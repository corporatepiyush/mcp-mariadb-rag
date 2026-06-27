//! Tests for src/doc/pool.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/doc/pool.zig");

const Pool = srcmod.Pool;
const Scratch = srcmod.Scratch;

// ── Tests ─────────────────────────────────────────────────────────────

test "Scratch retains capacity across resets" {
    var s = Scratch.init(testing.allocator);
    defer s.deinit();
    for (0..100) |_| {
        const buf = try s.allocator().alloc(u8, 1024);
        @memset(buf, 0xAB);
        s.reset();
    }
}

test "Pool acquire/release reuses storage" {
    const P = Pool(u64);
    var p = P.init(testing.allocator);
    defer p.deinit();

    const a = try p.acquire();
    a.* = 7;
    const ai = p.index(a);
    const b = try p.acquire();
    b.* = 9;
    try testing.expectEqual(@as(u32, 2), p.live);

    p.release(a);
    try testing.expectEqual(@as(u32, 1), p.live);
    // next acquire pops the just-freed node (LIFO free-list)
    const c = try p.acquire();
    try testing.expectEqual(ai, p.index(c));
    try testing.expectEqual(@as(u32, 2), p.live);
}

test "Pool handles survive growth; get(index) is stable" {
    const P = Pool(u32);
    var p = P.init(testing.allocator);
    defer p.deinit();

    var handles: [200]u32 = undefined;
    for (&handles, 0..) |*h, i| {
        const ptr = try p.acquire();
        ptr.* = @intCast(i);
        h.* = p.index(ptr);
    }
    for (handles, 0..) |h, i| {
        try testing.expectEqual(@as(u32, @intCast(i)), p.get(h).*);
    }
}

test "Pool ensureCapacity avoids realloc churn" {
    const P = Pool(u8);
    var p = P.init(testing.allocator);
    defer p.deinit();
    try p.ensureCapacity(1000);
    const cap = p.slab.len;
    for (0..1000) |_| _ = try p.acquire();
    try testing.expectEqual(cap, p.slab.len); // no growth happened
}
