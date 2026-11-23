//! Grammar union and concatenation (`grammar_union_concat.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_mod = @import("../grammar/mod.zig");
const Grammar = grammar_mod.Grammar;
const GrammarBuilder = grammar_mod.GrammarBuilder;
const GrammarExprType = grammar_mod.GrammarExprType;
const NO_EXPR = grammar_mod.NO_EXPR;
const error_mod = @import("error.zig");
const FunctorError = error_mod.FunctorError;

/// Creates a grammar that matches any of the grammars in the list (Rust
/// `Grammar::union`; renamed: `union` is a Zig keyword).
///
/// Equivalent to using the `|` operator to concatenate the grammars in the list.
/// Panics if `grammars` is empty (Rust `assert`).
pub fn union_(allocator: Allocator, grammars: []const *const Grammar) FunctorError!*Grammar {
    std.debug.assert(grammars.len != 0); // union requires at least one grammar
    var builder = try GrammarBuilder.new(allocator);
    errdefer builder.deinit();
    const root = try builder.add_empty_rule("root");
    var choices: std.ArrayList(i32) = .empty;
    defer choices.deinit(allocator);
    try choices.ensureTotalCapacity(allocator, grammars.len);
    for (grammars) |grammar| {
        const sub_root = try add_sub_grammar(&builder, grammar);
        const rule_ref = try builder.add_rule_ref(sub_root);
        choices.appendAssumeCapacity(try builder.add_sequence(&.{rule_ref}));
    }
    const body = try builder.add_choices(choices.items);
    builder.update_rule_body(root, body);
    const result = try builder.into_grammar_with_root_id(allocator, root);
    builder.deinit();
    return result;
}

/// Creates a grammar that matches the concatenation of the grammars in the list (Rust
/// `Grammar::concat`).
///
/// Equivalent to using the `+` operator to concatenate the grammars in the list.
/// Panics if `grammars` is empty (Rust `assert`).
pub fn concat(allocator: Allocator, grammars: []const *const Grammar) FunctorError!*Grammar {
    std.debug.assert(grammars.len != 0); // concat requires at least one grammar
    var builder = try GrammarBuilder.new(allocator);
    errdefer builder.deinit();
    const root = try builder.add_empty_rule("root");
    var sequence: std.ArrayList(i32) = .empty;
    defer sequence.deinit(allocator);
    try sequence.ensureTotalCapacity(allocator, grammars.len);
    for (grammars) |grammar| {
        const sub_root = try add_sub_grammar(&builder, grammar);
        sequence.appendAssumeCapacity(try builder.add_rule_ref(sub_root));
    }
    const seq = try builder.add_sequence(sequence.items);
    const body = try builder.add_choices(&.{seq});
    builder.update_rule_body(root, body);
    const result = try builder.into_grammar_with_root_id(allocator, root);
    builder.deinit();
    return result;
}

/// Copies every rule of `sub` into `builder` (deduplicating names and remapping references),
/// returning the new id of `sub`'s root rule (Rust `pub(crate)`; re-exported for the
/// compiler wave's tag-dispatch optimization pass).
pub fn add_sub_grammar(builder: *GrammarBuilder, sub: *const Grammar) Allocator.Error!i32 {
    const gpa = builder.allocator;
    var new_rule_ids: std.ArrayList(i32) = .empty;
    defer new_rule_ids.deinit(gpa);
    try new_rule_ids.ensureTotalCapacity(gpa, @intCast(sub.num_rules()));
    for (0..@intCast(sub.num_rules())) |i| {
        const name = try builder.get_new_rule_name(sub.rule(@intCast(i)).name);
        new_rule_ids.appendAssumeCapacity(try builder.add_empty_rule(name));
    }
    for (0..@intCast(sub.num_rules())) |i| {
        const rule = sub.rule(@intCast(i));
        const body = rule.body_expr_id;
        const lookahead = rule.lookahead_assertion_id;
        const new_body = try copy_expr(builder, sub, new_rule_ids.items, body);
        builder.update_rule_body(new_rule_ids.items[i], new_body);
        const new_lookahead = if (lookahead == NO_EXPR)
            NO_EXPR
        else
            try copy_expr(builder, sub, new_rule_ids.items, lookahead);
        builder.update_lookahead_assertion(new_rule_ids.items[i], new_lookahead);
        const remapper = struct {
            ids: []const i32,
            pub fn call(self: @This(), id: i32) i32 {
                return self.ids[@intCast(id)];
            }
        }{ .ids = new_rule_ids.items };
        try builder.copy_rule_attributes(new_rule_ids.items[i], sub, @intCast(i), remapper);
    }
    return new_rule_ids.items[@intCast(sub.root_rule_id)];
}

/// Re-adds an expression from `sub` into `builder`, remapping rule references through
/// `new_rule_ids`.
fn copy_expr(
    builder: *GrammarBuilder,
    sub: *const Grammar,
    new_rule_ids: []const i32,
    expr_id: i32,
) Allocator.Error!i32 {
    const gpa = builder.allocator;
    const expr = sub.expr(expr_id);
    const ty = expr.ty;
    const data = expr.data;
    switch (ty) {
        .Sequence => {
            var ids: std.ArrayList(i32) = .empty;
            defer ids.deinit(gpa);
            try ids.ensureTotalCapacity(gpa, data.len);
            for (data) |child| ids.appendAssumeCapacity(try copy_expr(builder, sub, new_rule_ids, child));
            return builder.add_sequence(ids.items);
        },
        .Choices => {
            var ids: std.ArrayList(i32) = .empty;
            defer ids.deinit(gpa);
            try ids.ensureTotalCapacity(gpa, data.len);
            for (data) |child| ids.appendAssumeCapacity(try copy_expr(builder, sub, new_rule_ids, child));
            return builder.add_choices(ids.items);
        },
        .RuleRef => return builder.add_rule_ref(new_rule_ids[@intCast(data[0])]),
        .Repeat => return builder.add_repeat(new_rule_ids[@intCast(data[0])], data[1], data[2]),
        // Tag-dispatch payloads embed rule ids, which must be remapped into the new grammar.
        .TagDispatch => {
            var td = try grammar_mod.tag_dispatch.decode_tag_dispatch_data(sub, gpa, data);
            defer td.deinit(gpa);
            for (td.tag_rule_pairs.items) |*pair| {
                pair.rule_id = new_rule_ids[@intCast(pair.rule_id)];
            }
            return builder.add_tag_dispatch(&td);
        },
        .TokenTagDispatch => {
            var ttd = try grammar_mod.token_tag_dispatch.decode_token_tag_dispatch_data(gpa, data);
            defer ttd.deinit(gpa);
            for (ttd.trigger_rule_pairs.items) |*pair| {
                pair.rule_id = new_rule_ids[@intCast(pair.rule_id)];
            }
            return builder.add_token_tag_dispatch(&ttd);
        },
        else => return builder.add_grammar_expr(ty, data),
    }
}

test "union and concat of two grammars" {
    const gpa = std.testing.allocator;
    const GB = grammar_mod.grammar_builder.GrammarBuilder;
    var b1 = try GB.new(gpa);
    defer b1.deinit();
    _ = try b1.add_rule_named("root", try b1.add_byte_string("a"));
    const g1 = try b1.into_grammar(gpa, "root", null);
    defer g1.deinit();
    var b2 = try GB.new(gpa);
    defer b2.deinit();
    _ = try b2.add_rule_named("root", try b2.add_byte_string("bc"));
    const g2 = try b2.into_grammar(gpa, "root", null);
    defer g2.deinit();

    const u = try union_(gpa, &.{ g1, g2 });
    defer u.deinit();
    // root ::= (root_1) | (root_2)
    const printer = grammar_mod.printer;
    const u_ebnf = try printer.to_string_ebnf(u, gpa);
    defer gpa.free(u_ebnf);
    try std.testing.expectEqualStrings(
        "root ::= ((root_1) | (root_2))\nroot_1 ::= \"a\"\nroot_2 ::= \"bc\"\n",
        u_ebnf,
    );

    const c = try concat(gpa, &.{ g1, g2 });
    defer c.deinit();
    const c_ebnf = try printer.to_string_ebnf(c, gpa);
    defer gpa.free(c_ebnf);
    try std.testing.expectEqualStrings(
        "root ::= ((root_1 root_2))\nroot_1 ::= \"a\"\nroot_2 ::= \"bc\"\n",
        c_ebnf,
    );
}
