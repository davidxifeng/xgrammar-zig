//! Error raised by the regex → EBNF converter — the Rust equivalent of the C++
//! `RegexConverter::RaiseError` fatal (`regex_error.rs`).

const std = @import("std");

/// Rust's thiserror struct carries data; Zig surfaces failure as an error set plus a
/// diagnostic out-param (`?*RegexErrorInfo`), whose `message` is allocated from the
/// caller `gpa` and freed by the caller.
pub const RegexError = error{
    Regex,
    OutOfMemory,
};

/// The data payload of a [`RegexError`].
pub const RegexErrorInfo = struct {
    /// 1-based position in the regex.
    position: usize,
    /// Human-readable description (allocated from `gpa`; the caller frees).
    message: []u8,
};

/// Builds the diagnostic and returns `error.Regex` (Rust `RegexError{position, message}`).
pub fn make(
    diag: ?*RegexErrorInfo,
    gpa: std.mem.Allocator,
    position: usize,
    message: []const u8,
) RegexError {
    if (diag) |d| {
        d.* = .{ .position = position, .message = gpa.dupe(u8, message) catch &.{} };
    }
    return error.Regex;
}

/// The Rust `Display` text: `"Regex parsing error at position {position}: {message}"`.
pub fn format_message(
    info: *const RegexErrorInfo,
    gpa: std.mem.Allocator,
) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "Regex parsing error at position {d}: {s}", .{ info.position, info.message });
}
