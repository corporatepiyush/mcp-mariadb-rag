//! Parser for connection URIs.
//!
//! Supports:
//!   `sqlite:///path/to/db`      — SQLite file-path database
//!   `mysql://user:pass@host:port/db`  — legacy MariaDB connections
//!
//! All returned slices borrow from the input `url`; the caller owns the
//! backing memory.

const std = @import("std");

pub const DEFAULT_PORT: u16 = 3306;

pub const ConnParams = struct {
    user: ?[]const u8 = null,
    pass: ?[]const u8 = null,
    host: ?[]const u8 = null,
    db: ?[]const u8 = null,
    port: u16 = DEFAULT_PORT,
    /// Set for `sqlite:///path` URIs. Borrows from the input URL.
    file_path: ?[]const u8 = null,
};

pub const ParseError = error{
    /// The URL did not start with a known scheme.
    UnsupportedScheme,
};

/// Parse a connection URL. Returns `file_path` for `sqlite://` URIs and the
/// standard connection parameters for `mysql://` URIs.
pub fn parse(url: []const u8) ParseError!ConnParams {
    if (std.mem.startsWith(u8, url, "sqlite://")) {
        const path = url["sqlite://".len..];
        return .{ .file_path = if (path.len > 0) path else null };
    }

    if (!std.mem.startsWith(u8, url, "mysql://")) return error.UnsupportedScheme;
    const rest = url["mysql://".len..];

    var params: ConnParams = .{};

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

test "sqlite absolute path" {
    const p = try parse("sqlite:///tmp/mcp.db");
    try std.testing.expectEqualStrings("/tmp/mcp.db", p.file_path.?);
    try std.testing.expect(p.user == null);
}

test "sqlite relative path" {
    const p = try parse("sqlite://./data.db");
    try std.testing.expectEqualStrings("./data.db", p.file_path.?);
}

test "sqlite in-memory" {
    const p = try parse("sqlite://");
    try std.testing.expect(p.file_path == null);
}

test "full mysql url" {
    const p = try parse("mysql://alice:s3cret@db.example.com:3307/shop");
    try std.testing.expectEqualStrings("alice", p.user.?);
    try std.testing.expectEqualStrings("s3cret", p.pass.?);
    try std.testing.expectEqualStrings("db.example.com", p.host.?);
    try std.testing.expectEqualStrings("shop", p.db.?);
    try std.testing.expectEqual(@as(u16, 3307), p.port);
    try std.testing.expect(p.file_path == null);
}

test "mysql no password" {
    const p = try parse("mysql://root@localhost/mcp");
    try std.testing.expectEqualStrings("root", p.user.?);
    try std.testing.expect(p.pass == null);
    try std.testing.expectEqualStrings("localhost", p.host.?);
    try std.testing.expectEqual(@as(u16, 3306), p.port);
}

test "mysql empty password after colon" {
    const p = try parse("mysql://root:@localhost:3306/mcp");
    try std.testing.expectEqualStrings("root", p.user.?);
    try std.testing.expect(p.pass == null);
}

test "mysql no database" {
    const p = try parse("mysql://root:pw@127.0.0.1:3306");
    try std.testing.expect(p.db == null);
    try std.testing.expectEqualStrings("127.0.0.1", p.host.?);
    try std.testing.expectEqual(@as(u16, 3306), p.port);
}

test "mysql host only" {
    const p = try parse("mysql://localhost");
    try std.testing.expect(p.user == null);
    try std.testing.expectEqualStrings("localhost", p.host.?);
}

test "mysql bad port falls back to default" {
    const p = try parse("mysql://root@host:notaport/db");
    try std.testing.expectEqual(@as(u16, 3306), p.port);
}

test "wrong scheme rejected" {
    try std.testing.expectError(error.UnsupportedScheme, parse("postgres://x@y/z"));
}
