//! Tests for src/embed/quant.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/embed/quant.zig");

const Scheme = srcmod.Scheme;
const decodeAlloc = srcmod.decodeAlloc;
const dimsOf = srcmod.dimsOf;
const encode = srcmod.encode;
const encodeAlloc = srcmod.encodeAlloc;
const encodedLen = srcmod.encodedLen;
const header_len = srcmod.header_len;
const int8View = srcmod.int8View;
const schemeOf = srcmod.schemeOf;
const writeHeader = srcmod.writeHeader;

// ── Tests ─────────────────────────────────────────────────────────────


test "Scheme.parse / name round-trip" {
    try testing.expectEqual(Scheme.f32, Scheme.parse(null));
    try testing.expectEqual(Scheme.f32, Scheme.parse("nonsense"));
    try testing.expectEqual(Scheme.f16, Scheme.parse("F16"));
    try testing.expectEqual(Scheme.int8, Scheme.parse("int8"));
    try testing.expectEqual(Scheme.binary, Scheme.parse("BINARY"));
    try testing.expectEqualStrings("int8", Scheme.int8.name());
}

test "encodedLen matches the per-scheme byte budget at D=384" {
    try testing.expectEqual(@as(usize, 5 + 1536), encodedLen(.f32, 384));
    try testing.expectEqual(@as(usize, 5 + 768), encodedLen(.f16, 384));
    try testing.expectEqual(@as(usize, 5 + 4 + 384), encodedLen(.int8, 384));
    try testing.expectEqual(@as(usize, 5 + 48), encodedLen(.binary, 384));
}

test "f32 round-trips exactly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = [_]f32{ 1, -2.5, 3.25, 0, 100.5 };
    const blob = try encodeAlloc(a, .f32, &v);
    try testing.expectEqual(Scheme.f32, try schemeOf(blob));
    try testing.expectEqual(@as(usize, 5), dimsOf(blob) catch 0);
    const back = try decodeAlloc(a, blob);
    try testing.expectEqualSlices(f32, &v, back);
}

test "f16 round-trips within f16 precision" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = [_]f32{ 1, -2.5, 0.333, 0, 42 };
    const blob = try encodeAlloc(a, .f16, &v);
    const back = try decodeAlloc(a, blob);
    for (v, back) |orig, got| try testing.expectApproxEqAbs(orig, got, 0.01);
}

test "int8 symmetric scale preserves direction within ~1%" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = [_]f32{ 0.1, -0.9, 0.5, 0.02, -0.3 };
    const blob = try encodeAlloc(a, .int8, &v);
    const view = try int8View(blob);
    try testing.expect(view.scale > 0);
    const back = try decodeAlloc(a, blob);
    // maxabs is 0.9 -> scale 0.9/127 ≈ 0.00709; error bound is half a step.
    for (v, back) |orig, got| try testing.expectApproxEqAbs(orig, got, view.scale);
}

test "int8 all-zero vector uses a safe unit scale" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = [_]f32{ 0, 0, 0 };
    const blob = try encodeAlloc(a, .int8, &v);
    const back = try decodeAlloc(a, blob);
    for (back) |g| try testing.expectEqual(@as(f32, 0), g);
}

test "binary keeps only sign, packs 8 bits/byte" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = [_]f32{ 1, -1, 0.5, -0.5, 0, -3, 7, -7, 2 }; // 9 dims -> 2 bytes
    const blob = try encodeAlloc(a, .binary, &v);
    try testing.expectEqual(@as(usize, 5 + 2), blob.len);
    const back = try decodeAlloc(a, blob);
    const want = [_]f32{ 1, -1, 1, -1, 1, -1, 1, -1, 1 }; // 0 maps to +1 (>=0)
    try testing.expectEqualSlices(f32, &want, back);
}

test "decode rejects truncated and unknown blobs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.InvalidBlob, schemeOf(&[_]u8{ 0, 1 }));
    // Valid header claiming 384 dims but no payload.
    var hdr: [header_len]u8 = undefined;
    writeHeader(&hdr, .f32, 384);
    try testing.expectError(error.InvalidBlob, decodeAlloc(a, &hdr));
    // Unknown scheme tag.
    var bad = [_]u8{ 99, 1, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectError(error.UnknownScheme, schemeOf(&bad));
}

test "fuzz: encode/decode never panics, decode length always equals dims" {
    var prng = std.Random.DefaultPrng.init(0x9A17);
    const rnd = prng.random();
    const schemes = [_]Scheme{ .f32, .f16, .int8, .binary };
    var buf: [64]f32 = undefined;

    for (0..2000) |_| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const n = rnd.intRangeAtMost(usize, 0, buf.len);
        for (buf[0..n]) |*x| x.* = @bitCast(rnd.int(u32)); // includes NaN/inf
        const scheme = schemes[rnd.intRangeLessThan(usize, 0, schemes.len)];
        const blob = try encodeAlloc(a, scheme, buf[0..n]);
        const back = try decodeAlloc(a, blob);
        try testing.expectEqual(n, back.len);
    }
}
