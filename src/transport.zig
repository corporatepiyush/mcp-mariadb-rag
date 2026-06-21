//! Transports built on the Zig 0.16 `std.Io` interface.
//!
//! Both transports take `io` and `gpa` (in that order, per project convention).
//! stdio is inherently serial (one JSON document per line); HTTP dispatches
//! each connection as a `std.Io.async` task, so slow queries no longer block
//! other clients. Concurrency is bounded by a ring of in-flight futures, and
//! each task gets its own arena carved from the thread-safe `gpa`.

const std = @import("std");
const server = @import("server.zig");
const pool_mod = @import("pool.zig");
const config_mod = @import("config.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const IN_BUF_SIZE = 64 * 1024;
const OUT_BUF_SIZE = 64 * 1024;
const MAX_BODY = 16 * 1024 * 1024;
/// Maximum number of HTTP connections handled concurrently.
const MAX_INFLIGHT = 64;

// ---- stdio transport: newline-delimited JSON ----------------------------

pub fn runStdio(io: Io, gpa: Allocator, pool: *pool_mod.ConnectionPool, config: *const config_mod.Config) void {
    var in_buf: [IN_BUF_SIZE]u8 = undefined;
    var out_buf: [OUT_BUF_SIZE]u8 = undefined;
    var fr = Io.File.stdin().reader(io, &in_buf);
    var fw = Io.File.stdout().writer(io, &out_buf);
    const r = &fr.interface;
    const w = &fw.interface;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    while (true) {
        _ = arena.reset(.retain_capacity);
        const alloc = arena.allocator();

        var line = Writer.Allocating.init(alloc);
        if (r.streamDelimiter(&line.writer, '\n')) |_| {
            r.toss(1); // discard the '\n' that streamDelimiter stopped at
            processLine(io, alloc, pool, config, w, line.written());
        } else |err| switch (err) {
            // Stream ended: handle a final line that had no trailing newline.
            error.EndOfStream => {
                processLine(io, alloc, pool, config, w, line.written());
                return;
            },
            error.ReadFailed => {
                std.log.err("stdin read failed", .{});
                return;
            },
            error.WriteFailed => return, // OOM buffering the line
        }
    }
}

fn processLine(
    io: Io,
    alloc: Allocator,
    pool: *pool_mod.ConnectionPool,
    config: *const config_mod.Config,
    w: *Writer,
    raw: []const u8,
) void {
    const line = std.mem.trimEnd(u8, raw, "\r");
    if (line.len == 0) return;
    const response = server.handleRequest(io, alloc, line, pool, config) orelse return;
    w.writeAll(response) catch return;
    w.writeByte('\n') catch return;
    w.flush() catch return;
}

// ---- HTTP transport (concurrent) ----------------------------------------

pub fn runHttp(io: Io, gpa: Allocator, pool: *pool_mod.ConnectionPool, config: *const config_mod.Config) void {
    // `IpAddress.parse` only accepts IP literals; map the loopback hostname.
    const host = if (std.ascii.eqlIgnoreCase(config.server.host, "localhost"))
        "127.0.0.1"
    else
        config.server.host;

    const addr = Io.net.IpAddress.parse(host, config.server.http_port) catch {
        std.log.err("invalid bind address {s}:{d}", .{ host, config.server.http_port });
        return;
    };
    var listener = addr.listen(io, .{ .reuse_address = true }) catch |err| {
        std.log.err("listen on {s}:{d} failed: {s}", .{ host, config.server.http_port, @errorName(err) });
        return;
    };
    defer listener.deinit(io);
    std.log.info("HTTP listening on {s}:{d}", .{ host, config.server.http_port });

    // Ring of in-flight connection tasks. Reusing a slot first awaits the task
    // that previously occupied it, which both reclaims its resources and bounds
    // concurrency to MAX_INFLIGHT.
    var slots: [MAX_INFLIGHT]?Io.Future(void) = @splat(null);
    defer for (&slots) |*slot| {
        if (slot.*) |*f| _ = f.await(io);
    };

    var idx: usize = 0;
    while (true) {
        const stream = listener.accept(io) catch |err| {
            std.log.warn("accept failed: {s}", .{@errorName(err)});
            continue;
        };
        if (slots[idx]) |*f| {
            _ = f.await(io);
            slots[idx] = null;
        }
        slots[idx] = io.async(handleConnTask, .{ io, gpa, pool, config, stream });
        idx = (idx + 1) % MAX_INFLIGHT;
    }
}

/// One connection, run as an async task. Owns the stream and its own arena.
fn handleConnTask(
    io: Io,
    gpa: Allocator,
    pool: *pool_mod.ConnectionPool,
    config: *const config_mod.Config,
    stream_in: Io.net.Stream,
) void {
    var stream = stream_in;
    defer stream.close(io);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    handleHttpConn(io, arena.allocator(), &stream, pool, config);
}

const HttpRequest = struct {
    content_length: usize = 0,
    authorized: bool = false,
};

fn handleHttpConn(
    io: Io,
    alloc: Allocator,
    stream: *Io.net.Stream,
    pool: *pool_mod.ConnectionPool,
    config: *const config_mod.Config,
) void {
    var in_buf: [IN_BUF_SIZE]u8 = undefined;
    var out_buf: [OUT_BUF_SIZE]u8 = undefined;
    var sr = stream.reader(io, &in_buf);
    var sw = stream.writer(io, &out_buf);
    const r = &sr.interface;
    const w = &sw.interface;

    const req = parseHttpHeaders(r, config) catch {
        sendHttp(w, "400 Bad Request", "{\"error\":\"bad request\"}");
        return;
    };

    if (!req.authorized) {
        sendHttp(w, "401 Unauthorized", "{\"error\":\"unauthorized\"}");
        return;
    }
    if (req.content_length == 0 or req.content_length > MAX_BODY) {
        sendHttp(w, "400 Bad Request", "{\"error\":\"missing or oversized body\"}");
        return;
    }

    const body = alloc.alloc(u8, req.content_length) catch {
        sendHttp(w, "500 Internal Server Error", "{\"error\":\"oom\"}");
        return;
    };
    r.readSliceAll(body) catch {
        sendHttp(w, "400 Bad Request", "{\"error\":\"truncated body\"}");
        return;
    };

    const response = server.handleRequest(io, alloc, body, pool, config) orelse "";
    sendHttp(w, "200 OK", response);
}

/// Read the request line and headers, extracting Content-Length and validating
/// the bearer token. Authorization passes automatically when no token is
/// configured.
fn parseHttpHeaders(r: *Io.Reader, config: *const config_mod.Config) !HttpRequest {
    var req: HttpRequest = .{ .authorized = (config.server.auth_token == null) };
    while (true) {
        const raw = r.takeDelimiterInclusive('\n') catch return error.BadRequest;
        const line = std.mem.trimEnd(u8, raw, "\r\n");
        if (line.len == 0) break; // blank line terminates headers

        if (asciiHasPrefix(line, "content-length:")) {
            const v = std.mem.trim(u8, line["content-length:".len..], " \t");
            req.content_length = std.fmt.parseInt(usize, v, 10) catch 0;
        } else if (asciiHasPrefix(line, "authorization:")) {
            if (config.server.auth_token) |token| {
                const v = std.mem.trim(u8, line["authorization:".len..], " \t");
                if (std.mem.startsWith(u8, v, "Bearer ") and
                    constantTimeEql(v["Bearer ".len..], token))
                {
                    req.authorized = true;
                }
            }
        }
    }
    return req;
}

fn sendHttp(w: *Writer, comptime status: []const u8, payload: []const u8) void {
    w.print(
        "HTTP/1.1 " ++ status ++ "\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
        .{payload.len},
    ) catch return;
    w.writeAll(payload) catch return;
    w.flush() catch return;
}

fn asciiHasPrefix(haystack: []const u8, comptime lower_prefix: []const u8) bool {
    if (haystack.len < lower_prefix.len) return false;
    inline for (lower_prefix, 0..) |c, i| {
        if (std.ascii.toLower(haystack[i]) != c) return false;
    }
    return true;
}

/// Length-aware constant-time comparison, to avoid leaking the auth token
/// through response timing.
fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}
