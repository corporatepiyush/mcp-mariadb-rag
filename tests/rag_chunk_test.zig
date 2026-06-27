//! Tests for src/rag/chunk.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/rag/chunk.zig");

const Options = srcmod.Options;
const chunk = srcmod.chunk;
const countTokens = srcmod.countTokens;
const parentChildChunk = srcmod.parentChildChunk;
const recursiveChunk = srcmod.recursiveChunk;
const separators = srcmod.separators;

// ── Tests ─────────────────────────────────────────────────────────────


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
