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
        try self.move(); // consume opening quote

        var buf: std.ArrayList(u8) = .empty;

        while (self.peek()) |ch| {
            if (ch == quote) {
                try self.move(); // consume closing quote
                return buf.toOwnedSlice(self.allocator);
            }

            if (ch == '\\') {
                try self.move(); // consume backslash
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
                try self.move();
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
            const digit = self.hexDigit(ch) orelse return self.fail("Invalid Hex Digit");
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
                const digit = self.hexDigit(ch) orelse return self.fail("Invalid Hex Digit");
                low = (low << 4) | digit;
            }

            if (low < 0xDC00 or low > 0xDFFF) return self.fail("Invalid Low Surrogate");
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

    fn parseMemberName(self: *JPQueryParser) ![]const u8 {
        const start = self.pos;

        const first = self.peek() orelse return self.fail("Expected Identifier");
        if (!self.isNameFirst(first)) return self.fail("Invalid Identifier");
        try self.move();

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
            // safe_int: non-zero digit followed by more digits
            if (!std.ascii.isDigit(self.peek() orelse 0)) {
                return self.fail("Expected Digit");
            }
            while (self.peek()) |ch| {
                if (!std.ascii.isDigit(ch)) break;
                try self.move();
            }
        }

        if (self.is('.')) {
            is_float = true;
            if (!std.ascii.isDigit(self.peek() orelse 0)) {
                return self.fail("Expected Digit after Decimal");
            }
            while (self.peek()) |ch| {
                if (!std.ascii.isDigit(ch)) break;
                try self.move();
            }
        }

        if (self.peek() == 'e' or self.peek() == 'E') {
            is_float = true;
            try self.move();
            _ = self.is('+') or self.is('-');
            if (!std.ascii.isDigit(self.peek() orelse 0)) {
                return self.fail("Expected Digit in Exponent");
            }
            while (self.peek()) |ch| {
                if (!std.ascii.isDigit(ch)) break;
                try self.move();
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
    return switch (ch) {
        0x00...0x1F => false,           // control characters
        '\\' => false,                  // backslash always escaped
        '"' => quote != '"',            // allowed unescaped only inside '...'
        '\'' => quote != '\'',          // allowed unescaped only inside "..."
        0x20...0x21,                    // space, !
        0x23...0x26,                    // # $ % &
        0x28...0x5B,                    // ( through [
        0x5D...0x7F => true,            // ] through DEL
        else => ch >= 0x80,             // non-ASCII
    };
}
