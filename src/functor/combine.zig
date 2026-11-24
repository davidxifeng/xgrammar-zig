//! Grammar union, concatenation, and sub-grammar merging (`combine`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_mod = @import("../grammar.zig");
const Grammar = grammar_mod.Grammar;
const GrammarBuilder = grammar_mod.GrammarBuilder;
const NO_EXPR = grammar_mod.NO_EXPR;
const dispatch = grammar_mod.dispatch;

/// Creates a grammar that matches any grammar in `grammars` (`g0 | g1 | ...`).
/// Asserts `grammars.len != 0`.
pub fn unionOf(allocator: Allocator, grammars: []const Grammar) Allocator.Error!Grammar {
    std.debug.assert(grammars.len != 0);
    var builder = try GrammarBuilder.init(allocator);
    defer builder.deinit();
    const root = try builder.addEmptyRule("root");
    var choices: std.ArrayList(i32) = .empty;
    defer choices.deinit(allocator);
    try choices.ensureTotalCapacity(allocator, grammars.len);
    for (grammars) |*grammar| {
        const sub_root = try addSubGrammar(&builder, grammar);
        const rule_ref = try builder.addRuleRef(sub_root);
        choices.appendAssumeCapacity(try builder.addSequence(&.{rule_ref}));
    }
    const body = try builder.addChoices(choices.items);
    builder.updateRuleBody(root, body);
    return builder.intoGrammarWithRootId(root);
}

/// Creates a grammar that matches the concatenation of `grammars` (`g0 g1 ...`).
/// Asserts `grammars.len != 0`.
pub fn concatOf(allocator: Allocator, grammars: []const Grammar) Allocator.Error!Grammar {
    std.debug.assert(grammars.len != 0);
    var builder = try GrammarBuilder.init(allocator);
    defer builder.deinit();
    const root = try builder.addEmptyRule("root");
    var sequence: std.ArrayList(i32) = .empty;
    defer sequence.deinit(allocator);
    try sequence.ensureTotalCapacity(allocator, grammars.len);
    for (grammars) |*grammar| {
        const sub_root = try addSubGrammar(&builder, grammar);
        sequence.appendAssumeCapacity(try builder.addRuleRef(sub_root));
    }
    const seq = try builder.addSequence(sequence.items);
    const body = try builder.addChoices(&.{seq});
    builder.updateRuleBody(root, body);
    return builder.intoGrammarWithRootId(root);
}

/// Copies every rule of `sub` into `builder` (deduplicating names and remapping rule ids),
/// returning the new id of `sub`'s root rule.
pub fn addSubGrammar(builder: *GrammarBuilder, sub: *const Grammar) Allocator.Error!i32 {
    const alloc = builder.scratch_alloc;
    const num_rules = sub.numRules();
    var new_rule_ids: std.ArrayList(i32) = .empty;
    defer new_rule_ids.deinit(alloc);
    try new_rule_ids.ensureTotalCapacity(alloc, num_rules);
    for (0..num_rules) |i| {
        const name = try builder.getNewRuleName(sub.rule(@intCast(i)).name);
        new_rule_ids.appendAssumeCapacity(try builder.addEmptyRule(name));
    }
    const remapper = struct {
        ids: []const i32,
        pub fn call(self: @This(), id: i32) i32 {
            return self.ids[@intCast(id)];
        }
    }{ .ids = new_rule_ids.items };

    for (0..num_rules) |i| {
        const r = sub.rule(@intCast(i));
        const new_body = try copyExpr(builder, sub, new_rule_ids.items, r.body_expr_id);
        builder.updateRuleBody(new_rule_ids.items[i], new_body);
        const new_lookahead = if (r.lookahead_assertion_id == NO_EXPR)
            NO_EXPR
        else
            try copyExpr(builder, sub, new_rule_ids.items, r.lookahead_assertion_id);
        builder.updateLookaheadAssertion(new_rule_ids.items[i], new_lookahead);
        try builder.copyRuleAttributes(new_rule_ids.items[i], sub, @intCast(i), remapper);
    }
    return new_rule_ids.items[@intCast(sub.rootRuleId())];
}

fn copyExpr(
    builder: *GrammarBuilder,
    sub: *const Grammar,
    new_rule_ids: []const i32,
    expr_id: i32,
) Allocator.Error!i32 {
    const alloc = builder.scratch_alloc;
    const e = sub.expr(expr_id);
    const data = e.data;
    switch (e.ty) {
        .Sequence => {
            var ids: std.ArrayList(i32) = .empty;
            defer ids.deinit(alloc);
            try ids.ensureTotalCapacity(alloc, data.len);
            for (data) |child| ids.appendAssumeCapacity(try copyExpr(builder, sub, new_rule_ids, child));
            return builder.addSequence(ids.items);
        },
        .Choices => {
            var ids: std.ArrayList(i32) = .empty;
            defer ids.deinit(alloc);
            try ids.ensureTotalCapacity(alloc, data.len);
            for (data) |child| ids.appendAssumeCapacity(try copyExpr(builder, sub, new_rule_ids, child));
            return builder.addChoices(ids.items);
        },
        .RuleRef => return builder.addRuleRef(new_rule_ids[@intCast(data[0])]),
        .Repeat => return builder.addRepeat(new_rule_ids[@intCast(data[0])], data[1], data[2]),
        .TagDispatch => {
            var td = try dispatch.decodeTagDispatchData(sub, alloc, data);
            defer td.deinit(alloc);
            for (td.tag_rule_pairs.items) |*pair| {
                pair.rule_id = new_rule_ids[@intCast(pair.rule_id)];
            }
            return builder.addTagDispatch(&td);
        },
        .TokenTagDispatch => {
            var ttd = try dispatch.decodeTokenTagDispatchData(alloc, data);
            defer ttd.deinit(alloc);
            for (ttd.trigger_rule_pairs.items) |*pair| {
                pair.rule_id = new_rule_ids[@intCast(pair.rule_id)];
            }
            return builder.addTokenTagDispatch(&ttd);
        },
        else => return builder.addGrammarExpr(e.ty, data),
    }
}

test "unionOf and concatOf merge two grammars cleanly" {
    const gpa = std.testing.allocator;
    var b1 = try GrammarBuilder.init(gpa);
    defer b1.deinit();
    _ = try b1.addRuleNamed("root", try b1.addByteString("a"));
    var g1 = try b1.intoGrammar("root", null);
    defer g1.deinit();

    var b2 = try GrammarBuilder.init(gpa);
    defer b2.deinit();
    _ = try b2.addRuleNamed("root", try b2.addByteString("bc"));
    var g2 = try b2.intoGrammar("root", null);
    defer g2.deinit();

    var u = try unionOf(gpa, &.{ g1, g2 });
    defer u.deinit();
    const u_ebnf = try u.toStringEbnf(gpa);
    defer gpa.free(u_ebnf);
    try std.testing.expectEqualStrings(
        "root ::= ((root_1) | (root_2))\nroot_1 ::= \"a\"\nroot_2 ::= \"bc\"\n",
        u_ebnf,
    );

    var c = try concatOf(gpa, &.{ g1, g2 });
    defer c.deinit();
    const c_ebnf = try c.toStringEbnf(gpa);
    defer gpa.free(c_ebnf);
    try std.testing.expectEqualStrings(
        "root ::= ((root_1 root_2))\nroot_1 ::= \"a\"\nroot_2 ::= \"bc\"\n",
        c_ebnf,
    );
}
