const JPQueryParser = struct {
    // input: []const u8,
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
            return Error.UnexpectedChar;
        }
    }

    fn rest(self: *JPQueryParser) []const u8 {
        return self.input[self.pos..];
    }

    fn isEnd(self: *JPQueryParser) bool {
        return self.pos >= self.input.len;
    }
};