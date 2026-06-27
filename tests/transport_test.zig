//! Full-stack transport tests: drive `server.handleRequest` — the exact entry
//! point the stdio/HTTP transports call — through JSON-RPC parsing, tool
//! dispatch, the action handlers, SQL generation, and a live SQLite pool, then
//! back out through response serialization.
//!
//! This is the layer the (subprocess) e2e tests cover, but in-process: hermetic,
//! fast, and — crucially — fuzzable. The generative tests feed random bytes,
//! random tool names, and random-but-well-typed RAG/KG payloads to prove the
//! whole stack never panics and always emits parseable JSON.
//!
//! Memory discipline mirrors the real transport: every request gets its own
//! arena (`server.handleRequest` does not free intermediates — it relies on the
//! caller's arena), so each call here runs inside an arena that is reset/freed,
//! and the suite runs under `testing.allocator` leak detection.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Value = std.json.Value;

const server = @import("../src/server.zig");
const pool_mod = @import("../src/pool.zig");
const config_mod = @import("../src/config.zig");
const schema_kg = @import("../src/kg/schema.zig");
const schema_rag = @import("../src/rag/schema.zig");

// ── Fixture ───────────────────────────────────────────────────────────

const Fixture = struct {
    threaded: Io.Threaded,
    router: pool_mod.Router,
    config: config_mod.Config,

    fn init(self: *Fixture) !void {
        self.threaded = .init(testing.allocator, .{});
        // Shared-cache in-memory DB per component pool (same underlying DB, so
        // schema is visible across both); min_size>=1 keeps it alive.
        const opts = pool_mod.Options{
            .min_size = 1,
            .max_size = 4,
            .tls = .{ .enforce = false, .verify = false, .ca_path = null },
        };
        self.router = .{
            .kg = try pool_mod.ConnectionPool.init(self.threaded.io(), testing.allocator, "sqlite://", opts),
            .rag = try pool_mod.ConnectionPool.init(self.threaded.io(), testing.allocator, "sqlite://", opts),
        };
        self.config = makeConfig();
        try self.initSchema();
    }

    fn deinit(self: *Fixture) void {
        self.router.close();
        self.config.deinit(testing.allocator);
        self.threaded.deinit();
    }

    fn io(self: *Fixture) Io {
        return self.threaded.io();
    }

    fn initSchema(self: *Fixture) !void {
        // Shared in-memory DB across both component pools, so applying both
        // schema scripts on one connection makes every table visible.
        var conn = try self.router.acquire(.rag);
        defer conn.deinit();
        try conn.executeScript(schema_kg.ddl);
        try conn.executeScript(schema_rag.ddl);
    }

    /// Invoke `handleRequest` with `body` inside a fresh arena, returning the
    /// response duped into `out` (caller-owned) or null. The arena (and every
    /// intermediate allocation) is released before returning.
    fn request(self: *Fixture, out: std.mem.Allocator, body: []const u8) !?[]const u8 {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const resp = server.handleRequest(self.io(), arena.allocator(), body, &self.router, &self.config) orelse return null;
        return try out.dupe(u8, resp);
    }

    /// Build a `tools/call` body and return the inner result text (the handler's
    /// JSON payload), duped into `out`.
    fn call(self: *Fixture, out: std.mem.Allocator, tool: []const u8, args_json: []const u8) !?[]const u8 {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const body = try std.fmt.allocPrint(a,
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}",
            .{ tool, args_json });
        const resp = server.handleRequest(self.io(), a, body, &self.router, &self.config) orelse return null;
        // Unwrap result.content[0].text.
        const parsed = std.json.parseFromSlice(Value, a, resp, .{}) catch return try out.dupe(u8, resp);
        const result = parsed.value.object.get("result") orelse return try out.dupe(u8, resp);
        const text = result.object.get("content").?.array.items[0].object.get("text").?.string;
        return try out.dupe(u8, text);
    }
};

fn makeConfig() config_mod.Config {
    return .{
        .database_url = testing.allocator.dupe(u8, "sqlite://") catch unreachable,
        .server = .{
            .host = testing.allocator.dupe(u8, "127.0.0.1") catch unreachable,
            .port = 3000,
            .http_port = 3001,
            .request_timeout_secs = 30,
            .access_mode = .unrestricted,
            .auth_token = null,
            .allow_url_import = false,
            .stdio = true,
            .log_level = testing.allocator.dupe(u8, "info") catch unreachable,
            .enable_metrics = false,
            .metrics_port = 9090,
        },
        .pool = .{ .min_size = 1, .max_size = 4, .queue_timeout_secs = 10, .create_timeout_secs = 5 },
        .tls = .{ .enforce = false, .verify = false, .ca_path = null },
    };
}

/// Append a 384-dim uniform embedding to `w`.
fn writeEmbedding(w: *std.Io.Writer, fill: f32) !void {
    try w.writeByte('[');
    for (0..384) |i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{d}", .{fill});
    }
    try w.writeByte(']');
}

fn ingestBody(a: std.mem.Allocator, id: []const u8, fills: []const f32) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(a);
    const w = &aw.writer;
    try w.print("{{\"id\":\"{s}\",\"chunks\":[", .{id});
    for (fills, 0..) |f, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"content\":\"chunk {d}\",\"ordinal\":{d},\"embedding\":", .{ i, i });
        try writeEmbedding(w, f);
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    return aw.written();
}

// ── Deterministic full-stack scenarios ────────────────────────────────

test "transport: ingest -> search -> vector_search -> stats end to end" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ing = (try fx.call(a, "rag_ingest_document", try ingestBody(a, "d1", &.{ 0.1, 0.5, 0.9 }))).?;
    try testing.expect(std.mem.indexOf(u8, ing, "\"chunks_ingested\":3") != null);

    var sb = std.Io.Writer.Allocating.init(a);
    try sb.writer.writeAll("{\"query\":\"chunk 1\",\"k\":3,\"vector\":");
    try writeEmbedding(&sb.writer, 0.5);
    try sb.writer.writeByte('}');
    const search = (try fx.call(a, "rag_search", sb.written())).?;
    const parsed = try std.json.parseFromSlice(Value, a, search, .{});
    try testing.expect(parsed.value.object.get("results").?.array.items.len >= 1);

    const stats = (try fx.call(a, "rag_stats", "{}")).?;
    try testing.expect(std.mem.indexOf(u8, stats, "\"chunk_count\":3") != null);
}

test "transport: unknown tool and malformed envelopes are handled, not panicked" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    // Unknown tool -> JSON-RPC error, never null/panic.
    const unknown = (try fx.request(testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"no_such_tool\"}}")).?;
    defer testing.allocator.free(unknown);
    try testing.expect(std.mem.indexOf(u8, unknown, "-32601") != null);

    // Empty / blank bodies -> null (no response).
    try testing.expect((try fx.request(testing.allocator, "")) == null);
    try testing.expect((try fx.request(testing.allocator, "   ")) == null);
}

// ── Fuzzing ───────────────────────────────────────────────────────────

test "fuzz: random bytes as a request body never panic the stack" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    var prng = std.Random.DefaultPrng.init(0x7A11_C0DE);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;

    for (0..3000) |_| {
        const len = rnd.intRangeAtMost(usize, 0, buf.len);
        for (buf[0..len]) |*b| b.* = rnd.int(u8);
        // Must not panic; any returned response is freed.
        if (try fx.request(testing.allocator, buf[0..len])) |resp| testing.allocator.free(resp);
    }
}

test "fuzz: well-formed JSON-RPC with random tool names + random args" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    var prng = std.Random.DefaultPrng.init(0xBADC0FFEE);
    const rnd = prng.random();

    const tools = [_][]const u8{
        "rag_search",           "rag_vector_search", "rag_ingest_document",
        "rag_chunk_text",       "rag_parent_child_chunk", "rag_stats",
        "rag_get_document",     "rag_delete_document", "vector_search",
        "upsert_vector_embedding", "create_entities", "search_nodes",
    };
    const arg_shapes = [_][]const u8{
        "{}",
        "{\"k\":-5}",
        "{\"vector\":[1,2,3]}",
        "{\"vector\":\"notarray\"}",
        "{\"query\":12345}",
        "{\"chunks\":[]}",
        "{\"chunks\":[{\"content\":\"x\"}]}",
        "{\"id\":null,\"k\":\"abc\"}",
        "{\"documentIds\":[1,2,3]}",
        "{\"text\":\"a b c\",\"strategy\":\"recursive\",\"chunkSize\":0}",
        "[]",
        "null",
    };

    for (0..2000) |_| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const tool = tools[rnd.uintLessThan(usize, tools.len)];
        const args = arg_shapes[rnd.uintLessThan(usize, arg_shapes.len)];
        const body = try std.fmt.allocPrint(a,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}",
            .{ rnd.int(u16), tool, args });
        // Whatever comes back must be valid JSON (the transport's contract).
        if (server.handleRequest(fx.io(), a, body, &fx.router, &fx.config)) |resp| {
            const parsed = std.json.parseFromSlice(Value, a, resp, .{}) catch {
                std.debug.print("non-JSON response for {s} {s}: {s}\n", .{ tool, args, resp });
                return error.NonJsonResponse;
            };
            _ = parsed;
        }
    }
}

test "fuzz: generative ingest + search invariants hold over random corpora" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    var prng = std.Random.DefaultPrng.init(0x6E11_5EED);
    const rnd = prng.random();

    // Ingest a handful of documents with random uniform embeddings.
    var doc: usize = 0;
    while (doc < 12) : (doc += 1) {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const n_chunks = rnd.intRangeAtMost(usize, 1, 5);
        const fills = try a.alloc(f32, n_chunks);
        for (fills) |*f| f.* = rnd.float(f32);
        const id = try std.fmt.allocPrint(a, "doc{d}", .{doc});
        const res = (try fx.call(a, "rag_ingest_document", try ingestBody(a, id, fills))).?;
        try testing.expect(std.mem.indexOf(u8, res, "chunks_ingested") != null);
    }

    // Run many random searches; each response must parse and obey invariants.
    for (0..500) |_| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const k = rnd.intRangeAtMost(usize, 1, 50);
        const use_mmr = rnd.boolean();
        const metric = if (rnd.boolean()) "cosine" else "euclidean";
        var sb = std.Io.Writer.Allocating.init(a);
        try sb.writer.print("{{\"k\":{d},\"mmr\":{s},\"metric\":\"{s}\",\"vector\":", .{ k, if (use_mmr) "true" else "false", metric });
        try writeEmbedding(&sb.writer, rnd.float(f32));
        if (rnd.boolean()) try sb.writer.writeAll(",\"query\":\"chunk 0\"");
        try sb.writer.writeByte('}');

        const text = (try fx.call(a, "rag_search", sb.written())).?;
        const parsed = try std.json.parseFromSlice(Value, a, text, .{});
        const results = parsed.value.object.get("results").?.array;
        // Never more than k results; every result has the required fields.
        try testing.expect(results.items.len <= k);
        for (results.items) |r| {
            try testing.expect(r.object.get("id") != null);
            try testing.expect(r.object.get("score") != null);
            try testing.expect(r.object.get("content") != null);
        }
    }
}

test "fuzz: vector_search responses are always valid UTF-8 JSON (KG blob guard)" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();

    var prng = std.Random.DefaultPrng.init(0x4B6_10B);
    const rnd = prng.random();

    // Seed some embeddings, then hammer vector_search with random query vectors
    // and metrics — the response must never contain raw blob bytes.
    for (0..8) |i| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var b = std.Io.Writer.Allocating.init(a);
        try b.writer.print("{{\"id\":\"v{d}\",\"entityName\":\"E{d}\",\"textContent\":\"t{d}\",\"vector\":", .{ i, i, i });
        try writeEmbedding(&b.writer, rnd.float(f32));
        try b.writer.writeByte('}');
        _ = try fx.call(a, "upsert_vector_embedding", b.written());
    }

    for (0..300) |_| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var b = std.Io.Writer.Allocating.init(a);
        try b.writer.print("{{\"metric\":\"{s}\",\"limit\":\"{d}\",\"vector\":", .{ if (rnd.boolean()) "cosine" else "euclidean", rnd.intRangeAtMost(usize, 1, 20) });
        try writeEmbedding(&b.writer, rnd.float(f32));
        try b.writer.writeByte('}');
        const text = (try fx.call(a, "vector_search", b.written())).?;
        try testing.expect(std.unicode.utf8ValidateSlice(text)); // no raw f32 bytes
        _ = try std.json.parseFromSlice(Value, a, text, .{}); // and it parses
    }
}
