//! Tests for src/index/store.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/index/store.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const Io = std.Io;
const Store = srcmod.Store;
const query = srcmod.query;
const schema = srcmod.schema;
const sqlite = srcmod.sqlite;

test "store: disabled returns null (caller uses flat scan)" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var s = Store.init(threaded.io(), testing.allocator, .{ .enabled = false });
    defer s.deinit();
    const db = try sqlite.openInMemory();
    defer sqlite.close(db);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const q = try arena.allocator().alloc(f32, schema.embeddingDims());
    @memset(q, 0.5);
    try testing.expect(s.search(db, arena.allocator(), q, 5) == null);
}

test "store: builds on demand and finds the nearest, then serves cached" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const db = try sqlite.openInMemory();
    defer sqlite.close(db);
    try createSchema(db, a);

    // Fills 0.10, 0.12, … so the query at 0.30 lands on id "c10".
    for (0..30) |i| {
        const id = try std.fmt.allocPrint(a, "c{d}", .{i});
        try insertVec(db, a, id, 0.10 + @as(f32, @floatFromInt(i)) * 0.02);
    }

    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var s = Store.init(threaded.io(), testing.allocator, .{ .enabled = true, .metric = .l2, .m = 16, .ef_construction = 100, .ef_search = 64 });
    defer s.deinit();
    s.bumpEpoch(); // simulate a write having happened

    const q = try a.alloc(f32, schema.embeddingDims());
    @memset(q, 0.30); // == fill of c10

    const res = s.search(db, a, q, 3) orelse return error.UnexpectedNull;
    try testing.expectEqual(@as(usize, 3), res.len);
    try testing.expectEqualStrings("c10", res[0].id);
    try testing.expectApproxEqAbs(@as(f32, 0), res[0].dist, 1e-3);

    // Second call hits the cache (same epoch) and is still correct.
    const res2 = s.search(db, a, q, 1) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("c10", res2[0].id);
}

test "store: a bumpEpoch forces a rebuild that sees new rows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const db = try sqlite.openInMemory();
    defer sqlite.close(db);
    try createSchema(db, a);
    try insertVec(db, a, "first", 0.9);

    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var s = Store.init(threaded.io(), testing.allocator, .{ .enabled = true, .metric = .l2 });
    defer s.deinit();
    s.bumpEpoch();

    const q = try a.alloc(f32, schema.embeddingDims());
    @memset(q, 0.1);
    _ = s.search(db, a, q, 5) orelse return error.UnexpectedNull; // builds with 1 row

    // Insert a row much closer to q, bump, and confirm the rebuild surfaces it.
    try insertVec(db, a, "closer", 0.1);
    s.bumpEpoch();
    const res = s.search(db, a, q, 1) orelse return error.UnexpectedNull;
    try testing.expectEqualStrings("closer", res[0].id);
}

// ---- helpers moved from src ----
pub fn createSchema(db: *sqlite.sqlite3, a: Allocator) !void {
    _ = a;
    try sqlite.execScript(db, schema.ddl);
}

pub fn insertVec(db: *sqlite.sqlite3, a: Allocator, id: []const u8, fill: f32) !void {
    const vec = try a.alloc(f32, schema.embeddingDims());
    @memset(vec, fill);
    const rows = [_]query.ChunkRow{.{ .id = id, .document_id = "d", .ordinal = 0, .content = "c", .token_count = 1, .vector = vec }};
    var aw = std.Io.Writer.Allocating.init(a);
    try query.writeUpsertChunks(&aw.writer, &rows);
    const stmt = try sqlite.prepare(db, aw.written());
    defer sqlite.finalize(stmt);
    try sqlite.check(sqlite.sqlite3_step(stmt));
}
