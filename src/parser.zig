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

    pub fn init(input: []const u8, allocator: std.mem.Allocator) JPQueryParser {
        return .{ .input = input, .allocator = allocator };
    }

    fn fail(self: *JPQueryParser, reason: []const u8) Error {
        self.err_desc = reason;
        return Error.UnexpectedChar;
    }

    fn peek(self: *JPQueryParser) ?u8 {
        if (self.pos >= self.input.len) return null;
        return self.input[self.pos];
    }

    fn move(self: *JPQueryParser) !void {
        if (self.pos < self.input.len) self.pos += 1 else return Error.UnexpectedEnd;
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
            self.err_desc = desc orelse "unexpected character";
            return Error.UnexpectedChar;
        }
    }

    fn rest(self: *JPQueryParser) []const u8 {
        return self.input[self.pos..];
    }

    fn isEnd(self: *JPQueryParser) bool {
        return self.pos >= self.input.len;
    }

    // --- String parsing ---

    fn parseString(self: *JPQueryParser) ![]const u8 {
        const quote = self.peek() orelse return self.fail("expected string");
        if (quote != '"' and quote != '\'') return self.fail("expected quote");
        try self.move(); // consume opening quote

        var buf: std.ArrayList(u8) = .empty;

        while (self.peek()) |ch| {
            if (ch == quote) {
                try self.move(); // consume closing quote
                return buf.toOwnedSlice(self.allocator);
            }

            if (ch == '\\') {
                try self.move(); // consume backslash
                const escaped = self.take() orelse return self.fail("unexpected end in string");

                const unescaped:u8 = switch (escaped) {
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
                    else => return self.fail("invalid escape sequence"),
                };
                try buf.append(self.allocator,unescaped);
            } else if (isUnescaped(ch, quote)) {
                try buf.append(self.allocator,ch);
                try self.move();
            } else {
                return self.fail("invalid character in string");
            }
        }

        return self.fail("unterminated string");
    }

    fn parseHexChar(self: *JPQueryParser) !u21 {
        var codepoint: u21 = 0;

        // read 4 hex digits
        var i: u8 = 0;
        while (i < 4) : (i += 1) {
            const ch = self.take() orelse return self.fail("incomplete unicode escape");
            const digit = self.hexDigit(ch) orelse return self.fail("invalid hex digit");
            codepoint = (codepoint << 4) | digit;
        }

        // handle surrogate pairs
        if (codepoint >= 0xD800 and codepoint <= 0xDBFF) {
            // high surrogate
            if (!self.is('\\')) return self.fail("incomplete surrogate pair");
            if (!self.is('u')) return self.fail("expected \\u after high surrogate");

            var low: u21 = 0;
            i = 0;
            while (i < 4) : (i += 1) {
                const ch = self.take() orelse return self.fail("incomplete unicode escape");
                const digit = self.hexDigit(ch) orelse return self.fail("invalid hex digit");
                low = (low << 4) | digit;
            }

            if (low < 0xDC00 or low > 0xDFFF) return self.fail("invalid low surrogate");

            // decode surrogate pair
            codepoint = 0x10000 + ((codepoint - 0xD800) << 10) + (low - 0xDC00);
        }

        return codepoint;
    }

    fn hexDigit(self: *JPQueryParser, ch: u8) ?u21 {
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

    // --- Member name shorthand ---

    fn parseMemberName(self: *JPQueryParser) ![]const u8 {
        const start = self.pos;

        // name_first
        const first = self.peek() orelse return self.fail("expected identifier");
        if (!self.isNameFirst(first)) return self.fail("invalid identifier start");
        try self.move();

        // name_char*
        while (self.peek()) |ch| {
            if (!self.isNameChar(ch)) break;
            try self.move();
        }

        return self.input[start..self.pos];
    }

    fn isNameFirst(self: *JPQueryParser, ch: u8) bool {
        _ = self;
        return std.ascii.isAlphabetic(ch) or
            ch == '_' or
            ch >= 0x80; // simplified: includes 0x80..0xD7FF and 0xE000..0x10FFFF
    }

    fn isNameChar(self: *JPQueryParser, ch: u8) bool {
        return self.isNameFirst(ch) or std.ascii.isDigit(ch);
    }

    // --- Number parsing ---

    fn parseNumber(self: *JPQueryParser) !model.Literal {
        const start = self.pos;
        var is_float = false;

        // optional minus or "-0"
    if (self.is('-')) {
            if (self.is('0')) {
                // "-0" - must be followed by frac or exp to be valid
            if (self.peek() != '.' and self.peek() != 'e' and self.peek() != 'E') {
                    return .{ .int = 0 };
                }
            }
        }

        // int part (if not already consumed "-0")
    if (!self.is('0')) {
            // safe_int: non-zero digit followed by more digits
        if (!std.ascii.isDigit(self.peek() orelse 0)) {
                return self.fail("expected digit");
            }
            while (self.peek()) |ch| {
                if (!std.ascii.isDigit(ch)) break;
                try self.move();
            }
        }

        // frac?
    if (self.is('.')) {
            is_float = true;
            if (!std.ascii.isDigit(self.peek() orelse 0)) {
                return self.fail("expected digit after decimal");
            }
            while (self.peek()) |ch| {
                if (!std.ascii.isDigit(ch)) break;
                try self.move();
            }
        }

        // exp?
    if (self.peek() == 'e' or self.peek() == 'E') {
            is_float = true;
            try self.move();
            _ = self.is('+') or self.is('-');
            if (!std.ascii.isDigit(self.peek() orelse 0)) {
                return self.fail("expected digit in exponent");
            }
            while (self.peek()) |ch| {
                if (!std.ascii.isDigit(ch)) break;
                try self.move();
            }
        }

        const num_str = self.input[start..self.pos];

        if (is_float) {
            const val = std.fmt.parseFloat(f64, num_str) catch {
                return self.fail("invalid float");
            };
            return .{ .float = val };
        } else {
            const val = std.fmt.parseInt(i64, num_str, 10) catch {
                return self.fail("invalid integer");
            };
            if (!model.isValidInt(val)) return self.fail("integer exceeds safe JavaScript range");
            return .{ .int = val };
        }
    }

    // --- Literal parsing ---

    pub fn parseLiteral(self: *JPQueryParser) !model.Literal {
        try self.skipWhitespace();

        const ch = self.peek() orelse return self.fail("expected literal");

        // string
        if (ch == '"' or ch == '\'') {
            const s = try self.parseString();
            return .{ .str = s };
        }

        // number
        if (std.ascii.isDigit(ch) or ch == '-') {
            return try self.parseNumber();
        }

        // bool
        if (self.matchStr("true")) return .{ .bool = true };
        if (self.matchStr("false")) return .{ .bool = false };

        // null
        if (self.matchStr("null")) return .null;

        return self.fail("expected literal");
    }

    fn matchStr(self: *JPQueryParser, s: []const u8) bool {
        if (self.pos + s.len > self.input.len) return false;
        if (!std.mem.eql(u8, self.input[self.pos .. self.pos + s.len], s)) return false;
        self.pos += s.len;
        return true;
    }

    // --- Whitespace ---

    fn skipWhitespace(self: *JPQueryParser) !void {
        while (self.peek()) |ch| {
            switch (ch) {
                ' ', '\t', '\r', '\n' => try self.move(),
                else => break,
            }
        }
    }

    pub fn parse(self: *JPQueryParser) Error!model.JPQuery {
        try self.expect('$', null);
        return model.JPQuery{ .segments = &[_]model.Segment{} };
    }
};

fn isUnescaped(ch: u8, quote: u8) bool {
    // unescaped chars based on quote type
    if (quote == '"') {
        // double_quoted: unescaped | "\'" | ESC ~ "\"" | ESC ~ escapable
        return (ch >= 0x20 and ch <= 0x21) or
            (ch >= 0x23 and ch <= 0x26) or
            (ch >= 0x28 and ch <= 0x5B) or
            (ch >= 0x5D and ch <= 0x7F) or
            (ch >= 0x80); // non-ASCII
    } else {
        // single_quoted: unescaped | "\"" | ESC ~ "\'" | ESC ~ escapable
        return (ch >= 0x20 and ch <= 0x21) or
            (ch >= 0x23 and ch <= 0x26) or
            (ch >= 0x28 and ch <= 0x5B) or
            (ch >= 0x5D and ch <= 0x7F) or
            (ch >= 0x80); // non-ASCII
    }
}
