//! SQL generation for the RAG document/chunk store.
//!
//! Mirrors the KG layer's split: every `write*` emits one statement into a
//! `*std.Io.Writer`, so the SQL is unit-testable without a live database.
//! User-derived text is escaped for the single-quoted literal context.
//! Vectors are stored as f32 BLOBs and indexed via the in-memory HNSW/IVF-FLAT
//! index (not SQL VEC_* functions — Phase 1d/1e).

const std = @import("std");
const validation = @import("../validation.zig");
const schema = @import("schema.zig");

const Writer = std.Io.Writer;

// ── Literal helpers ───────────────────────────────────────────────────

fn writeSqlLiteral(w: *Writer, s: []const u8) !void {
    try w.writeByte('\'');
    try validation.writeEscapedLiteral(w, s);
    try w.writeByte('\'');
}

/// `LIKE '%<q>%'` as a single escaped literal. Matches the KG layer's
/// lexical-search convention.
fn writeLikeContains(w: *Writer, query: []const u8) !void {
    try w.writeAll("LIKE '%");
    try validation.writeEscapedLiteral(w, query);
    try w.writeAll("%'");
}

fn writeVectorLiteral(w: *Writer, vector: []const f32) !void {
    try w.writeAll("X'");
    const bytes = std.mem.sliceAsBytes(vector);
    for (bytes) |b| {
        try w.writeByte(hex_chars[b >> 4]);
        try w.writeByte(hex_chars[b & 0xf]);
    }
    try w.writeByte('\'');
}

const hex_chars = "0123456789abcdef";

// ── Distance metric ───────────────────────────────────────────────────
// Retained for API compatibility; distance computation moves to
// application code (fusion.zig SIMD kernels) in Phase 1e.

pub const Metric = enum {
    euclidean,
    cosine,

    pub fn parse(s: ?[]const u8) Metric {
        const str = s orelse return .euclidean;
        if (std.ascii.eqlIgnoreCase(str, "cosine")) return .cosine;
        return .euclidean;
    }
};

// ── Document operations ───────────────────────────────────────────────

/// Upsert a document row by its string id. `metadata` is a raw JSON object.
pub fn writeUpsertDocument(
    w: *Writer,
    id: []const u8,
    uri: []const u8,
    title: []const u8,
    metadata: []const u8,
    chunk_count: u64,
) !void {
    try w.writeAll("INSERT INTO ");
    try validation.writeQuotedIdent(w, schema.document_table);
    try w.writeAll(" (id, uri, title, metadata, chunk_count) VALUES (");
    try writeSqlLiteral(w, id);
    try w.writeByte(',');
    try writeSqlLiteral(w, uri);
    try w.writeByte(',');
    try writeSqlLiteral(w, title);
    try w.writeByte(',');
    try writeSqlLiteral(w, metadata);
    try w.print(",{d})", .{chunk_count});
    try w.writeAll(" ON CONFLICT(id) DO UPDATE SET uri=excluded.uri, title=excluded.title, metadata=excluded.metadata, chunk_count=excluded.chunk_count");
}

/// `SELECT id, uri, title, metadata, chunk_count FROM rag_document WHERE id = '<id>'`
pub fn writeGetDocument(w: *Writer, id: []const u8) !void {
    try w.writeAll("SELECT id, uri, title, metadata, chunk_count FROM ");
    try validation.writeQuotedIdent(w, schema.document_table);
    try w.writeAll(" WHERE id = ");
    try writeSqlLiteral(w, id);
}

/// `SELECT ... FROM rag_document ORDER BY id [LIMIT n [OFFSET m]]`
pub fn writeListDocuments(w: *Writer, limit: ?u64, offset: ?u64) !void {
    try w.writeAll("SELECT id, uri, title, metadata, chunk_count FROM ");
    try validation.writeQuotedIdent(w, schema.document_table);
    try w.writeAll(" ORDER BY id");
    if (limit) |l| try w.print(" LIMIT {d}", .{l});
    if (offset) |o| try w.print(" OFFSET {d}", .{o});
}

pub fn writeDeleteDocument(w: *Writer, id: []const u8) !void {
    try w.writeAll("DELETE FROM ");
    try validation.writeQuotedIdent(w, schema.document_table);
    try w.writeAll(" WHERE id = ");
    try writeSqlLiteral(w, id);
}

// ── Chunk operations ──────────────────────────────────────────────────

/// One row for the batch chunk upsert. `vector` length should equal
/// `schema.embedding_dims`.
pub const ChunkRow = struct {
    id: []const u8,
    document_id: []const u8,
    ordinal: u64,
    content: []const u8,
    token_count: u64,
    vector: []const f32,
};

/// Multi-row `REPLACE INTO rag_chunk (...) VALUES (...), (...)`. Caller must
/// guarantee `rows.len > 0`.
pub fn writeUpsertChunks(w: *Writer, rows: []const ChunkRow) !void {
    try w.writeAll("INSERT INTO ");
    try validation.writeQuotedIdent(w, schema.chunk_table);
    try w.writeAll(" (id, document_id, ordinal, content, token_count, embedding) VALUES ");
    for (rows, 0..) |r, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeByte('(');
        try writeSqlLiteral(w, r.id);
        try w.writeByte(',');
        try writeSqlLiteral(w, r.document_id);
        try w.print(",{d},", .{r.ordinal});
        try writeSqlLiteral(w, r.content);
        try w.print(",{d},", .{r.token_count});
        try writeVectorLiteral(w, r.vector);
        try w.writeAll(")");
    }
    try w.writeAll(" ON CONFLICT(id) DO UPDATE SET document_id=excluded.document_id, ordinal=excluded.ordinal, content=excluded.content, token_count=excluded.token_count, embedding=excluded.embedding");
}

pub fn writeDeleteChunksByDocument(w: *Writer, document_id: []const u8) !void {
    try w.writeAll("DELETE FROM ");
    try validation.writeQuotedIdent(w, schema.chunk_table);
    try w.writeAll(" WHERE document_id = ");
    try writeSqlLiteral(w, document_id);
}

pub fn writeChunksByDocument(w: *Writer, document_id: []const u8) !void {
    try w.writeAll("SELECT id, document_id, ordinal, content FROM ");
    try validation.writeQuotedIdent(w, schema.chunk_table);
    try w.writeAll(" WHERE document_id = ");
    try writeSqlLiteral(w, document_id);
    try w.writeAll(" ORDER BY ordinal");
}

// ── Retrieval ─────────────────────────────────────────────────────────

/// Full semantic scan: only `id` + `embedding`, no `LIMIT`. Top-k selection
/// happens application-side via the streaming `flat.TopK` heap
/// (`retrieve.vectorScanTopK`), which keeps O(k) memory while scanning O(N)
/// rows. Selecting *just* the two columns the distance kernel needs keeps the
/// scan off the (potentially large) `content`/metadata bytes — those are
/// hydrated for the k survivors via `writeChunksByIds`. This replaces the old
/// `SELECT … LIMIT k`, which returned an arbitrary k rows and so had broken
/// recall for any corpus larger than k (PLAN.md §3).
/// `SELECT id, embedding FROM rag_chunk`
pub fn writeVectorScanAll(w: *Writer) !void {
    try w.writeAll("SELECT id, embedding FROM ");
    try validation.writeQuotedIdent(w, schema.chunk_table);
}

/// `<column> IN ('a','b',…)` with each id escaped. Caller guarantees `ids.len > 0`.
fn writeInList(w: *Writer, column: []const u8, ids: []const []const u8) !void {
    try w.writeAll(column);
    try w.writeAll(" IN (");
    for (ids, 0..) |id, i| {
        if (i > 0) try w.writeByte(',');
        try writeSqlLiteral(w, id);
    }
    try w.writeByte(')');
}

/// Document-scoped variant of the full vector scan: restricts the scan to chunks
/// whose `document_id` is in `doc_ids` (metadata pre-filtering — PLAN.md §2),
/// which the planner serves via `idx_chunk_doc` instead of a full table scan.
/// Caller guarantees `doc_ids.len > 0`.
/// `SELECT id, embedding FROM rag_chunk WHERE document_id IN ('a','b')`
pub fn writeVectorScanByDocuments(w: *Writer, doc_ids: []const []const u8) !void {
    try w.writeAll("SELECT id, embedding FROM ");
    try validation.writeQuotedIdent(w, schema.chunk_table);
    try w.writeAll(" WHERE ");
    try writeInList(w, "document_id", doc_ids);
}

/// Fetch the row payload for an explicit set of chunk ids — the hydration step
/// that fills `content`/`document_id`/`ordinal` for the top-k survivors of the
/// vector scan. Caller must guarantee `ids.len > 0`.
/// `SELECT id, document_id, ordinal, content FROM rag_chunk WHERE id IN ('a','b')`
pub fn writeChunksByIds(w: *Writer, ids: []const []const u8) !void {
    try w.writeAll("SELECT id, document_id, ordinal, content FROM ");
    try validation.writeQuotedIdent(w, schema.chunk_table);
    try w.writeAll(" WHERE ");
    try writeInList(w, "id", ids);
}

/// Lexical top-k by substring match. Ordered by content length ascending as a
/// simple match-density proxy (shorter chunks containing the term score higher);
/// RRF only needs a stable rank, the semantic side carries the fine ordering.
/// When `doc_ids` is non-null the match is scoped to those documents.
pub fn writeLexicalTopK(w: *Writer, query: []const u8, k: u64, doc_ids: ?[]const []const u8) !void {
    try w.writeAll("SELECT id, document_id, ordinal, content, embedding FROM ");
    try validation.writeQuotedIdent(w, schema.chunk_table);
    try w.writeAll(" WHERE content ");
    try writeLikeContains(w, query);
    if (doc_ids) |ids| {
        try w.writeAll(" AND ");
        try writeInList(w, "document_id", ids);
    }
    try w.print(" ORDER BY LENGTH(content) LIMIT {d}", .{k});
}

// ── Stats ─────────────────────────────────────────────────────────────

/// Combined document + chunk counts in one round-trip.
pub fn writeRagStatistics(w: *Writer) !void {
    try w.writeAll("SELECT (SELECT COUNT(*) FROM ");
    try validation.writeQuotedIdent(w, schema.document_table);
    try w.writeAll("), (SELECT COUNT(*) FROM ");
    try validation.writeQuotedIdent(w, schema.chunk_table);
    try w.writeByte(')');
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

fn renderSql(buf: []u8, comptime f: anytype, args: anytype) ![]u8 {
    var w = Writer.fixed(buf);
    try @call(.auto, f, .{&w} ++ args);
    return w.buffered();
}

test "writeUpsertDocument" {
    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings(
        "INSERT INTO `rag_document` (id, uri, title, metadata, chunk_count) VALUES ('d1','file://x','Title','{}',3) ON CONFLICT(id) DO UPDATE SET uri=excluded.uri, title=excluded.title, metadata=excluded.metadata, chunk_count=excluded.chunk_count",
        try renderSql(&buf, writeUpsertDocument, .{ "d1", "file://x", "Title", "{}", @as(u64, 3) }),
    );
}

test "writeUpsertDocument escapes quotes" {
    var buf: [1024]u8 = undefined;
    const out = try renderSql(&buf, writeUpsertDocument, .{ "d'1", "u", "O'Hara", "{}", @as(u64, 0) });
    try testing.expect(std.mem.indexOf(u8, out, "'d''1'") != null);
    try testing.expect(std.mem.indexOf(u8, out, "'O''Hara'") != null);
}

test "writeGetDocument" {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "SELECT id, uri, title, metadata, chunk_count FROM `rag_document` WHERE id = 'd1'",
        try renderSql(&buf, writeGetDocument, .{"d1"}),
    );
}

test "writeListDocuments with limit/offset" {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "SELECT id, uri, title, metadata, chunk_count FROM `rag_document` ORDER BY id LIMIT 10 OFFSET 5",
        try renderSql(&buf, writeListDocuments, .{ @as(?u64, 10), @as(?u64, 5) }),
    );
}

test "writeUpsertChunks batches rows" {
    var buf: [2048]u8 = undefined;
    const v0 = [_]f32{ 0.1, 0.2 };
    const v1 = [_]f32{ 0.3, 0.4 };
    const rows = [_]ChunkRow{
        .{ .id = "d1#0", .document_id = "d1", .ordinal = 0, .content = "hello", .token_count = 1, .vector = &v0 },
        .{ .id = "d1#1", .document_id = "d1", .ordinal = 1, .content = "world", .token_count = 1, .vector = &v1 },
    };
    const out = try renderSql(&buf, writeUpsertChunks, .{&rows});
    try testing.expect(std.mem.indexOf(u8, out, "INSERT INTO `rag_chunk` (id, document_id, ordinal, content, token_count, embedding) VALUES ") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ON CONFLICT(id) DO UPDATE") != null);
    try testing.expect(std.mem.indexOf(u8, out, "X'") != null);
    try testing.expect(std.mem.indexOf(u8, out, "('d1#0','d1',0,'hello',1,") != null);
    try testing.expect(std.mem.indexOf(u8, out, ", ('d1#1','d1',1,'world',1,") != null);
}

test "writeVectorScanAll scans only id + embedding, no LIMIT (full recall scan)" {
    var buf: [2048]u8 = undefined;
    const e = try renderSql(&buf, writeVectorScanAll, .{});
    try testing.expect(std.mem.indexOf(u8, e, "VEC_DISTANCE_EUCLIDEAN") == null);
    try testing.expectEqualStrings("SELECT id, embedding FROM `rag_chunk`", e);
    // No content/metadata in the hot scan, and no LIMIT — the heap bounds it.
    try testing.expect(std.mem.indexOf(u8, e, "content") == null);
    try testing.expect(std.mem.indexOf(u8, e, "LIMIT") == null);
}

test "writeChunksByIds builds an escaped IN list" {
    var buf: [1024]u8 = undefined;
    const ids = [_][]const u8{ "d1#0", "d1#1", "O'Brien" };
    const out = try renderSql(&buf, writeChunksByIds, .{@as([]const []const u8, &ids)});
    try testing.expectEqualStrings(
        "SELECT id, document_id, ordinal, content FROM `rag_chunk` WHERE id IN ('d1#0','d1#1','O''Brien')",
        out,
    );
}

test "writeLexicalTopK builds escaped LIKE, uses LENGTH" {
    var buf: [1024]u8 = undefined;
    const out = try renderSql(&buf, writeLexicalTopK, .{ "neural", @as(u64, 8), @as(?[]const []const u8, null) });
    try testing.expect(std.mem.indexOf(u8, out, "WHERE content LIKE '%neural%'") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ORDER BY LENGTH(content) LIMIT 8") != null);
    try testing.expect(std.mem.indexOf(u8, out, "||") == null);
    try testing.expect(std.mem.indexOf(u8, out, "document_id IN") == null); // no filter
}

test "writeLexicalTopK escapes quotes in query" {
    var buf: [1024]u8 = undefined;
    const out = try renderSql(&buf, writeLexicalTopK, .{ "O'Brien", @as(u64, 3), @as(?[]const []const u8, null) });
    try testing.expect(std.mem.indexOf(u8, out, "LIKE '%O''Brien%'") != null);
}

test "writeLexicalTopK scopes to documents when filtered" {
    var buf: [1024]u8 = undefined;
    const ids = [_][]const u8{ "d1", "d2" };
    const out = try renderSql(&buf, writeLexicalTopK, .{ "neural", @as(u64, 5), @as(?[]const []const u8, &ids) });
    try testing.expect(std.mem.indexOf(u8, out, "WHERE content LIKE '%neural%' AND document_id IN ('d1','d2')") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ORDER BY LENGTH(content) LIMIT 5") != null);
}

test "writeVectorScanByDocuments restricts to the document set" {
    var buf: [1024]u8 = undefined;
    const ids = [_][]const u8{ "d1", "O'Hara" };
    const out = try renderSql(&buf, writeVectorScanByDocuments, .{@as([]const []const u8, &ids)});
    try testing.expectEqualStrings(
        "SELECT id, embedding FROM `rag_chunk` WHERE document_id IN ('d1','O''Hara')",
        out,
    );
}

test "writeRagStatistics single round-trip" {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "SELECT (SELECT COUNT(*) FROM `rag_document`), (SELECT COUNT(*) FROM `rag_chunk`)",
        try renderSql(&buf, writeRagStatistics, .{}),
    );
}

test "Metric.parse" {
    try testing.expectEqual(Metric.euclidean, Metric.parse(null));
    try testing.expectEqual(Metric.euclidean, Metric.parse("euclidean"));
    try testing.expectEqual(Metric.cosine, Metric.parse("cosine"));
    try testing.expectEqual(Metric.cosine, Metric.parse("COSINE"));
    try testing.expectEqual(Metric.euclidean, Metric.parse("nonsense"));
}

test "writeDeleteChunksByDocument / writeChunksByDocument" {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "DELETE FROM `rag_chunk` WHERE document_id = 'd1'",
        try renderSql(&buf, writeDeleteChunksByDocument, .{"d1"}),
    );
    var buf2: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "SELECT id, document_id, ordinal, content FROM `rag_chunk` WHERE document_id = 'd1' ORDER BY ordinal",
        try renderSql(&buf2, writeChunksByDocument, .{"d1"}),
    );
}
