const std = @import("std");
const testing = std.testing;
const server = @import("../src/server.zig");
const pool_mod = @import("../src/pool.zig");
const config_mod = @import("../src/config.zig");

fn createTestPool(io: std.Io, allocator: std.mem.Allocator) !pool_mod.ConnectionPool {
    return try pool_mod.ConnectionPool.init(io, allocator, "sqlite:///tmp/test_mcp.db", .{
        .min_size = 0,
        .max_size = 1,
        .tls = .{ .enforce = false, .verify = false, .ca_path = null },
    });
}

fn createTestConfig(allocator: std.mem.Allocator) config_mod.Config {
    return .{
        .database_url = allocator.dupe(u8, "sqlite:///tmp/test_mcp.db") catch unreachable,
        .server = .{
            .host = allocator.dupe(u8, "127.0.0.1") catch unreachable,
            .port = 3000,
            .http_port = 3001,
            .request_timeout_secs = 30,
            .access_mode = .unrestricted,
            .auth_token = null,
            .allow_url_import = false,
            .stdio = false,
            .log_level = allocator.dupe(u8, "info") catch unreachable,
            .enable_metrics = false,
            .metrics_port = 9090,
        },
        .pool = .{
            .min_size = 0,
            .max_size = 1,
            .queue_timeout_secs = 10,
            .create_timeout_secs = 5,
        },
        .tls = .{
            .enforce = false,
            .verify = false,
            .ca_path = null,
        },
    };
}

fn handle(
    allocator: std.mem.Allocator,
    body: []const u8,
    pool: *pool_mod.ConnectionPool,
    config: *const config_mod.Config,
    io: std.Io,
) ?[]const u8 {
    return server.handleRequest(io, allocator, body, pool, config);
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ---- body validation ------------------------------------------------------

test "handleRequest: empty body returns null" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = try createTestPool(io, testing.allocator);
    defer pool.close();
    var cfg = createTestConfig(testing.allocator);
    defer cfg.deinit(testing.allocator);

    try testing.expect(handle(testing.allocator, "", &pool, &cfg, io) == null);
    try testing.expect(handle(testing.allocator, "   ", &pool, &cfg, io) == null);
}

test "handleRequest: invalid JSON returns parse error" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = try createTestPool(io, testing.allocator);
    defer pool.close();
    var cfg = createTestConfig(testing.allocator);
    defer cfg.deinit(testing.allocator);

    const resp = handle(testing.allocator, "{broken", &pool, &cfg, io) orelse return error.TestFailed;
    defer testing.allocator.free(resp);
    try testing.expect(contains(resp, "-32700"));
    try testing.expect(contains(resp, "Parse error"));
}

test "handleRequest: non-object returns invalid request" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = try createTestPool(io, testing.allocator);
    defer pool.close();
    var cfg = createTestConfig(testing.allocator);
    defer cfg.deinit(testing.allocator);

    const resp = handle(testing.allocator, "\"string\"", &pool, &cfg, io) orelse return error.TestFailed;
    defer testing.allocator.free(resp);
    try testing.expect(contains(resp, "-32600"));
    try testing.expect(contains(resp, "Invalid request"));
}

test "handleRequest: missing method" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = try createTestPool(io, testing.allocator);
    defer pool.close();
    var cfg = createTestConfig(testing.allocator);
    defer cfg.deinit(testing.allocator);

    const resp = handle(testing.allocator, "{}", &pool, &cfg, io) orelse return error.TestFailed;
    defer testing.allocator.free(resp);
    try testing.expect(contains(resp, "-32600"));
    try testing.expect(contains(resp, "Missing method"));
}

test "handleRequest: unknown method" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = try createTestPool(io, testing.allocator);
    defer pool.close();
    var cfg = createTestConfig(testing.allocator);
    defer cfg.deinit(testing.allocator);

    const resp = handle(testing.allocator, "{\"method\":\"foo\",\"id\":1}", &pool, &cfg, io) orelse return error.TestFailed;
    defer testing.allocator.free(resp);
    try testing.expect(contains(resp, "-32601"));
    try testing.expect(contains(resp, "Method not found"));
}

test "handleRequest: notification returns null" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = try createTestPool(io, testing.allocator);
    defer pool.close();
    var cfg = createTestConfig(testing.allocator);
    defer cfg.deinit(testing.allocator);

    try testing.expect(handle(testing.allocator, "{\"method\":\"notifications/initialized\"}", &pool, &cfg, io) == null);
    try testing.expect(handle(testing.allocator, "{\"method\":\"notifications/cancelled\"}", &pool, &cfg, io) == null);
}

// ---- initialize -----------------------------------------------------------

test "handleRequest: initialize with no params uses latest version" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = try createTestPool(io, testing.allocator);
    defer pool.close();
    var cfg = createTestConfig(testing.allocator);
    defer cfg.deinit(testing.allocator);

    const resp = handle(testing.allocator, "{\"method\":\"initialize\",\"id\":1}", &pool, &cfg, io) orelse return error.TestFailed;
    defer testing.allocator.free(resp);
    try testing.expect(contains(resp, "2025-11-25"));
    try testing.expect(contains(resp, "mcp-kv"));
    try testing.expect(contains(resp, "\"id\":1"));
}

test "handleRequest: initialize with matching version" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = try createTestPool(io, testing.allocator);
    defer pool.close();
    var cfg = createTestConfig(testing.allocator);
    defer cfg.deinit(testing.allocator);

    const resp = handle(testing.allocator, "{\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\"},\"id\":1}", &pool, &cfg, io) orelse return error.TestFailed;
    defer testing.allocator.free(resp);
    try testing.expect(contains(resp, "2024-11-05"));
}

test "handleRequest: initialize with unknown version falls back" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = try createTestPool(io, testing.allocator);
    defer pool.close();
    var cfg = createTestConfig(testing.allocator);
    defer cfg.deinit(testing.allocator);

    const resp = handle(testing.allocator, "{\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2099-01-01\"},\"id\":1}", &pool, &cfg, io) orelse return error.TestFailed;
    defer testing.allocator.free(resp);
    try testing.expect(contains(resp, "2025-11-25"));
}

// ---- tools/list -----------------------------------------------------------

test "handleRequest: tools/list returns tool registry" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = try createTestPool(io, testing.allocator);
    defer pool.close();
    var cfg = createTestConfig(testing.allocator);
    defer cfg.deinit(testing.allocator);

    const resp = handle(testing.allocator, "{\"method\":\"tools/list\",\"id\":1}", &pool, &cfg, io) orelse return error.TestFailed;
    defer testing.allocator.free(resp);
    try testing.expect(contains(resp, "execute_query"));
    try testing.expect(contains(resp, "list_tables"));
    try testing.expect(contains(resp, "create_table"));
    try testing.expect(contains(resp, "vector_search"));
}

// ---- ping -----------------------------------------------------------------

test "handleRequest: ping returns result null" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = try createTestPool(io, testing.allocator);
    defer pool.close();
    var cfg = createTestConfig(testing.allocator);
    defer cfg.deinit(testing.allocator);

    const resp = handle(testing.allocator, "{\"method\":\"ping\",\"id\":1}", &pool, &cfg, io) orelse return error.TestFailed;
    defer testing.allocator.free(resp);
    try testing.expect(contains(resp, "\"result\":null"));
}

// ---- tools/call (no-DB paths) ---------------------------------------------

test "handleRequest: tools/call missing name" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = try createTestPool(io, testing.allocator);
    defer pool.close();
    var cfg = createTestConfig(testing.allocator);
    defer cfg.deinit(testing.allocator);

    const resp = handle(testing.allocator, "{\"method\":\"tools/call\",\"params\":{},\"id\":1}", &pool, &cfg, io) orelse return error.TestFailed;
    defer testing.allocator.free(resp);
    try testing.expect(contains(resp, "-32602"));
    try testing.expect(contains(resp, "Missing 'name'"));
}

test "handleRequest: tools/call unknown tool" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = try createTestPool(io, testing.allocator);
    defer pool.close();
    var cfg = createTestConfig(testing.allocator);
    defer cfg.deinit(testing.allocator);

    const resp = handle(testing.allocator, "{\"method\":\"tools/call\",\"params\":{\"name\":\"nonexistent\"},\"id\":1}", &pool, &cfg, io) orelse return error.TestFailed;
    defer testing.allocator.free(resp);
    try testing.expect(contains(resp, "-32601"));
    try testing.expect(contains(resp, "Tool not found"));
}

test "handleRequest: tools/call unknown tool preserves id" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = try createTestPool(io, testing.allocator);
    defer pool.close();
    var cfg = createTestConfig(testing.allocator);
    defer cfg.deinit(testing.allocator);

    const resp = handle(testing.allocator, "{\"method\":\"tools/call\",\"params\":{\"name\":\"nonexistent\"},\"id\":42}", &pool, &cfg, io) orelse return error.TestFailed;
    defer testing.allocator.free(resp);
    try testing.expect(contains(resp, "\"id\":42"));
}

// ---- tools/call with known tool — pool closed ahead of time so acquire()
// returns PoolClosed. ------------------------------------------------------

test "handleRequest: tools/call known tool returns pool error" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = try createTestPool(io, testing.allocator);
    pool.close(); // close before acquire — no DB connection attempted
    var cfg = createTestConfig(testing.allocator);
    defer cfg.deinit(testing.allocator);

    const resp = handle(testing.allocator, "{\"method\":\"tools/call\",\"params\":{\"name\":\"search_nodes\"},\"id\":1}", &pool, &cfg, io) orelse return error.TestFailed;
    defer testing.allocator.free(resp);
    try testing.expect(contains(resp, "-32001"));
    try testing.expect(contains(resp, "Pool error"));
}

// ---- restricted mode ------------------------------------------------------

test "handleRequest: restricted mode blocks write tool" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = try createTestPool(io, testing.allocator);
    defer pool.close();

    var cfg = config_mod.Config{
        .database_url = testing.allocator.dupe(u8, "sqlite:///tmp/test_mcp.db") catch unreachable,
        .server = .{
            .host = testing.allocator.dupe(u8, "127.0.0.1") catch unreachable,
            .port = 3000,
            .http_port = 3001,
            .request_timeout_secs = 30,
            .access_mode = .restricted,
            .auth_token = null,
            .allow_url_import = false,
            .stdio = false,
            .log_level = testing.allocator.dupe(u8, "info") catch unreachable,
            .enable_metrics = false,
            .metrics_port = 9090,
        },
        .pool = .{
            .min_size = 0,
            .max_size = 1,
            .queue_timeout_secs = 10,
            .create_timeout_secs = 5,
        },
        .tls = .{ .enforce = false, .verify = false, .ca_path = null },
    };
    defer cfg.deinit(testing.allocator);

    const resp = handle(testing.allocator, "{\"method\":\"tools/call\",\"params\":{\"name\":\"create_entities\"},\"id\":1}", &pool, &cfg, io) orelse return error.TestFailed;
    defer testing.allocator.free(resp);
    try testing.expect(contains(resp, "Write operations not allowed"));
    try testing.expect(contains(resp, "isError"));
}

test "handleRequest: restricted mode allows read tool" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = try createTestPool(io, testing.allocator);
    pool.close(); // close before acquire — no DB connection
    var cfg = config_mod.Config{
        .database_url = testing.allocator.dupe(u8, "sqlite:///tmp/test_mcp.db") catch unreachable,
        .server = .{
            .host = testing.allocator.dupe(u8, "127.0.0.1") catch unreachable,
            .port = 3000,
            .http_port = 3001,
            .request_timeout_secs = 30,
            .access_mode = .restricted,
            .auth_token = null,
            .allow_url_import = false,
            .stdio = false,
            .log_level = testing.allocator.dupe(u8, "info") catch unreachable,
            .enable_metrics = false,
            .metrics_port = 9090,
        },
        .pool = .{
            .min_size = 0,
            .max_size = 1,
            .queue_timeout_secs = 10,
            .create_timeout_secs = 5,
        },
        .tls = .{ .enforce = false, .verify = false, .ca_path = null },
    };
    defer cfg.deinit(testing.allocator);

    const resp = handle(testing.allocator, "{\"method\":\"tools/call\",\"params\":{\"name\":\"search_nodes\"},\"id\":1}", &pool, &cfg, io) orelse return error.TestFailed;
    defer testing.allocator.free(resp);
    try testing.expect(!contains(resp, "Write operations not allowed"));
    try testing.expect(contains(resp, "Pool error"));
}
