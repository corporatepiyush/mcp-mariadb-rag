const std = @import("std");
const testing = std.testing;
const pool_mod = @import("../src/pool.zig");
const schema = @import("../src/kg/schema.zig");
const graph = @import("../src/kg/graph.zig");
const types = @import("../src/kg/types.zig");

const Writer = std.Io.Writer;

fn dbUrl() ?[]const u8 {
    const env = std.c.getenv("DATABASE_URL");
    return if (env) |ptr| std.mem.sliceTo(ptr, 0) else null;
}

fn createTables(conn: *pool_mod.PooledConnection) void {
    inline for (.{
        schema.writeCreateEntity,
        schema.writeCreateObservation,
        schema.writeCreateRelation,
        schema.writeCreateVectorEmbedding,
    }) |write_fn| {
        var buf: [2048]u8 = undefined;
        var w = Writer.fixed(&buf);
        _ = write_fn(&w) catch {};
        _ = conn.execute(w.buffered()) catch {};
    }
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

    const name = "test_entity_1";
    const etype = "test_type";
    const obs = &[_][]const u8{};
    const obs_json = try graph.observationsToJson(testing.allocator, obs);
    defer testing.allocator.free(obs_json);

    var buf: [1024]u8 = undefined;
    _ = try conn.execute(try renderSql(&buf, graph.writeInsertEntity, .{ name, etype, obs_json }));
    const result = try conn.query(testing.allocator, try renderSql(&buf, graph.writeGetEntity, .{name}));
    defer {
        if (result.rows) |r| testing.allocator.free(r);
        if (result.column_names) |c| testing.allocator.free(c);
        if (result.column_kinds) |k| testing.allocator.free(k);
    }

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

    const result = try conn.query(testing.allocator, try renderSql(&buf, graph.writeSearchRelations, .{
        @as(?[]const u8, "A"), @as(?[]const u8, null), @as(?[]const u8, null),
    }));
    defer {
        if (result.rows) |r| testing.allocator.free(r);
        if (result.column_names) |c| testing.allocator.free(c);
        if (result.column_kinds) |k| testing.allocator.free(k);
    }

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

    const result = try conn.query(testing.allocator, try renderSql(&buf, graph.writeDegree, .{ "X", types.Direction.out }));
    defer {
        if (result.rows) |r| testing.allocator.free(r);
        if (result.column_names) |c| testing.allocator.free(c);
        if (result.column_kinds) |k| testing.allocator.free(k);
    }

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

    const result = try conn.query(testing.allocator, try renderSql(&buf, graph.writeCountEntities, .{}));
    defer {
        if (result.rows) |r| testing.allocator.free(r);
        if (result.column_names) |c| testing.allocator.free(c);
        if (result.column_kinds) |k| testing.allocator.free(k);
    }

    try testing.expectEqual(@as(u64, 1), result.num_rows);
    try testing.expectEqualStrings("2", result.rows.?[0].values[0].?);
}
