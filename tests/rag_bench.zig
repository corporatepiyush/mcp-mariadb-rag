//! RAG engine microbenchmarks (DATABASE_URL-gated). Reports ns/op and ops/s for
//! the ingest/retrieval handlers plus the pure SIMD cosine kernel.

const std = @import("std");
const testing = std.testing;
const pool_mod = @import("../src/pool.zig");
const schema = @import("../src/rag/schema.zig");
const fusion = @import("../src/rag/fusion.zig");
const rag = @import("../src/actions/rag.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const PooledConn = pool_mod.PooledConnection;
const Writer = std.Io.Writer;

fn dbUrl() ?[]const u8 {
    const env = std.c.getenv("DATABASE_URL");
    return if (env) |ptr| std.mem.sliceTo(ptr, 0) else null;
}

fn parseJson(a: Allocator, src: []const u8) Value {
    const parsed = std.json.parseFromSlice(Value, a, src, .{}) catch @panic("bad JSON");
    return parsed.value;
}

fn createTables(conn: *PooledConn) void {
    inline for (.{ schema.writeCreateDocument, schema.writeCreateChunk }) |write_fn| {
        var buf: [2048]u8 = undefined;
        var w = Writer.fixed(&buf);
        _ = write_fn(&w) catch {};
        _ = conn.execute(w.buffered()) catch {};
    }
}

fn dropTables(conn: *PooledConn) void {
    inline for (.{ "rag_chunk", "rag_document" }) |t| {
        var buf: [128]u8 = undefined;
        const sql = std.fmt.bufPrint(&buf, "DROP TABLE IF EXISTS `{s}`", .{t}) catch return;
        _ = conn.execute(sql) catch {};
    }
}

fn writeVec(w: *Writer, fill: f32) void {
    for (0..schema.embedding_dims) |i| {
        if (i > 0) w.writeByte(',') catch {};
        w.print("{d}", .{fill}) catch {};
    }
}

fn seedDoc(a: Allocator, io: std.Io, conn: *PooledConn) void {
    var aw = Writer.Allocating.init(a);
    const w = &aw.writer;
    w.writeAll("{\"id\":\"benchdoc\",\"chunks\":[") catch {};
    inline for (0..8) |i| {
        if (i > 0) w.writeByte(',') catch {};
        w.print("{{\"content\":\"chunk number {d} about neural retrieval systems\",\"ordinal\":{d},\"embedding\":[", .{ i, i }) catch {};
        writeVec(w, @as(f32, @floatFromInt(i)) / 8.0);
        w.writeAll("]}") catch {};
    }
    w.writeAll("]}") catch {};
    _ = rag.ingestDocument(io, a, conn, parseJson(a, aw.toOwnedSlice() catch unreachable));
}

fn benchHandler(comptime name: []const u8, n: u64, io: std.Io, a: Allocator, conn: *PooledConn, comptime handler: anytype, args_json: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const start = std.Io.Timestamp.now(io, .awake);
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        const aa = arena.allocator();
        const args = if (args_json.len > 0) parseJson(aa, args_json) else null;
        const res = handler(io, aa, conn, args);
        if (res.is_error) {
            std.debug.print("BENCH FAIL [{s}]: {s}\n", .{ name, res.text });
            return;
        }
        _ = arena.reset(.retain_capacity);
    }
    const end = std.Io.Timestamp.now(io, .awake);
    const ns = std.Io.Timestamp.durationTo(start, end).nanoseconds;
    const per = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(n));
    std.debug.print("bench {s: <24} {d: >6} ops {d: >9.0} ns/op {d: >11.0} ops/s\n", .{ name, n, per, 1_000_000_000.0 / per });
}

test "rag_bench: handlers + cosine kernel" {
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
    seedDoc(arena.allocator(), io, &conn);

    std.debug.print("\n=== RAG benchmarks ===\n", .{});

    // Pure CPU: SIMD cosine over 384-dim vectors.
    {
        var av: [384]f32 = undefined;
        var bv: [384]f32 = undefined;
        for (&av, &bv, 0..) |*x, *y, i| {
            x.* = @floatFromInt(i % 7);
            y.* = @floatFromInt(i % 5);
        }
        const N: u64 = 200_000;
        const start = std.Io.Timestamp.now(io, .awake);
        var sink: f32 = 0;
        var i: u64 = 0;
        while (i < N) : (i += 1) sink += fusion.cosineSimilarity(&av, &bv);
        std.mem.doNotOptimizeAway(sink);
        const end = std.Io.Timestamp.now(io, .awake);
        const per = @as(f64, @floatFromInt(std.Io.Timestamp.durationTo(start, end).nanoseconds)) / @as(f64, @floatFromInt(N));
        std.debug.print("bench {s: <24} {d: >6} ops {d: >9.1} ns/op {d: >11.0} ops/s\n", .{ "cosine384(SIMD)", N, per, 1_000_000_000.0 / per });
    }

    var chunk_buf: [256]u8 = undefined;
    const chunk_args = std.fmt.bufPrint(&chunk_buf, "{{\"text\":\"{s}\",\"chunkSize\":4,\"overlap\":1}}", .{"the quick brown fox jumps over the lazy dog again and again repeatedly"}) catch unreachable;
    benchHandler("chunk_text", 5000, io, testing.allocator, &conn, rag.chunkText, chunk_args);

    // Read handlers: build query args with a full 384-dim vector once.
    var qaw = Writer.Allocating.init(arena.allocator());
    qaw.writer.writeAll("{\"query\":\"neural\",\"k\":5,\"vector\":[") catch {};
    writeVec(&qaw.writer, 0.5);
    qaw.writer.writeAll("]}") catch {};
    const search_args = qaw.toOwnedSlice() catch unreachable;

    var maw = Writer.Allocating.init(arena.allocator());
    maw.writer.writeAll("{\"query\":\"neural\",\"k\":5,\"mmr\":true,\"lambda\":0.5,\"vector\":[") catch {};
    writeVec(&maw.writer, 0.5);
    maw.writer.writeAll("]}") catch {};
    const mmr_args = maw.toOwnedSlice() catch unreachable;

    benchHandler("search_hybrid", 250, io, testing.allocator, &conn, rag.search, search_args);
    benchHandler("search_hybrid_mmr", 250, io, testing.allocator, &conn, rag.search, mmr_args);
    benchHandler("vector_search", 250, io, testing.allocator, &conn, rag.vectorSearch, search_args);
    benchHandler("rag_stats", 250, io, testing.allocator, &conn, rag.stats, "");

    std.debug.print("=== done ===\n", .{});
}
