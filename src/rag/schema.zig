//! DDL generation for the RAG (retrieval-augmented generation) tables.
//!
//! Two tables sit on top of the knowledge-graph layer:
//!   * `rag_document` — one row per ingested source document (id, uri, title,
//!     JSON metadata, chunk count).
//!   * `rag_chunk` — the retrievable units: a slice of a document's text plus a
//!     384-dim embedding. Lexical search runs over `content`; semantic search
//!     runs over `embedding` via MariaDB's native VECTOR index.
//!
//! Key-column widths are 63 (= 252 bytes under utf8mb4) to stay within
//! TidesDB's 255-byte max key length — the same constraint that governs the KG
//! tables. Embeddings are NOT NULL: a chunk without an embedding cannot
//! participate in semantic retrieval, and every ingest path supplies one.

const std = @import("std");
const validation = @import("../validation.zig");

const Writer = std.Io.Writer;

// ── Table name constants ──────────────────────────────────────────────

pub const document_table = "rag_document";
pub const chunk_table = "rag_chunk";

/// Embedding dimensionality, shared with the KG vector table and `VECTOR(384)`.
pub const embedding_dims = 384;

/// Returns all RAG table names for iteration during schema init / teardown.
pub fn allTableNames() []const []const u8 {
    return &.{ document_table, chunk_table };
}

fn writeIdent(w: *Writer, name: []const u8) !void {
    try validation.writeQuotedIdent(w, name);
}

// ── DDL generation ────────────────────────────────────────────────────

pub fn writeCreateDocument(w: *Writer) !void {
    try w.writeAll("CREATE TABLE IF NOT EXISTS ");
    try writeIdent(w, document_table);
    try w.writeAll(
        " (\n" ++
            "    id VARCHAR(63) NOT NULL PRIMARY KEY,\n" ++
            "    uri VARCHAR(255) NOT NULL DEFAULT '',\n" ++
            "    title VARCHAR(255) NOT NULL DEFAULT '',\n" ++
            "    metadata TEXT NOT NULL,\n" ++
            "    chunk_count INT NOT NULL DEFAULT 0,\n" ++
            "    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,\n" ++
            "    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP\n" ++
            ") ENGINE=TidesDB WRITE_BUFFER_SIZE=268435456",
    );
}

pub fn writeCreateChunk(w: *Writer) !void {
    try w.writeAll("CREATE TABLE IF NOT EXISTS ");
    try writeIdent(w, chunk_table);
    // `idx_document` serves chunk-by-document scans and cascade deletes;
    // the VECTOR index powers semantic top-k. `ordinal` preserves source order.
    try w.writeAll(
        " (\n" ++
            "    id VARCHAR(63) NOT NULL PRIMARY KEY,\n" ++
            "    document_id VARCHAR(63) NOT NULL,\n" ++
            "    ordinal INT NOT NULL DEFAULT 0,\n" ++
            "    content TEXT NOT NULL,\n" ++
            "    token_count INT NOT NULL DEFAULT 0,\n" ++
            "    embedding VECTOR(384) NOT NULL,\n" ++
            "    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,\n" ++
            "    INDEX idx_document (document_id),\n" ++
            "    VECTOR INDEX idx_chunk_embedding (embedding)\n" ++
            ") ENGINE=TidesDB WRITE_BUFFER_SIZE=268435456",
    );
}

/// Write both CREATE TABLE statements separated by `;\n\n` (for display/review).
pub fn writeAll(w: *Writer) !void {
    try writeCreateDocument(w);
    try w.writeAll(";\n\n");
    try writeCreateChunk(w);
    try w.writeByte(';');
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

test "writeCreateDocument" {
    var buf: [1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeCreateDocument(&w);
    const result = w.buffered();
    try testing.expect(std.mem.indexOf(u8, result, "CREATE TABLE IF NOT EXISTS `rag_document`") != null);
    try testing.expect(std.mem.indexOf(u8, result, "id VARCHAR(63) NOT NULL PRIMARY KEY") != null);
    try testing.expect(std.mem.indexOf(u8, result, "chunk_count INT NOT NULL DEFAULT 0") != null);
    try testing.expect(std.mem.indexOf(u8, result, "ENGINE=TidesDB") != null);
}

test "writeCreateChunk has vector + document indexes and 63-byte key" {
    var buf: [1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeCreateChunk(&w);
    const result = w.buffered();
    try testing.expect(std.mem.indexOf(u8, result, "CREATE TABLE IF NOT EXISTS `rag_chunk`") != null);
    try testing.expect(std.mem.indexOf(u8, result, "id VARCHAR(63) NOT NULL PRIMARY KEY") != null);
    try testing.expect(std.mem.indexOf(u8, result, "embedding VECTOR(384) NOT NULL") != null);
    try testing.expect(std.mem.indexOf(u8, result, "INDEX idx_document (document_id)") != null);
    try testing.expect(std.mem.indexOf(u8, result, "VECTOR INDEX idx_chunk_embedding (embedding)") != null);
    // No AUTO_INCREMENT — id is a caller-supplied string key.
    try testing.expect(std.mem.indexOf(u8, result, "AUTO_INCREMENT") == null);
}

test "writeAll concatenates both statements" {
    var buf: [4096]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeAll(&w);
    const result = w.buffered();
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, result, "CREATE TABLE IF NOT EXISTS"));
}

test "allTableNames returns two names" {
    const names = allTableNames();
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings(document_table, names[0]);
    try testing.expectEqualStrings(chunk_table, names[1]);
}
