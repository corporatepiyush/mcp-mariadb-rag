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
const index_store = @import("../index/store.zig");
const trace = @import("../observe/trace.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const PooledConn = pool.PooledConnection;
const Payload = mod.Payload;
const Writer = std.Io.Writer;

// Compile-time default; the *active* dimensionality is `schema.embeddingDims()`,
// resolved at startup from MCP_EMBED_DIMS. Used only where a comptime value is
// needed (e.g. the dimension-enforcement unit test).
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

/// Parse a JSON array into an owned embedding of exactly `schema.embeddingDims()`
/// components. Every vector in a corpus must share that width, so a wrong length
/// is a hard error.
fn embeddingExact(allocator: Allocator, val: Value) EmbedError![]f32 {
    if (val != .array) return error.NotNumber;
    const arr = val.array;
    const want = schema.embeddingDims();
    if (arr.items.len != want) return error.BadDim;
    const out = try allocator.alloc(f32, want);
    for (arr.items, 0..) |item, i| {
        out[i] = switch (item) {
            .float => |f| @floatCast(f),
            .integer => |n| @floatFromInt(n),
            else => return error.NotNumber,
        };
    }
    return out;
}

/// Parse an optional document pre-filter from `documentId` (string) or
/// `documentIds` (array of strings). Returns the arena-owned id slice, or null
/// when no filter is supplied. An empty/invalid `documentIds` also yields null
/// (no filter) rather than an error, so a malformed filter degrades to an
/// unscoped search instead of returning nothing.
fn parseDocFilter(allocator: Allocator, args: ?Value) ?[]const []const u8 {
    const a = args orelse return null;
    if (a != .object) return null;
    if (a.object.get("documentId")) |v| {
        if (v == .string and v.string.len > 0) {
            const out = allocator.alloc([]const u8, 1) catch return null;
            out[0] = v.string;
            return out;
        }
    }
    if (a.object.get("documentIds")) |v| {
        if (v == .array and v.array.items.len > 0) {
            var list: std.ArrayList([]const u8) = .empty;
            list.ensureTotalCapacity(allocator, v.array.items.len) catch return null;
            for (v.array.items) |item| {
                if (item == .string and item.string.len > 0) list.appendAssumeCapacity(item.string);
            }
            if (list.items.len == 0) return null;
            return list.items;
        }
    }
    return null;
}

/// Invalidate the ANN index cache after a committed write so the next search
/// rebuilds against the new corpus. No-op when the index is disabled/unset.
fn invalidateIndex() void {
    if (index_store.global()) |st| st.bumpEpoch();
}

/// "<what> must have exactly <N> dimensions" — N is the runtime MCP_EMBED_DIMS,
/// so the message tells the operator the actual configured width.
fn dimErr(allocator: Allocator, what: []const u8) Payload {
    const msg = std.fmt.allocPrint(
        allocator,
        "{s} must have exactly {d} dimensions (MCP_EMBED_DIMS)",
        .{ what, schema.embeddingDims() },
    ) catch return mod.errPayload("Embedding has the wrong dimensionality");
    return .{ .text = msg, .is_error = true };
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
    const strategy = mod.getStringParam(args, "strategy") orelse "window";

    const opts = chunk.Options{ .chunk_size = @intCast(size), .overlap = @intCast(overlap) };
    // "recursive" honours natural boundaries (paragraph→line→sentence→word);
    // "window" is the plain sliding token window. Unknown values fall back to
    // window so a typo degrades gracefully rather than erroring.
    const chunks = (if (std.ascii.eqlIgnoreCase(strategy, "recursive"))
        chunk.recursiveChunk(allocator, text, opts)
    else
        chunk.chunk(allocator, text, opts)) catch return mod.errPayload("Chunking failed");

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
    w.print("],\"count\":{d},\"strategy\":", .{chunks.len}) catch return mod.errPayload("Serialization error");
    jsonStr(w, strategy) catch return mod.errPayload("Serialization error");
    w.writeByte('}') catch return mod.errPayload("Serialization error");
    return .{ .text = aw.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
}

/// Parent-child chunking: small retrieval children plus the larger parent each
/// was cut from. The host embeds the children, retrieves on them, then expands a
/// hit to its `parentOrdinal` for generation context.
pub fn parentChildText(_: Io, allocator: Allocator, _: *PooledConn, args: ?Value) Payload {
    const text = mod.getStringParam(args, "text") orelse return mod.errPayload("Missing 'text' parameter");
    const pc = chunk.parentChildChunk(allocator, text, .{
        .parent_size = @intCast(getUintParam(args, "parentSize", 400)),
        .child_size = @intCast(getUintParam(args, "childSize", 100)),
        .child_overlap = @intCast(getUintParam(args, "childOverlap", 20)),
    }) catch return mod.errPayload("Chunking failed");

    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll("{\"parents\":[") catch return mod.errPayload("Serialization error");
    for (pc.parents, 0..) |p, i| {
        if (i > 0) w.writeByte(',') catch return mod.errPayload("Serialization error");
        w.print("{{\"ordinal\":{d},\"tokenCount\":{d},\"content\":", .{ p.ordinal, p.token_count }) catch
            return mod.errPayload("Serialization error");
        jsonStr(w, p.content) catch return mod.errPayload("Serialization error");
        w.writeByte('}') catch return mod.errPayload("Serialization error");
    }
    w.writeAll("],\"children\":[") catch return mod.errPayload("Serialization error");
    for (pc.children, 0..) |c, i| {
        if (i > 0) w.writeByte(',') catch return mod.errPayload("Serialization error");
        w.print("{{\"ordinal\":{d},\"parentOrdinal\":{d},\"tokenCount\":{d},\"content\":", .{ c.ordinal, c.parent_ordinal, c.token_count }) catch
            return mod.errPayload("Serialization error");
        jsonStr(w, c.content) catch return mod.errPayload("Serialization error");
        w.writeByte('}') catch return mod.errPayload("Serialization error");
    }
    w.print("],\"parentCount\":{d},\"childCount\":{d}}}", .{ pc.parents.len, pc.children.len }) catch
        return mod.errPayload("Serialization error");
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

fn errFromChunkParse(allocator: Allocator, err: anyerror) Payload {
    return switch (err) {
        error.BadChunk => mod.errPayload("Each chunk needs a string 'content' and 'embedding' array"),
        error.BadDim => dimErr(allocator, "Each embedding"),
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

    const rows = parseChunkRows(allocator, id, chunks_val.items) catch |err| return errFromChunkParse(allocator, err);

    const doc_sql = mod.renderToOwned(allocator, query.writeUpsertDocument, .{ id, uri, title, metadata, rows.len }) catch
        return mod.errPayload("Allocation error");
    defer allocator.free(doc_sql);
    const chunk_sql = mod.renderToOwned(allocator, query.writeUpsertChunks, .{rows}) catch
        return mod.errPayload("Allocation error");
    defer allocator.free(chunk_sql);

    // Atomic: document row and its chunks commit together (or not at all), in one
    // transaction (one fsync instead of two).
    conn.begin() catch return mod.errPayload("Failed to begin transaction");
    _ = conn.execute(doc_sql) catch {
        conn.rollback();
        return mod.errPayload("Document upsert failed");
    };
    _ = conn.execute(chunk_sql) catch {
        conn.rollback();
        return mod.errPayload("Chunk upsert failed");
    };
    conn.commit() catch {
        conn.rollback();
        return mod.errPayload("Failed to commit transaction");
    };
    invalidateIndex();

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

    const rows = parseChunkRows(allocator, document_id, chunks_val.items) catch |err| return errFromChunkParse(allocator, err);

    const sql = mod.renderToOwned(allocator, query.writeUpsertChunks, .{rows}) catch
        return mod.errPayload("Allocation error");
    defer allocator.free(sql);
    _ = conn.execute(sql) catch return mod.errPayload("Chunk upsert failed");
    invalidateIndex();

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
pub fn search(io: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const query_text = mod.getStringParam(args, "query");
    const vector_val = mod.getArrayParam(args, "vector");
    if (query_text == null and vector_val == null)
        return mod.errPayload("Provide 'vector' (query embedding) and/or 'query' (text)");

    var tr = trace.Trace.start(io);
    const want_trace = mod.getBoolParam(args, "trace", false);

    const k = getUintParam(args, "k", 10);
    const vec_k = getUintParam(args, "vecK", 30);
    const text_k = getUintParam(args, "textK", 30);
    const metric = query.Metric.parse(mod.getStringParam(args, "metric"));
    const use_mmr = mod.getBoolParam(args, "mmr", false);
    const lambda = getFloatParam(args, "lambda", 0.5);
    const rrf_k = getFloatParam(args, "rrfK", fusion.default_rrf_k);
    // Optional metadata pre-filter: restrict both retrieval arms to a document
    // set before scoring (uses idx_chunk_doc on the vector arm).
    const doc_filter = parseDocFilter(allocator, args);

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
            error.BadDim => dimErr(allocator, "Query 'vector'"),
            error.NotNumber => mod.errPayload("Query 'vector' must contain only numbers"),
            else => mod.errPayload("Allocation error"),
        };
        const sql = (if (doc_filter) |ids|
            mod.renderToOwned(allocator, query.writeVectorScanByDocuments, .{ids})
        else
            mod.renderToOwned(allocator, query.writeVectorScanAll, .{})) catch
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
    tr.lap("vector", vec_ids.items.len);

    // Lexical candidates.
    if (query_text) |qt| {
        if (qt.len > 0) {
            const sql = mod.renderToOwned(allocator, query.writeLexicalTopK, .{ qt, text_k, doc_filter }) catch
                return mod.errPayload("Allocation error");
            defer allocator.free(sql);
            const res = conn.query(allocator, sql) catch return mod.errPayload("Lexical query failed");
            collect(allocator, res, &cmap, &lex_ids) catch return mod.errPayload("Allocation error");
        }
    }
    tr.lap("lexical", lex_ids.items.len);

    // Reciprocal Rank Fusion over the two ranked id lists.
    const lists = [_][]const []const u8{ vec_ids.items, lex_ids.items };
    const fused = fusion.reciprocalRankFusion(allocator, &lists, rrf_k) catch
        return mod.errPayload("Allocation error");
    tr.lap("fusion", fused.len);
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
    tr.lap(if (use_mmr) "mmr" else "select", emitted);
    w.print("],\"count\":{d}", .{emitted}) catch return mod.errPayload("Serialization error");
    if (want_trace) {
        w.writeAll(",\"trace\":") catch return mod.errPayload("Serialization error");
        tr.writeJson(w) catch return mod.errPayload("Serialization error");
    }
    w.writeByte('}') catch return mod.errPayload("Serialization error");

    logTrace(&tr);
    return .{ .text = aw.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
}

/// Emit the trace as one structured `info` line (best-effort; never fails a
/// request over a log-formatting hiccup).
fn logTrace(tr: *const trace.Trace) void {
    var buf: [256]u8 = undefined;
    var w = Writer.fixed(&buf);
    tr.writeLog(&w) catch return;
    std.log.scoped(.rag).info("rag_search {s}", .{w.buffered()});
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
        error.BadDim => dimErr(allocator, "'vector'"),
        error.NotNumber => mod.errPayload("'vector' must contain only numbers"),
        else => mod.errPayload("Allocation error"),
    };
    const doc_filter = parseDocFilter(allocator, args);

    // HNSW fast path: O(log N) instead of the O(N) scan, when the index is
    // enabled, the request has no document filter (the graph isn't scoped), and
    // the request metric matches the index's build metric. Any miss falls
    // through to the always-correct flat scan below.
    if (doc_filter == null) {
        if (index_store.global()) |st| {
            const metric_matches = (st.metric() == .cosine) == (metric == .cosine);
            if (st.enabled() and metric_matches) {
                if (st.search(conn.conn.db, allocator, qvec, k)) |hits| {
                    return hnswResultPayload(allocator, conn, hits);
                }
            }
        }
    }

    const sql = (if (doc_filter) |ids|
        mod.renderToOwned(allocator, query.writeVectorScanByDocuments, .{ids})
    else
        mod.renderToOwned(allocator, query.writeVectorScanAll, .{})) catch
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

/// Emit the `{"results":[…]}` envelope from HNSW hits, hydrating
/// content/document/ordinal in one round-trip. Mirrors the flat-scan shape with
/// an `"index":"hnsw"` marker so callers can observe which path served them.
fn hnswResultPayload(allocator: Allocator, conn: *PooledConn, hits: []const index_store.Hit) Payload {
    const ids = allocator.alloc([]const u8, hits.len) catch return mod.errPayload("Allocation error");
    for (hits, 0..) |h, i| ids[i] = h.id;
    var rows = retrieve.fetchByIds(conn.conn.db, allocator, ids) catch return mod.errPayload("Query failed");

    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll("{\"results\":[") catch return mod.errPayload("Serialization error");
    for (hits, 0..) |h, i| {
        const r = rows.get(h.id) orelse retrieve.RowData{ .document_id = "", .ordinal = "0", .content = "" };
        if (i > 0) w.writeByte(',') catch return mod.errPayload("Serialization error");
        w.writeAll("{\"id\":") catch return mod.errPayload("Serialization error");
        jsonStr(w, h.id) catch return mod.errPayload("Serialization error");
        w.writeAll(",\"documentId\":") catch return mod.errPayload("Serialization error");
        jsonStr(w, r.document_id) catch return mod.errPayload("Serialization error");
        w.print(",\"ordinal\":{s},\"distance\":{d:.6},\"content\":", .{ r.ordinal, h.dist }) catch
            return mod.errPayload("Serialization error");
        jsonStr(w, r.content) catch return mod.errPayload("Serialization error");
        w.writeByte('}') catch return mod.errPayload("Serialization error");
    }
    w.print("],\"count\":{d},\"index\":\"hnsw\"}}", .{hits.len}) catch return mod.errPayload("Serialization error");
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
    const doc_sql = mod.renderToOwned(allocator, query.writeDeleteDocument, .{id}) catch
        return mod.errPayload("Allocation error");
    defer allocator.free(doc_sql);

    // Atomic: chunks and the document row are removed together.
    conn.begin() catch return mod.errPayload("Failed to begin transaction");
    const chunks_deleted = conn.execute(chunk_sql) catch {
        conn.rollback();
        return mod.errPayload("Chunk delete failed");
    };
    const docs_deleted = conn.execute(doc_sql) catch {
        conn.rollback();
        return mod.errPayload("Document delete failed");
    };
    conn.commit() catch {
        conn.rollback();
        return mod.errPayload("Failed to commit transaction");
    };
    invalidateIndex();

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

test "embeddingExact honours the runtime MCP_EMBED_DIMS width" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Switch the active width to 1024 (e.g. a Voyage embedder), then restore so
    // the global doesn't leak into other tests.
    const saved = schema.embeddingDims();
    defer schema.setEmbeddingDims(saved);
    schema.setEmbeddingDims(1024);

    // The old 384-wide vector is now rejected; a 1024-wide one is accepted.
    try testing.expectError(error.BadDim, embeddingExact(a, parseValue(a, zerosArray(a, 384, false))));
    const ok = try embeddingExact(a, parseValue(a, zerosArray(a, 1024, false)));
    try testing.expectEqual(@as(usize, 1024), ok.len);

    // setEmbeddingDims(0) is ignored — validation can't be disabled by a typo.
    schema.setEmbeddingDims(0);
    try testing.expectEqual(@as(usize, 1024), schema.embeddingDims());
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
