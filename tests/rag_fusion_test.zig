//! Tests for src/rag/fusion.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/rag/fusion.zig");

const cosineSimilarity = srcmod.cosineSimilarity;
const cosineSimilarityI8 = srcmod.cosineSimilarityI8;
const default_rrf_k = srcmod.default_rrf_k;
const euclideanDistance = srcmod.euclideanDistance;
const hammingDistance = srcmod.hammingDistance;
const mmrSelect = srcmod.mmrSelect;
const reciprocalRankFusion = srcmod.reciprocalRankFusion;

// ── Tests ─────────────────────────────────────────────────────────────


test "cosine: identical, orthogonal, opposite" {
    var a = [_]f32{ 1, 2, 3 };
    var b = [_]f32{ 1, 2, 3 };
    try testing.expectApproxEqAbs(@as(f32, 1.0), cosineSimilarity(&a, &b), 1e-6);

    var x = [_]f32{ 1, 0 };
    var y = [_]f32{ 0, 1 };
    try testing.expectApproxEqAbs(@as(f32, 0.0), cosineSimilarity(&x, &y), 1e-6);

    var p = [_]f32{ 1, 1 };
    var q = [_]f32{ -1, -1 };
    try testing.expectApproxEqAbs(@as(f32, -1.0), cosineSimilarity(&p, &q), 1e-6);
}

test "cosine: zero vector yields 0" {
    var a = [_]f32{ 0, 0, 0 };
    var b = [_]f32{ 1, 2, 3 };
    try testing.expectEqual(@as(f32, 0), cosineSimilarity(&a, &b));
}

test "cosine: 384-wide stress" {
    var a: [384]f32 = undefined;
    var b: [384]f32 = undefined;
    var prng = std.Random.DefaultPrng.init(0x1234);
    const rnd = prng.random();
    for (&a, &b) |*x, *y| {
        x.* = rnd.float(f32) * 2 - 1;
        y.* = rnd.float(f32) * 2 - 1;
    }
    const s = cosineSimilarity(&a, &b);
    try testing.expect(std.math.isFinite(s));
    try testing.expect(s >= -1.0001 and s <= 1.0001);
}

test "cosineI8: identical quanta yield ~1, opposite ~-1, orthogonal ~0" {
    var a = [_]i8{ 100, 50, -25 };
    try testing.expectApproxEqAbs(@as(f32, 1.0), cosineSimilarityI8(&a, &a), 1e-5);

    var p = [_]i8{ 100, 100 };
    var q = [_]i8{ -100, -100 };
    try testing.expectApproxEqAbs(@as(f32, -1.0), cosineSimilarityI8(&p, &q), 1e-5);

    var x = [_]i8{ 127, 0 };
    var y = [_]i8{ 0, 127 };
    try testing.expectApproxEqAbs(@as(f32, 0.0), cosineSimilarityI8(&x, &y), 1e-5);
}

test "cosineI8: zero vector yields 0, stays in range" {
    var z = [_]i8{ 0, 0, 0 };
    var u = [_]i8{ 1, 2, 3 };
    try testing.expectEqual(@as(f32, 0), cosineSimilarityI8(&z, &u));
    const s = cosineSimilarityI8(&u, &u);
    try testing.expect(s >= -1 and s <= 1);
}

test "cosineI8: tracks f32 cosine on the same direction" {
    // Quantizing a vector and its scaled-down copy should still read as parallel.
    var a = [_]i8{ 120, -60, 30, -90 };
    var b = [_]i8{ 40, -20, 10, -30 }; // a/3, same direction
    try testing.expectApproxEqAbs(@as(f32, 1.0), cosineSimilarityI8(&a, &b), 1e-3);
}

test "hamming: identical=0, all-different=bit count" {
    const a = [_]u8{ 0b1010_1010, 0b1111_0000 };
    try testing.expectEqual(@as(u32, 0), hammingDistance(&a, &a));

    const x = [_]u8{0b0000_0000};
    const y = [_]u8{0b1111_1111};
    try testing.expectEqual(@as(u32, 8), hammingDistance(&x, &y));
}

test "hamming: u64 lane path + byte tail agree with scalar" {
    var prng = std.Random.DefaultPrng.init(0x77AA);
    const rnd = prng.random();
    var a: [21]u8 = undefined; // 2 lanes + 5-byte tail
    var b: [21]u8 = undefined;
    for (&a, &b) |*x, *y| {
        x.* = rnd.int(u8);
        y.* = rnd.int(u8);
    }
    var scalar: u32 = 0;
    for (a, b) |xa, xb| scalar += @popCount(xa ^ xb);
    try testing.expectEqual(scalar, hammingDistance(&a, &b));
}

test "euclidean: identity is zero" {
    var a = [_]f32{ 1, 2, 3, 4 };
    try testing.expectApproxEqAbs(@as(f32, 0), euclideanDistance(&a, &a), 1e-6);
}

test "euclidean: 384-wide stress" {
    var a: [384]f32 = undefined;
    var b: [384]f32 = undefined;
    var prng = std.Random.DefaultPrng.init(0xE5);
    const rnd = prng.random();
    for (&a, &b) |*x, *y| {
        x.* = rnd.float(f32) * 10;
        y.* = rnd.float(f32) * 10;
    }
    const d = euclideanDistance(&a, &b);
    try testing.expect(std.math.isFinite(d));
    try testing.expect(d >= 0);
}

test "euclidean: non-384 lengths" {
    // 11 elements — any stride-related edge cases.
    {
        var a: [11]f32 = undefined;
        var b: [11]f32 = undefined;
        for (&a, &b, 0..) |*x, *y, i| {
            x.* = @floatFromInt(i + 1);
            y.* = @floatFromInt((i % 3) + 1);
        }
        try testing.expect(std.math.isFinite(euclideanDistance(&a, &b)));
    }
    // 1 element
    {
        var a: [1]f32 = [_]f32{5};
        var b: [1]f32 = [_]f32{2};
        try testing.expectApproxEqAbs(@as(f32, 3), euclideanDistance(&a, &b), 1e-6);
    }
    // No elements
    {
        const a: [0]f32 = .{};
        const b: [0]f32 = .{};
        try testing.expectApproxEqAbs(@as(f32, 0), euclideanDistance(&a, &b), 1e-6);
    }
}

test "euclidean: zero vector vs unit" {
    var z = [_]f32{ 0, 0, 0 };
    var u = [_]f32{ 1, 0, 0 };
    try testing.expectApproxEqAbs(@as(f32, 1), euclideanDistance(&z, &u), 1e-6);
}

test "cosine: non-384 lengths" {
    // 11 elements
    {
        var a: [11]f32 = undefined;
        var b: [11]f32 = undefined;
        for (&a, &b, 0..) |*x, *y, i| {
            x.* = @floatFromInt(i + 1);
            y.* = @floatFromInt((i % 3) + 1);
        }
        const s = cosineSimilarity(&a, &b);
        try testing.expect(std.math.isFinite(s));
        try testing.expect(s >= -1.0001 and s <= 1.0001);
    }
    // 1 element
    {
        var a = [_]f32{3};
        var b = [_]f32{3};
        try testing.expectApproxEqAbs(@as(f32, 1), cosineSimilarity(&a, &b), 1e-6);
    }
    // No elements — degenerate but must not panic.
    {
        const a: [0]f32 = .{};
        const b: [0]f32 = .{};
        try testing.expectEqual(@as(f32, 0), cosineSimilarity(&a, &b));
    }
}

test "rrf: overlap accumulates and outranks singletons" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = [_][]const u8{ "x", "y", "z" };
    const b = [_][]const u8{ "y", "w" };
    const lists = [_][]const []const u8{ &a, &b };
    const fused = try reciprocalRankFusion(arena.allocator(), &lists, default_rrf_k);

    // "y" appears in both lists, so it must rank first.
    try testing.expectEqualStrings("y", fused[0].id);
    try testing.expectEqual(@as(usize, 4), fused.len); // x,y,z,w distinct
    // scores are sorted descending
    for (1..fused.len) |i| try testing.expect(fused[i - 1].score >= fused[i].score);
}

test "rrf: empty lists yield empty result" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lists = [_][]const []const u8{};
    const fused = try reciprocalRankFusion(arena.allocator(), &lists, default_rrf_k);
    try testing.expectEqual(@as(usize, 0), fused.len);
}

test "mmr: lambda=1 reduces to relevance order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const e0 = [_]f32{ 1, 0 };
    const e1 = [_]f32{ 0, 1 };
    const e2 = [_]f32{ 1, 1 };
    const embs = [_][]const f32{ &e0, &e1, &e2 };
    const rel = [_]f32{ 0.2, 0.9, 0.5 };
    const sel = try mmrSelect(arena.allocator(), &embs, &rel, 1.0, 3);
    try testing.expectEqual(@as(usize, 1), sel[0]); // highest relevance first
    try testing.expectEqual(@as(usize, 2), sel[1]);
    try testing.expectEqual(@as(usize, 0), sel[2]);
}

test "mmr: lambda=0 avoids near-duplicates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // e0 and e1 are identical; a diversity-only ranker must not pick both early.
    const e0 = [_]f32{ 1, 0 };
    const e1 = [_]f32{ 1, 0 };
    const e2 = [_]f32{ 0, 1 };
    const embs = [_][]const f32{ &e0, &e1, &e2 };
    const rel = [_]f32{ 0.9, 0.9, 0.1 };
    const sel = try mmrSelect(arena.allocator(), &embs, &rel, 0.0, 2);
    // Second pick should be the orthogonal e2, not the duplicate of the first.
    try testing.expectEqual(@as(usize, 2), sel[1]);
}

test "mmr: top_k clamps to candidate count" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const e0 = [_]f32{ 1, 0 };
    const embs = [_][]const f32{&e0};
    const rel = [_]f32{1.0};
    const sel = try mmrSelect(arena.allocator(), &embs, &rel, 0.5, 10);
    try testing.expectEqual(@as(usize, 1), sel.len);
}

// ---- fuzzing --------------------------------------------------------------

test "fuzz: cosine stays finite and within [-1,1] on random finite vectors" {
    var prng = std.Random.DefaultPrng.init(0xC05);
    const rnd = prng.random();
    var a: [40]f32 = undefined;
    var b: [40]f32 = undefined;

    for (0..500) |_| {
        const n = rnd.intRangeAtMost(usize, 0, a.len);
        for (a[0..n], b[0..n]) |*x, *y| {
            x.* = (rnd.float(f32) * 2 - 1) * 1000;
            y.* = (rnd.float(f32) * 2 - 1) * 1000;
        }
        const s = cosineSimilarity(a[0..n], b[0..n]);
        try testing.expect(std.math.isFinite(s));
        try testing.expect(s >= -1.0001 and s <= 1.0001);
    }
}

test "fuzz: cosine never panics on raw random bits (NaN/inf inputs)" {
    var prng = std.Random.DefaultPrng.init(0xBE11);
    const rnd = prng.random();
    var a: [16]f32 = undefined;
    var b: [16]f32 = undefined;

    for (0..500) |_| {
        for (&a, &b) |*x, *y| {
            x.* = @bitCast(rnd.int(u32));
            y.* = @bitCast(rnd.int(u32));
        }
        const s = cosineSimilarity(&a, &b);
        try testing.expect(std.math.isFinite(s)); // guard collapses NaN/inf to 0
    }
}

test "fuzz: rrf / mmr never panic on random inputs" {
    var prng = std.Random.DefaultPrng.init(0x4F5E);
    const rnd = prng.random();

    for (0..300) |_| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        // Random ranked id lists drawn from a tiny id pool to force overlap.
        const ids = [_][]const u8{ "a", "b", "c", "d", "e" };
        var l0: std.ArrayList([]const u8) = .empty;
        var l1: std.ArrayList([]const u8) = .empty;
        for (0..rnd.intRangeAtMost(usize, 0, 5)) |_| try l0.append(a, ids[rnd.intRangeLessThan(usize, 0, ids.len)]);
        for (0..rnd.intRangeAtMost(usize, 0, 5)) |_| try l1.append(a, ids[rnd.intRangeLessThan(usize, 0, ids.len)]);
        const lists = [_][]const []const u8{ l0.items, l1.items };
        _ = try reciprocalRankFusion(a, &lists, default_rrf_k);

        // Random candidate embeddings + relevances for MMR.
        const n = rnd.intRangeAtMost(usize, 0, 12);
        const embs = try a.alloc([]const f32, n);
        const rel = try a.alloc(f32, n);
        for (0..n) |i| {
            const v = try a.alloc(f32, 8);
            for (v) |*x| x.* = rnd.float(f32) * 2 - 1;
            embs[i] = v;
            rel[i] = rnd.float(f32);
        }
        _ = try mmrSelect(a, embs, rel, rnd.float(f32), rnd.intRangeAtMost(usize, 0, 12));
    }
}
