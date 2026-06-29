//! Tests for src/doc/arrow.zig (Apache Arrow IPC reader).
//!
//! Fixtures under tests/fixtures/*.arrow are real Arrow IPC *stream* files
//! written by DuckDB's nanoarrow extension (`COPY … TO … (FORMAT ARROWS)`), so
//! these round-trip against another implementation's output.

const std = @import("std");
const testing = std.testing;
const arrow = @import("../src/doc/arrow.zig");

fn contains(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
}

const flat = @embedFile("fixtures/flat.arrow");
const big = @embedFile("fixtures/big.arrow");

fn decode(bytes: []const u8) !struct { text: []u8, units: usize, arena: *std.heap.ArenaAllocator } {
    const arena = try testing.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(testing.allocator);
    const r = try arrow.toText(arena.allocator(), bytes);
    return .{ .text = r.text, .units = r.units, .arena = arena };
}

fn freeDecode(d: anytype) void {
    d.arena.deinit();
    testing.allocator.destroy(d.arena);
}

test "arrow: not an arrow buffer is rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.NotArrow, arrow.toText(arena.allocator(), "hello, world!!!!"));
}

test "arrow: flat IPC stream — int/utf8/double/bool with nulls" {
    const d = try decode(flat);
    defer freeDecode(d);
    try testing.expectEqual(@as(usize, 4), d.units);
    try testing.expect(contains(d.text, "id name score flag"));
    try testing.expect(contains(d.text, "1 alice 1.5 true"));
    try testing.expect(contains(d.text, "2 bob 2.5 false"));
    try testing.expect(contains(d.text, "3 carol 3.5 true"));
    try testing.expect(contains(d.text, "\n4   \n")); // trailing all-null row
}

test "arrow: 1000-row batch (id + repeated strings)" {
    const d = try decode(big);
    defer freeDecode(d);
    try testing.expectEqual(@as(usize, 1000), d.units);
    try testing.expect(contains(d.text, "id color"));
    try testing.expect(contains(d.text, "red"));
    try testing.expect(contains(d.text, "green"));
    try testing.expect(contains(d.text, "blue"));
    try testing.expect(contains(d.text, "\n0 red\n"));
}

test "fuzz: arrow.toText never panics on random/truncated bytes" {
    var prng = std.Random.DefaultPrng.init(0xA770);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for (0..1000) |_| {
        const n = rnd.intRangeLessThan(usize, 0, buf.len);
        for (buf[0..n]) |*b| b.* = rnd.int(u8);
        // Bias half the cases to look like a stream so the message loop runs.
        if (rnd.boolean() and n >= 4) std.mem.writeInt(u32, buf[0..4], 0xFFFFFFFF, .little);
        _ = arrow.toText(arena.allocator(), buf[0..n]) catch {};
        _ = arena.reset(.retain_capacity);
    }
}
