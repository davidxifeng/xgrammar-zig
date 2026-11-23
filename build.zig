const std = @import("std");

/// Pure-Zig port of xgrammar-rs 0.2.8 (see docs/PORTING.md).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("xgrammar", .{
        .root_source_file = b.path("src/xgrammar.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit + parity tests");
    test_step.dependOn(&run_tests.step);
}
