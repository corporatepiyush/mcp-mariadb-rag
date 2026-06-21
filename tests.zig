//! Test aggregator at project root so both `src/` and `tests/` are in the
//! module tree. This file is the root_source_file for the test build step.

comptime {
    // ---- Source module inline tests --------------------------------------
    _ = @import("src/json.zig");
    _ = @import("src/url.zig");
    _ = @import("src/validation.zig");
    _ = @import("src/actions/schema.zig");
    _ = @import("src/actions/kg.zig");
    _ = @import("src/kg/schema.zig");
    _ = @import("src/kg/types.zig");
    _ = @import("src/kg/graph.zig");
    _ = @import("src/kg/vector.zig");

    // ---- Standalone test files -------------------------------------------
    _ = @import("tests/json_test.zig");
    _ = @import("tests/url_test.zig");
    _ = @import("tests/validation_test.zig");
    _ = @import("tests/config_test.zig");
    _ = @import("tests/actions_test.zig");
    _ = @import("tests/server_test.zig");
    _ = @import("tests/integration_test.zig");
    _ = @import("tests/kg_test.zig");
    _ = @import("tests/kg_bench.zig");
}
