const std = @import("std");
const jsonpath = @import("jsonpath");
const suite = @import("suite.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cases = try suite.getCases(allocator);
    const filtered_cases = try suite.getCaseFilters(allocator);
    defer {
        filtered_cases.deinit();
        cases.deinit();
    }

    var string_set = std.StringHashMap(suite.CaseFilter).init(allocator);
    defer string_set.deinit();

    for (filtered_cases.value) |case| {
        try string_set.put(case.name, case);
    }
    var total:usize = 0;
    var successfull_cases:usize = 0;
    var skipped_cases:usize = 0;
    var failed_cases = std.array_list.Managed([]const u8).init(allocator);
    defer failed_cases.deinit();

    for (cases.value.tests) |case| {
        total += 1;
        if (string_set.get(case.name)) |filter| {
            std.debug.print("Filter {f}\n", .{filter});
            skipped_cases += 1;
        } else {

            if (case.invalid_selector) {
                var parser = jsonpath.jsp.JPQueryParser.init(case.selector);
                 const jspath = parser.parse();
                if (jspath) |_| {
                    try failed_cases.append(case.name);
                } else |_| {
                    successfull_cases += 1;
                }
            } else {
                const v = jsonpath.text_query(case.name, case.name, allocator);
                if (v) |value| {
                    const results = value.results;
                    if (case.result)|r|{
                        const items = r.array.items;
                        if (compareValueSlices(items, results)) {
                            successfull_cases += 1;
                        } else {
                            try failed_cases.append(case.name);
                        }
                    }
                    else if(case.results)|rs|{
                        var checked = false;
                        const items = rs.array.items;
                        for (items) |item| {
                            const elems = item.array.items;
                            if (compareValueSlices(elems, results)){
                                successfull_cases += 1;
                                checked = true;
                                break;
                            }
                        }
                        if (!checked) {
                            try failed_cases.append(case.name);
                        }
                    }
                } else |_|{
                    try failed_cases.append(case.name);
                }
            }
        }
    }

    std.debug.print("-----------\n", .{});
    std.debug.print("Total:       {d}\n", .{total});
    std.debug.print("Successfull: {d}\n", .{successfull_cases});
    std.debug.print("Failed:      {d}\n", .{failed_cases.items.len});
    std.debug.print("Skipped:     {d}\n", .{skipped_cases});
    std.debug.print("-----------\n", .{});

    // try std.testing.expectEqual( 0, failed_cases.items.len);
}

fn compareValueSlices(a: []const std.json.Value, b: []const *const std.json.Value) bool {
    if (a.len != b.len) return false;

    for (a, b) |val_a, ptr_b| {
        if (!std.meta.eql(val_a, ptr_b.*)) {
            return false;
        }
    }

    return true;
}