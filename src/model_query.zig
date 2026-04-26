const std = @import("std");

const model = @import("model.zig");
const q = @import("query.zig");

pub fn querySlice(slice: model.Slice, iteration: *q.JsonPathIter) !void {
    var next_pointers = std.ArrayListUnmanaged(q.JsonPointer){};
    errdefer {
        for (next_pointers.items) |*p| p.deinit(iteration.allocator);
        next_pointers.deinit(iteration.allocator);
    }

    for (iteration.cursors.items) |cursor| {
        switch (cursor.json.*) {
            .array => |arr| {
                const len: i64 = @intCast(arr.items.len);
                const norm = struct {
                    fn call(i: i64, l: i64) i64 {
                        return if (i >= 0) i else l + i;
                    }
                }.call;

                const step = slice.step orelse 1;
                if (step == 0) continue;

                if (step > 0) {
                    const n_start = norm(slice.start orelse 0, len);
                    const n_end = norm(slice.end orelse len, len);
                    const lower = @max(@min(n_start, len), 0);
                    const upper = @max(@min(n_end, len), 0);

                    var idx: i64 = lower;
                    while (idx < upper) : (idx += step) {
                        const i: usize = @intCast(idx);
                        const new_path = try std.fmt.allocPrint(
                            iteration.allocator,
                            "{s}[{d}]",
                            .{ cursor.path, i },
                        );
                        errdefer iteration.allocator.free(new_path);
                        try next_pointers.append(iteration.allocator, .{ .json = &arr.items[i], .path = new_path });
                    }
                } else {
                    const n_start = norm(slice.start orelse len - 1, len);
                    const n_end = norm(slice.end orelse -len - 1, len);
                    const lower = @max(@min(n_end, len - 1), -1);
                    const upper = @max(@min(n_start, len - 1), -1);

                    var idx: i64 = upper;
                    while (idx > lower) : (idx += step) {
                        const i: usize = @intCast(idx);
                        const new_path = try std.fmt.allocPrint(
                            iteration.allocator,
                            "{s}[{d}]",
                            .{ cursor.path, i },
                        );
                        errdefer iteration.allocator.free(new_path);
                        try next_pointers.append(iteration.allocator, .{ .json = &arr.items[i], .path = new_path });
                    }
                }
            },
            else => {},
        }
    }

    for (iteration.cursors.items) |*p| p.deinit(iteration.allocator);
    iteration.cursors.deinit(iteration.allocator);
    iteration.cursors = next_pointers;
}

pub fn queryName(name: []const u8, iteration: *q.JsonPathIter) !void {
    var i: usize = 0;
    while (i < iteration.cursors.items.len) {
        const cursor = iteration.cursors.items[i];
        switch (cursor.json.*) {
            .object => |obj| {
                if (obj.getPtr(name)) |val| {
                    const new_path = try std.fmt.allocPrint(
                        iteration.allocator,
                        "{s}['{s}']",
                        .{ cursor.path, name },
                    );
                    iteration.allocator.free(cursor.path);
                    iteration.cursors.items[i] = .{ .json = val, .path = new_path };
                    i += 1;
                } else {
                    iteration.remove(i);
                }
            },
            else => iteration.remove(i),
        }
    }
}
pub fn queryIndex(index: i64, iteration: *q.JsonPathIter) !void {
    var i: usize = 0;
    while (i < iteration.cursors.items.len) {
        const cursor = iteration.cursors.items[i];
        switch (cursor.json.*) {
            .array => |arr| {
                const actual_index: usize = if (index >= 0) @intCast(index) else blk: {
                    const abs: usize = @intCast(-index);
                    if (abs > arr.items.len) {
                        iteration.remove(i);
                        continue;
                    }
                    break :blk arr.items.len - abs;
                };

                if (actual_index < arr.items.len) {
                    const new_path = try std.fmt.allocPrint(
                        iteration.allocator,
                        "{s}[{d}]",
                        .{ cursor.path, index },
                    );
                    iteration.allocator.free(cursor.path);
                    iteration.cursors.items[i] = .{ .json = &arr.items[actual_index], .path = new_path };
                    i += 1;
                } else {
                    iteration.remove(i);
                }
            },
            else => {
                iteration.remove(i);
            },
        }
    }
}
pub fn queryWildcard(iteration: *q.JsonPathIter) !void {
    var next_pointers = std.ArrayListUnmanaged(q.JsonPointer){};
    errdefer {
        for (next_pointers.items) |*p| p.deinit(iteration.allocator);
        next_pointers.deinit(iteration.allocator);
    }

    for (iteration.cursors.items) |cursor| {
        switch (cursor.json.*) {
            .array => |arr| {
                for (arr.items, 0..) |*elem, idx| {
                    const new_path = try std.fmt.allocPrint(
                        iteration.allocator,
                        "{s}[{d}]",
                        .{ cursor.path, idx },
                    );
                    errdefer iteration.allocator.free(new_path);
                    try next_pointers.append(iteration.allocator, .{ .json = elem, .path = new_path });
                }
            },
            .object => |obj| {
                var it = obj.iterator();
                while (it.next()) |entry| {
                    const new_path = try std.fmt.allocPrint(
                        iteration.allocator,
                        "{s}['{s}']",
                        .{ cursor.path, entry.key_ptr.* },
                    );
                    errdefer iteration.allocator.free(new_path);
                    try next_pointers.append(iteration.allocator, .{ .json = entry.value_ptr, .path = new_path });
                }
            },
            else => {},
        }
    }

    for (iteration.cursors.items) |*p| p.deinit(iteration.allocator);
    iteration.cursors.deinit(iteration.allocator);
    iteration.cursors = next_pointers;
}

pub fn queryDescendant(iteration: *q.JsonPathIter) !void {
    var next = std.ArrayListUnmanaged(q.JsonPointer){};
    errdefer {
        for (next.items) |*p| p.deinit(iteration.allocator);
        next.deinit(iteration.allocator);
    }

    for (iteration.cursors.items) |cursor| {
        try collectDescendants(iteration.allocator, cursor.json, cursor.path, &next);
    }

    for (iteration.cursors.items) |*p| p.deinit(iteration.allocator);
    iteration.cursors.deinit(iteration.allocator);
    iteration.cursors = next;
    try deduplicateByPath(iteration);
}

pub fn querySingularQuerySegmentByIndex(
    index: i64,
    iteration: *q.JsonPathIter,
) !void {
    var i: usize = 0;
    while (i < iteration.cursors.items.len) {
        const cursor = iteration.cursors.items[i];
        switch (cursor.json.*) {
            .array => |arr| {
                const resolved_index: usize = if (index >= 0) blk: {
                    const pos: usize = @intCast(index);
                    if (pos >= arr.items.len) {
                        iteration.remove(i);
                        continue;
                    }
                    break :blk pos;
                } else blk: {
                    const abs: usize = @intCast(-index);
                    if (abs > arr.items.len) {
                        iteration.remove(i);
                        continue;
                    }
                    break :blk arr.items.len - abs;
                };

                const new_path = try std.fmt.allocPrint(
                    iteration.allocator,
                    "{s}[{d}]",
                    .{ cursor.path, resolved_index },
                );
                iteration.allocator.free(cursor.path);
                iteration.cursors.items[i] = .{ .json = &arr.items[resolved_index], .path = new_path };
                i += 1;
            },
            else => iteration.remove(i),
        }
    }
}

pub fn querySingularQuerySegmentByName(
    name: []const u8,
    iteration: *q.JsonPathIter,
) !void {
    var i: usize = 0;
    while (i < iteration.cursors.items.len) {
        const cursor = iteration.cursors.items[i];
        switch (cursor.json.*) {
            .object => |obj| {
                if (obj.getPtr(name)) |val| {
                    const new_path = try std.fmt.allocPrint(
                        iteration.allocator,
                        "{s}['{s}']",
                        .{ cursor.path, name },
                    );
                    iteration.allocator.free(cursor.path);
                    iteration.cursors.items[i] = .{ .json = val, .path = new_path };
                    i += 1;
                } else {
                    iteration.remove(i);
                }
            },
            else => iteration.remove(i),
        }
    }
}

fn queryLength(arg: model.FnArg, iteration: *q.JsonPathIter) !void {}

fn queryValue(arg: model.FnArg, iteration: *q.JsonPathIter) !void {}
fn queryCount(arg: model.FnArg, iteration: *q.JsonPathIter) !void {}
fn querySearch(lhs: model.FnArg, rhs: model.FnArg, iteration: *q.JsonPathIter) !void {}
fn queryMatch(lhs: model.FnArg, rhs: model.FnArg, iteration: *q.JsonPathIter) !void {}
fn queryCustom(name: []const u8, args: []model.FnArg, iteration: *q.JsonPathIter) !void {}

fn collectDescendants(
    allocator: std.mem.Allocator,
    value: *std.json.Value,
    path: []const u8,
    out: *std.ArrayListUnmanaged(q.JsonPointer),
) !void {
    try out.append(allocator, .{ .json = value, .path = try allocator.dupe(u8, path) });

    switch (value.*) {
        .array => |arr| {
            for (arr.items, 0..) |*elem, i| {
                const child_path = try std.fmt.allocPrint(allocator, "{s}[{d}]", .{ path, i });
                errdefer allocator.free(child_path);
                try collectDescendants(allocator, elem, child_path, out);
                allocator.free(child_path);
            }
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                const child_path = try std.fmt.allocPrint(allocator, "{s}['{s}']", .{ path, entry.key_ptr.* });
                errdefer allocator.free(child_path);
                try collectDescendants(allocator, entry.value_ptr, child_path, out);
                allocator.free(child_path);
            }
        },
        else => {},
    }
}

fn deduplicateByPath(iteration: *q.JsonPathIter) !void {
    var seen = std.StringHashMap(void).init(iteration.allocator);
    defer seen.deinit();

    var deduped = std.ArrayListUnmanaged(q.JsonPointer){};
    errdefer {
        for (deduped.items) |*p| p.deinit(iteration.allocator);
        deduped.deinit(iteration.allocator);
    }

    for (iteration.cursors.items) |p| {
        const result = try seen.getOrPut(p.path);
        if (!result.found_existing) {
            try deduped.append(iteration.allocator, p);
        } else {
            iteration.allocator.free(p.path);
        }
    }

    iteration.cursors.deinit(iteration.allocator);
    iteration.cursors = deduped;
}
