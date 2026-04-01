const std = @import("std");
const model = @import("model.zig");
pub const jsp = @import("parser.zig");
const query = @import("query.zig");

pub fn text_query(
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
    errdefer json.deinit();
    var parser = jsp.JPQueryParser.init(path, allocator);
    var jp_path = try parser.parse();
    errdefer jp_path.deinit(allocator);
    return try query.perform(json, &jp_path, allocator);
}

test "smoke" {
    const allocator = std.testing.allocator;
    const source = "{\"foo\": [1, 2, 3]}";
    const path = "$.foo[*]";
    const result = try text_query(source, path, allocator);
    try std.testing.expectEqual(0, result.results.len);
}
