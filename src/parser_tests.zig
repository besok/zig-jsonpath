const std = @import("std");
const JPQueryParser = @import("parser.zig").JPQueryParser;
const model = @import("model.zig");
const lit = model.lit;
const slice = model.slice;
const sel = model.sel;
const sqs = model.sqs;

fn assertParseSuccess(
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

fn assertParseFails(input: []const u8, comptime parseFn: anytype) !void {
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

pub fn sqSegs(comptime segs: anytype) SingularQuerySegments {
    var arr: [segs.len]model.SingularQuerySegment = undefined;
    inline for (segs, 0..) |s, i| arr[i] = s;
    return .{ .segs = @constCast(&arr) };
}

fn parseSingularQuerySegments(p: *JPQueryParser) !SingularQuerySegments {
    const segs = try p.parseSingularQuerySegments();
    return .{ .segs = segs };
}

test "literal" {
    try assertParseSuccess("'☺'", lit("☺"), JPQueryParser.parseLiteral);
    try assertParseSuccess("' '", lit(" "), JPQueryParser.parseLiteral);
    try assertParseSuccess("'\"try'", lit("\"try"), JPQueryParser.parseLiteral);
    try assertParseSuccess("null", lit(null), JPQueryParser.parseLiteral);
    try assertParseSuccess("false", lit(false), JPQueryParser.parseLiteral);
    try assertParseSuccess("true", lit(true), JPQueryParser.parseLiteral);
    try assertParseSuccess("\"hello\"", lit("hello"), JPQueryParser.parseLiteral);
    try assertParseSuccess("'hello'", lit("hello"), JPQueryParser.parseLiteral);
    try assertParseSuccess("'hel\\'lo'", lit("hel'lo"), JPQueryParser.parseLiteral);
    try assertParseSuccess("'hel\"lo'", lit("hel\"lo"), JPQueryParser.parseLiteral);
    try assertParseSuccess("'hel\\nlo'", lit("hel\nlo"), JPQueryParser.parseLiteral);
    try assertParseSuccess("1", lit(1), JPQueryParser.parseLiteral);
    try assertParseSuccess("0", lit(0), JPQueryParser.parseLiteral);
    try assertParseSuccess("-0", lit(0), JPQueryParser.parseLiteral);
    try assertParseSuccess("1.2", lit(1.2), JPQueryParser.parseLiteral);
    try assertParseSuccess("9007199254740990", lit(9007199254740990), JPQueryParser.parseLiteral);

    try assertParseFails("\"\n\"", JPQueryParser.parseLiteral);
    try assertParseFails("hel\\\"lo", JPQueryParser.parseLiteral);
    try assertParseFails("9007199254740995", JPQueryParser.parseLiteral);
}

test "slice selector" {
    try assertParseSuccess(":", sel(slice(null, null, null)), JPQueryParser.parseIndexOrSlice);
    try assertParseSuccess("::", sel(slice(null, null, null)), JPQueryParser.parseIndexOrSlice);
    try assertParseSuccess("1:", sel(slice(1, null, null)), JPQueryParser.parseIndexOrSlice);
    try assertParseSuccess("1:1", sel(slice(1, 1, null)), JPQueryParser.parseIndexOrSlice);
    try assertParseSuccess("1:1:1", sel(slice(1, 1, 1)), JPQueryParser.parseIndexOrSlice);
    try assertParseSuccess(":1:1", sel(slice(null, 1, 1)), JPQueryParser.parseIndexOrSlice);
    try assertParseSuccess("::1", sel(slice(null, null, 1)), JPQueryParser.parseIndexOrSlice);
    try assertParseSuccess("1::1", sel(slice(1, null, 1)), JPQueryParser.parseIndexOrSlice);

    try assertParseFails("-0:", JPQueryParser.parseIndexOrSlice);
    try assertParseFails("9007199254740995", JPQueryParser.parseIndexOrSlice);
}

test "singular query segments" {
    var segs_bb = [_]model.SingularQuerySegment{ sqs("b"), sqs("b") };
    try assertParseSuccess("[\"b\"][\"b\"]", SingularQuerySegments{ .segs = &segs_bb }, parseSingularQuerySegments);

    var segs_21 = [_]model.SingularQuerySegment{ sqs(2), sqs(1) };
    try assertParseSuccess("[2][1]", SingularQuerySegments{ .segs = &segs_21 }, parseSingularQuerySegments);

    var segs_2a = [_]model.SingularQuerySegment{ sqs(2), sqs("a") };
    try assertParseSuccess("[2][\"a\"]", SingularQuerySegments{ .segs = &segs_2a }, parseSingularQuerySegments);

    var segs_ab = [_]model.SingularQuerySegment{ sqs("a"), sqs("b") };
    try assertParseSuccess(".a.b", SingularQuerySegments{ .segs = &segs_ab }, parseSingularQuerySegments);

    var segs_abc1 = [_]model.SingularQuerySegment{ sqs("a"), sqs("b"), sqs("c"), sqs(1) };
    try assertParseSuccess(".a.b[\"c\"][1]", SingularQuerySegments{ .segs = &segs_abc1 }, parseSingularQuerySegments);
}
//
// test "singular query" {
//     try assertParseSuccess("@.a.b", h.sqCurrent(&.{ h.sqSegName("a"), h.sqSegName("b") }), JPQueryParser.parseSingularQuery);
//     try assertParseSuccess("@",     h.sqCurrent(&.{}),                                      JPQueryParser.parseSingularQuery);
//     try assertParseSuccess("$",     h.sqRoot(&.{}),                                         JPQueryParser.parseSingularQuery);
//     try assertParseSuccess("$.a.b.c", h.sqRoot(&.{ h.sqSegName("a"), h.sqSegName("b"), h.sqSegName("c") }), JPQueryParser.parseSingularQuery);
//     try assertParseSuccess("$[\"a\"].b[3]", h.sqRoot(&.{ h.sqSegName("a"), h.sqSegName("b"), h.sqSegIndex(3) }), JPQueryParser.parseSingularQuery);
// }
//
// test "comparable" {
//     try assertParseSuccess("1",       h.cmpLit(h.litInt(1)),                                              JPQueryParser.parseComparable);
//     try assertParseSuccess("\"a\"",   h.cmpLit(h.lit("a")),                                               JPQueryParser.parseComparable);
//     try assertParseSuccess("@.a.b.c", h.cmpQuery(h.sqCurrent(&.{ h.sqSegName("a"), h.sqSegName("b"), h.sqSegName("c") })), JPQueryParser.parseComparable);
//     try assertParseSuccess("$.a.b.c", h.cmpQuery(h.sqRoot(&.{ h.sqSegName("a"), h.sqSegName("b"), h.sqSegName("c") })),    JPQueryParser.parseComparable);
//     try assertParseSuccess("$[1]",    h.cmpQuery(h.sqRoot(&.{ h.sqSegIndex(1) })),                        JPQueryParser.parseComparable);
// }
//
// test "comp expr" {
//     try assertParseSuccess(
//         "@.a.b.c == 1",
//         h.cmp("==",
//             h.cmpQuery(h.sqCurrent(&.{ h.sqSegName("a"), h.sqSegName("b"), h.sqSegName("c") })),
//             h.cmpLit(h.litInt(1)),
//         ),
//         JPQueryParser.parseFilter,
//     );
// }
//
// test "filter atom" {
//     try assertParseSuccess(
//         "1 > 2",
//         h.filterAtom(h.atomCmp(h.cmp(">", h.cmpLit(h.litInt(1)), h.cmpLit(h.litInt(2))))),
//         JPQueryParser.parseFilter,
//     );
//     try assertParseSuccess(
//         "!(@.a == 1 || @.b == 2)",
//         h.filterAtom(try h.atomFilter(std.testing.allocator,
//             h.filterOr(&.{
//                 h.filterAtom(h.atomCmp(h.cmp("==",
//                     h.cmpQuery(h.sqCurrent(&.{ h.sqSegName("a") })),
//                     h.cmpLit(h.litInt(1)),
//                 ))),
//                 h.filterAtom(h.atomCmp(h.cmp("==",
//                     h.cmpQuery(h.sqCurrent(&.{ h.sqSegName("b") })),
//                     h.cmpLit(h.litInt(2)),
//                 ))),
//             }),
//             true,
//         )),
//         JPQueryParser.parseFilter,
//     );
// }
//
// test "function expr" {
//     try assertParseSuccess(
//         "length(1)",
//         model.TestFunction{ .length = .{ .arg = h.argLit(h.litInt(1)) } },
//         JPQueryParser.parseFunctionExpr,
//     );
//     try assertParseSuccess(
//         "length(true)",
//         model.TestFunction{ .length = .{ .arg = h.argLit(h.litBool(true)) } },
//         JPQueryParser.parseFunctionExpr,
//     );
//     try assertParseSuccess(
//         "search(@, \"abc\")",
//         model.TestFunction{ .search = .{
//             .lhs = try h.argTest(std.testing.allocator, model.Test{ .rel_query = &.{} }),
//             .rhs = h.argLit(h.lit("abc")),
//         }},
//         JPQueryParser.parseFunctionExpr,
//     );
//     try assertParseSuccess(
//         "count(@.a)",
//         model.TestFunction{ .count = .{ .arg = try h.argTest(std.testing.allocator,
//             model.Test{ .rel_query = &.{ h.seg(h.sel(h.selectorName("a"))) } },
//         )}},
//         JPQueryParser.parseFunctionExpr,
//     );
//
//     try assertParseFails("count\t(@.*)", JPQueryParser.parseFunctionExpr);
// }
//
// test "full query" {
//     const atom = h.filterAtom(h.atomCmp(h.cmp(">",
//         h.cmpQuery(h.sqCurrent(&.{ h.sqSegName("a"), h.sqSegName("b") })),
//         h.cmpLit(h.litInt(1)),
//     )));
//     try assertParseSuccess(
//         "$.a.b[?@.a.b > 1]",
//         h.jpQuery(&.{
//             h.seg(h.sel(h.selectorName("a"))),
//             h.seg(h.sel(h.selectorName("b"))),
//             h.seg(h.sel(h.selectorFilter(atom))),
//         }),
//         JPQueryParser.parse,
//     );
// }
//
// test "parse root only" {
//     try assertParseSuccess("$", h.jpQuery(&.{}), JPQueryParser.parse);
// }
