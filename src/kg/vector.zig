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

pub fn writeVectorLiteral(w: *Writer, vector: []const f32) !void {
    try w.writeAll("X'");
    const bytes = std.mem.sliceAsBytes(vector);
    for (bytes) |b| {
        try w.writeByte(hex_chars[b >> 4]);
        try w.writeByte(hex_chars[b & 0xf]);
    }
    try w.writeByte('\'');
}

const hex_chars = "0123456789abcdef";

pub fn writeUpsertVector(w: *Writer, id: []const u8, entity_name: []const u8, text_content: []const u8, vector: []const f32) !void {
    try w.writeAll("INSERT INTO ");
    try validation.writeQuotedIdent(w, schema.vector_embedding_table);
    try w.writeAll(" (id, entity_name, text_content, embedding) VALUES (");
    try writeSqlLiteral(w, id);
    try w.writeByte(',');
    try writeSqlLiteral(w, entity_name);
    try w.writeByte(',');
    try writeSqlLiteral(w, text_content);
    try w.writeByte(',');
    try writeVectorLiteral(w, vector);
    try w.writeAll(") ON CONFLICT(id) DO UPDATE SET entity_name=excluded.entity_name, text_content=excluded.text_content, embedding=excluded.embedding");
}

pub fn writeSearchVectors(w: *Writer, _: []const f32, limit: u64) !void {
    try w.writeAll("SELECT id, entity_name, text_content, embedding FROM ");
    try validation.writeQuotedIdent(w, schema.vector_embedding_table);
    try w.writeAll(" LIMIT ");
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
