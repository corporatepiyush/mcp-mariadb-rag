//! Retrieval fusion and re-ranking — the query-side compute kernel.
//!
//! Three pure building blocks, all CPU-bound and DB-free so they are unit- and
//! fuzz-testable in isolation:
//!   * `cosineSimilarity` — dot/norm accumulation in a single scalar loop with
//!     `@setFloatMode(.Optimized)` so LLVM can auto-vectorize across strides.
//!   * `reciprocalRankFusion` — rank-based score fusion of N ranked id lists
//!     (the standard hybrid lexical+semantic combiner; order-only, score-free).
//!   * `mmrSelect` — Maximal Marginal Relevance greedy re-rank for diversity,
//!     with an incrementally-maintained max-similarity cache (O(k·n·d)).

const std = @import("std");

const Allocator = std.mem.Allocator;

// ── Cosine similarity ─────────────────────────────────────────────────

/// Cosine similarity in [-1, 1]. Compares over `min(a.len, b.len)` components;
/// a zero-magnitude vector yields 0. Scalar loop with `@setFloatMode(.Optimized)`
/// so LLVM auto-vectorizes where the target CPU supports it.
pub fn cosineSimilarity(a: []const f32, b: []const f32) f32 {
    @setFloatMode(.optimized);
    const n = @min(a.len, b.len);
    var dot: f32 = 0;
    var na: f32 = 0;
    var nb: f32 = 0;
    for (0..n) |i| {
        dot += a[i] * b[i];
        na += a[i] * a[i];
        nb += b[i] * b[i];
    }
    const denom = @sqrt(na) * @sqrt(nb);
    if (denom == 0) return 0;
    const sim = dot / denom;
    return if (std.math.isFinite(sim)) sim else 0;
}

// ── Euclidean distance ────────────────────────────────────────────────

/// Euclidean (L2) distance. Compares over `min(a.len, b.len)` components.
/// Returns the square root of the sum of squared differences. Scalar loop
/// with `@setFloatMode(.Optimized)` for auto-vectorization.
pub fn euclideanDistance(a: []const f32, b: []const f32) f32 {
    @setFloatMode(.optimized);
    const n = @min(a.len, b.len);
    var sum: f32 = 0;
    for (0..n) |i| {
        const d = a[i] - b[i];
        sum += d * d;
    }
    return if (std.math.isFinite(sum)) @sqrt(sum) else std.math.inf(f32);
}

// ── Quantized distance kernels ────────────────────────────────────────
// Consumed by the int8 / binary storage schemes in `embed/quant.zig`. The
// symmetric int8 scale cancels in a cosine ratio, so these need no scale arg.

/// Cosine similarity over symmetric-int8 quanta. Accumulates the dot product and
/// both squared norms in i32 (a 384-wide vector of i8·i8 maxes out at
/// 384·127·127 ≈ 6.2 M, far inside i32), then does one float divide. Because the
/// per-vector scales are symmetric they divide out of the ratio exactly, so this
/// approximates `cosineSimilarity` of the original f32 vectors directly.
pub fn cosineSimilarityI8(a: []const i8, b: []const i8) f32 {
    const n = @min(a.len, b.len);
    var dot: i32 = 0;
    var na: i32 = 0;
    var nb: i32 = 0;
    for (0..n) |i| {
        const x: i32 = a[i];
        const y: i32 = b[i];
        dot += x * y;
        na += x * x;
        nb += y * y;
    }
    if (na == 0 or nb == 0) return 0;
    const denom = @sqrt(@as(f32, @floatFromInt(na)) * @as(f32, @floatFromInt(nb)));
    const sim = @as(f32, @floatFromInt(dot)) / denom;
    return std.math.clamp(sim, -1, 1);
}

/// Hamming distance between two packed sign-bit vectors (8 dims/byte), counting
/// differing bits via `@popCount`. Reads 8 bytes at a time as a `u64` lane
/// (≈ 32× the f32 throughput) with a byte tail. This is the cheap pre-filter in
/// the "binary + rerank" pattern; survivors are reranked with exact vectors.
pub fn hammingDistance(a: []const u8, b: []const u8) u32 {
    const n = @min(a.len, b.len);
    var dist: u32 = 0;
    var i: usize = 0;
    while (i + 8 <= n) : (i += 8) {
        const xa = std.mem.readInt(u64, a[i..][0..8], .little);
        const xb = std.mem.readInt(u64, b[i..][0..8], .little);
        dist += @popCount(xa ^ xb);
    }
    while (i < n) : (i += 1) dist += @popCount(a[i] ^ b[i]);
    return dist;
}

// ── Reciprocal Rank Fusion ────────────────────────────────────────────

pub const Fused = struct { id: []const u8, score: f32 };

/// Default RRF constant. Larger `k` flattens the contribution of top ranks,
/// reducing the dominance of any single list (Cormack et al., 2009 use 60).
pub const default_rrf_k: f32 = 60;

/// Fuse N ranked id lists (each ordered best-first) into one ranking by
/// `score = Σ 1/(k + rank)`, rank 1-based. Ids appearing in multiple lists
/// accumulate, which is the whole point of hybrid retrieval. The returned slice
/// is sorted by score descending, ties broken by id ascending for determinism.
/// Borrowed id slices are reused, not duplicated; the caller's arena owns them.
pub fn reciprocalRankFusion(
    allocator: Allocator,
    lists: []const []const []const u8,
    k: f32,
) ![]Fused {
    var scores: std.StringArrayHashMapUnmanaged(f32) = .empty;
    defer scores.deinit(allocator);

    var upper: usize = 0;
    for (lists) |list| upper += list.len;
    try scores.ensureTotalCapacity(allocator, @intCast(upper));

    for (lists) |list| {
        for (list, 0..) |id, rank| {
            const contrib = 1.0 / (k + @as(f32, @floatFromInt(rank + 1)));
            const gop = scores.getOrPutAssumeCapacity(id);
            gop.value_ptr.* = (if (gop.found_existing) gop.value_ptr.* else 0) + contrib;
        }
    }

    const out = try allocator.alloc(Fused, scores.count());
    for (scores.keys(), scores.values(), 0..) |id, score, i| {
        out[i] = .{ .id = id, .score = score };
    }
    std.sort.block(Fused, out, {}, lessByScoreDesc);
    return out;
}

fn lessByScoreDesc(_: void, a: Fused, b: Fused) bool {
    if (a.score != b.score) return a.score > b.score;
    return std.mem.lessThan(u8, a.id, b.id);
}

// ── Maximal Marginal Relevance ────────────────────────────────────────

/// Greedy MMR re-rank for diversity. At each step picks the candidate maximizing
/// `λ·relevance[c] − (1−λ)·max_{s∈selected} cosine(c, s)`. `lambda` near 1
/// favours pure relevance; near 0 favours novelty. Returns selected candidate
/// indices in pick order (length `min(top_k, n)`).
///
/// `embeddings[i]` and `relevance[i]` describe candidate i; all embeddings
/// should share a dimensionality (shorter ones compare over the common prefix).
pub fn mmrSelect(
    allocator: Allocator,
    embeddings: []const []const f32,
    relevance: []const f32,
    lambda: f32,
    top_k: usize,
) ![]usize {
    const n = embeddings.len;
    std.debug.assert(relevance.len == n);
    const want = @min(top_k, n);

    const result = try allocator.alloc(usize, want);
    if (want == 0) return result;

    const chosen = try allocator.alloc(bool, n);
    defer allocator.free(chosen);
    @memset(chosen, false);

    // max_sim[c] = max cosine of candidate c against anything already selected.
    // Maintained incrementally so each round is a single O(n·d) pass.
    const max_sim = try allocator.alloc(f32, n);
    defer allocator.free(max_sim);
    @memset(max_sim, 0);

    const lam = std.math.clamp(lambda, 0, 1);

    var count: usize = 0;
    while (count < want) : (count += 1) {
        var best_i: usize = 0;
        var best_score: f32 = -std.math.inf(f32);
        var found = false;
        for (0..n) |c| {
            if (chosen[c]) continue;
            const score = lam * relevance[c] - (1 - lam) * max_sim[c];
            if (!found or score > best_score) {
                best_score = score;
                best_i = c;
                found = true;
            }
        }

        chosen[best_i] = true;
        result[count] = best_i;

        // Fold the freshly-picked item into every remaining candidate's max_sim.
        for (0..n) |c| {
            if (chosen[c]) continue;
            const s = cosineSimilarity(embeddings[c], embeddings[best_i]);
            if (s > max_sim[c]) max_sim[c] = s;
        }
    }
    return result;
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

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
