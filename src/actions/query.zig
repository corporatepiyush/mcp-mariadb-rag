const std = @import("std");
const pool = @import("../pool.zig");
const validation = @import("../validation.zig");
const mod = @import("mod.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const PooledConn = pool.PooledConnection;
const Payload = mod.Payload;

/// Validate `sql` against `prefix`, run it, and serialize the result.
fn queryAndPayload(allocator: Allocator, conn: *PooledConn, sql: []const u8, prefix: []const u8) Payload {
    validation.validateSql(sql, prefix) catch return mod.errPayload("Invalid SQL");
    const result = conn.query(allocator, sql) catch return mod.errPayload("Query failed");
    return mod.resultPayload(allocator, result);
}

pub fn executeQuery(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const sql = mod.getStringParam(args, "sql") orelse return mod.errPayload("Missing 'sql' parameter");
    return queryAndPayload(allocator, conn, sql, "SELECT");
}

pub fn executeInsert(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const sql = mod.getStringParam(args, "sql") orelse return mod.errPayload("Missing 'sql' parameter");
    return queryAndPayload(allocator, conn, sql, "INSERT");
}

pub fn executeUpdate(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const sql = mod.getStringParam(args, "sql") orelse return mod.errPayload("Missing 'sql' parameter");
    return queryAndPayload(allocator, conn, sql, "UPDATE");
}

pub fn executeDelete(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const sql = mod.getStringParam(args, "sql") orelse return mod.errPayload("Missing 'sql' parameter");
    return queryAndPayload(allocator, conn, sql, "DELETE");
}

pub fn explainQuery(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const sql = mod.getStringParam(args, "sql") orelse return mod.errPayload("Missing 'sql' parameter");
    // Only allow EXPLAIN of a single SELECT, so we never run arbitrary DML.
    validation.validateSql(sql, "SELECT") catch return mod.errPayload("Invalid SQL");
    const explain_sql = std.fmt.allocPrint(allocator, "EXPLAIN {s}", .{sql}) catch
        return mod.errPayload("Allocation error");
    const result = conn.query(allocator, explain_sql) catch return mod.errPayload("Explain failed");
    return mod.resultPayload(allocator, result);
}
