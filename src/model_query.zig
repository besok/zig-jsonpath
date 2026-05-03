const std = @import("std");
const mvzr = @import("mvzr");
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
fn evaluateArg(arg: model.FnArg, iter: *q.JsonPathIter) !?std.json.Value {
    return switch (arg) {
        .lit => |l| l.toJsValue(),
        .test_arg => |t| {
            try t.query(iter);
            return if (iter.cursors.items.len == 1) iter.cursors.items[0].json.* else null;
        },
        .filter => null,
    };
}

pub fn queryLength(arg: model.FnArg, iter: *q.JsonPathIter) !?std.json.Value {
    var branch = try iter.fork();
    defer branch.deinit();

    const val = try evaluateArg(arg, &branch) orelse return null;
    return switch (branch.cursors.items.len) {
        0 => null,
        1 => lengthOfValue(val),
        else => |n| .{ .integer = @intCast(n) },
    };
}

pub fn queryCount(arg: model.FnArg, iter: *q.JsonPathIter) !?std.json.Value {
    var branch = try iter.fork();
    defer branch.deinit();

    _ = try evaluateArg(arg, &branch);
    return switch (branch.cursors.items.len) {
        0 => null,
        else => |n| .{ .integer = @intCast(n) },
    };
}

pub fn queryValue(arg: model.FnArg, iter: *q.JsonPathIter) !?std.json.Value {
    var branch = try iter.fork();
    defer branch.deinit();

    return evaluateArg(arg, &branch);
}

pub fn queryMatch(lhs: model.FnArg, rhs: model.FnArg, iter: *q.JsonPathIter) !?std.json.Value {
    return queryRegex(lhs, rhs, false, iter);
}

pub fn querySearch(lhs: model.FnArg, rhs: model.FnArg, iter: *q.JsonPathIter) !?std.json.Value {
    return queryRegex(lhs, rhs, true, iter);
}

pub fn queryRegex(lhs: model.FnArg, rhs: model.FnArg, substr: bool, iter: *q.JsonPathIter) !?std.json.Value {
    var lhs_branch = try iter.fork();
    defer lhs_branch.deinit();
    const lhs_val = try evaluateArg(lhs, &lhs_branch) orelse return .{ .bool = false };

    var rhs_branch = try iter.fork();
    defer rhs_branch.deinit();
    const rhs_val = try evaluateArg(rhs, &rhs_branch) orelse return .{ .bool = false };

    const lhs_str = switch (lhs_val) {
        .string => |v| v,
        else => return .{ .bool = false },
    };
    const rhs_str = switch (rhs_val) {
        .string => |v| v,
        else => return .{ .bool = false },
    };

    const matched = try matchRegex(lhs_str, rhs_str, substr, iter.allocator);
    return .{ .bool = matched };
}
pub fn matchRegex(input: []const u8, pattern: []const u8, substr: bool, allocator: std.mem.Allocator) !bool {
    // strip user-provided anchors — we handle anchoring ourselves
    var p = pattern;
    if (std.mem.startsWith(u8, p, "^")) p = p[1..];
    if (std.mem.endsWith(u8, p, "$")) p = p[0 .. p.len - 1];

    const prepared = if (substr)
        try allocator.dupe(u8, p)
    else
        try std.fmt.allocPrint(allocator, "^{s}$", .{p});

    defer allocator.free(prepared);

    const re = mvzr.compile(prepared) orelse return false;
    return re.isMatch(input);
}

pub fn queryCustom(name: []const u8, args: []model.FnArg, iter: *q.JsonPathIter) !?std.json.Value {
    _ = name;
    _ = args;
    _ = iter;
    return null;
}

fn lengthOfValue(val: std.json.Value) ?std.json.Value {
    return switch (val) {
        .string => |v| .{ .integer = @intCast(std.unicode.utf8CountCodepoints(v) catch return null) },
        .array => |v| .{ .integer = @intCast(v.items.len) },
        .object => |v| .{ .integer = @intCast(v.count()) },
        else => null,
    };
}

pub fn jsonValueEql(a: std.json.Value, b: std.json.Value) bool {
    return switch (a) {
        .null => b == .null,

        .bool => |v| switch (b) {
            .bool => |w| v == w,
            else => false,
        },

        .integer => |v| switch (b) {
            .integer => |w| v == w,
            .float => |w| @as(f64, @floatFromInt(v)) == w,
            .number_string => |w| blk: {
                const parsed = std.fmt.parseInt(i64, w, 10) catch break :blk false;
                break :blk v == parsed;
            },
            else => false,
        },

        .float => |v| switch (b) {
            .float => |w| @abs(v - w) < 0.0001,
            .integer => |w| v == @as(f64, @floatFromInt(w)),
            .number_string => |w| blk: {
                const parsed = std.fmt.parseFloat(f64, w) catch break :blk false;
                break :blk @abs(v - parsed) < 0.0001;
            },
            else => false,
        },

        .string => |v| switch (b) {
            .string => |w| std.mem.eql(u8, v, w),
            else => false,
        },

        .number_string => |v| switch (b) {
            .number_string => |w| std.mem.eql(u8, v, w),

            .integer => |w| blk: {
                const parsed = std.fmt.parseInt(i64, v, 10) catch break :blk false;
                break :blk parsed == w;
            },

            .float => |w| blk: {
                const parsed = std.fmt.parseFloat(f64, v) catch break :blk false;
                break :blk @abs(parsed - w) < 0.0001;
            },

            else => false,
        },

        .array => |arr_a| switch (b) {
            .array => |arr_b| blk: {
                if (arr_a.items.len != arr_b.items.len) break :blk false;

                for (arr_a.items, arr_b.items) |item_a, item_b| {
                    if (!jsonValueEql(item_a, item_b)) break :blk false;
                }

                break :blk true;
            },
            else => false,
        },

        .object => |obj_a| switch (b) {
            .object => |obj_b| blk: {
                if (obj_a.count() != obj_b.count()) break :blk false;

                var it = obj_a.iterator();
                while (it.next()) |entry| {
                    const key = entry.key_ptr.*;
                    const val_a = entry.value_ptr.*;

                    const val_b = obj_b.get(key) orelse break :blk false;

                    if (!jsonValueEql(val_a, val_b)) break :blk false;
                }

                break :blk true;
            },
            else => false,
        },
    };
}

pub fn jsonValueCmp(a: std.json.Value, b: std.json.Value) ?std.math.Order {
    return switch (a) {
        .integer => |v| switch (b) {
            .integer => std.math.order(v, b.integer),
            .float => std.math.order(@as(f64, @floatFromInt(v)), b.float),
            else => null, // incomparable types
        },
        .float => |v| switch (b) {
            .float => std.math.order(v, b.float),
            .integer => std.math.order(v, @as(f64, @floatFromInt(b.integer))),
            else => null,
        },
        .string => |v| switch (b) {
            .string => std.mem.order(u8, v, b.string),
            else => null,
        },
        // null/bool/array/object are not ordered per RFC 9535
        else => null,
    };
}

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
