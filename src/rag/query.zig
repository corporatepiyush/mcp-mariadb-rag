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
    try w.writeAll("'[");
    for (vector, 0..) |v, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{d}", .{v});
    }
    try w.writeAll("]'");
}

// ── Distance metric ───────────────────────────────────────────────────

pub const Metric = enum {
    euclidean,
    cosine,

    fn sqlFunc(self: Metric) []const u8 {
        return switch (self) {
            .euclidean => "VEC_DISTANCE_EUCLIDEAN",
            .cosine => "VEC_DISTANCE_COSINE",
        };
    }

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
    try w.writeAll("REPLACE INTO ");
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
    try w.writeAll("REPLACE INTO ");
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
        try w.print(",{d},Vec_FromText(", .{r.token_count});
        try writeVectorLiteral(w, r.vector);
        try w.writeAll("))");
    }
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

/// Semantic top-k by vector distance. Returns the embedding as text so the
/// caller can re-rank (MMR) without a second round-trip.
/// `SELECT id, document_id, ordinal, content, VEC_ToText(embedding) AS emb,
///   <metric>(embedding, Vec_FromText('[..]')) AS distance FROM rag_chunk
///   ORDER BY distance LIMIT k`
pub fn writeVectorTopK(w: *Writer, query_vector: []const f32, k: u64, metric: Metric) !void {
    try w.writeAll("SELECT id, document_id, ordinal, content, VEC_ToText(embedding) AS emb, ");
    try w.writeAll(metric.sqlFunc());
    try w.writeAll("(embedding, Vec_FromText(");
    try writeVectorLiteral(w, query_vector);
    try w.writeAll(")) AS distance FROM ");
    try validation.writeQuotedIdent(w, schema.chunk_table);
    try w.print(" ORDER BY distance LIMIT {d}", .{k});
}

/// Lexical top-k by substring match. Ordered by content length ascending as a
/// simple match-density proxy (shorter chunks containing the term score higher);
/// RRF only needs a stable rank, the semantic side carries the fine ordering.
/// Embedding text is returned so fused candidates can feed MMR.
pub fn writeLexicalTopK(w: *Writer, query: []const u8, k: u64) !void {
    try w.writeAll("SELECT id, document_id, ordinal, content, VEC_ToText(embedding) AS emb FROM ");
    try validation.writeQuotedIdent(w, schema.chunk_table);
    try w.writeAll(" WHERE content ");
    try writeLikeContains(w, query);
    try w.print(" ORDER BY CHAR_LENGTH(content) LIMIT {d}", .{k});
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
        "REPLACE INTO `rag_document` (id, uri, title, metadata, chunk_count) VALUES ('d1','file://x','Title','{}',3)",
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

test "writeUpsertChunks batches rows with Vec_FromText" {
    var buf: [2048]u8 = undefined;
    const v0 = [_]f32{ 0.1, 0.2 };
    const v1 = [_]f32{ 0.3, 0.4 };
    const rows = [_]ChunkRow{
        .{ .id = "d1#0", .document_id = "d1", .ordinal = 0, .content = "hello", .token_count = 1, .vector = &v0 },
        .{ .id = "d1#1", .document_id = "d1", .ordinal = 1, .content = "world", .token_count = 1, .vector = &v1 },
    };
    const out = try renderSql(&buf, writeUpsertChunks, .{&rows});
    try testing.expect(std.mem.indexOf(u8, out, "REPLACE INTO `rag_chunk` (id, document_id, ordinal, content, token_count, embedding) VALUES ") != null);
    try testing.expect(std.mem.indexOf(u8, out, "('d1#0','d1',0,'hello',1,Vec_FromText('[0.1,0.2]'))") != null);
    try testing.expect(std.mem.indexOf(u8, out, ", ('d1#1','d1',1,'world',1,Vec_FromText('[0.3,0.4]'))") != null);
}

test "writeVectorTopK euclidean vs cosine" {
    var buf: [2048]u8 = undefined;
    const v = [_]f32{ 1, 2, 3 };
    const e = try renderSql(&buf, writeVectorTopK, .{ &v, @as(u64, 5), Metric.euclidean });
    try testing.expect(std.mem.indexOf(u8, e, "VEC_DISTANCE_EUCLIDEAN(embedding, Vec_FromText('[1,2,3]'))") != null);
    try testing.expect(std.mem.indexOf(u8, e, "VEC_ToText(embedding) AS emb") != null);
    try testing.expect(std.mem.indexOf(u8, e, "ORDER BY distance LIMIT 5") != null);

    var buf2: [2048]u8 = undefined;
    const c = try renderSql(&buf2, writeVectorTopK, .{ &v, @as(u64, 5), Metric.cosine });
    try testing.expect(std.mem.indexOf(u8, c, "VEC_DISTANCE_COSINE") != null);
}

test "writeLexicalTopK builds escaped LIKE, never `||`" {
    var buf: [1024]u8 = undefined;
    const out = try renderSql(&buf, writeLexicalTopK, .{ "neural", @as(u64, 8) });
    try testing.expect(std.mem.indexOf(u8, out, "WHERE content LIKE '%neural%'") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ORDER BY CHAR_LENGTH(content) LIMIT 8") != null);
    try testing.expect(std.mem.indexOf(u8, out, "||") == null);
}

test "writeLexicalTopK escapes quotes in query" {
    var buf: [1024]u8 = undefined;
    const out = try renderSql(&buf, writeLexicalTopK, .{ "O'Brien", @as(u64, 3) });
    try testing.expect(std.mem.indexOf(u8, out, "LIKE '%O''Brien%'") != null);
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
