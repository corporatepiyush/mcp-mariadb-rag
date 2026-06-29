//! Tests for src/doc/thrift.zig (Thrift compact protocol reader).

const std = @import("std");
const testing = std.testing;
const thrift = @import("../src/doc/thrift.zig");

test "thrift: unsigned LEB128 varint" {
    var r = thrift.Reader.init(&[_]u8{ 0xAC, 0x02 }); // 0x2C | (2<<7) = 300
    try testing.expectEqual(@as(u64, 300), try r.varint());
}

test "thrift: zig-zag signed" {
    {
        var r = thrift.Reader.init(&[_]u8{0x01});
        try testing.expectEqual(@as(i64, -1), try r.zigzag());
    }
    {
        var r = thrift.Reader.init(&[_]u8{0x02});
        try testing.expectEqual(@as(i64, 1), try r.zigzag());
    }
    {
        var r = thrift.Reader.init(&[_]u8{0x00});
        try testing.expectEqual(@as(i64, 0), try r.zigzag());
    }
}

test "thrift: struct with a single i32 field, then STOP" {
    // field header 0x15 = delta 1, type 5 (i32); value zigzag(7)=14=0x0E; STOP 0x00.
    var r = thrift.Reader.init(&[_]u8{ 0x15, 0x0E, 0x00 });
    const f = try r.fieldBegin();
    try testing.expect(!f.stop);
    try testing.expectEqual(thrift.CType.i32, f.ctype);
    try testing.expectEqual(@as(i16, 1), f.id);
    try testing.expectEqual(@as(i32, 7), try r.i32v());
    try testing.expect((try r.fieldBegin()).stop);
}

test "thrift: explicit field id when delta is zero" {
    // header 0x05 = delta 0, type 5; explicit zig-zag id = zigzag(9)=18=0x12.
    var r = thrift.Reader.init(&[_]u8{ 0x05, 0x12, 0x02, 0x00 });
    const f = try r.fieldBegin();
    try testing.expectEqual(@as(i16, 9), f.id);
    try testing.expectEqual(@as(i32, 1), try r.i32v()); // zigzag(1)=2
}

test "thrift: boolean fields carry value in the type nibble" {
    // delta 1 bool_true (0x11), delta 1 bool_false (0x12), STOP.
    var r = thrift.Reader.init(&[_]u8{ 0x11, 0x12, 0x00 });
    const t = try r.fieldBegin();
    try testing.expect(thrift.Reader.boolFromField(t));
    const fa = try r.fieldBegin();
    try testing.expect(!thrift.Reader.boolFromField(fa));
}

test "thrift: list header (small size) of i32" {
    // (size 2 << 4) | type 5 = 0x25; then two zig-zag i32 (5, 6).
    var r = thrift.Reader.init(&[_]u8{ 0x25, 0x0A, 0x0C });
    const h = try r.listBegin();
    try testing.expectEqual(thrift.CType.i32, h.elem);
    try testing.expectEqual(@as(u32, 2), h.size);
    try testing.expectEqual(@as(i32, 5), try r.i32v());
    try testing.expectEqual(@as(i32, 6), try r.i32v());
}

test "thrift: binary is length-prefixed and borrowed" {
    var r = thrift.Reader.init(&[_]u8{ 0x03, 'a', 'b', 'c' });
    try testing.expectEqualStrings("abc", try r.binary());
}

test "thrift: skip walks nested structs/lists without panicking" {
    // struct { 1: list<i32>[3,4]; 2: struct { 1: i32 5 } }  — skip the whole thing.
    const bytes = [_]u8{
        0x19, // field 1, type LIST(9)
        0x25, 0x06, 0x08, // list: size2 i32, values 3,4
        0x2C, // field 2, type STRUCT(12)
        0x15, 0x0A, 0x00, // inner: field1 i32 5, STOP
        0x00, // outer STOP
    };
    var r = thrift.Reader.init(&bytes);
    try r.skip(.@"struct");
    try testing.expectEqual(bytes.len, r.pos);
}

test "fuzz: thrift skip never panics on random bytes" {
    var prng = std.Random.DefaultPrng.init(0x7411);
    const rnd = prng.random();
    var buf: [64]u8 = undefined;
    for (0..3000) |_| {
        const n = rnd.intRangeLessThan(usize, 0, buf.len);
        for (buf[0..n]) |*b| b.* = rnd.int(u8);
        var r = thrift.Reader.init(buf[0..n]);
        r.skip(.@"struct") catch {};
    }
}
