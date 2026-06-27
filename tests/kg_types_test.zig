//! Tests for src/kg/types.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/kg/types.zig");
const Io = std.Io;

const Direction = srcmod.Direction;
const Entity = srcmod.Entity;
const KnowledgeGraphOut = srcmod.KnowledgeGraphOut;
const Relation = srcmod.Relation;
const Value = std.json.Value;
const Writer = std.Io.Writer;
const entitiesFromValue = srcmod.entitiesFromValue;
const entityFromValue = srcmod.entityFromValue;
const json = srcmod.json;
const nameHash = srcmod.nameHash;
const relationFromValue = srcmod.relationFromValue;
const relationsFromValue = srcmod.relationsFromValue;

// ── Tests ─────────────────────────────────────────────────────────────


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
