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

/// Execute a multi-statement DDL script via prepare/step, so it works on a
/// borrowed `[]const u8` (e.g. an embedded .sql file) without the
/// null-termination `sqlite3_exec` requires. Statements are split on `;`, but
/// the splitter skips `;` inside `--` line comments and `'…'` string literals,
/// so commentary (including "(release 3.37);") and quoted text don't terminate a
/// statement early. Comment/whitespace-only chunks compile to a null statement
/// and are skipped.
pub fn execScript(db: *sqlite3, script: []const u8) Error!void {
    var start: usize = 0;
    var i: usize = 0;
    var in_line_comment = false;
    var in_string = false;
    while (i < script.len) : (i += 1) {
        const ch = script[i];
        if (in_line_comment) {
            if (ch == '\n') in_line_comment = false;
            continue;
        }
        if (in_string) {
            if (ch == '\'') in_string = false;
            continue;
        }
        if (ch == '-' and i + 1 < script.len and script[i + 1] == '-') {
            in_line_comment = true;
            i += 1;
        } else if (ch == '\'') {
            in_string = true;
        } else if (ch == ';') {
            try execOne(db, script[start..i]);
            start = i + 1;
        }
    }
    try execOne(db, script[start..]); // trailing statement without a ';'
}

fn execOne(db: *sqlite3, chunk: []const u8) Error!void {
    const trimmed = std.mem.trim(u8, chunk, " \t\r\n");
    if (trimmed.len == 0) return;
    var stmt: ?*sqlite3_stmt = null;
    try check(sqlite3_prepare_v3(db, trimmed.ptr, @intCast(trimmed.len), 0, &stmt, null));
    const s = stmt orelse return; // comment-only chunk → nothing to run
    defer finalize(s);
    try check(sqlite3_step(s));
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
