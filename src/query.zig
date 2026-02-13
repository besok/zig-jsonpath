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
    filter: struct { expr: Filter, not: bool },
    validate: struct { expr: Validate, not: bool },
    compare: Comparison,
};

const JPQueryParser = struct {
    input: []const u8,
    pos: usize = 0,

    const Error = error{
        UnexpectedChar,
        UnexpectedEnd,
        InvalidIndex,
        ExpectedRoot,
    };

    fn init(input: []const u8) JPQueryParser {
        return .{ .input = input };
    }

    fn peek(self: *JPQueryParser) ?u8 {
        if (self.pos >= self.input.len) return null;
        return self.input[self.pos];
    }

    fn step(self: *JPQueryParser) !void {
        if (self.pos < self.input.len) self.pos += 1 else return Error.UnexpectedEnd;
    }

    fn eat(self: *JPQueryParser) ?u8 {
        const ch = self.peek() orelse return null;
        self.step();
        return ch;
    }

    fn match(self: *JPQueryParser, ch: u8) bool {
        if (self.peek() == ch) {
            self.step();
            return true;
        }
        return false;
    }

    fn expect(self: *JPQueryParser, ch: u8) Error!void {
        if (!self.match(ch)) {
            return self.fail("unexpected character");
        }
    }

    fn rest(self: *JPQueryParser) []const u8 {
        return self.input[self.pos..];
    }

    fn isEnd(self: *JPQueryParser) bool {
        return self.pos >= self.input.len;
    }
};
