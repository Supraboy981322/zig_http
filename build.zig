const std = @import("std");
const Build = std.Build;
const Target = std.Target.Query;

const test_targets = [_]Target{
    .{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
    },
    // TODO: test other targets
};

pub fn build(b:*Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const opts = b.addOptions();
    const root = b.option([]const u8, "root", "override module root dir") orelse "src";

    const module = b.addModule("zig_http", .{
        .root_source_file = b.path(b.pathJoin(&.{ root, "module.zig" })),
        .target = target,
        .optimize = optimize,
    });
    module.addOptions("options", opts);

    const test_step = b.step("test", "run the module tests");
    for (test_targets) |t| {
        const target_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.pathJoin(&.{ root, "module.zig" })),
                .target = b.resolveTargetQuery(t),
            }),
        });
        const run_tests = b.addRunArtifact(target_tests);
        run_tests.skip_foreign_checks = true;
        test_step.dependOn(&run_tests.step);
    }

    //build settings
    const bin = b.addExecutable(.{
        .name = "zig_http",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.graph.host,
        }),
    });
    bin.root_module.addOptions("options", opts);
    b.installArtifact(bin);

    //for 'zig build run'
    const run_bin = b.addRunArtifact(bin);
    if (b.args) |args| {
        run_bin.addArgs(args);
    }
    const run_step = b.step("run", "run the program");
    run_step.dependOn(&run_bin.step);
}
