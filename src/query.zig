const std = @import("std");

const Segment = union(enum) {
    root, // $
};

const JPQuery = struct { segments: []Segment };

const ParseError = error{
    UnexpectedChar,
    UnexpectedEnd,
    InvalidIndex,
};

fn parse(input: []const u8) ParseError!JPQuery {
    input = input;
    return ParseError.UnexpectedEnd;
}
