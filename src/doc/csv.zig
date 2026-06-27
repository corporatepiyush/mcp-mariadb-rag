//! RFC 4180 CSV / TSV reader, streaming and SIMD-accelerated.
//!
//! Design (Agent.md):
//!   * Single linear pass, stride-1, prefetch-friendly. Ordinary field bytes are
//!     skipped in 16-byte SIMD strides; the scalar path only runs at structural
//!     bytes (delimiter, quote, CR, LF).
//!   * Zero-copy for the common case: an unquoted field is a borrowed sub-slice
//!     of the input. Only quoted fields containing an escaped `""` are
//!     materialized (unescaped) into the arena.
//!   * Output is written straight into a caller `Writer` — no intermediate
//!     row/field container, no per-cell allocation. The text form joins cells
//!     with a single space and records with '\n', which is what the RAG chunker
//!     consumes downstream.
//!
//! Untrusted-input discipline: every slice returned falls within the input; the
//! scanner only ever advances. A lone trailing quote or delimiter cannot index
//! out of bounds (all reads are guarded by `i < len`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Error = error{OutOfMemory} || Writer.Error;

pub const Result = struct {
    text: []u8,
    units: usize, // record count
};

/// SIMD width for the skip-ordinary scan. 16 bytes is the SSE/NEON sweet spot
/// and degrades cleanly to scalar on the tail.
const lane = 16;
const Block = @Vector(lane, u8);

/// Return the index of the next structural byte at or after `from`:
/// the delimiter, a double-quote, CR or LF. Ordinary runs are skipped a vector
/// at a time. Returns `bytes.len` if none remain.
fn nextStructural(bytes: []const u8, from: usize, delim: u8) usize {
    var i = from;
    const len = bytes.len;
    const vdelim: Block = @splat(delim);
    const vquote: Block = @splat('"');
    const vcr: Block = @splat('\r');
    const vlf: Block = @splat('\n');

    while (i + lane <= len) {
        const chunk: Block = bytes[i..][0..lane].*;
        const hits = (chunk == vdelim) | (chunk == vquote) |
            (chunk == vcr) | (chunk == vlf);
        if (std.simd.firstTrue(hits)) |k| return i + k;
        i += lane;
    }
    // Scalar tail.
    while (i < len) : (i += 1) {
        const c = bytes[i];
        if (c == delim or c == '"' or c == '\r' or c == '\n') return i;
    }
    return len;
}

/// Parse CSV/TSV and render the text form into `w`. Returns the record count.
pub fn render(a: Allocator, bytes: []const u8, delim: u8, w: *Writer) Error!usize {
    var i: usize = 0;
    const len = bytes.len;
    var records: usize = 0;
    var field_in_record: usize = 0;
    var any_field_in_record = false;

    while (i < len) {
        // Parse one field.
        if (bytes[i] == '"') {
            // Quoted field: consume until the closing quote, handling "" escapes.
            i += 1;
            const start = i;
            var needs_unescape = false;
            var end: usize = start;
            scan: while (i < len) {
                const s = nextStructuralInQuotes(bytes, i);
                if (s >= len) {
                    end = len;
                    i = len;
                    break :scan;
                }
                // s points at a '"'
                if (s + 1 < len and bytes[s + 1] == '"') {
                    needs_unescape = true;
                    i = s + 2; // skip the escaped pair, stay in quotes
                    continue;
                }
                end = s; // closing quote
                i = s + 1;
                break :scan;
            }
            if (field_in_record > 0) try w.writeByte(' ');
            try writeField(a, w, bytes[start..end], needs_unescape);
            field_in_record += 1;
            any_field_in_record = true;
        } else {
            const s = nextStructural(bytes, i, delim);
            if (field_in_record > 0) try w.writeByte(' ');
            try w.writeAll(bytes[i..s]);
            if (bytes[i..s].len > 0) any_field_in_record = true;
            field_in_record += 1;
            i = s;
        }

        // Field separator vs record terminator.
        if (i >= len) break;
        const c = bytes[i];
        if (c == delim) {
            i += 1;
            continue;
        }
        if (c == '\r' or c == '\n') {
            // consume CRLF or LF or CR
            if (c == '\r' and i + 1 < len and bytes[i + 1] == '\n') i += 2 else i += 1;
            if (any_field_in_record) {
                try w.writeByte('\n');
                records += 1;
            }
            field_in_record = 0;
            any_field_in_record = false;
            continue;
        }
        // c == '"' mid-field (malformed) — treat as ordinary, advance one.
        try w.writeByte(c);
        i += 1;
    }
    // Terminate the final record (input without a trailing newline).
    if (any_field_in_record) {
        try w.writeByte('\n');
        records += 1;
    }
    return records;
}

/// Inside a quoted field only `"` is structural.
fn nextStructuralInQuotes(bytes: []const u8, from: usize) usize {
    var i = from;
    const len = bytes.len;
    const vquote: Block = @splat('"');
    while (i + lane <= len) {
        const chunk: Block = bytes[i..][0..lane].*;
        const hits = chunk == vquote;
        if (std.simd.firstTrue(hits)) |k| return i + k;
        i += lane;
    }
    while (i < len) : (i += 1) if (bytes[i] == '"') return i;
    return len;
}

/// Write a quoted field's contents, unescaping `""` -> `"` only when needed.
fn writeField(a: Allocator, w: *Writer, raw: []const u8, needs_unescape: bool) Error!void {
    if (!needs_unescape) {
        try w.writeAll(raw);
        return;
    }
    _ = a;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '"' and i + 1 < raw.len and raw[i + 1] == '"') {
            try w.writeByte('"');
            i += 2;
        } else {
            try w.writeByte(raw[i]);
            i += 1;
        }
    }
}

/// Convenience: parse into an owned text buffer in `a`.
pub fn toText(a: Allocator, bytes: []const u8, delim: u8) Error!Result {
    var aw = Writer.Allocating.init(a);
    errdefer aw.deinit();
    const units = try render(a, bytes, delim, &aw.writer);
    return .{ .text = try aw.toOwnedSlice(), .units = units };
}
