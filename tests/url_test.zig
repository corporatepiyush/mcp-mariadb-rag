//! URL parser edge cases beyond the inline tests in `url.zig`.
//!
//! Focus: boundary conditions, malformed inputs, password variants, IPv6
//! (not yet supported — document current behaviour), and encoding of special
//! characters in each URL component.

const std = @import("std");
const testing = std.testing;
const url = @import("../src/url.zig");

// ---- scheme --------------------------------------------------------------

test "parse: wrong scheme casing" {
    try testing.expectError(error.UnsupportedScheme, url.parse("MYSQL://host/db"));
    try testing.expectError(error.UnsupportedScheme, url.parse("MySql://host/db"));
}

test "parse: missing scheme separator" {
    try testing.expectError(error.UnsupportedScheme, url.parse("mysql:/host/db"));
}

test "parse: bare scheme" {
    try testing.expectError(error.UnsupportedScheme, url.parse("mysql:"));
}

// ---- user / password -----------------------------------------------------

test "parse: user with colon but no password" {
    const p = try url.parse("mysql://user:@host/db");
    try testing.expectEqualStrings("user", p.user.?);
    try testing.expect(p.pass == null);
}

test "parse: password with special chars" {
    // URL-encoded or raw pass through; the parser does not un-pct-encode
    const p = try url.parse("mysql://user:p%40ss@host/db");
    try testing.expectEqualStrings("user", p.user.?);
    try testing.expectEqualStrings("p%40ss", p.pass.?);
}

test "parse: user with at in password" {
    // The parser splits on the first '@', so 'p' is the password and
    // the host portion becomes 'ss@host/db'. Passwords containing '@'
    // are not supported by the current parser.
    const p = try url.parse("mysql://user:p@ss@host/db");
    try testing.expectEqualStrings("user", p.user.?);
    try testing.expectEqualStrings("p", p.pass.?);
    try testing.expectEqualStrings("ss@host", p.host.?);
}

test "parse: no userinfo" {
    const p = try url.parse("mysql://host/db");
    try testing.expect(p.user == null);
    try testing.expect(p.pass == null);
    try testing.expectEqualStrings("host", p.host.?);
}

// ---- host ----------------------------------------------------------------

test "parse: IPv4 host" {
    const p = try url.parse("mysql://user@192.168.1.1:3306/db");
    try testing.expectEqualStrings("192.168.1.1", p.host.?);
    try testing.expectEqual(@as(u16, 3306), p.port);
}

test "parse: host with trailing dot (FQDN)" {
    const p = try url.parse("mysql://user@host./db");
    try testing.expectEqualStrings("host.", p.host.?);
}

test "parse: no host (empty after @)" {
    const p = try url.parse("mysql://user@/db");
    try testing.expect(p.host == null);
    try testing.expectEqualStrings("db", p.db.?);
}

// ---- port ----------------------------------------------------------------

test "parse: explicit default port" {
    const p = try url.parse("mysql://host:3306/db");
    try testing.expectEqual(@as(u16, 3306), p.port);
}

test "parse: non-numeric port falls back" {
    try testing.expectEqual(@as(u16, url.DEFAULT_PORT), (try url.parse("mysql://host:port/db")).port);
    try testing.expectEqual(@as(u16, url.DEFAULT_PORT), (try url.parse("mysql://host:-1/db")).port);
    try testing.expectEqual(@as(u16, url.DEFAULT_PORT), (try url.parse("mysql://host:99999/db")).port);
}

test "parse: port with trailing colon" {
    try testing.expectEqual(@as(u16, url.DEFAULT_PORT), (try url.parse("mysql://host:/db")).port);
}

// ---- database path -------------------------------------------------------

test "parse: database with slash in name" {
    // The parser takes everything after the first '/' as the database name.
    const p = try url.parse("mysql://host/a/b");
    try testing.expectEqualStrings("a/b", p.db.?);
}

test "parse: root path (single slash)" {
    const p = try url.parse("mysql://host/");
    try testing.expect(p.db == null);
}

test "parse: no path" {
    const p = try url.parse("mysql://host:3306");
    try testing.expect(p.db == null);
}

// ---- edge: empty components after parsing --------------------------------

test "parse: only user and host" {
    const p = try url.parse("mysql://user@host");
    try testing.expectEqualStrings("user", p.user.?);
    try testing.expectEqualStrings("host", p.host.?);
    try testing.expect(p.pass == null);
    try testing.expect(p.db == null);
}

test "parse: trailing @ with no host" {
    const p = try url.parse("mysql://user@");
    try testing.expectEqualStrings("user", p.user.?);
    try testing.expect(p.host == null);
    try testing.expect(p.db == null);
}

// ---- regression: long values ---------------------------------------------

test "parse: long user" {
    const long_user = "u" ** 200;
    const url_str = "mysql://" ++ long_user ++ "@host/db";
    const p = try url.parse(url_str);
    try testing.expectEqualStrings(long_user, p.user.?);
}

test "parse: long password" {
    const long_pass = "p" ** 200;
    const url_str = "mysql://user:" ++ long_pass ++ "@host/db";
    const p = try url.parse(url_str);
    try testing.expectEqualStrings(long_pass, p.pass.?);
}

// ---- fuzzing --------------------------------------------------------------

test "fuzz: url.parse never panics on random printable ASCII" {
    var prng = std.Random.DefaultPrng.init(0xDEAD);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;

    for (0..1000) |_| {
        const len = rnd.intRangeLessThan(usize, 0, buf.len);
        const s = buf[0..len];
        for (s) |*b| b.* = rnd.intRangeAtMost(u8, 32, 126);

        const result = url.parse(s);
        if (result) |params| {
            _ = params;
        } else |err| {
            try testing.expect(err == error.UnsupportedScheme);
        }
    }
}

test "fuzz: url.parse with mysql:// prefixed random bytes" {
    var prng = std.Random.DefaultPrng.init(0xBEEF);
    const rnd = prng.random();
    const prefix = "mysql://";
    var buf: [512]u8 = undefined;

    for (0..500) |_| {
        const rest_len = rnd.intRangeLessThan(usize, 0, buf.len - prefix.len);
        const s = buf[0..prefix.len + rest_len];
        @memcpy(s[0..prefix.len], prefix);
        for (s[prefix.len..]) |*b| b.* = rnd.int(u8);

        _ = url.parse(s) catch {};
    }
}
