//! Tests for src/doc/snappy.zig (Snappy block decompressor).

const std = @import("std");
const testing = std.testing;
const snappy = @import("../src/doc/snappy.zig");

test "snappy: all-literal block" {
    // preamble len=5; literal tag (len-1)<<2 = 0x10; then "hello".
    const block = [_]u8{ 0x05, 0x10, 'h', 'e', 'l', 'l', 'o' };
    const out = try snappy.decode(testing.allocator, &block);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello", out);
}

test "snappy: literal + back-reference copy (overlapping run)" {
    // len=8; literal 'a'; then 1-byte-offset copy: len 7, offset 1 → "aaaaaaaa".
    // copy tag: type=01, len=7 → ((7-4)<<2)|1 = 0x0D, offset low byte = 0x01.
    const block = [_]u8{ 0x08, 0x00, 'a', 0x0D, 0x01 };
    const out = try snappy.decode(testing.allocator, &block);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("aaaaaaaa", out);
}

test "snappy: 2-byte offset copy" {
    // "abcd" then copy len=4 offset=4 → "abcdabcd".
    // literal len 4: tag (4-1)<<2 = 0x0C; copy type=10 len=4 → ((4-1)<<2)|2 = 0x0E,
    // offset 4 as u16 LE = 04 00.
    const block = [_]u8{ 0x08, 0x0C, 'a', 'b', 'c', 'd', 0x0E, 0x04, 0x00 };
    const out = try snappy.decode(testing.allocator, &block);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("abcdabcd", out);
}

test "snappy: truncated/garbage never panics, errors cleanly" {
    try testing.expectError(error.Corrupt, snappy.decode(testing.allocator, &[_]u8{ 0x08, 0x00 })); // claims 8, gives 0
    var prng = std.Random.DefaultPrng.init(0x5AFE);
    const rnd = prng.random();
    var buf: [64]u8 = undefined;
    for (0..2000) |_| {
        const n = rnd.intRangeLessThan(usize, 0, buf.len);
        for (buf[0..n]) |*b| b.* = rnd.int(u8);
        if (snappy.decode(testing.allocator, buf[0..n])) |out| {
            testing.allocator.free(out);
        } else |_| {}
    }
}
