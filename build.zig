const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zig_jsonpath", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests for the library itself
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);

    // Compliance runner as an executable
    const compliance_exe = b.addExecutable(.{
        .name = "compliance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("compliance-test-suite/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    compliance_exe.root_module.addImport("jsonpath", mod);

    const run_compliance = b.addRunArtifact(compliance_exe);
    const compliance_step = b.step("compliance", "Run compliance suite");
    compliance_step.dependOn(&run_compliance.step);

    b.installArtifact(compliance_exe);
}
