//! Tests for src/doc/doc.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/doc/doc.zig");

const readHeader = srcmod.readHeader;
const signature = srcmod.signature;
const toText = srcmod.toText;

// ── Tests ─────────────────────────────────────────────────────────────

test "legacy_doc: reads CFB header geometry" {
    var buf: [512]u8 = [_]u8{0} ** 512;
    @memcpy(buf[0..8], &signature);
    std.mem.writeInt(u16, buf[30..32], 9, .little); // 512-byte sectors
    std.mem.writeInt(u16, buf[32..34], 6, .little); // 64-byte mini sectors
    std.mem.writeInt(u32, buf[44..48], 1, .little);
    std.mem.writeInt(u32, buf[48..52], 2, .little);
    const h = try readHeader(&buf);
    try testing.expectEqual(@as(usize, 512), h.sector_size);
    try testing.expectEqual(@as(usize, 64), h.mini_sector_size);
    try testing.expectEqual(@as(u32, 2), h.dir_first_sector);
    try testing.expectError(error.Pending, toText(testing.allocator, &buf));
}

test "legacy_doc: rejects non-CFB" {
    var buf: [512]u8 = [_]u8{0} ** 512;
    @memcpy(buf[0..5], "%PDF-");
    try testing.expectError(error.NotCfb, readHeader(&buf));
}

test "fuzz: legacy_doc readHeader never panics" {
    var prng = std.Random.DefaultPrng.init(0xD0C5);
    const rnd = prng.random();
    var buf: [600]u8 = undefined;
    for (0..1000) |_| {
        const n = rnd.intRangeLessThan(usize, 0, buf.len);
        for (buf[0..n]) |*b| b.* = rnd.int(u8);
        _ = readHeader(buf[0..n]) catch {};
    }
}
