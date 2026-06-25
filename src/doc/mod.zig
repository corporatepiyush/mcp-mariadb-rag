//! Document-extraction front door: detect format, dispatch to the right native
//! parser, return normalized text ready for the RAG chunker.
//!
//! Layering (Agent.md "flat layering, allocator flow through layers"): the
//! caller passes the request arena; every parser allocates only from it and the
//! arena reset frees the whole extraction in one shot. No parser leaks pointers
//! past this boundary — `Extracted.text` is owned by the caller's arena.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const detect = @import("detect.zig");
pub const Format = detect.Format;

const text_mod = @import("text.zig");
const csv_mod = @import("csv/csv.zig");
const json_mod = @import("json/json.zig");
const xml_mod = @import("xml.zig");
const docx_mod = @import("docx/docx.zig");
const pdf_mod = @import("pdf/pdf.zig");
const parquet_mod = @import("parquet/parquet.zig");
const iceberg_mod = @import("iceberg/iceberg.zig");
const legacy_doc_mod = @import("legacy_doc/doc.zig");
const inflate = @import("inflate.zig");

pub const pool = @import("pool.zig");

pub const Error = error{
    OutOfMemory,
    /// Format recognized but its extractor isn't implemented in this build yet.
    Pending,
    /// Format not handled at all (e.g. unknown binary).
    Unsupported,
    /// Container/stream was malformed.
    Corrupt,
    /// Member expected in a container was absent.
    NotFound,
};

pub const Extracted = struct {
    format: Format,
    text: []const u8,
    /// Format-specific unit count: records (csv/ndjson), paragraphs (docx),
    /// content streams (pdf), lines (text), schema fields (iceberg).
    units: usize,
    bytes_in: usize,
};

/// Detect and extract in one call. `hint` is an optional filename/extension.
pub fn extract(a: Allocator, bytes: []const u8, hint: ?[]const u8) Error!Extracted {
    const fmt = detect.detect(bytes, hint);
    return extractAs(a, bytes, fmt);
}

/// Extract treating the bytes as a known format (skips detection).
pub fn extractAs(a: Allocator, bytes: []const u8, fmt: Format) Error!Extracted {
    const r: struct { text: []const u8, units: usize } = switch (fmt) {
        .text, .markdown => blk: {
            const x = try mapErr(text_mod.toText(a, bytes));
            break :blk .{ .text = x.text, .units = x.units };
        },
        .csv => blk: {
            const x = try mapErr(csv_mod.toText(a, bytes, ','));
            break :blk .{ .text = x.text, .units = x.units };
        },
        .tsv => blk: {
            const x = try mapErr(csv_mod.toText(a, bytes, '\t'));
            break :blk .{ .text = x.text, .units = x.units };
        },
        .json => blk: {
            const x = try mapErr(json_mod.toText(a, bytes));
            break :blk .{ .text = x.text, .units = x.units };
        },
        .ndjson => blk: {
            const x = try mapErr(json_mod.toTextNd(a, bytes));
            break :blk .{ .text = x.text, .units = x.units };
        },
        .xml, .html => blk: {
            const x = try mapErr(xml_mod.toText(a, bytes));
            break :blk .{ .text = x.text, .units = x.units };
        },
        .docx => blk: {
            const x = docx_mod.toText(a, bytes) catch |e| return mapContainerErr(e);
            break :blk .{ .text = x.text, .units = x.units };
        },
        .pdf => blk: {
            const x = try mapErr(pdf_mod.toText(a, bytes));
            break :blk .{ .text = x.text, .units = x.units };
        },
        .iceberg => blk: {
            const x = iceberg_mod.toText(a, bytes) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NotIceberg => return error.Corrupt,
                else => return error.Corrupt,
            };
            break :blk .{ .text = x.text, .units = x.units };
        },
        // Recognized, extraction pending (validated for honest framing errors).
        .parquet => {
            _ = parquet_mod.locateFooter(bytes) catch return error.Corrupt;
            return error.Pending;
        },
        .legacy_doc => {
            _ = legacy_doc_mod.readHeader(bytes) catch return error.Corrupt;
            return error.Pending;
        },
        .gzip, .unknown => return error.Unsupported,
    };

    return .{ .format = fmt, .text = r.text, .units = r.units, .bytes_in = bytes.len };
}

fn mapErr(res: anytype) Error!@TypeOf(res catch unreachable) {
    return res catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.WriteFailed => error.OutOfMemory,
    };
}


fn mapContainerErr(e: anyerror) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.EntryNotFound, error.NotZip => error.NotFound,
        error.Unsupported => error.Unsupported,
        else => error.Corrupt,
    };
}

/// One-line human status string for an `Error` (for tool responses).
pub fn errorMessage(e: Error, fmt: Format) []const u8 {
    return switch (e) {
        error.OutOfMemory => "Out of memory during extraction",
        error.Pending => switch (fmt) {
            .parquet => "Recognized Parquet; columnar decode is pending (native reader in progress)",
            .legacy_doc => "Recognized legacy .doc (OLE2/CFB); text decode is pending (native reader in progress)",
            else => "Format recognized; extractor pending",
        },
        error.Unsupported => "Unsupported or unrecognized document format",
        error.Corrupt => "Document is corrupt or malformed",
        error.NotFound => "Expected container member not found",
    };
}

// ── Tests ─────────────────────────────────────────────────────────────
const testing = std.testing;

test "extract dispatches by detected format" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const csv = try extract(a, "a,b\n1,2\n", null);
    try testing.expectEqual(Format.csv, csv.format);
    try testing.expectEqualStrings("a b\n1 2\n", csv.text);

    const js = try extract(a, "{\"k\":\"v\"}", null);
    try testing.expectEqual(Format.json, js.format);
    try testing.expectEqualStrings("k v", js.text);

    const txt = try extract(a, "plain prose", null);
    try testing.expectEqual(Format.text, txt.format);
}

test "extract reports pending for parquet" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [17]u8 = undefined;
    @memcpy(buf[0..4], "PAR1");
    @memset(buf[4..9], 'M');
    std.mem.writeInt(u32, buf[9..13], 5, .little);
    @memcpy(buf[13..17], "PAR1");
    try testing.expectError(error.Pending, extract(arena.allocator(), &buf, null));
}

test "fuzz: extract never panics on random bytes" {
    var prng = std.Random.DefaultPrng.init(0xE47AC7);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;
    for (0..2000) |_| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const n = rnd.intRangeLessThan(usize, 0, buf.len);
        for (buf[0..n]) |*b| b.* = rnd.int(u8);
        _ = extract(arena.allocator(), buf[0..n], null) catch {};
    }
}
