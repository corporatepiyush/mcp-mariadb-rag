//! Tests for src/rag/schema.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/rag/schema.zig");

const allTableNames = srcmod.allTableNames;
const chunk_table = srcmod.chunk_table;
const ddl = srcmod.ddl;
const document_table = srcmod.document_table;
const embeddingDims = srcmod.embeddingDims;
const embedding_dims = srcmod.embedding_dims;
const setEmbeddingDims = srcmod.setEmbeddingDims;

test "ddl: STRICT tables, content_hash, and the chunk index are present" {
    try testing.expect(std.mem.indexOf(u8, ddl, "CREATE TABLE IF NOT EXISTS `rag_document`") != null);
    try testing.expect(std.mem.indexOf(u8, ddl, "CREATE TABLE IF NOT EXISTS `rag_chunk`") != null);
    try testing.expect(std.mem.indexOf(u8, ddl, "embedding BLOB NOT NULL") != null);
    try testing.expect(std.mem.indexOf(u8, ddl, "content_hash TEXT NOT NULL DEFAULT ''") != null);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, ddl, ") STRICT"));
    try testing.expect(std.mem.indexOf(u8, ddl, "idx_chunk_doc") != null);
    try testing.expect(std.mem.indexOf(u8, ddl, "AUTO_INCREMENT") == null);
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
