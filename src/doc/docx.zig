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
pub const zip = @import("zip.zig");
pub const xml = @import("xml.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Error = zip.Error || error{OutOfMemory} || Writer.Error;

pub const Result = struct {
    text: []u8,
    units: usize, // paragraph count
};

pub const member = "word/document.xml";

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
