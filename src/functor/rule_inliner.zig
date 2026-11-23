//! Inlines references to simple rules, in place (`rule_inliner.rs`).
//!
//! When a choice is a sequence beginning with a reference to an *inlinable* rule, that
//! reference is expanded: each of the referenced rule's choices is spliced in front of the
//! choice's remaining elements. Only choices that actually inline are rebuilt; the rest
//! keep their original ids, and the referenced rule itself is left in place for the dead
//! code eliminator. Inlinability is judged on the original grammar, so the result does not
//! depend on the order rules are rewritten.

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_mod = @import("../grammar/mod.zig");
const Grammar = grammar_mod.Grammar;
const GrammarBuilder = grammar_mod.GrammarBuilder;
const GrammarExprType = grammar_mod.GrammarExprType;
const in_place = @import("in_place_grammar_rewriter.zig");

/// Inlines leading references to simple rules in place (the `GrammarFunctor.rule_inliner` pass).
pub fn rule_inliner(grammar: *Grammar) (Allocator.Error || @import("../support/mod.zig").Compact2dArrayError)!void {
    const gpa = grammar.arena.allocator();
    var inliner = RuleInliner{
        .original_body_expr_ids = .empty,
        .can_rule_be_inlined = .empty,
    };
    defer {
        inliner.original_body_expr_ids.deinit(gpa);
        inliner.can_rule_be_inlined.deinit(gpa);
    }
    try inliner.original_body_expr_ids.ensureTotalCapacity(gpa, grammar.rules.items.len);
    for (grammar.rules.items) |rule| inliner.original_body_expr_ids.appendAssumeCapacity(rule.body_expr_id);
    try inliner.can_rule_be_inlined.ensureTotalCapacity(gpa, @intCast(grammar.num_rules()));
    for (0..@intCast(grammar.num_rules())) |rule_id| {
        inliner.can_rule_be_inlined.appendAssumeCapacity(try can_rule_be_inlined(gpa, grammar, @intCast(rule_id)));
    }
    try in_place.apply(&inliner, grammar);
}

const RuleInliner = struct {
    original_body_expr_ids: std.ArrayList(i32),
    can_rule_be_inlined: std.ArrayList(bool),

    /// The rule referenced by the first element of `choice_id`, if that choice is a sequence
    /// led by a reference to an inlinable rule.
    fn leading_inlinable_rule(
        self: *RuleInliner,
        builder: *GrammarBuilder,
        choice_id: i32,
    ) ?i32 {
        const choice = builder.grammar_expr(choice_id);
        if (choice.ty != .Sequence or choice.is_empty()) return null;
        const first_element = builder.grammar_expr(choice.data[0]);
        if (first_element.ty != .RuleRef) return null;
        const rule_id = first_element.rule_ref_id();
        if (!self.can_rule_be_inlined.items[@intCast(rule_id)]) return null;
        return rule_id;
    }

    /// The overridden `visit_choices` (see the Rust trait impl).
    pub fn visit_choices(
        self: *RuleInliner,
        builder: *GrammarBuilder,
        memo: []i32,
        expr_id: i32,
    ) (Allocator.Error || @import("../support/mod.zig").Compact2dArrayError)!i32 {
        const gpa = builder.allocator;
        const size = builder.grammar_expr(expr_id).len();
        var new_choice_ids: ?std.ArrayList(i32) = null;
        errdefer if (new_choice_ids) |*ids| ids.deinit(gpa);
        for (0..size) |index| {
            const choice_id = builder.grammar_expr(expr_id).data[index];
            const inline_rule_id = self.leading_inlinable_rule(builder, choice_id) orelse {
                const new_choice_id = try in_place.visit_expr(self, builder, memo, choice_id);
                if (new_choice_ids == null and new_choice_id != choice_id) {
                    var ids: std.ArrayList(i32) = .empty;
                    try ids.appendSlice(gpa, builder.grammar_expr(expr_id).data[0..index]);
                    new_choice_ids = ids;
                }
                if (new_choice_ids) |*ids| try ids.append(gpa, new_choice_id);
                continue;
            };
            if (new_choice_ids == null) {
                var ids: std.ArrayList(i32) = .empty;
                try ids.appendSlice(gpa, builder.grammar_expr(expr_id).data[0..index]);
                new_choice_ids = ids;
            }
            const ids = &new_choice_ids.?;
            // Prepend each choice of the referenced rule to the rest of this sequence. The
            // element ids are copied and visited before anything is appended.
            const rest_source = builder.grammar_expr(choice_id).data[1..];
            var rest_element_ids: std.ArrayList(i32) = .empty;
            defer rest_element_ids.deinit(gpa);
            try rest_element_ids.ensureTotalCapacity(gpa, rest_source.len);
            for (rest_source) |element_id| {
                rest_element_ids.appendAssumeCapacity(try in_place.visit_expr(self, builder, memo, element_id));
            }
            const ref_body_id = self.original_body_expr_ids.items[@intCast(inline_rule_id)];
            const ref_choice_source = builder.grammar_expr(ref_body_id).data;
            const ref_choice_ids = try gpa.dupe(i32, ref_choice_source);
            defer gpa.free(ref_choice_ids);
            for (ref_choice_ids) |ref_choice_id| {
                var new_sequence: std.ArrayList(i32) = .empty;
                defer new_sequence.deinit(gpa);
                const seq_source = builder.grammar_expr(ref_choice_id).data;
                try new_sequence.ensureTotalCapacity(gpa, seq_source.len + rest_element_ids.items.len);
                for (seq_source) |element_id| {
                    new_sequence.appendAssumeCapacity(try in_place.visit_expr(self, builder, memo, element_id));
                }
                try new_sequence.appendSlice(gpa, rest_element_ids.items);
                try ids.append(gpa, try builder.add_sequence(new_sequence.items));
            }
        }
        if (new_choice_ids) |*ids| {
            defer ids.deinit(gpa);
            return builder.add_choices(ids.items);
        }
        return expr_id;
    }
};

/// A rule can be inlined iff it carries no per-rule runtime semantics and its body is a
/// non-empty choices of sequences that contain no rule references.
fn can_rule_be_inlined(gpa: Allocator, grammar: *const Grammar, rule_id: i32) Allocator.Error!bool {
    const rule = grammar.rule(rule_id);
    // Inlining a budgeted rule would erase the rule its length budget applies to. Inlining a
    // capture-relevant rule would eliminate its completion events, so its capture or hidden
    // span would never be recorded. Inlining a lazy rule would erase its committed-shortest
    // semantics. Inlining a temperature rule would erase the rule its sampling temperature
    // applies to.
    if (rule.max_tokens >= 0 or rule.max_chars >= 0 or rule.capture_name.len != 0 or
        grammar.suffix_stop_info(rule_id) != null or rule.is_lazy or rule.temperature != null)
    {
        return false;
    }
    const body = grammar.expr(rule.body_expr_id);
    if (body.ty != .Choices or body.is_empty()) return false;
    var inlinable = true;
    for (body.data) |choice_id| {
        const choice = grammar.expr(choice_id);
        if (choice.ty != .Sequence) {
            inlinable = false;
            break;
        }
        for (choice.data) |element_id| {
            if (grammar.expr(element_id).ty == .RuleRef) {
                inlinable = false;
                break;
            }
        }
        if (!inlinable) break;
    }
    _ = gpa;
    return inlinable;
}

test "rule inliner splices the referenced choices in front" {
    const gpa = std.testing.allocator;
    const mod = @import("../grammar/mod.zig");
    const GB = mod.grammar_builder.GrammarBuilder;
    var builder = try GB.new(gpa);
    defer builder.deinit();
    // pfx ::= "a" | "b"; root ::= (pfx "x") | "c"
    const pfx = try builder.add_rule_named(
        "pfx",
        try builder.add_choices(&.{ try builder.add_sequence(&.{try builder.add_byte_string("a")}), try builder.add_sequence(&.{try builder.add_byte_string("b")}) }),
    );
    const seq1 = try builder.add_sequence(&.{ try builder.add_rule_ref(pfx), try builder.add_byte_string("x") });
    const root_body = try builder.add_choices(&.{ seq1, try builder.add_byte_string("c") });
    _ = try builder.add_rule_named("root", root_body);
    const grammar = try builder.into_grammar(gpa, "root", null);
    defer grammar.deinit();

    try rule_inliner(grammar);

    const printer = grammar_mod.printer;
    const ebnf = try printer.to_string_ebnf(grammar, gpa);
    defer gpa.free(ebnf);
    // `pfx` itself stays (dead code elimination removes it later); the choice is spliced.
    try std.testing.expectEqualStrings(
        "pfx ::= ((\"a\") | (\"b\"))\nroot ::= ((\"a\" \"x\") | (\"b\" \"x\") | \"c\")\n",
        ebnf,
    );
}
