//! Tests for src/doc/mod.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/doc/mod.zig");

const Format = srcmod.Format;
const extract = srcmod.extract;

// ── Tests ─────────────────────────────────────────────────────────────

test "extract dispatches by detected format" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const csv = try extract(a, "a,b\n1,2\n", null);
    try testing.expectEqual(Format.csv, csv.format);
    try testing.expectEqualStrings("a b\n1 2\n", csv.text);

    const js = try extract(a, "{\"k\":\"v\"}", null);
    try testing.expectEqual(Format.json, js.format);
    try testing.expectEqualStrings("k v", js.text);

    const txt = try extract(a, "plain prose", null);
    try testing.expectEqual(Format.text, txt.format);
}

test "extract reports pending for parquet" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [17]u8 = undefined;
    @memcpy(buf[0..4], "PAR1");
    @memset(buf[4..9], 'M');
    std.mem.writeInt(u32, buf[9..13], 5, .little);
    @memcpy(buf[13..17], "PAR1");
    try testing.expectError(error.Pending, extract(arena.allocator(), &buf, null));
}

test "fuzz: extract never panics on random bytes" {
    var prng = std.Random.DefaultPrng.init(0xE47AC7);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;
    for (0..2000) |_| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const n = rnd.intRangeLessThan(usize, 0, buf.len);
        for (buf[0..n]) |*b| b.* = rnd.int(u8);
        _ = extract(arena.allocator(), buf[0..n], null) catch {};
    }
}
