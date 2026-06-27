//! Test aggregator at project root so both `src/` and `tests/` are in the
//! module tree. This file is the root_source_file for the test build step.

comptime {
    // ---- Source module inline tests --------------------------------------
    _ = @import("src/sqlite.zig");
    _ = @import("src/config.zig");
    _ = @import("src/json.zig");
    _ = @import("src/url.zig");
    _ = @import("src/validation.zig");
    _ = @import("src/actions/kg.zig");
    _ = @import("src/actions/rag.zig");
    _ = @import("src/kg/schema.zig");
    _ = @import("src/kg/types.zig");
    _ = @import("src/kg/graph.zig");
    _ = @import("src/kg/vector.zig");
    _ = @import("src/rag/schema.zig");
    _ = @import("src/rag/chunk.zig");
    _ = @import("src/rag/fusion.zig");
    _ = @import("src/rag/query.zig");
    _ = @import("src/rag/retrieve.zig");
    _ = @import("src/embed/quant.zig");
    _ = @import("src/index/flat.zig");
    _ = @import("src/index/hnsw.zig");
    _ = @import("src/index/store.zig");
    _ = @import("src/observe/trace.zig");
    _ = @import("src/generate/cache.zig");

    // ---- Standalone test files -------------------------------------------
    _ = @import("tests/json_test.zig");
    _ = @import("tests/url_test.zig");
    _ = @import("tests/validation_test.zig");
    _ = @import("tests/actions_test.zig");
    _ = @import("tests/server_test.zig");
    _ = @import("tests/integration_test.zig");
    _ = @import("tests/kg_test.zig");
    _ = @import("tests/kg_bench.zig");
    _ = @import("tests/rag_test.zig");
    _ = @import("tests/rag_bench.zig");
    _ = @import("tests/transport_test.zig");
    _ = @import("tests/e2e_test.zig");
}
