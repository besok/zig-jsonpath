//! A pure Zig implementation of JSONPath.

const std = @import("std");

/// Core data structures representing JSONPath tokens and evaluation results.
pub const model = @import("model.zig");

/// The parsing engine that converts a JSONPath string (e.g., `$.store.book[*].author`) 
/// into an executable internal representation.
pub const parser = @import("parser.zig");

/// The execution engine that applies a parsed JSONPath expression against a `std.json.Value` tree.
pub const query = @import("query.zig");

/// Evaluates a JSONPath query directly against a raw JSON string.
///
/// This is a high-level convenience function that combines JSON parsing, 
/// JSONPath parsing, and query execution into a single step.
///
/// **Parameters:**
/// - `source`: A slice containing the raw, unparsed JSON data (e.g., `{"a": 1}`).
/// - `path`: A slice containing the JSONPath query string (e.g., `$.a`).
/// - `allocator`: The memory allocator used for parsing the JSON tree, allocating 
///   the JSONPath AST, and constructing the final result.
///
/// **Returns:**
/// A `query.JsonPathResult` containing the matched JSON values.
///
/// **Memory Management & Caller Responsibility:**
/// Because this function parses the `source` string into a `std.json.Parsed(std.json.Value)`, 
/// the caller takes ownership of the returned `JsonPathResult`. If `JsonPathResult` retains 
/// pointers to the parsed JSON, the caller must ensure the result is properly deinitialized 
/// (e.g., by calling `result.deinit()`) to prevent memory leaks.
pub fn query_str(
    source: []const u8,
    path: []const u8,
    allocator: std.mem.Allocator,
) !query.JsonPathResult {
    var json = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        source,
        .{},
    );
    errdefer json.deinit();

    var jq_parser = parser.JPQueryParser.init(path, allocator);

    var jp_path = try jq_parser.parse();
    defer jp_path.deinit(allocator);

    return try query.perform(&json, &jp_path, allocator);
}