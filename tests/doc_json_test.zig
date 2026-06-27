//! Tests for src/doc/json.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/doc/json.zig");

const toText = srcmod.toText;
const toTextNd = srcmod.toTextNd;

test "json: object keeps keys with values" {
    try expectJson("{\"title\":\"Hello\",\"n\":3}", "title Hello n 3");
}

test "json: nested object and array" {
    try expectJson(
        "{\"a\":{\"b\":\"x\"},\"tags\":[\"p\",\"q\"]}",
        "a b x tags p q",
    );
}

test "json: scalars and null dropped" {
    try expectJson("{\"a\":null,\"b\":true,\"f\":1.5}", "a b true f 1.5");
}

test "json: bare array" {
    try expectJson("[\"one\",\"two\",\"three\"]", "one two three");
}

test "json: invalid falls back to raw" {
    try expectJson("  not json at all  ", "not json at all");
}

test "ndjson: one value per line, bad lines skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try toTextNd(arena.allocator(),
        \\{"a":1}
        \\garbage{
        \\{"b":"two"}
        \\
    );
    try testing.expectEqualStrings("a 1\nb two", r.text);
    try testing.expectEqual(@as(usize, 2), r.units);
}

test "fuzz: json extraction never panics" {
    var prng = std.Random.DefaultPrng.init(0x5500);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;
    const alphabet = "{}[]\":,0123456789abc null true";
    for (0..1500) |_| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const n = rnd.intRangeLessThan(usize, 0, buf.len);
        for (buf[0..n]) |*b| {
            b.* = if (rnd.boolean()) alphabet[rnd.intRangeLessThan(usize, 0, alphabet.len)] else rnd.int(u8);
        }
        _ = toText(arena.allocator(), buf[0..n]) catch {};
        _ = toTextNd(arena.allocator(), buf[0..n]) catch {};
    }
}

// ---- helpers moved from src ----
pub fn expectJson(input: []const u8, expect: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try toText(arena.allocator(), input);
    try testing.expectEqualStrings(expect, r.text);
}
