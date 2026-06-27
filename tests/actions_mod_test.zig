//! Tests for src/actions/mod.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/actions/mod.zig");

const componentFor = srcmod.componentFor;
const doc = srcmod.doc;
const kg = srcmod.kg;
const pool = srcmod.pool;
const rag = srcmod.rag;
const registry = srcmod.registry;

// ── Tests ─────────────────────────────────────────────────────────────


test "componentFor routes RAG/doc tools to rag, KG tools to kg" {
    // Every registered RAG/doc tool must route to the rag database.
    inline for (.{
        "rag_search", "rag_vector_search", "rag_ingest_document", "rag_chunk_text",
        "rag_parent_child_chunk", "rag_stats", "rag_get_document", "rag_delete_document",
        "doc_detect_format", "doc_extract_text", "doc_extract_and_chunk",
    }) |name| try testing.expectEqual(pool.Component.rag, componentFor(name));

    // Knowledge-graph tools route to the kg database.
    inline for (.{
        "vector_search", "bfs_path", "create_entities", "create_relations",
        "search_nodes", "get_graph_statistics", "upsert_vector_embedding",
    }) |name| try testing.expectEqual(pool.Component.kg, componentFor(name));

    // Every tool in the registry classifies without panicking.
    for (registry.keys()) |name| _ = componentFor(name);
}

test "componentFor: edge cases default to kg" {
    try testing.expectEqual(pool.Component.kg, componentFor(""));
    try testing.expectEqual(pool.Component.kg, componentFor("unknown_tool"));
    try testing.expectEqual(pool.Component.kg, componentFor("rag")); // no underscore
    try testing.expectEqual(pool.Component.rag, componentFor("rag_")); // prefix match
}
