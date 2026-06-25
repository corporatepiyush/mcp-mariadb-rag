//! DEFLATE / zlib decompression.
//!
//! Backed by `std.compress.flate.Decompress` — native Zig, zero C, streaming.
//! Per Agent.md's dependency rule ("read the full source; every dependency must
//! be compatible — no hidden allocs, zero-copy where possible, explicit error
//! handling"), the std flate decoder qualifies: it takes a caller-owned window
//! buffer (we own the 64 KiB history here, on the stack), reads from a caller
//! `Reader`, and surfaces errors explicitly. No external/C compression library
//! enters the build — we keep full control of the window and the output buffer.

const std = @import("std");
const flate = std.compress.flate;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Error = error{ OutOfMemory, CorruptStream } || Writer.Error;

/// Decompress a raw DEFLATE (RFC 1951, no header) stream into owned bytes.
/// `cap_hint` pre-sizes the output buffer to avoid resize churn when the
/// uncompressed size is known (e.g. from a ZIP central-directory record).
pub fn raw(a: Allocator, comp: []const u8, cap_hint: usize) Error![]u8 {
    return run(a, comp, .raw, cap_hint);
}

/// Decompress a zlib (RFC 1950, 2-byte header + adler32 footer) stream.
pub fn zlib(a: Allocator, comp: []const u8, cap_hint: usize) Error![]u8 {
    return run(a, comp, .zlib, cap_hint);
}

fn run(a: Allocator, comp: []const u8, container: flate.Container, cap_hint: usize) Error![]u8 {
    var in: std.Io.Reader = .fixed(comp);
    // The window must be >= max_window_len (64 KiB). Stack-resident, no heap.
    var window: [flate.max_window_len]u8 = undefined;
    var dec = flate.Decompress.init(&in, container, &window);

    var aw = Writer.Allocating.init(a);
    errdefer aw.deinit();
    if (cap_hint > 0) aw.ensureUnusedCapacity(cap_hint) catch return error.OutOfMemory;

    _ = dec.reader.streamRemaining(&aw.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return error.CorruptStream,
    };
    return aw.toOwnedSlice() catch error.OutOfMemory;
}

// ── Tests ─────────────────────────────────────────────────────────────
const testing = std.testing;

/// Round-trip via the std compressor so the test data is real DEFLATE.
/// The output writer needs a non-trivial backing buffer (Compress.init asserts
/// `output.buffer.len > 8`), so allocate capacity up front.
fn compressRaw(a: Allocator, plain: []const u8) ![]u8 {
    var aw = try Writer.Allocating.initCapacity(a, 4096);
    errdefer aw.deinit();
    var window: [flate.max_window_len]u8 = undefined;
    var comp: flate.Compress = try .init(&aw.writer, &window, .raw, .default);
    try comp.writer.writeAll(plain);
    try comp.finish();
    return aw.toOwnedSlice();
}

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

test "inflate reports corruption, never panics" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng = std.Random.DefaultPrng.init(0x1F1A7E);
    const rnd = prng.random();
    var buf: [128]u8 = undefined;
    for (0..400) |_| {
        const n = rnd.intRangeLessThan(usize, 0, buf.len);
        for (buf[0..n]) |*b| b.* = rnd.int(u8);
        _ = raw(a, buf[0..n], 0) catch {};
    }
}
