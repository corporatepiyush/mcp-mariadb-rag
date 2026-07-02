const std = @import("std");
const config_mod = @import("config.zig");
const transport = @import("transport.zig");
const pool_mod = @import("pool.zig");
const schema_kg = @import("kg/schema.zig");
const schema_rag = @import("rag/schema.zig");
const index_store = @import("index/store.zig");
const query_cache = @import("generate/cache.zig");

/// Initialise each component's schema in its own database file from the
/// canonical embedded `.sql`.
fn initSchema(router: *pool_mod.Router) !void {
    {
        var conn = try router.acquire(.kg);
        defer conn.deinit();
        try conn.executeScript(schema_kg.ddl);
    }
    {
        var conn = try router.acquire(.rag);
        defer conn.deinit();
        try conn.executeScript(schema_rag.ddl);
    }
    std.log.info("Schema initialized: kg + rag databases", .{});
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // The Zig 0.16 I/O interface: a `Threaded` implementation provides the
    // concrete `io` that the transports thread through file and socket I/O.
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var config = try config_mod.load(allocator);
    defer config.deinit(allocator);

    std.log.info("Starting MCP RAG Server", .{});

    // Capacity-planning preflight: `MCP_DRY_RUN=1` resolves the full knob table
    // and exits without serving.
    // Resolve the active embedding dimensionality once, before serving.
    schema_rag.setEmbeddingDims(config.embed_dims);

    config.logResolved();
    // Publish the resolved config so tool handlers can read tier-scaled caps.
    config_mod.setActive(&config);
    if (config.dry_run) {
        std.log.info("dry run: exiting without serving (MCP_DRY_RUN)", .{});
        return;
    }

    // Per-component database files: kg + rag get separate SQLite files (or
    // shared in-memory), each with its own pool, WAL, and PRAGMA profile, so a
    // write in one component never blocks the other.
    const kg_url = try config_mod.componentUrl(allocator, config.database_url, "kg");
    defer allocator.free(kg_url);
    const rag_url = try config_mod.componentUrl(allocator, config.database_url, "rag");
    defer allocator.free(rag_url);

    var router = pool_mod.Router{
        .kg = try pool_mod.ConnectionPool.init(io, allocator, kg_url, .{
            .min_size = config.pool.min_size,
            .max_size = config.pool.max_size,
            .tls = config.tls,
            .tuning = config.sqliteFor(.kg),
        }),
        .rag = try pool_mod.ConnectionPool.init(io, allocator, rag_url, .{
            .min_size = config.pool.min_size,
            .max_size = config.pool.max_size,
            .tls = config.tls,
            .tuning = config.sqliteFor(.rag),
        }),
    };
    defer router.close();

    std.log.info("Pools: kg={s} rag={s} (min={d} max={d})", .{
        kg_url, rag_url, config.pool.min_size, config.pool.max_size,
    });

    initSchema(&router) catch |err| {
        std.log.warn("Schema init failed (will be retried on first use): {s}", .{@errorName(err)});
    };

    // Publish the ANN index cache (no-op for queries when MCP_INDEX_TYPE=flat).
    var idx_store = index_store.Store.init(io, allocator, .{
        .enabled = config.index_type == .hnsw,
        .metric = if (config.index_cosine) .cosine else .l2,
        .m = config.hnsw_m,
        .ef_construction = config.hnsw_ef_construction,
        .ef_search = config.hnsw_ef_search,
    });
    defer idx_store.deinit();
    index_store.setGlobal(&idx_store);

    // Semantic query cache (inert when MCP_QCACHE_ENTRIES=0).
    var qcache = try query_cache.QueryCache.init(io, allocator, .{
        .capacity = config.qcache_entries,
        .threshold = config.qcache_threshold,
    });
    defer qcache.deinit();
    query_cache.setGlobal(&qcache);

    std.log.info("Running in stdio mode", .{});
    transport.runStdio(io, allocator, &router, &config);

    std.log.info("Server shutdown complete", .{});
}
