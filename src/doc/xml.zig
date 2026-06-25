//! XML / HTML text extraction and entity decoding.
//!
//! A forward, single-pass tokenizer that emits character data between tags and
//! drops markup. Used directly for `.xml`/`.html` and as the entity-decoding
//! backend for DOCX (which has its own `<w:t>`/paragraph structure on top).
//!
//! Discipline (Agent.md): iterative (no recursion), every read bounded by
//! `i < len`, comments / CDATA / `<script>` / `<style>` skipped without ever
//! indexing past the slice. Numeric and named character references are decoded;
//! unknown references are passed through verbatim (never crash on bad input).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Error = error{OutOfMemory} || Writer.Error;

pub const Result = struct {
    text: []u8,
    units: usize, // approximate element/text-node count
};

/// Decode XML/HTML character references in `raw`, writing decoded text to `w`.
/// Collapses nothing — pure entity decode.
pub fn decodeInto(w: *Writer, raw: []const u8) Error!void {
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '&') {
            try w.writeByte(raw[i]);
            i += 1;
            continue;
        }
        const semi = std.mem.indexOfScalarPos(u8, raw, i + 1, ';') orelse {
            try w.writeByte('&');
            i += 1;
            continue;
        };
        if (semi - i > 32) { // not a real entity, too long
            try w.writeByte('&');
            i += 1;
            continue;
        }
        const ent = raw[i + 1 .. semi];
        if (decodeOne(w, ent)) {
            i = semi + 1;
        } else {
            try w.writeByte('&');
            i += 1;
        }
    }
}

/// Decode a single entity body (without `&`/`;`). Returns true if handled.
fn decodeOne(w: *Writer, ent: []const u8) bool {
    if (ent.len == 0) return false;
    if (ent[0] == '#') {
        const cp: u21 = blk: {
            if (ent.len >= 2 and (ent[1] == 'x' or ent[1] == 'X')) {
                break :blk std.fmt.parseInt(u21, ent[2..], 16) catch return false;
            }
            break :blk std.fmt.parseInt(u21, ent[1..], 10) catch return false;
        };
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return false;
        w.writeAll(buf[0..n]) catch return false;
        return true;
    }
    const named = [_]struct { k: []const u8, v: []const u8 }{
        .{ .k = "amp", .v = "&" },   .{ .k = "lt", .v = "<" },
        .{ .k = "gt", .v = ">" },    .{ .k = "quot", .v = "\"" },
        .{ .k = "apos", .v = "'" },  .{ .k = "nbsp", .v = " " },
        .{ .k = "copy", .v = "\u{00A9}" }, .{ .k = "reg", .v = "\u{00AE}" },
        .{ .k = "mdash", .v = "\u{2014}" }, .{ .k = "ndash", .v = "\u{2013}" },
        .{ .k = "hellip", .v = "\u{2026}" }, .{ .k = "rsquo", .v = "\u{2019}" },
        .{ .k = "lsquo", .v = "\u{2018}" }, .{ .k = "ldquo", .v = "\u{201C}" },
        .{ .k = "rdquo", .v = "\u{201D}" },
    };
    for (named) |e| {
        if (std.mem.eql(u8, ent, e.k)) {
            w.writeAll(e.v) catch return false;
            return true;
        }
    }
    return false;
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}

/// Strip tags from XML/HTML, decoding entities and collapsing runs of
/// whitespace into single spaces. Returns the rendered text.
pub fn toText(a: Allocator, bytes: []const u8) Error!Result {
    var aw = Writer.Allocating.init(a);
    errdefer aw.deinit();
    const w = &aw.writer;
    var i: usize = 0;
    const len = bytes.len;
    var units: usize = 0;
    var pending_space = false; // collapse whitespace; emit lazily
    var wrote_any = false; // suppress a leading space at output start

    while (i < len) {
        if (bytes[i] == '<') {
            // Markup. Handle comments, CDATA, and script/style skipping.
            if (std.mem.startsWith(u8, bytes[i..], "<!--")) {
                const close = std.mem.indexOfPos(u8, bytes, i + 4, "-->") orelse break;
                i = close + 3;
                continue;
            }
            if (std.mem.startsWith(u8, bytes[i..], "<![CDATA[")) {
                const close = std.mem.indexOfPos(u8, bytes, i + 9, "]]>") orelse break;
                const cdata = bytes[i + 9 .. close];
                if (pending_space and wrote_any) try w.writeByte(' ');
                pending_space = false;
                if (cdata.len > 0) {
                    try w.writeAll(cdata);
                    wrote_any = true;
                }
                i = close + 3;
                continue;
            }
            // Tag name (for script/style block skipping + paragraph breaks).
            const tag_end = std.mem.indexOfScalarPos(u8, bytes, i, '>') orelse break;
            const inner = bytes[i + 1 .. tag_end];
            const name = tagName(inner);
            if (eqIgnoreCase(name, "script") or eqIgnoreCase(name, "style")) {
                // Skip to the matching close tag.
                const close_needle = if (eqIgnoreCase(name, "script")) "</script" else "</style";
                const close = indexOfIgnoreCase(bytes, tag_end + 1, close_needle) orelse break;
                const after = std.mem.indexOfScalarPos(u8, bytes, close, '>') orelse break;
                i = after + 1;
                pending_space = true;
                continue;
            }
            // Block-level tags become whitespace boundaries.
            if (isBlockTag(name)) pending_space = true;
            units += 1;
            i = tag_end + 1;
            continue;
        }
        // Character data run up to the next '<'.
        const next = std.mem.indexOfScalarPos(u8, bytes, i, '<') orelse len;
        try emitCollapsed(w, bytes[i..next], &pending_space, &wrote_any);
        i = next;
    }
    return .{ .text = try aw.toOwnedSlice(), .units = units };
}

/// Emit text with whitespace collapsed and entities decoded. `pending_space`
/// carries the "a space is owed" state across calls so boundaries between
/// text nodes collapse correctly.
fn emitCollapsed(w: *Writer, raw: []const u8, pending_space: *bool, wrote_any: *bool) Error!void {
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c) {
            pending_space.* = true;
            i += 1;
            continue;
        }
        if (pending_space.*) {
            if (wrote_any.*) try w.writeByte(' ');
            pending_space.* = false;
        }
        if (c == '&') {
            const semi = std.mem.indexOfScalarPos(u8, raw, i + 1, ';');
            if (semi != null and semi.? - i <= 32 and decodeOne(w, raw[i + 1 .. semi.?])) {
                i = semi.? + 1;
                wrote_any.* = true;
                continue;
            }
        }
        try w.writeByte(c);
        wrote_any.* = true;
        i += 1;
    }
}

fn tagName(inner: []const u8) []const u8 {
    var s: usize = 0;
    if (s < inner.len and inner[s] == '/') s += 1;
    var e = s;
    while (e < inner.len) : (e += 1) {
        const c = inner[e];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '/' or c == '>') break;
    }
    return inner[s..e];
}

fn isBlockTag(name: []const u8) bool {
    const blocks = [_][]const u8{
        "p", "br", "div", "li", "tr", "td", "th", "h1", "h2", "h3",
        "h4", "h5", "h6", "section", "article", "table", "ul", "ol", "blockquote",
    };
    for (blocks) |b| if (eqIgnoreCase(name, b)) return true;
    return false;
}

fn indexOfIgnoreCase(haystack: []const u8, from: usize, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    var i = from;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var ok = true;
        for (haystack[i .. i + needle.len], needle) |x, y| {
            if (std.ascii.toLower(x) != std.ascii.toLower(y)) {
                ok = false;
                break;
            }
        }
        if (ok) return i;
    }
    return null;
}

// ── Tests ─────────────────────────────────────────────────────────────
const testing = std.testing;

fn expectXml(input: []const u8, expect: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try toText(arena.allocator(), input);
    try testing.expectEqualStrings(expect, r.text);
}

test "xml: strips tags, keeps text" {
    try expectXml("<root><a>Hello</a> <b>World</b></root>", "Hello World");
}

test "xml: decodes entities" {
    try expectXml("<p>A &amp; B &lt;3 &#65;</p>", "A & B <3 A");
}

test "html: skips script and style" {
    try expectXml(
        "<html><style>p{color:red}</style><body>Hi<script>alert(1)</script>there</body></html>",
        "Hi there",
    );
}

test "xml: comments and CDATA" {
    try expectXml("<r><!-- skip me --><![CDATA[raw <tag>]]></r>", "raw <tag>");
}

test "xml: whitespace collapse" {
    try expectXml("<p>  a   b  \n c </p>", "a b c");
}

test "fuzz: xml extraction never panics" {
    var prng = std.Random.DefaultPrng.init(0x8A11);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;
    const alphabet = "<>/&;#amp lt gt 0123ABC \"'";
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
