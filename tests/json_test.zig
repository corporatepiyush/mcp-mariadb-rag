//! Additional JSON serialisation edge cases beyond the inline tests in
//! `json.zig`. Focuses on boundary conditions, encoding fidelity, and
//! round-trip safety for the project's wire format.

const std = @import("std");
const testing = std.testing;
const json = @import("../src/json.zig");
const types = @import("../src/types.zig");

const Writer = std.Io.Writer;

// ---- helpers -------------------------------------------------------------

fn render(comptime f: anytype, args: anytype) ![]const u8 {
    var buf: [2048]u8 = undefined;
    var w = Writer.fixed(&buf);
    try @call(.auto, f, .{&w} ++ args);
    return w.buffered();
}

fn renderAlloc(allocator: std.mem.Allocator, comptime f: anytype, args: anytype) ![]u8 {
    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    try @call(.auto, f, .{&aw.writer} ++ args);
    return aw.toOwnedSlice();
}

// ---- isJsonNumber --------------------------------------------------------

test "isJsonNumber rejects hex/octal/binary" {
    try testing.expect(!json.isJsonNumber("0x1F"));
    try testing.expect(!json.isJsonNumber("0o7"));
    try testing.expect(!json.isJsonNumber("0b101"));
}

test "isJsonNumber negative zero" {
    try testing.expect(json.isJsonNumber("-0"));
}

test "isJsonNumber leading plus" {
    try testing.expect(!json.isJsonNumber("+1"));
}

test "isJsonNumber multiple dots" {
    try testing.expect(!json.isJsonNumber("1.2.3"));
}

test "isJsonNumber trailing whitespace" {
    try testing.expect(!json.isJsonNumber("42 "));
}

test "isJsonNumber lone minus" {
    try testing.expect(!json.isJsonNumber("-"));
}

test "isJsonNumber scientific max bounds" {
    try testing.expect(json.isJsonNumber("1e-999"));
    try testing.expect(json.isJsonNumber("1e+999"));
    try testing.expect(json.isJsonNumber("1E308"));
}

test "isJsonNumber zero with leading decimal" {
    try testing.expect(!json.isJsonNumber(".5"));
}

// ---- fuzzing --------------------------------------------------------------

test "fuzz: isJsonNumber never panics on random byte sequences" {
    var prng = std.Random.DefaultPrng.init(42);
    const rnd = prng.random();
    var buf: [128]u8 = undefined;

    for (0..1000) |_| {
        const len = rnd.intRangeLessThan(usize, 0, buf.len);
        const s = buf[0..len];
        for (s) |*b| b.* = rnd.int(u8);

        _ = json.isJsonNumber(s);
    }
}

test "fuzz: isJsonNumber never panics on random high-byte sequences" {
    var prng = std.Random.DefaultPrng.init(123);
    const rnd = prng.random();
    var buf: [64]u8 = undefined;

    for (0..500) |_| {
        const len = rnd.intRangeLessThan(usize, 0, buf.len);
        const s = buf[0..len];
        for (s) |*b| b.* = rnd.intRangeAtMost(u8, 128, 255);

        _ = json.isJsonNumber(s);
    }
}

// ---- writeEscaped --------------------------------------------------------

test "writeEscaped: no-op for ascii text" {
    try testing.expectEqualStrings("hello world", try render(json.writeEscaped, .{"hello world"}));
}

test "writeEscaped: control chars near boundaries" {
    // 0x7f is DEL — NOT escaped by current code (it's not 0-0x1f), verify
    try testing.expectEqualStrings("a\x7fb", try render(json.writeEscaped, .{&[_]u8{ 0x61, 0x7f, 0x62 }}));
}

test "writeEscaped: surrogate range bytes" {
    // JSON does not allow lone surrogates; but our raw writer just escapes
    // 0-0x1f and special chars. Bytes 0x80-0xFF pass through — that's the
    // caller's responsibility to validate as UTF-8.
    try testing.expectEqualStrings("\xc3\xa9", try render(json.writeEscaped, .{"\xc3\xa9"}));
}

test "writeEscaped: mixed escape and plain" {
    try testing.expectEqualStrings(
        "hello\\nworld\\ttab",
        try render(json.writeEscaped, .{"hello\nworld\ttab"}),
    );
}

// ---- writeQuoted ---------------------------------------------------------

test "writeQuoted wraps and escapes" {
    try testing.expectEqualStrings(
        "\"a\\\"b\"",
        try render(json.writeQuoted, .{"a\"b"}),
    );
}

test "writeQuoted empty string" {
    try testing.expectEqualStrings("\"\"", try render(json.writeQuoted, .{""}));
}

// ---- writeRpcId ----------------------------------------------------------

test "writeRpcId: float id" {
    try testing.expectEqualStrings(
        "1.5",
        try render(json.writeRpcId, .{std.json.Value{ .float = 1.5 }}),
    );
}

test "writeRpcId: number_string" {
    try testing.expectEqualStrings(
        "12345678901234567890",
        try render(json.writeRpcId, .{std.json.Value{ .number_string = "12345678901234567890" }}),
    );
}

test "writeRpcId: object default to null" {
    var map = try std.json.ObjectMap.init(testing.allocator, &.{}, &.{});
    defer map.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "null",
        try render(json.writeRpcId, .{std.json.Value{ .object = map }}),
    );
}

// ---- writeRows -----------------------------------------------------------

test "writeRows: empty row set" {
    const buf = try renderAlloc(testing.allocator, json.writeRows, .{
        @as([]const types.Row, &.{}),
        @as(?[]const []const u8, null),
        @as(?[]const types.ColumnKind, null),
    });
    defer testing.allocator.free(buf);
    try testing.expectEqualStrings("{\"rows\":[],\"row_count\":0}", buf);
}

test "writeRows: NULL values" {
    const rows = [_]types.Row{
        .{ .values = &[_]?[]const u8{ null, null, null } },
    };
    const names = [_][]const u8{ "a", "b", "c" };
    const buf = try renderAlloc(testing.allocator, json.writeRows, .{ &rows, &names, @as(?[]const types.ColumnKind, null) });
    defer testing.allocator.free(buf);
    try testing.expectEqualStrings("{\"columns\":[\"a\",\"b\",\"c\"],\"rows\":[[null,null,null]],\"row_count\":1}", buf);
}

test "writeRows: mixed numeric with overflow string" {
    const rows = [_]types.Row{
        .{ .values = &[_]?[]const u8{ "99999999999999999999", null, "3.14" } },
    };
    const kinds = [_]types.ColumnKind{ .numeric, .text, .numeric };
    const buf = try renderAlloc(testing.allocator, json.writeRows, .{ &rows, @as(?[]const []const u8, null), &kinds });
    defer testing.allocator.free(buf);
    // All three are valid JSON numbers, so emit bare
    try testing.expectEqualStrings("{\"rows\":[[99999999999999999999,null,3.14]],\"row_count\":1}", buf);
}

test "writeRows: row_count matches provided slice length" {
    const rows = [_]types.Row{
        .{ .values = &[_]?[]const u8{} },
        .{ .values = &[_]?[]const u8{} },
    };
    const buf = try renderAlloc(testing.allocator, json.writeRows, .{ &rows, @as(?[]const []const u8, null), @as(?[]const types.ColumnKind, null) });
    defer testing.allocator.free(buf);
    try testing.expectEqualStrings("{\"rows\":[[],[]],\"row_count\":2}", buf);
}

// ---- writeAffected -------------------------------------------------------

test "writeAffected zero values" {
    try testing.expectEqualStrings(
        "{\"rows_affected\":0,\"insert_id\":0}",
        try render(json.writeAffected, .{ @as(u64, 0), @as(u64, 0) }),
    );
}

test "writeAffected large values" {
    try testing.expectEqualStrings(
        "{\"rows_affected\":18446744073709551615,\"insert_id\":18446744073709551615}",
        try render(json.writeAffected, .{ std.math.maxInt(u64), std.math.maxInt(u64) }),
    );
}

// ---- writeStatus ---------------------------------------------------------

test "writeStatus" {
    try testing.expectEqualStrings(
        "{\"status\":\"success\",\"action\":\"create\",\"name\":\"users\"}",
        try render(json.writeStatus, .{ "create", "name", "users" }),
    );
}

test "writeStatus with special chars" {
    try testing.expectEqualStrings(
        "{\"status\":\"success\",\"action\":\"create\",\"label-123\":\"some\\\"name\"}",
        try render(json.writeStatus, .{ "create", "label-123", "some\"name" }),
    );
}

// ---- writeQueryResult ----------------------------------------------------

test "writeQueryResult result set path" {
    const result = types.QueryResult{
        .rows = &[_]types.Row{
            .{ .values = &[_]?[]const u8{ "1", "alice" } },
        },
        .column_names = &[_][]const u8{ "id", "name" },
        .column_kinds = &[_]types.ColumnKind{ .numeric, .text },
        .num_fields = 2,
        .num_rows = 1,
        .affected_rows = 0,
        .insert_id = 0,
    };
    const buf = try renderAlloc(testing.allocator, json.writeQueryResult, .{result});
    defer testing.allocator.free(buf);
    try testing.expectEqualStrings(
        "{\"columns\":[\"id\",\"name\"],\"rows\":[[1,\"alice\"]],\"row_count\":1}",
        buf,
    );
}

test "writeQueryResult affected path" {
    const result = types.QueryResult{
        .rows = null,
        .column_names = null,
        .column_kinds = null,
        .num_fields = 0,
        .num_rows = 0,
        .affected_rows = 5,
        .insert_id = 42,
    };
    const buf = try renderAlloc(testing.allocator, json.writeQueryResult, .{result});
    defer testing.allocator.free(buf);
    try testing.expectEqualStrings("{\"rows_affected\":5,\"insert_id\":42}", buf);
}
