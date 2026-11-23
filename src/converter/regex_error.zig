//! Error raised by the regex → EBNF converter (`regex_error.rs`) — the Rust equivalent of
//! the C++ `RegexConverter::RaiseError` fatal.
//!
//! Rust struct-with-data → error set + diagnostic struct (parser-wave convention).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The error set of the regex converter.
pub const RegexError = error{ RegexParse, OutOfMemory };

/// A regex conversion failure, with the 1-based position in the regex where it occurred.
/// `message` is allocated from the caller's allocator and freed via `deinit`.
pub const RegexErrorInfo = struct {
    /// 1-based position in the regex.
    position: usize,
    /// Human-readable description.
    message: []u8,

    pub fn deinit(self: *RegexErrorInfo, allocator: Allocator) void {
        allocator.free(self.message);
    }

    /// The Rust `Display` text: `Regex parsing error at position {position}: {message}`.
    pub fn format_message(self: *const RegexErrorInfo, allocator: Allocator) Allocator.Error![]u8 {
        return std.fmt.allocPrint(allocator, "Regex parsing error at position {d}: {s}", .{ self.position, self.message });
    }
};
