//! Database connection wrapper and bounded, thread-safe connection pool.
//!
//! `DatabaseConn` wraps a raw `sqlite3` handle, initialises it with WAL mode,
//! a 5-second busy timeout, and `foreign_keys=OFF`.  `ConnectionPool` manages a
//! bounded set of these connections with mutex/condition for thread‑safe
//! acquire/release.

const std = @import("std");
const types = @import("types.zig");
const url_mod = @import("url.zig");
const sqlite = @import("sqlite.zig");
const config = @import("config.zig");

pub const TlsConfig = config.TlsConfig;

pub const Row = types.Row;
pub const QueryResult = types.QueryResult;
pub const ColumnKind = types.ColumnKind;

/// SQLite connection — wraps a raw `*sqlite3` handle.
///
/// File‑path databases are opened with `SQLITE_OPEN_READWRITE |
/// SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX`.  In‑memory databases use the
/// shared‑cache URI `file::memory:?cache=shared`.
pub const DatabaseConn = struct {
    id: u64,
    db: *sqlite.sqlite3,

    pub fn init(url: []const u8, id: u64, _: TlsConfig) !DatabaseConn {
        const params = try url_mod.parse(url);

        const db = if (params.file_path) |fp| blk: {
            var buf: [4096]u8 = undefined;
            if (fp.len >= buf.len) return error.NameTooLong;
            for (fp, 0..) |byte, j| buf[j] = byte;
            buf[fp.len] = 0;
            break :blk try sqlite.open(buf[0..fp.len :0]);
        } else try sqlite.openInMemory();

        errdefer sqlite.close(db);
        try sqlite.exec(db, "PRAGMA journal_mode=WAL");
        try sqlite.exec(db, "PRAGMA foreign_keys=OFF");
        try sqlite.check(sqlite.sqlite3_busy_timeout(db, 5000));
        return .{ .id = id, .db = db };
    }

    pub fn deinit(self: *const DatabaseConn) void {
        sqlite.close(self.db);
    }

    pub fn query(self: *DatabaseConn, allocator: std.mem.Allocator, sql: []const u8) !QueryResult {
        const sql_z = try allocator.alloc(u8, sql.len + 1);
        defer allocator.free(sql_z);
        for (sql, 0..) |byte, j| sql_z[j] = byte;
        sql_z[sql.len] = 0;
        const stmt = try sqlite.prepare(self.db, sql_z[0..sql.len :0]);
        defer sqlite.finalize(stmt);

        const col_count = @as(usize, @intCast(sqlite.sqlite3_column_count(stmt)));
        if (col_count == 0) {
            return QueryResult{
                .rows = null,
                .column_names = null,
                .column_kinds = null,
                .num_fields = 0,
                .num_rows = 0,
                .affected_rows = @intCast(sqlite.sqlite3_changes(self.db)),
                .insert_id = @intCast(sqlite.sqlite3_last_insert_rowid(self.db)),
            };
        }

        const col_names = try allocator.alloc([]const u8, col_count);
        for (0..col_count) |i| {
            const ci = @as(c_int, @intCast(i));
            col_names[i] = try allocator.dupe(u8, std.mem.sliceTo(sqlite.sqlite3_column_name(stmt, ci), 0));
        }

        var col_kinds = try allocator.alloc(ColumnKind, col_count);
        for (col_kinds) |*k| k.* = .text;

        var rows: std.ArrayList(Row) = .empty;
        var first_row = true;
        while (sqlite.sqlite3_step(stmt) == sqlite.SQLITE_ROW) {
            const values = try allocator.alloc(?[]const u8, col_count);
            for (0..col_count) |i| {
                const ci = @as(c_int, @intCast(i));
                const col_type = sqlite.sqlite3_column_type(stmt, ci);
                values[i] = if (col_type == sqlite.SQLITE_NULL)
                    null
                else blk: {
                    const ptr = sqlite.sqlite3_column_text(stmt, ci);
                    const len = @as(usize, @intCast(sqlite.sqlite3_column_bytes(stmt, ci)));
                    break :blk try allocator.dupe(u8, ptr[0..len]);
                };
            }
            try rows.append(allocator, .{ .values = values });

            if (first_row) {
                first_row = false;
                for (0..col_count) |i| {
                    const ci = @as(c_int, @intCast(i));
                    col_kinds[i] = switch (sqlite.sqlite3_column_type(stmt, ci)) {
                        sqlite.SQLITE_INTEGER, sqlite.SQLITE_FLOAT => .numeric,
                        else => .text,
                    };
                }
            }
        }

        const row_slice = try rows.toOwnedSlice(allocator);
        return QueryResult{
            .rows = row_slice,
            .column_names = col_names,
            .column_kinds = col_kinds,
            .num_fields = col_count,
            .num_rows = row_slice.len,
            .affected_rows = 0,
            .insert_id = 0,
        };
    }

    pub fn execute(self: *DatabaseConn, sql: []const u8) !u64 {
        var buf: [4096]u8 = undefined;
        if (sql.len >= buf.len) return error.SqlTooLong;
        for (sql, 0..) |byte, j| buf[j] = byte;
        buf[sql.len] = 0;
        try sqlite.exec(self.db, buf[0..sql.len :0]);
        return @intCast(sqlite.sqlite3_changes(self.db));
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

pub const PoolError = error{ PoolClosed, ConnectionFailed, InvalidUrl };

/// Bounded, thread-safe connection pool.
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
        _ = try url_mod.parse(url);
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

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "DatabaseConn init/query in-memory" {
    var conn = try DatabaseConn.init("sqlite://", 1, .{ .enforce = false, .verify = false, .ca_path = null });
    defer conn.deinit();

    _ = try conn.execute("CREATE TABLE t(x INTEGER, y TEXT)");
    _ = try conn.execute("INSERT INTO t VALUES(1, 'one')");
    _ = try conn.execute("INSERT INTO t VALUES(2, 'two')");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try conn.query(arena.allocator(), "SELECT x, y FROM t ORDER BY x");

    try testing.expectEqual(@as(usize, 2), result.num_fields);
    try testing.expectEqual(@as(u64, 2), result.num_rows);
    try testing.expect(result.rows != null);
    if (result.rows) |rows| {
        try testing.expectEqualStrings("1", rows[0].values[0].?);
        try testing.expectEqualStrings("one", rows[0].values[1].?);
        try testing.expectEqualStrings("2", rows[1].values[0].?);
        try testing.expectEqualStrings("two", rows[1].values[1].?);
    }
}

test "DatabaseConn query with NULL values" {
    var conn = try DatabaseConn.init("sqlite://", 2, .{ .enforce = false, .verify = false, .ca_path = null });
    defer conn.deinit();

    _ = try conn.execute("CREATE TABLE t(a INTEGER, b TEXT)");
    _ = try conn.execute("INSERT INTO t VALUES(1, NULL)");
    _ = try conn.execute("INSERT INTO t VALUES(NULL, 'text')");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try conn.query(arena.allocator(), "SELECT a, b FROM t ORDER BY a NULLS LAST");

    try testing.expectEqual(@as(u64, 2), result.num_rows);
    if (result.rows) |rows| {
        try testing.expect(rows[0].values[1] == null); // b is NULL
        try testing.expect(rows[1].values[0] == null); // a is NULL
        try testing.expectEqualStrings("text", rows[1].values[1].?);
    }
}

test "DatabaseConn execute returns affected rows" {
    var conn = try DatabaseConn.init("sqlite://", 3, .{ .enforce = false, .verify = false, .ca_path = null });
    defer conn.deinit();

    _ = try conn.execute("CREATE TABLE t(v TEXT)");
    const inserted = try conn.execute("INSERT INTO t VALUES('a'), ('b'), ('c')");
    try testing.expectEqual(@as(u64, 3), inserted);
}

test "DatabaseConn error on bad SQL" {
    var conn = try DatabaseConn.init("sqlite://", 4, .{ .enforce = false, .verify = false, .ca_path = null });
    defer conn.deinit();

    try testing.expectError(error.SqliteError, conn.execute("CREATE TABLE"));
}

test "DatabaseConn column names and kinds" {
    var conn = try DatabaseConn.init("sqlite://", 5, .{ .enforce = false, .verify = false, .ca_path = null });
    defer conn.deinit();
    _ = try conn.execute("CREATE TABLE t(a INTEGER, b TEXT, c REAL)");
    _ = try conn.execute("INSERT INTO t VALUES(1, 'x', 3.14)");

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try conn.query(arena.allocator(), "SELECT a, b, c FROM t");

    if (result.column_names) |names| {
        try testing.expectEqualStrings("a", names[0]);
        try testing.expectEqualStrings("b", names[1]);
        try testing.expectEqualStrings("c", names[2]);
    } else try testing.expect(false);
    try testing.expectEqual(@as(usize, 3), result.num_fields);
}

test "DatabaseConn DDL with no result set" {
    var conn = try DatabaseConn.init("sqlite://", 6, .{ .enforce = false, .verify = false, .ca_path = null });
    defer conn.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try conn.query(arena.allocator(), "CREATE TABLE t(x INTEGER)");
    try testing.expect(result.rows == null);
    try testing.expectEqual(@as(u64, 0), result.affected_rows);
}

test "ConnectionPool acquire/release" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = try ConnectionPool.init(io, testing.allocator, "sqlite://", .{
        .min_size = 1,
        .max_size = 2,
        .tls = .{ .enforce = false, .verify = false, .ca_path = null },
    });
    defer pool.close();

    var conn = try pool.acquire();
    defer conn.deinit();
    _ = try conn.execute("SELECT 1");
}

test "ConnectionPool returns PoolClosed after close" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = try ConnectionPool.init(io, testing.allocator, "sqlite://", .{
        .min_size = 0,
        .max_size = 1,
        .tls = .{ .enforce = false, .verify = false, .ca_path = null },
    });
    pool.close();
    try testing.expectError(error.PoolClosed, pool.acquire());
}

test "ConnectionPool rejects invalid URL" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try testing.expectError(error.UnsupportedScheme, ConnectionPool.init(io, testing.allocator, "postgres://x/y", .{
        .min_size = 0,
        .max_size = 1,
        .tls = .{ .enforce = false, .verify = false, .ca_path = null },
    }));
}

test "ConnectionPool concurrent acquire/release" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = try ConnectionPool.init(io, testing.allocator, "sqlite://", .{
        .min_size = 2,
        .max_size = 4,
        .tls = .{ .enforce = false, .verify = false, .ca_path = null },
    });
    defer pool.close();

    var c1 = try pool.acquire();
    defer c1.deinit();
    var c2 = try pool.acquire();
    defer c2.deinit();
    var c3 = try pool.acquire();
    defer c3.deinit();
}

// ── Fuzzing ────────────────────────────────────────────────────────────

test "fuzz: random SQL strings on DatabaseConn" {
    var rng = std.Random.DefaultPrng.init(0x1B_F00D);
    const rand = rng.random();

    var conn = try DatabaseConn.init("sqlite://", 100, .{ .enforce = false, .verify = false, .ca_path = null });
    defer conn.deinit();

    const chars = " ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789,;'\"-+*/%()";
    var buf: [128]u8 = undefined;
    for (0..200) |_| {
        const len = rand.uintLessThan(usize, buf.len - 1);
        for (0..len) |i| {
            buf[i] = chars[rand.uintLessThan(u8, chars.len)];
        }
        buf[len] = 0;
        _ = conn.execute(buf[0..len :0]) catch {};
    }
}

test "fuzz: random queries produce valid QueryResult" {
    var rng = std.Random.DefaultPrng.init(0x2C_BEEF);
    const rand = rng.random();

    var conn = try DatabaseConn.init("sqlite://", 101, .{ .enforce = false, .verify = false, .ca_path = null });
    defer conn.deinit();
    _ = try conn.execute("CREATE TABLE f(a INTEGER, b TEXT, c REAL)");

    // Insert random rows
    {
        const stmt = try sqlite.prepare(conn.db, "INSERT INTO f VALUES(?, ?, ?)");
        defer sqlite.finalize(stmt);
        for (0..50) |_| {
            try sqlite.check(sqlite.sqlite3_reset(stmt));
            try sqlite.check(sqlite.sqlite3_clear_bindings(stmt));
            _ = sqlite.sqlite3_bind_int64(stmt, 1, rand.int(i64));
            if (rand.boolean()) {
                var str: [16]u8 = undefined;
                for (&str) |*c| c.* = 'a' + rand.uintLessThan(u8, 26);
                _ = sqlite.sqlite3_bind_text(stmt, 2, &str, 16, sqlite.SQLITE_TRANSIENT);
            } else {
                _ = sqlite.sqlite3_bind_null(stmt, 2);
            }
            _ = sqlite.sqlite3_bind_double(stmt, 3, rand.float(f64));
            _ = sqlite.sqlite3_step(stmt);
        }
    }

    // Query them back
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const result = try conn.query(arena.allocator(), "SELECT a, b, c FROM f");
        try testing.expectEqual(@as(usize, 3), result.num_fields);
        try testing.expectEqual(@as(u64, 50), result.num_rows);
        if (result.rows) |rows| {
            for (rows) |row| {
                // a is never NULL (we always bound int64 for a)
                try testing.expect(row.values[0] != null);
                // b may be NULL
                // c is never NULL (we always bound double for c)
                try testing.expect(row.values[2] != null);
            }
        }
    }
}
