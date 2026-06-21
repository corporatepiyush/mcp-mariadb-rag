//! Core data types for the knowledge graph: Entity, Relation, Direction,
//! KnowledgeGraphOut, and their JSON serialization / deserialization.
//!
//! All allocations use the caller-supplied allocator (request-scoped arena, in
//! practice), so no per-type deinit is needed.

const std = @import("std");
const json = @import("../json.zig");

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

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

// -- Entity parsing ----------------------------------------------------

test "entityFromValue parses a valid entity" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\{"name":"Alice","entityType":"person","observations":["likes math","plays piano"]}
    ;
    const parsed = try std.json.parseFromSlice(Value, a, src, .{});
    const e = try entityFromValue(a, parsed.value);

    try testing.expectEqualStrings("Alice", e.name);
    try testing.expectEqualStrings("person", e.entity_type);
    try testing.expectEqual(@as(usize, 2), e.observations.len);
    try testing.expectEqualStrings("likes math", e.observations[0]);
    try testing.expectEqualStrings("plays piano", e.observations[1]);
}

test "entityFromValue rejects missing fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "{\"name\":\"X\"}";
    const parsed = try std.json.parseFromSlice(Value, a, src, .{});
    try testing.expectError(error.MissingField, entityFromValue(a, parsed.value));
}

test "entityFromValue rejects non-object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "\"oops\"";
    const parsed = try std.json.parseFromSlice(Value, arena.allocator(), src, .{});
    try testing.expectError(
        error.ExpectedObject,
        entityFromValue(arena.allocator(), parsed.value),
    );
}

test "entityFromValue rejects non-string name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "{\"name\":42,\"entityType\":\"t\",\"observations\":[]}";
    const parsed = try std.json.parseFromSlice(Value, a, src, .{});
    try testing.expectError(error.ExpectedString, entityFromValue(a, parsed.value));
}

test "entityFromValue rejects non-array observations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "{\"name\":\"X\",\"entityType\":\"t\",\"observations\":\"oops\"}";
    const parsed = try std.json.parseFromSlice(Value, a, src, .{});
    try testing.expectError(error.ExpectedArray, entityFromValue(a, parsed.value));
}

test "entityFromValue handles empty observations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "{\"name\":\"N\",\"entityType\":\"t\",\"observations\":[]}";
    const parsed = try std.json.parseFromSlice(Value, a, src, .{});
    const e = try entityFromValue(a, parsed.value);

    try testing.expectEqualStrings("N", e.name);
    try testing.expectEqual(@as(usize, 0), e.observations.len);
}

// -- Entity serialization ----------------------------------------------

test "Entity.writeJSON" {
    var buf: [512]u8 = undefined;
    var w = Writer.fixed(&buf);
    const e = Entity{
        .name = "Alice",
        .entity_type = "person",
        .observations = &.{ "likes math", "plays piano" },
    };
    try Entity.writeJSON(&w, e);
    try testing.expectEqualStrings(
        "{\"name\":\"Alice\",\"entityType\":\"person\",\"observations\":[\"likes math\",\"plays piano\"]}",
        w.buffered(),
    );
}

test "Entity.writeJSON empty observations" {
    var buf: [256]u8 = undefined;
    var w = Writer.fixed(&buf);
    const e = Entity{ .name = "Bob", .entity_type = "cat", .observations = &.{} };
    try Entity.writeJSON(&w, e);
    try testing.expectEqualStrings(
        "{\"name\":\"Bob\",\"entityType\":\"cat\",\"observations\":[]}",
        w.buffered(),
    );
}

test "Entity.writeJSON escapes special chars in fields" {
    var buf: [512]u8 = undefined;
    var w = Writer.fixed(&buf);
    const e = Entity{ .name = "a\"b\\c", .entity_type = "x\ny", .observations = &.{ "tab\there" } };
    try Entity.writeJSON(&w, e);
    try testing.expectEqualStrings(
        "{\"name\":\"a\\\"b\\\\c\",\"entityType\":\"x\\ny\",\"observations\":[\"tab\\there\"]}",
        w.buffered(),
    );
}

// -- Relation parsing --------------------------------------------------

test "relationFromValue parses a valid relation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "{\"from\":\"Alice\",\"to\":\"Bob\",\"relationType\":\"knows\"}";
    const parsed = try std.json.parseFromSlice(Value, a, src, .{});
    const r = try relationFromValue(a, parsed.value);

    try testing.expectEqualStrings("Alice", r.from);
    try testing.expectEqualStrings("Bob", r.to);
    try testing.expectEqualStrings("knows", r.relation_type);
}

test "relationFromValue rejects missing fields" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "{\"from\":\"A\"}";
    const parsed = try std.json.parseFromSlice(Value, a, src, .{});
    try testing.expectError(error.MissingField, relationFromValue(a, parsed.value));
}

test "relationFromValue rejects non-object" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "42";
    const parsed = try std.json.parseFromSlice(Value, arena.allocator(), src, .{});
    try testing.expectError(
        error.ExpectedObject,
        relationFromValue(arena.allocator(), parsed.value),
    );
}

test "relationFromValue rejects non-string from field" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = "{\"from\":null,\"to\":\"B\",\"relationType\":\"r\"}";
    const parsed = try std.json.parseFromSlice(Value, a, src, .{});
    try testing.expectError(error.ExpectedString, relationFromValue(a, parsed.value));
}

// -- Relation serialization --------------------------------------------

test "Relation.writeJSON" {
    var buf: [256]u8 = undefined;
    var w = Writer.fixed(&buf);
    const r = Relation{ .from = "Alice", .to = "Bob", .relation_type = "knows" };
    try Relation.writeJSON(&w, r);
    try testing.expectEqualStrings(
        "{\"from\":\"Alice\",\"to\":\"Bob\",\"relationType\":\"knows\"}",
        w.buffered(),
    );
}

test "Relation.writeJSON escapes special chars" {
    var buf: [256]u8 = undefined;
    var w = Writer.fixed(&buf);
    const r = Relation{ .from = "a\"b", .to = "c\\d", .relation_type = "x\ny" };
    try Relation.writeJSON(&w, r);
    try testing.expectEqualStrings(
        "{\"from\":\"a\\\"b\",\"to\":\"c\\\\d\",\"relationType\":\"x\\ny\"}",
        w.buffered(),
    );
}

// -- KnowledgeGraphOut serialization -----------------------------------

test "KnowledgeGraphOut.writeJSON" {
    var buf: [1024]u8 = undefined;
    var w = Writer.fixed(&buf);
    const out = KnowledgeGraphOut{
        .entities = &.{
            Entity{ .name = "Alice", .entity_type = "person", .observations = &.{"likes math"} },
        },
        .relations = &.{
            Relation{ .from = "Alice", .to = "Bob", .relation_type = "knows" },
        },
    };
    try KnowledgeGraphOut.writeJSON(&w, out);

    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\"entities\"") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\"relations\"") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\"Alice\"") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\"likes math\"") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\"knows\"") != null);
}

test "KnowledgeGraphOut.writeJSON empty graph" {
    var buf: [128]u8 = undefined;
    var w = Writer.fixed(&buf);
    const out = KnowledgeGraphOut{ .entities = &.{}, .relations = &.{} };
    try KnowledgeGraphOut.writeJSON(&w, out);
    try testing.expectEqualStrings(
        "{\"entities\":[],\"relations\":[]}",
        w.buffered(),
    );
}

// -- Direction ---------------------------------------------------------

test "Direction.parse" {
    try testing.expectEqual(Direction.out, Direction.parse("out"));
    try testing.expectEqual(Direction.incoming, Direction.parse("in"));
    try testing.expectEqual(Direction.both, Direction.parse("both"));
    try testing.expectEqual(Direction.out, Direction.parse("outgoing"));
    try testing.expectEqual(Direction.incoming, Direction.parse("incoming"));
    try testing.expectEqual(Direction.both, Direction.parse("unknown"));
    try testing.expectEqual(Direction.both, Direction.parse(null));
    try testing.expectEqual(Direction.both, Direction.parse(""));
}

test "Direction.parse case insensitive" {
    try testing.expectEqual(Direction.out, Direction.parse("OUT"));
    try testing.expectEqual(Direction.incoming, Direction.parse("Incoming"));
    try testing.expectEqual(Direction.both, Direction.parse("Both"));
}

test "Direction.jsonString" {
    try testing.expectEqualStrings("out", Direction.jsonString(.out));
    try testing.expectEqualStrings("in", Direction.jsonString(.incoming));
    try testing.expectEqualStrings("both", Direction.jsonString(.both));
}

// -- nameHash ----------------------------------------------------------

test "nameHash produces deterministic values" {
    // FNV-1a 64-bit: empty string.
    try testing.expectEqual(nameHash(""), @as(i64, -3750763034362895579));
    // Determinism: same input → same output.
    try testing.expectEqual(nameHash("a"), nameHash("a"));
    try testing.expectEqual(nameHash("Alice"), nameHash("Alice"));
    try testing.expect(nameHash("Alice") != nameHash("Bob"));
    try testing.expect(nameHash("") != nameHash(" "));
}

test "nameHash same input yields same output" {
    try testing.expectEqual(nameHash("some entity name"), nameHash("some entity name"));
}

// -- entitiesFromValue / relationsFromValue ----------------------------

test "entitiesFromValue parses array of entities" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\[{"name":"E1","entityType":"t1","observations":[]},{"name":"E2","entityType":"t2","observations":["obs"]}]
    ;
    const parsed = try std.json.parseFromSlice(Value, a, src, .{});
    const entities = try entitiesFromValue(a, parsed.value);

    try testing.expectEqual(@as(usize, 2), entities.len);
    try testing.expectEqualStrings("E1", entities[0].name);
    try testing.expectEqualStrings("t1", entities[0].entity_type);
    try testing.expectEqual(@as(usize, 0), entities[0].observations.len);
    try testing.expectEqualStrings("E2", entities[1].name);
    try testing.expectEqualStrings("t2", entities[1].entity_type);
    try testing.expectEqual(@as(usize, 1), entities[1].observations.len);
    try testing.expectEqualStrings("obs", entities[1].observations[0]);
}

test "entitiesFromValue rejects non-array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "\"not array\"";
    const parsed = try std.json.parseFromSlice(Value, arena.allocator(), src, .{});
    try testing.expectError(
        error.ExpectedArray,
        entitiesFromValue(arena.allocator(), parsed.value),
    );
}

test "relationsFromValue parses array of relations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\[{"from":"A","to":"B","relationType":"knows"},{"from":"B","to":"C","relationType":"likes"}]
    ;
    const parsed = try std.json.parseFromSlice(Value, a, src, .{});
    const relations = try relationsFromValue(a, parsed.value);

    try testing.expectEqual(@as(usize, 2), relations.len);
    try testing.expectEqualStrings("A", relations[0].from);
    try testing.expectEqualStrings("knows", relations[0].relation_type);
    try testing.expectEqualStrings("B", relations[1].from);
    try testing.expectEqualStrings("likes", relations[1].relation_type);
}

test "relationsFromValue rejects non-array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "{}";
    const parsed = try std.json.parseFromSlice(Value, arena.allocator(), src, .{});
    try testing.expectError(
        error.ExpectedArray,
        relationsFromValue(arena.allocator(), parsed.value),
    );
}
