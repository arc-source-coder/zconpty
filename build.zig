const std = @import("std");

fn addUucodeImport(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    if (b.lazyDependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .build_config_path = b.path("src/build/uucode_config.zig"),
    })) |dep| {
        module.addImport("uucode", dep.module("uucode"));
    }
}

pub fn build(b: *std.Build) void {
    const target = blk: {
        var result = b.standardTargetOptions(.{});
        // Match shim defaults: use MSVC ABI on Windows unless explicitly overridden.
        if (result.result.os.tag == .windows and result.query.abi == null) {
            var query = result.query;
            query.abi = .msvc;
            result = b.resolveTargetQuery(query);
        }
        break :blk result;
    };
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("zconpty", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    addUucodeImport(b, module, target, optimize);

    const test_step = b.step("test", "Run unit tests");
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addUucodeImport(b, lib_tests.root_module, target, optimize);
    lib_tests.root_module.addImport("zconpty", module);
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);

    const fmt_step = b.step("fmt", "Check code formatting");
    const fmt_check = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" }, .check = true });
    fmt_step.dependOn(&fmt_check.step);
    test_step.dependOn(fmt_step);
}
