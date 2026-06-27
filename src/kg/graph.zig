//! Knowledge graph operations — SQL generation and result parsing.
//!
//! Each public `write*` function emits a single SQL statement for a KG
//! operation.  Callers use `renderForConn` to execute it or compose multiple
//! statements themselves.
//!
//! Generation and execution are separated so SQL logic is testable without a
//! live database connection (unit tests cover the `write*` functions; e2e
//! integration tests cover both sides).

const std = @import("std");
const pool = @import("../pool.zig");
const validation = @import("../validation.zig");
const json_mod = @import("../json.zig");
pub const types = @import("types.zig");
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

/// Write a `LIKE '%<query>%'` substring (contains) pattern as a single escaped
/// literal.
///
/// SQLite's `||` is string concatenation (safe to use), but building the
/// pattern as a single literal avoids any dialect confusion. The query is
/// escaped for the string-literal context; `%`/`_` inside it keep their
/// wildcard meaning, preserving the original substring-search intent.
fn writeLikeContains(w: *Writer, query: []const u8) !void {
    try w.writeAll("LIKE '%");
    try validation.writeEscapedLiteral(w, query);
    try w.writeAll("%'");
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
pub fn parseObservationsJson(allocator: Allocator, json_str: []const u8) ![]const []const u8 {
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

/// `SELECT name, entity_type, observations FROM rag_entity WHERE name IN (<names>)`
///
/// Batch form of `writeGetEntity`: fetches many entities in one round-trip.
/// Rows come back in arbitrary order, so callers that need request order should
/// index the result by `name`. Caller must guarantee `names.len > 0`.
pub fn writeGetEntitiesByNames(w: *Writer, names: []const []const u8) !void {
    try w.writeAll("SELECT name, entity_type, observations FROM ");
    try validation.writeQuotedIdent(w, schema.entity_table);
    try w.writeAll(" WHERE name IN (");
    try writeNameList(w, names);
    try w.writeByte(')');
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
/// Caller must guarantee `relations.len > 0` (an empty list yields invalid SQL).
pub fn writeInsertRelations(w: *Writer, relations: []const types.Relation) !void {
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

/// Whether any entity in the set carries at least one observation. Callers use
/// this to skip emitting an empty `writeAllEntityObservations` statement.
pub fn anyObservations(entities: []const types.Entity) bool {
    for (entities) |e| {
        if (e.observations.len > 0) return true;
    }
    return false;
}

/// Single multi-row INSERT carrying every (entity_name, content) pair across all
/// entities, collapsing what was previously one round-trip per entity into one.
/// Caller must guard with `anyObservations` — emitting this for a set with no
/// observations yields a trailing-`VALUES` syntax error.
pub fn writeAllEntityObservations(w: *Writer, entities: []const types.Entity) !void {
    try w.writeAll("INSERT INTO ");
    try validation.writeQuotedIdent(w, schema.observation_table);
    try w.writeAll(" (entity_name, content) VALUES");
    var first = true;
    for (entities) |e| {
        for (e.observations) |content| {
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeByte('(');
            try writeSqlLiteral(w, e.name);
            try w.writeByte(',');
            try writeSqlLiteral(w, content);
            try w.writeByte(')');
        }
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
    try w.writeAll(" WHERE (name ");
    try writeLikeContains(w, query);
    try w.writeAll(" OR entity_type ");
    try writeLikeContains(w, query);
    try w.writeByte(')');
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

/// Combined entity + relation counts in a single round-trip.
/// `SELECT (SELECT COUNT(*) FROM rag_entity), (SELECT COUNT(*) FROM rag_relation)`
pub fn writeGraphStatistics(w: *Writer) !void {
    try w.writeAll("SELECT (SELECT COUNT(*) FROM ");
    try validation.writeQuotedIdent(w, schema.entity_table);
    try w.writeAll("), (SELECT COUNT(*) FROM ");
    try validation.writeQuotedIdent(w, schema.relation_table);
    try w.writeByte(')');
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
    try w.writeAll(" e WHERE e.name ");
    try writeLikeContains(w, query);
    try w.writeAll(" OR e.entity_type ");
    try writeLikeContains(w, query);
    try w.writeAll(" OR e.observations ");
    try writeLikeContains(w, query);
    try w.writeAll(" UNION SELECT DISTINCT e.name, e.entity_type, e.observations FROM ");
    try validation.writeQuotedIdent(w, schema.entity_table);
    try w.writeAll(" e JOIN ");
    try validation.writeQuotedIdent(w, schema.observation_table);
    try w.writeAll(" o ON o.entity_name = e.name WHERE o.content ");
    try writeLikeContains(w, query);
    try w.writeAll(" LIMIT ");
    try w.print("{d}", .{limit});
}
