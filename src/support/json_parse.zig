//! Depth-guarded JSON parsing.
//!
//! All nodes of the returned `std.json.Value` tree live in the `arena` allocator passed to
//! `parseJson`; free the entire tree by deinitializing that arena.

const std = @import("std");
const Allocator = std.mem.Allocator;
const recursion_guard = @import("recursion_guard.zig");

pub const ParseError = error{
    DepthExceeded,
    InvalidJson,
    OutOfMemory,
};

/// Parses `text` as JSON into `arena`, rejecting input whose value nesting exceeds
/// `getMaxRecursionDepth()`. Rejects trailing non-whitespace tokens.
pub fn parseJson(arena: Allocator, text: []const u8) ParseError!std.json.Value {
    const max: i64 = @intCast(recursion_guard.getMaxRecursionDepth());
    var depth: i64 = 0;
    var in_string = false;
    var escaped = false;
    for (text) |byte| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }
        switch (byte) {
            '"' => in_string = true,
            '[', '{' => depth += 1,
            ']', '}' => depth -= 1,
            ' ', '\t', '\n', '\r', ',', ':' => continue,
            else => {},
        }
        const value_depth: i64 = if (byte == '[' or byte == '{') depth - 1 else depth;
        if (value_depth > max) {
            return error.DepthExceeded;
        }
    }
    var scanner = std.json.Scanner.initCompleteInput(arena, text);
    defer scanner.deinit();
    const value = std.json.innerParse(std.json.Value, arena, &scanner, .{ .max_value_len = text.len }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    const token = scanner.next() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    if (token != .end_of_document) return error.InvalidJson;
    return value;
}

test "parseJson basic" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const value = try parseJson(a, "{\"a\": [1, 2, 3], \"b\": \"中文\"}");
    try std.testing.expect(value == .object);
    try std.testing.expectEqual(@as(i64, 1), value.object.get("a").?.array.items[0].integer);
    try std.testing.expectEqualStrings("中文", value.object.get("b").?.string);

    const simple = try parseJson(a, "42");
    try std.testing.expectEqual(@as(i64, 42), simple.integer);

    const null_value = try parseJson(a, "null");
    try std.testing.expect(null_value == .null);
}

test "parseJson rejects trailing garbage" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectError(error.InvalidJson, parseJson(a, "{} trailing"));
    try std.testing.expectError(error.InvalidJson, parseJson(a, "1 2"));
    _ = try parseJson(a, "  [1] \n ");
    try std.testing.expectError(error.InvalidJson, parseJson(a, "{"));
    try std.testing.expectError(error.InvalidJson, parseJson(a, "[1,]"));
}

test "parseJson enforces recursion depth" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const old_max = recursion_guard.getMaxRecursionDepth();
    defer recursion_guard.setMaxRecursionDepth(old_max) catch unreachable;
    recursion_guard.setMaxRecursionDepth(3) catch unreachable;

    try std.testing.expectError(error.DepthExceeded, parseJson(a, "[[[[1]]]]"));
    _ = try parseJson(a, "[[[ ]]]");
    _ = try parseJson(a, "[\"\\\"[\\\"\"]");

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(alloc);
    const deep: usize = 10;
    for (0..deep) |_| try buffer.append(alloc, '[');
    try buffer.append(alloc, '1');
    for (0..deep) |_| try buffer.append(alloc, ']');
    recursion_guard.setMaxRecursionDepth(@intCast(deep)) catch unreachable;
    _ = try parseJson(a, buffer.items);
    recursion_guard.setMaxRecursionDepth(@intCast(deep - 1)) catch unreachable;
    try std.testing.expectError(error.DepthExceeded, parseJson(a, buffer.items));
}
