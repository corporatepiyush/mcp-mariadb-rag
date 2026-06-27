const std = @import("std");
pub const pool = @import("../pool.zig");
const json = @import("../json.zig");
pub const kg = @import("kg.zig");
pub const rag = @import("rag.zig");
pub const doc = @import("doc.zig");

const Value = std.json.Value;
const Writer = std.Io.Writer;

/// Result of a tool handler: a text payload plus an error flag. `text` is
/// allocated in the request allocator.
pub const Payload = struct {
    text: []const u8,
    is_error: bool,
};

/// Tool handler. `io` and `allocator` lead (project convention); `io` is the
/// extensibility surface for handlers that perform their own I/O (e.g. calling
/// an embedding service) and is unused by the current SQL-only handlers.
const Handler = *const fn (std.Io, std.mem.Allocator, *pool.PooledConnection, ?Value) Payload;

pub const registry = std.StaticStringMap(Handler).initComptime(.{
    // ---- Knowledge graph ----
    .{ "vector_search", kg.vectorSearch },
    .{ "bfs_path", kg.bfsPath },
    .{ "fulltext_search", kg.fulltextSearch },
    .{ "create_entities", kg.createEntities },
    .{ "create_relations", kg.createRelations },
    .{ "delete_entities", kg.deleteEntities },
    .{ "delete_relations", kg.deleteRelation },
    .{ "add_observations", kg.addObservations },
    .{ "delete_observations", kg.deleteObservations },
    .{ "read_graph", kg.readGraph },
    .{ "search_nodes", kg.searchNodes },
    .{ "open_nodes", kg.openNodes },
    .{ "get_entity_stats", kg.getEntityStats },
    .{ "get_relation_stats", kg.getRelationStats },
    .{ "search_relations", kg.searchRelations },
    .{ "get_neighbors", kg.getNeighbors },
    .{ "get_entity_degree", kg.getEntityDegree },
    .{ "get_graph_statistics", kg.getGraphStatistics },
    .{ "upsert_vector_embedding", kg.upsertVectorEmbedding },
    .{ "delete_vector_embedding", kg.deleteVectorEmbedding },
    // ---- RAG engine: ingest, hybrid retrieval, document store ----
    .{ "rag_chunk_text", rag.chunkText },
    .{ "rag_parent_child_chunk", rag.parentChildText },
    .{ "rag_ingest_document", rag.ingestDocument },
    .{ "rag_upsert_chunks", rag.upsertChunks },
    .{ "rag_search", rag.search },
    .{ "rag_vector_search", rag.vectorSearch },
    .{ "rag_get_document", rag.getDocument },
    .{ "rag_list_documents", rag.listDocuments },
    .{ "rag_delete_document", rag.deleteDocument },
    .{ "rag_stats", rag.stats },
    // ---- Document extraction: detect / extract / chunk (native, streaming) ----
    .{ "doc_detect_format", doc.detectFormat },
    .{ "doc_extract_text", doc.extractText },
    .{ "doc_extract_and_chunk", doc.extractAndChunk },
});

// Tools that mutate persistent state. Document-extraction tools are read-only
// (they read files and return text), so none appear here.
const write_names = std.StaticStringMap(void).initComptime(.{
    .{"create_entities"}, .{"create_relations"}, .{"delete_entities"},
    .{"delete_relations"}, .{"add_observations"}, .{"delete_observations"},
    .{"upsert_vector_embedding"}, .{"delete_vector_embedding"},
    .{"rag_ingest_document"}, .{"rag_upsert_chunks"}, .{"rag_delete_document"},
});

pub fn isWriteTool(name: []const u8) bool {
    return write_names.has(name);
}

/// Which database file a tool operates on. RAG document/chunk tools and the
/// (DB-free) document-extraction tools use the `rag` file; the knowledge-graph
/// tools use the `kg` file. The split lets KG and RAG writes proceed without
/// contending for a single database's write lock.
pub fn componentFor(name: []const u8) pool.Component {
    if (std.mem.startsWith(u8, name, "rag_") or std.mem.startsWith(u8, name, "doc_")) return .rag;
    return .kg;
}

// ---- shared helpers for handlers ----------------------------------------

pub fn errPayload(msg: []const u8) Payload {
    return .{ .text = msg, .is_error = true };
}

/// Serialize a query result into a success payload, mapping serialization
/// failure (OOM) to an error payload.
pub fn resultPayload(allocator: std.mem.Allocator, result: pool.QueryResult) Payload {
    const text = renderToOwned(allocator, json.writeQueryResult, .{result}) catch
        return errPayload("Serialization error");
    return .{ .text = text, .is_error = false };
}

/// Run a `json.write*` function against a fresh allocating writer and return the
/// owned bytes.
pub fn renderToOwned(
    allocator: std.mem.Allocator,
    comptime write_fn: anytype,
    args: anytype,
) ![]u8 {
    var aw = Writer.Allocating.init(allocator);
    errdefer aw.deinit();
    try @call(.auto, write_fn, .{&aw.writer} ++ args);
    return aw.toOwnedSlice();
}

/// Like `renderToOwned` but yields a success `Payload`, mapping any write/OOM
/// failure to a uniform serialization error. The common shape for handlers that
/// build a JSON response into a `*Writer`.
pub fn renderOwned(
    allocator: std.mem.Allocator,
    comptime write_fn: anytype,
    args: anytype,
) Payload {
    const text = renderToOwned(allocator, write_fn, args) catch
        return errPayload("Serialization error");
    return .{ .text = text, .is_error = false };
}

pub fn getStringParam(args: ?Value, name: []const u8) ?[]const u8 {
    const a = args orelse return null;
    if (a != .object) return null;
    const v = a.object.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

pub fn getBoolParam(args: ?Value, name: []const u8, default: bool) bool {
    const a = args orelse return default;
    if (a != .object) return default;
    const v = a.object.get(name) orelse return default;
    return if (v == .bool) v.bool else default;
}

pub fn getArrayParam(args: ?Value, name: []const u8) ?std.json.Array {
    const a = args orelse return null;
    if (a != .object) return null;
    const v = a.object.get(name) orelse return null;
    return if (v == .array) v.array else null;
}
