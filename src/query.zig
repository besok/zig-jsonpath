const std = @import("std");
const model = @import("model.zig");
const jsp = @import("parser.zig");

pub const JsonPointer = struct {
    json: *std.json.Value,
    path: []const u8,

    pub fn deinit(self: *JsonPointer, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

pub const JsonPathResult = struct {
    json: std.json.Parsed(std.json.Value), // owns the JSON document
    results: []JsonPointer, // owns the result nodes and their paths
    allocator: std.mem.Allocator,

    pub fn deinit(self: *JsonPathResult) void {
        for (self.results) |*r| r.deinit(self.allocator);
        self.allocator.free(self.results);
        self.json.deinit();
    }
};

pub fn perform(
    parsed_json: std.json.Parsed(std.json.Value),
    path: *const model.JPQuery,
    allocator: std.mem.Allocator,
) !JsonPathResult {
    var iter = try query(path, JsonPathIter.init(&parsed_json.value, allocator));
    errdefer iter.deinit();
    return iter.toResult(parsed_json);
}

pub const JsonPathIter = struct {
    root: *std.json.Value,
    cursors: std.ArrayListUnmanaged(JsonPointer),
    allocator: std.mem.Allocator,

    pub fn init(root: *std.json.Value, allocator: std.mem.Allocator) JsonPathIter {
        return .{
            .root = root,
            .cursors = .{},
            .allocator = allocator,
        };
    }

    pub fn append(self: *JsonPathIter, value: *std.json.Value, path: []const u8) !void {
        try self.cursors.append(self.allocator, .{ .value = value, .path = path });
    }

    pub fn deinit(self: *JsonPathIter) void {
        for (self.cursors.items) |*r| r.deinit(self.allocator);
        self.cursors.deinit(self.allocator);
    }

    pub fn toResult(self: *JsonPathIter, original_json: std.json.Parsed(std.json.Value)) !JsonPathResult {
        const results = try self.cursors.toOwnedSlice(self.allocator);
        self.cursors = .{};
        return .{
            .json = original_json,
            .results = results,
            .allocator = self.allocator,
        };
    }
};

pub fn query(node: anytype, iteration: JsonPathIter) !JsonPathIter {
    const T = @TypeOf(node);
    if (!@hasDecl(T, "query")) {
        @compileError(@typeName(T) ++ " does not implement query");
    }
    return node.query(iteration);
}
