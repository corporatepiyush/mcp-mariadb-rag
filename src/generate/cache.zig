//! Semantic query cache — short-circuits the whole retrieval funnel when a
//! near-identical query recurs (PLAN.md §6/§7).
//!
//! A query is a cache hit when a stored entry has the *same* parameter signature
//! (k, vecK, metric, mmr, filter, …) AND its query embedding is within
//! `threshold` cosine of the new one. Matching on both keeps results correct:
//! the same vector under different `k`/filters must not reuse a stale response.
//!
//! Storage is a fixed-capacity ring (oldest-evicted), guarded by an
//! `std.Io.Mutex`. Any corpus write clears the cache, since cached responses
//! reflect the corpus at insertion time. Opt-in (capacity 0 = disabled), so it
//! is inert until configured.

const std = @import("std");
const fusion = @import("../rag/fusion.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Options = struct {
    /// Ring capacity in entries; 0 disables the cache.
    capacity: usize = 0,
    /// Cosine ≥ this counts as the same query.
    threshold: f32 = 0.97,
};

pub const QueryCache = struct {
    mutex: Io.Mutex = .init,
    io: Io,
    gpa: Allocator,
    threshold: f32,
    entries: []Entry, // ring; `embedding.len == 0` marks an empty slot
    head: usize = 0,

    const Entry = struct {
        embedding: []f32 = &.{},
        sig: u64 = 0,
        response: []u8 = &.{},
    };

    pub fn init(gpa: Allocator, io: Io, opts: Options) !QueryCache {
        const entries = try gpa.alloc(Entry, opts.capacity);
        for (entries) |*e| e.* = .{};
        return .{ .io = io, .gpa = gpa, .threshold = opts.threshold, .entries = entries };
    }

    pub fn deinit(self: *QueryCache) void {
        self.clearLocked();
        self.gpa.free(self.entries);
    }

    pub fn enabled(self: *const QueryCache) bool {
        return self.entries.len > 0;
    }

    inline fn lock(self: *QueryCache) void {
        self.mutex.lockUncancelable(self.io);
    }
    inline fn unlock(self: *QueryCache) void {
        self.mutex.unlock(self.io);
    }

    /// Return a cached response for `(qvec, sig)` duped into `arena`, or null.
    pub fn get(self: *QueryCache, arena: Allocator, qvec: []const f32, sig: u64) ?[]const u8 {
        if (self.entries.len == 0) return null;
        self.lock();
        defer self.unlock();
        for (self.entries) |e| {
            if (e.embedding.len == 0 or e.sig != sig) continue;
            if (fusion.cosineSimilarity(qvec, e.embedding) >= self.threshold) {
                return arena.dupe(u8, e.response) catch null;
            }
        }
        return null;
    }

    /// Store `response` for `(qvec, sig)`, evicting the oldest slot if full. The
    /// embedding and response are copied into the cache's own allocator.
    pub fn put(self: *QueryCache, qvec: []const f32, sig: u64, response: []const u8) void {
        if (self.entries.len == 0) return;
        const emb = self.gpa.dupe(f32, qvec) catch return;
        const resp = self.gpa.dupe(u8, response) catch {
            self.gpa.free(emb);
            return;
        };
        self.lock();
        defer self.unlock();
        const slot = &self.entries[self.head];
        if (slot.embedding.len != 0) {
            self.gpa.free(slot.embedding);
            self.gpa.free(slot.response);
        }
        slot.* = .{ .embedding = emb, .sig = sig, .response = resp };
        self.head = (self.head + 1) % self.entries.len;
    }

    /// Drop every entry — called after a corpus write so stale answers can't be
    /// served.
    pub fn clear(self: *QueryCache) void {
        if (self.entries.len == 0) return;
        self.lock();
        defer self.unlock();
        self.clearLocked();
    }

    fn clearLocked(self: *QueryCache) void {
        for (self.entries) |*e| {
            if (e.embedding.len != 0) {
                self.gpa.free(e.embedding);
                self.gpa.free(e.response);
            }
            e.* = .{};
        }
        self.head = 0;
    }
};

// ── Process-global instance ───────────────────────────────────────────

var g_instance: ?*QueryCache = null;

pub fn setGlobal(c: *QueryCache) void {
    g_instance = c;
}

pub fn global() ?*QueryCache {
    return g_instance;
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

fn makeCache(io: Io, cap: usize, thr: f32) !QueryCache {
    return QueryCache.init(testing.allocator, io, .{ .capacity = cap, .threshold = thr });
}

test "cache: near-identical query with same sig hits; different sig misses" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var c = try makeCache(threaded.io(), 8, 0.97);
    defer c.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v1 = [_]f32{ 1.0, 0.0, 0.0 };
    c.put(&v1, 42, "RESULT-A");

    // Same direction (cosine 1.0) + same sig → hit.
    const v2 = [_]f32{ 2.0, 0.0, 0.0 };
    const hit = c.get(a, &v2, 42) orelse return error.ExpectedHit;
    try testing.expectEqualStrings("RESULT-A", hit);

    // Same vector, different param signature → miss.
    try testing.expect(c.get(a, &v2, 99) == null);
}

test "cache: dissimilar query misses" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var c = try makeCache(threaded.io(), 8, 0.97);
    defer c.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const v1 = [_]f32{ 1.0, 0.0 };
    c.put(&v1, 1, "X");
    const ortho = [_]f32{ 0.0, 1.0 }; // cosine 0 < 0.97
    try testing.expect(c.get(arena.allocator(), &ortho, 1) == null);
}

test "cache: ring eviction drops the oldest" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var c = try makeCache(threaded.io(), 2, 0.99);
    defer c.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const e0 = [_]f32{ 1, 0, 0 };
    const e1 = [_]f32{ 0, 1, 0 };
    const e2 = [_]f32{ 0, 0, 1 };
    c.put(&e0, 1, "zero");
    c.put(&e1, 1, "one");
    c.put(&e2, 1, "two"); // evicts e0

    try testing.expect(c.get(a, &e0, 1) == null); // evicted
    try testing.expectEqualStrings("one", c.get(a, &e1, 1) orelse return error.Miss);
    try testing.expectEqualStrings("two", c.get(a, &e2, 1) orelse return error.Miss);
}

test "cache: clear empties everything" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var c = try makeCache(threaded.io(), 4, 0.9);
    defer c.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const v = [_]f32{ 1, 1 };
    c.put(&v, 1, "keep?");
    c.clear();
    try testing.expect(c.get(arena.allocator(), &v, 1) == null);
}

test "cache: disabled (capacity 0) is inert" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var c = try makeCache(threaded.io(), 0, 0.9);
    defer c.deinit();
    try testing.expect(!c.enabled());
    const v = [_]f32{1};
    c.put(&v, 1, "x"); // no-op
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect(c.get(arena.allocator(), &v, 1) == null);
}
