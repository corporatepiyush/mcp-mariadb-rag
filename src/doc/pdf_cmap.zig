//! PDF `ToUnicode` CMap parser (PDF 32000-1:2008, §9.10.3 + Adobe's
//! "ToUnicode Mapping File Tutorial").
//!
//! A font's `/ToUnicode` stream maps character *codes* (1- or 2-byte, as used in
//! the content stream's show-text operands) to Unicode. Without it, a Type0/CID
//! font's operands are opaque glyph indices and naive extraction yields garbage;
//! with it we recover real text. The grammar we read:
//!
//!   begincodespacerange  <lo> <hi> …  endcodespacerange   (sets the code width)
//!   N beginbfchar  <src> <dstUTF16BE> …  endbfchar
//!   N beginbfrange <lo> <hi> <dstUTF16BE> | [ <d0> <d1> … ]  endbfrange
//!
//! Destinations are UTF-16BE (so surrogate pairs decode to astral codepoints).
//! Ranges are expanded into a `code → UTF-8` map at parse time (bounded), so
//! translation at extract time is a single hash lookup per code.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Cap on expanded entries, so a hostile `bfrange <0000> <FFFFFFFF> …` can't
/// blow up memory.
const max_entries = 1 << 20;

pub const CMap = struct {
    /// Code width in bytes for chunking show-text operands (1 for simple fonts,
    /// 2 for the common Identity-H Type0 case).
    byte_width: u8 = 2,
    map: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,

    /// Translate a show-text operand: split into `byte_width`-byte codes, map
    /// each to its Unicode string, and write the result. Unmapped codes are
    /// skipped (a missing glyph adds nothing rather than garbage).
    pub fn translate(self: *const CMap, w: *Writer, bytes: []const u8) Writer.Error!void {
        const wdt: usize = if (self.byte_width == 0) 1 else self.byte_width;
        var i: usize = 0;
        while (i + wdt <= bytes.len) : (i += wdt) {
            var code: u32 = 0;
            for (0..wdt) |k| code = (code << 8) | bytes[i + k];
            if (self.map.get(code)) |u| try w.writeAll(u);
        }
    }

    pub fn count(self: *const CMap) usize {
        return self.map.count();
    }
};

/// Parse a decoded ToUnicode CMap. All allocations are from `a` (an arena).
pub fn parse(a: Allocator, src: []const u8) Allocator.Error!CMap {
    var cmap: CMap = .{};

    // Code width from the first codespacerange entry (token length / 2 bytes).
    if (std.mem.indexOf(u8, src, "begincodespacerange")) |cs| {
        var p = cs + "begincodespacerange".len;
        if (nextHex(src, &p)) |tok| {
            if (tok.len >= 2) cmap.byte_width = @intCast(@min(tok.len / 2, 4));
        }
    }

    // bfchar blocks.
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, src, search, "beginbfchar")) |bc| {
        var p = bc + "beginbfchar".len;
        const end = std.mem.indexOfPos(u8, src, p, "endbfchar") orelse src.len;
        while (p < end) {
            const code_tok = nextHexBounded(src, &p, end) orelse break;
            const dst_tok = nextHexBounded(src, &p, end) orelse break;
            if (cmap.map.count() >= max_entries) break;
            const code = hexToU32(code_tok);
            const utf8 = try utf16beToUtf8(a, dst_tok);
            try cmap.map.put(a, code, utf8);
        }
        search = end + "endbfchar".len;
    }

    // bfrange blocks.
    search = 0;
    while (std.mem.indexOfPos(u8, src, search, "beginbfrange")) |br| {
        var p = br + "beginbfrange".len;
        const end = std.mem.indexOfPos(u8, src, p, "endbfrange") orelse src.len;
        while (p < end) {
            const lo_tok = nextHexBounded(src, &p, end) orelse break;
            const hi_tok = nextHexBounded(src, &p, end) orelse break;
            const lo = hexToU32(lo_tok);
            const hi = hexToU32(hi_tok);
            // Destination is either a single <hex> or a [ <h0> <h1> … ] array.
            skipWs(src, &p, end);
            if (p < end and src[p] == '[') {
                p += 1;
                var c = lo;
                while (p < end and src[p] != ']') {
                    const d = nextHexBounded(src, &p, end) orelse break;
                    if (cmap.map.count() >= max_entries) break;
                    try cmap.map.put(a, c, try utf16beToUtf8(a, d));
                    c +%= 1;
                    skipWs(src, &p, end);
                }
                if (p < end and src[p] == ']') p += 1;
            } else {
                const dst_tok = nextHexBounded(src, &p, end) orelse break;
                const base = hexToU32(dst_tok);
                const units = dst_tok.len / 4; // UTF-16 code units (4 hex chars each)
                if (hi >= lo and hi - lo < max_entries) {
                    var c = lo;
                    while (c <= hi) : (c += 1) {
                        if (cmap.map.count() >= max_entries) break;
                        // Increment the last 16-bit unit across the range.
                        const v = base + (c - lo);
                        try cmap.map.put(a, c, try valueToUtf8(a, v, units));
                        if (c == std.math.maxInt(u32)) break;
                    }
                }
            }
        }
        search = end + "endbfrange".len;
    }

    return cmap;
}

// ── Token scanning ─────────────────────────────────────────────────────

fn skipWs(src: []const u8, p: *usize, end: usize) void {
    while (p.* < end and std.ascii.isWhitespace(src[p.*])) p.* += 1;
}

/// Next `<hex>` token at or after `p` (unbounded end).
fn nextHex(src: []const u8, p: *usize) ?[]const u8 {
    return nextHexBounded(src, p, src.len);
}

/// Next `<hex>` token within `[p, end)`, advancing `p` past it.
fn nextHexBounded(src: []const u8, p: *usize, end: usize) ?[]const u8 {
    while (p.* < end and src[p.*] != '<') {
        // Stop if we hit the next structural token start (avoid skipping past
        // an array bracket the caller cares about).
        if (src[p.*] == '[' or src[p.*] == ']') return null;
        p.* += 1;
    }
    if (p.* >= end) return null;
    const start = p.* + 1;
    const close = std.mem.indexOfScalarPos(u8, src[0..end], start, '>') orelse return null;
    p.* = close + 1;
    return src[start..close];
}

fn hexToU32(tok: []const u8) u32 {
    var v: u32 = 0;
    for (tok) |c| {
        const d = hexVal(c) orelse continue;
        v = (v << 4) | d;
    }
    return v;
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Convert a UTF-16BE hex destination (e.g. "0041", or a surrogate pair
/// "D83DDE00") to UTF-8.
fn utf16beToUtf8(a: Allocator, tok: []const u8) Allocator.Error![]const u8 {
    var units: [16]u16 = undefined;
    var nu: usize = 0;
    var i: usize = 0;
    while (i + 4 <= tok.len and nu < units.len) : (i += 4) {
        units[nu] = @intCast(hexToU32(tok[i .. i + 4]) & 0xFFFF);
        nu += 1;
    }
    return unitsToUtf8(a, units[0..nu]);
}

/// Render a numeric UTF-16 value (1 or 2 units) to UTF-8, for bfrange
/// incrementing destinations.
fn valueToUtf8(a: Allocator, value: u32, units: usize) Allocator.Error![]const u8 {
    if (units >= 2) {
        return unitsToUtf8(a, &[_]u16{ @intCast((value >> 16) & 0xFFFF), @intCast(value & 0xFFFF) });
    }
    return unitsToUtf8(a, &[_]u16{@intCast(value & 0xFFFF)});
}

/// Encode UTF-16 code units (with surrogate-pair combining) to UTF-8.
fn unitsToUtf8(a: Allocator, units: []const u16) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var k: usize = 0;
    while (k < units.len) {
        var cp: u21 = units[k];
        if (units[k] >= 0xD800 and units[k] <= 0xDBFF and k + 1 < units.len and
            units[k + 1] >= 0xDC00 and units[k + 1] <= 0xDFFF)
        {
            cp = 0x10000 + ((@as(u21, units[k] - 0xD800)) << 10) + (units[k + 1] - 0xDC00);
            k += 2;
        } else k += 1;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch continue; // skip invalid scalar
        try out.appendSlice(a, buf[0..n]);
    }
    return out.toOwnedSlice(a);
}
