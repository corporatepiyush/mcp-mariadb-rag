//! Retrieval fusion and re-ranking — the query-side compute kernel.
//!
//! Three pure building blocks, all CPU-bound and DB-free so they are unit- and
//! fuzz-testable in isolation:
//!   * `cosineSimilarity` — SIMD dot/norm accumulation with a scalar reference
//!     (`*Scalar`) that the tests cross-check, satisfying Agent.md's rule that
//!     every SIMD kernel ships a verified scalar fallback.
//!   * `reciprocalRankFusion` — rank-based score fusion of N ranked id lists
//!     (the standard hybrid lexical+semantic combiner; order-only, score-free).
//!   * `mmrSelect` — Maximal Marginal Relevance greedy re-rank for diversity,
//!     with an incrementally-maintained max-similarity cache (O(k·n·d)).

const std = @import("std");

const Allocator = std.mem.Allocator;

// ── Cosine similarity ─────────────────────────────────────────────────

const lanes = 8;
const Vf = @Vector(lanes, f32);

const Acc = struct { dot: f32, na: f32, nb: f32 };

/// Scalar reference accumulation. Exists both as the small-input path and as
/// the oracle the SIMD path is tested against.
fn accScalar(a: []const f32, b: []const f32, n: usize) Acc {
    var dot: f32 = 0;
    var na: f32 = 0;
    var nb: f32 = 0;
    for (0..n) |i| {
        dot += a[i] * b[i];
        na += a[i] * a[i];
        nb += b[i] * b[i];
    }
    return .{ .dot = dot, .na = na, .nb = nb };
}

/// 8-wide SIMD accumulation with a scalar epilogue for the tail.
fn accSimd(a: []const f32, b: []const f32, n: usize) Acc {
    var vd: Vf = @splat(0);
    var va: Vf = @splat(0);
    var vb: Vf = @splat(0);
    var i: usize = 0;
    while (i + lanes <= n) : (i += lanes) {
        const x: Vf = a[i..][0..lanes].*;
        const y: Vf = b[i..][0..lanes].*;
        vd += x * y;
        va += x * x;
        vb += y * y;
    }
    var dot: f32 = @reduce(.Add, vd);
    var na: f32 = @reduce(.Add, va);
    var nb: f32 = @reduce(.Add, vb);
    while (i < n) : (i += 1) {
        dot += a[i] * b[i];
        na += a[i] * a[i];
        nb += b[i] * b[i];
    }
    return .{ .dot = dot, .na = na, .nb = nb };
}

fn finish(acc: Acc) f32 {
    const denom = @sqrt(acc.na) * @sqrt(acc.nb);
    if (denom == 0) return 0; // a zero vector has no direction
    const sim = acc.dot / denom;
    // Degenerate inputs (inf/NaN components) can produce a non-finite ratio;
    // collapse those to 0 so downstream ranking never sees NaN.
    return if (std.math.isFinite(sim)) sim else 0;
}

/// Cosine similarity in [-1, 1]. Compares over `min(a.len, b.len)` components;
/// a zero-magnitude vector yields 0. Uses the SIMD path.
pub fn cosineSimilarity(a: []const f32, b: []const f32) f32 {
    const n = @min(a.len, b.len);
    return finish(accSimd(a, b, n));
}

/// Scalar-path cosine — same contract as `cosineSimilarity`, used as the test
/// oracle and available for callers that want to avoid the vector unit.
pub fn cosineSimilarityScalar(a: []const f32, b: []const f32) f32 {
    const n = @min(a.len, b.len);
    return finish(accScalar(a, b, n));
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
    const a = [_]f32{ 1, 2, 3 };
    const b = [_]f32{ 1, 2, 3 };
    try testing.expectApproxEqAbs(@as(f32, 1.0), cosineSimilarity(&a, &b), 1e-6);

    const x = [_]f32{ 1, 0 };
    const y = [_]f32{ 0, 1 };
    try testing.expectApproxEqAbs(@as(f32, 0.0), cosineSimilarity(&x, &y), 1e-6);

    const p = [_]f32{ 1, 1 };
    const q = [_]f32{ -1, -1 };
    try testing.expectApproxEqAbs(@as(f32, -1.0), cosineSimilarity(&p, &q), 1e-6);
}

test "cosine: zero vector yields 0" {
    const a = [_]f32{ 0, 0, 0 };
    const b = [_]f32{ 1, 2, 3 };
    try testing.expectEqual(@as(f32, 0), cosineSimilarity(&a, &b));
}

test "cosine: SIMD path matches scalar oracle on a 384-wide vector" {
    var a: [384]f32 = undefined;
    var b: [384]f32 = undefined;
    var prng = std.Random.DefaultPrng.init(0x1234);
    const rnd = prng.random();
    for (&a, &b) |*x, *y| {
        x.* = rnd.float(f32) * 2 - 1;
        y.* = rnd.float(f32) * 2 - 1;
    }
    try testing.expectApproxEqAbs(cosineSimilarityScalar(&a, &b), cosineSimilarity(&a, &b), 1e-5);
}

test "cosine: tail handling for non-multiple-of-8 lengths" {
    // 11 elements exercises one SIMD block + a 3-element scalar tail.
    var a: [11]f32 = undefined;
    var b: [11]f32 = undefined;
    for (&a, &b, 0..) |*x, *y, i| {
        x.* = @floatFromInt(i + 1);
        y.* = @floatFromInt((i % 3) + 1);
    }
    try testing.expectApproxEqAbs(cosineSimilarityScalar(&a, &b), cosineSimilarity(&a, &b), 1e-5);
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
