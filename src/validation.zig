//! Input validation and SQL-safety helpers.
//!
//! Two distinct escaping contexts exist and must not be confused:
//!   * identifiers that we wrap in backticks (`table`, `index`, ...)
//!   * values we interpolate into single-quoted string literals
//!     (e.g. `WHERE TABLE_NAME = '...'` against information_schema)
//! Mixing them up is how SQL injection slips in, so each has its own routine.

const std = @import("std");

const Writer = std.Io.Writer;

/// MySQL's own identifier limit is 64; we allow a little slack but cap it so a
/// pathological argument cannot blow past validation.
pub const MAX_IDENTIFIER_LEN: usize = 64;

pub const ValidationError = error{
    InvalidParam,
    EmptySql,
    SqlTooLong,
    InvalidSqlPrefix,
    MultiStatement,
};

/// Validate a bare identifier (table/column/index/schema/view name). Restricts
/// to `[A-Za-z0-9_$]`, which by construction cannot contain a backtick, quote,
/// whitespace, or semicolon — eliminating injection through identifier params.
pub fn validateIdentifier(name: []const u8) ValidationError!void {
    if (name.len == 0 or name.len > MAX_IDENTIFIER_LEN) return error.InvalidParam;
    for (name) |ch| {
        const ok = (ch >= 'a' and ch <= 'z') or
            (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or
            ch == '_' or ch == '$';
        if (!ok) return error.InvalidParam;
    }
}

/// Write `name` as a backtick-quoted identifier, doubling any embedded
/// backticks. Use this for identifiers that have NOT been restricted by
/// `validateIdentifier` (it is always safe regardless).
pub fn writeQuotedIdent(w: *Writer, name: []const u8) Writer.Error!void {
    try w.writeByte('`');
    for (name) |ch| {
        if (ch == '`') try w.writeByte('`'); // double to escape
        try w.writeByte(ch);
    }
    try w.writeByte('`');
}

/// Allocating convenience wrapper around `writeQuotedIdent`.
pub fn quoteIdent(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var aw = Writer.Allocating.init(allocator);
    errdefer aw.deinit();
    try writeQuotedIdent(&aw.writer, name);
    return aw.toOwnedSlice();
}

/// Write `s` escaped for use inside a single-quoted SQL string literal
/// (doubling `'` and escaping backslash). The surrounding quotes are NOT
/// written. MariaDB runs with NO_BACKSLASH_ESCAPES off by default, so a
/// backslash is an escape character and must itself be doubled.
pub fn writeEscapedLiteral(w: *Writer, s: []const u8) Writer.Error!void {
    for (s) |ch| {
        switch (ch) {
            '\'' => try w.writeAll("''"),
            '\\' => try w.writeAll("\\\\"),
            0 => {}, // drop embedded NUL rather than truncate the C string
            else => try w.writeByte(ch),
        }
    }
}

/// Validate a single-statement SQL string whose first keyword must match
/// `allowed_prefix` (case-insensitive), rejecting multi-statement payloads.
pub fn validateSql(sql: []const u8, allowed_prefix: []const u8) ValidationError!void {
    if (sql.len == 0) return error.EmptySql;
    if (sql.len > 10_000) return error.SqlTooLong;
    const trimmed = std.mem.trim(u8, sql, " \t\n\r");
    if (trimmed.len == 0) return error.EmptySql;

    const first_word_end = std.mem.indexOfScalar(u8, trimmed, ' ') orelse trimmed.len;
    const first_word = trimmed[0..first_word_end];
    if (!std.ascii.eqlIgnoreCase(first_word, allowed_prefix)) return error.InvalidSqlPrefix;

    const body = if (std.mem.endsWith(u8, trimmed, ";")) trimmed[0 .. trimmed.len - 1] else trimmed;
    if (findUnquotedSemicolon(body) != null) return error.MultiStatement;
}

/// Find the first `;` that is not inside a string/identifier quote or comment.
/// Used to reject stacked queries.
fn findUnquotedSemicolon(sql: []const u8) ?usize {
    var i: usize = 0;
    while (i < sql.len) {
        switch (sql[i]) {
            '\'' => i = skipQuoted(sql, i, '\'', true),
            '"' => i = skipQuoted(sql, i, '"', true),
            '`' => i = skipQuoted(sql, i, '`', false),
            '-' => {
                if (i + 1 < sql.len and sql[i + 1] == '-') {
                    i += 2;
                    while (i < sql.len and sql[i] != '\n') i += 1;
                } else i += 1;
            },
            '/' => {
                if (i + 1 < sql.len and sql[i + 1] == '*') {
                    i += 2;
                    while (i + 1 < sql.len and !(sql[i] == '*' and sql[i + 1] == '/')) i += 1;
                    i += 2;
                } else i += 1;
            },
            ';' => return i,
            else => i += 1,
        }
    }
    return null;
}

/// Skip a quoted run starting at the opening quote `sql[start]`. When
/// `doubling` is true a doubled quote (`''`) is treated as an escaped quote and
/// does not close the string. Returns the index just past the closing quote.
fn skipQuoted(sql: []const u8, start: usize, quote: u8, doubling: bool) usize {
    var i = start + 1;
    while (i < sql.len) {
        if (sql[i] == quote) {
            if (doubling and i + 1 < sql.len and sql[i + 1] == quote) {
                i += 2;
                continue;
            }
            return i + 1;
        }
        i += 1;
    }
    return i;
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const testing = std.testing;

test "validateIdentifier accepts/rejects" {
    try validateIdentifier("users");
    try validateIdentifier("user_table$2");
    try validateIdentifier("9lives"); // leading digit allowed (MySQL permits)
    try testing.expectError(error.InvalidParam, validateIdentifier(""));
    try testing.expectError(error.InvalidParam, validateIdentifier("a b"));
    try testing.expectError(error.InvalidParam, validateIdentifier("a;b"));
    try testing.expectError(error.InvalidParam, validateIdentifier("a'b"));
    try testing.expectError(error.InvalidParam, validateIdentifier("a`b"));
    try testing.expectError(error.InvalidParam, validateIdentifier("a" ** 65));
}

test "writeQuotedIdent doubles backticks" {
    var buf: [64]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeQuotedIdent(&w, "we`ird");
    try testing.expectEqualStrings("`we``ird`", w.buffered());
}

test "writeEscapedLiteral doubles quotes and backslashes" {
    var buf: [64]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeEscapedLiteral(&w, "O'Brien\\x");
    try testing.expectEqualStrings("O''Brien\\\\x", w.buffered());
}

test "validateSql prefix + length" {
    try validateSql("SELECT 1", "SELECT");
    try validateSql("  select * from t  ", "SELECT");
    try testing.expectError(error.EmptySql, validateSql("", "SELECT"));
    try testing.expectError(error.EmptySql, validateSql("   ", "SELECT"));
    try testing.expectError(error.InvalidSqlPrefix, validateSql("DROP TABLE t", "SELECT"));
    try testing.expectError(error.SqlTooLong, validateSql("SELECT " ++ ("1" ** 10_000), "SELECT"));
}

test "validateSql rejects stacked statements" {
    try testing.expectError(error.MultiStatement, validateSql("SELECT 1; DROP TABLE t", "SELECT"));
    // a trailing semicolon is fine
    try validateSql("SELECT 1;", "SELECT");
    // semicolon inside a string literal is fine
    try validateSql("SELECT ';'", "SELECT");
    try validateSql("SELECT '''; not a statement'", "SELECT");
    // semicolon inside a comment is fine
    try validateSql("SELECT 1 -- ; not a statement", "SELECT");
    try validateSql("SELECT 1 /* ; */ ", "SELECT");
}
