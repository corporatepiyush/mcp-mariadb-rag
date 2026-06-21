//! JSON-RPC / MCP protocol layer.
//!
//! Pure with respect to transport: `handleRequest` takes a request body and
//! returns an owned response string (or `null` for notifications). The stdio
//! and HTTP transports live in `transport.zig`.

const std = @import("std");
const pool_mod = @import("pool.zig");
const config_mod = @import("config.zig");
const actions = @import("actions/mod.zig");
const json = @import("json.zig");

const Value = std.json.Value;
const Writer = std.Io.Writer;

const SUPPORTED_VERSIONS = [_][]const u8{ "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05" };
const LATEST_VERSION = "2025-11-25";

const SERVER_INFO = "\"capabilities\":{\"tools\":{\"listChanged\":false}},\"serverInfo\":{\"name\":\"mcp-mariadb-rag\",\"version\":\"0.1.1\"}";

// ---- response builders (write into a *Writer) ---------------------------

fn writeInitialize(w: *Writer, id: ?Value, params: ?Value) Writer.Error!void {
    var ver: []const u8 = LATEST_VERSION;
    if (params) |p| {
        if (p == .object) {
            if (p.object.get("protocolVersion")) |v| {
                if (v == .string) {
                    for (SUPPORTED_VERSIONS) |sv| {
                        if (std.mem.eql(u8, v.string, sv)) {
                            ver = v.string;
                            break;
                        }
                    }
                }
            }
        }
    }
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"result\":{\"protocolVersion\":");
    try json.writeQuoted(w, ver);
    try w.writeByte(',');
    try w.writeAll(SERVER_INFO);
    try w.writeAll("},\"id\":");
    try json.writeRpcId(w, id);
    try w.writeByte('}');
}

fn writeRpcError(w: *Writer, id: ?Value, code: i64, msg: []const u8) Writer.Error!void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":");
    try w.print("{d}", .{code});
    try w.writeAll(",\"message\":");
    try json.writeQuoted(w, msg);
    try w.writeAll("},\"id\":");
    try json.writeRpcId(w, id);
    try w.writeByte('}');
}

fn writeToolResult(w: *Writer, id: ?Value, is_error: bool, payload: []const u8) Writer.Error!void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"result\":{\"isError\":");
    try w.writeAll(if (is_error) "true" else "false");
    try w.writeAll(",\"content\":[{\"type\":\"text\",\"text\":");
    try json.writeQuoted(w, payload);
    try w.writeAll("}]},\"id\":");
    try json.writeRpcId(w, id);
    try w.writeByte('}');
}

fn writeResult(w: *Writer, id: ?Value, comptime raw_result: []const u8) Writer.Error!void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"result\":" ++ raw_result ++ ",\"id\":");
    try json.writeRpcId(w, id);
    try w.writeByte('}');
}

fn writeToolsList(w: *Writer, id: ?Value) Writer.Error!void {
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"result\":{\"tools\":");
    try w.writeAll(@embedFile("tools.json"));
    try w.writeAll("},\"id\":");
    try json.writeRpcId(w, id);
    try w.writeByte('}');
}

/// Render `build_fn` into an owned response string. Serialization is in-memory,
/// so the only failure is OOM, which we surface as a parse-error response so the
/// transport always has something to send.
fn render(allocator: std.mem.Allocator, comptime build_fn: anytype, args: anytype) ?[]const u8 {
    var aw = Writer.Allocating.init(allocator);
    errdefer aw.deinit();
    @call(.auto, build_fn, .{&aw.writer} ++ args) catch return null;
    return aw.toOwnedSlice() catch null;
}

// ---- request dispatch ---------------------------------------------------

/// Parse and handle a JSON-RPC request. Returns `null` for notifications (no
/// response is sent). The returned string is allocated in `allocator`.
pub fn handleRequest(
    io: std.Io,
    allocator: std.mem.Allocator,
    body: []const u8,
    pool: *pool_mod.ConnectionPool,
    config: *const config_mod.Config,
) ?[]const u8 {
    const trimmed = std.mem.trim(u8, body, " \t\n\r");
    if (trimmed.len == 0) return null;

    var parsed = std.json.parseFromSlice(Value, allocator, trimmed, .{}) catch
        return render(allocator, writeRpcError, .{ @as(?Value, null), @as(i64, -32700), "Parse error" });
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object)
        return render(allocator, writeRpcError, .{ @as(?Value, null), @as(i64, -32600), "Invalid request" });
    const obj = root.object;

    const method = if (obj.get("method")) |v| (if (v == .string) v.string else "") else "";
    const params = obj.get("params");
    const id = obj.get("id");

    if (std.mem.eql(u8, method, "initialize"))
        return render(allocator, writeInitialize, .{ id, params });
    if (std.mem.eql(u8, method, "tools/list"))
        return render(allocator, writeToolsList, .{id});
    if (std.mem.eql(u8, method, "tools/call"))
        return handleToolsCall(io, allocator, id, params, pool, config);
    if (std.mem.eql(u8, method, "ping"))
        return render(allocator, writeResult, .{ id, "null" });
    if (std.mem.startsWith(u8, method, "notifications/"))
        return null; // notifications get no response
    if (method.len == 0)
        return render(allocator, writeRpcError, .{ id, @as(i64, -32600), "Missing method" });

    return render(allocator, writeRpcError, .{ id, @as(i64, -32601), "Method not found" });
}

fn handleToolsCall(
    io: std.Io,
    allocator: std.mem.Allocator,
    id: ?Value,
    params: ?Value,
    pool: *pool_mod.ConnectionPool,
    config: *const config_mod.Config,
) ?[]const u8 {
    const tool_name = actions.getStringParam(params, "name") orelse "";
    const args = if (params) |p| (if (p == .object) p.object.get("arguments") else null) else null;

    if (tool_name.len == 0)
        return render(allocator, writeRpcError, .{ id, @as(i64, -32602), "Missing 'name' parameter" });

    if (config.server.access_mode == .restricted and actions.isWriteTool(tool_name))
        return render(allocator, writeToolResult, .{ id, true, "Write operations not allowed in restricted mode" });

    const handler = actions.registry.get(tool_name) orelse
        return render(allocator, writeRpcError, .{ id, @as(i64, -32601), "Tool not found" });

    var conn = pool.acquire() catch
        return render(allocator, writeRpcError, .{ id, @as(i64, -32001), "Pool error" });
    defer conn.deinit();

    const result = handler(io, allocator, &conn, args);
    return render(allocator, writeToolResult, .{ id, result.is_error, result.text });
}
