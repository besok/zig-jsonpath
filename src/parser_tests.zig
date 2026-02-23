const std = @import("std");
const JPQueryParser = @import("parser.zig").JPQueryParser;
const model = @import("model.zig");
const lit = model.lit;

fn assertLiteral(input: []const u8, expected: model.Literal) !void {
    var p = JPQueryParser.init(input, std.testing.allocator);
    const res = p.parseLiteral() catch |e| return p.printThenFail(e);

    defer if (res == .str) std.testing.allocator.free(res.str);

    switch (expected) {
        .int => |val| {
            try std.testing.expect(res == .int);
            try std.testing.expectEqual(val, res.int);
        },
        .float => |val| {
            try std.testing.expect(res == .float);
            try std.testing.expectApproxEqAbs(val, res.float, 0.0001);
        },
        .str => |val| {
            try std.testing.expect(res == .str);
            try std.testing.expectEqualStrings(val, res.str);
        },
        .bool => |val| {
            try std.testing.expect(res == .bool);
            try std.testing.expectEqual(val, res.bool);
        },
        .null => {
            try std.testing.expect(res == .null);
        },
    }
}

fn assertLiteralFails(input: []const u8) !void {
    var p = JPQueryParser.init(input, std.testing.allocator);
    const res = p.parseLiteral();
    try std.testing.expectError(error.UnexpectedChar, res);
}

test "literal" {
    // Valid literals
    try assertLiteral("'☺'", lit("☺"));
    try assertLiteral("' '", lit(" "));
    try assertLiteral("'\"try'",  lit("\"try"));
    try assertLiteral("null", lit(null));
    try assertLiteral("false", lit(false));
    try assertLiteral("true", lit(true));
    try assertLiteral("\"hello\"", lit("hello"));
    try assertLiteral("'hello'", lit("hello"));
    try assertLiteral("'hel\\'lo'", lit("hel'lo"));
    try assertLiteral("'hel\"lo'", lit("hel\"lo"));
    try assertLiteral("'hel\\nlo'", lit("hel\nlo"));
    try assertLiteral("1", lit(1));
    try assertLiteral("0", lit(0));
    try assertLiteral("-0", lit(0));
    try assertLiteral("1.2", lit(1.2));
    try assertLiteral("9007199254740990", lit(9007199254740990));

    // Invalid literals
    try assertLiteralFails("\"\n\"");
    try assertLiteralFails("hel\\\"lo");
    try assertLiteralFails("9007199254740995");
}
