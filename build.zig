const std = @import("std");

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

    const test_step = b.step("test", "Run unit tests");
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    lib_tests.root_module.addImport("zconpty", module);
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);

    const fmt_step = b.step("fmt", "Check code formatting");
    const fmt_check = b.addFmt(.{ .paths = &.{ "src", "build.zig", "build.zig.zon" }, .check = true });
    fmt_step.dependOn(&fmt_check.step);
    test_step.dependOn(fmt_step);
}
