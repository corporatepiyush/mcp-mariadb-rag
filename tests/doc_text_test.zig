//! Tests for src/doc/text.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/doc/text.zig");

const replacement = srcmod.replacement;
const toText = srcmod.toText;

// ── Tests ─────────────────────────────────────────────────────────────

test "text: BOM stripped, CRLF normalized" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try toText(arena.allocator(), "\xEF\xBB\xBFline1\r\nline2\rline3\n");
    try testing.expectEqualStrings("line1\nline2\nline3\n", r.text);
    try testing.expectEqual(@as(usize, 4), r.units);
}

test "text: valid UTF-8 preserved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try toText(arena.allocator(), "caf\u{00E9} \u{2014} \u{1F600}");
    try testing.expectEqualStrings("caf\u{00E9} \u{2014} \u{1F600}", r.text);
}

test "text: invalid bytes become replacement char" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try toText(arena.allocator(), "a\xFFb\x80c");
    try testing.expectEqualStrings("a\u{FFFD}b\u{FFFD}c", r.text);
}

test "fuzz: text normalization never panics" {
    var prng = std.Random.DefaultPrng.init(0x7E47);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;
    for (0..1500) |_| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const n = rnd.intRangeLessThan(usize, 0, buf.len);
        for (buf[0..n]) |*b| b.* = rnd.int(u8);
        const r = try toText(arena.allocator(), buf[0..n]);
        try testing.expect(std.unicode.utf8ValidateSlice(r.text)); // always valid UTF-8 out
    }
}
