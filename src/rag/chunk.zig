//! Word-window text chunker — the ingest-side of the RAG engine.
//!
//! Splits a document into overlapping windows of approximately `chunk_size`
//! whitespace-delimited tokens, with `overlap` tokens shared between adjacent
//! windows so a sentence straddling a boundary still appears whole in one chunk.
//!
//! Mechanical-sympathy notes (per Agent.md):
//!   * Zero-copy: every `Chunk.content` is a borrowed sub-slice of the input
//!     text — no per-chunk string duplication. The caller's arena owns `text`.
//!   * Exact-fit, zero-resize: token offsets and the chunk array are sized from
//!     a counting pre-pass, so there is no incremental `ArrayList` growth.
//!   * Single linear scan for tokenization — stride-1, prefetch-friendly, and
//!     the whitespace test is branch-light.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// A retrievable window of the source text. `content` borrows from the input.
pub const Chunk = struct {
    ordinal: usize,
    content: []const u8,
    token_count: usize,
};

pub const Options = struct {
    /// Target tokens per chunk. Clamped to >= 1.
    chunk_size: usize = 200,
    /// Tokens shared between adjacent chunks. Clamped to <= chunk_size - 1.
    overlap: usize = 40,
};

/// True for ASCII whitespace. High bytes (UTF-8 continuation/lead) are treated
/// as non-whitespace, so multibyte words stay intact.
inline fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or
        c == '\x0b' or c == '\x0c';
}

/// Count maximal runs of non-whitespace bytes (the token count).
fn countTokens(text: []const u8) usize {
    var n: usize = 0;
    var in_tok = false;
    for (text) |c| {
        const space = isSpace(c);
        // Rising edge (space -> non-space) starts a new token.
        if (!space and !in_tok) n += 1;
        in_tok = !space;
    }
    return n;
}

/// Number of chunks a sliding window of `size`/`stride` produces over
/// `n_tokens`. Mirrors the emission loop exactly so the chunk array is sized
/// once with no slack.
fn countChunks(n_tokens: usize, size: usize, stride: usize) usize {
    if (n_tokens == 0) return 0;
    var start: usize = 0;
    var count: usize = 0;
    while (start < n_tokens) {
        count += 1;
        if (start + size >= n_tokens) break; // this window reaches the end
        start += stride;
    }
    return count;
}

/// Split `text` into overlapping token windows. Returns an owned slice of
/// `Chunk`; each `content` borrows from `text`, so `text` must outlive the
/// result. Empty/whitespace-only input yields an empty slice.
pub fn chunk(allocator: Allocator, text: []const u8, opts: Options) ![]Chunk {
    const size = @max(@as(usize, 1), opts.chunk_size);
    const overlap = @min(opts.overlap, size - 1);
    const stride = size - overlap; // >= 1 by construction

    const n_tokens = countTokens(text);
    if (n_tokens == 0) return &.{};

    // Materialize token byte spans in one pass (exact-fit arrays).
    const tok_start = try allocator.alloc(usize, n_tokens);
    defer allocator.free(tok_start);
    const tok_end = try allocator.alloc(usize, n_tokens);
    defer allocator.free(tok_end);

    {
        var ti: usize = 0;
        var in_tok = false;
        for (text, 0..) |c, i| {
            const space = isSpace(c);
            if (!space and !in_tok) {
                tok_start[ti] = i; // token begins
            } else if (space and in_tok) {
                tok_end[ti] = i; // token ends (exclusive)
                ti += 1;
            }
            in_tok = !space;
        }
        if (in_tok) {
            tok_end[ti] = text.len; // final token runs to EOF
        }
    }

    const n_chunks = countChunks(n_tokens, size, stride);
    const chunks = try allocator.alloc(Chunk, n_chunks);

    var start: usize = 0;
    var idx: usize = 0;
    while (start < n_tokens) : (idx += 1) {
        const end = @min(start + size, n_tokens); // exclusive token index
        chunks[idx] = .{
            .ordinal = idx,
            .content = text[tok_start[start]..tok_end[end - 1]],
            .token_count = end - start,
        };
        if (start + size >= n_tokens) break;
        start += stride;
    }
    return chunks;
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

test "countTokens" {
    try testing.expectEqual(@as(usize, 0), countTokens(""));
    try testing.expectEqual(@as(usize, 0), countTokens("   \t\n "));
    try testing.expectEqual(@as(usize, 1), countTokens("hello"));
    try testing.expectEqual(@as(usize, 1), countTokens("  hello  "));
    try testing.expectEqual(@as(usize, 3), countTokens("a b c"));
    try testing.expectEqual(@as(usize, 3), countTokens("  a\tb\n c  "));
}

test "chunk: empty / whitespace-only yields no chunks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 0), (try chunk(arena.allocator(), "", .{})).len);
    try testing.expectEqual(@as(usize, 0), (try chunk(arena.allocator(), "   \n\t", .{})).len);
}

test "chunk: single window when text fits" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cs = try chunk(arena.allocator(), "the quick brown fox", .{ .chunk_size = 10, .overlap = 2 });
    try testing.expectEqual(@as(usize, 1), cs.len);
    try testing.expectEqualStrings("the quick brown fox", cs[0].content);
    try testing.expectEqual(@as(usize, 4), cs[0].token_count);
    try testing.expectEqual(@as(usize, 0), cs[0].ordinal);
}

test "chunk: overlapping windows with stride" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // 6 tokens, size 3, overlap 1 -> stride 2 -> windows [0..3),[2..5),[4..6)
    const cs = try chunk(arena.allocator(), "a b c d e f", .{ .chunk_size = 3, .overlap = 1 });
    try testing.expectEqual(@as(usize, 3), cs.len);
    try testing.expectEqualStrings("a b c", cs[0].content);
    try testing.expectEqualStrings("c d e", cs[1].content);
    try testing.expectEqualStrings("e f", cs[2].content);
    try testing.expectEqual(@as(usize, 2), cs[2].token_count);
    // ordinals are sequential
    for (cs, 0..) |ch, i| try testing.expectEqual(i, ch.ordinal);
}

test "chunk: content is a borrow of the input (no copy)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = "alpha beta gamma delta";
    const cs = try chunk(arena.allocator(), text, .{ .chunk_size = 2, .overlap = 0 });
    for (cs) |ch| {
        const base = @intFromPtr(text.ptr);
        const c0 = @intFromPtr(ch.content.ptr);
        try testing.expect(c0 >= base and c0 + ch.content.len <= base + text.len);
    }
}

test "chunk: overlap clamped when >= chunk_size" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // overlap 9 with size 2 -> clamped to 1 -> stride 1
    const cs = try chunk(arena.allocator(), "a b c", .{ .chunk_size = 2, .overlap = 9 });
    try testing.expect(cs.len >= 2);
    try testing.expectEqualStrings("a b", cs[0].content);
}

test "chunk: chunk_size 0 clamped to 1" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cs = try chunk(arena.allocator(), "a b c", .{ .chunk_size = 0, .overlap = 0 });
    try testing.expectEqual(@as(usize, 3), cs.len);
    try testing.expectEqualStrings("a", cs[0].content);
}

// ---- fuzzing --------------------------------------------------------------
// The chunker consumes untrusted document bytes. Per Agent.md it must never
// panic on any input, and the borrow invariant (content ⊆ input) and ordinal
// monotonicity must hold for arbitrary bytes, sizes, and overlaps.

test "fuzz: chunk never panics and preserves borrow + ordinal invariants" {
    var prng = std.Random.DefaultPrng.init(0xC401);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;

    for (0..600) |_| {
        const len = rnd.intRangeLessThan(usize, 0, buf.len);
        const text = buf[0..len];
        for (text) |*b| b.* = rnd.int(u8); // all 256 byte values, incl. NUL/high

        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        const opts = Options{
            .chunk_size = rnd.intRangeAtMost(usize, 0, 16),
            .overlap = rnd.intRangeAtMost(usize, 0, 20),
        };
        const cs = chunk(arena.allocator(), text, opts) catch continue;

        const base = @intFromPtr(text.ptr);
        for (cs, 0..) |ch, i| {
            try testing.expectEqual(i, ch.ordinal); // sequential ordinals
            try testing.expect(ch.content.len > 0); // non-empty
            try testing.expect(ch.token_count > 0);
            const c0 = @intFromPtr(ch.content.ptr);
            try testing.expect(c0 >= base and c0 + ch.content.len <= base + text.len);
        }
    }
}
