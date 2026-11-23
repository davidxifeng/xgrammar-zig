//! Stateful matcher to match tokens to a BNF grammar (`grammar_matcher.rs`).

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;

const budget_mod = @import("budget_body_match_progress.zig");
const BudgetBodyMatchProgress = budget_mod.BudgetBodyMatchProgress;
const capture_span_mod = @import("capture_span_event.zig");
const CaptureSpanEvent = capture_span_mod.CaptureSpanEvent;
const error_mod = @import("error.zig");
const MatcherError = error_mod.MatcherError;
const MatcherErrorInfo = error_mod.MatcherErrorInfo;
const token_bitmask_mod = @import("token_bitmask.zig");
const TokenBitmask = token_bitmask_mod.TokenBitmask;
const bitmask_row_range = token_bitmask_mod.bitmask_row_range;
const get_bitmask_size = token_bitmask_mod.get_bitmask_size;

const compiler = @import("../compiler/mod.zig");
const AdaptiveTokenMask = compiler.AdaptiveTokenMask;
const AdaptiveTokenMaskCache = compiler.AdaptiveTokenMaskCache;
const AdaptiveTokenMaskStoreType = compiler.AdaptiveTokenMaskStoreType;
const CompiledGrammar = compiler.CompiledGrammar;
const fsm_mod = @import("../fsm/mod.zig");
const CompactFsmWithStartEnd = fsm_mod.CompactFsmWithStartEnd;
const StateSet = fsm_mod.fsm.StateSet;
const grammar_mod = @import("../grammar/mod.zig");
const parser_mod = @import("../parser/mod.zig");
const CaptureEvent = parser_mod.CaptureEvent;
const EarleyError = parser_mod.earley_parser.EarleyError;
const EarleyParser = parser_mod.EarleyParser;
const ParserRow = parser_mod.ParserRow;
const ParserState = parser_mod.ParserState;
const support = @import("../support/mod.zig");
const common_prefix_len = support.common_prefix_len;
const escape_bytes = support.escape_bytes;
const intset_intersection = support.intset_intersection;
const intset_union = support.intset_union;
const tokenizer_mod = @import("../tokenizer/mod.zig");
const TokenizerInfo = tokenizer_mod.tokenizer_info.TokenizerInfo;

/// One captured span returned by `GrammarMatcher.get_captures`.
pub const Capture = struct {
    name: []u8,
    bytes: []u8,
};

pub fn free_captures(allocator: Allocator, captures: []Capture) void {
    for (captures) |c| {
        allocator.free(c.name);
        allocator.free(c.bytes);
    }
    allocator.free(captures);
}

fn warn(message: []const u8) void {
    std.debug.print("{s}\n", .{message});
}

fn unwrap_earley_bool(res: EarleyError!bool) Allocator.Error!bool {
    return res catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}

fn unwrap_earley_void(res: EarleyError!void) Allocator.Error!void {
    return res catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}

fn occurrence_key(rule_id: i32, start_pos: i32) i64 {
    return (@as(i64, rule_id) << 32) | @as(i64, @as(u32, @bitCast(start_pos)));
}

fn get_bit(row_words: []const i32, token_id: i32) bool {
    const w = row_words[@intCast(@divTrunc(token_id, 32))];
    const bit: u5 = @intCast(@rem(token_id, 32));
    return ((@as(u32, @bitCast(w)) >> bit) & 1) != 0;
}

fn set_bit(row_words: []i32, token_id: i32, value: bool) void {
    const word_idx: usize = @intCast(@divTrunc(token_id, 32));
    const bit: u5 = @intCast(@rem(token_id, 32));
    const mask: i32 = @bitCast(@as(u32, 1) << bit);
    if (value) {
        row_words[word_idx] |= mask;
    } else {
        row_words[word_idx] &= ~mask;
    }
}

fn row_has_any_token(row_words: []const i32, vocab_size: i32) bool {
    const full_words: usize = @intCast(@divTrunc(vocab_size, 32));
    for (row_words[0..full_words]) |w| {
        if (w != 0) return true;
    }
    const rem: u5 = @intCast(@rem(vocab_size, 32));
    if (rem != 0 and full_words < row_words.len) {
        const last_mask: u32 = (@as(u32, 1) << rem) - 1;
        if ((@as(u32, @bitCast(row_words[full_words])) & last_mask) != 0) return true;
    }
    return false;
}

fn row_all_true(row_words: []const i32, vocab_size: i32) bool {
    const full_words: usize = @intCast(@divTrunc(vocab_size, 32));
    for (row_words[0..full_words]) |w| {
        if (w != -1) return false;
    }
    const rem: u5 = @intCast(@rem(vocab_size, 32));
    if (rem != 0 and full_words < row_words.len) {
        const last_mask: u32 = (@as(u32, 1) << rem) - 1;
        if ((@as(u32, @bitCast(row_words[full_words])) & last_mask) != last_mask) return false;
    }
    return true;
}

fn monotonic_ns() i128 {
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos, .linux, .freebsd, .netbsd, .openbsd, .dragonfly => {
            var ts: std.c.timespec = undefined;
            if (std.c.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts) == 0) {
                return @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
            }
            return 0;
        },
        else => return 0,
    }
}

fn sort_and_dedup_i32(list: *std.ArrayList(i32)) void {
    if (list.items.len <= 1) return;
    std.mem.sortUnstable(i32, list.items, {}, std.sort.asc(i32));
    var write: usize = 0;
    for (list.items, 0..) |v, read| {
        if (read == 0 or v != list.items[read - 1]) {
            list.items[write] = v;
            write += 1;
        }
    }
    list.items.len = write;
}

fn binary_search_i32(slice: []const i32, needle: i32) bool {
    var lo: usize = 0;
    var hi: usize = slice.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (slice[mid] < needle) {
            lo = mid + 1;
        } else if (slice[mid] > needle) {
            hi = mid;
        } else {
            return true;
        }
    }
    return false;
}

/// A stateful matcher to match tokens to the specified BNF grammar.
pub const GrammarMatcher = struct {
    allocator: Allocator,
    compiled_grammar: CompiledGrammar,
    parser: *EarleyParser,
    stop_token_ids: []i32,
    terminate_without_stop_token: bool,
    default_temperature: ?f32,
    has_warned_temperature_conflict: std.atomic.Value(bool),
    /// Number of parser rows created by each accepted string/token, for rollback.
    token_length_history: std.ArrayList(i32),
    budget_enforce_pending: bool,
    budget_force_close_pending: bool,
    budget_exceeded_warned: bool,
    char_budget_exceeded_warned: bool,
    char_budget_relaxed: bool,
    record_char_budget_relaxation: bool,
    has_budget_marker_rules: bool,
    has_token_edges: bool,
    budget_body_match_cache: std.AutoHashMapUnmanaged(i64, BudgetBodyMatchProgress),
    accepted_bytes: std.ArrayList(u8),
    row_byte_end: std.ArrayList(i64),
    temporary_input_bytes: std.ArrayList(u8),
    temporary_input_start_row: i32,
    tmp_rejected_indices: std.ArrayList(i32),
    tmp_rejected_indices_delta: std.ArrayList(i32),

    /// Constructs a matcher from a `CompiledGrammar`, terminating on the tokenizer's stop tokens.
    pub fn from_compiled_grammar(
        allocator: Allocator,
        compiled: *const CompiledGrammar,
        terminate_without_stop_token: bool,
    ) Allocator.Error!GrammarMatcher {
        return with_options(allocator, compiled, null, terminate_without_stop_token, null, null) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };
    }

    pub const InitOptions = struct {
        override_stop_tokens: ?[]const i32 = null,
        terminate_without_stop_token: bool = false,
        default_temperature: ?f32 = null,
        diag: ?*MatcherErrorInfo = null,
    };

    /// Idiomatic Zig 0.17 constructor with defaulted `InitOptions`.
    pub fn init(
        allocator: Allocator,
        compiled: *const CompiledGrammar,
        options: InitOptions,
    ) MatcherError!GrammarMatcher {
        return with_options(
            allocator,
            compiled,
            options.override_stop_tokens,
            options.terminate_without_stop_token,
            options.default_temperature,
            options.diag,
        );
    }

    /// Constructs a matcher with an optional stop-token override and a default sampling
    /// temperature used when no active rule specifies one.
    pub fn with_options(
        allocator: Allocator,
        compiled: *const CompiledGrammar,
        override_stop_tokens: ?[]const i32,
        terminate_without_stop_token: bool,
        default_temperature: ?f32,
        diag: ?*MatcherErrorInfo,
    ) MatcherError!GrammarMatcher {
        const tok = compiled.tokenizer_info();
        const vocab_size = tok.vocab_size;
        if (override_stop_tokens) |ids| {
            if (ids.len == 0) {
                if (diag) |d| d.* = .EmptyOverrideStopTokens;
                return error.EmptyOverrideStopTokens;
            }
            for (ids) |token_id| {
                if (token_id < 0 or token_id >= vocab_size) {
                    if (diag) |d| d.* = .{ .StopTokenOutOfRange = .{
                        .token_id = token_id,
                        .vocab_size = vocab_size,
                    } };
                    return error.StopTokenOutOfRange;
                }
            }
        }
        if (default_temperature) |temp| {
            if (!std.math.isFinite(temp) or temp < 0.0) {
                if (diag) |d| d.* = .InvalidDefaultTemperature;
                return error.InvalidDefaultTemperature;
            }
        }

        var compiled_ref = compiled.clone();
        errdefer compiled_ref.deinit();

        const g = compiled_ref.grammar();
        const parser = EarleyParser.new(allocator, g, null) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };
        errdefer parser.deinit();

        const has_budget_marker_rules = (parser.has_budget_rules or parser.has_char_budget_rules) and blk: {
            var rule_id: i32 = 0;
            while (rule_id < g.num_rules()) : (rule_id += 1) {
                const rule = g.rule(rule_id);
                if ((rule.max_tokens >= 0 or rule.max_chars >= 0)) {
                    if (g.suffix_stop_info(rule_id)) |info| {
                        if (info.body_rule_id >= 0) break :blk true;
                    }
                }
            }
            break :blk false;
        };

        const has_token_edges = parser.has_char_budget_rules and blk: {
            const fsm = g.complete_fsm;
            var s: i32 = 0;
            while (s < fsm.num_states()) : (s += 1) {
                for (fsm.state_edges(s)) |edge| {
                    if (edge.is_token() or edge.is_exclude_token()) break :blk true;
                }
            }
            break :blk false;
        };

        const stop_ids = try allocator.dupe(
            i32,
            override_stop_tokens orelse tok.stop_token_ids,
        );
        errdefer allocator.free(stop_ids);

        var row_byte_end: std.ArrayList(i64) = .empty;
        errdefer row_byte_end.deinit(allocator);
        try row_byte_end.append(allocator, 0);

        return .{
            .allocator = allocator,
            .compiled_grammar = compiled_ref,
            .parser = parser,
            .stop_token_ids = stop_ids,
            .terminate_without_stop_token = terminate_without_stop_token,
            .default_temperature = default_temperature,
            .has_warned_temperature_conflict = std.atomic.Value(bool).init(false),
            .token_length_history = .empty,
            .budget_enforce_pending = false,
            .budget_force_close_pending = false,
            .budget_exceeded_warned = false,
            .char_budget_exceeded_warned = false,
            .char_budget_relaxed = false,
            .record_char_budget_relaxation = false,
            .has_budget_marker_rules = has_budget_marker_rules,
            .has_token_edges = has_token_edges,
            .budget_body_match_cache = .empty,
            .accepted_bytes = .empty,
            .row_byte_end = row_byte_end,
            .temporary_input_bytes = .empty,
            .temporary_input_start_row = -1,
            .tmp_rejected_indices = .empty,
            .tmp_rejected_indices_delta = .empty,
        };
    }

    pub fn deinit(self: *GrammarMatcher) void {
        const a = self.allocator;
        self.clear_budget_body_match_cache();
        self.budget_body_match_cache.deinit(a);
        self.accepted_bytes.deinit(a);
        self.row_byte_end.deinit(a);
        self.temporary_input_bytes.deinit(a);
        self.tmp_rejected_indices.deinit(a);
        self.tmp_rejected_indices_delta.deinit(a);
        self.token_length_history.deinit(a);
        a.free(self.stop_token_ids);
        self.parser.deinit();
        self.compiled_grammar.deinit();
    }

    fn clear_budget_body_match_cache(self: *GrammarMatcher) void {
        var it = self.budget_body_match_cache.valueIterator();
        while (it.next()) |progress| {
            progress.deinit(self.allocator);
        }
        self.budget_body_match_cache.clearRetainingCapacity();
    }

    pub fn clone(self: *const GrammarMatcher, allocator: Allocator) Allocator.Error!GrammarMatcher {
        var compiled_ref = self.compiled_grammar.clone();
        errdefer compiled_ref.deinit();

        const parser_copy = self.parser.clone(allocator) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };
        errdefer parser_copy.deinit();

        const stop_ids = try allocator.dupe(i32, self.stop_token_ids);
        errdefer allocator.free(stop_ids);

        var token_len_hist: std.ArrayList(i32) = .empty;
        errdefer token_len_hist.deinit(allocator);
        try token_len_hist.appendSlice(allocator, self.token_length_history.items);

        var budget_cache: std.AutoHashMapUnmanaged(i64, BudgetBodyMatchProgress) = .empty;
        errdefer {
            var it = budget_cache.valueIterator();
            while (it.next()) |p| p.deinit(allocator);
            budget_cache.deinit(allocator);
        }
        try budget_cache.ensureTotalCapacity(allocator, self.budget_body_match_cache.count());
        var bc_it = self.budget_body_match_cache.iterator();
        while (bc_it.next()) |entry| {
            budget_cache.putAssumeCapacity(entry.key_ptr.*, try entry.value_ptr.clone(allocator));
        }

        var accepted_copy: std.ArrayList(u8) = .empty;
        errdefer accepted_copy.deinit(allocator);
        try accepted_copy.appendSlice(allocator, self.accepted_bytes.items);

        var row_end_copy: std.ArrayList(i64) = .empty;
        errdefer row_end_copy.deinit(allocator);
        try row_end_copy.appendSlice(allocator, self.row_byte_end.items);

        var temp_copy: std.ArrayList(u8) = .empty;
        errdefer temp_copy.deinit(allocator);
        try temp_copy.appendSlice(allocator, self.temporary_input_bytes.items);

        var tmp_rej: std.ArrayList(i32) = .empty;
        errdefer tmp_rej.deinit(allocator);
        try tmp_rej.appendSlice(allocator, self.tmp_rejected_indices.items);

        var tmp_delta: std.ArrayList(i32) = .empty;
        errdefer tmp_delta.deinit(allocator);
        try tmp_delta.appendSlice(allocator, self.tmp_rejected_indices_delta.items);

        return .{
            .allocator = allocator,
            .compiled_grammar = compiled_ref,
            .parser = parser_copy,
            .stop_token_ids = stop_ids,
            .terminate_without_stop_token = self.terminate_without_stop_token,
            .default_temperature = self.default_temperature,
            .has_warned_temperature_conflict = std.atomic.Value(bool).init(self.has_warned_temperature_conflict.load(.monotonic)),
            .token_length_history = token_len_hist,
            .budget_enforce_pending = self.budget_enforce_pending,
            .budget_force_close_pending = self.budget_force_close_pending,
            .budget_exceeded_warned = self.budget_exceeded_warned,
            .char_budget_exceeded_warned = self.char_budget_exceeded_warned,
            .char_budget_relaxed = self.char_budget_relaxed,
            .record_char_budget_relaxation = self.record_char_budget_relaxation,
            .has_budget_marker_rules = self.has_budget_marker_rules,
            .has_token_edges = self.has_token_edges,
            .budget_body_match_cache = budget_cache,
            .accepted_bytes = accepted_copy,
            .row_byte_end = row_end_copy,
            .temporary_input_bytes = temp_copy,
            .temporary_input_start_row = self.temporary_input_start_row,
            .tmp_rejected_indices = tmp_rej,
            .tmp_rejected_indices_delta = tmp_delta,
        };
    }

    /// Forks the matcher using its own allocator.
    pub fn fork(self: *const GrammarMatcher) Allocator.Error!GrammarMatcher {
        return self.clone(self.allocator);
    }

    pub fn tokenizer_info(self: *const GrammarMatcher) *const TokenizerInfo {
        return self.compiled_grammar.tokenizer_info();
    }

    pub fn get_stop_token_ids(self: *const GrammarMatcher) []const i32 {
        return self.stop_token_ids;
    }

    pub fn get_parser(self: *const GrammarMatcher) *const EarleyParser {
        return self.parser;
    }

    pub fn max_rollback_tokens(_: *const GrammarMatcher) i32 {
        return -1;
    }

    // --- Idiomatic Zig 0.17 methods ---

    pub fn acceptToken(self: *GrammarMatcher, token_id: i32) Allocator.Error!bool {
        return self.accept_token(token_id);
    }

    pub fn acceptString(self: *GrammarMatcher, input: []const u8) Allocator.Error!bool {
        return self.accept_string(input);
    }

    pub fn acceptBytes(self: *GrammarMatcher, input: []const u8) Allocator.Error!bool {
        return self.accept_bytes(input);
    }

    pub fn fillBitmask(self: *GrammarMatcher, bitmask: *TokenBitmask) MatcherError!bool {
        return self.fillBitmaskRow(bitmask, 0);
    }

    pub fn fillBitmaskRow(self: *GrammarMatcher, bitmask: *TokenBitmask, row: usize) MatcherError!bool {
        const s = bitmask.shape();
        return self.fill_next_token_bitmask(bitmask.words, &s, @intCast(row), null);
    }

    pub fn findJumpForwardString(self: *GrammarMatcher, allocator: Allocator) MatcherError![]u8 {
        return self.find_jump_forward_string(allocator, null);
    }

    pub fn isCompleted(self: *const GrammarMatcher) bool {
        return self.is_completed();
    }

    pub fn isTerminated(self: *const GrammarMatcher) bool {
        return self.is_terminated();
    }

    pub fn stopTokenIds(self: *const GrammarMatcher) []const i32 {
        return self.get_stop_token_ids();
    }

    pub fn getCaptures(self: *const GrammarMatcher, allocator: Allocator, deduplicate: bool) Allocator.Error![]Capture {
        return self.get_captures(allocator, deduplicate);
    }

    /// Human-readable dump of the latest parser states (caller owns).
    pub fn debug_print_internal_state(self: *const GrammarMatcher, allocator: Allocator) Allocator.Error![]u8 {
        return self.parser.print_states(allocator);
    }

    pub fn is_completed(self: *const GrammarMatcher) bool {
        return self.parser.is_root_completed();
    }

    pub fn is_stop_token_accepted(self: *const GrammarMatcher) bool {
        return self.parser.stop_token_is_accepted;
    }

    pub fn is_terminated(self: *const GrammarMatcher) bool {
        if (self.terminate_without_stop_token) {
            return self.parser.is_root_completed();
        }
        return self.is_stop_token_accepted();
    }

    pub fn accept_stop_token(self: *GrammarMatcher) Allocator.Error!bool {
        if (self.terminate_without_stop_token or !self.parser.is_root_completed()) {
            return false;
        }
        std.debug.assert(!self.parser.stop_token_is_accepted);
        try self.token_length_history.append(self.allocator, 0);
        self.parser.stop_token_is_accepted = true;
        return true;
    }

    pub fn reset(self: *GrammarMatcher) Allocator.Error!void {
        self.token_length_history.clearRetainingCapacity();
        self.parser.current_token_index = -1;
        self.budget_enforce_pending = false;
        self.budget_force_close_pending = false;
        self.budget_exceeded_warned = false;
        self.char_budget_exceeded_warned = false;
        self.char_budget_relaxed = false;
        self.record_char_budget_relaxation = false;
        self.clear_budget_body_match_cache();
        self.temporary_input_start_row = -1;
        self.temporary_input_bytes.clearRetainingCapacity();
        self.accepted_bytes.clearRetainingCapacity();
        self.row_byte_end.clearRetainingCapacity();
        try self.row_byte_end.append(self.allocator, 0);
        try unwrap_earley_void(self.parser.reset());
    }

    fn should_track_accepted_bytes(self: *const GrammarMatcher) bool {
        return self.parser.capture_tracking or self.has_budget_marker_rules;
    }

    fn append_per_byte_rows(self: *GrammarMatcher, bytes: []const u8) Allocator.Error!void {
        for (bytes) |byte| {
            try self.accepted_bytes.append(self.allocator, byte);
            try self.row_byte_end.append(self.allocator, @intCast(self.accepted_bytes.items.len));
        }
    }

    fn append_atomic_row(self: *GrammarMatcher, bytes: []const u8) Allocator.Error!void {
        try self.accepted_bytes.appendSlice(self.allocator, bytes);
        try self.row_byte_end.append(self.allocator, @intCast(self.accepted_bytes.items.len));
    }

    fn finish_character_budget_accept(self: *GrammarMatcher) void {
        if (self.char_budget_relaxed and !self.char_budget_exceeded_warned) {
            self.char_budget_exceeded_warned = true;
            warn("The character budget (max_chars) of a rule was exceeded: the rule could not end at the position where its budget ran out, so the budget is relaxed until the rule can end. This warning is reported once per matcher.");
        }
        self.char_budget_relaxed = false;
    }

    fn finish_accept(self: *GrammarMatcher, consumed_past_deadline: bool) bool {
        self.budget_enforce_pending = false;
        self.budget_force_close_pending = false;
        if (consumed_past_deadline and !self.budget_exceeded_warned) {
            self.budget_exceeded_warned = true;
            warn("The token budget (max_tokens) of a rule was exceeded: the rule could not end at the position where its budget ran out, so the budget is relaxed until the rule can end. This warning is reported once per matcher.");
        }
        self.finish_character_budget_accept();
        return true;
    }

    fn can_force_complete_without_marker(
        self: *GrammarMatcher,
        state: ParserState,
        use_char_budget: bool,
    ) Allocator.Error!bool {
        const expired = if (use_char_budget)
            self.parser.is_char_expired_state(state)
        else
            self.parser.is_expired_state(state);
        if (!expired or state.rule_id < 0) return false;
        const grammar = self.parser.grammar;
        const rule = grammar.rule(state.rule_id);
        if (if (use_char_budget) rule.max_chars < 0 else rule.max_tokens < 0) {
            return false;
        }
        const info = grammar.suffix_stop_info(state.rule_id) orelse return false;
        if (info.body_rule_id < 0) return false;
        std.debug.assert(self.should_track_accepted_bytes());

        const start_row = if (state.rule_start_pos == ParserState.NO_PREV_INPUT_POS)
            @as(i32, 0)
        else
            state.rule_start_pos;
        const begin: i64 = if (@as(usize, @intCast(start_row)) < self.row_byte_end.items.len)
            self.row_byte_end.items[@intCast(start_row)]
        else blk: {
            std.debug.assert(self.temporary_input_start_row >= 0 and start_row >= self.temporary_input_start_row);
            break :blk @as(i64, @intCast(self.accepted_bytes.items.len)) + @as(i64, start_row - self.temporary_input_start_row);
        };
        const end: i64 = @intCast(self.accepted_bytes.items.len + self.temporary_input_bytes.items.len);
        const body_fsm = grammar.per_rule_fsm(info.body_rule_id).?.get_fsm();
        const body_compact = body_fsm.get_fsm();

        const key = occurrence_key(state.rule_id, state.rule_start_pos);
        const accepted_len: i64 = @intCast(self.accepted_bytes.items.len);

        const gop = try self.budget_body_match_cache.getOrPut(self.allocator, key);
        if (!gop.found_existing) {
            var states = try fsm_mod.fsm.state_set_from(self.allocator, &.{body_fsm.get_start()});
            errdefer states.deinit();
            try body_compact.epsilon_closure(&states);
            gop.value_ptr.* = .{
                .begin_byte = begin,
                .end_byte = begin,
                .states = states,
                .temporary_input_snapshot = .empty,
            };
        } else {
            const progress = gop.value_ptr;
            if (progress.begin_byte != begin or
                progress.end_byte > end or
                (progress.end_byte > accepted_len and !std.mem.eql(u8, progress.temporary_input_snapshot.items, self.temporary_input_bytes.items)))
            {
                var states = try fsm_mod.fsm.state_set_from(self.allocator, &.{body_fsm.get_start()});
                errdefer states.deinit();
                try body_compact.epsilon_closure(&states);
                progress.deinit(self.allocator);
                progress.* = .{
                    .begin_byte = begin,
                    .end_byte = begin,
                    .states = states,
                    .temporary_input_snapshot = .empty,
                };
            }
        }

        const progress = gop.value_ptr;
        var next_states = StateSet.init(self.allocator);
        defer next_states.deinit();
        var offset = progress.end_byte;
        while (offset < end and progress.states.count() != 0) : (offset += 1) {
            const byte = if (offset < accepted_len)
                self.accepted_bytes.items[@intCast(offset)]
            else
                self.temporary_input_bytes.items[@intCast(offset - accepted_len)];
            try body_compact.advance_char(&progress.states, byte, &next_states);
            std.mem.swap(StateSet, &progress.states, &next_states);
        }
        progress.end_byte = end;
        progress.temporary_input_snapshot.clearRetainingCapacity();
        if (end > accepted_len) {
            try progress.temporary_input_snapshot.appendSlice(self.allocator, self.temporary_input_bytes.items);
        }

        var it = progress.states.keyIterator();
        while (it.next()) |state_id| {
            if (body_fsm.is_end_state(state_id.*)) return true;
        }
        return false;
    }

    fn apply_budget_enforcement_impl(self: *GrammarMatcher, use_char_budget: bool) Allocator.Error!bool {
        std.debug.assert(self.parser.tmp_process_state_queue.len == 0);
        var previous_row = try self.parser.latest_row(self.allocator);
        defer previous_row.deinit(self.allocator);

        self.parser.tmp_states_visited_in_queue.clear();
        self.parser.tmp_states_to_be_added.clearRetainingCapacity();
        self.parser.tmp_completed_lazy_occurrences.clearRetainingCapacity();
        self.parser.tmp_accept_stop_token = self.parser.is_root_completed();

        var force_completed_states: std.ArrayList(ParserState) = .empty;
        defer force_completed_states.deinit(self.allocator);
        var force_completed_occurrences = std.AutoHashMap(i64, void).init(self.allocator);
        defer force_completed_occurrences.deinit();

        for (previous_row.states.items) |state| {
            const expired = if (use_char_budget)
                self.parser.is_char_expired_state(state)
            else
                self.parser.is_expired_state(state);
            if (!expired) {
                try self.parser.enqueue_without_processing(state);
                continue;
            }
            if (!try self.can_force_complete_without_marker(state, use_char_budget)) {
                continue;
            }
            const occ_gop = try force_completed_occurrences.getOrPut(occurrence_key(state.rule_id, state.rule_start_pos));
            if (!occ_gop.found_existing) {
                try force_completed_states.append(self.allocator, state);
            }
        }
        for (force_completed_states.items) |state| {
            try unwrap_earley_void(self.parser.complete(state, false));
        }
        try unwrap_earley_void(self.parser.process_queue());
        if (self.parser.tmp_completed_lazy_occurrences.items.len != 0) {
            self.parser.remove_committed_lazy_states();
        }

        var any_expired = false;
        var any_alive = false;
        for (self.parser.tmp_states_to_be_added.items) |state| {
            const expired = if (use_char_budget)
                self.parser.is_char_expired_state(state)
            else
                self.parser.is_expired_state(state);
            if (expired) any_expired = true else any_alive = true;
        }
        if (any_expired and (any_alive or self.parser.tmp_accept_stop_token)) {
            var write: usize = 0;
            for (self.parser.tmp_states_to_be_added.items) |state| {
                const expired = if (use_char_budget)
                    self.parser.is_char_expired_state(state)
                else
                    self.parser.is_expired_state(state);
                if (!expired) {
                    self.parser.tmp_states_to_be_added.items[write] = state;
                    write += 1;
                }
            }
            self.parser.tmp_states_to_be_added.shrinkRetainingCapacity(write);
        }

        const viable = self.parser.tmp_accept_stop_token or self.parser.tmp_states_to_be_added.items.len != 0;
        if (!viable) {
            if (use_char_budget) {
                var restore_row = try previous_row.clone(self.allocator);
                defer restore_row.deinit(self.allocator);
                restore_row.completed = self.parser.is_root_completed();
                try self.parser.replace_latest_row(restore_row);
            }
            return false;
        }
        var latest = try self.parser.latest_row(self.allocator);
        defer latest.deinit(self.allocator);
        latest.states.clearRetainingCapacity();
        try latest.states.appendSlice(self.allocator, self.parser.tmp_states_to_be_added.items);
        self.parser.tmp_states_to_be_added.clearRetainingCapacity();
        latest.completed = self.parser.tmp_accept_stop_token;
        try self.parser.replace_latest_row(latest);
        return true;
    }

    fn apply_budget_enforcement(self: *GrammarMatcher) Allocator.Error!bool {
        return self.apply_budget_enforcement_impl(false);
    }

    fn apply_character_budget_enforcement_to_fixed_point(self: *GrammarMatcher) Allocator.Error!bool {
        var applied_any = false;
        var iter: i32 = 0;
        while (iter <= self.parser.grammar.num_rules()) : (iter += 1) {
            const has_expired = self.has_char_expired_state();
            if (!has_expired or !try self.apply_budget_enforcement_impl(true)) {
                return applied_any;
            }
            applied_any = true;
        }
        return applied_any;
    }

    fn has_char_expired_state(self: *const GrammarMatcher) bool {
        for (self.parser.scanable_state_history.back()) |state| {
            if (self.parser.is_char_expired_state(state)) return true;
        }
        return false;
    }

    fn advance_with_character_budget(self: *GrammarMatcher, byte: u8) Allocator.Error!bool {
        if (!self.parser.has_char_budget_rules or !EarleyParser.starts_utf8_codepoint(byte)) {
            return unwrap_earley_bool(self.parser.advance(byte));
        }
        if (!self.has_char_expired_state()) {
            return unwrap_earley_bool(self.parser.advance(byte));
        }
        var snapshot = try self.parser.latest_row(self.allocator);
        defer snapshot.deinit(self.allocator);
        const enforced = try self.apply_character_budget_enforcement_to_fixed_point();
        if (!enforced and self.record_char_budget_relaxation) {
            self.char_budget_relaxed = true;
        }
        const accepted = try unwrap_earley_bool(self.parser.advance(byte));
        if (!accepted and enforced) {
            try self.parser.replace_latest_row(snapshot);
        }
        return accepted;
    }

    fn advance_atomic_token_with_character_budget(
        self: *GrammarMatcher,
        token_id: i32,
        token_char_count: i32,
    ) Allocator.Error!bool {
        var has_expired_state = false;
        var crosses_budget = false;
        if (self.parser.has_char_budget_rules and token_char_count > 0) {
            const current_char_index = self.parser.current_char_index();
            for (self.parser.scanable_state_history.back()) |state| {
                has_expired_state = has_expired_state or self.parser.is_char_expired_state(state);
                crosses_budget = crosses_budget or
                    (state.char_budget_deadline >= 0 and current_char_index + token_char_count > state.char_budget_deadline);
            }
        }
        var snapshot: ?ParserRow = null;
        defer if (snapshot) |*s| s.deinit(self.allocator);
        var enforced = false;
        if (has_expired_state) {
            snapshot = try self.parser.latest_row(self.allocator);
            enforced = try self.apply_character_budget_enforcement_to_fixed_point();
            if (!enforced and self.record_char_budget_relaxation) {
                self.char_budget_relaxed = true;
            }
        }
        const accepted = try unwrap_earley_bool(self.parser.advance_atomic_token(token_id, token_char_count));
        if (!accepted and enforced) {
            try self.parser.replace_latest_row(snapshot.?);
        }
        if (accepted and crosses_budget and self.record_char_budget_relaxation) {
            self.char_budget_relaxed = true;
        }
        return accepted;
    }

    fn advance_byte(self: *GrammarMatcher, byte: u8) Allocator.Error!bool {
        if (self.parser.has_char_budget_rules) {
            return self.advance_with_character_budget(byte);
        }
        return unwrap_earley_bool(self.parser.advance(byte));
    }

    /// The sampling temperature of the current position, or `default_temperature` if none applies.
    pub fn temperature(self: *const GrammarMatcher) ?f32 {
        var syntax_temperature: ?f32 = null;
        var has_temperature_conflict = false;
        for (self.parser.scanable_state_history.back()) |state| {
            if (state.active_temperature_rule_id == -1) continue;
            const temp = self.parser.grammar.rule(state.active_temperature_rule_id).temperature.?;
            if (syntax_temperature) |current| {
                if (current != temp) has_temperature_conflict = true;
                if (temp > current) syntax_temperature = temp;
            } else {
                syntax_temperature = temp;
            }
        }
        if (has_temperature_conflict) {
            const self_mut = @constCast(self);
            if (self_mut.has_warned_temperature_conflict.cmpxchgStrong(false, true, .acq_rel, .monotonic) == null) {
                std.debug.print(
                    "Multiple active grammar paths specify different temperatures. Using the maximum temperature {d}.\n",
                    .{syntax_temperature orelse 0.0},
                );
            }
        }
        return syntax_temperature orelse self.default_temperature;
    }

    /// Accepts one token and updates the state of the matcher.
    pub fn accept_token(self: *GrammarMatcher, token_id: i32) Allocator.Error!bool {
        if (self.is_stop_token_accepted()) {
            std.debug.print(
                "The matcher has terminated after accepting the stop token, but is trying to accept new token with id {d}.\n",
                .{token_id},
            );
            return false;
        }
        const tok = self.tokenizer_info();
        const vocab_size = tok.vocab_size;
        if (token_id < 0 or token_id >= vocab_size) {
            std.debug.print("The token id {d} is out of range [0, {d}). Rejecting the token.\n", .{ token_id, vocab_size });
            return false;
        }
        const is_stop_token = std.mem.indexOfScalar(i32, self.stop_token_ids, token_id) != null;
        if (!is_stop_token and std.mem.indexOfScalar(i32, tok.special_token_ids, token_id) != null) {
            const tid_u: usize = @intCast(token_id);
            const decoded = if (tid_u < tok.decoded_vocab.len) tok.decoded_vocab[tid_u] else "<padding>";
            std.debug.print("GrammarMatcher cannot accept special token id {d}: {s}. Rejecting the token.\n", .{ token_id, decoded });
            return false;
        }

        self.parser.current_token_index = @intCast(self.token_length_history.items.len);
        self.char_budget_relaxed = false;
        self.record_char_budget_relaxation = false;
        const enforce_budget = self.budget_enforce_pending;
        const force_budget_close = self.budget_force_close_pending;
        if (force_budget_close) {
            var trial = try self.clone(self.allocator);
            defer trial.deinit();
            trial.parser.capture_recording = false;
            if (!try trial.apply_budget_enforcement()) {
                return false;
            }
            trial.budget_enforce_pending = false;
            trial.budget_force_close_pending = false;
            if (!try trial.accept_token(token_id)) {
                return false;
            }
        }

        self.parser.capture_recording = self.parser.capture_tracking;
        const accepted = try self.accept_token_definitive(token_id, is_stop_token, enforce_budget, force_budget_close);
        self.parser.capture_recording = false;
        self.parser.skip_expired_states = false;
        return accepted;
    }

    fn has_token_edge_in_latest_states(self: *const GrammarMatcher) bool {
        const g = self.parser.grammar;
        for (self.parser.latest_scanable_states()) |st| {
            const wse = g.per_rule_fsm(st.rule_id) orelse continue;
            for (wse.get_fsm().get_fsm().state_edges(st.element_id)) |edge| {
                if (edge.is_exclude_token() or edge.is_token()) return true;
            }
        }
        return false;
    }

    fn accept_token_definitive(
        self: *GrammarMatcher,
        token_id: i32,
        is_stop_token: bool,
        enforce_budget: bool,
        force_budget_close: bool,
    ) Allocator.Error!bool {
        if (force_budget_close) {
            if (!try self.apply_budget_enforcement()) {
                return false;
            }
            self.budget_enforce_pending = false;
            self.budget_force_close_pending = false;
        }
        self.parser.skip_expired_states = enforce_budget and !force_budget_close;

        const consumed_past_deadline = self.parser.has_budget_rules and !enforce_budget and blk: {
            for (self.parser.scanable_state_history.back()) |state| {
                if (self.parser.is_expired_state(state)) break :blk true;
            }
            break :blk false;
        };

        // #710: Only short-circuit as EOS termination when the root grammar can end here
        // (or terminate_without_stop_token is set). Otherwise fall through so stop tokens
        // that complete or advance the grammar itself are matched normally.
        if (is_stop_token and (self.parser.is_root_completed() or self.terminate_without_stop_token)) {
            const ok = try self.accept_stop_token();
            return ok and self.finish_accept(consumed_past_deadline);
        }

        const token = self.tokenizer_info().decoded_vocab[@intCast(token_id)];
        const has_char_budget_rules = self.parser.has_char_budget_rules;
        var token_char_count: i32 = 0;
        if (has_char_budget_rules) {
            for (token) |byte| {
                if (EarleyParser.starts_utf8_codepoint(byte)) token_char_count += 1;
            }
        }
        const size_before_token: i32 = @intCast(self.parser.rule_id_to_completable_states.len());
        var row_before_token: ?ParserRow = if (has_char_budget_rules) try self.parser.latest_row(self.allocator) else null;
        defer if (row_before_token) |*r| r.deinit(self.allocator);

        // Phase 1: atomic token path.
        const atomic_success = if (has_char_budget_rules)
            try self.advance_atomic_token_with_character_budget(token_id, token_char_count)
        else
            try unwrap_earley_bool(self.parser.advance_atomic_token(token_id, 0));

        var atomic_row: ?ParserRow = null;
        defer if (atomic_row) |*r| r.deinit(self.allocator);
        if (atomic_success) {
            atomic_row = try self.parser.latest_row(self.allocator);
            self.parser.pop_last_states(1);
        }
        if (row_before_token) |snap| {
            try self.parser.replace_latest_row(snap);
        }

        // Phase 2: byte-by-byte path.
        self.record_char_budget_relaxation = true;
        const track_temporary_input = has_char_budget_rules and self.has_budget_marker_rules;
        if (track_temporary_input) {
            self.temporary_input_start_row = @as(i32, @intCast(self.parser.scanable_state_history.len())) - 1;
            self.temporary_input_bytes.clearRetainingCapacity();
        }
        var pos: i32 = 0;
        var byte_path_success = true;
        var mid_token_atomic = false;
        for (token) |byte| {
            if (!try self.advance_byte(byte)) {
                // #942: Token began matching a literal and entered a token-level free-text region.
                if (pos > 0 and self.has_token_edge_in_latest_states()) {
                    const saved_relax = self.record_char_budget_relaxation;
                    self.record_char_budget_relaxation = false;
                    const mid_ok = if (has_char_budget_rules)
                        try self.advance_atomic_token_with_character_budget(token_id, token_char_count)
                    else
                        try unwrap_earley_bool(self.parser.advance_atomic_token(token_id, 0));
                    self.record_char_budget_relaxation = saved_relax;
                    if (mid_ok) {
                        pos += 1;
                        mid_token_atomic = true;
                        break;
                    }
                }
                byte_path_success = false;
                break;
            }
            if (track_temporary_input) {
                try self.temporary_input_bytes.append(self.allocator, byte);
            }
            pos += 1;
        }
        if (track_temporary_input) {
            self.temporary_input_start_row = -1;
            self.temporary_input_bytes.clearRetainingCapacity();
        }

        // Phase 3: combine results.
        if (!byte_path_success and !atomic_success) {
            self.parser.pop_last_states(pos);
            if (row_before_token) |snap| {
                try self.parser.replace_latest_row(snap);
            }
            self.record_char_budget_relaxation = false;
            self.char_budget_relaxed = false;
            return false;
        }
        if (atomic_success and !byte_path_success) {
            self.parser.pop_last_states(pos);
            if (row_before_token) |snap| {
                try self.parser.replace_latest_row(snap);
            }
            self.char_budget_relaxed = false;
            const accepted = if (has_char_budget_rules)
                try self.advance_atomic_token_with_character_budget(token_id, token_char_count)
            else
                try unwrap_earley_bool(self.parser.advance_atomic_token(token_id, 0));
            std.debug.assert(accepted);
            try self.token_length_history.append(self.allocator, 1);
            if (self.should_track_accepted_bytes()) {
                try self.append_atomic_row(token);
            }
        } else if (byte_path_success and !atomic_success) {
            try self.token_length_history.append(self.allocator, pos);
            if (self.should_track_accepted_bytes()) {
                if (mid_token_atomic) {
                    const split: usize = @intCast(pos - 1);
                    try self.append_per_byte_rows(token[0..split]);
                    try self.append_atomic_row(token[split..]);
                } else {
                    try self.append_per_byte_rows(token);
                }
            }
        } else {
            const arow = &atomic_row.?;
            if (token.len == 0) {
                const char_index = self.parser.current_char_index();
                const entered = self.parser.has_entered_char_budget();
                _ = try self.parser.scanable_state_history.push_row(arow.states.items);
                _ = try self.parser.rule_id_to_completable_states.push_row(arow.completable_states.items);
                try self.parser.is_completed.append(self.allocator, arow.completed);
                try self.parser.push_capture_row(arow.capture_events.items);
                self.parser.push_char_count_row(char_index, entered);
                try self.token_length_history.append(self.allocator, 1);
                if (self.should_track_accepted_bytes()) {
                    try self.append_atomic_row(token);
                }
            } else {
                try self.merge_atomic_row_into_byte_path(size_before_token, arow);
                try self.token_length_history.append(self.allocator, pos);
                if (self.should_track_accepted_bytes()) {
                    if (mid_token_atomic) {
                        const split: usize = @intCast(pos - 1);
                        try self.append_per_byte_rows(token[0..split]);
                        try self.append_atomic_row(token[split..]);
                    } else {
                        try self.append_per_byte_rows(token);
                    }
                }
            }
        }

        if (has_char_budget_rules) {
            _ = try self.apply_character_budget_enforcement_to_fixed_point();
        }
        self.record_char_budget_relaxation = false;
        const ok = self.finish_accept(consumed_past_deadline);
        if (ok and is_stop_token and self.parser.is_root_completed() and !self.terminate_without_stop_token) {
            self.parser.stop_token_is_accepted = true;
        }
        return ok;
    }

    fn merge_atomic_row_into_byte_path(
        self: *GrammarMatcher,
        size_before_token: i32,
        atomic_row: *const ParserRow,
    ) Allocator.Error!void {
        const a = self.allocator;
        var merged: std.ArrayList(ParserState) = .empty;
        defer merged.deinit(a);
        try merged.appendSlice(a, self.parser.latest_scanable_states());
        for (atomic_row.states.items) |state| {
            var seen = false;
            for (merged.items) |m| {
                if (m.eql(state)) {
                    seen = true;
                    break;
                }
            }
            if (!seen) try merged.append(a, state);
        }

        var merged_completable: std.ArrayList(parser_mod.parser_row.CompletableState) = .empty;
        defer merged_completable.deinit(a);
        try merged_completable.appendSlice(a, self.parser.latest_completable_states());

        var merged_capture_row = try self.parser.copy_last_capture_row(a);
        defer {
            for (merged_capture_row.items) |*ev| ev.stop_capture_targets.deinit(a);
            merged_capture_row.deinit(a);
        }

        const byte_completed = self.parser.is_root_completed();
        const final_char_index = self.parser.current_char_index();
        const final_char_budget_entered = self.parser.has_entered_char_budget();
        self.parser.pop_last_states(1);

        for (atomic_row.completable_states.items) |pair| {
            var seen = false;
            for (merged_completable.items) |m| {
                if (m.referenced_rule_id == pair.referenced_rule_id and m.parent_state.eql(pair.parent_state)) {
                    seen = true;
                    break;
                }
            }
            if (!seen) try merged_completable.append(a, pair);
        }

        const new_row: i32 = @intCast(self.parser.rule_id_to_completable_states.len());
        for (atomic_row.capture_events.items) |src_event| {
            var event = try parser_mod.capture_event.clone(src_event, a);
            errdefer event.stop_capture_targets.deinit(a);
            if (event.start_pos == size_before_token) event.start_pos = new_row;
            if (event.occurrence_start_pos == size_before_token) event.occurrence_start_pos = new_row;
            for (event.stop_capture_targets.items) |*target| {
                if (target.start_pos == size_before_token) target.start_pos = new_row;
            }
            var found: ?*CaptureEvent = null;
            for (merged_capture_row.items) |*existing| {
                if (existing.rule_id == event.rule_id and
                    existing.start_pos == event.start_pos and
                    existing.occurrence_start_pos == event.occurrence_start_pos)
                {
                    found = existing;
                    break;
                }
            }
            if (found) |existing| {
                existing.hidden_suffix_bytes = @max(existing.hidden_suffix_bytes, event.hidden_suffix_bytes);
                existing.hidden_stop_bytes = @max(existing.hidden_stop_bytes, event.hidden_stop_bytes);
                for (event.stop_capture_targets.items) |target| {
                    var seen = false;
                    for (existing.stop_capture_targets.items) |t| {
                        if (t.rule_id == target.rule_id and t.start_pos == target.start_pos) {
                            seen = true;
                            break;
                        }
                    }
                    if (!seen) try existing.stop_capture_targets.append(a, target);
                }
                event.stop_capture_targets.deinit(a);
            } else {
                try merged_capture_row.append(a, event);
            }
        }

        _ = try self.parser.scanable_state_history.push_row(merged.items);
        _ = try self.parser.rule_id_to_completable_states.push_row(merged_completable.items);
        try self.parser.is_completed.append(a, byte_completed or atomic_row.completed);
        try self.parser.push_capture_row(merged_capture_row.items);
        self.parser.push_char_count_row(final_char_index, final_char_budget_entered);
    }

    pub fn accept_string(self: *GrammarMatcher, input: []const u8) Allocator.Error!bool {
        return self.accept_bytes(input);
    }

    pub fn accept_bytes(self: *GrammarMatcher, input: []const u8) Allocator.Error!bool {
        if (self.is_stop_token_accepted()) {
            const escaped = escape_bytes(self.allocator, input) catch input;
            defer if (escaped.ptr != input.ptr) self.allocator.free(escaped);
            std.debug.print(
                "The matcher has terminated after accepting the stop token, but is trying to accept new string \"{s}\".\n",
                .{escaped},
            );
            return false;
        }
        self.parser.current_token_index = @intCast(self.token_length_history.items.len);
        self.char_budget_relaxed = false;
        self.record_char_budget_relaxation = true;
        self.parser.capture_recording = self.parser.capture_tracking;
        const accepted = try self.accept_bytes_definitive(input);
        self.parser.capture_recording = false;
        return accepted;
    }

    fn accept_bytes_definitive(self: *GrammarMatcher, input: []const u8) Allocator.Error!bool {
        const has_char_budget_rules = self.parser.has_char_budget_rules;
        var row_before_input: ?ParserRow = if (has_char_budget_rules) try self.parser.latest_row(self.allocator) else null;
        defer if (row_before_input) |*r| r.deinit(self.allocator);
        const track_temporary_input = has_char_budget_rules and self.has_budget_marker_rules;
        if (track_temporary_input) {
            self.temporary_input_start_row = @as(i32, @intCast(self.parser.scanable_state_history.len())) - 1;
            self.temporary_input_bytes.clearRetainingCapacity();
        }
        for (input, 0..) |byte, accepted_cnt| {
            if (!try self.advance_byte(byte)) {
                self.parser.pop_last_states(@intCast(accepted_cnt));
                if (row_before_input) |snap| {
                    try self.parser.replace_latest_row(snap);
                }
                if (track_temporary_input) {
                    self.temporary_input_start_row = -1;
                    self.temporary_input_bytes.clearRetainingCapacity();
                }
                self.record_char_budget_relaxation = false;
                self.char_budget_relaxed = false;
                return false;
            }
            if (track_temporary_input) {
                try self.temporary_input_bytes.append(self.allocator, byte);
            }
        }
        try self.token_length_history.append(self.allocator, @intCast(input.len));
        if (self.should_track_accepted_bytes()) {
            try self.append_per_byte_rows(input);
        }
        if (has_char_budget_rules and input.len != 0) {
            _ = try self.apply_character_budget_enforcement_to_fixed_point();
        }
        if (track_temporary_input) {
            self.temporary_input_start_row = -1;
            self.temporary_input_bytes.clearRetainingCapacity();
        }
        self.record_char_budget_relaxation = false;
        self.finish_character_budget_accept();
        return true;
    }

    /// Fills row `index` of `bitmask` (a buffer of `shape`). Returns whether the bitmask
    /// needs to be applied (i.e. is not all-true).
    pub fn fill_next_token_bitmask(
        self: *GrammarMatcher,
        bitmask: []i32,
        shape: []const i64,
        index: i32,
        diag: ?*MatcherErrorInfo,
    ) MatcherError!bool {
        if (self.is_stop_token_accepted()) {
            if (diag) |d| d.* = .{ .Terminated = "find the next token mask" };
            return error.Terminated;
        }
        const vocab_size = self.tokenizer_info().vocab_size;
        const range = try bitmask_row_range(self.allocator, shape, vocab_size, index, diag);
        if (range.end > bitmask.len) {
            return error_mod.set_invalid_arg(diag, self.allocator, "The provided bitmask buffer is smaller than its shape");
        }
        const row_words = bitmask[range.start..range.end];
        self.parser.current_token_index = @intCast(self.token_length_history.items.len);

        if (self.parser.has_budget_rules) {
            var any_expired = false;
            var any_alive = false;
            var can_force_close_without_marker = false;
            for (self.parser.latest_scanable_states()) |state| {
                if (self.parser.is_expired_state(state)) {
                    any_expired = true;
                    if (!can_force_close_without_marker and self.has_budget_marker_rules) {
                        can_force_close_without_marker = try self.can_force_complete_without_marker(state, false);
                    }
                } else {
                    any_alive = true;
                }
            }
            if (can_force_close_without_marker) {
                var trial = try self.clone(self.allocator);
                defer trial.deinit();
                trial.parser.capture_recording = false;
                const applied = try trial.apply_budget_enforcement();
                if (applied) {
                    try trial.fill_bitmask_for_states(row_words, false);
                }
                if (applied and (trial.parser.is_root_completed() or row_has_any_token(row_words, vocab_size))) {
                    self.budget_enforce_pending = true;
                    self.budget_force_close_pending = true;
                    return !row_all_true(row_words, vocab_size);
                }
            }
            if (any_expired and (any_alive or self.parser.is_root_completed())) {
                try self.fill_bitmask_for_states(row_words, true);
                if (row_has_any_token(row_words, vocab_size) or self.parser.is_root_completed()) {
                    self.budget_enforce_pending = true;
                    self.budget_force_close_pending = false;
                    return !row_all_true(row_words, vocab_size);
                }
            }
            self.budget_enforce_pending = false;
            self.budget_force_close_pending = false;
        }
        try self.fill_bitmask_for_states(row_words, false);
        return !row_all_true(row_words, vocab_size);
    }

    fn fill_bitmask_for_char_budget_boundary(
        self: *GrammarMatcher,
        row_words: []i32,
        adaptive_token_mask: *const AdaptiveTokenMask,
        remaining_chars: i32,
    ) Allocator.Error!void {
        const a = self.allocator;
        const tok = self.tokenizer_info();
        const token_char_counts = tok.token_char_counts;
        const vocab = tok.sorted_decoded_vocab;

        var tokens_to_check: std.ArrayList(i32) = .empty;
        defer tokens_to_check.deinit(a);
        try tokens_to_check.appendSlice(a, adaptive_token_mask.uncertain_indices);

        switch (adaptive_token_mask.store_type) {
            .Accepted => {
                for (adaptive_token_mask.accepted_indices) |index| {
                    if (token_char_counts[@intCast(index)] <= remaining_chars) {
                        set_bit(row_words, vocab[@intCast(index)].id, true);
                    } else {
                        try tokens_to_check.append(a, index);
                    }
                }
            },
            .AcceptedBitset => {
                for (vocab, 0..) |entry, index| {
                    if (!adaptive_token_mask.accepted_bitset.get(@intCast(entry.id))) continue;
                    if (token_char_counts[index] <= remaining_chars) {
                        set_bit(row_words, entry.id, true);
                    } else {
                        try tokens_to_check.append(a, @intCast(index));
                    }
                }
            },
            .Rejected => {
                var blocked: std.ArrayList(i32) = .empty;
                defer blocked.deinit(a);
                try blocked.appendSlice(a, adaptive_token_mask.rejected_indices);
                try blocked.appendSlice(a, adaptive_token_mask.uncertain_indices);
                std.mem.sortUnstable(i32, blocked.items, {}, std.sort.asc(i32));
                for (vocab, 0..) |entry, idx_u| {
                    const index: i32 = @intCast(idx_u);
                    if (token_char_counts[idx_u] <= remaining_chars) {
                        if (!binary_search_i32(blocked.items, index)) {
                            set_bit(row_words, entry.id, true);
                        }
                    } else if (!binary_search_i32(adaptive_token_mask.rejected_indices, index)) {
                        try tokens_to_check.append(a, index);
                    }
                }
            },
        }
        sort_and_dedup_i32(&tokens_to_check);

        const saved_temporary_input_start_row = self.temporary_input_start_row;
        const saved_temporary_input_bytes = self.temporary_input_bytes;
        self.temporary_input_bytes = .empty;
        defer {
            self.temporary_input_bytes.deinit(a);
            self.temporary_input_bytes = saved_temporary_input_bytes;
            self.temporary_input_start_row = saved_temporary_input_start_row;
        }

        const all_latest_states = try a.dupe(ParserState, self.parser.latest_scanable_states());
        defer a.free(all_latest_states);
        const all_latest_completed = self.parser.is_root_completed();

        try self.parser.push_states_to_check(all_latest_states, all_latest_completed);
        const initial_state_history_size: i32 = @intCast(self.parser.scanable_state_history.len());
        var previous_index: ?usize = null;
        var previous_matched_size: i32 = 0;
        self.temporary_input_start_row = initial_state_history_size - 1;
        var byte_rejected_tokens: std.ArrayList(i32) = .empty;
        defer byte_rejected_tokens.deinit(a);

        for (tokens_to_check.items) |index| {
            const u_idx: usize = @intCast(index);
            const token = vocab[u_idx].token;
            const common_prefix_length: i32 = if (previous_index) |prev|
                @min(common_prefix_len(vocab[prev].token, token), previous_matched_size)
            else
                0;
            self.parser.pop_last_states(
                @as(i32, @intCast(self.parser.scanable_state_history.len())) - initial_state_history_size - common_prefix_length,
            );
            self.temporary_input_bytes.shrinkRetainingCapacity(@intCast(common_prefix_length));

            var accepted = token.len != 0;
            var matched_size = common_prefix_length;
            while (@as(usize, @intCast(matched_size)) < token.len) {
                const byte = token[@intCast(matched_size)];
                if (!try self.advance_with_character_budget(byte)) {
                    accepted = false;
                    break;
                }
                try self.temporary_input_bytes.append(a, byte);
                matched_size += 1;
            }
            if (accepted) {
                set_bit(row_words, vocab[u_idx].id, true);
            } else {
                try byte_rejected_tokens.append(a, index);
            }
            previous_index = u_idx;
            previous_matched_size = matched_size;
        }
        self.parser.pop_last_states(
            @as(i32, @intCast(self.parser.scanable_state_history.len())) - initial_state_history_size + 1,
        );

        for (byte_rejected_tokens.items) |index| {
            try self.parser.push_states_to_check(all_latest_states, all_latest_completed);
            self.temporary_input_start_row = @as(i32, @intCast(self.parser.scanable_state_history.len())) - 1;
            self.temporary_input_bytes.clearRetainingCapacity();
            const entry = vocab[@intCast(index)];
            if (try self.advance_atomic_token_with_character_budget(entry.id, token_char_counts[@intCast(index)])) {
                set_bit(row_words, entry.id, true);
                self.parser.pop_last_states(1);
            }
            self.parser.pop_last_states(1);
        }
    }

    fn fill_bitmask_for_states(
        self: *GrammarMatcher,
        row_words: []i32,
        skip_expired: bool,
    ) Allocator.Error!void {
        const a = self.allocator;
        const tok = self.tokenizer_info();
        const sorted_decoded_vocab = tok.sorted_decoded_vocab;
        const subtree_range = tok.trie_subtree_nodes_range;
        const token_char_counts = tok.token_char_counts;
        const cache = self.compiled_grammar.adaptive_token_mask_cache();
        const has_char_budget_rules = self.parser.has_char_budget_rules;

        var latest_states: std.ArrayList(ParserState) = .empty;
        defer latest_states.deinit(a);
        for (self.parser.scanable_state_history.back()) |state| {
            if (!(skip_expired and self.parser.is_expired_state(state))) {
                try latest_states.append(a, state);
            }
        }

        @memset(row_words, 0);
        self.tmp_rejected_indices.clearRetainingCapacity();
        try self.tmp_rejected_indices.append(a, -1);

        const StateMaskPair = struct {
            state: ParserState,
            mask: *const AdaptiveTokenMask,
        };
        var latest_states_with_masks: std.ArrayList(StateMaskPair) = .empty;
        defer latest_states_with_masks.deinit(a);

        for (latest_states.items) |state| {
            const adaptive_token_mask = cache.get(state.cache_key()) orelse unreachable;
            if (state.char_budget_deadline >= 0) {
                const remaining_chars = state.char_budget_deadline - self.parser.current_char_index();
                if (remaining_chars <= tok.max_token_chars) {
                    try self.fill_bitmask_for_char_budget_boundary(row_words, adaptive_token_mask, @max(remaining_chars, 0));
                    continue;
                }
            }
            try latest_states_with_masks.append(a, .{ .state = state, .mask = adaptive_token_mask });
            switch (adaptive_token_mask.store_type) {
                .AcceptedBitset => {
                    for (row_words, adaptive_token_mask.accepted_bitset.as_words()) |*word, bits| {
                        word.* |= @as(i32, @bitCast(bits));
                    }
                },
                .Accepted => {
                    for (adaptive_token_mask.accepted_indices) |index| {
                        set_bit(row_words, sorted_decoded_vocab[@intCast(index)].id, true);
                    }
                },
                .Rejected => {},
            }
        }

        for (latest_states_with_masks.items) |pair| {
            const state = pair.state;
            const adaptive_token_mask = pair.mask;
            self.tmp_rejected_indices_delta.clearRetainingCapacity();
            try self.parser.push_one_state_to_check(state);
            const track_temporary_input = has_char_budget_rules and self.has_budget_marker_rules;
            var saved_start_row: i32 = -1;
            var saved_bytes: std.ArrayList(u8) = .empty;
            var has_saved = false;
            defer if (has_saved) {
                self.temporary_input_bytes.deinit(a);
                self.temporary_input_bytes = saved_bytes;
                self.temporary_input_start_row = saved_start_row;
            };
            if (track_temporary_input) {
                saved_start_row = self.temporary_input_start_row;
                saved_bytes = self.temporary_input_bytes;
                self.temporary_input_bytes = .empty;
                has_saved = true;
                self.temporary_input_start_row = @as(i32, @intCast(self.parser.scanable_state_history.len())) - 1;
            }

            var prev_token: ?[]const u8 = null;
            var prev_matched_size: i32 = 0;
            var last_rejected_uncertain_range: i32 = 0;
            const uncertain_indices = adaptive_token_mask.uncertain_indices;
            var position: usize = 0;

            while (position < uncertain_indices.len) {
                const cur_token_idx = uncertain_indices[position];
                position += 1;
                const cur_u: usize = @intCast(cur_token_idx);
                if (get_bit(row_words, sorted_decoded_vocab[cur_u].id)) {
                    continue;
                }
                if (cur_token_idx < last_rejected_uncertain_range) {
                    if (adaptive_token_mask.store_type == .Rejected) {
                        try self.tmp_rejected_indices_delta.append(a, cur_token_idx);
                    } else {
                        const remaining = uncertain_indices[position..];
                        const max_advance: usize = @intCast(last_rejected_uncertain_range - cur_token_idx - 1);
                        const search_slice = remaining[0..@min(remaining.len, max_advance)];
                        var lo: usize = 0;
                        var hi: usize = search_slice.len;
                        while (lo < hi) {
                            const mid = lo + (hi - lo) / 2;
                            if (search_slice[mid] < last_rejected_uncertain_range) {
                                lo = mid + 1;
                            } else {
                                hi = mid;
                            }
                        }
                        position += lo;
                    }
                    continue;
                }

                const cur_token = sorted_decoded_vocab[cur_u].token;
                var accepted = cur_token.len != 0 or !has_char_budget_rules;

                if (prev_token) |prev| {
                    const lcp_len = common_prefix_len(cur_token, prev);
                    if (lcp_len > prev_matched_size) {
                        last_rejected_uncertain_range = subtree_range[cur_u];
                        accepted = false;
                    } else if (lcp_len < prev_matched_size) {
                        self.parser.pop_last_states(prev_matched_size - lcp_len);
                        if (track_temporary_input) {
                            self.temporary_input_bytes.shrinkRetainingCapacity(@intCast(lcp_len));
                        }
                    }
                    prev_matched_size = @min(prev_matched_size, lcp_len);
                }

                var retried_atomically = false;
                if (accepted) {
                    const start_j: usize = @intCast(prev_matched_size);
                    for (cur_token[start_j..], start_j..) |byte, j| {
                        if (!try self.advance_byte(byte)) {
                            // #942: Allow transitioning mid-token from literal into a token-level free-text region.
                            if (prev_matched_size > 0 and self.has_token_edge_in_latest_states()) {
                                const saved_cap = self.parser.capture_recording;
                                const saved_relax = self.record_char_budget_relaxation;
                                self.parser.capture_recording = false;
                                self.record_char_budget_relaxation = false;
                                const mid_ok = if (has_char_budget_rules)
                                    try self.advance_atomic_token_with_character_budget(
                                        sorted_decoded_vocab[cur_u].id,
                                        token_char_counts[cur_u],
                                    )
                                else
                                    try unwrap_earley_bool(self.parser.advance_atomic_token(sorted_decoded_vocab[cur_u].id, 0));
                                self.parser.capture_recording = saved_cap;
                                self.record_char_budget_relaxation = saved_relax;
                                if (mid_ok) {
                                    prev_matched_size += 1;
                                    retried_atomically = true;
                                    break;
                                }
                            }
                            last_rejected_uncertain_range = subtree_range[cur_u];
                            accepted = false;
                            break;
                        }
                        if (track_temporary_input) {
                            try self.temporary_input_bytes.append(a, byte);
                        }
                        prev_matched_size = @as(i32, @intCast(j)) + 1;
                    }
                }

                if (!accepted and has_char_budget_rules and self.has_token_edges) {
                    retried_atomically = true;
                    self.parser.pop_last_states(prev_matched_size + 1);
                    if (track_temporary_input) {
                        self.temporary_input_bytes.clearRetainingCapacity();
                    }
                    try self.parser.push_one_state_to_check(state);
                    const saved_capture_recording = self.parser.capture_recording;
                    const saved_record_relaxation = self.record_char_budget_relaxation;
                    self.parser.capture_recording = false;
                    self.record_char_budget_relaxation = false;
                    accepted = try self.advance_atomic_token_with_character_budget(
                        sorted_decoded_vocab[cur_u].id,
                        token_char_counts[cur_u],
                    );
                    self.parser.capture_recording = saved_capture_recording;
                    self.record_char_budget_relaxation = saved_record_relaxation;
                    self.parser.pop_last_states(if (accepted) 2 else 1);
                    try self.parser.push_one_state_to_check(state);
                    prev_matched_size = 0;
                    if (accepted) {
                        last_rejected_uncertain_range = cur_token_idx + 1;
                    }
                }

                switch (adaptive_token_mask.store_type) {
                    .AcceptedBitset, .Accepted => {
                        if (accepted) set_bit(row_words, sorted_decoded_vocab[cur_u].id, true);
                    },
                    .Rejected => {
                        if (!accepted) try self.tmp_rejected_indices_delta.append(a, cur_token_idx);
                    },
                }
                prev_token = if (retried_atomically) null else cur_token;
            }

            self.parser.pop_last_states(prev_matched_size + 1);
            if (adaptive_token_mask.store_type == .Rejected) {
                try intset_union(a, &self.tmp_rejected_indices_delta, adaptive_token_mask.rejected_indices);
                try intset_intersection(a, &self.tmp_rejected_indices, self.tmp_rejected_indices_delta.items);
            }
        }

        const can_reach_end = self.parser.is_root_completed();
        try self.set_token_bitmask(row_words, can_reach_end, false);
    }

    fn set_token_bitmask(
        self: *GrammarMatcher,
        row_words: []i32,
        can_reach_end: bool,
        allow_special_token: bool,
    ) Allocator.Error!void {
        const tok = self.tokenizer_info();
        const sorted_decoded_vocab = tok.sorted_decoded_vocab;
        if (self.tmp_rejected_indices.items.len == 1 and self.tmp_rejected_indices.items[0] == -1) {
            if (allow_special_token) {
                for (tok.special_token_ids) |id| {
                    set_bit(row_words, id, true);
                }
            }
        } else {
            self.tmp_rejected_indices_delta.clearRetainingCapacity();
            for (self.tmp_rejected_indices.items) |index| {
                const token_id = sorted_decoded_vocab[@intCast(index)].id;
                if (!get_bit(row_words, token_id)) {
                    try self.tmp_rejected_indices_delta.append(self.allocator, token_id);
                }
            }
            @memset(row_words, -1);
            for (self.tmp_rejected_indices_delta.items) |token_id| {
                set_bit(row_words, token_id, false);
            }
            if (!allow_special_token) {
                for (tok.special_token_ids) |id| {
                    set_bit(row_words, id, false);
                }
            }
        }
        // #710: Allow a stop token if the root is already complete OR if matching the stop token itself completes the grammar.
        for (self.stop_token_ids) |id| {
            const allow_stop = if (can_reach_end) true else try self.does_stop_token_complete_grammar(id);
            set_bit(row_words, id, allow_stop);
        }
    }

    fn does_stop_token_complete_grammar(self: *GrammarMatcher, token_id: i32) Allocator.Error!bool {
        if (self.parser.is_root_completed()) return true;
        const tok = self.tokenizer_info();
        if (token_id < 0 or @as(usize, @intCast(token_id)) >= tok.vocab_size) return false;
        const tid_u: usize = @intCast(token_id);
        const token = if (tid_u < tok.decoded_vocab.len) tok.decoded_vocab[tid_u] else "";

        const has_char_budget = self.parser.has_char_budget_rules;
        var row_before: ?ParserRow = if (has_char_budget) try self.parser.latest_row(self.allocator) else null;
        defer if (row_before) |*r| r.deinit(self.allocator);
        const saved_relax = self.record_char_budget_relaxation;
        const saved_relaxed = self.char_budget_relaxed;
        self.record_char_budget_relaxation = false;
        defer {
            self.record_char_budget_relaxation = saved_relax;
            self.char_budget_relaxed = saved_relaxed;
        }

        // Check atomic token transition (supports Token edges matching special stop tokens too).
        const atomic_ok = try unwrap_earley_bool(self.parser.advance_atomic_token(token_id, 0));
        if (atomic_ok) {
            const completed = self.parser.is_root_completed();
            self.parser.pop_last_states(1);
            if (row_before) |snap| try self.parser.replace_latest_row(snap);
            if (completed) return true;
        }

        if (token.len == 0) return false;
        var pos: i32 = 0;
        var byte_ok = true;
        for (token) |byte| {
            if (!try self.advance_byte(byte)) {
                byte_ok = false;
                break;
            }
            pos += 1;
        }
        const completed_by_bytes = byte_ok and self.parser.is_root_completed();
        self.parser.pop_last_states(pos);
        if (row_before) |snap| try self.parser.replace_latest_row(snap);
        return completed_by_bytes;
    }

    /// Finds the longest jump-forward byte sequence valid from the current state (caller owns slice).
    pub fn find_jump_forward_string(
        self: *GrammarMatcher,
        allocator: Allocator,
        diag: ?*MatcherErrorInfo,
    ) MatcherError![]u8 {
        if (self.is_stop_token_accepted()) {
            if (diag) |d| d.* = .{ .Terminated = "get the jump forward string" };
            return error.Terminated;
        }
        self.parser.current_token_index = @intCast(self.token_length_history.items.len);
        if (self.budget_force_close_pending) {
            var trial = try self.clone(self.allocator);
            defer trial.deinit();
            trial.parser.capture_recording = false;
            if (try trial.apply_budget_enforcement()) {
                trial.budget_enforce_pending = false;
                trial.budget_force_close_pending = false;
                return trial.find_jump_forward_string(allocator, diag);
            }
        }

        const grammar = self.parser.grammar;
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);
        var num_accepted_chars: i32 = 0;
        while (true) {
            if (self.parser.is_root_completed()) break;
            const states = self.parser.latest_scanable_states();
            var next_char: i32 = -1;
            var can_find_next_char = true;
            for (states) |state| {
                if (self.budget_enforce_pending and self.parser.is_expired_state(state)) {
                    continue;
                }
                const fsm = grammar.per_rule_fsm(state.rule_id).?;
                for (fsm.get_fsm().get_fsm().state_edges(state.element_id)) |edge| {
                    if (!edge.is_char_range()) continue;
                    if (edge.min != edge.max or (next_char != -1 and next_char != edge.min)) {
                        can_find_next_char = false;
                        break;
                    }
                    next_char = edge.min;
                }
            }
            if (next_char == -1 or !can_find_next_char) break;
            const next_byte: u8 = @intCast(next_char);
            if (EarleyParser.starts_utf8_codepoint(next_byte)) {
                var any_char_expired = false;
                for (states) |state| {
                    if (self.parser.is_char_expired_state(state)) {
                        any_char_expired = true;
                        break;
                    }
                }
                if (any_char_expired) break;
            }
            try result.append(allocator, next_byte);
            _ = try unwrap_earley_bool(self.parser.advance(next_byte));
            num_accepted_chars += 1;
        }
        self.parser.pop_last_states(num_accepted_chars);
        // #1012: Keep jump-forward string aligned to complete UTF-8 character boundaries.
        const slice = result.items;
        if (slice.len > 0) {
            if (!EarleyParser.starts_utf8_codepoint(slice[0])) {
                result.clearRetainingCapacity();
            } else {
                var valid_len: usize = 0;
                while (valid_len < slice.len) {
                    const cp_len = std.unicode.utf8ByteSequenceLength(slice[valid_len]) catch break;
                    if (valid_len + cp_len > slice.len) break;
                    if (std.unicode.utf8Decode(slice[valid_len .. valid_len + cp_len])) |_| {
                        valid_len += cp_len;
                    } else |_| break;
                }
                result.shrinkRetainingCapacity(valid_len);
            }
        }
        return result.toOwnedSlice(allocator);
    }

    /// Rolls the matcher back by `num_tokens` accepted tokens or strings.
    pub fn rollback(self: *GrammarMatcher, num_tokens: i32, diag: ?*MatcherErrorInfo) MatcherError!void {
        if (num_tokens > @as(i32, @intCast(self.token_length_history.items.len))) {
            if (diag) |d| d.* = .{ .RollbackTooFar = .{
                .requested = num_tokens,
                .available = self.token_length_history.items.len,
            } };
            return error.RollbackTooFar;
        }
        var k: i32 = 0;
        while (k < num_tokens) : (k += 1) {
            const steps = self.token_length_history.pop().?;
            self.parser.pop_last_states(steps);
            if (self.should_track_accepted_bytes() and steps > 0) {
                const new_len = self.row_byte_end.items.len - @as(usize, @intCast(steps));
                self.row_byte_end.shrinkRetainingCapacity(new_len);
                const truncated_bytes: usize = @intCast(self.row_byte_end.items[self.row_byte_end.items.len - 1]);
                self.accepted_bytes.shrinkRetainingCapacity(truncated_bytes);
            }
        }
        if (num_tokens > 0) {
            self.parser.stop_token_is_accepted = false;
        }
        self.budget_enforce_pending = false;
        self.budget_force_close_pending = false;
        self.char_budget_relaxed = false;
        self.record_char_budget_relaxation = false;
        self.temporary_input_start_row = -1;
        self.temporary_input_bytes.clearRetainingCapacity();
        self.clear_budget_body_match_cache();
    }

    /// The captured spans recorded so far (caller owns slices via `free_captures`).
    pub fn get_captures(self: *const GrammarMatcher, allocator: Allocator, deduplicate: bool) Allocator.Error![]Capture {
        var result: std.ArrayList(Capture) = .empty;
        errdefer {
            for (result.items) |c| {
                allocator.free(c.name);
                allocator.free(c.bytes);
            }
            result.deinit(allocator);
        }
        if (!self.parser.capture_tracking) {
            return result.toOwnedSlice(allocator);
        }

        const history = &self.parser.capture_event_history;
        std.debug.assert(history.len() == self.row_byte_end.items.len);
        const grammar = self.parser.grammar;

        var events: std.ArrayList(CaptureSpanEvent) = .empty;
        defer {
            for (events.items) |*ev| ev.deinit(allocator);
            events.deinit(allocator);
        }

        for (0..history.len()) |row_idx| {
            for (history.row(row_idx)) |event| {
                const start_row = if (event.start_pos == ParserState.NO_PREV_INPUT_POS)
                    @as(i32, 0)
                else
                    event.start_pos;
                var targets_copy: std.ArrayList(parser_mod.CaptureOccurrence) = .empty;
                errdefer targets_copy.deinit(allocator);
                try targets_copy.appendSlice(allocator, event.stop_capture_targets.items);
                try events.append(allocator, .{
                    .rule_id = event.rule_id,
                    .start_row = start_row,
                    .occurrence_start_pos = event.occurrence_start_pos,
                    .end_row = @intCast(row_idx),
                    .hidden_suffix_bytes = event.hidden_suffix_bytes,
                    .hidden_stop_bytes = event.hidden_stop_bytes,
                    .stop_capture_targets = targets_copy,
                    .marker_present = false,
                    .marker_start_byte = -1,
                });
            }
        }

        const keep = try allocator.alloc(bool, events.items.len);
        defer allocator.free(keep);
        @memset(keep, true);
        if (deduplicate) {
            var last_index = std.AutoHashMap(i64, usize).init(allocator);
            defer last_index.deinit();
            for (events.items, 0..) |event, i| {
                const gop = try last_index.getOrPut(occurrence_key(event.rule_id, event.start_row));
                if (gop.found_existing) {
                    keep[gop.value_ptr.*] = false;
                }
                gop.value_ptr.* = i;
            }
        }

        for (events.items, 0..) |*event, i| {
            const hidden_bytes = @max(event.hidden_suffix_bytes, event.hidden_stop_bytes);
            if (!keep[i] or hidden_bytes <= 0) continue;
            const info = grammar.suffix_stop_info(event.rule_id).?;
            const event_start = self.row_byte_end.items[@intCast(event.start_row)];
            const event_end = self.row_byte_end.items[@intCast(event.end_row)];
            event.marker_present = true;
            if (info.body_rule_id == -1) {
                event.marker_start_byte = @max(event_start, event_end - @as(i64, hidden_bytes));
                continue;
            }
            const body_fsm = grammar.per_rule_fsm(info.body_rule_id).?.get_fsm();
            const marker_fsm = grammar.per_rule_fsm(info.marker_rule_id).?.get_fsm();
            const body_ends = try self.accepted_prefixes(allocator, body_fsm, event_start, event_end);
            defer allocator.free(body_ends);
            const marker_starts = try self.accepted_suffixes(allocator, marker_fsm, event_start, event_end);
            defer allocator.free(marker_starts);
            var matched_offset: ?usize = null;
            for (0..body_ends.len) |offset| {
                if (body_ends[offset] and marker_starts[offset]) {
                    matched_offset = offset;
                    break;
                }
            }
            if (matched_offset) |offset| {
                event.marker_start_byte = event_start + @as(i64, @intCast(offset));
            } else {
                std.debug.assert(false);
                event.marker_present = false;
                event.marker_start_byte = -1;
            }
        }

        const ByteSpan = struct { start: i64, end: i64 };
        var hidden_stop_spans_by_capture = std.AutoHashMap(i64, std.ArrayList(ByteSpan)).init(allocator);
        defer {
            var it = hidden_stop_spans_by_capture.valueIterator();
            while (it.next()) |list| list.deinit(allocator);
            hidden_stop_spans_by_capture.deinit();
        }
        for (events.items, 0..) |event, i| {
            if (!keep[i] or event.hidden_stop_bytes <= 0 or !event.marker_present) continue;
            const event_end = self.row_byte_end.items[@intCast(event.end_row)];
            if (event.marker_start_byte < event_end) {
                for (event.stop_capture_targets.items) |target| {
                    const gop = try hidden_stop_spans_by_capture.getOrPut(occurrence_key(target.rule_id, target.start_pos));
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(allocator, .{ .start = event.marker_start_byte, .end = event_end });
                }
            }
        }
        {
            var it = hidden_stop_spans_by_capture.valueIterator();
            while (it.next()) |list| {
                std.mem.sortUnstable(ByteSpan, list.items, {}, struct {
                    fn less(_: void, lhs: ByteSpan, rhs: ByteSpan) bool {
                        if (lhs.start != rhs.start) return lhs.start < rhs.start;
                        return lhs.end < rhs.end;
                    }
                }.less);
            }
        }

        for (events.items, 0..) |event, i| {
            if (!keep[i]) continue;
            const rule = grammar.rule(event.rule_id);
            const info = grammar.suffix_stop_info(event.rule_id);
            const capture_start = self.row_byte_end.items[@intCast(event.start_row)];
            var capture_end = self.row_byte_end.items[@intCast(event.end_row)];
            if (info) |inf| {
                if (event.marker_present and inf.stop_capture_name.len != 0) {
                    const marker = if (event.marker_start_byte < capture_end)
                        try allocator.dupe(u8, self.accepted_bytes.items[@intCast(event.marker_start_byte)..@intCast(capture_end)])
                    else
                        try allocator.dupe(u8, "");
                    errdefer allocator.free(marker);
                    const name_copy = try allocator.dupe(u8, inf.stop_capture_name);
                    errdefer allocator.free(name_copy);
                    try result.append(allocator, .{ .name = name_copy, .bytes = marker });
                }
            }
            if (rule.capture_name.len == 0) continue;
            if (event.hidden_suffix_bytes > 0 and event.marker_present) {
                capture_end = event.marker_start_byte;
            }

            var cap_bytes: std.ArrayList(u8) = .empty;
            errdefer cap_bytes.deinit(allocator);
            var cursor = capture_start;
            if (hidden_stop_spans_by_capture.get(occurrence_key(event.rule_id, event.occurrence_start_pos))) |spans| {
                for (spans.items) |span| {
                    if (span.end <= capture_start) continue;
                    if (span.start >= capture_end) break;
                    const seg_end = @min(span.start, capture_end);
                    if (cursor < seg_end) {
                        try cap_bytes.appendSlice(allocator, self.accepted_bytes.items[@intCast(cursor)..@intCast(seg_end)]);
                    }
                    cursor = @max(cursor, @min(span.end, capture_end));
                }
            }
            if (cursor < capture_end) {
                try cap_bytes.appendSlice(allocator, self.accepted_bytes.items[@intCast(cursor)..@intCast(capture_end)]);
            }

            const owned_bytes = try cap_bytes.toOwnedSlice(allocator);
            errdefer allocator.free(owned_bytes);
            const name_copy = try allocator.dupe(u8, rule.capture_name);
            errdefer allocator.free(name_copy);
            try result.append(allocator, .{ .name = name_copy, .bytes = owned_bytes });
        }

        return result.toOwnedSlice(allocator);
    }

    fn accepted_prefixes(
        self: *const GrammarMatcher,
        allocator: Allocator,
        fsm: *const CompactFsmWithStartEnd,
        begin: i64,
        end: i64,
    ) Allocator.Error![]bool {
        const len: usize = @intCast(end - begin + 1);
        const result = try allocator.alloc(bool, len);
        errdefer allocator.free(result);
        var states = try fsm_mod.fsm.state_set_from(allocator, &.{fsm.get_start()});
        defer states.deinit();
        const compact = fsm.get_fsm();
        try compact.epsilon_closure(&states);
        result[0] = set_contains_end(&states, fsm);
        var next_states = StateSet.init(allocator);
        defer next_states.deinit();
        var offset: i64 = 0;
        while (offset < end - begin) : (offset += 1) {
            const byte = self.accepted_bytes.items[@intCast(begin + offset)];
            try compact.advance_char(&states, byte, &next_states);
            std.mem.swap(StateSet, &states, &next_states);
            result[@intCast(offset + 1)] = set_contains_end(&states, fsm);
        }
        return result;
    }

    fn accepted_suffixes(
        self: *const GrammarMatcher,
        allocator: Allocator,
        marker_fsm: *const CompactFsmWithStartEnd,
        begin: i64,
        end: i64,
    ) Allocator.Error![]bool {
        const fsm = marker_fsm.get_fsm();
        var reachable = try marker_fsm.reachable_states();
        defer reachable.deinit();
        const num_states: usize = @intCast(fsm.num_states());

        const reverse_epsilon = try allocator.alloc(std.ArrayList(i32), num_states);
        defer {
            for (reverse_epsilon) |*l| l.deinit(allocator);
            allocator.free(reverse_epsilon);
        }
        @memset(reverse_epsilon, .empty);

        const RevCharEdge = struct { source: i32, min: i32, max: i32 };
        const reverse_char = try allocator.alloc(std.ArrayList(RevCharEdge), num_states);
        defer {
            for (reverse_char) |*l| l.deinit(allocator);
            allocator.free(reverse_char);
        }
        @memset(reverse_char, .empty);

        var rit = reachable.keyIterator();
        while (rit.next()) |src_ptr| {
            const source = src_ptr.*;
            for (fsm.state_edges(source)) |edge| {
                if (!reachable.contains(edge.target)) continue;
                const tgt_u: usize = @intCast(edge.target);
                if (edge.is_epsilon()) {
                    try reverse_epsilon[tgt_u].append(allocator, source);
                } else if (edge.is_char_range()) {
                    try reverse_char[tgt_u].append(allocator, .{ .source = source, .min = edge.min, .max = edge.max });
                }
            }
        }

        const add_rev_eps = struct {
            fn run(alloc: Allocator, states: *StateSet, rev_eps: []const std.ArrayList(i32)) Allocator.Error!void {
                var queue: std.ArrayList(i32) = .empty;
                defer queue.deinit(alloc);
                var it = states.keyIterator();
                while (it.next()) |s| try queue.append(alloc, s.*);
                var i: usize = 0;
                while (i < queue.items.len) : (i += 1) {
                    for (rev_eps[@intCast(queue.items[i])].items) |pred| {
                        const gop = try states.getOrPut(pred);
                        if (!gop.found_existing) try queue.append(alloc, pred);
                    }
                }
            }
        }.run;

        const length: usize = @intCast(end - begin);
        const result = try allocator.alloc(bool, length + 1);
        errdefer allocator.free(result);

        var states = StateSet.init(allocator);
        defer states.deinit();
        var s: i32 = 0;
        while (s < fsm.num_states()) : (s += 1) {
            if (marker_fsm.is_end_state(s)) try states.put(s, {});
        }
        try add_rev_eps(allocator, &states, reverse_epsilon);
        result[length] = states.contains(marker_fsm.get_start());

        var previous_states = StateSet.init(allocator);
        defer previous_states.deinit();
        var offset = length;
        while (offset > 0) {
            previous_states.clearRetainingCapacity();
            const byte: i32 = self.accepted_bytes.items[@intCast(begin + @as(i64, @intCast(offset)) - 1)];
            var it = states.keyIterator();
            while (it.next()) |tgt_ptr| {
                for (reverse_char[@intCast(tgt_ptr.*)].items) |edge| {
                    if (edge.min <= byte and byte <= edge.max) {
                        try previous_states.put(edge.source, {});
                    }
                }
            }
            try add_rev_eps(allocator, &previous_states, reverse_epsilon);
            std.mem.swap(StateSet, &states, &previous_states);
            offset -= 1;
            result[offset] = states.contains(marker_fsm.get_start());
        }
        return result;
    }

    fn set_contains_end(states: *const StateSet, fsm: *const CompactFsmWithStartEnd) bool {
        var it = states.keyIterator();
        while (it.next()) |s| {
            if (fsm.is_end_state(s.*)) return true;
        }
        return false;
    }

    /// Traverses a speculative-decoding draft tree and fills one token-mask row per node.
    pub fn traverse_draft_tree(
        self: *GrammarMatcher,
        retrieve_next_token: []const i64,
        retrieve_next_sibling: []const i64,
        draft_tokens: []const i64,
        token_bitmask: []i32,
        time_threshold: f64,
        temperatures: ?[]f32,
        diag: ?*MatcherErrorInfo,
    ) MatcherError!bool {
        const a = self.allocator;
        const num_nodes = retrieve_next_token.len;
        if (retrieve_next_sibling.len != num_nodes) {
            return error_mod.set_invalid_arg(
                diag,
                a,
                "The retrieve_next_token and retrieve_next_sibling tensors must have the same length",
            );
        }
        if (draft_tokens.len != num_nodes) {
            return error_mod.set_invalid_arg(
                diag,
                a,
                "The retrieve_next_token and draft_tokens tensors must have the same length",
            );
        }
        const bitmask_words: usize = @intCast(get_bitmask_size(self.tokenizer_info().vocab_size));
        if (token_bitmask.len != num_nodes * bitmask_words) {
            return error_mod.set_invalid_arg(
                diag,
                a,
                "The token_bitmask batch size must match the number of nodes in the tree",
            );
        }
        if (temperatures) |temps| {
            if (temps.len != num_nodes) {
                return error_mod.set_invalid_arg(
                    diag,
                    a,
                    "The temperatures size must match the number of nodes in the tree",
                );
            }
            @memset(temps, -1.0);
        }
        if (num_nodes == 0) {
            return error_mod.set_invalid_arg(diag, a, "The draft tree must not be empty");
        }
        if (retrieve_next_sibling[0] != -1) {
            return error_mod.set_invalid_arg(diag, a, "The root node must not have siblings");
        }

        const in_degree = try a.alloc(usize, num_nodes);
        defer a.free(in_degree);
        @memset(in_degree, 0);
        for (0..num_nodes) |i| {
            const fields = [2]struct { name: []const u8, val: i64 }{
                .{ .name = "retrieve_next_token", .val = retrieve_next_token[i] },
                .{ .name = "retrieve_next_sibling", .val = retrieve_next_sibling[i] },
            };
            for (fields) |entry| {
                if (entry.val < -1 or entry.val >= @as(i64, @intCast(num_nodes))) {
                    return error_mod.set_invalid_arg_fmt(
                        diag,
                        a,
                        "{s}[{d}] = {d} is out of bounds: it should be in [-1, {d}).",
                        .{ entry.name, i, entry.val, num_nodes },
                    );
                }
                if (entry.val != -1) {
                    in_degree[@intCast(entry.val)] += 1;
                }
            }
        }
        if (in_degree[0] != 0) {
            return error_mod.set_invalid_arg(diag, a, "The root node must not be the child or sibling of a node");
        }
        for (1..num_nodes) |node| {
            if (in_degree[node] > 1) {
                return error_mod.set_invalid_arg_fmt(
                    diag,
                    a,
                    "Node {d} is the target of {d} retrieve_next_token / retrieve_next_sibling entries; the draft tree must not contain cycles or shared nodes.",
                    .{ node, in_degree[node] },
                );
            }
        }

        return self.traverse_draft_tree_recursive(
            0,
            null,
            retrieve_next_token,
            retrieve_next_sibling,
            draft_tokens,
            token_bitmask,
            bitmask_words,
            temperatures,
            time_threshold,
            monotonic_ns(),
            diag,
        );
    }

    fn traverse_draft_tree_recursive(
        self: *GrammarMatcher,
        current: usize,
        parent: ?usize,
        retrieve_next_token: []const i64,
        retrieve_next_sibling: []const i64,
        draft_tokens: []const i64,
        token_bitmask: []i32,
        bitmask_words: usize,
        temperatures: ?[]f32,
        time_threshold: f64,
        start_ns: i128,
        diag: ?*MatcherErrorInfo,
    ) MatcherError!bool {
        const accepted: bool = if (current == 0)
            true
        else blk: {
            const p = parent.?;
            const token = draft_tokens[current];
            const bit_ok = token >= 0 and token < @as(i64, @intCast(bitmask_words * 32)) and blk2: {
                const tok_u: usize = @intCast(token);
                const word = token_bitmask[p * bitmask_words + tok_u / 32];
                const bit: u5 = @intCast(tok_u % 32);
                break :blk2 ((@as(u32, @bitCast(word)) & (@as(u32, 1) << bit)) != 0);
            };
            if (bit_ok and time_threshold > 0.0) {
                const elapsed_secs = @as(f64, @floatFromInt(monotonic_ns() - start_ns)) / @as(f64, std.time.ns_per_s);
                if (elapsed_secs > time_threshold) return false;
            }
            break :blk bit_ok;
        };

        const row_start = current * bitmask_words;
        const row_end = (current + 1) * bitmask_words;
        const token_accepted = accepted and (current == 0 or blk: {
            const tid = std.math.cast(i32, draft_tokens[current]) orelse break :blk false;
            break :blk try self.accept_token(tid);
        });

        if (token_accepted and !self.is_terminated()) {
            const batch_rows: i64 = @intCast(token_bitmask.len / bitmask_words);
            const shape = [2]i64{ batch_rows, @intCast(bitmask_words) };
            _ = try self.fill_next_token_bitmask(token_bitmask, &shape, @intCast(current), diag);
            if (temperatures) |temps| {
                temps[current] = self.temperature() orelse -1.0;
            }
            const child = retrieve_next_token[current];
            if (child != -1) {
                if (!try self.traverse_draft_tree_recursive(
                    @intCast(child),
                    current,
                    retrieve_next_token,
                    retrieve_next_sibling,
                    draft_tokens,
                    token_bitmask,
                    bitmask_words,
                    temperatures,
                    time_threshold,
                    start_ns,
                    diag,
                )) {
                    if (current != 0) try self.rollback(1, diag);
                    return false;
                }
            }
        } else {
            @memset(token_bitmask[row_start..row_end], 0);
        }

        if (token_accepted and current != 0) {
            try self.rollback(1, diag);
        }

        const sibling = retrieve_next_sibling[current];
        if (sibling != -1) {
            if (!try self.traverse_draft_tree_recursive(
                @intCast(sibling),
                parent,
                retrieve_next_token,
                retrieve_next_sibling,
                draft_tokens,
                token_bitmask,
                bitmask_words,
                temperatures,
                time_threshold,
                start_ns,
                diag,
            )) {
                return false;
            }
        }
        return true;
    }
};
