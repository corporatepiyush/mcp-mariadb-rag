//! In-memory ANN index cache that accelerates semantic search from the flat
//! O(N) scan to HNSW's O(log N), kept consistent with the SQLite corpus by a
//! coarse epoch counter.
//!
//! Design (read-heavy RAG): the index is a *derived cache*. Any write
//! (ingest/upsert/delete) bumps `corpus_epoch`; a search that finds the cached
//! index stale rebuilds it from the corpus once, under an exclusive lock, then
//! serves subsequent reads in parallel under a shared lock. This sidesteps the
//! hard problems of incremental HNSW deletion and per-insert maintenance: the
//! graph always reflects a committed snapshot, and a deleted chunk can never be
//! returned because the rebuild simply doesn't include it.
//!
//! Opt-in via `MCP_INDEX_TYPE=hnsw` (default `flat` = the existing scan, so this
//! is zero-risk until enabled). When disabled, or on any build error, `search`
//! returns null and the caller falls back to the always-correct flat scan.

const std = @import("std");
const sqlite = @import("../sqlite.zig");
const hnsw = @import("hnsw.zig");
const query = @import("../rag/query.zig");
const schema = @import("../rag/schema.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Options = struct {
    enabled: bool = false,
    metric: hnsw.Metric = .cosine,
    m: usize = 16,
    ef_construction: usize = 200,
    ef_search: usize = 64,
};

/// One ANN hit: the chunk id (duped into the caller's arena) and its distance.
pub const Hit = struct { id: []const u8, dist: f32 };

pub const Store = struct {
    mutex: Io.Mutex = .init,
    io: Io,
    gpa: Allocator,
    opts: Options,
    index: ?hnsw.Hnsw = null,
    ids: [][]const u8 = &.{}, // label → chunk id (owned by `gpa`)
    corpus_epoch: std.atomic.Value(u64) = .init(0),
    built_epoch: u64 = std.math.maxInt(u64),

    pub fn init(gpa: Allocator, io: Io, opts: Options) Store {
        return .{ .io = io, .gpa = gpa, .opts = opts };
    }

    inline fn lock(self: *Store) void {
        self.mutex.lockUncancelable(self.io);
    }
    inline fn unlock(self: *Store) void {
        self.mutex.unlock(self.io);
    }

    pub fn deinit(self: *Store) void {
        self.freeIndex();
    }

    fn freeIndex(self: *Store) void {
        if (self.index) |*ix| {
            ix.deinit();
            self.index = null;
        }
        for (self.ids) |id| self.gpa.free(id);
        if (self.ids.len > 0) self.gpa.free(self.ids);
        self.ids = &.{};
    }

    pub fn enabled(self: *const Store) bool {
        return self.opts.enabled;
    }

    /// Invalidate the cache. Called after every committed write so the next
    /// search rebuilds against the new corpus.
    pub fn bumpEpoch(self: *Store) void {
        _ = self.corpus_epoch.fetchAdd(1, .monotonic);
    }

    /// Return the metric this index was built with, so the caller scores the
    /// results consistently. (Distances also come back from `search`.)
    pub fn metric(self: *const Store) hnsw.Metric {
        return self.opts.metric;
    }

    /// Approximate nearest `k` chunk ids (nearest-first) with their distances,
    /// duplicated into `arena`. Returns null when the index is disabled or a
    /// build fails — the caller then uses the flat scan.
    pub fn search(self: *Store, db: *sqlite.sqlite3, arena: Allocator, qvec: []const f32, k: usize) ?[]Hit {
        if (!self.opts.enabled or k == 0) return null;

        // One mutex guards both rebuild and search. The search critical section
        // is O(log N) microseconds; rebuilds are rare (read-heavy corpus), so
        // serialising is an acceptable v1 versus the O(N) flat-scan alternative.
        self.lock();
        defer self.unlock();
        if (self.index == null or self.built_epoch != self.corpus_epoch.load(.monotonic)) {
            self.rebuild(db) catch {
                return null; // fall back to flat scan; never poison the cache
            };
        }
        return self.searchLocked(arena, qvec, k);
    }

    /// Caller holds the lock. Resolves labels to chunk ids and dupes them into
    /// `arena` while `self.ids` is guaranteed stable.
    fn searchLocked(self: *Store, arena: Allocator, qvec: []const f32, k: usize) ?[]Hit {
        if (self.index == null) return null;
        const res = self.index.?.search(arena, qvec, k, self.opts.ef_search) catch return null;
        const out = arena.alloc(Hit, res.len) catch return null;
        for (res, 0..) |r, i| {
            const id = arena.dupe(u8, self.ids[@intCast(r.label)]) catch return null;
            out[i] = .{ .id = id, .dist = r.dist };
        }
        return out;
    }

    /// Rebuild the graph from the committed corpus. Caller holds the exclusive
    /// lock. On success `built_epoch` matches the epoch captured at entry.
    fn rebuild(self: *Store, db: *sqlite.sqlite3) !void {
        const epoch = self.corpus_epoch.load(.monotonic);
        const dims = schema.embeddingDims();

        var fresh = hnsw.Hnsw.init(self.gpa, .{
            .dims = dims,
            .m = self.opts.m,
            .ef_construction = self.opts.ef_construction,
            .metric = self.opts.metric,
        });
        errdefer fresh.deinit();

        var ids: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (ids.items) |id| self.gpa.free(id);
            ids.deinit(self.gpa);
        }

        var sql_buf = std.Io.Writer.Allocating.init(self.gpa);
        defer sql_buf.deinit();
        try query.writeVectorScanAll(&sql_buf.writer);
        const stmt = try sqlite.prepare(db, sql_buf.written());
        defer sqlite.finalize(stmt);

        const scratch = try self.gpa.alloc(f32, dims);
        defer self.gpa.free(scratch);

        var label: u64 = 0;
        while (true) {
            const rc = sqlite.sqlite3_step(stmt);
            if (rc == sqlite.SQLITE_DONE) break;
            if (rc != sqlite.SQLITE_ROW) try sqlite.check(rc);

            const blob_ptr = sqlite.sqlite3_column_blob(stmt, 1) orelse continue;
            const blob_len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, 1));
            if (blob_len != dims * @sizeOf(f32)) continue; // skip mismatched-width rows
            @memcpy(std.mem.sliceAsBytes(scratch), @as([*]const u8, @ptrCast(blob_ptr))[0..blob_len]);

            const id_ptr = sqlite.sqlite3_column_text(stmt, 0);
            const id_len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, 0));
            const id = try self.gpa.dupe(u8, id_ptr[0..id_len]);
            errdefer self.gpa.free(id);
            try ids.append(self.gpa, id);

            _ = try fresh.insert(scratch, label);
            label += 1;
        }

        // Swap in the new index, freeing the old.
        self.freeIndex();
        self.index = fresh;
        self.ids = try ids.toOwnedSlice(self.gpa);
        self.built_epoch = epoch;
    }
};

// ── Process-global instance ───────────────────────────────────────────
// The handler signature can't carry the store, so (like the embedding-dims
// runtime field) a single instance is published at startup and read by the RAG
// handlers. The pointee lives for the process lifetime (a `main` local).

var g_instance: ?*Store = null;

pub fn setGlobal(s: *Store) void {
    g_instance = s;
}

pub fn global() ?*Store {
    return g_instance;
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

fn createSchema(db: *sqlite.sqlite3, a: Allocator) !void {
    _ = a;
    try sqlite.execScript(db, schema.ddl);
}

fn insertVec(db: *sqlite.sqlite3, a: Allocator, id: []const u8, fill: f32) !void {
    const vec = try a.alloc(f32, schema.embeddingDims());
    @memset(vec, fill);
    const rows = [_]query.ChunkRow{.{ .id = id, .document_id = "d", .ordinal = 0, .content = "c", .token_count = 1, .vector = vec }};
    var aw = std.Io.Writer.Allocating.init(a);
    try query.writeUpsertChunks(&aw.writer, &rows);
    const stmt = try sqlite.prepare(db, aw.written());
    defer sqlite.finalize(stmt);
    try sqlite.check(sqlite.sqlite3_step(stmt));
}

test "store: disabled returns null (caller uses flat scan)" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var s = Store.init(testing.allocator, threaded.io(), .{ .enabled = false });
    defer s.deinit();
    const db = try sqlite.openInMemory();
    defer sqlite.close(db);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const q = try arena.allocator().alloc(f32, schema.embeddingDims());
    @memset(q, 0.5);
    try testing.expect(s.search(db, arena.allocator(), q, 5) == null);
}

test "store: builds on demand and finds the nearest, then serves cached" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const db = try sqlite.openInMemory();
    defer sqlite.close(db);
    try createSchema(db, a);

    // Fills 0.10, 0.12, … so the query at 0.30 lands on id "c10".
    for (0..30) |i| {
        const id = try std.fmt.allocPrint(a, "c{d}", .{i});
        try insertVec(db, a, id, 0.10 + @as(f32, @floatFromInt(i)) * 0.02);
    }

    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var s = Store.init(testing.allocator, threaded.io(), .{ .enabled = true, .metric = .l2, .m = 16, .ef_construction = 100, .ef_search = 64 });
    defer s.deinit();
    s.bumpEpoch(); // simulate a write having happened

    const q = try a.alloc(f32, schema.embeddingDims());
    @memset(q, 0.30); // == fill of c10

    const res = s.search(db, a, q, 3) orelse return error.UnexpectedNull;
    try testing.expectEqual(@as(usize, 3), res.len);
    try testing.expectEqualStrings("c10", res[0].id);
    try testing.expectApproxEqAbs(@as(f32, 0), res[0].dist, 1e-3);

    // Second call hits the cache (same epoch) and is still correct.
    const res2 = s.search(db, a, q, 1) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("c10", res2[0].id);
}

test "store: a bumpEpoch forces a rebuild that sees new rows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const db = try sqlite.openInMemory();
    defer sqlite.close(db);
    try createSchema(db, a);
    try insertVec(db, a, "first", 0.9);

    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var s = Store.init(testing.allocator, threaded.io(), .{ .enabled = true, .metric = .l2 });
    defer s.deinit();
    s.bumpEpoch();

    const q = try a.alloc(f32, schema.embeddingDims());
    @memset(q, 0.1);
    _ = s.search(db, a, q, 5) orelse return error.UnexpectedNull; // builds with 1 row

    // Insert a row much closer to q, bump, and confirm the rebuild surfaces it.
    try insertVec(db, a, "closer", 0.1);
    s.bumpEpoch();
    const res = s.search(db, a, q, 1) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("closer", res[0].id);
}
