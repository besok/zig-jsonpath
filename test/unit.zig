const std = @import("std");
const jsonpath = @import("zig_jsonpath");


comptime {
    _ = @import("model_test.zig");
    _ = @import("parser_test.zig");
}

test "smoke" {
    const allocator = std.testing.allocator;
    const source = "{\"foo\": [1, 2, 3]}";
    const path = "$.foo[*]";
    var result = try jsonpath.text_query(source, path, allocator);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.results.len);
}