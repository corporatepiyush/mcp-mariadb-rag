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

pub const eocd_sig = 0x06054b50;
pub const cen_sig = 0x02014b50;
pub const loc_sig = 0x04034b50;
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
