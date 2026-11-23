//! Base for grammar passes that rewrite a grammar in place (`in_place_grammar_rewriter.rs`).
//!
//! The rewriter binds a `GrammarBuilder` directly to the target grammar (no copy) and walks
//! every rule body and lookahead assertion. An expr whose subtree is unchanged keeps its
//! original id; a new expr is appended only where a rewrite actually happens, so a pass with
//! nothing to do writes nothing. Changed ids propagate upward: a container is rebuilt when
//! any child changed, and a rule body or lookahead is updated when its expr changed. Stale
//! exprs left behind are removed later by the dead code eliminator.

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_mod = @import("grammar/mod.zig");
const Grammar = grammar_mod.Grammar;
const GrammarBuilder = grammar_mod.GrammarBuilder;
const GrammarExprType = grammar_mod.GrammarExprType;
const NO_EXPR = grammar_mod.NO_EXPR;

/// Rewrites every rule body and lookahead assertion of `grammar` in place with
/// `rewriter`'s `visit_sequence`/`visit_choices` overrides (the Rust trait default
/// `InPlaceGrammarRewriter::apply`).
pub fn apply(rewriter: anytype, grammar: *Grammar) Allocator.Error!void {
    var builder = try GrammarBuilder.edit_in_place(grammar);
    defer builder.deinit();
    try rewrite_all(rewriter, &builder);
    builder.edit_in_place_commit(grammar);
}

/// The Rust closure body of `apply`, factored out so `grammar_fsm_builder` can run the
/// same walk over an `edit_in_place` builder without committing.
pub fn rewrite_all(rewriter: anytype, builder: *GrammarBuilder) Allocator.Error!void {
    const gpa = builder.allocator;
    // Expr ids are dense, so the memo is a plain array over the original exprs. Appended
    // exprs are never visited again, so they need no memo slots.
    const memo = try gpa.alloc(i32, @intCast(builder.num_grammar_exprs()));
    defer gpa.free(memo);
    @memset(memo, NO_EXPR);
    for (0..@intCast(builder.num_rules())) |rule_id| {
        const body_expr_id = builder.get_rule(@intCast(rule_id)).body_expr_id;
        const new_body_expr_id = try visit_expr(rewriter, builder, memo, body_expr_id);
        if (new_body_expr_id != body_expr_id) {
            builder.update_rule_body(@intCast(rule_id), new_body_expr_id);
        }
        const lookahead_id = builder.get_rule(@intCast(rule_id)).lookahead_assertion_id;
        if (lookahead_id != NO_EXPR) {
            const new_lookahead_id = try visit_expr(rewriter, builder, memo, lookahead_id);
            if (new_lookahead_id != lookahead_id) {
                builder.update_lookahead_assertion(@intCast(rule_id), new_lookahead_id);
            }
        }
    }
}

/// Visits an original expr, returning its rewritten id, or the original id when nothing
/// changed. `memo` maps each original expr id to its result (`NO_EXPR` while unvisited).
pub fn visit_expr(rewriter: anytype, builder: *GrammarBuilder, memo: []i32, expr_id: i32) Allocator.Error!i32 {
    if (memo[@intCast(expr_id)] != NO_EXPR) {
        return memo[@intCast(expr_id)];
    }
    const result: i32 = switch (builder.grammar_expr(expr_id).ty) {
        .Sequence => try visit_sequence(rewriter, builder, memo, expr_id),
        .Choices => try visit_choices(rewriter, builder, memo, expr_id),
        else => expr_id,
    };
    memo[@intCast(expr_id)] = result;
    return result;
}

/// Rebuilds a sequence when any element changed (the Rust trait default; the `@hasDecl`
/// dispatch mirrors trait-method overriding).
pub fn visit_sequence(rewriter: anytype, builder: *GrammarBuilder, memo: []i32, expr_id: i32) Allocator.Error!i32 {
    const M = PassT(rewriter);
    if (comptime @hasDecl(M, "visit_sequence")) {
        return rewriter.visit_sequence(builder, memo, expr_id);
    }
    if (try visit_children(rewriter, builder, memo, expr_id)) |new_element_ids| {
        defer new_element_ids.deinit(builder.allocator);
        return builder.add_sequence(new_element_ids.items);
    }
    return expr_id;
}

/// Rebuilds a choices when any choice changed (the Rust trait default).
pub fn visit_choices(rewriter: anytype, builder: *GrammarBuilder, memo: []i32, expr_id: i32) Allocator.Error!i32 {
    const M = PassT(rewriter);
    if (comptime @hasDecl(M, "visit_choices")) {
        return rewriter.visit_choices(builder, memo, expr_id);
    }
    if (try visit_children(rewriter, builder, memo, expr_id)) |new_choice_ids| {
        defer new_choice_ids.deinit(builder.allocator);
        return builder.add_choices(new_choice_ids.items);
    }
    return expr_id;
}

/// Visits each child of a sequence or choices, returning the new child ids if any changed.
/// No memory is allocated when no child changes.
pub fn visit_children(
    rewriter: anytype,
    builder: *GrammarBuilder,
    memo: []i32,
    expr_id: i32,
) Allocator.Error!?std.ArrayList(i32) {
    const size = builder.grammar_expr(expr_id).len();
    const gpa = builder.allocator;
    var new_child_ids: ?std.ArrayList(i32) = null;
    errdefer if (new_child_ids) |*ids| ids.deinit(gpa);
    for (0..size) |index| {
        // A visit may append exprs, so the parent is re-read by id rather than held as a view.
        const child_id = builder.grammar_expr(expr_id).data[index];
        const new_child_id = try visit_expr(rewriter, builder, memo, child_id);
        if (new_child_ids == null and new_child_id != child_id) {
            // Materialize the already scanned, unchanged prefix on the first change.
            var ids: std.ArrayList(i32) = .empty;
            try ids.appendSlice(gpa, builder.grammar_expr(expr_id).data[0..index]);
            new_child_ids = ids;
        }
        if (new_child_ids) |*ids| try ids.append(gpa, new_child_id);
    }
    return new_child_ids;
}
