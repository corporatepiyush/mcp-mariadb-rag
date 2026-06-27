//! URL parser edge cases beyond the inline tests in `url.zig`.

const std = @import("std");
const testing = std.testing;
const url = @import("../src/url.zig");

test "parse: sqlite absolute nested path" {
    const p = try url.parse("sqlite:///var/lib/mcp/data.db");
    try testing.expectEqualStrings("/var/lib/mcp/data.db", p.file_path.?);
}

test "parse: sqlite in-memory with trailing slash" {
    const p = try url.parse("sqlite://");
    try testing.expect(p.file_path == null);
}

test "parse: sqlite relative path dot" {
    const p = try url.parse("sqlite://./data.db");
    try testing.expectEqualStrings("./data.db", p.file_path.?);
}

test "parse: sqlite windows-style path" {
    const p = try url.parse("sqlite://C:/data/mcp.db");
    try testing.expectEqualStrings("C:/data/mcp.db", p.file_path.?);
}

test "parse: wrong scheme casing" {
    try testing.expectError(error.UnsupportedScheme, url.parse("SQLITE:///db"));
    try testing.expectError(error.UnsupportedScheme, url.parse("Sqlite:///db"));
}

test "parse: missing scheme separator" {
    try testing.expectError(error.UnsupportedScheme, url.parse("sqlite:/db"));
}

test "parse: bare scheme" {
    try testing.expectError(error.UnsupportedScheme, url.parse("sqlite:"));
}

test "parse: other scheme" {
    try testing.expectError(error.UnsupportedScheme, url.parse("mysql://host/db"));
    try testing.expectError(error.UnsupportedScheme, url.parse("postgres://host/db"));
}

test "sqlite absolute path" {
    const p = try url.parse("sqlite:///tmp/mcp.db");
    try testing.expectEqualStrings("/tmp/mcp.db", p.file_path.?);
}

test "sqlite relative path" {
    const p = try url.parse("sqlite://./data.db");
    try testing.expectEqualStrings("./data.db", p.file_path.?);
}

test "sqlite in-memory" {
    const p = try url.parse("sqlite://");
    try testing.expect(p.file_path == null);
}

test "wrong scheme rejected" {
    try testing.expectError(error.UnsupportedScheme, url.parse("postgres://x@y/z"));
}

test "fuzz: parse never panics; file_path always borrows from the input" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE_71);
    const rnd = prng.random();
    var buf: [96]u8 = undefined;
    // Bias toward the "sqlite://" prefix so the path branch is exercised often.
    const prefix = "sqlite://";

    for (0..5000) |_| {
        const total = rnd.intRangeAtMost(usize, 0, buf.len);
        const u = buf[0..total];
        // Half the time, plant the scheme prefix; otherwise fully random bytes.
        if (rnd.boolean() and total >= prefix.len) {
            @memcpy(u[0..prefix.len], prefix);
            for (u[prefix.len..]) |*b| b.* = rnd.int(u8);
        } else {
            for (u) |*b| b.* = rnd.int(u8);
        }

        const params = url.parse(u) catch continue; // UnsupportedScheme is fine
        if (params.file_path) |fp| {
            // Borrow invariant: the returned slice must lie within the input.
            const base = @intFromPtr(u.ptr);
            const p = @intFromPtr(fp.ptr);
            try testing.expect(p >= base and p + fp.len <= base + u.len);
        }
    }
}

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
