//! Apache Arrow IPC reader — native decode of the columnar wire format to text.
//!
//! Reference: the Arrow IPC format spec (arrow `docs/source/format/Columnar.rst`
//! "Serialization and IPC") and the FlatBuffers schemas `Message.fbs`,
//! `Schema.fbs`, `File.fbs`. Two framings share the same machinery:
//!
//!   * **Stream**: a sequence of encapsulated messages, each
//!     `[0xFFFFFFFF continuation][u32 metadata_len][Message flatbuffer][padding]
//!     [body]`, terminated by a zero-length message. (DuckDB/nanoarrow writes
//!     this.)
//!   * **File** ("Feather v2"): `ARROW1\0\0` + the same message stream + a
//!     `Footer` + `[u32 footer_len]` + `ARROW1`. (pyarrow `new_file`.)
//!
//! A `Schema` message names the columns and their logical types; each
//! `RecordBatch` message carries `FieldNode`s (per-column length + null count)
//! and `Buffer`s (offset/length into the message body). For a flat column the
//! body holds a validity bitmap then the data (plus an offsets buffer for
//! var-length strings/binary). `DictionaryBatch` messages supply the values for
//! dictionary-encoded columns.
//!
//! Scope (Agent.md: native, arena-backed, honest): flat schemas with the common
//! types — Int, FloatingPoint, Bool, Utf8/LargeUtf8, Binary/LargeBinary,
//! Decimal, Date, Timestamp, FixedSizeBinary — plus dictionary encoding.
//! Body compression (LZ4/ZSTD), big-endian buffers, and nested/struct/list
//! columns are reported as `Unsupported` rather than mis-decoded.
//!
//! Output mirrors the CSV/Parquet readers: a header line of column names, then
//! one space-separated row per record.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Fb = @import("flatbuffers.zig");

pub const Error = error{ NotArrow, Truncated, Corrupt, Unsupported, OutOfMemory };

pub const file_magic = "ARROW1";
const continuation = 0xFFFFFFFF;

// MessageHeader union (Message.fbs).
const Header = enum(u8) { none = 0, schema = 1, dictionary_batch = 2, record_batch = 3, _ };

// Type union (Schema.fbs) — only the tags we render.
const TypeTag = enum(u8) {
    none = 0,
    @"null" = 1,
    int = 2,
    floating_point = 3,
    binary = 4,
    utf8 = 5,
    bool = 6,
    decimal = 7,
    date = 8,
    time = 9,
    timestamp = 10,
    interval = 11,
    list = 12,
    struct_ = 13,
    @"union" = 14,
    fixed_size_binary = 15,
    fixed_size_list = 16,
    map = 17,
    duration = 18,
    large_binary = 19,
    large_utf8 = 20,
    _,
};

const Field = struct {
    name: []const u8 = "",
    tag: TypeTag = .none,
    bit_width: u32 = 0,
    signed: bool = true,
    fp_precision: i16 = 0, // 0 half, 1 single, 2 double
    unit: i16 = 0, // date/timestamp/time unit
    scale: i32 = 0, // decimal
    byte_width: i32 = 0, // fixed_size_binary
    dict_id: ?i64 = null,
    dict_index_bits: u32 = 32,
    dict_index_signed: bool = true,
};

const Dictionary = struct { id: i64, vals: [][]const u8 };

const Reader = struct {
    a: Allocator,
    fields: []Field = &.{},
    dicts: std.ArrayList(Dictionary) = .empty,

    fn dictFor(self: *Reader, id: i64) ?[][]const u8 {
        for (self.dicts.items) |d| {
            if (d.id == id) return d.vals;
        }
        return null;
    }
};

// ── Message framing ────────────────────────────────────────────────────

pub const Result = struct { text: []u8, units: usize };

/// Decode an Arrow IPC stream or file buffer to row-major text.
pub fn toText(a: Allocator, bytes: []const u8) Error!Result {
    var rd = Reader{ .a = a };

    // File framing carries an 8-byte `ARROW1\0\0` prefix before the messages.
    var pos: usize = 0;
    const is_file = bytes.len >= 12 and std.mem.eql(u8, bytes[0..6], file_magic) and
        std.mem.eql(u8, bytes[bytes.len - 6 ..], file_magic);
    if (is_file) {
        pos = 8;
    } else if (!(bytes.len >= 4 and std.mem.readInt(u32, bytes[0..4], .little) == continuation)) {
        return error.NotArrow;
    }

    var aw = Writer.Allocating.init(a);
    errdefer aw.deinit();
    const w = &aw.writer;
    var header_written = false;
    var units: usize = 0;

    while (pos + 4 <= bytes.len) {
        // Optional continuation marker, then the metadata length.
        var meta_len: u32 = std.mem.readInt(u32, bytes[pos..][0..4], .little);
        pos += 4;
        if (meta_len == continuation) {
            if (pos + 4 > bytes.len) break;
            meta_len = std.mem.readInt(u32, bytes[pos..][0..4], .little);
            pos += 4;
        }
        if (meta_len == 0) break; // end-of-stream marker
        const meta_end = std.math.add(usize, pos, meta_len) catch return error.Corrupt;
        if (meta_end > bytes.len) break; // ran into the footer (file format) / truncated
        const msg_fb = bytes[pos..meta_end];
        pos = meta_end;

        const fb = Fb.init(msg_fb);
        const msg = fb.root();
        const body_len: usize = @intCast(@max(msg.readI64(3, 0), 0));
        const body_end = std.math.add(usize, pos, body_len) catch return error.Corrupt;
        if (body_end > bytes.len) return error.Corrupt;
        const body = bytes[pos..body_end];
        // Bodies are padded to 8 bytes; advance over the padding too.
        pos = std.mem.alignForward(usize, body_end, 8);

        const header_type: Header = @enumFromInt(msg.readU8(1, 0));
        const header = msg.table(2) orelse continue;
        switch (header_type) {
            .schema => try parseSchema(&rd, &fb, header),
            .dictionary_batch => try parseDictionaryBatch(&rd, &fb, header, body),
            .record_batch => {
                if (!header_written) {
                    for (rd.fields, 0..) |f, i| {
                        if (i > 0) w.writeByte(' ') catch return error.OutOfMemory;
                        w.writeAll(f.name) catch return error.OutOfMemory;
                    }
                    if (rd.fields.len > 0) w.writeByte('\n') catch return error.OutOfMemory;
                    header_written = true;
                }
                units += try emitRecordBatch(&rd, &fb, header, body, w);
            },
            else => {},
        }
    }

    return .{ .text = aw.toOwnedSlice() catch return error.OutOfMemory, .units = units };
}

// ── Schema ─────────────────────────────────────────────────────────────

fn parseSchema(rd: *Reader, fb: *const Fb, schema: Fb.Table) Error!void {
    if (schema.readI16(0, 0) != 0) return error.Unsupported; // big-endian buffers
    const fvec = schema.vector(1);
    const fields = rd.a.alloc(Field, fvec.len) catch return error.OutOfMemory;
    for (0..fvec.len) |i| {
        const ft = fvec.table(i) orelse return error.Corrupt;
        fields[i] = try parseField(fb, ft);
    }
    rd.fields = fields;
}

fn parseField(fb: *const Fb, ft: Fb.Table) Error!Field {
    var f: Field = .{};
    f.name = ft.string(0) orelse "";
    f.tag = @enumFromInt(ft.readU8(2, 0));
    if (ft.table(3)) |ty| {
        switch (f.tag) {
            .int => {
                f.bit_width = @intCast(@max(ty.readI32(0, 0), 0));
                f.signed = ty.readBool(1, true);
            },
            .floating_point => f.fp_precision = ty.readI16(0, 0),
            .date => f.unit = ty.readI16(0, 0),
            .timestamp => f.unit = ty.readI16(0, 0),
            .time => f.unit = ty.readI16(0, 0),
            .decimal => f.scale = ty.readI32(1, 0),
            .fixed_size_binary => f.byte_width = ty.readI32(0, 0),
            else => {},
        }
    }
    // Dictionary encoding: the column stores integer indices into a dictionary.
    if (ft.table(4)) |enc| {
        f.dict_id = enc.readI64(0, 0);
        if (enc.table(1)) |it| { // indexType (Int)
            f.dict_index_bits = @intCast(@max(it.readI32(0, 32), 8));
            f.dict_index_signed = it.readBool(1, true);
        }
    }
    _ = fb;
    return f;
}

// ── RecordBatch / DictionaryBatch ──────────────────────────────────────

const FIELD_NODE_STRIDE = 16; // {i64 length, i64 null_count}
const BUFFER_STRIDE = 16; // {i64 offset, i64 length}

const Buffer = struct { offset: i64, length: i64 };

const BatchView = struct {
    length: usize,
    nodes: Fb.Vector,
    buffers: Fb.Vector,
};

fn openBatch(fb: *const Fb, rb: Fb.Table) Error!BatchView {
    if (rb.table(3)) |_| return error.Unsupported; // BodyCompression (LZ4/ZSTD)
    _ = fb;
    return .{
        .length = @intCast(@max(rb.readI64(0, 0), 0)),
        .nodes = rb.vector(1),
        .buffers = rb.vector(2),
    };
}

fn bufferAt(fb: *const Fb, bv: BatchView, idx: usize) Buffer {
    const off = bv.buffers.elem(idx, BUFFER_STRIDE);
    return .{ .offset = fb.i64At(off), .length = fb.i64At(off + 8) };
}

fn nodeLen(fb: *const Fb, bv: BatchView, idx: usize) struct { length: usize, nulls: usize } {
    const off = bv.nodes.elem(idx, FIELD_NODE_STRIDE);
    return .{
        .length = @intCast(@max(fb.i64At(off), 0)),
        .nulls = @intCast(@max(fb.i64At(off + 8), 0)),
    };
}

/// Slice a body buffer (validated against the body bounds).
fn slice(body: []const u8, b: Buffer) Error![]const u8 {
    const start: usize = @intCast(@max(b.offset, 0));
    const len: usize = @intCast(@max(b.length, 0));
    const end = std.math.add(usize, start, len) catch return error.Corrupt;
    if (end > body.len) return error.Corrupt;
    return body[start..end];
}

fn parseDictionaryBatch(rd: *Reader, fb: *const Fb, db: Fb.Table, body: []const u8) Error!void {
    const id = db.readI64(0, 0);
    const rb = db.table(1) orelse return error.Corrupt;
    const bv = try openBatch(fb, rb);
    // A dictionary batch is a RecordBatch with a single column holding the
    // dictionary values. Decode it with the value type, not the index type.
    if (rd.fields.len == 0) return error.Corrupt;
    var value_field: ?Field = null;
    for (rd.fields) |f| {
        if (f.dict_id != null and f.dict_id.? == id) {
            var vf = f;
            vf.dict_id = null; // decode the values themselves, not indices
            value_field = vf;
            break;
        }
    }
    const vf = value_field orelse return error.Corrupt;
    var bi: usize = 0;
    const node = nodeLen(fb, bv, 0);
    const vals = try decodeColumn(rd, fb, vf, node.length, node.nulls, bv, &bi, body);
    rd.dicts.append(rd.a, .{ .id = id, .vals = vals }) catch return error.OutOfMemory;
}

fn emitRecordBatch(rd: *Reader, fb: *const Fb, rb: Fb.Table, body: []const u8, w: *Writer) Error!usize {
    const bv = try openBatch(fb, rb);
    const n = bv.length;

    // Decode every column, then transpose to rows.
    const cols = rd.a.alloc([][]const u8, rd.fields.len) catch return error.OutOfMemory;
    var bi: usize = 0;
    for (rd.fields, 0..) |f, ci| {
        const node = nodeLen(fb, bv, ci);
        cols[ci] = try decodeColumn(rd, fb, f, node.length, node.nulls, bv, &bi, body);
    }
    for (0..n) |r| {
        for (cols, 0..) |col, ci| {
            if (ci > 0) w.writeByte(' ') catch return error.OutOfMemory;
            if (r < col.len) w.writeAll(col[r]) catch return error.OutOfMemory;
        }
        w.writeByte('\n') catch return error.OutOfMemory;
    }
    return n;
}

// ── Column decode ──────────────────────────────────────────────────────

/// Decode one column's buffers into `len` rendered cells (nulls → ""). Advances
/// `bi` past the buffers this column consumes.
fn decodeColumn(rd: *Reader, fb: *const Fb, f: Field, len: usize, nulls: usize, bv: BatchView, bi: *usize, body: []const u8) Error![][]const u8 {
    const cells = rd.a.alloc([]const u8, len) catch return error.OutOfMemory;
    @memset(cells, "");

    // Buffer 0 is always the validity bitmap (may be empty when no nulls).
    const validity = try slice(body, bufferAt(fb, bv, bi.*));
    bi.* += 1;
    const has_validity = nulls > 0 and validity.len > 0;

    // Dictionary-encoded: decode integer indices, map through the dictionary.
    if (f.dict_id) |id| {
        const dict = rd.dictFor(id) orelse return error.Corrupt;
        const data = try slice(body, bufferAt(fb, bv, bi.*));
        bi.* += 1;
        const bytes_per = f.dict_index_bits / 8;
        for (0..len) |j| {
            if (has_validity and !bit(validity, j)) continue;
            const idx = readUintLE(data, j * bytes_per, bytes_per);
            if (idx >= dict.len) return error.Corrupt;
            cells[j] = dict[@intCast(idx)];
        }
        return cells;
    }

    switch (f.tag) {
        .int => {
            const data = try slice(body, bufferAt(fb, bv, bi.*));
            bi.* += 1;
            const bytes_per = f.bit_width / 8;
            for (0..len) |j| {
                if (has_validity and !bit(validity, j)) continue;
                cells[j] = if (f.signed)
                    try fmt(rd.a, "{d}", .{readIntLE(data, j * bytes_per, bytes_per)})
                else
                    try fmt(rd.a, "{d}", .{readUintLE(data, j * bytes_per, bytes_per)});
            }
        },
        .floating_point => {
            const data = try slice(body, bufferAt(fb, bv, bi.*));
            bi.* += 1;
            for (0..len) |j| {
                if (has_validity and !bit(validity, j)) continue;
                cells[j] = switch (f.fp_precision) {
                    1 => try fmt(rd.a, "{d}", .{f32At(data, j * 4)}),
                    2 => try fmt(rd.a, "{d}", .{f64At(data, j * 8)}),
                    else => "", // half precision: uncommon, skip rendering
                };
            }
        },
        .bool => {
            const data = try slice(body, bufferAt(fb, bv, bi.*));
            bi.* += 1;
            for (0..len) |j| {
                if (has_validity and !bit(validity, j)) continue;
                cells[j] = if (bit(data, j)) "true" else "false";
            }
        },
        .utf8, .binary => {
            const offsets = try slice(body, bufferAt(fb, bv, bi.*));
            bi.* += 1;
            const data = try slice(body, bufferAt(fb, bv, bi.*));
            bi.* += 1;
            for (0..len) |j| {
                if (has_validity and !bit(validity, j)) continue;
                const s: usize = @intCast(@max(readIntLE(offsets, j * 4, 4), 0));
                const e: usize = @intCast(@max(readIntLE(offsets, (j + 1) * 4, 4), 0));
                if (e > data.len or s > e) return error.Corrupt;
                cells[j] = data[s..e];
            }
        },
        .large_utf8, .large_binary => {
            const offsets = try slice(body, bufferAt(fb, bv, bi.*));
            bi.* += 1;
            const data = try slice(body, bufferAt(fb, bv, bi.*));
            bi.* += 1;
            for (0..len) |j| {
                if (has_validity and !bit(validity, j)) continue;
                const s: usize = @intCast(@max(readIntLE(offsets, j * 8, 8), 0));
                const e: usize = @intCast(@max(readIntLE(offsets, (j + 1) * 8, 8), 0));
                if (e > data.len or s > e) return error.Corrupt;
                cells[j] = data[s..e];
            }
        },
        .fixed_size_binary => {
            const data = try slice(body, bufferAt(fb, bv, bi.*));
            bi.* += 1;
            const w: usize = @intCast(@max(f.byte_width, 0));
            for (0..len) |j| {
                if (has_validity and !bit(validity, j)) continue;
                const s = j * w;
                if (s + w > data.len) return error.Corrupt;
                cells[j] = data[s .. s + w];
            }
        },
        .date => {
            const data = try slice(body, bufferAt(fb, bv, bi.*));
            bi.* += 1;
            for (0..len) |j| {
                if (has_validity and !bit(validity, j)) continue;
                const days: i64 = if (f.unit == 0) readIntLE(data, j * 4, 4) else @divFloor(readIntLE(data, j * 8, 8), 86_400_000);
                cells[j] = try renderDate(rd.a, days);
            }
        },
        .timestamp => {
            const data = try slice(body, bufferAt(fb, bv, bi.*));
            bi.* += 1;
            const ns_per: i64 = switch (f.unit) {
                0 => 1_000_000_000, // second
                1 => 1_000_000, // millisecond
                2 => 1_000, // microsecond
                else => 1, // nanosecond
            };
            for (0..len) |j| {
                if (has_validity and !bit(validity, j)) continue;
                cells[j] = try renderTimestamp(rd.a, readIntLE(data, j * 8, 8) * ns_per);
            }
        },
        .decimal => {
            const data = try slice(body, bufferAt(fb, bv, bi.*));
            bi.* += 1;
            for (0..len) |j| {
                if (has_validity and !bit(validity, j)) continue;
                cells[j] = try renderDecimal128(rd.a, data, j * 16, f.scale);
            }
        },
        .null => {}, // all null, no data buffer; leave cells empty
        else => return error.Unsupported, // list/struct/union/map/views: nested
    }
    return cells;
}

// ── Little-endian buffer reads ─────────────────────────────────────────

/// Bit `j` of an LSB-first bitmap (validity / boolean data).
fn bit(buf: []const u8, j: usize) bool {
    const byte = j >> 3;
    if (byte >= buf.len) return false;
    return (buf[byte] >> @intCast(j & 7)) & 1 != 0;
}

fn readUintLE(buf: []const u8, off: usize, n: usize) u64 {
    var v: u64 = 0;
    for (0..n) |k| {
        if (off + k >= buf.len) break;
        v |= @as(u64, buf[off + k]) << @intCast(8 * k);
    }
    return v;
}

fn readIntLE(buf: []const u8, off: usize, n: usize) i64 {
    const u = readUintLE(buf, off, n);
    if (n == 0 or n >= 8) return @bitCast(u);
    const sign_bit = @as(u64, 1) << @intCast(8 * n - 1);
    if (u & sign_bit != 0) {
        const ext = ~((@as(u64, 1) << @intCast(8 * n)) - 1);
        return @bitCast(u | ext);
    }
    return @bitCast(u);
}

fn f32At(buf: []const u8, off: usize) f32 {
    if (off + 4 > buf.len) return 0;
    return @bitCast(std.mem.readInt(u32, buf[off..][0..4], .little));
}
fn f64At(buf: []const u8, off: usize) f64 {
    if (off + 8 > buf.len) return 0;
    return @bitCast(std.mem.readInt(u64, buf[off..][0..8], .little));
}

// ── Rendering ──────────────────────────────────────────────────────────

fn fmt(a: Allocator, comptime f: []const u8, args: anytype) Error![]const u8 {
    return std.fmt.allocPrint(a, f, args) catch error.OutOfMemory;
}

fn renderDate(a: Allocator, days: i64) Error![]const u8 {
    const c = civilFromDays(days);
    return fmt(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ uYear(c.year), c.month, c.day });
}

fn renderTimestamp(a: Allocator, total_ns: i64) Error![]const u8 {
    const day_ns = 86_400 * 1_000_000_000;
    const days = @divFloor(total_ns, day_ns);
    const rem = @mod(total_ns, day_ns);
    const c = civilFromDays(days);
    var secs = @divFloor(rem, 1_000_000_000);
    const ns: u64 = @intCast(@mod(rem, 1_000_000_000));
    const hh = @divFloor(secs, 3600);
    secs -= hh * 3600;
    const mm = @divFloor(secs, 60);
    const ss = secs - mm * 60;
    return fmt(a, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}", .{
        uYear(c.year),         c.month,                c.day,
        @as(u64, @intCast(hh)), @as(u64, @intCast(mm)), @as(u64, @intCast(ss)),
        ns,
    });
}

/// Render a 16-byte little-endian two's-complement Arrow decimal with `scale`.
fn renderDecimal128(a: Allocator, buf: []const u8, off: usize, scale: i32) Error![]const u8 {
    if (off + 16 > buf.len) return error.Corrupt;
    const lo = std.mem.readInt(u64, buf[off..][0..8], .little);
    const hi = std.mem.readInt(u64, buf[off + 8 ..][0..8], .little);
    const v: i128 = @bitCast((@as(u128, hi) << 64) | lo);
    if (scale <= 0) return fmt(a, "{d}", .{v});
    const s: u32 = @intCast(scale);
    const neg = v < 0;
    const av: u128 = if (neg) @intCast(-v) else @intCast(v);
    var pow: u128 = 1;
    for (0..s) |_| pow *= 10;
    const ip = av / pow;
    const fp = av % pow;
    var tmp: [40]u8 = undefined;
    const frac = std.fmt.bufPrint(&tmp, "{d}", .{fp}) catch unreachable;
    const zeros = "0000000000000000000000000000000000000000";
    const pad = if (s > frac.len) s - @as(u32, @intCast(frac.len)) else 0;
    return fmt(a, "{s}{d}.{s}{s}", .{ if (neg) "-" else "", ip, zeros[0..pad], frac });
}

fn uYear(y: i64) u64 {
    return @intCast(@max(y, 0));
}

const Civil = struct { year: i64, month: u32, day: u32 };

/// Howard Hinnant's days→civil algorithm (proleptic Gregorian).
fn civilFromDays(z_in: i64) Civil {
    const z = z_in + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .year = y + (if (m <= 2) @as(i64, 1) else 0), .month = @intCast(m), .day = @intCast(d) };
}
