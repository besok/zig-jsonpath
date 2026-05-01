const std = @import("std");
const jsonpath = @import("jsonpath");
const suite = @import("suite.zig");

pub fn main() !void {
    // var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // defer _ = gpa.deinit();
    const allocator = std.heap.page_allocator;

    const cases = try suite.getCases(allocator);
    defer cases.deinit();

    const filtered_cases = try suite.getCaseFilters(allocator);
    defer filtered_cases.deinit();

    var skipped_set = std.StringHashMap(void).init(allocator);
    defer skipped_set.deinit();
    for (filtered_cases.value) |case| {
        try skipped_set.put(case.name, {});
    }

    var total: usize = 0;
    var passed: usize = 0;
    var skipped: usize = 0;

    for (cases.value.tests) |case| {
        total += 1;

        if (skipped_set.contains(case.name)) {
            skipped += 1;
            continue;
        }

        if (case.invalid_selector) {
            var parser = jsonpath.parser.JPQueryParser.init(case.selector, allocator);
            const jspath = parser.parse();
            if (jspath) |*q| {
                @constCast(q).deinit(allocator);
                std.debug.print(" ------- {s} -------\n", .{case.name});
                std.debug.print("{s}\n", .{"expected parse to fail but it succeeded"});
            } else |_| {
                passed += 1;
            }
        } else {
            const source = if (case.document) |doc|
                try jsonValueToSource(allocator, doc)
            else
                try allocator.dupe(u8, "null");

            defer allocator.free(source);

            const v = jsonpath.text_query(source, case.selector, allocator);
            if (v) |value| {
                var res = value;
                defer res.deinit();
                const results = res.results;
                const values = try allocator.alloc(*std.json.Value, results.len);
                defer allocator.free(values);
                for (results, 0..) |jp, i| {
                    values[i] = jp.json;
                }

                const ok = if (case.result) |r|
                    compareValueSlices(r.array.items, values)
                else if (case.results) |rs| blk: {
                    var any_match = false;
                    for (rs.array.items) |item| {
                        if (compareValueSlices(item.array.items, values)) {
                            any_match = true;
                            break;
                        }
                    }
                    break :blk any_match;
                } else false;

                if (ok) {
                    passed += 1;
                } else {
                    std.debug.print(" ------- {s} -------\n", .{case.name});
                    std.debug.print("{s}\n", .{"result mismatch"});

                    if (case.result) |r| {
                        std.debug.print("Expected:\n", .{});
                        for (r.array.items) |item| {
                            std.debug.print("  {f}\n", .{
                                std.json.fmt(item, .{ .whitespace = .indent_2 }),
                            });
                        }
                    }

                    std.debug.print("Actual:\n", .{});
                    for (values) |item| {
                        std.debug.print("  {f}\n", .{
                            std.json.fmt(item.*, .{ .whitespace = .indent_2 }),
                        });
                    }

                }
            } else |err| {
                std.debug.print(" ------- {s} -------\n", .{case.name});
                std.debug.print("query error: {s}\n", .{@errorName(err)});
            }
        }
    }


    std.debug.print("\n-----------\n", .{});
    std.debug.print("Total:   {d}\n", .{total});
    std.debug.print("Passed:  {d}\n", .{passed});
    std.debug.print("Failed:  {d}\n", .{total - passed - skipped});
    std.debug.print("Skipped: {d}\n", .{skipped});
    std.debug.print("-----------\n", .{});
}

fn compareValueSlices(a: []const std.json.Value, b: []const *std.json.Value) bool {
    if (a.len != b.len) return false;
    for (a, b) |val_a, ptr_b| {
        if (!jsonValueEql(val_a, ptr_b.*)) return false;
    }
    return true;
}

fn jsonValueEql(a: std.json.Value, b: std.json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |v| v == b.bool,
        .integer => |v| v == b.integer,
        .float => |v| @abs(v - b.float) < 0.0001,
        .string => |v| std.mem.eql(u8, v, b.string),
        .number_string => |v| std.mem.eql(u8, v, b.number_string),
        .array => |v| blk: {
            if (v.items.len != b.array.items.len) break :blk false;
            for (v.items, b.array.items) |x, y| {
                if (!jsonValueEql(x, y)) break :blk false;
            }
            break :blk true;
        },
        .object => |v| blk: {
            if (v.count() != b.object.count()) break :blk false;
            var it = v.iterator();
            while (it.next()) |entry| {
                const bval = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!jsonValueEql(entry.value_ptr.*, bval)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn jsonValueToSource(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    var stringifier: std.json.Stringify = .{
        .writer = &out.writer,
        .options = .{},
    };

    try stringifier.write(value);

    return try out.toOwnedSlice();
}
