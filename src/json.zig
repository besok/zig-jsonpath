const std = @import("std");

test "smoke from string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const js = "{\"a\":[1,2,3]}";

    const parsed_json = try std.json.parseFromSlice(std.json.Value, arena.allocator(), js, .{});

    std.debug.print("print - {any}", .{parsed_json.value.object});
}
