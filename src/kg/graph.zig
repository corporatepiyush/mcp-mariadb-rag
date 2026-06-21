//! Knowledge graph operations — SQL generation and result parsing.
//!
//! Each public `write*` function emits a single SQL statement for a KG
//! operation.  Callers use `renderForConn` to execute it or compose multiple
//! statements themselves.
//!
//! Generation and execution are separated so SQL logic is testable without a
//! live MariaDB connection (unit tests cover the `write*` functions; e2e
//! integration tests cover both sides).

const std = @import("std");
const pool = @import("../pool.zig");
const validation = @import("../validation.zig");
const json_mod = @import("../json.zig");
const types = @import("types.zig");
const schema = @import("schema.zig");

const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;
const PooledConn = pool.PooledConnection;
const QueryResult = pool.QueryResult;

// ── Helpers ───────────────────────────────────────────────────────────

/// Render a write* function into an owned SQL string.
pub fn renderToOwned(allocator: Allocator, comptime write_fn: anytype, args: anytype) ![]u8 {
    var aw = Writer.Allocating.init(allocator);
    errdefer aw.deinit();
    try @call(.auto, write_fn, .{&aw.writer} ++ args);
    return aw.toOwnedSlice();
}

/// Render a write* function and execute it, returning the affected row count.
pub fn execBuilt(allocator: Allocator, conn: *PooledConn, comptime write_fn: anytype, args: anytype) !u64 {
    const sql = try renderToOwned(allocator, write_fn, args);
    defer allocator.free(sql);
    return conn.execute(sql);
}

/// Write a single-quoted SQL literal with proper escaping.
fn writeSqlLiteral(w: *Writer, s: []const u8) !void {
    try w.writeByte('\'');
    try validation.writeEscapedLiteral(w, s);
    try w.writeByte('\'');
}

// ── Types ─────────────────────────────────────────────────────────────

/// Row type for batch entity inserts, shared between graph.zig and kg.zig.
pub const EntityInsertRow = struct {
    name: []const u8,
    entity_type: []const u8,
    obs_json: []const u8,
};

// ── Entity operations ─────────────────────────────────────────────────

/// `SELECT entity_type, observations FROM rag_entity WHERE name = '<name>'`
pub fn writeGetEntity(w: *Writer, name: []const u8) !void {
    try w.writeAll("SELECT entity_type, observations FROM ");
    try validation.writeQuotedIdent(w, schema.entity_table);
    try w.writeAll(" WHERE name = ");
    try writeSqlLiteral(w, name);
}

/// Parse a single Entity from a get_entity query result.
pub fn parseEntity(result: QueryResult, allocator: Allocator) !?types.Entity {
    const rows = result.rows orelse return null;
    if (rows.len == 0) return null;
    const row = rows[0];
    // row[0] = entity_type, row[1] = observations JSON
    const entity_type = row.values[0] orelse return null;
    const obs_json = row.values[1] orelse return null;

    const observations = try parseObservationsJson(allocator, obs_json);
    return types.Entity{
        .name = "", // caller fills name
        .entity_type = try allocator.dupe(u8, entity_type),
        .observations = observations,
    };
}

/// Parse a JSON array of strings from the observations column.
fn parseObservationsJson(allocator: Allocator, json_str: []const u8) ![]const []const u8 {
    if (json_str.len == 0 or std.mem.eql(u8, json_str, "[]")) {
        return &.{};
    }
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch return &.{};
    defer parsed.deinit();
    const arr = parsed.value.array.items;
    const result = try allocator.alloc([]const u8, arr.len);
    for (arr, 0..) |item, i| {
        result[i] = try allocator.dupe(u8, item.string);
    }
    return result;
}

/// `SELECT 1 FROM rag_entity WHERE name = '<name>'`
pub fn writeEntityExists(w: *Writer, name: []const u8) !void {
    try w.writeAll("SELECT 1 FROM ");
    try validation.writeQuotedIdent(w, schema.entity_table);
    try w.writeAll(" WHERE name = ");
    try writeSqlLiteral(w, name);
}

/// `INSERT INTO rag_entity (name, entity_type, observations) VALUES ('<n>','<t>','<js>')`
pub fn writeInsertEntity(w: *Writer, name: []const u8, entity_type: []const u8, obs_json: []const u8) !void {
    try w.writeAll("INSERT INTO ");
    try validation.writeQuotedIdent(w, schema.entity_table);
    try w.writeAll(" (name, entity_type, observations) VALUES (");
    try writeSqlLiteral(w, name);
    try w.writeByte(',');
    try writeSqlLiteral(w, entity_type);
    try w.writeByte(',');
    try writeSqlLiteral(w, obs_json);
    try w.writeByte(')');
}

/// Multi-row batch INSERT for entities.
/// `INSERT INTO rag_entity (name, entity_type, observations) VALUES (..), (..)`
pub fn writeInsertEntities(w: *Writer, entities: []const EntityInsertRow) !void {
    try w.writeAll("INSERT INTO ");
    try validation.writeQuotedIdent(w, schema.entity_table);
    try w.writeAll(" (name, entity_type, observations) VALUES ");
    for (entities, 0..) |e, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeByte('(');
        try writeSqlLiteral(w, e.name);
        try w.writeByte(',');
        try writeSqlLiteral(w, e.entity_type);
        try w.writeByte(',');
        try writeSqlLiteral(w, e.obs_json);
        try w.writeByte(')');
    }
}

/// `DELETE FROM rag_entity WHERE name = '<name>'`
pub fn writeDeleteEntity(w: *Writer, name: []const u8) !void {
    try w.writeAll("DELETE FROM ");
    try validation.writeQuotedIdent(w, schema.entity_table);
    try w.writeAll(" WHERE name = ");
    try writeSqlLiteral(w, name);
}

/// Build a comma-separated list of escaped names for use in an IN clause.
pub fn writeNameList(w: *Writer, names: []const []const u8) !void {
    for (names, 0..) |name, i| {
        if (i > 0) try w.writeAll(", ");
        try writeSqlLiteral(w, name);
    }
}

/// `DELETE FROM rag_entity WHERE name IN (<names>)`
pub fn writeDeleteEntities(w: *Writer, names: []const []const u8) !void {
    try w.writeAll("DELETE FROM ");
    try validation.writeQuotedIdent(w, schema.entity_table);
    try w.writeAll(" WHERE name IN (");
    try writeNameList(w, names);
    try w.writeByte(')');
}

/// Build a valid JSON array string from observation slices.
/// Caller owns the returned memory.
pub fn observationsToJson(allocator: Allocator, observations: []const []const u8) ![]u8 {
    var aw = Writer.Allocating.init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeByte('[');
    for (observations, 0..) |obs, i| {
        if (i > 0) try w.writeByte(',');
        try json_mod.writeQuoted(w, obs);
    }
    try w.writeByte(']');
    return aw.toOwnedSlice();
}

// ── Observation operations ────────────────────────────────────────────

/// `INSERT INTO rag_observation (id, entity_name, content) VALUES ('<uuid>','<name>','<content>')`
pub fn writeInsertObservation(w: *Writer, entity_name: []const u8, content: []const u8) !void {
    try w.writeAll("INSERT INTO ");
    try validation.writeQuotedIdent(w, schema.observation_table);
    try w.writeAll(" (entity_name, content) VALUES (");
    try writeSqlLiteral(w, entity_name);
    try w.writeByte(',');
    try writeSqlLiteral(w, content);
    try w.writeByte(')');
}

/// `DELETE FROM rag_observation WHERE entity_name = '<name>' AND content IN (<contents>)`
pub fn writeDeleteObservations(w: *Writer, entity_name: []const u8, contents: []const []const u8) !void {
    try w.writeAll("DELETE FROM ");
    try validation.writeQuotedIdent(w, schema.observation_table);
    try w.writeAll(" WHERE entity_name = ");
    try writeSqlLiteral(w, entity_name);
    try w.writeAll(" AND content IN (");
    for (contents, 0..) |c, i| {
        if (i > 0) try w.writeAll(", ");
        try writeSqlLiteral(w, c);
    }
    try w.writeByte(')');
}

// ── Relation operations ───────────────────────────────────────────────

/// `INSERT INTO rag_relation (from_entity, relation_type, to_entity) VALUES ('<f>','<t>','<tt>')`
pub fn writeInsertRelation(w: *Writer, from: []const u8, relation_type: []const u8, to: []const u8) !void {
    try w.writeAll("INSERT INTO ");
    try validation.writeQuotedIdent(w, schema.relation_table);
    try w.writeAll(" (from_entity, relation_type, to_entity) VALUES (");
    try writeSqlLiteral(w, from);
    try w.writeByte(',');
    try writeSqlLiteral(w, relation_type);
    try w.writeByte(',');
    try writeSqlLiteral(w, to);
    try w.writeByte(')');
}

/// Multi-row batch INSERT for relations.
/// `INSERT INTO rag_relation (from_entity, relation_type, to_entity) VALUES (..), (..)`
pub fn writeInsertRelations(w: *Writer, relations: []const struct { from: []const u8, relation_type: []const u8, to: []const u8 }) !void {
    try w.writeAll("INSERT INTO ");
    try validation.writeQuotedIdent(w, schema.relation_table);
    try w.writeAll(" (from_entity, relation_type, to_entity) VALUES ");
    for (relations, 0..) |r, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeByte('(');
        try writeSqlLiteral(w, r.from);
        try w.writeByte(',');
        try writeSqlLiteral(w, r.relation_type);
        try w.writeByte(',');
        try writeSqlLiteral(w, r.to);
        try w.writeByte(')');
    }
}

/// `DELETE FROM rag_relation WHERE from_entity='<f>' AND relation_type='<t>' AND to_entity='<tt>'`
pub fn writeDeleteRelation(w: *Writer, from: []const u8, relation_type: []const u8, to: []const u8) !void {
    try w.writeAll("DELETE FROM ");
    try validation.writeQuotedIdent(w, schema.relation_table);
    try w.writeAll(" WHERE from_entity = ");
    try writeSqlLiteral(w, from);
    try w.writeAll(" AND relation_type = ");
    try writeSqlLiteral(w, relation_type);
    try w.writeAll(" AND to_entity = ");
    try writeSqlLiteral(w, to);
}

/// Build a search_relations query with optional filters.
/// Filters that are empty strings are treated as absent.
pub fn writeSearchRelations(w: *Writer, from: ?[]const u8, to: ?[]const u8, rtype: ?[]const u8) !void {
    try w.writeAll("SELECT r.from_entity, r.relation_type, r.to_entity FROM ");
    try validation.writeQuotedIdent(w, schema.relation_table);
    try w.writeAll(" r WHERE 1=1");
    if (from) |f| {
        if (f.len > 0) {
            try w.writeAll(" AND r.from_entity = ");
            try writeSqlLiteral(w, f);
        }
    }
    if (to) |t| {
        if (t.len > 0) {
            try w.writeAll(" AND r.to_entity = ");
            try writeSqlLiteral(w, t);
        }
    }
    if (rtype) |rt| {
        if (rt.len > 0) {
            try w.writeAll(" AND r.relation_type = ");
            try writeSqlLiteral(w, rt);
        }
    }
    try w.writeAll(" ORDER BY r.from_entity, r.to_entity");
}

// ── Batch entity/observation operations ───────────────────────────────

/// Batch INSERT multiple observations for one entity.
pub fn writeInsertObservations(
    w: *Writer,
    entity_name: []const u8,
    contents: []const []const u8,
) !void {
    try w.writeAll("INSERT INTO ");
    try validation.writeQuotedIdent(w, schema.observation_table);
    try w.writeAll(" (entity_name, content) VALUES");
    for (contents, 0..) |content, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeByte('(');
        try writeSqlLiteral(w, entity_name);
        try w.writeByte(',');
        try writeSqlLiteral(w, content);
        try w.writeByte(')');
    }
}

// ── Read operations ───────────────────────────────────────────────────

/// `SELECT name, entity_type, observations FROM rag_entity [WHERE entity_type = '<t>'] [LIMIT <n>] [OFFSET <n>]`
pub fn writeReadEntities(w: *Writer, filter_type: ?[]const u8, limit: ?u64, offset: ?u64) !void {
    try w.writeAll("SELECT name, entity_type, observations FROM ");
    try validation.writeQuotedIdent(w, schema.entity_table);
    if (filter_type) |ft| {
        if (ft.len > 0) {
            try w.writeAll(" WHERE entity_type = ");
            try writeSqlLiteral(w, ft);
        }
    }
    try w.writeAll(" ORDER BY name");
    if (limit) |l| {
        try w.print(" LIMIT {d}", .{l});
    }
    if (offset) |o| {
        try w.print(" OFFSET {d}", .{o});
    }
}

/// `SELECT from_entity, relation_type, to_entity FROM rag_relation WHERE from_entity IN (<set>) OR to_entity IN (<set>)`
pub fn writeRelationsForEntitySet(w: *Writer, names: []const []const u8) !void {
    try w.writeAll("SELECT from_entity, relation_type, to_entity FROM ");
    try validation.writeQuotedIdent(w, schema.relation_table);
    try w.writeAll(" WHERE from_entity IN (");
    try writeNameList(w, names);
    try w.writeAll(") OR to_entity IN (");
    try writeNameList(w, names);
    try w.writeByte(')');
}

/// LIKE-based entity search.
/// `SELECT name, entity_type, observations FROM rag_entity WHERE name LIKE '%<q>%' OR entity_type LIKE '%<q>%' [AND entity_type = '<t>'] [LIMIT <n>] [OFFSET <n>]`
pub fn writeSearchEntities(w: *Writer, query: []const u8, filter_type: ?[]const u8, limit: ?u64, offset: ?u64) !void {
    try w.writeAll("SELECT name, entity_type, observations FROM ");
    try validation.writeQuotedIdent(w, schema.entity_table);
    try w.writeAll(" WHERE (name LIKE '%' || ");
    try writeSqlLiteral(w, query);
    try w.writeAll(" || '%' OR entity_type LIKE '%' || ");
    try writeSqlLiteral(w, query);
    try w.writeAll(" || '%')");
    if (filter_type) |ft| {
        if (ft.len > 0) {
            try w.writeAll(" AND entity_type = ");
            try writeSqlLiteral(w, ft);
        }
    }
    try w.writeAll(" ORDER BY name");
    if (limit) |l| {
        try w.print(" LIMIT {d}", .{l});
    }
    if (offset) |o| {
        try w.print(" OFFSET {d}", .{o});
    }
}

// ── Neighbor traversal ────────────────────────────────────────────────

/// Fetch outgoing relation targets for a set of entity names.
/// Returns `(from_entity, relation_type, to_entity)` rows.
pub fn writeOutgoingRelations(w: *Writer, names: []const []const u8) !void {
    try w.writeAll("SELECT from_entity, relation_type, to_entity FROM ");
    try validation.writeQuotedIdent(w, schema.relation_table);
    try w.writeAll(" WHERE from_entity IN (");
    try writeNameList(w, names);
    try w.writeByte(')');
}

/// Fetch incoming relation sources for a set of entity names.
pub fn writeIncomingRelations(w: *Writer, names: []const []const u8) !void {
    try w.writeAll("SELECT from_entity, relation_type, to_entity FROM ");
    try validation.writeQuotedIdent(w, schema.relation_table);
    try w.writeAll(" WHERE to_entity IN (");
    try writeNameList(w, names);
    try w.writeByte(')');
}

// ── Stats ─────────────────────────────────────────────────────────────

/// `SELECT COUNT(*) FROM rag_entity`
pub fn writeCountEntities(w: *Writer) !void {
    try w.writeAll("SELECT COUNT(*) FROM ");
    try validation.writeQuotedIdent(w, schema.entity_table);
}

/// `SELECT COUNT(*) FROM rag_relation`
pub fn writeCountRelations(w: *Writer) !void {
    try w.writeAll("SELECT COUNT(*) FROM ");
    try validation.writeQuotedIdent(w, schema.relation_table);
}

/// `SELECT entity_type, COUNT(*) as cnt FROM rag_entity GROUP BY entity_type ORDER BY cnt DESC`
pub fn writeEntityTypeCounts(w: *Writer) !void {
    try w.writeAll("SELECT entity_type, COUNT(*) as cnt FROM ");
    try validation.writeQuotedIdent(w, schema.entity_table);
    try w.writeAll(" GROUP BY entity_type ORDER BY cnt DESC");
}

/// `SELECT relation_type, COUNT(*) as cnt FROM rag_relation GROUP BY relation_type ORDER BY cnt DESC`
pub fn writeRelationTypeCounts(w: *Writer) !void {
    try w.writeAll("SELECT relation_type, COUNT(*) as cnt FROM ");
    try validation.writeQuotedIdent(w, schema.relation_table);
    try w.writeAll(" GROUP BY relation_type ORDER BY cnt DESC");
}

/// Count relations incident to an entity in a given direction.
pub fn writeDegree(w: *Writer, name: []const u8, direction: types.Direction) !void {
    switch (direction) {
        .out => {
            try w.writeAll("SELECT COUNT(*) FROM ");
            try validation.writeQuotedIdent(w, schema.relation_table);
            try w.writeAll(" WHERE from_entity = ");
            try writeSqlLiteral(w, name);
        },
        .incoming => {
            try w.writeAll("SELECT COUNT(*) FROM ");
            try validation.writeQuotedIdent(w, schema.relation_table);
            try w.writeAll(" WHERE to_entity = ");
            try writeSqlLiteral(w, name);
        },
        .both => {
            try w.writeAll("SELECT (SELECT COUNT(*) FROM ");
            try validation.writeQuotedIdent(w, schema.relation_table);
            try w.writeAll(" WHERE from_entity = ");
            try writeSqlLiteral(w, name);
            try w.writeAll(") + (SELECT COUNT(*) FROM ");
            try validation.writeQuotedIdent(w, schema.relation_table);
            try w.writeAll(" WHERE to_entity = ");
            try writeSqlLiteral(w, name);
            try w.writeByte(')');
        },
    }
}

// ── Pathfinding (BFS in SQL + Zig) ────────────────────────────────────

/// Fetch all relation triples where from_entity is in the given set.
/// Returns rows of `(to_entity, relation_type)` for outgoing.
pub fn writeBfsOutgoing(w: *Writer, names: []const []const u8) !void {
    try w.writeAll("SELECT from_entity, to_entity FROM ");
    try validation.writeQuotedIdent(w, schema.relation_table);
    try w.writeAll(" WHERE from_entity IN (");
    try writeNameList(w, names);
    try w.writeByte(')');
}

/// Returns rows of `(from_entity)` for incoming (to_entity in set).
pub fn writeBfsIncoming(w: *Writer, names: []const []const u8) !void {
    try w.writeAll("SELECT to_entity, from_entity FROM ");
    try validation.writeQuotedIdent(w, schema.relation_table);
    try w.writeAll(" WHERE to_entity IN (");
    try writeNameList(w, names);
    try w.writeByte(')');
}

/// Returns rows of `(parent, child)` for both directions (outgoing + incoming)
/// from a set of entity names. Used for BFS pathfinding.
pub fn writeBfsBoth(w: *Writer, names: []const []const u8) !void {
    try w.writeAll("SELECT from_entity AS parent, to_entity AS child FROM ");
    try validation.writeQuotedIdent(w, schema.relation_table);
    try w.writeAll(" WHERE from_entity IN (");
    try writeNameList(w, names);
    try w.writeAll(") UNION SELECT to_entity, from_entity FROM ");
    try validation.writeQuotedIdent(w, schema.relation_table);
    try w.writeAll(" WHERE to_entity IN (");
    try writeNameList(w, names);
    try w.writeByte(')');
}

/// BFS expansion query that returns `(parent, child)` rows for a set of frontier
/// entity names, following the given direction.
pub fn writeBfsExpand(w: *Writer, names: []const []const u8, direction: types.Direction) !void {
    switch (direction) {
        .out => {
            try w.writeAll("SELECT from_entity AS parent, to_entity AS child FROM ");
            try validation.writeQuotedIdent(w, schema.relation_table);
            try w.writeAll(" WHERE from_entity IN (");
            try writeNameList(w, names);
            try w.writeByte(')');
        },
        .incoming => {
            try w.writeAll("SELECT to_entity AS parent, from_entity AS child FROM ");
            try validation.writeQuotedIdent(w, schema.relation_table);
            try w.writeAll(" WHERE to_entity IN (");
            try writeNameList(w, names);
            try w.writeByte(')');
        },
        .both => {
            try w.writeAll("SELECT from_entity AS parent, to_entity AS child FROM ");
            try validation.writeQuotedIdent(w, schema.relation_table);
            try w.writeAll(" WHERE from_entity IN (");
            try writeNameList(w, names);
            try w.writeAll(") UNION SELECT to_entity, from_entity FROM ");
            try validation.writeQuotedIdent(w, schema.relation_table);
            try w.writeAll(" WHERE to_entity IN (");
            try writeNameList(w, names);
            try w.writeByte(')');
        },
    }
}

/// Full-text search across entities and observations using LIKE.
/// Returns entity name, entity type, observations, and matching observation content.
pub fn writeFulltextSearch(w: *Writer, query: []const u8, limit: u64) !void {
    try w.writeAll("SELECT DISTINCT e.name, e.entity_type, e.observations FROM ");
    try validation.writeQuotedIdent(w, schema.entity_table);
    try w.writeAll(" e WHERE e.name LIKE '%' || ");
    try writeSqlLiteral(w, query);
    try w.writeAll(" || '%' OR e.entity_type LIKE '%' || ");
    try writeSqlLiteral(w, query);
    try w.writeAll(" || '%' OR e.observations LIKE '%' || ");
    try writeSqlLiteral(w, query);
    try w.writeAll(" || '%' UNION SELECT DISTINCT e.name, e.entity_type, e.observations FROM ");
    try validation.writeQuotedIdent(w, schema.entity_table);
    try w.writeAll(" e JOIN ");
    try validation.writeQuotedIdent(w, schema.observation_table);
    try w.writeAll(" o ON o.entity_name = e.name WHERE o.content LIKE '%' || ");
    try writeSqlLiteral(w, query);
    try w.writeAll(" || '%' LIMIT ");
    try w.print("{d}", .{limit});
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

fn renderSql(buf: []u8, comptime f: anytype, args: anytype) ![]u8 {
    var w = Writer.fixed(buf);
    try @call(.auto, f, .{&w} ++ args);
    return w.buffered();
}

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
        "SELECT name, entity_type, observations FROM `rag_entity` WHERE (name LIKE '%' || 'alice' || '%' OR entity_type LIKE '%' || 'alice' || '%') ORDER BY name",
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
    try testing.expect(std.mem.indexOf(u8, result, "LIKE '%' || 'alice' || '%'") != null);
    try testing.expect(std.mem.indexOf(u8, result, "JOIN `rag_observation` o ON o.entity_name = e.name") != null);
    try testing.expect(std.mem.indexOf(u8, result, "LIMIT 10") != null);
}
