//! Tests for src/rag/query.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/rag/query.zig");
const Writer = std.Io.Writer;

const ChunkRow = srcmod.ChunkRow;
const Metric = srcmod.Metric;
const writeChunksByDocument = srcmod.writeChunksByDocument;
const writeChunksByIds = srcmod.writeChunksByIds;
const writeDeleteChunksByDocument = srcmod.writeDeleteChunksByDocument;
const writeGetDocument = srcmod.writeGetDocument;
const writeGetDocumentHash = srcmod.writeGetDocumentHash;
const writeLexicalTopK = srcmod.writeLexicalTopK;
const writeListDocuments = srcmod.writeListDocuments;
const writeRagStatistics = srcmod.writeRagStatistics;
const writeUpsertChunks = srcmod.writeUpsertChunks;
const writeUpsertDocument = srcmod.writeUpsertDocument;
const writeVectorScanAll = srcmod.writeVectorScanAll;
const writeVectorScanByDocuments = srcmod.writeVectorScanByDocuments;

test "writeUpsertDocument" {
    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings(
        "INSERT INTO `rag_document` (id, uri, title, metadata, chunk_count, content_hash) VALUES ('d1','file://x','Title','{}',3,'abc123') ON CONFLICT(id) DO UPDATE SET uri=excluded.uri, title=excluded.title, metadata=excluded.metadata, chunk_count=excluded.chunk_count, content_hash=excluded.content_hash",
        try renderSql(&buf, writeUpsertDocument, .{ "d1", "file://x", "Title", "{}", @as(u64, 3), "abc123" }),
    );
}

test "writeUpsertDocument escapes quotes" {
    var buf: [1024]u8 = undefined;
    const out = try renderSql(&buf, writeUpsertDocument, .{ "d'1", "u", "O'Hara", "{}", @as(u64, 0), "h" });
    try testing.expect(std.mem.indexOf(u8, out, "'d''1'") != null);
    try testing.expect(std.mem.indexOf(u8, out, "'O''Hara'") != null);
}

test "writeGetDocumentHash" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "SELECT content_hash FROM `rag_document` WHERE id = 'd1'",
        try renderSql(&buf, writeGetDocumentHash, .{"d1"}),
    );
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

// ---- helpers moved from src ----
pub fn renderSql(buf: []u8, comptime f: anytype, args: anytype) ![]u8 {
    var w = Writer.fixed(buf);
    try @call(.auto, f, .{&w} ++ args);
    return w.buffered();
}
