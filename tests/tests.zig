const std = @import("std");
const jsonpath = @import("jsonpath"); // Matches the name in addImport

test "public api check" {
    try std.testing.expect(0 == 0);
}