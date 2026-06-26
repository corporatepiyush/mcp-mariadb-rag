const std = @import("std");
const config_mod = @import("config.zig");
const transport = @import("transport.zig");
const pool_mod = @import("pool.zig");
const schema_kg = @import("kg/schema.zig");
const schema_rag = @import("rag/schema.zig");
const index_store = @import("index/store.zig");
const query_cache = @import("generate/cache.zig");

fn initKnowledgeGraphSchema(pool: *pool_mod.ConnectionPool) !void {
    var conn = try pool.acquire();
    defer conn.deinit();

    inline for (.{
        schema_kg.writeCreateEntity,
        schema_kg.writeCreateObservation,
        schema_kg.writeCreateRelation,
        schema_kg.writeCreateTypeDict,
        schema_kg.writeCreateGraphStat,
        schema_kg.writeCreateVectorEmbedding,
        // RAG document/chunk store same init path.
        schema_rag.writeCreateDocument,
        schema_rag.writeCreateChunk,
        schema_rag.writeCreateChunkIndex,
    }) |write_fn| {
        var buf: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try write_fn(&w);
        _ = try conn.execute(w.buffered());
    }

    std.log.info("Knowledge graph + RAG schema initialized (8 tables)", .{});
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

    std.log.info("Starting MCP KV Server", .{});

    // Capacity-planning preflight: `MCP_DRY_RUN=1` resolves the full knob table
    // and exits without serving.
    // Resolve the active embedding dimensionality once, before serving.
    schema_rag.setEmbeddingDims(config.embed_dims);

    config.logResolved();
    if (config.dry_run) {
        std.log.info("dry run: exiting without serving (MCP_DRY_RUN)", .{});
        return;
    }

    if (config.server.auth_token == null and !config.server.stdio) {
        std.log.warn("No auth token configured. Set MCP_AUTH_TOKEN for security.", .{});
    }

    var pool = try pool_mod.ConnectionPool.init(io, allocator, config.database_url, .{
        .min_size = config.pool.min_size,
        .max_size = config.pool.max_size,
        .tls = config.tls,
        .tuning = config.sqlite,
    });
    defer pool.close();

    std.log.info("Connection pool initialized: min={d}, max={d}, tls={}", .{
        config.pool.min_size, config.pool.max_size, config.tls.enforce,
    });

    initKnowledgeGraphSchema(&pool) catch |err| {
        std.log.warn("KG schema init failed (will be retried on first use): {s}", .{@errorName(err)});
    };

    // Publish the ANN index cache (no-op for queries when MCP_INDEX_TYPE=flat).
    var idx_store = index_store.Store.init(allocator, io, .{
        .enabled = config.index_type == .hnsw,
        .metric = if (config.index_cosine) .cosine else .l2,
        .m = config.hnsw_m,
        .ef_construction = config.hnsw_ef_construction,
        .ef_search = config.hnsw_ef_search,
    });
    defer idx_store.deinit();
    index_store.setGlobal(&idx_store);

    // Semantic query cache (inert when MCP_QCACHE_ENTRIES=0).
    var qcache = try query_cache.QueryCache.init(allocator, io, .{
        .capacity = config.qcache_entries,
        .threshold = config.qcache_threshold,
    });
    defer qcache.deinit();
    query_cache.setGlobal(&qcache);

    if (config.server.stdio) {
        std.log.info("Running in stdio mode", .{});
        transport.runStdio(io, allocator, &pool, &config);
    } else {
        std.log.info("Starting HTTP server on port {d}", .{config.server.http_port});
        transport.runHttp(io, allocator, &pool, &config);
    }

    std.log.info("Server shutdown complete", .{});
}
