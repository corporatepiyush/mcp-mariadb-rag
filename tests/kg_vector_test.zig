//! Tests for src/kg/vector.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/kg/vector.zig");
const Io = std.Io;

const Writer = std.Io.Writer;
const writeCountVectors = srcmod.writeCountVectors;
const writeCountVectorsByEntity = srcmod.writeCountVectorsByEntity;
const writeDeleteVectorById = srcmod.writeDeleteVectorById;
const writeDeleteVectorsByEntity = srcmod.writeDeleteVectorsByEntity;
const writeGetVectorsByEntity = srcmod.writeGetVectorsByEntity;
const writeSearchVectors = srcmod.writeSearchVectors;
const writeUpsertVector = srcmod.writeUpsertVector;
const writeVectorLiteral = srcmod.writeVectorLiteral;

test "writeUpsertVector" {
    var buf: [2048]u8 = undefined;
    const vec = [_]f32{ 0.1, 0.2, 0.3 };
    const result = try renderSql(&buf, writeUpsertVector, .{ "u1", "Alice", "text", &vec });
    try testing.expect(std.mem.indexOf(u8, result, "INSERT INTO") != null);
    try testing.expect(std.mem.indexOf(u8, result, "ON CONFLICT(id) DO UPDATE") != null);
    try testing.expect(std.mem.indexOf(u8, result, "Vec_FromText") == null);
    try testing.expect(std.mem.indexOf(u8, result, "'Alice'") != null);
}

test "writeSearchVectors" {
    var buf: [4096]u8 = undefined;
    const vec = [_]f32{ 0.1, 0.2, 0.3 };
    const result = try renderSql(&buf, writeSearchVectors, .{ &vec, @as(u64, 10) });
    try testing.expect(std.mem.indexOf(u8, result, "VEC_DISTANCE_EUCLIDEAN") == null);
    try testing.expect(std.mem.indexOf(u8, result, "SELECT id, entity_name, text_content, embedding FROM") != null);
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

test "writeVectorLiteral emits X'hex' blob literal" {
    var buf: [256]u8 = undefined;
    // f32: 1.5=0x3fc00000, -2.0=0xc0000000, 3.0=0x40400000 (little-endian)
    // So raw bytes: 00 00 c0 3f | 00 00 00 c0 | 00 00 40 40
    const vec = [_]f32{ 1.5, -2.0, 3.0 };
    var w = Writer.fixed(&buf);
    try writeVectorLiteral(&w, &vec);
    const result = w.buffered();
    try testing.expect(std.mem.indexOf(u8, result, "X'") != null);
    try testing.expect(result.len > 20); // X'hex' wrapper
    try testing.expect(std.mem.indexOf(u8, result, "c03f") != null); // 0x3fc0 → little-endian c0 3f
}

// ---- helpers moved from src ----
pub fn renderSql(buf: []u8, comptime f: anytype, args: anytype) ![]u8 {
    var w = Writer.fixed(buf);
    try @call(.auto, f, .{&w} ++ args);
    return w.buffered();
}
