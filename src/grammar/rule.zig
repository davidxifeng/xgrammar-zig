//! A named grammar rule (`rule.rs`).

/// Sentinel id meaning "no expression / no lookahead assertion".
pub const NO_EXPR: i32 = -1;

/// A production rule: a name plus the id of the grammar expression that forms its body.
pub const Rule = struct {
    /// The rule name.
    name: []const u8,
    /// The grammar-expression id of the rule body, or `NO_EXPR` if not yet set.
    body_expr_id: i32,
    /// The id of the associated lookahead-assertion expression (a sequence expr), or
    /// `NO_EXPR` if there is none.
    lookahead_assertion_id: i32,
    /// Whether the lookahead assertion is exact.
    is_exact_lookahead: bool,
    /// The token budget of the rule. When non-negative, the matcher bounds each occurrence of
    /// this rule to at most `max_tokens` LLM tokens. `-1` means no budget.
    max_tokens: i32,
    /// The Unicode codepoint budget of the rule. When non-negative, the matcher bounds each
    /// occurrence of this rule to at most `max_chars` codepoints. `-1` means no budget.
    max_chars: i32,
    /// The capture group name of the rule. When non-empty, the matcher records the input span
    /// matched by this rule on every completion. Empty means no capture.
    capture_name: []const u8,
    /// Whether the rule matches with committed-shortest (lazy) semantics.
    is_lazy: bool,
    /// The sampling temperature to use while matching this rule.
    temperature: ?f32,

    /// Creates a rule with the given name and body expression, no lookahead assertion.
    ///
    /// The caller keeps `name` alive; owners (builder/grammar) dupe it into their own arena.
    pub fn new(name: []const u8, body_expr_id: i32) Rule {
        return .{
            .name = name,
            .body_expr_id = body_expr_id,
            .lookahead_assertion_id = NO_EXPR,
            .is_exact_lookahead = false,
            .max_tokens = -1,
            .max_chars = -1,
            .capture_name = "",
            .is_lazy = false,
            .temperature = null,
        };
    }

    /// Creates a rule with no body yet (body set later via the builder).
    pub fn empty(name: []const u8) Rule {
        return new(name, NO_EXPR);
    }

    /// Rust `PartialEq` (string fields compared by content).
    pub fn eql(a: Rule, b: Rule) bool {
        return std.mem.eql(u8, a.name, b.name) and a.body_expr_id == b.body_expr_id and
            a.lookahead_assertion_id == b.lookahead_assertion_id and
            a.is_exact_lookahead == b.is_exact_lookahead and a.max_tokens == b.max_tokens and
            a.max_chars == b.max_chars and
            std.mem.eql(u8, a.capture_name, b.capture_name) and a.is_lazy == b.is_lazy and
            temperature_eql(a.temperature, b.temperature);
    }

    fn temperature_eql(a: ?f32, b: ?f32) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return a.? == b.?;
    }
};

const std = @import("std");

test "rule defaults" {
    const r = Rule.new("root", 7);
    try std.testing.expectEqualStrings("root", r.name);
    try std.testing.expectEqual(@as(i32, 7), r.body_expr_id);
    try std.testing.expectEqual(NO_EXPR, r.lookahead_assertion_id);
    try std.testing.expectEqual(false, r.is_exact_lookahead);
    try std.testing.expectEqual(@as(i32, -1), r.max_tokens);
    try std.testing.expectEqual(@as(i32, -1), r.max_chars);
    try std.testing.expectEqualStrings("", r.capture_name);
    try std.testing.expectEqual(false, r.is_lazy);
    try std.testing.expectEqual(@as(?f32, null), r.temperature);
    try std.testing.expect(r.eql(r));
    const e = Rule.empty("x");
    try std.testing.expectEqual(NO_EXPR, e.body_expr_id);
    var t = r;
    t.temperature = 0.7;
    try std.testing.expect(!t.eql(r));
    t.temperature = 0.7;
    try std.testing.expect(t.eql(t));
}
