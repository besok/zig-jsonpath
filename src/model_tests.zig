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
            if (!jsonEql(a.json.*, b.json.*)) return false;
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
fn jsonEql(a: std.json.Value, b: std.json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |v| v == b.bool,
        .integer => |v| v == b.integer,
        .float => |v| v == b.float,
        .string => |v| std.mem.eql(u8, v, b.string),
        .array => |v| blk: {
            if (v.items.len != b.array.items.len) break :blk false;
            for (v.items, b.array.items) |x, y| {
                if (!jsonEql(x, y)) break :blk false;
            }
            break :blk true;
        },
        .object => |v| blk: {
            if (v.count() != b.object.count()) break :blk false;
            var it = v.iterator();
            while (it.next()) |entry| {
                const bval = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!jsonEql(entry.value_ptr.*, bval)) break :blk false;
            }
            break :blk true;
        },
        .number_string => |v| std.mem.eql(u8, v, b.number_string),
    };
}

pub fn ptr(value: *std.json.Value, path: []const u8) query.JsonPointer {
    return .{ .json = value, .path = path };
}

pub fn init_query(query_str: []const u8) !model.JPQuery {
    var p = parser.JPQueryParser.init(query_str, std.testing.allocator);
    return try p.parse();
}

test "query root only" {
    var tjson = try TestJson.init("{}");
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var expected = TestIter.init(&.{ptr(tjson.value(), "$")});
    try expected.shouldEql(&iter);
}

test "query name" {
    var tjson = try TestJson.init("{\"a\":\"b\"}");
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$.a");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var expected_json = try TestJson.init("\"b\"");
    defer expected_json.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{ptr(expected_json.value(), "$['a']")});
    try expected.shouldEql(&iter);
}
test "query name 2" {
    var tjson = try TestJson.init("{\"a\":{\"b\":\"c\"}}");
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$.a.b");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var expected_json = try TestJson.init("\"c\"");
    defer expected_json.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{ptr(expected_json.value(), "$['a']['b']")});
    try expected.shouldEql(&iter);
}

test "query index" {
    var tjson = try TestJson.init("[\"a\",\"b\",\"c\"]");
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[1]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var expected_json = try TestJson.init("\"b\"");
    defer expected_json.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{ptr(expected_json.value(), "$[1]")});
    try expected.shouldEql(&iter);
}

test "query index negative" {
    var tjson = try TestJson.init("[\"a\",\"b\",\"c\"]");
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[-1]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var expected_json = try TestJson.init("\"c\"");
    defer expected_json.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{ptr(expected_json.value(), "$[-1]")});
    try expected.shouldEql(&iter);
}

test "query name and index" {
    var tjson = try TestJson.init("{\"a\":[\"x\",\"y\",\"z\"]}");
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$.a[2]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var expected_json = try TestJson.init("\"z\"");
    defer expected_json.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{ptr(expected_json.value(), "$['a'][2]")});
    try expected.shouldEql(&iter);
}

test "query wildcard array" {
    var tjson = try TestJson.init("[\"a\",\"b\",\"c\"]");
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[*]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp_a = try TestJson.init("\"a\"");
    defer exp_a.deinit(std.testing.allocator);
    var exp_b = try TestJson.init("\"b\"");
    defer exp_b.deinit(std.testing.allocator);
    var exp_c = try TestJson.init("\"c\"");
    defer exp_c.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{
        ptr(exp_a.value(), "$[0]"),
        ptr(exp_b.value(), "$[1]"),
        ptr(exp_c.value(), "$[2]"),
    });
    try expected.shouldEql(&iter);
}

test "query wildcard object" {
    var tjson = try TestJson.init("{\"a\":1,\"b\":2}");
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[*]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp_a = try TestJson.init("1");
    defer exp_a.deinit(std.testing.allocator);
    var exp_b = try TestJson.init("2");
    defer exp_b.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{
        ptr(exp_a.value(), "$['a']"),
        ptr(exp_b.value(), "$['b']"),
    });
    try expected.shouldEql(&iter);
}

test "query slice normal" {
    var tjson = try TestJson.init("[\"a\",\"b\",\"c\",\"d\",\"e\"]");
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[1:3]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp_b = try TestJson.init("\"b\"");
    defer exp_b.deinit(std.testing.allocator);
    var exp_c = try TestJson.init("\"c\"");
    defer exp_c.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{
        ptr(exp_b.value(), "$[1]"),
        ptr(exp_c.value(), "$[2]"),
    });
    try expected.shouldEql(&iter);
}

test "query slice empty array" {
    var tjson = try TestJson.init("[]");
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[0:1]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var expected = TestIter.init(&.{});
    try expected.shouldEql(&iter);
}

test "query slice not array" {
    var tjson = try TestJson.init("{\"a\":1}");
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[0:1]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var expected = TestIter.init(&.{});
    try expected.shouldEql(&iter);
}

test "query slice normalization" {
    var tjson = try TestJson.init("[\"a\",\"b\",\"c\",\"d\",\"e\"]");
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[0:100]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp_a = try TestJson.init("\"a\"");
    defer exp_a.deinit(std.testing.allocator);
    var exp_b = try TestJson.init("\"b\"");
    defer exp_b.deinit(std.testing.allocator);
    var exp_c = try TestJson.init("\"c\"");
    defer exp_c.deinit(std.testing.allocator);
    var exp_d = try TestJson.init("\"d\"");
    defer exp_d.deinit(std.testing.allocator);
    var exp_e = try TestJson.init("\"e\"");
    defer exp_e.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{
        ptr(exp_a.value(), "$[0]"),
        ptr(exp_b.value(), "$[1]"),
        ptr(exp_c.value(), "$[2]"),
        ptr(exp_d.value(), "$[3]"),
        ptr(exp_e.value(), "$[4]"),
    });
    try expected.shouldEql(&iter);
}

test "query slice negative" {
    var tjson = try TestJson.init("[\"a\",\"b\",\"c\",\"d\",\"e\"]");
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[-2:]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp_d = try TestJson.init("\"d\"");
    defer exp_d.deinit(std.testing.allocator);
    var exp_e = try TestJson.init("\"e\"");
    defer exp_e.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{
        ptr(exp_d.value(), "$[3]"),
        ptr(exp_e.value(), "$[4]"),
    });
    try expected.shouldEql(&iter);
}

test "query descendant one level" {
    var tjson = try TestJson.init("{\"a\":1,\"b\":2}");
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$..a");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp = try TestJson.init("1");
    defer exp.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{
        ptr(exp.value(), "$['a']"),
    });
    try expected.shouldEql(&iter);
}

test "query descendant several levels" {
    var tjson = try TestJson.init("{\"a\":{\"b\":{\"a\":42}}}");
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$..a");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp_outer = try TestJson.init("{\"b\":{\"a\":42}}");
    defer exp_outer.deinit(std.testing.allocator);
    var exp_inner = try TestJson.init("42");
    defer exp_inner.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{
        ptr(exp_outer.value(), "$['a']"),
        ptr(exp_inner.value(), "$['a']['b']['a']"),
    });
    try expected.shouldEql(&iter);
}

test "query descendant chained" {
    var tjson = try TestJson.init(
        \\{"a":{"b":1},"c":{"a":{"b":2}}}
    );
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$..a..b");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp1 = try TestJson.init("1");
    defer exp1.deinit(std.testing.allocator);
    var exp2 = try TestJson.init("2");
    defer exp2.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{
        ptr(exp1.value(), "$['a']['b']"),
        ptr(exp2.value(), "$['c']['a']['b']"),
    });
    try expected.shouldEql(&iter);
}

test "query descendant wildcard" {
    var tjson = try TestJson.init("{\"a\":[1,2],\"b\":[3,4]}");
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$..*");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp_a = try TestJson.init("[1,2]");
    defer exp_a.deinit(std.testing.allocator);
    var exp_b = try TestJson.init("[3,4]");
    defer exp_b.deinit(std.testing.allocator);
    var exp_1 = try TestJson.init("1");
    defer exp_1.deinit(std.testing.allocator);
    var exp_2 = try TestJson.init("2");
    defer exp_2.deinit(std.testing.allocator);
    var exp_3 = try TestJson.init("3");
    defer exp_3.deinit(std.testing.allocator);
    var exp_4 = try TestJson.init("4");
    defer exp_4.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{
        ptr(exp_a.value(), "$['a']"),
        ptr(exp_b.value(), "$['b']"),
        ptr(exp_1.value(), "$['a'][0]"),
        ptr(exp_2.value(), "$['a'][1]"),
        ptr(exp_3.value(), "$['b'][0]"),
        ptr(exp_4.value(), "$['b'][1]"),
    });
    try expected.shouldEql(&iter);
}

test "query descendant x then descendant y" {
    var tjson = try TestJson.init(
        \\{"a":{"b":{"a":{"b":99}}}}
    );
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$..a..b");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp1 = try TestJson.init("{\"a\":{\"b\":99}}");
    defer exp1.deinit(std.testing.allocator);
    var exp2 = try TestJson.init("99");
    defer exp2.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{
        ptr(exp1.value(), "$['a']['b']"),
        ptr(exp2.value(), "$['a']['b']['a']['b']"),
    });
    try expected.shouldEql(&iter);
}