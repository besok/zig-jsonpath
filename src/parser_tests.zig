const std = @import("std");
const JPQueryParser = @import("parser.zig").JPQueryParser;
const model = @import("model.zig");
const lit = model.lit;


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




// --- Helpers ----
fn assertParseSuccess(
    input: []const u8,
    expected: anytype,
    comptime parseFn: anytype,
) !void {
    var p = JPQueryParser.init(input, std.testing.allocator);
    var actual = parseFn(&p) catch |e| return p.printThenFail(e);
    defer actual.deinit(std.testing.allocator);
    try std.testing.expect(expected.eql(actual));
}
fn assertParseFails(input: []const u8, comptime parseFn: anytype) !void {
    var p = JPQueryParser.init(input, std.testing.allocator);
    const res = parseFn(&p);
    try std.testing.expectError(error.UnexpectedChar, res);
}
