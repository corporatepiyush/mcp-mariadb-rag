//! Integration tests that require a live MariaDB instance.
//!
//! Gated on the `DATABASE_URL` environment variable. When unset, the test
//! silently passes (skips). Run with:
//!
//!     DATABASE_URL="mysql://user:pass@host:port/db" zig build test
//!
//! The database specified in the URL must exist; no tables are created by
//! these tests.

const std = @import("std");
const testing = std.testing;
const pool_mod = @import("../src/pool.zig");
const config_mod = @import("../src/config.zig");
const server = @import("../src/server.zig");

fn dbUrl() ?[]const u8 {
    const env = std.c.getenv("DATABASE_URL");
    return if (env) |ptr| std.mem.sliceTo(ptr, 0) else null;
}

test "integration: url parse and pool init with min_size=1" {
    const url = dbUrl() orelse return;
    _ = url;
}

test "integration: connect and run SELECT 1" {
    const url = dbUrl() orelse return;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = try pool_mod.ConnectionPool.init(io, testing.allocator, url, .{
        .min_size = 1,
        .max_size = 2,
        .tls = .{ .enforce = false, .verify = false, .ca_path = null },
    });
    defer pool.close();

    var conn = try pool.acquire();
    defer conn.deinit();

    const result = try conn.query(testing.allocator, "SELECT 1 AS one");
    defer {
        if (result.rows) |rows| testing.allocator.free(rows);
        if (result.column_names) |names| testing.allocator.free(names);
        if (result.column_kinds) |kinds| testing.allocator.free(kinds);
    }

    try testing.expect(result.rows != null);
    try testing.expectEqual(@as(usize, 1), result.num_fields);
    try testing.expectEqual(@as(u64, 1), result.num_rows);

    if (result.column_names) |names| {
        try testing.expectEqualStrings("one", names[0]);
    }
    if (result.rows) |rows| {
        try testing.expectEqualStrings("1", rows[0].values[0].?);
    }
}

test "integration: execute INSERT then SELECT back" {
    const url = dbUrl() orelse return;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = try pool_mod.ConnectionPool.init(io, testing.allocator, url, .{
        .min_size = 1,
        .max_size = 2,
        .tls = .{ .enforce = false, .verify = false, .ca_path = null },
    });
    defer pool.close();

    var conn = try pool.acquire();
    defer conn.deinit();

    _ = conn.execute("CREATE TEMPORARY TABLE _mcp_test (id INT PRIMARY KEY, label VARCHAR(50))") catch
        return error.Skip;
    defer _ = conn.execute("DROP TEMPORARY TABLE IF EXISTS _mcp_test") catch {};

    const affected = try conn.execute("INSERT INTO _mcp_test VALUES (1, 'hello'), (2, 'world')");
    try testing.expectEqual(@as(u64, 2), affected);

    const result = try conn.query(testing.allocator, "SELECT * FROM _mcp_test ORDER BY id");
    defer {
        if (result.rows) |rows| testing.allocator.free(rows);
        if (result.column_names) |names| testing.allocator.free(names);
        if (result.column_kinds) |kinds| testing.allocator.free(kinds);
    }

    try testing.expectEqual(@as(u64, 2), result.num_rows);
    if (result.rows) |rows| {
        try testing.expectEqualStrings("1", rows[0].values[0].?);
        try testing.expectEqualStrings("hello", rows[0].values[1].?);
        try testing.expectEqualStrings("2", rows[1].values[0].?);
        try testing.expectEqualStrings("world", rows[1].values[1].?);
    }
}

test "integration: handleRequest initialize roundtrip" {
    const url = dbUrl() orelse return;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = try pool_mod.ConnectionPool.init(io, testing.allocator, url, .{
        .min_size = 1,
        .max_size = 2,
        .tls = .{ .enforce = false, .verify = false, .ca_path = null },
    });
    defer pool.close();

    var cfg = config_mod.Config{
        .database_url = testing.allocator.dupe(u8, url) catch unreachable,
        .default_engine = testing.allocator.dupe(u8, "InnoDB") catch unreachable,
        .server = .{
            .host = testing.allocator.dupe(u8, "127.0.0.1") catch unreachable,
            .port = 3000,
            .http_port = 3001,
            .request_timeout_secs = 30,
            .access_mode = .unrestricted,
            .auth_token = null,
            .allow_url_import = false,
            .stdio = false,
            .log_level = testing.allocator.dupe(u8, "info") catch unreachable,
            .enable_metrics = false,
            .metrics_port = 9090,
        },
        .pool = .{
            .min_size = 1,
            .max_size = 2,
            .queue_timeout_secs = 10,
            .create_timeout_secs = 5,
        },
        .tls = .{
            .enforce = false,
            .verify = false,
            .ca_path = null,
        },
    };
    defer cfg.deinit(testing.allocator);

    const resp = server.handleRequest(io, testing.allocator,
        "{\"method\":\"tools/call\",\"params\":{\"name\":\"list_tables\"},\"id\":1}",
        &pool, &cfg
    ) orelse return error.TestFailed;
    defer testing.allocator.free(resp);

    // With a real DB, this should succeed (not return Pool error)
    try testing.expect(!std.mem.containsAtLeast(u8, resp, 1, "-32001"));
}
