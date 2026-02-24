const std = @import("std");

pub const JPQuery = struct {
    segments: []Segment,

    pub fn deinit(self: *JPQuery, allocator: std.mem.Allocator) void {
        for (self.segments) |*seg| seg.deinit(allocator);
        allocator.free(self.segments);
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
};

/// Creates a Selector from a value. Usage:
///
///   sel(wildcard)        → .wildcard          (pass the `wildcard` sentinel: `pub const wildcard = {};`)
///   sel("foo")           → .name("foo")        (string literal or []const u8)
///   sel(1)               → .index(1)           (integer)
///   sel(slice(1, 2, 3))  → .slice(1, 2, 3)    (use the `slice()` helper)
///   sel(myFilter)        → .filter(myFilter)   (model.Filter value)
pub fn sel(value: anytype) Selector {
    const T = @TypeOf(value);
    if (T == void)         return .wildcard;
    if (T == Filter) return .{ .filter = value };
    if (T == Slice)  return .{ .slice = value };
    return switch (@typeInfo(T)) {
        .int, .comptime_int => .{ .index = @as(i64, @intCast(value)) },
        .pointer, .array    => .{ .name = value },
        else => @compileError("Unsupported type for sel()"),
    };
}

pub const Slice = struct {
    start: ?i64,
    end: ?i64,
    step: ?i64,
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
};

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
};

pub const Test = union(enum) {
    abs_query: JPQuery,
    rel_query: []Segment,
    function: TestFunction,

    pub fn deinit(self: *Test, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .abs_query => |*q| q.deinit(allocator),
            .rel_query => |ss| {
                for (ss) |*s| s.deinit(allocator);
                allocator.free(ss);
            },
            .function => |*f| f.deinit(allocator),
        }
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
};

pub const Comparable = union(enum) {
    lit: Literal,
    function: TestFunction,
    query: SingularQuery,

    pub fn deinit(self: *Comparable, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .lit => |*l| l.deinit(allocator),
            .function => |*f| f.deinit(allocator),
            .query => |*q| q.deinit(allocator),
        }
    }
};

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
};

pub const MAX_INT: i64 = 9007199254740991; // 2^53 - 1, maximum safe integer in JavaScript
pub const MIN_INT: i64 = -9007199254740991; // -(2^53 - 1), minimum safe integer in JavaScript

pub fn isValidInt(value: i64) bool {
    return value >= MIN_INT and value <= MAX_INT;
}
