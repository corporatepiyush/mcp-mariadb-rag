//! Tests for src/index/hnsw.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/index/hnsw.zig");
const fusion = @import("../src/rag/fusion.zig");
const Candidate = srcmod.Candidate;
const ascDist = srcmod.ascDist;
const Allocator = std.mem.Allocator;

const Hnsw = srcmod.Hnsw;

test "hnsw: empty index returns no results" {
    var h = Hnsw.init(testing.allocator, .{ .dims = 4 });
    defer h.deinit();
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var q = [_]f32{ 1, 0, 0, 0 };
    try testing.expectEqual(@as(usize, 0), (try h.search(arena.allocator(), &q, 5, 16)).len);
}

test "hnsw: single node is found and carries its label" {
    var h = Hnsw.init(testing.allocator, .{ .dims = 4 });
    defer h.deinit();
    var v = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    _ = try h.insert(&v, 42);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const res = try h.search(arena.allocator(), &v, 3, 16);
    try testing.expectEqual(@as(usize, 1), res.len);
    try testing.expectEqual(@as(u64, 42), res[0].label);
    try testing.expectApproxEqAbs(@as(f32, 0), res[0].dist, 1e-5);
}

test "hnsw: k larger than corpus returns the whole corpus" {
    var h = Hnsw.init(testing.allocator, .{ .dims = 4, .seed = 7 });
    defer h.deinit();
    inline for (.{ [_]f32{ 1, 0, 0, 0 }, [_]f32{ 0, 1, 0, 0 }, [_]f32{ 0, 0, 1, 0 } }, 0..) |v, i| {
        var vv = v;
        _ = try h.insert(&vv, i);
    }
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var q = [_]f32{ 1, 0, 0, 0 };
    const res = try h.search(arena.allocator(), &q, 10, 16);
    try testing.expectEqual(@as(usize, 3), res.len);
    try testing.expectEqual(@as(u64, 0), res[0].label); // exact match nearest
}

test "hnsw: high recall@10 versus brute force on 300 random vectors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var prng = std.Random.DefaultPrng.init(0xA11CE);
    const rnd = prng.random();
    const n = 300;
    const vecs = try a.alloc([4]f32, n);
    for (vecs) |*v| for (v) |*x| {
        x.* = rnd.float(f32) * 2 - 1;
    };

    var h = Hnsw.init(testing.allocator, .{ .dims = 4, .m = 16, .ef_construction = 100, .seed = 0xBEEF });
    defer h.deinit();
    for (vecs, 0..) |*v, i| _ = try h.insert(v, @intCast(i));

    var hits: usize = 0;
    var total: usize = 0;
    const k = 10;
    for (0..40) |_| {
        var q: [4]f32 = undefined;
        for (&q) |*x| x.* = rnd.float(f32) * 2 - 1;

        const truth = try bruteTopK(a, vecs, q, k);
        const got = try h.search(a, &q, k, 64);

        for (truth) |t| {
            total += 1;
            for (got) |r| {
                if (r.label == t) {
                    hits += 1;
                    break;
                }
            }
        }
    }
    const recall = @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(total));
    try testing.expect(recall >= 0.90); // approximate, but should be near-exact at this scale
}

test "fuzz: hnsw insert/search never panics on random ops" {
    var prng = std.Random.DefaultPrng.init(0xF0F0);
    const rnd = prng.random();

    var h = Hnsw.init(testing.allocator, .{ .dims = 4, .m = 8, .ef_construction = 32, .seed = 0xC0DE });
    defer h.deinit();

    var qarena = std.heap.ArenaAllocator.init(testing.allocator);
    defer qarena.deinit();

    for (0..400) |i| {
        var v: [4]f32 = undefined;
        for (&v) |*x| x.* = @bitCast(rnd.int(u32)); // includes NaN/inf
        _ = try h.insert(&v, @intCast(i));

        if (i % 7 == 0) {
            var q: [4]f32 = undefined;
            for (&q) |*x| x.* = rnd.float(f32);
            const res = try h.search(qarena.allocator(), &q, rnd.intRangeAtMost(usize, 0, 12), rnd.intRangeAtMost(usize, 1, 40));
            for (res) |r| try testing.expect(std.math.isFinite(r.dist) or r.dist == std.math.inf(f32));
        }
    }
    try testing.expectEqual(@as(usize, 400), h.len());
}

// ---- helpers moved from src ----
pub fn bruteTopK(a: Allocator, vecs: []const [4]f32, q: [4]f32, k: usize) ![]usize {
    const cands = try a.alloc(Candidate, vecs.len);
    for (vecs, 0..) |v, i| cands[i] = .{ .dist = 1.0 - fusion.cosineSimilarity(&v, &q), .id = @intCast(i) };
    std.sort.block(Candidate, cands, {}, ascDist);
    const out = try a.alloc(usize, @min(k, vecs.len));
    for (out, 0..) |*o, i| o.* = cands[i].id;
    return out;
}
