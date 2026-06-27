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
