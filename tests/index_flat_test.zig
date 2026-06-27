//! Tests for src/index/flat.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/index/flat.zig");

const TopK = srcmod.TopK;

// ── Tests ─────────────────────────────────────────────────────────────


test "TopK keeps the k smallest regardless of insertion order" {
    var buf: [3]TopK(usize).Entry = undefined;
    var tk = TopK(usize).init(&buf);
    const dists = [_]f32{ 5, 1, 9, 3, 7, 2, 8 };
    for (dists, 0..) |d, i| _ = tk.offer(d, i);

    const sorted = tk.sortedAsc();
    try testing.expectEqual(@as(usize, 3), sorted.len);
    try testing.expectEqual(@as(f32, 1), sorted[0].dist);
    try testing.expectEqual(@as(f32, 2), sorted[1].dist);
    try testing.expectEqual(@as(f32, 3), sorted[2].dist);
    // items travel with their distances
    try testing.expectEqual(@as(usize, 1), sorted[0].item);
    try testing.expectEqual(@as(usize, 5), sorted[1].item);
    try testing.expectEqual(@as(usize, 3), sorted[2].item);
}

test "TopK below capacity returns everything sorted" {
    var buf: [10]TopK(u8).Entry = undefined;
    var tk = TopK(u8).init(&buf);
    _ = tk.offer(3, 'c');
    _ = tk.offer(1, 'a');
    _ = tk.offer(2, 'b');
    const s = tk.sortedAsc();
    try testing.expectEqual(@as(usize, 3), s.len);
    try testing.expectEqual(@as(u8, 'a'), s[0].item);
    try testing.expectEqual(@as(u8, 'b'), s[1].item);
    try testing.expectEqual(@as(u8, 'c'), s[2].item);
}

test "TopK offer reports acceptance and rejects worse-than-worst" {
    var buf: [2]TopK(usize).Entry = undefined;
    var tk = TopK(usize).init(&buf);
    try testing.expect(tk.offer(5, 0)); // fills
    try testing.expect(tk.offer(3, 1)); // fills
    try testing.expect(!tk.offer(9, 2)); // worse than worst kept (5) -> rejected
    try testing.expect(tk.offer(1, 3)); // better -> evicts 5
    const s = tk.sortedAsc();
    try testing.expectEqual(@as(f32, 1), s[0].dist);
    try testing.expectEqual(@as(f32, 3), s[1].dist);
}

test "TopK with zero capacity accepts nothing" {
    var buf: [0]TopK(usize).Entry = .{};
    var tk = TopK(usize).init(&buf);
    try testing.expect(!tk.offer(1, 0));
    try testing.expectEqual(@as(usize, 0), tk.sortedAsc().len);
}

test "TopK rejects NaN distances" {
    var buf: [2]TopK(usize).Entry = undefined;
    var tk = TopK(usize).init(&buf);
    try testing.expect(!tk.offer(std.math.nan(f32), 0));
    try testing.expect(tk.offer(1, 1));
    try testing.expectEqual(@as(usize, 1), tk.len);
}

test "fuzz: TopK result equals a full sort's k-prefix" {
    var prng = std.Random.DefaultPrng.init(0x70BC);
    const rnd = prng.random();

    for (0..500) |_| {
        const n = rnd.intRangeAtMost(usize, 0, 40);
        const k = rnd.intRangeAtMost(usize, 1, 8);

        var all: [40]f32 = undefined;
        for (all[0..n]) |*d| d.* = rnd.float(f32) * 100;

        var buf: [8]TopK(usize).Entry = undefined;
        var tk = TopK(usize).init(buf[0..k]);
        for (all[0..n], 0..) |d, i| _ = tk.offer(d, i);

        // Reference: sort a copy, take k smallest distances.
        var ref: [40]f32 = undefined;
        @memcpy(ref[0..n], all[0..n]);
        std.sort.block(f32, ref[0..n], {}, std.sort.asc(f32));

        const got = tk.sortedAsc();
        const want = @min(k, n);
        try testing.expectEqual(want, got.len);
        for (0..want) |i| try testing.expectEqual(ref[i], got[i].dist);
    }
}
