//! Normalizes `kRepeat` expressions in place (`repetition_normalizer.rs`).
//!
//! For every repeat, the repeated rule is marked exact-lookahead; if that rule is nullable
//! the repeat's minimum count is lowered to 0 (reducing parser uncertainty). Must run after
//! `allow_empty_rule_ids` has populated the grammar.

const std = @import("std");
const grammar_mod = @import("../grammar/mod.zig");
const Grammar = grammar_mod.Grammar;
const GrammarExprType = grammar_mod.GrammarExprType;

/// Applies the repetition normalization in place.
pub fn repetition_normalizer(grammar: *Grammar) void {
    const allow_empty = grammar.allow_empty_rule_ids.items;
    for (0..@intCast(grammar.num_exprs())) |expr_id| {
        const expr = grammar.expr(@intCast(expr_id));
        if (expr.ty != .Repeat) continue;
        const repeat_rule_id = expr.data[0];
        grammar.rule_mut(repeat_rule_id).is_exact_lookahead = true;
        // allow_empty_rule_ids is kept sorted: a binary search is valid.
        if (std.sort.binarySearch(i32, allow_empty, repeat_rule_id, struct {
            fn cmp(ctx: i32, item: i32) std.math.Order {
                return std.math.order(item, ctx);
            }
        }.cmp) != null) {
            // The repeated rule is nullable: set its minimum count to 0.
            grammar.set_expr_data(@intCast(expr_id), 1, 0);
        }
    }
}

test "repetition normalizer lowers the minimum of nullable repeats" {
    const gpa = std.testing.allocator;
    const mod = @import("../grammar/mod.zig");
    const GrammarBuilder = mod.GrammarBuilder;
    var builder = try GrammarBuilder.new(gpa);
    defer builder.deinit();
    const cc = try builder.add_character_class(&.{mod.CharacterClassElement.new('a', 'b')}, false);
    const inner = try builder.add_rule_named("inner", cc);
    const empty = try builder.add_empty_str();
    const inner_choices = try builder.add_choices(&.{ empty, try builder.add_rule_ref(inner) });
    try builder.update_rule_body_by_name("inner", inner_choices);
    const rep = try builder.add_repeat(inner, 1, -1);
    _ = try builder.add_rule_named("root", rep);
    const grammar = try builder.into_grammar(gpa, "root", null);
    defer grammar.deinit();

    // The analyzer (under test in its own file) would mark `inner` empty; feed it directly.
    try grammar.set_allow_empty_rule_ids(&.{0});
    repetition_normalizer(grammar);
    try std.testing.expect(grammar.rule(0).is_exact_lookahead);
    const rep_expr = grammar.expr(grammar.rule(1).body_expr_id);
    try std.testing.expectEqual(@as(i32, 0), rep_expr.data[1]);
}
