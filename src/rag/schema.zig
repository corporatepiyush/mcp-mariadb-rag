const std = @import("std");

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

/// The canonical RAG schema. Single source of truth in `schema.sql` (embedded);
/// `pool.executeScript` / `sqlite.execScript` apply it statement-by-statement.
pub const ddl = @embedFile("schema.sql");
