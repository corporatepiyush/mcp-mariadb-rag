//! JSON serialization helpers built on the Zig 0.16 `std.Io.Writer` interface.
//!
//! Everything writes into a caller-supplied `*std.Io.Writer`, so the same code
//! serves the streaming stdout path and unit tests
//! (via `std.Io.Writer.fixed` / `.Allocating`). Failure is always
//! `error.WriteFailed` (the sink decides what that means: short buffer, OOM,
//! socket error).

const std = @import("std");
pub const types = @import("types.zig");

const Writer = std.Io.Writer;
pub const Error = Writer.Error;
const Value = std.json.Value;

/// Write `s` with JSON string escaping applied, without surrounding quotes.
pub fn writeEscaped(w: *Writer, s: []const u8) Error!void {
    // Emit unescaped runs in bulk and only break out for characters that
    // require escaping; this keeps the common case (no escapes) to a single
    // `writeAll` instead of a byte-at-a-time loop.
    var start: usize = 0;
    for (s, 0..) |ch, i| {
        const esc: ?[]const u8 = switch (ch) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0x08 => "\\b",
            0x0c => "\\f",
            0...7, 0x0b, 0x0e...0x1f => null, // other control chars: \u00XX below
            else => continue,
        };
        try w.writeAll(s[start..i]);
        if (esc) |e| {
            try w.writeAll(e);
        } else {
            try w.print("\\u{x:0>4}", .{ch});
        }
        start = i + 1;
    }
    try w.writeAll(s[start..]);
}

/// Write a complete, quoted JSON string.
pub fn writeQuoted(w: *Writer, s: []const u8) Error!void {
    try w.writeByte('"');
    try writeEscaped(w, s);
    try w.writeByte('"');
}

/// Serialize a JSON-RPC `id`. Per the spec an id may be a string, a number, or
/// null; anything else (or absent) is rendered as `null`.
pub fn writeRpcId(w: *Writer, id: ?Value) Error!void {
    const v = id orelse return w.writeAll("null");
    switch (v) {
        .integer => |n| try w.print("{d}", .{n}),
        .float => |f| try w.print("{d}", .{f}),
        .number_string => |s| try w.writeAll(s),
        .string => |s| try writeQuoted(w, s),
        .null => try w.writeAll("null"),
        else => try w.writeAll("null"),
    }
}

/// True when `s` is a syntactically valid JSON number, so it can be emitted as
/// a bare number token without quoting (preserving exact digits — no float
/// round-trip for big integers or decimals).
pub fn isJsonNumber(s: []const u8) bool {
    if (s.len == 0) return false;
    var i: usize = 0;
    if (s[i] == '-') i += 1;
    if (i == s.len) return false;

    // integer part
    if (s[i] == '0') {
        i += 1;
    } else if (s[i] >= '1' and s[i] <= '9') {
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
    } else return false;

    // fraction
    if (i < s.len and s[i] == '.') {
        i += 1;
        const frac_start = i;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        if (i == frac_start) return false;
    }

    // exponent
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        const exp_start = i;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        if (i == exp_start) return false;
    }

    return i == s.len;
}

/// Render a single cell. `null` is SQL NULL → JSON `null`. Numeric columns emit
/// a bare number token when well-formed, else a quoted string. Text columns are
/// always quoted.
fn writeCell(w: *Writer, value: ?[]const u8, kind: types.ColumnKind) Error!void {
    const v = value orelse return w.writeAll("null");
    if (kind == .numeric and isJsonNumber(v)) {
        try w.writeAll(v);
    } else {
        try writeQuoted(w, v);
    }
}

/// Serialize a result set as
/// `{"columns":[...],"rows":[[...],...],"row_count":N}`.
pub fn writeRows(
    w: *Writer,
    rows: []const types.Row,
    col_names: ?[]const []const u8,
    col_kinds: ?[]const types.ColumnKind,
) Error!void {
    try w.writeByte('{');

    if (col_names) |cols| {
        try w.writeAll("\"columns\":[");
        for (cols, 0..) |c, i| {
            if (i > 0) try w.writeByte(',');
            try writeQuoted(w, c);
        }
        try w.writeAll("],");
    }

    try w.writeAll("\"rows\":[");
    for (rows, 0..) |row, ri| {
        if (ri > 0) try w.writeByte(',');
        try w.writeByte('[');
        for (row.values, 0..) |val, vi| {
            if (vi > 0) try w.writeByte(',');
            const kind: types.ColumnKind = if (col_kinds) |ks|
                (if (vi < ks.len) ks[vi] else .text)
            else
                .text;
            try writeCell(w, val, kind);
        }
        try w.writeByte(']');
    }
    try w.writeAll("],\"row_count\":");
    try w.print("{d}", .{rows.len});
    try w.writeByte('}');
}

/// Serialize the affected-rows summary for a non-result-set statement.
pub fn writeAffected(w: *Writer, affected_rows: u64, insert_id: u64) Error!void {
    try w.print("{{\"rows_affected\":{d},\"insert_id\":{d}}}", .{ affected_rows, insert_id });
}

/// Serialize a whole `QueryResult` to its JSON payload form.
pub fn writeQueryResult(w: *Writer, result: types.QueryResult) Error!void {
    if (result.rows) |rows| {
        try writeRows(w, rows, result.column_names, result.column_kinds);
    } else {
        try writeAffected(w, result.affected_rows, result.insert_id);
    }
}

/// Serialize a DDL success object: `{"status":"success","action":A,"<label>":N}`.
pub fn writeStatus(w: *Writer, action: []const u8, label: []const u8, name: []const u8) Error!void {
    try w.writeAll("{\"status\":\"success\",\"action\":");
    try writeQuoted(w, action);
    try w.writeByte(',');
    try writeQuoted(w, label);
    try w.writeByte(':');
    try writeQuoted(w, name);
    try w.writeByte('}');
}
