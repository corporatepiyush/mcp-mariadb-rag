const std = @import("std");

pub const entity_table = "rag_entity";
pub const observation_table = "rag_observation";
pub const relation_table = "rag_relation";
pub const type_dict_table = "rag_type_dict";
pub const graph_stat_table = "rag_graph_stat";
pub const vector_embedding_table = "rag_vector_embedding";

pub fn allTableNames() []const []const u8 {
    return &.{
        entity_table,
        observation_table,
        relation_table,
        type_dict_table,
        graph_stat_table,
        vector_embedding_table,
    };
}

/// The canonical knowledge-graph schema. Single source of truth in `schema.sql`
/// (embedded); applied via `pool.executeScript` / `sqlite.execScript`.
pub const ddl = @embedFile("schema.sql");

const testing = std.testing;

test "ddl: six STRICT tables, UNIQUE relation, TEXT-id vector, access indexes" {
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, ddl, "CREATE TABLE IF NOT EXISTS"));
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, ddl, ") STRICT"));
    try testing.expect(std.mem.indexOf(u8, ddl, "INTEGER PRIMARY KEY AUTOINCREMENT") != null);
    try testing.expect(std.mem.indexOf(u8, ddl, "UNIQUE(from_entity, relation_type, to_entity)") != null);
    try testing.expect(std.mem.indexOf(u8, ddl, "id TEXT NOT NULL PRIMARY KEY") != null); // vector table
    try testing.expect(std.mem.indexOf(u8, ddl, "AUTO_INCREMENT") == null);
    // Access-path indexes (the optimization).
    inline for (.{ "idx_observation_entity", "idx_relation_from", "idx_relation_to", "idx_vector_entity" }) |idx|
        try testing.expect(std.mem.indexOf(u8, ddl, idx) != null);
}

test "allTableNames returns six names" {
    const names = allTableNames();
    try testing.expectEqual(@as(usize, 6), names.len);
    try testing.expectEqualStrings(entity_table, names[0]);
    try testing.expectEqualStrings(observation_table, names[1]);
    try testing.expectEqualStrings(relation_table, names[2]);
    try testing.expectEqualStrings(type_dict_table, names[3]);
    try testing.expectEqualStrings(graph_stat_table, names[4]);
    try testing.expectEqualStrings(vector_embedding_table, names[5]);
}
