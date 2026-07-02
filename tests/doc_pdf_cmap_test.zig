//! Tests for src/doc/pdf_cmap.zig (ToUnicode CMap parse + translate).

const std = @import("std");
const testing = std.testing;
const cmap = @import("../src/doc/pdf_cmap.zig");
const Writer = std.Io.Writer;

fn translate(cm: *const cmap.CMap, a: std.mem.Allocator, codes: []const u8) ![]u8 {
    var aw = Writer.Allocating.init(a);
    try cm.translate(&aw.writer, codes);
    return aw.toOwnedSlice();
}

test "pdf_cmap: bfchar + bfrange (incrementing), 2-byte codes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        "begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n" ++
        "2 beginbfchar\n<0041> <0041>\n<0042> <0042>\nendbfchar\n" ++
        "1 beginbfrange\n<0043> <0045> <0043>\nendbfrange\n"; // C,D,E
    const cm = try cmap.parse(a, src);
    try testing.expectEqual(@as(u8, 2), cm.byte_width);
    // Codes 0041 0042 0043 0044 0045 → "ABCDE".
    const out = try translate(&cm, a, &[_]u8{ 0, 0x41, 0, 0x42, 0, 0x43, 0, 0x44, 0, 0x45 });
    try testing.expectEqualStrings("ABCDE", out);
}

test "pdf_cmap: bfrange array form" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        "begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n" ++
        "1 beginbfrange\n<0030> <0031> [<0061> <0062>]\nendbfrange\n";
    const cm = try cmap.parse(a, src);
    const out = try translate(&cm, a, &[_]u8{ 0, 0x30, 0, 0x31 });
    try testing.expectEqualStrings("ab", out);
}

test "pdf_cmap: surrogate-pair destination decodes to an astral codepoint" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        "begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n" ++
        "1 beginbfchar\n<0001> <D83DDE00>\nendbfchar\n"; // U+1F600 😀
    const cm = try cmap.parse(a, src);
    const out = try translate(&cm, a, &[_]u8{ 0, 0x01 });
    try testing.expectEqualStrings("\u{1F600}", out);
}

test "pdf_cmap: single-byte code width" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        "begincodespacerange\n<00> <FF>\nendcodespacerange\n" ++
        "1 beginbfchar\n<41> <0041>\nendbfchar\n";
    const cm = try cmap.parse(a, src);
    try testing.expectEqual(@as(u8, 1), cm.byte_width);
    const out = try translate(&cm, a, &[_]u8{0x41});
    try testing.expectEqualStrings("A", out);
}
