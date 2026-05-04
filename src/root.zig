const std = @import("std");
pub const model = @import("model.zig");
pub const parser = @import("parser.zig");
pub const query = @import("query.zig");

pub fn query_str(
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
    var jq_parser = parser.JPQueryParser.init(path, allocator);
    var jp_path = try jq_parser.parse();
    defer jp_path.deinit(allocator);
    return try query.perform(&json, &jp_path, allocator);
}


