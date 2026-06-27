//! PDF text extraction (content-stream level).
//!
//! Scope and honesty (Agent.md: "everything correct"): this extracts the text
//! *operands* of the content streams — the `Tj`/`TJ`/`'`/`"` show-text
//! operators inside `BT … ET` text objects — after decompressing FlateDecode
//! streams with our native inflate. It correctly handles literal `( … )`
//! strings (escapes, octal, balanced parens, line continuations) and hex
//! `< … >` strings.
//!
//! It does NOT remap glyphs through CID/Type0 font CMaps; for documents whose
//! fonts use custom encodings the recovered bytes are the raw character codes,
//! not Unicode. For the overwhelmingly common WinAnsi/StandardEncoding case the
//! output is correct text. CMap-aware decoding is a planned follow-up — it
//! belongs here, in this module, not bolted onto a C dependency.
//!
//! Stream discovery is keyword-driven (`stream … endstream`) rather than full
//! xref-table parsing: simpler, and robust to the linearized/incremental files
//! that break naive xref readers. Every offset is bounds-checked.

const std = @import("std");
const inflate = @import("inflate.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Error = error{OutOfMemory} || Writer.Error;

pub const Result = struct {
    text: []u8,
    units: usize, // content streams from which text was recovered
};

/// Extract text from whole-file PDF bytes.
pub fn toText(a: Allocator, bytes: []const u8) Error!Result {
    var aw = Writer.Allocating.init(a);
    errdefer aw.deinit();
    const w = &aw.writer;
    var streams_used: usize = 0;

    var search: usize = 0;
    while (findStream(bytes, search)) |s| {
        search = s.next_search;
        const raw = bytes[s.data_start..s.data_end];
        // Decode if FlateDecode; fall back to raw bytes on any decode failure.
        const content: []const u8 = if (s.flate)
            (inflate.zlib(a, raw, raw.len * 4) catch
                inflate.raw(a, raw, raw.len * 4) catch raw)
        else
            raw;

        const before = aw.written().len;
        try extractContentText(w, content);
        if (aw.written().len > before) {
            try w.writeByte('\n');
            streams_used += 1;
        }
    }
    return .{ .text = try aw.toOwnedSlice(), .units = streams_used };
}

const StreamSpan = struct {
    data_start: usize,
    data_end: usize,
    flate: bool,
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
        // Data begins after the keyword and the EOL that must follow it.
        var ds = kw + 6;
        if (ds < bytes.len and bytes[ds] == '\r') ds += 1;
        if (ds < bytes.len and bytes[ds] == '\n') ds += 1;
        const end_kw = std.mem.indexOfPos(u8, bytes, ds, "endstream") orelse return null;
        var de = end_kw;
        // Trim a single trailing EOL between data and "endstream".
        if (de > ds and bytes[de - 1] == '\n') de -= 1;
        if (de > ds and bytes[de - 1] == '\r') de -= 1;

        // Look back a bounded window for the /Filter entry of this stream dict.
        const look_start = if (kw > 400) kw - 400 else 0;
        const dict = bytes[look_start..kw];
        const is_flate = std.mem.indexOf(u8, dict, "FlateDecode") != null;

        return .{ .data_start = ds, .data_end = de, .flate = is_flate, .next_search = end_kw + 9 };
    }
    return null;
}

/// Pull show-text operands out of a decoded content stream into `w`.
pub fn extractContentText(w: *Writer, content: []const u8) Error!void {
    var i: usize = 0;
    const len = content.len;
    var in_text = false; // between BT and ET

    while (i < len) {
        const c = content[i];
        switch (c) {
            '(' => {
                // Literal string; emit if we're in a text object.
                const end = try emitLiteral(w, content, i, in_text);
                i = end;
            },
            '<' => {
                if (i + 1 < len and content[i + 1] == '<') {
                    i += 2; // dictionary opener, skip
                } else {
                    const end = try emitHex(w, content, i, in_text);
                    i = end;
                }
            },
            'B' => {
                if (std.mem.startsWith(u8, content[i..], "BT")) in_text = true;
                i += 1;
            },
            'E' => {
                if (std.mem.startsWith(u8, content[i..], "ET")) {
                    in_text = false;
                    if (true) try w.writeByte(' ');
                }
                i += 1;
            },
            'T' => {
                // Positioning ops that imply a new line: T* (and Td/TD start
                // a new text line). Emit a newline so paragraphs separate.
                if (i + 1 < len and (content[i + 1] == '*')) {
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

/// Parse a literal `( … )` string starting at `open`; emit its decoded bytes if
/// `emit`. Returns the index just past the closing paren.
fn emitLiteral(w: *Writer, content: []const u8, open: usize, emit: bool) Error!usize {
    var i = open + 1;
    const len = content.len;
    var depth: usize = 1;
    while (i < len) {
        const c = content[i];
        if (c == '\\') {
            i += 1;
            if (i >= len) break;
            const e = content[i];
            if (emit) switch (e) {
                'n' => try w.writeByte('\n'),
                'r' => try w.writeByte('\r'),
                't' => try w.writeByte('\t'),
                'b' => try w.writeByte(0x08),
                'f' => try w.writeByte(0x0c),
                '(', ')', '\\' => try w.writeByte(e),
                '0'...'7' => {
                    // Up to 3 octal digits.
                    var val: u16 = e - '0';
                    var k: usize = 0;
                    while (k < 2 and i + 1 < len and content[i + 1] >= '0' and content[i + 1] <= '7') : (k += 1) {
                        i += 1;
                        val = val * 8 + (content[i] - '0');
                    }
                    try w.writeByte(@truncate(val));
                },
                '\r' => {
                    if (i + 1 < len and content[i + 1] == '\n') i += 1; // line continuation
                },
                '\n' => {}, // line continuation
                else => try w.writeByte(e),
            } else {
                // still need to consume octal run length even when not emitting
                if (e >= '0' and e <= '7') {
                    var k: usize = 0;
                    while (k < 2 and i + 1 < len and content[i + 1] >= '0' and content[i + 1] <= '7') : (k += 1) i += 1;
                }
            }
            i += 1;
            continue;
        }
        if (c == '(') {
            depth += 1;
            if (emit) try w.writeByte('(');
            i += 1;
            continue;
        }
        if (c == ')') {
            depth -= 1;
            if (depth == 0) {
                i += 1;
                break;
            }
            if (emit) try w.writeByte(')');
            i += 1;
            continue;
        }
        if (emit) try w.writeByte(c);
        i += 1;
    }
    return i;
}

/// Parse a hex `< … >` string starting at `open`; emit decoded bytes if `emit`.
fn emitHex(w: *Writer, content: []const u8, open: usize, emit: bool) Error!usize {
    var i = open + 1;
    const len = content.len;
    var hi: ?u8 = null;
    while (i < len and content[i] != '>') : (i += 1) {
        const d = hexVal(content[i]) orelse continue;
        if (hi) |h| {
            if (emit) try w.writeByte((h << 4) | d);
            hi = null;
        } else hi = d;
    }
    if (hi) |h| {
        if (emit) try w.writeByte(h << 4); // odd digit → low nibble 0
    }
    if (i < len) i += 1; // consume '>'
    return i;
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}
