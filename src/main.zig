const std = @import("std");
const config_mod = @import("config.zig");
const transport = @import("transport.zig");
const pool_mod = @import("pool.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // The Zig 0.16 I/O interface: a `Threaded` implementation provides the
    // concrete `io` that the transports thread through file and socket I/O.
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var config = try config_mod.load(allocator);
    defer config.deinit(allocator);

    std.log.info("Starting MCP MariaDB RAG Server", .{});

    if (config.server.auth_token == null and !config.server.stdio) {
        std.log.warn("No auth token configured. Set MCP_AUTH_TOKEN for security.", .{});
    }

    var pool = try pool_mod.ConnectionPool.init(io, allocator, config.database_url, .{
        .min_size = config.pool.min_size,
        .max_size = config.pool.max_size,
        .tls = config.tls,
        .default_engine = config.default_engine,
    });
    defer pool.close();

    std.log.info("Connection pool initialized: min={d}, max={d}, engine={s}, tls={}", .{
        config.pool.min_size, config.pool.max_size, config.default_engine, config.tls.enforce,
    });

    if (config.server.stdio) {
        std.log.info("Running in stdio mode", .{});
        transport.runStdio(io, allocator, &pool, &config);
    } else {
        std.log.info("Starting HTTP server on port {d}", .{config.server.http_port});
        transport.runHttp(io, allocator, &pool, &config);
    }

    std.log.info("Server shutdown complete", .{});
}
