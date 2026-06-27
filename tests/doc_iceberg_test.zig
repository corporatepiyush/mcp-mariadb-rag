//! Tests for src/doc/iceberg.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/doc/iceberg.zig");

const toText = srcmod.toText;

// ── Tests ─────────────────────────────────────────────────────────────

test "iceberg: projects table id, location and schema fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const meta =
        \\{
        \\  "format-version": 2,
        \\  "table-uuid": "9c12d441",
        \\  "location": "s3://warehouse/db/orders",
        \\  "current-schema-id": 0,
        \\  "schemas": [
        \\    {"schema-id": 0, "fields": [
        \\      {"name": "order_id", "type": "long"},
        \\      {"name": "customer_email", "type": "string"}
        \\    ]}
        \\  ]
        \\}
    ;
    const r = try toText(arena.allocator(), meta);
    try testing.expectEqualStrings(
        "table 9c12d441 location s3://warehouse/db/orders order_id:long customer_email:string",
        r.text,
    );
    try testing.expectEqual(@as(usize, 2), r.units);
}

test "iceberg: rejects non-json" {
    try testing.expectError(error.NotIceberg, toText(testing.allocator, "PAR1...."));
}

test "fuzz: iceberg toText never panics" {
    var prng = std.Random.DefaultPrng.init(0x1CEB);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;
    const alphabet = "{}[]\":,schema-fieldnametyplong 0123";
    for (0..1000) |_| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const n = rnd.intRangeLessThan(usize, 0, buf.len);
        for (buf[0..n]) |*b| {
            b.* = if (rnd.boolean()) alphabet[rnd.intRangeLessThan(usize, 0, alphabet.len)] else rnd.int(u8);
        }
        _ = toText(arena.allocator(), buf[0..n]) catch {};
    }
}
