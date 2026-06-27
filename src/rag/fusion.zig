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
