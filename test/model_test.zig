const std = @import("std");
const jsonpath = @import("zig_jsonpath");

const parser = jsonpath.parser;
const model = jsonpath.model;
const query = jsonpath.query;
const Iter = query.JsonPathIter;


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

test "query selectors multiple" {
    var tjson = try TestJson.init("{\"a\":1,\"b\":2,\"c\":3}");
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$['a','b']");
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

test "query selectors mixed name and index" {
    var tjson = try TestJson.init("[\"a\",\"b\",\"c\"]");
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[0,2]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp_a = try TestJson.init("\"a\"");
    defer exp_a.deinit(std.testing.allocator);
    var exp_c = try TestJson.init("\"c\"");
    defer exp_c.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{
        ptr(exp_a.value(), "$[0]"),
        ptr(exp_c.value(), "$[2]"),
    });
    try expected.shouldEql(&iter);
}

test "query selectors no match" {
    var tjson = try TestJson.init("{\"a\":1}");
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$['b','c']");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var expected = TestIter.init(&.{});
    try expected.shouldEql(&iter);
}

test "jsquery singular-like name selection keeps matched key" {
    var tjson = try TestJson.init("{\"a\":1,\"b\":2}");
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$.a");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp_a = try TestJson.init("1");
    defer exp_a.deinit(std.testing.allocator);
    var expected = TestIter.init(&.{ptr(exp_a.value(), "$['a']")});
    try expected.shouldEql(&iter);
}

test "jsquery singular-like name selection removes non-matching key" {
    var tjson = try TestJson.init("{\"a\":1}");
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$.missing");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var expected = TestIter.init(&.{});
    try expected.shouldEql(&iter);
}

test "jsquery singular-like index supports positive and negative indexes" {
    var tjson = try TestJson.init("[10,20,30]");
    defer tjson.deinit(std.testing.allocator);

    var js_query_pos = try init_query("$[1]");
    defer js_query_pos.deinit(std.testing.allocator);

    var iter_pos = Iter.init(tjson.value(), std.testing.allocator);
    try js_query_pos.query(&iter_pos);
    defer iter_pos.deinit();

    var exp_pos = try TestJson.init("20");
    defer exp_pos.deinit(std.testing.allocator);
    var expected_pos = TestIter.init(&.{ptr(exp_pos.value(), "$[1]")});
    try expected_pos.shouldEql(&iter_pos);

    var js_query_neg = try init_query("$[-1]");
    defer js_query_neg.deinit(std.testing.allocator);

    var iter_neg = Iter.init(tjson.value(), std.testing.allocator);
    try js_query_neg.query(&iter_neg);
    defer iter_neg.deinit();

    var exp_neg = try TestJson.init("30");
    defer exp_neg.deinit(std.testing.allocator);
    var expected_neg = TestIter.init(&.{ptr(exp_neg.value(), "$[-1]")});
    try expected_neg.shouldEql(&iter_neg);
}

test "jsquery singular-like index removes out of bounds and non-arrays" {
    var tjson_arr = try TestJson.init("[10,20]");
    defer tjson_arr.deinit(std.testing.allocator);

    var js_query_oob = try init_query("$[99]");
    defer js_query_oob.deinit(std.testing.allocator);

    var iter_oob = Iter.init(tjson_arr.value(), std.testing.allocator);
    try js_query_oob.query(&iter_oob);
    defer iter_oob.deinit();

    var expected_empty = TestIter.init(&.{});
    try expected_empty.shouldEql(&iter_oob);

    var tjson_obj = try TestJson.init("{\"a\":1}");
    defer tjson_obj.deinit(std.testing.allocator);

    var js_query_non_array = try init_query("$.a[0]");
    defer js_query_non_array.deinit(std.testing.allocator);

    var iter_non_array = Iter.init(tjson_obj.value(), std.testing.allocator);
    try js_query_non_array.query(&iter_non_array);
    defer iter_non_array.deinit();

    try expected_empty.shouldEql(&iter_non_array);
}

test "filter eq string" {
    var tjson = try TestJson.init(
        \\[{"name":"a","val":1},{"name":"b","val":2}]
    );
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[?@.name == 'a']");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp = try TestJson.init("{\"name\":\"a\",\"val\":1}");
    defer exp.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{ptr(exp.value(), "$[0]")});
    try expected.shouldEql(&iter);
}

test "filter eq integer" {
    var tjson = try TestJson.init(
        \\[{"val":1},{"val":2},{"val":3}]
    );
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[?@.val == 2]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp = try TestJson.init("{\"val\":2}");
    defer exp.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{ptr(exp.value(), "$[1]")});
    try expected.shouldEql(&iter);
}

test "filter gt" {
    var tjson = try TestJson.init(
        \\[{"val":1},{"val":2},{"val":3}]
    );
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[?@.val > 1]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp1 = try TestJson.init("{\"val\":2}");
    defer exp1.deinit(std.testing.allocator);
    var exp2 = try TestJson.init("{\"val\":3}");
    defer exp2.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{
        ptr(exp1.value(), "$[1]"),
        ptr(exp2.value(), "$[2]"),
    });
    try expected.shouldEql(&iter);
}

test "filter lte" {
    var tjson = try TestJson.init(
        \\[{"val":1},{"val":2},{"val":3}]
    );
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[?@.val <= 2]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp1 = try TestJson.init("{\"val\":1}");
    defer exp1.deinit(std.testing.allocator);
    var exp2 = try TestJson.init("{\"val\":2}");
    defer exp2.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{
        ptr(exp1.value(), "$[0]"),
        ptr(exp2.value(), "$[1]"),
    });
    try expected.shouldEql(&iter);
}

test "filter ne" {
    var tjson = try TestJson.init(
        \\[{"val":1},{"val":2},{"val":3}]
    );
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[?@.val != 2]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp1 = try TestJson.init("{\"val\":1}");
    defer exp1.deinit(std.testing.allocator);
    var exp2 = try TestJson.init("{\"val\":3}");
    defer exp2.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{
        ptr(exp1.value(), "$[0]"),
        ptr(exp2.value(), "$[2]"),
    });
    try expected.shouldEql(&iter);
}

test "filter existence test" {
    var tjson = try TestJson.init(
        \\[{"a":1},{"b":2},{"a":3}]
    );
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[?@.a]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp1 = try TestJson.init("{\"a\":1}");
    defer exp1.deinit(std.testing.allocator);
    var exp2 = try TestJson.init("{\"a\":3}");
    defer exp2.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{
        ptr(exp1.value(), "$[0]"),
        ptr(exp2.value(), "$[2]"),
    });
    try expected.shouldEql(&iter);
}

test "filter not existence test" {
    var tjson = try TestJson.init(
        \\[{"a":1},{"b":2},{"a":3}]
    );
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[?!@.a]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp = try TestJson.init("{\"b\":2}");
    defer exp.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{ptr(exp.value(), "$[1]")});
    try expected.shouldEql(&iter);
}

test "filter and" {
    var tjson = try TestJson.init(
        \\[{"val":1,"ok":true},{"val":2,"ok":true},{"val":3,"ok":false}]
    );
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[?@.val > 1 && @.ok == true]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp = try TestJson.init("{\"val\":2,\"ok\":true}");
    defer exp.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{ptr(exp.value(), "$[1]")});
    try expected.shouldEql(&iter);
}

test "filter or" {
    var tjson = try TestJson.init(
        \\[{"val":1},{"val":2},{"val":3}]
    );
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[?@.val == 1 || @.val == 3]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp1 = try TestJson.init("{\"val\":1}");
    defer exp1.deinit(std.testing.allocator);
    var exp2 = try TestJson.init("{\"val\":3}");
    defer exp2.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{
        ptr(exp1.value(), "$[0]"),
        ptr(exp2.value(), "$[2]"),
    });
    try expected.shouldEql(&iter);
}

test "filter null comparison" {
    var tjson = try TestJson.init(
        \\[{"val":null},{"val":1}]
    );
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[?@.val == null]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp = try TestJson.init("{\"val\":null}");
    defer exp.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{ptr(exp.value(), "$[0]")});
    try expected.shouldEql(&iter);
}

test "filter absolute query" {
    var tjson = try TestJson.init(
        \\{"items":[1,2,3],"threshold":2}
    );
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$.items[?@ > $.threshold]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp = try TestJson.init("3");
    defer exp.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{ptr(exp.value(), "$['items'][2]")});
    try expected.shouldEql(&iter);
}

test "filter length function" {
    var tjson = try TestJson.init(
        \\[{"name":"ab"},{"name":"abcd"},{"name":"a"}]
    );
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[?length(@.name) > 2]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp = try TestJson.init("{\"name\":\"abcd\"}");
    defer exp.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{ptr(exp.value(), "$[1]")});
    try expected.shouldEql(&iter);
}

test "filter count function" {
    var tjson = try TestJson.init(
        \\[{"tags":["a","b","c"]},{"tags":["x"]}]
    );
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[?count(@.tags.*) > 1]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp = try TestJson.init("{\"tags\":[\"a\",\"b\",\"c\"]}");
    defer exp.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{ptr(exp.value(), "$[0]")});
    try expected.shouldEql(&iter);
}

test "compliance basic root" {
    var tjson = try TestJson.init(
        \\["first","second"]
    );
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var expected = TestIter.init(&.{
        ptr(tjson.value(), "$"),
    });

    try expected.shouldEql(&iter);
}

test "compliance filter absolute equals self" {
    var tjson = try TestJson.init(
        \\[1,null,true,{"a":"b"},[false]]
    );
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[?$==$]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp_1 = try TestJson.init("1");
    defer exp_1.deinit(std.testing.allocator);

    var exp_null = try TestJson.init("null");
    defer exp_null.deinit(std.testing.allocator);

    var exp_true = try TestJson.init("true");
    defer exp_true.deinit(std.testing.allocator);

    var exp_obj = try TestJson.init(
        \\{"a":"b"}
    );
    defer exp_obj.deinit(std.testing.allocator);

    var exp_arr = try TestJson.init(
        \\[false]
    );
    defer exp_arr.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{
        ptr(exp_1.value(), "$[0]"),
        ptr(exp_null.value(), "$[1]"),
        ptr(exp_true.value(), "$[2]"),
        ptr(exp_obj.value(), "$[3]"),
        ptr(exp_arr.value(), "$[4]"),
    });

    try expected.shouldEql(&iter);
}

test "filter match function basic" {
    var tjson = try TestJson.init(
        \\[{"name":"foobar"},{"name":"foo"},{"name":"bar"}]
    );
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[?match(@.name, 'foo.*')]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp1 = try TestJson.init("{\"name\":\"foobar\"}");
    defer exp1.deinit(std.testing.allocator);
    var exp2 = try TestJson.init("{\"name\":\"foo\"}");
    defer exp2.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{
        ptr(exp1.value(), "$[0]"),
        ptr(exp2.value(), "$[1]"),
    });
    try expected.shouldEql(&iter);
}

test "filter match function full string only" {
    // match() anchors the whole string — 'foo' should NOT match 'foobar'
    var tjson = try TestJson.init(
        \\[{"name":"foobar"},{"name":"foo"},{"name":"bar"}]
    );
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[?match(@.name, 'foo')]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp = try TestJson.init("{\"name\":\"foo\"}");
    defer exp.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{ptr(exp.value(), "$[1]")});
    try expected.shouldEql(&iter);
}

test "filter search function substring" {
    // search() matches anywhere in the string
    var tjson = try TestJson.init(
        \\[{"name":"foobar"},{"name":"foo"},{"name":"bar"},{"name":"baz"}]
    );
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[?search(@.name, 'foo')]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp1 = try TestJson.init("{\"name\":\"foobar\"}");
    defer exp1.deinit(std.testing.allocator);
    var exp2 = try TestJson.init("{\"name\":\"foo\"}");
    defer exp2.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{
        ptr(exp1.value(), "$[0]"),
        ptr(exp2.value(), "$[1]"),
    });
    try expected.shouldEql(&iter);
}

test "filter search function no match" {
    var tjson = try TestJson.init(
        \\[{"name":"bar"},{"name":"baz"}]
    );
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[?search(@.name, 'foo')]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var expected = TestIter.init(&.{});
    try expected.shouldEql(&iter);
}

test "filter match non-string returns nothing" {
    var tjson = try TestJson.init(
        \\[{"name":1},{"name":"foo"}]
    );
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[?match(@.name, 'foo')]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp = try TestJson.init("{\"name\":\"foo\"}");
    defer exp.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{ptr(exp.value(), "$[1]")});
    try expected.shouldEql(&iter);
}

test "filter search with pattern mid string" {
    var tjson = try TestJson.init(
        \\[{"val":"abcdef"},{"val":"xyzabc"},{"val":"xyz"}]
    );
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[?search(@.val, 'abc')]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp1 = try TestJson.init("{\"val\":\"abcdef\"}");
    defer exp1.deinit(std.testing.allocator);
    var exp2 = try TestJson.init("{\"val\":\"xyzabc\"}");
    defer exp2.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{
        ptr(exp1.value(), "$[0]"),
        ptr(exp2.value(), "$[1]"),
    });
    try expected.shouldEql(&iter);
}

test "filter match with digit pattern" {
    var tjson = try TestJson.init(
        \\[{"code":"abc123"},{"code":"123"},{"code":"abc"}]
    );
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[?match(@.code, '[0-9]+')]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp = try TestJson.init("{\"code\":\"123\"}");
    defer exp.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{ptr(exp.value(), "$[1]")});
    try expected.shouldEql(&iter);
}

test "functions match explicit caret" {
    var tjson = try TestJson.init(
        \\["abc","axc","ab","xab"]
    );
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[?match(@, '^ab.*')]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp1 = try TestJson.init("\"abc\"");
    defer exp1.deinit(std.testing.allocator);
    var exp2 = try TestJson.init("\"ab\"");
    defer exp2.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{
        ptr(exp1.value(), "$[0]"),
        ptr(exp2.value(), "$[2]"),
    });
    try expected.shouldEql(&iter);
}

test "functions length non-singular query arg" {
    return error.SkipZigTest;
    // var tjson = try TestJson.init(
    //     \\[{"a":"ab","b":"cd"},{"a":"abc","b":"ef"}]
    // );
    // defer tjson.deinit(std.testing.allocator);
    //
    // var js_query = try init_query("$[?length(@.*)<3]");
    // defer js_query.deinit(std.testing.allocator);
    //
    // var iter = Iter.init(tjson.value(), std.testing.allocator);
    // const result = js_query.query(&iter);
    // defer iter.deinit();
    //
    // try std.testing.expectError(error.InvalidArgument, result);
}

test "functions search escaped backslash before dot" {
    var tjson = try TestJson.init(
        \\["x abc y","x a.c y","x axc y","x a\\ c y"]
    );
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[?search(@, 'a\\\\\\\\.c')]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp = try TestJson.init("\"x a\\\\ c y\"");
    defer exp.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{
        ptr(exp.value(), "$[3]"),
    });
    try expected.shouldEql(&iter);
}

test "basic descendant segment multiple selectors" {
    var tjson = try TestJson.init(
        \\[{"a":"b","d":"e"},{"a":"c","d":"f"}]
    );
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$..['a','d']");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp1 = try TestJson.init("\"b\"");
    defer exp1.deinit(std.testing.allocator);
    var exp2 = try TestJson.init("\"e\"");
    defer exp2.deinit(std.testing.allocator);
    var exp3 = try TestJson.init("\"c\"");
    defer exp3.deinit(std.testing.allocator);
    var exp4 = try TestJson.init("\"f\"");
    defer exp4.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{
        ptr(exp1.value(), "$[0]['a']"),
        ptr(exp2.value(), "$[0]['d']"),
        ptr(exp3.value(), "$[1]['a']"),
        ptr(exp4.value(), "$[1]['d']"),
    });
    try expected.shouldEql(&iter);
}

test "filter equals absent from index selector equals absent from name selector" {
    var tjson = try TestJson.init(
        \\[{"list":[1]}]
    );
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[?@.absent==@.list[9]]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp = try TestJson.init("{\"list\":[1]}");
    defer exp.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{ptr(exp.value(), "$[0]")});
    try expected.shouldEql(&iter);
}

test "filter less than or equal to null" {
    var tjson = try TestJson.init(
        \\[{"a":null,"d":"e"},{"a":"c","d":"f"}]
    );
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[?@.a<=null]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var exp = try TestJson.init("{\"a\":null,\"d\":\"e\"}");
    defer exp.deinit(std.testing.allocator);

    var expected = TestIter.init(&.{ptr(exp.value(), "$[0]")});
    try expected.shouldEql(&iter);
}

test "filter equals null absent from data" {
    var tjson = try TestJson.init(
        \\[{"d":"e"},{"a":"c","d":"f"}]
    );
    defer tjson.deinit(std.testing.allocator);

    var js_query = try init_query("$[?@.a==null]");
    defer js_query.deinit(std.testing.allocator);

    var iter = Iter.init(tjson.value(), std.testing.allocator);
    try js_query.query(&iter);
    defer iter.deinit();

    var expected = TestIter.init(&.{});
    try expected.shouldEql(&iter);
}