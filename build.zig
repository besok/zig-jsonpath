const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zig_jsonpath", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests
    const unit_tests_mod = b.createModule(.{
        .root_source_file = b.path("test/unit.zig"),
        .target = target,
        .optimize = optimize,
    });

    unit_tests_mod.addImport("zig_jsonpath", mod);

    const unit_tests = b.addTest(.{
        .root_module = unit_tests_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Compliance runner as an executable
    const compliance_mod = b.createModule(.{
        .root_source_file = b.path("compliance-test-suite/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    compliance_mod.addImport("jsonpath", mod);

    const compliance_exe = b.addExecutable(.{
        .name = "compliance",
        .root_module = compliance_mod,
    });

    const run_compliance = b.addRunArtifact(compliance_exe);

    const compliance_step = b.step("compliance", "Run compliance suite");
    compliance_step.dependOn(&run_compliance.step);

    // Optional: run both unit tests and compliance
    const check_step = b.step("check", "Run unit tests and compliance suite");
    check_step.dependOn(&run_unit_tests.step);
    check_step.dependOn(&run_compliance.step);

    b.installArtifact(compliance_exe);
}