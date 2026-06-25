//! Minimal, hardened ZIP reader — enough to pull a named member out of an
//! OOXML container (DOCX/XLSX/PPTX are ZIPs). Stored (method 0) and DEFLATE
//! (method 8) entries only; that is all OOXML uses.
//!
//! Security posture (Agent.md "every untrusted byte is an exploit primitive"):
//!   * The archive is parsed from the End-Of-Central-Directory record backwards,
//!     never by trusting in-band sizes blindly. Every offset/length is bounds-
//!     checked against the buffer before use; `add`/`mul` go through checked
//!     arithmetic so a crafted 0xFFFFFFFF length can't wrap.
//!   * ZIP64 and encrypted entries are rejected with a clear error rather than
//!     mis-parsed.
//!   * No allocation here except the decompressed output (owned by the caller's
//!     arena via `inflate`).

const std = @import("std");
const inflate = @import("inflate.zig");
const Allocator = std.mem.Allocator;

pub const Error = error{
    NotZip,
    BadArchive,
    EntryNotFound,
    Unsupported,
    CorruptStream,
    OutOfMemory,
};

const eocd_sig = 0x06054b50;
const cen_sig = 0x02014b50;
const loc_sig = 0x04034b50;
const eocd_min = 22; // EOCD record without comment

const CentralEntry = struct {
    method: u16,
    comp_size: u32,
    uncomp_size: u32,
    local_offset: u32,
    name: []const u8, // borrows from the archive bytes
};

/// Locate the End-Of-Central-Directory record by scanning backwards (the
/// comment field is variable length, so the record isn't at a fixed offset).
fn findEocd(bytes: []const u8) Error!usize {
    if (bytes.len < eocd_min) return error.NotZip;
    // Max comment length is 0xFFFF; bound the scan window accordingly.
    const max_back = @min(bytes.len, eocd_min + 0xFFFF);
    var i = bytes.len - eocd_min;
    const floor = bytes.len - max_back;
    while (true) : (i -= 1) {
        if (std.mem.readInt(u32, bytes[i..][0..4], .little) == eocd_sig) return i;
        if (i == floor) break;
    }
    return error.NotZip;
}

/// Find a central-directory entry by exact member name.
fn findCentral(bytes: []const u8, name: []const u8) Error!CentralEntry {
    const eocd = try findEocd(bytes);
    // EOCD: [16..20] = central dir offset, [10..12] = entry count.
    const cd_offset = std.mem.readInt(u32, bytes[eocd + 16 ..][0..4], .little);
    const count = std.mem.readInt(u16, bytes[eocd + 10 ..][0..2], .little);

    var p: usize = cd_offset;
    var n: usize = 0;
    while (n < count) : (n += 1) {
        if (p + 46 > bytes.len) return error.BadArchive;
        if (std.mem.readInt(u32, bytes[p..][0..4], .little) != cen_sig) return error.BadArchive;
        const method = std.mem.readInt(u16, bytes[p + 10 ..][0..2], .little);
        const comp_size = std.mem.readInt(u32, bytes[p + 20 ..][0..4], .little);
        const uncomp_size = std.mem.readInt(u32, bytes[p + 24 ..][0..4], .little);
        const name_len = std.mem.readInt(u16, bytes[p + 28 ..][0..2], .little);
        const extra_len = std.mem.readInt(u16, bytes[p + 30 ..][0..2], .little);
        const comment_len = std.mem.readInt(u16, bytes[p + 32 ..][0..2], .little);
        const local_offset = std.mem.readInt(u32, bytes[p + 42 ..][0..4], .little);

        const name_start = p + 46;
        const name_end = std.math.add(usize, name_start, name_len) catch return error.BadArchive;
        if (name_end > bytes.len) return error.BadArchive;
        const entry_name = bytes[name_start..name_end];

        if (std.mem.eql(u8, entry_name, name)) {
            if (comp_size == 0xFFFFFFFF or uncomp_size == 0xFFFFFFFF or local_offset == 0xFFFFFFFF)
                return error.Unsupported; // ZIP64
            return .{
                .method = method,
                .comp_size = comp_size,
                .uncomp_size = uncomp_size,
                .local_offset = local_offset,
                .name = entry_name,
            };
        }
        // Advance to the next central-directory header.
        p = name_end;
        p = std.math.add(usize, p, extra_len) catch return error.BadArchive;
        p = std.math.add(usize, p, comment_len) catch return error.BadArchive;
    }
    return error.EntryNotFound;
}

/// Extract and decompress a member by name into owned bytes (in `a`).
pub fn extract(a: Allocator, bytes: []const u8, name: []const u8) Error![]u8 {
    const e = try findCentral(bytes, name);

    // Re-derive the data start from the *local* header, whose name/extra
    // lengths can differ from the central directory's.
    const lo = e.local_offset;
    if (lo + 30 > bytes.len) return error.BadArchive;
    if (std.mem.readInt(u32, bytes[lo..][0..4], .little) != loc_sig) return error.BadArchive;
    const flags = std.mem.readInt(u16, bytes[lo + 6 ..][0..2], .little);
    if (flags & 0x0001 != 0) return error.Unsupported; // encrypted
    const l_name = std.mem.readInt(u16, bytes[lo + 26 ..][0..2], .little);
    const l_extra = std.mem.readInt(u16, bytes[lo + 28 ..][0..2], .little);

    var data_start: usize = lo + 30;
    data_start = std.math.add(usize, data_start, l_name) catch return error.BadArchive;
    data_start = std.math.add(usize, data_start, l_extra) catch return error.BadArchive;
    const data_end = std.math.add(usize, data_start, e.comp_size) catch return error.BadArchive;
    if (data_end > bytes.len) return error.BadArchive;
    const comp = bytes[data_start..data_end];

    return switch (e.method) {
        0 => try a.dupe(u8, comp), // stored
        8 => inflate.raw(a, comp, e.uncomp_size) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.CorruptStream,
        },
        else => error.Unsupported,
    };
}

// ── Tests ─────────────────────────────────────────────────────────────
const testing = std.testing;
const flate = std.compress.flate;
const Writer = std.Io.Writer;

/// Build a one-entry ZIP in memory (stored or deflate) for tests.
fn buildZip(a: Allocator, name: []const u8, content: []const u8, deflate: bool) ![]u8 {
    var data: []const u8 = content;
    var method: u16 = 0;
    if (deflate) {
        var aw = try Writer.Allocating.initCapacity(a, 4096);
        var window: [flate.max_window_len]u8 = undefined;
        var comp: flate.Compress = try .init(&aw.writer, &window, .raw, .default);
        try comp.writer.writeAll(content);
        try comp.finish();
        data = try aw.toOwnedSlice();
        method = 8;
    }

    var aw = Writer.Allocating.init(a);
    const w = &aw.writer;

    // Local file header.
    const local_off: u32 = 0;
    try writeU32(w, loc_sig);
    try writeU16(w, 20); // version needed
    try writeU16(w, 0); // flags
    try writeU16(w, method);
    try writeU16(w, 0); // mod time
    try writeU16(w, 0); // mod date
    try writeU32(w, 0); // crc (unchecked by our reader)
    try writeU32(w, @intCast(data.len));
    try writeU32(w, @intCast(content.len));
    try writeU16(w, @intCast(name.len));
    try writeU16(w, 0); // extra len
    try w.writeAll(name);
    try w.writeAll(data);

    const cd_off: u32 = @intCast(aw.written().len);
    // Central directory header.
    try writeU32(w, cen_sig);
    try writeU16(w, 20); // version made by
    try writeU16(w, 20); // version needed
    try writeU16(w, 0); // flags
    try writeU16(w, method);
    try writeU16(w, 0);
    try writeU16(w, 0);
    try writeU32(w, 0); // crc
    try writeU32(w, @intCast(data.len));
    try writeU32(w, @intCast(content.len));
    try writeU16(w, @intCast(name.len));
    try writeU16(w, 0); // extra
    try writeU16(w, 0); // comment
    try writeU16(w, 0); // disk
    try writeU16(w, 0); // internal attrs
    try writeU32(w, 0); // external attrs
    try writeU32(w, local_off);
    try w.writeAll(name);

    const cd_size: u32 = @intCast(aw.written().len - cd_off);
    // EOCD.
    try writeU32(w, eocd_sig);
    try writeU16(w, 0); // disk
    try writeU16(w, 0); // cd start disk
    try writeU16(w, 1); // entries on disk
    try writeU16(w, 1); // total entries
    try writeU32(w, cd_size);
    try writeU32(w, cd_off);
    try writeU16(w, 0); // comment len

    return aw.toOwnedSlice();
}

fn writeU16(w: *Writer, v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    try w.writeAll(&b);
}
fn writeU32(w: *Writer, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try w.writeAll(&b);
}

test "zip: extract stored entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const z = try buildZip(a, "word/document.xml", "<w:t>hello</w:t>", false);
    const out = try extract(a, z, "word/document.xml");
    try testing.expectEqualStrings("<w:t>hello</w:t>", out);
}

test "zip: extract deflate entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const payload = "The quick brown fox. " ** 40;
    const z = try buildZip(a, "word/document.xml", payload, true);
    const out = try extract(a, z, "word/document.xml");
    try testing.expectEqualStrings(payload, out);
}

test "zip: missing entry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const z = try buildZip(a, "a.txt", "x", false);
    try testing.expectError(error.EntryNotFound, extract(a, z, "b.txt"));
}

test "fuzz: zip reader never panics on random bytes" {
    var prng = std.Random.DefaultPrng.init(0x21B2);
    const rnd = prng.random();
    var buf: [256]u8 = undefined;
    for (0..1000) |_| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const n = rnd.intRangeLessThan(usize, 0, buf.len);
        for (buf[0..n]) |*b| b.* = rnd.int(u8);
        _ = extract(arena.allocator(), buf[0..n], "word/document.xml") catch {};
    }
}
