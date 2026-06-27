//! Tests for src/doc/zip.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/doc/zip.zig");
const loc_sig = srcmod.loc_sig;
const cen_sig = srcmod.cen_sig;
const eocd_sig = srcmod.eocd_sig;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const extract = srcmod.extract;

test "zip: extract stored entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const z = try buildZip(a, "word/document.xml", "<w:t>hello</w:t>", false);
    const out = try extract(a, z, "word/document.xml");
    try testing.expectEqualStrings("<w:t>hello</w:t>", out);
}

test "zip: extract deflate entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const payload = "The quick brown fox. " ** 40;
    const z = try buildZip(a, "word/document.xml", payload, true);
    const out = try extract(a, z, "word/document.xml");
    try testing.expectEqualStrings(payload, out);
}

test "zip: missing entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const z = try buildZip(a, "a.txt", "x", false);
    try testing.expectError(error.EntryNotFound, extract(a, z, "b.txt"));
}

test "fuzz: zip reader never panics on random bytes" {
    var prng = std.Random.DefaultPrng.init(0x21B2);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;
    for (0..1000) |_| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const n = rnd.intRangeLessThan(usize, 0, buf.len);
        for (buf[0..n]) |*b| b.* = rnd.int(u8);
        _ = extract(arena.allocator(), buf[0..n], "word/document.xml") catch {};
    }
}

// ---- helpers moved from src ----
const flate = std.compress.flate;
const Writer = std.Io.Writer;

/// Build a one-entry ZIP in memory (stored or deflate) for tests.
pub fn buildZip(a: Allocator, name: []const u8, content: []const u8, deflate: bool) ![]u8 {
    var data: []const u8 = content;
    var method: u16 = 0;
    if (deflate) {
        var aw = try Writer.Allocating.initCapacity(a, 4096);
        var window: [flate.max_window_len]u8 = undefined;
        var comp: flate.Compress = try .init(&aw.writer, &window, .raw, .default);
        try comp.writer.writeAll(content);
        try comp.finish();
        data = try aw.toOwnedSlice();
        method = 8;
    }

    var aw = Writer.Allocating.init(a);
    const w = &aw.writer;

    // Local file header.
    const local_off: u32 = 0;
    try writeU32(w, loc_sig);
    try writeU16(w, 20); // version needed
    try writeU16(w, 0); // flags
    try writeU16(w, method);
    try writeU16(w, 0); // mod time
    try writeU16(w, 0); // mod date
    try writeU32(w, 0); // crc (unchecked by our reader)
    try writeU32(w, @intCast(data.len));
    try writeU32(w, @intCast(content.len));
    try writeU16(w, @intCast(name.len));
    try writeU16(w, 0); // extra len
    try w.writeAll(name);
    try w.writeAll(data);

    const cd_off: u32 = @intCast(aw.written().len);
    // Central directory header.
    try writeU32(w, cen_sig);
    try writeU16(w, 20); // version made by
    try writeU16(w, 20); // version needed
    try writeU16(w, 0); // flags
    try writeU16(w, method);
    try writeU16(w, 0);
    try writeU16(w, 0);
    try writeU32(w, 0); // crc
    try writeU32(w, @intCast(data.len));
    try writeU32(w, @intCast(content.len));
    try writeU16(w, @intCast(name.len));
    try writeU16(w, 0); // extra
    try writeU16(w, 0); // comment
    try writeU16(w, 0); // disk
    try writeU16(w, 0); // internal attrs
    try writeU32(w, 0); // external attrs
    try writeU32(w, local_off);
    try w.writeAll(name);

    const cd_size: u32 = @intCast(aw.written().len - cd_off);
    // EOCD.
    try writeU32(w, eocd_sig);
    try writeU16(w, 0); // disk
    try writeU16(w, 0); // cd start disk
    try writeU16(w, 1); // entries on disk
    try writeU16(w, 1); // total entries
    try writeU32(w, cd_size);
    try writeU32(w, cd_off);
    try writeU16(w, 0); // comment len

    return aw.toOwnedSlice();
}

fn writeU16(w: *Writer, v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    try w.writeAll(&b);
}
fn writeU32(w: *Writer, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try w.writeAll(&b);
}
