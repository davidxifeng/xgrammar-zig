//! Rewrites lazy rule bodies into their terminal-like form where possible
//! (`lazy_body_flattener.rs`).
//!
//! Committed-shortest (lazy) matching needs the whole rule body to compile into a single
//! per-rule FSM. This pass unwraps the single-reference chains produced by regex conversion,
//! and flattens the right-recursive plus pattern (`x ::= cc x | cc`) and star pattern
//! (`x ::= cc x | ""`) produced by regex conversion and repetition expansion into `(cc cc*)`
//! and `(cc*)`. Grammars without lazy rules are returned unchanged.

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_mod = @import("../grammar/mod.zig");
const CharacterClassElement = grammar_mod.CharacterClassElement;
const Grammar = grammar_mod.Grammar;
const GrammarBuilder = grammar_mod.GrammarBuilder;
const GrammarExpr = grammar_mod.GrammarExpr;
const GrammarExprType = grammar_mod.GrammarExprType;
const mutator = @import("mutator.zig");
const MutatorState = mutator.MutatorState;
const error_mod = @import("error.zig");
const FunctorError = error_mod.FunctorError;

/// Bound on the depth of reference chains and nested patterns that are resolved.
const MAX_DEPTH: i32 = 64;

const MAX_CODEPOINT: i32 = 0x10_FFFF;

/// Flattens the bodies of lazy rules (the C++ `LazyBodyFlattenerImpl`).
pub fn lazy_body_flattener(allocator: Allocator, grammar: *const Grammar) FunctorError!*Grammar {
    var has_lazy = false;
    for (grammar.rules.items) |rule| {
        if (rule.is_lazy) {
            has_lazy = true;
            break;
        }
    }
    if (!has_lazy) return grammar.clone(allocator);
    var state = MutatorState{
        .base = grammar,
        .builder = try GrammarBuilder.new(allocator),
        .cur_rule_name = "",
    };
    errdefer state.builder.deinit();
    for (grammar.rules.items) |rule| _ = try state.builder.add_empty_rule(rule.name);
    for (grammar.rules.items, 0..) |rule, rule_id| {
        state.cur_rule_name = rule.name;
        const new_body_expr_id = if (rule.is_lazy)
            try build_flattened_lazy_body(&state, rule.body_expr_id)
        else
            try mutator.visit_expr_id(identity{}, &state, rule.body_expr_id);
        state.builder.update_rule_body(@intCast(rule_id), new_body_expr_id);
        const new_lookahead_id = try mutator.visit_lookahead(identity{}, &state, rule.lookahead_assertion_id);
        state.builder.update_lookahead_assertion(@intCast(rule_id), new_lookahead_id);
        try state.builder.copy_rule_attributes(@intCast(rule_id), grammar, @intCast(rule_id), identity_id);
    }
    const result = try state.builder.into_grammar_with_root_id(allocator, grammar.root_rule_id);
    state.builder.deinit();
    return result;
}

/// The identity mutator, used to copy the parts that are not flattened
/// (Rust `struct LazyBodyFlattener;` with a blank `impl GrammarMutator`).
const identity = struct {};

fn identity_id(id: i32) i32 {
    return id;
}

/// Rust `PartialEq for GrammarExpr` (type tag and payload content).
fn expr_eql(a: GrammarExpr, b: GrammarExpr) bool {
    return a.ty == b.ty and std.mem.eql(i32, a.data, b.data);
}

fn build_flattened_lazy_body(
    state: *MutatorState,
    body_expr_id: i32,
) FunctorError!i32 {
    const gpa = state.gpa();
    const base = state.base;
    {
        const ty = base.expr(body_expr_id).ty;
        if (ty == .Regex or ty == .Substring) return mutator.visit_expr_id(identity{}, state, body_expr_id);
    }
    // Unwrap chains of single rule references (r ::= (x), x ::= (y), ...) produced by regex
    // conversion, and detect the plus-desugar pattern at the top level.
    var cur_body_id = body_expr_id;
    var cur_rule_id: ?i32 = null;
    for (0..@intCast(MAX_DEPTH)) |_| {
        const element_id = sole_element(base, cur_body_id) orelse break;
        const rule_id = non_lazy_rule_ref(base, element_id) orelse break;
        cur_rule_id = rule_id;
        cur_body_id = base.rule(rule_id).body_expr_id;
    }

    const body = base.expr(cur_body_id);
    if (body.ty != .Choices) {
        std.debug.print("The body of the lazy rule '{s}' cannot be flattened into a terminal-like form\n", .{state.cur_rule_name});
        return mutator.visit_expr_id(identity{}, state, cur_body_id);
    }
    var repeat_elements: std.ArrayList(i32) = .empty;
    defer repeat_elements.deinit(gpa);
    if (cur_rule_id != null and try try_emit_repeat_pattern(state, cur_body_id, cur_rule_id.?, &repeat_elements)) {
        const sequence = try state.builder.add_sequence(repeat_elements.items);
        return state.builder.add_choices(&.{sequence});
    }
    var new_choice_ids: std.ArrayList(i32) = .empty;
    defer new_choice_ids.deinit(gpa);
    for (body.data) |choice_id| {
        if (base.expr(choice_id).ty != .Sequence) {
            try new_choice_ids.append(gpa, try mutator.visit_expr_id(identity{}, state, choice_id));
            continue;
        }
        var elements: std.ArrayList(i32) = .empty;
        defer elements.deinit(gpa);
        if (!try flatten_sequence_into(state, choice_id, &elements, 0)) {
            // Not flattenable; copy as is and let the terminal-like validation report the error.
            std.debug.print("The body of the lazy rule '{s}' cannot be flattened into a terminal-like form\n", .{state.cur_rule_name});
            return mutator.visit_expr_id(identity{}, state, cur_body_id);
        }
        try new_choice_ids.append(gpa, try state.builder.add_sequence(elements.items));
    }
    return state.builder.add_choices(new_choice_ids.items);
}

/// Appends the flattened elements of the sequence, splicing rule references whose body is a
/// single terminal-like sequence or the plus-desugar pattern, and coalescing references to
/// single-character alternations into character classes. Returns false if some element
/// cannot be flattened.
fn flatten_sequence_into(
    state: *MutatorState,
    sequence_id: i32,
    elements: *std.ArrayList(i32),
    depth: i32,
) FunctorError!bool {
    if (depth > MAX_DEPTH) return false;
    const gpa = state.gpa();
    const base = state.base;
    for (base.expr(sequence_id).data) |element_id| {
        const element = base.expr(element_id);
        if (element.ty == .ByteString or element.ty == .CharacterClass or element.ty == .CharacterClassStar) {
            try elements.append(gpa, try state.builder.add_grammar_expr(element.ty, element.data));
            continue;
        }
        const ref_rule_id = non_lazy_rule_ref(base, element_id) orelse return false;
        const ref_body_id = base.rule(ref_rule_id).body_expr_id;
        if (try try_emit_repeat_pattern(state, ref_body_id, ref_rule_id, elements)) continue;
        const ref_body = base.expr(ref_body_id);
        if (ref_body.ty == .Choices and ref_body.len() == 1) {
            const only_choice = base.expr(ref_body.data[0]);
            if (only_choice.ty == .EmptyStr) continue;
            if (only_choice.ty == .Sequence) {
                var spliced: std.ArrayList(i32) = .empty;
                defer spliced.deinit(gpa);
                if (try flatten_sequence_into(state, ref_body.data[0], &spliced, depth + 1)) {
                    try elements.appendSlice(gpa, spliced.items);
                    continue;
                }
            }
        }
        var ranges: std.ArrayList(CharacterClassElement) = .empty;
        defer ranges.deinit(gpa);
        if (try collect_single_char_ranges(gpa, base, element_id, &ranges, 0)) {
            const unioned = try union_ranges(gpa, ranges.items);
            defer gpa.free(unioned);
            try elements.append(gpa, try state.builder.add_character_class(unioned, false));
            continue;
        }
        return false;
    }
    return true;
}

/// Resolves an expr matching exactly one character into the codepoint ranges it accepts,
/// appending them to `ranges`. Accepts character classes, single-byte strings, and
/// references to non-lazy rules that are alternations of such elements.
fn collect_single_char_ranges(
    gpa: Allocator,
    base: *const Grammar,
    expr_id: i32,
    ranges: *std.ArrayList(CharacterClassElement),
    depth: i32,
) FunctorError!bool {
    if (depth > MAX_DEPTH) return false;
    const expr = base.expr(expr_id);
    switch (expr.ty) {
        .CharacterClass => {
            try append_positive_ranges(gpa, expr, ranges);
            return true;
        },
        .ByteString => if (expr.len() == 1) {
            try ranges.append(gpa, CharacterClassElement.new(expr.data[0], expr.data[0]));
            return true;
        },
        else => {},
    }
    const rule_id = non_lazy_rule_ref(base, expr_id) orelse return false;
    const body = base.expr(base.rule(rule_id).body_expr_id);
    if (body.ty != .Choices) return false;
    for (body.data) |choice_id| {
        const choice = base.expr(choice_id);
        if (choice.ty != .Sequence or choice.len() != 1) return false;
        if (!try collect_single_char_ranges(gpa, base, choice.data[0], ranges, depth + 1)) return false;
    }
    return true;
}

/// If the body matches the plus-desugar pattern (`self ::= e self | e`) or the
/// (generalized) star-desugar pattern (`self ::= "" | e1 self | e2 self | ...`), appends
/// the equivalent `(e e*)` or `((e1|e2|...)*)` to `elements` and returns true.
fn try_emit_repeat_pattern(
    state: *MutatorState,
    body_id: i32,
    self_rule_id: i32,
    elements: *std.ArrayList(i32),
) FunctorError!bool {
    if (try try_emit_plus_pattern(state, body_id, self_rule_id, elements)) return true;
    if (try try_emit_generalized_plus_pattern(state, body_id, self_rule_id, elements)) return true;
    return try try_emit_star_pattern(state, body_id, self_rule_id, elements);
}

/// If the body matches the generalized plus-desugar pattern (`self ::= e1 self | ... | e1 | ...`)
/// with single-character elements whose recursive and base unions are equal, appends the
/// equivalent `(cc cc*)` over the union to `elements` and returns true.
fn try_emit_generalized_plus_pattern(
    state: *MutatorState,
    body_id: i32,
    self_rule_id: i32,
    elements: *std.ArrayList(i32),
) FunctorError!bool {
    const gpa = state.gpa();
    const base = state.base;
    const body = base.expr(body_id);
    if (body.ty != .Choices) return false;
    var recursive_ranges: std.ArrayList(CharacterClassElement) = .empty;
    defer recursive_ranges.deinit(gpa);
    var base_ranges: std.ArrayList(CharacterClassElement) = .empty;
    defer base_ranges.deinit(gpa);
    for (body.data) |choice_id| {
        const choice = base.expr(choice_id);
        if (choice.ty != .Sequence) return false;
        if (choice.len() == 1) {
            if (!try collect_single_char_ranges(gpa, base, choice.data[0], &base_ranges, 0)) return false;
            continue;
        }
        if (choice.len() == 2 and is_rule_ref_to(base, choice.data[1], self_rule_id) and
            try collect_single_char_ranges(gpa, base, choice.data[0], &recursive_ranges, 0))
        {
            continue;
        }
        return false;
    }
    const recursive_unioned = try union_ranges(gpa, recursive_ranges.items);
    defer gpa.free(recursive_unioned);
    // The unions must coincide: with differing sets (e.g. self ::= a self | b, which is a*b),
    // the language is not (a|b)+.
    const base_unioned = try union_ranges(gpa, base_ranges.items);
    defer gpa.free(base_unioned);
    if (recursive_unioned.len == 0 or !ranges_eql(recursive_unioned, base_unioned)) return false;
    try elements.append(gpa, try state.builder.add_character_class(recursive_unioned, false));
    try elements.append(gpa, try state.builder.add_character_class_star(recursive_unioned, false));
    return true;
}

/// If the body matches the plus-desugar pattern (`self ::= e self | e`) with `e` resolving
/// to a star-expressible expr, appends the equivalent `(e e*)` (or `(e*)` when `e` itself
/// resolves to a star) to `elements` and returns true.
fn try_emit_plus_pattern(
    state: *MutatorState,
    body_id: i32,
    self_rule_id: i32,
    elements: *std.ArrayList(i32),
) FunctorError!bool {
    const gpa = state.gpa();
    const base = state.base;
    const body = base.expr(body_id);
    if (body.ty != .Choices or body.len() != 2) return false;
    for (0..2) |recursive_pos| {
        const recursive = base.expr(body.data[recursive_pos]);
        const base_choice = base.expr(body.data[1 - recursive_pos]);
        if (recursive.ty != .Sequence or recursive.len() != 2 or
            base_choice.ty != .Sequence or base_choice.len() != 1) continue;
        if (!is_rule_ref_to(base, recursive.data[1], self_rule_id) or
            !expr_eql(base.expr(recursive.data[0]), base.expr(base_choice.data[0]))) continue;
        const resolved_id = resolve_star_expressible(base, recursive.data[0]) orelse {
            // Not a single terminal; e may still be a single-character alternation, giving
            // (e1|e2|...)+ = cc cc* over the union of the ranges.
            var ranges: std.ArrayList(CharacterClassElement) = .empty;
            defer ranges.deinit(gpa);
            if (!try collect_single_char_ranges(gpa, base, recursive.data[0], &ranges, 0)) continue;
            const unioned = try union_ranges(gpa, ranges.items);
            defer gpa.free(unioned);
            try elements.append(gpa, try state.builder.add_character_class(unioned, false));
            try elements.append(gpa, try state.builder.add_character_class_star(unioned, false));
            return true;
        };
        const resolved = base.expr(resolved_id);
        if (resolved.ty == .CharacterClassStar) {
            // (e*)+ is e*.
            try elements.append(gpa, try state.builder.add_grammar_expr(resolved.ty, resolved.data));
            return true;
        }
        var character_ranges: []CharacterClassElement = undefined;
        var is_negative = false;
        var owned: bool = false;
        if (resolved.ty == .CharacterClass) {
            const cc = try resolved.character_class(gpa);
            character_ranges = cc.ranges;
            is_negative = cc.is_negative;
            owned = true;
        } else {
            // A single-byte string.
            character_ranges = try gpa.alloc(CharacterClassElement, 1);
            character_ranges[0] = CharacterClassElement.new(resolved.data[0], resolved.data[0]);
            owned = true;
        }
        defer if (owned) gpa.free(character_ranges);
        try elements.append(gpa, try state.builder.add_grammar_expr(resolved.ty, resolved.data));
        try elements.append(gpa, try state.builder.add_character_class_star(character_ranges, is_negative));
        return true;
    }
    return false;
}

/// If the body matches the generalized star-desugar pattern (`self ::= "" | e1 self | e2 self |
/// ...`) with each `e` resolving to character ranges, appends the equivalent single character
/// class star `((e1|e2|...)*)` to `elements` and returns true.
fn try_emit_star_pattern(
    state: *MutatorState,
    body_id: i32,
    self_rule_id: i32,
    elements: *std.ArrayList(i32),
) FunctorError!bool {
    const gpa = state.gpa();
    const base = state.base;
    const body = base.expr(body_id);
    if (body.ty != .Choices) return false;
    var has_empty = false;
    var ranges: std.ArrayList(CharacterClassElement) = .empty;
    defer ranges.deinit(gpa);
    for (body.data) |choice_id| {
        const choice = base.expr(choice_id);
        if (choice.ty == .EmptyStr) {
            has_empty = true;
            continue;
        }
        if (choice.ty != .Sequence or choice.len() != 2 or
            !is_rule_ref_to(base, choice.data[1], self_rule_id) or
            !try collect_star_ranges(gpa, base, choice.data[0], &ranges, 0))
        {
            return false;
        }
    }
    if (!has_empty or ranges.items.len == 0) return false;
    const unioned = try union_ranges(gpa, ranges.items);
    defer gpa.free(unioned);
    try elements.append(gpa, try state.builder.add_character_class_star(unioned, false));
    return true;
}

/// Resolves an expr repeated under an enclosing star into the codepoint ranges it repeats
/// over, appending them to `ranges`. Accepts character classes, character class stars,
/// single-byte strings, and references to non-lazy rules that are alternations of such
/// elements, or star/plus recursions over them — under an enclosing star, all of these are
/// equivalent to the union of their character ranges.
fn collect_star_ranges(
    gpa: Allocator,
    base: *const Grammar,
    expr_id: i32,
    ranges: *std.ArrayList(CharacterClassElement),
    depth: i32,
) FunctorError!bool {
    if (depth > MAX_DEPTH) return false;
    const expr = base.expr(expr_id);
    switch (expr.ty) {
        .CharacterClass, .CharacterClassStar => {
            try append_positive_ranges(gpa, expr, ranges);
            return true;
        },
        .ByteString => if (expr.len() == 1) {
            try ranges.append(gpa, CharacterClassElement.new(expr.data[0], expr.data[0]));
            return true;
        },
        else => {},
    }
    const rule_id = non_lazy_rule_ref(base, expr_id) orelse return false;
    const body = base.expr(base.rule(rule_id).body_expr_id);
    if (body.ty != .Choices) return false;
    var has_empty = false;
    var base_elements: std.ArrayList(i32) = .empty;
    defer base_elements.deinit(gpa);
    var recursive_elements: std.ArrayList(i32) = .empty;
    defer recursive_elements.deinit(gpa);
    for (body.data) |choice_id| {
        const choice = base.expr(choice_id);
        if (choice.ty == .EmptyStr) {
            has_empty = true;
        } else if (choice.ty == .Sequence and choice.len() == 1) {
            try base_elements.append(gpa, choice.data[0]);
        } else if (choice.ty == .Sequence and choice.len() == 2 and
            is_rule_ref_to(base, choice.data[1], rule_id))
        {
            try recursive_elements.append(gpa, choice.data[0]);
        } else {
            return false;
        }
    }
    // The safe shapes: an alternation (a | b | ...), a star ("" | e1 self | ...), and a plus
    // (e self | e, or single-character alternated forms with equal recursive/base unions).
    // Mixed shapes like (a self | b) are a*b, whose star is not the union, so they are
    // rejected.
    const collect: []const i32 = blk: {
        if (recursive_elements.items.len == 0) break :blk base_elements.items;
        if ((base_elements.items.len == 0 and has_empty) or
            (recursive_elements.items.len == 1 and base_elements.items.len == 1 and !has_empty and
                expr_eql(base.expr(recursive_elements.items[0]), base.expr(base_elements.items[0]))))
        {
            break :blk recursive_elements.items;
        }
        if (!has_empty) {
            var recursive_ranges: std.ArrayList(CharacterClassElement) = .empty;
            defer recursive_ranges.deinit(gpa);
            var base_ranges: std.ArrayList(CharacterClassElement) = .empty;
            defer base_ranges.deinit(gpa);
            for (recursive_elements.items) |id| {
                if (!try collect_single_char_ranges(gpa, base, id, &recursive_ranges, depth + 1)) return false;
            }
            for (base_elements.items) |id| {
                if (!try collect_single_char_ranges(gpa, base, id, &base_ranges, depth + 1)) return false;
            }
            const recursive_unioned = try union_ranges(gpa, recursive_ranges.items);
            defer gpa.free(recursive_unioned);
            const base_unioned = try union_ranges(gpa, base_ranges.items);
            defer gpa.free(base_unioned);
            if (!ranges_eql(recursive_unioned, base_unioned)) return false;
            try ranges.appendSlice(gpa, recursive_unioned);
            return true;
        }
        return false;
    };
    for (collect) |id| {
        if (!try collect_star_ranges(gpa, base, id, ranges, depth + 1)) return false;
    }
    return true;
}

/// Appends the positive codepoint ranges of a character class or character class star,
/// complementing negated classes over `[0, 0x10FFFF]`.
fn append_positive_ranges(
    gpa: Allocator,
    expr: GrammarExpr,
    ranges: *std.ArrayList(CharacterClassElement),
) Allocator.Error!void {
    const cc = try expr.character_class(gpa);
    defer gpa.free(cc.ranges);
    if (!cc.is_negative) {
        try ranges.appendSlice(gpa, cc.ranges);
        return;
    }
    const unioned = try union_ranges(gpa, cc.ranges);
    defer gpa.free(unioned);
    var next: i32 = 0;
    for (unioned) |range| {
        if (range.lower > next) {
            try ranges.append(gpa, CharacterClassElement.new(next, range.lower - 1));
        }
        next = @max(next, range.upper + 1);
    }
    if (next <= MAX_CODEPOINT) {
        try ranges.append(gpa, CharacterClassElement.new(next, MAX_CODEPOINT));
    }
}

/// Sorts the ranges and merges overlapping or adjacent ones. Allocated from `gpa`.
fn union_ranges(gpa: Allocator, ranges: []const CharacterClassElement) Allocator.Error![]CharacterClassElement {
    const sorted = try gpa.dupe(CharacterClassElement, ranges);
    errdefer gpa.free(sorted);
    std.mem.sort(CharacterClassElement, sorted, {}, struct {
        fn less(_: void, a: CharacterClassElement, b: CharacterClassElement) bool {
            return a.lower < b.lower;
        }
    }.less);
    var result: std.ArrayList(CharacterClassElement) = .empty;
    errdefer result.deinit(gpa);
    for (sorted) |range| {
        if (result.items.len != 0 and range.lower <= result.items[result.items.len - 1].upper + 1) {
            const last = &result.items[result.items.len - 1];
            last.upper = @max(last.upper, range.upper);
        } else {
            try result.append(gpa, range);
        }
    }
    gpa.free(sorted);
    return result.toOwnedSlice(gpa);
}

/// Whether two sorted, merged range lists cover the same ranges.
fn ranges_eql(a: []const CharacterClassElement, b: []const CharacterClassElement) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!x.eql(y)) return false;
    }
    return true;
}

/// Resolves an expr through chains of non-lazy single-reference rules to a star-expressible
/// expr: a character class, a single-byte string, or a character class star.
fn resolve_star_expressible(base: *const Grammar, expr_id: i32) ?i32 {
    var cur_id = expr_id;
    for (0..@intCast(MAX_DEPTH)) |_| {
        const cur = base.expr(cur_id);
        if (cur.ty == .CharacterClass or cur.ty == .CharacterClassStar or
            (cur.ty == .ByteString and cur.len() == 1))
        {
            return cur_id;
        }
        const element_id = sole_element(base, base.rule(non_lazy_rule_ref(base, cur_id) orelse return null).body_expr_id) orelse return null;
        cur_id = element_id;
    }
    return null;
}

/// The only element of a body that is a choices of one sequence of one element.
fn sole_element(base: *const Grammar, body_id: i32) ?i32 {
    const body = base.expr(body_id);
    if (body.ty != .Choices or body.len() != 1) return null;
    const choice = base.expr(body.data[0]);
    if (choice.ty == .Sequence and choice.len() == 1) return choice.data[0];
    return null;
}

/// The referenced rule, if the expr is a reference to a non-lazy rule.
fn non_lazy_rule_ref(base: *const Grammar, expr_id: i32) ?i32 {
    const expr = base.expr(expr_id);
    if (expr.ty != .RuleRef) return null;
    const rule_id = expr.rule_ref_id();
    if (base.rule(rule_id).is_lazy) return null;
    return rule_id;
}

/// Whether the expr is a reference to `rule_id`.
fn is_rule_ref_to(base: *const Grammar, expr_id: i32, rule_id: i32) bool {
    const expr = base.expr(expr_id);
    return expr.ty == .RuleRef and expr.rule_ref_id() == rule_id;
}

test "lazy body flattener unwraps plus-desugar pattern" {
    const gpa = std.testing.allocator;
    const mod = @import("../grammar/mod.zig");
    const GB = mod.grammar_builder.GrammarBuilder;
    var builder = try GB.new(gpa);
    defer builder.deinit();
    // part ::= "a" part | "a" (plus-desugar); root[+lazy] ::= part "b" — flattened to
    // root ::= ("a" [a]* …) style terminal body: cc cc*.
    const cc = try builder.add_character_class(&.{mod.CharacterClassElement.new('a', 'a')}, false);
    const part = try builder.add_rule_named("part", mod.NO_EXPR);
    const self_ref = try builder.add_rule_ref(part);
    const rec = try builder.add_sequence(&.{ cc, self_ref });
    const part_body = try builder.add_choices(&.{ rec, try builder.add_sequence(&.{cc}) });
    builder.update_rule_body(part, part_body);
    const part_ref = try builder.add_rule_ref(part);
    const root_body = try builder.add_choices(&.{try builder.add_sequence(&.{ part_ref, try builder.add_byte_string("b") })});
    const root = try builder.add_rule_named("root", root_body);
    builder.update_lazy(root, true);
    const grammar = try builder.into_grammar(gpa, "root", null);
    defer grammar.deinit();

    const flattened = try lazy_body_flattener(gpa, grammar);
    defer flattened.deinit();
    const printer = mod.printer;
    const ebnf = try printer.to_string_ebnf(flattened, gpa);
    defer gpa.free(ebnf);
    try std.testing.expect(std.mem.indexOf(u8, ebnf, "[a]*") != null);
// the root body must not reference `part` any more
    const root_line = std.mem.indexOf(u8, ebnf, "root[") orelse std.mem.indexOf(u8, ebnf, "root ::=") orelse return error.TestUnexpectedResult;
    const line_end = std.mem.indexOfScalarPos(u8, ebnf, root_line, '\n').?;
    try std.testing.expect(std.mem.indexOf(u8, ebnf[root_line..line_end], "part") == null);
}
