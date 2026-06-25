//! Database connection wrapper and bounded, thread-safe connection pool.
//!
//! Currently stubbed after MariaDB removal. Full SQLite implementation
//! arrives in Phase 1b.
//!
//! WARNING: `query()` and `execute()` return `error.NotImplemented` — any
//! code path that reaches a real database operation will fail at runtime
//! until the pool is rewritten.

const std = @import("std");
const types = @import("types.zig");
const url_mod = @import("url.zig");
const config = @import("config.zig");

pub const TlsConfig = config.TlsConfig;

pub const Row = types.Row;
pub const QueryResult = types.QueryResult;
pub const ColumnKind = types.ColumnKind;

/// Stub connection — replaced by SQLiteConn in Phase 1b.
pub const DatabaseConn = struct {
    id: u64,

    pub fn init(url: []const u8, id: u64, _: TlsConfig) !DatabaseConn {
        _ = url_mod.parse(url) catch return error.InvalidUrl;
        return .{ .id = id };
    }

    pub fn deinit(_: *const DatabaseConn) void {}

    pub fn query(_: *DatabaseConn, _: std.mem.Allocator, _: []const u8) !QueryResult {
        return error.NotImplemented;
    }

    pub fn execute(_: *DatabaseConn, _: []const u8) !u64 {
        return error.NotImplemented;
    }
};

pub const PooledConnection = struct {
    conn: DatabaseConn,
    pool: ?*ConnectionPool,
    valid: bool,

    pub fn deinit(self: *PooledConnection) void {
        if (self.pool) |p| {
            p.release(self.conn, self.valid);
        } else {
            self.conn.deinit();
        }
    }

    pub fn query(self: *PooledConnection, a: std.mem.Allocator, sql: []const u8) !QueryResult {
        return self.conn.query(a, sql) catch |err| {
            self.valid = false;
            return err;
        };
    }

    pub fn execute(self: *PooledConnection, sql: []const u8) !u64 {
        return self.conn.execute(sql) catch |err| {
            self.valid = false;
            return err;
        };
    }
};

const ConnList = std.ArrayList(DatabaseConn);

pub const PoolError = error{ PoolClosed, ConnectionFailed, InvalidUrl, NotImplemented };

/// Bounded, thread-safe connection pool.
///
/// Full implementation returns in Phase 1b with SQLite. For now the pool
/// creates stub connections that reject queries.
pub const Options = struct {
    min_size: u32,
    max_size: u32,
    tls: TlsConfig,
};

pub const ConnectionPool = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    free_list: ConnList,
    url: []u8,
    tls: TlsConfig,
    current_id: u64,
    total_count: u32,
    max_size: u32,
    closed: bool,
    allocator: std.mem.Allocator,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        url: []const u8,
        options: Options,
    ) !ConnectionPool {
        const effective_max = @max(@max(options.max_size, options.min_size), 1);
        var pool = ConnectionPool{
            .io = io,
            .free_list = .empty,
            .url = try allocator.dupe(u8, url),
            .tls = options.tls,
            .current_id = 0,
            .total_count = 0,
            .max_size = effective_max,
            .closed = false,
            .allocator = allocator,
        };
        errdefer allocator.free(pool.url);

        try pool.free_list.ensureTotalCapacity(allocator, effective_max);
        errdefer {
            for (pool.free_list.items) |conn| conn.deinit();
            pool.free_list.deinit(allocator);
        }

        for (0..options.min_size) |_| {
            const conn = try DatabaseConn.init(url, pool.nextId(), options.tls);
            pool.free_list.appendAssumeCapacity(conn);
            pool.total_count += 1;
        }
        return pool;
    }

    inline fn lock(self: *ConnectionPool) void {
        self.mutex.lockUncancelable(self.io);
    }
    inline fn unlock(self: *ConnectionPool) void {
        self.mutex.unlock(self.io);
    }

    fn nextId(self: *ConnectionPool) u64 {
        defer self.current_id += 1;
        return self.current_id;
    }

    pub fn acquire(self: *ConnectionPool) PoolError!PooledConnection {
        self.lock();
        while (true) {
            if (self.closed) {
                self.unlock();
                return error.PoolClosed;
            }

            if (self.free_list.pop()) |conn| {
                self.unlock();
                return .{ .conn = conn, .pool = self, .valid = true };
            }

            if (self.total_count < self.max_size) {
                self.total_count += 1;
                const id = self.nextId();
                const tls = self.tls;
                self.unlock();
                const conn = DatabaseConn.init(self.url, id, tls) catch {
                    self.lock();
                    self.total_count -= 1;
                    self.cond.signal(self.io);
                    self.unlock();
                    return error.ConnectionFailed;
                };
                return .{ .conn = conn, .pool = self, .valid = true };
            }

            self.cond.waitUncancelable(self.io, &self.mutex);
        }
    }

    fn release(self: *ConnectionPool, conn: DatabaseConn, valid: bool) void {
        if (!valid) {
            conn.deinit();
            self.lock();
            self.total_count -= 1;
            self.cond.signal(self.io);
            self.unlock();
            return;
        }

        self.lock();
        if (self.closed) {
            self.unlock();
            conn.deinit();
            self.lock();
            self.total_count -= 1;
            self.unlock();
            return;
        }
        self.free_list.appendAssumeCapacity(conn);
        self.cond.signal(self.io);
        self.unlock();
    }

    pub fn close(self: *ConnectionPool) void {
        self.lock();
        self.closed = true;
        while (self.free_list.pop()) |conn| {
            conn.deinit();
            self.total_count -= 1;
        }
        self.free_list.deinit(self.allocator);
        self.cond.broadcast(self.io);
        self.unlock();
        self.allocator.free(self.url);
    }
};
