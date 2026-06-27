//! Tests for src/validation.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/validation.zig");
const Io = std.Io;

const Writer = std.Io.Writer;
const skipQuoted = srcmod.skipQuoted;
const validateIdentifier = srcmod.validateIdentifier;
const validateSql = srcmod.validateSql;
const writeEscapedLiteral = srcmod.writeEscapedLiteral;
const writeQuotedIdent = srcmod.writeQuotedIdent;

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------


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

// ---- property/fuzz tests for the injection-defense invariants ----------------
// These are the security-critical functions: any input, no matter how hostile,
// must produce output that cannot break out of its quoting context.

/// The core literal-escaping invariant: in the output every `'` and every `\`
/// occurs only as a doubled pair, and there is no NUL — so wrapping the output in
/// single quotes can never terminate the literal early. Returns false on any
/// lone quote/backslash, which would be an injection.
fn literalIsUnbreakable(out: []const u8) bool {
    var i: usize = 0;
    while (i < out.len) {
        switch (out[i]) {
            '\'' => {
                if (i + 1 >= out.len or out[i + 1] != '\'') return false;
                i += 2;
            },
            '\\' => {
                if (i + 1 >= out.len or out[i + 1] != '\\') return false;
                i += 2;
            },
            0 => return false,
            else => i += 1,
        }
    }
    return true;
}

test "fuzz: writeEscapedLiteral output can never break out of a string literal" {
    var prng = std.Random.DefaultPrng.init(0x5A1E_9000);
    const rnd = prng.random();
    var in_buf: [128]u8 = undefined;
    var out_buf: [512]u8 = undefined; // worst case 2x + slack

    for (0..5000) |_| {
        const len = rnd.intRangeAtMost(usize, 0, in_buf.len);
        for (in_buf[0..len]) |*b| b.* = rnd.int(u8); // every byte incl. ' \ NUL
        var w = Writer.fixed(&out_buf);
        try writeEscapedLiteral(&w, in_buf[0..len]);
        try testing.expect(literalIsUnbreakable(w.buffered()));
    }
}

test "fuzz: writeQuotedIdent is backtick-wrapped with every inner backtick doubled" {
    var prng = std.Random.DefaultPrng.init(0xB17C_0DE);
    const rnd = prng.random();
    var in_buf: [64]u8 = undefined;
    var out_buf: [256]u8 = undefined;

    for (0..5000) |_| {
        const len = rnd.intRangeAtMost(usize, 0, in_buf.len);
        for (in_buf[0..len]) |*b| b.* = rnd.int(u8);
        var w = Writer.fixed(&out_buf);
        try writeQuotedIdent(&w, in_buf[0..len]);
        const out = w.buffered();
        try testing.expect(out.len >= 2 and out[0] == '`' and out[out.len - 1] == '`');
        // Every backtick in the body (excluding the wrappers) must be doubled.
        const body = out[1 .. out.len - 1];
        var i: usize = 0;
        while (i < body.len) : (i += 1) {
            if (body[i] == '`') {
                try testing.expect(i + 1 < body.len and body[i + 1] == '`');
                i += 1;
            }
        }
    }
}

test "fuzz: validateSql never panics or hangs on random bytes" {
    var prng = std.Random.DefaultPrng.init(0x5A1_DA7A);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;
    // Alphabet rich in the parser's special bytes to exercise the quote/comment
    // state machine and skipQuoted's bounds.
    const alphabet = "SELECT 'abc\"`-/*;\n\\";

    for (0..5000) |_| {
        const len = rnd.intRangeAtMost(usize, 0, buf.len);
        for (buf[0..len]) |*b| b.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];
        validateSql(buf[0..len], "SELECT") catch {}; // any error is fine; must return
    }
}
