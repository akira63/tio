// tio - a serial device I/O tool (Zig rewrite)
// Build file for Zig 0.13.0+
// No Lua dependency - scripting support removed.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "tio",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link the C standard library (needed for termios, ioctl, poll, etc.)
    exe.linkLibC();

    // Platform-specific compile flags
    if (target.result.os.tag == .linux) {
        exe.defineCMacro("__linux__", null);
    } else if (target.result.os.tag == .macos) {
        exe.defineCMacro("__APPLE__", null);
    }

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run tio");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.linkLibC();

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
