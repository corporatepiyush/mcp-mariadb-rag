const std = @import("std");
const pool = @import("../pool.zig");
const validation = @import("../validation.zig");
const schema = @import("schema.zig");

const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;
const PooledConn = pool.PooledConnection;

pub fn renderToOwned(allocator: Allocator, comptime write_fn: anytype, args: anytype) ![]u8 {
    var aw = Writer.Allocating.init(allocator);
    errdefer aw.deinit();
    try @call(.auto, write_fn, .{&aw.writer} ++ args);
    return aw.toOwnedSlice();
}

pub fn execBuilt(allocator: Allocator, conn: *PooledConn, comptime write_fn: anytype, args: anytype) !u64 {
    const sql = try renderToOwned(allocator, write_fn, args);
    defer allocator.free(sql);
    return conn.execute(sql);
}

fn writeSqlLiteral(w: *Writer, s: []const u8) !void {
    try w.writeByte('\'');
    try validation.writeEscapedLiteral(w, s);
    try w.writeByte('\'');
}

fn writeVectorLiteral(w: *Writer, vector: []const f32) !void {
    try w.writeByte('\'');
    try w.writeByte('[');
    for (vector, 0..) |v, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{d}", .{v});
    }
    try w.writeByte(']');
    try w.writeByte('\'');
}

pub fn writeUpsertVector(w: *Writer, id: []const u8, entity_name: []const u8, text_content: []const u8, vector: []const f32) !void {
    try w.writeAll("REPLACE INTO ");
    try validation.writeQuotedIdent(w, schema.vector_embedding_table);
    try w.writeAll(" (id, entity_name, text_content, embedding) VALUES (");
    try writeSqlLiteral(w, id);
    try w.writeByte(',');
    try writeSqlLiteral(w, entity_name);
    try w.writeByte(',');
    try writeSqlLiteral(w, text_content);
    try w.writeAll(", Vec_FromText(");
    try writeVectorLiteral(w, vector);
    try w.writeAll("))");
}

pub fn writeSearchVectors(w: *Writer, query_vector: []const f32, limit: u64) !void {
    try w.writeAll("SELECT id, entity_name, text_content, VEC_DISTANCE_EUCLIDEAN(embedding, Vec_FromText(");
    try writeVectorLiteral(w, query_vector);
    try w.writeAll(")) AS distance FROM ");
    try validation.writeQuotedIdent(w, schema.vector_embedding_table);
    try w.writeAll(" ORDER BY distance LIMIT ");
    try w.print("{d}", .{limit});
}

pub fn writeDeleteVectorById(w: *Writer, id: []const u8) !void {
    try w.writeAll("DELETE FROM ");
    try validation.writeQuotedIdent(w, schema.vector_embedding_table);
    try w.writeAll(" WHERE id = ");
    try writeSqlLiteral(w, id);
}

pub fn writeDeleteVectorsByEntity(w: *Writer, entity_name: []const u8) !void {
    try w.writeAll("DELETE FROM ");
    try validation.writeQuotedIdent(w, schema.vector_embedding_table);
    try w.writeAll(" WHERE entity_name = ");
    try writeSqlLiteral(w, entity_name);
}

pub fn writeGetVectorsByEntity(w: *Writer, entity_name: []const u8, limit: ?u64) !void {
    try w.writeAll("SELECT id, entity_name, text_content, embedding FROM ");
    try validation.writeQuotedIdent(w, schema.vector_embedding_table);
    try w.writeAll(" WHERE entity_name = ");
    try writeSqlLiteral(w, entity_name);
    try w.writeAll(" ORDER BY created_at");
    if (limit) |l| {
        try w.print(" LIMIT {d}", .{l});
    }
}

pub fn writeCountVectors(w: *Writer) !void {
    try w.writeAll("SELECT COUNT(*) FROM ");
    try validation.writeQuotedIdent(w, schema.vector_embedding_table);
}

pub fn writeCountVectorsByEntity(w: *Writer, entity_name: []const u8) !void {
    try w.writeAll("SELECT COUNT(*) FROM ");
    try validation.writeQuotedIdent(w, schema.vector_embedding_table);
    try w.writeAll(" WHERE entity_name = ");
    try writeSqlLiteral(w, entity_name);
}

const testing = std.testing;

fn renderSql(buf: []u8, comptime f: anytype, args: anytype) ![]u8 {
    var w = Writer.fixed(buf);
    try @call(.auto, f, .{&w} ++ args);
    return w.buffered();
}

test "writeUpsertVector" {
    var buf: [2048]u8 = undefined;
    const vec = [_]f32{ 0.1, 0.2, 0.3 };
    const result = try renderSql(&buf, writeUpsertVector, .{ "u1", "Alice", "text", &vec });
    try testing.expect(std.mem.indexOf(u8, result, "REPLACE INTO") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Vec_FromText") != null);
    try testing.expect(std.mem.indexOf(u8, result, "'Alice'") != null);
}

test "writeSearchVectors" {
    var buf: [4096]u8 = undefined;
    const vec = [_]f32{ 0.1, 0.2, 0.3 };
    const result = try renderSql(&buf, writeSearchVectors, .{ &vec, @as(u64, 10) });
    try testing.expect(std.mem.indexOf(u8, result, "VEC_DISTANCE_EUCLIDEAN") != null);
    try testing.expect(std.mem.indexOf(u8, result, "ORDER BY distance") != null);
    try testing.expect(std.mem.indexOf(u8, result, "LIMIT 10") != null);
}

test "writeDeleteVectorById" {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "DELETE FROM `rag_vector_embedding` WHERE id = 'u1'",
        try renderSql(&buf, writeDeleteVectorById, .{"u1"}),
    );
}

test "writeDeleteVectorsByEntity" {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "DELETE FROM `rag_vector_embedding` WHERE entity_name = 'Alice'",
        try renderSql(&buf, writeDeleteVectorsByEntity, .{"Alice"}),
    );
}

test "writeGetVectorsByEntity" {
    var buf: [512]u8 = undefined;
    const result = try renderSql(&buf, writeGetVectorsByEntity, .{ "Alice", @as(?u64, null) });
    try testing.expect(std.mem.indexOf(u8, result, "WHERE entity_name = 'Alice'") != null);
    try testing.expect(std.mem.indexOf(u8, result, "LIMIT") == null);
}

test "writeGetVectorsByEntity with limit" {
    var buf: [512]u8 = undefined;
    const result = try renderSql(&buf, writeGetVectorsByEntity, .{ "Alice", @as(?u64, 5) });
    try testing.expect(std.mem.indexOf(u8, result, "LIMIT 5") != null);
}

test "writeCountVectors" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "SELECT COUNT(*) FROM `rag_vector_embedding`",
        try renderSql(&buf, writeCountVectors, .{}),
    );
}

test "writeCountVectorsByEntity" {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "SELECT COUNT(*) FROM `rag_vector_embedding` WHERE entity_name = 'Alice'",
        try renderSql(&buf, writeCountVectorsByEntity, .{"Alice"}),
    );
}

test "writeVectorLiteral formats floats" {
    var buf: [256]u8 = undefined;
    const vec = [_]f32{ 1.5, -2.0, 3.0 };
    var w = Writer.fixed(&buf);
    try writeVectorLiteral(&w, &vec);
    const result = w.buffered();
    try testing.expectEqualStrings("'[1.5,-2,3]'", result);
}
