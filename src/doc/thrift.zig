//! Thrift Compact Protocol reader (read-only, bounded, no allocation).
//!
//! Parquet frames its `FileMetaData` and every `PageHeader` as Thrift
//! compact-protocol structs, so a correct Parquet reader needs a correct
//! compact-protocol decoder first. This implements the wire format exactly as
//! specified in Apache Thrift's `doc/specs/thrift-compact-protocol.md`:
//!
//!   * unsigned LEB128 varints (7 data bits/byte, MSB = continuation),
//!   * zig-zag transform for signed i16/i32/i64,
//!   * field headers as `(delta << 4) | type`, with a zig-zag varint field id
//!     when the 4-bit delta is 0,
//!   * collection headers as `(size << 4) | elem-type`, with a varint size when
//!     size ≥ 15.
//!
//! Untrusted-input discipline (Agent.md: "every untrusted byte is an exploit
//! primitive"): the reader never indexes past its slice. Every read is bounds
//! checked and returns `error.Truncated`/`error.Malformed` rather than
//! panicking, and `skip` is depth-limited so a hostile nested struct cannot blow
//! the stack.

const std = @import("std");

pub const Error = error{ Truncated, Malformed };

/// Compact-protocol type nibbles (used in both field headers and collection
/// element-type slots). `bool_true`/`bool_false` carry a struct-field boolean's
/// value in the type nibble itself.
pub const CType = enum(u4) {
    stop = 0,
    bool_true = 1,
    bool_false = 2,
    i8 = 3,
    i16 = 4,
    i32 = 5,
    i64 = 6,
    double = 7,
    binary = 8,
    list = 9,
    set = 10,
    map = 11,
    @"struct" = 12,
    _,
};

pub const Field = struct {
    /// Set for the STOP marker that terminates a struct.
    stop: bool,
    ctype: CType,
    id: i16,
};

pub const ListHeader = struct {
    elem: CType,
    size: u32,
};

/// Cursor over a borrowed byte slice. All decoding state is the position; the
/// caller drives the struct grammar (`fieldBegin` … `skip`/typed read … until
/// STOP), exactly mirroring how the Parquet structs are laid out.
pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,
    /// Field id of the last field read, per struct scope. The compact protocol
    /// stores deltas relative to it; callers reset it to 0 when entering a
    /// struct via `enterStruct`.
    last_field_id: i16 = 0,

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf };
    }

    pub fn byte(self: *Reader) Error!u8 {
        if (self.pos >= self.buf.len) return error.Truncated;
        const b = self.buf[self.pos];
        self.pos += 1;
        return b;
    }

    /// Unsigned LEB128 varint, capped at 64 bits. Rejects overlong encodings
    /// rather than overflowing the shift.
    pub fn varint(self: *Reader) Error!u64 {
        var result: u64 = 0;
        var shift: u32 = 0;
        while (true) {
            const b = try self.byte();
            if (shift >= 64) return error.Malformed; // varint too long
            result |= @as(u64, b & 0x7f) << @intCast(shift);
            if (b & 0x80 == 0) break;
            shift += 7;
        }
        return result;
    }

    pub fn zigzag(self: *Reader) Error!i64 {
        const u = try self.varint();
        return @bitCast((u >> 1) ^ (~(u & 1) +% 1));
    }

    pub fn i32v(self: *Reader) Error!i32 {
        const v = try self.zigzag();
        if (v < std.math.minInt(i32) or v > std.math.maxInt(i32)) return error.Malformed;
        return @intCast(v);
    }

    pub fn i16v(self: *Reader) Error!i16 {
        const v = try self.zigzag();
        if (v < std.math.minInt(i16) or v > std.math.maxInt(i16)) return error.Malformed;
        return @intCast(v);
    }

    pub fn double(self: *Reader) Error!f64 {
        const bytes = try self.take(8);
        // Compact protocol stores doubles little-endian.
        return @bitCast(std.mem.readInt(u64, bytes[0..8], .little));
    }

    /// Borrow `n` bytes from the buffer, advancing the cursor.
    pub fn take(self: *Reader, n: usize) Error![]const u8 {
        const end = std.math.add(usize, self.pos, n) catch return error.Truncated;
        if (end > self.buf.len) return error.Truncated;
        const out = self.buf[self.pos..end];
        self.pos = end;
        return out;
    }

    /// Length-prefixed binary/string: varint length then that many bytes,
    /// borrowed from the input.
    pub fn binary(self: *Reader) Error![]const u8 {
        const n = try self.varint();
        return self.take(@intCast(n));
    }

    /// Enter a nested struct: save and reset the field-id delta base, returning
    /// the previous base so the caller can restore it on exit.
    pub fn enterStruct(self: *Reader) i16 {
        const prev = self.last_field_id;
        self.last_field_id = 0;
        return prev;
    }

    pub fn exitStruct(self: *Reader, prev: i16) void {
        self.last_field_id = prev;
    }

    /// Read a struct field header. Returns `stop = true` at the STOP byte.
    pub fn fieldBegin(self: *Reader) Error!Field {
        const b = try self.byte();
        if (b == 0) return .{ .stop = true, .ctype = .stop, .id = 0 };
        const ctype: CType = @enumFromInt(@as(u4, @intCast(b & 0x0f)));
        const delta: u4 = @intCast(b >> 4);
        var id: i16 = undefined;
        if (delta == 0) {
            id = try self.i16v(); // explicit zig-zag field id
        } else {
            id = self.last_field_id + @as(i16, delta);
        }
        self.last_field_id = id;
        return .{ .stop = false, .ctype = ctype, .id = id };
    }

    /// Boolean struct field: the value lives in the field header's type nibble.
    pub fn boolFromField(f: Field) bool {
        return f.ctype == .bool_true;
    }

    pub fn listBegin(self: *Reader) Error!ListHeader {
        const b = try self.byte();
        const elem: CType = @enumFromInt(@as(u4, @intCast(b & 0x0f)));
        var size: u32 = @intCast(b >> 4);
        if (size == 15) {
            const s = try self.varint();
            if (s > std.math.maxInt(u32)) return error.Malformed;
            size = @intCast(s);
        }
        return .{ .elem = elem, .size = size };
    }

    /// Read a boolean element inside a collection (a full 0/non-0 byte, unlike
    /// the in-header encoding used for struct fields).
    pub fn boolElem(self: *Reader) Error!bool {
        return (try self.byte()) != 0;
    }

    /// Skip a value of compact type `ct`, including nested containers. Depth is
    /// bounded so adversarial nesting cannot exhaust the stack.
    pub fn skip(self: *Reader, ct: CType) Error!void {
        return self.skipDepth(ct, 0);
    }

    fn skipDepth(self: *Reader, ct: CType, depth: u8) Error!void {
        if (depth > 64) return error.Malformed;
        switch (ct) {
            .bool_true, .bool_false => {}, // value already in the type nibble
            .i8 => _ = try self.byte(),
            .i16, .i32, .i64 => _ = try self.varint(),
            .double => _ = try self.take(8),
            .binary => _ = try self.binary(),
            .list, .set => {
                const h = try self.listBegin();
                var i: usize = 0;
                while (i < h.size) : (i += 1) {
                    if (h.elem == .bool_true or h.elem == .bool_false) {
                        _ = try self.byte();
                    } else {
                        try self.skipDepth(h.elem, depth + 1);
                    }
                }
            },
            .map => {
                // size varint, then a key/value type byte, then size*(k,v).
                const size = try self.varint();
                if (size != 0) {
                    const kv = try self.byte();
                    const ktype: CType = @enumFromInt(@as(u4, @intCast(kv >> 4)));
                    const vtype: CType = @enumFromInt(@as(u4, @intCast(kv & 0x0f)));
                    var i: u64 = 0;
                    while (i < size) : (i += 1) {
                        try self.skipDepth(ktype, depth + 1);
                        try self.skipDepth(vtype, depth + 1);
                    }
                }
            },
            .@"struct" => {
                const prev = self.enterStruct();
                defer self.exitStruct(prev);
                while (true) {
                    const f = try self.fieldBegin();
                    if (f.stop) break;
                    try self.skipDepth(f.ctype, depth + 1);
                }
            },
            .stop, _ => return error.Malformed,
        }
    }
};
