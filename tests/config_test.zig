//! Tests for src/config.zig (moved out of src; src holds code only).

const std = @import("std");
const testing = std.testing;
const srcmod = @import("../src/config.zig");

const Config = srcmod.Config;
const HostInfo = srcmod.HostInfo;
const SqliteTuning = srcmod.SqliteTuning;
const Synchronous = srcmod.Synchronous;
const Tier = srcmod.Tier;
const componentUrl = srcmod.componentUrl;
const tierPoolMax = srcmod.tierPoolMax;

// ── Tests ─────────────────────────────────────────────────────────────


test "Tier.detect spans phone to datacenter by RAM" {
    try testing.expectEqual(Tier.mobile, Tier.detect(512 * 1024 * 1024, 1));
    try testing.expectEqual(Tier.edge, Tier.detect(4 * (1 << 30), 2));
    try testing.expectEqual(Tier.server, Tier.detect(32 * (1 << 30), 16));
    try testing.expectEqual(Tier.dc, Tier.detect(256 * (1 << 30), 64));
    // A small-RAM but many-core box is bumped off mobile.
    try testing.expectEqual(Tier.edge, Tier.detect(512 * 1024 * 1024, 8));
}

test "Tier.parse round-trips, rejects junk" {
    try testing.expectEqual(Tier.server, Tier.parse("SERVER").?);
    try testing.expectEqual(Tier.dc, Tier.parse("dc").?);
    try testing.expect(Tier.parse("nonsense") == null);
    try testing.expect(Tier.parse(null) == null);
}

test "SqliteTuning.forTier scales the IO knobs monotonically" {
    const m = SqliteTuning.forTier(.mobile);
    const s = SqliteTuning.forTier(.server);
    const d = SqliteTuning.forTier(.dc);
    try testing.expect(m.cache_kib < s.cache_kib and s.cache_kib < d.cache_kib);
    try testing.expect(m.mmap_bytes == 0 and s.mmap_bytes > 0);
    try testing.expect(d.mmap_bytes > s.mmap_bytes);
    // mobile favours durability; bigger boxes relax to NORMAL under WAL.
    try testing.expectEqual(Synchronous.full, m.synchronous);
    try testing.expectEqual(Synchronous.normal, s.synchronous);
    try testing.expectEqualStrings("MEMORY", d.temp_store.sql());
}

test "tierPoolMax follows the pool sizing table" {
    try testing.expectEqual(@as(u32, 2), tierPoolMax(.mobile, 8));
    try testing.expectEqual(@as(u32, 16), tierPoolMax(.edge, 8));
    try testing.expectEqual(@as(u32, 64), tierPoolMax(.server, 8));
    try testing.expectEqual(@as(u32, 128), tierPoolMax(.dc, 8));
}

test "HostInfo.detect returns sane, nonzero facts" {
    const h = HostInfo.detect();
    try testing.expect(h.cores >= 1);
    try testing.expect(h.ram_bytes >= 1 << 30); // at least the 1 GiB fallback
}

test "componentUrl inserts the component before the extension" {
    const a = testing.allocator;
    const cases = .{
        .{ "sqlite:///tmp/mcp.db", "kg", "sqlite:///tmp/mcp.kg.db" },
        .{ "sqlite:///tmp/mcp.db", "rag", "sqlite:///tmp/mcp.rag.db" },
        .{ "sqlite://./data.db", "kg", "sqlite://./data.kg.db" },
        // No extension: append the component.
        .{ "sqlite:///var/store", "rag", "sqlite:///var/store.rag" },
        // Dots in a directory but not the filename: split on the filename dot.
        .{ "sqlite:///a.b/mcp.db", "kg", "sqlite:///a.b/mcp.kg.db" },
        // In-memory and non-sqlite are returned unchanged.
        .{ "sqlite://", "kg", "sqlite://" },
        .{ "postgres://x/y", "rag", "postgres://x/y" },
    };
    inline for (cases) |case| {
        const got = try componentUrl(a, case[0], case[1]);
        defer a.free(got);
        try testing.expectEqualStrings(case[2], got);
    }
}

test "componentUrl: a dotted directory with an extensionless file appends" {
    const a = testing.allocator;
    // last '.' is before the last '/', so it's part of the directory → append.
    const got = try componentUrl(a, "sqlite:///a.b/store", "kg");
    defer a.free(got);
    try testing.expectEqualStrings("sqlite:///a.b/store.kg", got);
}

test "sqliteFor gives RAG a larger page size, KG the base" {
    var cfg: Config = .{
        .database_url = "",
        .server = undefined,
        .pool = undefined,
        .tls = .{ .enforce = false, .verify = false, .ca_path = null },
        .sqlite = SqliteTuning.forTier(.server), // page_size 8192
    };
    const rag = cfg.sqliteFor(.rag);
    const kg = cfg.sqliteFor(.kg);
    try testing.expectEqual(@as(u32, 16384), rag.page_size); // packs embedding BLOBs
    try testing.expectEqual(cfg.sqlite.page_size, kg.page_size);
    try testing.expect(rag.page_size > kg.page_size);
}
