const std = @import("std");

pub const sqlite3 = opaque {};
pub const sqlite3_stmt = opaque {};

pub const SQLITE_OK = 0;
pub const SQLITE_ROW = 100;
pub const SQLITE_DONE = 101;
pub const SQLITE_ERROR = 1;
pub const SQLITE_BUSY = 5;
pub const SQLITE_LOCKED = 6;
pub const SQLITE_NOMEM = 7;
pub const SQLITE_READONLY = 8;
pub const SQLITE_INTERRUPT = 9;
pub const SQLITE_IOERR = 10;
pub const SQLITE_CORRUPT = 11;
pub const SQLITE_SCHEMA = 17;
pub const SQLITE_TOOBIG = 18;
pub const SQLITE_CONSTRAINT = 19;
pub const SQLITE_MISMATCH = 20;
pub const SQLITE_MISUSE = 21;
pub const SQLITE_RANGE = 25;
pub const SQLITE_NOTADB = 26;

pub const SQLITE_OPEN_READWRITE = 0x00000002;
pub const SQLITE_OPEN_CREATE = 0x00000004;
pub const SQLITE_OPEN_URI = 0x00000040;
pub const SQLITE_OPEN_FULLMUTEX = 0x00010000;

pub const SQLITE_PREPARE_PERSISTENT = 0x01;

pub const SQLITE_INTEGER = 1;
pub const SQLITE_FLOAT = 2;
pub const SQLITE_TEXT = 3;
pub const SQLITE_BLOB = 4;
pub const SQLITE_NULL = 5;

pub const SQLITE_TRANSIENT: ?*anyopaque = @ptrFromInt(~@as(usize, 0));
pub const SQLITE_STATIC: ?*anyopaque = @ptrFromInt(0);

pub const Error = error{
    SqliteBusy,
    SqliteLocked,
    SqliteNoMem,
    SqliteReadOnly,
    SqliteInterrupt,
    SqliteIoErr,
    SqliteCorrupt,
    SqliteSchema,
    SqliteTooBig,
    SqliteConstraint,
    SqliteMismatch,
    SqliteRange,
    SqliteNotADb,
    SqliteError,
};

pub fn check(rc: c_int) Error!void {
    return switch (rc) {
        SQLITE_OK => {},
        SQLITE_ROW => {},
        SQLITE_DONE => {},
        SQLITE_BUSY => error.SqliteBusy,
        SQLITE_LOCKED => error.SqliteLocked,
        SQLITE_NOMEM => error.SqliteNoMem,
        SQLITE_READONLY => error.SqliteReadOnly,
        SQLITE_INTERRUPT => error.SqliteInterrupt,
        SQLITE_IOERR => error.SqliteIoErr,
        SQLITE_CORRUPT => error.SqliteCorrupt,
        SQLITE_SCHEMA => error.SqliteSchema,
        SQLITE_TOOBIG => error.SqliteTooBig,
        SQLITE_CONSTRAINT => error.SqliteConstraint,
        SQLITE_MISMATCH => error.SqliteMismatch,
        SQLITE_RANGE => error.SqliteRange,
        SQLITE_NOTADB => error.SqliteNotADb,
        else => error.SqliteError,
    };
}

pub extern "c" fn sqlite3_open_v2(path: [*:0]const u8, ppDb: *?*sqlite3, flags: c_int, zVfs: ?[*:0]const u8) c_int;
pub extern "c" fn sqlite3_close_v2(db: ?*sqlite3) c_int;
pub extern "c" fn sqlite3_db_handle(stmt: ?*sqlite3_stmt) ?*sqlite3;
pub extern "c" fn sqlite3_exec(db: ?*sqlite3, sql: [*:0]const u8, callback: ?*const fn (?*anyopaque, c_int, **u8, **u8) callconv(.c) c_int, arg: ?*anyopaque, errmsg: ?*?*u8) c_int;
pub extern "c" fn sqlite3_prepare_v3(db: ?*sqlite3, sql: [*]const u8, nByte: c_int, flags: c_uint, ppStmt: *?*sqlite3_stmt, pzTail: ?*?[*:0]const u8) c_int;
pub extern "c" fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
pub extern "c" fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;
pub extern "c" fn sqlite3_reset(stmt: ?*sqlite3_stmt) c_int;
pub extern "c" fn sqlite3_clear_bindings(stmt: ?*sqlite3_stmt) c_int;
pub extern "c" fn sqlite3_bind_int64(stmt: ?*sqlite3_stmt, idx: c_int, val: i64) c_int;
pub extern "c" fn sqlite3_bind_double(stmt: ?*sqlite3_stmt, idx: c_int, val: f64) c_int;
pub extern "c" fn sqlite3_bind_text(stmt: ?*sqlite3_stmt, idx: c_int, val: [*]const u8, n: c_int, destructor: ?*anyopaque) c_int;
pub extern "c" fn sqlite3_bind_blob(stmt: ?*sqlite3_stmt, idx: c_int, val: ?*const anyopaque, n: c_int, destructor: ?*anyopaque) c_int;
pub extern "c" fn sqlite3_bind_null(stmt: ?*sqlite3_stmt, idx: c_int) c_int;
pub extern "c" fn sqlite3_column_count(stmt: ?*sqlite3_stmt) c_int;
pub extern "c" fn sqlite3_column_type(stmt: ?*sqlite3_stmt, iCol: c_int) c_int;
pub extern "c" fn sqlite3_column_int64(stmt: ?*sqlite3_stmt, iCol: c_int) i64;
pub extern "c" fn sqlite3_column_double(stmt: ?*sqlite3_stmt, iCol: c_int) f64;
pub extern "c" fn sqlite3_column_text(stmt: ?*sqlite3_stmt, iCol: c_int) [*:0]const u8;
pub extern "c" fn sqlite3_column_blob(stmt: ?*sqlite3_stmt, iCol: c_int) ?*const anyopaque;
pub extern "c" fn sqlite3_column_bytes(stmt: ?*sqlite3_stmt, iCol: c_int) c_int;
pub extern "c" fn sqlite3_column_name(stmt: ?*sqlite3_stmt, iCol: c_int) [*:0]const u8;
pub extern "c" fn sqlite3_changes(db: ?*sqlite3) c_int;
pub extern "c" fn sqlite3_last_insert_rowid(db: ?*sqlite3) i64;
pub extern "c" fn sqlite3_busy_timeout(db: ?*sqlite3, ms: c_int) c_int;
pub extern "c" fn sqlite3_errmsg(db: ?*sqlite3) [*:0]const u8;
pub extern "c" fn sqlite3_extended_errcode(db: ?*sqlite3) c_int;

pub fn open(path: [*:0]const u8) Error!*sqlite3 {
    var db: ?*sqlite3 = null;
    const flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX;
    try check(sqlite3_open_v2(path, &db, flags, null));
    return db.?;
}

pub fn openInMemory() Error!*sqlite3 {
    var db: ?*sqlite3 = null;
    const flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI;
    try check(sqlite3_open_v2("file::memory:?cache=shared", &db, flags, null));
    return db.?;
}

pub fn close(db: *sqlite3) void {
    _ = sqlite3_close_v2(db);
}

pub fn exec(db: *sqlite3, sql: [*:0]const u8) Error!void {
    try check(sqlite3_exec(db, sql, null, null, null));
}

pub fn prepare(db: *sqlite3, sql: []const u8) Error!*sqlite3_stmt {
    var stmt: ?*sqlite3_stmt = null;
    try check(sqlite3_prepare_v3(db, sql.ptr, @intCast(sql.len), SQLITE_PREPARE_PERSISTENT, &stmt, null));
    return stmt.?;
}

pub fn finalize(stmt: *sqlite3_stmt) void {
    _ = sqlite3_finalize(stmt);
}

pub fn dbHandle(stmt: *sqlite3_stmt) *sqlite3 {
    return sqlite3_db_handle(stmt).?;
}

pub fn errmsg(db: *sqlite3) [*:0]const u8 {
    return sqlite3_errmsg(db);
}

pub fn errcode(db: *sqlite3) c_int {
    return sqlite3_extended_errcode(db);
}

test "open / close in-memory database" {
    const db = try openInMemory();
    defer close(db);
    try exec(db, "CREATE TABLE test(id INTEGER PRIMARY KEY, val TEXT)");
    try exec(db, "INSERT INTO test(id, val) VALUES(1, 'hello')");
    try exec(db, "INSERT INTO test(id, val) VALUES(2, 'world')");
}

test "prepare / bind / step / column" {
    const db = try openInMemory();
    defer close(db);
    try exec(db, "CREATE TABLE t(a INTEGER, b TEXT, c REAL)");
    try exec(db, "INSERT INTO t(a, b, c) VALUES(10, 'ten', 1.5), (20, 'twenty', 2.5), (null, 'null', null)");

    const stmt = try prepare(db, "SELECT a, b, c FROM t WHERE a IS NOT NULL ORDER BY a");
    defer finalize(stmt);

    try check(sqlite3_step(stmt));
    try std.testing.expectEqual(SQLITE_INTEGER, sqlite3_column_type(stmt, 0));
    try std.testing.expectEqual(@as(i64, 10), sqlite3_column_int64(stmt, 0));
    try std.testing.expectEqual(SQLITE_TEXT, sqlite3_column_type(stmt, 1));
    try std.testing.expectEqualStrings("ten", std.mem.sliceTo(sqlite3_column_text(stmt, 1), 0));
    try std.testing.expectEqual(SQLITE_FLOAT, sqlite3_column_type(stmt, 2));
    try std.testing.expectEqual(@as(f64, 1.5), sqlite3_column_double(stmt, 2));

    try check(sqlite3_step(stmt));
    try std.testing.expectEqual(SQLITE_INTEGER, sqlite3_column_type(stmt, 0));
    try std.testing.expectEqual(@as(i64, 20), sqlite3_column_int64(stmt, 0));
    try std.testing.expectEqual(SQLITE_TEXT, sqlite3_column_type(stmt, 1));
    try std.testing.expectEqualStrings("twenty", std.mem.sliceTo(sqlite3_column_text(stmt, 1), 0));
    try std.testing.expectEqual(SQLITE_FLOAT, sqlite3_column_type(stmt, 2));
    try std.testing.expectEqual(@as(f64, 2.5), sqlite3_column_double(stmt, 2));

    try std.testing.expectEqual(SQLITE_DONE, sqlite3_step(stmt));
}

test "error handling - bad SQL" {
    const db = try openInMemory();
    defer close(db);
    const rc = sqlite3_exec(db, "CREATE TABLE", null, null, null);
    try std.testing.expectError(error.SqliteError, check(rc));
}

test "bind parameters" {
    const db = try openInMemory();
    defer close(db);
    try exec(db, "CREATE TABLE t(a INTEGER, b TEXT, c REAL, d BLOB)");

    const stmt = try prepare(db, "INSERT INTO t(a, b, c, d) VALUES(?, ?, ?, ?)");
    defer finalize(stmt);

    try check(sqlite3_bind_int64(stmt, 1, 42));
    try check(sqlite3_bind_text(stmt, 2, "hello", 5, SQLITE_TRANSIENT));
    try check(sqlite3_bind_double(stmt, 3, 3.14));
    var blob = [_]u8{ 0x00, 0x01, 0x02 };
    try check(sqlite3_bind_blob(stmt, 4, &blob, 3, SQLITE_TRANSIENT));
    try check(sqlite3_step(stmt));
    try check(sqlite3_reset(stmt));
    try check(sqlite3_clear_bindings(stmt));

    const q = try prepare(db, "SELECT a, b, c, d FROM t");
    defer finalize(q);
    try check(sqlite3_step(q));
    try std.testing.expectEqual(@as(i64, 42), sqlite3_column_int64(q, 0));
    try std.testing.expectEqualStrings("hello", std.mem.sliceTo(sqlite3_column_text(q, 1), 0));
    try std.testing.expectEqual(@as(f64, 3.14), sqlite3_column_double(q, 2));
    try std.testing.expectEqual(@as(c_int, 3), sqlite3_column_bytes(q, 3));
}

test "changes and last_insert_rowid" {
    const db = try openInMemory();
    defer close(db);
    try exec(db, "CREATE TABLE t(id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT)");
    try exec(db, "INSERT INTO t(v) VALUES('a')");
    try exec(db, "INSERT INTO t(v) VALUES('b')");
    try exec(db, "INSERT INTO t(v) VALUES('c')");
    try std.testing.expectEqual(@as(i64, 3), sqlite3_last_insert_rowid(db));
    try std.testing.expectEqual(@as(c_int, 1), sqlite3_changes(db));
}

test "busy timeout" {
    const db = try openInMemory();
    defer close(db);
    try check(sqlite3_busy_timeout(db, 5000));
}

test "column name and count" {
    const db = try openInMemory();
    defer close(db);
    try exec(db, "CREATE TABLE t(a INTEGER, b TEXT)");
    const stmt = try prepare(db, "SELECT a, b FROM t");
    defer finalize(stmt);
    try std.testing.expectEqual(@as(c_int, 2), sqlite3_column_count(stmt));
    try std.testing.expectEqualStrings("a", std.mem.sliceTo(sqlite3_column_name(stmt, 0), 0));
    try std.testing.expectEqualStrings("b", std.mem.sliceTo(sqlite3_column_name(stmt, 1), 0));
}

test "fuzz - random SQL strings" {
    var rng = std.Random.DefaultPrng.init(42);
    const rand = rng.random();
    const db = try openInMemory();
    defer close(db);

    const chars = " ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789,;'\"-+*/%()";
    var buf: [256]u8 = undefined;
    for (0..100) |_| {
        const len = rand.uintLessThan(usize, buf.len - 1);
        for (0..len) |i| {
            buf[i] = chars[rand.uintLessThan(u8, chars.len)];
        }
        buf[len] = 0;
        _ = sqlite3_exec(db, buf[0..len :0], null, null, null);
    }
}

test "fuzz - bind with random values" {
    var rng = std.Random.DefaultPrng.init(12345);
    const rand = rng.random();
    const db = try openInMemory();
    defer close(db);
    try exec(db, "CREATE TABLE t(a INTEGER, b REAL, c TEXT)");

    const stmt = try prepare(db, "INSERT INTO t VALUES(?, ?, ?)");
    defer finalize(stmt);

    for (0..50) |_| {
        try check(sqlite3_reset(stmt));
        try check(sqlite3_clear_bindings(stmt));

        switch (rand.uintLessThan(u8, 4)) {
            0 => try check(sqlite3_bind_int64(stmt, 1, rand.int(i64))),
            1 => try check(sqlite3_bind_double(stmt, 1, rand.float(f64))),
            2 => try check(sqlite3_bind_null(stmt, 1)),
            3 => {},
            else => {},
        }
        switch (rand.uintLessThan(u8, 4)) {
            0 => try check(sqlite3_bind_int64(stmt, 2, rand.int(i64))),
            1 => try check(sqlite3_bind_double(stmt, 2, rand.float(f64))),
            2 => try check(sqlite3_bind_null(stmt, 2)),
            3 => {},
            else => {},
        }
        switch (rand.uintLessThan(u8, 3)) {
            0 => {
                var str: [32]u8 = undefined;
                for (&str) |*c| c.* = 'a' + rand.uintLessThan(u8, 26);
                try check(sqlite3_bind_text(stmt, 3, &str, 32, SQLITE_TRANSIENT));
            },
            1 => try check(sqlite3_bind_null(stmt, 3)),
            2 => {},
            else => {},
        }

        _ = sqlite3_step(stmt);
    }
}
