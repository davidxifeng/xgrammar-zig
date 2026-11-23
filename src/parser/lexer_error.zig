//! Error raised by the EBNF lexer (`lexer_error.rs`).
//!
//! Rust's `thiserror` struct carries its data in the value; Zig error sets cannot, so the
//! failure surfaces as `error.Lexer` with the diagnostic optionally written back through a
//! `?*LexerError` out parameter.

const std = @import("std");

/// A lexing failure, with the 1-based source position where it occurred.
pub const LexerError = struct {
    /// 1-based line of the error.
    line: i32 = 0,
    /// 1-based column of the error.
    column: i32 = 0,
    /// Human-readable description (allocated; caller frees).
    message: []const u8 = "",

    /// The Rust `#[error(...)]` display text (caller owns).
    pub fn format_message(self: LexerError, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return std.fmt.allocPrint(gpa, "EBNF lexer error at line {d}, column {d}: {s}", .{
            self.line, self.column, self.message,
        });
    }
};

/// The error-set form of [`LexerError`].
pub const LexerFailure = error{Lexer};

/// Writes the diagnostic into `diag` when present.
pub fn report(diag: ?*LexerError, err: LexerError) LexerFailure {
    if (diag) |d| d.* = err;
    return error.Lexer;
}
