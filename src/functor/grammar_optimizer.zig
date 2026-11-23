//! The grammar optimization pipeline run before parsing (`grammar_optimizer.rs`).
//!
//! Runs the byte-string fuser and rule inliner (both in place), the repetition-range
//! expander, the lazy body flattener, dead-code eliminator, lookahead analyzer, empty-rule
//! analysis, lazy rule validation, repetition normalizer, and finally the grammar FSM
//! builder, leaving the grammar marked optimized and ready for the Earley parser.

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_mod = @import("../grammar/mod.zig");
const Grammar = grammar_mod.Grammar;
const GrammarExprType = grammar_mod.GrammarExprType;
const allow_empty_rule_analyzer = @import("allow_empty_rule_analyzer.zig");
const byte_string_fuser_mod = @import("byte_string_fuser.zig");
const dead_code_eliminator_mod = @import("dead_code_eliminator.zig");
const error_mod = @import("error.zig");
const FunctorError = error_mod.FunctorError;
const FunctorErrorInfo = error_mod.FunctorErrorInfo;
const grammar_fsm_builder_mod = @import("grammar_fsm_builder.zig");
const lazy_body_flattener_mod = @import("lazy_body_flattener.zig");
const lookahead_assertion_analyzer_mod = @import("lookahead_assertion_analyzer.zig");
const repetition_normalizer_mod = @import("repetition_normalizer.zig");
const repetition_range_expander_mod = @import("repetition_range_expander.zig");
const rule_inliner_mod = @import("rule_inliner.zig");

/// Optimizes `grammar`, returning a new grammar with per-rule FSMs built. The input is
/// untouched; the caller owns the result.
///
/// `diag` optionally receives the failure details (strings allocated from `allocator`;
/// the caller frees `FsmBuild` messages).
///
/// Errors: an invalid repetition range, a lazy rule body that is not terminal-like, or a
/// rule body (e.g. a regex) that fails to compile into an automaton.
pub fn grammar_optimizer(
    allocator: Allocator,
    grammar: *const Grammar,
    diag: ?*FunctorErrorInfo,
) FunctorError!*Grammar {
    // The fuser and inliner rewrite in place, so they work on a private copy of the input.
    var current = try grammar.clone(allocator);
    errdefer current.deinit();

    try byte_string_fuser_mod.byte_string_fuser(current);
    try rule_inliner_mod.rule_inliner(current);
    {
        const expanded = try repetition_range_expander_mod.repetition_range_expander(allocator, current, diag);
        current.deinit();
        current = expanded;
    }
    {
        const flattened = try lazy_body_flattener_mod.lazy_body_flattener(allocator, current);
        current.deinit();
        current = flattened;
    }
    {
        const dead = try dead_code_eliminator_mod.dead_code_eliminator(allocator, current);
        current.deinit();
        current = dead;
    }
    {
        const analyzed = try lookahead_assertion_analyzer_mod.lookahead_assertion_analyzer(allocator, current);
        current.deinit();
        current = analyzed;
    }
    {
        const ids = try allow_empty_rule_analyzer.allow_empty_rule_ids(allocator, current);
        defer allocator.free(ids);
        try current.set_allow_empty_rule_ids(ids);
    }
    try validate_lazy_rules(allocator, current, diag);
    repetition_normalizer_mod.repetition_normalizer(current);
    try grammar_fsm_builder_mod.GrammarFsmBuilder.apply(allocator, current, diag);
    current.set_optimized(true);
    return current;
}

/// Committed-shortest (lazy) matching requires the whole rule body to compile into a single
/// per-rule FSM without rule references, so that the states of one occurrence are exactly
/// the states with the rule's id.
fn validate_lazy_rules(allocator: Allocator, grammar: *const Grammar, diag: ?*FunctorErrorInfo) FunctorError!void {
    for (grammar.rules.items) |rule| {
        if (!rule.is_lazy) continue;
        const body = grammar.expr(rule.body_expr_id);
        switch (body.ty) {
            .Regex, .Substring => continue,
            .Choices => {},
            else => {
                error_mod.set_diag(diag, .{ .LazyRuleBodyNotChoices = rule.name });
                return error.LazyRuleBodyNotChoices;
            },
        }
        for (body.data) |choice_id| {
            const choice = grammar.expr(choice_id);
            if (choice.ty == .EmptyStr) continue;
            for (choice.data) |element_id| {
                const element_ty = grammar.expr(element_id).ty;
                if (element_ty != .ByteString and element_ty != .CharacterClass and element_ty != .CharacterClassStar) {
                    error_mod.set_diag(diag, .{ .LazyRuleElementNotTerminal = rule.name });
                    return error.LazyRuleElementNotTerminal;
                }
            }
        }
    }
    _ = allocator;
}

test "grammar optimizer end to end" {
    const gpa = std.testing.allocator;
    const mod = @import("../grammar/mod.zig");
    const GrammarBuilder = mod.GrammarBuilder;
    var builder = try GrammarBuilder.new(gpa);
    defer builder.deinit();
    // word ::= (([a-z]) | ([a-z] word)); root ::= (("hello" word) | ("bye")) — normalized
    // shape (choices of sequences), as produced by the structure normalizer.
    const cc = try builder.add_character_class(&.{mod.CharacterClassElement.new('a', 'z')}, false);
    const word = try builder.add_rule_named("word", mod.NO_EXPR);
    const rec = try builder.add_sequence(&.{ cc, try builder.add_rule_ref(word) });
    builder.update_rule_body(word, try builder.add_choices(&.{ try builder.add_sequence(&.{cc}), rec }));
    const hello = try builder.add_sequence(&.{ try builder.add_byte_string("hello"), try builder.add_rule_ref(word) });
    const body = try builder.add_choices(&.{ hello, try builder.add_sequence(&.{try builder.add_byte_string("bye")}) });
    _ = try builder.add_rule_named("root", body);
    const grammar = try builder.into_grammar(gpa, "root", null);
    defer grammar.deinit();

    var diag: FunctorErrorInfo = undefined;
    const optimized = try grammar_optimizer(gpa, grammar, &diag);
    defer optimized.deinit();
    try std.testing.expect(optimized.is_optimized());
    // The dead `word` prefix copy is eliminated and FSMs are installed.
    try std.testing.expect(optimized.per_rule_fsms.items.len == optimized.rules.items.len);
    for (optimized.rules.items, 0..) |rule, i| {
        _ = rule;
        try std.testing.expect(optimized.per_rule_fsm(@intCast(i)) != null);
    }
}

