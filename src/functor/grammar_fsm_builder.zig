//! Builds finite-state machines from grammar expressions (`grammar_fsm_builder.rs`).
//!
//! Each rule body lowers into an `FsmWithStartEnd` built directly into one FSM: byte
//! strings, character classes (canonical UTF-8 codepoint ranges), rule references, tokens,
//! repeats, regexes, substrings, and the tag-dispatch automata. The per-rule automata are
//! then folded into the grammar's shared complete FSM.

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_mod = @import("../grammar/mod.zig");
const Grammar = grammar_mod.Grammar;
const GrammarBuilder = grammar_mod.GrammarBuilder;
const GrammarExpr = grammar_mod.GrammarExpr;
const GrammarExprType = grammar_mod.GrammarExprType;
const TagDispatch = grammar_mod.TagDispatch;
const TokenTagDispatch = grammar_mod.TokenTagDispatch;
const fsm_mod = @import("../fsm/mod.zig");
const CompactFsm = fsm_mod.CompactFsm;
const CompactFsmWithStartEnd = fsm_mod.CompactFsmWithStartEnd;
const CompactFsmWithStartEndWithSize = fsm_mod.CompactFsmWithStartEndWithSize;
const FsmWithStartEndWithSize = fsm_mod.FsmWithStartEndWithSize;
const Fsm = fsm_mod.Fsm;
const FsmWithStartEnd = fsm_mod.FsmWithStartEnd;
const RegexFsmBuilder = fsm_mod.RegexFsmBuilder;
const TrieFsmBuilder = fsm_mod.TrieFsmBuilder;
const add_packed_utf8_range_edges = fsm_mod.add_packed_utf8_range_edges;
const codepoint_to_packed_utf8 = fsm_mod.codepoint_to_packed_utf8;
const expression_fsm_builder_mod = @import("expression_fsm_builder.zig");
const ExpressionFsmBuilder = expression_fsm_builder_mod.ExpressionFsmBuilder;
const regular_grammar_fsm_builder_mod = @import("regular_grammar_fsm_builder.zig");
const in_place = @import("in_place_grammar_rewriter.zig");
const error_mod = @import("error.zig");
const FunctorError = error_mod.FunctorError;
const FunctorErrorInfo = error_mod.FunctorErrorInfo;

/// The largest Unicode codepoint.
const MAX_CODEPOINT: u32 = 0x10FFFF;

/// Stateless builder of per-expression FSMs (the C++ `GrammarFSMBuilder`).
pub const GrammarFsmBuilder = struct {
    /// Compiles every rule body into an FSM, folding them into one shared complete FSM
    /// stored on the grammar. Large bounded regex repetitions add new rules, which get
    /// FSMs too.
    ///
    /// `diag` optionally receives the `FsmBuild` failure message (allocated from
    /// `allocator`; the caller frees it).
    pub fn apply(allocator: Allocator, grammar: *Grammar, diag: ?*FunctorErrorInfo) FunctorError!void {
        const gpa = allocator;
        const num_original_rules = grammar.num_rules();
        var complete_fsm = try Fsm.new(gpa, 0);
        errdefer complete_fsm.deinit();
        var per_rule_fsms: std.ArrayList(FsmWithStartEndWithSize) = .empty;
        errdefer {
            for (per_rule_fsms.items) |*item| item.deinit();
            per_rule_fsms.deinit(gpa);
        }
        {
            var builder = try GrammarBuilder.edit_in_place(grammar);
            defer builder.deinit();
            // New rules may be appended while building, so the rule count is re-read.
            var rule_id: i32 = 0;
            while (rule_id < builder.num_rules()) : (rule_id += 1) {
                const rule = builder.get_rule(rule_id);
                var rule_fsm = try ExpressionFsmBuilder.build_expression_fsm(
                    gpa,
                    &builder,
                    rule.body_expr_id,
                    rule.name,
                    true,
                    diag,
                );
                defer rule_fsm.deinit();
                try per_rule_fsms.append(gpa, try rule_fsm.add_to_complete_fsm(&complete_fsm));
            }
            builder.edit_in_place_commit(grammar);
        }
        errdefer complete_fsm.deinit();

        // The rules created while building missed the allow-empty analysis; their ids are
        // larger than all existing ones, so appending keeps the list sorted.
        var allow_empty: std.ArrayList(i32) = .empty;
        defer allow_empty.deinit(gpa);
        try allow_empty.appendSlice(gpa, grammar.allow_empty_rule_ids.items);
        for (@intCast(num_original_rules)..@intCast(grammar.num_rules())) |rule_id| {
            const body = grammar.expr(grammar.rule(@intCast(rule_id)).body_expr_id);
            std.debug.assert(body.ty == .Regex);
            const pattern = try body.regex_pattern(gpa);
            defer gpa.free(pattern);
            var err_msg: ?[]u8 = null;
            defer if (err_msg) |m| gpa.free(m);
            if (RegexFsmBuilder.matches_empty(gpa, pattern, &err_msg)) |matches| {
                if (matches) try allow_empty.append(gpa, @intCast(rule_id));
            } else |_| {}
        }
        try grammar.set_allow_empty_rule_ids(allow_empty.items);

        var compact_complete_fsm = try CompactFsm.from_fsm(gpa, &complete_fsm);
        errdefer compact_complete_fsm.deinit();
        var compact_per_rule_fsms: std.ArrayList(?CompactFsmWithStartEndWithSize) = .empty;
        errdefer {
            for (compact_per_rule_fsms.items) |item_const| {
                if (item_const) |mut_const| {
                    var f = mut_const;
                    f.deinit();
                }
            }
            compact_per_rule_fsms.deinit(gpa);
        }
        for (per_rule_fsms.items) |fsm| {
            // `CompactFsmWithStartEnd.new` consumes `ends`; the source keeps its own list.
            var ends_dup: std.ArrayList(i32) = .empty;
            try ends_dup.appendSlice(gpa, fsm.ends.items);
            const with_start_end = try CompactFsmWithStartEnd.new(
                gpa,
                compact_complete_fsm.clone(),
                fsm.start,
                ends_dup,
                false,
            );
            try compact_per_rule_fsms.append(gpa, CompactFsmWithStartEndWithSize.new(
                with_start_end,
                fsm.edge_num,
                fsm.node_num,
            ));
        }
        // `set_fsms` retains the grammar's own references; the caller's handles stay valid
        // and are released here (PORTING: grammar.zig `set_fsms` doc).
        try grammar.set_fsms(compact_complete_fsm, compact_per_rule_fsms.items);
        compact_complete_fsm.deinit();
        for (compact_per_rule_fsms.items) |item_const| {
            if (item_const) |mut_const| {
                var f = mut_const;
                f.deinit();
            }
        }
        compact_per_rule_fsms.deinit(gpa);
        complete_fsm.deinit();
        for (per_rule_fsms.items) |*item| item.deinit();
        per_rule_fsms.deinit(gpa);
    }

    /// Builds the FSM for a `RuleRef` expression. The caller owns the result.
    pub fn rule_ref(allocator: Allocator, expr: GrammarExpr) Allocator.Error!FsmWithStartEnd {
        var fsm = try Fsm.new(allocator, 2);
        errdefer fsm.deinit();
        try fsm.add_rule_edge(0, 1, expr.data[0]);
        var ends: std.ArrayList(i32) = .empty;
        errdefer ends.deinit(allocator);
        try ends.append(allocator, 1);
        return FsmWithStartEnd.new(allocator, fsm, 0, ends, false);
    }

    /// Builds the FSM for a `ByteString` expression (one transition per byte).
    pub fn byte_string(allocator: Allocator, expr: GrammarExpr) Allocator.Error!FsmWithStartEnd {
        std.debug.assert(expr.ty == .ByteString);
        var fsm = try Fsm.new(allocator, 1);
        errdefer fsm.deinit();
        const end = try build_byte_string(&fsm, expr.data, 0);
        var ends: std.ArrayList(i32) = .empty;
        errdefer ends.deinit(allocator);
        try ends.append(allocator, end);
        return FsmWithStartEnd.new(allocator, fsm, 0, ends, false);
    }

    /// Builds the FSM for a `CharacterClass` / `CharacterClassStar` expression.
    pub fn character_class(allocator: Allocator, expr: GrammarExpr) Allocator.Error!FsmWithStartEnd {
        var fsm = try Fsm.new(allocator, 1);
        errdefer fsm.deinit();
        const end: i32 = if (expr.ty == .CharacterClassStar) 0 else try fsm.add_state();
        add_character_class_transitions(&fsm, expr.data, 0, end);
        var ends: std.ArrayList(i32) = .empty;
        errdefer ends.deinit(allocator);
        try ends.append(allocator, end);
        return FsmWithStartEnd.new(allocator, fsm, 0, ends, false);
    }

    /// Builds the FSM for a `Token` expression (a single token-set edge).
    pub fn token(allocator: Allocator, expr: GrammarExpr) Allocator.Error!FsmWithStartEnd {
        std.debug.assert(expr.ty == .Token);
        var fsm = try Fsm.new(allocator, 2);
        errdefer fsm.deinit();
        try fsm.add_token_edge(0, 1, expr.data);
        var ends: std.ArrayList(i32) = .empty;
        errdefer ends.deinit(allocator);
        try ends.append(allocator, 1);
        return FsmWithStartEnd.new(allocator, fsm, 0, ends, false);
    }

    /// Builds the FSM for an `ExcludeToken` expression (a single exclude-token edge).
    pub fn exclude_token(allocator: Allocator, expr: GrammarExpr) Allocator.Error!FsmWithStartEnd {
        std.debug.assert(expr.ty == .ExcludeToken);
        var fsm = try Fsm.new(allocator, 2);
        errdefer fsm.deinit();
        try fsm.add_exclude_token_edge(0, 1, expr.data);
        var ends: std.ArrayList(i32) = .empty;
        errdefer ends.deinit(allocator);
        try ends.append(allocator, 1);
        return FsmWithStartEnd.new(allocator, fsm, 0, ends, false);
    }

    /// Builds the dispatch FSM for a token tag-dispatch.
    pub fn token_tag_dispatch(allocator: Allocator, ttd: *const TokenTagDispatch) Allocator.Error!FsmWithStartEnd {
        var fsm = try Fsm.new(allocator, 1);
        errdefer fsm.deinit();
        const ends = try build_token_tag_dispatch(&fsm, ttd, 0);
        return FsmWithStartEnd.new(allocator, fsm, 0, ends, false);
    }

    /// Builds the FSM for a `Sequence` expression of `grammar` (no simplification).
    /// The caller owns the result.
    pub fn sequence(
        allocator: Allocator,
        expr: GrammarExpr,
        grammar: *const Grammar,
    ) (error_mod.FunctorError)!FsmWithStartEnd {
        std.debug.assert(expr.ty == .Sequence);
        var builder = try GrammarBuilder.from_grammar(grammar, allocator);
        defer builder.deinit();
        const sequence_id = try builder.add_sequence(expr.data);
        const result = try ExpressionFsmBuilder.build(allocator, &builder, sequence_id, null, false, null);
        builder.deinit();
        return result;
    }

    /// Builds the FSM for a `Choices` expression of `grammar`, simplified and minimized.
    /// The caller owns the result.
    pub fn choices(
        allocator: Allocator,
        expr: GrammarExpr,
        grammar: *const Grammar,
    ) FunctorError!FsmWithStartEnd {
        std.debug.assert(expr.ty == .Choices);
        var builder = try GrammarBuilder.from_grammar(grammar, allocator);
        defer builder.deinit();
        const choices_id = try builder.add_choices(expr.data);
        const result = try ExpressionFsmBuilder.build_expression_fsm(allocator, &builder, choices_id, null, false, null);
        builder.deinit();
        return result;
    }

    /// Builds the dispatch FSM for a string tag-dispatch, or `null` if the trie cannot be
    /// built. The caller owns the result.
    pub fn tag_dispatch(allocator: Allocator, td: *const TagDispatch) Allocator.Error!?FsmWithStartEnd {
        const gpa = allocator;
        const tag_names = try gpa.alloc([]const u8, td.tag_rule_pairs.items.len);
        defer gpa.free(tag_names);
        for (td.tag_rule_pairs.items, 0..) |pair, i| tag_names[i] = pair.tag;
        const excluded = try gpa.alloc([]const u8, td.excludes.items.len);
        defer gpa.free(excluded);
        for (td.excludes.items, 0..) |e, i| excluded[i] = e;
        var end_states: std.ArrayList(i32) = .empty;
        defer end_states.deinit(gpa);
        const trie = try TrieFsmBuilder.build(gpa, tag_names, excluded, &end_states, true, true);
        var trie_fsm = trie orelse return null;
        defer trie_fsm.deinit();
        const start = trie_fsm.get_start();

        // The final end states are all states except the trie's terminal (trigger) states.
        var ends: std.ArrayList(i32) = .empty;
        errdefer ends.deinit(gpa);
        for (0..@intCast(trie_fsm.num_states())) |state| {
            if (!trie_fsm.is_end_state(@intCast(state))) try ends.append(gpa, @intCast(state));
        }
        // Add a rule-ref edge out of each trigger's terminal state.
        for (td.tag_rule_pairs.items, 0..) |pair, i| {
            const next_state = if (td.loop_after_dispatch)
                start
            else blk: {
                const state = try trie_fsm.fsm_mut().add_state();
                try ends.append(gpa, state);
                break :blk state;
            };
            try trie_fsm.fsm_mut().add_rule_edge(end_states.items[i], next_state, pair.rule_id);
        }
        const result = FsmWithStartEnd.new(gpa, try trie_fsm.get_fsm().clone(gpa), start, ends, false) catch |err| {
            ends.deinit(gpa);
            return err;
        };
        return result;
    }

    /// Compiles a standalone regex into a simplified, minimized automaton. With `json_string`
    /// the characters that must be escaped in a JSON string are excluded. The caller owns
    /// the result. On error, `err_msg.*` receives the message (allocated; caller frees).
    pub fn regex(
        allocator: Allocator,
        regex_pattern: []const u8,
        json_string: bool,
        err_msg: ?*?[]u8,
    ) @import("../fsm/regex_ir.zig").RegexError!FsmWithStartEnd {
        const gpa = allocator;
        const result = if (json_string)
            RegexFsmBuilder.build_with_forbidden_chars(gpa, regex_pattern, json_string_forbidden_chars(), null, "", err_msg)
        else
            RegexFsmBuilder.build(gpa, regex_pattern, null, "", err_msg);
        var built = result catch |err| return err;
        defer built.deinit();
        var simplified = try built.simplify_epsilon(gpa);
        defer simplified.deinit();
        return simplified.merge_equivalent_states(gpa);
    }

    /// Flattens a regular grammar (no non-tail recursion, no annotations) into one automaton
    /// of at most `max_num_states` intermediate states. The caller owns the result. On
    /// error, `err_msg.*` receives why the grammar cannot be flattened (allocated; caller
    /// frees).
    pub fn from_regular_grammar(
        allocator: Allocator,
        grammar: *const Grammar,
        max_num_states: i32,
        err_msg: ?*?[]u8,
    ) error{Flatten}!FsmWithStartEnd {
        return regular_grammar_fsm_builder_mod.build(allocator, grammar, max_num_states, err_msg);
    }

    /// The characters that must be escaped in a JSON string: control characters, `"` and `\`.
    pub fn json_string_forbidden_chars() *const [256]bool {
        const S = struct {
            var forbidden: [256]bool = undefined;
            var initialized = false;
        };
        if (!S.initialized) {
            @setEvalBranchQuota(10000);
            for (0..256) |i| S.forbidden[i] = i <= 0x1F;
            S.forbidden['"'] = true;
            S.forbidden['\\'] = true;
            S.initialized = true;
        }
        return &S.forbidden;
    }

    /// Adds a chain of byte transitions from `start`, returning the end state.
    pub fn build_byte_string(fsm: *Fsm, bytes: []const i32, start: i32) Allocator.Error!i32 {
        var current = start;
        for (bytes) |byte_in| {
            const next = try fsm.add_state();
            const byte: i32 = @as(u8, @intCast(byte_in));
            try fsm.add_edge(current, next, byte, byte);
            current = next;
        }
        return current;
    }

    /// Adds the transitions of a (possibly negated) character class payload
    /// `[is_negative, lower0, upper0, ...]` from `start` to `end`.
    pub fn add_character_class_transitions(fsm: *Fsm, data: []const i32, start: i32, end: i32) void {
        var i: usize = 1;
        const positive = data[0] == 0;
        if (positive) {
            while (i + 1 < data.len) : (i += 2) {
                add_codepoint_range(fsm, start, end, @intCast(@max(data[i], 0)), @intCast(@max(data[i + 1], 0)));
            }
            return;
        }
        // Complement codepoint ranges before encoding them, so negated classes reject
        // exactly the listed codepoints. Payloads are small (parsed from regexes), so a
        // fixed buffer avoids the allocator plumbing of the Rust `collect()`.
        var arena_buf: [1024][2]u32 = undefined;
        var count: usize = 0;
        while (i + 1 < data.len) : (i += 2) {
            arena_buf[count] = .{ @intCast(@max(data[i], 0)), @intCast(@max(data[i + 1], 0)) };
            count += 1;
        }
        const excluded_slice = arena_buf[0..count];
        std.mem.sort([2]u32, excluded_slice, {}, struct {
            fn less(_: void, a: [2]u32, b: [2]u32) bool {
                return a[0] < b[0];
            }
        }.less);
        var next: u32 = 0;
        for (excluded_slice) |range| {
            const low = range[0];
            const high = range[1];
            if (low > next) {
                add_codepoint_range(fsm, start, end, next, @min(low - 1, MAX_CODEPOINT));
            }
            if (high >= MAX_CODEPOINT) return;
            next = @max(next, high + 1);
        }
        if (next <= MAX_CODEPOINT) {
            add_codepoint_range(fsm, start, end, next, MAX_CODEPOINT);
        }
    }

    /// Adds a token tag-dispatch from `start`, returning its end states (an owned list).
    pub fn build_token_tag_dispatch(fsm: *Fsm, ttd: *const TokenTagDispatch, start: i32) Allocator.Error!std.ArrayList(i32) {
        const gpa = fsm.allocator;
        var end_states: std.ArrayList(i32) = .empty;
        errdefer end_states.deinit(gpa);
        var dispatch_states: std.ArrayList(i32) = .empty;
        defer dispatch_states.deinit(gpa);
        try dispatch_states.ensureTotalCapacity(gpa, ttd.trigger_rule_pairs.items.len);
        for (ttd.trigger_rule_pairs.items) |_| {
            dispatch_states.appendAssumeCapacity(try fsm.add_state());
        }
        try end_states.append(gpa, start);
        const end_state = if (ttd.loop_after_dispatch)
            start
        else blk: {
            const state = try fsm.add_state();
            try end_states.append(gpa, state);
            break :blk state;
        };
        var excluded_token_ids: std.ArrayList(i32) = .empty;
        defer excluded_token_ids.deinit(gpa);
        for (ttd.trigger_rule_pairs.items) |pair| {
            try excluded_token_ids.append(gpa, pair.token_id);
        }
        try excluded_token_ids.appendSlice(gpa, ttd.excludes.items);
        std.mem.sort(i32, excluded_token_ids.items, {}, std.sort.asc(i32));
        {
            var write: usize = 0;
            for (excluded_token_ids.items, 0..) |v, read| {
                if (read == 0 or excluded_token_ids.items[write - 1] != v) {
                    excluded_token_ids.items[write] = v;
                    write += 1;
                }
            }
            excluded_token_ids.shrinkRetainingCapacity(write);
        }
        for (ttd.trigger_rule_pairs.items, dispatch_states.items) |pair, dispatch_state| {
            try fsm.add_token_edge(start, dispatch_state, &.{pair.token_id});
            try fsm.add_rule_edge(dispatch_state, end_state, pair.rule_id);
        }
        try fsm.add_exclude_token_edge(start, start, excluded_token_ids.items);
        return end_states;
    }
};

/// Adds every canonically UTF-8 encoded codepoint in `[low, high]` from `from` to `to`,
/// split at the UTF-8 width boundaries so no overlong encodings are admitted.
fn add_codepoint_range(fsm: *Fsm, from: i32, to: i32, low_in: u32, high: u32) void {
    var low = low_in;
    for ([_]u32{ 0x7F, 0x7FF, 0xFFFF, MAX_CODEPOINT }) |width_end| {
        if (low <= high and low <= width_end) {
            const end = @min(high, width_end);
            add_packed_utf8_range_edges(fsm, from, to, codepoint_to_packed_utf8(low), codepoint_to_packed_utf8(end)) catch unreachable;
            low = end + 1;
        }
    }
}
