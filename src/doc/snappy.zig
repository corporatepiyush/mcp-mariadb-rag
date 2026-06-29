//! Snappy block-format decompressor (the "raw" framing Parquet uses).
//!
//! Reference: google/snappy `format_description.txt`. A block is a varint of the
//! decompressed length followed by a stream of elements. Each element begins
//! with a tag byte whose low two bits select a kind:
//!
//!   * 00 literal      — length-1 in the upper 6 bits (or in 1..4 trailing
//!                       little-endian bytes when those 6 bits are 60..63),
//!                       followed by that many verbatim bytes.
//!   * 01 copy, 1-byte — len = ((tag>>2)&7)+4, 11-bit offset.
//!   * 10 copy, 2-byte — len = (tag>>2)+1, 16-bit little-endian offset.
//!   * 11 copy, 4-byte — len = (tag>>2)+1, 32-bit little-endian offset.
//!
//! Copies reference already-emitted output and may overlap their source, so the
//! copy loop is intentionally byte-at-a-time. This is the framed Snappy used by
//! Parquet's SNAPPY codec — *not* the streamed/CRC framing.
//!
//! Untrusted-input discipline: the declared length bounds the single output
//! allocation; every literal read and every copy offset/length is validated
//! against the buffers, returning `error.Corrupt` instead of reading or writing
//! out of bounds.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ Corrupt, OutOfMemory };

/// Decompress a Snappy block into a freshly-allocated buffer owned by `a`.
pub fn decode(a: Allocator, src: []const u8) Error![]u8 {
    var ip: usize = 0;

    // Preamble: decompressed length as a varint (max 32-bit per the format).
    var out_len: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        if (ip >= src.len) return error.Corrupt;
        const b = src[ip];
        ip += 1;
        out_len |= @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) break;
        shift += 7;
        if (shift > 32) return error.Corrupt;
    }
    if (out_len > std.math.maxInt(u32)) return error.Corrupt;

    const out = a.alloc(u8, @intCast(out_len)) catch return error.OutOfMemory;
    errdefer a.free(out);
    var op: usize = 0;

    while (ip < src.len) {
        const tag = src[ip];
        ip += 1;
        switch (tag & 0x03) {
            0 => { // literal
                var lit_len: usize = (tag >> 2) + 1;
                if (lit_len > 60) {
                    // 61..64 means (lit_len-60) extra little-endian length bytes.
                    const extra = lit_len - 60;
                    if (ip + extra > src.len) return error.Corrupt;
                    var v: u64 = 0;
                    for (0..extra) |k| v |= @as(u64, src[ip + k]) << @intCast(8 * k);
                    ip += extra;
                    if (v >= std.math.maxInt(u32)) return error.Corrupt;
                    lit_len = @as(usize, @intCast(v)) + 1;
                }
                if (ip + lit_len > src.len) return error.Corrupt;
                if (op + lit_len > out.len) return error.Corrupt;
                @memcpy(out[op..][0..lit_len], src[ip..][0..lit_len]);
                ip += lit_len;
                op += lit_len;
            },
            1 => { // copy with 1-byte offset
                if (ip >= src.len) return error.Corrupt;
                const len: usize = ((tag >> 2) & 0x07) + 4;
                const off: usize = (@as(usize, tag >> 5) << 8) | src[ip];
                ip += 1;
                try copy(out, &op, off, len);
            },
            2 => { // copy with 2-byte offset
                if (ip + 2 > src.len) return error.Corrupt;
                const len: usize = (tag >> 2) + 1;
                const off: usize = std.mem.readInt(u16, src[ip..][0..2], .little);
                ip += 2;
                try copy(out, &op, off, len);
            },
            3 => { // copy with 4-byte offset
                if (ip + 4 > src.len) return error.Corrupt;
                const len: usize = (tag >> 2) + 1;
                const off: usize = std.mem.readInt(u32, src[ip..][0..4], .little);
                ip += 4;
                try copy(out, &op, off, len);
            },
            else => unreachable,
        }
    }
    if (op != out.len) return error.Corrupt; // declared length must be exact
    return out;
}

/// Back-reference copy. `off` is the distance behind the write head; the copy
/// may overlap (e.g. RLE-style runs), so it proceeds one byte at a time.
fn copy(out: []u8, op: *usize, off: usize, len: usize) Error!void {
    if (off == 0 or off > op.*) return error.Corrupt; // must point into emitted output
    if (op.* + len > out.len) return error.Corrupt;
    var src_i = op.* - off;
    var dst_i = op.*;
    var n = len;
    while (n > 0) : (n -= 1) {
        out[dst_i] = out[src_i];
        dst_i += 1;
        src_i += 1;
    }
    op.* += len;
}
