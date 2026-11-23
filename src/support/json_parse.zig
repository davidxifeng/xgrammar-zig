//! Depth-guarded JSON parsing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const recursion_guard = @import("recursion_guard.zig");

/// Error set mirroring the Rust `Result<Value, String>`: a parse error message or the
/// recursion-depth error message. The message text can be reproduced with
/// `recursion_guard.format_depth_exceeded` / `std.json` diagnostics.
pub const ParseError = error{
    /// Input nesting exceeds the configured maximum recursion depth.
    DepthExceeded,
    /// The input is not valid JSON (or has trailing garbage).
    InvalidJson,
    OutOfMemory,
};

/// Parses `text` as JSON, rejecting input whose value nesting exceeds the maximum recursion
/// depth (the C++ `ParseJSON`, which guards every nested array or object item). The depth is
/// checked before parsing, so a fixed parser nesting limit is lifted.
pub fn parse_json(allocator: Allocator, text: []const u8) ParseError!std.json.Value {
    const max = recursion_guard.get_max_recursion_depth();
    var depth: i32 = 0;
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
        // A value (or container item) at nesting `depth` is parsed at recursion depth `depth`.
        const value_depth: i32 = if (byte == '[' or byte == '{') depth - 1 else depth;
        if (value_depth > max) {
            return error.DepthExceeded;
        }
    }
    // Depth pre-check done; parse without a nesting limit (std.json's container stack is
    // dynamically allocated, so it has no fixed depth cap).
    var scanner = std.json.Scanner.initCompleteInput(allocator, text);
    defer scanner.deinit();
    const value = std.json.innerParse(std.json.Value, allocator, &scanner, .{ .max_value_len = text.len }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    // serde's `deserializer.end()`: reject trailing non-whitespace.
    const token = scanner.next() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    if (token != .end_of_document) return error.InvalidJson;
    return value;
}

test "parse_json basic" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const value = try parse_json(a, "{\"a\": [1, 2, 3], \"b\": \"中文\"}");
    try std.testing.expect(value == .object);
    try std.testing.expectEqual(@as(i64, 1), value.object.get("a").?.array.items[0].integer);
    try std.testing.expectEqualStrings("中文", value.object.get("b").?.string);

    const simple = try parse_json(a, "42");
    try std.testing.expectEqual(@as(i64, 42), simple.integer);

    const null_value = try parse_json(a, "null");
    try std.testing.expect(null_value == .null);
}

test "parse_json rejects trailing garbage" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectError(error.InvalidJson, parse_json(a, "{} trailing"));
    try std.testing.expectError(error.InvalidJson, parse_json(a, "1 2"));
    // Trailing whitespace is fine (serde's `end` allows it).
    _ = try parse_json(a, "  [1] \n ");
    try std.testing.expectError(error.InvalidJson, parse_json(a, "{"));
    try std.testing.expectError(error.InvalidJson, parse_json(a, "[1,]"));
}

test "parse_json enforces recursion depth" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    const old_max = recursion_guard.get_max_recursion_depth();
    defer recursion_guard.set_max_recursion_depth(old_max) catch unreachable;
    recursion_guard.set_max_recursion_depth(3) catch unreachable;

    // Four open containers: the scalar sits at value_depth 4 > max 3.
    try std.testing.expectError(error.DepthExceeded, parse_json(a, "[[[[1]]]]"));
    // Depth 3 is fine.
    _ = try parse_json(a, "[[[ ]]]");
    // Escaped quotes inside strings don't affect depth tracking.
    _ = try parse_json(a, "[\"\\\"[\\\"\"]");

    // Deeply nested beyond the limit fails; within it succeeds.
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(alloc);
    const deep: usize = 10;
    for (0..deep) |_| try buffer.append(alloc, '[');
    try buffer.append(alloc, '1');
    for (0..deep) |_| try buffer.append(alloc, ']');
    recursion_guard.set_max_recursion_depth(@intCast(deep)) catch unreachable;
    _ = try parse_json(a, buffer.items);
    recursion_guard.set_max_recursion_depth(@intCast(deep - 1)) catch unreachable;
    try std.testing.expectError(error.DepthExceeded, parse_json(a, buffer.items));
}
