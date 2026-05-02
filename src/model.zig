const std = @import("std");
const q = @import("query.zig");
const Iter = q.JsonPathIter;
const inner = @import("model_query.zig");

const debug_query = @import("build_options").debug_query;

inline fn dbg(comptime fmt: []const u8, args: anytype) void {
    if (debug_query) std.debug.print(fmt, args);
}

fn debugCursors(label: []const u8, iter: *Iter) void {
    if (!debug_query) return;
    std.debug.print("[{s}] {d} cursors:\n", .{ label, iter.cursors.items.len });
    for (iter.cursors.items) |c| {
        std.debug.print("  path={s} value={f}\n", .{
            c.path,
            std.json.fmt(c.json.*, .{}),
        });
    }
}

fn debugJsValues(a: std.json.Value, b: std.json.Value) void {
    if (!debug_query) return;
    std.debug.print("lhs:\n{f}\n", .{
        std.json.fmt(a, .{ .whitespace = .indent_2 }),
    });

    std.debug.print("rhs:\n{f}\n", .{
        std.json.fmt(b, .{ .whitespace = .indent_2 }),
    });
}

fn debugCursorsAt(iter: *Iter) void {
    debugCursors("CURSORS", iter);
}

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
    pub fn query(self: *const JPQuery, iteration: *Iter) !void {
        var iter = iteration;
        dbg("[JPQuery] start, cursors: {d}\n", .{iter.cursors.items.len});
        try iter.append(iter.root, "$");
        for (self.segments) |seg| {
            try seg.query(iter);
        }
        dbg("[JPQuery] end, cursors: {d}\n", .{iter.cursors.items.len});
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
    pub fn query(self: Segment, iteration: *Iter) !void {
        dbg("[Segment] tag={s}, cursors before: {d}\n", .{ @tagName(self), iteration.cursors.items.len });
        switch (self) {
            .selector => |s| try s.query(iteration),
            .selectors => |ss| {
                var next = std.ArrayListUnmanaged(q.JsonPointer){};
                errdefer {
                    for (next.items) |*p| p.deinit(iteration.allocator);
                    next.deinit(iteration.allocator);
                }

                for (ss) |s| {
                    var branch = Iter.init(iteration.root, iteration.allocator);
                    defer branch.deinit();
                    for (iteration.cursors.items) |p| {
                        const duped = try iteration.allocator.dupe(u8, p.path);
                        errdefer iteration.allocator.free(duped);
                        try branch.cursors.append(iteration.allocator, .{ .json = p.json, .path = duped });
                    }
                    try s.query(&branch);
                    for (branch.cursors.items) |p| {
                        const duped = try iteration.allocator.dupe(u8, p.path);
                        errdefer iteration.allocator.free(duped);
                        try next.append(iteration.allocator, .{ .json = p.json, .path = duped });
                    }
                }

                for (iteration.cursors.items) |*p| p.deinit(iteration.allocator);
                iteration.cursors.deinit(iteration.allocator);
                iteration.cursors = next;
            },
            .descendant => |s| {
                try inner.queryDescendant(iteration);
                try s.query(iteration);
            },
        }
        dbg("[Segment] tag={s}, cursors after: {d}\n", .{ @tagName(self), iteration.cursors.items.len });
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

    pub fn query(self: Selector, iteration: *Iter) !void {
        dbg("[Selector] tag={s}, cursors before: {d}\n", .{ @tagName(self), iteration.cursors.items.len });
        switch (self) {
            .wildcard => try inner.queryWildcard(iteration),
            .name => |n| {
                dbg("[Selector.name] name={s}\n", .{n});
                try inner.queryName(n, iteration);
            },
            .index => |i| {
                dbg("[Selector.index] index={d}\n", .{i});
                try inner.queryIndex(i, iteration);
            },
            .slice => |slce| try inner.querySlice(slce, iteration),
            .filter => |f| {
                var next = std.ArrayListUnmanaged(q.JsonPointer){};
                errdefer {
                    for (next.items) |*p| p.deinit(iteration.allocator);
                    next.deinit(iteration.allocator);
                }

                for (iteration.cursors.items) |cursor| {
                    switch (cursor.json.*) {
                        .array => |arr| {
                            for (arr.items, 0..) |*elem, i| {
                                const path = try std.fmt.allocPrint(
                                    iteration.allocator,
                                    "{s}[{d}]",
                                    .{ cursor.path, i },
                                );
                                errdefer iteration.allocator.free(path);
                                try next.append(iteration.allocator, .{ .json = elem, .path = path });
                            }
                        },
                        .object => |obj| {
                            var it = obj.iterator();
                            while (it.next()) |entry| {
                                const path = try std.fmt.allocPrint(
                                    iteration.allocator,
                                    "{s}['{s}']",
                                    .{ cursor.path, entry.key_ptr.* },
                                );
                                errdefer iteration.allocator.free(path);
                                try next.append(iteration.allocator, .{ .json = entry.value_ptr, .path = path });
                            }
                        },
                        else => {},
                    }
                }

                for (iteration.cursors.items) |*p| p.deinit(iteration.allocator);
                iteration.cursors.deinit(iteration.allocator);
                iteration.cursors = next;

                try f.query(iteration);
            },
        }
        dbg("[Selector] tag={s}, cursors after: {d}\n", .{ @tagName(self), iteration.cursors.items.len });
    }
};

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

    pub fn query(self: Filter, iteration: *Iter) anyerror!void {
        dbg("[Filter] tag={s}, cursors before: {d}\n", .{ @tagName(self), iteration.cursors.items.len });
        switch (self) {
            .atom => |a| try a.query(iteration),
            .ands => |fs| {
                for (fs) |f| try f.query(iteration);
            },
            .ors => |fs| {
                var next = std.ArrayListUnmanaged(q.JsonPointer){};
                errdefer {
                    for (next.items) |*p| p.deinit(iteration.allocator);
                    next.deinit(iteration.allocator);
                }

                for (fs) |f| {
                    var branch = try iteration.fork();
                    defer branch.deinit();
                    try f.query(&branch);
                    for (branch.cursors.items) |p| {
                        const duped = try iteration.allocator.dupe(u8, p.path);
                        errdefer iteration.allocator.free(duped);
                        try next.append(iteration.allocator, .{ .json = p.json, .path = duped });
                    }
                }

                for (iteration.cursors.items) |*p| p.deinit(iteration.allocator);
                iteration.cursors.deinit(iteration.allocator);
                iteration.cursors = next;
            },
        }
        dbg("[Filter] tag={s}, cursors after: {d}\n", .{ @tagName(self), iteration.cursors.items.len });
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

    pub fn query(self: FilterAtom, iteration: *Iter) anyerror!void {
        dbg("[FilterAtom] tag={s}, cursors before: {d}\n", .{ @tagName(self), iteration.cursors.items.len });
        switch (self) {
            .filter => |f| {
                var passing = std.ArrayListUnmanaged(q.JsonPointer){};
                errdefer {
                    for (passing.items) |*p| p.deinit(iteration.allocator);
                    passing.deinit(iteration.allocator);
                }

                for (iteration.cursors.items) |cursor| {
                    var branch = try iteration.forkSingle(cursor);
                    defer branch.deinit();
                    try f.expr.query(&branch);

                    const survived = branch.cursors.items.len > 0;
                    const passes = if (f.not) !survived else survived;
                    dbg("[FilterAtom.filter] path={s} survived={} not={} passes={}\n", .{ cursor.path, survived, f.not, passes });
                    if (passes) {
                        const duped = try iteration.allocator.dupe(u8, cursor.path);
                        errdefer iteration.allocator.free(duped);
                        try passing.append(iteration.allocator, .{ .json = cursor.json, .path = duped });
                    }
                }

                for (iteration.cursors.items) |*p| p.deinit(iteration.allocator);
                iteration.cursors.deinit(iteration.allocator);
                iteration.cursors = passing;
            },
            .test_expr => |t| {
                var passing = std.ArrayListUnmanaged(q.JsonPointer){};
                errdefer {
                    for (passing.items) |*p| p.deinit(iteration.allocator);
                    passing.deinit(iteration.allocator);
                }

                for (iteration.cursors.items) |cursor| {
                    var branch = try iteration.forkSingle(cursor);
                    defer branch.deinit();
                    try t.expr.query(&branch);

                    const exists = branch.cursors.items.len > 0;
                    const passes = if (t.not) !exists else exists;
                    dbg("[FilterAtom.test_expr] path={s} exists={} not={} passes={}\n", .{ cursor.path, exists, t.not, passes });
                    if (passes) {
                        const duped = try iteration.allocator.dupe(u8, cursor.path);
                        errdefer iteration.allocator.free(duped);
                        try passing.append(iteration.allocator, .{ .json = cursor.json, .path = duped });
                    }
                }

                for (iteration.cursors.items) |*p| p.deinit(iteration.allocator);
                iteration.cursors.deinit(iteration.allocator);
                iteration.cursors = passing;
            },
            .compare => |c| {
                var passing = std.ArrayListUnmanaged(q.JsonPointer){};
                errdefer {
                    for (passing.items) |*p| p.deinit(iteration.allocator);
                    passing.deinit(iteration.allocator);
                }

                for (iteration.cursors.items) |cursor| {
                    var branch = try iteration.forkSingle(cursor);
                    defer branch.deinit();
                    const result = try c.evaluate(&branch);
                    dbg("[FilterAtom.compare] path={s}\n", .{cursor.path});
                    if (result) {
                        const duped = try iteration.allocator.dupe(u8, cursor.path);
                        errdefer iteration.allocator.free(duped);
                        try passing.append(iteration.allocator, .{ .json = cursor.json, .path = duped });
                    }
                }

                for (iteration.cursors.items) |*p| p.deinit(iteration.allocator);
                iteration.cursors.deinit(iteration.allocator);
                iteration.cursors = passing;
            },
        }
        dbg("[FilterAtom] tag={s}, cursors after: {d}\n", .{ @tagName(self), iteration.cursors.items.len });
    }
};

pub const Test = union(enum) {
    abs_query: JPQuery,
    rel_query: []Segment,
    function: TestFunction,

    pub fn deinit(self: *Test, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .abs_query => |*jpq| jpq.deinit(allocator),
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
    pub fn query(self: Test, iteration: *Iter) anyerror!void {
        dbg("[Test] tag={s}, cursors before: {d}\n", .{ @tagName(self), iteration.cursors.items.len });
        switch (self) {
            .abs_query => |jpq| {
                for (iteration.cursors.items) |*p| p.deinit(iteration.allocator);
                iteration.cursors.clearRetainingCapacity();
                try jpq.query(iteration);
            },
            .rel_query => |segments| {
                for (segments) |seg| try seg.query(iteration);
            },
            .function => |f| {
                const val = try f.evaluate(iteration);
                dbg("[Test.function] evaluate result: {any}\n", .{val});
                const passes = if (val) |v| switch (v) {
                    .bool => |b| b,
                    else => true,
                } else false;

                if (!passes) {
                    for (iteration.cursors.items) |*p| p.deinit(iteration.allocator);
                    iteration.cursors.clearRetainingCapacity();
                }
            },
        }
        dbg("[Test] tag={s}, cursors after: {d}\n", .{ @tagName(self), iteration.cursors.items.len });
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

    pub fn evaluate(self: TestFunction, iter: *Iter) !?std.json.Value {
        dbg("[TestFunction] evaluating tag={s}\n", .{@tagName(self)});
        const result = switch (self) {
            .length => |v| try inner.queryLength(v.arg, iter),
            .value => |v| try inner.queryValue(v.arg, iter),
            .count => |v| try inner.queryCount(v.arg, iter),
            .search => |v| try inner.querySearch(v.lhs, v.rhs, iter),
            .match => |v| try inner.queryMatch(v.lhs, v.rhs, iter),
            .custom => |v| try inner.queryCustom(v.name, v.args, iter),
        };
        dbg("[TestFunction] tag={s}\n", .{
            @tagName(self),
        });
        return result;
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
    pub fn toJsValue(self: Literal) std.json.Value {
        return switch (self) {
            .int => |v| .{ .integer = v },
            .float => |v| .{ .float = v },
            .str => |v| .{ .string = v },
            .bool => |v| .{ .bool = v },
            .null => .null,
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
    pub fn evaluate(self: Comparison, iter: *Iter) !bool {
        const op = switch (self) {
            inline else => |v| v,
        };
        const lhs = try op.lhs.evaluate(iter) orelse {
            dbg("[Comparison.{s}] lhs is null\n", .{@tagName(self)});
            return false;
        };
        const rhs = try op.rhs.evaluate(iter) orelse {
            dbg("[Comparison.{s}] rhs is null\n", .{@tagName(self)});
            return false;
        };
        dbg("[Comparison.{s}]\n", .{@tagName(self)});
        return switch (self) {
            .eq => inner.jsonValueEql(lhs, rhs),
            .ne => !inner.jsonValueEql(lhs, rhs),
            .gt => (inner.jsonValueCmp(lhs, rhs) orelse return false) == .gt,
            .lt => (inner.jsonValueCmp(lhs, rhs) orelse return false) == .lt,
            .gte => (inner.jsonValueCmp(lhs, rhs) orelse return false) != .lt,
            .lte => (inner.jsonValueCmp(lhs, rhs) orelse return false) != .gt,
        };
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
    pub fn evaluate(self: Comparable, iter: *Iter) !?std.json.Value {
        dbg("[Comparable] tag={s}, cursors: {d}\n", .{ @tagName(self), iter.cursors.items.len });
        const result = switch (self) {
            .lit => |l| l.toJsValue(),
            .function => |f| try f.evaluate(iter),
            .query => |sq| blk: {
                var branch = try iter.fork();
                defer branch.deinit();
                try sq.query(&branch);
                dbg("[Comparable.query] branch cursors after sq.query: {d}\n", .{branch.cursors.items.len});
                break :blk if (branch.cursors.items.len == 1) branch.cursors.items[0].json.* else null;
            },
        };
        dbg("[Comparable] tag={s}\n", .{@tagName(self)});
        return result;
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
    pub fn query(self: SingularQuery, iter: *Iter) !void {
        dbg("[SingularQuery] tag={s}, cursors before: {d}\n", .{ @tagName(self), iter.cursors.items.len });
        switch (self) {
            .root => |segs| {
                for (iter.cursors.items) |*p| p.deinit(iter.allocator);
                iter.cursors.clearRetainingCapacity();
                try iter.append(iter.root, "$");
                for (segs) |seg| {
                    try seg.query(iter);
                }
            },
            .current => |segs| {
                for (segs) |seg| {
                    try seg.query(iter);
                }
            },
        }
        dbg("[SingularQuery] tag={s}, cursors after: {d}\n", .{ @tagName(self), iter.cursors.items.len });
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

    pub fn query(self: SingularQuerySegment, iter: *Iter) !void {
        dbg("[SingularQuerySegment] tag={s}, cursors before: {d}\n", .{ @tagName(self), iter.cursors.items.len });
        switch (self) {
            .index => |i| try inner.querySingularQuerySegmentByIndex(i, iter),
            .name => |n| {
                dbg("[SingularQuerySegment.name] name={s}\n", .{n});
                try inner.querySingularQuerySegmentByName(n, iter);
            },
        }
        dbg("[SingularQuerySegment] tag={s}, cursors after: {d}\n", .{ @tagName(self), iter.cursors.items.len });
    }
};

pub fn sqs(value: anytype) SingularQuerySegment {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .pointer, .array => .{ .name = value },
        .int, .comptime_int => .{ .index = @as(i64, @intCast(value)) },
        else => @compileError("Unsupported type for sqs(): " ++ @typeName(T)),
    };
}

pub const MAX_INT: i64 = 9007199254740991;
pub const MIN_INT: i64 = -9007199254740991;

pub fn isValidInt(value: i64) bool {
    return value >= MIN_INT and value <= MAX_INT;
}
