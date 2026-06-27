const std = @import("std");
const testing = std.testing;
const pool_mod = @import("../src/pool.zig");
const kg = @import("../src/actions/kg.zig");
const graph = @import("../src/kg/graph.zig");
const schema = @import("../src/kg/schema.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const PooledConn = pool_mod.PooledConnection;
const Writer = std.Io.Writer;

fn dbUrl() ?[]const u8 {
    const env = std.c.getenv("DATABASE_URL");
    return if (env) |ptr| std.mem.sliceTo(ptr, 0) else null;
}

fn setupTables(conn: *PooledConn) void {
    conn.executeScript(schema.ddl) catch {};
}

fn dropTables(conn: *PooledConn) void {
    for (schema.allTableNames()) |tname| {
        var buf: [128]u8 = undefined;
        const sql = std.fmt.bufPrint(&buf, "DROP TABLE IF EXISTS `{s}`", .{tname}) catch continue;
        _ = conn.execute(sql) catch continue;
    }
}

fn insertEntity(conn: *PooledConn, name: []const u8, etype: []const u8) void {
    var buf: [1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    _ = graph.writeInsertEntity(&w, name, etype, "[]") catch {};
    _ = conn.execute(w.buffered()) catch {};
}

fn insertRelation(conn: *PooledConn, from: []const u8, rtype: []const u8, to: []const u8) void {
    var buf: [1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    _ = graph.writeInsertRelation(&w, from, rtype, to) catch {};
    _ = conn.execute(w.buffered()) catch {};
}

fn parseJson(allocator: Allocator, json_str: []const u8) Value {
    const parsed = std.json.parseFromSlice(Value, allocator, json_str, .{}) catch @panic("bad JSON");
    return parsed.value;
}

fn benchRead(comptime name: []const u8, comptime n: u64, io: std.Io, a: Allocator, conn: *PooledConn, comptime handler: anytype, args: ?Value) void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const start = std.Io.Timestamp.now(io, .awake);
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        const aa = arena.allocator();
        const result = handler(io, aa, conn, args);
        if (result.is_error) {
            std.debug.print("BENCH FAIL [{s}]: {s}\n", .{ name, result.text });
            return;
        }
        _ = arena.reset(.retain_capacity);
    }
    const end = std.Io.Timestamp.now(io, .awake);
    const ns = std.Io.Timestamp.durationTo(start, end).nanoseconds;
    const ns_per_op = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(n));
    const ops_per_s = 1_000_000_000.0 / ns_per_op;
    std.debug.print("bench {s: <25}  {d: >6} ops  {d: >8.0} ns/op  {d: >10.0} ops/s\n", .{
        name, n, ns_per_op, ops_per_s,
    });
}

test "kg_bench: tool call handlers" {
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
    setupTables(&conn);

    // ---- Seed shared data for read benchmarks ----
    for (0..10) |i| {
        var buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "bench_entity_{d}", .{i}) catch unreachable;
        insertEntity(&conn, name, if (i < 5) "type_a" else "type_b");
    }
    for (0..9) |i| {
        var buf1: [64]u8 = undefined;
        var buf2: [64]u8 = undefined;
        const from = std.fmt.bufPrint(&buf1, "bench_entity_{d}", .{i}) catch unreachable;
        const to = std.fmt.bufPrint(&buf2, "bench_entity_{d}", .{i + 1}) catch unreachable;
        insertRelation(&conn, from, "knows", to);
    }
    insertRelation(&conn, "bench_entity_0", "knows", "bench_entity_2");

    std.debug.print("\n=== read benchmarks ===\n", .{});

    benchRead("getEntityStats", 250, io, testing.allocator, &conn, kg.getEntityStats, null);
    benchRead("getRelationStats", 250, io, testing.allocator, &conn, kg.getRelationStats, null);
    benchRead("getGraphStatistics", 250, io, testing.allocator, &conn, kg.getGraphStatistics, null);
    benchRead("readGraph", 250, io, testing.allocator, &conn, kg.readGraph, null);

    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        const args = parseJson(aa,
            \\{"from":"bench_entity_0","to":"bench_entity_1","relationType":"knows"}
        );
        benchRead("searchRelations-3param", 250, io, testing.allocator, &conn, kg.searchRelations, args);
    }

    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        const args = parseJson(aa,
            \\{"names":["bench_entity_0","bench_entity_1"]}
        );
        benchRead("getNeighbors-2", 250, io, testing.allocator, &conn, kg.getNeighbors, args);
    }

    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        const args = parseJson(aa,
            \\{"name":"bench_entity_0","direction":"out"}
        );
        benchRead("getEntityDegree-out", 250, io, testing.allocator, &conn, kg.getEntityDegree, args);
    }

    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        const args = parseJson(aa,
            \\{"query":"entity_0","limit":"20"}
        );
        benchRead("searchNodes", 250, io, testing.allocator, &conn, kg.searchNodes, args);
    }

    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        const args = parseJson(aa,
            \\{"names":["bench_entity_0","bench_entity_1","bench_entity_2"]}
        );
        benchRead("openNodes-3", 250, io, testing.allocator, &conn, kg.openNodes, args);
    }

    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        const args = parseJson(aa,
            \\{"names":["bench_entity_0"]}
        );
        benchRead("openNodes-1", 250, io, testing.allocator, &conn, kg.openNodes, args);
    }

    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        const args = parseJson(aa,
            \\{"query":"bench_entity","limit":"20"}
        );
        benchRead("fulltextSearch", 250, io, testing.allocator, &conn, kg.fulltextSearch, args);
    }

    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        const args = parseJson(aa,
            \\{"source":"bench_entity_0","target":"bench_entity_5","maxHops":"10","direction":"out"}
        );
        benchRead("bfsPath-out-5hop", 250, io, testing.allocator, &conn, kg.bfsPath, args);
    }

    // ---- Write benchmarks ----
    std.debug.print("=== write benchmarks ===\n", .{});

    // createEntities: each iteration creates 2 entities with unique names
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        const start = std.Io.Timestamp.now(io, .awake);
        const N: u64 = 50;
        var i: u64 = 0;
        while (i < N) : (i += 1) {
            var buf: [512]u8 = undefined;
            const len = (std.fmt.bufPrint(&buf,
                \\{{"entities":[{{"name":"bench_ce_{d}_0","entityType":"t","observations":[]}},{{"name":"bench_ce_{d}_1","entityType":"t","observations":[]}}]}}
            , .{ i, i }) catch unreachable).len;
            _ = arena.reset(.retain_capacity);
            const aa = arena.allocator();
            const args = parseJson(aa, buf[0..len]);
            const result = kg.createEntities(io, aa, &conn, args);
            if (result.is_error) {
                std.debug.print("BENCH FAIL [createEntities] iter {d}: {s}\n", .{ i, result.text });
                return;
            }
        }
        const end = std.Io.Timestamp.now(io, .awake);
        const ns = std.Io.Timestamp.durationTo(start, end).nanoseconds;
        const ns_per_op = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(N));
        const ops_per_s = 1_000_000_000.0 / ns_per_op;
        std.debug.print("bench {s: <25}  {d: >6} ops  {d: >8.0} ns/op  {d: >10.0} ops/s\n", .{
            "createEntities", N, ns_per_op, ops_per_s,
        });
    }

    // createRelations: each iteration creates a relation with unique type
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        const start = std.Io.Timestamp.now(io, .awake);
        const N: u64 = 50;
        var i: u64 = 0;
        while (i < N) : (i += 1) {
            var buf: [256]u8 = undefined;
            const len = (std.fmt.bufPrint(&buf,
                \\{{"relations":[{{"from":"bench_entity_0","to":"bench_entity_1","relationType":"rel_cr_{d}"}}]}}
            , .{i}) catch unreachable).len;
            _ = arena.reset(.retain_capacity);
            const aa = arena.allocator();
            const args = parseJson(aa, buf[0..len]);
            const result = kg.createRelations(io, aa, &conn, args);
            if (result.is_error) {
                std.debug.print("BENCH FAIL [createRelations] iter {d}: {s}\n", .{ i, result.text });
                return;
            }
        }
        const end = std.Io.Timestamp.now(io, .awake);
        const ns = std.Io.Timestamp.durationTo(start, end).nanoseconds;
        const ns_per_op = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(N));
        const ops_per_s = 1_000_000_000.0 / ns_per_op;
        std.debug.print("bench {s: <25}  {d: >6} ops  {d: >8.0} ns/op  {d: >10.0} ops/s\n", .{
            "createRelations", N, ns_per_op, ops_per_s,
        });
    }

    // Pre-create entities for deleteEntities benchmark
    for (0..100) |i| {
        var buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "bench_del_{d}", .{i}) catch unreachable;
        insertEntity(&conn, name, "type_del");
    }

    // deleteEntities: delete 2 entities at a time
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        const start = std.Io.Timestamp.now(io, .awake);
        const N: u64 = 30;
        var i: u64 = 0;
        while (i < N) : (i += 1) {
            var buf: [256]u8 = undefined;
            const len = (std.fmt.bufPrint(&buf,
                \\{{"names":["bench_del_{d}","bench_del_{d}"]}}
            , .{ i * 2, i * 2 + 1 }) catch unreachable).len;
            _ = arena.reset(.retain_capacity);
            const aa = arena.allocator();
            const args = parseJson(aa, buf[0..len]);
            const result = kg.deleteEntities(io, aa, &conn, args);
            if (result.is_error) {
                std.debug.print("BENCH FAIL [deleteEntities] iter {d}: {s}\n", .{ i, result.text });
                return;
            }
        }
        const end = std.Io.Timestamp.now(io, .awake);
        const ns = std.Io.Timestamp.durationTo(start, end).nanoseconds;
        const ns_per_op = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(N));
        const ops_per_s = 1_000_000_000.0 / ns_per_op;
        std.debug.print("bench {s: <25}  {d: >6} ops  {d: >8.0} ns/op  {d: >10.0} ops/s\n", .{
            "deleteEntities", N, ns_per_op, ops_per_s,
        });
    }

    // Pre-create relations for deleteRelation benchmark
    for (0..50) |i| {
        var buf: [64]u8 = undefined;
        const rtype = std.fmt.bufPrint(&buf, "rel_del_{d}", .{i}) catch unreachable;
        insertRelation(&conn, "bench_entity_9", rtype, "bench_entity_8");
    }

    // deleteRelation: one at a time
    {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        const start = std.Io.Timestamp.now(io, .awake);
        const N: u64 = 50;
        var i: u64 = 0;
        while (i < N) : (i += 1) {
            var buf: [256]u8 = undefined;
            const len = (std.fmt.bufPrint(&buf,
                \\{{"from":"bench_entity_9","to":"bench_entity_8","relationType":"rel_del_{d}"}}
            , .{i}) catch unreachable).len;
            _ = arena.reset(.retain_capacity);
            const aa = arena.allocator();
            const args = parseJson(aa, buf[0..len]);
            const result = kg.deleteRelation(io, aa, &conn, args);
            if (result.is_error) {
                std.debug.print("BENCH FAIL [deleteRelation] iter {d}: {s}\n", .{ i, result.text });
                return;
            }
        }
        const end = std.Io.Timestamp.now(io, .awake);
        const ns = std.Io.Timestamp.durationTo(start, end).nanoseconds;
        const ns_per_op = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(N));
        const ops_per_s = 1_000_000_000.0 / ns_per_op;
        std.debug.print("bench {s: <25}  {d: >6} ops  {d: >8.0} ns/op  {d: >10.0} ops/s\n", .{
            "deleteRelation", N, ns_per_op, ops_per_s,
        });
    }

    std.debug.print("=== done ===\n", .{});
}
