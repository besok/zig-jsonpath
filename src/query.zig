const std = @import("std");
const model = @import("model.zig");
const jsp = @import("parser.zig");

pub const JsQueryResult = struct {
    source: *std.json.Value,
    results: []*std.json.Value,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *JsQueryResult) void {
        self.allocator.free(self.results);
    }
};

pub fn perform_query(
    source: *std.json.Value,
    path: *model.JPQuery,
    allocator: std.mem.Allocator,
) !JsQueryResult {
    _ = path;
    return JsQueryResult{
        .source = source,
        .results = try allocator.alloc(*std.json.Value, 0),
        .allocator = allocator,
    };
}
