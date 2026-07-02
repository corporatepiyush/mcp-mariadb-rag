//! Tests for src/doc/pdf_filters.zig (PDF stream filter decoders).

const std = @import("std");
const testing = std.testing;
const filters = @import("../src/doc/pdf_filters.zig");

fn dec(f: filters.Filter, data: []const u8) ![]u8 {
    return filters.decode(testing.allocator, f, data);
}

test "pdf_filters: ASCIIHexDecode" {
    const out = try dec(.asciihex, "48656C6C6F>"); // "Hello" + EOD
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("Hello", out);
}

test "pdf_filters: ASCIIHexDecode odd trailing digit → low nibble 0" {
    const out = try dec(.asciihex, "4A2>"); // 'J' then 0x20
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("J ", out);
}

test "pdf_filters: ASCII85Decode" {
    // "sure" → base85 digits 37,9,17,44,22 → "F*2M7".
    const out = try dec(.ascii85, "F*2M7~>");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("sure", out);
}

test "pdf_filters: ASCII85Decode 'z' expands to four zero bytes" {
    const out = try dec(.ascii85, "z~>");
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, out);
}

test "pdf_filters: RunLengthDecode literal + repeat runs" {
    // literal run of 5 ("Hello"), then repeat 'A' ×3 (257-254), then EOD.
    const out = try dec(.runlength, &[_]u8{ 0x04, 'H', 'e', 'l', 'l', 'o', 0xFE, 'A', 0x80 });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("HelloAAA", out);
}

test "pdf_filters: LZWDecode variable-width codes" {
    // Hand-encoded LZW for "AAAAAA": [CLEAR, 'A'=65, 258, 259, EOD] as 9-bit
    // MSB-first codes → bytes {80 10 60 50 38 08}.
    const out = try dec(.lzw, &[_]u8{ 0x80, 0x10, 0x60, 0x50, 0x38, 0x08 });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("AAAAAA", out);
}

test "pdf_filters: image-only filter is unsupported (caller falls back to raw)" {
    try testing.expectEqual(filters.Filter.unsupported, filters.filterFromName("DCTDecode"));
    try testing.expectError(error.Unsupported, dec(.unsupported, "junk"));
}

test "fuzz: pdf filters never panic on random bytes" {
    var prng = std.Random.DefaultPrng.init(0xF117E5);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;
    const fs = [_]filters.Filter{ .asciihex, .ascii85, .runlength, .lzw, .flate };
    for (0..3000) |_| {
        const n = rnd.intRangeLessThan(usize, 0, buf.len);
        for (buf[0..n]) |*b| b.* = rnd.int(u8);
        const f = fs[rnd.intRangeLessThan(usize, 0, fs.len)];
        if (dec(f, buf[0..n])) |out| testing.allocator.free(out) else |_| {}
    }
}
