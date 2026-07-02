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
pub const json = @import("../json.zig");
const mod = @import("mod.zig");
pub const schema = @import("../rag/schema.zig");
const query = @import("../rag/query.zig");
const chunk = @import("../rag/chunk.zig");
const fusion = @import("../rag/fusion.zig");
const retrieve = @import("../rag/retrieve.zig");
const index_store = @import("../index/store.zig");
const trace = @import("../observe/trace.zig");
const query_cache = @import("../generate/cache.zig");
const config_mod = @import("../config.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const PooledConn = pool.PooledConnection;
const Payload = mod.Payload;
const Writer = std.Io.Writer;

// Compile-time default; the *active* dimensionality is `schema.embeddingDims()`,
// resolved at startup from MCP_EMBED_DIMS. Used only where a comptime value is
// needed (e.g. the dimension-enforcement unit test).
pub const dims = schema.embedding_dims;

// ── Param helpers ─────────────────────────────────────────────────────

/// Read an unsigned integer param accepting either a JSON number or a numeric
/// string (MCP clients send both forms).
pub fn getUintParam(args: ?Value, name: []const u8, default: u64) u64 {
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
pub fn embeddingExact(allocator: Allocator, val: Value) EmbedError![]f32 {
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

/// Digest of everything that defines a document's stored state — id, metadata,
/// and every chunk's content + embedding bytes. Hex u64; cheap and collision-
/// safe enough for change detection.
fn contentHash(
    allocator: Allocator,
    id: []const u8,
    uri: []const u8,
    title: []const u8,
    metadata: []const u8,
    rows: []const query.ChunkRow,
) ![]const u8 {
    var h = std.hash.Wyhash.init(0xD0C_15A_FE);
    h.update(id);
    h.update(uri);
    h.update(title);
    h.update(metadata);
    for (rows) |r| {
        h.update(r.content);
        h.update(std.mem.sliceAsBytes(r.vector));
        h.update("\x00"); // field delimiter
    }
    return std.fmt.allocPrint(allocator, "{x}", .{h.final()});
}

/// True iff the document already exists with exactly this `hash`.
fn documentHashMatches(allocator: Allocator, conn: *PooledConn, id: []const u8, hash: []const u8) bool {
    const sql = mod.renderToOwned(allocator, query.writeGetDocumentHash, .{id}) catch return false;
    defer allocator.free(sql);
    const res = conn.query(allocator, sql) catch return false;
    const rows = res.rows orelse return false;
    if (rows.len == 0) return false;
    const existing = rows[0].values[0] orelse return false;
    return std.mem.eql(u8, existing, hash);
}

/// Invalidate derived caches after a committed write: the ANN index rebuilds on
/// the next search, and stale cached answers are dropped. Both are no-ops when
/// unset/disabled.
fn invalidateIndex() void {
    if (index_store.global()) |st| st.bumpEpoch();
    if (query_cache.global()) |qc| qc.clear();
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
pub fn embFromBlob(allocator: Allocator, blob: []const u8) ![]f32 {
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

    // Content-hash dedup: if this id already holds identical content (chunks +
    // metadata), skip the write and the index/cache invalidation entirely.
    const hash = contentHash(allocator, id, uri, title, metadata, rows) catch
        return mod.errPayload("Allocation error");
    if (documentHashMatches(allocator, conn, id, hash)) {
        var aw = Writer.Allocating.init(allocator);
        defer aw.deinit();
        const w = &aw.writer;
        w.writeAll("{\"id\":") catch return mod.errPayload("Serialization error");
        jsonStr(w, id) catch return mod.errPayload("Serialization error");
        w.print(",\"chunks_ingested\":0,\"skipped\":true}}", .{}) catch return mod.errPayload("Serialization error");
        return .{ .text = aw.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
    }

    const doc_sql = mod.renderToOwned(allocator, query.writeUpsertDocument, .{ id, uri, title, metadata, rows.len, hash }) catch
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

    // Tier-scaled server-side caps (PLAN §6): clamp per-request knobs so a small
    // build can't be driven past its budget. The candidate ceiling bounds each
    // retrieval arm; `k` is bounded by max_k.
    const caps = config_mod.active();
    const cap_k: u64 = if (caps) |c| c.max_k else std.math.maxInt(u64);
    const cap_cand: u64 = if (caps) |c| c.max_candidates else std.math.maxInt(u64);

    const k = @min(getUintParam(args, "k", 10), cap_k);
    const vec_k = @min(getUintParam(args, "vecK", 30), cap_cand);
    const text_k = @min(getUintParam(args, "textK", 30), cap_cand);
    const metric = query.Metric.parse(mod.getStringParam(args, "metric"));
    const use_mmr = mod.getBoolParam(args, "mmr", false);
    const lambda = getFloatParam(args, "lambda", 0.5);
    const rrf_k = getFloatParam(args, "rrfK", fusion.default_rrf_k);
    // Optional metadata pre-filter: restrict both retrieval arms to a document
    // set before scoring (uses idx_chunk_doc on the vector arm).
    const doc_filter = parseDocFilter(allocator, args);

    // Parse the query embedding once (the cache key and the vector arm share it).
    const qvec: ?[]f32 = if (vector_val) |vv| (embeddingExact(allocator, .{ .array = vv }) catch |err| return switch (err) {
        error.BadDim => dimErr(allocator, "Query 'vector'"),
        error.NotNumber => mod.errPayload("Query 'vector' must contain only numbers"),
        else => mod.errPayload("Allocation error"),
    }) else null;

    // Semantic cache: a near-identical prior query with identical parameters
    // returns its cached response, skipping retrieval entirely. Bypassed when a
    // trace is requested so timings always reflect a real run.
    const sig = paramSig(query_text, k, vec_k, text_k, metric, use_mmr, lambda, rrf_k, doc_filter);
    if (!want_trace) {
        if (qvec) |qv| if (query_cache.global()) |qc| {
            if (qc.get(allocator, qv, sig)) |cached| return .{ .text = cached, .is_error = false };
        };
    }

    var cmap: std.StringHashMapUnmanaged(Candidate) = .empty;
    defer cmap.deinit(allocator);
    var vec_ids: std.ArrayList([]const u8) = .empty;
    defer vec_ids.deinit(allocator);
    var lex_ids: std.ArrayList([]const u8) = .empty;
    defer lex_ids.deinit(allocator);

    // Semantic candidates: a full streaming scan that keeps the true top-`vec_k`
    // by vector distance (correct recall regardless of corpus size), already
    // ordered nearest-first by the heap selector.
    if (qvec) |qv| {
        const sql = (if (doc_filter) |ids|
            mod.renderToOwned(allocator, query.writeVectorScanByDocuments, .{ids})
        else
            mod.renderToOwned(allocator, query.writeVectorScanAll, .{})) catch
            return mod.errPayload("Allocation error");
        defer allocator.free(sql);
        const matches = retrieve.vectorScanTopK(conn.conn.db, allocator, sql, qv, metric, vec_k) catch
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

    // MMR is O(k·n·d); above the tier's cutoff, fall back to plain RRF order so
    // the diversify step can't dominate latency on a large fused set.
    const cap_mmr_n: usize = if (caps) |c| c.mmr_max_n else std.math.maxInt(usize);
    const do_mmr = use_mmr and fused.len <= cap_mmr_n;

    if (do_mmr) {
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
    tr.lap(if (do_mmr) "mmr" else "select", emitted);
    w.print("],\"count\":{d}", .{emitted}) catch return mod.errPayload("Serialization error");
    if (want_trace) {
        w.writeAll(",\"trace\":") catch return mod.errPayload("Serialization error");
        tr.writeJson(w) catch return mod.errPayload("Serialization error");
    }
    w.writeByte('}') catch return mod.errPayload("Serialization error");

    logTrace(&tr);
    const out = aw.toOwnedSlice() catch return mod.errPayload("Allocation error");
    // Populate the semantic cache for a future near-identical query.
    if (!want_trace) {
        if (qvec) |qv| if (query_cache.global()) |qc| qc.put(qv, sig, out);
    }
    return .{ .text = out, .is_error = false };
}

/// Stable hash of every parameter that changes the result set, so the semantic
/// cache only reuses a response for an identical query shape.
fn paramSig(
    query_text: ?[]const u8,
    k: u64,
    vec_k: u64,
    text_k: u64,
    metric: query.Metric,
    use_mmr: bool,
    lambda: f32,
    rrf_k: f32,
    doc_filter: ?[]const []const u8,
) u64 {
    var h = std.hash.Wyhash.init(0x4147_5349_4748);
    h.update(std.mem.asBytes(&k));
    h.update(std.mem.asBytes(&vec_k));
    h.update(std.mem.asBytes(&text_k));
    h.update(&[_]u8{ @intFromEnum(metric), @intFromBool(use_mmr) });
    h.update(std.mem.asBytes(&lambda));
    h.update(std.mem.asBytes(&rrf_k));
    if (query_text) |q| h.update(q);
    if (doc_filter) |ids| for (ids) |id| {
        h.update(id);
        h.update("\x00"); // delimiter so ["ab","c"] ≠ ["a","bc"]
    };
    return h.final();
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
