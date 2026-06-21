const std = @import("std");

// Targets MariaDB 12.3 LTS (the current LTS line, supported to 2029) running the
// TidesDB storage engine via the tidesql plugin (https://github.com/tidesdb/tidesql).
// Homebrew's `mariadb` formula currently provides 12.3.x.
const mariadb_include = "/opt/homebrew/opt/mariadb/include/mysql";
const mariadb_lib = "/opt/homebrew/opt/mariadb/lib";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Zig 0.16 deprecated inline `@cImport`; C translation now lives in the
    // build system. `src/c.h` is the single MariaDB translation unit, exposed
    // to Zig source as `@import("c")`.
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(.{ .cwd_relative = mariadb_include });
    const c_module = translate_c.createModule();

    // ---- main executable ----
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureModule(exe_mod, c_module);

    const exe = b.addExecutable(.{
        .name = "mcp-mariadb-rag",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the MCP MariaDB RAG server");
    run_step.dependOn(&run_cmd.step);

    // ---- unit + integration tests ----
    // `tests.zig` at the project root aggregates every module so all `test` blocks are pulled
    // into one binary. DB-dependent tests gate themselves on $DATABASE_URL.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureModule(test_mod, c_module);

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&run_tests.step);
}

/// Wire up libc, the MariaDB client library, and the translated `c` bindings.
///
/// We link ONLY `libmariadb`. It already carries its TLS/compression
/// dependencies (openssl@3's libssl/libcrypto and libz) through its own
/// install-names, as `mariadb_config --libs` (`-lmariadb`) confirms. Linking
/// `ssl`/`crypto`/`z` explicitly here pulled in whatever copy the linker
/// happened to find — with no openssl library path configured — which risked
/// a version mismatch against the openssl libmariadb is actually bound to.
fn configureModule(mod: *std.Build.Module, c_module: *std.Build.Module) void {
    mod.link_libc = true;
    mod.addImport("c", c_module);
    mod.addLibraryPath(.{ .cwd_relative = mariadb_lib });
    mod.linkSystemLibrary("mariadb", .{ .needed = true });
}
