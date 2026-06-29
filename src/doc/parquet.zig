//! Apache Parquet reader — native columnar decode to text.
//!
//! Reference: the Apache Parquet format spec (`parquet-format/README.md` and
//! `src/main/thrift/parquet.thrift`) and the encodings doc
//! (`parquet-format/Encodings.md`). A Parquet file is framed by the 4-byte
//! magic `PAR1` at both ends; the tail is
//! `[FileMetaData (thrift-compact)][u32 footer-len][PAR1]`. `FileMetaData`
//! names the schema and, per row group, each column chunk's codec, encodings,
//! and page offsets. Each column chunk is a sequence of pages
//! (`[PageHeader (thrift-compact)][page body]`); the body is compressed and
//! holds optional repetition/definition levels followed by the encoded values.
//!
//! What this implements (natively, arena-backed — Agent.md: no libarrow, no C):
//!   * Thrift compact protocol (../thrift) for `FileMetaData` + every `PageHeader`.
//!   * Codecs: UNCOMPRESSED, SNAPPY (../snappy), GZIP (../inflate). LZ4/ZSTD/
//!     BROTLI/LZO are reported as `Unsupported` rather than mis-decoded.
//!   * Encodings: PLAIN, PLAIN_DICTIONARY / RLE_DICTIONARY (dictionary page +
//!     RLE/bit-packed-hybrid indices), RLE (boolean), and the delta family
//!     (DELTA_BINARY_PACKED, DELTA_LENGTH_BYTE_ARRAY, DELTA_BYTE_ARRAY).
//!   * Physical types: BOOLEAN, INT32, INT64, INT96 (→ timestamp), FLOAT,
//!     DOUBLE, BYTE_ARRAY, FIXED_LEN_BYTE_ARRAY.
//!   * Definition levels (nullability) for flat schemas.
//!
//! Scope: flat (non-repeated) schemas — the tabular shape that dominates real
//! Parquet. A repeated/nested leaf (max repetition level > 0) is reported as
//! `Unsupported` instead of silently flattening and mis-aligning rows.
//!
//! Output is row-major text: a header line of column names, then one line per
//! row with cells separated by spaces — the same shape the CSV reader emits, so
//! the RAG chunker treats every tabular source uniformly.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const thrift = @import("thrift.zig");
const snappy = @import("snappy.zig");
const inflate = @import("inflate.zig");

pub const Error = error{ NotParquet, Truncated, Corrupt, Unsupported, OutOfMemory };

pub const magic = "PAR1";

// ── Enums (parquet.thrift) ─────────────────────────────────────────────

pub const PhysicalType = enum(i32) {
    boolean = 0,
    int32 = 1,
    int64 = 2,
    int96 = 3,
    float = 4,
    double = 5,
    byte_array = 6,
    fixed_len_byte_array = 7,
    _,
};

pub const Repetition = enum(i32) { required = 0, optional = 1, repeated = 2, _ };

pub const Codec = enum(i32) {
    uncompressed = 0,
    snappy = 1,
    gzip = 2,
    lzo = 3,
    brotli = 4,
    lz4 = 5,
    zstd = 6,
    lz4_raw = 7,
    _,
};

pub const Encoding = enum(i32) {
    plain = 0,
    plain_dictionary = 2,
    rle = 3,
    bit_packed = 4,
    delta_binary_packed = 5,
    delta_length_byte_array = 6,
    delta_byte_array = 7,
    rle_dictionary = 8,
    byte_stream_split = 9,
    _,
};

pub const PageType = enum(i32) {
    data_page = 0,
    index_page = 1,
    dictionary_page = 2,
    data_page_v2 = 3,
    _,
};

/// Legacy `ConvertedType` (parquet.thrift). Writers — including DuckDB — still
/// emit this alongside the newer `LogicalType` union, so honoring it is enough
/// to render decimals, dates, timestamps, and unsigned ints correctly.
pub const ConvertedType = enum(i32) {
    none = -1,
    utf8 = 0,
    map = 1,
    map_key_value = 2,
    list = 3,
    @"enum" = 4,
    decimal = 5,
    date = 6,
    time_millis = 7,
    time_micros = 8,
    timestamp_millis = 9,
    timestamp_micros = 10,
    uint_8 = 11,
    uint_16 = 12,
    uint_32 = 13,
    uint_64 = 14,
    int_8 = 15,
    int_16 = 16,
    int_32 = 17,
    int_64 = 18,
    json = 19,
    bson = 20,
    interval = 21,
    _,
};

// ── Footer framing ─────────────────────────────────────────────────────

pub const Footer = struct {
    metadata_start: usize,
    metadata_len: u32,
};

/// Validate the `PAR1` framing and locate the footer `FileMetaData` block.
pub fn locateFooter(bytes: []const u8) Error!Footer {
    if (bytes.len < 12) return error.NotParquet; // magic+len+magic minimum
    if (!std.mem.eql(u8, bytes[0..4], magic)) return error.NotParquet;
    if (!std.mem.eql(u8, bytes[bytes.len - 4 ..], magic)) return error.NotParquet;
    const len_off = bytes.len - 8;
    const meta_len = std.mem.readInt(u32, bytes[len_off..][0..4], .little);
    const meta_start = std.math.sub(usize, len_off, meta_len) catch return error.Truncated;
    if (meta_start < 4) return error.Truncated;
    return .{ .metadata_start = meta_start, .metadata_len = meta_len };
}

// ── Metadata structs (only the fields we use) ──────────────────────────

const SchemaElement = struct {
    ptype: ?PhysicalType = null,
    type_length: i32 = 0,
    repetition: Repetition = .required,
    name: []const u8 = "",
    num_children: i32 = 0,
    converted: ConvertedType = .none,
    scale: i32 = 0,
};

const ColumnMeta = struct {
    ptype: PhysicalType = .boolean,
    codec: Codec = .uncompressed,
    num_values: i64 = 0,
    data_page_offset: i64 = 0,
    dictionary_page_offset: ?i64 = null,
    total_compressed_size: i64 = 0,
};

const RowGroup = struct {
    columns: []ColumnMeta,
    num_rows: i64,
};

const FileMeta = struct {
    schema: []SchemaElement,
    row_groups: []RowGroup,
    num_rows: i64,
};

/// A flattened leaf column with the per-leaf levels needed to decode it.
const Leaf = struct {
    name: []const u8,
    ptype: PhysicalType,
    type_length: i32,
    max_def_level: u32,
    max_rep_level: u32,
    converted: ConvertedType = .none,
    scale: i32 = 0,
};

// ── Thrift parse helpers (field ids per parquet.thrift) ────────────────

fn tErr(e: thrift.Error) Error {
    return switch (e) {
        error.Truncated => error.Truncated,
        error.Malformed => error.Corrupt,
    };
}

fn parseSchemaElement(r: *thrift.Reader) Error!SchemaElement {
    var se: SchemaElement = .{};
    const prev = r.enterStruct();
    defer r.exitStruct(prev);
    while (true) {
        const f = r.fieldBegin() catch |e| return tErr(e);
        if (f.stop) break;
        switch (f.id) {
            1 => se.ptype = @enumFromInt(r.i32v() catch |e| return tErr(e)),
            2 => se.type_length = r.i32v() catch |e| return tErr(e),
            3 => se.repetition = @enumFromInt(r.i32v() catch |e| return tErr(e)),
            4 => se.name = r.binary() catch |e| return tErr(e),
            5 => se.num_children = r.i32v() catch |e| return tErr(e),
            6 => se.converted = @enumFromInt(r.i32v() catch |e| return tErr(e)),
            7 => se.scale = r.i32v() catch |e| return tErr(e),
            else => r.skip(f.ctype) catch |e| return tErr(e),
        }
    }
    return se;
}

fn parseColumnMeta(r: *thrift.Reader) Error!ColumnMeta {
    var cm: ColumnMeta = .{};
    const prev = r.enterStruct();
    defer r.exitStruct(prev);
    while (true) {
        const f = r.fieldBegin() catch |e| return tErr(e);
        if (f.stop) break;
        switch (f.id) {
            1 => cm.ptype = @enumFromInt(r.i32v() catch |e| return tErr(e)),
            4 => cm.codec = @enumFromInt(r.i32v() catch |e| return tErr(e)),
            5 => cm.num_values = (r.zigzag() catch |e| return tErr(e)),
            7 => cm.total_compressed_size = (r.zigzag() catch |e| return tErr(e)),
            9 => cm.data_page_offset = (r.zigzag() catch |e| return tErr(e)),
            11 => cm.dictionary_page_offset = (r.zigzag() catch |e| return tErr(e)),
            else => r.skip(f.ctype) catch |e| return tErr(e),
        }
    }
    return cm;
}

fn parseColumnChunk(r: *thrift.Reader) Error!ColumnMeta {
    var cm: ColumnMeta = .{};
    const prev = r.enterStruct();
    defer r.exitStruct(prev);
    while (true) {
        const f = r.fieldBegin() catch |e| return tErr(e);
        if (f.stop) break;
        switch (f.id) {
            3 => cm = try parseColumnMeta(r), // meta_data
            else => r.skip(f.ctype) catch |e| return tErr(e),
        }
    }
    return cm;
}

fn parseRowGroup(a: Allocator, r: *thrift.Reader) Error!RowGroup {
    var cols: std.ArrayList(ColumnMeta) = .empty;
    var num_rows: i64 = 0;
    const prev = r.enterStruct();
    defer r.exitStruct(prev);
    while (true) {
        const f = r.fieldBegin() catch |e| return tErr(e);
        if (f.stop) break;
        switch (f.id) {
            1 => { // list<ColumnChunk>
                const h = r.listBegin() catch |e| return tErr(e);
                var i: usize = 0;
                while (i < h.size) : (i += 1) {
                    const cm = try parseColumnChunk(r);
                    cols.append(a, cm) catch return error.OutOfMemory;
                }
            },
            3 => num_rows = (r.zigzag() catch |e| return tErr(e)),
            else => r.skip(f.ctype) catch |e| return tErr(e),
        }
    }
    return .{ .columns = cols.toOwnedSlice(a) catch return error.OutOfMemory, .num_rows = num_rows };
}

fn parseFileMeta(a: Allocator, meta_bytes: []const u8) Error!FileMeta {
    var r = thrift.Reader.init(meta_bytes);
    var schema: std.ArrayList(SchemaElement) = .empty;
    var groups: std.ArrayList(RowGroup) = .empty;
    var num_rows: i64 = 0;
    while (true) {
        const f = r.fieldBegin() catch |e| return tErr(e);
        if (f.stop) break;
        switch (f.id) {
            2 => { // list<SchemaElement>
                const h = r.listBegin() catch |e| return tErr(e);
                var i: usize = 0;
                while (i < h.size) : (i += 1) {
                    const se = try parseSchemaElement(&r);
                    schema.append(a, se) catch return error.OutOfMemory;
                }
            },
            3 => num_rows = (r.zigzag() catch |e| return tErr(e)),
            4 => { // list<RowGroup>
                const h = r.listBegin() catch |e| return tErr(e);
                var i: usize = 0;
                while (i < h.size) : (i += 1) {
                    const rg = try parseRowGroup(a, &r);
                    groups.append(a, rg) catch return error.OutOfMemory;
                }
            },
            else => r.skip(f.ctype) catch |e| return tErr(e),
        }
    }
    return .{
        .schema = schema.toOwnedSlice(a) catch return error.OutOfMemory,
        .row_groups = groups.toOwnedSlice(a) catch return error.OutOfMemory,
        .num_rows = num_rows,
    };
}

/// Walk the DFS-preorder schema list, deriving the leaf columns and their
/// max definition/repetition levels. `schema[0]` is the root message.
fn buildLeaves(a: Allocator, schema: []const SchemaElement) Error![]Leaf {
    if (schema.len == 0) return error.Corrupt;
    var leaves: std.ArrayList(Leaf) = .empty;
    // Iterative DFS carrying the running (def,rep) levels down each branch.
    const Frame = struct { idx: usize, remaining: usize, def: u32, rep: u32 };
    var stack: std.ArrayList(Frame) = .empty;
    // Root's children are the top-level columns; the root itself adds no level.
    var i: usize = 1;
    const root_children: usize = @intCast(@max(schema[0].num_children, 0));
    stack.append(a, .{ .idx = 0, .remaining = root_children, .def = 0, .rep = 0 }) catch return error.OutOfMemory;

    while (stack.items.len > 0) {
        var top = &stack.items[stack.items.len - 1];
        if (top.remaining == 0) {
            _ = stack.pop();
            continue;
        }
        if (i >= schema.len) return error.Corrupt;
        top.remaining -= 1;
        const se = schema[i];
        const parent_def = top.def;
        const parent_rep = top.rep;
        i += 1;

        const def = parent_def + @as(u32, switch (se.repetition) {
            .required => 0,
            .optional, .repeated => 1,
            else => 0,
        });
        const rep = parent_rep + @as(u32, if (se.repetition == .repeated) 1 else 0);

        if (se.num_children > 0) {
            stack.append(a, .{
                .idx = i - 1,
                .remaining = @intCast(se.num_children),
                .def = def,
                .rep = rep,
            }) catch return error.OutOfMemory;
        } else {
            const pt = se.ptype orelse return error.Corrupt;
            leaves.append(a, .{
                .name = se.name,
                .ptype = pt,
                .type_length = se.type_length,
                .max_def_level = def,
                .max_rep_level = rep,
                .converted = se.converted,
                .scale = se.scale,
            }) catch return error.OutOfMemory;
        }
    }
    return leaves.toOwnedSlice(a) catch return error.OutOfMemory;
}

// ── Page header ────────────────────────────────────────────────────────

const PageHeader = struct {
    ptype: PageType = .data_page,
    uncompressed_size: i32 = 0,
    compressed_size: i32 = 0,
    // data page (v1)
    dp_num_values: i32 = 0,
    dp_encoding: Encoding = .plain,
    // dictionary page
    dict_num_values: i32 = 0,
    // data page v2
    v2_num_values: i32 = 0,
    v2_num_nulls: i32 = 0,
    v2_encoding: Encoding = .plain,
    v2_def_len: i32 = 0,
    v2_rep_len: i32 = 0,
    v2_compressed: bool = true,
    header_len: usize = 0,
};

fn parseDataPageHeader(r: *thrift.Reader, ph: *PageHeader) Error!void {
    const prev = r.enterStruct();
    defer r.exitStruct(prev);
    while (true) {
        const f = r.fieldBegin() catch |e| return tErr(e);
        if (f.stop) break;
        switch (f.id) {
            1 => ph.dp_num_values = r.i32v() catch |e| return tErr(e),
            2 => ph.dp_encoding = @enumFromInt(r.i32v() catch |e| return tErr(e)),
            else => r.skip(f.ctype) catch |e| return tErr(e),
        }
    }
}

fn parseDictPageHeader(r: *thrift.Reader, ph: *PageHeader) Error!void {
    const prev = r.enterStruct();
    defer r.exitStruct(prev);
    while (true) {
        const f = r.fieldBegin() catch |e| return tErr(e);
        if (f.stop) break;
        switch (f.id) {
            1 => ph.dict_num_values = r.i32v() catch |e| return tErr(e),
            else => r.skip(f.ctype) catch |e| return tErr(e),
        }
    }
}

fn parseDataPageHeaderV2(r: *thrift.Reader, ph: *PageHeader) Error!void {
    const prev = r.enterStruct();
    defer r.exitStruct(prev);
    while (true) {
        const f = r.fieldBegin() catch |e| return tErr(e);
        if (f.stop) break;
        switch (f.id) {
            1 => ph.v2_num_values = r.i32v() catch |e| return tErr(e),
            2 => ph.v2_num_nulls = r.i32v() catch |e| return tErr(e),
            4 => ph.v2_encoding = @enumFromInt(r.i32v() catch |e| return tErr(e)),
            5 => ph.v2_def_len = r.i32v() catch |e| return tErr(e),
            6 => ph.v2_rep_len = r.i32v() catch |e| return tErr(e),
            7 => ph.v2_compressed = thrift.Reader.boolFromField(f),
            else => r.skip(f.ctype) catch |e| return tErr(e),
        }
    }
}

/// Parse a `PageHeader` at the start of `buf`; `header_len` records how many
/// bytes it consumed so the caller can locate the page body.
fn parsePageHeader(buf: []const u8) Error!PageHeader {
    var r = thrift.Reader.init(buf);
    var ph: PageHeader = .{};
    while (true) {
        const f = r.fieldBegin() catch |e| return tErr(e);
        if (f.stop) break;
        switch (f.id) {
            1 => ph.ptype = @enumFromInt(r.i32v() catch |e| return tErr(e)),
            2 => ph.uncompressed_size = r.i32v() catch |e| return tErr(e),
            3 => ph.compressed_size = r.i32v() catch |e| return tErr(e),
            5 => try parseDataPageHeader(&r, &ph),
            7 => try parseDictPageHeader(&r, &ph),
            8 => try parseDataPageHeaderV2(&r, &ph),
            else => r.skip(f.ctype) catch |e| return tErr(e),
        }
    }
    ph.header_len = r.pos;
    return ph;
}

// ── Decompression ──────────────────────────────────────────────────────

/// Decompress (or borrow) a page body to its declared uncompressed size.
fn decompress(a: Allocator, codec: Codec, src: []const u8, uncompressed_size: usize) Error![]const u8 {
    switch (codec) {
        .uncompressed => return src,
        .snappy => {
            const out = snappy.decode(a, src) catch |e| return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                error.Corrupt => error.Corrupt,
            };
            if (out.len != uncompressed_size) return error.Corrupt;
            return out;
        },
        .gzip => {
            const deflate = try gzipBody(src);
            const out = inflate.raw(a, deflate, uncompressed_size) catch |e| return switch (e) {
                error.OutOfMemory, error.WriteFailed => error.OutOfMemory,
                else => error.Corrupt,
            };
            return out;
        },
        else => return error.Unsupported,
    }
}

/// Strip the RFC 1952 gzip header, returning the embedded raw-DEFLATE stream.
fn gzipBody(src: []const u8) Error![]const u8 {
    if (src.len < 18) return error.Corrupt; // 10 header + min deflate + 8 trailer
    if (src[0] != 0x1f or src[1] != 0x8b or src[2] != 8) return error.Corrupt;
    const flg = src[3];
    var p: usize = 10;
    if (flg & 0x04 != 0) { // FEXTRA
        if (p + 2 > src.len) return error.Corrupt;
        const xlen = std.mem.readInt(u16, src[p..][0..2], .little);
        p += 2 + xlen;
    }
    if (flg & 0x08 != 0) p = nulTerm(src, p); // FNAME
    if (flg & 0x10 != 0) p = nulTerm(src, p); // FCOMMENT
    if (flg & 0x02 != 0) p += 2; // FHCRC
    if (p + 8 > src.len) return error.Corrupt;
    return src[p .. src.len - 8]; // drop CRC32 + ISIZE trailer
}

fn nulTerm(src: []const u8, from: usize) usize {
    var p = from;
    while (p < src.len and src[p] != 0) p += 1;
    return @min(p + 1, src.len);
}

// ── Bit / RLE-hybrid readers (Encodings.md) ────────────────────────────

/// Least-significant-bit-first bit reader (Parquet packs bits LSB-first).
const BitReader = struct {
    data: []const u8,
    byte_pos: usize = 0,
    bit_pos: u32 = 0,

    fn read(self: *BitReader, width: u32) u64 {
        var result: u64 = 0;
        var got: u32 = 0;
        while (got < width) {
            if (self.byte_pos >= self.data.len) break; // zero-pad past the end
            const avail: u32 = 8 - self.bit_pos;
            const take: u32 = @min(width - got, avail);
            const mask: u64 = (@as(u64, 1) << @intCast(take)) - 1;
            const bits: u64 = (@as(u64, self.data[self.byte_pos] >> @intCast(self.bit_pos))) & mask;
            result |= bits << @intCast(got);
            got += take;
            self.bit_pos += take;
            if (self.bit_pos == 8) {
                self.bit_pos = 0;
                self.byte_pos += 1;
            }
        }
        return result;
    }
};

fn bitWidth(max: u32) u32 {
    if (max == 0) return 0;
    return 32 - @clz(max);
}

/// Decode exactly `count` values from an RLE/bit-packed hybrid stream into
/// `out`. Used for definition levels and dictionary indices.
pub fn rleHybrid(data: []const u8, bit_width: u32, count: usize, out: []u32) Error!void {
    if (count == 0) return;
    if (bit_width == 0) {
        @memset(out[0..count], 0);
        return;
    }
    var pos: usize = 0;
    var produced: usize = 0;
    const nbytes: usize = (bit_width + 7) / 8;
    while (produced < count) {
        const header = readVarint(data, &pos) orelse return error.Corrupt;
        if (header & 1 == 0) { // RLE run
            const run: usize = @intCast(header >> 1);
            if (pos + nbytes > data.len) return error.Corrupt;
            var val: u32 = 0;
            for (0..nbytes) |k| val |= @as(u32, data[pos + k]) << @intCast(8 * k);
            pos += nbytes;
            const n = @min(run, count - produced);
            for (0..n) |_| {
                out[produced] = val;
                produced += 1;
            }
        } else { // bit-packed run
            const groups: usize = @intCast(header >> 1);
            const total = groups * 8;
            const need = groups * bit_width; // bytes (8 values * bit_width bits)
            if (pos + need > data.len) return error.Corrupt;
            var br = BitReader{ .data = data[pos .. pos + need] };
            for (0..total) |_| {
                const v: u32 = @truncate(br.read(bit_width));
                if (produced < count) {
                    out[produced] = v;
                    produced += 1;
                }
            }
            pos += need;
        }
    }
}

fn readVarint(data: []const u8, pos: *usize) ?u64 {
    var result: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        if (pos.* >= data.len) return null;
        const b = data[pos.*];
        pos.* += 1;
        result |= @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) break;
        if (shift >= 63) return null;
        shift += 7;
    }
    return result;
}

fn readZigZag(data: []const u8, pos: *usize) ?i64 {
    const u = readVarint(data, pos) orelse return null;
    return @bitCast((u >> 1) ^ (~(u & 1) +% 1));
}

// ── Value decoders → rendered cell strings ─────────────────────────────

/// Decode `count` PLAIN-encoded values of the leaf's type into rendered cells.
fn plainDecode(a: Allocator, leaf: Leaf, buf: []const u8, count: usize) Error![][]const u8 {
    const pt = leaf.ptype;
    const type_length = leaf.type_length;
    const cells = a.alloc([]const u8, count) catch return error.OutOfMemory;
    var p: usize = 0;
    switch (pt) {
        .boolean => {
            var br = BitReader{ .data = buf };
            for (0..count) |i| cells[i] = if (br.read(1) != 0) "true" else "false";
        },
        .int32 => for (0..count) |i| {
            if (p + 4 > buf.len) return error.Corrupt;
            const v = std.mem.readInt(i32, buf[p..][0..4], .little);
            p += 4;
            cells[i] = try renderInt(a, v, leaf);
        },
        .int64 => for (0..count) |i| {
            if (p + 8 > buf.len) return error.Corrupt;
            const v = std.mem.readInt(i64, buf[p..][0..8], .little);
            p += 8;
            cells[i] = try renderInt(a, v, leaf);
        },
        .int96 => for (0..count) |i| {
            if (p + 12 > buf.len) return error.Corrupt;
            cells[i] = try renderInt96(a, buf[p..][0..12]);
            p += 12;
        },
        .float => for (0..count) |i| {
            if (p + 4 > buf.len) return error.Corrupt;
            const v: f32 = @bitCast(std.mem.readInt(u32, buf[p..][0..4], .little));
            p += 4;
            cells[i] = std.fmt.allocPrint(a, "{d}", .{v}) catch return error.OutOfMemory;
        },
        .double => for (0..count) |i| {
            if (p + 8 > buf.len) return error.Corrupt;
            const v: f64 = @bitCast(std.mem.readInt(u64, buf[p..][0..8], .little));
            p += 8;
            cells[i] = std.fmt.allocPrint(a, "{d}", .{v}) catch return error.OutOfMemory;
        },
        .byte_array => for (0..count) |i| {
            if (p + 4 > buf.len) return error.Corrupt;
            const len = std.mem.readInt(u32, buf[p..][0..4], .little);
            p += 4;
            const end = std.math.add(usize, p, len) catch return error.Corrupt;
            if (end > buf.len) return error.Corrupt;
            cells[i] = if (leaf.converted == .decimal)
                try renderBytesDecimal(a, buf[p..end], leaf.scale)
            else
                buf[p..end]; // borrow (buf lives in arena / input)
            p = end;
        },
        .fixed_len_byte_array => {
            const w: usize = @intCast(@max(type_length, 0));
            for (0..count) |i| {
                if (p + w > buf.len) return error.Corrupt;
                cells[i] = if (leaf.converted == .decimal)
                    try renderBytesDecimal(a, buf[p .. p + w], leaf.scale)
                else
                    buf[p .. p + w];
                p += w;
            }
        },
        else => return error.Unsupported,
    }
    return cells;
}

/// DELTA_BINARY_PACKED: decode `count` integers (Encodings.md §Delta encoding).
pub fn deltaBinaryPacked(a: Allocator, buf: []const u8, count: usize) Error![]i64 {
    var pos: usize = 0;
    const block_size: u64 = readVarint(buf, &pos) orelse return error.Corrupt;
    const miniblocks: u64 = readVarint(buf, &pos) orelse return error.Corrupt;
    const total: u64 = readVarint(buf, &pos) orelse return error.Corrupt;
    const first: i64 = readZigZag(buf, &pos) orelse return error.Corrupt;
    if (miniblocks == 0 or block_size == 0 or block_size % miniblocks != 0) return error.Corrupt;
    const values_per_mini: usize = @intCast(block_size / miniblocks);

    const n: usize = @intCast(@min(total, @as(u64, count)));
    const out = a.alloc(i64, count) catch return error.OutOfMemory;
    if (n == 0) return out;
    out[0] = first;
    var produced: usize = 1;
    var value: i64 = first;

    const widths = a.alloc(u8, @intCast(miniblocks)) catch return error.OutOfMemory;
    while (produced < n) {
        const min_delta: i64 = readZigZag(buf, &pos) orelse return error.Corrupt;
        if (pos + miniblocks > buf.len) return error.Corrupt;
        for (0..@intCast(miniblocks)) |m| {
            widths[m] = buf[pos];
            pos += 1;
        }
        for (0..@intCast(miniblocks)) |m| {
            const w: u32 = widths[m];
            const need = (values_per_mini * w + 7) / 8;
            if (pos + need > buf.len) return error.Corrupt;
            var br = BitReader{ .data = buf[pos .. pos + need] };
            for (0..values_per_mini) |_| {
                const raw = br.read(w);
                // delta = min_delta + zigzag-free raw (raw is unsigned bit-packed)
                const delta: i64 = min_delta +% @as(i64, @bitCast(raw));
                value +%= delta;
                if (produced < n) {
                    out[produced] = value;
                    produced += 1;
                }
            }
            pos += need;
            if (produced >= n) break;
        }
    }
    // If the stream held fewer than `count` values, the remainder stays 0; the
    // caller only consumes the `present` count it expects.
    return out;
}

fn intCellsFromI64(a: Allocator, vals: []const i64, count: usize, leaf: Leaf) Error![][]const u8 {
    const cells = a.alloc([]const u8, count) catch return error.OutOfMemory;
    for (0..count) |i| cells[i] = try renderInt(a, vals[i], leaf);
    return cells;
}

/// DELTA_LENGTH_BYTE_ARRAY: delta-packed lengths then concatenated bytes.
fn deltaLengthByteArray(a: Allocator, buf: []const u8, count: usize) Error![][]const u8 {
    // The length block is self-describing (it carries its own total), and the
    // byte data follows immediately after it. Decode lengths, tracking how many
    // header bytes they consumed.
    var consumed: usize = 0;
    const lengths = try deltaBinaryPackedTracked(a, buf, count, &consumed);
    const cells = a.alloc([]const u8, count) catch return error.OutOfMemory;
    var p = consumed;
    for (0..count) |i| {
        const len: usize = @intCast(@max(lengths[i], 0));
        const end = std.math.add(usize, p, len) catch return error.Corrupt;
        if (end > buf.len) return error.Corrupt;
        cells[i] = buf[p..end];
        p = end;
    }
    return cells;
}

/// DELTA_BYTE_ARRAY: prefix lengths (delta) + suffixes (delta-length-byte-array);
/// each value reuses a prefix of the previous value.
fn deltaByteArray(a: Allocator, buf: []const u8, count: usize) Error![][]const u8 {
    var consumed: usize = 0;
    const prefixes = try deltaBinaryPackedTracked(a, buf, count, &consumed);
    const suffixes = try deltaLengthByteArray(a, buf[consumed..], count);
    const cells = a.alloc([]const u8, count) catch return error.OutOfMemory;
    var prev: []const u8 = "";
    for (0..count) |i| {
        const plen: usize = @intCast(@max(prefixes[i], 0));
        if (plen > prev.len) return error.Corrupt;
        const suffix = suffixes[i];
        const full = a.alloc(u8, plen + suffix.len) catch return error.OutOfMemory;
        @memcpy(full[0..plen], prev[0..plen]);
        @memcpy(full[plen..], suffix);
        cells[i] = full;
        prev = full;
    }
    return cells;
}

/// Like `deltaBinaryPacked` but reports how many input bytes the block used,
/// so callers can find data that follows the block.
fn deltaBinaryPackedTracked(a: Allocator, buf: []const u8, count: usize, consumed: *usize) Error![]i64 {
    var pos: usize = 0;
    const block_size: u64 = readVarint(buf, &pos) orelse return error.Corrupt;
    const miniblocks: u64 = readVarint(buf, &pos) orelse return error.Corrupt;
    const total: u64 = readVarint(buf, &pos) orelse return error.Corrupt;
    const first: i64 = readZigZag(buf, &pos) orelse return error.Corrupt;
    if (miniblocks == 0 or block_size == 0 or block_size % miniblocks != 0) return error.Corrupt;
    const values_per_mini: usize = @intCast(block_size / miniblocks);

    const out = a.alloc(i64, count) catch return error.OutOfMemory;
    const n: usize = @intCast(@min(total, @as(u64, count)));
    var produced_total: u64 = 0; // counts toward `total`, including beyond `count`
    if (total > 0) {
        if (n > 0) out[0] = first;
        produced_total = 1;
        var value: i64 = first;
        var written: usize = 1;
        const widths = a.alloc(u8, @intCast(miniblocks)) catch return error.OutOfMemory;
        outer: while (produced_total < total) {
            const min_delta: i64 = readZigZag(buf, &pos) orelse return error.Corrupt;
            if (pos + miniblocks > buf.len) return error.Corrupt;
            for (0..@intCast(miniblocks)) |m| {
                widths[m] = buf[pos];
                pos += 1;
            }
            for (0..@intCast(miniblocks)) |m| {
                const w: u32 = widths[m];
                const need = (values_per_mini * w + 7) / 8;
                if (pos + need > buf.len) return error.Corrupt;
                var br = BitReader{ .data = buf[pos .. pos + need] };
                for (0..values_per_mini) |_| {
                    const raw = br.read(w);
                    value +%= min_delta +% @as(i64, @bitCast(raw));
                    if (written < n) {
                        out[written] = value;
                        written += 1;
                    }
                    produced_total += 1;
                    if (produced_total >= total) break;
                }
                pos += need;
                if (produced_total >= total) break :outer;
            }
        }
    }
    consumed.* = pos;
    return out;
}

// ── Column decode ──────────────────────────────────────────────────────

/// Decode one column chunk into exactly `num_rows` rendered cells (nulls → "").
fn decodeColumn(a: Allocator, file: []const u8, leaf: Leaf, cm: ColumnMeta, num_rows: usize) Error![][]const u8 {
    const rows = a.alloc([]const u8, num_rows) catch return error.OutOfMemory;
    @memset(rows, "");

    const start: usize = blk: {
        if (cm.dictionary_page_offset) |d| {
            if (d > 0 and d < cm.data_page_offset) break :blk @intCast(d);
        }
        break :blk @intCast(@max(cm.data_page_offset, 0));
    };

    var off = start;
    var produced: usize = 0;
    var dict: ?[][]const u8 = null;
    const def_bw = bitWidth(leaf.max_def_level);

    while (produced < num_rows) {
        if (off >= file.len) return error.Corrupt;
        const ph = try parsePageHeader(file[off..]);
        const body_start = off + ph.header_len;
        const comp_size: usize = @intCast(@max(ph.compressed_size, 0));
        const uncomp_size: usize = @intCast(@max(ph.uncompressed_size, 0));
        const body_end = std.math.add(usize, body_start, comp_size) catch return error.Corrupt;
        if (body_end > file.len) return error.Corrupt;
        const body = file[body_start..body_end];
        off = body_end;

        switch (ph.ptype) {
            .dictionary_page => {
                const page = try decompress(a, cm.codec, body, uncomp_size);
                dict = try plainDecode(a, leaf, page, @intCast(@max(ph.dict_num_values, 0)));
            },
            .data_page => {
                const page = try decompress(a, cm.codec, body, uncomp_size);
                const nv: usize = @intCast(@max(ph.dp_num_values, 0));
                try emitDataPage(a, leaf, def_bw, page, .{
                    .num_values = nv,
                    .encoding = ph.dp_encoding,
                    .v2 = false,
                    .v2_def_len = 0,
                    .v2_rep_len = 0,
                    .num_nulls = 0,
                }, dict, rows, &produced);
            },
            .data_page_v2 => {
                // V2: levels are uncompressed and length-prefixed by the header;
                // only the values region is compressed.
                const rep_len: usize = @intCast(@max(ph.v2_rep_len, 0));
                const def_len: usize = @intCast(@max(ph.v2_def_len, 0));
                if (rep_len + def_len > body.len) return error.Corrupt;
                const levels = body[0 .. rep_len + def_len];
                const values_comp = body[rep_len + def_len ..];
                const values_uncomp = if (ph.v2_compressed)
                    try decompress(a, cm.codec, values_comp, uncomp_size - rep_len - def_len)
                else
                    values_comp;
                // Reassemble [levels][values] so the shared path can read def levels.
                const page = a.alloc(u8, levels.len + values_uncomp.len) catch return error.OutOfMemory;
                @memcpy(page[0..levels.len], levels);
                @memcpy(page[levels.len..], values_uncomp);
                try emitDataPage(a, leaf, def_bw, page, .{
                    .num_values = @intCast(@max(ph.v2_num_values, 0)),
                    .encoding = ph.v2_encoding,
                    .v2 = true,
                    .v2_def_len = def_len,
                    .v2_rep_len = rep_len,
                    .num_nulls = @intCast(@max(ph.v2_num_nulls, 0)),
                }, dict, rows, &produced);
            },
            .index_page => {}, // no row data
            else => return error.Corrupt,
        }
    }
    return rows;
}

const PageInfo = struct {
    num_values: usize,
    encoding: Encoding,
    v2: bool,
    v2_def_len: usize,
    v2_rep_len: usize,
    num_nulls: usize,
};

/// Decode one data page's def levels + values and scatter them into `rows`.
fn emitDataPage(
    a: Allocator,
    leaf: Leaf,
    def_bw: u32,
    page: []const u8,
    info: PageInfo,
    dict: ?[][]const u8,
    rows: [][]const u8,
    produced: *usize,
) Error!void {
    if (leaf.max_rep_level > 0) return error.Unsupported; // nested/repeated columns

    var pos: usize = 0;
    // Definition levels (present/absent). For required columns there are none.
    var defs: ?[]u32 = null;
    if (leaf.max_def_level > 0 and info.num_values > 0) {
        const d = a.alloc(u32, info.num_values) catch return error.OutOfMemory;
        if (info.v2) {
            const def_data = page[info.v2_rep_len .. info.v2_rep_len + info.v2_def_len];
            try rleHybrid(def_data, def_bw, info.num_values, d);
            pos = info.v2_rep_len + info.v2_def_len;
        } else {
            if (pos + 4 > page.len) return error.Corrupt;
            const llen = std.mem.readInt(u32, page[pos..][0..4], .little);
            pos += 4;
            const end = std.math.add(usize, pos, llen) catch return error.Corrupt;
            if (end > page.len) return error.Corrupt;
            try rleHybrid(page[pos..end], def_bw, info.num_values, d);
            pos = end;
        }
        defs = d;
    } else if (info.v2) {
        pos = info.v2_rep_len + info.v2_def_len;
    }

    // Count present (non-null) values this page carries.
    const present: usize = if (defs) |d| blk: {
        var c: usize = 0;
        for (d) |lvl| {
            if (lvl == leaf.max_def_level) c += 1;
        }
        break :blk c;
    } else if (info.v2) info.num_values - info.num_nulls else info.num_values;

    const values_buf = page[pos..];
    const vals = try decodeValues(a, leaf, info.encoding, values_buf, present, dict);

    // Scatter into row positions, honoring nulls.
    var vi: usize = 0;
    for (0..info.num_values) |k| {
        if (produced.* >= rows.len) break;
        const is_present = if (defs) |d| d[k] == leaf.max_def_level else true;
        if (is_present) {
            if (vi >= vals.len) return error.Corrupt;
            rows[produced.*] = vals[vi];
            vi += 1;
        } else {
            rows[produced.*] = "";
        }
        produced.* += 1;
    }
}

/// Decode `present` values per the page encoding into rendered cells.
fn decodeValues(
    a: Allocator,
    leaf: Leaf,
    encoding: Encoding,
    buf: []const u8,
    present: usize,
    dict: ?[][]const u8,
) Error![][]const u8 {
    switch (encoding) {
        .plain => {
            return plainDecode(a, leaf, buf, present);
        },
        .plain_dictionary, .rle_dictionary => {
            const d = dict orelse return error.Corrupt;
            if (present == 0) return a.alloc([]const u8, 0) catch return error.OutOfMemory;
            if (buf.len == 0) return error.Corrupt;
            const idx_bw: u32 = buf[0];
            const idxs = a.alloc(u32, present) catch return error.OutOfMemory;
            try rleHybrid(buf[1..], idx_bw, present, idxs);
            var cells = a.alloc([]const u8, present) catch return error.OutOfMemory;
            for (0..present) |i| {
                if (idxs[i] >= d.len) return error.Corrupt;
                cells[i] = d[idxs[i]];
            }
            return cells;
        },
        .rle => {
            // RLE-encoded boolean data page: 4-byte length prefix + hybrid(bw=1).
            if (leaf.ptype != .boolean) return error.Unsupported;
            if (buf.len < 4) return error.Corrupt;
            const llen = std.mem.readInt(u32, buf[0..4], .little);
            const end = std.math.add(usize, 4, llen) catch return error.Corrupt;
            if (end > buf.len) return error.Corrupt;
            const bits = a.alloc(u32, present) catch return error.OutOfMemory;
            try rleHybrid(buf[4..end], 1, present, bits);
            var cells = a.alloc([]const u8, present) catch return error.OutOfMemory;
            for (0..present) |i| cells[i] = if (bits[i] != 0) "true" else "false";
            return cells;
        },
        .delta_binary_packed => {
            if (leaf.ptype != .int32 and leaf.ptype != .int64) return error.Unsupported;
            const vals = try deltaBinaryPacked(a, buf, present);
            return intCellsFromI64(a, vals, present, leaf);
        },
        .delta_length_byte_array => {
            if (leaf.ptype != .byte_array) return error.Unsupported;
            return deltaLengthByteArray(a, buf, present);
        },
        .delta_byte_array => {
            if (leaf.ptype != .byte_array) return error.Unsupported;
            return deltaByteArray(a, buf, present);
        },
        else => return error.Unsupported,
    }
}

// ── Rendering helpers ──────────────────────────────────────────────────

fn fmtInt(a: Allocator, v: i64) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "{d}", .{v});
}

/// Render an INT32/INT64-backed value honoring its converted type so decimals,
/// dates, timestamps, and unsigned ints read correctly instead of as raw ints.
fn renderInt(a: Allocator, v: i64, leaf: Leaf) Error![]const u8 {
    return switch (leaf.converted) {
        .decimal => renderDecimal(a, v, leaf.scale),
        .date => blk: {
            const c = civilFromDays(v);
            break :blk std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ uYear(c.year), c.month, c.day }) catch error.OutOfMemory;
        },
        .timestamp_millis => renderUnixTimestamp(a, v, 1_000_000),
        .timestamp_micros => renderUnixTimestamp(a, v, 1_000),
        .uint_8, .uint_16, .uint_32, .uint_64 => std.fmt.allocPrint(a, "{d}", .{@as(u64, @bitCast(v))}) catch error.OutOfMemory,
        else => fmtInt(a, v) catch error.OutOfMemory,
    };
}

fn pow10(n: u32) u64 {
    var r: u64 = 1;
    var i: u32 = 0;
    while (i < n) : (i += 1) r *= 10;
    return r;
}

/// Render an unscaled integer `v` as a fixed-point decimal with `scale`
/// fractional digits (e.g. v=15, scale=1 → "1.5").
fn renderDecimal(a: Allocator, v: i64, scale: i32) Error![]const u8 {
    if (scale <= 0) return fmtInt(a, v) catch error.OutOfMemory;
    if (scale > 18) return error.Corrupt;
    const s: u32 = @intCast(scale);
    const neg = v < 0;
    const av: u64 = if (neg) @intCast(-@as(i128, v)) else @intCast(v);
    const pow = pow10(s);
    const ip = av / pow;
    const fp = av % pow;
    const zeros = "000000000000000000"; // 18 zeros
    var tmp: [24]u8 = undefined;
    const frac = std.fmt.bufPrint(&tmp, "{d}", .{fp}) catch unreachable;
    const pad = if (s > frac.len) s - @as(u32, @intCast(frac.len)) else 0;
    return std.fmt.allocPrint(a, "{s}{d}.{s}{s}", .{
        if (neg) "-" else "", ip, zeros[0..pad], frac,
    }) catch error.OutOfMemory;
}

/// Render a big-endian two's-complement decimal (BYTE_ARRAY / FIXED_LEN). Values
/// wider than 64 bits fall back to raw bytes (precision > 18 is uncommon).
fn renderBytesDecimal(a: Allocator, bytes: []const u8, scale: i32) Error![]const u8 {
    if (bytes.len == 0 or bytes.len > 8) return bytes;
    var v: i64 = if (bytes[0] & 0x80 != 0) -1 else 0; // sign-extend
    for (bytes) |b| v = (v << 8) | b;
    return renderDecimal(a, v, scale);
}

/// Render a Unix timestamp (`value` × `ns_per_unit` nanoseconds) as ISO-8601.
fn renderUnixTimestamp(a: Allocator, value: i64, ns_per_unit: i64) Error![]const u8 {
    const day_ns = 86_400 * 1_000_000_000;
    const total_ns = value * ns_per_unit;
    const days = @divFloor(total_ns, day_ns);
    const rem = @mod(total_ns, day_ns); // always in [0, day_ns)
    return fmtDateTime(a, civilFromDays(days), rem);
}

/// Render a 12-byte INT96 (Impala-style timestamp: i64 nanos-of-day + u32
/// Julian day) as an ISO-8601 instant. INT96 is deprecated but still appears in
/// older files, so decode it rather than emit raw bytes.
fn renderInt96(a: Allocator, b: []const u8) Error![]const u8 {
    const nanos_of_day = std.mem.readInt(i64, b[0..8], .little);
    const julian_day = std.mem.readInt(u32, b[8..12], .little);
    const days: i64 = @as(i64, @intCast(julian_day)) - 2440588; // Unix epoch JDN
    return fmtDateTime(a, civilFromDays(days), nanos_of_day);
}

/// Format a civil date plus a `nanos_of_day` (0 ≤ n < 86 400 s) as ISO-8601.
/// Components are formatted as unsigned so the zero-padding never picks up a
/// spurious sign.
fn fmtDateTime(a: Allocator, c: Civil, nanos_of_day: i64) Error![]const u8 {
    var secs = @divFloor(nanos_of_day, 1_000_000_000);
    const ns: u64 = @intCast(@mod(nanos_of_day, 1_000_000_000));
    const hh = @divFloor(secs, 3600);
    secs -= hh * 3600;
    const mm = @divFloor(secs, 60);
    const ss = secs - mm * 60;
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}", .{
        uYear(c.year), c.month, c.day,
        @as(u64, @intCast(hh)),  @as(u64, @intCast(mm)), @as(u64, @intCast(ss)),
        ns,
    }) catch error.OutOfMemory;
}

fn uYear(y: i64) u64 {
    return @intCast(@max(y, 0));
}

const Civil = struct { year: i64, month: u32, day: u32 };

/// Howard Hinnant's days→civil algorithm (proleptic Gregorian).
fn civilFromDays(z_in: i64) Civil {
    const z = z_in + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153); // [0, 11]
    const d = doy - @divFloor(153 * mp + 2, 5) + 1; // [1, 31]
    const m = if (mp < 10) mp + 3 else mp - 9; // [1, 12]
    _ = &z;
    return .{ .year = y + (if (m <= 2) @as(i64, 1) else 0), .month = @intCast(m), .day = @intCast(d) };
}

// ── Public API ─────────────────────────────────────────────────────────

pub const Result = struct { text: []u8, units: usize };

/// Decode a whole-file Parquet buffer to row-major text. `units` is the row
/// count (header line excluded).
pub fn toText(a: Allocator, bytes: []const u8) Error!Result {
    const footer = try locateFooter(bytes);
    const meta = try parseFileMeta(a, bytes[footer.metadata_start..][0..footer.metadata_len]);
    const leaves = try buildLeaves(a, meta.schema);

    for (leaves) |lf| {
        if (lf.max_rep_level > 0) return error.Unsupported; // repeated/nested
    }

    var aw = Writer.Allocating.init(a);
    errdefer aw.deinit();
    const w = &aw.writer;

    // Header line: column names.
    for (leaves, 0..) |lf, i| {
        if (i > 0) w.writeByte(' ') catch return error.OutOfMemory;
        w.writeAll(lf.name) catch return error.OutOfMemory;
    }
    if (leaves.len > 0) w.writeByte('\n') catch return error.OutOfMemory;

    var units: usize = 0;
    for (meta.row_groups) |rg| {
        if (rg.columns.len != leaves.len) return error.Corrupt;
        const nrows: usize = @intCast(@max(rg.num_rows, 0));

        // Decode every column of the row group up front (column-major storage),
        // then transpose to rows.
        const cols = a.alloc([][]const u8, leaves.len) catch return error.OutOfMemory;
        for (leaves, 0..) |lf, ci| {
            cols[ci] = try decodeColumn(a, bytes, lf, rg.columns[ci], nrows);
        }
        for (0..nrows) |r| {
            for (cols, 0..) |col, ci| {
                if (ci > 0) w.writeByte(' ') catch return error.OutOfMemory;
                w.writeAll(col[r]) catch return error.OutOfMemory;
            }
            w.writeByte('\n') catch return error.OutOfMemory;
            units += 1;
        }
    }
    return .{ .text = aw.toOwnedSlice() catch return error.OutOfMemory, .units = units };
}
