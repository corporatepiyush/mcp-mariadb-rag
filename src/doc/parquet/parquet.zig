//! Apache Parquet reader — scaffold.
//!
//! Status: structural validation implemented; column decoding is a tracked
//! follow-up. Parquet is a columnar format framed by the 4-byte magic "PAR1"
//! at both ends; the footer is `[FileMetaData(thrift-compact)][u32 len]["PAR1"]`.
//! Full extraction requires a Thrift-compact reader plus the page encodings
//! (PLAIN, RLE/bit-pack, dictionary) and the page codecs (snappy, gzip, zstd) —
//! all of which will be implemented natively in this module (Agent.md: native,
//! arena-backed, SIMD where the encodings allow), not delegated to libarrow.
//!
//! What works today: detecting a well-formed Parquet file and locating its
//! footer metadata block, so the pipeline gives an honest, bounded answer
//! instead of mis-parsing. `toText` reports the pending status explicitly.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ NotParquet, Truncated, Pending, OutOfMemory };

pub const magic = "PAR1";

pub const Footer = struct {
    /// Byte range of the Thrift-compact FileMetaData within the file.
    metadata_start: usize,
    metadata_len: u32,
};

/// Validate framing and locate the footer metadata. This is the foundation the
/// Thrift reader will build on.
pub fn locateFooter(bytes: []const u8) Error!Footer {
    if (bytes.len < 12) return error.NotParquet; // magic+len+magic minimum
    if (!std.mem.eql(u8, bytes[0..4], magic)) return error.NotParquet;
    if (!std.mem.eql(u8, bytes[bytes.len - 4 ..], magic)) return error.NotParquet;
    const len_off = bytes.len - 8;
    const meta_len = std.mem.readInt(u32, bytes[len_off..][0..4], .little);
    const meta_start = std.math.sub(usize, len_off, meta_len) catch return error.Truncated;
    if (meta_start < 4) return error.Truncated;
    return .{ .metadata_start = meta_start, .metadata_len = meta_len };
}

pub const Result = struct { text: []u8, units: usize };

pub fn toText(a: Allocator, bytes: []const u8) Error!Result {
    _ = a;
    _ = try locateFooter(bytes); // validate framing; honest error on garbage
    return error.Pending;
}

// ── Tests ─────────────────────────────────────────────────────────────
const testing = std.testing;

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
