//! Expands bounded/unbounded repetitions into explicit rules (`repetition_range_expander.rs`).
//!
//! Small bounds are "unzipped" into repeated elements and a tail of optional rules; large
//! bounds keep a `Repeat` node wrapped so the matcher can count efficiently. Lookups go
//! through the builder (never the source grammar) so expanding two large repeats in one
//! rule cannot index out of bounds. Identical repetitions share one expansion.

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_mod = @import("../grammar/mod.zig");
const CharacterClassElement = grammar_mod.CharacterClassElement;
const Grammar = grammar_mod.Grammar;
const GrammarExprType = grammar_mod.GrammarExprType;
const mutator = @import("mutator.zig");
const MutatorState = mutator.MutatorState;
const error_mod = @import("error.zig");
const FunctorError = error_mod.FunctorError;
const FunctorErrorInfo = error_mod.FunctorErrorInfo;

const UNZIP_THRESHOLD: i64 = 128;

/// Expands repetition ranges (the `GrammarFunctor.repetition_range_expander` pass).
///
/// Every repetition is checked up front, as the expansion visits every repetition reachable
/// from a rule. `diag` optionally receives `InvalidRepetitionRange` details.
pub fn repetition_range_expander(
    allocator: Allocator,
    grammar: *const Grammar,
    diag: ?*FunctorErrorInfo,
) FunctorError!*Grammar {
    for (0..@intCast(grammar.num_exprs())) |expr_id| {
        const expr = grammar.expr(@intCast(expr_id));
        if (expr.ty == .Repeat) {
            const repeat = expr.repeat();
            const lower: i64 = repeat.min_repeat;
            const upper: i64 = repeat.max_repeat;
            if (lower < 0 or (upper != -1 and upper < lower)) {
                error_mod.set_diag(diag, .{ .InvalidRepetitionRange = .{ .lower = lower, .upper = upper } });
                return error.InvalidRepetitionRange;
            }
        }
    }
    var expander = RepetitionRangeExpander{ .repetition_cache = RepetitionCache.init(allocator) };
    defer expander.repetition_cache.deinit();
    return mutator.apply(&expander, allocator, grammar);
}

/// The repetition cache: `cache_key = (expr type tag, expr data…, lower, upper)`
/// (Rust `Vec<i64>` keys; kept as i64 bytes with a string-hash map). Owns its keys.
const RepetitionCache = struct {
    map: std.StringHashMap(i32),
    allocator: Allocator,

    fn init(allocator: Allocator) RepetitionCache {
        return .{ .map = std.StringHashMap(i32).init(allocator), .allocator = allocator };
    }

    fn deinit(self: *RepetitionCache) void {
        var kit = self.map.keyIterator();
        while (kit.next()) |k| self.allocator.free(k.*);
        self.map.deinit();
    }

    fn get(self: *RepetitionCache, key: []const u8) ?i32 {
        return self.map.get(key);
    }

    fn put(self: *RepetitionCache, key: []u8, value: i32) Allocator.Error!void {
        try self.map.put(key, value);
    }
};

const RepetitionRangeExpander = struct {
    repetition_cache: RepetitionCache,

    pub fn visit_repeat(
        self: *RepetitionRangeExpander,
        state: *MutatorState,
        ty: GrammarExprType,
        data: []const i32,
    ) FunctorError!i32 {
        _ = ty;
        const ref_rule_id = data[0];
        const lower: i64 = data[1];
        const upper: i64 = data[2];
        const name = state.cur_rule_name;
        return handle_repetition_range(self, state, name, ref_rule_id, lower, upper);
    }
};

/// Unzips a repetition into explicit sequences/choices (used for small bounds).
fn legacy_handle_repetition_range(
    state: *MutatorState,
    cur_rule_name: []const u8,
    grammar_expr_id: i32,
    lower: i64,
    upper: i64,
) FunctorError!i32 {
    const gpa = state.gpa();
    // Construct expr expr ... expr (lower times).
    var elements: std.ArrayList(i32) = .empty;
    defer elements.deinit(gpa);
    try elements.appendNTimes(gpa, grammar_expr_id, @intCast(@max(lower, 0)));

    // Case 1: {l} — expr repeated l times.
    if (upper == lower) {
        const seq = try state.builder.add_sequence(elements.items);
        const choices = try state.builder.add_choices(&.{seq});
        const result_rule_id = try state.builder.add_rule_with_hint(cur_rule_name, choices);
        return state.builder.add_rule_ref(result_rule_id);
    }

    // Case 2: {l,} — expr repeated l times, then `rest ::= "" | expr rest`.
    if (upper == -1) {
        const new_rule_name = try state.builder.get_new_rule_name(cur_rule_name);
        const new_rule_id = try state.builder.add_empty_rule(new_rule_name);
        const ref_to_new_rule = try state.builder.add_rule_ref(new_rule_id);
        const empty = try state.builder.add_empty_str();
        const seq = try state.builder.add_sequence(&.{ grammar_expr_id, ref_to_new_rule });
        const body = try state.builder.add_choices(&.{ empty, seq });
        state.builder.update_rule_body(new_rule_id, body);
        try elements.append(gpa, try state.builder.add_rule_ref(new_rule_id));
        const final_seq = try state.builder.add_sequence(elements.items);
        const choices = try state.builder.add_choices(&.{final_seq});
        const result_rule_id = try state.builder.add_rule_with_hint(cur_rule_name, choices);
        return state.builder.add_rule_ref(result_rule_id);
    }

    // Case 3: {l, r} with r - l >= 1 — a chain of optional rules.
    const extra: usize = @intCast(upper - lower);
    var rest_rule_ids: std.ArrayList(i32) = .empty;
    defer rest_rule_ids.deinit(gpa);
    try rest_rule_ids.ensureTotalCapacity(gpa, extra);
    for (0..extra) |_| {
        const new_rule_name = try state.builder.get_new_rule_name(cur_rule_name);
        rest_rule_ids.appendAssumeCapacity(try state.builder.add_empty_rule(new_rule_name));
    }
    for (0..extra -| 1) |i| {
        const ref_to_next_rule = try state.builder.add_rule_ref(rest_rule_ids.items[i + 1]);
        const empty = try state.builder.add_empty_str();
        const seq = try state.builder.add_sequence(&.{ grammar_expr_id, ref_to_next_rule });
        const body = try state.builder.add_choices(&.{ empty, seq });
        state.builder.update_rule_body(rest_rule_ids.items[i], body);
    }
    const empty = try state.builder.add_empty_str();
    const last_seq = try state.builder.add_sequence(&.{grammar_expr_id});
    const last_body = try state.builder.add_choices(&.{ empty, last_seq });
    const last_rule = rest_rule_ids.items[rest_rule_ids.items.len - 1];
    state.builder.update_rule_body(last_rule, last_body);

    try elements.append(gpa, try state.builder.add_rule_ref(rest_rule_ids.items[0]));
    const final_seq = try state.builder.add_sequence(elements.items);
    const choices = try state.builder.add_choices(&.{final_seq});
    const result_rule_id = try state.builder.add_rule_with_hint(cur_rule_name, choices);
    return state.builder.add_rule_ref(result_rule_id);
}

/// Handles `{lower, upper}`, unzipping for small bounds and keeping a `Repeat` for large.
fn handle_repetition_range(
    expander: *RepetitionRangeExpander,
    state: *MutatorState,
    cur_rule_name: []const u8,
    rule_id: i32,
    lower: i64,
    upper: i64,
) FunctorError!i32 {
    // If the referred rule is a single element, use that element directly. Keep the
    // reference to budgeted, suffix/stop, lazy, and temperature rules: replacing it with the
    // rule's content would erase the rule that the runtime semantics apply to.
    var grammar_expr_id = try state.builder.add_rule_ref(rule_id);
    const base = state.base;
    const ref_rule = base.rule(rule_id);
    const ref_rule_body = base.expr(ref_rule.body_expr_id);
    if (ref_rule.max_tokens < 0 and ref_rule.max_chars < 0 and
        base.suffix_stop_info(rule_id) == null and !ref_rule.is_lazy and
        ref_rule.temperature == null and ref_rule_body.ty == .Choices and ref_rule_body.data.len == 1)
    {
        const ref_choice = base.expr(ref_rule_body.data[0]);
        if (ref_choice.ty == .Sequence and ref_choice.data.len == 1) {
            // Visit the element instead of copying it verbatim: a nested repetition such as
            // b ::= a{2,} must be expanded too, or an unbounded repeat reaches the parser.
            grammar_expr_id = try mutator.visit_expr_id(expander, state, ref_choice.data[0]);
        }
    }

    const repeated_expr = state.builder.grammar_expr(grammar_expr_id);
    // Cache keys live and die with the cache's allocator (the builder allocator is an
    // arena; freeing its pointers with the pass allocator would be invalid).
    const cache_gpa = expander.repetition_cache.allocator;
    const cache_key = try make_cache_key(cache_gpa, repeated_expr.ty, repeated_expr.data, lower, upper);
    errdefer cache_gpa.free(cache_key);
    if (expander.repetition_cache.get(cache_key)) |cached| {
        cache_gpa.free(cache_key);
        return cached;
    }

    const result = try expand_repetition_range(state, cur_rule_name, grammar_expr_id, lower, upper);
    try expander.repetition_cache.put(cache_key, result);
    return result;
}

/// The cache key of one repetition: the type tag, the data payload, and the bounds,
/// little-endian i64s (Rust hashes the equivalent `Vec<i64>`).
fn make_cache_key(
    gpa: Allocator,
    ty: GrammarExprType,
    data: []const i32,
    lower: i64,
    upper: i64,
) Allocator.Error![]u8 {
    var key: std.ArrayList(u8) = .empty;
    errdefer key.deinit(gpa);
    try key.ensureTotalCapacity(gpa, (data.len + 3) * 8);
    var buf: [8]u8 = undefined;
    try key.appendSlice(gpa, bytes_of(&buf, ty.as_i32()));
    for (data) |v| try key.appendSlice(gpa, bytes_of(&buf, v));
    try key.appendSlice(gpa, bytes_of(&buf, lower));
    try key.appendSlice(gpa, bytes_of(&buf, upper));
    return key.toOwnedSlice(gpa);
}

fn bytes_of(buf: *[8]u8, v: i64) []const u8 {
    std.mem.writeInt(i64, buf, v, .little);
    return buf;
}

fn expand_repetition_range(
    state: *MutatorState,
    cur_rule_name: []const u8,
    grammar_expr_id: i32,
    lower_in: i64,
    upper_in: i64,
) FunctorError!i32 {
    var lower = lower_in;
    var upper = upper_in;
    // Case 1: small upper, or unbounded upper with small lower — unzip.
    if ((upper != -1 and upper <= UNZIP_THRESHOLD) or (upper == -1 and lower <= UNZIP_THRESHOLD)) {
        return legacy_handle_repetition_range(state, cur_rule_name, grammar_expr_id, lower, upper);
    }

    // Case 2: upper unbounded with large lower, or upper bounded but > threshold.
    var choices: std.ArrayList(i32) = .empty;
    defer choices.deinit(state.gpa());
    if (lower < UNZIP_THRESHOLD) {
        const unzipped = try legacy_handle_repetition_range(state, cur_rule_name, grammar_expr_id, lower, UNZIP_THRESHOLD - 1);
        try choices.append(state.gpa(), try state.builder.add_sequence(&.{unzipped}));
        lower = UNZIP_THRESHOLD;
    }

    var infinite_repetition_id: ?i32 = null;
    var repeated_sequence: std.ArrayList(i32) = .empty;
    defer repeated_sequence.deinit(state.gpa());
    // Case 2.2: unbounded upper becomes `{lower} {0, inf}`.
    if (upper == -1) {
        const expr = state.builder.grammar_expr(grammar_expr_id);
        if (expr.ty == .CharacterClass) {
            const ranges = try expr.character_class(state.gpa());
            defer state.gpa().free(ranges.ranges);
            infinite_repetition_id = try state.builder.add_character_class_star(ranges.ranges, ranges.is_negative);
        } else {
            var name_buf: std.ArrayList(u8) = .empty;
            defer name_buf.deinit(state.gpa());
            try name_buf.appendSlice(state.gpa(), cur_rule_name);
            try name_buf.appendSlice(state.gpa(), "_repeat_inf");
            const unbounded_name = try state.builder.get_new_rule_name(name_buf.items);
            const unbounded_rule_id = try state.builder.add_empty_rule(unbounded_name);
            const ref_unbounded = try state.builder.add_rule_ref(unbounded_rule_id);
            const recursion_sequence = try state.builder.add_sequence(&.{ grammar_expr_id, ref_unbounded });
            const empty = try state.builder.add_empty_str();
            const recursion_choice = try state.builder.add_choices(&.{ empty, recursion_sequence });
            state.builder.update_rule_body(unbounded_rule_id, recursion_choice);
            infinite_repetition_id = try state.builder.add_rule_ref(unbounded_rule_id);
        }
        upper = lower;
    }

    var repeat_name_buf: std.ArrayList(u8) = .empty;
    defer repeat_name_buf.deinit(state.gpa());
    try repeat_name_buf.appendSlice(state.gpa(), cur_rule_name);
    try repeat_name_buf.appendSlice(state.gpa(), "_repeat_1");
    const repeat_name = repeat_name_buf.items;

    if (infinite_repetition_id) |id| {
        try repeated_sequence.append(state.gpa(), id);
    }

    // The repetition body, when upper is strictly above the threshold.
    if (upper != UNZIP_THRESHOLD) {
        const inner_seq = try state.builder.add_sequence(&.{grammar_expr_id});
        const inner_choices = try state.builder.add_choices(&.{inner_seq});
        const new_rule_id = try state.builder.add_rule_with_hint(repeat_name, inner_choices);
        const repeat = try state.builder.add_repeat(
            new_rule_id,
            @intCast(lower - UNZIP_THRESHOLD),
            @intCast(upper - UNZIP_THRESHOLD),
        );
        const repeat_seq = try state.builder.add_sequence(&.{repeat});
        const repeat_choices = try state.builder.add_choices(&.{repeat_seq});
        var inner_name_buf: std.ArrayList(u8) = .empty;
        defer inner_name_buf.deinit(state.gpa());
        try inner_name_buf.appendSlice(state.gpa(), repeat_name);
        try inner_name_buf.appendSlice(state.gpa(), "_inner");
        const new_repeated_rule_id = try state.builder.add_rule_with_hint(inner_name_buf.items, repeat_choices);
        try repeated_sequence.append(state.gpa(), try state.builder.add_rule_ref(new_repeated_rule_id));
        var repetition_lookahead: std.ArrayList(i32) = .empty;
        defer repetition_lookahead.deinit(state.gpa());
        try repetition_lookahead.appendNTimes(state.gpa(), grammar_expr_id, @intCast(UNZIP_THRESHOLD));
        const lookahead = try state.builder.add_sequence(repetition_lookahead.items);
        state.builder.update_lookahead_assertion(new_rule_id, lookahead);
    }

    // The last `threshold` copies of the element.
    for (0..@intCast(UNZIP_THRESHOLD)) |_| {
        try repeated_sequence.append(state.gpa(), grammar_expr_id);
    }

    try choices.append(state.gpa(), try state.builder.add_sequence(repeated_sequence.items));
    const result_choices = try state.builder.add_choices(choices.items);
    const result_rule_id = try state.builder.add_rule_with_hint(cur_rule_name, result_choices);
    return state.builder.add_rule_ref(result_rule_id);
}

test "repetition range expander unzips small bounds" {
    const gpa = std.testing.allocator;
    const mod = @import("../grammar/mod.zig");
    const GrammarBuilder = mod.GrammarBuilder;
    var builder = try GrammarBuilder.new(gpa);
    defer builder.deinit();
    const inner = try builder.add_rule_named("inner", try builder.add_byte_string("a"));
    const rep = try builder.add_repeat(inner, 2, 3);
    _ = try builder.add_rule_named("root", rep);
    const grammar = try builder.into_grammar(gpa, "root", null);
    defer grammar.deinit();

    const expanded = try repetition_range_expander(gpa, grammar, null);
    defer expanded.deinit();
    const printer = mod.printer;
    const ebnf = try printer.to_string_ebnf(expanded, gpa);
    defer gpa.free(ebnf);
    // {2,3} becomes a repeated run followed by a chain of optional rules.
    try std.testing.expect(std.mem.indexOf(u8, ebnf, "inner inner") != null);
}

test "repetition range expander rejects invalid ranges" {
    const gpa = std.testing.allocator;
    const mod = @import("../grammar/mod.zig");
    const GrammarBuilder = mod.GrammarBuilder;
    var builder = try GrammarBuilder.new(gpa);
    defer builder.deinit();
    const inner = try builder.add_rule_named("inner", try builder.add_byte_string("a"));
    const rep = try builder.add_repeat(inner, 3, 1);
    _ = try builder.add_rule_named("root", rep);
    const grammar = try builder.into_grammar(gpa, "root", null);
    defer grammar.deinit();

    var diag: FunctorErrorInfo = undefined;
    try std.testing.expectError(error.InvalidRepetitionRange, repetition_range_expander(gpa, grammar, &diag));
    const msg = try error_mod.format_message(gpa, diag);
    defer gpa.free(msg);
    try std.testing.expectEqualStrings("Invalid repetition range {3, 1}", msg);
}
