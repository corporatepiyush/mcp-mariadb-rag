//! stdio transport built on the Zig 0.16 `std.Io` interface.
//!
//! Takes `io` and `gpa` (in that order, per project convention). stdio is
//! inherently serial: one JSON document per line.

const std = @import("std");
const server = @import("server.zig");
const pool_mod = @import("pool.zig");
const config_mod = @import("config.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const IN_BUF_SIZE = 64 * 1024;
const OUT_BUF_SIZE = 64 * 1024;

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

    while (true) {
        _ = arena.reset(.retain_capacity);
        const alloc = arena.allocator();

        var line = Writer.Allocating.init(alloc);
        if (r.streamDelimiter(&line.writer, '\n')) |_| {
            r.toss(1); // discard the '\n' that streamDelimiter stopped at
            processLine(io, alloc, router, config, w, line.written());
        } else |err| switch (err) {
            // Stream ended: handle a final line that had no trailing newline.
            error.EndOfStream => {
                processLine(io, alloc, router, config, w, line.written());
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
    router: *pool_mod.Router,
    config: *const config_mod.Config,
    w: *Writer,
    raw: []const u8,
) void {
    const line = std.mem.trimEnd(u8, raw, "\r");
    if (line.len == 0) return;
    const response = server.handleRequest(io, alloc, line, router, config) orelse return;
    w.writeAll(response) catch return;
    w.writeByte('\n') catch return;
    w.flush() catch return;
}
