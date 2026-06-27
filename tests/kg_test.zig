const std = @import("std");
const testing = std.testing;
const pool_mod = @import("../src/pool.zig");
const schema = @import("../src/kg/schema.zig");
const graph = @import("../src/kg/graph.zig");
const types = @import("../src/kg/types.zig");
const kg = @import("../src/actions/kg.zig");

const Writer = std.Io.Writer;
const Value = std.json.Value;

fn dbUrl() ?[]const u8 {
    const env = std.c.getenv("DATABASE_URL");
    return if (env) |ptr| std.mem.sliceTo(ptr, 0) else null;
}

fn parseJson(allocator: std.mem.Allocator, src: []const u8) Value {
    const parsed = std.json.parseFromSlice(Value, allocator, src, .{}) catch @panic("bad JSON");
    return parsed.value;
}

/// Build an `upsert_vector_embedding` args JSON string with a full 384-dim
/// embedding (every component set to `fill`), matching the 384-dim BLOB schema.
fn vectorArgs(allocator: std.mem.Allocator, id: []const u8, entity: []const u8, text: []const u8, fill: f32) ![]u8 {
    var aw = Writer.Allocating.init(allocator);
    const w = &aw.writer;
    try w.print("{{\"id\":\"{s}\",\"entityName\":\"{s}\",\"textContent\":\"{s}\",\"vector\":[", .{ id, entity, text });
    for (0..384) |i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{d}", .{fill});
    }
    try w.writeAll("]}");
    return aw.toOwnedSlice();
}

fn createTables(conn: *pool_mod.PooledConnection) void {
    conn.executeScript(schema.ddl) catch {};
}

fn dropTables(conn: *pool_mod.PooledConnection) void {
    for (schema.allTableNames()) |tname| {
        var buf: [128]u8 = undefined;
        const sql = std.fmt.bufPrint(&buf, "DROP TABLE IF EXISTS `{s}`", .{tname}) catch continue;
        _ = conn.execute(sql) catch continue;
    }
}

fn renderSql(buf: []u8, comptime f: anytype, args: anytype) ![]u8 {
    var w = Writer.fixed(buf);
    try @call(.auto, f, .{&w} ++ args);
    return w.buffered();
}

test "kg_integration: create entity and read it back" {
    const url = dbUrl() orelse return;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pool = try pool_mod.ConnectionPool.init(io, testing.allocator, url, .{
        .min_size = 1, .max_size = 2,
        .tls = .{ .enforce = false, .verify = false, .ca_path = null },
    });
    defer pool.close();
    var conn = try pool.acquire();
    defer conn.deinit();

    dropTables(&conn);
    createTables(&conn);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const name = "test_entity_1";
    const etype = "test_type";
    const obs = &[_][]const u8{};
    const obs_json = try graph.observationsToJson(a, obs);

    var buf: [1024]u8 = undefined;
    _ = try conn.execute(try renderSql(&buf, graph.writeInsertEntity, .{ name, etype, obs_json }));
    const result = try conn.query(a, try renderSql(&buf, graph.writeGetEntity, .{name}));

    try testing.expectEqual(@as(u64, 1), result.num_rows);
    try testing.expectEqualStrings(etype, result.rows.?[0].values[0].?);
}

test "kg_integration: insert relation and search" {
    const url = dbUrl() orelse return;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pool = try pool_mod.ConnectionPool.init(io, testing.allocator, url, .{
        .min_size = 1, .max_size = 2,
        .tls = .{ .enforce = false, .verify = false, .ca_path = null },
    });
    defer pool.close();
    var conn = try pool.acquire();
    defer conn.deinit();

    dropTables(&conn);
    createTables(&conn);

    const obs_json = "[]";
    var buf: [1024]u8 = undefined;
    _ = try conn.execute(try renderSql(&buf, graph.writeInsertEntity, .{ "A", "type1", obs_json }));
    _ = try conn.execute(try renderSql(&buf, graph.writeInsertEntity, .{ "B", "type2", obs_json }));
    _ = try conn.execute(try renderSql(&buf, graph.writeInsertRelation, .{ "A", "knows", "B" }));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = try conn.query(arena.allocator(), try renderSql(&buf, graph.writeSearchRelations, .{
        @as(?[]const u8, "A"), @as(?[]const u8, null), @as(?[]const u8, null),
    }));

    try testing.expectEqual(@as(u64, 1), result.num_rows);
    if (result.rows) |rows| {
        try testing.expectEqualStrings("A", rows[0].values[0].?);
        try testing.expectEqualStrings("knows", rows[0].values[1].?);
        try testing.expectEqualStrings("B", rows[0].values[2].?);
    }
}

test "kg_integration: entity degree" {
    const url = dbUrl() orelse return;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pool = try pool_mod.ConnectionPool.init(io, testing.allocator, url, .{
        .min_size = 1, .max_size = 2,
        .tls = .{ .enforce = false, .verify = false, .ca_path = null },
    });
    defer pool.close();
    var conn = try pool.acquire();
    defer conn.deinit();

    dropTables(&conn);
    createTables(&conn);

    const obs_json = "[]";
    var buf: [1024]u8 = undefined;
    _ = try conn.execute(try renderSql(&buf, graph.writeInsertEntity, .{ "X", "t", obs_json }));
    _ = try conn.execute(try renderSql(&buf, graph.writeInsertEntity, .{ "Y", "t", obs_json }));
    _ = try conn.execute(try renderSql(&buf, graph.writeInsertRelation, .{ "X", "e", "Y" }));
    _ = try conn.execute(try renderSql(&buf, graph.writeInsertRelation, .{ "X", "f", "Y" }));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = try conn.query(arena.allocator(), try renderSql(&buf, graph.writeDegree, .{ "X", types.Direction.out }));

    try testing.expectEqual(@as(u64, 1), result.num_rows);
    try testing.expectEqualStrings("2", result.rows.?[0].values[0].?);
}

test "kg_integration: count entities" {
    const url = dbUrl() orelse return;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pool = try pool_mod.ConnectionPool.init(io, testing.allocator, url, .{
        .min_size = 1, .max_size = 2,
        .tls = .{ .enforce = false, .verify = false, .ca_path = null },
    });
    defer pool.close();
    var conn = try pool.acquire();
    defer conn.deinit();

    dropTables(&conn);
    createTables(&conn);

    const obs_json = "[]";
    var buf: [1024]u8 = undefined;
    _ = try conn.execute(try renderSql(&buf, graph.writeInsertEntity, .{ "C1", "t", obs_json }));
    _ = try conn.execute(try renderSql(&buf, graph.writeInsertEntity, .{ "C2", "t", obs_json }));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const result = try conn.query(arena.allocator(), try renderSql(&buf, graph.writeCountEntities, .{}));

    try testing.expectEqual(@as(u64, 1), result.num_rows);
    try testing.expectEqualStrings("2", result.rows.?[0].values[0].?);
}

// ── Handler-level integration tests (new v0.3.0 batch paths) ──────────

test "kg_integration: createEntities batches entities + observations" {
    const url = dbUrl() orelse return;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pool = try pool_mod.ConnectionPool.init(io, testing.allocator, url, .{
        .min_size = 1, .max_size = 2,
        .tls = .{ .enforce = false, .verify = false, .ca_path = null },
    });
    defer pool.close();
    var conn = try pool.acquire();
    defer conn.deinit();

    dropTables(&conn);
    createTables(&conn);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const args = parseJson(a,
        \\{"entities":[
        \\  {"name":"Alice","entityType":"person","observations":["likes math","plays piano"]},
        \\  {"name":"Bob","entityType":"person","observations":[]},
        \\  {"name":"Carol","entityType":"robot","observations":["beeps"]}
        \\]}
    );
    const res = kg.createEntities(io, a, &conn, args);
    try testing.expect(!res.is_error);

    var buf: [256]u8 = undefined;
    const cnt = try conn.query(a, try renderSql(&buf, graph.writeCountEntities, .{}));
    try testing.expectEqualStrings("3", cnt.rows.?[0].values[0].?);

    // Observations: 2 (Alice) + 0 (Bob) + 1 (Carol) = 3 rows, one batched INSERT.
    const obs = try conn.query(a, "SELECT COUNT(*) FROM `rag_observation`");
    try testing.expectEqualStrings("3", obs.rows.?[0].values[0].?);
}

test "kg_integration: empty entities/relations rejected" {
    const url = dbUrl() orelse return;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pool = try pool_mod.ConnectionPool.init(io, testing.allocator, url, .{
        .min_size = 1, .max_size = 2,
        .tls = .{ .enforce = false, .verify = false, .ca_path = null },
    });
    defer pool.close();
    var conn = try pool.acquire();
    defer conn.deinit();

    dropTables(&conn);
    createTables(&conn);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expect(kg.createEntities(io, a, &conn, parseJson(a, "{\"entities\":[]}")).is_error);
    try testing.expect(kg.createRelations(io, a, &conn, parseJson(a, "{\"relations\":[]}")).is_error);
}

test "kg_integration: deleteEntities batch IN clause" {
    const url = dbUrl() orelse return;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pool = try pool_mod.ConnectionPool.init(io, testing.allocator, url, .{
        .min_size = 1, .max_size = 2,
        .tls = .{ .enforce = false, .verify = false, .ca_path = null },
    });
    defer pool.close();
    var conn = try pool.acquire();
    defer conn.deinit();

    dropTables(&conn);
    createTables(&conn);

    var buf: [1024]u8 = undefined;
    inline for (.{ "D1", "D2", "D3" }) |name| {
        _ = try conn.execute(try renderSql(&buf, graph.writeInsertEntity, .{ name, "t", "[]" }));
    }

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const res = kg.deleteEntities(io, a, &conn, parseJson(a, "{\"names\":[\"D1\",\"D2\"]}"));
    try testing.expect(!res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.text, "\"deleted\":2") != null);

    var buf2: [256]u8 = undefined;
    const cnt = try conn.query(a, try renderSql(&buf2, graph.writeCountEntities, .{}));
    try testing.expectEqualStrings("1", cnt.rows.?[0].values[0].?);
}

test "kg_integration: openNodes skips missing names with valid JSON" {
    const url = dbUrl() orelse return;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pool = try pool_mod.ConnectionPool.init(io, testing.allocator, url, .{
        .min_size = 1, .max_size = 2,
        .tls = .{ .enforce = false, .verify = false, .ca_path = null },
    });
    defer pool.close();
    var conn = try pool.acquire();
    defer conn.deinit();

    dropTables(&conn);
    createTables(&conn);

    var buf: [1024]u8 = undefined;
    // Only "Present" exists; "Missing" must be skipped without breaking JSON.
    _ = try conn.execute(try renderSql(&buf, graph.writeInsertEntity, .{ "Present", "t", "[]" }));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // First name missing — previously produced `{"entities":[,{...}]}`.
    const res = kg.openNodes(io, a, &conn, parseJson(a, "{\"names\":[\"Missing\",\"Present\"]}"));
    try testing.expect(!res.is_error);

    // The result must parse as valid JSON and contain exactly one entity.
    const parsed = try std.json.parseFromSlice(Value, a, res.text, .{});
    const entities = parsed.value.object.get("entities").?.array;
    try testing.expectEqual(@as(usize, 1), entities.items.len);
    try testing.expectEqualStrings("Present", entities.items[0].object.get("name").?.string);
}

test "kg_integration: getGraphStatistics single round-trip" {
    const url = dbUrl() orelse return;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pool = try pool_mod.ConnectionPool.init(io, testing.allocator, url, .{
        .min_size = 1, .max_size = 2,
        .tls = .{ .enforce = false, .verify = false, .ca_path = null },
    });
    defer pool.close();
    var conn = try pool.acquire();
    defer conn.deinit();

    dropTables(&conn);
    createTables(&conn);

    var buf: [1024]u8 = undefined;
    _ = try conn.execute(try renderSql(&buf, graph.writeInsertEntity, .{ "S1", "t", "[]" }));
    _ = try conn.execute(try renderSql(&buf, graph.writeInsertEntity, .{ "S2", "t", "[]" }));
    _ = try conn.execute(try renderSql(&buf, graph.writeInsertRelation, .{ "S1", "knows", "S2" }));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const res = kg.getGraphStatistics(io, a, &conn, null);
    try testing.expect(!res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.text, "\"entity_count\":2") != null);
    try testing.expect(std.mem.indexOf(u8, res.text, "\"relation_count\":1") != null);
}

test "kg_integration: vector upsert by string id replaces in place" {
    const url = dbUrl() orelse return;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pool = try pool_mod.ConnectionPool.init(io, testing.allocator, url, .{
        .min_size = 1, .max_size = 2,
        .tls = .{ .enforce = false, .verify = false, .ca_path = null },
    });
    defer pool.close();
    var conn = try pool.acquire();
    defer conn.deinit();

    dropTables(&conn);
    createTables(&conn);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The schema's 384-dim BLOB column requires exactly 384 dimensions, so build
    // the args JSON with a full-length embedding rather than a toy 3-vector.
    const v1 = try vectorArgs(a, "vec1", "Alice", "hello", 0.1);
    try testing.expect(!kg.upsertVectorEmbedding(io, a, &conn, parseJson(a, v1)).is_error);

    // Same id again — REPLACE must keep a single row rather than collide on id=0.
    const v2 = try vectorArgs(a, "vec1", "Alice", "updated", 0.4);
    try testing.expect(!kg.upsertVectorEmbedding(io, a, &conn, parseJson(a, v2)).is_error);

    const cnt = try conn.query(a, "SELECT COUNT(*) FROM `rag_vector_embedding`");
    try testing.expectEqualStrings("1", cnt.rows.?[0].values[0].?);

    const txt = try conn.query(a, "SELECT text_content FROM `rag_vector_embedding` WHERE id = 'vec1'");
    try testing.expectEqualStrings("updated", txt.rows.?[0].values[0].?);

    const del = kg.deleteVectorEmbedding(io, a, &conn, parseJson(a, "{\"id\":\"vec1\"}"));
    try testing.expect(!del.is_error);
    const cnt2 = try conn.query(a, "SELECT COUNT(*) FROM `rag_vector_embedding`");
    try testing.expectEqualStrings("0", cnt2.rows.?[0].values[0].?);
}

/// Build a JSON string for a vectorSearch args with a query vector of `fill` repeated 384 times.
fn vectorSearchArgs(allocator: std.mem.Allocator, fill: f32, limit: u64, metric: []const u8) ![]u8 {
    var aw = Writer.Allocating.init(allocator);
    const w = &aw.writer;
    try w.print("{{\"vector\":[", .{});
    for (0..384) |i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{d}", .{fill});
    }
    try w.print("],\"limit\":{d},\"metric\":\"{s}\"}}", .{ limit, metric });
    return aw.toOwnedSlice();
}

test "kg_integration: vectorSearch returns results in ascending distance order" {
    const url = dbUrl() orelse return;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pool = try pool_mod.ConnectionPool.init(io, testing.allocator, url, .{
        .min_size = 1, .max_size = 2,
        .tls = .{ .enforce = false, .verify = false, .ca_path = null },
    });
    defer pool.close();
    var conn = try pool.acquire();
    defer conn.deinit();

    dropTables(&conn);
    createTables(&conn);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Query vector: all 0.5s
    const query_fill: f32 = 0.5;

    // Insert three vectors at different distances from query:
    //   close:  all 0.55 → euclidean = 384*(0.05²)   ≈ 0.96
    //   medium: all 0.9  → euclidean = 384*(0.40²)   ≈ 7.68
    //   far:    all 0.1  → euclidean = 384*(0.40²)   ≈ 7.68 (same dist as medium)
    // Use a different medium value to ensure three distinct distances.
    //   close:  all 0.55 → dist ≈ 0.96
    //   medium: all 0.8  → dist ≈ 384*(0.3²) = 5.88
    //   far:    all 0.05 → dist ≈ 384*(0.45²) = 7.68
    const v_close = try vectorArgs(a, "v_close", "Close", "nearest", 0.55);
    const v_medium = try vectorArgs(a, "v_medium", "Medium", "middle", 0.8);
    const v_far = try vectorArgs(a, "v_far", "Far", "farthest", 0.05);

    try testing.expect(!kg.upsertVectorEmbedding(io, a, &conn, parseJson(a, v_close)).is_error);
    try testing.expect(!kg.upsertVectorEmbedding(io, a, &conn, parseJson(a, v_medium)).is_error);
    try testing.expect(!kg.upsertVectorEmbedding(io, a, &conn, parseJson(a, v_far)).is_error);

    // Search with euclidean metric, limit > 3 to return all.
    const args = try vectorSearchArgs(a, query_fill, 10, "euclidean");
    const res = kg.vectorSearch(io, a, &conn, parseJson(a, args));
    try testing.expect(!res.is_error);

    const parsed = try std.json.parseFromSlice(Value, a, res.text, .{});
    const rows = parsed.value.object.get("rows").?.array;

    // Must return at least 3 rows
    try testing.expect(rows.items.len >= 3);

    // First three rows should be close, medium, far (ascending euclidean distance)
    const id0 = rows.items[0].array.items[0].string; // id
    const id1 = rows.items[1].array.items[0].string;
    const id2 = rows.items[2].array.items[0].string;

    try testing.expectEqualStrings("v_close", id0);
    try testing.expectEqualStrings("v_medium", id1);
    try testing.expectEqualStrings("v_far", id2);
}

test "kg_integration: vectorSearch returns results in ascending cosine distance order" {
    const url = dbUrl() orelse return;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pool = try pool_mod.ConnectionPool.init(io, testing.allocator, url, .{
        .min_size = 1, .max_size = 2,
        .tls = .{ .enforce = false, .verify = false, .ca_path = null },
    });
    defer pool.close();
    var conn = try pool.acquire();
    defer conn.deinit();

    dropTables(&conn);
    createTables(&conn);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Query vector: all 1.0s
    // close: all 1.0 → identical → cosine = 1.0  → dist = 0.0
    // far:   all 0.0 → opposite  → cosine = 0.0  → dist = 1.0
    const v_identical = try vectorArgs(a, "v_ident", "Same", "identical", 1.0);
    const v_opposite = try vectorArgs(a, "v_opp", "Opposite", "far", 0.0);

    try testing.expect(!kg.upsertVectorEmbedding(io, a, &conn, parseJson(a, v_identical)).is_error);
    try testing.expect(!kg.upsertVectorEmbedding(io, a, &conn, parseJson(a, v_opposite)).is_error);

    const args = try vectorSearchArgs(a, 1.0, 10, "cosine");
    const res = kg.vectorSearch(io, a, &conn, parseJson(a, args));
    try testing.expect(!res.is_error);

    const parsed = try std.json.parseFromSlice(Value, a, res.text, .{});
    const rows = parsed.value.object.get("rows").?.array;
    try testing.expect(rows.items.len >= 2);

    // Identical vector (cosine distance 0) should sort before opposite (cosine distance 1)
    try testing.expectEqualStrings("v_ident", rows.items[0].array.items[0].string);
    try testing.expectEqualStrings("v_opp", rows.items[1].array.items[0].string);
}
