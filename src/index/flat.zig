//! Flat (brute-force) vector index — the honest, always-correct baseline and the
//! mobile-tier default. Correct at any corpus size, just O(N·D).
//!
//! The core is `TopK`: a bounded **max-heap of the k smallest distances**. A
//! scan offers every candidate's distance; the heap keeps only the running best
//! k, so a pass over N candidates costs O(N·log k) time and O(k) memory and
//! never materializes the full result set. This is the structural fix for the
//! old `SELECT … LIMIT k` retrieval, which returned an arbitrary k rows and so
//! had broken recall for any corpus larger than k (PLAN.md §3).
//!
//! Allocation-free: the caller supplies the heap buffer (stack, arena, or a
//! budget-sized slab), keeping the selector usable inside a streaming DB cursor.

const std = @import("std");

/// Bounded top-k selector over an arbitrary payload `T` keyed by an f32 distance
/// (smaller = better). Backed by a max-heap so the worst kept element is always
/// at the root and evicted in O(log k) when a better candidate arrives.
pub fn TopK(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct { dist: f32, item: T };

        heap: []Entry,
        len: usize = 0,

        /// `buf.len` is the capacity k. A zero-length buffer accepts nothing.
        pub fn init(buf: []Entry) Self {
            return .{ .heap = buf, .len = 0 };
        }

        pub fn capacity(self: *const Self) usize {
            return self.heap.len;
        }

        /// True once k entries are held — past this point only a strictly better
        /// distance is kept, so a scan can skip materializing a doomed candidate.
        pub fn isFull(self: *const Self) bool {
            return self.heap.len > 0 and self.len == self.heap.len;
        }

        /// Distance of the current worst kept entry. Only meaningful when `len > 0`.
        pub fn worstDist(self: *const Self) f32 {
            return self.heap[0].dist;
        }

        /// Offer a candidate. Returns true if it was kept (heap not yet full, or
        /// it beats the current worst). NaN distances are rejected so a corrupt
        /// vector can never displace a real neighbour.
        pub fn offer(self: *Self, dist: f32, item: T) bool {
            if (self.heap.len == 0 or std.math.isNan(dist)) return false;
            if (self.len < self.heap.len) {
                self.heap[self.len] = .{ .dist = dist, .item = item };
                self.siftUp(self.len);
                self.len += 1;
                return true;
            }
            // Full: replace the worst (root) only if this is strictly better.
            if (dist >= self.heap[0].dist) return false;
            self.heap[0] = .{ .dist = dist, .item = item };
            self.siftDown(0);
            return true;
        }

        /// Sort the kept entries ascending by distance in place and return them
        /// (best first). The heap invariant is destroyed; call once when done.
        pub fn sortedAsc(self: *Self) []Entry {
            const out = self.heap[0..self.len];
            std.sort.block(Entry, out, {}, lessByDist);
            return out;
        }

        fn lessByDist(_: void, a: Entry, b: Entry) bool {
            return a.dist < b.dist;
        }

        fn siftUp(self: *Self, start: usize) void {
            var i = start;
            while (i > 0) {
                const parent = (i - 1) / 2;
                if (self.heap[i].dist <= self.heap[parent].dist) break;
                std.mem.swap(Entry, &self.heap[i], &self.heap[parent]);
                i = parent;
            }
        }

        fn siftDown(self: *Self, start: usize) void {
            var i = start;
            while (true) {
                const l = 2 * i + 1;
                const r = 2 * i + 2;
                var largest = i;
                if (l < self.len and self.heap[l].dist > self.heap[largest].dist) largest = l;
                if (r < self.len and self.heap[r].dist > self.heap[largest].dist) largest = r;
                if (largest == i) break;
                std.mem.swap(Entry, &self.heap[i], &self.heap[largest]);
                i = largest;
            }
        }
    };
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

test "TopK keeps the k smallest regardless of insertion order" {
    var buf: [3]TopK(usize).Entry = undefined;
    var tk = TopK(usize).init(&buf);
    const dists = [_]f32{ 5, 1, 9, 3, 7, 2, 8 };
    for (dists, 0..) |d, i| _ = tk.offer(d, i);

    const sorted = tk.sortedAsc();
    try testing.expectEqual(@as(usize, 3), sorted.len);
    try testing.expectEqual(@as(f32, 1), sorted[0].dist);
    try testing.expectEqual(@as(f32, 2), sorted[1].dist);
    try testing.expectEqual(@as(f32, 3), sorted[2].dist);
    // items travel with their distances
    try testing.expectEqual(@as(usize, 1), sorted[0].item);
    try testing.expectEqual(@as(usize, 5), sorted[1].item);
    try testing.expectEqual(@as(usize, 3), sorted[2].item);
}

test "TopK below capacity returns everything sorted" {
    var buf: [10]TopK(u8).Entry = undefined;
    var tk = TopK(u8).init(&buf);
    _ = tk.offer(3, 'c');
    _ = tk.offer(1, 'a');
    _ = tk.offer(2, 'b');
    const s = tk.sortedAsc();
    try testing.expectEqual(@as(usize, 3), s.len);
    try testing.expectEqual(@as(u8, 'a'), s[0].item);
    try testing.expectEqual(@as(u8, 'b'), s[1].item);
    try testing.expectEqual(@as(u8, 'c'), s[2].item);
}

test "TopK offer reports acceptance and rejects worse-than-worst" {
    var buf: [2]TopK(usize).Entry = undefined;
    var tk = TopK(usize).init(&buf);
    try testing.expect(tk.offer(5, 0)); // fills
    try testing.expect(tk.offer(3, 1)); // fills
    try testing.expect(!tk.offer(9, 2)); // worse than worst kept (5) -> rejected
    try testing.expect(tk.offer(1, 3)); // better -> evicts 5
    const s = tk.sortedAsc();
    try testing.expectEqual(@as(f32, 1), s[0].dist);
    try testing.expectEqual(@as(f32, 3), s[1].dist);
}

test "TopK with zero capacity accepts nothing" {
    var buf: [0]TopK(usize).Entry = .{};
    var tk = TopK(usize).init(&buf);
    try testing.expect(!tk.offer(1, 0));
    try testing.expectEqual(@as(usize, 0), tk.sortedAsc().len);
}

test "TopK rejects NaN distances" {
    var buf: [2]TopK(usize).Entry = undefined;
    var tk = TopK(usize).init(&buf);
    try testing.expect(!tk.offer(std.math.nan(f32), 0));
    try testing.expect(tk.offer(1, 1));
    try testing.expectEqual(@as(usize, 1), tk.len);
}

test "fuzz: TopK result equals a full sort's k-prefix" {
    var prng = std.Random.DefaultPrng.init(0x70BC);
    const rnd = prng.random();

    for (0..500) |_| {
        const n = rnd.intRangeAtMost(usize, 0, 40);
        const k = rnd.intRangeAtMost(usize, 1, 8);

        var all: [40]f32 = undefined;
        for (all[0..n]) |*d| d.* = rnd.float(f32) * 100;

        var buf: [8]TopK(usize).Entry = undefined;
        var tk = TopK(usize).init(buf[0..k]);
        for (all[0..n], 0..) |d, i| _ = tk.offer(d, i);

        // Reference: sort a copy, take k smallest distances.
        var ref: [40]f32 = undefined;
        @memcpy(ref[0..n], all[0..n]);
        std.sort.block(f32, ref[0..n], {}, std.sort.asc(f32));

        const got = tk.sortedAsc();
        const want = @min(k, n);
        try testing.expectEqual(want, got.len);
        for (0..want) |i| try testing.expectEqual(ref[i], got[i].dist);
    }
}
