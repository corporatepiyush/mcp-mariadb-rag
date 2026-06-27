//! Vector quantization — the highest-leverage screw on the scaling (memory) axis.
//!
//! A stored embedding's dominant cost is `D · bytes-per-component`. Quantization
//! moves that by 4×–48× with bounded recall loss (see PLAN.md §2):
//!
//!   scheme   bytes/comp   D=384 bytes/vector   recall@10 vs f32
//!   f32      4            1536                 baseline
//!   f16      2            768                  ~0.999
//!   int8     1            384                  ~0.98   (per-vector symmetric scale)
//!   binary   0.125        48                   ~0.92   (sign bits + exact rerank)
//!
//! Every encoded blob is **self-describing**: a 5-byte header carries the scheme
//! tag and the dimensionality, so a corpus can mix schemes during a migration and
//! a reader never needs out-of-band metadata. The header is:
//!
//!     [0]      scheme tag  (u8, `Scheme`)
//!     [1..5]   dims        (u32, little-endian)
//!     [5..]    payload     (scheme-specific, see `encode`)
//!
//! This module is pure (no allocator state, no DB) so it is unit- and
//! fuzz-testable in isolation. The matching distance kernels that consume the
//! int8 / binary payloads live in `rag/fusion.zig` (`cosineSimilarityI8`,
//! `hammingDistance`) next to their f32 siblings.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const header_len = 5;

pub const QuantError = error{ InvalidBlob, BadDim, UnknownScheme, BufferTooSmall };

pub const Scheme = enum(u8) {
    f32 = 0,
    f16 = 1,
    int8 = 2,
    binary = 3,

    pub fn parse(s: ?[]const u8) Scheme {
        const str = s orelse return .f32;
        if (std.ascii.eqlIgnoreCase(str, "f16")) return .f16;
        if (std.ascii.eqlIgnoreCase(str, "int8")) return .int8;
        if (std.ascii.eqlIgnoreCase(str, "binary")) return .binary;
        return .f32;
    }

    pub fn name(self: Scheme) []const u8 {
        return switch (self) {
            .f32 => "f32",
            .f16 => "f16",
            .int8 => "int8",
            .binary => "binary",
        };
    }
};

/// Bytes the payload occupies for `dims` components under `scheme` (header
/// excluded). `binary` packs 8 sign bits per byte; `int8` prefixes a 4-byte
/// per-vector scale.
pub fn payloadLen(scheme: Scheme, dims: usize) usize {
    return switch (scheme) {
        .f32 => dims * @sizeOf(f32),
        .f16 => dims * @sizeOf(f16),
        .int8 => @sizeOf(f32) + dims, // scale + one i8 per component
        .binary => (dims + 7) / 8,
    };
}

/// Total encoded blob length (header + payload).
pub fn encodedLen(scheme: Scheme, dims: usize) usize {
    return header_len + payloadLen(scheme, dims);
}

pub fn writeHeader(dst: []u8, scheme: Scheme, dims: usize) void {
    dst[0] = @intFromEnum(scheme);
    std.mem.writeInt(u32, dst[1..5], @intCast(dims), .little);
}

/// Encode `vec` into `dst` (which must be at least `encodedLen(scheme, vec.len)`).
/// Returns the exact written slice. No allocation; `dst` may be a stack buffer.
pub fn encode(dst: []u8, scheme: Scheme, vec: []const f32) QuantError![]u8 {
    const total = encodedLen(scheme, vec.len);
    if (dst.len < total) return error.BufferTooSmall;
    writeHeader(dst, scheme, vec.len);
    const payload = dst[header_len..total];

    switch (scheme) {
        .f32 => @memcpy(payload, std.mem.sliceAsBytes(vec)),
        .f16 => {
            for (vec, 0..) |x, i| {
                const h: f16 = @floatCast(x);
                std.mem.writeInt(u16, payload[i * 2 ..][0..2], @bitCast(h), .little);
            }
        },
        .int8 => {
            // Symmetric per-vector scale: q = round(x / scale), scale = maxabs/127.
            var maxabs: f32 = 0;
            for (vec) |x| maxabs = @max(maxabs, @abs(x));
            const scale: f32 = if (maxabs == 0) 1.0 else maxabs / 127.0;
            std.mem.writeInt(u32, payload[0..4], @bitCast(scale), .little);
            const q = payload[4..];
            for (vec, 0..) |x, i| {
                const scaled = std.math.clamp(@round(x / scale), -127.0, 127.0);
                q[i] = @bitCast(@as(i8, @intFromFloat(scaled)));
            }
        },
        .binary => {
            @memset(payload, 0);
            // Bit i set iff component i >= 0 (LSB-first within each byte).
            for (vec, 0..) |x, i| {
                if (x >= 0) payload[i / 8] |= (@as(u8, 1) << @intCast(i % 8));
            }
        },
    }
    return dst[0..total];
}

/// Allocate and encode — the convenience path for the storage layer.
pub fn encodeAlloc(allocator: Allocator, scheme: Scheme, vec: []const f32) ![]u8 {
    const dst = try allocator.alloc(u8, encodedLen(scheme, vec.len));
    errdefer allocator.free(dst);
    return encode(dst, scheme, vec) catch unreachable; // dst sized exactly
}

pub fn schemeOf(blob: []const u8) QuantError!Scheme {
    if (blob.len < header_len) return error.InvalidBlob;
    return switch (blob[0]) {
        @intFromEnum(Scheme.f32) => .f32,
        @intFromEnum(Scheme.f16) => .f16,
        @intFromEnum(Scheme.int8) => .int8,
        @intFromEnum(Scheme.binary) => .binary,
        else => error.UnknownScheme,
    };
}

pub fn dimsOf(blob: []const u8) QuantError!usize {
    if (blob.len < header_len) return error.InvalidBlob;
    return std.mem.readInt(u32, blob[1..5], .little);
}

/// Validate the header against the payload length and return the payload slice.
fn payloadOf(blob: []const u8) QuantError![]const u8 {
    const scheme = try schemeOf(blob);
    const dims = try dimsOf(blob);
    const want = encodedLen(scheme, dims);
    if (blob.len < want) return error.InvalidBlob;
    return blob[header_len..want];
}

/// Decode any scheme back to an approximate f32 vector. `binary` reconstructs to
/// ±1 (it carries only sign), so callers that need accuracy must rerank with the
/// exact f32/f16 vectors — the "binary + rerank" pattern.
pub fn decodeAlloc(allocator: Allocator, blob: []const u8) ![]f32 {
    const scheme = try schemeOf(blob);
    const dims = try dimsOf(blob);
    const payload = try payloadOf(blob);
    const out = try allocator.alloc(f32, dims);
    errdefer allocator.free(out);

    switch (scheme) {
        .f32 => @memcpy(std.mem.sliceAsBytes(out), payload),
        .f16 => {
            for (out, 0..) |*o, i| {
                const bits = std.mem.readInt(u16, payload[i * 2 ..][0..2], .little);
                const h: f16 = @bitCast(bits);
                o.* = @floatCast(h);
            }
        },
        .int8 => {
            const scale: f32 = @bitCast(std.mem.readInt(u32, payload[0..4], .little));
            const q = payload[4..];
            for (out, 0..) |*o, i| {
                const v: i8 = @bitCast(q[i]);
                o.* = @as(f32, @floatFromInt(v)) * scale;
            }
        },
        .binary => {
            for (out, 0..) |*o, i| {
                const bit = (payload[i / 8] >> @intCast(i % 8)) & 1;
                o.* = if (bit == 1) 1.0 else -1.0;
            }
        },
    }
    return out;
}

/// Borrow the int8 payload without decoding: the per-vector scale and the raw
/// `[]const i8` quanta, for the `cosineSimilarityI8` fast path.
pub const Int8View = struct { scale: f32, q: []const i8 };

pub fn int8View(blob: []const u8) QuantError!Int8View {
    if (try schemeOf(blob) != .int8) return error.InvalidBlob;
    const payload = try payloadOf(blob);
    const scale: f32 = @bitCast(std.mem.readInt(u32, payload[0..4], .little));
    return .{ .scale = scale, .q = @ptrCast(payload[4..]) };
}

/// Borrow the packed sign-bit payload for the `hammingDistance` fast path.
pub fn binaryView(blob: []const u8) QuantError![]const u8 {
    if (try schemeOf(blob) != .binary) return error.InvalidBlob;
    return payloadOf(blob);
}
