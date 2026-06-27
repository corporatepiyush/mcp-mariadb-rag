//! JSON and NDJSON (JSON Lines) text extraction.
//!
//! Goal: turn structured JSON into a readable, embeddable text projection for
//! the RAG chunker — object keys kept inline with their values so semantic
//! context survives ("title Foo author Bar"), arrays flattened, scalars printed
//! verbatim. This is extraction, not pretty-printing: structure punctuation is
//! dropped, content is kept.
//!
//! Discipline (Agent.md):
//!   * Parsing uses `std.json` (native Zig, bounded nesting) over the request
//!     arena — one allocation domain, freed by arena reset.
//!   * The tree walk is *iterative* with an explicit work stack (no native
//!     recursion → no stack-overflow surface on adversarial nesting).
//!   * NDJSON streams line-by-line; one malformed line is skipped, not fatal,
//!     so a 10M-line file isn't lost to a single bad record.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;

pub const Error = error{OutOfMemory} || Writer.Error;

pub const Result = struct {
    text: []u8,
    units: usize, // number of top-level JSON values rendered
};

/// A frame on the explicit walk stack.
///
/// `object` holds the `ObjectMap` *by value*: the map struct is a few words of
/// pointers into the parse arena, so copying it is cheap and — crucially —
/// stable, whereas a pointer into a by-value `Value` capture would dangle the
/// moment `push` returned.
const Frame = union(enum) {
    /// Emit a scalar then pop.
    scalar: Value,
    /// Iterate an object's entries from `idx`.
    object: struct { map: std.json.ObjectMap, idx: usize },
    /// Iterate an array's items from `idx`.
    array: struct { items: []const Value, idx: usize },
};

/// Render one parsed value into `w` iteratively. `sep_pending` tracks whether a
/// separating space is owed before the next token.
fn renderValue(a: Allocator, root: Value, w: *Writer) Error!void {
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(a);
    var sep = false;

    try push(a, &stack, root);
    while (stack.items.len > 0) {
        const top = &stack.items[stack.items.len - 1];
        switch (top.*) {
            .scalar => |v| {
                _ = stack.pop();
                try writeScalar(w, v, &sep);
            },
            .object => |*st| {
                if (st.idx >= st.map.count()) {
                    _ = stack.pop();
                    continue;
                }
                const entry_key = st.map.keys()[st.idx];
                const entry_val = st.map.values()[st.idx];
                st.idx += 1;
                // Emit the key as context, then schedule the value.
                if (sep) try w.writeByte(' ');
                try w.writeAll(entry_key);
                sep = true;
                try push(a, &stack, entry_val);
            },
            .array => |*st| {
                if (st.idx >= st.items.len) {
                    _ = stack.pop();
                    continue;
                }
                const item = st.items[st.idx];
                st.idx += 1;
                try push(a, &stack, item);
            },
        }
    }
}

fn push(a: Allocator, stack: *std.ArrayList(Frame), v: Value) Error!void {
    switch (v) {
        .object => |m| try stack.append(a, .{ .object = .{ .map = m, .idx = 0 } }),
        .array => |arr| try stack.append(a, .{ .array = .{ .items = arr.items, .idx = 0 } }),
        else => try stack.append(a, .{ .scalar = v }),
    }
}

fn writeScalar(w: *Writer, v: Value, sep: *bool) Error!void {
    switch (v) {
        .null => {}, // drop nulls
        .bool => |b| {
            if (sep.*) try w.writeByte(' ');
            try w.writeAll(if (b) "true" else "false");
            sep.* = true;
        },
        .integer => |n| {
            if (sep.*) try w.writeByte(' ');
            try w.print("{d}", .{n});
            sep.* = true;
        },
        .float => |f| {
            if (sep.*) try w.writeByte(' ');
            try w.print("{d}", .{f});
            sep.* = true;
        },
        .number_string => |s| {
            if (sep.*) try w.writeByte(' ');
            try w.writeAll(s);
            sep.* = true;
        },
        .string => |s| {
            if (s.len == 0) return;
            if (sep.*) try w.writeByte(' ');
            try w.writeAll(s);
            sep.* = true;
        },
        .object, .array => unreachable, // containers never reach here
    }
}

/// Extract a single JSON document.
pub fn toText(a: Allocator, bytes: []const u8) Error!Result {
    var aw = Writer.Allocating.init(a);
    errdefer aw.deinit();
    var parsed = std.json.parseFromSlice(Value, a, bytes, .{}) catch {
        // Not valid JSON after all — fall back to raw passthrough.
        try aw.writer.writeAll(std.mem.trim(u8, bytes, " \t\r\n"));
        return .{ .text = try aw.toOwnedSlice(), .units = 0 };
    };
    defer parsed.deinit();
    try renderValue(a, parsed.value, &aw.writer);
    return .{ .text = try aw.toOwnedSlice(), .units = 1 };
}

/// Extract NDJSON: one JSON value per non-empty line. Malformed lines are
/// skipped. Each rendered record is separated by a newline.
pub fn toTextNd(a: Allocator, bytes: []const u8) Error!Result {
    var aw = Writer.Allocating.init(a);
    errdefer aw.deinit();
    var units: usize = 0;
    var line_it = std.mem.splitScalar(u8, bytes, '\n');
    while (line_it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(Value, a, line, .{}) catch continue;
        defer parsed.deinit();
        if (units > 0) try aw.writer.writeByte('\n');
        try renderValue(a, parsed.value, &aw.writer);
        units += 1;
    }
    return .{ .text = try aw.toOwnedSlice(), .units = units };
}
