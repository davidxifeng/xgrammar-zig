//! Infers lookahead assertions for rules (`lookahead_assertion_analyzer.rs`).
//!
//! When a rule is referenced in exactly one place where it is not the final element of a
//! sequence, the text that must follow it is fixed; that suffix is attached to the rule as
//! a lookahead assertion so the matcher can resolve completion earlier.

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_mod = @import("../grammar/mod.zig");
const Grammar = grammar_mod.Grammar;
const GrammarExprType = grammar_mod.GrammarExprType;
const NO_EXPR = grammar_mod.NO_EXPR;
const error_mod = @import("error.zig");
const FunctorError = error_mod.FunctorError;

/// Infers and attaches lookahead assertions (the `GrammarFunctor.lookahead_assertion_analyzer`
/// pass).
pub fn lookahead_assertion_analyzer(allocator: Allocator, grammar: *const Grammar) FunctorError!*Grammar {
    var analyzer = LookaheadAssertionAnalyzer{
        .allocator = allocator,
        .base = grammar,
        .builder = undefined,
        .infos = .empty,
    };
    errdefer analyzer.deinit_temps();
    analyzer.builder = try grammar_mod.GrammarBuilder.from_grammar(grammar, allocator);
    const result = try analyzer.run();
    analyzer.deinit_temps();
    return result;
}

const RuleLookaheadInfo = struct {
    is_triggered_by_dispatch: bool = false,
    appears_as_last_in_other_rule: bool = false,
    non_last_occurrence_count: i32 = 0,
    suffix_after_first_occurrence: std.ArrayList(i32) = .empty,
};

const LookaheadAssertionAnalyzer = struct {
    allocator: Allocator,
    base: *const Grammar,
    builder: grammar_mod.GrammarBuilder,
    infos: std.ArrayList(RuleLookaheadInfo),

    fn deinit_temps(self: *LookaheadAssertionAnalyzer) void {
        for (self.infos.items) |*info| info.suffix_after_first_occurrence.deinit(self.allocator);
        self.infos.deinit(self.allocator);
        self.builder.deinit();
    }

    fn run(self: *LookaheadAssertionAnalyzer) FunctorError!*Grammar {
        const root_body = self.base.expr(self.base.root_rule().body_expr_id);
        if (root_body.ty == .TagDispatch or root_body.ty == .TokenTagDispatch or
            root_body.ty == .Regex or root_body.ty == .Substring)
        {
            return self.base.clone(self.allocator);
        }

        try self.build_rule_lookahead_info();

        const root_id = self.base.root_rule_id;
        for (0..@intCast(self.base.num_rules())) |i| {
            if (i == @as(usize, @intCast(root_id))) continue;
            if (self.base.rule(@intCast(i)).lookahead_assertion_id != NO_EXPR) {
                const exact = self.can_use_derived_lookahead(@intCast(i));
                self.builder.update_lookahead_exact(@intCast(i), exact);
                continue;
            }
            if (try self.detect_lookahead_assertion(@intCast(i))) |lookahead_id| {
                self.builder.update_lookahead_assertion(@intCast(i), lookahead_id);
                self.builder.update_lookahead_exact(@intCast(i), true);
            }
        }
        const result = try self.builder.into_grammar_with_root_id(self.allocator, root_id);
        return result;
    }

    fn can_use_derived_lookahead(self: *LookaheadAssertionAnalyzer, rule_id: i32) bool {
        const info = &self.infos.items[@intCast(rule_id)];
        return !info.is_triggered_by_dispatch and !info.appears_as_last_in_other_rule and
            info.non_last_occurrence_count == 1;
    }

    fn detect_lookahead_assertion(self: *LookaheadAssertionAnalyzer, rule_id: i32) FunctorError!?i32 {
        if (!self.can_use_derived_lookahead(rule_id)) return null;
        const suffix = self.infos.items[@intCast(rule_id)].suffix_after_first_occurrence.items;
        return try self.builder.add_sequence(suffix);
    }

    fn build_rule_lookahead_info(self: *LookaheadAssertionAnalyzer) Allocator.Error!void {
        const num_rules: usize = @intCast(self.base.num_rules());
        try self.infos.ensureTotalCapacity(self.allocator, num_rules);
        for (0..num_rules) |_| self.infos.appendAssumeCapacity(.{});

        for (0..num_rules) |i| {
            const body = self.base.expr(self.base.rule(@intCast(i)).body_expr_id);
            switch (body.ty) {
                .TagDispatch => {
                    var td = try grammar_mod.tag_dispatch.tag_dispatch(self.base, self.allocator, self.base.rule(@intCast(i)).body_expr_id);
                    defer td.deinit(self.allocator);
                    for (td.tag_rule_pairs.items) |pair| {
                        self.infos.items[@intCast(pair.rule_id)].is_triggered_by_dispatch = true;
                    }
                    continue;
                },
                .TokenTagDispatch => {
                    var ttd = try grammar_mod.token_tag_dispatch.token_tag_dispatch(self.base, self.allocator, self.base.rule(@intCast(i)).body_expr_id);
                    defer ttd.deinit(self.allocator);
                    for (ttd.trigger_rule_pairs.items) |pair| {
                        self.infos.items[@intCast(pair.rule_id)].is_triggered_by_dispatch = true;
                    }
                    continue;
                },
                // A regex or substring rule is a leaf: it references no other rules.
                .Regex, .Substring => continue,
                else => {},
            }
            // Otherwise the body is a choices of sequences.
            for (body.data) |sequence_id| {
                const seq = self.base.expr(sequence_id);
                if (seq.ty != .Sequence or seq.is_empty()) continue;
                const elements = seq.data;
                const last = self.base.expr(elements[elements.len - 1]);
                if (last.ty == .RuleRef and i != @as(usize, @intCast(last.rule_ref_id()))) {
                    self.infos.items[@intCast(last.rule_ref_id())].appears_as_last_in_other_rule = true;
                }
                for (0..elements.len - 1) |j| {
                    const element = self.base.expr(elements[j]);
                    if (element.ty != .RuleRef) continue;
                    const info = &self.infos.items[@intCast(element.rule_ref_id())];
                    if (info.non_last_occurrence_count == 0) {
                        try info.suffix_after_first_occurrence.appendSlice(self.allocator, elements[j + 1 ..]);
                    }
                    info.non_last_occurrence_count += 1;
                }
            }
        }
    }
};

test "lookahead analyzer attaches the suffix after a single non-last reference" {
    const gpa = std.testing.allocator;
    const mod = @import("../grammar/mod.zig");
    const GrammarBuilder = mod.GrammarBuilder;
    var builder = try GrammarBuilder.new(gpa);
    defer builder.deinit();
    // part ::= (("a")); root ::= ((part "b")) — normalized shape.
    const part = try builder.add_rule_named("part", try builder.add_choices(&.{try builder.add_sequence(&.{try builder.add_byte_string("a")})}));
    _ = try builder.add_rule_named(
        "root",
        try builder.add_choices(&.{try builder.add_sequence(&.{ try builder.add_rule_ref(part), try builder.add_byte_string("b") })}),
    );
    const grammar = try builder.into_grammar(gpa, "root", null);
    defer grammar.deinit();

    const analyzed = try lookahead_assertion_analyzer(gpa, grammar);
    defer analyzed.deinit();
    const la = analyzed.rule(part).lookahead_assertion_id;
    try std.testing.expect(la != NO_EXPR);
    const la_seq = analyzed.expr(la);
    try std.testing.expectEqual(@as(usize, 1), la_seq.data.len);
    const suffix = try analyzed.expr(la_seq.data[0]).byte_string(gpa);
    defer gpa.free(suffix);
    try std.testing.expectEqualStrings("b", suffix);
    try std.testing.expect(analyzed.rule(part).is_exact_lookahead);
}
