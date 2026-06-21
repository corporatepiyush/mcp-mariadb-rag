//! MariaDB connection wrapper and a bounded, thread-safe connection pool.
//!
//! Design notes / fixes over the original:
//!   * Uses `mysql_real_query` (length-delimited) instead of `mysql_query`,
//!     which required a NUL-terminated string and over-read non-terminated
//!     slices.
//!   * Distinguishes "statement produced no result set" from "store_result
//!     failed" via `mysql_field_count`.
//!   * Preserves SQL NULL distinctly from the empty string, and classifies each
//!     column's wire type so the serializer never coerces text to numbers.
//!   * The pool enforces `max_size`, blocks (with timeout) when exhausted, and
//!     never performs network I/O (connect / ping) while holding the lock.

const c = @import("c");
const std = @import("std");
const types = @import("types.zig");
const url_mod = @import("url.zig");
const config = @import("config.zig");

pub const TlsConfig = config.TlsConfig;

pub const Row = types.Row;
pub const QueryResult = types.QueryResult;
pub const ColumnKind = types.ColumnKind;

pub const MariaDBConn = struct {
    conn: *c.MYSQL,
    id: u64,
    created_at: i64,

    pub fn init(url: []const u8, id: u64, tls: TlsConfig) !MariaDBConn {
        const conn = c.mysql_init(null) orelse return error.ConnectionFailed;
        errdefer c.mysql_close(conn);

        const params = url_mod.parse(url) catch return error.InvalidUrl;

        // The C client needs NUL-terminated strings; stage them on the stack.
        var ubuf: [256]u8 = undefined;
        var pbuf: [256]u8 = undefined;
        var hbuf: [256]u8 = undefined;
        var dbuf: [256]u8 = undefined;
        var cabuf: [1024]u8 = undefined;

        const c_user = try cstr(&ubuf, params.user);
        const c_pass = try cstr(&pbuf, params.pass);
        const c_host = try cstr(&hbuf, params.host);
        const c_db = try cstr(&dbuf, params.db);

        try applyTls(conn, tls, &cabuf);

        if (c.mysql_real_connect(conn, c_host, c_user, c_pass, c_db, params.port, null, 0) == null) {
            std.log.err("MariaDB connection failed: {s}", .{c.mysql_error(conn)});
            return error.ConnectionFailed;
        }

        _ = c.mysql_set_character_set(conn, "utf8mb4");
        return .{ .conn = conn, .id = id, .created_at = @intCast(c.time(null)) };
    }

    pub fn isAlive(self: *const MariaDBConn) bool {
        return c.mysql_ping(self.conn) == 0;
    }

    pub fn deinit(self: *const MariaDBConn) void {
        c.mysql_close(self.conn);
    }

    /// Run a query and materialize the result set (if any) into `a`.
    pub fn query(self: *MariaDBConn, a: std.mem.Allocator, sql: []const u8) !QueryResult {
        if (c.mysql_real_query(self.conn, sql.ptr, sql.len) != 0) return error.QueryFailed;

        const result = c.mysql_store_result(self.conn) orelse {
            // NULL can mean "no result set" (DML/DDL) or a genuine error.
            // A statement that legitimately returns no columns has
            // field_count == 0; anything else is a failure.
            if (c.mysql_field_count(self.conn) != 0) return error.QueryFailed;
            const affected = c.mysql_affected_rows(self.conn);
            return .{
                .rows = null,
                .column_names = null,
                .column_kinds = null,
                .num_fields = 0,
                .num_rows = affected,
                .affected_rows = affected,
                .insert_id = c.mysql_insert_id(self.conn),
            };
        };
        defer c.mysql_free_result(result);

        const num_fields: usize = @intCast(c.mysql_num_fields(result));
        const num_rows = c.mysql_num_rows(result);
        const fields = c.mysql_fetch_fields(result);

        const col_names = try a.alloc([]const u8, num_fields);
        const col_kinds = try a.alloc(ColumnKind, num_fields);
        for (0..num_fields) |i| {
            const f = &fields[i];
            col_names[i] = try a.dupe(u8, f.name[0..std.mem.len(f.name)]);
            col_kinds[i] = classifyColumn(f.type);
        }

        var row_list: std.ArrayList(Row) = .empty;
        while (c.mysql_fetch_row(result)) |row| {
            const lengths = c.mysql_fetch_lengths(result);
            const values = try a.alloc(?[]const u8, num_fields);
            for (0..num_fields) |i| {
                values[i] = if (row[i]) |ptr|
                    try a.dupe(u8, ptr[0..lengths[i]])
                else
                    null; // SQL NULL, distinct from ""
            }
            try row_list.append(a, .{ .values = values });
        }

        return .{
            .rows = try row_list.toOwnedSlice(a),
            .column_names = col_names,
            .column_kinds = col_kinds,
            .num_fields = num_fields,
            .num_rows = num_rows,
            .affected_rows = num_rows,
            .insert_id = 0,
        };
    }

    /// Run a statement that returns no result set, yielding the affected count.
    pub fn execute(self: *MariaDBConn, sql: []const u8) !u64 {
        if (c.mysql_real_query(self.conn, sql.ptr, sql.len) != 0) return error.QueryFailed;
        return c.mysql_affected_rows(self.conn);
    }
};

/// Apply TLS connection options before `mysql_real_connect`.
fn applyTls(conn: *c.MYSQL, tls: TlsConfig, ca_buf: []u8) !void {
    var on: u8 = 1;
    if (tls.enforce) {
        _ = c.mysql_options(conn, c.MYSQL_OPT_SSL_ENFORCE, @ptrCast(&on));
    }
    if (tls.verify) {
        _ = c.mysql_options(conn, c.MYSQL_OPT_SSL_VERIFY_SERVER_CERT, @ptrCast(&on));
    }
    if (tls.ca_path) |ca| {
        const ca_cstr = try cstr(ca_buf, ca);
        _ = c.mysql_options(conn, c.MYSQL_OPT_SSL_CA, @ptrCast(ca_cstr));
    }
}

/// Copy an optional Zig slice into `buf` as a NUL-terminated C string, or null.
fn cstr(buf: []u8, value: ?[]const u8) ![*c]const u8 {
    const v = value orelse return null;
    if (v.len + 1 > buf.len) return error.InvalidUrl;
    @memcpy(buf[0..v.len], v);
    buf[v.len] = 0;
    return buf.ptr;
}

/// Map a MariaDB wire type to a JSON rendering class. Only true numeric column
/// types render as bare JSON numbers; everything else stays a string so values
/// like zip codes ("007") or timestamps are never silently mangled.
fn classifyColumn(t: c.enum_field_types) ColumnKind {
    return switch (t) {
        c.MYSQL_TYPE_DECIMAL,
        c.MYSQL_TYPE_TINY,
        c.MYSQL_TYPE_SHORT,
        c.MYSQL_TYPE_LONG,
        c.MYSQL_TYPE_FLOAT,
        c.MYSQL_TYPE_DOUBLE,
        c.MYSQL_TYPE_LONGLONG,
        c.MYSQL_TYPE_INT24,
        c.MYSQL_TYPE_YEAR,
        c.MYSQL_TYPE_NEWDECIMAL,
        => .numeric,
        else => .text,
    };
}

pub const PooledConnection = struct {
    conn: MariaDBConn,
    pool: ?*ConnectionPool,
    /// Cleared if a query on this connection fails, so a possibly-broken
    /// connection is discarded rather than returned to the pool.
    valid: bool,

    pub fn deinit(self: *PooledConnection) void {
        if (self.pool) |p| {
            p.release(self.conn, self.valid);
        } else {
            self.conn.deinit();
        }
    }

    /// The server's configured default storage engine (falls back to TidesDB
    /// for a pool-less test connection).
    pub fn defaultEngine(self: *const PooledConnection) []const u8 {
        return if (self.pool) |p| p.default_engine else "TidesDB";
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

const ConnList = std.ArrayList(MariaDBConn);

pub const PoolError = error{ PoolClosed, ConnectionFailed, InvalidUrl };

/// Bounded, thread-safe connection pool.
///
/// Synchronization uses the Zig 0.16 `std.Io.Mutex`/`Condition`, which are
/// futex-backed and therefore need the `Io` instance (stored here). Critical
/// sections only touch in-memory bookkeeping; all network I/O (connect / ping)
/// happens with the lock released. The blocking wait path is only reachable
/// when more than `max_size` callers contend concurrently — harmless for the
/// current single-threaded transports, correct if they later go concurrent.
pub const Options = struct {
    min_size: u32,
    max_size: u32,
    tls: TlsConfig,
    /// Default CREATE TABLE engine. Borrowed; must outlive the pool.
    default_engine: []const u8 = "TidesDB",
};

pub const ConnectionPool = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    free_list: ConnList,
    url: []u8,
    tls: TlsConfig,
    default_engine: []const u8,
    current_id: u64,
    /// Live connections, whether idle in `free_list` or checked out.
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
            .default_engine = options.default_engine,
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
            const conn = try MariaDBConn.init(url, pool.nextId(), options.tls);
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

    /// Check out a connection, creating one on demand up to `max_size` and
    /// blocking when the pool is saturated. Network operations are performed
    /// outside the lock.
    pub fn acquire(self: *ConnectionPool) PoolError!PooledConnection {
        self.lock();
        while (true) {
            if (self.closed) {
                self.unlock();
                return error.PoolClosed;
            }

            if (self.free_list.pop()) |conn| {
                // Validate outside the lock; a dead idle connection is dropped.
                self.unlock();
                if (conn.isAlive()) return .{ .conn = conn, .pool = self, .valid = true };
                conn.deinit();
                self.lock();
                self.total_count -= 1;
                self.cond.signal(self.io); // freed a slot
                continue;
            }

            if (self.total_count < self.max_size) {
                self.total_count += 1;
                const id = self.nextId();
                const tls = self.tls;
                self.unlock();
                const conn = MariaDBConn.init(self.url, id, tls) catch {
                    self.lock();
                    self.total_count -= 1;
                    self.cond.signal(self.io);
                    self.unlock();
                    return error.ConnectionFailed;
                };
                return .{ .conn = conn, .pool = self, .valid = true };
            }

            // Saturated: wait for a release (or for the pool to close).
            self.cond.waitUncancelable(self.io, &self.mutex);
        }
    }

    fn release(self: *ConnectionPool, conn: MariaDBConn, valid: bool) void {
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
        // Capacity was reserved at init, so this cannot fail.
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
        self.cond.broadcast(self.io); // wake any blocked acquirers
        self.unlock();
        self.allocator.free(self.url);
    }
};
