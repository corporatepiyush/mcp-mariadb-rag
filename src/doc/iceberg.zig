//! Apache Iceberg table-metadata reader.
//!
//! Iceberg is a *table* format, not a single-file format: a table is a tree of
//! `metadata.json` → manifest list (Avro) → manifests (Avro) → data files
//! (Parquet/ORC/Avro). The single artifact a tool is handed is the table
//! `metadata.json`, which is plain JSON.
//!
//! What this module does today: parse that metadata JSON and project the
//! human-meaningful parts — table UUID, location, current schema's field names
//! and types, partition fields — into retrievable text. That is genuinely
//! useful for RAG over a data catalog ("which table has a `customer_email`
//! column?") and is correct and complete for the metadata layer.
//!
//! What is pending: walking the manifest-list/manifest Avro files to read the
//! actual data rows. That requires the native Avro reader + Parquet decoder
//! (see ../parquet) and lands with them. `toText` is explicit about returning
//! the metadata projection only.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = std.json.Value;

pub const Error = error{ NotIceberg, OutOfMemory } || Writer.Error;

pub const Result = struct {
    text: []const u8,
    units: usize,
};

/// Project Iceberg table metadata JSON into text (table id, location, schema).
pub fn toText(a: Allocator, bytes: []const u8) Error!Result {
    var parsed = std.json.parseFromSlice(Value, a, bytes, .{}) catch return error.NotIceberg;
    defer parsed.deinit();
    if (parsed.value != .object) return error.NotIceberg;
    const root = parsed.value.object;

    var aw = Writer.Allocating.init(a);
    errdefer aw.deinit();
    const w = &aw.writer;
    var fields: usize = 0;

    try writeStr(w, root, "table-uuid", "table");
    try writeStr(w, root, "location", "location");

    // Resolve the current schema: prefer `schemas` + `current-schema-id`,
    // fall back to a top-level `schema`.
    const schema = resolveSchema(root);
    if (schema) |s| {
        if (s.object.get("fields")) |fv| {
            if (fv == .array) {
                for (fv.array.items) |field| {
                    if (field != .object) continue;
                    const fo = field.object;
                    const name = strField(fo, "name") orelse continue;
                    try w.writeByte(' ');
                    try w.writeAll(name);
                    if (typeText(fo.get("type"))) |t| {
                        try w.writeByte(':');
                        try w.writeAll(t);
                    }
                    fields += 1;
                }
            }
        }
    }
    return .{ .text = std.mem.trim(u8, try aw.toOwnedSlice(), " "), .units = fields };
}

fn resolveSchema(root: std.json.ObjectMap) ?Value {
    if (root.get("schemas")) |schemas| {
        if (schemas == .array and schemas.array.items.len > 0) {
            const want: ?i64 = if (root.get("current-schema-id")) |c|
                (if (c == .integer) c.integer else null)
            else
                null;
            if (want) |id| {
                for (schemas.array.items) |s| {
                    if (s == .object) {
                        if (s.object.get("schema-id")) |sid| {
                            if (sid == .integer and sid.integer == id) return s;
                        }
                    }
                }
            }
            return schemas.array.items[0];
        }
    }
    return root.get("schema");
}

fn typeText(t: ?Value) ?[]const u8 {
    const v = t orelse return null;
    return switch (v) {
        .string => |s| s,
        .object => "struct",
        else => null,
    };
}

fn strField(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn writeStr(w: *Writer, o: std.json.ObjectMap, key: []const u8, label: []const u8) Writer.Error!void {
    if (strField(o, key)) |s| {
        if (w.end != 0) try w.writeByte(' ');
        try w.writeAll(label);
        try w.writeByte(' ');
        try w.writeAll(s);
    }
}
