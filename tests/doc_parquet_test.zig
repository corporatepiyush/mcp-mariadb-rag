//! Tests for src/doc/parquet.zig (moved out of src; src holds code only).
//!
//! The fixtures under tests/fixtures/*.parquet are real files written by DuckDB
//! (`COPY … TO … (FORMAT PARQUET …)`), so these are genuine round-trip tests
//! against another implementation's output, not against a hand-rolled encoder.

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/doc/parquet.zig");

const locateFooter = srcmod.locateFooter;
const magic = srcmod.magic;
const toText = srcmod.toText;
const rleHybrid = srcmod.rleHybrid;
const deltaBinaryPacked = srcmod.deltaBinaryPacked;

fn contains(h: []const u8, n: []const u8) bool {
    return std.mem.indexOf(u8, h, n) != null;
}

/// Decode a fixture with an arena (toText makes many small allocations).
fn decode(bytes: []const u8) !struct { text: []u8, units: usize, arena: *std.heap.ArenaAllocator } {
    const arena = try testing.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(testing.allocator);
    const r = try toText(arena.allocator(), bytes);
    return .{ .text = r.text, .units = r.units, .arena = arena };
}

fn freeDecode(d: anytype) void {
    d.arena.deinit();
    testing.allocator.destroy(d.arena);
}

// ── Framing ────────────────────────────────────────────────────────────

test "parquet: rejects non-parquet" {
    try testing.expectError(error.NotParquet, locateFooter("not a parquet file!!"));
    try testing.expectError(error.NotParquet, locateFooter("PAR1"));
}

test "parquet: malformed metadata is reported, not mis-parsed" {
    var buf: [17]u8 = undefined;
    @memcpy(buf[0..4], magic);
    @memcpy(buf[4..9], "MMMMM");
    std.mem.writeInt(u32, buf[9..13], 5, .little);
    @memcpy(buf[13..17], magic);
    try testing.expectError(error.Corrupt, toText(testing.allocator, &buf));
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

test "fuzz: parquet toText never panics on framed garbage" {
    var prng = std.Random.DefaultPrng.init(0x6A22);
    const rnd = prng.random();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [128]u8 = undefined;
    for (0..2000) |_| {
        const n = rnd.intRangeAtMost(usize, 12, buf.len);
        for (buf[0..n]) |*b| b.* = rnd.int(u8);
        // Plant valid PAR1 framing + a plausible footer length so the metadata
        // parser is actually entered on hostile bytes.
        @memcpy(buf[0..4], "PAR1");
        @memcpy(buf[n - 4 .. n], "PAR1");
        std.mem.writeInt(u32, buf[n - 8 ..][0..4], rnd.intRangeAtMost(u32, 0, @intCast(n)), .little);
        _ = toText(arena.allocator(), buf[0..n]) catch {};
        _ = arena.reset(.retain_capacity);
    }
}

// ── Real DuckDB files: flat table, every codec ─────────────────────────

const flat_uncompressed = @embedFile("fixtures/flat_uncompressed.parquet");
const flat_snappy = @embedFile("fixtures/flat_snappy.parquet");
const flat_gzip = @embedFile("fixtures/flat_gzip.parquet");
const flat_zstd = @embedFile("fixtures/flat_zstd.parquet");
const dict_file = @embedFile("fixtures/dict.parquet");
const types_file = @embedFile("fixtures/types.parquet");

/// id BIGINT, name UTF8, score DOUBLE, flag BOOLEAN — with a trailing all-null
/// row to exercise definition levels.
fn checkFlat(bytes: []const u8) !void {
    const d = try decode(bytes);
    defer freeDecode(d);
    try testing.expectEqual(@as(usize, 4), d.units); // 4 data rows
    try testing.expect(contains(d.text, "id name score flag")); // header
    try testing.expect(contains(d.text, "1 alice 1.5 true"));
    try testing.expect(contains(d.text, "2 bob 2.5 false"));
    try testing.expect(contains(d.text, "3 carol 3.5 true"));
    // Null row: id present (4), the rest empty → "4   \n".
    try testing.expect(contains(d.text, "\n4   \n"));
}

test "parquet: flat table, UNCOMPRESSED + PLAIN" {
    try checkFlat(flat_uncompressed);
}

test "parquet: flat table, SNAPPY" {
    try checkFlat(flat_snappy);
}

test "parquet: flat table, GZIP" {
    try checkFlat(flat_gzip);
}

test "parquet: ZSTD codec is reported as unsupported, not mis-decoded" {
    // toText is arena-contracted (mod.zig passes the request arena); transient
    // allocations on the error path are reclaimed by the arena.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.Unsupported, toText(arena.allocator(), flat_zstd));
}

test "parquet: dictionary encoding over many rows" {
    const d = try decode(dict_file);
    defer freeDecode(d);
    try testing.expectEqual(@as(usize, 1000), d.units);
    try testing.expect(contains(d.text, "id color"));
    try testing.expect(contains(d.text, "red"));
    try testing.expect(contains(d.text, "green"));
    try testing.expect(contains(d.text, "blue"));
    // First data row: i=0 → id 0, color 'red'.
    try testing.expect(contains(d.text, "\n0 red\n"));
}

// ── Encoding primitives (golden vectors, since DuckDB only emits PLAIN/dict) ──

test "parquet: RLE/bit-packed hybrid — RLE run" {
    // header (3<<1)|0 = 0x06 → run of 3; bit_width 8 → 1 value byte 0x05.
    var out: [3]u32 = undefined;
    try rleHybrid(&[_]u8{ 0x06, 0x05 }, 8, 3, &out);
    try testing.expectEqualSlices(u32, &[_]u32{ 5, 5, 5 }, &out);
}

test "parquet: RLE/bit-packed hybrid — bit-packed run" {
    // header (1<<1)|1 = 0x03 → 1 group of 8; bit_width 2; values 1,2,3 packed
    // LSB-first into 0b00_11_10_01 = 0x39, second byte 0.
    var out: [3]u32 = undefined;
    try rleHybrid(&[_]u8{ 0x03, 0x39, 0x00 }, 2, 3, &out);
    try testing.expectEqualSlices(u32, &[_]u32{ 1, 2, 3 }, &out);
}

test "parquet: DELTA_BINARY_PACKED decodes a delta sequence" {
    // block_size=128, miniblocks=4, total=5, first=zigzag(1)=2; one block with
    // min_delta=zigzag(1)=2 and four width-0 miniblocks → deltas all 1 → 1..5.
    const stream = [_]u8{ 0x80, 0x01, 0x04, 0x05, 0x02, 0x02, 0x00, 0x00, 0x00, 0x00 };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const vals = try deltaBinaryPacked(arena.allocator(), &stream, 5);
    try testing.expectEqualSlices(i64, &[_]i64{ 1, 2, 3, 4, 5 }, vals);
}

test "parquet: converted types — decimal, date, timestamp, int" {
    const d = try decode(types_file);
    defer freeDecode(d);
    try testing.expectEqual(@as(usize, 1), d.units);
    try testing.expect(contains(d.text, "amount d ts n"));
    try testing.expect(contains(d.text, "12.34")); // DECIMAL(5,2), unscaled 1234
    try testing.expect(contains(d.text, "2021-03-15")); // DATE
    try testing.expect(contains(d.text, "2021-03-15T12:30:45.000000000")); // TIMESTAMP_MICROS
    try testing.expect(contains(d.text, " 42")); // INT_32
}
