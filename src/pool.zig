//! Database connection wrapper and bounded, thread-safe connection pool.
//!
//! `DatabaseConn` wraps a raw `sqlite3` handle, initialises it with WAL mode,
//! a 5-second busy timeout, and `foreign_keys=OFF`.  `ConnectionPool` manages a
//! bounded set of these connections with mutex/condition for thread‑safe
//! acquire/release.

const std = @import("std");
const types = @import("types.zig");
const url_mod = @import("url.zig");
pub const sqlite = @import("sqlite.zig");
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

    /// Open with the conservative default tuning. Used by tests and any caller
    /// that hasn't resolved a tier.
    pub fn init(url: []const u8, id: u64, tls: TlsConfig) !DatabaseConn {
        return initTuned(url, id, tls, config.SqliteTuning.safe_default);
    }

    /// Open and apply the tier-scaled storage-engine PRAGMAs (`tuning`). These
    /// are the IO-axis screws: page cache, memory-mapped I/O window, WAL
    /// checkpoint cadence, and the durability/throughput `synchronous` dial.
    pub fn initTuned(url: []const u8, id: u64, _: TlsConfig, tuning: config.SqliteTuning) !DatabaseConn {
        const params = try url_mod.parse(url);

        const db = if (params.file_path) |fp| blk: {
            var buf: [4096]u8 = undefined;
            if (fp.len >= buf.len) return error.NameTooLong;
            for (fp, 0..) |byte, j| buf[j] = byte;
            buf[fp.len] = 0;
            break :blk try sqlite.open(buf[0..fp.len :0]);
        } else try sqlite.openInMemory();

        errdefer sqlite.close(db);
        try applyPragmas(db, tuning);
        return .{ .id = id, .db = db };
    }

    /// Build and run each PRAGMA. `page_size` goes first (it only takes effect on
    /// a brand-new file); the rest are idempotent per connection.
    fn applyPragmas(db: *sqlite.sqlite3, tuning: config.SqliteTuning) !void {
        var buf: [128]u8 = undefined;
        try sqlite.exec(db, try std.fmt.bufPrintZ(&buf, "PRAGMA page_size={d}", .{tuning.page_size}));
        try sqlite.exec(db, "PRAGMA journal_mode=WAL");
        try sqlite.exec(db, "PRAGMA foreign_keys=OFF");
        try sqlite.exec(db, try std.fmt.bufPrintZ(&buf, "PRAGMA cache_size=-{d}", .{tuning.cache_kib}));
        try sqlite.exec(db, try std.fmt.bufPrintZ(&buf, "PRAGMA mmap_size={d}", .{tuning.mmap_bytes}));
        try sqlite.exec(db, try std.fmt.bufPrintZ(&buf, "PRAGMA synchronous={s}", .{tuning.synchronous.sql()}));
        if (tuning.temp_store != .default)
            try sqlite.exec(db, try std.fmt.bufPrintZ(&buf, "PRAGMA temp_store={s}", .{tuning.temp_store.sql()}));
        try sqlite.exec(db, try std.fmt.bufPrintZ(&buf, "PRAGMA wal_autocheckpoint={d}", .{tuning.wal_autocheckpoint}));
        try sqlite.check(sqlite.sqlite3_busy_timeout(db, @intCast(tuning.busy_ms)));
        try sqlite.exec(db, "PRAGMA optimize");
    }

    pub fn deinit(self: *const DatabaseConn) void {
        sqlite.close(self.db);
    }

    pub fn query(self: *DatabaseConn, allocator: std.mem.Allocator, sql: []const u8) !QueryResult {
        const stmt = try sqlite.prepare(self.db, sql);
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
        while (true) {
            const rc = sqlite.sqlite3_step(stmt);
            if (rc == sqlite.SQLITE_DONE) break;
            if (rc != sqlite.SQLITE_ROW) try sqlite.check(rc);

            const values = try allocator.alloc(?[]const u8, col_count);
            for (0..col_count) |i| {
                const ci = @as(c_int, @intCast(i));
                const col_type = sqlite.sqlite3_column_type(stmt, ci);
                values[i] = if (col_type == sqlite.SQLITE_NULL)
                    null
                else if (col_type == sqlite.SQLITE_BLOB) blk: {
                    const ptr = @as([*]const u8, @ptrCast(sqlite.sqlite3_column_blob(stmt, ci)));
                    const len = @as(usize, @intCast(sqlite.sqlite3_column_bytes(stmt, ci)));
                    break :blk try allocator.dupe(u8, ptr[0..len]);
                } else blk: {
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
        const stmt = try sqlite.prepare(self.db, sql);
        defer sqlite.finalize(stmt);
        try sqlite.check(sqlite.sqlite3_step(stmt));
        return @intCast(sqlite.sqlite3_changes(self.db));
    }

    /// Run a multi-statement DDL script (`;`-separated). Our schema files
    /// contain no semicolons except statement terminators (no triggers/strings),
    /// so a simple split is safe and avoids the null-termination dance of
    /// `sqlite3_exec`.
    pub fn executeScript(self: *DatabaseConn, script: []const u8) !void {
        try sqlite.execScript(self.db, script);
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
        self.* = undefined;
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

    pub fn executeScript(self: *PooledConnection, script: []const u8) !void {
        return self.conn.executeScript(script) catch |err| {
            self.valid = false;
            return err;
        };
    }

    /// Begin an immediate write transaction (acquires the write lock up front,
    /// so the multi-statement body can't interleave with another writer).
    pub fn begin(self: *PooledConnection) !void {
        _ = try self.execute("BEGIN IMMEDIATE");
    }

    pub fn commit(self: *PooledConnection) !void {
        _ = try self.execute("COMMIT");
    }

    /// Best-effort rollback for the error path; a failure here doesn't mask the
    /// original error, but does invalidate the connection so the pool recycles it.
    pub fn rollback(self: *PooledConnection) void {
        _ = self.conn.execute("ROLLBACK") catch {
            self.valid = false;
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
    /// Tier-scaled SQLite PRAGMAs applied to every connection. Defaults to the
    /// conservative preset so existing callers/tests need no change.
    tuning: config.SqliteTuning = config.SqliteTuning.safe_default,
};

pub const ConnectionPool = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    free_list: ConnList,
    url: []u8,
    tls: TlsConfig,
    tuning: config.SqliteTuning,
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
            .tuning = options.tuning,
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
            const conn = try DatabaseConn.initTuned(url, pool.nextId(), options.tls, options.tuning);
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
                const tuning = self.tuning;
                self.unlock();
                const conn = DatabaseConn.initTuned(self.url, id, tls, tuning) catch {
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

// ── Component router ───────────────────────────────────────────────────
//
// Each component gets its own SQLite file, pool, WAL, and PRAGMA profile, so a
// write on one never holds a lock the other needs. WAL already gives each file
// concurrent readers + one writer; separating files removes *cross-component*
// write serialization entirely (the KG writer and the RAG writer no longer
// contend for a single database's write lock).

pub const Component = enum { kg, rag };

/// Holds the per-component pools and dispatches acquisition by component.
pub const Router = struct {
    kg: ConnectionPool,
    rag: ConnectionPool,

    pub fn acquire(self: *Router, component: Component) PoolError!PooledConnection {
        return switch (component) {
            .kg => self.kg.acquire(),
            .rag => self.rag.acquire(),
        };
    }

    pub fn close(self: *Router) void {
        self.kg.close();
        self.rag.close();
    }
};
