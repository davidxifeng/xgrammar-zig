//! The grammar visitor/mutator framework (`mutator.rs`).
//!
//! A mutator walks every rule and rebuilds the grammar into a fresh `GrammarBuilder`,
//! dispatching on each expression's type. The defaults form an identity transform; a pass
//! overrides the `visit_*` methods it cares about. Rust's trait defaults become free
//! functions here, and each dispatch site selects them via comptime `@hasDecl` duck
//! typing (Zig has no extension traits).

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_mod = @import("grammar/mod.zig");
const Grammar = grammar_mod.Grammar;
const GrammarBuilder = grammar_mod.GrammarBuilder;
const GrammarExprType = grammar_mod.GrammarExprType;
const tag_dispatch_mod = grammar_mod.tag_dispatch;
const token_tag_dispatch_mod = grammar_mod.token_tag_dispatch;
const error_mod = @import("error.zig");
const FunctorError = error_mod.FunctorError;

/// Traversal state: the source grammar, the builder for the result, and the rule being
/// rewritten (a hint for generated rule names). `cur_rule_name` borrows the source
/// grammar's names (read-only during a pass).
pub const MutatorState = struct {
    /// The grammar being transformed (read-only source).
    base: *const Grammar,
    /// The builder accumulating the result.
    builder: GrammarBuilder,
    /// Name of the rule currently being rewritten.
    cur_rule_name: []const u8,

    /// Scratch allocator for pass temporaries (the builder's own allocator).
    pub fn gpa(self: *const MutatorState) Allocator {
        return self.builder.allocator;
    }
};

/// Rebuilds the grammar with `mutator`'s overrides (the shared Rust trait default
/// `GrammarMutator::apply`). Rules are created empty first (preserving rule ids), then each
/// body and lookahead assertion is visited.
pub fn apply(mutator: anytype, allocator: Allocator, grammar: *const Grammar) FunctorError!*Grammar {
    var state = MutatorState{
        .base = grammar,
        .builder = try GrammarBuilder.new(allocator),
        .cur_rule_name = "",
    };
    errdefer state.builder.deinit();
    for (grammar.rules.items) |rule| _ = try state.builder.add_empty_rule(rule.name);
    for (0..@intCast(grammar.num_rules())) |i| {
        const rule = grammar.rule(@intCast(i));
        state.cur_rule_name = rule.name;
        const new_body = try visit_expr_id(mutator, &state, rule.body_expr_id);
        state.builder.update_rule_body(@intCast(i), new_body);
        const new_lookahead = try visit_lookahead(mutator, &state, rule.lookahead_assertion_id);
        state.builder.update_lookahead_assertion(@intCast(i), new_lookahead);
        try state.builder.copy_rule_attributes(@intCast(i), grammar, @intCast(i), identity_rule_id);
    }
    const root = grammar.root_rule().name;
    const result = state.builder.into_grammar(allocator, root, null) catch |err| switch (err) {
        error.RootRuleNotFound => unreachable, // root rule preserved during mutation
        else => |e| return e,
    };
    state.builder.deinit();
    return result;
}

fn identity_rule_id(id: i32) i32 {
    return id;
}

/// Visits a lookahead assertion, passing `NO_EXPR` through (the Rust trait default).
pub fn visit_lookahead(mutator: anytype, state: *MutatorState, lookahead_id: i32) FunctorError!i32 {
    if (lookahead_id == grammar_mod.NO_EXPR) return grammar_mod.NO_EXPR;
    return visit_expr_id(mutator, state, lookahead_id);
}

/// Visits the source expression with the given id (the Rust trait default).
pub fn visit_expr_id(mutator: anytype, state: *MutatorState, expr_id: i32) FunctorError!i32 {
    const expr = state.base.expr(expr_id);
    return visit_expr(mutator, state, expr.ty, expr.data);
}

/// Dispatches on the expression type (the Rust trait default), preferring the mutator's
/// overrides. `data` is borrowed from the source grammar for the duration of the call.
pub fn visit_expr(mutator: anytype, state: *MutatorState, ty: GrammarExprType, data: []const i32) FunctorError!i32 {
    const M = PassT(mutator);
    return switch (ty) {
        .Sequence => if (comptime @hasDecl(M, "visit_sequence"))
            mutator.visit_sequence(state, data)
        else
            visit_sequence_default(mutator, state, data),
        .Choices => if (comptime @hasDecl(M, "visit_choices"))
            mutator.visit_choices(state, data)
        else
            visit_choices_default(mutator, state, data),
        .EmptyStr => if (comptime @hasDecl(M, "visit_empty_str"))
            mutator.visit_empty_str(state, ty, data)
        else
            visit_element_default(state, ty, data),
        .ByteString => if (comptime @hasDecl(M, "visit_byte_string"))
            mutator.visit_byte_string(state, ty, data)
        else
            visit_element_default(state, ty, data),
        .CharacterClass => if (comptime @hasDecl(M, "visit_character_class"))
            mutator.visit_character_class(state, ty, data)
        else
            visit_element_default(state, ty, data),
        .CharacterClassStar => if (comptime @hasDecl(M, "visit_character_class_star"))
            mutator.visit_character_class_star(state, ty, data)
        else
            visit_element_default(state, ty, data),
        .RuleRef => if (comptime @hasDecl(M, "visit_rule_ref"))
            mutator.visit_rule_ref(state, ty, data)
        else
            visit_element_default(state, ty, data),
        .Repeat => if (comptime @hasDecl(M, "visit_repeat"))
            mutator.visit_repeat(state, ty, data)
        else
            visit_element_default(state, ty, data),
        .Token => if (comptime @hasDecl(M, "visit_token"))
            mutator.visit_token(state, ty, data)
        else
            visit_element_default(state, ty, data),
        .ExcludeToken => if (comptime @hasDecl(M, "visit_exclude_token"))
            mutator.visit_exclude_token(state, ty, data)
        else
            visit_element_default(state, ty, data),
        .TagDispatch => if (comptime @hasDecl(M, "visit_tag_dispatch"))
            mutator.visit_tag_dispatch(state, ty, data)
        else
            visit_tag_dispatch_default(state, data),
        .TokenTagDispatch => if (comptime @hasDecl(M, "visit_token_tag_dispatch"))
            mutator.visit_token_tag_dispatch(state, ty, data)
        else
            visit_token_tag_dispatch_default(state, data),
        .Regex, .Substring => if (comptime @hasDecl(M, "visit_element"))
            mutator.visit_element(state, ty, data)
        else
            visit_element_default(state, ty, data),
    };
}

/// Rebuilds a sequence, visiting each element (the Rust trait default).
pub fn visit_sequence_default(mutator: anytype, state: *MutatorState, data: []const i32) FunctorError!i32 {
    const gpa = state.gpa();
    var ids: std.ArrayList(i32) = .empty;
    defer ids.deinit(gpa);
    try ids.ensureTotalCapacity(gpa, data.len);
    for (data) |child| ids.appendAssumeCapacity(try visit_expr_id(mutator, state, child));
    return state.builder.add_sequence(ids.items);
}

/// Rebuilds an alternation, visiting each choice (the Rust trait default).
pub fn visit_choices_default(mutator: anytype, state: *MutatorState, data: []const i32) FunctorError!i32 {
    const gpa = state.gpa();
    var ids: std.ArrayList(i32) = .empty;
    defer ids.deinit(gpa);
    try ids.ensureTotalCapacity(gpa, data.len);
    for (data) |child| ids.appendAssumeCapacity(try visit_expr_id(mutator, state, child));
    return state.builder.add_choices(ids.items);
}

/// Re-adds a leaf expression unchanged. The per-leaf hooks below default to this
/// (Rust `GrammarMutator::visit_element`).
pub fn visit_element_default(state: *MutatorState, ty: GrammarExprType, data: []const i32) FunctorError!i32 {
    return state.builder.add_grammar_expr(ty, data);
}

/// Re-encodes a tag-dispatch payload into the fresh builder (the Rust trait default).
/// Tag-dispatch payloads embed byte-string and excludes expression ids that point into
/// the source grammar, so they are decoded and re-encoded rather than copied raw.
pub fn visit_tag_dispatch_default(state: *MutatorState, data: []const i32) FunctorError!i32 {
    const gpa = state.gpa();
    const tag_dispatch = try tag_dispatch_mod.decode_tag_dispatch_data(state.base, gpa, data);
    defer tag_dispatch.deinit(gpa);
    return state.builder.add_tag_dispatch(&tag_dispatch);
}

/// Re-encodes a token-tag-dispatch payload into the fresh builder (the Rust trait
/// default; rule ids are preserved by the rule-ordering invariant of `apply`).
pub fn visit_token_tag_dispatch_default(state: *MutatorState, data: []const i32) FunctorError!i32 {
    const gpa = state.gpa();
    const ttd = try token_tag_dispatch_mod.decode_token_tag_dispatch_data(gpa, data);
    defer ttd.deinit(gpa);
    return state.builder.add_token_tag_dispatch(&ttd);
}
