//! Static grammar analysis passes:
//! - `allowEmptyRuleIds` & `ruleRefGraph` (nullable-rule analysis)
//! - `analyzeLookaheadAssertions` & `analyzeLookaheadAssertionsInPlace`

const std = @import("std");
const Allocator = std.mem.Allocator;

const fsm_mod = @import("../fsm.zig");
const RegexFsmBuilder = fsm_mod.RegexFsmBuilder;
const grammar_mod = @import("../grammar.zig");
const CharacterClassElement = grammar_mod.CharacterClassElement;
const Grammar = grammar_mod.Grammar;
const GrammarBuilder = grammar_mod.GrammarBuilder;
const NO_EXPR = grammar_mod.NO_EXPR;
const dispatch = grammar_mod.dispatch;
const Compact2dArrayError = @import("../support.zig").Compact2dArrayError;
const mutator = @import("mutator.zig");
const FunctorError = mutator.FunctorError;

// ---------------------------------------------------------------------------
// 1. AllowEmptyRuleAnalyzer
// ---------------------------------------------------------------------------

/// Returns the sorted ids of rules that can derive the empty string. Caller owns the slice.
pub fn allowEmptyRuleIds(allocator: Allocator, grammar: *const Grammar) Allocator.Error![]i32 {
    var empty: std.AutoHashMapUnmanaged(i32, void) = .empty;
    defer empty.deinit(allocator);
    try findExplicitEmptyRules(allocator, grammar, &empty);
    const graph = try ruleRefGraph(allocator, grammar);
    defer {
        for (graph) |*refs| refs.deinit(allocator);
        allocator.free(graph);
    }
    try findIndirectEmptyRules(allocator, grammar, &empty, graph);
    var result: std.ArrayList(i32) = .empty;
    errdefer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, empty.count());
    var it = empty.keyIterator();
    while (it.next()) |key| result.appendAssumeCapacity(key.*);
    std.mem.sortUnstable(i32, result.items, {}, std.sort.asc(i32));
    return result.toOwnedSlice(allocator);
}

/// Builds the inverse reference graph: `graph[referee] = [referrers]` (sorted, deduplicated).
/// Caller owns the returned slice and every inner list.
pub fn ruleRefGraph(allocator: Allocator, grammar: *const Grammar) Allocator.Error![]std.ArrayList(i32) {
    const n = grammar.numRules();
    const graph = try allocator.alloc(std.ArrayList(i32), n);
    for (graph) |*refs| refs.* = .empty;
    var ok = false;
    errdefer if (!ok) {
        for (graph) |*refs| refs.deinit(allocator);
        allocator.free(graph);
    };
    for (0..n) |cur| {
        const body_id = grammar.rule(@intCast(cur)).body_expr_id;
        try visitRefs(allocator, grammar, body_id, @intCast(cur), graph);
    }
    for (graph) |*refs| {
        std.mem.sortUnstable(i32, refs.items, {}, std.sort.asc(i32));
        dedupSorted(refs);
    }
    ok = true;
    return graph;
}

fn dedupSorted(list: *std.ArrayList(i32)) void {
    var write: usize = 0;
    for (list.items, 0..) |v, read| {
        if (read == 0 or list.items[write - 1] != v) {
            list.items[write] = v;
            write += 1;
        }
    }
    list.shrinkRetainingCapacity(write);
}

fn visitRefs(
    allocator: Allocator,
    grammar: *const Grammar,
    expr_id: i32,
    cur_rule: i32,
    graph: []std.ArrayList(i32),
) Allocator.Error!void {
    const e = grammar.expr(expr_id);
    switch (e.ty) {
        .Choices, .Sequence => {
            for (e.data) |child| try visitRefs(allocator, grammar, child, cur_rule, graph);
        },
        .RuleRef, .Repeat => try graph[@intCast(e.data[0])].append(allocator, cur_rule),
        .TagDispatch => {
            var td = try dispatch.tagDispatch(grammar, allocator, expr_id);
            defer td.deinit(allocator);
            for (td.tag_rule_pairs.items) |pair| try graph[@intCast(pair.rule_id)].append(allocator, cur_rule);
        },
        .TokenTagDispatch => {
            var ttd = try dispatch.tokenTagDispatch(grammar, allocator, expr_id);
            defer ttd.deinit(allocator);
            for (ttd.trigger_rule_pairs.items) |pair| try graph[@intCast(pair.rule_id)].append(allocator, cur_rule);
        },
        else => {},
    }
}

fn findExplicitEmptyRules(
    allocator: Allocator,
    grammar: *const Grammar,
    empty: *std.AutoHashMapUnmanaged(i32, void),
) Allocator.Error!void {
    for (0..grammar.numRules()) |i| {
        const body = grammar.expr(grammar.rule(@intCast(i)).body_expr_id);
        switch (body.ty) {
            .TagDispatch, .TokenTagDispatch, .Substring => {
                try empty.put(allocator, @intCast(i), {});
                continue;
            },
            .Regex => {
                const pattern = try body.regexPattern(allocator);
                defer allocator.free(pattern);
                if (RegexFsmBuilder.matchesEmpty(allocator, pattern, null)) |matches| {
                    if (matches) try empty.put(allocator, @intCast(i), {});
                } else |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {},
                }
                continue;
            },
            else => {},
        }
        // Normalized non-leaf body is a Choices expression.
        if (grammar.expr(body.data[0]).ty == .EmptyStr) {
            try empty.put(allocator, @intCast(i), {});
            continue;
        }
        for (body.data) |seq_id| {
            const seq = grammar.expr(seq_id);
            var all_star = seq.data.len > 0;
            for (seq.data) |e_id| {
                if (grammar.expr(e_id).ty != .CharacterClassStar) {
                    all_star = false;
                    break;
                }
            }
            if (all_star) {
                try empty.put(allocator, @intCast(i), {});
                break;
            }
        }
    }
}

fn seqExprIsEpsilon(
    grammar: *const Grammar,
    seq_id: i32,
    empty: *const std.AutoHashMapUnmanaged(i32, void),
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

fn findIndirectEmptyRules(
    allocator: Allocator,
    grammar: *const Grammar,
    empty: *std.AutoHashMapUnmanaged(i32, void),
    graph: []const std.ArrayList(i32),
) Allocator.Error!void {
    var queue: std.Deque(i32) = .empty;
    defer queue.deinit(allocator);
    var it = empty.keyIterator();
    while (it.next()) |key| try queue.pushBack(allocator, key.*);
    while (queue.popFront()) |rule_id| {
        for (graph[@intCast(rule_id)].items) |referrer| {
            if (empty.contains(referrer)) continue;
            const body = grammar.expr(grammar.rule(referrer).body_expr_id);
            var is_epsilon = false;
            for (body.data) |seq_id| {
                if (seqExprIsEpsilon(grammar, seq_id, empty)) {
                    is_epsilon = true;
                    break;
                }
            }
            if (is_epsilon) {
                try empty.put(allocator, referrer, {});
                try queue.pushBack(allocator, referrer);
            }
        }
    }
}

// ---------------------------------------------------------------------------
// 2. LookaheadAssertionAnalyzer
// ---------------------------------------------------------------------------

/// Infers and attaches lookahead assertions, returning a fresh `Grammar` by value.
pub fn analyzeLookaheadAssertions(allocator: Allocator, grammar: *const Grammar) FunctorError!Grammar {
    var copy = try grammar.dupe(allocator);
    errdefer copy.deinit();
    try analyzeLookaheadAssertionsInPlace(allocator, &copy);
    return copy;
}

/// Infers and attaches lookahead assertions on `grammar` in place.
pub fn analyzeLookaheadAssertionsInPlace(allocator: Allocator, grammar: *Grammar) FunctorError!void {
    const root_body = grammar.expr(grammar.rootRule().body_expr_id);
    if (root_body.ty == .TagDispatch or root_body.ty == .TokenTagDispatch or
        root_body.ty == .Regex or root_body.ty == .Substring)
    {
        return;
    }

    var analyzer = LookaheadAssertionAnalyzer{
        .allocator = allocator,
        .grammar = grammar,
        .infos = .empty,
    };
    defer analyzer.deinit();
    try analyzer.run();
}

const RuleLookaheadInfo = struct {
    is_triggered_by_dispatch: bool = false,
    appears_as_last_in_other_rule: bool = false,
    non_last_occurrence_count: i32 = 0,
    suffix_after_first_occurrence: std.ArrayList(i32) = .empty,
};

const LookaheadAssertionAnalyzer = struct {
    allocator: Allocator,
    grammar: *Grammar,
    infos: std.ArrayList(RuleLookaheadInfo),

    fn deinit(self: *LookaheadAssertionAnalyzer) void {
        for (self.infos.items) |*info| info.suffix_after_first_occurrence.deinit(self.allocator);
        self.infos.deinit(self.allocator);
    }

    fn run(self: *LookaheadAssertionAnalyzer) (Allocator.Error || Compact2dArrayError)!void {
        try self.buildRuleLookaheadInfo();

        var builder = GrammarBuilder.editInPlace(self.grammar);
        defer builder.deinit();

        const root_id = self.grammar.rootRuleId();
        for (0..self.grammar.numRules()) |i| {
            if (i == @as(usize, @intCast(root_id))) continue;
            if (builder.getRule(@intCast(i)).lookahead_assertion_id != NO_EXPR) {
                const exact = self.canUseDerivedLookahead(@intCast(i));
                builder.updateLookaheadExact(@intCast(i), exact);
                continue;
            }
            if (try self.detectLookaheadAssertion(&builder, @intCast(i))) |lookahead_id| {
                builder.updateLookaheadAssertion(@intCast(i), lookahead_id);
                builder.updateLookaheadExact(@intCast(i), true);
            }
        }
        builder.editInPlaceCommit(self.grammar);
    }

    fn canUseDerivedLookahead(self: *const LookaheadAssertionAnalyzer, rule_id: i32) bool {
        const info = &self.infos.items[@intCast(rule_id)];
        return !info.is_triggered_by_dispatch and !info.appears_as_last_in_other_rule and
            info.non_last_occurrence_count == 1;
    }

    fn detectLookaheadAssertion(
        self: *const LookaheadAssertionAnalyzer,
        builder: *GrammarBuilder,
        rule_id: i32,
    ) Allocator.Error!?i32 {
        if (!self.canUseDerivedLookahead(rule_id)) return null;
        const suffix = self.infos.items[@intCast(rule_id)].suffix_after_first_occurrence.items;
        return try builder.addSequence(suffix);
    }

    fn buildRuleLookaheadInfo(self: *LookaheadAssertionAnalyzer) Allocator.Error!void {
        const num_rules = self.grammar.numRules();
        try self.infos.ensureTotalCapacity(self.allocator, num_rules);
        for (0..num_rules) |_| self.infos.appendAssumeCapacity(.{});

        for (0..num_rules) |i| {
            const body_expr_id = self.grammar.rule(@intCast(i)).body_expr_id;
            const body = self.grammar.expr(body_expr_id);
            switch (body.ty) {
                .TagDispatch => {
                    var td = try dispatch.tagDispatch(self.grammar, self.allocator, body_expr_id);
                    defer td.deinit(self.allocator);
                    for (td.tag_rule_pairs.items) |pair| {
                        self.infos.items[@intCast(pair.rule_id)].is_triggered_by_dispatch = true;
                    }
                    continue;
                },
                .TokenTagDispatch => {
                    var ttd = try dispatch.tokenTagDispatch(self.grammar, self.allocator, body_expr_id);
                    defer ttd.deinit(self.allocator);
                    for (ttd.trigger_rule_pairs.items) |pair| {
                        self.infos.items[@intCast(pair.rule_id)].is_triggered_by_dispatch = true;
                    }
                    continue;
                },
                .Regex, .Substring => continue,
                else => {},
            }
            for (body.data) |sequence_id| {
                const seq = self.grammar.expr(sequence_id);
                if (seq.ty != .Sequence or seq.isEmpty()) continue;
                const elements = seq.data;
                const last = self.grammar.expr(elements[elements.len - 1]);
                if (last.ty == .RuleRef and i != @as(usize, @intCast(last.ruleRefId()))) {
                    self.infos.items[@intCast(last.ruleRefId())].appears_as_last_in_other_rule = true;
                }
                for (0..elements.len - 1) |j| {
                    const element = self.grammar.expr(elements[j]);
                    if (element.ty != .RuleRef) continue;
                    const info = &self.infos.items[@intCast(element.ruleRefId())];
                    if (info.non_last_occurrence_count == 0) {
                        try info.suffix_after_first_occurrence.appendSlice(self.allocator, elements[j + 1 ..]);
                    }
                    info.non_last_occurrence_count += 1;
                }
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "allowEmptyRuleIds direct and indirect" {
    const gpa = std.testing.allocator;
    var builder = try GrammarBuilder.init(gpa);
    defer builder.deinit();
    const cc = try builder.addCharacterClass(&.{CharacterClassElement.init('a', 'z')}, false);
    const empty = try builder.addEmptyStr();
    const inner_body = try builder.addChoices(&.{ empty, try builder.addSequence(&.{cc}) });
    const inner = try builder.addRuleNamed("inner", inner_body);
    const mid = try builder.addRuleNamed(
        "mid",
        try builder.addChoices(&.{try builder.addSequence(&.{try builder.addRuleRef(inner)})}),
    );
    _ = try builder.addRuleNamed(
        "root",
        try builder.addChoices(&.{try builder.addSequence(&.{ try builder.addRuleRef(mid), try builder.addByteString("x") })}),
    );
    var grammar = try builder.intoGrammar("root", null);
    defer grammar.deinit();

    const ids = try allowEmptyRuleIds(gpa, &grammar);
    defer gpa.free(ids);
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqual(inner, ids[0]);
    try std.testing.expectEqual(mid, ids[1]);
}

test "analyzeLookaheadAssertions attaches suffix after single non-last reference" {
    const gpa = std.testing.allocator;
    var builder = try GrammarBuilder.init(gpa);
    defer builder.deinit();
    const part = try builder.addRuleNamed("part", try builder.addChoices(&.{try builder.addSequence(&.{try builder.addByteString("a")})}));
    _ = try builder.addRuleNamed(
        "root",
        try builder.addChoices(&.{try builder.addSequence(&.{ try builder.addRuleRef(part), try builder.addByteString("b") })}),
    );
    var grammar = try builder.intoGrammar("root", null);
    defer grammar.deinit();

    var analyzed = try analyzeLookaheadAssertions(gpa, &grammar);
    defer analyzed.deinit();
    const la = analyzed.rule(part).lookahead_assertion_id;
    try std.testing.expect(la != NO_EXPR);
    const la_seq = analyzed.expr(la);
    try std.testing.expectEqual(@as(usize, 1), la_seq.data.len);
    const suffix = try analyzed.expr(la_seq.data[0]).byteString(gpa);
    defer gpa.free(suffix);
    try std.testing.expectEqualStrings("b", suffix);
    try std.testing.expect(analyzed.rule(part).is_exact_lookahead);
}
