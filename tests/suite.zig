const std = @import("std");

const CaseFilter = struct {
    name: []const u8,
    reason: []const u8,
    issue: usize,
    expected_to_fix: bool,
};

const Case = struct {
    name: []const u8,
    selector: []const u8,
    invalid_selector: bool = false,
    document: ?std.json.Value = null,
    result: ?std.json.Value = null,
    result_paths: ?[][]const u8 = null,
    results: ?std.json.Value = null,
    results_paths: ?[][][]const u8 = null,
};

const Suite = struct { tests: []Case };

const case_filters = @embedFile("config/filtered_cases.json");
const cases = @embedFile("jsonpath-compliance-test-suite/cts.json");

fn getCaseFilters(allocator: std.mem.Allocator) !std.json.Parsed([]CaseFilter) {
    return try std.json.parseFromSlice([]CaseFilter, allocator, case_filters, .{});
}
fn getCases(allocator: std.mem.Allocator) !std.json.Parsed(Suite) {
    return try std.json.parseFromSlice(Suite, allocator, cases, .{
        .ignore_unknown_fields = true,
    });
}

test "simple read of filtered cases" {
    const filters = try getCaseFilters(std.testing.allocator);
    defer filters.deinit();

    std.debug.print("{f}\n", .{std.json.fmt(filters.value, .{ .whitespace = .indent_2 })});
}

test "simple read of all cases" {
    const all_cases = try getCases(std.testing.allocator);
    defer all_cases.deinit();

    std.debug.print("{f}\n", .{std.json.fmt(all_cases.value, .{ .whitespace = .indent_2 })});
}
