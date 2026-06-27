//! Per-query tracing — the observability spine (PLAN.md §8).
//!
//! A `Trace` stamps a monotonic clock at each retrieval stage so an operator can
//! see where a query spent its time and how many candidates each stage handled.
//! It is allocation-free (a fixed stage array), so it's cheap enough to leave on
//! for every request: the handler logs a structured line, and echoes the trace
//! into the response when the caller passes `"trace": true`.

const std = @import("std");
const Io = std.Io;
const Writer = std.Io.Writer;

/// Process-wide monotonic id source, so concurrent queries get distinct trace
/// ids without coordination.
var id_counter: std.atomic.Value(u64) = .init(1);

fn nextId() u64 {
    return id_counter.fetchAdd(1, .monotonic);
}

pub const Trace = struct {
    pub const max_stages = 8;

    pub const Stage = struct { name: []const u8, us: u64, count: u64 };

    io: Io,
    id: u64,
    last: Io.Timestamp,
    stages: [max_stages]Stage = undefined,
    n: usize = 0,

    pub fn start(io: Io) Trace {
        return .{ .io = io, .id = nextId(), .last = Io.Timestamp.now(io, .awake) };
    }

    /// Record the elapsed time since the previous lap as stage `name`, handling
    /// `count` candidates. Silently capped at `max_stages`.
    pub fn lap(self: *Trace, name: []const u8, count: u64) void {
        if (self.n >= self.stages.len) return;
        const now = Io.Timestamp.now(self.io, .awake);
        const us = self.last.durationTo(now).toMicroseconds();
        self.stages[self.n] = .{ .name = name, .us = @intCast(@max(@as(i64, 0), us)), .count = count };
        self.n += 1;
        self.last = now;
    }

    pub fn totalUs(self: *const Trace) u64 {
        var sum: u64 = 0;
        for (self.stages[0..self.n]) |s| sum += s.us;
        return sum;
    }

    /// `{"traceId":N,"stages":[{"name":..,"us":..,"count":..}],"totalUs":N}`.
    /// Stage names are compile-time literals, so no escaping is needed.
    pub fn writeJson(self: *const Trace, w: *Writer) !void {
        try w.print("{{\"traceId\":{d},\"stages\":[", .{self.id});
        for (self.stages[0..self.n], 0..) |s, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{{\"name\":\"{s}\",\"us\":{d},\"count\":{d}}}", .{ s.name, s.us, s.count });
        }
        try w.print("],\"totalUs\":{d}}}", .{self.totalUs()});
    }

    /// One-line structured summary for `std.log`: `id=.. total_us=.. vector=.. …`.
    pub fn writeLog(self: *const Trace, w: *Writer) !void {
        try w.print("id={d} total_us={d}", .{ self.id, self.totalUs() });
        for (self.stages[0..self.n]) |s| try w.print(" {s}={d}us/{d}", .{ s.name, s.us, s.count });
    }
};
