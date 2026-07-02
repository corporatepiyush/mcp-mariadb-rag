//! PDF stream filters (PDF 32000-1:2008, §7.4) — the decode side only.
//!
//! A PDF stream's `/Filter` may chain several decoders (e.g.
//! `[/ASCII85Decode /FlateDecode]`); each is applied in order. This implements
//! the text-relevant filters natively: ASCIIHexDecode, ASCII85Decode,
//! RunLengthDecode, LZWDecode, and FlateDecode (via ../inflate). Image-only
//! filters (DCTDecode/CCITTFax/JBIG2/JPX) are not text and are reported
//! `Unsupported` so the caller can fall back to the raw bytes.
//!
//! Untrusted-input discipline: every decoder is bounds-checked, allocates only
//! from the caller's arena, and caps its output so a small but adversarial
//! stream (e.g. an LZW bomb) cannot expand without limit.

const std = @import("std");
const Allocator = std.mem.Allocator;
const inflate = @import("inflate.zig");

pub const Error = error{ OutOfMemory, Corrupt, Unsupported };

/// Hard ceiling on a single filter's output, so a decompression bomb can't
/// exhaust memory. 256 MiB matches the document-extraction input cap.
pub const max_output = 256 * 1024 * 1024;

pub const Filter = enum { flate, lzw, ascii85, asciihex, runlength, unsupported };

pub fn filterFromName(name: []const u8) Filter {
    if (eq(name, "FlateDecode") or eq(name, "Fl")) return .flate;
    if (eq(name, "LZWDecode") or eq(name, "LZW")) return .lzw;
    if (eq(name, "ASCII85Decode") or eq(name, "A85")) return .ascii85;
    if (eq(name, "ASCIIHexDecode") or eq(name, "AHx")) return .asciihex;
    if (eq(name, "RunLengthDecode") or eq(name, "RL")) return .runlength;
    return .unsupported;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Decode `data` through one filter. The result is owned by `a` (or, for the
/// identity/`unsupported` fallthrough, the caller decides).
pub fn decode(a: Allocator, filter: Filter, data: []const u8) Error![]u8 {
    return switch (filter) {
        .flate => flate(a, data),
        .lzw => lzw(a, data),
        .ascii85 => ascii85(a, data),
        .asciihex => asciihex(a, data),
        .runlength => runlength(a, data),
        .unsupported => error.Unsupported,
    };
}

fn flate(a: Allocator, data: []const u8) Error![]u8 {
    // PDF FlateDecode is zlib-wrapped; fall back to raw DEFLATE for producers
    // that omit the 2-byte header.
    if (inflate.zlib(a, data, data.len * 4)) |out| return out else |_| {}
    return inflate.raw(a, data, data.len * 4) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Corrupt,
    };
}

fn asciihex(a: Allocator, data: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var hi: ?u8 = null;
    for (data) |c| {
        if (c == '>') break; // EOD
        const v = hexVal(c) orelse continue; // skip whitespace / junk
        if (hi) |h| {
            try out.append(a, (h << 4) | v);
            hi = null;
        } else hi = v;
    }
    if (hi) |h| try out.append(a, h << 4); // odd trailing digit
    return out.toOwnedSlice(a);
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn ascii85(a: Allocator, data: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var tuple: [5]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    // Skip an optional "<~" introducer.
    if (data.len >= 2 and data[0] == '<' and data[1] == '~') i = 2;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (c == '~') break; // "~>" EOD
        if (std.ascii.isWhitespace(c)) continue;
        if (c == 'z' and n == 0) {
            try out.appendSlice(a, &[_]u8{ 0, 0, 0, 0 });
            continue;
        }
        if (c < '!' or c > 'u') return error.Corrupt;
        tuple[n] = c - '!';
        n += 1;
        if (n == 5) {
            var v: u32 = 0;
            for (tuple) |t| v = v *% 85 +% t;
            try out.appendSlice(a, &[_]u8{
                @truncate(v >> 24), @truncate(v >> 16), @truncate(v >> 8), @truncate(v),
            });
            n = 0;
        }
        if (out.items.len > max_output) return error.Corrupt;
    }
    if (n > 0) {
        // Final partial group of n chars decodes to n-1 bytes; pad with 'u'.
        if (n == 1) return error.Corrupt;
        for (n..5) |k| tuple[k] = 84; // 'u' - '!'
        var v: u32 = 0;
        for (tuple) |t| v = v *% 85 +% t;
        const bytes = [_]u8{ @truncate(v >> 24), @truncate(v >> 16), @truncate(v >> 8), @truncate(v) };
        try out.appendSlice(a, bytes[0 .. n - 1]);
    }
    return out.toOwnedSlice(a);
}

fn runlength(a: Allocator, data: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < data.len) {
        const len = data[i];
        i += 1;
        if (len == 128) break; // EOD
        if (len < 128) {
            const count: usize = @as(usize, len) + 1;
            if (i + count > data.len) return error.Corrupt;
            try out.appendSlice(a, data[i .. i + count]);
            i += count;
        } else {
            const count: usize = 257 - @as(usize, len);
            if (i >= data.len) return error.Corrupt;
            try out.appendNTimes(a, data[i], count);
            i += 1;
        }
        if (out.items.len > max_output) return error.Corrupt;
    }
    return out.toOwnedSlice(a);
}

/// LZWDecode with variable 9–12-bit MSB-first codes and the default
/// EarlyChange=1 behaviour (PDF 32000-1 §7.4.4.2 + the TIFF LZW algorithm).
fn lzw(a: Allocator, data: []const u8) Error![]u8 {
    const clear_code = 256;
    const eod_code = 257;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);

    // Dictionary: each entry is a byte string. Entries 0..255 are single bytes;
    // 256/257 are control codes; 258+ are built during decode.
    var dict: std.ArrayList([]u8) = .empty;
    defer {
        for (dict.items) |e| a.free(e);
        dict.deinit(a);
    }
    const resetDict = struct {
        fn run(al: Allocator, d: *std.ArrayList([]u8)) Error!void {
            for (d.items) |e| al.free(e);
            d.clearRetainingCapacity();
            var b: u16 = 0;
            while (b < 258) : (b += 1) {
                const e = al.alloc(u8, if (b < 256) 1 else 0) catch return error.OutOfMemory;
                if (b < 256) e[0] = @truncate(b);
                d.append(al, e) catch return error.OutOfMemory;
            }
        }
    }.run;

    try resetDict(a, &dict);
    var code_width: u5 = 9;
    var bit_buf: u32 = 0;
    var bits: u5 = 0;
    var prev: ?usize = null;
    var byte_i: usize = 0;

    while (true) {
        // Refill the bit buffer MSB-first until we have a full code.
        while (bits < code_width) {
            if (byte_i >= data.len) return out.toOwnedSlice(a); // input exhausted
            bit_buf = (bit_buf << 8) | data[byte_i];
            byte_i += 1;
            bits += 8;
        }
        const code: usize = (bit_buf >> @intCast(bits - code_width)) & ((@as(u32, 1) << code_width) - 1);
        bits -= code_width;

        if (code == eod_code) break;
        if (code == clear_code) {
            try resetDict(a, &dict);
            code_width = 9;
            prev = null;
            continue;
        }

        var entry: []const u8 = undefined;
        if (code < dict.items.len) {
            entry = dict.items[code];
        } else if (code == dict.items.len and prev != null) {
            // KwKwK case: prev entry + its own first byte.
            const p = dict.items[prev.?];
            const tmp = try a.alloc(u8, p.len + 1);
            @memcpy(tmp[0..p.len], p);
            tmp[p.len] = p[0];
            entry = tmp;
            dict.append(a, tmp) catch return error.OutOfMemory;
            prev = code;
            try out.appendSlice(a, entry);
            if (out.items.len > max_output) return error.Corrupt;
            widen(&code_width, dict.items.len);
            continue;
        } else return error.Corrupt;

        try out.appendSlice(a, entry);
        if (out.items.len > max_output) return error.Corrupt;

        if (prev) |pidx| {
            // Add prev + first byte of current entry to the dictionary.
            const p = dict.items[pidx];
            const ne = try a.alloc(u8, p.len + 1);
            @memcpy(ne[0..p.len], p);
            ne[p.len] = entry[0];
            dict.append(a, ne) catch return error.OutOfMemory;
        }
        prev = code;
        widen(&code_width, dict.items.len);
    }
    return out.toOwnedSlice(a);
}

/// Grow the code width as the dictionary fills (EarlyChange=1: switch one code
/// before the boundary).
fn widen(code_width: *u5, dict_len: usize) void {
    if (dict_len + 1 >= (@as(usize, 1) << code_width.*) and code_width.* < 12) {
        code_width.* += 1;
    }
}
