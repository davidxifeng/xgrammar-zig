//! Rewrites lazy rule bodies into their terminal-like form where possible
//! (`lazy_flattener`).
//!
//! Grammars with zero lazy rules pass through without rebuilding.

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_mod = @import("../grammar.zig");
const CharacterClassElement = grammar_mod.CharacterClassElement;
const Grammar = grammar_mod.Grammar;
const GrammarBuilder = grammar_mod.GrammarBuilder;
const GrammarExpr = grammar_mod.GrammarExpr;
const mutator = @import("mutator.zig");
const FunctorError = mutator.FunctorError;
const MutatorState = mutator.MutatorState;

const log = std.log.scoped(.xgrammar);

const MAX_DEPTH: i32 = 64;
const MAX_CODEPOINT: i32 = 0x10_FFFF;

/// Returns true if `grammar` has at least one lazy rule.
pub fn hasLazyRules(grammar: *const Grammar) bool {
    for (grammar.rulesSlice()) |r| {
        if (r.is_lazy) return true;
    }
    return false;
}

/// Flattens the bodies of lazy rules, returning a fresh `Grammar` by value.
/// Fast pass-through when `grammar` has zero lazy rules.
pub fn flattenLazyBodies(allocator: Allocator, grammar: *const Grammar) FunctorError!Grammar {
    if (!hasLazyRules(grammar)) return grammar.dupe(allocator);
    return flattenAll(allocator, grammar);
}

/// Flattens lazy rule bodies on `grammar` in place (zero-copy no-op when no lazy rules exist).
pub fn flattenInPlace(allocator: Allocator, grammar: *Grammar) FunctorError!void {
    if (!hasLazyRules(grammar)) return;
    const flattened = try flattenAll(allocator, grammar);
    grammar.deinit();
    grammar.* = flattened;
}

fn flattenAll(allocator: Allocator, grammar: *const Grammar) FunctorError!Grammar {
    var state = MutatorState{
        .base = grammar,
        .builder = try GrammarBuilder.init(allocator),
        .cur_rule_name = "",
    };
    defer state.builder.deinit();

    for (grammar.rulesSlice()) |r| _ = try state.builder.addEmptyRule(r.name);
    for (grammar.rulesSlice(), 0..) |r, rule_id| {
        state.cur_rule_name = r.name;
        const new_body_expr_id = if (r.is_lazy)
            try buildFlattenedLazyBody(&state, r.body_expr_id)
        else
            try mutator.visitExprId(identity{}, &state, r.body_expr_id);
        state.builder.updateRuleBody(@intCast(rule_id), new_body_expr_id);
        const new_lookahead_id = try mutator.visitLookahead(identity{}, &state, r.lookahead_assertion_id);
        state.builder.updateLookaheadAssertion(@intCast(rule_id), new_lookahead_id);
        try state.builder.copyRuleAttributes(@intCast(rule_id), grammar, @intCast(rule_id), identityId);
    }
    return state.builder.intoGrammarWithRootId(grammar.rootRuleId());
}

const identity = struct {};

fn identityId(id: i32) i32 {
    return id;
}

fn exprEql(a: GrammarExpr, b: GrammarExpr) bool {
    return a.ty == b.ty and std.mem.eql(i32, a.data, b.data);
}

fn buildFlattenedLazyBody(state: *MutatorState, body_expr_id: i32) FunctorError!i32 {
    const alloc = state.gpa();
    const base = state.base;
    {
        const ty = base.expr(body_expr_id).ty;
        if (ty == .Regex or ty == .Substring) return mutator.visitExprId(identity{}, state, body_expr_id);
    }
    var cur_body_id = body_expr_id;
    var cur_rule_id: ?i32 = null;
    for (0..@intCast(MAX_DEPTH)) |_| {
        const element_id = soleElement(base, cur_body_id) orelse break;
        const rule_id = nonLazyRuleRef(base, element_id) orelse break;
        cur_rule_id = rule_id;
        cur_body_id = base.rule(rule_id).body_expr_id;
    }

    const body = base.expr(cur_body_id);
    if (body.ty != .Choices) {
        log.warn("The body of the lazy rule '{s}' cannot be flattened into a terminal-like form", .{state.cur_rule_name});
        return mutator.visitExprId(identity{}, state, cur_body_id);
    }
    var repeat_elements: std.ArrayList(i32) = .empty;
    defer repeat_elements.deinit(alloc);
    if (cur_rule_id != null and try tryEmitRepeatPattern(state, cur_body_id, cur_rule_id.?, &repeat_elements)) {
        const sequence = try state.builder.addSequence(repeat_elements.items);
        return state.builder.addChoices(&.{sequence});
    }
    var new_choice_ids: std.ArrayList(i32) = .empty;
    defer new_choice_ids.deinit(alloc);
    for (body.data) |choice_id| {
        if (base.expr(choice_id).ty != .Sequence) {
            try new_choice_ids.append(alloc, try mutator.visitExprId(identity{}, state, choice_id));
            continue;
        }
        var elements: std.ArrayList(i32) = .empty;
        defer elements.deinit(alloc);
        if (!try flattenSequenceInto(state, choice_id, &elements, 0)) {
            log.warn("The body of the lazy rule '{s}' cannot be flattened into a terminal-like form", .{state.cur_rule_name});
            return mutator.visitExprId(identity{}, state, cur_body_id);
        }
        try new_choice_ids.append(alloc, try state.builder.addSequence(elements.items));
    }
    return state.builder.addChoices(new_choice_ids.items);
}

fn flattenSequenceInto(
    state: *MutatorState,
    sequence_id: i32,
    elements: *std.ArrayList(i32),
    depth: i32,
) FunctorError!bool {
    if (depth > MAX_DEPTH) return false;
    const alloc = state.gpa();
    const base = state.base;
    for (base.expr(sequence_id).data) |element_id| {
        const element = base.expr(element_id);
        if (element.ty == .ByteString or element.ty == .CharacterClass or element.ty == .CharacterClassStar) {
            try elements.append(alloc, try state.builder.addGrammarExpr(element.ty, element.data));
            continue;
        }
        const ref_rule_id = nonLazyRuleRef(base, element_id) orelse return false;
        const ref_body_id = base.rule(ref_rule_id).body_expr_id;
        if (try tryEmitRepeatPattern(state, ref_body_id, ref_rule_id, elements)) continue;
        const ref_body = base.expr(ref_body_id);
        if (ref_body.ty == .Choices and ref_body.len() == 1) {
            const only_choice = base.expr(ref_body.data[0]);
            if (only_choice.ty == .EmptyStr) continue;
            if (only_choice.ty == .Sequence) {
                var spliced: std.ArrayList(i32) = .empty;
                defer spliced.deinit(alloc);
                if (try flattenSequenceInto(state, ref_body.data[0], &spliced, depth + 1)) {
                    try elements.appendSlice(alloc, spliced.items);
                    continue;
                }
            }
        }
        var ranges: std.ArrayList(CharacterClassElement) = .empty;
        defer ranges.deinit(alloc);
        if (try collectSingleCharRanges(alloc, base, element_id, &ranges, 0)) {
            const unioned = try unionRanges(alloc, ranges.items);
            defer alloc.free(unioned);
            try elements.append(alloc, try state.builder.addCharacterClass(unioned, false));
            continue;
        }
        return false;
    }
    return true;
}

fn collectSingleCharRanges(
    alloc: Allocator,
    base: *const Grammar,
    expr_id: i32,
    ranges: *std.ArrayList(CharacterClassElement),
    depth: i32,
) FunctorError!bool {
    if (depth > MAX_DEPTH) return false;
    const e = base.expr(expr_id);
    switch (e.ty) {
        .CharacterClass => {
            try appendPositiveRanges(alloc, e, ranges);
            return true;
        },
        .ByteString => if (e.len() == 1) {
            try ranges.append(alloc, CharacterClassElement.init(e.data[0], e.data[0]));
            return true;
        },
        else => {},
    }
    const rule_id = nonLazyRuleRef(base, expr_id) orelse return false;
    const body = base.expr(base.rule(rule_id).body_expr_id);
    if (body.ty != .Choices) return false;
    for (body.data) |choice_id| {
        const choice = base.expr(choice_id);
        if (choice.ty != .Sequence or choice.len() != 1) return false;
        if (!try collectSingleCharRanges(alloc, base, choice.data[0], ranges, depth + 1)) return false;
    }
    return true;
}

fn tryEmitRepeatPattern(
    state: *MutatorState,
    body_id: i32,
    self_rule_id: i32,
    elements: *std.ArrayList(i32),
) FunctorError!bool {
    if (try tryEmitPlusPattern(state, body_id, self_rule_id, elements)) return true;
    if (try tryEmitGeneralizedPlusPattern(state, body_id, self_rule_id, elements)) return true;
    return tryEmitStarPattern(state, body_id, self_rule_id, elements);
}

fn tryEmitGeneralizedPlusPattern(
    state: *MutatorState,
    body_id: i32,
    self_rule_id: i32,
    elements: *std.ArrayList(i32),
) FunctorError!bool {
    const alloc = state.gpa();
    const base = state.base;
    const body = base.expr(body_id);
    if (body.ty != .Choices) return false;
    var recursive_ranges: std.ArrayList(CharacterClassElement) = .empty;
    defer recursive_ranges.deinit(alloc);
    var base_ranges: std.ArrayList(CharacterClassElement) = .empty;
    defer base_ranges.deinit(alloc);
    for (body.data) |choice_id| {
        const choice = base.expr(choice_id);
        if (choice.ty != .Sequence) return false;
        if (choice.len() == 1) {
            if (!try collectSingleCharRanges(alloc, base, choice.data[0], &base_ranges, 0)) return false;
            continue;
        }
        if (choice.len() == 2 and isRuleRefTo(base, choice.data[1], self_rule_id) and
            try collectSingleCharRanges(alloc, base, choice.data[0], &recursive_ranges, 0))
        {
            continue;
        }
        return false;
    }
    const recursive_unioned = try unionRanges(alloc, recursive_ranges.items);
    defer alloc.free(recursive_unioned);
    const base_unioned = try unionRanges(alloc, base_ranges.items);
    defer alloc.free(base_unioned);
    if (recursive_unioned.len == 0 or !rangesEql(recursive_unioned, base_unioned)) return false;
    try elements.append(alloc, try state.builder.addCharacterClass(recursive_unioned, false));
    try elements.append(alloc, try state.builder.addCharacterClassStar(recursive_unioned, false));
    return true;
}

fn tryEmitPlusPattern(
    state: *MutatorState,
    body_id: i32,
    self_rule_id: i32,
    elements: *std.ArrayList(i32),
) FunctorError!bool {
    const alloc = state.gpa();
    const base = state.base;
    const body = base.expr(body_id);
    if (body.ty != .Choices or body.len() != 2) return false;
    for (0..2) |recursive_pos| {
        const recursive = base.expr(body.data[recursive_pos]);
        const base_choice = base.expr(body.data[1 - recursive_pos]);
        if (recursive.ty != .Sequence or recursive.len() != 2 or
            base_choice.ty != .Sequence or base_choice.len() != 1) continue;
        if (!isRuleRefTo(base, recursive.data[1], self_rule_id) or
            !exprEql(base.expr(recursive.data[0]), base.expr(base_choice.data[0]))) continue;
        const resolved_id = resolveStarExpressible(base, recursive.data[0]) orelse {
            var ranges: std.ArrayList(CharacterClassElement) = .empty;
            defer ranges.deinit(alloc);
            if (!try collectSingleCharRanges(alloc, base, recursive.data[0], &ranges, 0)) continue;
            const unioned = try unionRanges(alloc, ranges.items);
            defer alloc.free(unioned);
            try elements.append(alloc, try state.builder.addCharacterClass(unioned, false));
            try elements.append(alloc, try state.builder.addCharacterClassStar(unioned, false));
            return true;
        };
        const resolved = base.expr(resolved_id);
        if (resolved.ty == .CharacterClassStar) {
            try elements.append(alloc, try state.builder.addGrammarExpr(resolved.ty, resolved.data));
            return true;
        }
        var single_buf = [1]CharacterClassElement{undefined};
        const cc_owned = if (resolved.ty == .CharacterClass) try resolved.characterClass(alloc) else null;
        defer if (cc_owned) |c| alloc.free(c.ranges);
        const character_ranges: []const CharacterClassElement = if (cc_owned) |c|
            c.ranges
        else blk: {
            single_buf[0] = CharacterClassElement.init(resolved.data[0], resolved.data[0]);
            break :blk &single_buf;
        };
        const is_negative = if (cc_owned) |c| c.is_negative else false;
        try elements.append(alloc, try state.builder.addGrammarExpr(resolved.ty, resolved.data));
        try elements.append(alloc, try state.builder.addCharacterClassStar(character_ranges, is_negative));
        return true;
    }
    return false;
}

fn tryEmitStarPattern(
    state: *MutatorState,
    body_id: i32,
    self_rule_id: i32,
    elements: *std.ArrayList(i32),
) FunctorError!bool {
    const alloc = state.gpa();
    const base = state.base;
    const body = base.expr(body_id);
    if (body.ty != .Choices) return false;
    var has_empty = false;
    var ranges: std.ArrayList(CharacterClassElement) = .empty;
    defer ranges.deinit(alloc);
    for (body.data) |choice_id| {
        const choice = base.expr(choice_id);
        if (choice.ty == .EmptyStr) {
            has_empty = true;
            continue;
        }
        if (choice.ty != .Sequence or choice.len() != 2 or
            !isRuleRefTo(base, choice.data[1], self_rule_id) or
            !try collectStarRanges(alloc, base, choice.data[0], &ranges, 0))
        {
            return false;
        }
    }
    if (!has_empty or ranges.items.len == 0) return false;
    const unioned = try unionRanges(alloc, ranges.items);
    defer alloc.free(unioned);
    try elements.append(alloc, try state.builder.addCharacterClassStar(unioned, false));
    return true;
}

fn collectStarRanges(
    alloc: Allocator,
    base: *const Grammar,
    expr_id: i32,
    ranges: *std.ArrayList(CharacterClassElement),
    depth: i32,
) FunctorError!bool {
    if (depth > MAX_DEPTH) return false;
    const e = base.expr(expr_id);
    switch (e.ty) {
        .CharacterClass, .CharacterClassStar => {
            try appendPositiveRanges(alloc, e, ranges);
            return true;
        },
        .ByteString => if (e.len() == 1) {
            try ranges.append(alloc, CharacterClassElement.init(e.data[0], e.data[0]));
            return true;
        },
        else => {},
    }
    const rule_id = nonLazyRuleRef(base, expr_id) orelse return false;
    const body = base.expr(base.rule(rule_id).body_expr_id);
    if (body.ty != .Choices) return false;
    var has_empty = false;
    var base_elements: std.ArrayList(i32) = .empty;
    defer base_elements.deinit(alloc);
    var recursive_elements: std.ArrayList(i32) = .empty;
    defer recursive_elements.deinit(alloc);
    for (body.data) |choice_id| {
        const choice = base.expr(choice_id);
        if (choice.ty == .EmptyStr) {
            has_empty = true;
        } else if (choice.ty == .Sequence and choice.len() == 1) {
            try base_elements.append(alloc, choice.data[0]);
        } else if (choice.ty == .Sequence and choice.len() == 2 and
            isRuleRefTo(base, choice.data[1], rule_id))
        {
            try recursive_elements.append(alloc, choice.data[0]);
        } else {
            return false;
        }
    }
    const collect: []const i32 = blk: {
        if (recursive_elements.items.len == 0) break :blk base_elements.items;
        if ((base_elements.items.len == 0 and has_empty) or
            (recursive_elements.items.len == 1 and base_elements.items.len == 1 and !has_empty and
                exprEql(base.expr(recursive_elements.items[0]), base.expr(base_elements.items[0]))))
        {
            break :blk recursive_elements.items;
        }
        if (!has_empty) {
            var recursive_ranges: std.ArrayList(CharacterClassElement) = .empty;
            defer recursive_ranges.deinit(alloc);
            var base_ranges: std.ArrayList(CharacterClassElement) = .empty;
            defer base_ranges.deinit(alloc);
            for (recursive_elements.items) |id| {
                if (!try collectSingleCharRanges(alloc, base, id, &recursive_ranges, depth + 1)) return false;
            }
            for (base_elements.items) |id| {
                if (!try collectSingleCharRanges(alloc, base, id, &base_ranges, depth + 1)) return false;
            }
            const recursive_unioned = try unionRanges(alloc, recursive_ranges.items);
            defer alloc.free(recursive_unioned);
            const base_unioned = try unionRanges(alloc, base_ranges.items);
            defer alloc.free(base_unioned);
            if (!rangesEql(recursive_unioned, base_unioned)) return false;
            try ranges.appendSlice(alloc, recursive_unioned);
            return true;
        }
        return false;
    };
    for (collect) |id| {
        if (!try collectStarRanges(alloc, base, id, ranges, depth + 1)) return false;
    }
    return true;
}

fn appendPositiveRanges(
    alloc: Allocator,
    expr: GrammarExpr,
    ranges: *std.ArrayList(CharacterClassElement),
) Allocator.Error!void {
    const cc = try expr.characterClass(alloc);
    defer alloc.free(cc.ranges);
    if (!cc.is_negative) {
        try ranges.appendSlice(alloc, cc.ranges);
        return;
    }
    const unioned = try unionRanges(alloc, cc.ranges);
    defer alloc.free(unioned);
    var next: i32 = 0;
    for (unioned) |range| {
        if (range.lower > next) {
            try ranges.append(alloc, CharacterClassElement.init(next, range.lower - 1));
        }
        next = @max(next, range.upper + 1);
    }
    if (next <= MAX_CODEPOINT) {
        try ranges.append(alloc, CharacterClassElement.init(next, MAX_CODEPOINT));
    }
}

fn unionRanges(alloc: Allocator, ranges: []const CharacterClassElement) Allocator.Error![]CharacterClassElement {
    const sorted = try alloc.dupe(CharacterClassElement, ranges);
    defer alloc.free(sorted);
    std.mem.sortUnstable(CharacterClassElement, sorted, {}, struct {
        fn less(_: void, a: CharacterClassElement, b: CharacterClassElement) bool {
            return a.lower < b.lower;
        }
    }.less);
    var result: std.ArrayList(CharacterClassElement) = .empty;
    errdefer result.deinit(alloc);
    for (sorted) |range| {
        if (result.items.len != 0 and range.lower <= result.items[result.items.len - 1].upper + 1) {
            const last = &result.items[result.items.len - 1];
            last.upper = @max(last.upper, range.upper);
        } else {
            try result.append(alloc, range);
        }
    }
    return result.toOwnedSlice(alloc);
}

fn rangesEql(a: []const CharacterClassElement, b: []const CharacterClassElement) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!x.eql(y)) return false;
    }
    return true;
}

fn resolveStarExpressible(base: *const Grammar, expr_id: i32) ?i32 {
    var cur_id = expr_id;
    for (0..@intCast(MAX_DEPTH)) |_| {
        const cur = base.expr(cur_id);
        if (cur.ty == .CharacterClass or cur.ty == .CharacterClassStar or
            (cur.ty == .ByteString and cur.len() == 1))
        {
            return cur_id;
        }
        const element_id = soleElement(base, base.rule(nonLazyRuleRef(base, cur_id) orelse return null).body_expr_id) orelse return null;
        cur_id = element_id;
    }
    return null;
}

fn soleElement(base: *const Grammar, body_id: i32) ?i32 {
    const body = base.expr(body_id);
    if (body.ty != .Choices or body.len() != 1) return null;
    const choice = base.expr(body.data[0]);
    if (choice.ty == .Sequence and choice.len() == 1) return choice.data[0];
    return null;
}

fn nonLazyRuleRef(base: *const Grammar, expr_id: i32) ?i32 {
    const e = base.expr(expr_id);
    if (e.ty != .RuleRef) return null;
    const rule_id = e.ruleRefId();
    if (base.rule(rule_id).is_lazy) return null;
    return rule_id;
}

fn isRuleRefTo(base: *const Grammar, expr_id: i32, rule_id: i32) bool {
    const e = base.expr(expr_id);
    return e.ty == .RuleRef and e.ruleRefId() == rule_id;
}

test "flattenLazyBodies unwraps plus-desugar pattern and skips non-lazy grammars" {
    const gpa = std.testing.allocator;
    var builder = try GrammarBuilder.init(gpa);
    defer builder.deinit();
    const cc = try builder.addCharacterClass(&.{CharacterClassElement.init('a', 'a')}, false);
    const part = try builder.addRuleNamed("part", grammar_mod.NO_EXPR);
    const self_ref = try builder.addRuleRef(part);
    const rec = try builder.addSequence(&.{ cc, self_ref });
    const part_body = try builder.addChoices(&.{ rec, try builder.addSequence(&.{cc}) });
    builder.updateRuleBody(part, part_body);
    const part_ref = try builder.addRuleRef(part);
    const root_body = try builder.addChoices(&.{try builder.addSequence(&.{ part_ref, try builder.addByteString("b") })});
    const root = try builder.addRuleNamed("root", root_body);
    builder.updateLazy(root, true);
    var grammar = try builder.intoGrammar("root", null);
    defer grammar.deinit();

    var flattened = try flattenLazyBodies(gpa, &grammar);
    defer flattened.deinit();
    const ebnf = try flattened.toStringEbnf(gpa);
    defer gpa.free(ebnf);
    try std.testing.expect(std.mem.indexOf(u8, ebnf, "[a]*") != null);
    const root_line = std.mem.indexOf(u8, ebnf, "root[") orelse std.mem.indexOf(u8, ebnf, "root ::=") orelse return error.TestUnexpectedResult;
    const line_end = std.mem.indexOfScalarPos(u8, ebnf, root_line, '\n').?;
    try std.testing.expect(std.mem.indexOf(u8, ebnf[root_line..line_end], "part") == null);

    // Non-lazy grammar passes through in place without cloning.
    var b2 = try GrammarBuilder.init(gpa);
    defer b2.deinit();
    _ = try b2.addRuleNamed("root", try b2.addByteString("x"));
    var g2 = try b2.intoGrammar("root", null);
    defer g2.deinit();
    const orig_impl = g2.impl;
    try flattenInPlace(gpa, &g2);
    try std.testing.expectEqual(orig_impl, g2.impl);
}
