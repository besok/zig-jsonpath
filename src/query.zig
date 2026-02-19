const std = @import("std");
const model = @import("model.zig");
const jsp = @import("parser.zig");

pub const JsonPathResult = struct {
    _parsed_json: std.json.Parsed(std.json.Value),
    results: []*std.json.Value,
    allocator: std.mem.Allocator,

    pub fn deinit(self: JsonPathResult) void {
        self._parsed_json.deinit();
        self.allocator.free(self.results);
    }
};

pub fn perform_query(
    parsed_json: std.json.Parsed(std.json.Value),
    path: *model.JPQuery,
    allocator: std.mem.Allocator,
) !JsonPathResult {
    _ = path;

    return JsonPathResult{
        ._parsed_json = parsed_json,
        .results = try allocator.alloc(*std.json.Value, 0),
        .allocator = allocator,
    };
}
