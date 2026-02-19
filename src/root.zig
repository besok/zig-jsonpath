const std = @import("std");
const model = @import("model.zig");
pub const jsp = @import("parser.zig");
const query = @import("query.zig");

pub fn jsonpath_from_string(
    source: []const u8,
    path: []const u8,
    allocator: std.mem.Allocator,
) !query.JsonPathResult {
    var json = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        source,
        .{},
    );
    defer json.deinit();
    var parser = jsp.JPQueryParser.init(path);
    var jp_path = try parser.parse();
    return try query.perform_query(json, &jp_path, allocator);
}

test "smoke" {
    const allocator = std.testing.allocator;
    const source = "{\"foo\": [1, 2, 3]}";
    const path = "$.foo[*]";
    var result = try jsonpath_from_string(source, path, allocator);
    defer result.deinit();
    try std.testing.expectEqual(3, result.results.len);
}
