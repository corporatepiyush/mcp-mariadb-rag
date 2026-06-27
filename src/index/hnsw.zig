//! HNSW — Hierarchical Navigable Small World graph (Malkov & Yashunin, 2016).
//!
//! The server/dc-tier vector index: O(log N) query instead of the flat scan's
//! O(N). A multi-layer proximity graph is descended greedily from a sparse top
//! layer down to the dense base layer, where a best-first search with a tunable
//! breadth (`efSearch`) collects the candidate neighbourhood.
//!
//! This is a self-contained, in-memory implementation: insert + search, the
//! neighbour-selection heuristic (Algorithm 4) for graph quality, per-node
//! connection pruning, and a generation-stamped visited set so a query never
//! pays an O(N) reset. Distances reuse the `fusion` SIMD kernels. Vectors and
//! the graph are owned by the index; `deinit` frees everything.
//!
//! Knobs map to PLAN.md §3: `m` (neighbours/node), `ef_construction`
//! (build breadth), `efSearch` (query breadth — the recall/latency dial).

const std = @import("std");
const fusion = @import("../rag/fusion.zig");

const Allocator = std.mem.Allocator;
const Order = std.math.Order;
const ArrayListU32 = std.ArrayListUnmanaged(u32);

pub const Metric = enum { cosine, l2 };

/// A scored graph node: `dist` to the query, `id` is the internal node index.
pub const Candidate = struct { dist: f32, id: u32 };

/// Public search hit: the caller-supplied `label` and its distance.
pub const Result = struct { label: u64, dist: f32 };

pub fn ascDist(_: void, a: Candidate, b: Candidate) bool {
    return a.dist < b.dist;
}

// Min-priority on distance (pop → nearest): the candidate frontier.
fn minOrder(_: void, a: Candidate, b: Candidate) Order {
    return std.math.order(a.dist, b.dist);
}
// Max-priority on distance (pop → farthest): the bounded result set.
fn maxOrder(_: void, a: Candidate, b: Candidate) Order {
    return std.math.order(b.dist, a.dist);
}

const MinPQ = std.PriorityQueue(Candidate, void, minOrder);
const MaxPQ = std.PriorityQueue(Candidate, void, maxOrder);

const Node = struct {
    vector: []f32,
    label: u64,
    level: usize,
    /// `conns[l]` = neighbour node ids at layer `l`, for `l` in `0..=level`.
    conns: []ArrayListU32,
};

pub const Options = struct {
    dims: usize,
    m: usize = 16,
    ef_construction: usize = 200,
    metric: Metric = .cosine,
    seed: u64 = 0x9E3779B97F4A7C15,
};

pub const Hnsw = struct {
    allocator: Allocator,
    dims: usize,
    m: usize, // max neighbours per node above layer 0
    m0: usize, // max neighbours at layer 0 (2·m, the usual choice)
    ef_construction: usize,
    ml: f64, // level-generation normaliser, 1/ln(m)
    metric: Metric,
    nodes: std.ArrayListUnmanaged(Node),
    entry: ?u32,
    max_level: usize,
    rng: std.Random.DefaultPrng,

    pub fn init(allocator: Allocator, opts: Options) Hnsw {
        const m = @max(@as(usize, 2), opts.m);
        return .{
            .allocator = allocator,
            .dims = opts.dims,
            .m = m,
            .m0 = m * 2,
            .ef_construction = @max(opts.ef_construction, m),
            .ml = 1.0 / @log(@as(f64, @floatFromInt(m))),
            .metric = opts.metric,
            .nodes = .empty,
            .entry = null,
            .max_level = 0,
            .rng = std.Random.DefaultPrng.init(opts.seed),
        };
    }

    pub fn deinit(self: *Hnsw) void {
        for (self.nodes.items) |*n| {
            self.allocator.free(n.vector);
            for (n.conns) |*c| c.deinit(self.allocator);
            self.allocator.free(n.conns);
        }
        self.nodes.deinit(self.allocator);
    }

    pub fn len(self: *const Hnsw) usize {
        return self.nodes.items.len;
    }

    fn dist(self: *const Hnsw, a: []const f32, b: []const f32) f32 {
        return switch (self.metric) {
            .cosine => 1.0 - fusion.cosineSimilarity(a, b),
            .l2 => fusion.euclideanDistance(a, b),
        };
    }

    fn randomLevel(self: *Hnsw) usize {
        // r ∈ (0,1]; clamp away from 0 so -ln(r) stays finite.
        const r = @max(self.rng.random().float(f64), std.math.floatMin(f64));
        const lvl = @floor(-@log(r) * self.ml);
        return @intFromFloat(@max(@as(f64, 0), lvl));
    }

    /// Best-first search of one layer. Returns the ≤`ef` nearest nodes to `q`
    /// reachable from `eps`, allocated in `a` (unordered). The visited set is
    /// arena-local (not instance state), so `search` mutates nothing on the
    /// graph and concurrent searches are safe under a shared lock.
    fn searchLayer(self: *Hnsw, a: Allocator, q: []const f32, eps: []const u32, ef: usize, layer: usize) ![]Candidate {
        const visited = try a.alloc(bool, self.nodes.items.len);
        @memset(visited, false);

        var frontier = MinPQ.initContext({});
        defer frontier.deinit(a);
        var result = MaxPQ.initContext({});
        defer result.deinit(a);

        for (eps) |e| {
            const d = self.dist(q, self.nodes.items[e].vector);
            try frontier.push(a, .{ .dist = d, .id = e });
            try result.push(a, .{ .dist = d, .id = e });
            visited[e] = true;
        }

        while (frontier.pop()) |c| {
            if (c.dist > result.peek().?.dist) break; // nearest unexplored worse than worst kept
            for (self.nodes.items[c.id].conns[layer].items) |e| {
                if (visited[e]) continue;
                visited[e] = true;
                const d = self.dist(q, self.nodes.items[e].vector);
                if (result.count() < ef or d < result.peek().?.dist) {
                    try frontier.push(a, .{ .dist = d, .id = e });
                    try result.push(a, .{ .dist = d, .id = e });
                    if (result.count() > ef) _ = result.pop(); // drop farthest
                }
            }
        }

        const out = try a.alloc(Candidate, result.count());
        var i: usize = 0;
        while (result.pop()) |c| : (i += 1) out[i] = c;
        return out;
    }

    /// Neighbour-selection heuristic (Algorithm 4): keep a candidate only if it
    /// is closer to `q` than to every already-kept neighbour, which spreads the
    /// connections out and sharply improves graph navigability over plain
    /// nearest-M. `cands` is sorted ascending in place. Returns up to `m` ids.
    fn selectHeuristic(self: *Hnsw, a: Allocator, cands: []Candidate, m: usize) ![]u32 {
        std.sort.block(Candidate, cands, {}, ascDist);
        var kept: ArrayListU32 = .empty;
        try kept.ensureTotalCapacity(a, m);
        for (cands) |c| {
            if (kept.items.len >= m) break;
            var good = true;
            for (kept.items) |r| {
                if (self.dist(self.nodes.items[c.id].vector, self.nodes.items[r].vector) < c.dist) {
                    good = false;
                    break;
                }
            }
            if (good) kept.appendAssumeCapacity(c.id);
        }
        return kept.items;
    }

    /// Re-select a node's layer neighbours down to `max_conn` via the heuristic
    /// after a new bidirectional edge pushed it over budget.
    fn prune(self: *Hnsw, a: Allocator, node_id: u32, layer: usize, max_conn: usize) !void {
        const node = &self.nodes.items[node_id];
        const cur = node.conns[layer].items;
        const cands = try a.alloc(Candidate, cur.len);
        for (cur, 0..) |nb, i| cands[i] = .{ .dist = self.dist(node.vector, self.nodes.items[nb].vector), .id = nb };
        const kept = try self.selectHeuristic(a, cands, max_conn);
        node.conns[layer].clearRetainingCapacity();
        node.conns[layer].appendSliceAssumeCapacity(kept);
    }

    /// Insert `vector` (length must equal `dims`) under caller key `label`.
    /// Returns the internal node id.
    pub fn insert(self: *Hnsw, vector: []const f32, label: u64) !u32 {
        std.debug.assert(vector.len == self.dims);
        const level = self.randomLevel();

        const conns = try self.allocator.alloc(ArrayListU32, level + 1);
        errdefer self.allocator.free(conns);
        for (conns) |*c| c.* = .empty;
        const vcopy = try self.allocator.dupe(f32, vector);
        errdefer self.allocator.free(vcopy);

        const nid: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{ .vector = vcopy, .label = label, .level = level, .conns = conns });

        if (self.entry == null) {
            self.entry = nid;
            self.max_level = level;
            return nid;
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var eps: ArrayListU32 = .empty;
        try eps.append(a, self.entry.?);

        // Descend the empty upper layers greedily (ef = 1).
        var lc = self.max_level;
        while (lc > level) : (lc -= 1) {
            const w = try self.searchLayer(a, vcopy, eps.items, 1, lc);
            eps.clearRetainingCapacity();
            try eps.append(a, nearest(w));
        }

        // Connect from the node's top layer down to 0.
        var layer: isize = @intCast(@min(level, self.max_level));
        while (layer >= 0) : (layer -= 1) {
            const l: usize = @intCast(layer);
            const w = try self.searchLayer(a, vcopy, eps.items, self.ef_construction, l);
            const max_conn = if (l == 0) self.m0 else self.m;

            const dup = try a.dupe(Candidate, w);
            const selected = try self.selectHeuristic(a, dup, self.m);
            for (selected) |e| {
                try self.nodes.items[nid].conns[l].append(self.allocator, e);
                try self.nodes.items[e].conns[l].append(self.allocator, nid);
                if (self.nodes.items[e].conns[l].items.len > max_conn) try self.prune(a, e, l, max_conn);
            }

            eps.clearRetainingCapacity();
            for (w) |c| try eps.append(a, c.id);
        }

        if (level > self.max_level) {
            self.entry = nid;
            self.max_level = level;
        }
        return nid;
    }

    /// Approximate k nearest neighbours of `query`, nearest first. `ef_search`
    /// is the query-time breadth (clamped up to `k`); larger = higher recall.
    pub fn search(self: *Hnsw, a: Allocator, query: []const f32, k: usize, ef_search: usize) ![]Result {
        if (self.entry == null or k == 0) return &.{};

        var eps: ArrayListU32 = .empty;
        try eps.append(a, self.entry.?);

        var lc = self.max_level;
        while (lc > 0) : (lc -= 1) {
            const w = try self.searchLayer(a, query, eps.items, 1, lc);
            eps.clearRetainingCapacity();
            try eps.append(a, nearest(w));
        }

        const w = try self.searchLayer(a, query, eps.items, @max(ef_search, k), 0);
        std.sort.block(Candidate, w, {}, ascDist);
        const n = @min(k, w.len);
        const out = try a.alloc(Result, n);
        for (w[0..n], 0..) |c, i| out[i] = .{ .label = self.nodes.items[c.id].label, .dist = c.dist };
        return out;
    }

    fn nearest(cands: []const Candidate) u32 {
        var best = cands[0];
        for (cands[1..]) |c| {
            if (c.dist < best.dist) best = c;
        }
        return best.id;
    }
};
