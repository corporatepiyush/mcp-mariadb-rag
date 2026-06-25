//! DOCX (Office Open XML, WordprocessingML) text extraction.
//!
//! A .docx is a ZIP whose `word/document.xml` holds the body as WordprocessingML.
//! We pull that member out (`zip.extract` → native inflate), then run a focused
//! scanner that understands just the structural elements that carry text:
//!   * `<w:t> … </w:t>`  — a text run; its (entity-encoded) content is emitted.
//!   * `<w:tab/>`        — a tab.
//!   * `<w:br/>` `<w:cr/>` — a line break.
//!   * `</w:p>`          — paragraph end → newline.
//! Everything else (run properties, styles, bookmarks) is skipped.
//!
//! This is deliberately not a general XML tree build — Agent.md favors a single
//! linear pass over the document bytes with bounded reads, which is both faster
//! and a smaller attack surface than materializing a DOM.

const std = @import("std");
const zip = @import("../zip.zig");
const xml = @import("../xml.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Error = zip.Error || error{OutOfMemory} || Writer.Error;

pub const Result = struct {
    text: []u8,
    units: usize, // paragraph count
};

const member = "word/document.xml";

/// Extract readable text from DOCX container bytes.
pub fn toText(a: Allocator, bytes: []const u8) Error!Result {
    const xml_bytes = try zip.extract(a, bytes, member);
    return renderBody(a, xml_bytes);
}

/// Render WordprocessingML body text. Public for direct testing without the
/// ZIP envelope.
pub fn renderBody(a: Allocator, doc: []const u8) Error!Result {
    var aw = Writer.Allocating.init(a);
    errdefer aw.deinit();
    const w = &aw.writer;

    var i: usize = 0;
    const len = doc.len;
    var paragraphs: usize = 0;
    var line_has_text = false;

    while (i < len) {
        const lt = std.mem.indexOfScalarPos(u8, doc, i, '<') orelse break;
        // Emit nothing for character data outside elements (WordML has none of
        // significance between the tags we track).
        i = lt;
        const gt = std.mem.indexOfScalarPos(u8, doc, i, '>') orelse break;
        const tag = doc[i + 1 .. gt]; // tag body without < >

        if (isTextOpen(tag)) {
            // Content runs from after '>' to the matching </w:t>.
            const content_start = gt + 1;
            const close = std.mem.indexOfPos(u8, doc, content_start, "</w:t>") orelse {
                i = gt + 1;
                continue;
            };
            try xml.decodeInto(w, doc[content_start..close]);
            if (close > content_start) line_has_text = true;
            i = close + "</w:t>".len;
            continue;
        }
        if (matchTag(tag, "w:tab")) {
            try w.writeByte('\t');
        } else if (matchTag(tag, "w:br") or matchTag(tag, "w:cr")) {
            try w.writeByte('\n');
        } else if (std.mem.eql(u8, tag, "/w:p")) {
            try w.writeByte('\n');
            if (line_has_text) paragraphs += 1;
            line_has_text = false;
        }
        i = gt + 1;
    }
    return .{ .text = try aw.toOwnedSlice(), .units = paragraphs };
}

/// True for `<w:t>` or `<w:t xml:space="preserve">` (open tag, not the close).
fn isTextOpen(tag: []const u8) bool {
    if (tag.len < 3) return false;
    if (tag[0] == '/') return false;
    if (!std.mem.startsWith(u8, tag, "w:t")) return false;
    // Next char must end the name: '>' is already stripped, so it's space or
    // end-of-tag. Guard against `w:tab`, `w:tbl`, etc.
    if (tag.len == 3) return true; // exactly "w:t"
    const c = tag[3];
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

/// Match a (possibly self-closing) tag name, e.g. `matchTag("w:tab/", "w:tab")`.
fn matchTag(tag: []const u8, name: []const u8) bool {
    if (!std.mem.startsWith(u8, tag, name)) return false;
    if (tag.len == name.len) return true;
    const c = tag[name.len];
    return c == ' ' or c == '/' or c == '\t' or c == '\r' or c == '\n';
}

// ── Tests ─────────────────────────────────────────────────────────────
const testing = std.testing;
const flate = std.compress.flate;

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
