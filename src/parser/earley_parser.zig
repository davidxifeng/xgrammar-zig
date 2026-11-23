//! The Earley parser (`earley_parser.rs`).
//!
//! The parser walks the per-rule FSMs of an optimized [`Grammar`]: most live
//! [`ParserState`] values have `rule_id >= 0` and scan FSM byte/token edges. Lookahead
//! assertions use the IR path (`rule_id == -1`) with `sequence_id` pointing at the
//! assertion expression; the parser predicts, scans, and completes those states over the
//! grammar expression tree in the classic Earley three-phase loop.
//!
//! The matcher and the token-mask cache builder extend the parser (they derive from it in
//! the C++), so the fields they drive directly are public.
//!
//! FSM 数据经 `Grammar.complete_fsm` / `Grammar.per_rule_fsms` 字段接入
//! （WaveGrammar 的挂点，见 grammar.zig 注释；Rust `Grammar::fsm_state_offsets` 在此
//! 本地重算，参照 grammar.rs L72）。字段安装前由 comptime 门控
//! `grammar_fsm_installed` 拦下：入口一律 `error.FsmNotInstalled`（解除条件：字段
//! 安装后自动消失，非长期接口）；缺 per-rule FSM 视为逻辑不变量，按 Rust
//! `expect("per-rule FSM")` panic。

const std = @import("std");

const capture_event_mod = @import("capture_event.zig");
const capture_occurrence_mod = @import("capture_occurrence.zig");
const parser_row_mod = @import("parser_row.zig");
const parser_state_mod = @import("parser_state.zig");
const repeat_detector_mod = @import("repeat_detector.zig");
const grammar_mod = @import("../grammar/mod.zig");
const support = @import("../support/mod.zig");
const fsm_mod = @import("../fsm/mod.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const CaptureEvent = capture_event_mod.CaptureEvent;
const CaptureOccurrence = capture_occurrence_mod.CaptureOccurrence;
const Compact2dArray = support.compact_2d_array.Compact2dArray;
const Compact2dArrayError = support.compact_2d_array.Compact2dArrayError;
const CompletableState = parser_row_mod.CompletableState;
const Grammar = grammar_mod.Grammar;
const GrammarExprType = grammar_mod.GrammarExprType;
const ParserRow = parser_row_mod.ParserRow;
const ParserState = parser_state_mod.ParserState;
const RepeatDetector = repeat_detector_mod.RepeatDetector;

const FSM_STATE_INITIALIZED: u8 = 1 << 0;
const FSM_STATE_SCANABLE: u8 = 1 << 1;
const FSM_STATE_NON_TERMINAL: u8 = 1 << 2;
const FSM_STATE_END: u8 = 1 << 3;
const FSM_STATE_HAS_EDGES: u8 = 1 << 4;

/// Errors raised by the parser (OOM plus the temporary fsm-hook gate).
pub const EarleyError = Allocator.Error || Compact2dArrayError || FsmGateError;

/// WaveGrammar 尚未在 `Grammar` 上安装 `complete_fsm`/`per_rule_fsms` 字段时
/// FSM 路径的门控错误（comptime 检测，字段安装后自动不可达）。
pub const FsmGateError = error{FsmNotInstalled};

/// Whether `Grammar` already carries the fsm-wave hooks (set by WaveGrammar).
pub const grammar_fsm_installed =
    @hasField(Grammar, "complete_fsm") and @hasField(Grammar, "per_rule_fsms");

/// An incremental Earley parser over an optimized grammar's per-rule FSMs.
pub const EarleyParser = struct {
    gpa: Allocator,
    /// The optimized grammar being parsed (Rust `Arc<Grammar>`; borrowed here).
    grammar: *const Grammar,
    /// Whether the stop token can be accepted in this advance round.
    tmp_accept_stop_token: bool,
    /// `is_completed.items[i]` = whether the root rule is completed after accepting `i` inputs.
    is_completed: ArrayList(bool),
    /// Per input position: `(referenced_rule_id, parent_state)` pairs awaiting completion.
    rule_id_to_completable_states: Compact2dArray(CompletableState),
    /// Per input position: the scanable states after accepting that input.
    scanable_state_history: Compact2dArray(ParserState),
    /// Scratch: states to add to the next scanable-history row.
    tmp_states_to_be_added: ArrayList(ParserState),
    /// Scratch: the processing queue (Rust `VecDeque<ParserState>`).
    tmp_process_state_queue: std.Deque(ParserState),
    /// Scratch: states already enqueued this round.
    tmp_states_visited_in_queue: RepeatDetector,
    /// Whether the stop token has been accepted.
    stop_token_is_accepted: bool,
    /// Graph-state properties tagged with the rule whose accepting states they include.
    fsm_state_flags_cache: ArrayList(u64),
    fsm_state_offsets: ArrayList(usize),
    /// Whether each rule can match the empty string.
    rule_is_nullable: []bool,
    /// The index of the LLM token currently being accepted, set by the matcher; `-1` before
    /// any token. `budget_deadline` values are compared against it.
    current_token_index: i32,
    /// Whether states past their budget deadline are skipped when scanning.
    skip_expired_states: bool,
    /// Whether any rule of the grammar has a token budget.
    has_budget_rules: bool,
    /// The number of Unicode codepoints accepted at every parser history row.
    char_count_history: ArrayList(i32),
    /// Whether any rule of the grammar has a character budget.
    has_char_budget_rules: bool,
    /// Whether a character-budgeted occurrence was entered since the initial parser row.
    char_budget_entry_history: ArrayList(bool),
    /// Entry-history value for the row currently being expanded.
    tmp_char_budget_entered: bool,
    /// Whether any rule has a capture or stop_capture name. When false the capture machinery is
    /// disabled.
    capture_tracking: bool,
    /// Whether the grammar contains suffix/stop spans that may affect captures.
    has_hidden_capture_rules: bool,
    /// Whether capture events are recorded in `complete`. Only enabled during definitive
    /// advances, never during speculative exploration.
    capture_recording: bool,
    /// `capture_event_history[i]` stores the events recorded when input position `i` was
    /// created. Kept aligned with `scanable_state_history` whenever `capture_tracking` is true.
    capture_event_history: Compact2dArray(CaptureEvent),
    /// The lazy rule occurrences `(rule_id, rule_start_pos)` completed while building the
    /// current row; their remaining states are removed when the row is finalized.
    tmp_completed_lazy_occurrences: ArrayList(LazyOccurrence),

    /// One lazy occurrence (Rust tuple `(i32, i32)`).
    pub const LazyOccurrence = struct {
        rule_id: i32,
        rule_start_pos: i32,
    };

    /// Creates a parser over `grammar`, starting from `initial_state` or, if `null`, from the
    /// root rule.
    ///
    /// The returned parser is heap-allocated and owns itself (`deinit`).
    /// Rust panics on an unoptimized grammar; this port asserts it.
    /// `Grammar` 的 fsm 挂点（WaveGrammar）安装前抛 `error.FsmNotInstalled`
    /// （`fsm_state_offsets` 按 `Grammar::fsm_state_offsets`，参照 earley_parser.rs `new`）。
    pub fn new(
        gpa: Allocator,
        grammar: *const Grammar,
        initial_state: ?ParserState,
    ) EarleyError!*EarleyParser {
        std.debug.assert(grammar.is_optimized()); // "The grammar is not optimized. Please optimize the grammar before using the Earley parser."
        const num_rules: usize = @intCast(grammar.num_rules());
        const has_budget_rules = blk: {
            for (grammar.rules.items) |rule| {
                if (rule.max_tokens >= 0) break :blk true;
            }
            break :blk false;
        };
        const has_char_budget_rules = blk: {
            for (grammar.rules.items) |rule| {
                if (rule.max_chars >= 0) break :blk true;
            }
            break :blk false;
        };
        const capture_tracking = blk: {
            for (grammar.rules.items) |rule| {
                if (rule.capture_name.len != 0) break :blk true;
            }
            for (grammar.suffix_stop_infos.items) |info| {
                if (info.stop_capture_name.len != 0) break :blk true;
            }
            break :blk false;
        };
        const has_hidden_capture_rules = blk: {
            for (grammar.suffix_stop_infos.items) |info| {
                if (info.hidden_suffix_bytes > 0 or info.hidden_stop_bytes > 0) break :blk true;
            }
            break :blk false;
        };

        const rule_is_nullable = try gpa.alloc(bool, num_rules);
        errdefer gpa.free(rule_is_nullable);
        @memset(rule_is_nullable, false);
        for (grammar.allow_empty_rule_ids.items) |rule_id| {
            rule_is_nullable[@intCast(rule_id)] = true;
        }

        const parser = try gpa.create(EarleyParser);
        errdefer gpa.destroy(parser);
        parser.* = .{
            .gpa = gpa,
            .grammar = grammar,
            .tmp_accept_stop_token = false,
            .is_completed = .empty,
            .rule_id_to_completable_states = try Compact2dArray(CompletableState).init(gpa),
            .scanable_state_history = try Compact2dArray(ParserState).init(gpa),
            .tmp_states_to_be_added = .empty,
            .tmp_process_state_queue = .empty,
            .tmp_states_visited_in_queue = RepeatDetector.new(),
            .stop_token_is_accepted = false,
            .fsm_state_flags_cache = .empty,
            .fsm_state_offsets = .empty,
            .rule_is_nullable = rule_is_nullable,
            .current_token_index = -1,
            .skip_expired_states = false,
            .has_budget_rules = has_budget_rules,
            .char_count_history = .empty,
            .has_char_budget_rules = has_char_budget_rules,
            .char_budget_entry_history = .empty,
            .tmp_char_budget_entered = false,
            .capture_tracking = capture_tracking,
            .has_hidden_capture_rules = has_hidden_capture_rules,
            .capture_recording = false,
            .capture_event_history = try Compact2dArray(CaptureEvent).init(gpa),
            .tmp_completed_lazy_occurrences = .empty,
        };
        errdefer parser.deinit();
        try parser.init_fsm_state_offsets();
        const initial = initial_state orelse try parser.root_initial_state();
        try parser.push_state_and_expand(initial);
        return parser;
    }

    /// Releases everything the parser owns, including itself.
    pub fn deinit(self: *EarleyParser) void {
        const gpa = self.gpa;
        self.is_completed.deinit(gpa);
        self.rule_id_to_completable_states.deinit();
        self.scanable_state_history.deinit();
        self.tmp_states_to_be_added.deinit(gpa);
        self.tmp_process_state_queue.deinit(gpa);
        self.tmp_states_visited_in_queue.deinit(gpa);
        self.fsm_state_flags_cache.deinit(gpa);
        self.fsm_state_offsets.deinit(gpa);
        gpa.free(self.rule_is_nullable);
        self.char_count_history.deinit(gpa);
        self.char_budget_entry_history.deinit(gpa);
        self.capture_event_history.deinit();
        self.tmp_completed_lazy_occurrences.deinit(gpa);
        gpa.destroy(self);
    }

    /// Whether the root rule is currently completed (the stop token is acceptable).
    /// (Rust `EarleyParser::is_completed`; renamed: the field owns the Rust name.)
    pub fn is_root_completed(self: *const EarleyParser) bool {
        return self.is_completed.items[self.is_completed.items.len - 1];
    }

    /// The scanable states at the latest position (borrowed from the history).
    pub fn latest_scanable_states(self: *const EarleyParser) []const ParserState {
        return self.scanable_state_history.back();
    }

    /// The `(referenced_rule_id, parent_state)` completable pairs at the latest position
    /// (borrowed from the history).
    pub fn latest_completable_states(self: *const EarleyParser) []const CompletableState {
        return self.rule_id_to_completable_states.back();
    }

    /// Whether the stop token has been accepted.
    pub fn is_stop_token_accepted(self: *const EarleyParser) bool {
        return self.stop_token_is_accepted;
    }

    /// Whether completing the occurrence of a suffix/stop rule actually consumed its trailing
    /// marker. A non-looping tag dispatch can also complete before its trigger is seen; only the
    /// terminal post-dispatch state has no outgoing edges.
    fn completion_consumed_marker(self: *const EarleyParser, state: ParserState) EarleyError!bool {
        const body = self.grammar.expr(self.grammar.rule(state.rule_id).body_expr_id);
        if (body.ty != .TagDispatch) return true;
        const fsm = try self.per_rule_fsm(state.rule_id);
        return fsm.get_fsm().state_edges(state.element_id).len == 0;
    }

    /// The shared complete FSM (Rust `Grammar::complete_fsm()`).
    fn complete_fsm(self: *const EarleyParser) FsmGateError!fsm_mod.CompactFsm {
        if (comptime !grammar_fsm_installed) return error.FsmNotInstalled;
        return self.grammar.complete_fsm;
    }

    /// The compiled per-rule FSM view (Rust `Grammar::per_rule_fsm(...).expect("per-rule FSM")`
    /// unwrapped to the `CompactFsmWithStartEnd`). A missing entry is the temporary
    /// not-installed gate until WaveGrammar populates the field.
    fn per_rule_fsm(
        self: *const EarleyParser,
        rule_id: i32,
    ) FsmGateError!*const fsm_mod.CompactFsmWithStartEnd {
        if (comptime !grammar_fsm_installed) return error.FsmNotInstalled;
        const idx: usize = @intCast(rule_id);
        if (idx >= self.grammar.per_rule_fsms.items.len) return error.FsmNotInstalled;
        const view = self.grammar.per_rule_fsms.items[idx] orelse return error.FsmNotInstalled;
        return &view.fsm;
    }

    /// Computes `Grammar::fsm_state_offsets` (grammar.rs L72) into `self.fsm_state_offsets`:
    /// distinct FSM storages get consecutive state ranges; shared rule views reuse one range.
    fn init_fsm_state_offsets(self: *EarleyParser) (FsmGateError || Allocator.Error)!void {
        if (comptime !grammar_fsm_installed) return error.FsmNotInstalled;
        self.fsm_state_offsets.clearRetainingCapacity();
        var storage: ArrayList(fsm_mod.CompactFsm) = .empty;
        defer storage.deinit(self.gpa);
        const shared_complete = self.grammar.complete_fsm;
        try storage.append(self.gpa, shared_complete);
        var next_offset = @as(usize, @intCast(complete.num_states()));
        try self.fsm_state_offsets.append(self.gpa, 0);
        for (self.grammar.per_rule_fsms.items) |view| {
            const offset = blk: {
                const wrapper = view orelse break :blk 0;
                const fsm = wrapper.fsm.get_fsm();
                for (storage.items, 0..) |shared, i| {
                    if (fsm.shares_storage(shared)) break :blk self.fsm_state_offsets.items[i];
                }
                const offset = next_offset;
                next_offset += @as(usize, @intCast(fsm.num_states()));
                storage.append(self.gpa, fsm) catch unreachable;
                break :blk offset;
            };
            try self.fsm_state_offsets.append(self.gpa, offset);
        }
    }

    /// Collects the captured rule occurrences whose concrete Earley parent chains contain the
    /// given stop completion, following only the parent links of this occurrence.
    fn collect_stop_capture_targets(
        self: *EarleyParser,
        state: ParserState,
    ) Allocator.Error!ArrayList(CaptureOccurrence) {
        var targets: ArrayList(CaptureOccurrence) = .empty;
        errdefer targets.deinit(self.gpa);
        var pending: ArrayList(CaptureOccurrence) = .empty;
        defer pending.deinit(self.gpa);
        try pending.append(self.gpa, .{ .rule_id = state.rule_id, .start_pos = state.rule_start_pos });
        var visited = std.AutoHashMap(CaptureOccurrence, void).init(self.gpa);
        defer visited.deinit();
        while (pending.pop()) |occurrence| {
            if ((try visited.getOrPut(occurrence)).found_existing) continue;
            if (self.rule_has_capture(occurrence.rule_id)) {
                try targets.append(self.gpa, occurrence);
            }
            if (occurrence.start_pos == ParserState.NO_PREV_INPUT_POS) continue;
            for (self.rule_id_to_completable_states.row(@intCast(occurrence.start_pos))) |entry| {
                if (entry.referenced_rule_id != occurrence.rule_id or entry.parent_state.rule_id < 0) continue;
                try pending.append(self.gpa, .{
                    .rule_id = entry.parent_state.rule_id,
                    .start_pos = entry.parent_state.rule_start_pos,
                });
            }
        }
        return targets;
    }

    /// Records a capture or hidden-span event for a completed rule in the current row.
    fn record_capture_event(self: *EarleyParser, state: ParserState, marker_present: bool) EarleyError!void {
        const info = self.grammar.suffix_stop_info(state.rule_id);
        const marker_consumed = marker_present and info != null and
            (info.?.hidden_suffix_bytes > 0 or info.?.hidden_stop_bytes > 0) and
            try self.completion_consumed_marker(state);
        var hidden_suffix_bytes: i32 = 0;
        var hidden_stop_bytes: i32 = 0;
        var body_rule_id: i32 = -1;
        if (info != null and marker_consumed) {
            hidden_suffix_bytes = info.?.hidden_suffix_bytes;
            hidden_stop_bytes = info.?.hidden_stop_bytes;
            body_rule_id = info.?.body_rule_id;
        }
        var event_start_pos = state.rule_start_pos;
        if (marker_consumed and body_rule_id == state.rule_id) {
            // A self-referencing body helper marks the zero-width event inserted immediately after
            // a dynamic string trigger. Its capture span is the fixed-length marker before it.
            std.debug.assert(event_start_pos != ParserState.NO_PREV_INPUT_POS);
            event_start_pos -= @max(hidden_suffix_bytes, hidden_stop_bytes);
            std.debug.assert(event_start_pos >= 0);
        }
        var stop_capture_targets: ArrayList(CaptureOccurrence) = .empty;
        errdefer stop_capture_targets.deinit(self.gpa);
        if (hidden_stop_bytes > 0) {
            stop_capture_targets = try self.collect_stop_capture_targets(state);
        }
        try self.capture_event_history.push_in_latest_row(.{
            .rule_id = state.rule_id,
            .start_pos = event_start_pos,
            .occurrence_start_pos = state.rule_start_pos,
            .hidden_suffix_bytes = hidden_suffix_bytes,
            .hidden_stop_bytes = hidden_stop_bytes,
            .stop_capture_targets = stop_capture_targets,
        });
    }

    fn resolve_active_temperature_rule(self: *const EarleyParser, rule_id: i32, inherited_rule_id: i32) i32 {
        if (self.grammar.rule(rule_id).temperature != null) {
            return rule_id;
        } else {
            return inherited_rule_id;
        }
    }

    fn rule_has_capture(self: *const EarleyParser, rule_id: i32) bool {
        return self.capture_tracking and rule_id >= 0 and
            self.grammar.rule(rule_id).capture_name.len != 0;
    }

    fn rule_has_hidden_bytes(self: *const EarleyParser, rule_id: i32) bool {
        if (!self.capture_tracking or !self.has_hidden_capture_rules or rule_id < 0) return false;
        const info = self.grammar.suffix_stop_info(rule_id) orelse return false;
        return info.hidden_suffix_bytes > 0 or info.hidden_stop_bytes > 0;
    }

    fn rule_needs_capture_event(self: *const EarleyParser, rule_id: i32) bool {
        return self.rule_has_capture(rule_id) or self.rule_has_hidden_bytes(rule_id);
    }

    /// Whether the state's derivation may not consume the next token.
    pub fn is_expired_state(self: *const EarleyParser, state: ParserState) bool {
        return state.budget_deadline >= 0 and self.current_token_index > state.budget_deadline;
    }

    /// Whether the state's derivation may not consume another Unicode codepoint.
    pub fn is_char_expired_state(self: *const EarleyParser, state: ParserState) bool {
        return state.char_budget_deadline >= 0 and self.current_char_index() >= state.char_budget_deadline;
    }

    /// The deadline for a newly predicted occurrence of the rule: its own budget counted from
    /// the current token, capped by the parent's deadline for nested budgets.
    fn deadline_for_rule(self: *const EarleyParser, rule_id: i32, parent_deadline: i32) i32 {
        const own = self.grammar.rule(rule_id).max_tokens;
        if (own < 0) return parent_deadline;
        const deadline = @min(@as(i64, self.current_token_index) + @as(i64, own), @as(i64, std.math.maxInt(i32)));
        if (parent_deadline >= 0) {
            return @intCast(@min(deadline, @as(i64, parent_deadline)));
        }
        return @intCast(deadline);
    }

    /// The character deadline for a newly predicted rule occurrence.
    fn char_deadline_for_rule(self: *const EarleyParser, rule_id: i32, parent_deadline: i32) i32 {
        const own = self.grammar.rule(rule_id).max_chars;
        if (own < 0) return parent_deadline;
        const deadline = std.math.add(i32, self.current_char_index(), own) catch std.math.maxInt(i32);
        if (parent_deadline >= 0) {
            return @min(deadline, parent_deadline);
        }
        return deadline;
    }

    /// Whether `byte` starts a UTF-8 codepoint (is not a continuation byte).
    pub fn starts_utf8_codepoint(byte: u8) bool {
        return (byte & 0xC0) != 0x80;
    }

    /// Removes the last `count` recorded positions.
    ///
    /// Rust panics if `count` is not smaller than the number of recorded positions; this port
    /// asserts it.
    pub fn pop_last_states(self: *EarleyParser, count: i32) void {
        self.stop_token_is_accepted = false;
        const n: usize = @intCast(count);
        std.debug.assert(n < self.rule_id_to_completable_states.len()); // "The number of states to be popped is larger than the size of states."
        self.rule_id_to_completable_states.pop_back(n);
        self.is_completed.shrinkRetainingCapacity(self.is_completed.items.len - n);
        self.scanable_state_history.pop_back(n);
        if (self.capture_tracking) {
            self.capture_event_history.pop_back(n);
        }
        if (self.has_char_budget_rules) {
            self.char_count_history.shrinkRetainingCapacity(self.char_count_history.items.len - n);
            self.char_budget_entry_history.shrinkRetainingCapacity(self.char_budget_entry_history.items.len - n);
        }
    }

    /// The completion operation of the Earley parser: advances the parents waiting for the
    /// completed rule. `marker_present` is false when a suffix/stop rule is force-completed
    /// without its trailing marker.
    pub fn complete(self: *EarleyParser, state: ParserState, marker_present: bool) EarleyError!void {
        // Record capture and hidden-span events, only during definitive advances.
        if (self.capture_recording and self.rule_needs_capture_event(state.rule_id)) {
            try self.record_capture_event(state, marker_present);
        }
        if (state.rule_id != -1 and self.grammar.rule(state.rule_id).is_lazy) {
            try self.tmp_completed_lazy_occurrences.append(self.gpa, .{
                .rule_id = state.rule_id,
                .rule_start_pos = state.rule_start_pos,
            });
        }
        if (state.rule_start_pos == ParserState.NO_PREV_INPUT_POS) {
            // If a root rule can achieve here, then it must be completed.
            self.tmp_accept_stop_token = true;
            return;
        }
        // Completion only enqueues, so the parent row does not change while it is walked.
        const range = self.rule_id_to_completable_states.row_range(@intCast(state.rule_start_pos));
        for (self.rule_id_to_completable_states.data_slice()[range.start..range.end]) |entry| {
            const ref_id = entry.referenced_rule_id;
            const parent_state = entry.parent_state;
            if (ref_id != state.rule_id) continue;
            if (parent_state.rule_id == -1) {
                const parent_expr = self.grammar.expr(parent_state.sequence_id);
                const element_expr = self.grammar.expr(parent_expr.data[@intCast(parent_state.element_id)]);
                std.debug.assert(element_expr.ty == .RuleRef or element_expr.ty == .Repeat);
                if (element_expr.ty == .RuleRef) {
                    try self.enqueue(parent_state.at_element(parent_state.element_id + 1));
                    continue;
                }
                // The parent state is a repeat: increase the repeat count.
                const repeat_spec = element_expr.repeat();
                var new_state = parent_state;
                new_state.repeat_count += 1;
                if (new_state.repeat_count >= repeat_spec.min_repeat) {
                    try self.enqueue(parent_state.at_element(parent_state.element_id + 1));
                }
                if (new_state.repeat_count < repeat_spec.max_repeat) {
                    try self.enqueue(new_state);
                }
                continue;
            }
            // The rule is referenced by a FSM: check whether the parent sits on a repeat edge (by
            // invariance, a state with a repeat edge has exactly one outgoing edge).
            const fsm = try self.complete_fsm();
            var repeat: ?struct { target: i32, lower: i32, upper: i32 } = null;
            for (fsm.state_edges(parent_state.element_id)) |edge| {
                if (!edge.is_repeat_ref()) continue;
                const info = fsm.repeat_edge_info(edge.aux_index());
                if (info.rule_id() == ref_id) {
                    repeat = .{ .target = edge.target, .lower = info.lower(), .upper = info.upper() };
                    break;
                }
            }
            const found = repeat orelse {
                try self.enqueue(parent_state);
                continue;
            };
            const new_count = parent_state.repeat_count + 1;
            if (new_count >= found.lower) {
                try self.enqueue(parent_state.at_element(found.target));
            }
            if (new_count < found.upper) {
                try self.enqueue(parent_state.at_element_with_repeat(parent_state.element_id, new_count));
            }
        }
    }

    /// The prediction operation of the Earley parser. Returns `(scanable, completable)`.
    pub fn predict(self: *EarleyParser, state: ParserState) EarleyError!struct { scanable: bool, completable: bool } {
        if (state.rule_id != -1) {
            const flags = try self.fsm_state_flags(state.rule_id, state.element_id);
            if (flags & FSM_STATE_NON_TERMINAL != 0) {
                try self.expand_next_rule_ref_element_on_fsm(state);
            }
            return .{
                .scanable = flags & FSM_STATE_SCANABLE != 0,
                .completable = flags & FSM_STATE_END != 0,
            };
        }
        const grammar_expr = self.grammar.expr(state.sequence_id);
        std.debug.assert(grammar_expr.ty == .Sequence or grammar_expr.ty == .EmptyStr);
        if (state.element_id == @as(i32, @intCast(grammar_expr.len()))) {
            // The rule is completed.
            return .{ .scanable = false, .completable = true };
        }
        const element_expr_id = grammar_expr.data[@intCast(state.element_id)];
        const element_expr = self.grammar.expr(element_expr_id);
        switch (element_expr.ty) {
            .RuleRef => {
                try self.expand_next_rule_ref_element(state, state.sequence_id, element_expr_id);
                return .{ .scanable = false, .completable = false };
            },
            .CharacterClassStar => {
                if (state.sub_element_id == 0) {
                    try self.enqueue(state.at_element(state.element_id + 1));
                }
                return .{ .scanable = true, .completable = false };
            },
            .Repeat => {
                const repeat_spec = element_expr.repeat();
                std.debug.assert(state.repeat_count <= repeat_spec.max_repeat);
                try self.expand_next_rule_ref_element(state, state.sequence_id, element_expr_id);
                if (state.repeat_count >= repeat_spec.min_repeat) {
                    try self.enqueue(state.at_element(state.element_id + 1));
                }
                return .{ .scanable = false, .completable = false };
            },
            .ByteString, .CharacterClass => return .{ .scanable = true, .completable = false },
            .Token, .ExcludeToken => return .{ .scanable = false, .completable = false },
            // Rust panics: "The element type is not supported!"
            else => {
                std.debug.panic("The element type is not supported! The type is: {s}", .{@tagName(element_expr.ty)});
            },
        }
    }

    fn scan(self: *EarleyParser, state: ParserState, ch: u8) EarleyError!void {
        if (state.rule_id != -1) {
            try self.advance_fsm(state, ch);
            return;
        }
        const element_expr_id = self.grammar.expr(state.sequence_id).data[@intCast(state.element_id)];
        switch (self.grammar.expr(element_expr_id).ty) {
            .ByteString => self.advance_byte_string(state, ch, element_expr_id),
            .CharacterClass => try self.advance_character_class(state, ch, element_expr_id),
            .CharacterClassStar => try self.advance_character_class_star(state, ch, element_expr_id),
            // Rust panics: "The element type is not supported!"
            else => {
                std.debug.panic("The element type is not supported! The type is: {s}", .{@tagName(self.grammar.expr(element_expr_id).ty)});
            },
        }
    }

    /// Runs the predict/complete loop over the processing queue.
    pub fn process_queue(self: *EarleyParser) EarleyError!void {
        while (self.tmp_process_state_queue.popFront()) |state| {
            const result = try self.predict(state);
            if (result.completable) {
                try self.complete(state, true);
            }
            if (result.scanable) {
                try self.tmp_states_to_be_added.append(self.gpa, state);
            }
        }
    }

    /// Advances the parser by one input byte. Returns false (leaving state unchanged) if the
    /// byte is not accepted.
    pub fn advance(self: *EarleyParser, ch: u8) EarleyError!bool {
        std.debug.assert(self.tmp_process_state_queue.len == 0);
        self.tmp_states_visited_in_queue.clear();
        self.tmp_states_to_be_added.clearRetainingCapacity();
        self.tmp_accept_stop_token = false;
        self.tmp_completed_lazy_occurrences.clearRetainingCapacity();
        if (self.has_char_budget_rules) {
            self.tmp_char_budget_entered = self.char_budget_entry_history.items[self.char_budget_entry_history.items.len - 1];
            try self.char_count_history.append(self.gpa, self.current_char_index() + @as(i32, @intFromBool(starts_utf8_codepoint(ch))));
        }
        // Scanning only queues states, so the latest row does not change while it is walked.
        const range = self.scanable_state_history.row_range(self.scanable_state_history.len() - 1);
        for (self.scanable_state_history.data_slice()[range.start..range.end]) |state| {
            if (self.skip_expired_states and self.is_expired_state(state)) continue;
            try self.scan(state, ch);
        }
        if (self.tmp_process_state_queue.len == 0 and self.tmp_states_to_be_added.items.len == 0) {
            if (self.has_char_budget_rules) {
                _ = self.char_count_history.pop();
            }
            return false;
        }
        _ = try self.rule_id_to_completable_states.push_row(&.{});
        if (self.capture_tracking) {
            _ = try self.capture_event_history.push_row(&.{});
        }
        try self.process_queue();
        try self.finish_row(false);
        return true;
    }

    /// Finalizes the row built by the processing loop: removes committed lazy states and
    /// records completion, scanable states and (unless already pushed) the character rows.
    fn finish_row(self: *EarleyParser, push_char_count: bool) EarleyError!void {
        if (self.tmp_completed_lazy_occurrences.items.len != 0) {
            self.remove_committed_lazy_states();
        }
        try self.is_completed.append(self.gpa, self.tmp_accept_stop_token);
        _ = try self.scanable_state_history.push_row(self.tmp_states_to_be_added.items);
        if (self.has_char_budget_rules) {
            if (push_char_count) {
                try self.char_count_history.append(self.gpa, self.current_char_index());
            }
            try self.char_budget_entry_history.append(self.gpa, self.tmp_char_budget_entered);
        }
    }

    /// Removes the states of the lazy occurrences completed in the current row
    /// (committed-shortest matching).
    pub fn remove_committed_lazy_states(self: *EarleyParser) void {
        const committed = self.tmp_completed_lazy_occurrences;
        self.tmp_completed_lazy_occurrences = .empty;
        defer self.tmp_completed_lazy_occurrences = committed;
        var write: usize = 0;
        for (self.tmp_states_to_be_added.items) |state| {
            var is_lazy = false;
            for (committed.items) |occ| {
                if (state.rule_id == occ.rule_id and state.rule_start_pos == occ.rule_start_pos) {
                    is_lazy = true;
                    break;
                }
            }
            if (!is_lazy) {
                self.tmp_states_to_be_added.items[write] = state;
                write += 1;
            }
        }
        self.tmp_states_to_be_added.shrinkRetainingCapacity(write);
    }

    fn fsm_state_flags(self: *EarleyParser, rule_id: i32, state_id: i32) EarleyError!u8 {
        const index = self.fsm_state_offsets.items[@intCast(rule_id)] + @as(usize, @intCast(state_id));
        if (index < self.fsm_state_flags_cache.items.len) {
            const entry = self.fsm_state_flags_cache.items[index];
            if (entry & 0xFF != 0 and entry >> 8 == @as(u64, @intCast(rule_id))) {
                return @truncate(entry);
            }
        }
        return self.initialize_fsm_state_flags(rule_id, state_id);
    }

    fn initialize_fsm_state_flags(self: *EarleyParser, rule_id: i32, state_id: i32) EarleyError!u8 {
        const fsm = try self.per_rule_fsm(rule_id);
        const offset = self.fsm_state_offsets.items[@intCast(rule_id)];
        if (self.fsm_state_flags_cache.items.len < offset + @as(usize, @intCast(fsm.num_states()))) {
            try self.fsm_state_flags_cache.appendNTimes(self.gpa, 0, offset + @as(usize, @intCast(fsm.num_states())) - self.fsm_state_flags_cache.items.len);
        }
        var flags = FSM_STATE_INITIALIZED;
        if (fsm.is_end_state(state_id)) {
            flags |= FSM_STATE_END;
        }
        const edges = fsm.get_fsm().state_edges(state_id);
        if (edges.len != 0) {
            flags |= FSM_STATE_HAS_EDGES;
        }
        for (edges) |edge| {
            if (edge.is_char_range() or edge.is_token() or edge.is_exclude_token()) {
                flags |= FSM_STATE_SCANABLE;
            } else if (edge.is_rule_ref() or edge.is_epsilon() or edge.is_repeat_ref()) {
                flags |= FSM_STATE_NON_TERMINAL;
            }
        }
        self.fsm_state_flags_cache.items[offset + @as(usize, @intCast(state_id))] =
            @as(u64, @intCast(rule_id)) << 8 | flags;
        return flags;
    }

    /// The initial state expanded from the root rule of the grammar.
    pub fn root_initial_state(self: *const EarleyParser) EarleyError!ParserState {
        const root_rule_id = self.grammar.root_rule_id;
        var state = ParserState.new(
            root_rule_id,
            self.grammar.root_rule().body_expr_id,
            (try self.per_rule_fsm(root_rule_id)).get_start(),
            ParserState.NO_PREV_INPUT_POS,
        );
        state.budget_deadline = self.deadline_for_rule(root_rule_id, -1);
        state.active_temperature_rule_id = self.resolve_active_temperature_rule(root_rule_id, -1);
        state.char_budget_deadline = self.char_deadline_for_rule(root_rule_id, -1);
        return state;
    }

    /// Pushes `state` and expands it through the predict/complete loop into a new position.
    pub fn push_state_and_expand(self: *EarleyParser, state: ParserState) EarleyError!void {
        self.tmp_states_visited_in_queue.clear();
        self.tmp_accept_stop_token = false;
        self.tmp_states_to_be_added.clearRetainingCapacity();
        self.tmp_completed_lazy_occurrences.clearRetainingCapacity();
        try self.enqueue(state);
        _ = try self.rule_id_to_completable_states.push_row(&.{});
        if (self.capture_tracking) {
            _ = try self.capture_event_history.push_row(&.{});
        }
        try self.process_queue();
        try self.finish_row(true);
    }

    /// Resets the parser to the freshly-expanded root rule.
    pub fn reset(self: *EarleyParser) EarleyError!void {
        const rows = self.rule_id_to_completable_states.len();
        self.rule_id_to_completable_states.pop_back(rows);
        const rows2 = self.scanable_state_history.len();
        self.scanable_state_history.pop_back(rows2);
        self.is_completed.clearRetainingCapacity();
        self.stop_token_is_accepted = false;
        if (self.capture_tracking) {
            const rows3 = self.capture_event_history.len();
            self.capture_event_history.pop_back(rows3);
        }
        self.char_count_history.clearRetainingCapacity();
        self.char_budget_entry_history.clearRetainingCapacity();
        self.tmp_char_budget_entered = false;
        self.capture_recording = false;
        std.debug.assert(self.tmp_process_state_queue.len == 0);
        const root = try self.root_initial_state();
        try self.push_state_and_expand(root);
    }

    /// Records the completable parent pairs for a predicted rule reference, applying the
    /// right-recursion optimization when allowed. Returns whether the child becomes a root.
    fn add_completable_parents(
        self: *EarleyParser,
        state: ParserState,
        ref_rule_id: i32,
        is_right_recursion: bool,
        parent_entry: ParserState,
    ) Allocator.Error!bool {
        // The right-recursion optimization elides the completion of the parent rule (and, in the
        // to-root case, corrupts the start position of the child rule), so it is disabled when
        // either rule produces capture-history events.
        const cur_pos: i32 = @intCast(self.rule_id_to_completable_states.len() - 1);
        if (!is_right_recursion or state.rule_start_pos == cur_pos or
            self.rule_needs_capture_event(state.rule_id) or self.rule_needs_capture_event(ref_rule_id))
        {
            try self.rule_id_to_completable_states.push_in_latest_row(.{
                .referenced_rule_id = ref_rule_id,
                .parent_state = parent_entry,
            });
            return false;
        }
        if (state.rule_start_pos == ParserState.NO_PREV_INPUT_POS) {
            return true;
        }
        // The parents live in an earlier row, so appending to the latest row leaves them in place;
        // like upstream, duplicates are checked against the latest row as it was before the loop.
        const parents = self.rule_id_to_completable_states.row_range(@intCast(state.rule_start_pos));
        const latest = self.rule_id_to_completable_states.row_range(self.rule_id_to_completable_states.len() - 1);
        const data = self.rule_id_to_completable_states.data_slice();
        for (data[parents.start..parents.end]) |entry| {
            const parent_rule_id = entry.referenced_rule_id;
            const parent_state = entry.parent_state;
            if (parent_rule_id != state.rule_id) continue;
            var known = false;
            for (data[latest.start..latest.end]) |known_entry| {
                if (known_entry.referenced_rule_id == ref_rule_id and known_entry.parent_state.eql(parent_state)) {
                    known = true;
                    break;
                }
            }
            if (!known) {
                try self.rule_id_to_completable_states.push_in_latest_row(.{
                    .referenced_rule_id = ref_rule_id,
                    .parent_state = parent_state,
                });
            }
        }
        return false;
    }

    /// Enqueues the start state of a newly predicted occurrence of `ref_rule_id`.
    fn enqueue_rule_start(
        self: *EarleyParser,
        state: ParserState,
        ref_rule_id: i32,
        right_recursion_to_root: bool,
    ) EarleyError!void {
        const ref_rule = self.grammar.rule(ref_rule_id);
        if (ref_rule.max_chars >= 0) {
            self.tmp_char_budget_entered = true;
        }
        const start_pos: i32 = if (right_recursion_to_root)
            ParserState.NO_PREV_INPUT_POS
        else
            @as(i32, @intCast(self.rule_id_to_completable_states.len())) - 1;
        var new_state = ParserState.new(
            ref_rule_id,
            ref_rule.body_expr_id,
            (try self.per_rule_fsm(ref_rule_id)).get_start(),
            start_pos,
        );
        new_state.budget_deadline = self.deadline_for_rule(ref_rule_id, state.budget_deadline);
        new_state.active_temperature_rule_id =
            self.resolve_active_temperature_rule(ref_rule_id, state.active_temperature_rule_id);
        new_state.char_budget_deadline = self.char_deadline_for_rule(ref_rule_id, state.char_budget_deadline);
        try self.enqueue(new_state);
    }

    /// Predicts a rule reference or repeat element in an IR sequence (lookahead path).
    fn expand_next_rule_ref_element(
        self: *EarleyParser,
        state: ParserState,
        sequence_id: i32,
        sub_element_expr_id: i32,
    ) EarleyError!void {
        const sequence_len: i32 = @intCast(self.grammar.expr(sequence_id).len());
        const sub_expr = self.grammar.expr(sub_element_expr_id);
        std.debug.assert(sub_expr.ty == .RuleRef or sub_expr.ty == .Repeat);
        const ref_rule_id = sub_expr.data[0];
        const is_right_recursion = state.element_id == sequence_len - 1 and sub_expr.ty != .Repeat;
        const right_recursion_to_root =
            try self.add_completable_parents(state, ref_rule_id, is_right_recursion, state);
        if (self.rule_is_nullable[@intCast(ref_rule_id)]) {
            try self.enqueue(state.at_element(state.element_id + 1));
        }
        try self.enqueue_rule_start(state, ref_rule_id, right_recursion_to_root);
    }

    /// Predicts the rule references, repeat references, and epsilon edges of a FSM state.
    fn expand_next_rule_ref_element_on_fsm(self: *EarleyParser, state: ParserState) EarleyError!void {
        // Rust snapshots the edges into a SmallVec before enqueuing; the grammar's edge table
        // is immutable during the loop, so the borrowed slice is equivalent.
        const fsm = try self.per_rule_fsm(state.rule_id);
        const edges = fsm.get_fsm().state_edges(state.element_id);
        for (edges) |edge| {
            if (edge.is_epsilon()) {
                try self.enqueue(state.at_element(edge.target));
                continue;
            }
            const target = edge.target;
            var ref_rule_id: i32 = undefined;
            var is_repeat = false;
            if (edge.is_rule_ref()) {
                ref_rule_id = edge.ref_rule_id();
            } else if (edge.is_repeat_ref()) {
                const info = (try self.complete_fsm()).repeat_edge_info(edge.aux_index());
                if (state.repeat_count >= info.lower()) {
                    try self.enqueue(state.at_element(target));
                }
                if (state.repeat_count >= info.upper()) {
                    continue;
                }
                ref_rule_id = info.rule_id();
                is_repeat = true;
            } else {
                continue;
            }

            const target_flags = try self.fsm_state_flags(state.rule_id, target);
            const is_right_recursion =
                !is_repeat and target_flags & FSM_STATE_HAS_EDGES == 0 and target_flags & FSM_STATE_END != 0;
            // For repeat edges the parent entry keeps the source state and the repeat count; for
            // rule references it is the post-transition state.
            const parent_entry = if (is_repeat)
                state.at_element_with_repeat(state.element_id, state.repeat_count)
            else
                state.at_element(target);
            const right_recursion_to_root =
                try self.add_completable_parents(state, ref_rule_id, is_right_recursion, parent_entry);
            if (!is_repeat and self.rule_is_nullable[@intCast(ref_rule_id)]) {
                try self.enqueue(state.at_element(target));
            }
            try self.enqueue_rule_start(state, ref_rule_id, right_recursion_to_root);
        }
    }

    fn advance_byte_string(self: *EarleyParser, state: ParserState, ch: u8, expr_id: i32) void {
        const expr = self.grammar.expr(expr_id);
        std.debug.assert(@as(i32, @intCast(expr.len())) > state.sub_element_id);
        if (@as(u8, @intCast(expr.data[@intCast(state.sub_element_id)])) != ch) return;
        var new_state = state;
        new_state.sub_element_id += 1;
        if (new_state.sub_element_id == @as(i32, @intCast(expr.len()))) {
            new_state.element_id += 1;
            new_state.sub_element_id = 0;
            self.enqueue_no_fail(new_state);
        } else {
            self.tmp_states_to_be_added.append(self.gpa, new_state) catch unreachable;
        }
    }

    /// Shared UTF-8 handling of character classes. `star` keeps the state on the same element
    /// after a full codepoint is matched.
    fn advance_character_class_impl(
        self: *EarleyParser,
        state: ParserState,
        ch: u8,
        expr_id: i32,
        star: bool,
    ) Allocator.Error!void {
        const class_data = self.grammar.expr(expr_id).data;
        const is_negative = class_data[0] != 0;

        const finish = struct {
            fn f(s: ParserState, is_star: bool) ParserState {
                var new_state = s;
                if (!is_star) new_state.element_id += 1;
                new_state.partial_codepoint = 0;
                return new_state;
            }
        }.f;

        // The state is matching a UTF-8 character (continuation bytes).
        if (state.sub_element_id > 0) {
            if ((ch & 0xC0) != 0x80) return;
            var new_state = state;
            new_state.sub_element_id -= 1;
            new_state.partial_codepoint = (new_state.partial_codepoint << 6) | @as(i32, ch & 0x3F);
            if (new_state.sub_element_id == 0) {
                const codepoint = new_state.partial_codepoint;
                const matches_range = ranges_overlap(class_data, codepoint, codepoint);
                if (matches_range != is_negative) {
                    try self.enqueue(finish(new_state, star));
                }
            } else {
                // Check whether the partial codepoint could still match any range. Negative
                // classes always continue and verify on the final byte.
                const remaining_bytes = new_state.sub_element_id;
                const min_codepoint = new_state.partial_codepoint << @intCast(6 * remaining_bytes);
                const max_codepoint = min_codepoint | ((1 << @intCast(6 * remaining_bytes)) - 1);
                if (is_negative or ranges_overlap(class_data, min_codepoint, max_codepoint)) {
                    try self.tmp_states_to_be_added.append(self.gpa, new_state);
                }
            }
            return;
        }

        // Non-ASCII first bytes.
        if (ch >= 0x80) {
            const decoded = support.encoding.handle_utf8_first_byte(ch) orelse return;
            std.debug.assert(decoded.consumed > 1);
            const remaining: u5 = @intCast(6 * (@as(i32, decoded.consumed) - 1));
            const min_codepoint = decoded.codepoint << remaining;
            const max_codepoint = min_codepoint | ((1 << remaining) - 1);
            if (is_negative or ranges_overlap(class_data, min_codepoint, max_codepoint)) {
                var new_state = state;
                new_state.sub_element_id = @as(i32, @intCast(decoded.consumed)) - 1;
                new_state.partial_codepoint = decoded.codepoint;
                try self.tmp_states_to_be_added.append(self.gpa, new_state);
            }
            return;
        }

        const in_range = blk: {
            var i: usize = 1;
            while (i + 1 < class_data.len) : (i += 2) {
                if (@as(u8, @intCast(class_data[i])) <= ch and ch <= @as(u8, @intCast(class_data[i + 1]))) break :blk true;
            }
            break :blk false;
        };
        if (in_range != is_negative) {
            var new_state = state;
            if (!star) {
                new_state.element_id += 1;
                new_state.sub_element_id = 0;
            }
            try self.enqueue(new_state);
        }
    }

    fn advance_character_class(self: *EarleyParser, state: ParserState, ch: u8, expr_id: i32) Allocator.Error!void {
        std.debug.assert(self.grammar.expr(expr_id).ty == .CharacterClass);
        return self.advance_character_class_impl(state, ch, expr_id, false);
    }

    fn advance_character_class_star(self: *EarleyParser, state: ParserState, ch: u8, expr_id: i32) Allocator.Error!void {
        std.debug.assert(self.grammar.expr(expr_id).ty == .CharacterClassStar);
        return self.advance_character_class_impl(state, ch, expr_id, true);
    }

    /// Enqueues a post-scan state: scanable leaves skip the predict/complete queue.
    fn enqueue_scan_target(self: *EarleyParser, new_state: ParserState) EarleyError!void {
        const flags = try self.fsm_state_flags(new_state.rule_id, new_state.element_id);
        if (flags & FSM_STATE_NON_TERMINAL == 0 and flags & FSM_STATE_END == 0 and flags & FSM_STATE_SCANABLE != 0) {
            try self.enqueue_without_processing(new_state);
        } else {
            try self.enqueue(new_state);
        }
    }

    fn advance_fsm(self: *EarleyParser, state: ParserState, ch: u8) EarleyError!void {
        const value: i32 = ch;
        // Rust collects the matching targets into a SmallVec before enqueuing; the grammar's
        // edge table is immutable during the loop, so the two passes are equivalent.
        const fsm = try self.per_rule_fsm(state.rule_id);
        const edges = fsm.get_fsm().state_edges(state.element_id);
        var targets: ArrayList(i32) = .empty;
        defer targets.deinit(self.gpa);
        for (edges) |edge| {
            if (edge.is_char_range() and edge.min <= value and value <= edge.max) {
                try targets.append(self.gpa, edge.target);
            }
        }
        for (targets.items) |element_id| {
            try self.enqueue_scan_target(state.with_element(element_id));
        }
    }

    fn scan_atomic_token(self: *EarleyParser, state: ParserState, token_id: i32) EarleyError!void {
        if (state.rule_id == -1) return;
        const fsm = try self.per_rule_fsm(state.rule_id);
        const edges = fsm.get_fsm().state_edges(state.element_id);
        var targets: ArrayList(i32) = .empty;
        defer targets.deinit(self.gpa);
        for (edges) |edge| {
            const matches = blk: {
                if (edge.is_token()) {
                    break :blk fsm.get_fsm().token_edge_info(edge.aux_index()).contains(token_id);
                } else if (edge.is_exclude_token()) {
                    break :blk fsm.get_fsm().exclude_token_edge_info(edge.aux_index()).accepts(token_id);
                } else {
                    break :blk false;
                }
            };
            if (matches) try targets.append(self.gpa, edge.target);
        }
        for (targets.items) |element_id| {
            try self.enqueue_scan_target(state.with_element(element_id));
        }
    }

    /// Advances the parser by accepting a whole token via token/exclude-token edges, consuming
    /// `token_char_count` codepoints. Returns false (state unchanged) if no state advances.
    pub fn advance_atomic_token(self: *EarleyParser, token_id: i32, token_char_count: i32) EarleyError!bool {
        std.debug.assert(self.tmp_process_state_queue.len == 0);
        self.tmp_states_visited_in_queue.clear();
        self.tmp_states_to_be_added.clearRetainingCapacity();
        self.tmp_accept_stop_token = false;
        self.tmp_completed_lazy_occurrences.clearRetainingCapacity();
        if (self.has_char_budget_rules) {
            self.tmp_char_budget_entered = self.char_budget_entry_history.items[self.char_budget_entry_history.items.len - 1];
            try self.char_count_history.append(self.gpa, self.current_char_index() + token_char_count);
        }
        const latest_states = try self.gpa.dupe(ParserState, self.latest_scanable_states());
        defer self.gpa.free(latest_states);
        for (latest_states) |state| {
            if (self.skip_expired_states and self.is_expired_state(state)) continue;
            try self.scan_atomic_token(state, token_id);
        }
        if (self.tmp_process_state_queue.len == 0 and self.tmp_states_to_be_added.items.len == 0) {
            if (self.has_char_budget_rules) {
                _ = self.char_count_history.pop();
            }
            return false;
        }
        _ = try self.rule_id_to_completable_states.push_row(&.{});
        if (self.capture_tracking) {
            _ = try self.capture_event_history.push_row(&.{});
        }
        try self.process_queue();
        try self.finish_row(false);
        return true;
    }

    /// Enqueues `state` for prediction/completion if it was not visited this round.
    pub fn enqueue(self: *EarleyParser, state: ParserState) Allocator.Error!void {
        if (!self.tmp_states_visited_in_queue.is_visited(state)) {
            try self.tmp_process_state_queue.pushBack(self.gpa, state);
            try self.tmp_states_visited_in_queue.insert(self.gpa, state);
        }
    }

    /// OOM-free variant used in infallible Rust paths (`advance_byte_string`); on OOM the
    /// process aborts (Rust aborts on OOM too).
    fn enqueue_no_fail(self: *EarleyParser, state: ParserState) void {
        self.enqueue(state) catch @panic("oom");
    }

    /// Adds `state` directly to the next scanable row if it was not visited this round.
    pub fn enqueue_without_processing(self: *EarleyParser, state: ParserState) Allocator.Error!void {
        if (!self.tmp_states_visited_in_queue.is_visited(state)) {
            try self.tmp_states_visited_in_queue.insert(self.gpa, state);
            try self.tmp_states_to_be_added.append(self.gpa, state);
        }
    }

    /// Pushes one state as a new temporary position to check (without expanding it).
    pub fn push_one_state_to_check(self: *EarleyParser, state: ParserState) Allocator.Error!void {
        const completed = self.is_root_completed();
        try self.push_states_to_check(&.{state}, completed);
    }

    /// Pushes a temporary parser row for token-mask checking.
    pub fn push_states_to_check(self: *EarleyParser, states: []const ParserState, completed: bool) Allocator.Error!void {
        _ = try self.rule_id_to_completable_states.push_row(&.{});
        try self.is_completed.append(self.gpa, completed);
        _ = try self.scanable_state_history.push_row(states);
        if (self.capture_tracking) {
            _ = try self.capture_event_history.push_row(&.{});
        }
        if (self.has_char_budget_rules) {
            try self.char_count_history.append(self.gpa, self.current_char_index());
            const entered = self.char_budget_entry_history.items[self.char_budget_entry_history.items.len - 1];
            try self.char_budget_entry_history.append(self.gpa, entered);
        }
    }

    /// Pushes a character-count row for a parser row created by the matcher.
    pub fn push_char_count_row(self: *EarleyParser, char_count: i32, char_budget_entered: bool) void {
        if (self.has_char_budget_rules) {
            self.char_count_history.append(self.gpa, char_count) catch unreachable;
            self.char_budget_entry_history.append(self.gpa, char_budget_entered) catch unreachable;
        }
    }

    /// The number of codepoints accepted so far.
    pub fn current_char_index(self: *const EarleyParser) i32 {
        if (self.char_count_history.items.len == 0) return 0;
        return self.char_count_history.items[self.char_count_history.items.len - 1];
    }

    /// Whether a character-budgeted occurrence was entered since the initial row.
    pub fn has_entered_char_budget(self: *const EarleyParser) bool {
        if (!self.has_char_budget_rules) return false;
        if (self.char_budget_entry_history.items.len == 0) return false;
        return self.char_budget_entry_history.items[self.char_budget_entry_history.items.len - 1];
    }

    /// Copies the capture events of the latest input position (deep copy; caller owns).
    pub fn copy_last_capture_row(self: *const EarleyParser, gpa: Allocator) Allocator.Error!ArrayList(CaptureEvent) {
        var out: ArrayList(CaptureEvent) = .empty;
        errdefer out.deinit(gpa);
        if (self.capture_tracking) {
            try out.ensureTotalCapacity(gpa, self.capture_event_history.back().len);
            for (self.capture_event_history.back()) |event|
                out.appendAssumeCapacity(try capture_event_mod.clone(event, gpa));
        }
        return out;
    }

    /// Pushes a new row of capture events, keeping the capture history aligned with the state
    /// history when a position is created outside of `advance`.
    pub fn push_capture_row(self: *EarleyParser, events: []const CaptureEvent) Allocator.Error!void {
        if (self.capture_tracking) {
            _ = try self.capture_event_history.push_row(events);
        }
    }

    /// A copy of the latest history row (deep; caller owns, see [`ParserRow.deinit`]).
    pub fn latest_row(self: *const EarleyParser, gpa: Allocator) Allocator.Error!ParserRow {
        var row = ParserRow{};
        errdefer row.deinit(gpa);
        try row.states.appendSlice(gpa, self.latest_scanable_states());
        try row.completable_states.appendSlice(gpa, self.latest_completable_states());
        row.completed = self.is_root_completed();
        row.capture_events = try self.copy_last_capture_row(gpa);
        return row;
    }

    /// Replaces the latest history row (used to restore a row after a failed tentative
    /// transition, or to commit an enforced one).
    pub fn replace_latest_row(self: *EarleyParser, row: ParserRow) Allocator.Error!void {
        self.scanable_state_history.pop_back(1);
        _ = try self.scanable_state_history.push_row(row.states.items);
        self.rule_id_to_completable_states.pop_back(1);
        _ = try self.rule_id_to_completable_states.push_row(row.completable_states.items);
        self.is_completed.items[self.is_completed.items.len - 1] = row.completed;
        if (self.capture_tracking) {
            self.capture_event_history.pop_back(1);
            _ = try self.capture_event_history.push_row(row.capture_events.items);
        }
    }

    /// A human-readable dump of the latest scanable states (caller owns).
    pub fn print_states(self: *const EarleyParser, gpa: Allocator) Allocator.Error![]u8 {
        var result: ArrayList(u8) = .empty;
        errdefer result.deinit(gpa);
        const w = result.writer(gpa);
        try w.print("There are {d} steps in history. Last step: [\n", .{self.scanable_state_history.len()});
        for (self.scanable_state_history.back()) |state| {
            const text = try state.display(gpa);
            defer gpa.free(text);
            try w.print("{s}, \n", .{text});
        }
        try result.appendSlice(gpa, "]");
        return result.toOwnedSlice(gpa);
    }
};

/// Whether `[min_codepoint, max_codepoint]` overlaps any range in a character-class payload.
fn ranges_overlap(class_data: []const i32, min_codepoint: i32, max_codepoint: i32) bool {
    var i: usize = 1;
    while (i + 1 < class_data.len) : (i += 2) {
        if (max_codepoint >= class_data[i] and min_codepoint <= class_data[i + 1]) return true;
    }
    return false;
}
