const std = @import("std");
const model = @import("model.zig");
const jsp = @import("parser.zig");

pub const JsonPathResult = struct {
    parsed_json: std.json.Parsed(std.json.Value),
    results: []*std.json.Value,
    allocator: std.mem.Allocator,
    path: *model.JPQuery,

    pub fn deinit(self: JsonPathResult) void {
        self.parsed_json.deinit();
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
        .parsed_json = parsed_json,
        .results = try allocator.alloc(*std.json.Value, 0),
        .path = path,
        .allocator = allocator,
    };
}
