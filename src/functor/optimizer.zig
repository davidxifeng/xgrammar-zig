//! The grammar optimization pipeline (`optimizer`).
//!
//! Runs byte-string fusing and rule inlining (in place), zero-copy conditional
//! repetition expansion and lazy-body flattening, dead-code elimination, lookahead
//! analysis, empty-rule analysis, lazy-rule validation, repetition normalization,
//! and finally per-rule FSM construction.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Diagnostic = @import("../Diagnostic.zig").Diagnostic;
const grammar_mod = @import("../grammar.zig");
const Grammar = grammar_mod.Grammar;
const analysis_passes = @import("analysis_passes.zig");
const fsm_builder = @import("fsm_builder.zig");
const lazy_flattener = @import("lazy_flattener.zig");
const mutator = @import("mutator.zig");
const FunctorError = mutator.FunctorError;
const normalizer = @import("normalizer.zig");
const repetition_expander = @import("repetition_expander.zig");
const simplify_passes = @import("simplify_passes.zig");

/// Optimizes `grammar`, returning a new `Grammar` with per-rule FSMs built.
/// The input is untouched; the caller owns the result (`deinit`).
///
/// `diag` optionally receives failure diagnostics (invalid repetition range,
/// non-terminal lazy rule, or FSM/regex build errors).
pub fn optimizeGrammar(
    allocator: Allocator,
    grammar: *const Grammar,
    diag: ?*Diagnostic,
) FunctorError!Grammar {
    var current = try grammar.dupe(allocator);
    errdefer current.deinit();

    try simplify_passes.fuseByteStrings(&current);
    try simplify_passes.inlineRules(&current);
    try repetition_expander.expandInPlace(allocator, &current, diag);
    try lazy_flattener.flattenInPlace(allocator, &current);
    {
        const dead = try simplify_passes.eliminateDeadCode(allocator, &current);
        current.deinit();
        current = dead;
    }
    try analysis_passes.analyzeLookaheadAssertionsInPlace(allocator, &current);
    {
        const ids = try analysis_passes.allowEmptyRuleIds(allocator, &current);
        defer allocator.free(ids);
        try current.setAllowEmptyRuleIds(ids);
    }
    try validateLazyRules(allocator, &current, diag);
    normalizer.normalizeRepetition(&current);
    try fsm_builder.GrammarFsmBuilder.apply(allocator, &current, diag);
    current.setOptimized(true);
    return current;
}

/// Validates that every lazy rule compiles into a single per-rule FSM without rule refs.
fn validateLazyRules(allocator: Allocator, grammar: *const Grammar, diag: ?*Diagnostic) FunctorError!void {
    for (grammar.rulesSlice()) |r| {
        if (!r.is_lazy) continue;
        const body = grammar.expr(r.body_expr_id);
        switch (body.ty) {
            .Regex, .Substring => continue,
            .Choices => {},
            else => {
                if (diag) |d| try d.setCopy(allocator, .functor_lazy_rule_body_not_choices, r.name);
                return error.LazyRuleBodyNotChoices;
            },
        }
        for (body.data) |choice_id| {
            const choice = grammar.expr(choice_id);
            if (choice.ty == .EmptyStr) continue;
            for (choice.data) |element_id| {
                const element_ty = grammar.expr(element_id).ty;
                if (element_ty != .ByteString and element_ty != .CharacterClass and element_ty != .CharacterClassStar) {
                    if (diag) |d| try d.setCopy(allocator, .functor_lazy_rule_element_not_terminal, r.name);
                    return error.LazyRuleElementNotTerminal;
                }
            }
        }
    }
}

test "optimizeGrammar end to end and lazy rule Diagnostics" {
    const gpa = std.testing.allocator;
    const GrammarBuilder = grammar_mod.GrammarBuilder;
    const CharacterClassElement = grammar_mod.CharacterClassElement;
    {
        var builder = try GrammarBuilder.init(gpa);
        defer builder.deinit();
        const cc = try builder.addCharacterClass(&.{CharacterClassElement.init('a', 'z')}, false);
        const word = try builder.addRuleNamed("word", grammar_mod.NO_EXPR);
        const rec = try builder.addSequence(&.{ cc, try builder.addRuleRef(word) });
        builder.updateRuleBody(word, try builder.addChoices(&.{ try builder.addSequence(&.{cc}), rec }));
        const hello = try builder.addSequence(&.{ try builder.addByteString("hello"), try builder.addRuleRef(word) });
        const body = try builder.addChoices(&.{ hello, try builder.addSequence(&.{try builder.addByteString("bye")}) });
        _ = try builder.addRuleNamed("root", body);
        var grammar = try builder.intoGrammar("root", null);
        defer grammar.deinit();

        var diag: Diagnostic = .{};
        defer diag.deinit(gpa);
        var optimized = try optimizeGrammar(gpa, &grammar, &diag);
        defer optimized.deinit();
        try std.testing.expect(optimized.isOptimized());
        try std.testing.expectEqual(optimized.numRules(), optimized.perRuleFsmsSlice().len);
        for (0..optimized.numRules()) |i| {
            try std.testing.expect(optimized.perRuleFsm(@intCast(i)) != null);
        }
    }

    // Lazy rule validation reports Diagnostic matching FunctorError formatting.
    {
        var builder = try GrammarBuilder.init(gpa);
        defer builder.deinit();
        // Non-tail self-recursive rule cannot be flattened into a terminal-like FSM.
        const leaf = try builder.addRuleNamed("leaf", grammar_mod.NO_EXPR);
        const leaf_seq = try builder.addSequence(&.{
            try builder.addByteString("a"),
            try builder.addRuleRef(leaf),
            try builder.addByteString("b"),
        });
        builder.updateRuleBody(leaf, try builder.addChoices(&.{ try builder.addEmptyStr(), leaf_seq }));
        const bad_body = try builder.addChoices(&.{try builder.addSequence(&.{try builder.addRuleRef(leaf)})});
        const root = try builder.addRuleNamed("root", bad_body);
        builder.updateLazy(root, true);
        var grammar = try builder.intoGrammar("root", null);
        defer grammar.deinit();

        var diag: Diagnostic = .{};
        defer diag.deinit(gpa);
        try std.testing.expectError(error.LazyRuleElementNotTerminal, optimizeGrammar(gpa, &grammar, &diag));
        const msg = try diag.formatAlloc(gpa);
        defer gpa.free(msg);
        try std.testing.expectEqualStrings(
            "lazy rule 'root' must have a terminal-like body (strings, character classes, and regexes that " ++
                "compile to a single FSM); rule references and repetition ranges are not supported",
            msg,
        );
    }
}
