//! Streaming semantic retrieval — the query-side scan that replaces the broken
//! `SELECT … LIMIT k`. It steps a cursor over every candidate row, decodes each
//! embedding BLOB into a single reused scratch buffer, scores it with the
//! `fusion` SIMD kernel, and feeds the distance to a bounded `flat.TopK` heap.
//!
//! Memory is O(k + D): only the survivors that actually enter the heap are
//! duplicated into the caller's arena, and a full heap short-circuits the dup of
//! any candidate that cannot beat the current worst. Time is O(N·D + N·log k).
//! Correct at every corpus size — the property the old `LIMIT k` lacked.

const std = @import("std");
pub const sqlite = @import("../sqlite.zig");
const fusion = @import("fusion.zig");
const flat = @import("../index/flat.zig");
pub const query = @import("query.zig");

const Allocator = std.mem.Allocator;

/// One scored chunk that survived the top-k scan. All slices are arena-owned.
pub const Match = struct {
    dist: f32,
    id: []const u8,
    document_id: []const u8,
    ordinal: []const u8,
    content: []const u8,
    emb: []f32,
};

/// Distance under `metric` (smaller = nearer): cosine distance `1 - cos`, or raw
/// L2. Kept here so the scan and any caller-side re-rank agree on the metric.
pub fn distance(metric: query.Metric, a: []const f32, b: []const f32) f32 {
    return switch (metric) {
        .cosine => 1.0 - fusion.cosineSimilarity(a, b),
        .euclidean => fusion.euclideanDistance(a, b),
    };
}

fn dupText(allocator: Allocator, stmt: *sqlite.sqlite3_stmt, col: c_int) ![]const u8 {
    const ptr = sqlite.sqlite3_column_text(stmt, col);
    const len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, col));
    return allocator.dupe(u8, ptr[0..len]);
}

/// What the hot scan keeps per survivor: just the id and its decoded vector. The
/// row payload (content/document_id/ordinal) is fetched afterwards for the k
/// winners only — see `vectorScanTopK`.
const ScanItem = struct { id: []const u8, emb: []f32 };

/// Scan the result of `sql` — which must select `id, embedding` in that order
/// (see `query.writeVectorScanAll`) — and return the `k` rows nearest to `qvec`,
/// sorted nearest-first, with their `content`/`document_id`/`ordinal` hydrated.
/// `sql` carries no `LIMIT`; the heap bounds the output.
///
/// Two phases: (1) stream every row, scoring `id`+`embedding` only, so the scan
/// never drags content bytes through the page cache for the N−k losers; (2) one
/// `WHERE id IN (…)` round-trip hydrates the surviving k.
pub fn vectorScanTopK(
    db: *sqlite.sqlite3,
    allocator: Allocator,
    sql: []const u8,
    qvec: []const f32,
    metric: query.Metric,
    k: usize,
) ![]Match {
    if (k == 0) return &.{};

    // ── Phase 1: full vector scan, id + embedding only ──
    const heap_buf = try allocator.alloc(flat.TopK(ScanItem).Entry, k);
    var tk = flat.TopK(ScanItem).init(heap_buf);
    {
        const stmt = try sqlite.prepare(db, sql);
        defer sqlite.finalize(stmt);

        // One scratch decode buffer, reused across rows (sized to the first
        // row's dimensionality and re-sized only if a row's width differs).
        var scratch: []f32 = &.{};
        while (true) {
            const rc = sqlite.sqlite3_step(stmt);
            if (rc == sqlite.SQLITE_DONE) break;
            if (rc != sqlite.SQLITE_ROW) try sqlite.check(rc);

            const blob_ptr = sqlite.sqlite3_column_blob(stmt, 1) orelse continue;
            const blob_len: usize = @intCast(sqlite.sqlite3_column_bytes(stmt, 1));
            const nfloats = blob_len / @sizeOf(f32);
            if (nfloats == 0 or blob_len % @sizeOf(f32) != 0) continue;

            if (scratch.len != nfloats) scratch = try allocator.alloc(f32, nfloats);
            // @memcpy through the aligned scratch avoids reinterpreting a
            // possibly unaligned SQLite BLOB pointer as []f32 (which would be UB).
            @memcpy(std.mem.sliceAsBytes(scratch), @as([*]const u8, @ptrCast(blob_ptr))[0..blob_len]);

            const d = distance(metric, scratch, qvec);
            if (std.math.isNan(d)) continue;
            // A full heap whose worst beats this row skips the duplication.
            if (tk.isFull() and d >= tk.worstDist()) continue;

            _ = tk.offer(d, .{
                .id = try dupText(allocator, stmt, 0),
                .emb = try allocator.dupe(f32, scratch),
            });
        }
    }

    const entries = tk.sortedAsc();
    const out = try allocator.alloc(Match, entries.len);
    for (entries, 0..) |e, i| out[i] = .{
        .dist = e.dist,
        .id = e.item.id,
        .document_id = "",
        .ordinal = "0",
        .content = "",
        .emb = e.item.emb,
    };
    if (out.len == 0) return out;

    // ── Phase 2: hydrate the k survivors in one round-trip ──
    try hydrate(db, allocator, out);
    return out;
}

/// Row payload fetched by id during hydration.
pub const RowData = struct { document_id: []const u8, ordinal: []const u8, content: []const u8 };

/// Fetch `document_id`/`ordinal`/`content` for an explicit id set in one
/// `WHERE id IN (…)` round-trip, keyed by id. Arena-owned. Shared by the flat
/// scan's hydration and the HNSW path. `ids.len == 0` yields an empty map.
pub fn fetchByIds(db: *sqlite.sqlite3, allocator: Allocator, ids: []const []const u8) !std.StringHashMapUnmanaged(RowData) {
    var by_id: std.StringHashMapUnmanaged(RowData) = .empty;
    if (ids.len == 0) return by_id;
    try by_id.ensureTotalCapacity(allocator, @intCast(ids.len));

    var aw = std.Io.Writer.Allocating.init(allocator);
    try query.writeChunksByIds(&aw.writer, ids);
    const stmt = try sqlite.prepare(db, aw.written());
    defer sqlite.finalize(stmt);

    while (true) {
        const rc = sqlite.sqlite3_step(stmt);
        if (rc == sqlite.SQLITE_DONE) break;
        if (rc != sqlite.SQLITE_ROW) try sqlite.check(rc);
        const id = try dupText(allocator, stmt, 0);
        by_id.putAssumeCapacity(id, .{
            .document_id = try dupText(allocator, stmt, 1),
            .ordinal = try dupText(allocator, stmt, 2),
            .content = try dupText(allocator, stmt, 3),
        });
    }
    return by_id;
}

/// Fill `content`/`document_id`/`ordinal` on `matches` (nearest-first order
/// preserved). Ids deleted between scan and fetch keep their empty defaults
/// rather than failing the whole retrieval.
pub fn hydrate(db: *sqlite.sqlite3, allocator: Allocator, matches: []Match) !void {
    const ids = try allocator.alloc([]const u8, matches.len);
    for (matches, 0..) |m, i| ids[i] = m.id;
    var by_id = try fetchByIds(db, allocator, ids);
    for (matches) |*m| {
        if (by_id.get(m.id)) |r| {
            m.document_id = r.document_id;
            m.ordinal = r.ordinal;
            m.content = r.content;
        }
    }
}
