const std = @import("std");

pub fn build(b: *std.Build) void {
    const mod = b.addModule("ztype", .{ .root_source_file = b.path("src/root.zig") });

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // const exe = b.addExecutable(.{
    //     .name = "binary-encoding-decoding",
    //     .root_source_file = b.path("src/main.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // b.installArtifact(exe);
    // const run_cmd = b.addRunArtifact(exe);
    // run_cmd.step.dependOn(b.getInstallStep());
    // if (b.args) |args| {
    //     run_cmd.addArgs(args);
    // }
    // const run_step = b.step("run", "Run the app");
    // run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("ztype", mod);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
