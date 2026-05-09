const std = @import("std");
const model = @import("model.zig");
const jsp = @import("parser.zig");

/// Represents a single matched node resulting from a JSONPath query.
pub const JsonPointer = struct {
    json: *std.json.Value,
    /// The string representation of the specific path leading to this node (e.g., `$.store.book[0]`).
    path: []const u8,

    pub fn deinit(self: *JsonPointer, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

/// The complete result set of a JSONPath query execution.
///
/// This struct safely bundles the matched results alongside the underlying
/// JSON document's memory arena. By taking ownership of the `std.json.Parsed`
/// object, it guarantees that all `*std.json.Value` pointers within the `results`
/// array remain safely alive and valid for the lifetime of this struct.
pub const JsonPathResult = struct {
    json: std.json.Parsed(std.json.Value),
    results: []JsonPointer,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *JsonPathResult) void {
        for (self.results) |*r| r.deinit(self.allocator);
        self.allocator.free(self.results);
        self.json.deinit();
    }
};


/// Executes a compiled JSONPath query against a pre-parsed JSON document.
///
/// **Parameters:**
/// - `parsed_json`: A pointer to the parsed JSON document. The returned result will
///   contain references to the values within this document, so the underlying JSON
///   arena must remain alive for the lifetime of the result.
/// - `path`: A pointer to the compiled JSONPath query (`model.JPQuery`) to execute.
/// - `allocator`: The memory allocator used for tracking temporary iteration state
///   (like active cursors) and allocating the final array of matched results.
///
/// **Returns:**
/// A `JsonPathResult` containing an array of pointers/values matching the query.
///
/// **Memory Management & Caller Responsibility:**
/// The caller takes ownership of the returned `JsonPathResult` and is responsible
/// for deinitializing it (e.g., `result.deinit()`) to free the array of matches.
/// If an error occurs during execution, all temporary allocations made by the
/// internal iterator are safely cleaned up automatically.
pub fn perform(
    parsed_json: *std.json.Parsed(std.json.Value),
    path: *const model.JPQuery,
    allocator: std.mem.Allocator,
) !JsonPathResult {
    var init_query = JsonPathIter.init(&parsed_json.value, allocator);
    errdefer init_query.deinit();

    try query(path, &init_query);
    return init_query.toResult(parsed_json.*);
}
/// Manages the execution state of a JSONPath query as it traverses a JSON document.
///
/// Because JSONPath queries can branch (e.g., `$.store.*` or filters), a single query
/// can actively evaluate multiple nodes at once. This struct acts as a cursor manager,
/// tracking all currently active nodes (`cursors`), remembering the string path taken
/// to reach each one, and managing the dynamic memory for those paths.
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

    pub fn getRoot(self: *JsonPathIter) *std.json.Value {
        return self.root;
    }

    pub fn append(self: *JsonPathIter, value: *std.json.Value, path: []const u8) !void {
        const duped = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(duped);
        try self.cursors.append(self.allocator, .{ .json = value, .path = duped });
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
    pub fn eql(self: JsonPathIter, other: JsonPathIter) bool {
        if (self.cursors.items.len != other.cursors.items.len) return false;
        for (self.cursors.items, other.cursors.items) |a, b| {
            if (a.json != b.json) return false;
            if (!std.mem.eql(u8, a.path, b.path)) return false;
        }
        return true;
    }
    pub fn print(self: *JsonPathIter) void {
        std.debug.print("JsonPathIter({d} cursors):\n", .{self.cursors.items.len});
        for (self.cursors.items) |c| {
            std.debug.print("  path: {s}\n  value: {f}\n", .{
                c.path,
                std.json.fmt(c.json.*, .{ .whitespace = .indent_2 }),
            });
        }
    }
    pub fn remove(self: *JsonPathIter, i: usize) void {
        var r = self.cursors.orderedRemove(i);
        r.deinit(self.allocator);
    }
    pub fn fork(self: *JsonPathIter) !JsonPathIter {
        var branch = JsonPathIter.init(self.root, self.allocator);
        errdefer branch.deinit();
        for (self.cursors.items) |p| {
            const duped = try self.allocator.dupe(u8, p.path);
            errdefer self.allocator.free(duped);
            try branch.cursors.append(self.allocator, .{ .json = p.json, .path = duped });
        }
        return branch;
    }
    pub fn forkSingle(self: *JsonPathIter, cursor: JsonPointer) !JsonPathIter {
        var branch = JsonPathIter.init(self.root, self.allocator);
        errdefer branch.deinit();
        const duped = try self.allocator.dupe(u8, cursor.path);
        errdefer self.allocator.free(duped);
        try branch.cursors.append(self.allocator, .{ .json = cursor.json, .path = duped });
        return branch;
    }
};

pub fn query(node: anytype, iteration: *JsonPathIter) !void {
    const T = switch (@typeInfo(@TypeOf(node))) {
        .pointer => |p| p.child,
        else => @TypeOf(node),
    };
    if (!@hasDecl(T, "query")) {
        // @compileError(@typeName(T) ++ " does not implement query");
        return;
    }
    try node.query(iteration);
}
