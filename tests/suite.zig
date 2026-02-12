const std = @import("std");

const FilteredCase = struct {
    name: []const u8,
    reason: []const u8,
    issue: usize,
    expected_to_fix: bool,
};

const filtered_cases = @embedFile("config/filtered_cases.json");

fn getFilteredCases(allocator: std.mem.Allocator) !std.json.Parsed([]FilteredCase) {
    return try std.json.parseFromSlice([]FilteredCase, allocator, filtered_cases, .{});
}

test "simple read of filtered cases" {
    const cases = try getFilteredCases(std.testing.allocator);
    defer cases.deinit();

    std.debug.print("{f}\n", .{std.json.fmt(cases.value, .{ .whitespace = .indent_2 })});
}
