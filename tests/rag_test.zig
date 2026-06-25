//! End-to-end RAG tests against a live SQLite instance.
//! Gated on DATABASE_URL; skipped (pass) when unset.
//!
//!     DATABASE_URL="sqlite:///tmp/mcp_test.db" zig build test
//!
//! NOTE: each test keeps its own `std.Io.Threaded` as a stack local and never
//! moves it after `.io()` — moving it would dangle the pointers the pool's
//! futex-backed mutex holds. (Hence no shared setup struct.)

const std = @import("std");
const testing = std.testing;
const pool_mod = @import("../src/pool.zig");
const schema = @import("../src/rag/schema.zig");
const rag = @import("../src/actions/rag.zig");

const Writer = std.Io.Writer;
const Value = std.json.Value;
const PooledConn = pool_mod.PooledConnection;

fn dbUrl() ?[]const u8 {
    const env = std.c.getenv("DATABASE_URL");
    return if (env) |ptr| std.mem.sliceTo(ptr, 0) else null;
}

fn parseJson(a: std.mem.Allocator, src: []const u8) Value {
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

/// Write 384 comma-separated copies of `fill` (a full embedding literal body).
fn writeVec(w: *Writer, fill: f32) void {
    for (0..schema.embedding_dims) |i| {
        if (i > 0) w.writeByte(',') catch {};
        w.print("{d}", .{fill}) catch {};
    }
}

/// Build ingest args: doc "doc1" with three chunks whose embeddings are uniform
/// vectors at 0.1, 0.5, 0.9 so semantic ranking is predictable.
fn ingestArgs(a: std.mem.Allocator) []u8 {
    const contents = [_][]const u8{
        "the cat sat on the mat",
        "neural networks learn vector representations",
        "deep learning models scale with data",
    };
    const fills = [_]f32{ 0.1, 0.5, 0.9 };

    var aw = Writer.Allocating.init(a);
    const w = &aw.writer;
    w.writeAll("{\"id\":\"doc1\",\"title\":\"ML\",\"metadata\":\"{}\",\"chunks\":[") catch {};
    inline for (0..3) |i| {
        if (i > 0) w.writeByte(',') catch {};
        w.print("{{\"content\":\"{s}\",\"ordinal\":{d},\"embedding\":[", .{ contents[i], i }) catch {};
        writeVec(w, fills[i]);
        w.writeAll("]}") catch {};
    }
    w.writeAll("]}") catch {};
    return aw.toOwnedSlice() catch unreachable;
}

/// Build a search args JSON with the given lexical query and a full 384-dim
/// query vector, plus an extras fragment (e.g. ",\"mmr\":true").
fn searchArgs(a: std.mem.Allocator, query: []const u8, fill: f32, extras: []const u8) []u8 {
    var aw = Writer.Allocating.init(a);
    const w = &aw.writer;
    w.print("{{\"query\":\"{s}\"{s},\"vector\":[", .{ query, extras }) catch {};
    writeVec(w, fill);
    w.writeAll("]}") catch {};
    return aw.toOwnedSlice() catch unreachable;
}

test "rag_integration: ingest -> stats -> get -> delete" {
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

    const ing = rag.ingestDocument(io, a, &conn, parseJson(a, ingestArgs(a)));
    try testing.expect(!ing.is_error);
    try testing.expect(std.mem.indexOf(u8, ing.text, "\"chunks_ingested\":3") != null);

    const st = rag.stats(io, a, &conn, null);
    try testing.expect(!st.is_error);
    try testing.expect(std.mem.indexOf(u8, st.text, "\"document_count\":1") != null);
    try testing.expect(std.mem.indexOf(u8, st.text, "\"chunk_count\":3") != null);

    const got = rag.getDocument(io, a, &conn, parseJson(a, "{\"id\":\"doc1\"}"));
    try testing.expect(!got.is_error);
    try testing.expect(std.mem.indexOf(u8, got.text, "doc1") != null);

    const del = rag.deleteDocument(io, a, &conn, parseJson(a, "{\"id\":\"doc1\"}"));
    try testing.expect(!del.is_error);
    try testing.expect(std.mem.indexOf(u8, del.text, "\"chunks_deleted\":3") != null);

    const st2 = rag.stats(io, a, &conn, null);
    try testing.expect(std.mem.indexOf(u8, st2.text, "\"document_count\":0") != null);
}

test "rag_integration: hybrid search surfaces the relevant chunk" {
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

    try testing.expect(!rag.ingestDocument(io, a, &conn, parseJson(a, ingestArgs(a))).is_error);

    // Lexical "neural" + a vector near the 0.5 chunk both point at the
    // "neural networks" chunk, so RRF must rank it first.
    const res = rag.search(io, a, &conn, parseJson(a, searchArgs(a, "neural", 0.5, ",\"k\":3")));
    try testing.expect(!res.is_error);
    const parsed = try std.json.parseFromSlice(Value, a, res.text, .{});
    const results = parsed.value.object.get("results").?.array;
    try testing.expect(results.items.len >= 1);
    try testing.expectEqualStrings("doc1#1", results.items[0].object.get("id").?.string);
    try testing.expect(std.mem.indexOf(u8, results.items[0].object.get("content").?.string, "neural") != null);
}

test "rag_integration: vector search with cosine metric" {
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

    try testing.expect(!rag.ingestDocument(io, a, &conn, parseJson(a, ingestArgs(a))).is_error);

    var aw = Writer.Allocating.init(a);
    aw.writer.writeAll("{\"metric\":\"cosine\",\"k\":3,\"vector\":[") catch {};
    writeVec(&aw.writer, 0.9);
    aw.writer.writeAll("]}") catch {};
    const res = rag.vectorSearch(io, a, &conn, parseJson(a, aw.toOwnedSlice() catch unreachable));
    try testing.expect(!res.is_error);
    try testing.expect(std.mem.indexOf(u8, res.text, "doc1#") != null);
}

test "rag_integration: MMR re-ranking runs end-to-end" {
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

    try testing.expect(!rag.ingestDocument(io, a, &conn, parseJson(a, ingestArgs(a))).is_error);

    const res = rag.search(io, a, &conn, parseJson(a, searchArgs(a, "learning", 0.7, ",\"k\":2,\"mmr\":true,\"lambda\":0.3")));
    try testing.expect(!res.is_error);
    const parsed = try std.json.parseFromSlice(Value, a, res.text, .{});
    try testing.expect(parsed.value.object.get("results").?.array.items.len >= 1);
}

test "rag_integration: chunk_text handler serializes windows" {
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

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const res = rag.chunkText(io, a, &conn, parseJson(a, "{\"text\":\"a b c d e f\",\"chunkSize\":3,\"overlap\":1}"));
    try testing.expect(!res.is_error);
    const parsed = try std.json.parseFromSlice(Value, a, res.text, .{});
    try testing.expectEqual(@as(i64, 3), parsed.value.object.get("count").?.integer);
}
