const std = @import("std");
const model = @import("model.zig");
const query = @import("query.zig");
const Iter = query.JsonPathIter;
const parser = @import("parser.zig");

pub const TestJson = struct {
    parsed: std.json.Parsed(std.json.Value),

    pub fn init(json_str: []const u8) !TestJson {
        return .{
            .parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_str, .{}),
        };
    }

    pub fn deinit(self: *TestJson, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.parsed.deinit();
    }

    pub fn value(self: *TestJson) *std.json.Value {
        return &self.parsed.value;
    }
};

pub const TestIter = struct {
    cursors: []const query.JsonPointer,

    pub fn eql(self: TestIter, actual: *Iter) bool {
        if (self.cursors.len != actual.cursors.items.len) return false;
        for (self.cursors, actual.cursors.items) |a, b| {
            if (a.json != b.json) return false;
            if (!std.mem.eql(u8, a.path, b.path)) return false;
        }
        return true;
    }

    pub fn print(self: TestIter) void {
        std.debug.print("ExpectedIter({d} cursors):\n", .{self.cursors.len});
        for (self.cursors) |c| {
            std.debug.print("  path: {s}\n  value: {f}\n", .{
                c.path,
                std.json.fmt(c.json.*, .{ .whitespace = .indent_2 }),
            });
        }
    }
    pub fn init(cursors: []const query.JsonPointer) TestIter {
        return .{ .cursors = cursors };
    }

    pub fn shouldEql(expected: *TestIter, actual: *Iter) !void {
        if (!expected.eql(actual)) {
            std.debug.print("=== expected ===\n", .{});
            expected.print();
            std.debug.print("=== actual ===\n", .{});
            actual.print();
            return error.TestExpectedEqual;
        }
    }
};



pub fn ptr(value: *std.json.Value, path: []const u8) query.JsonPointer {
    return .{ .json = value, .path = path };
}



pub fn init_query(query_str: []const u8) !model.JPQuery {
    var p = parser.JPQueryParser.init(query_str, std.testing.allocator);
    return try p.parse();
}

test "parse root only" {
    var tjson = try TestJson.init("{}");
    defer tjson.deinit(std.testing.allocator);


    var js_query = try init_query("$");
    defer js_query.deinit(std.testing.allocator);


    var actual = try js_query.query(Iter.init(tjson.value(), std.testing.allocator));
    defer actual.deinit();

    var expected =  TestIter.init(&.{ptr(tjson.value(), "$")});
    try expected.shouldEql(&actual);

}
