const std = @import("std");
const model = @import("model.zig");
const jsp = @import("parser.zig");

pub const JsonPathResult = struct {
    json: std.json.Parsed(std.json.Value),
    path: *model.JPQuery,
    results: []*std.json.Value,
    allocator: std.mem.Allocator,

    pub fn deinit(self: JsonPathResult) void {
        self.json.deinit();
        self.allocator.free(self.results);
        self.path.deinit(self.allocator);
    }
};

pub fn perform_query(
    parsed_json: std.json.Parsed(std.json.Value),
    path: *model.JPQuery,
    allocator: std.mem.Allocator,
) !JsonPathResult {

    return JsonPathResult{
        .json = parsed_json,
        .path = path,
        .results = try allocator.alloc(*std.json.Value, 0),
        .allocator = allocator,
    };
}
