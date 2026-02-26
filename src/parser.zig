const std = @import("std");
const model = @import("model.zig");

pub const JPQueryParser = struct {
    input: []const u8,
    allocator: std.mem.Allocator,
    pos: usize = 0,
    err_desc: []const u8 = "Unexpected error",

    const Error = error{
        UnexpectedChar,
        UnexpectedEnd,
        InvalidIndex,
        ExpectedRoot,
    };
    pub fn errorMsg(self: *JPQueryParser) ![]const u8 {
        const window = 20;
        const pos = @min(self.pos, self.input.len);

        const start = if (pos > window) pos - window else 0;
        const end = @min(pos + window, self.input.len);

        const before = self.input[start..pos];
        const after = self.input[pos..end];

        const left_ellipsis = if (start > 0) "..." else "";
        const right_ellipsis = if (end < self.input.len) "..." else "";

        const left_pad = left_ellipsis.len + before.len;

        var caret_buf: [64]u8 = undefined;
        @memset(caret_buf[0..left_pad], ' ');
        caret_buf[left_pad] = '^';

        const caret_line = caret_buf[0 .. left_pad + 1];

        return std.fmt.allocPrint(self.allocator,
            \\{s}, position = {d}
            \\{s}{s}{s}{s}
            \\{s}
        , .{
            self.err_desc,
            self.pos,
            left_ellipsis,
            before,
            after,
            right_ellipsis,
            caret_line,
        });
    }

    pub fn printThenFail(self: *JPQueryParser, err: anyerror) !void {
        const msg = try self.errorMsg();
        defer self.allocator.free(msg);
        std.debug.print("{s}\n", .{msg});
        return err;
    }

    pub fn init(input: []const u8, allocator: std.mem.Allocator) JPQueryParser {
        return .{ .input = input, .allocator = allocator };
    }

    pub fn parse(self: *JPQueryParser) !model.JPQuery {
        try self.expect('$', "Expected '$' at start of JSONPath query");
        const segments = try self.parseSegments();
        if (!self.isEnd()) return self.fail("Unexpected input after query");
        return .{ .segments = segments };
    }

    fn fail(self: *JPQueryParser, reason: []const u8) Error {
        self.err_desc = reason;
        return Error.UnexpectedChar;
    }

    fn peek(self: *JPQueryParser) ?u8 {
        if (self.pos >= self.input.len) return null;
        return self.input[self.pos];
    }

    fn move(self: *JPQueryParser, n: usize) !void {
        if (self.pos + n <= self.input.len) {
            self.pos += n;
        } else {
            return Error.UnexpectedEnd;
        }
    }

    fn take(self: *JPQueryParser) ?u8 {
        const ch = self.peek() orelse return null;
        self.pos += 1;
        return ch;
    }

    fn is(self: *JPQueryParser, ch: u8) bool {
        if (self.peek() == ch) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn expect(self: *JPQueryParser, ch: u8, desc: ?[]const u8) Error!void {
        if (!self.is(ch)) {
            self.err_desc = desc orelse "Unexpected Character";
            return Error.UnexpectedChar;
        }
    }

    fn rest(self: *JPQueryParser) []const u8 {
        return self.input[self.pos..];
    }

    fn isEnd(self: *JPQueryParser) bool {
        return self.pos >= self.input.len;
    }

    fn parseString(self: *JPQueryParser) ![]const u8 {
        const quote = self.peek() orelse return self.fail("Unexpected String Literal");
        if (quote != '"' and quote != '\'') return self.fail("The Quote is expected");
        try self.move(1); // consume opening quote

        var buf: std.ArrayList(u8) = .empty;

        while (self.peek()) |ch| {
            if (ch == quote) {
                try self.move(1);
                return buf.toOwnedSlice(self.allocator);
            }

            if (ch == '\\') {
                try self.move(1);
                const escaped = self.take() orelse return self.fail("The String ends unexpectedly");

                const unescaped: u8 = switch (escaped) {
                    'b' => '\x08',
                    'f' => '\x0C',
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    '/' => '/',
                    '\\' => '\\',
                    '"' => '"',
                    '\'' => '\'',
                    'u' => {
                        const codepoint = try self.parseHexChar();
                        try self.appendUtf8(&buf, codepoint);
                        continue;
                    },
                    else => return self.fail("Invalid Escape Sequence"),
                };
                try buf.append(self.allocator, unescaped);
            } else if (isUnescaped(ch, quote)) {
                try buf.append(self.allocator, ch);
                try self.move(1);
            } else {
                return self.fail("Invalid Character");
            }
        }

        return self.fail("Unterminated String");
    }

    fn parseHexChar(self: *JPQueryParser) !u21 {
        var codepoint: u21 = 0;

        var i: u8 = 0;
        while (i < 4) : (i += 1) {
            const ch = self.take() orelse return self.fail("Incomplete Unicode Escape");
            const digit = self.parseHexDigit(ch) orelse return self.fail("Invalid Hex Digit");
            codepoint = (codepoint << 4) | digit;
        }

        // handle surrogate pairs
        if (codepoint >= 0xD800 and codepoint <= 0xDBFF) {
            // high surrogate
            if (!self.is('\\')) return self.fail("Incomplete Surrogate Pair");
            if (!self.is('u')) return self.fail("Expected \\u after High Surrogate");

            var low: u21 = 0;
            i = 0;
            while (i < 4) : (i += 1) {
                const ch = self.take() orelse return self.fail("Incomplete Unicode Escape");
                const digit = self.parseHexDigit(ch) orelse return self.fail("Invalid Hex Digit");
                low = (low << 4) | digit;
            }

            if (low < 0xDC00 or low > 0xDFFF) return self.fail("Invalid Low Surrogate");
            codepoint = 0x10000 + ((codepoint - 0xD800) << 10) + (low - 0xDC00);
        }

        return codepoint;
    }

    fn parseHexDigit(self: *JPQueryParser, ch: u8) ?u21 {
        _ = self;
        return switch (ch) {
            '0'...'9' => ch - '0',
            'a'...'f' => ch - 'a' + 10,
            'A'...'F' => ch - 'A' + 10,
            else => null,
        };
    }

    fn appendUtf8(self: *JPQueryParser, buf: *std.ArrayList(u8), codepoint: u21) !void {
        var bytes: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &bytes) catch {
            return error.InvalidCodepoint;
        };
        try buf.appendSlice(self.allocator, bytes[0..len]);
    }

    fn parseMemberName(self: *JPQueryParser) ![]const u8 {
        const start = self.pos;

        const first = self.peek() orelse return self.fail("Expected Identifier");
        if (!isNameFirst(first)) return self.fail("Invalid Identifier");
        try self.move(1);

        while (self.peek()) |ch| {
            if (!isNameChar(ch)) break;
            try self.move(1);
        }

        return self.allocator.dupe(u8, self.input[start..self.pos]);
    }

    fn parseNumber(self: *JPQueryParser) !model.Literal {
        const start = self.pos;
        var is_float = false;

        if (self.is('-')) {
            if (self.is('0')) {
                // "-0" - must be followed by frac or exp to be valid
                if (self.peek() != '.' and self.peek() != 'e' and self.peek() != 'E') {
                    return .{ .int = 0 };
                }
            }
        }

        if (!self.is('0')) {
            if (!std.ascii.isDigit(self.peek() orelse 0)) {
                return self.fail("Expected Digit");
            }
            while (self.peek()) |ch| {
                if (!std.ascii.isDigit(ch)) break;
                try self.move(1);
            }
        }

        if (self.is('.')) {
            is_float = true;
            if (!std.ascii.isDigit(self.peek() orelse 0)) {
                return self.fail("Expected Digit after Decimal");
            }
            while (self.peek()) |ch| {
                if (!std.ascii.isDigit(ch)) break;
                try self.move(1);
            }
        }

        if (self.peek() == 'e' or self.peek() == 'E') {
            is_float = true;
            try self.move(1);
            _ = self.is('+') or self.is('-');
            if (!std.ascii.isDigit(self.peek() orelse 0)) {
                return self.fail("Expected Digit in Exponent");
            }
            while (self.peek()) |ch| {
                if (!std.ascii.isDigit(ch)) break;
                try self.move(1);
            }
        }

        const num_str = self.input[start..self.pos];

        if (is_float) {
            const val = std.fmt.parseFloat(f64, num_str) catch {
                return self.fail("Invalid Float");
            };
            return .{ .float = val };
        } else {
            const val = std.fmt.parseInt(i64, num_str, 10) catch {
                return self.fail("Invalid Integer");
            };
            if (!model.isValidInt(val)) return self.fail("Integer exceeds safe JavaScript Range");
            return .{ .int = val };
        }
    }

    pub fn parseLiteral(self: *JPQueryParser) !model.Literal {
        try self.skipWhitespace();

        const ch = self.peek() orelse return self.fail("Expected iteral");

        if (ch == '"' or ch == '\'') {
            const s = try self.parseString();
            return .{ .str = s };
        }

        if (std.ascii.isDigit(ch) or ch == '-') {
            return try self.parseNumber();
        }

        if (self.matchStr("true")) return .{ .bool = true };
        if (self.matchStr("false")) return .{ .bool = false };
        if (self.matchStr("null")) return .null;

        return self.fail("expected literal");
    }

    fn matchStr(self: *JPQueryParser, s: []const u8) bool {
        if (self.pos + s.len > self.input.len) return false;
        if (!std.mem.eql(u8, self.input[self.pos .. self.pos + s.len], s)) return false;
        self.pos += s.len;
        return true;
    }

    fn skipWhitespace(self: *JPQueryParser) !void {
        while (self.peek()) |ch| {
            switch (ch) {
                ' ', '\t', '\r', '\n' => try self.move(1),
                else => break,
            }
        }
    }
    pub fn parseFunctionExpr(self: *JPQueryParser) anyerror!model.TestFunction {
        if (self.matchStr("length")) return .{ .length = .{ .arg = try self.parseOneArg() } };
        if (self.matchStr("value")) return .{ .value = .{ .arg = try self.parseOneArg() } };
        if (self.matchStr("count")) return .{ .count = .{ .arg = try self.parseOneArg() } };
        if (self.matchStr("search")) return try self.parseTwoArgFn(.search);
        if (self.matchStr("match")) return try self.parseTwoArgFn(.match);

        const name = try self.parseMemberName();
        var args = std.ArrayListUnmanaged(model.FnArg){};
        errdefer {
            for (args.items) |*a| a.deinit(self.allocator);
            args.deinit(self.allocator);
        }

        try self.expect('(', "Expected '(' after function name");
        try self.skipWhitespace();

        if (!self.is(')')) {
            try args.append(self.allocator, try self.parseFnArg());
            try self.skipWhitespace();
            while (self.is(',')) {
                try self.skipWhitespace();
                try args.append(self.allocator, try self.parseFnArg());
                try self.skipWhitespace();
            }
            try self.expect(')', "Expected ')' to close function arguments");
        }

        return .{ .custom = .{ .name = name, .args = try args.toOwnedSlice(self.allocator) } };
    }

    fn parseOneArg(self: *JPQueryParser) !model.FnArg {
        try self.expect('(', "Expected '('");
        try self.skipWhitespace();
        const arg = try self.parseFnArg();
        try self.skipWhitespace();
        try self.expect(')', "Expected ')'");
        return arg;
    }

    fn parseTwoArgFn(self: *JPQueryParser, comptime tag: anytype) !model.TestFunction {

        try self.expect('(', "Expected '('");
        try self.skipWhitespace();
        var lhs = try self.parseFnArg();
        errdefer lhs.deinit(self.allocator);
        try self.skipWhitespace();
        try self.expect(',', "Expected ',' between arguments");
        try self.skipWhitespace();
        const rhs = try self.parseFnArg();
        try self.skipWhitespace();
        try self.expect(')', "Expected ')'");
        return @unionInit(model.TestFunction, @tagName(tag), .{ .lhs = lhs, .rhs = rhs });
    }

    fn parseFnArg(self: *JPQueryParser) !model.FnArg {
        const saved_pos = self.pos;
        const saved_desc = self.err_desc;

        if (self.parseLiteral()) |lit| {
            return .{ .lit = lit };
        } else |_| {
            self.pos = saved_pos;
            self.err_desc = saved_desc;
        }

        if (self.peek() == '(' or self.peek() == '!') {
            const f = try self.allocator.create(model.Filter);
            errdefer self.allocator.destroy(f);
            f.* = try self.parseFilter();
            return .{ .filter = f };
        }

        const t = try self.allocator.create(model.Test);
        errdefer self.allocator.destroy(t);
        t.* = try self.parseTest();
        return .{ .test_arg = t };
    }

    fn restStartsWith(self: *JPQueryParser, s: []const u8) bool {
        return std.mem.startsWith(u8, self.rest(), s);
    }

    pub fn parseSegments(self: *JPQueryParser) ![]model.Segment {
        var segments = std.ArrayListUnmanaged(model.Segment){};
        errdefer {
            for (segments.items) |*s| s.deinit(self.allocator);
            segments.deinit(self.allocator);
        }

        try self.skipWhitespace();
        while (self.peek()) |ch| {
            if (ch != '.' and ch != '[') break;
            const seg = try self.parseSegment();
            try segments.append(self.allocator, seg);
            try self.skipWhitespace();
        }

        return segments.toOwnedSlice(self.allocator);
    }

    fn parseSegment(self: *JPQueryParser) !model.Segment {
        if (self.restStartsWith("..")) {
            try self.move(2);
            const inner = try self.parseDescendantInner();
            const ptr = try self.allocator.create(model.Segment);
            errdefer self.allocator.destroy(ptr);
            ptr.* = inner;
            return .{ .descendant = ptr };
        }

        if (self.peek() == '.') {
            try self.move(1);
            return try self.parseChildDot();
        }

        if (self.peek() == '[') {
            return try self.parseBracketedSelection();
        }

        return self.fail("Expected segment");
    }

    fn parseDescendantInner(self: *JPQueryParser) !model.Segment {
        if (self.peek() == '[') return try self.parseBracketedSelection();
        if (self.peek() == '*') {
            try self.move(1);
            return .{ .selector = .wildcard };
        }
        const name = try self.parseMemberName();
        return .{ .selector = .{ .name = name } };
    }

    fn parseChildDot(self: *JPQueryParser) !model.Segment {
        if (self.peek() == '*') {
            try self.move(1);
            return .{ .selector = .wildcard };
        }
        const name = try self.parseMemberName();
        return .{ .selector = .{ .name = name } };
    }

    fn parseBracketedSelection(self: *JPQueryParser) !model.Segment {
        try self.expect('[', "Expected '['");
        try self.skipWhitespace();

        var selectors = std.ArrayListUnmanaged(model.Selector){};
        errdefer {
            for (selectors.items) |*s| s.deinit(self.allocator);
            selectors.deinit(self.allocator);
        }

        const first = try self.parseSelector();
        try selectors.append(self.allocator, first);
        try self.skipWhitespace();

        while (self.is(',')) {
            try self.skipWhitespace();
            const sel = try self.parseSelector();
            try selectors.append(self.allocator, sel);
            try self.skipWhitespace();
        }

        try self.expect(']', "Expected ']'");

        // single selector -> .selector, multiple -> .selectors
        if (selectors.items.len == 1) {
            const sel = selectors.items[0];
            selectors.deinit(self.allocator);
            return .{ .selector = sel };
        }

        return .{ .selectors = try selectors.toOwnedSlice(self.allocator) };
    }

    fn parseSelector(self: *JPQueryParser) !model.Selector {
        const ch = self.peek() orelse return self.fail("Expected selector");

        if (ch == '*') {
            try self.move(1);
            return .wildcard;
        }

        if (ch == '?') {
            try self.move(1);
            try self.skipWhitespace();
            const f = try self.parseFilter();
            return .{ .filter = f };
        }

        if (ch == '"' or ch == '\'') {
            const s = try self.parseString();
            return .{ .name = s };
        }

        if (ch == '-' or std.ascii.isDigit(ch) or ch == ':') {
            return try self.parseIndexOrSlice();
        }

        if (isNameFirst(ch)) {
            const name = try self.parseMemberName();
            return .{ .name = name };
        }

        return self.fail("Unexpected selector");
    }

    pub fn parseIndexOrSlice(self: *JPQueryParser) !model.Selector {
        if (self.peek() == ':') {
            try self.move(1);
            return try self.parseSliceTail(null);
        }

        const int_val = try self.parseSliceInt();

        try self.skipWhitespace();

        if (self.is(':')) {
            return try self.parseSliceTail(int_val);
        }

        return .{ .index = int_val };
    }

    fn parseSliceInt(self: *JPQueryParser) !i64 {
        const start = self.pos;
        const is_neg = self.is('-');
        if (!std.ascii.isDigit(self.peek() orelse 0)) {
            self.pos = start;
            return self.fail("Expected integer");
        }
        if (is_neg and self.peek() == '0') {
            self.pos = start;
            return self.fail("Negative zero is not valid in slice/index");
        }

        while (self.peek()) |c| {
            if (!std.ascii.isDigit(c)) break;
            try self.move(1);
        }
        const s = self.input[start..self.pos];
        const val = std.fmt.parseInt(i64, s, 10) catch return self.fail("Invalid integer");
        if (!model.isValidInt(val)) return self.fail("Integer exceeds safe JavaScript range");
        return val;
    }

    pub fn parseSliceTail(self: *JPQueryParser, start: ?i64) !model.Selector {
        try self.skipWhitespace();

        var end: ?i64 = null;
        if (self.peek() != ':' and self.peek() != ']' and self.peek() != null) {
            if (self.peek() == '-' or std.ascii.isDigit(self.peek() orelse 0)) {
                end = try self.parseSliceInt();
                try self.skipWhitespace();
            }
        }

        var step: ?i64 = null;
        if (self.is(':')) {
            try self.skipWhitespace();
            if (self.peek() == '-' or std.ascii.isDigit(self.peek() orelse 0)) {
                step = try self.parseSliceInt();
            }
        }

        return .{ .slice = .{ .start = start, .end = end, .step = step } };
    }
    pub fn parseFilter(self: *JPQueryParser) !model.Filter {
        return try self.parseLogicalOr();
    }

    fn parseLogicalOr(self: *JPQueryParser) anyerror!model.Filter {
        var items = std.ArrayListUnmanaged(model.Filter){};
        errdefer {
            for (items.items) |*f| f.deinit(self.allocator);
            items.deinit(self.allocator);
        }

        const first = try self.parseLogicalAnd();
        try items.append(self.allocator, first);

        try self.skipWhitespace();
        while (self.restStartsWith("||")) {
            try self.move(2);
            try self.skipWhitespace();
            const next = try self.parseLogicalAnd();
            try items.append(self.allocator, next);
            try self.skipWhitespace();
        }

        if (items.items.len == 1) {
            const single = items.items[0];
            items.deinit(self.allocator);
            return single;
        }

        return .{ .ors = try items.toOwnedSlice(self.allocator) };
    }

    fn parseLogicalAnd(self: *JPQueryParser) !model.Filter {
        var items = std.ArrayListUnmanaged(model.Filter){};
        errdefer {
            for (items.items) |*f| f.deinit(self.allocator);
            items.deinit(self.allocator);
        }

        const first = try self.parseAtom();
        try items.append(self.allocator, first);

        try self.skipWhitespace();
        while (self.restStartsWith("&&")) {
            try self.move(2);
            try self.skipWhitespace();
            const next = try self.parseAtom();
            try items.append(self.allocator, next);
            try self.skipWhitespace();
        }

        if (items.items.len == 1) {
            const single = items.items[0];
            items.deinit(self.allocator);
            return single;
        }

        return .{ .ands = try items.toOwnedSlice(self.allocator) };
    }

    fn parseAtom(self: *JPQueryParser) !model.Filter {
        const not = self.is('!');
        try self.skipWhitespace();

        if (self.peek() == '(') {
            try self.move(1);
            try self.skipWhitespace();
            const inner = try self.parseLogicalOr();
            try self.skipWhitespace();
            try self.expect(')', "Expected ')'");

            const ptr = try self.allocator.create(model.Filter);
            errdefer self.allocator.destroy(ptr);
            ptr.* = inner;
            return .{ .atom = .{ .filter = .{ .expr = ptr, .not = not } } };
        }

        const saved_pos = self.pos;
        const saved_desc = self.err_desc;

        if (try self.tryCompExpr(not)) |filter| return filter;

        self.pos = saved_pos;
        self.err_desc = saved_desc;

        return try self.parseTestExpr(not);
    }

    fn tryCompExpr(self: *JPQueryParser, not: bool) !?model.Filter {
        _ = not;
        const lhs = self.parseComparable() catch return null;

        try self.skipWhitespace();
        const op = (try self.parseCompOp()) orelse {
            var lhs_mut = lhs;
            lhs_mut.deinit(self.allocator);
            return null;
        };

        try self.skipWhitespace();
        var lhs_mut = lhs;
        errdefer lhs_mut.deinit(self.allocator);
        const rhs = try self.parseComparable();

        const bin = model.BinaryOp{ .lhs = lhs_mut, .rhs = rhs };
        const cmp: model.Comparison = switch (op) {
            .eq => .{ .eq = bin },
            .ne => .{ .ne = bin },
            .lt => .{ .lt = bin },
            .lte => .{ .lte = bin },
            .gt => .{ .gt = bin },
            .gte => .{ .gte = bin },
        };
        return .{ .atom = .{ .compare = cmp } };
    }

    const CompOp = enum { eq, ne, lt, lte, gt, gte };

    fn parseCompOp(self: *JPQueryParser) !?CompOp {
        if (self.restStartsWith("==")) {
            try self.move(2);
            return .eq;
        }
        if (self.restStartsWith("!=")) {
            try self.move(2);
            return .ne;
        }
        if (self.restStartsWith("<=")) {
            try self.move(2);
            return .lte;
        }
        if (self.restStartsWith(">=")) {
            try self.move(2);
            return .gte;
        }
        if (self.restStartsWith("<")) {
            try self.move(1);
            return .lt;
        }
        if (self.restStartsWith(">")) {
            try self.move(1);
            return .gt;
        }
        return null;
    }

    pub fn parseComparable(self: *JPQueryParser) !model.Comparable {
        const saved_pos = self.pos;
        const saved_desc = self.err_desc;

        if (self.parseLiteral()) |l| {
            return .{ .lit = l };
        } else |_| {
            self.pos = saved_pos;
            self.err_desc = saved_desc;
        }

        const ch = self.peek() orelse return self.fail("Expected comparable");

        if (ch == '@' or ch == '$') {
            return .{ .query = try self.parseSingularQuery() };
        }

        return .{ .function = try self.parseFunctionExpr() };
    }

    fn parseTestExpr(self: *JPQueryParser, not: bool) !model.Filter {
        const t = try self.allocator.create(model.Test);
        errdefer self.allocator.destroy(t);
        t.* = try self.parseTest();
        return .{ .atom = .{ .test_expr = .{ .expr = t, .not = not } } };
    }

    fn parseTest(self: *JPQueryParser) !model.Test {
        const ch = self.peek() orelse return self.fail("Expected test");

        if (ch == '@') {
            try self.move(1);
            const segs = try self.parseSegments();
            return .{ .rel_query = segs };
        }

        if (ch == '$') {
            try self.move(1);
            const segs = try self.parseSegments();
            return .{ .abs_query = .{ .segments = segs } };
        }

        return .{ .function = try self.parseFunctionExpr() };
    }

    pub fn parseSingularQuery(self: *JPQueryParser) !model.SingularQuery {
        const ch = self.peek() orelse return self.fail("Expected singular query");

        if (ch == '@') {
            try self.move(1);
            const segs = try self.parseSingularQuerySegments();
            return .{ .current = segs };
        }

        if (ch == '$') {
            try self.move(1);
            const segs = try self.parseSingularQuerySegments();
            return .{ .root = segs };
        }

        return self.fail("Expected '@' or '$'");
    }

    pub fn parseSingularQuerySegments(self: *JPQueryParser) ![]model.SingularQuerySegment {
        var segs = std.ArrayListUnmanaged(model.SingularQuerySegment){};
        errdefer {
            for (segs.items) |*s| s.deinit(self.allocator);
            segs.deinit(self.allocator);
        }

        try self.skipWhitespace();
        while (self.peek()) |ch| {
            if (ch == '[') {
                const seg = try self.parseBracketedSingularSegment();
                try segs.append(self.allocator, seg);
            } else if (ch == '.') {
                try self.move(1);
                const name = try self.parseMemberName();
                try segs.append(self.allocator, .{ .name = name });
            } else {
                break;
            }
            try self.skipWhitespace();
        }

        return segs.toOwnedSlice(self.allocator);
    }

    fn parseBracketedSingularSegment(self: *JPQueryParser) !model.SingularQuerySegment {
        try self.expect('[', "Expected '['");
        try self.skipWhitespace();

        const ch = self.peek() orelse return self.fail("Expected name or index");

        if (std.ascii.isDigit(ch) or ch == '-') {
            const val = try self.parseSliceInt();
            try self.skipWhitespace();
            try self.expect(']', "Expected ']'");
            return .{ .index = val };
        }

        if (ch == '"' or ch == '\'') {
            const name = try self.parseString();
            try self.skipWhitespace();
            try self.expect(']', "Expected ']'");
            return .{ .name = name };
        }

        return self.fail("Expected name or index in singular query segment");
    }
};

fn isNameFirst(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or
        ch == '_' or
        ch >= 0x80; // simplified: includes 0x80..0xD7FF and 0xE000..0x10FFFF
}

fn isNameChar(ch: u8) bool {
    return isNameFirst(ch) or std.ascii.isDigit(ch);
}

fn isUnescaped(ch: u8, quote: u8) bool {
    return switch (ch) {
        0x00...0x1F => false, // control characters
        '\\' => false, // backslash always escaped
        '"' => quote != '"', // allowed unescaped only inside '...'
        '\'' => quote != '\'', // allowed unescaped only inside "..."
        0x20...0x21, // space, !
        0x23...0x26, // # $ % &
        0x28...0x5B, // ( through [
        0x5D...0x7F,
        => true, // ] through DEL
        else => ch >= 0x80, // non-ASCII
    };
}
