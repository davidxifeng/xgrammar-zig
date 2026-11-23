//! Small byte-sequence helpers shared by the matcher and adaptive-mask builder.

/// Length of the longest common prefix of `a` and `b`.
pub fn common_prefix_len(a: []const u8, b: []const u8) i32 {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n and a[i] == b[i]) : (i += 1) {}
    return @intCast(i);
}

test "common_prefix_len" {
    try std.testing.expectEqual(@as(i32, 0), common_prefix_len("abc", "xyz"));
    try std.testing.expectEqual(@as(i32, 3), common_prefix_len("abcd", "abce"));
    try std.testing.expectEqual(@as(i32, 2), common_prefix_len("ab", "abZ"));
    try std.testing.expectEqual(@as(i32, 0), common_prefix_len("", "abc"));
    try std.testing.expectEqual(@as(i32, 0), common_prefix_len("abc", ""));
}

const std = @import("std");
