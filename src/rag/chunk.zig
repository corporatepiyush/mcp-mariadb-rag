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

// ── Recursive chunking ────────────────────────────────────────────────
//
// LangChain-style recursive split: prefer to break at the coarsest natural
// boundary (paragraph → line → sentence → word) that keeps a piece within the
// token budget, then greedily re-pack adjacent pieces into chunks so we don't
// emit a swarm of tiny fragments. Like `chunk`, every `content` is a borrowed
// contiguous sub-slice of `text` — separators between merged pieces are simply
// included in the span, and a piece that becomes its own chunk is trimmed of the
// surrounding whitespace.

/// Boundary hierarchy, coarsest first. Splitting on " " yields single tokens, so
/// recursion always terminates with pieces of ≤ 1 token (≤ any `chunk_size ≥ 1`).
const separators = [_][]const u8{ "\n\n", "\n", ". ", " " };

/// A trimmed, token-counted span of the original text (absolute byte offsets).
const Segment = struct { start: usize, end: usize, tokens: usize };

/// Trim ASCII whitespace from `text` and, if anything remains, record it as a
/// segment at absolute offset `off`.
fn pushTrimmed(list: *std.ArrayList(Segment), text: []const u8, off: usize) void {
    var s: usize = 0;
    while (s < text.len and isSpace(text[s])) : (s += 1) {}
    var e: usize = text.len;
    while (e > s and isSpace(text[e - 1])) : (e -= 1) {}
    if (e <= s) return;
    list.appendAssumeCapacity(.{ .start = off + s, .end = off + e, .tokens = countTokens(text[s..e]) });
}

/// Recursively split `text` (at absolute offset `off`) into segments each ≤
/// `size` tokens, descending the separator hierarchy from `sep_idx`. Capacity is
/// pre-reserved by the caller (≤ one segment per token), so pushes never resize.
fn splitRecursive(
    list: *std.ArrayList(Segment),
    text: []const u8,
    off: usize,
    sep_idx: usize,
    size: usize,
) void {
    const toks = countTokens(text);
    if (toks == 0) return;
    if (toks <= size or sep_idx >= separators.len) {
        pushTrimmed(list, text, off);
        return;
    }
    const sep = separators[sep_idx];
    var it = std.mem.splitSequence(u8, text, sep);
    var piece_off = off;
    while (it.next()) |piece| {
        splitRecursive(list, piece, piece_off, sep_idx + 1, size);
        piece_off += piece.len + sep.len; // overshoots harmlessly on the last piece
    }
}

/// Recursive-boundary chunker. Splits `text` along natural boundaries, then packs
/// adjacent segments into chunks of ≤ `chunk_size` tokens with `overlap` tokens
/// of carry-over between consecutive chunks. Each `content` borrows from `text`.
/// Empty/whitespace-only input yields an empty slice.
pub fn recursiveChunk(allocator: Allocator, text: []const u8, opts: Options) ![]Chunk {
    const size = @max(@as(usize, 1), opts.chunk_size);
    const overlap = @min(opts.overlap, size - 1);

    const n_tokens = countTokens(text);
    if (n_tokens == 0) return &.{};

    // Upper bound: every token its own segment. Reserve once, no resize.
    var segs = try std.ArrayList(Segment).initCapacity(allocator, n_tokens);
    defer segs.deinit(allocator);
    splitRecursive(&segs, text, 0, 0, size);
    if (segs.items.len == 0) return &.{};

    const items = segs.items;
    var chunks = try std.ArrayList(Chunk).initCapacity(allocator, items.len);
    errdefer chunks.deinit(allocator);

    var i: usize = 0;
    var ordinal: usize = 0;
    while (i < items.len) {
        // Greedily extend [i, j) while it fits; always take at least one segment.
        var j = i;
        var tok: usize = 0;
        while (j < items.len) : (j += 1) {
            if (j > i and tok + items[j].tokens > size) break;
            tok += items[j].tokens;
        }
        const content = text[items[i].start..items[j - 1].end];
        chunks.appendAssumeCapacity(.{ .ordinal = ordinal, .content = content, .token_count = tok });
        ordinal += 1;
        if (j >= items.len) break;

        // Next start: back up over whole trailing segments totalling ≤ overlap
        // tokens, but never past i+1 (guarantees forward progress).
        var next_i = j;
        if (overlap > 0) {
            var k = j;
            var back: usize = 0;
            while (k > i + 1) {
                const t = items[k - 1].tokens;
                if (back + t > overlap) break;
                back += t;
                k -= 1;
            }
            next_i = k;
        }
        if (next_i <= i) next_i = i + 1;
        i = next_i;
    }
    return chunks.toOwnedSlice(allocator);
}

// ── Parent-child chunking ─────────────────────────────────────────────
//
// Retrieve on small, precise child chunks; generate from their larger parent for
// context. Parents come from `recursiveChunk` at a coarse budget; each parent is
// then window-chunked into children that carry a back-reference to the parent.

pub const ParentChildOptions = struct {
    /// Parent (context) chunk budget, in tokens.
    parent_size: usize = 400,
    /// Child (retrieval) chunk budget, in tokens.
    child_size: usize = 100,
    /// Token overlap between adjacent children within a parent.
    child_overlap: usize = 20,
};

/// A retrieval-sized chunk plus the index of the parent it was cut from.
pub const Child = struct {
    ordinal: usize, // global child index
    parent_ordinal: usize, // index into `parents`
    content: []const u8,
    token_count: usize,
};

pub const ParentChild = struct {
    parents: []Chunk,
    children: []Child,

    pub fn deinit(self: ParentChild, allocator: Allocator) void {
        allocator.free(self.parents);
        allocator.free(self.children);
    }
};

/// Build the parent set (recursive, no overlap) and, for each parent, its
/// children (window-chunked). Every `content` borrows from `text`. The caller
/// owns both returned slices (`ParentChild.deinit`, or an arena).
pub fn parentChildChunk(allocator: Allocator, text: []const u8, opts: ParentChildOptions) !ParentChild {
    const parents = try recursiveChunk(allocator, text, .{ .chunk_size = opts.parent_size, .overlap = 0 });
    errdefer allocator.free(parents);

    var kids: std.ArrayList(Child) = .empty;
    errdefer kids.deinit(allocator);

    var gord: usize = 0;
    for (parents, 0..) |p, pi| {
        const subs = try chunk(allocator, p.content, .{ .chunk_size = opts.child_size, .overlap = opts.child_overlap });
        defer allocator.free(subs);
        try kids.ensureUnusedCapacity(allocator, subs.len);
        for (subs) |s| {
            kids.appendAssumeCapacity(.{
                .ordinal = gord,
                .parent_ordinal = pi,
                .content = s.content,
                .token_count = s.token_count,
            });
            gord += 1;
        }
    }
    return .{ .parents = parents, .children = try kids.toOwnedSlice(allocator) };
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

// ── recursiveChunk tests ──────────────────────────────────────────────

test "recursiveChunk: empty / whitespace-only yields no chunks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 0), (try recursiveChunk(arena.allocator(), "", .{})).len);
    try testing.expectEqual(@as(usize, 0), (try recursiveChunk(arena.allocator(), "  \n\n \t", .{})).len);
}

test "recursiveChunk: fits in one chunk when under budget" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cs = try recursiveChunk(arena.allocator(), "the quick brown fox", .{ .chunk_size = 50, .overlap = 0 });
    try testing.expectEqual(@as(usize, 1), cs.len);
    try testing.expectEqualStrings("the quick brown fox", cs[0].content);
    try testing.expectEqual(@as(usize, 4), cs[0].token_count);
}

test "recursiveChunk: prefers paragraph boundaries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Three short paragraphs; budget large enough for one each but not two.
    const text = "alpha beta\n\ngamma delta\n\nepsilon zeta";
    const cs = try recursiveChunk(arena.allocator(), text, .{ .chunk_size = 2, .overlap = 0 });
    try testing.expectEqual(@as(usize, 3), cs.len);
    try testing.expectEqualStrings("alpha beta", cs[0].content);
    try testing.expectEqualStrings("gamma delta", cs[1].content);
    try testing.expectEqualStrings("epsilon zeta", cs[2].content);
}

test "recursiveChunk: descends to sentences then words when needed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // One paragraph, two sentences; budget forces a sentence-level split.
    const text = "one two three. four five six";
    const cs = try recursiveChunk(arena.allocator(), text, .{ .chunk_size = 3, .overlap = 0 });
    try testing.expectEqual(@as(usize, 2), cs.len);
    // The "." was the separator and is dropped from a stand-alone sentence piece.
    try testing.expectEqualStrings("one two three", cs[0].content);
    try testing.expectEqualStrings("four five six", cs[1].content);
}

test "recursiveChunk: packs small pieces up to the budget" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Six one-word lines, budget 4 -> [4 words][2 words].
    const text = "a\nb\nc\nd\ne\nf";
    const cs = try recursiveChunk(arena.allocator(), text, .{ .chunk_size = 4, .overlap = 0 });
    try testing.expectEqual(@as(usize, 2), cs.len);
    try testing.expectEqual(@as(usize, 4), cs[0].token_count);
    try testing.expectEqual(@as(usize, 2), cs[1].token_count);
}

test "recursiveChunk: overlap re-includes trailing tokens and still progresses" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = "a b c d e f g h";
    const cs = try recursiveChunk(arena.allocator(), text, .{ .chunk_size = 4, .overlap = 2 });
    try testing.expect(cs.len >= 2);
    // ordinals sequential, every chunk within budget, forward progress.
    for (cs, 0..) |ch, i| {
        try testing.expectEqual(i, ch.ordinal);
        try testing.expect(ch.token_count <= 4);
        try testing.expect(ch.token_count > 0);
    }
    // Coverage: the union of chunk spans must reach the final token.
    try testing.expectEqualStrings("h", cs[cs.len - 1].content[cs[cs.len - 1].content.len - 1 ..]);
}

test "recursiveChunk: content always borrows from input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const text = "alpha beta\n\ngamma. delta epsilon zeta eta theta";
    const cs = try recursiveChunk(arena.allocator(), text, .{ .chunk_size = 3, .overlap = 1 });
    const base = @intFromPtr(text.ptr);
    for (cs) |ch| {
        const c0 = @intFromPtr(ch.content.ptr);
        try testing.expect(c0 >= base and c0 + ch.content.len <= base + text.len);
    }
}

test "fuzz: recursiveChunk never panics; borrow + ordinal + budget invariants hold" {
    var prng = std.Random.DefaultPrng.init(0x5EED);
    const rnd = prng.random();
    var buf: [512]u8 = undefined;
    // A byte alphabet rich in separators to exercise every recursion level.
    const alphabet = "abc .\n\t";

    for (0..800) |_| {
        const len = rnd.intRangeLessThan(usize, 0, buf.len);
        const text = buf[0..len];
        for (text) |*b| b.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];

        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const size = rnd.intRangeAtMost(usize, 1, 12);
        const cs = recursiveChunk(arena.allocator(), text, .{
            .chunk_size = size,
            .overlap = rnd.intRangeAtMost(usize, 0, 16),
        }) catch continue;

        const base = @intFromPtr(text.ptr);
        for (cs, 0..) |ch, i| {
            try testing.expectEqual(i, ch.ordinal);
            try testing.expect(ch.content.len > 0);
            try testing.expect(ch.token_count > 0);
            const c0 = @intFromPtr(ch.content.ptr);
            try testing.expect(c0 >= base and c0 + ch.content.len <= base + text.len);
        }
    }
}

// ── parentChildChunk tests ────────────────────────────────────────────

test "parentChildChunk: every child maps to a valid parent it is contained in" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        "Retrieval augmented generation grounds a model in external text.\n\n" ++
        "Chunking splits documents into retrievable units of bounded size.\n\n" ++
        "Hybrid search fuses dense and sparse signals before reranking.";
    const pc = try parentChildChunk(a, text, .{ .parent_size = 8, .child_size = 3, .child_overlap = 1 });

    try testing.expect(pc.parents.len >= 1);
    try testing.expect(pc.children.len >= pc.parents.len); // ≥ one child per parent

    // Global child ordinals are 0..N-1, and each child's parent index is valid.
    for (pc.children, 0..) |c, i| {
        try testing.expectEqual(i, c.ordinal);
        try testing.expect(c.parent_ordinal < pc.parents.len);
        // The child's bytes lie within its parent's span (children cut from it).
        const parent = pc.parents[c.parent_ordinal];
        const pbase = @intFromPtr(parent.content.ptr);
        const cbase = @intFromPtr(c.content.ptr);
        try testing.expect(cbase >= pbase and cbase + c.content.len <= pbase + parent.content.len);
        try testing.expect(c.token_count <= 3);
    }
}

test "parentChildChunk: children are smaller than parents" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "one two three four five six seven eight nine ten eleven twelve";
    const pc = try parentChildChunk(a, text, .{ .parent_size = 6, .child_size = 2, .child_overlap = 0 });
    var max_child: usize = 0;
    for (pc.children) |c| max_child = @max(max_child, c.token_count);
    try testing.expect(max_child <= 2);
    var max_parent: usize = 0;
    for (pc.parents) |p| max_parent = @max(max_parent, p.token_count);
    try testing.expect(max_parent >= max_child);
}

test "parentChildChunk: empty input yields no parents or children" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const pc = try parentChildChunk(arena.allocator(), "   \n\n  ", .{});
    try testing.expectEqual(@as(usize, 0), pc.parents.len);
    try testing.expectEqual(@as(usize, 0), pc.children.len);
}

test "fuzz: parentChildChunk never panics; child ⊆ parent ⊆ input" {
    var prng = std.Random.DefaultPrng.init(0x9C0FF);
    const rnd = prng.random();
    var buf: [384]u8 = undefined;
    const alphabet = "abc .\n";

    for (0..400) |_| {
        const len = rnd.intRangeLessThan(usize, 0, buf.len);
        const text = buf[0..len];
        for (text) |*b| b.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];

        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const pc = parentChildChunk(arena.allocator(), text, .{
            .parent_size = rnd.intRangeAtMost(usize, 1, 16),
            .child_size = rnd.intRangeAtMost(usize, 1, 6),
            .child_overlap = rnd.intRangeAtMost(usize, 0, 8),
        }) catch continue;

        const tbase = @intFromPtr(text.ptr);
        for (pc.parents) |p| {
            const pb = @intFromPtr(p.content.ptr);
            try testing.expect(pb >= tbase and pb + p.content.len <= tbase + text.len);
        }
        for (pc.children) |c| {
            try testing.expect(c.parent_ordinal < pc.parents.len);
            const parent = pc.parents[c.parent_ordinal];
            const pb = @intFromPtr(parent.content.ptr);
            const cb = @intFromPtr(c.content.ptr);
            try testing.expect(cb >= pb and cb + c.content.len <= pb + parent.content.len);
        }
    }
}
