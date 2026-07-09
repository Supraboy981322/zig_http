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

    try examples(b, opts, target, optimize, module);
    try tests(b, opts, optimize, root);
    try cli(b, opts, target, optimize, module);
}

pub fn examples(
    b:*std.Build,
    opts:*std.Build.Step.Options,
    target:std.Build.ResolvedTarget,
    optimize:?std.builtin.OptimizeMode,
    mod:*std.Build.Module,
) !void {
    //build settings
    const bin = b.addExecutable(.{
        .name = "zig_http-examples",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bin.root_module.addOptions("options", opts);
    bin.root_module.addImport("zig_http", mod);
    b.installArtifact(bin);

    //for 'zig build run'
    const run_bin = b.addRunArtifact(bin);
    if (b.args) |args| {
        run_bin.addArgs(args);
    }
    const run_step = b.step("examples", "run the examples");
    run_step.dependOn(&run_bin.step);
}

pub fn tests(
    b:*std.Build,
    opts:*std.Build.Step.Options,
    optimize:?std.builtin.OptimizeMode,
    root:[]const u8,
) !void {
    const test_step = b.step("test", "run the module tests");
    for (test_targets) |t| {
        const target_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.pathJoin(&.{ root, "module.zig" })),
                .target = b.resolveTargetQuery(t),
                .optimize = optimize,
            }),
        });
        target_tests.root_module.addOptions("options", opts);
        const run_tests = b.addRunArtifact(target_tests);
        run_tests.skip_foreign_checks = true;
        test_step.dependOn(&run_tests.step);
    }
}

pub fn cli(
    b:*std.Build,
    opts:*std.Build.Step.Options,
    target:std.Build.ResolvedTarget,
    optimize:?std.builtin.OptimizeMode,
    mod:*std.Build.Module,
) !void {
    //build settings
    const bin = b.addExecutable(.{
        .name = "zig_http",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cli/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bin.root_module.addOptions("options", opts);
    bin.root_module.addImport("zig_http", mod);
    b.installArtifact(bin);

    //for 'zig build run'
    const run_bin = b.addRunArtifact(bin);
    if (b.args) |args| {
        run_bin.addArgs(args);
    }
    const run_step = b.step("run", "run the program");
    run_step.dependOn(&run_bin.step);
}
