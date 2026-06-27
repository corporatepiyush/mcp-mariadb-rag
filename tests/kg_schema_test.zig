//! Tests for src/kg/schema.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/kg/schema.zig");

const allTableNames = srcmod.allTableNames;
const ddl = srcmod.ddl;
const entity_table = srcmod.entity_table;
const graph_stat_table = srcmod.graph_stat_table;
const observation_table = srcmod.observation_table;
const relation_table = srcmod.relation_table;
const type_dict_table = srcmod.type_dict_table;
const vector_embedding_table = srcmod.vector_embedding_table;

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
