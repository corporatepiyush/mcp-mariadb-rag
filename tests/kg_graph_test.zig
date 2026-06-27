//! Tests for src/kg/graph.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/kg/graph.zig");
const Io = std.Io;

const Writer = std.Io.Writer;
const anyObservations = srcmod.anyObservations;
const observationsToJson = srcmod.observationsToJson;
const parseObservationsJson = srcmod.parseObservationsJson;
const types = srcmod.types;
const writeAllEntityObservations = srcmod.writeAllEntityObservations;
const writeBfsBoth = srcmod.writeBfsBoth;
const writeBfsExpand = srcmod.writeBfsExpand;
const writeCountEntities = srcmod.writeCountEntities;
const writeDegree = srcmod.writeDegree;
const writeDeleteEntities = srcmod.writeDeleteEntities;
const writeDeleteObservations = srcmod.writeDeleteObservations;
const writeDeleteRelation = srcmod.writeDeleteRelation;
const writeEntityExists = srcmod.writeEntityExists;
const writeEntityTypeCounts = srcmod.writeEntityTypeCounts;
const writeFulltextSearch = srcmod.writeFulltextSearch;
const writeGetEntitiesByNames = srcmod.writeGetEntitiesByNames;
const writeGetEntity = srcmod.writeGetEntity;
const writeGraphStatistics = srcmod.writeGraphStatistics;
const writeInsertEntity = srcmod.writeInsertEntity;
const writeInsertObservation = srcmod.writeInsertObservation;
const writeInsertRelation = srcmod.writeInsertRelation;
const writeInsertRelations = srcmod.writeInsertRelations;
const writeNameList = srcmod.writeNameList;
const writeOutgoingRelations = srcmod.writeOutgoingRelations;
const writeReadEntities = srcmod.writeReadEntities;
const writeRelationTypeCounts = srcmod.writeRelationTypeCounts;
const writeRelationsForEntitySet = srcmod.writeRelationsForEntitySet;
const writeSearchEntities = srcmod.writeSearchEntities;
const writeSearchRelations = srcmod.writeSearchRelations;

test "writeGetEntity" {
    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings(
        "SELECT entity_type, observations FROM `rag_entity` WHERE name = 'Alice'",
        try renderSql(&buf, writeGetEntity, .{"Alice"}),
    );
}

test "writeGetEntity escapes single quotes in name" {
    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings(
        "SELECT entity_type, observations FROM `rag_entity` WHERE name = 'O''Brien'",
        try renderSql(&buf, writeGetEntity, .{"O'Brien"}),
    );
}

test "writeInsertEntity" {
    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings(
        "INSERT INTO `rag_entity` (name, entity_type, observations) VALUES ('Alice','person','[]')",
        try renderSql(&buf, writeInsertEntity, .{ "Alice", "person", "[]" }),
    );
}

test "writeDeleteEntities" {
    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings(
        "DELETE FROM `rag_entity` WHERE name IN ('A', 'B')",
        try renderSql(&buf, writeDeleteEntities, .{ &[_][]const u8{ "A", "B" } }),
    );
}

test "writeEntityExists" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "SELECT 1 FROM `rag_entity` WHERE name = 'Alice'",
        try renderSql(&buf, writeEntityExists, .{"Alice"}),
    );
}

test "writeInsertObservation" {
    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings(
        "INSERT INTO `rag_observation` (entity_name, content) VALUES ('Alice','likes math')",
        try renderSql(&buf, writeInsertObservation, .{ "Alice", "likes math" }),
    );
}

test "writeDeleteObservations" {
    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings(
        "DELETE FROM `rag_observation` WHERE entity_name = 'Alice' AND content IN ('obs1', 'obs2')",
        try renderSql(&buf, writeDeleteObservations, .{ "Alice", &[_][]const u8{ "obs1", "obs2" } }),
    );
}

test "writeInsertRelation" {
    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings(
        "INSERT INTO `rag_relation` (from_entity, relation_type, to_entity) VALUES ('Alice','knows','Bob')",
        try renderSql(&buf, writeInsertRelation, .{ "Alice", "knows", "Bob" }),
    );
}

test "writeDeleteRelation" {
    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings(
        "DELETE FROM `rag_relation` WHERE from_entity = 'A' AND relation_type = 'r' AND to_entity = 'B'",
        try renderSql(&buf, writeDeleteRelation, .{ "A", "r", "B" }),
    );
}

test "writeSearchRelations with no filters" {
    var buf: [2048]u8 = undefined;
    try testing.expectEqualStrings(
        "SELECT r.from_entity, r.relation_type, r.to_entity FROM `rag_relation` r WHERE 1=1 ORDER BY r.from_entity, r.to_entity",
        try renderSql(&buf, writeSearchRelations, .{ null, null, null }),
    );
}

test "writeSearchRelations with from filter" {
    var buf: [2048]u8 = undefined;
    const result = try renderSql(&buf, writeSearchRelations, .{ "Alice", @as(?[]const u8, null), @as(?[]const u8, null) });
    try testing.expect(std.mem.indexOf(u8, result, "r.from_entity = 'Alice'") != null);
}

test "writeSearchRelations with all three filters" {
    var buf: [2048]u8 = undefined;
    const result = try renderSql(&buf, writeSearchRelations, .{ "A", "B", "knows" });
    try testing.expect(std.mem.indexOf(u8, result, "r.from_entity = 'A'") != null);
    try testing.expect(std.mem.indexOf(u8, result, "r.to_entity = 'B'") != null);
    try testing.expect(std.mem.indexOf(u8, result, "r.relation_type = 'knows'") != null);
}

test "writeReadEntities no filter" {
    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings(
        "SELECT name, entity_type, observations FROM `rag_entity` ORDER BY name",
        try renderSql(&buf, writeReadEntities, .{ @as(?[]const u8, null), @as(?u64, null), @as(?u64, null) }),
    );
}

test "writeReadEntities with type filter and limit" {
    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings(
        "SELECT name, entity_type, observations FROM `rag_entity` WHERE entity_type = 'person' ORDER BY name LIMIT 10",
        try renderSql(&buf, writeReadEntities, .{ "person", @as(?u64, 10), @as(?u64, null) }),
    );
}

test "writeReadEntities with limit and offset" {
    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings(
        "SELECT name, entity_type, observations FROM `rag_entity` ORDER BY name LIMIT 5 OFFSET 10",
        try renderSql(&buf, writeReadEntities, .{ @as(?[]const u8, null), @as(?u64, 5), @as(?u64, 10) }),
    );
}

test "writeSearchEntities" {
    var buf: [2048]u8 = undefined;
    try testing.expectEqualStrings(
        "SELECT name, entity_type, observations FROM `rag_entity` WHERE (name LIKE '%alice%' OR entity_type LIKE '%alice%') ORDER BY name",
        try renderSql(&buf, writeSearchEntities, .{ "alice", @as(?[]const u8, null), @as(?u64, null), @as(?u64, null) }),
    );
}

test "writeSearchEntities with filter and limit" {
    var buf: [2048]u8 = undefined;
    const result = try renderSql(&buf, writeSearchEntities, .{ "query", "person", @as(?u64, 20), @as(?u64, 0) });
    try testing.expect(std.mem.indexOf(u8, result, "AND entity_type = 'person'") != null);
    try testing.expect(std.mem.indexOf(u8, result, "LIMIT 20") != null);
    try testing.expect(std.mem.indexOf(u8, result, "OFFSET 0") != null);
}

test "writeRelationsForEntitySet" {
    var buf: [2048]u8 = undefined;
    try testing.expectEqualStrings(
        "SELECT from_entity, relation_type, to_entity FROM `rag_relation` WHERE from_entity IN ('A', 'B') OR to_entity IN ('A', 'B')",
        try renderSql(&buf, writeRelationsForEntitySet, .{ &[_][]const u8{ "A", "B" } }),
    );
}

test "writeOutgoingRelations" {
    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings(
        "SELECT from_entity, relation_type, to_entity FROM `rag_relation` WHERE from_entity IN ('A')",
        try renderSql(&buf, writeOutgoingRelations, .{ &[_][]const u8{"A"} }),
    );
}

test "writeCountEntities" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "SELECT COUNT(*) FROM `rag_entity`",
        try renderSql(&buf, writeCountEntities, .{}),
    );
}

test "writeEntityTypeCounts" {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "SELECT entity_type, COUNT(*) as cnt FROM `rag_entity` GROUP BY entity_type ORDER BY cnt DESC",
        try renderSql(&buf, writeEntityTypeCounts, .{}),
    );
}

test "writeRelationTypeCounts" {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "SELECT relation_type, COUNT(*) as cnt FROM `rag_relation` GROUP BY relation_type ORDER BY cnt DESC",
        try renderSql(&buf, writeRelationTypeCounts, .{}),
    );
}

test "writeDegree out" {
    var buf: [2048]u8 = undefined;
    try testing.expectEqualStrings(
        "SELECT COUNT(*) FROM `rag_relation` WHERE from_entity = 'Alice'",
        try renderSql(&buf, writeDegree, .{ "Alice", types.Direction.out }),
    );
}

test "writeDegree incoming" {
    var buf: [2048]u8 = undefined;
    try testing.expectEqualStrings(
        "SELECT COUNT(*) FROM `rag_relation` WHERE to_entity = 'Alice'",
        try renderSql(&buf, writeDegree, .{ "Alice", types.Direction.incoming }),
    );
}

test "writeDegree both" {
    var buf: [2048]u8 = undefined;
    const result = try renderSql(&buf, writeDegree, .{ "Alice", types.Direction.both });
    try testing.expect(std.mem.indexOf(u8, result, "from_entity = 'Alice'") != null);
    try testing.expect(std.mem.indexOf(u8, result, "to_entity = 'Alice'") != null);
}

test "observationsToJson empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try observationsToJson(arena.allocator(), &.{});
    try testing.expectEqualStrings("[]", result);
}

test "observationsToJson with values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try observationsToJson(arena.allocator(), &.{ "hello", "world" });
    try testing.expectEqualStrings("[\"hello\",\"world\"]", result);
}

test "observationsToJson escapes special chars" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try observationsToJson(arena.allocator(), &.{"it's fine"});
    try testing.expectEqualStrings("[\"it's fine\"]", result);
}

test "parseObservationsJson empty array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try parseObservationsJson(arena.allocator(), "[]");
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "parseObservationsJson with values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try parseObservationsJson(arena.allocator(), "[\"a\",\"b\"]");
    try testing.expectEqual(@as(usize, 2), result.len);
    try testing.expectEqualStrings("a", result[0]);
    try testing.expectEqualStrings("b", result[1]);
}

test "parseObservationsJson round-trips observationsToJson output" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const json_str = try observationsToJson(arena.allocator(), &.{ "hello", "it's fine", "tab\there" });
    const result = try parseObservationsJson(arena.allocator(), json_str);
    try testing.expectEqual(@as(usize, 3), result.len);
    try testing.expectEqualStrings("hello", result[0]);
    try testing.expectEqualStrings("it's fine", result[1]);
    try testing.expectEqualStrings("tab\there", result[2]);
}

test "parseObservationsJson malformed returns empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try parseObservationsJson(arena.allocator(), "not json");
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "writeNameList" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "'A', 'B', 'C'",
        try renderSql(&buf, writeNameList, .{ &[_][]const u8{ "A", "B", "C" } }),
    );
}

test "writeNameList single" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "'only'",
        try renderSql(&buf, writeNameList, .{ &[_][]const u8{"only"} }),
    );
}

test "writeBfsBoth" {
    var buf: [2048]u8 = undefined;
    const result = try renderSql(&buf, writeBfsBoth, .{ &[_][]const u8{ "A", "B" } });
    try testing.expect(std.mem.indexOf(u8, result, "SELECT from_entity AS parent, to_entity AS child FROM") != null);
    try testing.expect(std.mem.indexOf(u8, result, "WHERE to_entity IN ('A', 'B')") != null);
    try testing.expect(std.mem.indexOf(u8, result, "UNION SELECT to_entity, from_entity FROM") != null);
    try testing.expect(std.mem.indexOf(u8, result, "WHERE from_entity IN ('A', 'B')") != null);
}

test "writeBfsExpand outgoing" {
    var buf: [2048]u8 = undefined;
    const result = try renderSql(&buf, writeBfsExpand, .{ &[_][]const u8{ "A" }, types.Direction.out });
    try testing.expect(std.mem.indexOf(u8, result, "AS parent, to_entity AS child FROM") != null);
    try testing.expect(std.mem.indexOf(u8, result, "WHERE from_entity IN ('A')") != null);
}

test "writeBfsExpand incoming" {
    var buf: [2048]u8 = undefined;
    const result = try renderSql(&buf, writeBfsExpand, .{ &[_][]const u8{ "A" }, types.Direction.incoming });
    try testing.expect(std.mem.indexOf(u8, result, "AS parent, from_entity AS child FROM") != null);
    try testing.expect(std.mem.indexOf(u8, result, "WHERE to_entity IN ('A')") != null);
}

test "writeBfsExpand both" {
    var buf: [4096]u8 = undefined;
    const result = try renderSql(&buf, writeBfsExpand, .{ &[_][]const u8{ "A", "B" }, types.Direction.both });
    try testing.expect(std.mem.indexOf(u8, result, "UNION") != null);
}

test "writeFulltextSearch" {
    var buf: [4096]u8 = undefined;
    const result = try renderSql(&buf, writeFulltextSearch, .{ "alice", 10 });
    try testing.expect(std.mem.indexOf(u8, result, "SELECT DISTINCT e.name") != null);
    try testing.expect(std.mem.indexOf(u8, result, "LIKE '%alice%'") != null);
    // No bare `||` in LIKE patterns — build as a single literal.
    try testing.expect(std.mem.indexOf(u8, result, "||") == null);
    try testing.expect(std.mem.indexOf(u8, result, "JOIN `rag_observation` o ON o.entity_name = e.name") != null);
    try testing.expect(std.mem.indexOf(u8, result, "LIMIT 10") != null);
}

// -- Regression: search must not emit bare `||` in LIKE patterns -----------------

test "writeSearchEntities builds a single LIKE literal, never `||`" {
    var buf: [2048]u8 = undefined;
    const result = try renderSql(&buf, writeSearchEntities, .{ "alice", @as(?[]const u8, null), @as(?u64, null), @as(?u64, null) });
    try testing.expect(std.mem.indexOf(u8, result, "name LIKE '%alice%'") != null);
    try testing.expect(std.mem.indexOf(u8, result, "entity_type LIKE '%alice%'") != null);
    try testing.expect(std.mem.indexOf(u8, result, "||") == null);
}

test "writeSearchEntities escapes quotes inside the LIKE pattern" {
    var buf: [2048]u8 = undefined;
    const result = try renderSql(&buf, writeSearchEntities, .{ "O'Brien", @as(?[]const u8, null), @as(?u64, null), @as(?u64, null) });
    try testing.expect(std.mem.indexOf(u8, result, "LIKE '%O''Brien%'") != null);
    try testing.expect(std.mem.indexOf(u8, result, "||") == null);
}

test "writeFulltextSearch escapes quotes and avoids `||`" {
    var buf: [4096]u8 = undefined;
    const result = try renderSql(&buf, writeFulltextSearch, .{ "a'b", 5 });
    try testing.expect(std.mem.indexOf(u8, result, "LIKE '%a''b%'") != null);
    try testing.expect(std.mem.indexOf(u8, result, "||") == null);
}

// -- Batch helpers -----------------------------------------------------------

test "writeInsertRelations batches multiple rows" {
    var buf: [2048]u8 = undefined;
    const rels = [_]types.Relation{
        .{ .from = "A", .to = "B", .relation_type = "knows" },
        .{ .from = "B", .to = "C", .relation_type = "likes" },
    };
    try testing.expectEqualStrings(
        "INSERT INTO `rag_relation` (from_entity, relation_type, to_entity) VALUES ('A','knows','B'), ('B','likes','C')",
        try renderSql(&buf, writeInsertRelations, .{&rels}),
    );
}

test "writeInsertRelations escapes literals" {
    var buf: [2048]u8 = undefined;
    const rels = [_]types.Relation{.{ .from = "O'Hara", .to = "B", .relation_type = "r" }};
    const result = try renderSql(&buf, writeInsertRelations, .{&rels});
    try testing.expect(std.mem.indexOf(u8, result, "'O''Hara'") != null);
}

test "writeGetEntitiesByNames" {
    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings(
        "SELECT name, entity_type, observations FROM `rag_entity` WHERE name IN ('A', 'B', 'C')",
        try renderSql(&buf, writeGetEntitiesByNames, .{&[_][]const u8{ "A", "B", "C" }}),
    );
}

test "anyObservations" {
    const none = [_]types.Entity{
        .{ .name = "A", .entity_type = "t", .observations = &.{} },
        .{ .name = "B", .entity_type = "t", .observations = &.{} },
    };
    try testing.expect(!anyObservations(&none));

    const some = [_]types.Entity{
        .{ .name = "A", .entity_type = "t", .observations = &.{} },
        .{ .name = "B", .entity_type = "t", .observations = &.{"obs"} },
    };
    try testing.expect(anyObservations(&some));
    try testing.expect(!anyObservations(&.{}));
}

test "writeAllEntityObservations collapses pairs into one statement" {
    var buf: [2048]u8 = undefined;
    const entities = [_]types.Entity{
        .{ .name = "A", .entity_type = "t", .observations = &.{ "a1", "a2" } },
        .{ .name = "B", .entity_type = "t", .observations = &.{} }, // skipped
        .{ .name = "C", .entity_type = "t", .observations = &.{"c1"} },
    };
    try testing.expectEqualStrings(
        "INSERT INTO `rag_observation` (entity_name, content) VALUES('A','a1'),('A','a2'),('C','c1')",
        try renderSql(&buf, writeAllEntityObservations, .{&entities}),
    );
}

test "writeGraphStatistics single round-trip query" {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "SELECT (SELECT COUNT(*) FROM `rag_entity`), (SELECT COUNT(*) FROM `rag_relation`)",
        try renderSql(&buf, writeGraphStatistics, .{}),
    );
}

// ---- fuzzing --------------------------------------------------------------
// The search/fulltext builders interpolate an untrusted query string into a
// LIKE literal. Per Agent.md, fuzz the escaping path over arbitrary bytes
// (including NUL, quotes, backslashes, high bytes) using an allocating writer so
// variable-length input can never overflow a fixed buffer. Invariant: the
// builder never panics on any input. (The structural "no bare `||`" guarantee is
// covered by the deterministic tests; it can't be asserted here because random
// query bytes may legitimately contain `|` characters inside the escaped literal.)

test "fuzz: writeSearchEntities / writeFulltextSearch never panic on random bytes" {
    var prng = std.Random.DefaultPrng.init(0x5EA4C);
    const rnd = prng.random();
    var qbuf: [256]u8 = undefined;

    for (0..500) |_| {
        const len = rnd.intRangeLessThan(usize, 0, qbuf.len);
        const q = qbuf[0..len];
        for (q) |*b| b.* = rnd.int(u8);

        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var se = Writer.Allocating.init(arena.allocator());
        writeSearchEntities(&se.writer, q, null, null, null) catch {};

        var fs = Writer.Allocating.init(arena.allocator());
        writeFulltextSearch(&fs.writer, q, 10) catch {};
    }
}

// ---- helpers moved from src ----
pub fn renderSql(buf: []u8, comptime f: anytype, args: anytype) ![]u8 {
    var w = Writer.fixed(buf);
    try @call(.auto, f, .{&w} ++ args);
    return w.buffered();
}
