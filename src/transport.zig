//! stdio transport built on the Zig 0.16 `std.Io` interface.
//!
//! Takes `io` and `gpa` (in that order, per project convention). stdio is
//! inherently serial: one JSON document per line.
//!
//! Hardening (untrusted peer): each request line is bounded by
//! `config.max_request_bytes` (the `MCP_MAX_REQUEST_MB` knob, tier-scaled). A
//! line that exceeds the cap is *drained* to its terminating newline without
//! buffering the overflow — so a hostile or runaway producer can never grow the
//! per-request arena without bound — and answered with a JSON-RPC error. Reads
//! and writes both go through fixed 64 KiB OS buffers; the only growable buffer
//! is the line accumulator, which the cap bounds.

const std = @import("std");
const server = @import("server.zig");
const pool_mod = @import("pool.zig");
const config_mod = @import("config.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const IN_BUF_SIZE = 64 * 1024;
const OUT_BUF_SIZE = 64 * 1024;

/// Static reply for a request line that overruns the size cap. `id` is unknown
/// (we stopped reading before parsing), so it is null per JSON-RPC.
const OVERSIZE_RESPONSE =
    "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32600,\"message\":\"Request exceeds maximum size\"},\"id\":null}";

// ---- stdio transport: newline-delimited JSON ----------------------------

pub fn runStdio(io: Io, gpa: Allocator, router: *pool_mod.Router, config: *const config_mod.Config) void {
    var in_buf: [IN_BUF_SIZE]u8 = undefined;
    var out_buf: [OUT_BUF_SIZE]u8 = undefined;
    var fr = Io.File.stdin().reader(io, &in_buf);
    var fw = Io.File.stdout().writer(io, &out_buf);
    const r = &fr.interface;
    const w = &fw.interface;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const cap: usize = @intCast(config.max_request_bytes);

    while (true) {
        _ = arena.reset(.retain_capacity);
        const alloc = arena.allocator();

        var line = Writer.Allocating.init(alloc);
        // Accumulate up to `cap` bytes of the line; the '\n' is left unconsumed.
        _ = r.streamDelimiterLimit(&line.writer, '\n', .limited(cap)) catch |err| switch (err) {
            error.StreamTooLong => {
                // Oversized: discard the remainder of the line (no allocation)
                // and reply with an error instead of buffering it.
                _ = r.discardDelimiterInclusive('\n') catch |e| switch (e) {
                    error.EndOfStream => {
                        writeLine(w, OVERSIZE_RESPONSE);
                        return;
                    },
                    error.ReadFailed => {
                        std.log.err("stdin read failed", .{});
                        return;
                    },
                };
                writeLine(w, OVERSIZE_RESPONSE);
                continue;
            },
            error.ReadFailed => {
                std.log.err("stdin read failed", .{});
                return;
            },
            error.WriteFailed => return, // OOM buffering the line
        };

        // streamDelimiterLimit stops at the delimiter or at end-of-stream
        // (the latter is *not* an error). Disambiguate by consuming one byte.
        const b = r.takeByte() catch |err| switch (err) {
            error.EndOfStream => {
                // Final line had no trailing newline.
                processLine(io, alloc, router, config, w, line.written());
                return;
            },
            error.ReadFailed => {
                std.log.err("stdin read failed", .{});
                return;
            },
        };
        std.debug.assert(b == '\n');
        processLine(io, alloc, router, config, w, line.written());
    }
}

/// Write a response followed by the newline framing, flushing. Errors (broken
/// pipe / OOM in the output buffer) are terminal for this line.
fn writeLine(w: *Writer, bytes: []const u8) void {
    w.writeAll(bytes) catch return;
    w.writeByte('\n') catch return;
    w.flush() catch return;
}

fn processLine(
    io: Io,
    alloc: Allocator,
    router: *pool_mod.Router,
    config: *const config_mod.Config,
    w: *Writer,
    raw: []const u8,
) void {
    const line = std.mem.trimEnd(u8, raw, "\r");
    if (line.len == 0) return;
    const response = server.handleRequest(io, alloc, line, router, config) orelse return;
    writeLine(w, response);
}
