const std = @import("std");
const pool = @import("../pool.zig");
const json = @import("../json.zig");
const schema = @import("schema.zig");
const query = @import("query.zig");
const stubs = @import("stubs.zig");
const kg = @import("kg.zig");

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
    .{ "list_tables", schema.listTables },
    .{ "describe_table", schema.describeTable },
    .{ "list_indexes", schema.listIndexes },
    .{ "list_schemas", schema.listSchemas },
    .{ "show_constraints", schema.showConstraints },
    .{ "list_triggers", schema.listTriggers },
    .{ "create_table", schema.createTable },
    .{ "drop_table", schema.dropTable },
    .{ "create_view", schema.createView },
    .{ "drop_view", schema.dropView },
    .{ "create_schema", schema.createSchema },
    .{ "drop_schema", schema.dropSchema },
    .{ "create_index", schema.createIndex },
    .{ "drop_index", schema.dropIndex },
    .{ "execute_query", query.executeQuery },
    .{ "execute_insert", query.executeInsert },
    .{ "execute_update", query.executeUpdate },
    .{ "execute_delete", query.executeDelete },
    .{ "explain_query", query.explainQuery },
    .{ "show_table_status", stubs.notImpl },
    .{ "show_processlist", stubs.notImpl },
    .{ "show_variables", stubs.notImpl },
    .{ "show_status", stubs.notImpl },
    .{ "show_databases", stubs.notImpl },
    .{ "show_engines", stubs.notImpl },
    .{ "list_users", stubs.notImpl },
    .{ "show_grants", stubs.notImpl },
    .{ "optimize_table", stubs.notImpl },
    .{ "analyze_table", stubs.notImpl },
    .{ "check_table", stubs.notImpl },
    .{ "flush_tables", stubs.notImpl },
    .{ "truncate_table", stubs.notImpl },
    .{ "add_column", stubs.notImpl },
    .{ "drop_column", stubs.notImpl },
    .{ "rename_column", stubs.notImpl },
    .{ "alter_column_type", stubs.notImpl },
    .{ "rename_table", stubs.notImpl },
    .{ "create_user", stubs.notImpl },
    .{ "drop_user", stubs.notImpl },
    .{ "grant_privileges", stubs.notImpl },
    .{ "revoke_privileges", stubs.notImpl },
    .{ "show_locks", stubs.notImpl },
    .{ "show_transaction_isolation", stubs.notImpl },
    .{ "vector_search", kg.vectorSearch },
    .{ "bfs_path", kg.bfsPath },
    .{ "fulltext_search", kg.fulltextSearch },
    .{ "list_fulltext_indexes", stubs.notImpl },
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
});

const write_names = std.StaticStringMap(void).initComptime(.{
    .{"create_table"}, .{"drop_table"},  .{"create_view"},      .{"drop_view"},
    .{"create_schema"}, .{"drop_schema"}, .{"create_index"},     .{"drop_index"},
    .{"execute_insert"}, .{"execute_update"}, .{"execute_delete"},
    .{"optimize_table"}, .{"analyze_table"}, .{"check_table"},   .{"flush_tables"},
    .{"truncate_table"}, .{"add_column"},  .{"drop_column"},      .{"rename_column"},
    .{"alter_column_type"}, .{"rename_table"}, .{"create_user"},  .{"drop_user"},
    .{"grant_privileges"}, .{"revoke_privileges"},
    .{"create_entities"}, .{"create_relations"}, .{"delete_entities"},
    .{"delete_relations"}, .{"add_observations"}, .{"delete_observations"},
    .{"upsert_vector_embedding"}, .{"delete_vector_embedding"},
});

pub fn isWriteTool(name: []const u8) bool {
    return write_names.has(name);
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
