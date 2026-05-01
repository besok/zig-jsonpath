const std = @import("std");
const jsonpath = @import("zig_jsonpath");
const parser = jsonpath.parser;
const JPQueryParser = parser.JPQueryParser;
const model = jsonpath.model;
const lit = model.lit;
const slice = model.slice;
const sel = model.sel;
const sqs = model.sqs;
const cmp = model.cmp;
const fCmp = model.filterCmp;
const fOr = model.filterOr;
const eq = model.eq;

fn expectGood(
    input: []const u8,
    expected: anytype,
    comptime parseFn: anytype,
) !void {
    var p = JPQueryParser.init(input, std.testing.allocator);
    var actual = parseFn(&p) catch |e| return p.printThenFail(e);
    defer actual.deinit(std.testing.allocator);
    if (!expected.eql(actual)) {
        std.debug.print("expected: {any}\n", .{expected});
        std.debug.print("actual:   {any}\n", .{actual});
        return error.TestExpectedEqual;
    }
}

fn expectFail(input: []const u8, comptime parseFn: anytype) !void {
    var p = JPQueryParser.init(input, std.testing.allocator);
    const res = parseFn(&p);
    try std.testing.expectError(error.UnexpectedChar, res);
}

pub const SingularQuerySegments = struct {
    segs: []model.SingularQuerySegment,

    pub fn eql(self: SingularQuerySegments, other: SingularQuerySegments) bool {
        if (self.segs.len != other.segs.len) return false;
        for (self.segs, other.segs) |a, b| {
            if (!a.eql(b)) return false;
        }
        return true;
    }

    pub fn deinit(self: *SingularQuerySegments, allocator: std.mem.Allocator) void {
        for (self.segs) |*s| {
            switch (s.*) {
                .name => |n| allocator.free(n),
                .index => {},
            }
        }
        allocator.free(self.segs);
    }
};

fn parseSingularQuerySegments(p: *JPQueryParser) !SingularQuerySegments {
    const segs = try p.parseSingularQuerySegments();
    return .{ .segs = segs };
}

test "literal" {
    try expectGood("'☺'", lit("☺"), JPQueryParser.parseLiteral);
    try expectGood("' '", lit(" "), JPQueryParser.parseLiteral);
    try expectGood("'\"try'", lit("\"try"), JPQueryParser.parseLiteral);
    try expectGood("null", lit(null), JPQueryParser.parseLiteral);
    try expectGood("false", lit(false), JPQueryParser.parseLiteral);
    try expectGood("true", lit(true), JPQueryParser.parseLiteral);
    try expectGood("\"hello\"", lit("hello"), JPQueryParser.parseLiteral);
    try expectGood("'hello'", lit("hello"), JPQueryParser.parseLiteral);
    try expectGood("'hel\\'lo'", lit("hel'lo"), JPQueryParser.parseLiteral);
    try expectGood("'hel\"lo'", lit("hel\"lo"), JPQueryParser.parseLiteral);
    try expectGood("'hel\\nlo'", lit("hel\nlo"), JPQueryParser.parseLiteral);
    try expectGood("1", lit(1), JPQueryParser.parseLiteral);
    try expectGood("0", lit(0), JPQueryParser.parseLiteral);
    try expectGood("-0", lit(0), JPQueryParser.parseLiteral);
    try expectGood("1.2", lit(1.2), JPQueryParser.parseLiteral);
    try expectGood("9007199254740990", lit(9007199254740990), JPQueryParser.parseLiteral);

    try expectFail("\"\n\"", JPQueryParser.parseLiteral);
    try expectFail("hel\\\"lo", JPQueryParser.parseLiteral);
    try expectFail("9007199254740995", JPQueryParser.parseLiteral);
}

test "slice selector" {
    try expectGood(":", sel(slice(null, null, null)), JPQueryParser.parseIndexOrSlice);
    try expectGood("::", sel(slice(null, null, null)), JPQueryParser.parseIndexOrSlice);
    try expectGood("1:", sel(slice(1, null, null)), JPQueryParser.parseIndexOrSlice);
    try expectGood("1:1", sel(slice(1, 1, null)), JPQueryParser.parseIndexOrSlice);
    try expectGood("1:1:1", sel(slice(1, 1, 1)), JPQueryParser.parseIndexOrSlice);
    try expectGood(":1:1", sel(slice(null, 1, 1)), JPQueryParser.parseIndexOrSlice);
    try expectGood("::1", sel(slice(null, null, 1)), JPQueryParser.parseIndexOrSlice);
    try expectGood("1::1", sel(slice(1, null, 1)), JPQueryParser.parseIndexOrSlice);

    try expectFail("-0:", JPQueryParser.parseIndexOrSlice);
    try expectFail("9007199254740995", JPQueryParser.parseIndexOrSlice);
}

test "singular query segments" {
    var segs_bb = [_]model.SingularQuerySegment{ sqs("b"), sqs("b") };
    try expectGood("[\"b\"][\"b\"]", SingularQuerySegments{ .segs = &segs_bb }, parseSingularQuerySegments);

    var segs_21 = [_]model.SingularQuerySegment{ sqs(2), sqs(1) };
    try expectGood("[2][1]", SingularQuerySegments{ .segs = &segs_21 }, parseSingularQuerySegments);

    var segs_2a = [_]model.SingularQuerySegment{ sqs(2), sqs("a") };
    try expectGood("[2][\"a\"]", SingularQuerySegments{ .segs = &segs_2a }, parseSingularQuerySegments);

    var segs_ab = [_]model.SingularQuerySegment{ sqs("a"), sqs("b") };
    try expectGood(".a.b", SingularQuerySegments{ .segs = &segs_ab }, parseSingularQuerySegments);

    var segs_abc1 = [_]model.SingularQuerySegment{ sqs("a"), sqs("b"), sqs("c"), sqs(1) };
    try expectGood(".a.b[\"c\"][1]", SingularQuerySegments{ .segs = &segs_abc1 }, parseSingularQuerySegments);
}

test "singular query" {
    var segs_ab = [_]model.SingularQuerySegment{ sqs("a"), sqs("b") };
    try expectGood("@.a.b", model.SingularQuery{ .current = &segs_ab }, JPQueryParser.parseSingularQuery);

    try expectGood("@", model.SingularQuery{ .current = &.{} }, JPQueryParser.parseSingularQuery);
    try expectGood("$", model.SingularQuery{ .root = &.{} }, JPQueryParser.parseSingularQuery);

    var segs_abc = [_]model.SingularQuerySegment{ sqs("a"), sqs("b"), sqs("c") };
    try expectGood("$.a.b.c", model.SingularQuery{ .root = &segs_abc }, JPQueryParser.parseSingularQuery);

    var segs_ab3 = [_]model.SingularQuerySegment{ sqs("a"), sqs("b"), sqs(3) };
    try expectGood("$[\"a\"].b[3]", model.SingularQuery{ .root = &segs_ab3 }, JPQueryParser.parseSingularQuery);
}
test "comparable" {
    try expectGood("1", cmp(lit(1)), JPQueryParser.parseComparable);
    try expectGood("\"a\"", cmp(lit("a")), JPQueryParser.parseComparable);

    var segs_abc_cur = [_]model.SingularQuerySegment{ sqs("a"), sqs("b"), sqs("c") };
    try expectGood("@.a.b.c", cmp(model.SingularQuery{ .current = &segs_abc_cur }), JPQueryParser.parseComparable);

    var segs_abc_root = [_]model.SingularQuerySegment{ sqs("a"), sqs("b"), sqs("c") };
    try expectGood("$.a.b.c", cmp(model.SingularQuery{ .root = &segs_abc_root }), JPQueryParser.parseComparable);

    var segs_1 = [_]model.SingularQuerySegment{sqs(1)};
    try expectGood("$[1]", cmp(model.SingularQuery{ .root = &segs_1 }), JPQueryParser.parseComparable);
}

test "comp expr" {
    var segs_abc = [_]model.SingularQuerySegment{ sqs("a"), sqs("b"), sqs("c") };
    try expectGood(
        "@.a.b.c == 1",
        model.Filter{ .atom = .{ .compare = .{ .eq = .{
            .lhs = cmp(model.SingularQuery{ .current = &segs_abc }),
            .rhs = cmp(lit(1)),
        } } } },
        JPQueryParser.parseFilter,
    );
}
test "filter atom" {
    try expectGood(
        "1 > 2",
        model.Filter{ .atom = .{ .compare = .{ .gt = .{
            .lhs = cmp(lit(1)),
            .rhs = cmp(lit(2)),
        } } } },
        JPQueryParser.parseFilter,
    );

    var seg_a = [_]model.SingularQuerySegment{sqs("a")};
    var seg_b = [_]model.SingularQuerySegment{sqs("b")};
    var ors = [_]model.Filter{
        fCmp(eq(cmp(model.SingularQuery{ .current = &seg_a }), cmp(lit(1)))),
        fCmp(eq(cmp(model.SingularQuery{ .current = &seg_b }), cmp(lit(2)))),
    };
    const or_ptr = try std.testing.allocator.create(model.Filter);
    defer std.testing.allocator.destroy(or_ptr);
    or_ptr.* = fOr(&ors);
    try expectGood(
        "!(@.a == 1 || @.b == 2)",
        model.Filter{ .atom = .{ .filter = .{ .expr = or_ptr, .not = true } } },
        JPQueryParser.parseFilter,
    );
}
test "function expr" {
    try expectGood(
        "length(1)",
        model.TestFunction{ .length = .{ .arg = .{ .lit = lit(1) } } },
        JPQueryParser.parseFunctionExpr,
    );
    try expectGood(
        "length(true)",
        model.TestFunction{ .length = .{ .arg = .{ .lit = lit(true) } } },
        JPQueryParser.parseFunctionExpr,
    );

    const rel_empty = try std.testing.allocator.create(model.Test);
    defer std.testing.allocator.destroy(rel_empty);
    rel_empty.* = .{ .rel_query = &.{} };
    try expectGood(
        "search(@, \"abc\")",
        model.TestFunction{ .search = .{
            .lhs = .{ .test_arg = rel_empty },
            .rhs = .{ .lit = lit("abc") },
        } },
        JPQueryParser.parseFunctionExpr,
    );

    var seg_a = [_]model.Segment{.{ .selector = .{ .name = "a" } }};
    const rel_a = try std.testing.allocator.create(model.Test);
    defer std.testing.allocator.destroy(rel_a);
    rel_a.* = .{ .rel_query = &seg_a };
    try expectGood(
        "count(@.a)",
        model.TestFunction{ .count = .{ .arg = .{ .test_arg = rel_a } } },
        JPQueryParser.parseFunctionExpr,
    );

    try expectFail("count\t(@.*)", JPQueryParser.parseFunctionExpr);
}

test "parse root only" {
    try expectGood("$", model.JPQuery{ .segments = &.{} }, JPQueryParser.parse);
}

test "full query" {
    var segs_ab = [_]model.SingularQuerySegment{ sqs("a"), sqs("b") };
    const atom = model.Filter{ .atom = .{ .compare = .{ .gt = .{
        .lhs = cmp(model.SingularQuery{ .current = &segs_ab }),
        .rhs = cmp(lit(1)),
    } } } };
    var segments = [_]model.Segment{
        .{ .selector = .{ .name = "a" } },
        .{ .selector = .{ .name = "b" } },
        .{ .selector = .{ .filter = atom } },
    };
    try expectGood(
        "$.a.b[?@.a.b > 1]",
        model.JPQuery{ .segments = &segments },
        JPQueryParser.parse,
    );
}
