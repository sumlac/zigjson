const std = @import("std");

/// Build graph entry point.
///
/// This file wires:
/// - the library module (`zig_jsonloads`)
/// - a tiny CLI executable (`zig_jsonloads`)
/// - a benchmark executable (`bench_jsonloads`)
/// - test steps for both library and executable roots
pub fn build(b: *std.Build) void {
    // Allow caller-selected target/optimization while keeping sensible defaults.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Public module exported by this package.
    const lib_mod = b.addModule("zig_jsonloads", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Demo CLI executable that imports the parser module.
    const exe = b.addExecutable(.{
        .name = "zig_jsonloads",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_jsonloads", .module = lib_mod },
            },
        }),
    });
    b.installArtifact(exe);

    // Benchmark executable used by `zig build bench`.
    const bench_exe = b.addExecutable(.{
        .name = "bench_jsonloads",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_jsonloads", .module = lib_mod },
            },
        }),
    });
    b.installArtifact(bench_exe);

    // `zig build run -- <json>` helper step.
    const run_step = b.step("run", "Run the CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| run_cmd.addArgs(args);

    // `zig build bench -- <iters>` helper step.
    const bench_step = b.step("bench", "Run parser microbenchmarks");
    const bench_cmd = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&bench_cmd.step);
    if (b.args) |args| bench_cmd.addArgs(args);

    // Library-root tests (`src/root.zig` test blocks).
    const mod_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Executable-root tests (`src/main.zig` test blocks, if any).
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // Aggregate test step.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
