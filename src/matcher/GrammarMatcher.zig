//! Stateful matcher to match tokens to a BNF grammar (`grammar_matcher.rs`).

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;

const compiler = @import("../compiler.zig");
const AdaptiveTokenMask = compiler.AdaptiveTokenMask;
const CompiledGrammar = compiler.CompiledGrammar;
const Diagnostic = @import("../Diagnostic.zig").Diagnostic;
const fsm_mod = @import("../fsm.zig");
const CompactFsmWithStartEnd = fsm_mod.CompactFsmWithStartEnd;
const StateSet = fsm_mod.StateSet;
const grammar_mod = @import("../grammar.zig");
const Grammar = grammar_mod.Grammar;
const matcher_mod = @import("../matcher.zig");
const MatcherError = matcher_mod.MatcherError;
const parser_mod = @import("../parser.zig");
const CaptureEvent = parser_mod.CaptureEvent;
const CaptureOccurrence = parser_mod.CaptureOccurrence;
const CompletableState = parser_mod.CompletableState;
const EarleyParser = parser_mod.EarleyParser;
const ParserRow = parser_mod.ParserRow;
const ParserState = parser_mod.ParserState;
const support = @import("../support.zig");
const commonPrefixLen = support.commonPrefixLen;
const escapeBytes = support.escapeBytes;
const intsetIntersection = support.intsetIntersection;
const tokenizer_mod = @import("../tokenizer.zig");
const TokenizerInfo = tokenizer_mod.TokenizerInfo;

const bitmask_mod = @import("TokenBitmask.zig");
const TokenBitmask = bitmask_mod.TokenBitmask;
const TokenBitmaskView = bitmask_mod.TokenBitmaskView;
const bitmaskRowRange = bitmask_mod.bitmaskRowRange;
const bitmaskSize = bitmask_mod.bitmaskSize;

const log = std.log.scoped(.xgrammar);

/// One captured span returned by `GrammarMatcher.getCaptures`.
pub const Capture = struct {
    name: []u8,
    bytes: []u8,

    pub fn freeSlice(allocator: Allocator, captures: []Capture) void {
        for (captures) |c| {
            allocator.free(c.name);
            allocator.free(c.bytes);
        }
        allocator.free(captures);
    }
};

/// Incremental body-FSM progress of a budgeted suffix/stop rule occurrence.
const BudgetBodyMatchProgress = struct {
    begin_byte: i64,
    end_byte: i64,
    states: StateSet,
    temporary_input_snapshot: std.ArrayList(u8),

    fn deinit(self: *BudgetBodyMatchProgress, allocator: Allocator) void {
        self.states.deinit();
        self.temporary_input_snapshot.deinit(allocator);
    }

    fn dupe(self: *const BudgetBodyMatchProgress, allocator: Allocator) Allocator.Error!BudgetBodyMatchProgress {
        var states_copy = try fsm_mod.cloneSet(allocator, &self.states);
        errdefer states_copy.deinit();

        var snap_copy: std.ArrayList(u8) = .empty;
        errdefer snap_copy.deinit(allocator);
        try snap_copy.appendSlice(allocator, self.temporary_input_snapshot.items);

        return .{
            .begin_byte = self.begin_byte,
            .end_byte = self.end_byte,
            .states = states_copy,
            .temporary_input_snapshot = snap_copy,
        };
    }
};

/// A capture event flattened out of the parser history, with its marker resolved to bytes.
const CaptureSpanEvent = struct {
    rule_id: i32,
    start_row: i32,
    occurrence_start_pos: i32,
    end_row: i32,
    hidden_suffix_bytes: i32,
    hidden_stop_bytes: i32,
    stop_capture_targets: std.ArrayList(CaptureOccurrence),
    marker_present: bool,
    marker_start_byte: i64,

    fn deinit(self: *CaptureSpanEvent, allocator: Allocator) void {
        self.stop_capture_targets.deinit(allocator);
    }
};

const StateMaskPair = struct {
    state: ParserState,
    mask: *const AdaptiveTokenMask,
};

inline fn occurrenceKey(rule_id: i32, start_pos: i32) i64 {
    return (@as(i64, rule_id) << 32) | @as(i64, @as(u32, @bitCast(start_pos)));
}

inline fn getBit(row_words: []const i32, token_id: i32) bool {
    const u: usize = @intCast(token_id);
    return ((@as(u32, @bitCast(row_words[u / 32])) >> @as(u5, @intCast(u % 32))) & 1) != 0;
}

inline fn setBit(row_words: []i32, token_id: i32, value: bool) void {
    const u: usize = @intCast(token_id);
    const word_idx = u / 32;
    const bit: u5 = @intCast(u % 32);
    const mask: i32 = @bitCast(@as(u32, 1) << bit);
    if (value) {
        row_words[word_idx] |= mask;
    } else {
        row_words[word_idx] &= ~mask;
    }
}

fn rowHasAnyToken(row_words: []const i32, vocab_size: usize) bool {
    const full_words = vocab_size / 32;
    for (row_words[0..full_words]) |w| {
        if (w != 0) return true;
    }
    const rem: u5 = @intCast(vocab_size % 32);
    if (rem != 0 and full_words < row_words.len) {
        const last_mask: u32 = (@as(u32, 1) << rem) - 1;
        if ((@as(u32, @bitCast(row_words[full_words])) & last_mask) != 0) return true;
    }
    return false;
}

fn rowAllTrue(row_words: []const i32, vocab_size: usize) bool {
    const full_words = vocab_size / 32;
    for (row_words[0..full_words]) |w| {
        if (w != -1) return false;
    }
    const rem: u5 = @intCast(vocab_size % 32);
    if (rem != 0 and full_words < row_words.len) {
        const last_mask: u32 = (@as(u32, 1) << rem) - 1;
        if ((@as(u32, @bitCast(row_words[full_words])) & last_mask) != last_mask) return false;
    }
    return true;
}

fn monotonicNs() i128 {
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

fn sortAndDedupI32(list: *std.ArrayList(i32)) void {
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

fn binarySearchI32(slice: []const i32, needle: i32) bool {
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

/// Stateful matcher to match tokens and byte strings to a compiled BNF grammar.
pub const GrammarMatcher = struct {
    allocator: Allocator,
    compiled_grammar: CompiledGrammar,
    parser: EarleyParser,
    stop_token_ids: []u32,
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
    tmp_latest_states: std.ArrayList(ParserState),
    tmp_states_with_masks: std.ArrayList(StateMaskPair),
    tmp_rejected_indices: std.ArrayList(i32),
    tmp_rejected_indices_delta: std.ArrayList(i32),
    tmp_intset_scratch: std.ArrayList(i32),

    pub const Options = struct {
        override_stop_tokens: ?[]const u32 = null,
        terminate_without_stop_token: bool = false,
        default_temperature: ?f32 = null,
        diag: ?*Diagnostic = null,
    };

    /// Constructs a `GrammarMatcher` from `compiled` and `options`.
    pub fn init(
        allocator: Allocator,
        compiled: *const CompiledGrammar,
        options: Options,
    ) MatcherError!GrammarMatcher {
        const tok = compiled.tokenizerInfo();
        const vocab_size = tok.vocabSize();
        if (options.override_stop_tokens) |ids| {
            if (ids.len == 0) {
                if (options.diag) |d| d.setStatic(.matcher_empty_override_stop_tokens, "");
                return error.EmptyOverrideStopTokens;
            }
            for (ids) |token_id| {
                if (@as(usize, token_id) >= vocab_size) {
                    if (options.diag) |d| {
                        d.setNumbers(
                            .matcher_stop_token_out_of_range,
                            @intCast(token_id),
                            std.math.cast(i64, vocab_size) orelse std.math.maxInt(i64),
                        );
                    }
                    return error.StopTokenOutOfRange;
                }
            }
        }
        if (options.default_temperature) |temp| {
            if (!std.math.isFinite(temp) or temp < 0.0) {
                if (options.diag) |d| d.setStatic(.matcher_invalid_default_temperature, "");
                return error.InvalidDefaultTemperature;
            }
        }

        var compiled_ref = compiled.retain();
        errdefer compiled_ref.deinit();

        const g = compiled_ref.grammar();
        var parser = try EarleyParser.init(allocator, g, null);
        errdefer parser.deinit();

        const has_budget_marker_rules = (parser.has_budget_rules or parser.has_char_budget_rules) and blk: {
            for (0..g.numRules()) |rid_u| {
                const rule_id: i32 = @intCast(rid_u);
                const rule = g.rule(rule_id);
                if (rule.max_tokens >= 0 or rule.max_chars >= 0) {
                    if (g.suffixStopInfo(rule_id)) |info| {
                        if (info.body_rule_id >= 0) break :blk true;
                    }
                }
            }
            break :blk false;
        };

        const has_token_edges = parser.has_char_budget_rules and blk: {
            const fsm = g.completeFsm();
            var s: i32 = 0;
            while (s < fsm.numStates()) : (s += 1) {
                for (fsm.stateEdges(s)) |edge| {
                    if (edge.isToken() or edge.isExcludeToken()) break :blk true;
                }
            }
            break :blk false;
        };

        const stop_ids = try allocator.dupe(
            u32,
            options.override_stop_tokens orelse tok.stopTokenIds(),
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
            .terminate_without_stop_token = options.terminate_without_stop_token,
            .default_temperature = options.default_temperature,
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
            .tmp_latest_states = .empty,
            .tmp_states_with_masks = .empty,
            .tmp_rejected_indices = .empty,
            .tmp_rejected_indices_delta = .empty,
            .tmp_intset_scratch = .empty,
        };
    }

    pub fn deinit(self: *GrammarMatcher) void {
        const a = self.allocator;
        self.clearBudgetBodyMatchCache();
        self.budget_body_match_cache.deinit(a);
        self.accepted_bytes.deinit(a);
        self.row_byte_end.deinit(a);
        self.temporary_input_bytes.deinit(a);
        self.tmp_latest_states.deinit(a);
        self.tmp_states_with_masks.deinit(a);
        self.tmp_rejected_indices.deinit(a);
        self.tmp_rejected_indices_delta.deinit(a);
        self.tmp_intset_scratch.deinit(a);
        self.token_length_history.deinit(a);
        a.free(self.stop_token_ids);
        self.parser.deinit();
        self.compiled_grammar.deinit();
        self.* = undefined;
    }

    fn clearBudgetBodyMatchCache(self: *GrammarMatcher) void {
        var it = self.budget_body_match_cache.valueIterator();
        while (it.next()) |progress| {
            progress.deinit(self.allocator);
        }
        self.budget_body_match_cache.clearRetainingCapacity();
    }

    /// Deep-copies the matcher into `allocator`, retaining the shared compiled grammar.
    pub fn clone(self: *const GrammarMatcher, allocator: Allocator) Allocator.Error!GrammarMatcher {
        var compiled_ref = self.compiled_grammar.retain();
        errdefer compiled_ref.deinit();

        var parser_copy = try self.parser.dupe(allocator);
        errdefer parser_copy.deinit();

        const stop_ids = try allocator.dupe(u32, self.stop_token_ids);
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
            budget_cache.putAssumeCapacity(entry.key_ptr.*, try entry.value_ptr.dupe(allocator));
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
            .tmp_latest_states = .empty,
            .tmp_states_with_masks = .empty,
            .tmp_rejected_indices = .empty,
            .tmp_rejected_indices_delta = .empty,
            .tmp_intset_scratch = .empty,
        };
    }

    /// Forks the matcher using its own allocator.
    pub fn fork(self: *const GrammarMatcher) Allocator.Error!GrammarMatcher {
        return self.clone(self.allocator);
    }

    pub inline fn grammar(self: *const GrammarMatcher) *const Grammar {
        return self.compiled_grammar.grammar();
    }

    pub inline fn tokenizerInfo(self: *const GrammarMatcher) *const TokenizerInfo {
        return self.compiled_grammar.tokenizerInfo();
    }

    pub inline fn stopTokenIds(self: *const GrammarMatcher) []const u32 {
        return self.stop_token_ids;
    }

    pub inline fn earleyParser(self: *const GrammarMatcher) *const EarleyParser {
        return &self.parser;
    }

    pub fn maxRollbackTokens(_: *const GrammarMatcher) i32 {
        return -1;
    }

    pub fn isCompleted(self: *const GrammarMatcher) bool {
        return self.parser.isRootCompleted();
    }

    pub fn isStopTokenAccepted(self: *const GrammarMatcher) bool {
        return self.parser.stop_token_is_accepted;
    }

    pub fn isTerminated(self: *const GrammarMatcher) bool {
        if (self.terminate_without_stop_token) {
            return self.parser.isRootCompleted();
        }
        return self.isStopTokenAccepted();
    }

    /// Streams a human-readable dump of the latest internal parser states to `writer`.
    pub fn debugPrintInternalState(self: *const GrammarMatcher, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("There are {d} steps in history. Last step: [\n", .{self.parser.scanable_state_history.len()});
        for (self.parser.latestScanableStates()) |state| {
            try writer.print("{f}, \n", .{state});
        }
        try writer.writeAll("]");
    }

    pub fn acceptStopToken(self: *GrammarMatcher) Allocator.Error!bool {
        if (self.terminate_without_stop_token or !self.parser.isRootCompleted()) {
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
        self.clearBudgetBodyMatchCache();
        self.temporary_input_start_row = -1;
        self.temporary_input_bytes.clearRetainingCapacity();
        self.accepted_bytes.clearRetainingCapacity();
        self.row_byte_end.clearRetainingCapacity();
        try self.row_byte_end.append(self.allocator, 0);
        try self.parser.reset();
    }

    fn shouldTrackAcceptedBytes(self: *const GrammarMatcher) bool {
        return self.parser.capture_tracking or self.has_budget_marker_rules;
    }

    fn appendPerByteRows(self: *GrammarMatcher, bytes: []const u8) Allocator.Error!void {
        for (bytes) |byte| {
            try self.accepted_bytes.append(self.allocator, byte);
            try self.row_byte_end.append(self.allocator, @intCast(self.accepted_bytes.items.len));
        }
    }

    fn appendAtomicRow(self: *GrammarMatcher, bytes: []const u8) Allocator.Error!void {
        try self.accepted_bytes.appendSlice(self.allocator, bytes);
        try self.row_byte_end.append(self.allocator, @intCast(self.accepted_bytes.items.len));
    }

    fn finishCharacterBudgetAccept(self: *GrammarMatcher) void {
        if (self.char_budget_relaxed and !self.char_budget_exceeded_warned) {
            self.char_budget_exceeded_warned = true;
            log.warn("The character budget (max_chars) of a rule was exceeded: the rule could not end at the position where its budget ran out, so the budget is relaxed until the rule can end. This warning is reported once per matcher.", .{});
        }
        self.char_budget_relaxed = false;
    }

    fn finishAccept(self: *GrammarMatcher, consumed_past_deadline: bool) bool {
        self.budget_enforce_pending = false;
        self.budget_force_close_pending = false;
        if (consumed_past_deadline and !self.budget_exceeded_warned) {
            self.budget_exceeded_warned = true;
            log.warn("The token budget (max_tokens) of a rule was exceeded: the rule could not end at the position where its budget ran out, so the budget is relaxed until the rule can end. This warning is reported once per matcher.", .{});
        }
        self.finishCharacterBudgetAccept();
        return true;
    }

    fn canForceCompleteWithoutMarker(
        self: *GrammarMatcher,
        state: ParserState,
        use_char_budget: bool,
    ) Allocator.Error!bool {
        const expired = if (use_char_budget)
            self.parser.isCharExpiredState(state)
        else
            self.parser.isExpiredState(state);
        if (!expired or state.rule_id < 0) return false;
        const g = self.parser.grammar;
        const rule = g.rule(state.rule_id);
        if (if (use_char_budget) rule.max_chars < 0 else rule.max_tokens < 0) {
            return false;
        }
        const info = g.suffixStopInfo(state.rule_id) orelse return false;
        if (info.body_rule_id < 0) return false;
        std.debug.assert(self.shouldTrackAcceptedBytes());

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
        const body_fsm = &g.perRuleFsm(info.body_rule_id).?.fsm;
        const body_compact = body_fsm.fsm;

        const key = occurrenceKey(state.rule_id, state.rule_start_pos);
        const accepted_len: i64 = @intCast(self.accepted_bytes.items.len);

        const gop = try self.budget_body_match_cache.getOrPut(self.allocator, key);
        if (!gop.found_existing) {
            var states = try fsm_mod.stateSetFrom(self.allocator, &.{body_fsm.start});
            errdefer states.deinit();
            try body_compact.epsilonClosure(self.allocator, &states);
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
                var states = try fsm_mod.stateSetFrom(self.allocator, &.{body_fsm.start});
                errdefer states.deinit();
                try body_compact.epsilonClosure(self.allocator, &states);
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
            try body_compact.advanceChar(self.allocator, &progress.states, byte, &next_states);
            std.mem.swap(StateSet, &progress.states, &next_states);
        }
        progress.end_byte = end;
        progress.temporary_input_snapshot.clearRetainingCapacity();
        if (end > accepted_len) {
            try progress.temporary_input_snapshot.appendSlice(self.allocator, self.temporary_input_bytes.items);
        }

        var it = progress.states.keyIterator();
        while (it.next()) |state_id| {
            if (body_fsm.isEndState(state_id.*)) return true;
        }
        return false;
    }

    fn applyBudgetEnforcementImpl(self: *GrammarMatcher, use_char_budget: bool) Allocator.Error!bool {
        std.debug.assert(self.parser.tmp_process_state_queue.len == 0);
        var previous_row = try self.parser.latestRow(self.allocator);
        defer previous_row.deinit(self.allocator);

        self.parser.tmp_states_visited_in_queue.clear();
        self.parser.tmp_states_to_be_added.clearRetainingCapacity();
        self.parser.tmp_completed_lazy_occurrences.clearRetainingCapacity();
        self.parser.tmp_accept_stop_token = self.parser.isRootCompleted();

        var force_completed_states: std.ArrayList(ParserState) = .empty;
        defer force_completed_states.deinit(self.allocator);
        var force_completed_occurrences: std.AutoHashMapUnmanaged(i64, void) = .empty;
        defer force_completed_occurrences.deinit(self.allocator);

        for (previous_row.states.items) |state| {
            const expired = if (use_char_budget)
                self.parser.isCharExpiredState(state)
            else
                self.parser.isExpiredState(state);
            if (!expired) {
                try self.parser.enqueueWithoutProcessing(state);
                continue;
            }
            if (!try self.canForceCompleteWithoutMarker(state, use_char_budget)) {
                continue;
            }
            const occ_gop = try force_completed_occurrences.getOrPut(
                self.allocator,
                occurrenceKey(state.rule_id, state.rule_start_pos),
            );
            if (!occ_gop.found_existing) {
                try force_completed_states.append(self.allocator, state);
            }
        }
        for (force_completed_states.items) |state| {
            try self.parser.complete(state, false);
        }
        try self.parser.processQueue();
        if (self.parser.tmp_completed_lazy_occurrences.items.len != 0) {
            self.parser.removeCommittedLazyStates();
        }

        var any_expired = false;
        var any_alive = false;
        for (self.parser.tmp_states_to_be_added.items) |state| {
            const expired = if (use_char_budget)
                self.parser.isCharExpiredState(state)
            else
                self.parser.isExpiredState(state);
            if (expired) any_expired = true else any_alive = true;
        }
        if (any_expired and (any_alive or self.parser.tmp_accept_stop_token)) {
            var write: usize = 0;
            for (self.parser.tmp_states_to_be_added.items) |state| {
                const expired = if (use_char_budget)
                    self.parser.isCharExpiredState(state)
                else
                    self.parser.isExpiredState(state);
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
                var restore_row = try previous_row.dupe(self.allocator);
                defer restore_row.deinit(self.allocator);
                restore_row.completed = self.parser.isRootCompleted();
                try self.parser.replaceLatestRow(restore_row);
            }
            return false;
        }
        var latest = try self.parser.latestRow(self.allocator);
        defer latest.deinit(self.allocator);
        latest.states.clearRetainingCapacity();
        try latest.states.appendSlice(self.allocator, self.parser.tmp_states_to_be_added.items);
        self.parser.tmp_states_to_be_added.clearRetainingCapacity();
        latest.completed = self.parser.tmp_accept_stop_token;
        try self.parser.replaceLatestRow(latest);
        return true;
    }

    fn applyBudgetEnforcement(self: *GrammarMatcher) Allocator.Error!bool {
        return self.applyBudgetEnforcementImpl(false);
    }

    fn applyCharacterBudgetEnforcementToFixedPoint(self: *GrammarMatcher) Allocator.Error!bool {
        var applied_any = false;
        var iter: usize = 0;
        while (iter <= self.parser.grammar.numRules()) : (iter += 1) {
            const has_expired = self.hasCharExpiredState();
            if (!has_expired or !try self.applyBudgetEnforcementImpl(true)) {
                return applied_any;
            }
            applied_any = true;
        }
        return applied_any;
    }

    fn hasCharExpiredState(self: *const GrammarMatcher) bool {
        for (self.parser.scanable_state_history.back()) |state| {
            if (self.parser.isCharExpiredState(state)) return true;
        }
        return false;
    }

    fn advanceWithCharacterBudget(self: *GrammarMatcher, byte: u8) Allocator.Error!bool {
        if (!self.parser.has_char_budget_rules or !EarleyParser.startsUtf8Codepoint(byte)) {
            return self.parser.advance(byte);
        }
        if (!self.hasCharExpiredState()) {
            return self.parser.advance(byte);
        }
        var snapshot = try self.parser.latestRow(self.allocator);
        defer snapshot.deinit(self.allocator);
        const enforced = try self.applyCharacterBudgetEnforcementToFixedPoint();
        if (!enforced and self.record_char_budget_relaxation) {
            self.char_budget_relaxed = true;
        }
        const accepted = try self.parser.advance(byte);
        if (!accepted and enforced) {
            try self.parser.replaceLatestRow(snapshot);
        }
        return accepted;
    }

    fn advanceAtomicTokenWithCharacterBudget(
        self: *GrammarMatcher,
        token_id: i32,
        token_char_count: i32,
    ) Allocator.Error!bool {
        var has_expired_state = false;
        var crosses_budget = false;
        if (self.parser.has_char_budget_rules and token_char_count > 0) {
            const current_char_index = self.parser.currentCharIndex();
            for (self.parser.scanable_state_history.back()) |state| {
                has_expired_state = has_expired_state or self.parser.isCharExpiredState(state);
                crosses_budget = crosses_budget or
                    (state.char_budget_deadline >= 0 and current_char_index + token_char_count > state.char_budget_deadline);
            }
        }
        var snapshot: ?ParserRow = null;
        defer if (snapshot) |*s| s.deinit(self.allocator);
        var enforced = false;
        if (has_expired_state) {
            snapshot = try self.parser.latestRow(self.allocator);
            enforced = try self.applyCharacterBudgetEnforcementToFixedPoint();
            if (!enforced and self.record_char_budget_relaxation) {
                self.char_budget_relaxed = true;
            }
        }
        const accepted = try self.parser.advanceAtomicToken(token_id, token_char_count);
        if (!accepted and enforced) {
            try self.parser.replaceLatestRow(snapshot.?);
        }
        if (accepted and crosses_budget and self.record_char_budget_relaxation) {
            self.char_budget_relaxed = true;
        }
        return accepted;
    }

    inline fn advanceByte(self: *GrammarMatcher, byte: u8) Allocator.Error!bool {
        if (self.parser.has_char_budget_rules) {
            return self.advanceWithCharacterBudget(byte);
        }
        return self.parser.advance(byte);
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
                log.warn(
                    "Multiple active grammar paths specify different temperatures. Using the maximum temperature {d}.",
                    .{syntax_temperature orelse 0.0},
                );
            }
        }
        return syntax_temperature orelse self.default_temperature;
    }

    /// Accepts one token and updates the state of the matcher.
    pub fn acceptToken(self: *GrammarMatcher, token_id: u32, diag: ?*Diagnostic) MatcherError!bool {
        if (self.isStopTokenAccepted()) {
            log.warn(
                "The matcher has terminated after accepting the stop token, but is trying to accept new token with id {d}.",
                .{token_id},
            );
            return false;
        }
        const tok = self.tokenizerInfo();
        const vocab_size = tok.vocabSize();
        if (@as(usize, token_id) >= vocab_size) {
            log.warn("The token id {d} is out of range [0, {d}). Rejecting the token.", .{ token_id, vocab_size });
            return false;
        }
        const is_stop_token = std.mem.indexOfScalar(u32, self.stop_token_ids, token_id) != null;
        if (!is_stop_token and std.mem.indexOfScalar(u32, tok.specialTokenIds(), token_id) != null) {
            const tid_u: usize = @intCast(token_id);
            const decoded_vocab = tok.decodedVocab();
            const decoded = if (tid_u < decoded_vocab.len) decoded_vocab[tid_u] else "<padding>";
            log.warn("GrammarMatcher cannot accept special token id {d}: {s}. Rejecting the token.", .{ token_id, decoded });
            return false;
        }

        self.parser.current_token_index = @intCast(self.token_length_history.items.len);
        self.char_budget_relaxed = false;
        self.record_char_budget_relaxation = false;
        const enforce_budget = self.budget_enforce_pending;
        const force_budget_close = self.budget_force_close_pending;
        if (force_budget_close) {
            var trial = try self.fork();
            defer trial.deinit();
            trial.parser.capture_recording = false;
            if (!try trial.applyBudgetEnforcement()) {
                return false;
            }
            trial.budget_enforce_pending = false;
            trial.budget_force_close_pending = false;
            if (!try trial.acceptToken(token_id, diag)) {
                return false;
            }
        }

        self.parser.capture_recording = self.parser.capture_tracking;
        const accepted = try self.acceptTokenDefinitive(token_id, is_stop_token, enforce_budget, force_budget_close);
        self.parser.capture_recording = false;
        self.parser.skip_expired_states = false;
        return accepted;
    }

    fn hasTokenEdgeInLatestStates(self: *const GrammarMatcher) bool {
        const g = self.parser.grammar;
        for (self.parser.latestScanableStates()) |st| {
            const wse = g.perRuleFsm(st.rule_id) orelse continue;
            for (wse.stateEdges(st.element_id)) |edge| {
                if (edge.isExcludeToken() or edge.isToken()) return true;
            }
        }
        return false;
    }

    fn acceptTokenDefinitive(
        self: *GrammarMatcher,
        token_id: u32,
        is_stop_token: bool,
        enforce_budget: bool,
        force_budget_close: bool,
    ) Allocator.Error!bool {
        if (force_budget_close) {
            if (!try self.applyBudgetEnforcement()) {
                return false;
            }
            self.budget_enforce_pending = false;
            self.budget_force_close_pending = false;
        }
        self.parser.skip_expired_states = enforce_budget and !force_budget_close;

        const consumed_past_deadline = self.parser.has_budget_rules and !enforce_budget and blk: {
            for (self.parser.scanable_state_history.back()) |state| {
                if (self.parser.isExpiredState(state)) break :blk true;
            }
            break :blk false;
        };

        // #710: Only short-circuit as EOS termination when the root grammar can end here
        // (or terminate_without_stop_token is set). Otherwise fall through so stop tokens
        // that complete or advance the grammar itself are matched normally.
        if (is_stop_token and (self.parser.isRootCompleted() or self.terminate_without_stop_token)) {
            const ok = try self.acceptStopToken();
            return ok and self.finishAccept(consumed_past_deadline);
        }

        const tid_i32: i32 = @intCast(token_id);
        const token = self.tokenizerInfo().decodedVocab()[@intCast(token_id)];
        const has_char_budget_rules = self.parser.has_char_budget_rules;
        var token_char_count: i32 = 0;
        if (has_char_budget_rules) {
            for (token) |byte| {
                if (EarleyParser.startsUtf8Codepoint(byte)) token_char_count += 1;
            }
        }
        const size_before_token: i32 = @intCast(self.parser.rule_id_to_completable_states.len());
        var row_before_token: ?ParserRow = if (has_char_budget_rules) try self.parser.latestRow(self.allocator) else null;
        defer if (row_before_token) |*r| r.deinit(self.allocator);

        // Phase 1: atomic token path.
        const atomic_success = if (has_char_budget_rules)
            try self.advanceAtomicTokenWithCharacterBudget(tid_i32, token_char_count)
        else
            try self.parser.advanceAtomicToken(tid_i32, 0);

        var atomic_row: ?ParserRow = null;
        defer if (atomic_row) |*r| r.deinit(self.allocator);
        if (atomic_success) {
            atomic_row = try self.parser.latestRow(self.allocator);
            self.parser.popLastStates(1);
        }
        if (row_before_token) |snap| {
            try self.parser.replaceLatestRow(snap);
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
            if (!try self.advanceByte(byte)) {
                // #942: Token began matching a literal and entered a token-level free-text region.
                if (pos > 0 and self.hasTokenEdgeInLatestStates()) {
                    const saved_relax = self.record_char_budget_relaxation;
                    self.record_char_budget_relaxation = false;
                    const mid_ok = if (has_char_budget_rules)
                        try self.advanceAtomicTokenWithCharacterBudget(tid_i32, token_char_count)
                    else
                        try self.parser.advanceAtomicToken(tid_i32, 0);
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
            self.parser.popLastStates(pos);
            if (row_before_token) |snap| {
                try self.parser.replaceLatestRow(snap);
            }
            self.record_char_budget_relaxation = false;
            self.char_budget_relaxed = false;
            return false;
        }
        if (atomic_success and !byte_path_success) {
            self.parser.popLastStates(pos);
            if (row_before_token) |snap| {
                try self.parser.replaceLatestRow(snap);
            }
            self.char_budget_relaxed = false;
            const accepted = if (has_char_budget_rules)
                try self.advanceAtomicTokenWithCharacterBudget(tid_i32, token_char_count)
            else
                try self.parser.advanceAtomicToken(tid_i32, 0);
            std.debug.assert(accepted);
            try self.token_length_history.append(self.allocator, 1);
            if (self.shouldTrackAcceptedBytes()) {
                try self.appendAtomicRow(token);
            }
        } else if (byte_path_success and !atomic_success) {
            try self.token_length_history.append(self.allocator, pos);
            if (self.shouldTrackAcceptedBytes()) {
                if (mid_token_atomic) {
                    const split: usize = @intCast(pos - 1);
                    try self.appendPerByteRows(token[0..split]);
                    try self.appendAtomicRow(token[split..]);
                } else {
                    try self.appendPerByteRows(token);
                }
            }
        } else {
            const arow = &atomic_row.?;
            if (token.len == 0) {
                const char_index = self.parser.currentCharIndex();
                const entered = self.parser.hasEnteredCharBudget();
                _ = try self.parser.scanable_state_history.pushRow(self.parser.gpa, arow.states.items);
                _ = try self.parser.rule_id_to_completable_states.pushRow(self.parser.gpa, arow.completable_states.items);
                try self.parser.is_completed.append(self.parser.gpa, arow.completed);
                try self.parser.pushCaptureRow(arow.capture_events.items);
                try self.parser.pushCharCountRow(char_index, entered);
                try self.token_length_history.append(self.allocator, 1);
                if (self.shouldTrackAcceptedBytes()) {
                    try self.appendAtomicRow(token);
                }
            } else {
                try self.mergeAtomicRowIntoBytePath(size_before_token, arow);
                try self.token_length_history.append(self.allocator, pos);
                if (self.shouldTrackAcceptedBytes()) {
                    if (mid_token_atomic) {
                        const split: usize = @intCast(pos - 1);
                        try self.appendPerByteRows(token[0..split]);
                        try self.appendAtomicRow(token[split..]);
                    } else {
                        try self.appendPerByteRows(token);
                    }
                }
            }
        }

        if (has_char_budget_rules) {
            _ = try self.applyCharacterBudgetEnforcementToFixedPoint();
        }
        self.record_char_budget_relaxation = false;
        const ok = self.finishAccept(consumed_past_deadline);
        if (ok and is_stop_token and self.parser.isRootCompleted() and !self.terminate_without_stop_token) {
            self.parser.stop_token_is_accepted = true;
        }
        return ok;
    }

    fn mergeAtomicRowIntoBytePath(
        self: *GrammarMatcher,
        size_before_token: i32,
        atomic_row: *const ParserRow,
    ) Allocator.Error!void {
        const a = self.allocator;
        var merged: std.ArrayList(ParserState) = .empty;
        defer merged.deinit(a);
        try merged.appendSlice(a, self.parser.latestScanableStates());
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

        var merged_completable: std.ArrayList(CompletableState) = .empty;
        defer merged_completable.deinit(a);
        try merged_completable.appendSlice(a, self.parser.latestCompletableStates());

        var merged_capture_row = try self.parser.copyLastCaptureRow(a);
        defer {
            for (merged_capture_row.items) |*ev| ev.deinit(a);
            merged_capture_row.deinit(a);
        }

        const byte_completed = self.parser.isRootCompleted();
        const final_char_index = self.parser.currentCharIndex();
        const final_char_budget_entered = self.parser.hasEnteredCharBudget();
        self.parser.popLastStates(1);

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
            var event = try src_event.dupe(a);
            errdefer event.deinit(a);
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
                event.deinit(a);
            } else {
                try merged_capture_row.append(a, event);
            }
        }

        _ = try self.parser.scanable_state_history.pushRow(self.parser.gpa, merged.items);
        _ = try self.parser.rule_id_to_completable_states.pushRow(self.parser.gpa, merged_completable.items);
        try self.parser.is_completed.append(self.parser.gpa, byte_completed or atomic_row.completed);
        try self.parser.pushCaptureRow(merged_capture_row.items);
        try self.parser.pushCharCountRow(final_char_index, final_char_budget_entered);
    }

    /// Accepts raw bytes / a UTF-8 string and updates the matcher state. On rejection the state is unchanged.
    pub fn acceptString(self: *GrammarMatcher, bytes: []const u8, diag: ?*Diagnostic) MatcherError!bool {
        _ = diag;
        if (self.isStopTokenAccepted()) {
            const escaped = escapeBytes(self.allocator, bytes) catch bytes;
            defer if (escaped.ptr != bytes.ptr) self.allocator.free(escaped);
            log.warn(
                "The matcher has terminated after accepting the stop token, but is trying to accept new string \"{s}\".",
                .{escaped},
            );
            return false;
        }
        self.parser.current_token_index = @intCast(self.token_length_history.items.len);
        self.char_budget_relaxed = false;
        self.record_char_budget_relaxation = true;
        self.parser.capture_recording = self.parser.capture_tracking;
        const accepted = try self.acceptBytesDefinitive(bytes);
        self.parser.capture_recording = false;
        return accepted;
    }

    fn acceptBytesDefinitive(self: *GrammarMatcher, input: []const u8) Allocator.Error!bool {
        const has_char_budget_rules = self.parser.has_char_budget_rules;
        var row_before_input: ?ParserRow = if (has_char_budget_rules) try self.parser.latestRow(self.allocator) else null;
        defer if (row_before_input) |*r| r.deinit(self.allocator);
        const track_temporary_input = has_char_budget_rules and self.has_budget_marker_rules;
        if (track_temporary_input) {
            self.temporary_input_start_row = @as(i32, @intCast(self.parser.scanable_state_history.len())) - 1;
            self.temporary_input_bytes.clearRetainingCapacity();
        }
        for (input, 0..) |byte, accepted_cnt| {
            if (!try self.advanceByte(byte)) {
                self.parser.popLastStates(@intCast(accepted_cnt));
                if (row_before_input) |snap| {
                    try self.parser.replaceLatestRow(snap);
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
        if (self.shouldTrackAcceptedBytes()) {
            try self.appendPerByteRows(input);
        }
        if (has_char_budget_rules and input.len != 0) {
            _ = try self.applyCharacterBudgetEnforcementToFixedPoint();
        }
        if (track_temporary_input) {
            self.temporary_input_start_row = -1;
            self.temporary_input_bytes.clearRetainingCapacity();
        }
        self.record_char_budget_relaxation = false;
        self.finishCharacterBudgetAccept();
        return true;
    }

    /// Fills row `row_index` of `bitmask`. Returns whether the mask has at least one rejected token.
    pub fn fillNextTokenBitmask(
        self: *GrammarMatcher,
        bitmask: *TokenBitmask,
        row_index: usize,
        diag: ?*Diagnostic,
    ) MatcherError!bool {
        return self.fillNextTokenBitmaskView(bitmask.view(), row_index, diag);
    }

    /// Fills row `row_index` of borrowed `view`. Returns whether the mask has at least one rejected token.
    pub fn fillNextTokenBitmaskView(
        self: *GrammarMatcher,
        view: TokenBitmaskView,
        row_index: usize,
        diag: ?*Diagnostic,
    ) MatcherError!bool {
        if (self.isStopTokenAccepted()) {
            if (diag) |d| d.setStatic(.matcher_terminated, "find the next token mask");
            return error.Terminated;
        }
        const vocab_size = self.tokenizerInfo().vocabSize();
        if (view.vocab_size != vocab_size) {
            if (diag) |d| try d.setFmt(
                self.allocator,
                .message,
                "The provided bitmask vocab_size ({d}) does not match tokenizer vocab_size ({d})",
                .{ view.vocab_size, vocab_size },
            );
            return error.InvalidArgument;
        }
        const range = try view.rowRangeDiag(self.allocator, row_index, diag);
        return self.fillNextTokenBitmaskImpl(view.words[range.start..range.end]);
    }

    /// Fills row `index` of raw `bitmask` buffer of `shape`. Returns whether the mask needs to be applied.
    pub fn fillNextTokenBitmaskRaw(
        self: *GrammarMatcher,
        bitmask: []i32,
        shape: []const i64,
        index: usize,
        diag: ?*Diagnostic,
    ) MatcherError!bool {
        if (self.isStopTokenAccepted()) {
            if (diag) |d| d.setStatic(.matcher_terminated, "find the next token mask");
            return error.Terminated;
        }
        const vocab_size = self.tokenizerInfo().vocabSize();
        const range = try bitmaskRowRange(self.allocator, shape, vocab_size, index, diag);
        if (range.end > bitmask.len) {
            if (diag) |d| d.setStatic(.message, "The provided bitmask buffer is smaller than its shape");
            return error.InvalidArgument;
        }
        return self.fillNextTokenBitmaskImpl(bitmask[range.start..range.end]);
    }

    pub fn fillNextTokenBitmaskImpl(
        self: *GrammarMatcher,
        row_words: []i32,
    ) Allocator.Error!bool {
        const vocab_size = self.tokenizerInfo().vocabSize();
        self.parser.current_token_index = @intCast(self.token_length_history.items.len);

        if (self.parser.has_budget_rules) {
            var any_expired = false;
            var any_alive = false;
            var can_force_close_without_marker = false;
            for (self.parser.latestScanableStates()) |state| {
                if (self.parser.isExpiredState(state)) {
                    any_expired = true;
                    if (!can_force_close_without_marker and self.has_budget_marker_rules) {
                        can_force_close_without_marker = try self.canForceCompleteWithoutMarker(state, false);
                    }
                } else {
                    any_alive = true;
                }
            }
            if (can_force_close_without_marker) {
                var trial = try self.fork();
                defer trial.deinit();
                trial.parser.capture_recording = false;
                const applied = try trial.applyBudgetEnforcement();
                if (applied) {
                    try trial.fillBitmaskForStates(row_words, false);
                }
                if (applied and (trial.parser.isRootCompleted() or rowHasAnyToken(row_words, vocab_size))) {
                    self.budget_enforce_pending = true;
                    self.budget_force_close_pending = true;
                    return !rowAllTrue(row_words, vocab_size);
                }
            }
            if (any_expired and (any_alive or self.parser.isRootCompleted())) {
                try self.fillBitmaskForStates(row_words, true);
                if (rowHasAnyToken(row_words, vocab_size) or self.parser.isRootCompleted()) {
                    self.budget_enforce_pending = true;
                    self.budget_force_close_pending = false;
                    return !rowAllTrue(row_words, vocab_size);
                }
            }
            self.budget_enforce_pending = false;
            self.budget_force_close_pending = false;
        }
        try self.fillBitmaskForStates(row_words, false);
        return !rowAllTrue(row_words, vocab_size);
    }

    fn fillBitmaskForCharBudgetBoundary(
        self: *GrammarMatcher,
        row_words: []i32,
        adaptive_token_mask: *const AdaptiveTokenMask,
        remaining_chars: i32,
    ) Allocator.Error!void {
        const a = self.allocator;
        const tok = self.tokenizerInfo();
        const token_char_counts = tok.tokenCharCounts();
        const vocab = tok.sortedDecodedVocab();

        var tokens_to_check: std.ArrayList(i32) = .empty;
        defer tokens_to_check.deinit(a);
        try tokens_to_check.appendSlice(a, adaptive_token_mask.uncertain_indices);

        switch (adaptive_token_mask.storage) {
            .accepted => |indices| {
                for (indices) |index| {
                    if (token_char_counts[@intCast(index)] <= remaining_chars) {
                        setBit(row_words, vocab[@intCast(index)].id, true);
                    } else {
                        try tokens_to_check.append(a, index);
                    }
                }
            },
            .accepted_bitset => |bs| {
                for (vocab, 0..) |entry, index| {
                    if (!bs.get(@intCast(entry.id))) continue;
                    if (token_char_counts[index] <= remaining_chars) {
                        setBit(row_words, entry.id, true);
                    } else {
                        try tokens_to_check.append(a, @intCast(index));
                    }
                }
            },
            .rejected => |rejected_indices| {
                var blocked: std.ArrayList(i32) = .empty;
                defer blocked.deinit(a);
                try blocked.appendSlice(a, rejected_indices);
                try blocked.appendSlice(a, adaptive_token_mask.uncertain_indices);
                std.mem.sortUnstable(i32, blocked.items, {}, std.sort.asc(i32));
                for (vocab, 0..) |entry, idx_u| {
                    const index: i32 = @intCast(idx_u);
                    if (token_char_counts[idx_u] <= remaining_chars) {
                        if (!binarySearchI32(blocked.items, index)) {
                            setBit(row_words, entry.id, true);
                        }
                    } else if (!binarySearchI32(rejected_indices, index)) {
                        try tokens_to_check.append(a, index);
                    }
                }
            },
        }
        sortAndDedupI32(&tokens_to_check);

        const saved_temporary_input_start_row = self.temporary_input_start_row;
        const saved_temporary_input_bytes = self.temporary_input_bytes;
        self.temporary_input_bytes = .empty;
        defer {
            self.temporary_input_bytes.deinit(a);
            self.temporary_input_bytes = saved_temporary_input_bytes;
            self.temporary_input_start_row = saved_temporary_input_start_row;
        }

        const all_latest_states = try a.dupe(ParserState, self.parser.latestScanableStates());
        defer a.free(all_latest_states);
        const all_latest_completed = self.parser.isRootCompleted();

        try self.parser.pushStatesToCheck(all_latest_states, all_latest_completed);
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
                @min(commonPrefixLen(vocab[prev].token, token), previous_matched_size)
            else
                0;
            self.parser.popLastStates(
                @as(i32, @intCast(self.parser.scanable_state_history.len())) - initial_state_history_size - common_prefix_length,
            );
            self.temporary_input_bytes.shrinkRetainingCapacity(@intCast(common_prefix_length));

            var accepted = token.len != 0;
            var matched_size = common_prefix_length;
            while (@as(usize, @intCast(matched_size)) < token.len) {
                const byte = token[@intCast(matched_size)];
                if (!try self.advanceWithCharacterBudget(byte)) {
                    accepted = false;
                    break;
                }
                try self.temporary_input_bytes.append(a, byte);
                matched_size += 1;
            }
            if (accepted) {
                setBit(row_words, vocab[u_idx].id, true);
            } else {
                try byte_rejected_tokens.append(a, index);
            }
            previous_index = u_idx;
            previous_matched_size = matched_size;
        }
        self.parser.popLastStates(
            @as(i32, @intCast(self.parser.scanable_state_history.len())) - initial_state_history_size + 1,
        );

        for (byte_rejected_tokens.items) |index| {
            try self.parser.pushStatesToCheck(all_latest_states, all_latest_completed);
            self.temporary_input_start_row = @as(i32, @intCast(self.parser.scanable_state_history.len())) - 1;
            self.temporary_input_bytes.clearRetainingCapacity();
            const entry = vocab[@intCast(index)];
            if (try self.advanceAtomicTokenWithCharacterBudget(entry.id, token_char_counts[@intCast(index)])) {
                setBit(row_words, entry.id, true);
                self.parser.popLastStates(1);
            }
            self.parser.popLastStates(1);
        }
    }

    /// Computes `tmp_rejected_indices_delta = tmp_rejected_indices_delta ∪ rhs` reusing scratch
    /// capacity so repeat calls after warmup perform zero heap allocations.
    fn unionRejectedDeltaWith(self: *GrammarMatcher, rhs: []const i32) Allocator.Error!void {
        const a = self.allocator;
        const lhs = self.tmp_rejected_indices_delta.items;
        if (rhs.len == 0) return;
        if (lhs.len == 0) {
            try self.tmp_rejected_indices_delta.appendSlice(a, rhs);
            return;
        }
        self.tmp_intset_scratch.clearRetainingCapacity();
        try self.tmp_intset_scratch.ensureTotalCapacity(a, lhs.len + rhs.len);
        var i: usize = 0;
        var j: usize = 0;
        while (i < lhs.len and j < rhs.len) {
            if (lhs[i] < rhs[j]) {
                self.tmp_intset_scratch.appendAssumeCapacity(lhs[i]);
                i += 1;
            } else if (lhs[i] > rhs[j]) {
                self.tmp_intset_scratch.appendAssumeCapacity(rhs[j]);
                j += 1;
            } else {
                self.tmp_intset_scratch.appendAssumeCapacity(lhs[i]);
                i += 1;
                j += 1;
            }
        }
        self.tmp_intset_scratch.appendSliceAssumeCapacity(lhs[i..]);
        self.tmp_intset_scratch.appendSliceAssumeCapacity(rhs[j..]);
        self.tmp_rejected_indices_delta.clearRetainingCapacity();
        try self.tmp_rejected_indices_delta.appendSlice(a, self.tmp_intset_scratch.items);
    }

    fn fillBitmaskForStates(
        self: *GrammarMatcher,
        row_words: []i32,
        skip_expired: bool,
    ) Allocator.Error!void {
        const a = self.allocator;
        const tok = self.tokenizerInfo();
        const sorted_decoded_vocab = tok.sortedDecodedVocab();
        const subtree_range = tok.trieSubtreeNodesRange();
        const token_char_counts = tok.tokenCharCounts();
        const cache = self.compiled_grammar.adaptiveTokenMaskCache();
        const has_char_budget_rules = self.parser.has_char_budget_rules;

        self.tmp_latest_states.clearRetainingCapacity();
        for (self.parser.scanable_state_history.back()) |state| {
            if (!(skip_expired and self.parser.isExpiredState(state))) {
                try self.tmp_latest_states.append(a, state);
            }
        }

        @memset(row_words, 0);
        self.tmp_rejected_indices.clearRetainingCapacity();
        try self.tmp_rejected_indices.append(a, -1);

        self.tmp_states_with_masks.clearRetainingCapacity();

        for (self.tmp_latest_states.items) |state| {
            const adaptive_token_mask = cache.get(state.cacheKey()) orelse unreachable;
            if (state.char_budget_deadline >= 0) {
                const remaining_chars = state.char_budget_deadline - self.parser.currentCharIndex();
                if (remaining_chars <= tok.maxTokenChars()) {
                    try self.fillBitmaskForCharBudgetBoundary(row_words, adaptive_token_mask, @max(remaining_chars, 0));
                    continue;
                }
            }
            try self.tmp_states_with_masks.append(a, .{ .state = state, .mask = adaptive_token_mask });
            switch (adaptive_token_mask.storage) {
                .accepted_bitset => |bs| {
                    for (row_words, bs.asWords()) |*word, bits| {
                        word.* |= @as(i32, @bitCast(bits));
                    }
                },
                .accepted => |indices| {
                    for (indices) |index| {
                        setBit(row_words, sorted_decoded_vocab[@intCast(index)].id, true);
                    }
                },
                .rejected => {},
            }
        }

        for (self.tmp_states_with_masks.items) |pair| {
            const state = pair.state;
            const adaptive_token_mask = pair.mask;
            self.tmp_rejected_indices_delta.clearRetainingCapacity();
            try self.parser.pushOneStateToCheck(state);
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
                if (getBit(row_words, sorted_decoded_vocab[cur_u].id)) {
                    continue;
                }
                if (cur_token_idx < last_rejected_uncertain_range) {
                    if (adaptive_token_mask.storeType() == .rejected) {
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
                    const lcp_len = commonPrefixLen(cur_token, prev);
                    if (lcp_len > prev_matched_size) {
                        last_rejected_uncertain_range = subtree_range[cur_u];
                        accepted = false;
                    } else if (lcp_len < prev_matched_size) {
                        self.parser.popLastStates(prev_matched_size - lcp_len);
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
                        if (!try self.advanceByte(byte)) {
                            // #942: Allow transitioning mid-token from literal into a token-level free-text region.
                            if (prev_matched_size > 0 and self.hasTokenEdgeInLatestStates()) {
                                const saved_cap = self.parser.capture_recording;
                                const saved_relax = self.record_char_budget_relaxation;
                                self.parser.capture_recording = false;
                                self.record_char_budget_relaxation = false;
                                const mid_ok = if (has_char_budget_rules)
                                    try self.advanceAtomicTokenWithCharacterBudget(
                                        sorted_decoded_vocab[cur_u].id,
                                        token_char_counts[cur_u],
                                    )
                                else
                                    try self.parser.advanceAtomicToken(sorted_decoded_vocab[cur_u].id, 0);
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
                    self.parser.popLastStates(prev_matched_size + 1);
                    if (track_temporary_input) {
                        self.temporary_input_bytes.clearRetainingCapacity();
                    }
                    try self.parser.pushOneStateToCheck(state);
                    const saved_capture_recording = self.parser.capture_recording;
                    const saved_record_relaxation = self.record_char_budget_relaxation;
                    self.parser.capture_recording = false;
                    self.record_char_budget_relaxation = false;
                    accepted = try self.advanceAtomicTokenWithCharacterBudget(
                        sorted_decoded_vocab[cur_u].id,
                        token_char_counts[cur_u],
                    );
                    self.parser.capture_recording = saved_capture_recording;
                    self.record_char_budget_relaxation = saved_record_relaxation;
                    self.parser.popLastStates(if (accepted) 2 else 1);
                    try self.parser.pushOneStateToCheck(state);
                    prev_matched_size = 0;
                    if (accepted) {
                        last_rejected_uncertain_range = cur_token_idx + 1;
                    }
                }

                switch (adaptive_token_mask.storage) {
                    .accepted_bitset, .accepted => {
                        if (accepted) setBit(row_words, sorted_decoded_vocab[cur_u].id, true);
                    },
                    .rejected => {
                        if (!accepted) try self.tmp_rejected_indices_delta.append(a, cur_token_idx);
                    },
                }
                prev_token = if (retried_atomically) null else cur_token;
            }

            self.parser.popLastStates(prev_matched_size + 1);
            switch (adaptive_token_mask.storage) {
                .rejected => |rejected_indices| {
                    try self.unionRejectedDeltaWith(rejected_indices);
                    try intsetIntersection(a, &self.tmp_rejected_indices, self.tmp_rejected_indices_delta.items);
                },
                else => {},
            }
        }

        const can_reach_end = self.parser.isRootCompleted();
        try self.setTokenBitmask(row_words, can_reach_end, false);
    }

    fn setTokenBitmask(
        self: *GrammarMatcher,
        row_words: []i32,
        can_reach_end: bool,
        allow_special_token: bool,
    ) Allocator.Error!void {
        const tok = self.tokenizerInfo();
        const sorted_decoded_vocab = tok.sortedDecodedVocab();
        if (self.tmp_rejected_indices.items.len == 1 and self.tmp_rejected_indices.items[0] == -1) {
            if (allow_special_token) {
                for (tok.specialTokenIds()) |id| {
                    setBit(row_words, @intCast(id), true);
                }
            }
        } else {
            self.tmp_rejected_indices_delta.clearRetainingCapacity();
            for (self.tmp_rejected_indices.items) |index| {
                const token_id = sorted_decoded_vocab[@intCast(index)].id;
                if (!getBit(row_words, token_id)) {
                    try self.tmp_rejected_indices_delta.append(self.allocator, token_id);
                }
            }
            @memset(row_words, -1);
            for (self.tmp_rejected_indices_delta.items) |token_id| {
                setBit(row_words, token_id, false);
            }
            if (!allow_special_token) {
                for (tok.specialTokenIds()) |id| {
                    setBit(row_words, @intCast(id), false);
                }
            }
        }
        // #710: Allow a stop token if the root is already complete OR if matching the stop token itself completes the grammar.
        for (self.stop_token_ids) |id| {
            const allow_stop = if (can_reach_end) true else try self.doesStopTokenCompleteGrammar(id);
            setBit(row_words, @intCast(id), allow_stop);
        }
    }

    fn doesStopTokenCompleteGrammar(self: *GrammarMatcher, token_id: u32) Allocator.Error!bool {
        if (self.parser.isRootCompleted()) return true;
        const tok = self.tokenizerInfo();
        const tid_u: usize = @intCast(token_id);
        if (tid_u >= tok.vocabSize()) return false;
        const decoded_vocab = tok.decodedVocab();
        const token = if (tid_u < decoded_vocab.len) decoded_vocab[tid_u] else "";

        const has_char_budget = self.parser.has_char_budget_rules;
        var row_before: ?ParserRow = if (has_char_budget) try self.parser.latestRow(self.allocator) else null;
        defer if (row_before) |*r| r.deinit(self.allocator);
        const saved_relax = self.record_char_budget_relaxation;
        const saved_relaxed = self.char_budget_relaxed;
        self.record_char_budget_relaxation = false;
        defer {
            self.record_char_budget_relaxation = saved_relax;
            self.char_budget_relaxed = saved_relaxed;
        }

        // Check atomic token transition (supports Token edges matching special stop tokens too).
        const atomic_ok = try self.parser.advanceAtomicToken(@intCast(token_id), 0);
        if (atomic_ok) {
            const completed = self.parser.isRootCompleted();
            self.parser.popLastStates(1);
            if (row_before) |snap| try self.parser.replaceLatestRow(snap);
            if (completed) return true;
        }

        if (token.len == 0) return false;
        var pos: i32 = 0;
        var byte_ok = true;
        for (token) |byte| {
            if (!try self.advanceByte(byte)) {
                byte_ok = false;
                break;
            }
            pos += 1;
        }
        const completed_by_bytes = byte_ok and self.parser.isRootCompleted();
        self.parser.popLastStates(pos);
        if (row_before) |snap| try self.parser.replaceLatestRow(snap);
        return completed_by_bytes;
    }

    /// Finds the longest jump-forward byte sequence valid from the current state (caller owns slice).
    pub fn findJumpForwardString(
        self: *GrammarMatcher,
        allocator: Allocator,
        diag: ?*Diagnostic,
    ) MatcherError![]u8 {
        if (self.isStopTokenAccepted()) {
            if (diag) |d| d.setStatic(.matcher_terminated, "get the jump forward string");
            return error.Terminated;
        }
        self.parser.current_token_index = @intCast(self.token_length_history.items.len);
        if (self.budget_force_close_pending) {
            var trial = try self.fork();
            defer trial.deinit();
            trial.parser.capture_recording = false;
            if (try trial.applyBudgetEnforcement()) {
                trial.budget_enforce_pending = false;
                trial.budget_force_close_pending = false;
                return trial.findJumpForwardString(allocator, diag);
            }
        }

        const g = self.parser.grammar;
        var result: std.ArrayList(u8) = .empty;
        errdefer result.deinit(allocator);
        var num_accepted_chars: i32 = 0;
        while (true) {
            if (self.parser.isRootCompleted()) break;
            const states = self.parser.latestScanableStates();
            var next_char: i32 = -1;
            var can_find_next_char = true;
            for (states) |state| {
                if (self.budget_enforce_pending and self.parser.isExpiredState(state)) {
                    continue;
                }
                const fsm = g.perRuleFsm(state.rule_id).?;
                for (fsm.stateEdges(state.element_id)) |edge| {
                    if (!edge.isCharRange()) continue;
                    if (edge.min != edge.max or (next_char != -1 and next_char != edge.min)) {
                        can_find_next_char = false;
                        break;
                    }
                    next_char = edge.min;
                }
            }
            if (next_char == -1 or !can_find_next_char) break;
            const next_byte: u8 = @intCast(next_char);
            if (EarleyParser.startsUtf8Codepoint(next_byte)) {
                var any_char_expired = false;
                for (states) |state| {
                    if (self.parser.isCharExpiredState(state)) {
                        any_char_expired = true;
                        break;
                    }
                }
                if (any_char_expired) break;
            }
            try result.append(allocator, next_byte);
            _ = try self.parser.advance(next_byte);
            num_accepted_chars += 1;
        }
        self.parser.popLastStates(num_accepted_chars);
        // #1012: Keep jump-forward string aligned to complete UTF-8 character boundaries.
        const slice = result.items;
        if (slice.len > 0) {
            if (!EarleyParser.startsUtf8Codepoint(slice[0])) {
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
    pub fn rollback(self: *GrammarMatcher, num_tokens: usize, diag: ?*Diagnostic) MatcherError!void {
        if (num_tokens > self.token_length_history.items.len) {
            if (diag) |d| {
                d.setNumbers(
                    .matcher_rollback_too_far,
                    std.math.cast(i64, num_tokens) orelse std.math.maxInt(i64),
                    std.math.cast(i64, self.token_length_history.items.len) orelse std.math.maxInt(i64),
                );
            }
            return error.RollbackTooFar;
        }
        for (0..num_tokens) |_| {
            const steps = self.token_length_history.pop().?;
            self.parser.popLastStates(steps);
            if (self.shouldTrackAcceptedBytes() and steps > 0) {
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
        self.clearBudgetBodyMatchCache();
    }

    /// Returns the captured spans recorded so far (caller owns slices via `Capture.freeSlice`).
    pub fn getCaptures(self: *const GrammarMatcher, allocator: Allocator, deduplicate: bool) Allocator.Error![]Capture {
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
        const g = self.parser.grammar;

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
                var targets_copy: std.ArrayList(CaptureOccurrence) = .empty;
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
            var last_index: std.AutoHashMapUnmanaged(i64, usize) = .empty;
            defer last_index.deinit(allocator);
            for (events.items, 0..) |event, i| {
                const gop = try last_index.getOrPut(allocator, occurrenceKey(event.rule_id, event.start_row));
                if (gop.found_existing) {
                    keep[gop.value_ptr.*] = false;
                }
                gop.value_ptr.* = i;
            }
        }

        for (events.items, 0..) |*event, i| {
            const hidden_bytes = @max(event.hidden_suffix_bytes, event.hidden_stop_bytes);
            if (!keep[i] or hidden_bytes <= 0) continue;
            const info = g.suffixStopInfo(event.rule_id).?;
            const event_start = self.row_byte_end.items[@intCast(event.start_row)];
            const event_end = self.row_byte_end.items[@intCast(event.end_row)];
            event.marker_present = true;
            if (info.body_rule_id == -1) {
                event.marker_start_byte = @max(event_start, event_end - @as(i64, hidden_bytes));
                continue;
            }
            const body_fsm = &g.perRuleFsm(info.body_rule_id).?.fsm;
            const marker_fsm = &g.perRuleFsm(info.marker_rule_id).?.fsm;
            const body_ends = try self.acceptedPrefixes(allocator, body_fsm, event_start, event_end);
            defer allocator.free(body_ends);
            const marker_starts = try self.acceptedSuffixes(allocator, marker_fsm, event_start, event_end);
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
        var hidden_stop_spans_by_capture: std.AutoHashMapUnmanaged(i64, std.ArrayList(ByteSpan)) = .empty;
        defer {
            var it = hidden_stop_spans_by_capture.valueIterator();
            while (it.next()) |list| list.deinit(allocator);
            hidden_stop_spans_by_capture.deinit(allocator);
        }
        for (events.items, 0..) |event, i| {
            if (!keep[i] or event.hidden_stop_bytes <= 0 or !event.marker_present) continue;
            const event_end = self.row_byte_end.items[@intCast(event.end_row)];
            if (event.marker_start_byte < event_end) {
                for (event.stop_capture_targets.items) |target| {
                    const gop = try hidden_stop_spans_by_capture.getOrPut(
                        allocator,
                        occurrenceKey(target.rule_id, target.start_pos),
                    );
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
            const rule = g.rule(event.rule_id);
            const info = g.suffixStopInfo(event.rule_id);
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
            if (hidden_stop_spans_by_capture.get(occurrenceKey(event.rule_id, event.occurrence_start_pos))) |spans| {
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

    fn acceptedPrefixes(
        self: *const GrammarMatcher,
        allocator: Allocator,
        fsm: *const CompactFsmWithStartEnd,
        begin: i64,
        end: i64,
    ) Allocator.Error![]bool {
        const len: usize = @intCast(end - begin + 1);
        const result = try allocator.alloc(bool, len);
        errdefer allocator.free(result);
        var states = try fsm_mod.stateSetFrom(allocator, &.{fsm.start});
        defer states.deinit();
        const compact = fsm.fsm;
        try compact.epsilonClosure(allocator, &states);
        result[0] = setContainsEnd(&states, fsm);
        var next_states = StateSet.init(allocator);
        defer next_states.deinit();
        var offset: i64 = 0;
        while (offset < end - begin) : (offset += 1) {
            const byte = self.accepted_bytes.items[@intCast(begin + offset)];
            try compact.advanceChar(allocator, &states, byte, &next_states);
            std.mem.swap(StateSet, &states, &next_states);
            result[@intCast(offset + 1)] = setContainsEnd(&states, fsm);
        }
        return result;
    }

    fn acceptedSuffixes(
        self: *const GrammarMatcher,
        allocator: Allocator,
        marker_fsm: *const CompactFsmWithStartEnd,
        begin: i64,
        end: i64,
    ) Allocator.Error![]bool {
        const fsm = marker_fsm.fsm;
        var reachable = try marker_fsm.reachableStates(allocator);
        defer reachable.deinit();
        const num_states: usize = @intCast(fsm.numStates());

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
            for (fsm.stateEdges(source)) |edge| {
                if (!reachable.contains(edge.target)) continue;
                const tgt_u: usize = @intCast(edge.target);
                if (edge.isEpsilon()) {
                    try reverse_epsilon[tgt_u].append(allocator, source);
                } else if (edge.isCharRange()) {
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
        while (s < fsm.numStates()) : (s += 1) {
            if (marker_fsm.isEndState(s)) try states.put(s, {});
        }
        try add_rev_eps(allocator, &states, reverse_epsilon);
        result[length] = states.contains(marker_fsm.start);

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
            result[offset] = states.contains(marker_fsm.start);
        }
        return result;
    }

    fn setContainsEnd(states: *const StateSet, fsm: *const CompactFsmWithStartEnd) bool {
        var it = states.keyIterator();
        while (it.next()) |s| {
            if (fsm.isEndState(s.*)) return true;
        }
        return false;
    }

    /// Traverses a speculative-decoding draft tree and fills one row per node in `bitmask`.
    pub fn traverseDraftTree(
        self: *GrammarMatcher,
        retrieve_next_token: []const i32,
        retrieve_next_sibling: []const i32,
        draft_tokens: []const i32,
        bitmask: *TokenBitmask,
        time_threshold: f64,
        temperatures: ?[]f32,
        diag: ?*Diagnostic,
    ) MatcherError!bool {
        return self.traverseDraftTreeView(
            retrieve_next_token,
            retrieve_next_sibling,
            draft_tokens,
            bitmask.view(),
            time_threshold,
            temperatures,
            diag,
        );
    }

    /// Traverses a speculative-decoding draft tree and fills one row per node in borrowed `view`.
    pub fn traverseDraftTreeView(
        self: *GrammarMatcher,
        retrieve_next_token: []const i32,
        retrieve_next_sibling: []const i32,
        draft_tokens: []const i32,
        view: TokenBitmaskView,
        time_threshold: f64,
        temperatures: ?[]f32,
        diag: ?*Diagnostic,
    ) MatcherError!bool {
        const vocab_size = self.tokenizerInfo().vocabSize();
        if (view.vocab_size != vocab_size) {
            if (diag) |d| try d.setFmt(
                self.allocator,
                .message,
                "The provided bitmask vocab_size ({d}) does not match tokenizer vocab_size ({d})",
                .{ view.vocab_size, vocab_size },
            );
            return error.InvalidArgument;
        }
        return self.traverseDraftTreeRaw(
            retrieve_next_token,
            retrieve_next_sibling,
            draft_tokens,
            view.words,
            time_threshold,
            temperatures,
            diag,
        );
    }

    /// Traverses a speculative-decoding draft tree and fills one row per node in raw `token_bitmask`.
    pub fn traverseDraftTreeRaw(
        self: *GrammarMatcher,
        retrieve_next_token: []const i32,
        retrieve_next_sibling: []const i32,
        draft_tokens: []const i32,
        token_bitmask: []i32,
        time_threshold: f64,
        temperatures: ?[]f32,
        diag: ?*Diagnostic,
    ) MatcherError!bool {
        const a = self.allocator;
        const num_nodes = retrieve_next_token.len;
        if (retrieve_next_sibling.len != num_nodes) {
            if (diag) |d| d.setStatic(.message, "The retrieve_next_token and retrieve_next_sibling tensors must have the same length");
            return error.InvalidArgument;
        }
        if (draft_tokens.len != num_nodes) {
            if (diag) |d| d.setStatic(.message, "The retrieve_next_token and draft_tokens tensors must have the same length");
            return error.InvalidArgument;
        }
        const bitmask_words = bitmaskSize(self.tokenizerInfo().vocabSize());
        if (token_bitmask.len != num_nodes * bitmask_words) {
            if (diag) |d| d.setStatic(.message, "The token_bitmask batch size must match the number of nodes in the tree");
            return error.InvalidArgument;
        }
        if (temperatures) |temps| {
            if (temps.len != num_nodes) {
                if (diag) |d| d.setStatic(.message, "The temperatures size must match the number of nodes in the tree");
                return error.InvalidArgument;
            }
            @memset(temps, -1.0);
        }
        if (num_nodes == 0) {
            if (diag) |d| d.setStatic(.message, "The draft tree must not be empty");
            return error.InvalidArgument;
        }
        if (retrieve_next_sibling[0] != -1) {
            if (diag) |d| d.setStatic(.message, "The root node must not have siblings");
            return error.InvalidArgument;
        }

        const in_degree = try a.alloc(usize, num_nodes);
        defer a.free(in_degree);
        @memset(in_degree, 0);
        for (0..num_nodes) |i| {
            const fields = [2]struct { name: []const u8, val: i32 }{
                .{ .name = "retrieve_next_token", .val = retrieve_next_token[i] },
                .{ .name = "retrieve_next_sibling", .val = retrieve_next_sibling[i] },
            };
            for (fields) |entry| {
                if (entry.val < -1 or entry.val >= @as(i32, @intCast(num_nodes))) {
                    if (diag) |d| {
                        try d.setFmt(
                            a,
                            .message,
                            "{s}[{d}] = {d} is out of bounds: it should be in [-1, {d}).",
                            .{ entry.name, i, entry.val, num_nodes },
                        );
                    }
                    return error.InvalidArgument;
                }
                if (entry.val != -1) {
                    in_degree[@intCast(entry.val)] += 1;
                }
            }
        }
        if (in_degree[0] != 0) {
            if (diag) |d| d.setStatic(.message, "The root node must not be the child or sibling of a node");
            return error.InvalidArgument;
        }
        for (1..num_nodes) |node| {
            if (in_degree[node] > 1) {
                if (diag) |d| {
                    try d.setFmt(
                        a,
                        .message,
                        "Node {d} is the target of {d} retrieve_next_token / retrieve_next_sibling entries; the draft tree must not contain cycles or shared nodes.",
                        .{ node, in_degree[node] },
                    );
                }
                return error.InvalidArgument;
            }
        }

        return self.traverseDraftTreeRecursive(
            0,
            null,
            retrieve_next_token,
            retrieve_next_sibling,
            draft_tokens,
            token_bitmask,
            bitmask_words,
            temperatures,
            time_threshold,
            monotonicNs(),
            diag,
        );
    }

    fn traverseDraftTreeRecursive(
        self: *GrammarMatcher,
        current: usize,
        parent: ?usize,
        retrieve_next_token: []const i32,
        retrieve_next_sibling: []const i32,
        draft_tokens: []const i32,
        token_bitmask: []i32,
        bitmask_words: usize,
        temperatures: ?[]f32,
        time_threshold: f64,
        start_ns: i128,
        diag: ?*Diagnostic,
    ) MatcherError!bool {
        const accepted: bool = if (current == 0)
            true
        else blk: {
            const p = parent.?;
            const token = draft_tokens[current];
            const bit_ok = token >= 0 and @as(usize, @intCast(token)) < bitmask_words * 32 and blk2: {
                const tok_u: usize = @intCast(token);
                const word = token_bitmask[p * bitmask_words + tok_u / 32];
                const bit: u5 = @intCast(tok_u % 32);
                break :blk2 ((@as(u32, @bitCast(word)) & (@as(u32, 1) << bit)) != 0);
            };
            if (bit_ok and time_threshold > 0.0) {
                const elapsed_secs = @as(f64, @floatFromInt(monotonicNs() - start_ns)) / @as(f64, std.time.ns_per_s);
                if (elapsed_secs > time_threshold) return false;
            }
            break :blk bit_ok;
        };

        const row_start = current * bitmask_words;
        const row_end = (current + 1) * bitmask_words;
        const token_accepted = accepted and (current == 0 or blk: {
            const tid = std.math.cast(u32, draft_tokens[current]) orelse break :blk false;
            break :blk try self.acceptToken(tid, diag);
        });

        if (token_accepted and !self.isTerminated()) {
            const batch_rows: i64 = @intCast(token_bitmask.len / bitmask_words);
            const shape = [2]i64{ batch_rows, @intCast(bitmask_words) };
            _ = try self.fillNextTokenBitmaskRaw(token_bitmask, &shape, current, diag);
            if (temperatures) |temps| {
                temps[current] = self.temperature() orelse -1.0;
            }
            const child = retrieve_next_token[current];
            if (child != -1) {
                if (!try self.traverseDraftTreeRecursive(
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
            if (!try self.traverseDraftTreeRecursive(
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

test {
    std.testing.refAllDecls(Capture);
    std.testing.refAllDecls(GrammarMatcher);
}
