//! Tests for src/doc/detect.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/doc/detect.zig");

const Format = srcmod.Format;
const cfb_magic = srcmod.cfb_magic;
const detect = srcmod.detect;
const zip_magic = srcmod.zip_magic;

// ── Tests ─────────────────────────────────────────────────────────────

test "detect: binary signatures" {
    try testing.expectEqual(Format.pdf, detect("%PDF-1.7\n...", null));
    try testing.expectEqual(Format.legacy_doc, detect(&cfb_magic, null));
    try testing.expectEqual(Format.parquet, detect("PAR1\x00\x00\x00\x00PAR1", null));
    try testing.expectEqual(Format.gzip, detect(&[_]u8{ 0x1f, 0x8b, 0x08 }, null));
}

test "detect: arrow IPC file and stream framings" {
    // File format: ARROW1 magic at both ends.
    try testing.expectEqual(Format.arrow, detect("ARROW1\x00\x00....ARROW1", null));
    // Stream format: leading 0xFFFFFFFF continuation marker.
    try testing.expectEqual(Format.arrow, detect(&[_]u8{ 0xff, 0xff, 0xff, 0xff, 0x10, 0, 0, 0 }, null));
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
