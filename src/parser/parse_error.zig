//! Error raised by the EBNF parser — fatal (`parse_error.rs`).
//!
//! Rust's `thiserror` struct carries its data in the value; Zig error sets cannot, so the
//! failure surfaces as `error.Parser` with the diagnostic optionally written back through a
//! `?*ParserError` out parameter (same pattern as the grammar wave's `DeserializeError`).

const std = @import("std");

/// A parsing failure, with the 1-based source position where it occurred.
pub const ParserError = struct {
    /// 1-based line of the error.
    line: i32 = 0,
    /// 1-based column of the error.
    column: i32 = 0,
    /// Human-readable description (allocated; caller frees).
    message: []const u8 = "",

    /// The Rust `#[error(...)]` display text (caller owns).
    pub fn format_message(self: ParserError, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return std.fmt.allocPrint(gpa, "EBNF parser error at line {d}, column {d}: {s}", .{
            self.line, self.column, self.message,
        });
    }
};

/// The error-set form of [`ParserError`].
pub const ParserFailure = error{Parser};

/// Writes the diagnostic into `diag` when present.
pub fn report(diag: ?*ParserError, err: ParserError) ParserFailure {
    if (diag) |d| d.* = err;
    return error.Parser;
}
