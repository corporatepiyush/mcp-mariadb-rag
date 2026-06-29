//! Minimal read-only FlatBuffers accessor — enough to walk Apache Arrow's IPC
//! metadata (`Message`, `Schema`, `Field`, `RecordBatch`, …).
//!
//! Reference: the FlatBuffers internals doc (google/flatbuffers
//! `_internals.md`). Layout, all little-endian:
//!   * The root is a `uoffset` (u32) at the buffer start pointing to the root
//!     table.
//!   * A table begins with an `soffset` (i32) to its vtable: `vtable = tablepos
//!     - soffset`. The vtable is `[u16 vtable_bytes][u16 table_bytes][u16
//!     field_voffset]…`; a field's value is at `tablepos + voffset`, or absent
//!     (use default) when the slot is missing or its voffset is 0.
//!   * Sub-objects (tables, strings, vectors) are referenced by a `uoffset`
//!     stored at the field, relative to the uoffset's own position. Strings and
//!     vectors begin with a u32 length; struct vector elements are stored inline.
//!
//! Untrusted-input discipline: every read is bounds-checked and returns a zero
//! value / `null` / absent rather than indexing out of range, so a malformed or
//! hostile buffer can never read past the slice or panic.

const std = @import("std");

buf: []const u8,

const Fb = @This();

pub fn init(buf: []const u8) Fb {
    return .{ .buf = buf };
}

// ── Bounds-checked little-endian primitives ────────────────────────────

fn u8At(self: Fb, off: usize) u8 {
    return if (off < self.buf.len) self.buf[off] else 0;
}
fn u16At(self: Fb, off: usize) u16 {
    if (off + 2 > self.buf.len) return 0;
    return std.mem.readInt(u16, self.buf[off..][0..2], .little);
}
fn u32At(self: Fb, off: usize) u32 {
    if (off + 4 > self.buf.len) return 0;
    return std.mem.readInt(u32, self.buf[off..][0..4], .little);
}
fn i32At(self: Fb, off: usize) i32 {
    if (off + 4 > self.buf.len) return 0;
    return std.mem.readInt(i32, self.buf[off..][0..4], .little);
}

pub fn i64At(self: Fb, off: usize) i64 {
    if (off + 8 > self.buf.len) return 0;
    return std.mem.readInt(i64, self.buf[off..][0..8], .little);
}
pub fn f64At(self: Fb, off: usize) f64 {
    if (off + 8 > self.buf.len) return 0;
    return @bitCast(std.mem.readInt(u64, self.buf[off..][0..8], .little));
}

// ── Tables ─────────────────────────────────────────────────────────────

pub const Table = struct {
    fb: *const Fb,
    pos: usize,

    /// Absolute offset of field `i`'s value, or 0 when the field is absent
    /// (caller substitutes the default).
    fn fieldOffset(self: Table, i: usize) usize {
        const soffset = self.fb.i32At(self.pos);
        const vt_signed = @as(i64, @intCast(self.pos)) - soffset;
        if (vt_signed < 0) return 0;
        const vt: usize = @intCast(vt_signed);
        const vt_bytes = self.fb.u16At(vt);
        const slot = 4 + i * 2;
        if (slot + 2 > vt_bytes) return 0;
        const voffset = self.fb.u16At(vt + slot);
        if (voffset == 0) return 0;
        return self.pos + voffset;
    }

    pub fn readU8(self: Table, i: usize, default: u8) u8 {
        const off = self.fieldOffset(i);
        return if (off == 0) default else self.fb.u8At(off);
    }
    pub fn readI16(self: Table, i: usize, default: i16) i16 {
        const off = self.fieldOffset(i);
        return if (off == 0) default else @bitCast(self.fb.u16At(off));
    }
    pub fn readI32(self: Table, i: usize, default: i32) i32 {
        const off = self.fieldOffset(i);
        return if (off == 0) default else self.fb.i32At(off);
    }
    pub fn readI64(self: Table, i: usize, default: i64) i64 {
        const off = self.fieldOffset(i);
        return if (off == 0) default else self.fb.i64At(off);
    }
    pub fn readBool(self: Table, i: usize, default: bool) bool {
        const off = self.fieldOffset(i);
        return if (off == 0) default else (self.fb.u8At(off) != 0);
    }

    /// Follow a uoffset field to a sub-table.
    pub fn table(self: Table, i: usize) ?Table {
        const off = self.fieldOffset(i);
        if (off == 0) return null;
        const child = off + self.fb.u32At(off);
        if (child >= self.fb.buf.len) return null;
        return Table{ .fb = self.fb, .pos = child };
    }

    /// Follow a uoffset field to a string (borrowed from the buffer).
    pub fn string(self: Table, i: usize) ?[]const u8 {
        const off = self.fieldOffset(i);
        if (off == 0) return null;
        const sp = off + self.fb.u32At(off);
        const len = self.fb.u32At(sp);
        const start = sp + 4;
        const end = std.math.add(usize, start, len) catch return null;
        if (end > self.fb.buf.len) return null;
        return self.fb.buf[start..end];
    }

    /// Vector handle for field `i` (length + base position of element 0).
    pub fn vector(self: Table, i: usize) Vector {
        const off = self.fieldOffset(i);
        if (off == 0) return .{ .fb = self.fb, .base = 0, .len = 0 };
        const vp = off + self.fb.u32At(off);
        const len = self.fb.u32At(vp);
        return .{ .fb = self.fb, .base = vp + 4, .len = len };
    }
};

pub const Vector = struct {
    fb: *const Fb,
    base: usize,
    len: u32,

    /// Element table `idx` for a vector of tables (`[SomeTable]`).
    pub fn table(self: Vector, idx: usize) ?Table {
        if (idx >= self.len) return null;
        const epos = self.base + idx * 4;
        const child = epos + self.fb.u32At(epos);
        if (child >= self.fb.buf.len) return null;
        return Table{ .fb = self.fb, .pos = child };
    }

    /// Absolute offset of inline element `idx` for a vector of structs/scalars.
    pub fn elem(self: Vector, idx: usize, stride: usize) usize {
        return self.base + idx * stride;
    }
};

/// The root table of a flatbuffer (`uoffset` at offset 0).
pub fn root(self: *const Fb) Table {
    return .{ .fb = self, .pos = self.u32At(0) };
}
