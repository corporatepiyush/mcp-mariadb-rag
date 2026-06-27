//! Tests for src/doc/inflate.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/doc/inflate.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const flate = srcmod.flate;
const raw = srcmod.raw;
const zlib = srcmod.zlib;

test "inflate raw round-trips" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plain = "The quick brown fox jumps over the lazy dog. " ** 50;
    const comp = try compressRaw(a, plain);
    const out = try raw(a, comp, plain.len);
    try testing.expectEqualStrings(plain, out);
}

test "inflate raw on empty input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const comp = try compressRaw(a, "");
    const out = try raw(a, comp, 0);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "zlib header validation rejects bad streams with CorruptStream (no panic)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Too short, wrong compression method, bad FCHECK, and FDICT-set are all
    // rejected by our own header parse before any byte reaches the std decoder.
    try testing.expectError(error.CorruptStream, zlib(a, "", 0));
    try testing.expectError(error.CorruptStream, zlib(a, &.{0x78}, 0));
    try testing.expectError(error.CorruptStream, zlib(a, &.{ 0x07, 0x00 }, 0)); // CM != 8
    try testing.expectError(error.CorruptStream, zlib(a, &.{ 0x78, 0x9d }, 0)); // FCHECK fails
    try testing.expectError(error.CorruptStream, zlib(a, &.{ 0x78, 0xbb }, 0)); // FDICT set
}

test "zlib round-trips real data through the raw path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plain = "the quick brown fox jumps over the lazy dog" ** 4;
    // Build a real zlib stream: header + raw DEFLATE + (ignored) adler32.
    const deflated = try compressRaw(a, plain);
    var stream = try a.alloc(u8, 2 + deflated.len + 4);
    stream[0] = 0x78;
    stream[1] = 0x9c;
    @memcpy(stream[2 .. 2 + deflated.len], deflated);
    @memset(stream[2 + deflated.len ..], 0); // dummy adler32 — ignored
    const out = try zlib(a, stream, 0);
    try testing.expectEqualStrings(plain, out);
}

// NOTE: a "feed arbitrary bytes, never panic" fuzz test is intentionally absent.
// std.compress.flate's DEFLATE decoder `assert`s (an un-catchable panic in
// Debug/ReleaseSafe, UB in ReleaseFast) on certain malformed streams, so no
// caller can guarantee no-panic on adversarial compressed input. We harden what
// we own — the zlib header parse above rejects bad headers before the decoder —
// but the inner-block limitation is the std decoder's. Inputs reach it only via
// trusted-ish document extraction (zip/pdf); a hardened decoder or process
// isolation would be needed to fully contain malformed-DEFLATE input.

// ---- helpers moved from src ----
/// Round-trip via the std compressor so the test data is real DEFLATE.
/// The output writer needs a non-trivial backing buffer (Compress.init asserts
/// `output.buffer.len > 8`), so allocate capacity up front.
pub fn compressRaw(a: Allocator, plain: []const u8) ![]u8 {
    var aw = try Writer.Allocating.initCapacity(a, 4096);
    errdefer aw.deinit();
    var window: [flate.max_window_len]u8 = undefined;
    var comp: flate.Compress = try .init(&aw.writer, &window, .raw, .default);
    try comp.writer.writeAll(plain);
    try comp.finish();
    return aw.toOwnedSlice();
}
