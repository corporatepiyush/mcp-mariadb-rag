const std = @import("std");
const testing = std.testing;
const validation = @import("../src/validation.zig");

const Writer = std.Io.Writer;

fn renderAlloc(comptime f: anytype, args: anytype) ![]u8 {
    var aw = Writer.Allocating.init(testing.allocator);
    defer aw.deinit();
    try @call(.auto, f, .{&aw.writer} ++ args);
    return aw.toOwnedSlice();
}

test "writeQuotedIdent: empty name" {
    const buf = try renderAlloc(validation.writeQuotedIdent, .{""});
    defer testing.allocator.free(buf);
    try testing.expectEqualStrings("``", buf);
}

test "writeQuotedIdent: only backticks" {
    const buf = try renderAlloc(validation.writeQuotedIdent, .{"``"});
    defer testing.allocator.free(buf);
    try testing.expectEqualStrings("``````", buf);
}

test "writeEscapedLiteral: empty string" {
    const buf = try renderAlloc(validation.writeEscapedLiteral, .{""});
    defer testing.allocator.free(buf);
    try testing.expectEqualStrings("", buf);
}

test "writeEscapedLiteral: NUL byte dropped" {
    const buf = try renderAlloc(validation.writeEscapedLiteral, .{&[_]u8{ 0x61, 0x00, 0x62 }});
    defer testing.allocator.free(buf);
    try testing.expectEqualStrings("ab", buf);
}

test "writeEscapedLiteral: only special chars" {
    const buf = try renderAlloc(validation.writeEscapedLiteral, .{"'\\"});
    defer testing.allocator.free(buf);
    try testing.expectEqualStrings("''\\\\", buf);
}

test "writeEscapedLiteral: no special chars" {
    const buf = try renderAlloc(validation.writeEscapedLiteral, .{"hello world"});
    defer testing.allocator.free(buf);
    try testing.expectEqualStrings("hello world", buf);
}

test "quoteIdent allocating wrapper" {
    const q = try validation.quoteIdent(testing.allocator, "users");
    defer testing.allocator.free(q);
    try testing.expectEqualStrings("`users`", q);
}

test "quoteIdent with backtick" {
    const q = try validation.quoteIdent(testing.allocator, "we`rd");
    defer testing.allocator.free(q);
    try testing.expectEqualStrings("`we``rd`", q);
}

test "validateSql: semicolon inside backtick identifier" {
    try validation.validateSql("SELECT `a;b` FROM t", "SELECT");
}

test "validateSql: semicolon inside doubled single-quote string" {
    try validation.validateSql("SELECT 'a'';b'", "SELECT");
}

test "validateSql: semicolon inside doubled double-quote string" {
    try validation.validateSql("SELECT \"a\"\"  ;  b\"", "SELECT");
}

test "validateSql: block comment containing semicolon" {
    try validation.validateSql("SELECT 1 /* ; still in comment */", "SELECT");
}

test "validateSql: single-line comment at EOF (no newline)" {
    try validation.validateSql("SELECT 1 -- no newline at end", "SELECT");
}

test "validateSql: dashes inside string not confused with comment" {
    try validation.validateSql("SELECT '--'", "SELECT");
}

test "validateSql: comment-only SQL has no valid prefix" {
    try testing.expectError(error.InvalidSqlPrefix, validation.validateSql("-- just a comment", "SELECT"));
    try testing.expectError(error.InvalidSqlPrefix, validation.validateSql("/* just a comment */", "SELECT"));
}

test "validateSql: only whitespace rejected as empty" {
    try testing.expectError(error.EmptySql, validation.validateSql("   ", "SELECT"));
}

test "validateIdentifier: max valid length" {
    try validation.validateIdentifier("a" ** 64);
}

test "validateIdentifier: dollar signs allowed" {
    try validation.validateIdentifier("$table_1$");
}

test "validateIdentifier: rejects null byte" {
    try testing.expectError(error.InvalidParam, validation.validateIdentifier(&[_]u8{ 0x61, 0x00, 0x62 }));
}

test "validateIdentifier: underscores and digits" {
    try validation.validateIdentifier("_9");
    try validation.validateIdentifier("abc_123_DEF");
}

// ---- fuzzing --------------------------------------------------------------

test "fuzz: validateIdentifier never panics on random byte sequences" {
    var prng = std.Random.DefaultPrng.init(0xCAFE);
    const rnd = prng.random();
    var buf: [128]u8 = undefined;

    for (0..500) |_| {
        const len = rnd.intRangeLessThan(usize, 0, buf.len);
        const s = buf[0..len];
        for (s) |*b| b.* = rnd.int(u8);

        validation.validateIdentifier(s) catch {};
    }
}

test "fuzz: validateSql never panics on random printable strings" {
    var prng = std.Random.DefaultPrng.init(0xABBA);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;

    for (0..500) |_| {
        const len = rnd.intRangeLessThan(usize, 0, buf.len);
        const s = buf[0..len];
        for (s) |*b| b.* = rnd.intRangeAtMost(u8, 32, 126);

        validation.validateSql(s, "SELECT") catch {};
    }
}

test "fuzz: validateSql all four prefix types" {
    var prng = std.Random.DefaultPrng.init(0x1234);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;
    const prefixes = [_][]const u8{ "SELECT", "INSERT", "UPDATE", "DELETE" };

    for (0..500) |_| {
        const len = rnd.intRangeLessThan(usize, 0, buf.len);
        const s = buf[0..len];
        for (s) |*b| b.* = rnd.intRangeAtMost(u8, 32, 126);
        const prefix = prefixes[rnd.intRangeLessThan(usize, 0, prefixes.len)];

        validation.validateSql(s, prefix) catch {};
    }
}

test "fuzz: validateSql with arbitrary byte sequences (including multi-byte)" {
    var prng = std.Random.DefaultPrng.init(0xFFFF);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;

    for (0..500) |_| {
        const len = rnd.intRangeLessThan(usize, 0, buf.len);
        const s = buf[0..len];
        for (s) |*b| b.* = rnd.int(u8);

        validation.validateSql(s, "SELECT") catch {};
    }
}
