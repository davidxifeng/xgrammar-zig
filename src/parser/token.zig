//! A lexical token and its processed value (`token.rs`; the C++ `cpp/grammar_parser.h` value
//! becomes a typed [`TokenValue`]).
//!
//! The `Str` payloads are allocator-owned byte slices; `tokenize` duplicates them from the
//! input and the consumer frees them via [`free_tokens`] (or hands them to an arena).

const std = @import("std");

const rule_attributes = @import("rule_attributes.zig");
const token_type = @import("token_type.zig");

const RuleAttributes = rule_attributes.RuleAttributes;
const TokenType = token_type.TokenType;

/// The processed payload attached to a token.
pub const TokenValue = union(enum) {
    /// No payload (punctuation, EOF, …).
    None,
    /// An integer literal value.
    Int: i64,
    /// A boolean literal value.
    Bool: bool,
    /// A decoded string: the value of a string literal, or an identifier's text.
    Str: []const u8,
    /// A codepoint, for a literal character in a character class.
    Codepoint: i32,

    /// The integer value, if this is `Int`.
    pub fn as_int(self: TokenValue) ?i64 {
        return switch (self) {
            .Int => |v| v,
            else => null,
        };
    }

    /// The boolean value, if this is `Bool`.
    pub fn as_bool(self: TokenValue) ?bool {
        return switch (self) {
            .Bool => |v| v,
            else => null,
        };
    }

    /// The string value, if this is `Str`.
    pub fn as_str(self: TokenValue) ?[]const u8 {
        return switch (self) {
            .Str => |s| s,
            else => null,
        };
    }

    /// The codepoint value, if this is `Codepoint`.
    pub fn as_codepoint(self: TokenValue) ?i32 {
        return switch (self) {
            .Codepoint => |c| c,
            else => null,
        };
    }

    /// Rust `PartialEq` for the payload.
    pub fn eql(a: TokenValue, b: TokenValue) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .None => true,
            .Int => |v| v == b.Int,
            .Bool => |v| v == b.Bool,
            .Str => |s| std.mem.eql(u8, s, b.Str),
            .Codepoint => |c| c == b.Codepoint,
        };
    }
};

/// A single lexical token: its kind, the original source text, a processed value, and the
/// 1-based source position where it began.
pub const Token = struct {
    /// The token kind.
    ty: TokenType,
    /// The original source text of the token.
    lexeme: []const u8,
    /// The processed value.
    value: TokenValue,
    /// 1-based line where the token starts.
    line: i32,
    /// 1-based column where the token starts.
    column: i32,
    /// The attribute block of a rule-definition identifier, e.g. `name[max_tokens=10] ::= ...`.
    rule_attributes: ?RuleAttributes = null,

    /// Rust `PartialEq` for tests.
    pub fn eql(a: Token, b: Token) bool {
        return a.ty == b.ty and std.mem.eql(u8, a.lexeme, b.lexeme) and
            a.value.eql(b.value) and a.line == b.line and a.column == b.column;
    }
};

/// Releases the heap strings of a token list produced by `tokenize` (Rust frees via `Drop`).
pub fn free_tokens(gpa: std.mem.Allocator, tokens: []Token) void {
    for (tokens) |token| {
        gpa.free(token.lexeme);
        switch (token.value) {
            .Str => |s| gpa.free(s),
            else => {},
        }
        if (token.rule_attributes) |attrs| {
            gpa.free(attrs.capture_name);
            gpa.free(attrs.suffix_stop_info.stop_capture_name);
        }
    }
}
