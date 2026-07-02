//! Tests for src/doc/pdf.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/doc/pdf.zig");
const extractContentText = srcmod.extractContentText;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Writer = std.Io.Writer;
const toText = srcmod.toText;

test "pdf: literal show-text operators" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try extract(arena.allocator(), "BT /F1 12 Tf (Hello) Tj ( World) Tj ET");
    try testing.expectEqualStrings("Hello World ", out);
}

test "pdf: TJ array and escapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try extract(arena.allocator(), "BT [(Ab) -250 (c\\)d)] TJ ET");
    try testing.expectEqualStrings("Abc)d ", out);
}

test "pdf: hex strings and octal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try extract(arena.allocator(), "BT <48656C6C6F> Tj (\\101\\102) Tj ET");
    try testing.expectEqualStrings("HelloAB ", out);
}

test "pdf: ignores strings outside BT/ET and dict openers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try extract(arena.allocator(), "<< /Foo (bar) >> (outside) BT (inside) Tj ET");
    try testing.expectEqualStrings("inside ", out);
}

test "pdf: full document with flate content stream" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const stream_text = "BT (Compressed PDF text) Tj ET";
    // zlib-compress the content stream (PDF FlateDecode == zlib).
    var caw = try Writer.Allocating.initCapacity(a, 512);
    var window: [flate.max_window_len]u8 = undefined;
    var comp: flate.Compress = try .init(&caw.writer, &window, .zlib, .default);
    try comp.writer.writeAll(stream_text);
    try comp.finish();
    const compressed = try caw.toOwnedSlice();

    const pdf = try std.fmt.allocPrint(a,
        "%PDF-1.7\n4 0 obj\n<< /Length {d} /Filter /FlateDecode >>\nstream\n{s}\nendstream\nendobj\n",
        .{ compressed.len, compressed },
    );
    const r = try toText(a, pdf);
    try testing.expectEqualStrings("Compressed PDF text \n", r.text);
    try testing.expectEqual(@as(usize, 1), r.units);
}

test "pdf: ASCIIHexDecode content stream (filter chain)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const content = "BT (Hex filtered) Tj ET";
    // Hex-encode the content stream for ASCIIHexDecode.
    var hex: std.ArrayList(u8) = .empty;
    for (content) |c| {
        var b: [2]u8 = undefined;
        _ = std.fmt.bufPrint(&b, "{X:0>2}", .{c}) catch unreachable;
        try hex.appendSlice(a, &b);
    }
    try hex.appendSlice(a, ">");

    const pdf = try std.fmt.allocPrint(a,
        "%PDF-1.7\n1 0 obj\n<< /Filter /ASCIIHexDecode /Length {d} >>\nstream\n{s}\nendstream\nendobj\n",
        .{ hex.items.len, hex.items },
    );
    const r = try toText(a, pdf);
    try testing.expectEqualStrings("Hex filtered \n", r.text);
}

test "pdf: Type0 font mapped through /ToUnicode (2-byte codes → Unicode)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A minimal modern-style PDF: a /Font resource names F1 → a Type0 font whose
    // /ToUnicode CMap maps 2-byte codes 0041/0042 to 'A'/'B'. The content stream
    // shows the 2-byte string <00410042>, which must decode to "AB".
    const pdf =
        "%PDF-1.7\n" ++
        "1 0 obj\n<< /Font << /F1 2 0 R >> >>\nendobj\n" ++
        "2 0 obj\n<< /Type /Font /Subtype /Type0 /ToUnicode 3 0 R >>\nendobj\n" ++
        "3 0 obj\n<< /Length 180 >>\nstream\n" ++
        "/CIDInit /ProcSet findresource begin 12 dict begin begincmap\n" ++
        "1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n" ++
        "2 beginbfchar\n<0041> <0041>\n<0042> <0042>\nendbfchar\n" ++
        "endcmap end end\nendstream\nendobj\n" ++
        "4 0 obj\n<< /Length 33 >>\nstream\n" ++
        "BT /F1 12 Tf <00410042> Tj ET\nendstream\nendobj\n";

    const r = try toText(a, pdf);
    try testing.expect(std.mem.indexOf(u8, r.text, "AB") != null);
    // The raw glyph-code bytes (0x00) must NOT leak into the output.
    try testing.expect(std.mem.indexOfScalar(u8, r.text, 0x00) == null);
}

test "fuzz: pdf extraction never panics" {
    var prng = std.Random.DefaultPrng.init(0x9DF00D);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;
    const alphabet = "()<>\\BTETj 0123456789ABCabc/[]";
    for (0..1500) |_| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const n = rnd.intRangeLessThan(usize, 0, buf.len);
        for (buf[0..n]) |*b| {
            b.* = if (rnd.boolean()) alphabet[rnd.intRangeLessThan(usize, 0, alphabet.len)] else rnd.int(u8);
        }
        _ = toText(arena.allocator(), buf[0..n]) catch {};
    }
}

// ---- helpers moved from src ----
pub const flate = std.compress.flate;

pub fn extract(a: Allocator, content: []const u8) ![]u8 {
    var aw = Writer.Allocating.init(a);
    var fonts: srcmod.FontMap = .empty;
    var scratch: std.ArrayList(u8) = .empty;
    try extractContentText(a, &aw.writer, content, &fonts, &scratch);
    return aw.toOwnedSlice();
}
