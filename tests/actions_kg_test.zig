//! Tests for src/actions/kg.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/actions/kg.zig");
const Io = std.Io;

const Value = std.json.Value;
const Writer = std.Io.Writer;
const json = srcmod.json;
const parseVector = srcmod.parseVector;
const stringArray = srcmod.stringArray;
const vector_dims = srcmod.vector_dims;
const writeEntityObject = srcmod.writeEntityObject;
const writeRelationObject = srcmod.writeRelationObject;

test "parseVector accepts mixed int/float and reports length" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [vector_dims]f32 = undefined;
    const arr = jsonArray(&arena, "[1, 2.5, 3, -4.25]");
    const out = try parseVector(&buf, arr);
    try testing.expectEqual(@as(usize, 4), out.len);
    try testing.expectEqual(@as(f32, 1.0), out[0]);
    try testing.expectEqual(@as(f32, 2.5), out[1]);
    try testing.expectEqual(@as(f32, 3.0), out[2]);
    try testing.expectEqual(@as(f32, -4.25), out[3]);
}

test "parseVector rejects non-numbers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [vector_dims]f32 = undefined;
    const arr = jsonArray(&arena, "[1, \"two\", 3]");
    try testing.expectError(error.NotNumber, parseVector(&buf, arr));
}

test "parseVector rejects over-long vectors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [vector_dims]f32 = undefined;
    // Build a 385-element array.
    var aw = Writer.Allocating.init(arena.allocator());
    try aw.writer.writeByte('[');
    for (0..vector_dims + 1) |i| {
        if (i > 0) try aw.writer.writeByte(',');
        try aw.writer.writeByte('1');
    }
    try aw.writer.writeByte(']');
    const arr = jsonArray(&arena, try aw.toOwnedSlice());
    try testing.expectError(error.TooLong, parseVector(&buf, arr));
}

test "parseVector accepts exactly 384 dims" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [vector_dims]f32 = undefined;
    var aw = Writer.Allocating.init(arena.allocator());
    try aw.writer.writeByte('[');
    for (0..vector_dims) |i| {
        if (i > 0) try aw.writer.writeByte(',');
        try aw.writer.writeByte('0');
    }
    try aw.writer.writeByte(']');
    const arr = jsonArray(&arena, try aw.toOwnedSlice());
    const out = try parseVector(&buf, arr);
    try testing.expectEqual(@as(usize, vector_dims), out.len);
}

test "stringArray collects strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const arr = jsonArray(&arena, "[\"a\",\"b\",\"c\"]");
    const out = try stringArray(arena.allocator(), arr);
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqualStrings("a", out[0]);
    try testing.expectEqualStrings("c", out[2]);
}

test "stringArray rejects non-string element" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const arr = jsonArray(&arena, "[\"a\", 2]");
    try testing.expectError(error.NotString, stringArray(arena.allocator(), arr));
}

test "stringArray handles empty array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const arr = jsonArray(&arena, "[]");
    const out = try stringArray(arena.allocator(), arr);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "writeEntityObject embeds raw observations and escapes name/type" {
    var buf: [512]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeEntityObject(&w, "A\"x", "person", "[\"o1\"]");
    try testing.expectEqualStrings(
        "{\"name\":\"A\\\"x\",\"entityType\":\"person\",\"observations\":[\"o1\"]}",
        w.buffered(),
    );
}

test "writeRelationObject" {
    var buf: [256]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeRelationObject(&w, "A", "knows", "B");
    try testing.expectEqualStrings(
        "{\"from\":\"A\",\"relationType\":\"knows\",\"to\":\"B\"}",
        w.buffered(),
    );
}

// ---- fuzzing --------------------------------------------------------------
// parseVector and stringArray consume arrays parsed from untrusted JSON; per
// Agent.md every such extractor gets a property test asserting it never panics
// across all JSON value variants, lengths spanning the 384-dim cap, and the
// empty case. We feed generated JSON text through the real parser so the whole
// bytes -> Value -> extractor path is exercised.

test "fuzz: parseVector / stringArray never panic on random JSON arrays" {
    var prng = std.Random.DefaultPrng.init(0xF00D);
    const rnd = prng.random();
    var fbuf: [vector_dims]f32 = undefined;

    for (0..500) |_| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var aw = Writer.Allocating.init(a);
        const w = &aw.writer;
        w.writeByte('[') catch continue;
        const n = rnd.intRangeAtMost(usize, 0, 400); // spans the 384 cap on both sides
        for (0..n) |i| {
            if (i > 0) w.writeByte(',') catch continue;
            switch (rnd.intRangeLessThan(u8, 0, 6)) {
                0 => w.writeAll("null") catch {},
                1 => w.writeAll(if (rnd.boolean()) "true" else "false") catch {},
                2 => w.print("{d}", .{rnd.int(i32)}) catch {},
                3 => w.print("{d}.25", .{rnd.int(i16)}) catch {},
                4 => w.writeAll("\"s\"") catch {},
                else => w.writeAll("[]") catch {},
            }
        }
        w.writeByte(']') catch continue;
        const src = aw.toOwnedSlice() catch continue;

        const parsed = std.json.parseFromSlice(Value, a, src, .{}) catch continue;
        if (parsed.value != .array) continue;
        const arr = parsed.value.array;
        _ = parseVector(&fbuf, arr) catch {};
        _ = stringArray(a, arr) catch {};
    }
}

// ---- helpers moved from src ----
pub fn jsonArray(arena: *std.heap.ArenaAllocator, src: []const u8) std.json.Array {
    const parsed = std.json.parseFromSlice(Value, arena.allocator(), src, .{}) catch unreachable;
    return parsed.value.array;
}
