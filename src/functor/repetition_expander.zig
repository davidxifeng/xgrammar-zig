//! Expands bounded/unbounded repetitions into explicit rules (`repetition_expander`).
//!
//! Small bounds are unzipped into repeated elements and a tail of optional rules; large
//! bounds keep a `Repeat` node wrapped so the matcher can count efficiently. Identical
//! repetitions share one expansion. Grammars with zero `.Repeat` expressions pass through
//! with zero rebuilding.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Diagnostic = @import("../Diagnostic.zig").Diagnostic;
const grammar_mod = @import("../grammar.zig");
const Grammar = grammar_mod.Grammar;
const GrammarExprType = grammar_mod.GrammarExprType;
const mutator = @import("mutator.zig");
const FunctorError = mutator.FunctorError;
const MutatorState = mutator.MutatorState;

const UNZIP_THRESHOLD: i64 = 128;

/// Returns true if `grammar` contains at least one `.Repeat` expression.
pub fn hasRepeatExprs(grammar: *const Grammar) bool {
    for (0..grammar.numExprs()) |expr_id| {
        if (grammar.expr(@intCast(expr_id)).ty == .Repeat) return true;
    }
    return false;
}

/// Expands repetition ranges, returning a fresh `Grammar` by value.
/// Fast pass-through when `grammar` contains zero `.Repeat` expressions (dupes without rebuilding).
/// `diag` optionally receives `.functor_invalid_repetition_range`.
pub fn expandRepetitionRanges(
    allocator: Allocator,
    grammar: *const Grammar,
    diag: ?*Diagnostic,
) FunctorError!Grammar {
    if (!hasRepeatExprs(grammar)) return grammar.dupe(allocator);
    return expandAll(allocator, grammar, diag);
}

/// Expands repetition ranges on `grammar` in place (zero-copy no-op when no `.Repeat` exists).
pub fn expandInPlace(
    allocator: Allocator,
    grammar: *Grammar,
    diag: ?*Diagnostic,
) FunctorError!void {
    if (!hasRepeatExprs(grammar)) return;
    const expanded = try expandAll(allocator, grammar, diag);
    grammar.deinit();
    grammar.* = expanded;
}

fn expandAll(
    allocator: Allocator,
    grammar: *const Grammar,
    diag: ?*Diagnostic,
) FunctorError!Grammar {
    for (0..grammar.numExprs()) |expr_id| {
        const e = grammar.expr(@intCast(expr_id));
        if (e.ty == .Repeat) {
            const rep = e.repeat();
            const lower: i64 = rep.min_repeat;
            const upper: i64 = rep.max_repeat;
            if (lower < 0 or (upper != -1 and upper < lower)) {
                if (diag) |d| d.setNumbers(.functor_invalid_repetition_range, lower, upper);
                return error.InvalidRepetitionRange;
            }
        }
    }
    var expander = RepetitionRangeExpander{ .repetition_cache = RepetitionCache.init(allocator) };
    defer expander.repetition_cache.deinit();
    return mutator.apply(&expander, allocator, grammar);
}

const RepetitionCache = struct {
    map: std.StringHashMapUnmanaged(i32) = .empty,
    allocator: Allocator,

    fn init(allocator: Allocator) RepetitionCache {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *RepetitionCache) void {
        var kit = self.map.keyIterator();
        while (kit.next()) |k| self.allocator.free(k.*);
        self.map.deinit(self.allocator);
    }

    fn get(self: *const RepetitionCache, key: []const u8) ?i32 {
        return self.map.get(key);
    }

    fn put(self: *RepetitionCache, key: []u8, value: i32) Allocator.Error!void {
        try self.map.put(self.allocator, key, value);
    }
};

const RepetitionRangeExpander = struct {
    repetition_cache: RepetitionCache,

    pub fn visitRepeat(
        self: *RepetitionRangeExpander,
        state: *MutatorState,
        ty: GrammarExprType,
        data: []const i32,
    ) FunctorError!i32 {
        _ = ty;
        return handleRepetitionRange(self, state, state.cur_rule_name, data[0], data[1], data[2]);
    }
};

fn legacyHandleRepetitionRange(
    state: *MutatorState,
    cur_rule_name: []const u8,
    grammar_expr_id: i32,
    lower: i64,
    upper: i64,
) FunctorError!i32 {
    const alloc = state.gpa();
    var elements: std.ArrayList(i32) = .empty;
    defer elements.deinit(alloc);
    try elements.appendNTimes(alloc, grammar_expr_id, @intCast(@max(lower, 0)));

    // Case 1: {l}
    if (upper == lower) {
        const seq = try state.builder.addSequence(elements.items);
        const choices = try state.builder.addChoices(&.{seq});
        const result_rule_id = try state.builder.addRuleWithHint(cur_rule_name, choices);
        return state.builder.addRuleRef(result_rule_id);
    }

    // Case 2: {l,}
    if (upper == -1) {
        const new_rule_name = try state.builder.getNewRuleName(cur_rule_name);
        const new_rule_id = try state.builder.addEmptyRule(new_rule_name);
        const ref_to_new_rule = try state.builder.addRuleRef(new_rule_id);
        const empty = try state.builder.addEmptyStr();
        const seq = try state.builder.addSequence(&.{ grammar_expr_id, ref_to_new_rule });
        const body = try state.builder.addChoices(&.{ empty, seq });
        state.builder.updateRuleBody(new_rule_id, body);
        try elements.append(alloc, try state.builder.addRuleRef(new_rule_id));
        const final_seq = try state.builder.addSequence(elements.items);
        const choices = try state.builder.addChoices(&.{final_seq});
        const result_rule_id = try state.builder.addRuleWithHint(cur_rule_name, choices);
        return state.builder.addRuleRef(result_rule_id);
    }

    // Case 3: {l, r} with r - l >= 1
    const extra: usize = @intCast(upper - lower);
    var rest_rule_ids: std.ArrayList(i32) = .empty;
    defer rest_rule_ids.deinit(alloc);
    try rest_rule_ids.ensureTotalCapacity(alloc, extra);
    for (0..extra) |_| {
        const new_rule_name = try state.builder.getNewRuleName(cur_rule_name);
        rest_rule_ids.appendAssumeCapacity(try state.builder.addEmptyRule(new_rule_name));
    }
    for (0..extra -| 1) |i| {
        const ref_to_next = try state.builder.addRuleRef(rest_rule_ids.items[i + 1]);
        const empty = try state.builder.addEmptyStr();
        const seq = try state.builder.addSequence(&.{ grammar_expr_id, ref_to_next });
        const body = try state.builder.addChoices(&.{ empty, seq });
        state.builder.updateRuleBody(rest_rule_ids.items[i], body);
    }
    const empty = try state.builder.addEmptyStr();
    const last_seq = try state.builder.addSequence(&.{grammar_expr_id});
    const last_body = try state.builder.addChoices(&.{ empty, last_seq });
    const last_rule = rest_rule_ids.items[rest_rule_ids.items.len - 1];
    state.builder.updateRuleBody(last_rule, last_body);

    try elements.append(alloc, try state.builder.addRuleRef(rest_rule_ids.items[0]));
    const final_seq = try state.builder.addSequence(elements.items);
    const choices = try state.builder.addChoices(&.{final_seq});
    const result_rule_id = try state.builder.addRuleWithHint(cur_rule_name, choices);
    return state.builder.addRuleRef(result_rule_id);
}

fn handleRepetitionRange(
    expander: *RepetitionRangeExpander,
    state: *MutatorState,
    cur_rule_name: []const u8,
    rule_id: i32,
    lower: i64,
    upper: i64,
) FunctorError!i32 {
    var grammar_expr_id = try state.builder.addRuleRef(rule_id);
    const base = state.base;
    const ref_rule = base.rule(rule_id);
    const ref_rule_body = base.expr(ref_rule.body_expr_id);
    if (ref_rule.max_tokens < 0 and ref_rule.max_chars < 0 and
        base.suffixStopInfo(rule_id) == null and !ref_rule.is_lazy and
        ref_rule.temperature == null and ref_rule_body.ty == .Choices and ref_rule_body.data.len == 1)
    {
        const ref_choice = base.expr(ref_rule_body.data[0]);
        if (ref_choice.ty == .Sequence and ref_choice.data.len == 1) {
            grammar_expr_id = try mutator.visitExprId(expander, state, ref_choice.data[0]);
        }
    }

    const repeated_expr = state.builder.grammarExpr(grammar_expr_id);
    const cache_alloc = expander.repetition_cache.allocator;
    const cache_key = try makeCacheKey(cache_alloc, repeated_expr.ty, repeated_expr.data, lower, upper);
    errdefer cache_alloc.free(cache_key);
    if (expander.repetition_cache.get(cache_key)) |cached| {
        cache_alloc.free(cache_key);
        return cached;
    }

    const result = try expandRepetitionRange(state, cur_rule_name, grammar_expr_id, lower, upper);
    try expander.repetition_cache.put(cache_key, result);
    return result;
}

fn makeCacheKey(
    alloc: Allocator,
    ty: GrammarExprType,
    data: []const i32,
    lower: i64,
    upper: i64,
) Allocator.Error![]u8 {
    var key: std.ArrayList(u8) = .empty;
    errdefer key.deinit(alloc);
    try key.ensureTotalCapacity(alloc, (data.len + 3) * 8);
    var buf: [8]u8 = undefined;
    try key.appendSlice(alloc, bytesOf(&buf, ty.asI32()));
    for (data) |v| try key.appendSlice(alloc, bytesOf(&buf, v));
    try key.appendSlice(alloc, bytesOf(&buf, lower));
    try key.appendSlice(alloc, bytesOf(&buf, upper));
    return key.toOwnedSlice(alloc);
}

fn bytesOf(buf: *[8]u8, v: i64) []const u8 {
    std.mem.writeInt(i64, buf, v, .little);
    return buf;
}

fn expandRepetitionRange(
    state: *MutatorState,
    cur_rule_name: []const u8,
    grammar_expr_id: i32,
    lower_in: i64,
    upper_in: i64,
) FunctorError!i32 {
    const alloc = state.gpa();
    var lower = lower_in;
    var upper = upper_in;
    if ((upper != -1 and upper <= UNZIP_THRESHOLD) or (upper == -1 and lower <= UNZIP_THRESHOLD)) {
        return legacyHandleRepetitionRange(state, cur_rule_name, grammar_expr_id, lower, upper);
    }

    var choices: std.ArrayList(i32) = .empty;
    defer choices.deinit(alloc);
    if (lower < UNZIP_THRESHOLD) {
        const unzipped = try legacyHandleRepetitionRange(state, cur_rule_name, grammar_expr_id, lower, UNZIP_THRESHOLD - 1);
        try choices.append(alloc, try state.builder.addSequence(&.{unzipped}));
        lower = UNZIP_THRESHOLD;
    }

    var infinite_repetition_id: ?i32 = null;
    var repeated_sequence: std.ArrayList(i32) = .empty;
    defer repeated_sequence.deinit(alloc);
    if (upper == -1) {
        const e = state.builder.grammarExpr(grammar_expr_id);
        if (e.ty == .CharacterClass) {
            const ranges = try e.characterClass(alloc);
            defer alloc.free(ranges.ranges);
            infinite_repetition_id = try state.builder.addCharacterClassStar(ranges.ranges, ranges.is_negative);
        } else {
            var name_buf: std.ArrayList(u8) = .empty;
            defer name_buf.deinit(alloc);
            try name_buf.appendSlice(alloc, cur_rule_name);
            try name_buf.appendSlice(alloc, "_repeat_inf");
            const unbounded_name = try state.builder.getNewRuleName(name_buf.items);
            const unbounded_rule_id = try state.builder.addEmptyRule(unbounded_name);
            const ref_unbounded = try state.builder.addRuleRef(unbounded_rule_id);
            const recursion_sequence = try state.builder.addSequence(&.{ grammar_expr_id, ref_unbounded });
            const empty = try state.builder.addEmptyStr();
            const recursion_choice = try state.builder.addChoices(&.{ empty, recursion_sequence });
            state.builder.updateRuleBody(unbounded_rule_id, recursion_choice);
            infinite_repetition_id = try state.builder.addRuleRef(unbounded_rule_id);
        }
        upper = lower;
    }

    var repeat_name_buf: std.ArrayList(u8) = .empty;
    defer repeat_name_buf.deinit(alloc);
    try repeat_name_buf.appendSlice(alloc, cur_rule_name);
    try repeat_name_buf.appendSlice(alloc, "_repeat_1");
    const repeat_name = repeat_name_buf.items;

    if (infinite_repetition_id) |id| {
        try repeated_sequence.append(alloc, id);
    }

    if (upper != UNZIP_THRESHOLD) {
        const inner_seq = try state.builder.addSequence(&.{grammar_expr_id});
        const inner_choices = try state.builder.addChoices(&.{inner_seq});
        const new_rule_id = try state.builder.addRuleWithHint(repeat_name, inner_choices);
        const rep = try state.builder.addRepeat(
            new_rule_id,
            @intCast(lower - UNZIP_THRESHOLD),
            @intCast(upper - UNZIP_THRESHOLD),
        );
        const repeat_seq = try state.builder.addSequence(&.{rep});
        const repeat_choices = try state.builder.addChoices(&.{repeat_seq});
        var inner_name_buf: std.ArrayList(u8) = .empty;
        defer inner_name_buf.deinit(alloc);
        try inner_name_buf.appendSlice(alloc, repeat_name);
        try inner_name_buf.appendSlice(alloc, "_inner");
        const new_repeated_rule_id = try state.builder.addRuleWithHint(inner_name_buf.items, repeat_choices);
        try repeated_sequence.append(alloc, try state.builder.addRuleRef(new_repeated_rule_id));
        var repetition_lookahead: std.ArrayList(i32) = .empty;
        defer repetition_lookahead.deinit(alloc);
        try repetition_lookahead.appendNTimes(alloc, grammar_expr_id, @intCast(UNZIP_THRESHOLD));
        const lookahead = try state.builder.addSequence(repetition_lookahead.items);
        state.builder.updateLookaheadAssertion(new_rule_id, lookahead);
    }

    for (0..@intCast(UNZIP_THRESHOLD)) |_| {
        try repeated_sequence.append(alloc, grammar_expr_id);
    }

    try choices.append(alloc, try state.builder.addSequence(repeated_sequence.items));
    const result_choices = try state.builder.addChoices(choices.items);
    const result_rule_id = try state.builder.addRuleWithHint(cur_rule_name, result_choices);
    return state.builder.addRuleRef(result_rule_id);
}

test "expandRepetitionRanges unzips small bounds and skips when absent" {
    const gpa = std.testing.allocator;
    const GrammarBuilder = grammar_mod.GrammarBuilder;
    {
        var builder = try GrammarBuilder.init(gpa);
        defer builder.deinit();
        const inner = try builder.addRuleNamed("inner", try builder.addByteString("a"));
        const rep = try builder.addRepeat(inner, 2, 3);
        _ = try builder.addRuleNamed("root", rep);
        var grammar = try builder.intoGrammar("root", null);
        defer grammar.deinit();

        var expanded = try expandRepetitionRanges(gpa, &grammar, null);
        defer expanded.deinit();
        const ebnf = try expanded.toStringEbnf(gpa);
        defer gpa.free(ebnf);
        try std.testing.expect(std.mem.indexOf(u8, ebnf, "inner inner") != null);
    }
    {
        var builder = try GrammarBuilder.init(gpa);
        defer builder.deinit();
        _ = try builder.addRuleNamed("root", try builder.addByteString("abc"));
        var grammar = try builder.intoGrammar("root", null);
        defer grammar.deinit();
        const orig_impl = grammar.impl;
        try expandInPlace(gpa, &grammar, null);
        try std.testing.expectEqual(orig_impl, grammar.impl);
    }
}

test "expandRepetitionRanges rejects invalid ranges with Diagnostic" {
    const gpa = std.testing.allocator;
    const GrammarBuilder = grammar_mod.GrammarBuilder;
    var builder = try GrammarBuilder.init(gpa);
    defer builder.deinit();
    const inner = try builder.addRuleNamed("inner", try builder.addByteString("a"));
    const rep = try builder.addRepeat(inner, 3, 1);
    _ = try builder.addRuleNamed("root", rep);
    var grammar = try builder.intoGrammar("root", null);
    defer grammar.deinit();

    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);
    try std.testing.expectError(error.InvalidRepetitionRange, expandRepetitionRanges(gpa, &grammar, &diag));
    const msg = try diag.formatAlloc(gpa);
    defer gpa.free(msg);
    try std.testing.expectEqualStrings("Invalid repetition range {3, 1}", msg);
}

test "unbounded repetition above threshold does not crash" {
    const gpa = std.testing.allocator;
    var grammar = try @import("normalizer.zig").fromEbnf(gpa, "root ::= [a-z]{129,} [0-9]{129,}", "root", null);
    defer grammar.deinit();
    var expanded = try expandRepetitionRanges(gpa, &grammar, null);
    defer expanded.deinit();
}
