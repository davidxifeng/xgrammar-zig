//! Unified error for turning an EBNF string into a grammar (lexing or parsing)
//! (`ebnf_error.rs`).
//!
//! Rust's enum carries the inner error value; Zig surfaces `EbnfError` as an error set with
//! the diagnostic (line/column/message) optionally written back through `?*EbnfErrorInfo`.

const std = @import("std");

const lexer_error = @import("lexer_error.zig");
const parse_error = @import("parse_error.zig");

const LexerError = lexer_error.LexerError;
const ParserError = parse_error.ParserError;

/// A failure while converting EBNF text to a grammar.
pub const EbnfError = error{
    /// The lexer rejected the input.
    Lexer,
    /// The parser rejected the token stream.
    Parser,
    /// A normalization pass failed (mirrors C++ `XGRAMMAR_LOG(FATAL)` becoming a Python error).
    Normalization,
};

/// The data payload of an [`EbnfError`] (Rust's enum variant contents).
pub const EbnfErrorInfo = union(enum) {
    lexer: LexerError,
    parser: ParserError,
    normalization: []const u8,
};

/// Writes `info` into `diag` when present.
pub fn report(diag: ?*EbnfErrorInfo, info: EbnfErrorInfo) EbnfError {
    if (diag) |d| d.* = info;
    return switch (info) {
        .lexer => error.Lexer,
        .parser => error.Parser,
        .normalization => error.Normalization,
    };
}

/// The human-readable message of the underlying error (allocated; caller frees).
pub fn message_of(info: EbnfErrorInfo, gpa: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
    return switch (info) {
        .lexer => |e| gpa.dupe(u8, e.message),
        .parser => |e| gpa.dupe(u8, e.message),
        .normalization => |m| gpa.dupe(u8, m),
    };
}
