//! Pure parser for `mysql://user:pass@host:port/db` connection strings.
//!
//! Extracted out of the connection layer so it can be unit-tested without a
//! live database (and without pulling in the MariaDB C headers). All returned
//! slices borrow from the input `url`; the caller owns the backing memory.

const std = @import("std");

pub const DEFAULT_PORT: u16 = 3306;

pub const ConnParams = struct {
    user: ?[]const u8 = null,
    pass: ?[]const u8 = null,
    host: ?[]const u8 = null,
    db: ?[]const u8 = null,
    port: u16 = DEFAULT_PORT,
};

pub const ParseError = error{
    /// The URL did not start with the `mysql://` scheme.
    UnsupportedScheme,
};

/// Parse a `mysql://` URL. Missing components are left `null` so the caller can
/// apply client-library defaults. The port falls back to `DEFAULT_PORT` when
/// absent or unparseable rather than failing the whole connection.
pub fn parse(url: []const u8) ParseError!ConnParams {
    const scheme = "mysql://";
    if (!std.mem.startsWith(u8, url, scheme)) return error.UnsupportedScheme;
    const rest = url[scheme.len..];

    var params: ConnParams = .{};

    // Split userinfo from the host portion on the first '@'. A password may
    // itself contain '@' in theory, but connection strings overwhelmingly do
    // not; we split on the first '@' to keep host parsing unambiguous.
    const at = std.mem.indexOfScalar(u8, rest, '@');
    const userinfo = if (at) |i| rest[0..i] else "";
    const hostpart = if (at) |i| rest[i + 1 ..] else rest;

    if (at != null and userinfo.len != 0) {
        if (std.mem.indexOfScalar(u8, userinfo, ':')) |colon| {
            params.user = nonEmpty(userinfo[0..colon]);
            params.pass = nonEmpty(userinfo[colon + 1 ..]);
        } else {
            params.user = nonEmpty(userinfo);
        }
    }

    // Separate host[:port] from the optional /database path.
    const hostport, const db = if (std.mem.indexOfScalar(u8, hostpart, '/')) |slash|
        .{ hostpart[0..slash], nonEmpty(hostpart[slash + 1 ..]) }
    else
        .{ hostpart, null };
    params.db = db;

    if (std.mem.indexOfScalar(u8, hostport, ':')) |colon| {
        params.host = nonEmpty(hostport[0..colon]);
        params.port = std.fmt.parseInt(u16, hostport[colon + 1 ..], 10) catch DEFAULT_PORT;
    } else {
        params.host = nonEmpty(hostport);
    }

    return params;
}

fn nonEmpty(s: []const u8) ?[]const u8 {
    return if (s.len == 0) null else s;
}

test "full url" {
    const p = try parse("mysql://alice:s3cret@db.example.com:3307/shop");
    try std.testing.expectEqualStrings("alice", p.user.?);
    try std.testing.expectEqualStrings("s3cret", p.pass.?);
    try std.testing.expectEqualStrings("db.example.com", p.host.?);
    try std.testing.expectEqualStrings("shop", p.db.?);
    try std.testing.expectEqual(@as(u16, 3307), p.port);
}

test "no password" {
    const p = try parse("mysql://root@localhost/mcp");
    try std.testing.expectEqualStrings("root", p.user.?);
    try std.testing.expect(p.pass == null);
    try std.testing.expectEqualStrings("localhost", p.host.?);
    try std.testing.expectEqual(@as(u16, 3306), p.port);
}

test "empty password after colon" {
    const p = try parse("mysql://root:@localhost:3306/mcp");
    try std.testing.expectEqualStrings("root", p.user.?);
    try std.testing.expect(p.pass == null);
}

test "no database" {
    const p = try parse("mysql://root:pw@127.0.0.1:3306");
    try std.testing.expect(p.db == null);
    try std.testing.expectEqualStrings("127.0.0.1", p.host.?);
    try std.testing.expectEqual(@as(u16, 3306), p.port);
}

test "host only" {
    const p = try parse("mysql://localhost");
    try std.testing.expect(p.user == null);
    try std.testing.expectEqualStrings("localhost", p.host.?);
}

test "bad port falls back to default" {
    const p = try parse("mysql://root@host:notaport/db");
    try std.testing.expectEqual(@as(u16, 3306), p.port);
}

test "wrong scheme rejected" {
    try std.testing.expectError(error.UnsupportedScheme, parse("postgres://x@y/z"));
}
