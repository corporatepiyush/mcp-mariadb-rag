//! RAG tool handlers: ingest (chunk + store), retrieval (hybrid lexical +
//! semantic with RRF and optional MMR), and document CRUD.
//!
//! Embeddings are caller-supplied (Anthropic has no embeddings endpoint; hosts
//! typically use a dedicated embedder such as Voyage AI). This layer owns
//! chunking, storage, fusion, and re-ranking — all the database-side RAG work.
//!
//! Per Agent.md: one request arena owns every allocation; retrieval fuses in
//! Zig (SIMD cosine / RRF / MMR) rather than fragile nested-window SQL; batch
//! writes collapse to a single multi-row statement; containers are pre-sized
//! from known counts.

const std = @import("std");
const pool = @import("../pool.zig");
const json = @import("../json.zig");
const mod = @import("mod.zig");
const schema = @import("../rag/schema.zig");
const query = @import("../rag/query.zig");
const chunk = @import("../rag/chunk.zig");
const fusion = @import("../rag/fusion.zig");
const retrieve = @import("../rag/retrieve.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const PooledConn = pool.PooledConnection;
const Payload = mod.Payload;
const Writer = std.Io.Writer;

const dims = schema.embedding_dims;

// ── Param helpers ─────────────────────────────────────────────────────

/// Read an unsigned integer param accepting either a JSON number or a numeric
/// string (MCP clients send both forms).
fn getUintParam(args: ?Value, name: []const u8, default: u64) u64 {
    const a = args orelse return default;
    if (a != .object) return default;
    const v = a.object.get(name) orelse return default;
    return switch (v) {
        .integer => |n| if (n >= 0) @intCast(n) else default,
        .string => |s| std.fmt.parseUnsigned(u64, s, 10) catch default,
        else => default,
    };
}

fn getFloatParam(args: ?Value, name: []const u8, default: f32) f32 {
    const a = args orelse return default;
    if (a != .object) return default;
    const v = a.object.get(name) orelse return default;
    return switch (v) {
        .float => |f| @floatCast(f),
        .integer => |n| @floatFromInt(n),
        .string => |s| std.fmt.parseFloat(f32, s) catch default,
        else => default,
    };
}

const EmbedError = error{ BadDim, NotNumber, OutOfMemory };

/// Parse a JSON array into an owned `[dims]`-length embedding. The 384-dim BLOB
/// column requires an exact match, so a wrong length is a hard error.
fn embeddingExact(allocator: Allocator, val: Value) EmbedError![]f32 {
    if (val != .array) return error.NotNumber;
    const arr = val.array;
    if (arr.items.len != dims) return error.BadDim;
    const out = try allocator.alloc(f32, dims);
    for (arr.items, 0..) |item, i| {
        out[i] = switch (item) {
            .float => |f| @floatCast(f),
            .integer => |n| @floatFromInt(n),
            else => return error.NotNumber,
        };
    }
    return out;
}

/// Interpret raw f32 blob bytes as a float slice.
fn embFromBlob(allocator: Allocator, blob: []const u8) ![]f32 {
    const n = blob.len / @sizeOf(f32);
    if (n == 0 or blob.len % @sizeOf(f32) != 0) return error.InvalidBlob;
    const out = try allocator.alloc(f32, n);
    @memcpy(std.mem.sliceAsBytes(out), blob);
    return out;
}

fn jsonStr(w: *Writer, s: []const u8) !void {
    try json.writeQuoted(w, s);
}

// ── Ingestion ─────────────────────────────────────────────────────────

/// Pure chunking tool: text -> windows. No DB write; the caller embeds each
/// chunk and feeds them to `rag_ingest_document`.
pub fn chunkText(_: Io, allocator: Allocator, _: *PooledConn, args: ?Value) Payload {
    const text = mod.getStringParam(args, "text") orelse return mod.errPayload("Missing 'text' parameter");
    const size = getUintParam(args, "chunkSize", 200);
    const overlap = getUintParam(args, "overlap", 40);

    const chunks = chunk.chunk(allocator, text, .{
        .chunk_size = @intCast(size),
        .overlap = @intCast(overlap),
    }) catch return mod.errPayload("Chunking failed");

    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll("{\"chunks\":[") catch return mod.errPayload("Serialization error");
    for (chunks, 0..) |c, i| {
        if (i > 0) w.writeByte(',') catch return mod.errPayload("Serialization error");
        w.print("{{\"ordinal\":{d},\"tokenCount\":{d},\"content\":", .{ c.ordinal, c.token_count }) catch
            return mod.errPayload("Serialization error");
        jsonStr(w, c.content) catch return mod.errPayload("Serialization error");
        w.writeByte('}') catch return mod.errPayload("Serialization error");
    }
    w.print("],\"count\":{d}}}", .{chunks.len}) catch return mod.errPayload("Serialization error");
    return .{ .text = aw.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
}

/// Parse the shared `chunks` array (objects with content + embedding, optional
/// id/ordinal/tokenCount) into ChunkRow values keyed under `document_id`.
fn parseChunkRows(allocator: Allocator, document_id: []const u8, items: []const Value) ![]query.ChunkRow {
    const rows = try allocator.alloc(query.ChunkRow, items.len);
    for (items, 0..) |item, i| {
        if (item != .object) return error.BadChunk;
        const obj = item.object;
        const content_v = obj.get("content") orelse return error.BadChunk;
        if (content_v != .string) return error.BadChunk;
        const emb_v = obj.get("embedding") orelse return error.BadChunk;
        const vector = try embeddingExact(allocator, emb_v);

        const ordinal: u64 = if (obj.get("ordinal")) |o| switch (o) {
            .integer => |n| if (n >= 0) @intCast(n) else i,
            else => i,
        } else i;

        const id: []const u8 = if (obj.get("id")) |idv|
            (if (idv == .string) idv.string else try std.fmt.allocPrint(allocator, "{s}#{d}", .{ document_id, ordinal }))
        else
            try std.fmt.allocPrint(allocator, "{s}#{d}", .{ document_id, ordinal });

        const token_count: u64 = if (obj.get("tokenCount")) |t| switch (t) {
            .integer => |n| if (n >= 0) @intCast(n) else 0,
            else => 0,
        } else 0;

        rows[i] = .{
            .id = id,
            .document_id = document_id,
            .ordinal = ordinal,
            .content = content_v.string,
            .token_count = token_count,
            .vector = vector,
        };
    }
    return rows;
}

fn errFromChunkParse(err: anyerror) Payload {
    return switch (err) {
        error.BadChunk => mod.errPayload("Each chunk needs a string 'content' and 'embedding' array"),
        error.BadDim => mod.errPayload("Each embedding must have exactly 384 dimensions"),
        error.NotNumber => mod.errPayload("Embedding must contain only numbers"),
        else => mod.errPayload("Allocation error"),
    };
}

/// Store a document and all of its (already-embedded) chunks in two statements:
/// one document upsert, one batched chunk upsert.
pub fn ingestDocument(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const id = mod.getStringParam(args, "id") orelse return mod.errPayload("Missing 'id' parameter");
    const chunks_val = mod.getArrayParam(args, "chunks") orelse return mod.errPayload("Missing 'chunks' parameter");
    if (chunks_val.items.len == 0) return mod.errPayload("Empty chunks list");

    const uri = mod.getStringParam(args, "uri") orelse "";
    const title = mod.getStringParam(args, "title") orelse "";
    const metadata = mod.getStringParam(args, "metadata") orelse "{}";

    const rows = parseChunkRows(allocator, id, chunks_val.items) catch |err| return errFromChunkParse(err);

    const doc_sql = mod.renderToOwned(allocator, query.writeUpsertDocument, .{ id, uri, title, metadata, rows.len }) catch
        return mod.errPayload("Allocation error");
    defer allocator.free(doc_sql);
    _ = conn.execute(doc_sql) catch return mod.errPayload("Document upsert failed");

    const chunk_sql = mod.renderToOwned(allocator, query.writeUpsertChunks, .{rows}) catch
        return mod.errPayload("Allocation error");
    defer allocator.free(chunk_sql);
    _ = conn.execute(chunk_sql) catch return mod.errPayload("Chunk upsert failed");

    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll("{\"id\":") catch return mod.errPayload("Serialization error");
    jsonStr(w, id) catch return mod.errPayload("Serialization error");
    w.print(",\"chunks_ingested\":{d}}}", .{rows.len}) catch return mod.errPayload("Serialization error");
    return .{ .text = aw.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
}

/// Upsert chunks for an existing document without touching the document row.
pub fn upsertChunks(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const document_id = mod.getStringParam(args, "documentId") orelse return mod.errPayload("Missing 'documentId' parameter");
    const chunks_val = mod.getArrayParam(args, "chunks") orelse return mod.errPayload("Missing 'chunks' parameter");
    if (chunks_val.items.len == 0) return mod.errPayload("Empty chunks list");

    const rows = parseChunkRows(allocator, document_id, chunks_val.items) catch |err| return errFromChunkParse(err);

    const sql = mod.renderToOwned(allocator, query.writeUpsertChunks, .{rows}) catch
        return mod.errPayload("Allocation error");
    defer allocator.free(sql);
    _ = conn.execute(sql) catch return mod.errPayload("Chunk upsert failed");

    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    aw.writer.print("{{\"chunks_upserted\":{d}}}", .{rows.len}) catch return mod.errPayload("Serialization error");
    return .{ .text = aw.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
}

// ── Retrieval ─────────────────────────────────────────────────────────

/// One retrieved chunk plus the data fusion/MMR needs.
const Candidate = struct {
    id: []const u8,
    document_id: []const u8,
    ordinal: []const u8,
    content: []const u8,
    emb: []const f32,
};

/// Drain a retrieval result set into the candidate map (keyed by id) and append
/// each id, in result order, to `order`. Column layout: 0 id, 1 document_id,
/// 2 ordinal, 3 content, 4 emb-text.
fn collect(
    allocator: Allocator,
    result: pool.QueryResult,
    cmap: *std.StringHashMapUnmanaged(Candidate),
    order: *std.ArrayList([]const u8),
) !void {
    const rows = result.rows orelse return;
    try cmap.ensureUnusedCapacity(allocator, @intCast(rows.len));
    try order.ensureUnusedCapacity(allocator, rows.len);
    for (rows) |row| {
        const id = row.values[0] orelse continue;
        order.appendAssumeCapacity(id);
        if (cmap.contains(id)) continue;
        const emb = embFromBlob(allocator, row.values[4] orelse "") catch &.{};
        cmap.putAssumeCapacity(id, .{
            .id = id,
            .document_id = row.values[1] orelse "",
            .ordinal = row.values[2] orelse "0",
            .content = row.values[3] orelse "",
            .emb = emb,
        });
    }
}

fn writeResult(w: *Writer, c: Candidate, score: f32) !void {
    try w.writeAll("{\"id\":");
    try jsonStr(w, c.id);
    try w.writeAll(",\"documentId\":");
    try jsonStr(w, c.document_id);
    try w.print(",\"ordinal\":{s},\"score\":{d:.6},\"content\":", .{ c.ordinal, score });
    try jsonStr(w, c.content);
    try w.writeByte('}');
}

/// Hybrid retrieval: semantic top-k (vector) ⊕ lexical top-k (LIKE), fused with
/// Reciprocal Rank Fusion, optionally diversified with MMR. At least one of
/// `vector` (query embedding) or `query` (text) must be supplied.
pub fn search(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const query_text = mod.getStringParam(args, "query");
    const vector_val = mod.getArrayParam(args, "vector");
    if (query_text == null and vector_val == null)
        return mod.errPayload("Provide 'vector' (query embedding) and/or 'query' (text)");

    const k = getUintParam(args, "k", 10);
    const vec_k = getUintParam(args, "vecK", 30);
    const text_k = getUintParam(args, "textK", 30);
    const metric = query.Metric.parse(mod.getStringParam(args, "metric"));
    const use_mmr = mod.getBoolParam(args, "mmr", false);
    const lambda = getFloatParam(args, "lambda", 0.5);
    const rrf_k = getFloatParam(args, "rrfK", fusion.default_rrf_k);

    var cmap: std.StringHashMapUnmanaged(Candidate) = .empty;
    defer cmap.deinit(allocator);
    var vec_ids: std.ArrayList([]const u8) = .empty;
    defer vec_ids.deinit(allocator);
    var lex_ids: std.ArrayList([]const u8) = .empty;
    defer lex_ids.deinit(allocator);

    // Semantic candidates: a full streaming scan that keeps the true top-`vec_k`
    // by vector distance (correct recall regardless of corpus size), already
    // ordered nearest-first by the heap selector.
    if (vector_val) |vv| {
        const qvec = embeddingExact(allocator, .{ .array = vv }) catch |err| return switch (err) {
            error.BadDim => mod.errPayload("Query 'vector' must have exactly 384 dimensions"),
            error.NotNumber => mod.errPayload("Query 'vector' must contain only numbers"),
            else => mod.errPayload("Allocation error"),
        };
        const sql = mod.renderToOwned(allocator, query.writeVectorScanAll, .{}) catch
            return mod.errPayload("Allocation error");
        defer allocator.free(sql);
        const matches = retrieve.vectorScanTopK(conn.conn.db, allocator, sql, qvec, metric, vec_k) catch
            return mod.errPayload("Vector query failed");
        cmap.ensureUnusedCapacity(allocator, @intCast(matches.len)) catch return mod.errPayload("Allocation error");
        vec_ids.ensureUnusedCapacity(allocator, matches.len) catch return mod.errPayload("Allocation error");
        for (matches) |m| {
            vec_ids.appendAssumeCapacity(m.id);
            if (!cmap.contains(m.id)) cmap.putAssumeCapacity(m.id, .{
                .id = m.id,
                .document_id = m.document_id,
                .ordinal = m.ordinal,
                .content = m.content,
                .emb = m.emb,
            });
        }
    }

    // Lexical candidates.
    if (query_text) |qt| {
        if (qt.len > 0) {
            const sql = mod.renderToOwned(allocator, query.writeLexicalTopK, .{ qt, text_k }) catch
                return mod.errPayload("Allocation error");
            defer allocator.free(sql);
            const res = conn.query(allocator, sql) catch return mod.errPayload("Lexical query failed");
            collect(allocator, res, &cmap, &lex_ids) catch return mod.errPayload("Allocation error");
        }
    }

    // Reciprocal Rank Fusion over the two ranked id lists.
    const lists = [_][]const []const u8{ vec_ids.items, lex_ids.items };
    const fused = fusion.reciprocalRankFusion(allocator, &lists, rrf_k) catch
        return mod.errPayload("Allocation error");
    if (fused.len == 0) return .{ .text = "{\"results\":[],\"count\":0}", .is_error = false };

    // Determine output order: plain RRF, or MMR-diversified over the fused set.
    const want = @min(k, fused.len);
    var order_idx: []const usize = undefined;
    var owned_idx: ?[]usize = null;
    defer if (owned_idx) |oi| allocator.free(oi);

    if (use_mmr) {
        const embs = allocator.alloc([]const f32, fused.len) catch return mod.errPayload("Allocation error");
        defer allocator.free(embs);
        const rels = allocator.alloc(f32, fused.len) catch return mod.errPayload("Allocation error");
        defer allocator.free(rels);
        for (fused, 0..) |f, i| {
            embs[i] = if (cmap.get(f.id)) |c| c.emb else &.{};
            rels[i] = f.score;
        }
        owned_idx = fusion.mmrSelect(allocator, embs, rels, lambda, want) catch
            return mod.errPayload("Allocation error");
        order_idx = owned_idx.?;
    } else {
        const idx = allocator.alloc(usize, want) catch return mod.errPayload("Allocation error");
        for (0..want) |i| idx[i] = i; // fused is already sorted by score desc
        owned_idx = idx;
        order_idx = idx;
    }

    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll("{\"results\":[") catch return mod.errPayload("Serialization error");
    var emitted: usize = 0;
    for (order_idx) |fi| {
        const f = fused[fi];
        const c = cmap.get(f.id) orelse continue;
        if (emitted > 0) w.writeByte(',') catch return mod.errPayload("Serialization error");
        emitted += 1;
        writeResult(w, c, f.score) catch return mod.errPayload("Serialization error");
    }
    w.print("],\"count\":{d}}}", .{emitted}) catch return mod.errPayload("Serialization error");
    return .{ .text = aw.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
}

/// Pure semantic search over chunks (no lexical/fusion). Streams the whole chunk
/// set through the bounded top-k heap and returns the `k` nearest by vector
/// distance, nearest-first. Output is a `{"results":[…],"count":n}` envelope
/// with each chunk's distance under the metric used.
pub fn vectorSearch(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const vector_val = mod.getArrayParam(args, "vector") orelse return mod.errPayload("Missing 'vector' parameter");
    const k = getUintParam(args, "k", 10);
    const metric = query.Metric.parse(mod.getStringParam(args, "metric"));

    const qvec = embeddingExact(allocator, .{ .array = vector_val }) catch |err| return switch (err) {
        error.BadDim => mod.errPayload("'vector' must have exactly 384 dimensions"),
        error.NotNumber => mod.errPayload("'vector' must contain only numbers"),
        else => mod.errPayload("Allocation error"),
    };
    const sql = mod.renderToOwned(allocator, query.writeVectorScanAll, .{}) catch
        return mod.errPayload("Allocation error");
    defer allocator.free(sql);
    const matches = retrieve.vectorScanTopK(conn.conn.db, allocator, sql, qvec, metric, k) catch
        return mod.errPayload("Query failed");

    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll("{\"results\":[") catch return mod.errPayload("Serialization error");
    for (matches, 0..) |m, i| {
        if (i > 0) w.writeByte(',') catch return mod.errPayload("Serialization error");
        w.writeAll("{\"id\":") catch return mod.errPayload("Serialization error");
        jsonStr(w, m.id) catch return mod.errPayload("Serialization error");
        w.writeAll(",\"documentId\":") catch return mod.errPayload("Serialization error");
        jsonStr(w, m.document_id) catch return mod.errPayload("Serialization error");
        w.print(",\"ordinal\":{s},\"distance\":{d:.6},\"content\":", .{ m.ordinal, m.dist }) catch
            return mod.errPayload("Serialization error");
        jsonStr(w, m.content) catch return mod.errPayload("Serialization error");
        w.writeByte('}') catch return mod.errPayload("Serialization error");
    }
    w.print("],\"count\":{d}}}", .{matches.len}) catch return mod.errPayload("Serialization error");
    return .{ .text = aw.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
}

// ── Document CRUD + stats ─────────────────────────────────────────────

pub fn getDocument(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const id = mod.getStringParam(args, "id") orelse return mod.errPayload("Missing 'id' parameter");
    const sql = mod.renderToOwned(allocator, query.writeGetDocument, .{id}) catch
        return mod.errPayload("Allocation error");
    defer allocator.free(sql);
    const res = conn.query(allocator, sql) catch return mod.errPayload("Query failed");
    return mod.resultPayload(allocator, res);
}

pub fn listDocuments(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const limit: ?u64 = if (mod.getStringParam(args, "limit")) |_| getUintParam(args, "limit", 50) else getUintParam(args, "limit", 50);
    const offset: ?u64 = getUintParam(args, "offset", 0);
    const sql = mod.renderToOwned(allocator, query.writeListDocuments, .{ limit, offset }) catch
        return mod.errPayload("Allocation error");
    defer allocator.free(sql);
    const res = conn.query(allocator, sql) catch return mod.errPayload("Query failed");
    return mod.resultPayload(allocator, res);
}

/// Delete a document and all its chunks (two statements).
pub fn deleteDocument(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const id = mod.getStringParam(args, "id") orelse return mod.errPayload("Missing 'id' parameter");

    const chunk_sql = mod.renderToOwned(allocator, query.writeDeleteChunksByDocument, .{id}) catch
        return mod.errPayload("Allocation error");
    defer allocator.free(chunk_sql);
    const chunks_deleted = conn.execute(chunk_sql) catch return mod.errPayload("Chunk delete failed");

    const doc_sql = mod.renderToOwned(allocator, query.writeDeleteDocument, .{id}) catch
        return mod.errPayload("Allocation error");
    defer allocator.free(doc_sql);
    const docs_deleted = conn.execute(doc_sql) catch return mod.errPayload("Document delete failed");

    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    aw.writer.print("{{\"documents_deleted\":{d},\"chunks_deleted\":{d}}}", .{ docs_deleted, chunks_deleted }) catch
        return mod.errPayload("Serialization error");
    return .{ .text = aw.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
}

pub fn stats(_: Io, allocator: Allocator, conn: *PooledConn, _: ?Value) Payload {
    const sql = mod.renderToOwned(allocator, query.writeRagStatistics, .{}) catch
        return mod.errPayload("Allocation error");
    defer allocator.free(sql);
    const res = conn.query(allocator, sql) catch return mod.errPayload("Query failed");
    const row0 = if (res.rows) |rows| (if (rows.len > 0) rows[0] else null) else null;
    const d_count = if (row0) |r| r.values[0] orelse "0" else "0";
    const c_count = if (row0) |r| r.values[1] orelse "0" else "0";

    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    aw.writer.print("{{\"document_count\":{s},\"chunk_count\":{s}}}", .{ d_count, c_count }) catch
        return mod.errPayload("Serialization error");
    return .{ .text = aw.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
}

// ── Tests (DB-free helper coverage) ───────────────────────────────────

const testing = std.testing;

test "embFromBlob round-trips an f32 array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const orig = [_]f32{ 1, 2.5, -3 };
    const blob = std.mem.sliceAsBytes(&orig);
    const v = try embFromBlob(arena.allocator(), blob);
    try testing.expectEqual(@as(usize, 3), v.len);
    try testing.expectEqual(@as(f32, 1), v[0]);
    try testing.expectEqual(@as(f32, 2.5), v[1]);
    try testing.expectEqual(@as(f32, -3), v[2]);
}

test "embFromBlob handles empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidBlob, embFromBlob(arena.allocator(), ""));
    try testing.expectError(error.InvalidBlob, embFromBlob(arena.allocator(), &[_]u8{ 0, 1, 2 }));
}

/// Build a Value by parsing JSON text (avoids depending on the std.json
/// map/array constructor signatures, which differ across Zig versions).
fn parseValue(a: Allocator, src: []const u8) Value {
    const parsed = std.json.parseFromSlice(Value, a, src, .{}) catch unreachable;
    return parsed.value;
}

/// A JSON array literal of `n` zeros, optionally with a leading non-number.
fn zerosArray(a: Allocator, n: usize, leading_string: bool) []const u8 {
    var aw = Writer.Allocating.init(a);
    const w = &aw.writer;
    w.writeByte('[') catch unreachable;
    for (0..n) |i| {
        if (i > 0) w.writeByte(',') catch unreachable;
        if (i == 0 and leading_string) {
            w.writeAll("\"x\"") catch unreachable;
        } else {
            w.writeByte('0') catch unreachable;
        }
    }
    w.writeByte(']') catch unreachable;
    return aw.toOwnedSlice() catch unreachable;
}

test "embeddingExact enforces dimensionality" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectError(error.BadDim, embeddingExact(a, parseValue(a, "[1.0]")));
    try testing.expectError(error.NotNumber, embeddingExact(a, parseValue(a, zerosArray(a, dims, true))));

    const ok = try embeddingExact(a, parseValue(a, zerosArray(a, dims, false)));
    try testing.expectEqual(@as(usize, dims), ok.len);
}

test "getUintParam accepts number and string forms" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = parseValue(a, "{\"n\":7,\"s\":\"9\"}");
    try testing.expectEqual(@as(u64, 7), getUintParam(args, "n", 1));
    try testing.expectEqual(@as(u64, 9), getUintParam(args, "s", 1));
    try testing.expectEqual(@as(u64, 3), getUintParam(args, "missing", 3));
}

test "fuzz: embFromBlob never panics on random bytes" {
    var prng = std.Random.DefaultPrng.init(0xEEEE);
    const rnd = prng.random();
    var buf: [128]u8 = undefined;

    for (0..500) |_| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const len = rnd.intRangeLessThan(usize, 0, buf.len);
        for (buf[0..len]) |*b| b.* = rnd.int(u8);
        _ = embFromBlob(arena.allocator(), buf[0..len]) catch {};
    }
}
