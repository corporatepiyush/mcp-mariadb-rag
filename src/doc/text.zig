//! Plain-text / Markdown normalization.
//!
//! "Extraction" for already-textual formats means: strip a UTF-8 BOM, normalize
//! CRLF/CR line endings to LF, and validate the bytes are UTF-8 (replacing
//! invalid sequences so downstream chunking/embedding never chokes). Markdown is
//! treated as text — its syntax is meaningful context for retrieval, so we keep
//! it rather than stripping it.
//!
//! Per Agent.md: single linear pass, output sized from the input length (it can
//! only shrink — BOM removal and CRLF→LF), one arena allocation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Error = error{OutOfMemory} || Writer.Error;

pub const Result = struct {
    text: []u8,
    units: usize, // line count
};

pub const replacement = "\u{FFFD}";

pub fn toText(a: Allocator, bytes: []const u8) Error!Result {
    var src = bytes;
    if (std.mem.startsWith(u8, src, "\xEF\xBB\xBF")) src = src[3..]; // BOM

    // Output never exceeds input length except when invalid bytes expand to the
    // 3-byte replacement char; size generously but bounded.
    var aw = Writer.Allocating.init(a);
    errdefer aw.deinit();
    aw.ensureUnusedCapacity(src.len) catch return error.OutOfMemory;
    const w = &aw.writer;

    var i: usize = 0;
    var lines: usize = 1;
    while (i < src.len) {
        const c = src[i];
        if (c == '\r') {
            try w.writeByte('\n');
            lines += 1;
            if (i + 1 < src.len and src[i + 1] == '\n') i += 1; // CRLF → one LF
            i += 1;
            continue;
        }
        if (c == '\n') {
            try w.writeByte('\n');
            lines += 1;
            i += 1;
            continue;
        }
        if (c < 0x80) {
            try w.writeByte(c);
            i += 1;
            continue;
        }
        // Multi-byte UTF-8: validate the sequence length and bytes.
        const seq_len = std.unicode.utf8ByteSequenceLength(c) catch {
            try w.writeAll(replacement);
            i += 1;
            continue;
        };
        if (i + seq_len > src.len or !std.unicode.utf8ValidateSlice(src[i .. i + seq_len])) {
            try w.writeAll(replacement);
            i += 1;
            continue;
        }
        try w.writeAll(src[i .. i + seq_len]);
        i += seq_len;
    }
    if (src.len == 0) lines = 0;
    return .{ .text = try aw.toOwnedSlice(), .units = lines };
}
