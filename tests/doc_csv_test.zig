//! Tests for src/doc/csv.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/doc/csv.zig");

const render = srcmod.render;
const toText = srcmod.toText;

test "csv: simple rows" {
    try expectText("a,b,c\n1,2,3\n", ',', "a b c\n1 2 3\n", 2);
}

test "csv: trailing row without newline" {
    try expectText("x,y\n1,2", ',', "x y\n1 2\n", 2);
}

test "csv: quoted fields with embedded delimiter and newline" {
    try expectText(
        "name,note\n\"Doe, John\",\"line1\nline2\"\n",
        ',',
        "name note\nDoe, John line1\nline2\n",
        2,
    );
}

test "csv: escaped doubled quotes" {
    try expectText("a\n\"she said \"\"hi\"\"\"\n", ',', "a\nshe said \"hi\"\n", 2);
}

test "tsv: tab delimiter" {
    try expectText("a\tb\n1\t2\n", '\t', "a b\n1 2\n", 2);
}

test "csv: empty fields and blank lines" {
    try expectText("a,,c\n\n1,2,3\n", ',', "a  c\n1 2 3\n", 2);
}

test "csv: SIMD path on long unquoted field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const long = "abcdefghijklmnopqrstuvwxyz0123456789abcdef"; // > 32 bytes
    const input = try std.fmt.allocPrint(arena.allocator(), "{s},{s}\n", .{ long, long });
    const r = try toText(arena.allocator(), input, ',');
    const expect = try std.fmt.allocPrint(arena.allocator(), "{s} {s}\n", .{ long, long });
    try testing.expectEqualStrings(expect, r.text);
}

test "fuzz: csv render never panics on random bytes" {
    var prng = std.Random.DefaultPrng.init(0xC5712);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;
    const alphabet = "ab,\"\n\r\t 12";
    for (0..1000) |_| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const n = rnd.intRangeLessThan(usize, 0, buf.len);
        for (buf[0..n]) |*b| {
            b.* = if (rnd.boolean()) alphabet[rnd.intRangeLessThan(usize, 0, alphabet.len)] else rnd.int(u8);
        }
        _ = toText(arena.allocator(), buf[0..n], if (rnd.boolean()) ',' else '\t') catch {};
    }
}

// ---- helpers moved from src ----
pub fn expectText(input: []const u8, delim: u8, expect: []const u8, expect_rows: usize) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try toText(arena.allocator(), input, delim);
    try testing.expectEqualStrings(expect, r.text);
    try testing.expectEqual(expect_rows, r.units);
}
