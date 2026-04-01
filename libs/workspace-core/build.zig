const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // Use system SQLite instead of bundled source to avoid Apple linker alignment issues
    lib_module.linkSystemLibrary("sqlite3", .{});

    const lib = b.addLibrary(.{
        .name = "workspace-core",
        .root_module = lib_module,
        .linkage = .static,
    });
    b.installArtifact(lib);
    lib.installHeader(b.path("include/workspace_core.h"), "workspace_core.h");

    const test_module = b.createModule(.{
        .root_source_file = b.path("tests/store_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_module.linkSystemLibrary("sqlite3", .{});
    test_module.addImport("workspace_core", lib_module);

    const test_exe = b.addTest(.{
        .root_module = test_module,
    });
    const run_tests = b.addRunArtifact(test_exe);

    const test_step = b.step("test", "Run workspace-core tests");
    test_step.dependOn(&run_tests.step);
}
