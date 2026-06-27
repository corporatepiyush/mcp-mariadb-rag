//! Tests for src/actions/rag.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/actions/rag.zig");
const Io = std.Io;

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Writer = std.Io.Writer;
const dims = srcmod.dims;
const embFromBlob = srcmod.embFromBlob;
const embeddingExact = srcmod.embeddingExact;
const getUintParam = srcmod.getUintParam;
const json = srcmod.json;
const schema = srcmod.schema;

// ── Tests (DB-free helper coverage) ───────────────────────────────────


test "embFromBlob round-trips an f32 array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const orig = [_]f32{ 1, 2.5, -3 };
    const blob = std.mem.sliceAsBytes(&orig);
    const v = try embFromBlob(arena.allocator(), blob);
    try testing.expectEqual(@as(usize, 3), v.len);
    try testing.expectEqual(@as(f32, 1), v[0]);
    try testing.expectEqual(@as(f32, 2.5), v[1]);
    try testing.expectEqual(@as(f32, -3), v[2]);
}

test "embFromBlob handles empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidBlob, embFromBlob(arena.allocator(), ""));
    try testing.expectError(error.InvalidBlob, embFromBlob(arena.allocator(), &[_]u8{ 0, 1, 2 }));
}

/// Build a Value by parsing JSON text (avoids depending on the std.json
/// map/array constructor signatures, which differ across Zig versions).
fn parseValue(a: Allocator, src: []const u8) Value {
    const parsed = std.json.parseFromSlice(Value, a, src, .{}) catch unreachable;
    return parsed.value;
}

/// A JSON array literal of `n` zeros, optionally with a leading non-number.
fn zerosArray(a: Allocator, n: usize, leading_string: bool) []const u8 {
    var aw = Writer.Allocating.init(a);
    const w = &aw.writer;
    w.writeByte('[') catch unreachable;
    for (0..n) |i| {
        if (i > 0) w.writeByte(',') catch unreachable;
        if (i == 0 and leading_string) {
            w.writeAll("\"x\"") catch unreachable;
        } else {
            w.writeByte('0') catch unreachable;
        }
    }
    w.writeByte(']') catch unreachable;
    return aw.toOwnedSlice() catch unreachable;
}

test "embeddingExact enforces dimensionality" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectError(error.BadDim, embeddingExact(a, parseValue(a, "[1.0]")));
    try testing.expectError(error.NotNumber, embeddingExact(a, parseValue(a, zerosArray(a, dims, true))));

    const ok = try embeddingExact(a, parseValue(a, zerosArray(a, dims, false)));
    try testing.expectEqual(@as(usize, dims), ok.len);
}

test "embeddingExact honours the runtime MCP_EMBED_DIMS width" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Switch the active width to 1024 (e.g. a Voyage embedder), then restore so
    // the global doesn't leak into other tests.
    const saved = schema.embeddingDims();
    defer schema.setEmbeddingDims(saved);
    schema.setEmbeddingDims(1024);

    // The old 384-wide vector is now rejected; a 1024-wide one is accepted.
    try testing.expectError(error.BadDim, embeddingExact(a, parseValue(a, zerosArray(a, 384, false))));
    const ok = try embeddingExact(a, parseValue(a, zerosArray(a, 1024, false)));
    try testing.expectEqual(@as(usize, 1024), ok.len);

    // setEmbeddingDims(0) is ignored — validation can't be disabled by a typo.
    schema.setEmbeddingDims(0);
    try testing.expectEqual(@as(usize, 1024), schema.embeddingDims());
}

test "getUintParam accepts number and string forms" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = parseValue(a, "{\"n\":7,\"s\":\"9\"}");
    try testing.expectEqual(@as(u64, 7), getUintParam(args, "n", 1));
    try testing.expectEqual(@as(u64, 9), getUintParam(args, "s", 1));
    try testing.expectEqual(@as(u64, 3), getUintParam(args, "missing", 3));
}

test "fuzz: embFromBlob never panics on random bytes" {
    var prng = std.Random.DefaultPrng.init(0xEEEE);
    const rnd = prng.random();
    var buf: [128]u8 = undefined;

    for (0..500) |_| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const len = rnd.intRangeLessThan(usize, 0, buf.len);
        for (buf[0..len]) |*b| b.* = rnd.int(u8);
        _ = embFromBlob(arena.allocator(), buf[0..len]) catch {};
    }
}
