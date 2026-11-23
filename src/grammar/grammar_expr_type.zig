//! The discriminant for a grammar expression and the data layout of each kind
//! (`grammar_expr_type.rs`).

/// The kind of a grammar expression.
///
/// Each variant documents the layout of the `i32` data array it owns inside the grammar's
/// flat CSR buffer. The type tag is stored as the first `i32` of every expression.
pub const GrammarExprType = enum(i32) {
    /// A string of bytes (0–255). Supports UTF-8 strings.
    /// Data: `[byte0, byte1, ...]`.
    ByteString = 0,
    /// A range of characters (each character is a Unicode codepoint), e.g. `[a-z]`, `[ac-z]`.
    /// Can be negated: `[^a-z]`, `[^ac-z]`. Only ASCII characters are allowed inside `[]`,
    /// but this expression can accept or reject Unicode characters.
    /// Data: `[is_negative, lower0, upper0, lower1, upper1, ...]`.
    CharacterClass = 1,
    /// A star quantifier of a character class, e.g. `[a-z]*`, `[^a-z]*`.
    /// Data: same layout as `CharacterClass`.
    CharacterClassStar = 2,
    /// The empty string, i.e. `""`. Data: `[]`.
    EmptyStr = 3,
    /// A reference to another rule. Data: `[rule_id]`.
    RuleRef = 4,
    /// A sequence of grammar expressions, e.g. `("a" "b")`.
    /// Data: `[grammar_expr_id0, grammar_expr_id1, ...]`.
    Sequence = 5,
    /// A choice of grammar expressions, e.g. `("a" "b") | "c"`.
    /// Data: `[grammar_expr_id0, grammar_expr_id1, ...]`.
    Choices = 6,
    /// Tag dispatch (internal optimization construct).
    /// Data: `[tag_expr0, rule_id0, ..., loop_after_dispatch, excluded_str_expr_id]`.
    TagDispatch = 7,
    /// Bounded or unbounded repetition.
    /// Data: `[rule_id, min_repeat_count, max_repeat_count]`.
    Repeat = 8,
    /// An explicit set of allowed tokens.
    /// Data: `[token_id_0, token_id_1, ...]`.
    Token = 9,
    /// An explicit set of excluded tokens.
    /// Data: `[token_id_0, token_id_1, ...]`.
    ExcludeToken = 10,
    /// Token-triggered tag dispatch (internal optimization construct).
    /// Data: `[trigger_cnt, (token_id, rule_id) × N, loop_after_dispatch, exclude_cnt, token_id × M]`.
    TokenTagDispatch = 11,
    /// A regex pattern stored as bytes; compiled into an automaton by the grammar FSM builder.
    /// Data: `[json_string, byte0, byte1, ...]` (the bytes are the pattern string).
    Regex = 12,
    /// Every contiguous subsequence of a list of byte-string chunks, including the empty one.
    /// Data: `[chunk0_len, byte0_0, byte0_1, ..., chunk1_len, byte1_0, ...]`.
    Substring = 13,

    /// The raw `i32` tag stored in the flat grammar buffer.
    pub fn as_i32(self: GrammarExprType) i32 {
        return @intFromEnum(self);
    }
};

/// Error when an `i32` does not correspond to a known `GrammarExprType`
/// (Rust `UnknownGrammarExprType(i32)`; the bad tag is visible at the call site, so the
/// error set carries no payload).
pub const UnknownGrammarExprType = error{UnknownGrammarExprType};

/// Rust `TryFrom<i32>` for `GrammarExprType`.
pub fn try_from(value: i32) UnknownGrammarExprType!GrammarExprType {
    return switch (value) {
        0 => .ByteString,
        1 => .CharacterClass,
        2 => .CharacterClassStar,
        3 => .EmptyStr,
        4 => .RuleRef,
        5 => .Sequence,
        6 => .Choices,
        7 => .TagDispatch,
        8 => .Repeat,
        9 => .Token,
        10 => .ExcludeToken,
        11 => .TokenTagDispatch,
        12 => .Regex,
        13 => .Substring,
        else => error.UnknownGrammarExprType,
    };
}

const std = @import("std");

test "expr type roundtrip" {
    const all = [_]GrammarExprType{ .ByteString, .CharacterClass, .CharacterClassStar, .EmptyStr, .RuleRef, .Sequence, .Choices, .TagDispatch, .Repeat, .Token, .ExcludeToken, .TokenTagDispatch, .Regex, .Substring };
    for (all, 0..) |ty, i| {
        try std.testing.expectEqual(@as(i32, @intCast(i)), ty.as_i32());
        try std.testing.expectEqual(ty, try try_from(ty.as_i32()));
    }
    try std.testing.expectError(error.UnknownGrammarExprType, try_from(14));
    try std.testing.expectError(error.UnknownGrammarExprType, try_from(-1));
    try std.testing.expectEqual(@as(i32, 13), GrammarExprType.Substring.as_i32());
}
