//! Document-extraction tool handlers: detect a format, extract text, or
//! extract-then-chunk a local document — all native, all in the request arena.
//!
//! Input sourcing (one of, checked in order):
//!   * `path`          — a local file path; the server streams it from disk.
//!                       This is a *local-first* design: the MCP host and server
//!                       share a trust boundary and full control over I/O.
//!   * `contentBase64` — document bytes inline, base64-encoded.
//!   * `text`          — raw text content (already a string).
//!
//! A hard `max_bytes` cap bounds memory per call (Agent.md: never multiply an
//! untrusted length before a bounds check; here the cap is the bound).

const std = @import("std");
const pool = @import("../pool.zig");
const mod = @import("mod.zig");
const doc = @import("../doc/mod.zig");
const chunk = @import("../rag/chunk.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const PooledConn = pool.PooledConnection;
const Payload = mod.Payload;
const Writer = std.Io.Writer;

/// 256 MiB ceiling on a single document read. Large enough for real corpora,
/// small enough to bound a single request's footprint.
const max_bytes: usize = 256 << 20;

const SourceError = error{ NoSource, TooLarge, ReadFailed, BadBase64, OutOfMemory };

/// Resolve the document bytes from `path` | `contentBase64` | `text`.
/// Returns bytes owned by `a` (or borrowed from the JSON value for `text`).
fn loadSource(io: Io, a: Allocator, args: ?Value) SourceError!struct { bytes: []const u8, hint: ?[]const u8 } {
    if (mod.getStringParam(args, "path")) |path| {
        const bytes = readFile(io, a, path) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.FileTooBig => error.TooLarge,
            else => error.ReadFailed,
        };
        return .{ .bytes = bytes, .hint = path };
    }
    if (mod.getStringParam(args, "contentBase64")) |b64| {
        const dec = std.base64.standard.Decoder;
        const n = dec.calcSizeForSlice(b64) catch return error.BadBase64;
        if (n > max_bytes) return error.TooLarge;
        const out = a.alloc(u8, n) catch return error.OutOfMemory;
        dec.decode(out, b64) catch return error.BadBase64;
        return .{ .bytes = out, .hint = mod.getStringParam(args, "filename") };
    }
    if (mod.getStringParam(args, "text")) |t| {
        return .{ .bytes = t, .hint = mod.getStringParam(args, "filename") };
    }
    return error.NoSource;
}

fn readFile(io: Io, a: Allocator, path: []const u8) ![]u8 {
    return try std.Io.Dir.cwd().readFileAlloc(io, path, a, Io.Limit.limited(max_bytes));
}

fn sourceErrPayload(e: SourceError) Payload {
    return mod.errPayload(switch (e) {
        error.NoSource => "Provide one of 'path', 'contentBase64', or 'text'",
        error.TooLarge => "Document exceeds the 256 MiB extraction limit",
        error.ReadFailed => "Could not read the file at 'path'",
        error.BadBase64 => "'contentBase64' is not valid base64",
        error.OutOfMemory => "Out of memory reading the document",
    });
}

fn writeJsonString(w: *Writer, s: []const u8) Writer.Error!void {
    // Reuse the project's JSON string quoter for correct escaping.
    try @import("../json.zig").writeQuoted(w, s);
}

// ── Tools ─────────────────────────────────────────────────────────────

/// `doc_detect_format`: identify the document format without extracting.
pub fn detectFormat(io: Io, allocator: Allocator, _: *PooledConn, args: ?Value) Payload {
    const src = loadSource(io, allocator, args) catch |e| return sourceErrPayload(e);
    const fmt = doc.detect.detect(src.bytes, src.hint);

    return mod.renderOwned(allocator, struct {
        fn write(w: *Writer, format: doc.Format, bytes_len: usize) Writer.Error!void {
            try w.writeAll("{\"format\":");
            try writeJsonString(w, format.label());
            try w.print(",\"extractable\":{s},\"bytes\":{d}}}", .{
                if (format.isExtractable()) "true" else "false",
                bytes_len,
            });
        }
    }.write, .{ fmt, src.bytes.len });
}

/// `doc_extract_text`: detect + extract the document to plain text.
pub fn extractText(io: Io, allocator: Allocator, _: *PooledConn, args: ?Value) Payload {
    const src = loadSource(io, allocator, args) catch |e| return sourceErrPayload(e);
    const forced = parseFormat(mod.getStringParam(args, "format"));

    const result = if (forced) |f|
        doc.extractAs(allocator, src.bytes, f)
    else
        doc.extract(allocator, src.bytes, src.hint);

    const ex = result catch |e| {
        const fmt = forced orelse doc.detect.detect(src.bytes, src.hint);
        return mod.errPayload(doc.errorMessage(e, fmt));
    };

    return mod.renderOwned(allocator, struct {
        fn write(w: *Writer, e: doc.Extracted) Writer.Error!void {
            try w.writeAll("{\"format\":");
            try writeJsonString(w, e.format.label());
            try w.print(",\"units\":{d},\"bytes\":{d},\"text\":", .{ e.units, e.bytes_in });
            try writeJsonString(w, e.text);
            try w.writeByte('}');
        }
    }.write, .{ex});
}

/// `doc_extract_and_chunk`: extract then split into overlapping token windows,
/// ready to embed and feed to `rag_ingest_document`.
pub fn extractAndChunk(io: Io, allocator: Allocator, _: *PooledConn, args: ?Value) Payload {
    const src = loadSource(io, allocator, args) catch |e| return sourceErrPayload(e);
    const forced = parseFormat(mod.getStringParam(args, "format"));

    const result = if (forced) |f|
        doc.extractAs(allocator, src.bytes, f)
    else
        doc.extract(allocator, src.bytes, src.hint);

    const ex = result catch |e| {
        const fmt = forced orelse doc.detect.detect(src.bytes, src.hint);
        return mod.errPayload(doc.errorMessage(e, fmt));
    };

    const size = getUint(args, "chunkSize", 200);
    const overlap = getUint(args, "overlap", 40);

    // Chunk against a reset-per-document scratch pool so the token-span working
    // set (which can be large) doesn't permanently bloat the response arena.
    var scratch = doc.pool.Scratch.init(allocator);
    defer scratch.deinit();
    const chunks = chunk.chunk(scratch.allocator(), ex.text, .{
        .chunk_size = @intCast(size),
        .overlap = @intCast(overlap),
    }) catch return mod.errPayload("Chunking failed");

    return mod.renderOwned(allocator, struct {
        fn write(w: *Writer, e: doc.Extracted, cs: []const chunk.Chunk) Writer.Error!void {
            try w.writeAll("{\"format\":");
            try writeJsonString(w, e.format.label());
            try w.print(",\"count\":{d},\"chunks\":[", .{cs.len});
            for (cs, 0..) |c, i| {
                if (i > 0) try w.writeByte(',');
                try w.print("{{\"ordinal\":{d},\"tokenCount\":{d},\"content\":", .{ c.ordinal, c.token_count });
                try writeJsonString(w, c.content);
                try w.writeByte('}');
            }
            try w.writeAll("]}");
        }
    }.write, .{ ex, chunks });
}

fn getUint(args: ?Value, name: []const u8, default: u64) u64 {
    const a = args orelse return default;
    if (a != .object) return default;
    const v = a.object.get(name) orelse return default;
    return switch (v) {
        .integer => |n| if (n >= 0) @intCast(n) else default,
        .string => |s| std.fmt.parseUnsigned(u64, s, 10) catch default,
        else => default,
    };
}

fn parseFormat(name: ?[]const u8) ?doc.Format {
    const n = name orelse return null;
    inline for (@typeInfo(doc.Format).@"enum".fields) |f| {
        if (std.mem.eql(u8, n, f.name)) return @field(doc.Format, f.name);
    }
    return null;
}
