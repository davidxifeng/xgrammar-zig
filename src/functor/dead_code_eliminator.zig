//! Removes rules unreachable from the root (`dead_code_eliminator.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_mod = @import("grammar/mod.zig");
const Grammar = grammar_mod.Grammar;
const GrammarExprType = grammar_mod.GrammarExprType;
const NO_EXPR = grammar_mod.NO_EXPR;
const mutator = @import("mutator.zig");
const MutatorState = mutator.MutatorState;
const error_mod = @import("error.zig");
const FunctorError = error_mod.FunctorError;

/// Drops rules that are unreachable from the root, remapping rule ids (the
/// `GrammarFunctor.dead_code_eliminator` pass).
pub fn dead_code_eliminator(allocator: Allocator, grammar: *const Grammar) FunctorError!*Grammar {
    const gpa = allocator;
    const used = try used_rules(gpa, grammar);
    defer gpa.free(used);
    var pass = DeadCodeEliminator{ .rule_id_map = std.AutoHashMap(i32, i32).init(gpa) };
    defer pass.rule_id_map.deinit();
    var state = MutatorState{
        .base = grammar,
        .builder = try grammar_mod.GrammarBuilder.new(gpa),
        .cur_rule_name = "",
    };
    errdefer state.builder.deinit();
    // Recreate the surviving rules (in ascending old-id order), recording old → new ids.
    for (used) |old_id| {
        const new_id = try state.builder.add_empty_rule(grammar.rule(old_id).name);
        try pass.rule_id_map.put(gpa, old_id, new_id);
    }
    for (used) |old_id| {
        const rule = grammar.rule(old_id);
        state.cur_rule_name = rule.name;
        const new_body = try mutator.visit_expr_id(&pass, &state, rule.body_expr_id);
        const new_id = pass.rule_id_map.get(old_id).?;
        state.builder.update_rule_body(new_id, new_body);
        const new_lookahead = try mutator.visit_lookahead(&pass, &state, rule.lookahead_assertion_id);
        state.builder.update_lookahead_assertion(new_id, new_lookahead);
        try copy_attributes_remapped(&state.builder, new_id, grammar, old_id, &pass);
    }
    const new_root = pass.rule_id_map.get(grammar.root_rule_id).?;
    const result = try state.builder.into_grammar_with_root_id(gpa, new_root);
    state.builder.deinit();
    return result;
}

/// Rust `copy_rule_attributes` with the rule-id closure `|id| pass.rule_id_map[&id]`;
/// spelled out here because Zig has no closures (matches `GrammarBuilder.copy_rule_attributes`).
fn copy_attributes_remapped(
    builder: *grammar_mod.GrammarBuilder,
    rule_id: i32,
    grammar: *const Grammar,
    source_rule_id: i32,
    pass: *const DeadCodeEliminator,
) Allocator.Error!void {
    const rule = grammar.rule(source_rule_id);
    builder.update_max_tokens(rule_id, rule.max_tokens);
    builder.update_max_chars(rule_id, rule.max_chars);
    try builder.update_capture_name(rule_id, rule.capture_name);
    if (grammar.suffix_stop_info(source_rule_id)) |info_src| {
        var info = try grammar_mod.grammar.dupe_suffix_stop_info(builder.allocator, info_src.*);
        if (info.body_rule_id >= 0) {
            info.body_rule_id = pass.rule_id_map.get(info.body_rule_id).?;
            info.marker_rule_id = pass.rule_id_map.get(info.marker_rule_id).?;
        }
        try builder.update_suffix_stop_info(rule_id, info);
    }
    builder.update_lazy(rule_id, rule.is_lazy);
    builder.update_rule_temperature(rule_id, rule.temperature);
}

const DeadCodeEliminator = struct {
    rule_id_map: std.AutoHashMap(i32, i32),

    fn visit_rule_ref(
        self: *DeadCodeEliminator,
        state: *MutatorState,
        ty: GrammarExprType,
        data: []const i32,
    ) FunctorError!i32 {
        _ = ty;
        const new_id = self.rule_id_map.get(data[0]).?;
        return state.builder.add_rule_ref(new_id);
    }

    fn visit_repeat(
        self: *DeadCodeEliminator,
        state: *MutatorState,
        ty: GrammarExprType,
        data: []const i32,
    ) FunctorError!i32 {
        _ = ty;
        const new_id = self.rule_id_map.get(data[0]).?;
        return state.builder.add_repeat(new_id, data[1], data[2]);
    }

    /// Tag-dispatch payloads embed rule ids, which the rule remapping must also follow.
    fn visit_tag_dispatch(
        self: *DeadCodeEliminator,
        state: *MutatorState,
        ty: GrammarExprType,
        data: []const i32,
    ) FunctorError!i32 {
        _ = ty;
        const gpa = state.gpa();
        var td = try grammar_mod.tag_dispatch.decode_tag_dispatch_data(state.base, gpa, data);
        defer td.deinit(gpa);
        for (td.tag_rule_pairs.items) |*pair| {
            pair.rule_id = self.rule_id_map.get(pair.rule_id).?;
        }
        return state.builder.add_tag_dispatch(&td);
    }

    fn visit_token_tag_dispatch(
        self: *DeadCodeEliminator,
        state: *MutatorState,
        ty: GrammarExprType,
        data: []const i32,
    ) FunctorError!i32 {
        _ = ty;
        const gpa = state.gpa();
        var ttd = try grammar_mod.token_tag_dispatch.decode_token_tag_dispatch_data(gpa, data);
        defer ttd.deinit(gpa);
        for (ttd.trigger_rule_pairs.items) |*pair| {
            pair.rule_id = self.rule_id_map.get(pair.rule_id).?;
        }
        return state.builder.add_token_tag_dispatch(&ttd);
    }
};

/// Returns, in ascending order, the ids of all rules reachable from the root, counting the
/// helper rules of suffix/stop metadata as referenced. Allocated from `allocator`.
fn used_rules(allocator: Allocator, grammar: *const Grammar) Allocator.Error![]i32 {
    var visited = std.AutoArrayHashMap(i32, void).init(allocator);
    defer visited.deinit();
    var queue = std.Deque(i32).init(allocator);
    defer queue.deinit();
    try queue.push_back(grammar.root_rule_id);
    while (queue.pop_front()) |rule_id| {
        const gop = try visited.getOrPut(rule_id);
        if (gop.found_existing) continue;
        const rule = grammar.rule(rule_id);
        try collect_rule_refs(allocator, grammar, rule.body_expr_id, &queue);
        if (rule.lookahead_assertion_id != NO_EXPR) {
            try collect_rule_refs(allocator, grammar, rule.lookahead_assertion_id, &queue);
        }
        if (grammar.suffix_stop_info(rule_id)) |info| {
            if (info.body_rule_id != -1) {
                try queue.push_back(info.body_rule_id);
                try queue.push_back(info.marker_rule_id);
            }
        }
    }
    const result = try allocator.dupe(i32, visited.keys());
    std.mem.sort(i32, result, {}, std.sort.asc(i32));
    return result;
}

/// Pushes every rule referenced (directly or via nested sequence/choices) by `expr_id`.
fn collect_rule_refs(
    allocator: Allocator,
    grammar: *const Grammar,
    expr_id: i32,
    queue: *std.Deque(i32),
) Allocator.Error!void {
    const expr = grammar.expr(expr_id);
    switch (expr.ty) {
        .RuleRef, .Repeat => try queue.push_back(expr.data[0]),
        .Sequence, .Choices => {
            for (expr.data) |child| try collect_rule_refs(allocator, grammar, child, queue);
        },
        .TagDispatch => {
            const td = try grammar_mod.tag_dispatch.tag_dispatch(grammar, allocator, expr_id);
            defer td.deinit(allocator);
            for (td.tag_rule_pairs.items) |pair| try queue.push_back(pair.rule_id);
        },
        .TokenTagDispatch => {
            const ttd = try grammar_mod.token_tag_dispatch.token_tag_dispatch(grammar, allocator, expr_id);
            defer ttd.deinit(allocator);
            for (ttd.trigger_rule_pairs.items) |pair| try queue.push_back(pair.rule_id);
        },
        else => {},
    }
}

test "dead code eliminator keeps reachable rules and remaps refs" {
    const gpa = std.testing.allocator;
    const mod = @import("grammar/mod.zig");
    const GrammarBuilder = mod.GrammarBuilder;
    var builder = try GrammarBuilder.new(gpa);
    defer builder.deinit();
    // unused ::= "z" (unreferenced); keep ::= "a"; root[+tokens] ::= keep
    _ = try builder.add_rule_named("unused", try builder.add_byte_string("z"));
    const keep = try builder.add_rule_named("keep", try builder.add_byte_string("a"));
    const root = try builder.add_rule_named("root", try builder.add_rule_ref(keep));
    try builder.update_max_tokens(root, 5);
    const grammar = try builder.into_grammar(gpa, "root", null);
    defer grammar.deinit();

    const reduced = try dead_code_eliminator(gpa, grammar);
    defer reduced.deinit();
    try std.testing.expectEqual(@as(i32, 2), reduced.num_rules());
    try std.testing.expectEqualStrings("keep", reduced.rule(0).name);
    try std.testing.expectEqualStrings("root", reduced.rule(1).name);
    try std.testing.expectEqual(root, reduced.root_rule_id);
    try std.testing.expectEqual(@as(i32, 5), reduced.rule(1).max_tokens);
    const body = reduced.expr(reduced.rule(1).body_expr_id);
    try std.testing.expectEqual(@as(i32, 0), body.data[0]); // ref remapped old keep(1) → 0
}
