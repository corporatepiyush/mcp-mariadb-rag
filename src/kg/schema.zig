const std = @import("std");

const Writer = std.Io.Writer;

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

pub fn writeCreateEntity(w: *Writer) !void {
    try w.writeAll(
        \\CREATE TABLE IF NOT EXISTS `rag_entity` (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    name TEXT NOT NULL UNIQUE,
        \\    entity_type TEXT NOT NULL DEFAULT '',
        \\    observations TEXT NOT NULL,
        \\    created_at TEXT DEFAULT (datetime('now')),
        \\    updated_at TEXT DEFAULT (datetime('now'))
        \\)
    );
}

pub fn writeCreateObservation(w: *Writer) !void {
    try w.writeAll(
        \\CREATE TABLE IF NOT EXISTS `rag_observation` (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    entity_name TEXT NOT NULL,
        \\    content TEXT NOT NULL,
        \\    created_at TEXT DEFAULT (datetime('now'))
        \\)
    );
}

pub fn writeCreateRelation(w: *Writer) !void {
    try w.writeAll(
        \\CREATE TABLE IF NOT EXISTS `rag_relation` (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    from_entity TEXT NOT NULL,
        \\    relation_type TEXT NOT NULL,
        \\    to_entity TEXT NOT NULL,
        \\    weight REAL DEFAULT 1.0,
        \\    created_at TEXT DEFAULT (datetime('now')),
        \\    UNIQUE(from_entity, relation_type, to_entity)
        \\)
    );
}

pub fn writeCreateTypeDict(w: *Writer) !void {
    try w.writeAll(
        \\CREATE TABLE IF NOT EXISTS `rag_type_dict` (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    kind TEXT NOT NULL,
        \\    name TEXT NOT NULL,
        \\    created_at TEXT DEFAULT (datetime('now')),
        \\    UNIQUE(kind, name)
        \\)
    );
}

pub fn writeCreateGraphStat(w: *Writer) !void {
    try w.writeAll(
        \\CREATE TABLE IF NOT EXISTS `rag_graph_stat` (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    stat_name TEXT NOT NULL UNIQUE,
        \\    stat_value INTEGER NOT NULL,
        \\    updated_at TEXT DEFAULT (datetime('now'))
        \\)
    );
}

pub fn writeCreateVectorEmbedding(w: *Writer) !void {
    try w.writeAll(
        \\CREATE TABLE IF NOT EXISTS `rag_vector_embedding` (
        \\    id TEXT NOT NULL PRIMARY KEY,
        \\    entity_name TEXT NOT NULL,
        \\    text_content TEXT NOT NULL,
        \\    embedding TEXT NOT NULL,
        \\    created_at TEXT DEFAULT (datetime('now'))
        \\)
    );
}

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

const testing = std.testing;

test "writeCreateEntity" {
    var buf: [1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeCreateEntity(&w);
    try testing.expectEqualStrings(
        \\CREATE TABLE IF NOT EXISTS `rag_entity` (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    name TEXT NOT NULL UNIQUE,
        \\    entity_type TEXT NOT NULL DEFAULT '',
        \\    observations TEXT NOT NULL,
        \\    created_at TEXT DEFAULT (datetime('now')),
        \\    updated_at TEXT DEFAULT (datetime('now'))
        \\)
    ,
        w.buffered(),
    );
}

test "writeCreateObservation" {
    var buf: [1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeCreateObservation(&w);
    try testing.expectEqualStrings(
        \\CREATE TABLE IF NOT EXISTS `rag_observation` (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    entity_name TEXT NOT NULL,
        \\    content TEXT NOT NULL,
        \\    created_at TEXT DEFAULT (datetime('now'))
        \\)
    ,
        w.buffered(),
    );
}

test "writeCreateRelation" {
    var buf: [1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeCreateRelation(&w);
    try testing.expectEqualStrings(
        \\CREATE TABLE IF NOT EXISTS `rag_relation` (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    from_entity TEXT NOT NULL,
        \\    relation_type TEXT NOT NULL,
        \\    to_entity TEXT NOT NULL,
        \\    weight REAL DEFAULT 1.0,
        \\    created_at TEXT DEFAULT (datetime('now')),
        \\    UNIQUE(from_entity, relation_type, to_entity)
        \\)
    ,
        w.buffered(),
    );
}

test "writeCreateTypeDict" {
    var buf: [1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeCreateTypeDict(&w);
    try testing.expectEqualStrings(
        \\CREATE TABLE IF NOT EXISTS `rag_type_dict` (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    kind TEXT NOT NULL,
        \\    name TEXT NOT NULL,
        \\    created_at TEXT DEFAULT (datetime('now')),
        \\    UNIQUE(kind, name)
        \\)
    ,
        w.buffered(),
    );
}

test "writeCreateGraphStat" {
    var buf: [1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeCreateGraphStat(&w);
    try testing.expectEqualStrings(
        \\CREATE TABLE IF NOT EXISTS `rag_graph_stat` (
        \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\    stat_name TEXT NOT NULL UNIQUE,
        \\    stat_value INTEGER NOT NULL,
        \\    updated_at TEXT DEFAULT (datetime('now'))
        \\)
    ,
        w.buffered(),
    );
}

test "writeCreateVectorEmbedding" {
    var buf: [1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeCreateVectorEmbedding(&w);
    try testing.expectEqualStrings(
        \\CREATE TABLE IF NOT EXISTS `rag_vector_embedding` (
        \\    id TEXT NOT NULL PRIMARY KEY,
        \\    entity_name TEXT NOT NULL,
        \\    text_content TEXT NOT NULL,
        \\    embedding TEXT NOT NULL,
        \\    created_at TEXT DEFAULT (datetime('now'))
        \\)
    ,
        w.buffered(),
    );
}

test "writeAll concatenates six statements with ; separators" {
    var buf: [8192]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeAll(&w);
    const result = w.buffered();

    try testing.expect(result.len > 0);
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, result, "CREATE TABLE IF NOT EXISTS"));
    try testing.expect(std.mem.indexOf(u8, result, "INTEGER PRIMARY KEY AUTOINCREMENT") != null);
    try testing.expect(std.mem.indexOf(u8, result, "TEXT NOT NULL") != null);
}

test "writeCreateRelation includes UNIQUE constraint" {
    var buf: [1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeCreateRelation(&w);
    const result = w.buffered();
    try testing.expect(std.mem.indexOf(u8, result, "UNIQUE(from_entity, relation_type, to_entity)") != null);
}

test "writeCreateVectorEmbedding keys on a TEXT id for upsert-by-id" {
    var buf: [1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeCreateVectorEmbedding(&w);
    const result = w.buffered();
    try testing.expect(std.mem.indexOf(u8, result, "id TEXT NOT NULL PRIMARY KEY") != null);
    try testing.expect(std.mem.indexOf(u8, result, "AUTO_INCREMENT") == null);
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
