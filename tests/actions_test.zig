const std = @import("std");
const testing = std.testing;
const actions = @import("../src/actions/mod.zig");
const stubs = @import("../src/actions/stubs.zig");

const Writer = std.Io.Writer;

// ---- isWriteTool ----------------------------------------------------------

test "isWriteTool: known write tools return true" {
    try testing.expect(actions.isWriteTool("create_table"));
    try testing.expect(actions.isWriteTool("drop_table"));
    try testing.expect(actions.isWriteTool("execute_insert"));
    try testing.expect(actions.isWriteTool("execute_update"));
    try testing.expect(actions.isWriteTool("execute_delete"));
    try testing.expect(actions.isWriteTool("create_index"));
    try testing.expect(actions.isWriteTool("drop_index"));
    try testing.expect(actions.isWriteTool("create_schema"));
    try testing.expect(actions.isWriteTool("drop_schema"));
    try testing.expect(actions.isWriteTool("create_view"));
    try testing.expect(actions.isWriteTool("drop_view"));
}

test "isWriteTool: non-write tools return false" {
    try testing.expect(!actions.isWriteTool("execute_query"));
    try testing.expect(!actions.isWriteTool("list_tables"));
    try testing.expect(!actions.isWriteTool("describe_table"));
    try testing.expect(!actions.isWriteTool("list_schemas"));
    try testing.expect(!actions.isWriteTool("explain_query"));
}

test "isWriteTool: unknown tool returns false" {
    try testing.expect(!actions.isWriteTool(""));
    try testing.expect(!actions.isWriteTool("nonexistent_tool"));
    try testing.expect(!actions.isWriteTool("SELECT"));
}

// ---- fuzzing --------------------------------------------------------------

test "fuzz: isWriteTool never panics on random byte sequences" {
    var prng = std.Random.DefaultPrng.init(0xF00D);
    const rnd = prng.random();
    var buf: [64]u8 = undefined;

    for (0..500) |_| {
        const len = rnd.intRangeLessThan(usize, 0, buf.len);
        const s = buf[0..len];
        for (s) |*b| b.* = rnd.int(u8);

        _ = actions.isWriteTool(s);
    }
}

test "fuzz: getStringParam never panics on random JSON values" {
    var prng = std.Random.DefaultPrng.init(0xB0BA);
    const rnd = prng.random();
    var buf: [32]u8 = undefined;

    for (0..200) |_| {
        const tag = rnd.intRangeLessThan(u8, 0, 5);
        const val: std.json.Value = switch (tag) {
            0 => .null,
            1 => .{ .bool = rnd.boolean() },
            2 => .{ .integer = @as(i64, @intCast(rnd.int(i32))) },
            3 => .{ .float = rnd.float(f64) },
            4 => blk: {
                const len = rnd.intRangeLessThan(usize, 0, buf.len);
                const s = buf[0..len];
                for (s) |*b| b.* = rnd.intRangeAtMost(u8, 32, 126);
                break :blk std.json.Value{ .string = s };
            },
            else => .null,
        };

        _ = actions.getStringParam(val, "key");
        _ = actions.getBoolParam(val, "flag", true);
        _ = actions.getArrayParam(val, "items");
    }
}

// ---- errPayload -----------------------------------------------------------

test "errPayload fields" {
    const p = actions.errPayload("something broke");
    try testing.expect(p.is_error);
    try testing.expectEqualStrings("something broke", p.text);
}

test "errPayload empty message" {
    const p = actions.errPayload("");
    try testing.expect(p.is_error);
    try testing.expectEqualStrings("", p.text);
}

// ---- getStringParam -------------------------------------------------------

test "getStringParam: null args" {
    try testing.expect(actions.getStringParam(null, "key") == null);
}

test "getStringParam: non-object args" {
    try testing.expect(actions.getStringParam(std.json.Value{ .integer = 42 }, "key") == null);
}

test "getStringParam: missing key" {
    var map = try std.json.ObjectMap.init(testing.allocator, &.{}, &.{});
    defer map.deinit(testing.allocator);
    try testing.expect(actions.getStringParam(std.json.Value{ .object = map }, "key") == null);
}

test "getStringParam: non-string value" {
    var map = try std.json.ObjectMap.init(testing.allocator, &.{}, &.{});
    defer map.deinit(testing.allocator);
    try map.put(testing.allocator, "key", std.json.Value{ .integer = 42 });
    try testing.expect(actions.getStringParam(std.json.Value{ .object = map }, "key") == null);
}

test "getStringParam: string value" {
    var map = try std.json.ObjectMap.init(testing.allocator, &.{}, &.{});
    defer map.deinit(testing.allocator);
    try map.put(testing.allocator, "key", std.json.Value{ .string = "value" });
    const v = actions.getStringParam(std.json.Value{ .object = map }, "key");
    try testing.expect(v != null);
    try testing.expectEqualStrings("value", v.?);
}

// ---- getBoolParam ---------------------------------------------------------

test "getBoolParam: default used" {
    var map = try std.json.ObjectMap.init(testing.allocator, &.{}, &.{});
    defer map.deinit(testing.allocator);
    try testing.expectEqual(true, actions.getBoolParam(std.json.Value{ .object = map }, "key", true));
    try testing.expectEqual(false, actions.getBoolParam(std.json.Value{ .object = map }, "key", false));
}

test "getBoolParam: null args returns default" {
    try testing.expectEqual(true, actions.getBoolParam(null, "key", true));
}

test "getBoolParam: explicit values" {
    var map = try std.json.ObjectMap.init(testing.allocator, &.{}, &.{});
    defer map.deinit(testing.allocator);
    try map.put(testing.allocator, "flag", std.json.Value{ .bool = true });
    try testing.expectEqual(true, actions.getBoolParam(std.json.Value{ .object = map }, "flag", false));
}

test "getBoolParam: non-bool falls back to default" {
    var map = try std.json.ObjectMap.init(testing.allocator, &.{}, &.{});
    defer map.deinit(testing.allocator);
    try map.put(testing.allocator, "flag", std.json.Value{ .string = "true" });
    try testing.expectEqual(false, actions.getBoolParam(std.json.Value{ .object = map }, "flag", false));
}

// ---- getArrayParam --------------------------------------------------------

test "getArrayParam: null args" {
    try testing.expect(actions.getArrayParam(null, "key") == null);
}

test "getArrayParam: non-object args" {
    try testing.expect(actions.getArrayParam(std.json.Value{ .string = "x" }, "key") == null);
}

test "getArrayParam: missing key" {
    var map = try std.json.ObjectMap.init(testing.allocator, &.{}, &.{});
    defer map.deinit(testing.allocator);
    try testing.expect(actions.getArrayParam(std.json.Value{ .object = map }, "key") == null);
}

test "getArrayParam: array value" {
    var map = try std.json.ObjectMap.init(testing.allocator, &.{}, &.{});
    defer map.deinit(testing.allocator);
    var arr = std.json.Array.init(testing.allocator);
    defer arr.deinit();
    try arr.append(std.json.Value{ .string = "a" });
    try map.put(testing.allocator, "items", std.json.Value{ .array = arr });
    const v = actions.getArrayParam(std.json.Value{ .object = map }, "items");
    try testing.expect(v != null);
    try testing.expectEqual(@as(usize, 1), v.?.items.len);
}

// ---- stubs ----------------------------------------------------------------

test "stubs.notImpl" {
    const p = stubs.notImpl(undefined, testing.allocator, undefined, null);
    try testing.expect(p.is_error);
    try testing.expectEqualStrings("Not yet implemented", p.text);
}

// ---- renderToOwned --------------------------------------------------------

fn writeHello(w: *Writer, name: []const u8) !void {
    try w.writeAll("hello ");
    try w.writeAll(name);
}

test "renderToOwned with simple writer" {
    const buf = try actions.renderToOwned(testing.allocator, writeHello, .{"world"});
    defer testing.allocator.free(buf);
    try testing.expectEqualStrings("hello world", buf);
}
