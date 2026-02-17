const std = @import("std");

pub const JPQuery = struct { segments: []Segment };

pub const Segment = union(enum) {
    descendant: *Segment,
    selector: Selector,
    selectors: []Selector,
};
pub const Selector = union(enum) {
    name: []const u8,
    wildcard,
    index: i64,
    slice: Slice,
    filter: Filter,
};
pub const Slice = struct {
    start: ?i64,
    end: ?i64,
    step: ?i64,
};
pub const Filter = union(enum) {
    ors: []Filter,
    ands: []Filter,
    atom: FilterAtom,
};

pub const FilterAtom = union(enum) {
    filter: struct { expr: *Filter, not: bool },
    test_expr: struct { expr: Test, not: bool },
    compare: Comparison,
};

pub const Test = union(enum) {
    abs_query: JPQuery,
    rel_query: []Segment,
    function: TestFunction,
};

pub const TestFunction = union(enum) {
    custom: struct { name: []const u8, args: []FnArg },
    length: struct { arg: FnArg },
    value: struct { arg: FnArg },
    count: struct { arg: FnArg },
    search: struct { lhs: FnArg, rhs: FnArg },
    match: struct { lhs: FnArg, rhs: FnArg },
};

pub const FnArg = union(enum) {
    lit: Literal,
    test_arg: *Test,
    filter: *Filter,
};

pub const Literal = union(enum) {
    int: i64,
    float: f64,
    str: []const u8,
    bool: bool,
    null,
};

pub const BinaryOp = struct {
    lhs: Comparable,
    rhs: Comparable,
};

pub const Comparison = union(enum) {
    eq: BinaryOp,
    ne: BinaryOp,
    gt: BinaryOp,
    gte: BinaryOp,
    lt: BinaryOp,
    lte: BinaryOp,
};

pub const Comparable = union(enum) {
    lit: Literal,
    function: TestFunction,
    query: SingularQuery,
};

pub const SingularQuery = union(enum) {
    current: []SingularQuerySegment,
    root: []SingularQuerySegment,
};

pub const SingularQuerySegment = union(enum) {
    index: i64,
    name: []const u8,
};
