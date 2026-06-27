//! Tests for src/doc/docx.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/doc/docx.zig");
const Io = std.Io;

const Writer = std.Io.Writer;
const member = srcmod.member;
const renderBody = srcmod.renderBody;
const toText = srcmod.toText;
const xml = srcmod.xml;
const zip = srcmod.zip;

test "docx: renderBody extracts runs and paragraph breaks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body =
        "<w:body><w:p><w:r><w:t>Hello</w:t></w:r>" ++
        "<w:r><w:t xml:space=\"preserve\"> world</w:t></w:r></w:p>" ++
        "<w:p><w:r><w:t>Second &amp; line</w:t></w:r></w:p></w:body>";
    const r = try renderBody(arena.allocator(), body);
    try testing.expectEqualStrings("Hello world\nSecond & line\n", r.text);
    try testing.expectEqual(@as(usize, 2), r.units);
}

test "docx: tabs and breaks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = "<w:p><w:t>a</w:t><w:tab/><w:t>b</w:t><w:br/><w:t>c</w:t></w:p>";
    const r = try renderBody(arena.allocator(), body);
    try testing.expectEqualStrings("a\tb\nc\n", r.text);
}

test "docx: does not confuse w:tab/w:tbl with w:t" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = "<w:p><w:tbl></w:tbl><w:t>real</w:t></w:p>";
    const r = try renderBody(arena.allocator(), body);
    try testing.expectEqualStrings("real\n", r.text);
}

// End-to-end: wrap WordML in a real (deflated) ZIP and extract.
test "docx: full container round-trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = "<w:document><w:body><w:p><w:t>Packaged text</w:t></w:p></w:body></w:document>";

    // Deflate the body.
    var caw = try Writer.Allocating.initCapacity(a, 1024);
    var window: [flate.max_window_len]u8 = undefined;
    var comp: flate.Compress = try .init(&caw.writer, &window, .raw, .default);
    try comp.writer.writeAll(body);
    try comp.finish();
    const data = try caw.toOwnedSlice();

    // Hand-assemble a single-entry zip (mirrors zip.zig's test builder).
    var aw = Writer.Allocating.init(a);
    const w = &aw.writer;
    const name = member;
    try wU32(w, 0x04034b50);
    try wU16(w, 20);
    try wU16(w, 0);
    try wU16(w, 8);
    try wU16(w, 0);
    try wU16(w, 0);
    try wU32(w, 0);
    try wU32(w, @intCast(data.len));
    try wU32(w, @intCast(body.len));
    try wU16(w, @intCast(name.len));
    try wU16(w, 0);
    try w.writeAll(name);
    try w.writeAll(data);
    const cd_off: u32 = @intCast(aw.written().len);
    try wU32(w, 0x02014b50);
    try wU16(w, 20);
    try wU16(w, 20);
    try wU16(w, 0);
    try wU16(w, 8);
    try wU16(w, 0);
    try wU16(w, 0);
    try wU32(w, 0);
    try wU32(w, @intCast(data.len));
    try wU32(w, @intCast(body.len));
    try wU16(w, @intCast(name.len));
    try wU16(w, 0);
    try wU16(w, 0);
    try wU16(w, 0);
    try wU16(w, 0);
    try wU32(w, 0);
    try wU32(w, 0);
    try w.writeAll(name);
    const cd_size: u32 = @intCast(aw.written().len - cd_off);
    try wU32(w, 0x06054b50);
    try wU16(w, 0);
    try wU16(w, 0);
    try wU16(w, 1);
    try wU16(w, 1);
    try wU32(w, cd_size);
    try wU32(w, cd_off);
    try wU16(w, 0);
    const archive = try aw.toOwnedSlice();

    const r = try toText(a, archive);
    try testing.expectEqualStrings("Packaged text\n", r.text);
}

fn wU16(w: *Writer, v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    try w.writeAll(&b);
}
fn wU32(w: *Writer, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try w.writeAll(&b);
}

test "fuzz: docx renderBody never panics" {
    var prng = std.Random.DefaultPrng.init(0xD0CF11);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;
    const alphabet = "<>/wtprbo: &;amp\"=";
    for (0..1000) |_| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const n = rnd.intRangeLessThan(usize, 0, buf.len);
        for (buf[0..n]) |*b| {
            b.* = if (rnd.boolean()) alphabet[rnd.intRangeLessThan(usize, 0, alphabet.len)] else rnd.int(u8);
        }
        _ = renderBody(arena.allocator(), buf[0..n]) catch {};
    }
}

// ---- helpers moved from src ----
pub const flate = std.compress.flate;
