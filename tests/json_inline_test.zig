//! Tests for src/json.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/json.zig");
const Io = std.Io;

const Value = std.json.Value;
const Writer = std.Io.Writer;
const isJsonNumber = srcmod.isJsonNumber;
const types = srcmod.types;
const writeAffected = srcmod.writeAffected;
const writeEscaped = srcmod.writeEscaped;
const writeQuoted = srcmod.writeQuoted;
const writeRows = srcmod.writeRows;
const writeRpcId = srcmod.writeRpcId;

fn renderToBuf(buf: []u8, comptime f: anytype, args: anytype) ![]u8 {
    var w = Writer.fixed(buf);
    try @call(.auto, f, .{&w} ++ args);
    return w.buffered();
}

test "fuzz: writeQuoted output is always valid JSON that round-trips" {
    var prng = std.Random.DefaultPrng.init(0x350_15ED);
    const rnd = prng.random();
    var in_buf: [128]u8 = undefined;
    var out_buf: [1024]u8 = undefined; // \uXXXX worst case 6x

    for (0..5000) |_| {
        const len = rnd.intRangeAtMost(usize, 0, in_buf.len);
        // Single-byte codepoints (0x00–0x7F) are always valid UTF-8 and exercise
        // every escape branch (quote, backslash, \n\r\t\b\f, \u00XX, passthrough).
        for (in_buf[0..len]) |*b| b.* = rnd.uintLessThan(u8, 0x80);

        var w = Writer.fixed(&out_buf);
        try writeQuoted(&w, in_buf[0..len]);
        const out = w.buffered();

        const parsed = try std.json.parseFromSlice([]const u8, testing.allocator, out, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings(in_buf[0..len], parsed.value);
    }
}

test "escaping" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "a\\\"b\\\\c\\nd\\te",
        try renderToBuf(&buf, writeEscaped, .{"a\"b\\c\nd\te"}),
    );
}

test "escaping control characters" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "\\u0000\\u0001\\b\\f",
        try renderToBuf(&buf, writeEscaped, .{&[_]u8{ 0x00, 0x01, 0x08, 0x0c }}),
    );
}

test "rpc id variants" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("42", try renderToBuf(&buf, writeRpcId, .{Value{ .integer = 42 }}));
    try testing.expectEqualStrings("\"abc\"", try renderToBuf(&buf, writeRpcId, .{Value{ .string = "abc" }}));
    try testing.expectEqualStrings("null", try renderToBuf(&buf, writeRpcId, .{@as(?Value, null)}));
    try testing.expectEqualStrings("null", try renderToBuf(&buf, writeRpcId, .{Value{ .null = {} }}));
}

test "isJsonNumber" {
    try testing.expect(isJsonNumber("0"));
    try testing.expect(isJsonNumber("-42"));
    try testing.expect(isJsonNumber("3.14"));
    try testing.expect(isJsonNumber("-0.5e10"));
    try testing.expect(isJsonNumber("123456789012345678901234567890")); // big int kept verbatim
    try testing.expect(!isJsonNumber(""));
    try testing.expect(!isJsonNumber("007")); // leading zero is NOT a JSON number
    try testing.expect(!isJsonNumber("1."));
    try testing.expect(!isJsonNumber("1e"));
    try testing.expect(!isJsonNumber("abc"));
    try testing.expect(!isJsonNumber("12abc"));
    try testing.expect(!isJsonNumber("+1"));
}

test "writeRows: NULL vs empty string vs numeric coercion" {
    const rows = [_]types.Row{
        .{ .values = &[_]?[]const u8{ "1", null, "" } },
        .{ .values = &[_]?[]const u8{ "007", "hi\"x", "2" } },
    };
    const names = [_][]const u8{ "id", "name", "qty" };
    const kinds = [_]types.ColumnKind{ .numeric, .text, .numeric };

    var aw = Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try writeRows(&aw.writer, &rows, &names, &kinds);

    try testing.expectEqualStrings(
        "{\"columns\":[\"id\",\"name\",\"qty\"],\"rows\":[[1,null,\"\"],[\"007\",\"hi\\\"x\",2]],\"row_count\":2}",
        aw.written(),
    );
}

test "writeAffected" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "{\"rows_affected\":3,\"insert_id\":17}",
        try renderToBuf(&buf, writeAffected, .{ @as(u64, 3), @as(u64, 17) }),
    );
}
