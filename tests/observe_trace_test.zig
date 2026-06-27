//! Tests for src/observe/trace.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/observe/trace.zig");

const Io = std.Io;
const Trace = srcmod.Trace;
const Writer = std.Io.Writer;

// ── Tests ─────────────────────────────────────────────────────────────


test "trace: laps record names, counts, and a monotonic total" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var t = Trace.start(io);
    t.lap("vector", 30);
    t.lap("lexical", 12);
    t.lap("fusion", 40);

    try testing.expectEqual(@as(usize, 3), t.n);
    try testing.expectEqualStrings("vector", t.stages[0].name);
    try testing.expectEqual(@as(u64, 12), t.stages[1].count);
    // total equals the sum of stage durations.
    try testing.expectEqual(t.stages[0].us + t.stages[1].us + t.stages[2].us, t.totalUs());

    var buf: [512]u8 = undefined;
    var w = Writer.fixed(&buf);
    try t.writeJson(&w);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "\"traceId\":") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"name\":\"fusion\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"totalUs\":") != null);
}

test "trace: caps at max_stages without overflowing" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var t = Trace.start(threaded.io());
    for (0..Trace.max_stages + 5) |_| t.lap("s", 1);
    try testing.expectEqual(Trace.max_stages, t.n);
}

test "trace: distinct ids across traces" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const a = Trace.start(io);
    const b = Trace.start(io);
    try testing.expect(a.id != b.id);
}
