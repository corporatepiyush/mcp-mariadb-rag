//! Legacy Microsoft Word `.doc` (OLE2 / Compound File Binary) reader — scaffold.
//!
//! Status: container header validation implemented; the WordDocument stream +
//! piece-table decode is a tracked follow-up.
//!
//! A `.doc` is an OLE2/CFB compound file: a 512-byte header, a FAT of sector
//! chains, a directory of named streams, and the text living in the
//! `WordDocument` stream addressed through the FIB's piece table (in the
//! `0Table`/`1Table` stream). Recovering clean text means walking the FAT,
//! finding those streams, and applying the piece table — substantial, and it
//! belongs here as native Zig (Agent.md), not as a shell-out to antiword/catdoc.
//!
//! What works today: validating the CFB signature and reading the header's
//! sector-size shift, the foundation the FAT walker will use. `toText` reports
//! the pending status rather than guessing.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ NotCfb, Truncated, Pending, OutOfMemory };

pub const signature = [_]u8{ 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1 };

pub const Header = struct {
    sector_size: usize, // 1 << sector_shift
    mini_sector_size: usize,
    fat_sector_count: u32,
    dir_first_sector: u32,
};

/// Validate the CFB header and read the geometry the FAT walker needs.
pub fn readHeader(bytes: []const u8) Error!Header {
    if (bytes.len < 512) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..8], &signature)) return error.NotCfb;
    const sector_shift = std.mem.readInt(u16, bytes[30..32], .little);
    const mini_shift = std.mem.readInt(u16, bytes[32..34], .little);
    if (sector_shift < 7 or sector_shift > 16) return error.Truncated; // 128B..64KB
    if (mini_shift < 2 or mini_shift > sector_shift) return error.Truncated;
    return .{
        .sector_size = @as(usize, 1) << @intCast(sector_shift),
        .mini_sector_size = @as(usize, 1) << @intCast(mini_shift),
        .fat_sector_count = std.mem.readInt(u32, bytes[44..48], .little),
        .dir_first_sector = std.mem.readInt(u32, bytes[48..52], .little),
    };
}

pub const Result = struct { text: []u8, units: usize };

pub fn toText(a: Allocator, bytes: []const u8) Error!Result {
    _ = a;
    _ = try readHeader(bytes); // validate container; honest error on garbage
    return error.Pending;
}

// ── Tests ─────────────────────────────────────────────────────────────
const testing = std.testing;

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
