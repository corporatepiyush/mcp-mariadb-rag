//! Schema introspection and DDL handlers.
//!
//! Every user-supplied identifier (table / view / schema / index name) is run
//! through `validation.validateIdentifier` before it touches a query and is
//! emitted with the appropriate quoting helper. This closes the SQL injection
//! holes in the original, which interpolated raw names into both backtick and
//! single-quote contexts.
//!
//! Handlers follow the project convention of leading with `io` then
//! `allocator`; `io` is unused by these SQL-only handlers.

const std = @import("std");
const pool = @import("../pool.zig");
const validation = @import("../validation.zig");
const json = @import("../json.zig");
const mod = @import("mod.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Array = std.json.Array;
const PooledConn = pool.PooledConnection;
const Payload = mod.Payload;
const Writer = std.Io.Writer;

// ---- read-only introspection (static SQL) -------------------------------

fn queryStatic(allocator: Allocator, conn: *PooledConn, sql: []const u8) Payload {
    const result = conn.query(allocator, sql) catch return mod.errPayload("Database error");
    return mod.resultPayload(allocator, result);
}

pub fn listTables(_: Io, allocator: Allocator, conn: *PooledConn, _: ?Value) Payload {
    return queryStatic(allocator, conn, "SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE FROM information_schema.TABLES WHERE TABLE_SCHEMA NOT IN ('mysql', 'performance_schema', 'sys', 'information_schema') ORDER BY TABLE_SCHEMA, TABLE_NAME");
}

pub fn listIndexes(_: Io, allocator: Allocator, conn: *PooledConn, _: ?Value) Payload {
    return queryStatic(allocator, conn, "SELECT TABLE_SCHEMA, TABLE_NAME, INDEX_NAME, COLUMN_NAME, NON_UNIQUE, INDEX_TYPE, SEQ_IN_INDEX FROM information_schema.STATISTICS WHERE TABLE_SCHEMA NOT IN ('mysql', 'performance_schema', 'sys', 'information_schema') ORDER BY TABLE_SCHEMA, TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX");
}

pub fn listSchemas(_: Io, allocator: Allocator, conn: *PooledConn, _: ?Value) Payload {
    return queryStatic(allocator, conn, "SELECT SCHEMA_NAME, DEFAULT_CHARACTER_SET_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('mysql', 'performance_schema', 'sys', 'information_schema') ORDER BY SCHEMA_NAME");
}

pub fn showConstraints(_: Io, allocator: Allocator, conn: *PooledConn, _: ?Value) Payload {
    return queryStatic(allocator, conn, "SELECT TABLE_SCHEMA, TABLE_NAME, CONSTRAINT_NAME, CONSTRAINT_TYPE FROM information_schema.TABLE_CONSTRAINTS WHERE TABLE_SCHEMA NOT IN ('mysql', 'performance_schema', 'sys', 'information_schema') ORDER BY TABLE_SCHEMA, TABLE_NAME, CONSTRAINT_NAME");
}

// ---- introspection parameterized by a table name ------------------------

pub fn describeTable(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const table = mod.getStringParam(args, "table") orelse return mod.errPayload("Missing 'table' parameter");
    validation.validateIdentifier(table) catch return mod.errPayload("Invalid table name");
    const sql = mod.renderToOwned(allocator, writeLiteralQuery, .{
        "SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, EXTRA, COLUMN_KEY FROM information_schema.COLUMNS WHERE TABLE_NAME = '",
        table,
        "' ORDER BY ORDINAL_POSITION",
    }) catch return mod.errPayload("Allocation error");
    return queryStatic(allocator, conn, sql);
}

pub fn listTriggers(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const table = mod.getStringParam(args, "table") orelse return mod.errPayload("Missing 'table' parameter");
    validation.validateIdentifier(table) catch return mod.errPayload("Invalid table name");
    const sql = mod.renderToOwned(allocator, writeLiteralQuery, .{
        "SELECT TRIGGER_NAME, EVENT_MANIPULATION, ACTION_TIMING, ACTION_STATEMENT, EVENT_OBJECT_TABLE, TRIGGER_SCHEMA FROM information_schema.TRIGGERS WHERE EVENT_OBJECT_TABLE = '",
        table,
        "' ORDER BY TRIGGER_NAME",
    }) catch return mod.errPayload("Allocation error");
    return queryStatic(allocator, conn, sql);
}

/// `prefix + escaped(value) + suffix`, escaping `value` for a single-quoted
/// SQL string literal.
fn writeLiteralQuery(w: *Writer, prefix: []const u8, value: []const u8, suffix: []const u8) !void {
    try w.writeAll(prefix);
    try validation.writeEscapedLiteral(w, value);
    try w.writeAll(suffix);
}

// ---- DDL ----------------------------------------------------------------

/// Build a statement via `build_fn`, execute it, and return its payload.
fn execBuilt(
    allocator: Allocator,
    conn: *PooledConn,
    action: []const u8,
    label: []const u8,
    name: []const u8,
    comptime build_fn: anytype,
    build_args: anytype,
) Payload {
    const sql = mod.renderToOwned(allocator, build_fn, build_args) catch |err| return ddlBuildError(err);
    _ = conn.execute(sql) catch return mod.errPayload("Query failed");
    const text = mod.renderToOwned(allocator, json.writeStatus, .{ action, label, name }) catch
        return mod.errPayload("Serialization error");
    return .{ .text = text, .is_error = false };
}

fn ddlBuildError(err: anyerror) Payload {
    return switch (err) {
        error.NotAString => mod.errPayload("Column must be a string"),
        else => mod.errPayload("Allocation error"),
    };
}

/// Join a JSON array of string column specs with ", ". The specs are free-form
/// SQL fragments (column definitions / column lists) by design.
fn writeColumnList(w: *Writer, cols: Array) !void {
    for (cols.items, 0..) |col, i| {
        if (col != .string) return error.NotAString;
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(col.string);
    }
}

pub fn createTable(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const table = mod.getStringParam(args, "table") orelse return mod.errPayload("Missing 'table' parameter");
    const cols = mod.getArrayParam(args, "columns") orelse return mod.errPayload("Missing 'columns' parameter");
    validation.validateIdentifier(table) catch return mod.errPayload("Invalid table name");

    return execBuilt(allocator, conn, "CREATE TABLE", "table", table, writeCreateTable, .{ table, cols });
}

fn writeCreateTable(w: *Writer, table: []const u8, cols: Array) !void {
    try w.writeAll("CREATE TABLE ");
    try validation.writeQuotedIdent(w, table);
    try w.writeAll(" (");
    try writeColumnList(w, cols);
    try w.writeAll(") ENGINE=TidesDB WRITE_BUFFER_SIZE=268435456");
}

pub fn dropTable(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const table = mod.getStringParam(args, "table") orelse return mod.errPayload("Missing 'table' parameter");
    validation.validateIdentifier(table) catch return mod.errPayload("Invalid table name");
    const if_exists = mod.getBoolParam(args, "if_exists", false);
    const cascade = mod.getBoolParam(args, "cascade", false);
    return execBuilt(allocator, conn, "DROP TABLE", "table", table, writeDropTable, .{ table, if_exists, cascade });
}

fn writeDropTable(w: *Writer, table: []const u8, if_exists: bool, cascade: bool) !void {
    try w.writeAll("DROP TABLE ");
    if (if_exists) try w.writeAll("IF EXISTS ");
    try validation.writeQuotedIdent(w, table);
    if (cascade) try w.writeAll(" CASCADE");
}

pub fn createView(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const name = mod.getStringParam(args, "view_name") orelse return mod.errPayload("Missing 'view_name' parameter");
    const query_text = mod.getStringParam(args, "query") orelse return mod.errPayload("Missing 'query' parameter");
    validation.validateIdentifier(name) catch return mod.errPayload("Invalid view name");
    const or_replace = mod.getBoolParam(args, "or_replace", false);
    return execBuilt(allocator, conn, "CREATE VIEW", "view_name", name, writeCreateView, .{ name, query_text, or_replace });
}

fn writeCreateView(w: *Writer, name: []const u8, query_text: []const u8, or_replace: bool) !void {
    try w.writeAll(if (or_replace) "CREATE OR REPLACE VIEW " else "CREATE VIEW ");
    try validation.writeQuotedIdent(w, name);
    try w.writeAll(" AS ");
    try w.writeAll(query_text);
}

pub fn dropView(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const name = mod.getStringParam(args, "view_name") orelse return mod.errPayload("Missing 'view_name' parameter");
    validation.validateIdentifier(name) catch return mod.errPayload("Invalid view name");
    const if_exists = mod.getBoolParam(args, "if_exists", false);
    return execBuilt(allocator, conn, "DROP VIEW", "view_name", name, writeDropObject, .{ "DROP VIEW", if_exists, name });
}

pub fn createSchema(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const name = mod.getStringParam(args, "schema_name") orelse return mod.errPayload("Missing 'schema_name' parameter");
    validation.validateIdentifier(name) catch return mod.errPayload("Invalid schema name");
    const if_not_exists = mod.getBoolParam(args, "if_not_exists", false);
    return execBuilt(allocator, conn, "CREATE SCHEMA", "schema_name", name, writeCreateSchema, .{ name, if_not_exists });
}

fn writeCreateSchema(w: *Writer, name: []const u8, if_not_exists: bool) !void {
    try w.writeAll("CREATE SCHEMA ");
    if (if_not_exists) try w.writeAll("IF NOT EXISTS ");
    try validation.writeQuotedIdent(w, name);
}

pub fn dropSchema(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const name = mod.getStringParam(args, "schema_name") orelse return mod.errPayload("Missing 'schema_name' parameter");
    validation.validateIdentifier(name) catch return mod.errPayload("Invalid schema name");
    const if_exists = mod.getBoolParam(args, "if_exists", false);
    return execBuilt(allocator, conn, "DROP SCHEMA", "schema_name", name, writeDropObject, .{ "DROP SCHEMA", if_exists, name });
}

/// `<verb> [IF EXISTS ]<quoted name>` (DROP VIEW / DROP SCHEMA).
fn writeDropObject(w: *Writer, verb: []const u8, if_exists: bool, name: []const u8) !void {
    try w.writeAll(verb);
    try w.writeByte(' ');
    if (if_exists) try w.writeAll("IF EXISTS ");
    try validation.writeQuotedIdent(w, name);
}

pub fn createIndex(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const idx = mod.getStringParam(args, "index_name") orelse return mod.errPayload("Missing 'index_name' parameter");
    const table = mod.getStringParam(args, "table") orelse return mod.errPayload("Missing 'table' parameter");
    const cols = mod.getArrayParam(args, "columns") orelse return mod.errPayload("Missing 'columns' parameter");
    validation.validateIdentifier(idx) catch return mod.errPayload("Invalid index name");
    validation.validateIdentifier(table) catch return mod.errPayload("Invalid table name");
    const unique = mod.getBoolParam(args, "unique", false);
    return execBuilt(allocator, conn, "CREATE INDEX", "index_name", idx, writeCreateIndex, .{ idx, table, cols, unique });
}

fn writeCreateIndex(w: *Writer, idx: []const u8, table: []const u8, cols: Array, unique: bool) !void {
    try w.writeAll(if (unique) "CREATE UNIQUE INDEX " else "CREATE INDEX ");
    try validation.writeQuotedIdent(w, idx);
    try w.writeAll(" ON ");
    try validation.writeQuotedIdent(w, table);
    try w.writeAll(" (");
    try writeColumnList(w, cols);
    try w.writeByte(')');
}

pub fn dropIndex(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const table = mod.getStringParam(args, "table") orelse return mod.errPayload("Missing 'table' parameter");
    const idx = mod.getStringParam(args, "index_name") orelse return mod.errPayload("Missing 'index_name' parameter");
    validation.validateIdentifier(table) catch return mod.errPayload("Invalid table name");
    validation.validateIdentifier(idx) catch return mod.errPayload("Invalid index name");
    return execBuilt(allocator, conn, "DROP INDEX", "index_name", idx, writeDropIndex, .{ table, idx });
}

fn writeDropIndex(w: *Writer, table: []const u8, idx: []const u8) !void {
    try w.writeAll("ALTER TABLE ");
    try validation.writeQuotedIdent(w, table);
    try w.writeAll(" DROP INDEX ");
    try validation.writeQuotedIdent(w, idx);
}

// ---- tests: SQL generation (no database required) -----------------------

const testing = std.testing;

fn renderSql(buf: []u8, comptime f: anytype, args: anytype) ![]u8 {
    var w = Writer.fixed(buf);
    try @call(.auto, f, .{&w} ++ args);
    return w.buffered();
}

test "writeCreateTable emits quoted ident, columns, and ENGINE clause" {
    var cols = Array.init(testing.allocator);
    defer cols.deinit();
    try cols.append(.{ .string = "id INT PRIMARY KEY" });
    try cols.append(.{ .string = "name VARCHAR(50)" });

    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "CREATE TABLE `t` (id INT PRIMARY KEY, name VARCHAR(50)) ENGINE=TidesDB WRITE_BUFFER_SIZE=268435456",
        try renderSql(&buf, writeCreateTable, .{ "t", cols }),
    );
}

test "writeDropTable: IF EXISTS + CASCADE" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "DROP TABLE IF EXISTS `t` CASCADE",
        try renderSql(&buf, writeDropTable, .{ "t", true, true }),
    );
    try testing.expectEqualStrings(
        "DROP TABLE `t`",
        try renderSql(&buf, writeDropTable, .{ "t", false, false }),
    );
}

test "writeCreateView: OR REPLACE" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "CREATE OR REPLACE VIEW `v` AS SELECT 1",
        try renderSql(&buf, writeCreateView, .{ "v", "SELECT 1", true }),
    );
}

test "writeCreateSchema: IF NOT EXISTS" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "CREATE SCHEMA IF NOT EXISTS `s`",
        try renderSql(&buf, writeCreateSchema, .{ "s", true }),
    );
}

test "writeDropIndex builds ALTER TABLE ... DROP INDEX" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "ALTER TABLE `t` DROP INDEX `i`",
        try renderSql(&buf, writeDropIndex, .{ "t", "i" }),
    );
}

test "writeLiteralQuery escapes single quotes (injection-safe literal context)" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "WHERE x = 'O''Brien'",
        try renderSql(&buf, writeLiteralQuery, .{ "WHERE x = '", "O'Brien", "'" }),
    );
}
