//! Standard regex dot semantics on top of the regex engine, whose `.` matches every codepoint.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Rewrites every unescaped `.` outside character classes to `[^\n]` unless
/// `dot_matches_newline` is true (the dot-all `s` flag). Allocated from `allocator`.
pub fn rewrite_regex_dots(allocator: Allocator, pattern: []const u8, dot_matches_newline: bool) Allocator.Error![]u8 {
    if (dot_matches_newline) {
        return allocator.dupe(u8, pattern);
    }
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, pattern.len);
    var escaped = false;
    var in_character_class = false;
    for (pattern) |c| {
        if (escaped) {
            try result.append(allocator, c);
            escaped = false;
            continue;
        }
        switch (c) {
            '\\' => {
                try result.append(allocator, c);
                escaped = true;
            },
            '[' => {
                try result.append(allocator, c);
                in_character_class = true;
            },
            ']' => {
                try result.append(allocator, c);
                in_character_class = false;
            },
            '.' => {
                if (!in_character_class) {
                    try result.appendSlice(allocator, "[^\\n]");
                } else {
                    try result.append(allocator, c);
                }
            },
            else => try result.append(allocator, c),
        }
    }
    return result.toOwnedSlice(allocator);
}

test "rewrite dots" {
    const a = std.testing.allocator;
    const r1 = try rewrite_regex_dots(a, "a.c", false);
    defer a.free(r1);
    try std.testing.expectEqualStrings("a[^\\n]c", r1);
    const r2 = try rewrite_regex_dots(a, "[.].", false);
    defer a.free(r2);
    try std.testing.expectEqualStrings("[.][^\\n]", r2);
    const r3 = try rewrite_regex_dots(a, "a.", true);
    defer a.free(r3);
    try std.testing.expectEqualStrings("a.", r3);
    const r4 = try rewrite_regex_dots(a, "\\.", false);
    defer a.free(r4);
    try std.testing.expectEqualStrings("\\.", r4);
}
