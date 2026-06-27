//! Tests for src/sqlite.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/sqlite.zig");
const sqlite3_bind_blob = srcmod.sqlite3_bind_blob;
const sqlite3_bind_double = srcmod.sqlite3_bind_double;
const sqlite3_bind_int64 = srcmod.sqlite3_bind_int64;
const sqlite3_bind_null = srcmod.sqlite3_bind_null;
const sqlite3_bind_text = srcmod.sqlite3_bind_text;
const sqlite3_busy_timeout = srcmod.sqlite3_busy_timeout;
const sqlite3_changes = srcmod.sqlite3_changes;
const sqlite3_clear_bindings = srcmod.sqlite3_clear_bindings;
const sqlite3_column_bytes = srcmod.sqlite3_column_bytes;
const sqlite3_column_count = srcmod.sqlite3_column_count;
const sqlite3_column_double = srcmod.sqlite3_column_double;
const sqlite3_column_int64 = srcmod.sqlite3_column_int64;
const sqlite3_column_name = srcmod.sqlite3_column_name;
const sqlite3_column_text = srcmod.sqlite3_column_text;
const sqlite3_column_type = srcmod.sqlite3_column_type;
const sqlite3_exec = srcmod.sqlite3_exec;
const sqlite3_last_insert_rowid = srcmod.sqlite3_last_insert_rowid;
const sqlite3_reset = srcmod.sqlite3_reset;
const sqlite3_step = srcmod.sqlite3_step;

const SQLITE_DONE = srcmod.SQLITE_DONE;
const SQLITE_FLOAT = srcmod.SQLITE_FLOAT;
const SQLITE_INTEGER = srcmod.SQLITE_INTEGER;
const SQLITE_TEXT = srcmod.SQLITE_TEXT;
const SQLITE_TRANSIENT = srcmod.SQLITE_TRANSIENT;
const check = srcmod.check;
const close = srcmod.close;
const exec = srcmod.exec;
const execScript = srcmod.execScript;
const finalize = srcmod.finalize;
const open = srcmod.open;
const openInMemory = srcmod.openInMemory;
const prepare = srcmod.prepare;

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

test "execScript runs multiple statements, ignoring ';' in comments and strings" {
    const db = try openInMemory();
    defer close(db);

    // A '--' comment containing a semicolon and a string literal containing one
    // must NOT terminate the statement early.
    try execScript(db,
        \\-- a comment with a semicolon; it must not split here
        \\CREATE TABLE a(x TEXT NOT NULL DEFAULT 'has ; inside') STRICT;
        \\CREATE TABLE b(y INTEGER) STRICT;
        \\-- trailing comment-only chunk
    );

    // Both tables exist iff these inserts prepare+step cleanly.
    inline for (.{ "INSERT INTO a(x) VALUES('z')", "INSERT INTO b(y) VALUES(1)" }) |sql| {
        const s = try prepare(db, sql);
        defer finalize(s);
        try check(sqlite3_step(s));
    }
}

test "execScript: empty/comment-only scripts are a no-op" {
    const db = try openInMemory();
    defer close(db);
    try execScript(db, "");
    try execScript(db, "   \n\t  ");
    try execScript(db, "-- only a comment\n-- and another");
    try execScript(db, ";;; ; ;");
}

test "fuzz: execScript never panics on random bytes" {
    const db = try openInMemory();
    defer close(db);
    var prng = std.Random.DefaultPrng.init(0x5C12_F00D);
    const rnd = prng.random();
    var buf: [160]u8 = undefined;
    for (0..1500) |_| {
        const len = rnd.intRangeAtMost(usize, 0, buf.len);
        for (buf[0..len]) |*b| b.* = rnd.int(u8);
        execScript(db, buf[0..len]) catch {}; // any SqliteError is fine; must not panic
    }
}
