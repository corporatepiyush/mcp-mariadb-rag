//! Tests for src/generate/cache.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/generate/cache.zig");
const QueryCache = srcmod.QueryCache;

const Io = std.Io;

test "cache: near-identical query with same sig hits; different sig misses" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var c = try makeCache(threaded.io(), 8, 0.97);
    defer c.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const v1 = [_]f32{ 1.0, 0.0, 0.0 };
    c.put(&v1, 42, "RESULT-A");

    // Same direction (cosine 1.0) + same sig → hit.
    const v2 = [_]f32{ 2.0, 0.0, 0.0 };
    const hit = c.get(a, &v2, 42) orelse return error.ExpectedHit;
    try testing.expectEqualStrings("RESULT-A", hit);

    // Same vector, different param signature → miss.
    try testing.expect(c.get(a, &v2, 99) == null);
}

test "cache: dissimilar query misses" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var c = try makeCache(threaded.io(), 8, 0.97);
    defer c.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const v1 = [_]f32{ 1.0, 0.0 };
    c.put(&v1, 1, "X");
    const ortho = [_]f32{ 0.0, 1.0 }; // cosine 0 < 0.97
    try testing.expect(c.get(arena.allocator(), &ortho, 1) == null);
}

test "cache: ring eviction drops the oldest" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var c = try makeCache(threaded.io(), 2, 0.99);
    defer c.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const e0 = [_]f32{ 1, 0, 0 };
    const e1 = [_]f32{ 0, 1, 0 };
    const e2 = [_]f32{ 0, 0, 1 };
    c.put(&e0, 1, "zero");
    c.put(&e1, 1, "one");
    c.put(&e2, 1, "two"); // evicts e0

    try testing.expect(c.get(a, &e0, 1) == null); // evicted
    try testing.expectEqualStrings("one", c.get(a, &e1, 1) orelse return error.Miss);
    try testing.expectEqualStrings("two", c.get(a, &e2, 1) orelse return error.Miss);
}

test "cache: clear empties everything" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var c = try makeCache(threaded.io(), 4, 0.9);
    defer c.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const v = [_]f32{ 1, 1 };
    c.put(&v, 1, "keep?");
    c.clear();
    try testing.expect(c.get(arena.allocator(), &v, 1) == null);
}

test "cache: disabled (capacity 0) is inert" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var c = try makeCache(threaded.io(), 0, 0.9);
    defer c.deinit();
    try testing.expect(!c.enabled());
    const v = [_]f32{1};
    c.put(&v, 1, "x"); // no-op
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect(c.get(arena.allocator(), &v, 1) == null);
}

// ---- helpers moved from src ----
pub fn makeCache(io: Io, cap: usize, thr: f32) !QueryCache {
    return QueryCache.init(io, testing.allocator, .{ .capacity = cap, .threshold = thr });
}
