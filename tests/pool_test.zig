//! Tests for src/pool.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/pool.zig");
const Io = std.Io;

const ConnectionPool = srcmod.ConnectionPool;
const DatabaseConn = srcmod.DatabaseConn;
const Options = srcmod.Options;
const PooledConnection = srcmod.PooledConnection;
const QueryResult = srcmod.QueryResult;
const Router = srcmod.Router;
const sqlite = srcmod.sqlite;

// ── Tests ──────────────────────────────────────────────────────────────


test "Router dispatches to the right component pool" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const opts = Options{ .min_size = 1, .max_size = 2, .tls = .{ .enforce = false, .verify = false, .ca_path = null } };

    var router = Router{
        .kg = try ConnectionPool.init(io, testing.allocator, "sqlite://", opts),
        .rag = try ConnectionPool.init(io, testing.allocator, "sqlite://", opts),
    };
    defer router.close();

    var kg_conn = try router.acquire(.kg);
    defer kg_conn.deinit();
    _ = try kg_conn.execute("CREATE TABLE k(x INTEGER)");
    var rag_conn = try router.acquire(.rag);
    defer rag_conn.deinit();
    _ = try rag_conn.execute("SELECT 1");
}

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

test "DatabaseConn constraint violation on execute" {
    var conn = try DatabaseConn.init("sqlite://", 7, .{ .enforce = false, .verify = false, .ca_path = null });
    defer conn.deinit();
    _ = try conn.execute("CREATE TABLE t(x INTEGER UNIQUE)");
    _ = try conn.execute("INSERT INTO t VALUES(1)");
    try testing.expectError(error.SqliteConstraint, conn.execute("INSERT INTO t VALUES(1)"));
}

test "DatabaseConn execute with long SQL" {
    var conn = try DatabaseConn.init("sqlite://", 8, .{ .enforce = false, .verify = false, .ca_path = null });
    defer conn.deinit();
    _ = try conn.execute("CREATE TABLE t(x TEXT)");

    const prefix = "INSERT INTO t VALUES('";
    const suffix = "')";
    const content_len = 4096;
    var buf: [prefix.len + content_len + suffix.len]u8 = undefined;

    for (prefix, 0..) |byte, j| buf[j] = byte;
    for (buf[prefix.len..][0..content_len]) |*c| c.* = 'a';
    for (suffix, 0..) |byte, j| buf[prefix.len + content_len + j] = byte;

    try testing.expect(buf.len > 4096);
    const n = try conn.execute(buf[0..]);
    try testing.expectEqual(@as(u64, 1), n);
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

test "PooledConnection transaction commit and rollback" {
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

    _ = try conn.execute("CREATE TABLE t(x INTEGER)");

    // Commit persists.
    try conn.begin();
    _ = try conn.execute("INSERT INTO t VALUES(1)");
    _ = try conn.execute("INSERT INTO t VALUES(2)");
    try conn.commit();

    // Rollback discards.
    try conn.begin();
    _ = try conn.execute("INSERT INTO t VALUES(3)");
    conn.rollback();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const res = try conn.query(arena.allocator(), "SELECT COUNT(*) FROM t");
    try testing.expectEqualStrings("2", res.rows.?[0].values[0].?);
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
