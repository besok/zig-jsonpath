const std = @import("std");

const JPQuery = struct { segments: []Segment };

const Segment = union(enum) {
    descendant: *Segment,
    selector: Selector,
    selectors: []Selector,
};
const Selector = union(enum) {
    name: []const u8,
    wildcard,
    index: i64,
    slice: Slice,
    filter: Filter,
};
const Slice = struct {
    start: ?i64,
    end: ?i64,
    step: ?i64,
};
const Filter = union(enum) {
    ors: []Filter,
    ands: []Filter,
    atom: FilterAtom,
};

const FilterAtom = union(enum) {
    filter: struct { expr: *Filter, not: bool },
    test_expr: struct { expr: Test, not: bool },
    compare: Comparison,
};

const Test = union(enum) {
    abs_query: JPQuery,
    rel_query: []Segment,
    function: TestFunction,
};

const TestFunction = union(enum) {
    custom: struct { name: []const u8, args: []FnArg },
    length: struct { arg: FnArg },
    value: struct { arg: FnArg },
    count: struct { arg: FnArg },
    search: struct { lhs: FnArg, rhs: FnArg },
    match: struct { lhs: FnArg, rhs: FnArg },
};

const FnArg = union(enum) {
    lit: Literal,
    test_arg: *Test,
    filter: *Filter,
};

const Literal = union(enum) {
    int: i64,
    float: f64,
    str: []const u8,
    bool: bool,
    null,
};

const BinaryOp = struct {
    lhs: Comparable,
    rhs: Comparable,
};

const Comparison = union(enum) {
    eq:  BinaryOp,
    ne:  BinaryOp,
    gt:  BinaryOp,
    gte: BinaryOp,
    lt:  BinaryOp,
    lte: BinaryOp,
};


const Comparable = union(enum) {
    lit: Literal,
    function: TestFunction,
    query: SingularQuery,
};

const SingularQuery = union(enum) {
    current: []SingularQuerySegment,
    root: []SingularQuerySegment,
};

const SingularQuerySegment = union(enum) { index: i64, name: []const u8 };
