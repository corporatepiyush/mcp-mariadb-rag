//! PDF text extraction (content-stream level), tolerant of modern PDFs.
//!
//! Scope (Agent.md: "everything correct, honest about limits"): this extracts
//! the text operands of the content streams — the `Tj`/`TJ`/`'`/`"` show-text
//! operators inside `BT … ET` — after running each stream through its full
//! `/Filter` chain (ASCIIHex, ASCII85, RunLength, LZW, Flate; see
//! ../pdf_filters). It handles literal `( … )` strings (escapes, octal,
//! balanced parens, line continuations) and hex `< … >` strings.
//!
//! Rich text / modern fonts: for Type0/CID fonts whose operands are opaque
//! 1- or 2-byte glyph codes, the recovered bytes are mapped through the font's
//! `/ToUnicode` CMap (see ../pdf_cmap) so the output is real Unicode rather than
//! glyph indices. The active font is tracked via the `Tf` operator and resolved
//! against the document's `/Font` resource dictionaries. Fonts without a
//! `/ToUnicode` map fall back to emitting the raw operand bytes (correct for the
//! common WinAnsi/StandardEncoding case).
//!
//! What it still does NOT do: glyph-to-Unicode via embedded CMap/encoding
//! differences when no `/ToUnicode` is present, and image-only filters
//! (DCT/CCITT/JBIG2). Stream discovery is keyword-driven (`stream … endstream`)
//! and every offset is bounds-checked, so it stays robust on linearized /
//! incrementally-updated files that break naive xref readers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const filters = @import("pdf_filters.zig");
const cmap = @import("pdf_cmap.zig");

pub const Error = error{OutOfMemory} || Writer.Error;

pub const Result = struct {
    text: []u8,
    units: usize, // content streams from which text was recovered
};

/// Resource-name (e.g. "F1") → its `/ToUnicode` CMap, built once per document.
pub const FontMap = std.StringHashMapUnmanaged(cmap.CMap);

/// Extract text from whole-file PDF bytes.
pub fn toText(a: Allocator, bytes: []const u8) Error!Result {
    const objs = buildObjects(a, bytes) catch return error.OutOfMemory;
    var fonts = buildFontMaps(a, bytes, objs) catch return error.OutOfMemory;

    var aw = Writer.Allocating.init(a);
    errdefer aw.deinit();
    const w = &aw.writer;
    var streams_used: usize = 0;
    var scratch: std.ArrayList(u8) = .empty;

    var search: usize = 0;
    while (findStream(bytes, search)) |s| {
        search = s.next_search;
        const raw = bytes[s.data_start..s.data_end];
        const content = decodeStream(a, raw, s.dict) orelse raw;

        const before = aw.written().len;
        try extractContentText(a, w, content, &fonts, &scratch);
        if (aw.written().len > before) {
            try w.writeByte('\n');
            streams_used += 1;
        }
    }
    return .{ .text = try aw.toOwnedSlice(), .units = streams_used };
}

// ── Stream discovery ───────────────────────────────────────────────────

const StreamSpan = struct {
    data_start: usize,
    data_end: usize,
    dict: []const u8, // the stream's dictionary bytes (for /Filter)
    next_search: usize,
};

/// Find the next `stream … endstream` body at or after `from`.
fn findStream(bytes: []const u8, from: usize) ?StreamSpan {
    var i = from;
    while (std.mem.indexOfPos(u8, bytes, i, "stream")) |kw| {
        // Skip the "endstream" keyword (its tail also contains "stream").
        if (kw >= 3 and std.mem.eql(u8, bytes[kw - 3 .. kw], "end")) {
            i = kw + 6;
            continue;
        }
        var ds = kw + 6;
        if (ds < bytes.len and bytes[ds] == '\r') ds += 1;
        if (ds < bytes.len and bytes[ds] == '\n') ds += 1;
        const end_kw = std.mem.indexOfPos(u8, bytes, ds, "endstream") orelse return null;
        var de = end_kw;
        if (de > ds and bytes[de - 1] == '\n') de -= 1;
        if (de > ds and bytes[de - 1] == '\r') de -= 1;

        // The stream dictionary is the window just before the keyword (the
        // closest `/Filter` to the stream wins).
        const look_start = if (kw > 4096) kw - 4096 else 0;
        return .{ .data_start = ds, .data_end = de, .dict = bytes[look_start..kw], .next_search = end_kw + 9 };
    }
    return null;
}

/// Decode a stream body through its `/Filter` chain. Returns null on any
/// unsupported/failed filter so the caller can fall back to the raw bytes.
fn decodeStream(a: Allocator, raw: []const u8, dict: []const u8) ?[]const u8 {
    var fs: [8]filters.Filter = undefined;
    const n = parseFilters(dict, &fs);
    if (n == 0) return null; // no filter → caller uses raw
    var cur: []const u8 = raw;
    for (fs[0..n]) |f| {
        cur = filters.decode(a, f, cur) catch return null;
    }
    return cur;
}

/// Parse the `/Filter` entry (name or array) from a stream dict into `out`,
/// returning the count. Picks the `/Filter` closest to the stream.
fn parseFilters(dict: []const u8, out: []filters.Filter) usize {
    const fp = std.mem.lastIndexOf(u8, dict, "/Filter") orelse return 0;
    var i = fp + "/Filter".len;
    skipWs(dict, &i);
    var n: usize = 0;
    if (i < dict.len and dict[i] == '[') {
        i += 1;
        while (i < dict.len and dict[i] != ']' and n < out.len) {
            skipWs(dict, &i);
            if (i < dict.len and dict[i] == '/') {
                out[n] = filters.filterFromName(readName(dict, &i));
                n += 1;
            } else i += 1;
        }
    } else if (i < dict.len and dict[i] == '/') {
        out[n] = filters.filterFromName(readName(dict, &i));
        n += 1;
    }
    return n;
}

// ── Object table + font/CMap resolution ────────────────────────────────

const ObjTable = std.AutoHashMapUnmanaged(u32, []const u8);

/// Map object number → object body (the bytes between `obj` and `endobj`), by
/// scanning `N G obj … endobj`. Robust to missing/!corrupt xref tables.
fn buildObjects(a: Allocator, bytes: []const u8) Allocator.Error!ObjTable {
    var t: ObjTable = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, i, "obj")) |kw| {
        // Skip "endobj".
        if (kw >= 3 and std.mem.eql(u8, bytes[kw - 3 .. kw], "end")) {
            i = kw + 3;
            continue;
        }
        i = kw + 3;
        // Back-parse "num gen" immediately before "obj".
        if (parseObjNum(bytes, kw)) |num| {
            const end = std.mem.indexOfPos(u8, bytes, kw + 3, "endobj") orelse bytes.len;
            try t.put(a, num, bytes[kw + 3 .. end]);
            i = end + 6;
        }
    }
    return t;
}

/// Parse the object number from the `num gen obj` header that ends at `obj_kw`.
fn parseObjNum(bytes: []const u8, obj_kw: usize) ?u32 {
    var p = obj_kw;
    p = backSkipWs(bytes, p);
    const gen_end = p;
    p = backSkipDigits(bytes, p);
    if (p == gen_end) return null; // no generation number
    p = backSkipWs(bytes, p);
    const num_end = p;
    const num_start = backSkipDigits(bytes, p);
    if (num_start == num_end) return null;
    return std.fmt.parseInt(u32, bytes[num_start..num_end], 10) catch null;
}

/// Build resource-name → ToUnicode CMap by walking every `/Font` resource dict.
fn buildFontMaps(a: Allocator, bytes: []const u8, objs: ObjTable) Allocator.Error!FontMap {
    var fonts: FontMap = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, i, "/Font")) |fp| {
        i = fp + "/Font".len;
        // The value is either an inline dict or an indirect reference to one.
        var j = i;
        skipWs(bytes, &j);
        const dict: []const u8 = blk: {
            if (j < bytes.len and bytes[j] == '<') {
                break :blk balancedDict(bytes, j) orelse continue;
            }
            const ref = parseRefAt(bytes, &j) orelse continue;
            const body = objs.get(ref) orelse continue;
            const ds = std.mem.indexOfScalar(u8, body, '<') orelse continue;
            break :blk balancedDict(body, ds) orelse continue;
        };
        try parseFontDict(a, dict, objs, &fonts);
    }
    return fonts;
}

/// Parse a `/Font` dict's `/Name N G R` entries, resolving each font's
/// `/ToUnicode` CMap and recording it under the resource name.
fn parseFontDict(a: Allocator, dict: []const u8, objs: ObjTable, fonts: *FontMap) Allocator.Error!void {
    var p: usize = 0;
    while (p < dict.len) {
        if (dict[p] != '/') {
            p += 1;
            continue;
        }
        const name = readName(dict, &p);
        skipWs(dict, &p);
        const font_ref = parseRefAt(dict, &p) orelse continue;
        const font_body = objs.get(font_ref) orelse continue;
        const tu = findRef(font_body, "/ToUnicode") orelse continue;
        const tu_body = objs.get(tu) orelse continue;
        const span = findStream(tu_body, 0) orelse continue;
        const raw = tu_body[span.data_start..span.data_end];
        const decoded = decodeStream(a, raw, span.dict) orelse raw;
        const cm = cmap.parse(a, decoded) catch continue;
        if (cm.count() == 0) continue;
        // Dupe the name (borrows from `dict`, which lives in the input — safe,
        // but dupe keeps the map self-contained).
        const key = a.dupe(u8, name) catch return error.OutOfMemory;
        try fonts.put(a, key, cm);
    }
}

/// Find `/key N G R` in `haystack` and return the object number.
fn findRef(haystack: []const u8, key: []const u8) ?u32 {
    const kp = std.mem.indexOf(u8, haystack, key) orelse return null;
    var p = kp + key.len;
    skipWs(haystack, &p);
    return parseRefAt(haystack, &p);
}

// ── Content-stream text extraction ─────────────────────────────────────

/// Pull show-text operands out of a decoded content stream into `w`, mapping
/// through the active font's `/ToUnicode` CMap when one is set.
pub fn extractContentText(
    a: Allocator,
    w: *Writer,
    content: []const u8,
    fonts: *const FontMap,
    scratch: *std.ArrayList(u8),
) Error!void {
    var i: usize = 0;
    const len = content.len;
    var in_text = false; // between BT and ET
    var active: ?*const cmap.CMap = null;
    var pending_name: []const u8 = "";

    while (i < len) {
        const c = content[i];
        switch (c) {
            '(' => {
                scratch.clearRetainingCapacity();
                const end = try decodeLiteral(a, scratch, content, i);
                if (in_text) try emit(w, active, scratch.items);
                i = end;
            },
            '<' => {
                if (i + 1 < len and content[i + 1] == '<') {
                    i += 2; // dictionary opener, skip
                } else {
                    scratch.clearRetainingCapacity();
                    const end = try decodeHex(a, scratch, content, i);
                    if (in_text) try emit(w, active, scratch.items);
                    i = end;
                }
            },
            '/' => {
                pending_name = readName(content, &i); // resource name for a later Tf
            },
            'B' => {
                if (std.mem.startsWith(u8, content[i..], "BT")) in_text = true;
                i += 1;
            },
            'E' => {
                if (std.mem.startsWith(u8, content[i..], "ET")) {
                    in_text = false;
                    try w.writeByte(' ');
                }
                i += 1;
            },
            'T' => {
                if (i + 1 < len and content[i + 1] == 'f') {
                    active = fonts.getPtr(pending_name); // set the current font
                    i += 2;
                } else if (i + 1 < len and content[i + 1] == '*') {
                    if (in_text) try w.writeByte('\n');
                    i += 2;
                } else i += 1;
            },
            '\'', '"' => {
                if (in_text) try w.writeByte('\n');
                i += 1;
            },
            else => i += 1,
        }
    }
}

/// Emit decoded operand bytes, mapping through the active CMap if present.
fn emit(w: *Writer, active: ?*const cmap.CMap, bytes: []const u8) Writer.Error!void {
    if (active) |cm| try cm.translate(w, bytes) else try w.writeAll(bytes);
}

/// Decode a literal `( … )` string at `open` into `buf`; returns the index past
/// the closing paren.
fn decodeLiteral(a: Allocator, buf: *std.ArrayList(u8), content: []const u8, open: usize) Error!usize {
    var i = open + 1;
    const len = content.len;
    var depth: usize = 1;
    while (i < len) {
        const c = content[i];
        if (c == '\\') {
            i += 1;
            if (i >= len) break;
            const e = content[i];
            switch (e) {
                'n' => try app(a, buf, '\n'),
                'r' => try app(a, buf, '\r'),
                't' => try app(a, buf, '\t'),
                'b' => try app(a, buf, 0x08),
                'f' => try app(a, buf, 0x0c),
                '(', ')', '\\' => try app(a, buf, e),
                '0'...'7' => {
                    var val: u16 = e - '0';
                    var k: usize = 0;
                    while (k < 2 and i + 1 < len and content[i + 1] >= '0' and content[i + 1] <= '7') : (k += 1) {
                        i += 1;
                        val = val * 8 + (content[i] - '0');
                    }
                    try app(a, buf, @truncate(val));
                },
                '\r' => {
                    if (i + 1 < len and content[i + 1] == '\n') i += 1; // line continuation
                },
                '\n' => {}, // line continuation
                else => try app(a, buf, e),
            }
            i += 1;
            continue;
        }
        if (c == '(') {
            depth += 1;
            try app(a, buf, '(');
            i += 1;
            continue;
        }
        if (c == ')') {
            depth -= 1;
            if (depth == 0) {
                i += 1;
                break;
            }
            try app(a, buf, ')');
            i += 1;
            continue;
        }
        try app(a, buf, c);
        i += 1;
    }
    return i;
}

/// Decode a hex `< … >` string at `open` into `buf`; returns the index past `>`.
fn decodeHex(a: Allocator, buf: *std.ArrayList(u8), content: []const u8, open: usize) Error!usize {
    var i = open + 1;
    const len = content.len;
    var hi: ?u8 = null;
    while (i < len and content[i] != '>') : (i += 1) {
        const d = hexVal(content[i]) orelse continue;
        if (hi) |h| {
            try app(a, buf, (h << 4) | d);
            hi = null;
        } else hi = d;
    }
    if (hi) |h| try app(a, buf, h << 4); // odd digit → low nibble 0
    if (i < len) i += 1; // consume '>'
    return i;
}

fn app(a: Allocator, buf: *std.ArrayList(u8), byte: u8) Error!void {
    buf.append(a, byte) catch return error.OutOfMemory;
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// ── Low-level token scanning ───────────────────────────────────────────

fn skipWs(s: []const u8, i: *usize) void {
    while (i.* < s.len and isWs(s[i.*])) i.* += 1;
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == 0 or c == 0x0c;
}

fn isDelim(c: u8) bool {
    return switch (c) {
        '(', ')', '<', '>', '[', ']', '{', '}', '/', '%' => true,
        else => false,
    };
}

/// Read a name token starting at a `/` (or at `i` if already past it),
/// returning the name without the slash and advancing `i`.
fn readName(s: []const u8, i: *usize) []const u8 {
    if (i.* < s.len and s[i.*] == '/') i.* += 1;
    const start = i.*;
    while (i.* < s.len and !isWs(s[i.*]) and !isDelim(s[i.*])) i.* += 1;
    return s[start..i.*];
}

/// Parse `num gen R` at `i`, returning `num` and advancing past `R`. Restores
/// `i` and returns null if the shape doesn't match.
fn parseRefAt(s: []const u8, i: *usize) ?u32 {
    const save = i.*;
    skipWs(s, i);
    const num = readInt(s, i) orelse {
        i.* = save;
        return null;
    };
    skipWs(s, i);
    _ = readInt(s, i) orelse {
        i.* = save;
        return null;
    };
    skipWs(s, i);
    if (i.* < s.len and s[i.*] == 'R') {
        i.* += 1;
        return num;
    }
    i.* = save;
    return null;
}

fn readInt(s: []const u8, i: *usize) ?u32 {
    const start = i.*;
    while (i.* < s.len and s[i.*] >= '0' and s[i.*] <= '9') i.* += 1;
    if (i.* == start) return null;
    return std.fmt.parseInt(u32, s[start..i.*], 10) catch null;
}

fn backSkipWs(s: []const u8, from: usize) usize {
    var p = from;
    while (p > 0 and isWs(s[p - 1])) p -= 1;
    return p;
}

fn backSkipDigits(s: []const u8, from: usize) usize {
    var p = from;
    while (p > 0 and s[p - 1] >= '0' and s[p - 1] <= '9') p -= 1;
    return p;
}

/// Return the balanced `<< … >>` dict starting at `start` (which must point at
/// `<<`), including both delimiters.
fn balancedDict(s: []const u8, start: usize) ?[]const u8 {
    if (start + 2 > s.len or s[start] != '<' or s[start + 1] != '<') return null;
    var i = start + 2;
    var depth: usize = 1;
    while (i + 1 < s.len) {
        if (s[i] == '<' and s[i + 1] == '<') {
            depth += 1;
            i += 2;
        } else if (s[i] == '>' and s[i + 1] == '>') {
            depth -= 1;
            i += 2;
            if (depth == 0) return s[start..i];
        } else i += 1;
    }
    return null;
}
