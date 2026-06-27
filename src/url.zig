//! Parser for `sqlite:///path/to/db` connection URIs.

const std = @import("std");

pub const ConnParams = struct {
    /// Set for `sqlite:///path` URIs. Borrows from the input URL.
    file_path: ?[]const u8 = null,
};

pub const ParseError = error{
    /// The URL did not start with `sqlite://`.
    UnsupportedScheme,
};

/// Parse a connection URL. Returns `file_path` for `sqlite://` URIs.
pub fn parse(url: []const u8) ParseError!ConnParams {
    if (std.mem.startsWith(u8, url, "sqlite://")) {
        const path = url["sqlite://".len..];
        if (path.len > 0 and path[0] == '/') {
            return .{ .file_path = path };
        }
        return .{ .file_path = if (path.len > 0) path else null };
    }
    return error.UnsupportedScheme;
}

test "sqlite absolute path" {
    const p = try parse("sqlite:///tmp/mcp.db");
    try std.testing.expectEqualStrings("/tmp/mcp.db", p.file_path.?);
}

test "sqlite relative path" {
    const p = try parse("sqlite://./data.db");
    try std.testing.expectEqualStrings("./data.db", p.file_path.?);
}

test "sqlite in-memory" {
    const p = try parse("sqlite://");
    try std.testing.expect(p.file_path == null);
}

test "wrong scheme rejected" {
    try std.testing.expectError(error.UnsupportedScheme, parse("postgres://x@y/z"));
}

test "fuzz: parse never panics; file_path always borrows from the input" {
    const testing = std.testing;
    var prng = std.Random.DefaultPrng.init(0xC0FFEE_71);
    const rnd = prng.random();
    var buf: [96]u8 = undefined;
    // Bias toward the "sqlite://" prefix so the path branch is exercised often.
    const prefix = "sqlite://";

    for (0..5000) |_| {
        const total = rnd.intRangeAtMost(usize, 0, buf.len);
        const url = buf[0..total];
        // Half the time, plant the scheme prefix; otherwise fully random bytes.
        if (rnd.boolean() and total >= prefix.len) {
            @memcpy(url[0..prefix.len], prefix);
            for (url[prefix.len..]) |*b| b.* = rnd.int(u8);
        } else {
            for (url) |*b| b.* = rnd.int(u8);
        }

        const params = parse(url) catch continue; // UnsupportedScheme is fine
        if (params.file_path) |fp| {
            // Borrow invariant: the returned slice must lie within the input.
            const base = @intFromPtr(url.ptr);
            const p = @intFromPtr(fp.ptr);
            try testing.expect(p >= base and p + fp.len <= base + url.len);
        }
    }
}
