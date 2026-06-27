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

    pub fn init(io: Io, gpa: Allocator, opts: Options) !QueryCache {
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
