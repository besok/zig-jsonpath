const std = @import("std");
const q = @import("query.zig");

pub const JPQuery = struct {
    segments: []Segment,

    pub fn deinit(self: *JPQuery, allocator: std.mem.Allocator) void {
        for (self.segments) |*seg| seg.deinit(allocator);
        allocator.free(self.segments);
    }
    pub fn eql(self: JPQuery, other: JPQuery) bool {
        if (self.segments.len != other.segments.len) return false;
        for (self.segments, other.segments) |a, b| {
            if (!a.eql(b)) return false;
        }
        return true;
    }
    pub fn query(self: *JPQuery, iteration: *q.JsonPathIter) !void {
        var iter = iteration;
        try iter.append(iter.root, "$");
        for (self.segments) |seg| {
            try seg.query(iter);
        }
    }
};

pub const Segment = union(enum) {
    descendant: *Segment,
    selector: Selector,
    selectors: []Selector,

    pub fn deinit(self: *Segment, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .descendant => |s| {
                s.deinit(allocator);
                allocator.destroy(s);
            },
            .selector => |*s| s.deinit(allocator),
            .selectors => |ss| {
                for (ss) |*s| s.deinit(allocator);
                allocator.free(ss);
            },
        }
    }
    pub fn eql(self: Segment, other: Segment) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .selector => |v| v.eql(other.selector),
            .descendant => |v| v.eql(other.descendant.*),
            .selectors => |vs| blk: {
                if (vs.len != other.selectors.len) break :blk false;
                for (vs, other.selectors) |a, b| {
                    if (!a.eql(b)) break :blk false;
                }
                break :blk true;
            },
        };
    }
    pub fn query(self: Segment, iteration: *q.JsonPathIter) !void {
        switch (self) {
            .selector => |s| try s.query(iteration),
            .selectors => |_| {},
            .descendant => |_| {},
        }
    }
};

pub const Selector = union(enum) {
    name: []const u8,
    wildcard,
    index: i64,
    slice: Slice,
    filter: Filter,

    pub fn deinit(self: *Selector, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .name => |n| allocator.free(n),
            .filter => |*f| f.deinit(allocator),
            else => {},
        }
    }
    pub fn eql(self: Selector, other: Selector) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .wildcard => true,
            .name => |v| std.mem.eql(u8, v, other.name),
            .index => |v| v == other.index,
            .slice => |v| v.eql(other.slice),
            .filter => |v| v.eql(other.filter),
        };
    }

    pub fn query(self: Selector, iteration: *q.JsonPathIter) !void {
        switch (self) {
            .wildcard => {
                try queryWildcard(iteration);
            },
            .name => |n| {
                try queryName(n, iteration);
            },
            .index => |i| {
                try queryIndex(i, iteration);
            },
            .slice => |_| {},
            .filter => |_| {},
        }
    }
};

fn queryName(name: []const u8, iteration: *q.JsonPathIter) !void {
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
fn queryIndex(index: i64, iteration: *q.JsonPathIter) !void {
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
fn queryWildcard(iteration: *q.JsonPathIter) !void {
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

/// Creates a Selector from a value. Usage:
///
///   sel(wildcard)        → .wildcard          (pass the `wildcard` sentinel: `pub const wildcard = {};`)
///   sel("foo")           → .name("foo")        (string literal or []const u8)
///   sel(1)               → .index(1)           (integer)
///   sel(slice(1, 2, 3))  → .slice(1, 2, 3)    (use the `slice()` helper)
///   sel(myFilter)        → .filter(myFilter)   (model.Filter value)
pub fn sel(value: anytype) Selector {
    const T = @TypeOf(value);
    if (T == void) return .wildcard;
    if (T == Filter) return .{ .filter = value };
    if (T == Slice) return .{ .slice = value };
    return switch (@typeInfo(T)) {
        .int, .comptime_int => .{ .index = @as(i64, @intCast(value)) },
        .pointer, .array => .{ .name = value },
        else => @compileError("Unsupported type for sel()"),
    };
}

pub const Slice = struct {
    start: ?i64,
    end: ?i64,
    step: ?i64,

    pub fn eql(self: Slice, other: Slice) bool {
        return self.start == other.start and
            self.end == other.end and
            self.step == other.step;
    }
};
pub fn slice(start: ?i64, end: ?i64, step: ?i64) Slice {
    return .{ .start = start, .end = end, .step = step };
}

pub const Filter = union(enum) {
    ors: []Filter,
    ands: []Filter,
    atom: FilterAtom,

    pub fn deinit(self: *Filter, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ors => |fs| {
                for (fs) |*f| f.deinit(allocator);
                allocator.free(fs);
            },
            .ands => |fs| {
                for (fs) |*f| f.deinit(allocator);
                allocator.free(fs);
            },
            .atom => |*a| a.deinit(allocator),
        }
    }
    pub fn eql(self: Filter, other: Filter) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .atom => |v| v.eql(other.atom),
            .ors => |vs| blk: {
                if (vs.len != other.ors.len) break :blk false;
                for (vs, other.ors) |a, b| {
                    if (!a.eql(b)) break :blk false;
                }
                break :blk true;
            },
            .ands => |vs| blk: {
                if (vs.len != other.ands.len) break :blk false;
                for (vs, other.ands) |a, b| {
                    if (!a.eql(b)) break :blk false;
                }
                break :blk true;
            },
        };
    }
};

pub fn filterCmp(c: Comparison) Filter {
    return .{ .atom = .{ .compare = c } };
}

pub fn filterOr(filters: []Filter) Filter {
    return .{ .ors = filters };
}

pub fn filterAnd(filters: []Filter) Filter {
    return .{ .ands = filters };
}

pub const FilterAtom = union(enum) {
    filter: struct { expr: *Filter, not: bool },
    test_expr: struct { expr: *Test, not: bool },
    compare: Comparison,

    pub fn deinit(self: *FilterAtom, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .filter => |f| {
                f.expr.deinit(allocator);
                allocator.destroy(f.expr);
            },
            .test_expr => |t| {
                t.expr.deinit(allocator);
                allocator.destroy(t.expr);
            },
            .compare => |*c| c.deinit(allocator),
        }
    }
    pub fn eql(self: FilterAtom, other: FilterAtom) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .filter => |v| v.not == other.filter.not and v.expr.eql(other.filter.expr.*),
            .test_expr => |v| v.not == other.test_expr.not and v.expr.eql(other.test_expr.expr.*),
            .compare => |v| v.eql(other.compare),
        };
    }
};

pub const Test = union(enum) {
    abs_query: JPQuery,
    rel_query: []Segment,
    function: TestFunction,

    pub fn deinit(self: *Test, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .abs_query => |*query| query.deinit(allocator),
            .rel_query => |ss| {
                for (ss) |*s| s.deinit(allocator);
                allocator.free(ss);
            },
            .function => |*f| f.deinit(allocator),
        }
    }
    pub fn eql(self: Test, other: Test) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .abs_query => |v| v.eql(other.abs_query),
            .function => |v| v.eql(other.function),
            .rel_query => |vs| blk: {
                if (vs.len != other.rel_query.len) break :blk false;
                for (vs, other.rel_query) |a, b| {
                    if (!a.eql(b)) break :blk false;
                }
                break :blk true;
            },
        };
    }
};

pub const TestFunction = union(enum) {
    custom: struct { name: []const u8, args: []FnArg },
    length: struct { arg: FnArg },
    value: struct { arg: FnArg },
    count: struct { arg: FnArg },
    search: struct { lhs: FnArg, rhs: FnArg },
    match: struct { lhs: FnArg, rhs: FnArg },

    pub fn deinit(self: *TestFunction, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .custom => |c| {
                allocator.free(c.name);
                for (c.args) |*a| a.deinit(allocator);
                allocator.free(c.args);
            },
            .length => |*f| f.arg.deinit(allocator),
            .value => |*f| f.arg.deinit(allocator),
            .count => |*f| f.arg.deinit(allocator),
            .search => |*f| {
                f.lhs.deinit(allocator);
                f.rhs.deinit(allocator);
            },
            .match => |*f| {
                f.lhs.deinit(allocator);
                f.rhs.deinit(allocator);
            },
        }
    }
    pub fn eql(self: TestFunction, other: TestFunction) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .length => |v| v.arg.eql(other.length.arg),
            .value => |v| v.arg.eql(other.value.arg),
            .count => |v| v.arg.eql(other.count.arg),
            .search => |v| v.lhs.eql(other.search.lhs) and v.rhs.eql(other.search.rhs),
            .match => |v| v.lhs.eql(other.match.lhs) and v.rhs.eql(other.match.rhs),
            .custom => |v| blk: {
                if (!std.mem.eql(u8, v.name, other.custom.name)) break :blk false;
                if (v.args.len != other.custom.args.len) break :blk false;
                for (v.args, other.custom.args) |a, b| {
                    if (!a.eql(b)) break :blk false;
                }
                break :blk true;
            },
        };
    }
};

pub const FnArg = union(enum) {
    lit: Literal,
    test_arg: *Test,
    filter: *Filter,

    pub fn deinit(self: *FnArg, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .lit => |*l| l.deinit(allocator),
            .test_arg => |t| {
                t.deinit(allocator);
                allocator.destroy(t);
            },
            .filter => |f| {
                f.deinit(allocator);
                allocator.destroy(f);
            },
        }
    }
    pub fn eql(self: FnArg, other: FnArg) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .lit => |v| v.eql(other.lit),
            .test_arg => |v| v.eql(other.test_arg.*),
            .filter => |v| v.eql(other.filter.*),
        };
    }
};

pub const Literal = union(enum) {
    int: i64,
    float: f64,
    str: []const u8,
    bool: bool,
    null,

    pub fn deinit(self: *Literal, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .str => |s| allocator.free(s),
            else => {},
        }
    }
    pub fn eql(self: Literal, other: Literal) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .int => |v| v == other.int,
            .float => |v| @abs(v - other.float) < 0.01,
            .str => |v| std.mem.eql(u8, v, other.str),
            .bool => |v| v == other.bool,
            .null => true,
        };
    }
};

pub fn lit(value: anytype) Literal {
    const T = @TypeOf(value);
    if (T == @TypeOf(null)) return .null;
    if (T == bool) return .{ .bool = value };
    return switch (@typeInfo(T)) {
        .comptime_int, .int => .{ .int = @as(i64, @intCast(value)) },
        .comptime_float, .float => .{ .float = @as(f64, @floatCast(value)) },
        .pointer => .{ .str = value },
        else => @compileError("Unsupported type for Literal"),
    };
}

pub const BinaryOp = struct {
    lhs: Comparable,
    rhs: Comparable,

    pub fn deinit(self: *BinaryOp, allocator: std.mem.Allocator) void {
        self.lhs.deinit(allocator);
        self.rhs.deinit(allocator);
    }
};

pub const Comparison = union(enum) {
    eq: BinaryOp,
    ne: BinaryOp,
    gt: BinaryOp,
    gte: BinaryOp,
    lt: BinaryOp,
    lte: BinaryOp,

    pub fn deinit(self: *Comparison, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*op| op.deinit(allocator),
        }
    }
    pub fn eql(self: Comparison, other: Comparison) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        switch (self) {
            inline else => |v, tag| {
                const o = @field(other, @tagName(tag));
                return v.lhs.eql(o.lhs) and v.rhs.eql(o.rhs);
            },
        }
    }
};

pub fn eq(lhs: Comparable, rhs: Comparable) Comparison {
    return .{ .eq = .{ .lhs = lhs, .rhs = rhs } };
}
pub fn ne(lhs: Comparable, rhs: Comparable) Comparison {
    return .{ .ne = .{ .lhs = lhs, .rhs = rhs } };
}
pub fn gt(lhs: Comparable, rhs: Comparable) Comparison {
    return .{ .gt = .{ .lhs = lhs, .rhs = rhs } };
}
pub fn lt(lhs: Comparable, rhs: Comparable) Comparison {
    return .{ .lt = .{ .lhs = lhs, .rhs = rhs } };
}
pub fn gte(lhs: Comparable, rhs: Comparable) Comparison {
    return .{ .gte = .{ .lhs = lhs, .rhs = rhs } };
}
pub fn lte(lhs: Comparable, rhs: Comparable) Comparison {
    return .{ .lte = .{ .lhs = lhs, .rhs = rhs } };
}

pub const Comparable = union(enum) {
    lit: Literal,
    function: TestFunction,
    query: SingularQuery,

    pub fn deinit(self: *Comparable, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .lit => |*l| l.deinit(allocator),
            .function => |*f| f.deinit(allocator),
            .query => |*query| query.deinit(allocator),
        }
    }
    pub fn eql(self: Comparable, other: Comparable) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .lit => |v| v.eql(other.lit),
            .function => |v| v.eql(other.function),
            .query => |v| v.eql(other.query),
        };
    }
};
pub fn cmp(value: anytype) Comparable {
    const T = @TypeOf(value);
    if (T == Literal) return .{ .lit = value };
    if (T == SingularQuery) return .{ .query = value };
    if (T == TestFunction) return .{ .function = value };
    @compileError("Unsupported type for comparable(): " ++ @typeName(T));
}

pub const SingularQuery = union(enum) {
    current: []SingularQuerySegment,
    root: []SingularQuerySegment,

    pub fn deinit(self: *SingularQuery, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |ss| {
                for (ss) |*s| s.deinit(allocator);
                allocator.free(ss);
            },
        }
    }
    pub fn eql(self: SingularQuery, other: SingularQuery) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        const self_segs = switch (self) {
            inline else => |v| v,
        };
        const other_segs = switch (other) {
            inline else => |v| v,
        };
        if (self_segs.len != other_segs.len) return false;
        for (self_segs, other_segs) |a, b| {
            if (!a.eql(b)) return false;
        }
        return true;
    }
};

pub const SingularQuerySegment = union(enum) {
    index: i64,
    name: []const u8,

    pub fn deinit(self: *SingularQuerySegment, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .name => |n| allocator.free(n),
            .index => {},
        }
    }
    pub fn eql(self: SingularQuerySegment, other: SingularQuerySegment) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .name => |v| std.mem.eql(u8, v, other.name),
            .index => |v| v == other.index,
        };
    }
};

/// Creates a SingularQuerySegment from a value. Usage:
///
///   sqs(1)     → .index(1)   (integer)
///   sqs("foo") → .name("foo") (string literal or []const u8)
pub fn sqs(value: anytype) SingularQuerySegment {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .pointer, .array => .{ .name = value },
        .int, .comptime_int => .{ .index = @as(i64, @intCast(value)) },
        else => @compileError("Unsupported type for sqs(): " ++ @typeName(T)),
    };
}

pub const MAX_INT: i64 = 9007199254740991; // 2^53 - 1, maximum safe integer in JavaScript
pub const MIN_INT: i64 = -9007199254740991; // -(2^53 - 1), minimum safe integer in JavaScript

pub fn isValidInt(value: i64) bool {
    return value >= MIN_INT and value <= MAX_INT;
}
