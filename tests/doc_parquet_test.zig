//! Tests for src/doc/parquet.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/doc/parquet.zig");

const locateFooter = srcmod.locateFooter;
const magic = srcmod.magic;
const toText = srcmod.toText;

// ── Tests ─────────────────────────────────────────────────────────────

test "parquet: locate footer of a framed file" {
    // [PAR1][meta(5 bytes)][len=5][PAR1]
    var buf: [17]u8 = undefined;
    @memcpy(buf[0..4], magic);
    @memcpy(buf[4..9], "MMMMM");
    std.mem.writeInt(u32, buf[9..13], 5, .little);
    @memcpy(buf[13..17], magic);
    const f = try locateFooter(&buf);
    try testing.expectEqual(@as(usize, 4), f.metadata_start);
    try testing.expectEqual(@as(u32, 5), f.metadata_len);
    try testing.expectError(error.Pending, toText(testing.allocator, &buf));
}

test "parquet: rejects non-parquet" {
    try testing.expectError(error.NotParquet, locateFooter("not a parquet file!!"));
    try testing.expectError(error.NotParquet, locateFooter("PAR1"));
}

test "fuzz: parquet locateFooter never panics" {
    var prng = std.Random.DefaultPrng.init(0x9A11);
    const rnd = prng.random();
    var buf: [64]u8 = undefined;
    for (0..1000) |_| {
        const n = rnd.intRangeLessThan(usize, 0, buf.len);
        for (buf[0..n]) |*b| b.* = rnd.int(u8);
        _ = locateFooter(buf[0..n]) catch {};
    }
}
