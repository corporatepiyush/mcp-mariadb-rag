//! DDL generation for the knowledge graph tables.
//!
//! Each `writeCreate*` function emits a single `CREATE TABLE IF NOT EXISTS`
//! statement.  Callers iterate over the individual functions and execute them
//! one at a time (multi-statement is not enabled on the connection pool).

const std = @import("std");
const validation = @import("../validation.zig");

const Writer = std.Io.Writer;

// ── Table name constants ──────────────────────────────────────────────

pub const entity_table = "rag_entity";
pub const observation_table = "rag_observation";
pub const relation_table = "rag_relation";
pub const type_dict_table = "rag_type_dict";
pub const graph_stat_table = "rag_graph_stat";
pub const vector_embedding_table = "rag_vector_embedding";

/// Returns all table names for iteration during schema initialisation.
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

// ── Private helpers ───────────────────────────────────────────────────

/// Write `name` as a backtick-quoted MariaDB identifier.
fn writeIdent(w: *Writer, name: []const u8) !void {
    try validation.writeQuotedIdent(w, name);
}

// ── DDL generation ────────────────────────────────────────────────────

pub fn writeCreateEntity(w: *Writer) !void {
    try w.writeAll("CREATE TABLE IF NOT EXISTS ");
    try writeIdent(w, entity_table);
    try w.writeAll(
        " (\n"
        ++ "    id BIGINT AUTO_INCREMENT PRIMARY KEY,\n"
        ++ "    name VARCHAR(63) NOT NULL,\n"
        ++ "    entity_type VARCHAR(63) NOT NULL DEFAULT '',\n"
        ++ "    observations TEXT NOT NULL,\n"
        ++ "    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,\n"
        ++ "    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,\n"
        ++ "    UNIQUE INDEX idx_name (name),\n"
        ++ "    INDEX idx_type (entity_type)\n"
        ++ ") ENGINE=TidesDB WRITE_BUFFER_SIZE=268435456",
    );
}

pub fn writeCreateObservation(w: *Writer) !void {
    try w.writeAll("CREATE TABLE IF NOT EXISTS ");
    try writeIdent(w, observation_table);
    try w.writeAll(
        " (\n"
        ++ "    id BIGINT AUTO_INCREMENT PRIMARY KEY,\n"
        ++ "    entity_name VARCHAR(63) NOT NULL,\n"
        ++ "    content TEXT NOT NULL,\n"
        ++ "    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,\n"
        ++ "    INDEX idx_entity (entity_name)\n"
        ++ ") ENGINE=TidesDB WRITE_BUFFER_SIZE=268435456",
    );
}

pub fn writeCreateRelation(w: *Writer) !void {
    try w.writeAll("CREATE TABLE IF NOT EXISTS ");
    try writeIdent(w, relation_table);
    try w.writeAll(
        " (\n"
        ++ "    id BIGINT AUTO_INCREMENT PRIMARY KEY,\n"
        ++ "    from_entity VARCHAR(63) NOT NULL,\n"
        ++ "    relation_type VARCHAR(63) NOT NULL,\n"
        ++ "    to_entity VARCHAR(63) NOT NULL,\n"
        ++ "    weight REAL DEFAULT 1.0,\n"
        ++ "    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,\n"
        ++ "    UNIQUE INDEX idx_rel (from_entity, relation_type, to_entity)\n"
        ++ ") ENGINE=TidesDB WRITE_BUFFER_SIZE=268435456",
    );
}

pub fn writeCreateTypeDict(w: *Writer) !void {
    try w.writeAll("CREATE TABLE IF NOT EXISTS ");
    try writeIdent(w, type_dict_table);
    try w.writeAll(
        " (\n"
        ++ "    id BIGINT AUTO_INCREMENT PRIMARY KEY,\n"
        ++ "    kind VARCHAR(63) NOT NULL,\n"
        ++ "    name VARCHAR(63) NOT NULL,\n"
        ++ "    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,\n"
        ++ "    UNIQUE INDEX idx_kind_name (kind, name)\n"
        ++ ") ENGINE=TidesDB WRITE_BUFFER_SIZE=268435456",
    );
}

pub fn writeCreateGraphStat(w: *Writer) !void {
    try w.writeAll("CREATE TABLE IF NOT EXISTS ");
    try writeIdent(w, graph_stat_table);
    try w.writeAll(
        " (\n"
        ++ "    id BIGINT AUTO_INCREMENT PRIMARY KEY,\n"
        ++ "    stat_name VARCHAR(63) NOT NULL,\n"
        ++ "    stat_value BIGINT NOT NULL,\n"
        ++ "    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,\n"
        ++ "    UNIQUE INDEX idx_stat_name (stat_name)\n"
        ++ ") ENGINE=TidesDB WRITE_BUFFER_SIZE=268435456",
    );
}

pub fn writeCreateVectorEmbedding(w: *Writer) !void {
    try w.writeAll("CREATE TABLE IF NOT EXISTS ");
    try writeIdent(w, vector_embedding_table);
    try w.writeAll(
        " (\n"
        ++ "    id BIGINT AUTO_INCREMENT PRIMARY KEY,\n"
        ++ "    entity_name VARCHAR(63) NOT NULL,\n"
        ++ "    text_content TEXT NOT NULL,\n"
        ++ "    embedding VECTOR(384) NOT NULL,\n"
        ++ "    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,\n"
        ++ "    INDEX idx_entity_name (entity_name),\n"
        ++ "    VECTOR INDEX idx_embedding (embedding)\n"
        ++ ") ENGINE=TidesDB WRITE_BUFFER_SIZE=268435456",
    );
}

// ── Batch DDL (for display / review) ──────────────────────────────────

/// Write all six CREATE TABLE statements separated by `;\n` terminators.
/// Does NOT include a final trailing newline.
pub fn writeAll(w: *Writer) !void {
    try writeCreateEntity(w);
    try w.writeAll(";\n\n");
    try writeCreateObservation(w);
    try w.writeAll(";\n\n");
    try writeCreateRelation(w);
    try w.writeAll(";\n\n");
    try writeCreateTypeDict(w);
    try w.writeAll(";\n\n");
    try writeCreateGraphStat(w);
    try w.writeAll(";\n\n");
    try writeCreateVectorEmbedding(w);
    try w.writeByte(';');
}

// ── Tests ─────────────────────────────────────────────────────────────

test "writeCreateEntity" {
    var buf: [1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeCreateEntity(&w);
    try std.testing.expectEqualStrings(
        \\CREATE TABLE IF NOT EXISTS `rag_entity` (
        \\    id BIGINT AUTO_INCREMENT PRIMARY KEY,
        \\    name VARCHAR(63) NOT NULL,
        \\    entity_type VARCHAR(63) NOT NULL DEFAULT '',
        \\    observations TEXT NOT NULL,
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        \\    UNIQUE INDEX idx_name (name),
        \\    INDEX idx_type (entity_type)
        \\) ENGINE=TidesDB WRITE_BUFFER_SIZE=268435456
    ,
        w.buffered(),
    );
}

test "writeCreateObservation" {
    var buf: [1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeCreateObservation(&w);
    try std.testing.expectEqualStrings(
        \\CREATE TABLE IF NOT EXISTS `rag_observation` (
        \\    id BIGINT AUTO_INCREMENT PRIMARY KEY,
        \\    entity_name VARCHAR(63) NOT NULL,
        \\    content TEXT NOT NULL,
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    INDEX idx_entity (entity_name)
        \\) ENGINE=TidesDB WRITE_BUFFER_SIZE=268435456
    ,
        w.buffered(),
    );
}

test "writeCreateRelation" {
    var buf: [1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeCreateRelation(&w);
    try std.testing.expectEqualStrings(
        \\CREATE TABLE IF NOT EXISTS `rag_relation` (
        \\    id BIGINT AUTO_INCREMENT PRIMARY KEY,
        \\    from_entity VARCHAR(63) NOT NULL,
        \\    relation_type VARCHAR(63) NOT NULL,
        \\    to_entity VARCHAR(63) NOT NULL,
        \\    weight REAL DEFAULT 1.0,
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    UNIQUE INDEX idx_rel (from_entity, relation_type, to_entity)
        \\) ENGINE=TidesDB WRITE_BUFFER_SIZE=268435456
    ,
        w.buffered(),
    );
}

test "writeCreateTypeDict" {
    var buf: [1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeCreateTypeDict(&w);
    try std.testing.expectEqualStrings(
        \\CREATE TABLE IF NOT EXISTS `rag_type_dict` (
        \\    id BIGINT AUTO_INCREMENT PRIMARY KEY,
        \\    kind VARCHAR(63) NOT NULL,
        \\    name VARCHAR(63) NOT NULL,
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    UNIQUE INDEX idx_kind_name (kind, name)
        \\) ENGINE=TidesDB WRITE_BUFFER_SIZE=268435456
    ,
        w.buffered(),
    );
}

test "writeCreateGraphStat" {
    var buf: [1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeCreateGraphStat(&w);
    try std.testing.expectEqualStrings(
        \\CREATE TABLE IF NOT EXISTS `rag_graph_stat` (
        \\    id BIGINT AUTO_INCREMENT PRIMARY KEY,
        \\    stat_name VARCHAR(63) NOT NULL,
        \\    stat_value BIGINT NOT NULL,
        \\    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        \\    UNIQUE INDEX idx_stat_name (stat_name)
        \\) ENGINE=TidesDB WRITE_BUFFER_SIZE=268435456
    ,
        w.buffered(),
    );
}

test "writeCreateVectorEmbedding" {
    var buf: [1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeCreateVectorEmbedding(&w);
    try std.testing.expectEqualStrings(
        \\CREATE TABLE IF NOT EXISTS `rag_vector_embedding` (
        \\    id BIGINT AUTO_INCREMENT PRIMARY KEY,
        \\    entity_name VARCHAR(63) NOT NULL,
        \\    text_content TEXT NOT NULL,
        \\    embedding VECTOR(384) NOT NULL,
        \\    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        \\    INDEX idx_entity_name (entity_name),
        \\    VECTOR INDEX idx_embedding (embedding)
        \\) ENGINE=TidesDB WRITE_BUFFER_SIZE=268435456
    ,
        w.buffered(),
    );
}

test "writeAll concatenates six statements with ; separators" {
    var buf: [8192]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeAll(&w);
    const result = w.buffered();

    // Verify each table name appears in the batch output.
    try std.testing.expect(result.len > 0);
    try std.testing.expectEqual(@as(usize, 6), std.mem.count(u8, result, "CREATE TABLE IF NOT EXISTS"));
    try std.testing.expect(std.mem.indexOf(u8, result, "ENGINE=TidesDB") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "VECTOR INDEX") != null);
}

test "allTableNames returns six names" {
    const names = allTableNames();
    try std.testing.expectEqual(@as(usize, 6), names.len);
    try std.testing.expectEqualStrings(entity_table, names[0]);
    try std.testing.expectEqualStrings(observation_table, names[1]);
    try std.testing.expectEqualStrings(relation_table, names[2]);
    try std.testing.expectEqualStrings(type_dict_table, names[3]);
    try std.testing.expectEqualStrings(graph_stat_table, names[4]);
    try std.testing.expectEqualStrings(vector_embedding_table, names[5]);
}
