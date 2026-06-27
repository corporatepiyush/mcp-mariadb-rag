//! Core data types for the knowledge graph: Entity, Relation, Direction,
//! KnowledgeGraphOut, and their JSON serialization / deserialization.
//!
//! All allocations use the caller-supplied allocator (request-scoped arena, in
//! practice), so no per-type deinit is needed.

const std = @import("std");
pub const json = @import("../json.zig");

const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const ParseError = error{
    MissingField,
    ExpectedString,
    ExpectedArray,
    ExpectedObject,
};

// ── Entity ────────────────────────────────────────────────────────────

/// A knowledge-graph entity with its type and observation strings.
pub const Entity = struct {
    name: []const u8,
    entity_type: []const u8,
    observations: []const []const u8,

    /// Write as JSON: `{"name":"...","entityType":"...","observations":["..."]}`
    pub fn writeJSON(w: *Writer, entity: Entity) !void {
        try w.writeAll("{\"name\":");
        try json.writeQuoted(w, entity.name);
        try w.writeAll(",\"entityType\":");
        try json.writeQuoted(w, entity.entity_type);
        try w.writeAll(",\"observations\":[");
        for (entity.observations, 0..) |obs, i| {
            if (i > 0) try w.writeByte(',');
            try json.writeQuoted(w, obs);
        }
        try w.writeAll("]}");
    }
};

/// Parse a single `Entity` from a JSON value.
pub fn entityFromValue(allocator: Allocator, value: Value) (ParseError || Allocator.Error)!Entity {
    if (value != .object) return error.ExpectedObject;
    const map = value.object;

    const name_val = map.get("name") orelse return error.MissingField;
    if (name_val != .string) return error.ExpectedString;
    const name = try allocator.dupe(u8, name_val.string);

    const etype_val = map.get("entityType") orelse return error.MissingField;
    if (etype_val != .string) return error.ExpectedString;
    const entity_type = try allocator.dupe(u8, etype_val.string);

    const obs_val = map.get("observations") orelse return error.MissingField;
    if (obs_val != .array) return error.ExpectedArray;
    const obs_items = obs_val.array.items;
    const observations = try allocator.alloc([]const u8, obs_items.len);
    for (obs_items, 0..) |item, i| {
        if (item != .string) return error.ExpectedString;
        observations[i] = try allocator.dupe(u8, item.string);
    }

    return Entity{ .name = name, .entity_type = entity_type, .observations = observations };
}

/// Parse an array of entities from a JSON value.
pub fn entitiesFromValue(allocator: Allocator, value: Value) (ParseError || Allocator.Error)![]Entity {
    if (value != .array) return error.ExpectedArray;
    const items = value.array.items;
    const result = try allocator.alloc(Entity, items.len);
    for (items, 0..) |item, i| {
        result[i] = try entityFromValue(allocator, item);
    }
    return result;
}

// ── Relation ──────────────────────────────────────────────────────────

/// A directed relation between two entities with a type label.
pub const Relation = struct {
    from: []const u8,
    to: []const u8,
    relation_type: []const u8,

    /// Write as JSON: `{"from":"...","to":"...","relationType":"..."}`
    pub fn writeJSON(w: *Writer, relation: Relation) !void {
        try w.writeAll("{\"from\":");
        try json.writeQuoted(w, relation.from);
        try w.writeAll(",\"to\":");
        try json.writeQuoted(w, relation.to);
        try w.writeAll(",\"relationType\":");
        try json.writeQuoted(w, relation.relation_type);
        try w.writeByte('}');
    }
};

/// Parse a single `Relation` from a JSON value.
pub fn relationFromValue(allocator: Allocator, value: Value) (ParseError || Allocator.Error)!Relation {
    if (value != .object) return error.ExpectedObject;
    const map = value.object;

    const from_val = map.get("from") orelse return error.MissingField;
    if (from_val != .string) return error.ExpectedString;
    const from = try allocator.dupe(u8, from_val.string);

    const to_val = map.get("to") orelse return error.MissingField;
    if (to_val != .string) return error.ExpectedString;
    const to = try allocator.dupe(u8, to_val.string);

    const rt_val = map.get("relationType") orelse return error.MissingField;
    if (rt_val != .string) return error.ExpectedString;
    const relation_type = try allocator.dupe(u8, rt_val.string);

    return Relation{ .from = from, .to = to, .relation_type = relation_type };
}

/// Parse an array of relations from a JSON value.
pub fn relationsFromValue(allocator: Allocator, value: Value) (ParseError || Allocator.Error)![]Relation {
    if (value != .array) return error.ExpectedArray;
    const items = value.array.items;
    const result = try allocator.alloc(Relation, items.len);
    for (items, 0..) |item, i| {
        result[i] = try relationFromValue(allocator, item);
    }
    return result;
}

// ── KnowledgeGraphOut ────────────────────────────────────────────────

/// Container returned by read_graph / search_nodes and other bulk-read tools.
pub const KnowledgeGraphOut = struct {
    entities: []const Entity,
    relations: []const Relation,

    /// Write as JSON: `{"entities":[...],"relations":[...]}`
    pub fn writeJSON(w: *Writer, out: KnowledgeGraphOut) !void {
        try w.writeAll("{\"entities\":[");
        for (out.entities, 0..) |e, i| {
            if (i > 0) try w.writeByte(',');
            try Entity.writeJSON(w, e);
        }
        try w.writeAll("],\"relations\":[");
        for (out.relations, 0..) |r, i| {
            if (i > 0) try w.writeByte(',');
            try Relation.writeJSON(w, r);
        }
        try w.writeAll("]}");
    }
};

// ── Direction ─────────────────────────────────────────────────────────

/// Relation traversal direction. Canonical input values are "out", "in", "both";
/// the long forms "outgoing" and "incoming" are also accepted.
pub const Direction = enum(u8) {
    out,
    incoming,
    both,

    fn eqCI(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |ca, cb| {
            if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
        }
        return true;
    }

    /// Parse from the string values used in tool input schemas.
    pub fn parse(s: ?[]const u8) Direction {
        const str = s orelse return .both;
        if (eqCI(str, "out") or eqCI(str, "outgoing")) return .out;
        if (eqCI(str, "in") or eqCI(str, "incoming")) return .incoming;
        return .both;
    }

    /// Canonical JSON string for this variant ("out" / "in" / "both").
    pub fn jsonString(dir: Direction) []const u8 {
        return switch (dir) {
            .out => "out",
            .incoming => "in",
            .both => "both",
        };
    }
};

// ── Utility ───────────────────────────────────────────────────────────

/// FNV-1a 64-bit hash.  Used by the in-memory LRU cache keyed on entity name.
pub fn nameHash(name: []const u8) i64 {
    var h: u64 = 0xcbf29ce484222325;
    for (name) |b| {
        h ^= @as(u64, b);
        h *%= 0x100000001b3;
    }
    return @as(i64, @bitCast(h));
}
