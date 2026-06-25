//! Content-based document format detection.
//!
//! Detection is magic-byte first (the bytes never lie), extension/hint second
//! (advisory only). Per Agent.md every untrusted byte is an exploit primitive,
//! so the sniffer only ever *reads* a bounded prefix/suffix and never indexes
//! past the slice — all comparisons go through `startsWith`/`endsWith`/bounded
//! loops. No allocation: detection is a pure function over a borrowed slice.

const std = @import("std");

pub const Format = enum {
    text,
    markdown,
    csv,
    tsv,
    json,
    ndjson,
    xml,
    html,
    docx,
    pdf,
    parquet,
    iceberg,
    legacy_doc, // OLE2/CFB Word .doc
    gzip,
    unknown,

    /// Human label for diagnostics / tool output.
    pub fn label(f: Format) []const u8 {
        return @tagName(f);
    }

    /// Whether this tag's extraction pipeline can turn the format into text.
    /// Scaffolded formats report `false` so callers get an honest answer.
    pub fn isExtractable(f: Format) bool {
        return switch (f) {
            .text, .markdown, .csv, .tsv, .json, .ndjson, .xml, .html, .docx, .pdf => true,
            .parquet, .iceberg, .legacy_doc, .gzip, .unknown => false,
        };
    }
};

/// OLE2 / Compound File Binary signature (legacy .doc/.xls/.ppt).
const cfb_magic = [_]u8{ 0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1 };
const zip_magic = [_]u8{ 'P', 'K', 0x03, 0x04 };
const zip_empty = [_]u8{ 'P', 'K', 0x05, 0x06 }; // empty-archive EOCD seen first

/// First non-whitespace byte, or 0 if the slice is all whitespace/empty.
fn firstNonWs(bytes: []const u8) u8 {
    for (bytes) |b| {
        switch (b) {
            ' ', '\t', '\n', '\r', 0x0b, 0x0c => {},
            else => return b,
        }
    }
    return 0;
}

/// Detect format from content, with an optional filename/extension hint used
/// only to disambiguate text-shaped families (csv vs tsv, json vs ndjson, md).
pub fn detect(bytes: []const u8, hint: ?[]const u8) Format {
    // 1. Hard binary signatures — unambiguous, magic-byte anchored.
    if (std.mem.startsWith(u8, bytes, "%PDF-")) return .pdf;
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], &cfb_magic)) return .legacy_doc;
    if (bytes.len >= 2 and bytes[0] == 0x1f and bytes[1] == 0x8b) return .gzip;

    // Parquet is framed by "PAR1" at both ends (magic header + footer).
    if (bytes.len >= 8 and
        std.mem.eql(u8, bytes[0..4], "PAR1") and
        std.mem.eql(u8, bytes[bytes.len - 4 ..], "PAR1")) return .parquet;

    // ZIP container: could be DOCX/XLSX/PPTX or a plain zip. Peek the local
    // file name that follows the 30-byte local-file header.
    if (std.mem.startsWith(u8, bytes, &zip_magic) or
        std.mem.startsWith(u8, bytes, &zip_empty))
    {
        if (zipLooksLikeOfficeWord(bytes)) return .docx;
        return .docx; // default OOXML; non-word zips still route through the zip reader
    }

    // 2. Text-shaped families. Use the structural first byte, then the hint.
    const c0 = firstNonWs(bytes);
    if (c0 == '{' or c0 == '[') {
        // JSON vs NDJSON vs Iceberg-metadata. Iceberg table metadata is JSON
        // carrying "format-version" + "table-uuid"; recognize it specifically.
        if (looksLikeIcebergMetadata(bytes)) return .iceberg;
        if (looksLikeNdjson(bytes)) return .ndjson;
        return .json;
    }
    if (c0 == '<') {
        if (caseContains(bytes[0..@min(bytes.len, 256)], "<html")) return .html;
        return .xml;
    }

    // 3. Extension hint for the remaining plain-text families.
    if (hint) |h| {
        if (endsWithIgnoreCase(h, ".tsv")) return .tsv;
        if (endsWithIgnoreCase(h, ".csv")) return .csv;
        if (endsWithIgnoreCase(h, ".ndjson") or endsWithIgnoreCase(h, ".jsonl")) return .ndjson;
        if (endsWithIgnoreCase(h, ".json")) return .json;
        if (endsWithIgnoreCase(h, ".md") or endsWithIgnoreCase(h, ".markdown")) return .markdown;
        if (endsWithIgnoreCase(h, ".xml")) return .xml;
        if (endsWithIgnoreCase(h, ".html") or endsWithIgnoreCase(h, ".htm")) return .html;
        if (endsWithIgnoreCase(h, ".tsv")) return .tsv;
    }

    // 4. Delimiter sniffing for headerless tabular text.
    if (sniffTabular(bytes)) |fmt| return fmt;

    if (c0 == 0) return .unknown; // empty / all whitespace
    return .text;
}

/// Heuristic: a ZIP whose first local entry names a `word/` or
/// `[Content_Types].xml` member is an OOXML Word document.
fn zipLooksLikeOfficeWord(bytes: []const u8) bool {
    if (bytes.len < 30) return false;
    const name_len = std.mem.readInt(u16, bytes[26..28], .little);
    const start: usize = 30;
    const end = std.math.add(usize, start, name_len) catch return false;
    if (end > bytes.len) return false;
    const name = bytes[start..end];
    return std.mem.startsWith(u8, name, "word/") or
        std.mem.eql(u8, name, "[Content_Types].xml") or
        std.mem.startsWith(u8, name, "_rels/");
}

fn looksLikeIcebergMetadata(bytes: []const u8) bool {
    const window = bytes[0..@min(bytes.len, 1024)];
    return std.mem.indexOf(u8, window, "\"format-version\"") != null and
        (std.mem.indexOf(u8, window, "\"table-uuid\"") != null or
            std.mem.indexOf(u8, window, "\"current-snapshot-id\"") != null);
}

/// NDJSON: multiple top-level JSON values, one per line. Detect by a closing
/// brace/bracket/quote/digit immediately before a newline that is itself
/// followed by another value opener.
fn looksLikeNdjson(bytes: []const u8) bool {
    var i: usize = 0;
    var lines_with_values: usize = 0;
    const limit = @min(bytes.len, 4096);
    while (i < limit) {
        // skip to end of line
        const nl = std.mem.indexOfScalarPos(u8, bytes[0..limit], i, '\n') orelse break;
        const line = std.mem.trim(u8, bytes[i..nl], " \t\r");
        if (line.len > 0) {
            const a = line[0];
            const z = line[line.len - 1];
            const opens = a == '{' or a == '[';
            const closes = z == '}' or z == ']';
            if (opens and closes) lines_with_values += 1 else return false;
        }
        i = nl + 1;
    }
    return lines_with_values >= 2;
}

/// Count a delimiter on the first up-to-8 non-empty lines; consistent multi-col
/// rows with commas → csv, tabs → tsv.
fn sniffTabular(bytes: []const u8) ?Format {
    var line_it = std.mem.splitScalar(u8, bytes[0..@min(bytes.len, 4096)], '\n');
    var rows: usize = 0;
    var comma_consistent = true;
    var tab_consistent = true;
    var first_commas: usize = 0;
    var first_tabs: usize = 0;
    while (line_it.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r");
        if (line.len == 0) continue;
        const commas = std.mem.count(u8, line, ",");
        const tabs = std.mem.count(u8, line, "\t");
        if (rows == 0) {
            first_commas = commas;
            first_tabs = tabs;
        } else {
            if (commas != first_commas) comma_consistent = false;
            if (tabs != first_tabs) tab_consistent = false;
        }
        rows += 1;
        if (rows >= 8) break;
    }
    if (rows >= 2 and first_tabs >= 1 and tab_consistent) return .tsv;
    if (rows >= 2 and first_commas >= 1 and comma_consistent) return .csv;
    return null;
}

fn endsWithIgnoreCase(haystack: []const u8, suffix: []const u8) bool {
    if (haystack.len < suffix.len) return false;
    const tail = haystack[haystack.len - suffix.len ..];
    for (tail, suffix) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

fn caseContains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (haystack[i .. i + needle.len], needle) |a, b| {
            if (std.ascii.toLower(a) != std.ascii.toLower(b)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

// ── Tests ─────────────────────────────────────────────────────────────
const testing = std.testing;

test "detect: binary signatures" {
    try testing.expectEqual(Format.pdf, detect("%PDF-1.7\n...", null));
    try testing.expectEqual(Format.legacy_doc, detect(&cfb_magic, null));
    try testing.expectEqual(Format.parquet, detect("PAR1\x00\x00\x00\x00PAR1", null));
    try testing.expectEqual(Format.gzip, detect(&[_]u8{ 0x1f, 0x8b, 0x08 }, null));
}

test "detect: docx zip" {
    // local file header naming word/document.xml
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..4], &zip_magic);
    @memset(buf[4..26], 0);
    std.mem.writeInt(u16, buf[26..28], 18, .little); // name length
    @memset(buf[28..30], 0);
    @memcpy(buf[30..48], "word/document.xml "[0..18]);
    try testing.expectEqual(Format.docx, detect(buf[0..48], null));
}

test "detect: json vs ndjson vs iceberg" {
    try testing.expectEqual(Format.json, detect("  { \"a\": 1 }", null));
    try testing.expectEqual(Format.ndjson, detect("{\"a\":1}\n{\"b\":2}\n", null));
    try testing.expectEqual(Format.iceberg, detect(
        "{\"format-version\":2,\"table-uuid\":\"abc\"}",
        null,
    ));
}

test "detect: tabular + hints" {
    try testing.expectEqual(Format.csv, detect("a,b,c\n1,2,3\n4,5,6\n", null));
    try testing.expectEqual(Format.tsv, detect("a\tb\n1\t2\n", null));
    try testing.expectEqual(Format.markdown, detect("# Title\n\nbody", "notes.md"));
    try testing.expectEqual(Format.text, detect("just some prose here", null));
    try testing.expectEqual(Format.unknown, detect("   \n\t ", null));
}

test "detect: xml/html" {
    try testing.expectEqual(Format.xml, detect("<?xml version=\"1.0\"?><r/>", null));
    try testing.expectEqual(Format.html, detect("<!DOCTYPE html><html></html>", null));
}

test "fuzz: detect never panics on random bytes" {
    var prng = std.Random.DefaultPrng.init(0xD37EC7);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;
    for (0..2000) |_| {
        const len = rnd.intRangeLessThan(usize, 0, buf.len);
        for (buf[0..len]) |*b| b.* = rnd.int(u8);
        _ = detect(buf[0..len], if (rnd.boolean()) ".csv" else null);
    }
}
