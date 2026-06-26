const std = @import("std");

const Writer = std.Io.Writer;

pub const document_table = "rag_document";
pub const chunk_table = "rag_chunk";

/// Compile-time default embedding dimensionality. The *active* dimensionality is
/// a runtime value (`embeddingDims`) so the same binary can serve a corpus built
/// with a stronger, higher-dimensional embedder (Voyage 1024/1536, OpenAI
/// text-embedding-3-large 3072, …) without a recompile — set once at startup
/// from `MCP_EMBED_DIMS`. The `embedding` column is an untyped BLOB, so the only
/// invariant is that every vector in one corpus shares this width.
pub const embedding_dims = 384;

var runtime_embedding_dims: usize = embedding_dims;

/// The active embedding dimensionality every ingest/query embedding must match.
pub fn embeddingDims() usize {
    return @atomicLoad(usize, &runtime_embedding_dims, .acquire);
}

/// Set the active dimensionality. Called once at startup (`main`) from config;
/// `d == 0` is ignored so a misconfigured env var can't disable validation.
pub fn setEmbeddingDims(d: usize) void {
    if (d == 0) return;
    @atomicStore(usize, &runtime_embedding_dims, d, .release);
}

pub fn allTableNames() []const []const u8 {
    return &.{ document_table, chunk_table };
}

// Tables are STRICT (SQLite ≥ 3.37): the declared column type is enforced, so a
// malformed `embedding` (e.g. a TEXT where a BLOB belongs) is rejected at insert
// instead of silently corrupting the vector scan. `CREATE TABLE IF NOT EXISTS`
// leaves any pre-existing non-STRICT table untouched — new databases get STRICT,
// old ones keep working without a migration.

pub fn writeCreateDocument(w: *Writer) !void {
    try w.writeAll(
        \\CREATE TABLE IF NOT EXISTS `rag_document` (
        \\    id TEXT NOT NULL PRIMARY KEY,
        \\    uri TEXT NOT NULL DEFAULT '',
        \\    title TEXT NOT NULL DEFAULT '',
        \\    metadata TEXT NOT NULL,
        \\    chunk_count INTEGER NOT NULL DEFAULT 0,
        \\    created_at TEXT DEFAULT (datetime('now')),
        \\    updated_at TEXT DEFAULT (datetime('now'))
        \\) STRICT
    );
}

pub fn writeCreateChunk(w: *Writer) !void {
    try w.writeAll(
        \\CREATE TABLE IF NOT EXISTS `rag_chunk` (
        \\    id TEXT NOT NULL PRIMARY KEY,
        \\    document_id TEXT NOT NULL,
        \\    ordinal INTEGER NOT NULL DEFAULT 0,
        \\    content TEXT NOT NULL,
        \\    token_count INTEGER NOT NULL DEFAULT 0,
        \\    embedding BLOB NOT NULL,
        \\    created_at TEXT DEFAULT (datetime('now'))
        \\) STRICT
    );
}

/// Covering index for the per-document access paths (`writeChunksByDocument`,
/// `writeDeleteChunksByDocument`). Without it those `WHERE document_id = ? ORDER
/// BY ordinal` queries are full table scans. The `(document_id, ordinal)` key
/// order also satisfies the ORDER BY for free.
pub fn writeCreateChunkIndex(w: *Writer) !void {
    try w.writeAll("CREATE INDEX IF NOT EXISTS `idx_chunk_doc` ON `rag_chunk` (document_id, ordinal)");
}

pub fn writeAll(w: *Writer) !void {
    try writeCreateDocument(w);
    try w.writeAll(";\n\n");
    try writeCreateChunk(w);
    try w.writeAll(";\n\n");
    try writeCreateChunkIndex(w);
    try w.writeByte(';');
}

const testing = std.testing;

test "writeCreateDocument" {
    var buf: [1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeCreateDocument(&w);
    const result = w.buffered();
    try testing.expect(std.mem.indexOf(u8, result, "CREATE TABLE IF NOT EXISTS `rag_document`") != null);
    try testing.expect(std.mem.indexOf(u8, result, "id TEXT NOT NULL PRIMARY KEY") != null);
    try testing.expect(std.mem.indexOf(u8, result, "chunk_count INTEGER NOT NULL DEFAULT 0") != null);
    try testing.expect(std.mem.indexOf(u8, result, "AUTO_INCREMENT") == null);
}

test "writeCreateChunk stores embedding as BLOB" {
    var buf: [1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeCreateChunk(&w);
    const result = w.buffered();
    try testing.expect(std.mem.indexOf(u8, result, "CREATE TABLE IF NOT EXISTS `rag_chunk`") != null);
    try testing.expect(std.mem.indexOf(u8, result, "id TEXT NOT NULL PRIMARY KEY") != null);
    try testing.expect(std.mem.indexOf(u8, result, "embedding BLOB NOT NULL") != null);
    try testing.expect(std.mem.indexOf(u8, result, "AUTO_INCREMENT") == null);
}

test "writeCreate* tables are STRICT" {
    var buf: [1024]u8 = undefined;
    {
        var w = Writer.fixed(&buf);
        try writeCreateDocument(&w);
        try testing.expect(std.mem.endsWith(u8, w.buffered(), ") STRICT"));
    }
    {
        var w = Writer.fixed(&buf);
        try writeCreateChunk(&w);
        try testing.expect(std.mem.endsWith(u8, w.buffered(), ") STRICT"));
    }
}

test "writeCreateChunkIndex keys (document_id, ordinal)" {
    var buf: [256]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeCreateChunkIndex(&w);
    try testing.expectEqualStrings(
        "CREATE INDEX IF NOT EXISTS `idx_chunk_doc` ON `rag_chunk` (document_id, ordinal)",
        w.buffered(),
    );
}

test "writeAll emits both tables plus the chunk index" {
    var buf: [4096]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeAll(&w);
    const result = w.buffered();
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, result, "CREATE TABLE IF NOT EXISTS"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, result, "CREATE INDEX IF NOT EXISTS"));
}

test "allTableNames returns two names" {
    const names = allTableNames();
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings(document_table, names[0]);
    try testing.expectEqualStrings(chunk_table, names[1]);
}

test "embeddingDims defaults to the compile-time value; setter round-trips; 0 ignored" {
    const saved = embeddingDims();
    defer setEmbeddingDims(saved);

    try testing.expectEqual(@as(usize, embedding_dims), saved); // default == 384
    setEmbeddingDims(1536);
    try testing.expectEqual(@as(usize, 1536), embeddingDims());
    setEmbeddingDims(0); // a misconfigured env var must not disable validation
    try testing.expectEqual(@as(usize, 1536), embeddingDims());
}
