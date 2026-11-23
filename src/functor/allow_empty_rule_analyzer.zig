//! Determines which rules can match the empty string (`allow_empty_rule_analyzer.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_mod = @import("../grammar/mod.zig");
const Grammar = grammar_mod.Grammar;
const GrammarExprType = grammar_mod.GrammarExprType;
const fsm_mod = @import("../fsm/mod.zig");
const RegexFsmBuilder = fsm_mod.RegexFsmBuilder;

/// Returns the sorted ids of rules that can derive the empty string.
/// The result is allocated from `allocator`; the caller owns it.
pub fn allow_empty_rule_ids(allocator: Allocator, grammar: *const Grammar) Allocator.Error![]i32 {
    var empty = std.AutoHashMap(i32, void).init(allocator);
    defer empty.deinit();
    try find_explicit_empty_rules(allocator, grammar, &empty);
    const graph = try rule_ref_graph(allocator, grammar);
    defer {
        for (graph) |*refs| refs.deinit(allocator);
        allocator.free(graph);
    }
    try find_indirect_empty_rules(allocator, grammar, &empty, graph);
    var result: std.ArrayList(i32) = .empty;
    errdefer result.deinit(allocator);
    var it = empty.keyIterator();
    while (it.next()) |key| try result.append(allocator, key.*);
    std.mem.sort(i32, result.items, {}, std.sort.asc(i32));
    return result.toOwnedSlice(allocator);
}

/// Builds the inverse reference graph: `graph[referee] = [referrers]`.
/// Allocated from `allocator` (one list per rule); the caller owns the result.
pub fn rule_ref_graph(allocator: Allocator, grammar: *const Grammar) Allocator.Error![]std.ArrayList(i32) {
    const n: usize = @intCast(grammar.num_rules());
    const graph = try allocator.alloc(std.ArrayList(i32), n);
    for (graph) |*refs| refs.* = .empty;
    var ok = true;
    errdefer if (!ok) {
        for (graph) |*refs| refs.deinit(allocator);
        allocator.free(graph);
    };
    for (0..n) |cur| {
        const body_id = grammar.rule(@intCast(cur)).body_expr_id;
        try visit_refs(allocator, grammar, body_id, @intCast(cur), graph);
    }
    for (graph) |*refs| {
        std.mem.sort(i32, refs.items, {}, std.sort.asc(i32));
        _ = dedup_sorted(refs);
    }
    ok = true;
    return graph;
}

/// In-place dedup of a sorted list (Rust `Vec::dedup`).
fn dedup_sorted(list: *std.ArrayList(i32)) usize {
    var write: usize = 0;
    for (list.items, 0..) |v, read| {
        if (read == 0 or list.items[write - 1] != v) {
            list.items[write] = v;
            write += 1;
        }
    }
    list.shrinkRetainingCapacity(write);
    return write;
}

fn visit_refs(
    allocator: Allocator,
    grammar: *const Grammar,
    expr_id: i32,
    cur_rule: i32,
    graph: []std.ArrayList(i32),
) Allocator.Error!void {
    const expr = grammar.expr(expr_id);
    switch (expr.ty) {
        .Choices, .Sequence => {
            for (expr.data) |child| try visit_refs(allocator, grammar, child, cur_rule, graph);
        },
        .RuleRef, .Repeat => try graph[@intCast(expr.data[0])].append(allocator, cur_rule),
        .TagDispatch => {
            var td = try grammar_mod.tag_dispatch.tag_dispatch(grammar, allocator, expr_id);
            defer td.deinit(allocator);
            for (td.tag_rule_pairs.items) |pair| try graph[@intCast(pair.rule_id)].append(allocator, cur_rule);
        },
        .TokenTagDispatch => {
            var ttd = try grammar_mod.token_tag_dispatch.token_tag_dispatch(grammar, allocator, expr_id);
            defer ttd.deinit(allocator);
            for (ttd.trigger_rule_pairs.items) |pair| try graph[@intCast(pair.rule_id)].append(allocator, cur_rule);
        },
        else => {},
    }
}

fn find_explicit_empty_rules(
    allocator: Allocator,
    grammar: *const Grammar,
    empty: *std.AutoHashMap(i32, void),
) Allocator.Error!void {
    for (0..@intCast(grammar.num_rules())) |i| {
        const body = grammar.expr(grammar.rule(@intCast(i)).body_expr_id);
        switch (body.ty) {
            // A substring automaton always accepts the empty string: every state is accepting.
            .TagDispatch, .TokenTagDispatch, .Substring => {
                try empty.put(@intCast(i), {});
                continue;
            },
            // Nullability is checked syntactically on the parsed regex; parse errors are
            // reported by the FSM builder later.
            .Regex => {
                const pattern = try body.regex_pattern(allocator);
                defer allocator.free(pattern);
                var err_msg: ?[]u8 = null;
                defer if (err_msg) |m| allocator.free(m);
                if (RegexFsmBuilder.matches_empty(allocator, pattern, &err_msg)) |matches| {
                    if (matches) try empty.put(@intCast(i), {});
                } else |_| {}
                continue;
            },
            else => {},
        }
        // Otherwise it is a choices expr.
        if (grammar.expr(body.data[0]).ty == .EmptyStr) {
            try empty.put(@intCast(i), {});
            continue;
        }
        for (body.data) |seq_id| {
            const seq = grammar.expr(seq_id);
            var all_star = seq.data.len > 0;
            for (seq.data) |e| {
                if (grammar.expr(e).ty != .CharacterClassStar) {
                    all_star = false;
                    break;
                }
            }
            if (all_star) {
                try empty.put(@intCast(i), {});
                break;
            }
        }
    }
}

/// Whether a sequence expr derives epsilon given the currently-known empty rules.
fn seq_expr_is_epsilon(
    grammar: *const Grammar,
    seq_id: i32,
    empty: *const std.AutoHashMap(i32, void),
) bool {
    const seq = grammar.expr(seq_id);
    if (seq.ty == .EmptyStr) return true;
    for (seq.data) |i| {
        const element = grammar.expr(i);
        switch (element.ty) {
            .RuleRef => if (!empty.contains(element.data[0])) return false,
            .CharacterClassStar => {},
            .Repeat => if (!empty.contains(element.data[0]) and element.data[1] != 0) return false,
            else => return false,
        }
    }
    return true;
}

fn find_indirect_empty_rules(
    allocator: Allocator,
    grammar: *const Grammar,
    empty: *std.AutoHashMap(i32, void),
    graph: []const std.ArrayList(i32),
) Allocator.Error!void {
    var queue: std.Deque(i32) = .empty;
    defer queue.deinit(allocator);
    var it = empty.keyIterator();
    while (it.next()) |key| try queue.pushBack(allocator,key.*);
    while (queue.popFront()) |rule_id| {
        for (graph[@intCast(rule_id)].items) |referrer| {
            if (empty.contains(referrer)) continue;
            const body = grammar.expr(grammar.rule(@intCast(referrer)).body_expr_id);
            var is_epsilon = false;
            for (body.data) |seq_id| {
                if (seq_expr_is_epsilon(grammar, seq_id, empty)) {
                    is_epsilon = true;
                    break;
                }
            }
            if (is_epsilon) {
                try empty.put(referrer, {});
                try queue.pushBack(allocator,referrer);
            }
        }
    }
}

test "allow empty rule ids direct and indirect" {
    const gpa = std.testing.allocator;
    const mod = @import("../grammar/mod.zig");
    const GrammarBuilder = mod.GrammarBuilder;
    var builder = try GrammarBuilder.new(gpa);
    defer builder.deinit();
    // inner ::= ("" | [a-z]); mid ::= (inner); root ::= ((mid "x")) — normalized shape:
    // every rule body is a choices of sequences.
    const cc = try builder.add_character_class(&.{mod.CharacterClassElement.new('a', 'z')}, false);
    const empty = try builder.add_empty_str();
    const inner_body = try builder.add_choices(&.{ empty, try builder.add_sequence(&.{cc}) });
    const inner = try builder.add_rule_named("inner", inner_body);
    const mid = try builder.add_rule_named("mid", try builder.add_choices(&.{try builder.add_sequence(&.{try builder.add_rule_ref(inner)})}));
    const root = try builder.add_rule_named(
        "root",
        try builder.add_choices(&.{try builder.add_sequence(&.{ try builder.add_rule_ref(mid), try builder.add_byte_string("x") })}),
    );
    const grammar = try builder.into_grammar(gpa, "root", null);
    defer grammar.deinit();

    const ids = try allow_empty_rule_ids(gpa, grammar);
    defer gpa.free(ids);
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqual(inner, ids[0]);
    try std.testing.expectEqual(mid, ids[1]);
    _ = root;
}
