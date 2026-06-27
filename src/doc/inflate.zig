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
pub const flate = std.compress.flate;
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
///
/// We parse the header ourselves and decode the embedded raw DEFLATE with the
/// `raw` path rather than std's `.zlib` container: the std zlib decoder
/// `assert`s (panics, un-catchable) on some malformed streams, which a corrupt
/// PDF FlateDecode could otherwise trigger. The `raw` path returns
/// `CorruptStream` on bad input instead. The trailing adler32 is ignored — the
/// DEFLATE end-of-stream marker bounds the output.
pub fn zlib(a: Allocator, comp: []const u8, cap_hint: usize) Error![]u8 {
    if (comp.len < 2) return error.CorruptStream;
    const cmf = comp[0];
    const flg = comp[1];
    if (cmf & 0x0f != 8) return error.CorruptStream; // CM must be DEFLATE
    if ((@as(u16, cmf) << 8 | flg) % 31 != 0) return error.CorruptStream; // FCHECK
    if (flg & 0x20 != 0) return error.CorruptStream; // FDICT (preset dict) unsupported
    return raw(a, comp[2..], cap_hint);
}

fn run(a: Allocator, comp: []const u8, container: flate.Container, cap_hint: usize) Error![]u8 {
    var in: std.Io.Reader = .fixed(comp);
    // The window must be >= max_window_len (64 KiB). Stack-resident, no heap.
    var window: [flate.max_window_len]u8 = undefined;
    var dec = flate.Decompress.init(&in, container, &window);

    // The decoder writes through `aw.writer`, which must have a non-trivial
    // backing buffer — a zero-length buffer trips an assert deep in the std
    // decoder on some streams. Always start with real capacity (and honour the
    // caller's size hint when larger).
    var aw = Writer.Allocating.initCapacity(a, @max(cap_hint, 4096)) catch return error.OutOfMemory;
    errdefer aw.deinit();

    _ = dec.reader.streamRemaining(&aw.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return error.CorruptStream,
    };
    return aw.toOwnedSlice() catch error.OutOfMemory;
}
