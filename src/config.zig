const std = @import("std");
const c = std.c;

pub const AccessMode = enum {
    unrestricted,
    restricted,
};

pub const ServerConfig = struct {
    host: []const u8,
    port: u16,
    http_port: u16,
    request_timeout_secs: u64,
    access_mode: AccessMode,
    auth_token: ?[]const u8,
    allow_url_import: bool,
    stdio: bool,
    log_level: []const u8,
    enable_metrics: bool,
    metrics_port: u16,
};

pub const PoolConfig = struct {
    min_size: u32,
    max_size: u32,
    queue_timeout_secs: u64,
    create_timeout_secs: u64,
};

/// TLS settings for the connection to the database.
pub const TlsConfig = struct {
    /// Require an encrypted connection; the handshake fails if TLS is unavailable.
    enforce: bool,
    /// Verify the server certificate against the system / CA bundle.
    verify: bool,
    /// Optional path to a CA certificate file.
    ca_path: ?[]const u8,
};

pub const Config = struct {
    database_url: []const u8,
    server: ServerConfig,
    pool: PoolConfig,
    tls: TlsConfig,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.database_url);
        allocator.free(self.server.host);
        allocator.free(self.server.log_level);
        if (self.server.auth_token) |t| allocator.free(t);
        if (self.tls.ca_path) |p| allocator.free(p);
    }
};

fn getEnv(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    const v = c.getenv(@ptrCast(name.ptr));
    if (v) |ptr| {
        const len = std.mem.len(ptr);
        return allocator.dupe(u8, ptr[0..len]) catch null;
    }
    return null;
}

fn envBool(name: []const u8) bool {
    const v = c.getenv(@ptrCast(name.ptr));
    if (v) |ptr| {
        const val = std.mem.sliceTo(ptr, 0);
        return std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "yes");
    }
    return false;
}

fn envU16(name: []const u8, default: u16) u16 {
    const v = c.getenv(@ptrCast(name.ptr));
    if (v) |ptr| {
        const val = std.mem.sliceTo(ptr, 0);
        return std.fmt.parseInt(u16, val, 10) catch default;
    }
    return default;
}

fn envU32(name: []const u8, default: u32) u32 {
    const v = c.getenv(@ptrCast(name.ptr));
    if (v) |ptr| {
        const val = std.mem.sliceTo(ptr, 0);
        return std.fmt.parseInt(u32, val, 10) catch default;
    }
    return default;
}

pub fn load(allocator: std.mem.Allocator) !Config {
    const database_url = getEnv(allocator, "DATABASE_URL") orelse try allocator.dupe(u8, "sqlite:///tmp/mcp.db");
    const host = getEnv(allocator, "MCP_HOST") orelse try allocator.dupe(u8, "127.0.0.1");
    const port = envU16("MCP_PORT", 3000);
    const http_port = envU16("MCP_HTTP_PORT", 3001);
    const log_level = getEnv(allocator, "MCP_LOG_LEVEL") orelse try allocator.dupe(u8, "info");
    const enable_metrics = envBool("MCP_ENABLE_METRICS");
    const metrics_port = envU16("MCP_METRICS_PORT", 9090);
    const stdio_mode = envBool("MCP_STDIO");
    const access_mode_str = getEnv(allocator, "MCP_ACCESS_MODE");
    const access_mode: AccessMode = if (access_mode_str) |s| blk: {
        defer allocator.free(s);
        break :blk if (std.mem.eql(u8, s, "restricted")) .restricted else .unrestricted;
    } else .unrestricted;
    const auth_token = getEnv(allocator, "MCP_AUTH_TOKEN");
    const allow_url_import = envBool("MCP_ALLOW_URL_IMPORT");

    const num_cpus = @max(1, try std.Thread.getCpuCount());
    const min_size = envU32("MCP_MIN_CONNECTIONS", @intCast(@min(5, num_cpus)));
    const max_size = envU32("MCP_MAX_CONNECTIONS", @intCast(num_cpus * 8));
    const queue_timeout = envU32("MCP_QUEUE_TIMEOUT", 10);
    const create_timeout = envU32("MCP_CREATE_TIMEOUT", 5);

    return .{
        .database_url = database_url,
        .tls = .{
            .enforce = envBool("MCP_DB_SSL"),
            .verify = envBool("MCP_DB_SSL_VERIFY"),
            .ca_path = getEnv(allocator, "MCP_DB_SSL_CA"),
        },
        .server = .{
            .host = host,
            .port = port,
            .http_port = http_port,
            .request_timeout_secs = 30,
            .access_mode = access_mode,
            .auth_token = auth_token,
            .allow_url_import = allow_url_import,
            .stdio = stdio_mode,
            .log_level = log_level,
            .enable_metrics = enable_metrics,
            .metrics_port = metrics_port,
        },
        .pool = .{
            .min_size = min_size,
            .max_size = max_size,
            .queue_timeout_secs = queue_timeout,
            .create_timeout_secs = create_timeout,
        },
    };
}


