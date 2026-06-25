const std = @import("std");
const pool = @import("../pool.zig");
const json = @import("../json.zig");
const mod = @import("mod.zig");
const graph = @import("../kg/graph.zig");
const vector = @import("../kg/vector.zig");
const types = @import("../kg/types.zig");
const schema = @import("../kg/schema.zig");
const fusion = @import("../rag/fusion.zig");
const sqtypes = @import("../types.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const PooledConn = pool.PooledConnection;
const Payload = mod.Payload;
const Writer = std.Io.Writer;

/// Maximum embedding dimensionality (matches `VECTOR(384)` in the schema).
const vector_dims = 384;

/// Parse a JSON array of numbers into a fixed-capacity f32 buffer, returning the
/// populated prefix. Accepts both float and integer JSON values. Errors if the
/// array is longer than `vector_dims` or contains a non-number.
fn parseVector(buf: *[vector_dims]f32, arr: std.json.Array) error{ TooLong, NotNumber }![]const f32 {
    if (arr.items.len > vector_dims) return error.TooLong;
    for (arr.items, 0..) |item, i| {
        buf[i] = switch (item) {
            .float => |f| @as(f32, @floatCast(f)),
            .integer => |n| @as(f32, @floatFromInt(n)),
            else => return error.NotNumber,
        };
    }
    return buf[0..arr.items.len];
}

/// Collect a JSON array of strings into an owned slice, erroring on any
/// non-string element.
fn stringArray(allocator: Allocator, arr: std.json.Array) error{ NotString, OutOfMemory }![]const []const u8 {
    const out = try allocator.alloc([]const u8, arr.items.len);
    for (arr.items, 0..) |item, i| {
        if (item != .string) return error.NotString;
        out[i] = item.string;
    }
    return out;
}

fn execBuilt(allocator: Allocator, conn: *PooledConn, comptime write_fn: anytype, args: anytype) !u64 {
    const sql = try mod.renderToOwned(allocator, write_fn, args);
    defer allocator.free(sql);
    return conn.execute(sql);
}

fn writeJsonString(w: *Writer, s: []const u8) !void {
    try json.writeQuoted(w, s);
}

/// `{"name":..,"entityType":..,"observations":<raw>}`. `obs` is the raw JSON
/// array text straight from the `observations` column.
fn writeEntityObject(w: *Writer, name: []const u8, etype: []const u8, obs: []const u8) !void {
    try w.writeAll("{\"name\":");
    try writeJsonString(w, name);
    try w.writeAll(",\"entityType\":");
    try writeJsonString(w, etype);
    try w.writeAll(",\"observations\":");
    try w.writeAll(obs);
    try w.writeByte('}');
}

/// `{"from":..,"relationType":..,"to":..}`.
fn writeRelationObject(w: *Writer, from: []const u8, rtype: []const u8, to: []const u8) !void {
    try w.writeAll("{\"from\":");
    try writeJsonString(w, from);
    try w.writeAll(",\"relationType\":");
    try writeJsonString(w, rtype);
    try w.writeAll(",\"to\":");
    try writeJsonString(w, to);
    try w.writeByte('}');
}

/// Entity row payload indexed by name when batch-fetching.
const EntityRow = struct { entity_type: []const u8, observations: []const u8 };

/// Fetch many entities by name in one round-trip, indexed by name. Replaces the
/// previous one-`SELECT`-per-name loops in `openNodes` / `getNeighbors`.
fn fetchEntitiesByName(
    allocator: Allocator,
    conn: *PooledConn,
    names: []const []const u8,
) !std.StringHashMapUnmanaged(EntityRow) {
    var map: std.StringHashMapUnmanaged(EntityRow) = .empty;
    if (names.len == 0) return map;
    const sql = try mod.renderToOwned(allocator, graph.writeGetEntitiesByNames, .{names});
    defer allocator.free(sql);
    const result = try conn.query(allocator, sql);
    const rows = result.rows orelse return map;
    // Row count is known up front (one entry per row, duplicates overwrite), so
    // size once instead of letting the map rehash as it grows.
    try map.ensureTotalCapacity(allocator, @intCast(rows.len));
    for (rows) |row| {
        const nm = row.values[0] orelse continue;
        map.putAssumeCapacity(nm, .{
            .entity_type = row.values[1] orelse "",
            .observations = row.values[2] orelse "[]",
        });
    }
    return map;
}

pub fn createEntities(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const entities_val = mod.getArrayParam(args, "entities") orelse
        return mod.errPayload("Missing 'entities' parameter");

    const entities = types.entitiesFromValue(allocator, Value{ .array = entities_val }) catch
        return mod.errPayload("Invalid entity format");

    if (entities.len == 0) return mod.errPayload("Empty entities list");

    {
        var batch: std.ArrayList(graph.EntityInsertRow) = .empty;
        defer batch.deinit(allocator);
        // Exact row count is known: one batch row per entity, no resize.
        batch.ensureTotalCapacity(allocator, entities.len) catch
            return mod.errPayload("Allocation error");
        for (entities) |entity| {
            const obs_json = graph.observationsToJson(allocator, entity.observations) catch
                return mod.errPayload("Serialization error");
            batch.appendAssumeCapacity(.{ .name = entity.name, .entity_type = entity.entity_type, .obs_json = obs_json });
        }
        const sql = mod.renderToOwned(allocator, graph.writeInsertEntities, .{batch.items}) catch
            return mod.errPayload("Allocation error");
        defer allocator.free(sql);
        _ = conn.execute(sql) catch return mod.errPayload("Create entity failed");
    }

    // All observations across every entity go in a single multi-row INSERT
    // rather than one round-trip per entity.
    if (graph.anyObservations(entities)) {
        const ins_sql = mod.renderToOwned(allocator, graph.writeAllEntityObservations, .{entities}) catch
            return mod.errPayload("Allocation error");
        defer allocator.free(ins_sql);
        _ = conn.execute(ins_sql) catch return mod.errPayload("Create observations failed");
    }

    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll("{\"ids\":[") catch return mod.errPayload("Serialization error");
    for (entities, 0..) |e, i| {
        if (i > 0) w.writeByte(',') catch return mod.errPayload("Serialization error");
        writeJsonString(w, e.name) catch return mod.errPayload("Serialization error");
    }
    w.writeAll("]}") catch return mod.errPayload("Serialization error");

    return .{ .text = aw.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
}

pub fn createRelations(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const relations_val = mod.getArrayParam(args, "relations") orelse
        return mod.errPayload("Missing 'relations' parameter");

    const relations = types.relationsFromValue(allocator, Value{ .array = relations_val }) catch
        return mod.errPayload("Invalid relation format");

    if (relations.len == 0) return mod.errPayload("Empty relations list");

    // Single multi-row INSERT instead of one round-trip per relation.
    _ = execBuilt(allocator, conn, graph.writeInsertRelations, .{relations}) catch
        return mod.errPayload("Create relation failed");

    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    aw.writer.print("{{\"relations_created\":{d}}}", .{relations.len}) catch
        return mod.errPayload("Serialization error");
    return .{ .text = aw.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
}

pub fn deleteEntities(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const names_val = mod.getArrayParam(args, "names") orelse
        return mod.errPayload("Missing 'names' parameter");

    const names = stringArray(allocator, names_val) catch |err| return switch (err) {
        error.NotString => mod.errPayload("Name must be a string"),
        error.OutOfMemory => mod.errPayload("Allocation error"),
    };

    if (names.len == 0) return mod.errPayload("Empty names list");

    // Single `DELETE ... WHERE name IN (...)` instead of one per name.
    const affected = execBuilt(allocator, conn, graph.writeDeleteEntities, .{names}) catch
        return mod.errPayload("Delete failed");

    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    aw.writer.print("{{\"deleted\":{d}}}", .{affected}) catch
        return mod.errPayload("Serialization error");
    return .{ .text = aw.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
}

pub fn deleteRelation(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const from = mod.getStringParam(args, "from") orelse return mod.errPayload("Missing 'from' parameter");
    const to = mod.getStringParam(args, "to") orelse return mod.errPayload("Missing 'to' parameter");
    const rtype = mod.getStringParam(args, "relationType") orelse return mod.errPayload("Missing 'relationType' parameter");

    const affected = execBuilt(allocator, conn, graph.writeDeleteRelation, .{ from, rtype, to }) catch
        return mod.errPayload("Delete failed");

    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    aw.writer.print("{{\"deleted\":{d}}}", .{affected}) catch
        return mod.errPayload("Serialization error");
    return .{ .text = aw.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
}

pub fn addObservations(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const name = mod.getStringParam(args, "name") orelse return mod.errPayload("Missing 'name' parameter");
    const obs_val = mod.getArrayParam(args, "observations") orelse
        return mod.errPayload("Missing 'observations' parameter");

    const obs_slice = stringArray(allocator, obs_val) catch |err| return switch (err) {
        error.NotString => mod.errPayload("Observation must be a string"),
        error.OutOfMemory => mod.errPayload("Allocation error"),
    };

    if (obs_slice.len == 0) {
        var aw = Writer.Allocating.init(allocator);
        defer aw.deinit();
        aw.writer.writeAll("{\"observations_added\":0}") catch
            return mod.errPayload("Serialization error");
        return .{ .text = aw.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
    }

    const ins_sql = mod.renderToOwned(allocator, graph.writeInsertObservations, .{ name, obs_slice }) catch
        return mod.errPayload("Allocation error");
    defer allocator.free(ins_sql);
    _ = conn.execute(ins_sql) catch return mod.errPayload("Add observations failed");

    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    aw.writer.print("{{\"observations_added\":{d}}}", .{obs_slice.len}) catch
        return mod.errPayload("Serialization error");
    return .{ .text = aw.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
}

pub fn deleteObservations(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const name = mod.getStringParam(args, "name") orelse return mod.errPayload("Missing 'name' parameter");
    const obs_val = mod.getArrayParam(args, "observations") orelse
        return mod.errPayload("Missing 'observations' parameter");

    const obs_slice = stringArray(allocator, obs_val) catch |err| return switch (err) {
        error.NotString => mod.errPayload("Observation must be a string"),
        error.OutOfMemory => mod.errPayload("Allocation error"),
    };

    if (obs_slice.len == 0) {
        var aw = Writer.Allocating.init(allocator);
        defer aw.deinit();
        aw.writer.writeAll("{\"observations_deleted\":0}") catch
            return mod.errPayload("Serialization error");
        return .{ .text = aw.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
    }

    const affected = execBuilt(allocator, conn, graph.writeDeleteObservations, .{ name, obs_slice }) catch
        return mod.errPayload("Delete observations failed");

    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    aw.writer.print("{{\"observations_deleted\":{d}}}", .{affected}) catch
        return mod.errPayload("Serialization error");
    return .{ .text = aw.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
}

fn fetchEntitiesAndRelations(allocator: Allocator, conn: *PooledConn, sql_entities: []const u8) Payload {
    const e_result = conn.query(allocator, sql_entities) catch
        return mod.errPayload("Query failed");
    const e_rows = e_result.rows orelse return mod.errPayload("No entity data");

    var entity_names: std.ArrayList([]const u8) = .empty;
    // One name per entity row; reserve exactly that, no resize.
    entity_names.ensureTotalCapacity(allocator, e_rows.len) catch
        return mod.errPayload("Allocation error");
    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    w.writeAll("{\"entities\":[") catch return mod.errPayload("Serialization error");
    for (e_rows, 0..) |row, i| {
        const ename = row.values[0] orelse "";
        const etype = row.values[1] orelse "";
        const eobs = row.values[2] orelse "[]";

        entity_names.appendAssumeCapacity(ename);

        if (i > 0) w.writeByte(',') catch return mod.errPayload("Serialization error");
        w.writeAll("{\"name\":") catch return mod.errPayload("Serialization error");
        writeJsonString(w, ename) catch return mod.errPayload("Serialization error");
        w.writeAll(",\"entityType\":") catch return mod.errPayload("Serialization error");
        writeJsonString(w, etype) catch return mod.errPayload("Serialization error");
        w.writeAll(",\"observations\":") catch return mod.errPayload("Serialization error");
        w.writeAll(eobs) catch return mod.errPayload("Serialization error");
        w.writeByte('}') catch return mod.errPayload("Serialization error");
    }
    w.writeAll("],\"relations\":[") catch return mod.errPayload("Serialization error");

    if (entity_names.items.len > 0) {
        const r_sql = mod.renderToOwned(allocator, graph.writeRelationsForEntitySet, .{entity_names.items}) catch
            return mod.errPayload("Allocation error");
        defer allocator.free(r_sql);

        const r_result = conn.query(allocator, r_sql) catch
            return mod.errPayload("Relation query failed");
        if (r_result.rows) |r_rows| {
            for (r_rows, 0..) |row, i| {
                if (i > 0) w.writeByte(',') catch return mod.errPayload("Serialization error");
                w.writeAll("{\"from\":") catch return mod.errPayload("Serialization error");
                writeJsonString(w, row.values[0] orelse "") catch return mod.errPayload("Serialization error");
                w.writeAll(",\"relationType\":") catch return mod.errPayload("Serialization error");
                writeJsonString(w, row.values[1] orelse "") catch return mod.errPayload("Serialization error");
                w.writeAll(",\"to\":") catch return mod.errPayload("Serialization error");
                writeJsonString(w, row.values[2] orelse "") catch return mod.errPayload("Serialization error");
                w.writeByte('}') catch return mod.errPayload("Serialization error");
            }
        }
    }

    w.writeAll("]}") catch return mod.errPayload("Serialization error");
    return .{ .text = aw.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
}

pub fn readGraph(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const filter_type = mod.getStringParam(args, "entityType");
    const limit: ?u64 = if (mod.getStringParam(args, "limit")) |l| std.fmt.parseUnsigned(u64, l, 10) catch null else null;
    const offset: ?u64 = if (mod.getStringParam(args, "offset")) |o| std.fmt.parseUnsigned(u64, o, 10) catch null else null;

    const sql = mod.renderToOwned(allocator, graph.writeReadEntities, .{ filter_type, limit, offset }) catch
        return mod.errPayload("Allocation error");
    defer allocator.free(sql);

    return fetchEntitiesAndRelations(allocator, conn, sql);
}

pub fn searchNodes(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const query = mod.getStringParam(args, "query") orelse return mod.errPayload("Missing 'query' parameter");
    const filter_type = mod.getStringParam(args, "entityType");
    const limit: ?u64 = if (mod.getStringParam(args, "limit")) |l| std.fmt.parseUnsigned(u64, l, 10) catch null else null;
    const offset: ?u64 = if (mod.getStringParam(args, "offset")) |o| std.fmt.parseUnsigned(u64, o, 10) catch null else null;

    const sql = mod.renderToOwned(allocator, graph.writeSearchEntities, .{ query, filter_type, limit, offset }) catch
        return mod.errPayload("Allocation error");
    defer allocator.free(sql);

    return fetchEntitiesAndRelations(allocator, conn, sql);
}

pub fn openNodes(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const names_val = mod.getArrayParam(args, "names") orelse
        return mod.errPayload("Missing 'names' parameter");

    const names = stringArray(allocator, names_val) catch |err| return switch (err) {
        error.NotString => mod.errPayload("Name must be a string"),
        error.OutOfMemory => mod.errPayload("Allocation error"),
    };

    if (names.len == 0) return mod.errPayload("Empty names list");

    // One round-trip for all requested entities; emit them in request order.
    var emap = fetchEntitiesByName(allocator, conn, names) catch
        return mod.errPayload("Query failed");
    defer emap.deinit(allocator);

    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll("{\"entities\":[") catch return mod.errPayload("Serialization error");

    var first = true;
    for (names) |name| {
        const e = emap.get(name) orelse continue;
        if (!first) w.writeByte(',') catch return mod.errPayload("Serialization error");
        first = false;
        writeEntityObject(w, name, e.entity_type, e.observations) catch
            return mod.errPayload("Serialization error");
    }
    w.writeAll("],\"relations\":[") catch return mod.errPayload("Serialization error");

    const r_sql = mod.renderToOwned(allocator, graph.writeRelationsForEntitySet, .{names}) catch
        return mod.errPayload("Allocation error");
    defer allocator.free(r_sql);

    const r_result = conn.query(allocator, r_sql) catch {
        w.writeAll("]}") catch return mod.errPayload("Serialization error");
        return .{ .text = aw.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
    };
    if (r_result.rows) |r_rows| {
        for (r_rows, 0..) |row, i| {
            if (i > 0) w.writeByte(',') catch return mod.errPayload("Serialization error");
            writeRelationObject(w, row.values[0] orelse "", row.values[1] orelse "", row.values[2] orelse "") catch
                return mod.errPayload("Serialization error");
        }
    }

    w.writeAll("]}") catch return mod.errPayload("Serialization error");
    return .{ .text = aw.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
}

pub fn getEntityStats(_: Io, allocator: Allocator, conn: *PooledConn, _: ?Value) Payload {
    const sql = mod.renderToOwned(allocator, graph.writeEntityTypeCounts, .{}) catch
        return mod.errPayload("Allocation error");
    defer allocator.free(sql);
    const result = conn.query(allocator, sql) catch return mod.errPayload("Query failed");
    return mod.resultPayload(allocator, result);
}

pub fn getRelationStats(_: Io, allocator: Allocator, conn: *PooledConn, _: ?Value) Payload {
    const sql = mod.renderToOwned(allocator, graph.writeRelationTypeCounts, .{}) catch
        return mod.errPayload("Allocation error");
    defer allocator.free(sql);
    const result = conn.query(allocator, sql) catch return mod.errPayload("Query failed");
    return mod.resultPayload(allocator, result);
}

pub fn searchRelations(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const from = mod.getStringParam(args, "from");
    const to = mod.getStringParam(args, "to");
    const rtype = mod.getStringParam(args, "relationType");

    const sql = mod.renderToOwned(allocator, graph.writeSearchRelations, .{ from, to, rtype }) catch
        return mod.errPayload("Allocation error");
    defer allocator.free(sql);
    const result = conn.query(allocator, sql) catch return mod.errPayload("Query failed");
    return mod.resultPayload(allocator, result);
}

pub fn getNeighbors(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const names_val = mod.getArrayParam(args, "names") orelse
        return mod.errPayload("Missing 'names' parameter");

    const names = stringArray(allocator, names_val) catch |err| return switch (err) {
        error.NotString => mod.errPayload("Name must be a string"),
        error.OutOfMemory => mod.errPayload("Allocation error"),
    };

    const dir_str = mod.getStringParam(args, "direction");
    const dir = types.Direction.parse(dir_str);

    const sql = switch (dir) {
        .out => mod.renderToOwned(allocator, graph.writeOutgoingRelations, .{names}) catch
            return mod.errPayload("Allocation error"),
        .incoming => mod.renderToOwned(allocator, graph.writeIncomingRelations, .{names}) catch
            return mod.errPayload("Allocation error"),
        .both => mod.renderToOwned(allocator, graph.writeRelationsForEntitySet, .{names}) catch
            return mod.errPayload("Allocation error"),
    };
    defer allocator.free(sql);

    const result = conn.query(allocator, sql) catch return mod.errPayload("Query failed");
    const rows = result.rows orelse {
        return .{ .text = "{\"entities\":[],\"relations\":[]}", .is_error = false };
    };

    // Collect the distinct endpoints of every incident relation, then fetch all
    // of their entity rows in a single round-trip.
    var neighbor_names: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer neighbor_names.deinit(allocator);

    // At most two distinct endpoints per relation row; size once up front.
    neighbor_names.ensureTotalCapacity(allocator, @intCast(rows.len * 2)) catch
        return mod.errPayload("Allocation error");
    for (rows) |row| {
        const from = row.values[0] orelse "";
        const to = row.values[2] orelse "";
        neighbor_names.putAssumeCapacity(from, {});
        neighbor_names.putAssumeCapacity(to, {});
    }

    var emap = fetchEntitiesByName(allocator, conn, neighbor_names.keys()) catch
        return mod.errPayload("Query failed");
    defer emap.deinit(allocator);

    var kg = Writer.Allocating.init(allocator);
    defer kg.deinit();
    const kw = &kg.writer;

    kw.writeAll("{\"entities\":[") catch return mod.errPayload("Serialization error");
    var first_entity = true;
    for (neighbor_names.keys()) |nname| {
        const e = emap.get(nname) orelse continue;
        if (!first_entity) kw.writeByte(',') catch return mod.errPayload("Serialization error");
        first_entity = false;
        writeEntityObject(kw, nname, e.entity_type, e.observations) catch
            return mod.errPayload("Serialization error");
    }
    kw.writeAll("],\"relations\":[") catch return mod.errPayload("Serialization error");
    for (rows, 0..) |row, i| {
        if (i > 0) kw.writeByte(',') catch return mod.errPayload("Serialization error");
        writeRelationObject(kw, row.values[0] orelse "", row.values[1] orelse "", row.values[2] orelse "") catch
            return mod.errPayload("Serialization error");
    }
    kw.writeAll("]}") catch return mod.errPayload("Serialization error");

    return .{ .text = kg.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
}

pub fn getEntityDegree(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const name = mod.getStringParam(args, "name") orelse return mod.errPayload("Missing 'name' parameter");
    const dir_str = mod.getStringParam(args, "direction");
    const dir = types.Direction.parse(dir_str);

    const sql = mod.renderToOwned(allocator, graph.writeDegree, .{ name, dir }) catch
        return mod.errPayload("Allocation error");
    defer allocator.free(sql);
    const result = conn.query(allocator, sql) catch return mod.errPayload("Query failed");
    const rows = result.rows orelse return mod.errPayload("No result");
    if (rows.len == 0) return mod.errPayload("No data");

    const count_val = rows[0].values[0] orelse "0";
    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    aw.writer.print("{{\"degree\":{s}}}", .{count_val}) catch
        return mod.errPayload("Serialization error");
    return .{ .text = aw.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
}

pub fn getGraphStatistics(_: Io, allocator: Allocator, conn: *PooledConn, _: ?Value) Payload {
    // Both counts come back in one round-trip as a single two-column row.
    const sql = mod.renderToOwned(allocator, graph.writeGraphStatistics, .{}) catch
        return mod.errPayload("Allocation error");
    defer allocator.free(sql);
    const result = conn.query(allocator, sql) catch return mod.errPayload("Query failed");
    const row0 = if (result.rows) |rows| (if (rows.len > 0) rows[0] else null) else null;
    const e_count = if (row0) |r| r.values[0] orelse "0" else "0";
    const r_count = if (row0) |r| r.values[1] orelse "0" else "0";

    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    aw.writer.print("{{\"entity_count\":{s},\"relation_count\":{s}}}", .{ e_count, r_count }) catch
        return mod.errPayload("Serialization error");
    return .{ .text = aw.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
}

pub fn upsertVectorEmbedding(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const id = mod.getStringParam(args, "id") orelse return mod.errPayload("Missing 'id' parameter");
    const entity_name = mod.getStringParam(args, "entityName") orelse return mod.errPayload("Missing 'entityName' parameter");
    const text_content = mod.getStringParam(args, "textContent") orelse return mod.errPayload("Missing 'textContent' parameter");

    const vec_val = mod.getArrayParam(args, "vector") orelse
        return mod.errPayload("Missing 'vector' parameter");

    var vec: [vector_dims]f32 = undefined;
    const vec_slice = parseVector(&vec, vec_val) catch |err| return switch (err) {
        error.TooLong => mod.errPayload("Vector exceeds 384 dimensions"),
        error.NotNumber => mod.errPayload("Vector must contain numbers"),
    };

    _ = execBuilt(allocator, conn, vector.writeUpsertVector, .{ id, entity_name, text_content, vec_slice }) catch
        return mod.errPayload("Upsert failed");

    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll("{\"id\":") catch return mod.errPayload("Serialization error");
    writeJsonString(w, id) catch return mod.errPayload("Serialization error");
    w.writeByte('}') catch return mod.errPayload("Serialization error");
    return .{ .text = aw.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
}

pub fn vectorSearch(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const vec_val = mod.getArrayParam(args, "vector") orelse
        return mod.errPayload("Missing 'vector' parameter");
    const limit_val = mod.getStringParam(args, "limit") orelse "10";
    const limit = std.fmt.parseUnsigned(u64, limit_val, 10) catch 10;
    const metric_str = mod.getStringParam(args, "metric");
    const is_euclidean = if (metric_str) |m| std.ascii.eqlIgnoreCase(m, "euclidean") else false;

    var vec: [vector_dims]f32 = undefined;
    const vec_slice = parseVector(&vec, vec_val) catch |err| return switch (err) {
        error.TooLong => mod.errPayload("Vector exceeds 384 dimensions"),
        error.NotNumber => mod.errPayload("Vector must contain numbers"),
    };

    const sql = mod.renderToOwned(allocator, vector.writeSearchVectors, .{ vec_slice, limit }) catch
        return mod.errPayload("Allocation error");
    defer allocator.free(sql);
    const result = conn.query(allocator, sql) catch return mod.errPayload("Query failed");
    return reorderKgRows(allocator, result, vec_slice, is_euclidean);
}

/// Interpret raw f32 blob bytes as a float slice.
fn embFromBlob(a: Allocator, blob: []const u8) ![]f32 {
    const n = blob.len / @sizeOf(f32);
    if (n == 0 or blob.len % @sizeOf(f32) != 0) return error.InvalidBlob;
    const out = try a.alloc(f32, n);
    @memcpy(std.mem.sliceAsBytes(out), blob);
    return out;
}

fn reorderKgRows(a: Allocator, result: pool.QueryResult, qvec: []const f32, is_euclidean: bool) Payload {
    const rows = result.rows orelse return mod.resultPayload(a, result);
    if (rows.len < 2) return mod.resultPayload(a, result);

    const n = rows.len;
    const distances = a.alloc(f32, n) catch return mod.errPayload("Allocation error");
    defer a.free(distances);

    const valid = a.alloc(bool, n) catch return mod.errPayload("Allocation error");
    defer a.free(valid);

    for (rows, 0..) |row, i| {
        const emb = embFromBlob(a, row.values[3] orelse "") catch {
            valid[i] = false;
            continue;
        };
        valid[i] = emb.len > 0;
        distances[i] = if (valid[i])
            if (is_euclidean) fusion.euclideanDistance(emb, qvec) else 1.0 - fusion.cosineSimilarity(emb, qvec)
        else
            std.math.inf(f32);
    }

    const indices = a.alloc(usize, n) catch return mod.errPayload("Allocation error");
    defer a.free(indices);
    for (0..n) |i| indices[i] = i;

    const SortCtx = struct { d: []const f32, v: []const bool };
    std.sort.block(usize, indices, SortCtx{ .d = distances, .v = valid }, struct {
        fn less(ctx: SortCtx, x: usize, y: usize) bool {
            if (ctx.v[x] != ctx.v[y]) return ctx.v[x];
            return ctx.d[x] < ctx.d[y];
        }
    }.less);

    const sorted_rows = a.alloc(sqtypes.Row, n) catch return mod.errPayload("Allocation error");
    for (indices, 0..) |idx, i| sorted_rows[i] = rows[idx];

    const sorted = sqtypes.QueryResult{
        .rows = sorted_rows,
        .column_names = result.column_names,
        .column_kinds = result.column_kinds,
        .num_fields = result.num_fields,
        .num_rows = result.num_rows,
        .affected_rows = result.affected_rows,
        .insert_id = result.insert_id,
    };
    return mod.resultPayload(a, sorted);
}

pub fn deleteVectorEmbedding(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const entity_name = mod.getStringParam(args, "entityName");

    if (entity_name) |name| {
        const affected = execBuilt(allocator, conn, vector.writeDeleteVectorsByEntity, .{name}) catch
            return mod.errPayload("Delete failed");

        var aw = Writer.Allocating.init(allocator);
        defer aw.deinit();
        aw.writer.print("{{\"deleted\":{d}}}", .{affected}) catch
            return mod.errPayload("Serialization error");
        return .{ .text = aw.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
    }

    const id = mod.getStringParam(args, "id") orelse return mod.errPayload("Missing 'id' or 'entityName' parameter");
    const affected = execBuilt(allocator, conn, vector.writeDeleteVectorById, .{id}) catch
        return mod.errPayload("Delete failed");

    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    aw.writer.print("{{\"deleted\":{d}}}", .{affected}) catch
        return mod.errPayload("Serialization error");
    return .{ .text = aw.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
}

pub fn bfsPath(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const source = mod.getStringParam(args, "source") orelse
        return mod.errPayload("Missing 'source' parameter");
    const target = mod.getStringParam(args, "target") orelse
        return mod.errPayload("Missing 'target' parameter");
    const max_hops_str = mod.getStringParam(args, "maxHops");
    const max_hops = if (max_hops_str) |s| std.fmt.parseUnsigned(u64, s, 10) catch 10 else 10;
    const dir_str = mod.getStringParam(args, "direction");
    const dir = types.Direction.parse(dir_str);

    var visited: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer visited.deinit(allocator);
    var predecessors: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    defer predecessors.deinit(allocator);
    var frontier: std.ArrayListUnmanaged([]const u8) = .empty;
    defer frontier.deinit(allocator);
    var next_set: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer next_set.deinit(allocator);

    visited.put(allocator, source, {}) catch return mod.errPayload("Allocation error");
    frontier.append(allocator, source) catch return mod.errPayload("Allocation error");

    var found = false;
    var depth: u64 = 0;

    while (depth < max_hops and !found and frontier.items.len > 0) : (depth += 1) {
        const sql = mod.renderToOwned(allocator, graph.writeBfsExpand, .{ frontier.items, dir }) catch
            return mod.errPayload("Allocation error");
        defer allocator.free(sql);

        const result = conn.query(allocator, sql) catch return mod.errPayload("Query failed");
        const rows = result.rows orelse break;

        next_set.clearRetainingCapacity();
        frontier.clearRetainingCapacity();

        for (rows) |row| {
            const parent = row.values[0] orelse "";
            const child = row.values[1] orelse "";
            if (child.len == 0) continue;

            if (visited.get(child) != null) continue;
            visited.put(allocator, child, {}) catch return mod.errPayload("Allocation error");
            predecessors.put(allocator, child, parent) catch return mod.errPayload("Allocation error");

            if (std.mem.eql(u8, child, target)) {
                found = true;
                break;
            }

            if (next_set.get(child) == null) {
                next_set.put(allocator, child, {}) catch return mod.errPayload("Allocation error");
                frontier.append(allocator, child) catch return mod.errPayload("Allocation error");
            }
        }
    }

    if (!found) return mod.errPayload("No path found");

    var path_rev: std.ArrayListUnmanaged([]const u8) = .empty;
    defer path_rev.deinit(allocator);

    var current = target;
    while (!std.mem.eql(u8, current, source)) {
        path_rev.append(allocator, current) catch return mod.errPayload("Allocation error");
        current = predecessors.get(current) orelse break;
    }
    path_rev.append(allocator, source) catch return mod.errPayload("Allocation error");

    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll("{\"path\":[") catch return mod.errPayload("Serialization error");
    var i = path_rev.items.len;
    while (i > 0) {
        i -= 1;
        writeJsonString(w, path_rev.items[i]) catch return mod.errPayload("Serialization error");
        if (i > 0) w.writeByte(',') catch return mod.errPayload("Serialization error");
    }
    w.writeAll("]}") catch return mod.errPayload("Serialization error");

    return .{ .text = aw.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
}

pub fn fulltextSearch(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const query = mod.getStringParam(args, "query") orelse
        return mod.errPayload("Missing 'query' parameter");
    const limit_str = mod.getStringParam(args, "limit");
    const limit = if (limit_str) |s| std.fmt.parseUnsigned(u64, s, 10) catch 20 else 20;

    const sql = mod.renderToOwned(allocator, graph.writeFulltextSearch, .{ query, limit }) catch
        return mod.errPayload("Allocation error");
    defer allocator.free(sql);
    const result = conn.query(allocator, sql) catch return mod.errPayload("Query failed");
    return mod.resultPayload(allocator, result);
}

// ── Tests (DB-free helper coverage) ───────────────────────────────────

const testing = std.testing;

fn jsonArray(arena: *std.heap.ArenaAllocator, src: []const u8) std.json.Array {
    const parsed = std.json.parseFromSlice(Value, arena.allocator(), src, .{}) catch unreachable;
    return parsed.value.array;
}

test "parseVector accepts mixed int/float and reports length" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [vector_dims]f32 = undefined;
    const arr = jsonArray(&arena, "[1, 2.5, 3, -4.25]");
    const out = try parseVector(&buf, arr);
    try testing.expectEqual(@as(usize, 4), out.len);
    try testing.expectEqual(@as(f32, 1.0), out[0]);
    try testing.expectEqual(@as(f32, 2.5), out[1]);
    try testing.expectEqual(@as(f32, 3.0), out[2]);
    try testing.expectEqual(@as(f32, -4.25), out[3]);
}

test "parseVector rejects non-numbers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [vector_dims]f32 = undefined;
    const arr = jsonArray(&arena, "[1, \"two\", 3]");
    try testing.expectError(error.NotNumber, parseVector(&buf, arr));
}

test "parseVector rejects over-long vectors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [vector_dims]f32 = undefined;
    // Build a 385-element array.
    var aw = Writer.Allocating.init(arena.allocator());
    try aw.writer.writeByte('[');
    for (0..vector_dims + 1) |i| {
        if (i > 0) try aw.writer.writeByte(',');
        try aw.writer.writeByte('1');
    }
    try aw.writer.writeByte(']');
    const arr = jsonArray(&arena, try aw.toOwnedSlice());
    try testing.expectError(error.TooLong, parseVector(&buf, arr));
}

test "parseVector accepts exactly 384 dims" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: [vector_dims]f32 = undefined;
    var aw = Writer.Allocating.init(arena.allocator());
    try aw.writer.writeByte('[');
    for (0..vector_dims) |i| {
        if (i > 0) try aw.writer.writeByte(',');
        try aw.writer.writeByte('0');
    }
    try aw.writer.writeByte(']');
    const arr = jsonArray(&arena, try aw.toOwnedSlice());
    const out = try parseVector(&buf, arr);
    try testing.expectEqual(@as(usize, vector_dims), out.len);
}

test "stringArray collects strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const arr = jsonArray(&arena, "[\"a\",\"b\",\"c\"]");
    const out = try stringArray(arena.allocator(), arr);
    try testing.expectEqual(@as(usize, 3), out.len);
    try testing.expectEqualStrings("a", out[0]);
    try testing.expectEqualStrings("c", out[2]);
}

test "stringArray rejects non-string element" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const arr = jsonArray(&arena, "[\"a\", 2]");
    try testing.expectError(error.NotString, stringArray(arena.allocator(), arr));
}

test "stringArray handles empty array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const arr = jsonArray(&arena, "[]");
    const out = try stringArray(arena.allocator(), arr);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "writeEntityObject embeds raw observations and escapes name/type" {
    var buf: [512]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeEntityObject(&w, "A\"x", "person", "[\"o1\"]");
    try testing.expectEqualStrings(
        "{\"name\":\"A\\\"x\",\"entityType\":\"person\",\"observations\":[\"o1\"]}",
        w.buffered(),
    );
}

test "writeRelationObject" {
    var buf: [256]u8 = undefined;
    var w = Writer.fixed(&buf);
    try writeRelationObject(&w, "A", "knows", "B");
    try testing.expectEqualStrings(
        "{\"from\":\"A\",\"relationType\":\"knows\",\"to\":\"B\"}",
        w.buffered(),
    );
}

// ---- fuzzing --------------------------------------------------------------
// parseVector and stringArray consume arrays parsed from untrusted JSON; per
// Agent.md every such extractor gets a property test asserting it never panics
// across all JSON value variants, lengths spanning the 384-dim cap, and the
// empty case. We feed generated JSON text through the real parser so the whole
// bytes -> Value -> extractor path is exercised.

test "fuzz: parseVector / stringArray never panic on random JSON arrays" {
    var prng = std.Random.DefaultPrng.init(0xF00D);
    const rnd = prng.random();
    var fbuf: [vector_dims]f32 = undefined;

    for (0..500) |_| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var aw = Writer.Allocating.init(a);
        const w = &aw.writer;
        w.writeByte('[') catch continue;
        const n = rnd.intRangeAtMost(usize, 0, 400); // spans the 384 cap on both sides
        for (0..n) |i| {
            if (i > 0) w.writeByte(',') catch continue;
            switch (rnd.intRangeLessThan(u8, 0, 6)) {
                0 => w.writeAll("null") catch {},
                1 => w.writeAll(if (rnd.boolean()) "true" else "false") catch {},
                2 => w.print("{d}", .{rnd.int(i32)}) catch {},
                3 => w.print("{d}.25", .{rnd.int(i16)}) catch {},
                4 => w.writeAll("\"s\"") catch {},
                else => w.writeAll("[]") catch {},
            }
        }
        w.writeByte(']') catch continue;
        const src = aw.toOwnedSlice() catch continue;

        const parsed = std.json.parseFromSlice(Value, a, src, .{}) catch continue;
        if (parsed.value != .array) continue;
        const arr = parsed.value.array;
        _ = parseVector(&fbuf, arr) catch {};
        _ = stringArray(a, arr) catch {};
    }
}
