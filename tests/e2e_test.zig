//! End-to-end tests that drive the **actual built binary** over stdio, exactly
//! as an MCP host would: spawn `zig-out/bin/mcp-rag`, write newline-delimited
//! JSON-RPC requests, close stdin, and assert on the responses.
//!
//! These replace the throwaway shell/Python smoke checks — they are permanent,
//! run under `zig build test`, and exercise the real serialization, transport,
//! storage, index, and trace paths together. Skipped (pass) if the binary
//! hasn't been built yet; `build.zig` makes the test step depend on the install
//! so a normal `zig build test` has it present.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Writer = std.Io.Writer;
const Value = std.json.Value;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const bin_path = "zig-out/bin/mcp-rag";

/// e2e tests spawn the real binary; gated on `MCP_E2E=1` (and the binary being
/// built) so a plain `zig build test` stays fast and hermetic.
fn binExists(io: Io) bool {
    if (getenv("MCP_E2E") == null) return false;
    std.Io.Dir.cwd().access(io, bin_path, .{}) catch return false;
    return true;
}

/// Spawn the binary in stdio mode against `db_path`, send `requests` (each a
/// full JSON-RPC object on its own line), close stdin, and return all stdout.
///
/// The child env is set **explicitly** via `environ_map`: Zig 0.16 spawns from
/// the environment snapshot captured at startup, so a runtime `setenv` would not
/// reach the child. The sqlite dylib is found via the rpath baked
/// into the binary, so a minimal env suffices.
fn drive(allocator: std.mem.Allocator, io: Io, db_path: []const u8, requests: []const u8) ![]u8 {
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("MCP_STDIO", "1");
    try env.put("DATABASE_URL", db_path);

    var child = try std.process.spawn(io, .{
        .argv = &.{bin_path},
        .environ_map = &env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    errdefer _ = child.wait(io) catch {};

    {
        var wbuf: [256]u8 = undefined;
        var fw = child.stdin.?.writer(io, &wbuf);
        try fw.interface.writeAll(requests);
        try fw.interface.flush();
    }
    child.stdin.?.close(io); // EOF → server's read loop ends and it exits
    child.stdin = null;

    var rbuf: [4096]u8 = undefined;
    var fr = child.stdout.?.readerStreaming(io, &rbuf);
    const out = try fr.interface.allocRemaining(allocator, .limited(4 * 1024 * 1024));
    _ = try child.wait(io);
    return out;
}

/// Parse the response line whose `id` matches and return its `result.content[0].text`.
fn resultText(allocator: std.mem.Allocator, stdout: []const u8, id: i64) !?[]const u8 {
    var it = std.mem.splitScalar(u8, stdout, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        const parsed = std.json.parseFromSlice(Value, allocator, trimmed, .{}) catch continue;
        const obj = parsed.value.object;
        const rid = obj.get("id") orelse continue;
        if (rid != .integer or rid.integer != id) continue;
        const result = obj.get("result") orelse return null;
        const content = result.object.get("content") orelse return null;
        const text = content.array.items[0].object.get("text") orelse return null;
        return try allocator.dupe(u8, text.string);
    }
    return null;
}

/// Append a 384-dim uniform embedding `[fill,fill,…]` to `w`.
fn writeEmbedding(w: *Writer, fill: f32) !void {
    try w.writeByte('[');
    for (0..384) |i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{d}", .{fill});
    }
    try w.writeByte(']');
}

fn tmpDb(allocator: std.mem.Allocator, io: Io, name: []const u8) ![]const u8 {
    // Fresh DB per test. The Router derives per-component files (name.kg.db /
    // name.rag.db) from the base, so remove the base AND both component files,
    // each with their -wal/-shm sidecars, or a prior run's data leaks in.
    const cwd = std.Io.Dir.cwd();
    const base = name[0 .. name.len - 3]; // strip ".db"
    inline for (.{ "", ".kg", ".rag" }) |comp| {
        inline for (.{ "", "-wal", "-shm" }) |sidecar| {
            var buf: [256]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "{s}{s}.db{s}", .{ base, comp, sidecar })) |p| {
                cwd.deleteFile(io, p) catch {};
            } else |_| {}
        }
    }
    return std.fmt.allocPrint(allocator, "sqlite:///{s}", .{name});
}

// ── Tests ─────────────────────────────────────────────────────────────

test "e2e: tools/list advertises the RAG + KG tools" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    if (!binExists(io)) return;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const db = try tmpDb(a, io, "/tmp/mcp_e2e_list.db");
    const reqs = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}\n";
    const out = try drive(a, io, db, reqs);

    // tools/list returns its own shape; just assert the key tools are present.
    try testing.expect(std.mem.indexOf(u8, out, "rag_search") != null);
    try testing.expect(std.mem.indexOf(u8, out, "rag_parent_child_chunk") != null);
    try testing.expect(std.mem.indexOf(u8, out, "vector_search") != null);
}

test "e2e: ingest then hybrid search returns the relevant chunk with a trace" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    if (!binExists(io)) return;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var aw = Writer.Allocating.init(a);
    const w = &aw.writer;
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"rag_ingest_document\",\"arguments\":{\"id\":\"doc1\",\"chunks\":[");
    try w.writeAll("{\"content\":\"the cat sat\",\"ordinal\":0,\"embedding\":");
    try writeEmbedding(w, 0.1);
    try w.writeAll("},{\"content\":\"neural networks learn\",\"ordinal\":1,\"embedding\":");
    try writeEmbedding(w, 0.5);
    try w.writeAll("}]}}}\n");
    // hybrid search: lexical "neural" + a vector near the 0.5 chunk, with trace.
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"rag_search\",\"arguments\":{\"query\":\"neural\",\"k\":2,\"trace\":true,\"vector\":");
    try writeEmbedding(w, 0.5);
    try w.writeAll("}}}\n");

    const db = try tmpDb(a, io, "/tmp/mcp_e2e_search.db");
    const out = try drive(a, io, db, aw.written());

    const ingest = (try resultText(a, out, 1)) orelse return error.NoIngestResponse;
    try testing.expect(std.mem.indexOf(u8, ingest, "\"chunks_ingested\":2") != null);

    const search = (try resultText(a, out, 2)) orelse return error.NoSearchResponse;
    const parsed = try std.json.parseFromSlice(Value, a, search, .{});
    const results = parsed.value.object.get("results").?.array;
    try testing.expect(results.items.len >= 1);
    try testing.expectEqualStrings("doc1#1", results.items[0].object.get("id").?.string);
    // trace echoed back with per-stage timing.
    try testing.expect(parsed.value.object.get("trace") != null);
    try testing.expect(std.mem.indexOf(u8, search, "\"totalUs\":") != null);
}

test "e2e: re-ingesting identical content is deduped (skipped)" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    if (!binExists(io)) return;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var aw = Writer.Allocating.init(a);
    const w = &aw.writer;
    inline for (.{ 1, 2 }) |id| {
        try w.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"rag_ingest_document\",\"arguments\":{{\"id\":\"d\",\"chunks\":[{{\"content\":\"alpha\",\"ordinal\":0,\"embedding\":", .{id});
        try writeEmbedding(w, 0.2);
        try w.writeAll("}]}}}\n");
    }

    const db = try tmpDb(a, io, "/tmp/mcp_e2e_dedup.db");
    const out = try drive(a, io, db, aw.written());

    const first = (try resultText(a, out, 1)) orelse return error.NoFirst;
    try testing.expect(std.mem.indexOf(u8, first, "\"chunks_ingested\":1") != null);
    const second = (try resultText(a, out, 2)) orelse return error.NoSecond;
    try testing.expect(std.mem.indexOf(u8, second, "\"skipped\":true") != null);
}

test "e2e: KG vector_search returns valid JSON with a distance column" {
    var threaded: Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    if (!binExists(io)) return;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var aw = Writer.Allocating.init(a);
    const w = &aw.writer;
    // Two embeddings: identical (cosine dist 0) and opposite-ish.
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"upsert_vector_embedding\",\"arguments\":{\"id\":\"v_near\",\"entityName\":\"N\",\"textContent\":\"near\",\"vector\":");
    try writeEmbedding(w, 1.0);
    try w.writeAll("}}}\n");
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"upsert_vector_embedding\",\"arguments\":{\"id\":\"v_far\",\"entityName\":\"F\",\"textContent\":\"far\",\"vector\":");
    try writeEmbedding(w, 0.0);
    try w.writeAll("}}}\n");
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"vector_search\",\"arguments\":{\"metric\":\"cosine\",\"limit\":\"10\",\"vector\":");
    try writeEmbedding(w, 1.0);
    try w.writeAll("}}}\n");

    const db = try tmpDb(a, io, "/tmp/mcp_e2e_kg.db");
    const out = try drive(a, io, db, aw.written());

    const search = (try resultText(a, out, 3)) orelse return error.NoSearch;
    // The bug this guards: the response must be parseable JSON (no raw BLOB),
    // carry a distance column, and rank the identical vector first.
    const parsed = try std.json.parseFromSlice(Value, a, search, .{});
    const cols = parsed.value.object.get("columns").?.array;
    try testing.expectEqualStrings("distance", cols.items[cols.items.len - 1].string);
    const rows = parsed.value.object.get("rows").?.array;
    try testing.expect(rows.items.len >= 2);
    try testing.expectEqualStrings("v_near", rows.items[0].array.items[0].string);
}
