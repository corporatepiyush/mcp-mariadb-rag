const std = @import("std");
const pool = @import("../pool.zig");
const json = @import("../json.zig");
const validation = @import("../validation.zig");
const mod = @import("mod.zig");
const graph = @import("../kg/graph.zig");
const vector = @import("../kg/vector.zig");
const types = @import("../kg/types.zig");
const schema = @import("../kg/schema.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const PooledConn = pool.PooledConnection;
const Payload = mod.Payload;
const Writer = std.Io.Writer;

fn writeObservationsBatch(w: *Writer, entity_name: []const u8, contents: []const []const u8) !void {
    try w.writeAll("INSERT INTO ");
    try validation.writeQuotedIdent(w, schema.observation_table);
    try w.writeAll(" (entity_name, content) VALUES");
    for (contents, 0..) |content, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll(" ('");
        try validation.writeEscapedLiteral(w, entity_name);
        try w.writeByte('\'');
        try w.writeByte(',');
        try w.writeByte('\'');
        try validation.writeEscapedLiteral(w, content);
        try w.writeByte('\'');
        try w.writeByte(')');
    }
}

fn execBuilt(allocator: Allocator, conn: *PooledConn, comptime write_fn: anytype, args: anytype) !u64 {
    const sql = try mod.renderToOwned(allocator, write_fn, args);
    defer allocator.free(sql);
    return conn.execute(sql);
}

fn writeJsonString(w: *Writer, s: []const u8) !void {
    try json.writeQuoted(w, s);
}

pub fn createEntities(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const entities_val = mod.getArrayParam(args, "entities") orelse
        return mod.errPayload("Missing 'entities' parameter");

    const entities = types.entitiesFromValue(allocator, Value{ .array = entities_val }) catch
        return mod.errPayload("Invalid entity format");

    {
        var batch: std.ArrayList(graph.EntityInsertRow) = .empty;
        defer batch.deinit(allocator);
        for (entities) |entity| {
            const obs_json = graph.observationsToJson(allocator, entity.observations) catch
                return mod.errPayload("Serialization error");
            batch.append(allocator, .{ .name = entity.name, .entity_type = entity.entity_type, .obs_json = obs_json }) catch
                return mod.errPayload("Allocation error");
        }
        const sql = mod.renderToOwned(allocator, graph.writeInsertEntities, .{batch.items}) catch
            return mod.errPayload("Allocation error");
        defer allocator.free(sql);
        _ = conn.execute(sql) catch return mod.errPayload("Create entity failed");
    }

    for (entities) |entity| {
        if (entity.observations.len > 0) {
            const ins_sql = mod.renderToOwned(allocator, writeObservationsBatch, .{ entity.name, entity.observations }) catch
                return mod.errPayload("Allocation error");
            defer allocator.free(ins_sql);
            _ = conn.execute(ins_sql) catch return mod.errPayload("Create observations failed");
        }
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

    for (relations) |rel| {
        _ = execBuilt(allocator, conn, graph.writeInsertRelation, .{ rel.from, rel.relation_type, rel.to }) catch
            return mod.errPayload("Create relation failed");
    }

    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    aw.writer.print("{{\"relations_created\":{d}}}", .{relations.len}) catch
        return mod.errPayload("Serialization error");
    return .{ .text = aw.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
}

pub fn deleteEntities(_: Io, allocator: Allocator, conn: *PooledConn, args: ?Value) Payload {
    const names_val = mod.getArrayParam(args, "names") orelse
        return mod.errPayload("Missing 'names' parameter");

    var names: std.ArrayList([]const u8) = .empty;
    for (names_val.items) |item| {
        if (item != .string) return mod.errPayload("Name must be a string");
        names.append(allocator, item.string) catch return mod.errPayload("Allocation error");
    }

    if (names.items.len == 0) return mod.errPayload("Empty names list");

    for (names.items) |name| {
        const sql = mod.renderToOwned(allocator, graph.writeDeleteEntity, .{name}) catch
            return mod.errPayload("Allocation error");
        defer allocator.free(sql);
        _ = conn.execute(sql) catch return mod.errPayload("Delete failed");
    }

    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    aw.writer.print("{{\"deleted\":{d}}}", .{names.items.len}) catch
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

    var contents: std.ArrayList([]const u8) = .empty;
    for (obs_val.items) |item| {
        if (item != .string) return mod.errPayload("Observation must be a string");
        contents.append(allocator, item.string) catch return mod.errPayload("Allocation error");
    }
    const obs_slice = contents.items;

    if (obs_slice.len == 0) {
        var aw = Writer.Allocating.init(allocator);
        defer aw.deinit();
        aw.writer.writeAll("{\"observations_added\":0}") catch
            return mod.errPayload("Serialization error");
        return .{ .text = aw.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
    }

    const ins_sql = mod.renderToOwned(allocator, writeObservationsBatch, .{ name, obs_slice }) catch
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

    var contents: std.ArrayList([]const u8) = .empty;
    for (obs_val.items) |item| {
        if (item != .string) return mod.errPayload("Observation must be a string");
        contents.append(allocator, item.string) catch return mod.errPayload("Allocation error");
    }
    const obs_slice = contents.items;

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
    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;

    w.writeAll("{\"entities\":[") catch return mod.errPayload("Serialization error");
    for (e_rows, 0..) |row, i| {
        const ename = row.values[0] orelse "";
        const etype = row.values[1] orelse "";
        const eobs = row.values[2] orelse "[]";

        entity_names.append(allocator, ename) catch return mod.errPayload("Allocation error");

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

    var names: std.ArrayList([]const u8) = .empty;
    for (names_val.items) |item| {
        if (item != .string) return mod.errPayload("Name must be a string");
        names.append(allocator, item.string) catch return mod.errPayload("Allocation error");
    }

    if (names.items.len == 0) return mod.errPayload("Empty names list");

    var aw = Writer.Allocating.init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll("{\"entities\":[") catch return mod.errPayload("Serialization error");

    const r_sql = mod.renderToOwned(allocator, graph.writeRelationsForEntitySet, .{names.items}) catch
        return mod.errPayload("Allocation error");
    defer allocator.free(r_sql);

    for (names.items, 0..) |name, i| {
        const sql = mod.renderToOwned(allocator, graph.writeGetEntity, .{name}) catch
            return mod.errPayload("Allocation error");
        defer allocator.free(sql);

        const result = conn.query(allocator, sql) catch continue;
        const rows = result.rows orelse continue;
        if (rows.len == 0) continue;
        const row = rows[0];
        const etype = row.values[0] orelse "";
        const eobs = row.values[1] orelse "[]";

        if (i > 0) w.writeByte(',') catch return mod.errPayload("Serialization error");
        w.writeAll("{\"name\":") catch return mod.errPayload("Serialization error");
        writeJsonString(w, name) catch return mod.errPayload("Serialization error");
        w.writeAll(",\"entityType\":") catch return mod.errPayload("Serialization error");
        writeJsonString(w, etype) catch return mod.errPayload("Serialization error");
        w.writeAll(",\"observations\":") catch return mod.errPayload("Serialization error");
        w.writeAll(eobs) catch return mod.errPayload("Serialization error");
        w.writeByte('}') catch return mod.errPayload("Serialization error");
    }
    w.writeAll("],\"relations\":[") catch return mod.errPayload("Serialization error");

    const r_result = conn.query(allocator, r_sql) catch {
        w.writeAll("]}") catch return mod.errPayload("Serialization error");
        return .{ .text = aw.toOwnedSlice() catch return mod.errPayload("Allocation error"), .is_error = false };
    };
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

    var names: std.ArrayList([]const u8) = .empty;
    for (names_val.items) |item| {
        if (item != .string) return mod.errPayload("Name must be a string");
        names.append(allocator, item.string) catch return mod.errPayload("Allocation error");
    }

    const dir_str = mod.getStringParam(args, "direction");
    const dir = types.Direction.parse(dir_str);

    const sql = switch (dir) {
        .out => mod.renderToOwned(allocator, graph.writeOutgoingRelations, .{names.items}) catch
            return mod.errPayload("Allocation error"),
        .incoming => mod.renderToOwned(allocator, graph.writeIncomingRelations, .{names.items}) catch
            return mod.errPayload("Allocation error"),
        .both => mod.renderToOwned(allocator, graph.writeRelationsForEntitySet, .{names.items}) catch
            return mod.errPayload("Allocation error"),
    };
    defer allocator.free(sql);

    const result = conn.query(allocator, sql) catch return mod.errPayload("Query failed");
    const rows = result.rows orelse {
        return .{ .text = "{\"entities\":[],\"relations\":[]}", .is_error = false };
    };

    var neighbor_names: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer neighbor_names.deinit(allocator);

    for (rows) |row| {
        const from = row.values[0] orelse "";
        const to = row.values[2] orelse "";
        if (neighbor_names.get(from) == null) {
            neighbor_names.put(allocator, from, {}) catch return mod.errPayload("Allocation error");
        }
        if (neighbor_names.get(to) == null) {
            neighbor_names.put(allocator, to, {}) catch return mod.errPayload("Allocation error");
        }
    }

    var kg = Writer.Allocating.init(allocator);
    defer kg.deinit();
    const kw = &kg.writer;

    kw.writeAll("{\"entities\":[") catch return mod.errPayload("Serialization error");
    var first_entity = true;
    for (neighbor_names.keys()) |nname| {
        const e_sql = mod.renderToOwned(allocator, graph.writeGetEntity, .{nname}) catch
            return mod.errPayload("Allocation error");
        defer allocator.free(e_sql);

        const e_result = conn.query(allocator, e_sql) catch continue;
        const e_rows = e_result.rows orelse continue;
        if (e_rows.len == 0) continue;
        const erow = e_rows[0];
        const etype = erow.values[0] orelse "";
        const eobs = erow.values[1] orelse "[]";

        if (!first_entity) kw.writeByte(',') catch return mod.errPayload("Serialization error");
        first_entity = false;
        kw.writeAll("{\"name\":") catch return mod.errPayload("Serialization error");
        writeJsonString(kw, nname) catch return mod.errPayload("Serialization error");
        kw.writeAll(",\"entityType\":") catch return mod.errPayload("Serialization error");
        writeJsonString(kw, etype) catch return mod.errPayload("Serialization error");
        kw.writeAll(",\"observations\":") catch return mod.errPayload("Serialization error");
        kw.writeAll(eobs) catch return mod.errPayload("Serialization error");
        kw.writeByte('}') catch return mod.errPayload("Serialization error");
    }
    kw.writeAll("],\"relations\":[") catch return mod.errPayload("Serialization error");
    for (rows, 0..) |row, i| {
        if (i > 0) kw.writeByte(',') catch return mod.errPayload("Serialization error");
        kw.writeAll("{\"from\":") catch return mod.errPayload("Serialization error");
        writeJsonString(kw, row.values[0] orelse "") catch return mod.errPayload("Serialization error");
        kw.writeAll(",\"relationType\":") catch return mod.errPayload("Serialization error");
        writeJsonString(kw, row.values[1] orelse "") catch return mod.errPayload("Serialization error");
        kw.writeAll(",\"to\":") catch return mod.errPayload("Serialization error");
        writeJsonString(kw, row.values[2] orelse "") catch return mod.errPayload("Serialization error");
        kw.writeByte('}') catch return mod.errPayload("Serialization error");
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
    const e_sql = mod.renderToOwned(allocator, graph.writeCountEntities, .{}) catch
        return mod.errPayload("Allocation error");
    defer allocator.free(e_sql);
    const e_result = conn.query(allocator, e_sql) catch return mod.errPayload("Query failed");
    const e_count = if (e_result.rows) |rows| (if (rows.len > 0) rows[0].values[0] orelse "0" else "0") else "0";

    const r_sql = mod.renderToOwned(allocator, graph.writeCountRelations, .{}) catch
        return mod.errPayload("Allocation error");
    defer allocator.free(r_sql);
    const r_result = conn.query(allocator, r_sql) catch return mod.errPayload("Query failed");
    const r_count = if (r_result.rows) |rows| (if (rows.len > 0) rows[0].values[0] orelse "0" else "0") else "0";

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

    var vec: [384]f32 = undefined;
    if (vec_val.items.len > 384) return mod.errPayload("Vector exceeds 384 dimensions");
    for (vec_val.items, 0..) |item, i| {
        vec[i] = switch (item) {
            .float => |f| @as(f32, @floatCast(f)),
            .integer => |n| @as(f32, @floatFromInt(n)),
            else => return mod.errPayload("Vector must contain numbers"),
        };
    }

    _ = execBuilt(allocator, conn, vector.writeUpsertVector, .{ id, entity_name, text_content, vec[0..vec_val.items.len] }) catch
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

    var vec: [384]f32 = undefined;
    if (vec_val.items.len > 384) return mod.errPayload("Vector exceeds 384 dimensions");
    for (vec_val.items, 0..) |item, i| {
        vec[i] = switch (item) {
            .float => |f| @as(f32, @floatCast(f)),
            .integer => |n| @as(f32, @floatFromInt(n)),
            else => return mod.errPayload("Vector must contain numbers"),
        };
    }

    const sql = mod.renderToOwned(allocator, vector.writeSearchVectors, .{ vec[0..vec_val.items.len], limit }) catch
        return mod.errPayload("Allocation error");
    defer allocator.free(sql);
    const result = conn.query(allocator, sql) catch return mod.errPayload("Query failed");
    return mod.resultPayload(allocator, result);
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
