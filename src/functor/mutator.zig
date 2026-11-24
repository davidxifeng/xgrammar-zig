//! Grammar visitor/mutator and in-place rewriter frameworks (`mutator` + `in_place`).
//!
//! `apply` walks every rule of a `*const Grammar` and rebuilds a new `Grammar` into a fresh
//! `GrammarBuilder`, dispatching on each expression's type.
//! `in_place` binds a `GrammarBuilder` directly to a `*Grammar` via `editInPlace`, appending
//! new expressions only when a rewrite actually occurs.

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_mod = @import("../grammar.zig");
const Grammar = grammar_mod.Grammar;
const GrammarBuilder = grammar_mod.GrammarBuilder;
const GrammarExprType = grammar_mod.GrammarExprType;
const NO_EXPR = grammar_mod.NO_EXPR;
const dispatch = grammar_mod.dispatch;
const Compact2dArrayError = @import("../support.zig").Compact2dArrayError;

/// Error set raised by grammar transformation passes.
pub const FunctorError = Allocator.Error || Compact2dArrayError || error{
    /// A repetition range with a negative lower bound, or an upper bound below the lower one.
    InvalidRepetitionRange,
    /// A rule body could not be compiled into an automaton (e.g. an invalid regex).
    FsmBuild,
    /// A lazy rule whose body is not a choices of terminal-like sequences.
    LazyRuleBodyNotChoices,
    /// A lazy rule whose body contains an element that does not compile into the rule's own FSM.
    LazyRuleElementNotTerminal,
};

/// Traversal state for rebuilding mutators: the read-only source grammar, the builder for
/// the result, and the current rule name (hint for generated rule names).
pub const MutatorState = struct {
    base: *const Grammar,
    builder: GrammarBuilder,
    cur_rule_name: []const u8,

    /// Scratch allocator for pass temporaries (the builder's scratch allocator).
    pub fn gpa(self: *const MutatorState) Allocator {
        return self.builder.scratch_alloc;
    }
};

fn PassT(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };
}

/// Rebuilds `grammar` with `mutator`'s overrides, returning a new `Grammar` by value.
/// Rules are created empty first (preserving rule ids), then each body and lookahead
/// assertion is visited.
pub fn apply(mutator: anytype, allocator: Allocator, grammar: *const Grammar) FunctorError!Grammar {
    var state = MutatorState{
        .base = grammar,
        .builder = try GrammarBuilder.init(allocator),
        .cur_rule_name = "",
    };
    defer state.builder.deinit();

    for (grammar.rulesSlice()) |r| _ = try state.builder.addEmptyRule(r.name);
    for (0..grammar.numRules()) |i| {
        const r = grammar.rule(@intCast(i));
        state.cur_rule_name = r.name;
        const new_body = try visitExprId(mutator, &state, r.body_expr_id);
        state.builder.updateRuleBody(@intCast(i), new_body);
        const new_lookahead = try visitLookahead(mutator, &state, r.lookahead_assertion_id);
        state.builder.updateLookaheadAssertion(@intCast(i), new_lookahead);
        try state.builder.copyRuleAttributes(@intCast(i), grammar, @intCast(i), identityRuleId);
    }
    const root = grammar.rootRule().name;
    return state.builder.intoGrammar(root, null) catch |err| switch (err) {
        error.RootRuleNotFound => unreachable, // root rule preserved during mutation
        else => |e| return e,
    };
}

fn identityRuleId(id: i32) i32 {
    return id;
}

/// Visits a lookahead assertion, passing `NO_EXPR` through.
pub fn visitLookahead(mutator: anytype, state: *MutatorState, lookahead_id: i32) FunctorError!i32 {
    if (lookahead_id == NO_EXPR) return NO_EXPR;
    return visitExprId(mutator, state, lookahead_id);
}

/// Visits the source expression with the given id.
pub fn visitExprId(mutator: anytype, state: *MutatorState, expr_id: i32) FunctorError!i32 {
    const e = state.base.expr(expr_id);
    return visitExpr(mutator, state, e.ty, e.data);
}

/// Dispatches on the expression type, preferring the mutator's overrides.
pub fn visitExpr(mutator: anytype, state: *MutatorState, ty: GrammarExprType, data: []const i32) FunctorError!i32 {
    const M = PassT(@TypeOf(mutator));
    return switch (ty) {
        .Sequence => if (comptime @hasDecl(M, "visitSequence"))
            mutator.visitSequence(state, data)
        else
            visitSequenceDefault(mutator, state, data),
        .Choices => if (comptime @hasDecl(M, "visitChoices"))
            mutator.visitChoices(state, data)
        else
            visitChoicesDefault(mutator, state, data),
        .EmptyStr => if (comptime @hasDecl(M, "visitEmptyStr"))
            mutator.visitEmptyStr(state, ty, data)
        else
            visitElementDefault(state, ty, data),
        .ByteString => if (comptime @hasDecl(M, "visitByteString"))
            mutator.visitByteString(state, ty, data)
        else
            visitElementDefault(state, ty, data),
        .CharacterClass => if (comptime @hasDecl(M, "visitCharacterClass"))
            mutator.visitCharacterClass(state, ty, data)
        else
            visitElementDefault(state, ty, data),
        .CharacterClassStar => if (comptime @hasDecl(M, "visitCharacterClassStar"))
            mutator.visitCharacterClassStar(state, ty, data)
        else
            visitElementDefault(state, ty, data),
        .RuleRef => if (comptime @hasDecl(M, "visitRuleRef"))
            mutator.visitRuleRef(state, ty, data)
        else
            visitElementDefault(state, ty, data),
        .Repeat => if (comptime @hasDecl(M, "visitRepeat"))
            mutator.visitRepeat(state, ty, data)
        else
            visitElementDefault(state, ty, data),
        .Token => if (comptime @hasDecl(M, "visitToken"))
            mutator.visitToken(state, ty, data)
        else
            visitElementDefault(state, ty, data),
        .ExcludeToken => if (comptime @hasDecl(M, "visitExcludeToken"))
            mutator.visitExcludeToken(state, ty, data)
        else
            visitElementDefault(state, ty, data),
        .TagDispatch => if (comptime @hasDecl(M, "visitTagDispatch"))
            mutator.visitTagDispatch(state, ty, data)
        else
            visitTagDispatchDefault(state, data),
        .TokenTagDispatch => if (comptime @hasDecl(M, "visitTokenTagDispatch"))
            mutator.visitTokenTagDispatch(state, ty, data)
        else
            visitTokenTagDispatchDefault(state, data),
        .Regex, .Substring => if (comptime @hasDecl(M, "visitElement"))
            mutator.visitElement(state, ty, data)
        else
            visitElementDefault(state, ty, data),
    };
}

/// Rebuilds a sequence, visiting each element.
pub fn visitSequenceDefault(mutator: anytype, state: *MutatorState, data: []const i32) FunctorError!i32 {
    const alloc = state.gpa();
    var ids: std.ArrayList(i32) = .empty;
    defer ids.deinit(alloc);
    try ids.ensureTotalCapacity(alloc, data.len);
    for (data) |child| ids.appendAssumeCapacity(try visitExprId(mutator, state, child));
    return state.builder.addSequence(ids.items);
}

/// Rebuilds an alternation, visiting each choice.
pub fn visitChoicesDefault(mutator: anytype, state: *MutatorState, data: []const i32) FunctorError!i32 {
    const alloc = state.gpa();
    var ids: std.ArrayList(i32) = .empty;
    defer ids.deinit(alloc);
    try ids.ensureTotalCapacity(alloc, data.len);
    for (data) |child| ids.appendAssumeCapacity(try visitExprId(mutator, state, child));
    return state.builder.addChoices(ids.items);
}

/// Re-adds a leaf expression unchanged.
pub fn visitElementDefault(state: *MutatorState, ty: GrammarExprType, data: []const i32) FunctorError!i32 {
    return state.builder.addGrammarExpr(ty, data);
}

/// Re-encodes a tag-dispatch payload into the fresh builder.
pub fn visitTagDispatchDefault(state: *MutatorState, data: []const i32) FunctorError!i32 {
    const alloc = state.gpa();
    var td = try dispatch.decodeTagDispatchData(state.base, alloc, data);
    defer td.deinit(alloc);
    return state.builder.addTagDispatch(&td);
}

/// Re-encodes a token-tag-dispatch payload into the fresh builder.
pub fn visitTokenTagDispatchDefault(state: *MutatorState, data: []const i32) FunctorError!i32 {
    const alloc = state.gpa();
    var ttd = try dispatch.decodeTokenTagDispatchData(alloc, data);
    defer ttd.deinit(alloc);
    return state.builder.addTokenTagDispatch(&ttd);
}

/// In-place grammar rewriting framework (`editInPlace` + `editInPlaceCommit`).
///
/// Unchanged subtrees keep their original expression ids and allocate nothing.
pub const in_place = struct {
    /// Rewrites every rule body and lookahead assertion of `grammar` in place using
    /// `rewriter`'s `visitSequence` / `visitChoices` overrides.
    pub fn apply(rewriter: anytype, grammar: *Grammar) (Allocator.Error || Compact2dArrayError)!void {
        var builder = GrammarBuilder.editInPlace(grammar);
        defer builder.deinit();
        try rewriteAll(rewriter, &builder);
        builder.editInPlaceCommit(grammar);
    }

    /// Walks all rules of an `editInPlace` builder without committing.
    pub fn rewriteAll(rewriter: anytype, builder: *GrammarBuilder) (Allocator.Error || Compact2dArrayError)!void {
        const alloc = builder.scratch_alloc;
        // Expr ids are dense, so the memo is a plain array over the original exprs.
        const memo = try alloc.alloc(i32, @intCast(builder.numGrammarExprs()));
        defer alloc.free(memo);
        @memset(memo, NO_EXPR);
        for (0..@intCast(builder.numRules())) |rule_id| {
            const body_expr_id = builder.getRule(@intCast(rule_id)).body_expr_id;
            const new_body_expr_id = try in_place.visitExpr(rewriter, builder, memo, body_expr_id);
            if (new_body_expr_id != body_expr_id) {
                builder.updateRuleBody(@intCast(rule_id), new_body_expr_id);
            }
            const lookahead_id = builder.getRule(@intCast(rule_id)).lookahead_assertion_id;
            if (lookahead_id != NO_EXPR) {
                const new_lookahead_id = try in_place.visitExpr(rewriter, builder, memo, lookahead_id);
                if (new_lookahead_id != lookahead_id) {
                    builder.updateLookaheadAssertion(@intCast(rule_id), new_lookahead_id);
                }
            }
        }
    }

    /// Visits an original expr, returning its rewritten id or the original id when unchanged.
    pub fn visitExpr(
        rewriter: anytype,
        builder: *GrammarBuilder,
        memo: []i32,
        expr_id: i32,
    ) (Allocator.Error || Compact2dArrayError)!i32 {
        if (memo[@intCast(expr_id)] != NO_EXPR) {
            return memo[@intCast(expr_id)];
        }
        const result: i32 = switch (builder.grammarExpr(expr_id).ty) {
            .Sequence => try in_place.visitSequence(rewriter, builder, memo, expr_id),
            .Choices => try in_place.visitChoices(rewriter, builder, memo, expr_id),
            else => expr_id,
        };
        memo[@intCast(expr_id)] = result;
        return result;
    }

    /// Rebuilds a sequence when any element changed.
    pub fn visitSequence(
        rewriter: anytype,
        builder: *GrammarBuilder,
        memo: []i32,
        expr_id: i32,
    ) (Allocator.Error || Compact2dArrayError)!i32 {
        const M = PassT(@TypeOf(rewriter));
        if (comptime @hasDecl(M, "visitSequence")) {
            return rewriter.visitSequence(builder, memo, expr_id);
        }
        if (try in_place.visitChildren(rewriter, builder, memo, expr_id)) |new_element_ids_const| {
            var new_element_ids = new_element_ids_const;
            defer new_element_ids.deinit(builder.scratch_alloc);
            return builder.addSequence(new_element_ids.items);
        }
        return expr_id;
    }

    /// Rebuilds a choices when any choice changed.
    pub fn visitChoices(
        rewriter: anytype,
        builder: *GrammarBuilder,
        memo: []i32,
        expr_id: i32,
    ) (Allocator.Error || Compact2dArrayError)!i32 {
        const M = PassT(@TypeOf(rewriter));
        if (comptime @hasDecl(M, "visitChoices")) {
            return rewriter.visitChoices(builder, memo, expr_id);
        }
        if (try in_place.visitChildren(rewriter, builder, memo, expr_id)) |new_choice_ids_const| {
            var new_choice_ids = new_choice_ids_const;
            defer new_choice_ids.deinit(builder.scratch_alloc);
            return builder.addChoices(new_choice_ids.items);
        }
        return expr_id;
    }

    /// Visits each child of a sequence or choices, returning the new child ids if any changed.
    /// Allocates nothing when no child changes.
    pub fn visitChildren(
        rewriter: anytype,
        builder: *GrammarBuilder,
        memo: []i32,
        expr_id: i32,
    ) (Allocator.Error || Compact2dArrayError)!?std.ArrayList(i32) {
        const size = builder.grammarExpr(expr_id).len();
        const alloc = builder.scratch_alloc;
        var new_child_ids: ?std.ArrayList(i32) = null;
        errdefer if (new_child_ids) |*ids| ids.deinit(alloc);
        for (0..size) |index| {
            // Re-read parent by id each step in case a child rewrite appended to `builder`.
            const child_id = builder.grammarExpr(expr_id).data[index];
            const new_child_id = try in_place.visitExpr(rewriter, builder, memo, child_id);
            if (new_child_ids == null and new_child_id != child_id) {
                var ids: std.ArrayList(i32) = .empty;
                try ids.appendSlice(alloc, builder.grammarExpr(expr_id).data[0..index]);
                new_child_ids = ids;
            }
            if (new_child_ids) |*ids| try ids.append(alloc, new_child_id);
        }
        return new_child_ids;
    }
};

test "mutator identity and in_place no-op preserve grammar" {
    const a = std.testing.allocator;
    var builder = try GrammarBuilder.init(a);
    defer builder.deinit();
    const bs = try builder.addByteString("hi");
    const seq = try builder.addSequence(&.{bs});
    const choices = try builder.addChoices(&.{seq});
    _ = try builder.addRuleNamed("root", choices);
    var g = try builder.intoGrammar("root", null);
    defer g.deinit();

    const Identity = struct {};
    var copy = try apply(Identity{}, a, &g);
    defer copy.deinit();
    try std.testing.expect(g.eql(&copy));

    const orig_exprs = g.numExprs();
    try in_place.apply(Identity{}, &g);
    try std.testing.expectEqual(orig_exprs, g.numExprs());
    try std.testing.expect(g.eql(&copy));
}
