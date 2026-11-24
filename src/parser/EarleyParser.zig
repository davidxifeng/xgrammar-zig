//! Incremental Earley parser over an optimized grammar's per-rule FSMs, along with
//! `ParserState`, `ParserStateCacheKey`, `ParserRow`, `CompletableState`, `RepeatDetector`,
//! `CaptureEvent`, and `CaptureOccurrence`.
//!
//! Most live `ParserState` values have `rule_id >= 0` and scan FSM byte/token edges.
//! Lookahead assertions use the IR path (`rule_id == -1`) with `sequence_id` pointing at
//! the assertion expression; the parser predicts, scans, and completes those states over
//! the grammar expression tree in the classic Earley three-phase loop.
//!
//! The matcher and the token-mask cache builder drive the parser directly, so the fields
//! they inspect/update are public.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const fsm_mod = @import("../fsm.zig");
const grammar_mod = @import("../grammar.zig");
const support = @import("../support.zig");

const Compact2dArray = support.Compact2dArray;
const CompactFsmWithStartEndWithSize = fsm_mod.CompactFsmWithStartEndWithSize;
const Grammar = grammar_mod.Grammar;

/// Error set for Earley parser operations.
pub const EarleyError = Allocator.Error;

/// A concrete occurrence of a captured rule in an Earley parent chain.
pub const CaptureOccurrence = struct {
    /// The id of the captured rule.
    rule_id: i32,
    /// The position where the rule occurrence started.
    start_pos: i32,
};

/// Recorded when a captured (or capture-hiding) rule is completed during parsing.
///
/// The matched span is `[start_pos, r)` in input positions, where `r` is the history row
/// at which the event is recorded.
pub const CaptureEvent = struct {
    /// The id of the completed rule.
    rule_id: i32,
    /// The position where the rule started matching. `ParserState.NO_PREV_INPUT_POS` means
    /// position 0 (the rule acts as the root).
    start_pos: i32,
    /// The unadjusted start position of this rule occurrence. Differs from `start_pos` for
    /// the zero-width event inserted after a dynamic-dispatch marker.
    occurrence_start_pos: i32,
    /// Number of trailing bytes hidden only from this rule's own capture.
    hidden_suffix_bytes: i32,
    /// Number of trailing bytes hidden from every containing capture.
    hidden_stop_bytes: i32,
    /// The captured rule occurrences whose concrete Earley parent chains contain this stop
    /// completion. Includes this rule's occurrence when the rule itself is captured.
    stop_capture_targets: ArrayList(CaptureOccurrence) = .empty,

    /// Deep copy into `gpa`.
    pub fn dupe(self: CaptureEvent, gpa: Allocator) Allocator.Error!CaptureEvent {
        return .{
            .rule_id = self.rule_id,
            .start_pos = self.start_pos,
            .occurrence_start_pos = self.occurrence_start_pos,
            .hidden_suffix_bytes = self.hidden_suffix_bytes,
            .hidden_stop_bytes = self.hidden_stop_bytes,
            .stop_capture_targets = try self.stop_capture_targets.clone(gpa),
        };
    }

    /// Structural equality across fields and target list.
    pub fn eql(a: CaptureEvent, b: CaptureEvent) bool {
        if (a.rule_id != b.rule_id or a.start_pos != b.start_pos or
            a.occurrence_start_pos != b.occurrence_start_pos or
            a.hidden_suffix_bytes != b.hidden_suffix_bytes or
            a.hidden_stop_bytes != b.hidden_stop_bytes or
            a.stop_capture_targets.items.len != b.stop_capture_targets.items.len) return false;
        for (a.stop_capture_targets.items, b.stop_capture_targets.items) |x, y| {
            if (x.rule_id != y.rule_id or x.start_pos != y.start_pos) return false;
        }
        return true;
    }

    /// Releases the target list.
    pub fn deinit(self: *CaptureEvent, gpa: Allocator) void {
        self.stop_capture_targets.deinit(gpa);
    }
};

/// Adaptive token-mask cache key of a parser state.
///
/// Equality/hash cover `rule_id`, `sequence_id`, `element_id`, and `sub_element_id` only:
/// the token mask of a state does not depend on its start position, repeat count, partial
/// codepoint, budgets, or temperature.
pub const ParserStateCacheKey = struct {
    /// The rule's id.
    rule_id: i32,
    /// The rule body expression id.
    sequence_id: i32,
    /// The FSM node.
    element_id: i32,
    /// The sub element id.
    sub_element_id: i32,
};

/// One Earley item: a position within a rule's FSM plus the input position it began at.
pub const ParserState = struct {
    /// The rule's id (`-1` for an IR-path lookahead state).
    rule_id: i32,
    /// The rule body (or lookahead sequence) expression id.
    sequence_id: i32,
    /// The current FSM node (or element index in an IR sequence).
    element_id: i32,
    /// The input position the rule started at, or `NO_PREV_INPUT_POS` for the root.
    rule_start_pos: i32,
    /// The last token index this state's derivation may consume, from the token budget
    /// (`Rule.max_tokens`) of the rule it is inside; `-1` means unlimited.
    budget_deadline: i32,
    /// The id of the sub element in the current element of the sequence.
    sub_element_id: i32,
    /// The number of times the element is repeated (for repeat edges).
    repeat_count: i32,
    /// Partial codepoint accumulated during UTF-8 decoding for character classes.
    partial_codepoint: i32,
    /// The innermost active rule that specifies a sampling temperature, or `-1`.
    active_temperature_rule_id: i32,
    /// The absolute input codepoint position at which the active character budget expires;
    /// `-1` means unlimited.
    char_budget_deadline: i32,

    /// A `rule_start_pos` meaning the state is the root of the parsing stack.
    pub const NO_PREV_INPUT_POS: i32 = -1;

    /// Creates a state at `element_id` of `sequence_id` with no budgets, sub element, repeat
    /// count, partial codepoint, or temperature rule.
    pub fn init(
        rule_id: i32,
        sequence_id: i32,
        element_id: i32,
        rule_start_pos: i32,
    ) ParserState {
        return .{
            .rule_id = rule_id,
            .sequence_id = sequence_id,
            .element_id = element_id,
            .rule_start_pos = rule_start_pos,
            .budget_deadline = -1,
            .sub_element_id = 0,
            .repeat_count = 0,
            .partial_codepoint = 0,
            .active_temperature_rule_id = -1,
            .char_budget_deadline = -1,
        };
    }

    /// Same occurrence moved to `element_id`, resetting `sub_element_id`, `repeat_count`,
    /// and `partial_codepoint` (budgets and temperature rule are inherited).
    pub fn atElement(self: ParserState, element_id: i32) ParserState {
        return self.atElementWithRepeat(element_id, 0);
    }

    /// Same occurrence moved to `element_id` with an explicit `repeat_count`.
    pub fn atElementWithRepeat(self: ParserState, element_id: i32, repeat_count: i32) ParserState {
        var out = self;
        out.element_id = element_id;
        out.sub_element_id = 0;
        out.repeat_count = repeat_count;
        out.partial_codepoint = 0;
        return out;
    }

    /// Only changes `element_id`, leaving all other fields intact.
    pub fn withElement(self: ParserState, element_id: i32) ParserState {
        var out = self;
        out.element_id = element_id;
        return out;
    }

    /// The adaptive token-mask cache key of this state.
    pub fn cacheKey(self: ParserState) ParserStateCacheKey {
        return .{
            .rule_id = self.rule_id,
            .sequence_id = self.sequence_id,
            .element_id = self.element_id,
            .sub_element_id = self.sub_element_id,
        };
    }

    /// Serializes as the C++ `XGRAMMAR_MEMBER_ARRAY` order.
    pub inline fn serializeMemberArray(self: ParserState) [10]i32 {
        return .{
            self.rule_id,
            self.sequence_id,
            self.element_id,
            self.rule_start_pos,
            self.budget_deadline,
            self.sub_element_id,
            self.repeat_count,
            self.partial_codepoint,
            self.active_temperature_rule_id,
            self.char_budget_deadline,
        };
    }

    /// Deserializes a member array produced by `serializeMemberArray`.
    /// Returns `null` unless `values` contains exactly ten integers.
    pub fn fromMemberArray(values: []const i32) ?ParserState {
        if (values.len != 10) return null;
        return .{
            .rule_id = values[0],
            .sequence_id = values[1],
            .element_id = values[2],
            .rule_start_pos = values[3],
            .budget_deadline = values[4],
            .sub_element_id = values[5],
            .repeat_count = values[6],
            .partial_codepoint = values[7],
            .active_temperature_rule_id = values[8],
            .char_budget_deadline = values[9],
        };
    }

    /// Structural equality across all 10 fields.
    pub fn eql(a: ParserState, b: ParserState) bool {
        return std.meta.eql(a.serializeMemberArray(), b.serializeMemberArray());
    }

    /// Lexicographic ordering over fields in declaration order (used for deterministic sorting).
    pub fn lessThan(a: ParserState, b: ParserState) bool {
        return std.mem.order(i32, &a.serializeMemberArray(), &b.serializeMemberArray()) == .lt;
    }

    /// Streams the human-readable representation (`{f}` formatting).
    pub fn format(self: ParserState, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print(
            "ParserState(rule_id={d}, sequence_id={d}, element_id={d}, rule_start_pos={d}, sub_element_id={d}",
            .{ self.rule_id, self.sequence_id, self.element_id, self.rule_start_pos, self.sub_element_id },
        );
        if (self.repeat_count != 0) try writer.print(", repeat_count={d}", .{self.repeat_count});
        if (self.partial_codepoint != 0) try writer.print(", partial_codepoint={d}", .{self.partial_codepoint});
        if (self.budget_deadline != -1) try writer.print(", budget_deadline={d}", .{self.budget_deadline});
        if (self.active_temperature_rule_id != -1) {
            try writer.print(", active_temperature_rule_id={d}", .{self.active_temperature_rule_id});
        }
        if (self.char_budget_deadline != -1) {
            try writer.print(", char_budget_deadline={d}", .{self.char_budget_deadline});
        }
        try writer.writeAll(")");
    }

    /// Returns the human-readable representation allocated from `gpa` (caller owns).
    pub fn display(self: ParserState, gpa: Allocator) Allocator.Error![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        self.format(&aw.writer) catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }
};

/// One completable parent pair `(referenced_rule_id, parent_state)`.
pub const CompletableState = struct {
    referenced_rule_id: i32,
    parent_state: ParserState,
};

/// The parser state recorded at one input position: the scanable states, the completable
/// parent pairs, whether the root rule is completed, and the capture events.
pub const ParserRow = struct {
    /// The scanable states.
    states: ArrayList(ParserState) = .empty,
    /// The `(referenced_rule_id, parent_state)` pairs awaiting completion.
    completable_states: ArrayList(CompletableState) = .empty,
    /// Whether the root rule is completed.
    completed: bool = false,
    /// The capture events recorded at this position.
    capture_events: ArrayList(CaptureEvent) = .empty,

    /// Deep copy into `gpa`.
    pub fn dupe(self: ParserRow, gpa: Allocator) Allocator.Error!ParserRow {
        var out: ParserRow = .{
            .states = try self.states.clone(gpa),
            .completable_states = .empty,
            .completed = self.completed,
            .capture_events = .empty,
        };
        errdefer out.deinit(gpa);
        out.completable_states = try self.completable_states.clone(gpa);
        try out.capture_events.ensureTotalCapacity(gpa, self.capture_events.items.len);
        for (self.capture_events.items) |event| {
            out.capture_events.appendAssumeCapacity(try event.dupe(gpa));
        }
        return out;
    }

    /// Structural equality across all row fields.
    pub fn eql(a: ParserRow, b: ParserRow) bool {
        if (a.completed != b.completed) return false;
        if (a.states.items.len != b.states.items.len) return false;
        for (a.states.items, b.states.items) |x, y| {
            if (!x.eql(y)) return false;
        }
        if (a.completable_states.items.len != b.completable_states.items.len) return false;
        for (a.completable_states.items, b.completable_states.items) |x, y| {
            if (x.referenced_rule_id != y.referenced_rule_id or !x.parent_state.eql(y.parent_state)) return false;
        }
        if (a.capture_events.items.len != b.capture_events.items.len) return false;
        for (a.capture_events.items, b.capture_events.items) |x, y| {
            if (!x.eql(y)) return false;
        }
        return true;
    }

    /// Releases all owned lists.
    pub fn deinit(self: *ParserRow, gpa: Allocator) void {
        self.states.deinit(gpa);
        self.completable_states.deinit(gpa);
        for (self.capture_events.items) |*event| event.deinit(gpa);
        self.capture_events.deinit(gpa);
    }
};

/// The number of states scanned linearly before switching to the hash set.
const TRANSITION_THRESHOLD: usize = 50;

/// A set of visited parser states used to deduplicate the processing queue.
/// Small rounds scan linearly and promote to a hash set once `TRANSITION_THRESHOLD` is exceeded.
pub const RepeatDetector = struct {
    visited_vector: ArrayList(ParserState) = .empty,
    visited_set: std.AutoHashMapUnmanaged(ParserState, void) = .empty,

    /// Creates an empty detector.
    pub fn init() RepeatDetector {
        return .{};
    }

    /// Whether `state` has already been inserted.
    pub fn isVisited(self: *const RepeatDetector, state: ParserState) bool {
        if (self.visited_vector.items.len > TRANSITION_THRESHOLD) {
            return self.visited_set.contains(state);
        }
        // Compare whole states at once: states queued together usually share their leading
        // fields, so a field-by-field comparison branches deep and mispredicts.
        const key = state.serializeMemberArray();
        for (self.visited_vector.items) |visited| {
            const fields = visited.serializeMemberArray();
            var differences: i32 = 0;
            for (fields, key) |a, b| differences |= a ^ b;
            if (differences == 0) return true;
        }
        return false;
    }

    /// Records `state` as visited.
    pub fn insert(self: *RepeatDetector, gpa: Allocator, state: ParserState) Allocator.Error!void {
        if (self.visited_vector.items.len == TRANSITION_THRESHOLD) {
            try self.visited_set.ensureTotalCapacity(gpa, @intCast(self.visited_vector.items.len * 2));
            for (self.visited_vector.items) |visited|
                self.visited_set.putAssumeCapacity(visited, {});
        }
        if (self.visited_vector.items.len >= TRANSITION_THRESHOLD) {
            try self.visited_set.put(gpa, state, {});
        }
        try self.visited_vector.append(gpa, state);
    }

    /// Clears all recorded states while retaining capacity.
    pub fn clear(self: *RepeatDetector) void {
        if (self.visited_vector.items.len > TRANSITION_THRESHOLD) {
            self.visited_set.clearRetainingCapacity();
        }
        self.visited_vector.clearRetainingCapacity();
    }

    /// Releases both containers.
    pub fn deinit(self: *RepeatDetector, gpa: Allocator) void {
        self.visited_vector.deinit(gpa);
        self.visited_set.deinit(gpa);
    }
};

const FSM_STATE_INITIALIZED: u8 = 1 << 0;
const FSM_STATE_SCANABLE: u8 = 1 << 1;
const FSM_STATE_NON_TERMINAL: u8 = 1 << 2;
const FSM_STATE_END: u8 = 1 << 3;
const FSM_STATE_HAS_EDGES: u8 = 1 << 4;

/// An incremental Earley parser over an optimized grammar's per-rule FSMs.
pub const EarleyParser = struct {
    gpa: Allocator,
    /// The optimized grammar being parsed (borrowed; must outlive the parser).
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
    /// Scratch: the processing queue.
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

    /// One lazy occurrence `(rule_id, rule_start_pos)`.
    pub const LazyOccurrence = struct {
        rule_id: i32,
        rule_start_pos: i32,
    };

    /// Creates a parser over an optimized `grammar`, starting from `initial_state` or, if
    /// `null`, from the root rule.
    pub fn init(
        gpa: Allocator,
        grammar: *const Grammar,
        initial_state: ?ParserState,
    ) Allocator.Error!EarleyParser {
        std.debug.assert(grammar.isOptimized());
        const num_rules = grammar.numRules();
        const has_budget_rules = blk: {
            for (grammar.rulesSlice()) |rule| {
                if (rule.max_tokens >= 0) break :blk true;
            }
            break :blk false;
        };
        const has_char_budget_rules = blk: {
            for (grammar.rulesSlice()) |rule| {
                if (rule.max_chars >= 0) break :blk true;
            }
            break :blk false;
        };
        const capture_tracking = blk: {
            for (grammar.rulesSlice()) |rule| {
                if (rule.capture_name.len != 0) break :blk true;
            }
            for (grammar.suffixStopInfosSlice()) |info| {
                if (info.stop_capture_name.len != 0) break :blk true;
            }
            break :blk false;
        };
        const has_hidden_capture_rules = blk: {
            for (grammar.suffixStopInfosSlice()) |info| {
                if (info.hidden_suffix_bytes > 0 or info.hidden_stop_bytes > 0) break :blk true;
            }
            break :blk false;
        };

        var transferred = false;

        const rule_is_nullable = try gpa.alloc(bool, num_rules);
        errdefer if (!transferred) gpa.free(rule_is_nullable);
        @memset(rule_is_nullable, false);
        for (grammar.allowEmptyRuleIdsSlice()) |rule_id| {
            rule_is_nullable[@intCast(rule_id)] = true;
        }

        var completable = try Compact2dArray(CompletableState).init(gpa);
        errdefer if (!transferred) completable.deinit(gpa);

        var scanable = try Compact2dArray(ParserState).init(gpa);
        errdefer if (!transferred) scanable.deinit(gpa);

        var capture_history = try Compact2dArray(CaptureEvent).init(gpa);
        errdefer if (!transferred) capture_history.deinit(gpa);

        var state_offsets = try grammar.fsmStateOffsets(gpa);
        errdefer if (!transferred) state_offsets.deinit(gpa);

        var parser: EarleyParser = .{
            .gpa = gpa,
            .grammar = grammar,
            .tmp_accept_stop_token = false,
            .is_completed = .empty,
            .rule_id_to_completable_states = completable,
            .scanable_state_history = scanable,
            .tmp_states_to_be_added = .empty,
            .tmp_process_state_queue = .empty,
            .tmp_states_visited_in_queue = .{},
            .stop_token_is_accepted = false,
            .fsm_state_flags_cache = .empty,
            .fsm_state_offsets = state_offsets,
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
            .capture_event_history = capture_history,
            .tmp_completed_lazy_occurrences = .empty,
        };
        transferred = true;
        errdefer parser.deinit();

        const initial = initial_state orelse parser.rootInitialState();
        try parser.pushStateAndExpand(initial);
        return parser;
    }

    fn freeCaptureRowsFrom(self: *EarleyParser, first_row: usize) void {
        if (!self.capture_tracking) return;
        var r = first_row;
        while (r < self.capture_event_history.len()) : (r += 1) {
            for (self.capture_event_history.rowMut(r)) |*ev| {
                ev.deinit(self.gpa);
            }
        }
    }

    /// Deep-copies the parser state into `gpa`, borrowing the same `grammar`.
    pub fn dupe(self: *const EarleyParser, gpa: Allocator) Allocator.Error!EarleyParser {
        var transferred = false;

        const rule_is_nullable = try gpa.dupe(bool, self.rule_is_nullable);
        errdefer if (!transferred) gpa.free(rule_is_nullable);

        var is_completed: ArrayList(bool) = .empty;
        errdefer if (!transferred) is_completed.deinit(gpa);
        try is_completed.appendSlice(gpa, self.is_completed.items);

        var completable = try self.rule_id_to_completable_states.dupe(gpa);
        errdefer if (!transferred) completable.deinit(gpa);

        var scanable = try self.scanable_state_history.dupe(gpa);
        errdefer if (!transferred) scanable.deinit(gpa);

        var flags_cache: ArrayList(u64) = .empty;
        errdefer if (!transferred) flags_cache.deinit(gpa);
        try flags_cache.appendSlice(gpa, self.fsm_state_flags_cache.items);

        var state_offsets: ArrayList(usize) = .empty;
        errdefer if (!transferred) state_offsets.deinit(gpa);
        try state_offsets.appendSlice(gpa, self.fsm_state_offsets.items);

        var char_counts: ArrayList(i32) = .empty;
        errdefer if (!transferred) char_counts.deinit(gpa);
        try char_counts.appendSlice(gpa, self.char_count_history.items);

        var char_entries: ArrayList(bool) = .empty;
        errdefer if (!transferred) char_entries.deinit(gpa);
        try char_entries.appendSlice(gpa, self.char_budget_entry_history.items);

        const src_captures = self.capture_event_history.dataSlice();
        const cloned_captures_buf = try gpa.alloc(CaptureEvent, src_captures.len);
        defer gpa.free(cloned_captures_buf);
        var cloned_count: usize = 0;
        errdefer for (cloned_captures_buf[0..cloned_count]) |*ev| ev.deinit(gpa);
        for (src_captures, 0..) |ev, i| {
            cloned_captures_buf[i] = try ev.dupe(gpa);
            cloned_count += 1;
        }
        const capture_history = Compact2dArray(CaptureEvent).initFromDataAndIndptr(
            gpa,
            cloned_captures_buf,
            self.capture_event_history.indptrSlice(),
        ) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };
        cloned_count = 0;
        transferred = true;

        return .{
            .gpa = gpa,
            .grammar = self.grammar,
            .tmp_accept_stop_token = self.tmp_accept_stop_token,
            .is_completed = is_completed,
            .rule_id_to_completable_states = completable,
            .scanable_state_history = scanable,
            .tmp_states_to_be_added = .empty,
            .tmp_process_state_queue = .empty,
            .tmp_states_visited_in_queue = .{},
            .stop_token_is_accepted = self.stop_token_is_accepted,
            .fsm_state_flags_cache = flags_cache,
            .fsm_state_offsets = state_offsets,
            .rule_is_nullable = rule_is_nullable,
            .current_token_index = self.current_token_index,
            .skip_expired_states = self.skip_expired_states,
            .has_budget_rules = self.has_budget_rules,
            .char_count_history = char_counts,
            .has_char_budget_rules = self.has_char_budget_rules,
            .char_budget_entry_history = char_entries,
            .tmp_char_budget_entered = self.tmp_char_budget_entered,
            .capture_tracking = self.capture_tracking,
            .has_hidden_capture_rules = self.has_hidden_capture_rules,
            .capture_recording = self.capture_recording,
            .capture_event_history = capture_history,
            .tmp_completed_lazy_occurrences = .empty,
        };
    }

    /// Releases all allocations owned by the parser.
    pub fn deinit(self: *EarleyParser) void {
        const gpa = self.gpa;
        self.freeCaptureRowsFrom(0);
        self.is_completed.deinit(gpa);
        self.rule_id_to_completable_states.deinit(gpa);
        self.scanable_state_history.deinit(gpa);
        self.tmp_states_to_be_added.deinit(gpa);
        self.tmp_process_state_queue.deinit(gpa);
        self.tmp_states_visited_in_queue.deinit(gpa);
        self.fsm_state_flags_cache.deinit(gpa);
        self.fsm_state_offsets.deinit(gpa);
        gpa.free(self.rule_is_nullable);
        self.char_count_history.deinit(gpa);
        self.char_budget_entry_history.deinit(gpa);
        self.capture_event_history.deinit(gpa);
        self.tmp_completed_lazy_occurrences.deinit(gpa);
        self.* = undefined;
    }

    /// Whether the root rule is currently completed (the stop token is acceptable).
    pub fn isRootCompleted(self: *const EarleyParser) bool {
        return self.is_completed.items[self.is_completed.items.len - 1];
    }

    /// The scanable states at the latest position (borrowed from the history).
    pub fn latestScanableStates(self: *const EarleyParser) []const ParserState {
        return self.scanable_state_history.back();
    }

    /// The `(referenced_rule_id, parent_state)` completable pairs at the latest position
    /// (borrowed from the history).
    pub fn latestCompletableStates(self: *const EarleyParser) []const CompletableState {
        return self.rule_id_to_completable_states.back();
    }

    /// Whether the stop token has been accepted.
    pub fn isStopTokenAccepted(self: *const EarleyParser) bool {
        return self.stop_token_is_accepted;
    }

    fn perRuleFsm(self: *const EarleyParser, rule_id: i32) *const CompactFsmWithStartEndWithSize {
        return self.grammar.perRuleFsm(rule_id) orelse @panic("per-rule FSM missing");
    }

    /// Whether completing the occurrence of a suffix/stop rule actually consumed its trailing
    /// marker. A non-looping tag dispatch can also complete before its trigger is seen; only
    /// the terminal post-dispatch state has no outgoing edges.
    fn completionConsumedMarker(self: *const EarleyParser, state: ParserState) bool {
        const body = self.grammar.expr(self.grammar.rule(state.rule_id).body_expr_id);
        if (body.ty != .TagDispatch) return true;
        return self.perRuleFsm(state.rule_id).stateEdges(state.element_id).len == 0;
    }

    /// Collects the captured rule occurrences whose concrete Earley parent chains contain the
    /// given stop completion, following only the parent links of this occurrence.
    fn collectStopCaptureTargets(
        self: *EarleyParser,
        state: ParserState,
    ) Allocator.Error!ArrayList(CaptureOccurrence) {
        var targets: ArrayList(CaptureOccurrence) = .empty;
        errdefer targets.deinit(self.gpa);
        var pending: ArrayList(CaptureOccurrence) = .empty;
        defer pending.deinit(self.gpa);
        try pending.append(self.gpa, .{ .rule_id = state.rule_id, .start_pos = state.rule_start_pos });
        var visited: std.AutoHashMapUnmanaged(CaptureOccurrence, void) = .empty;
        defer visited.deinit(self.gpa);
        while (pending.pop()) |occurrence| {
            if ((try visited.getOrPut(self.gpa, occurrence)).found_existing) continue;
            if (self.ruleHasCapture(occurrence.rule_id)) {
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
    fn recordCaptureEvent(self: *EarleyParser, state: ParserState, marker_present: bool) Allocator.Error!void {
        const info = self.grammar.suffixStopInfo(state.rule_id);
        const marker_consumed = marker_present and info != null and
            (info.?.hidden_suffix_bytes > 0 or info.?.hidden_stop_bytes > 0) and
            self.completionConsumedMarker(state);
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
            stop_capture_targets = try self.collectStopCaptureTargets(state);
        }
        try self.capture_event_history.pushInLatestRow(self.gpa, .{
            .rule_id = state.rule_id,
            .start_pos = event_start_pos,
            .occurrence_start_pos = state.rule_start_pos,
            .hidden_suffix_bytes = hidden_suffix_bytes,
            .hidden_stop_bytes = hidden_stop_bytes,
            .stop_capture_targets = stop_capture_targets,
        });
    }

    fn resolveActiveTemperatureRule(self: *const EarleyParser, rule_id: i32, inherited_rule_id: i32) i32 {
        if (self.grammar.rule(rule_id).temperature != null) {
            return rule_id;
        } else {
            return inherited_rule_id;
        }
    }

    fn ruleHasCapture(self: *const EarleyParser, rule_id: i32) bool {
        return self.capture_tracking and rule_id >= 0 and
            self.grammar.rule(rule_id).capture_name.len != 0;
    }

    fn ruleHasHiddenBytes(self: *const EarleyParser, rule_id: i32) bool {
        if (!self.capture_tracking or !self.has_hidden_capture_rules or rule_id < 0) return false;
        const info = self.grammar.suffixStopInfo(rule_id) orelse return false;
        return info.hidden_suffix_bytes > 0 or info.hidden_stop_bytes > 0;
    }

    fn ruleNeedsCaptureEvent(self: *const EarleyParser, rule_id: i32) bool {
        return self.ruleHasCapture(rule_id) or self.ruleHasHiddenBytes(rule_id);
    }

    /// Whether the state's derivation may not consume the next token.
    pub fn isExpiredState(self: *const EarleyParser, state: ParserState) bool {
        return state.budget_deadline >= 0 and self.current_token_index > state.budget_deadline;
    }

    /// Whether the state's derivation may not consume another Unicode codepoint.
    pub fn isCharExpiredState(self: *const EarleyParser, state: ParserState) bool {
        return state.char_budget_deadline >= 0 and self.currentCharIndex() >= state.char_budget_deadline;
    }

    /// The deadline for a newly predicted occurrence of the rule: its own budget counted from
    /// the current token, capped by the parent's deadline for nested budgets.
    fn deadlineForRule(self: *const EarleyParser, rule_id: i32, parent_deadline: i32) i32 {
        const own = self.grammar.rule(rule_id).max_tokens;
        if (own < 0) return parent_deadline;
        const deadline = @min(@as(i64, self.current_token_index) + @as(i64, own), @as(i64, std.math.maxInt(i32)));
        if (parent_deadline >= 0) {
            return @intCast(@min(deadline, @as(i64, parent_deadline)));
        }
        return @intCast(deadline);
    }

    /// The character deadline for a newly predicted rule occurrence.
    fn charDeadlineForRule(self: *const EarleyParser, rule_id: i32, parent_deadline: i32) i32 {
        const own = self.grammar.rule(rule_id).max_chars;
        if (own < 0) return parent_deadline;
        const deadline = std.math.add(i32, self.currentCharIndex(), own) catch std.math.maxInt(i32);
        if (parent_deadline >= 0) {
            return @min(deadline, parent_deadline);
        }
        return deadline;
    }

    /// Whether `byte` starts a UTF-8 codepoint (is not a continuation byte).
    pub fn startsUtf8Codepoint(byte: u8) bool {
        return (byte & 0xC0) != 0x80;
    }

    /// Removes the last `count` recorded positions.
    pub fn popLastStates(self: *EarleyParser, count: i32) void {
        self.stop_token_is_accepted = false;
        const n: usize = @intCast(count);
        std.debug.assert(n < self.rule_id_to_completable_states.len());
        self.rule_id_to_completable_states.popBack(n);
        self.is_completed.shrinkRetainingCapacity(self.is_completed.items.len - n);
        self.scanable_state_history.popBack(n);
        if (self.capture_tracking) {
            const len = self.capture_event_history.len();
            self.freeCaptureRowsFrom(len - n);
            self.capture_event_history.popBack(n);
        }
        if (self.has_char_budget_rules) {
            self.char_count_history.shrinkRetainingCapacity(self.char_count_history.items.len - n);
            self.char_budget_entry_history.shrinkRetainingCapacity(self.char_budget_entry_history.items.len - n);
        }
    }

    /// The completion operation of the Earley parser: advances the parents waiting for the
    /// completed rule. `marker_present` is false when a suffix/stop rule is force-completed
    /// without its trailing marker.
    pub fn complete(self: *EarleyParser, state: ParserState, marker_present: bool) Allocator.Error!void {
        // Record capture and hidden-span events, only during definitive advances.
        if (self.capture_recording and self.ruleNeedsCaptureEvent(state.rule_id)) {
            try self.recordCaptureEvent(state, marker_present);
        }
        if (state.rule_id != -1 and self.grammar.rule(state.rule_id).is_lazy) {
            try self.tmp_completed_lazy_occurrences.append(self.gpa, .{
                .rule_id = state.rule_id,
                .rule_start_pos = state.rule_start_pos,
            });
        }
        if (state.rule_start_pos == ParserState.NO_PREV_INPUT_POS) {
            self.tmp_accept_stop_token = true;
            return;
        }
        // Completion only enqueues, so the parent row does not change while it is walked.
        const range = self.rule_id_to_completable_states.rowRange(@intCast(state.rule_start_pos));
        for (self.rule_id_to_completable_states.dataSlice()[range.start..range.end]) |entry| {
            const ref_id = entry.referenced_rule_id;
            const parent_state = entry.parent_state;
            if (ref_id != state.rule_id) continue;
            if (parent_state.rule_id == -1) {
                const parent_expr = self.grammar.expr(parent_state.sequence_id);
                const element_expr = self.grammar.expr(parent_expr.data[@intCast(parent_state.element_id)]);
                std.debug.assert(element_expr.ty == .RuleRef or element_expr.ty == .Repeat);
                if (element_expr.ty == .RuleRef) {
                    try self.enqueue(parent_state.atElement(parent_state.element_id + 1));
                    continue;
                }
                const repeat_spec = element_expr.repeat();
                var new_state = parent_state;
                new_state.repeat_count += 1;
                if (new_state.repeat_count >= repeat_spec.min_repeat) {
                    try self.enqueue(parent_state.atElement(parent_state.element_id + 1));
                }
                if (new_state.repeat_count < repeat_spec.max_repeat) {
                    try self.enqueue(new_state);
                }
                continue;
            }
            // The rule is referenced by an FSM: check whether the parent sits on a repeat edge
            // (by invariance, a state with a repeat edge has exactly one outgoing edge).
            const fsm = self.grammar.completeFsm();
            var repeat: ?struct { target: i32, lower: i32, upper: i32 } = null;
            for (fsm.stateEdges(parent_state.element_id)) |edge| {
                if (!edge.isRepeatRef()) continue;
                const info = fsm.repeatEdgeInfo(edge.auxIndex());
                if (info.ruleId() == ref_id) {
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
                try self.enqueue(parent_state.atElement(found.target));
            }
            if (new_count < found.upper) {
                try self.enqueue(parent_state.atElementWithRepeat(parent_state.element_id, new_count));
            }
        }
    }

    /// The prediction operation of the Earley parser. Returns `(scanable, completable)`.
    pub fn predict(self: *EarleyParser, state: ParserState) Allocator.Error!struct { scanable: bool, completable: bool } {
        if (state.rule_id != -1) {
            const flags = try self.fsmStateFlags(state.rule_id, state.element_id);
            if (flags & FSM_STATE_NON_TERMINAL != 0) {
                try self.expandNextRuleRefElementOnFsm(state);
            }
            return .{
                .scanable = flags & FSM_STATE_SCANABLE != 0,
                .completable = flags & FSM_STATE_END != 0,
            };
        }
        const grammar_expr = self.grammar.expr(state.sequence_id);
        std.debug.assert(grammar_expr.ty == .Sequence or grammar_expr.ty == .EmptyStr);
        if (state.element_id == @as(i32, @intCast(grammar_expr.len()))) {
            return .{ .scanable = false, .completable = true };
        }
        const element_expr_id = grammar_expr.data[@intCast(state.element_id)];
        const element_expr = self.grammar.expr(element_expr_id);
        switch (element_expr.ty) {
            .RuleRef => {
                try self.expandNextRuleRefElement(state, state.sequence_id, element_expr_id);
                return .{ .scanable = false, .completable = false };
            },
            .CharacterClassStar => {
                if (state.sub_element_id == 0) {
                    try self.enqueue(state.atElement(state.element_id + 1));
                }
                return .{ .scanable = true, .completable = false };
            },
            .Repeat => {
                const repeat_spec = element_expr.repeat();
                std.debug.assert(state.repeat_count <= repeat_spec.max_repeat);
                try self.expandNextRuleRefElement(state, state.sequence_id, element_expr_id);
                if (state.repeat_count >= repeat_spec.min_repeat) {
                    try self.enqueue(state.atElement(state.element_id + 1));
                }
                return .{ .scanable = false, .completable = false };
            },
            .ByteString, .CharacterClass => return .{ .scanable = true, .completable = false },
            .Token, .ExcludeToken => return .{ .scanable = false, .completable = false },
            else => {
                std.debug.panic("The element type is not supported! The type is: {s}", .{@tagName(element_expr.ty)});
            },
        }
    }

    fn scan(self: *EarleyParser, state: ParserState, ch: u8) Allocator.Error!void {
        if (state.rule_id != -1) {
            try self.advanceFsm(state, ch);
            return;
        }
        const element_expr_id = self.grammar.expr(state.sequence_id).data[@intCast(state.element_id)];
        switch (self.grammar.expr(element_expr_id).ty) {
            .ByteString => try self.advanceByteString(state, ch, element_expr_id),
            .CharacterClass => try self.advanceCharacterClass(state, ch, element_expr_id),
            .CharacterClassStar => try self.advanceCharacterClassStar(state, ch, element_expr_id),
            else => {
                std.debug.panic("The element type is not supported! The type is: {s}", .{@tagName(self.grammar.expr(element_expr_id).ty)});
            },
        }
    }

    /// Runs the predict/complete loop over the processing queue.
    pub fn processQueue(self: *EarleyParser) Allocator.Error!void {
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
    pub fn advance(self: *EarleyParser, ch: u8) Allocator.Error!bool {
        std.debug.assert(self.tmp_process_state_queue.len == 0);
        self.tmp_states_visited_in_queue.clear();
        self.tmp_states_to_be_added.clearRetainingCapacity();
        self.tmp_accept_stop_token = false;
        self.tmp_completed_lazy_occurrences.clearRetainingCapacity();
        if (self.has_char_budget_rules) {
            self.tmp_char_budget_entered = self.char_budget_entry_history.items[self.char_budget_entry_history.items.len - 1];
            try self.char_count_history.append(self.gpa, self.currentCharIndex() + @as(i32, @intFromBool(startsUtf8Codepoint(ch))));
        }
        // Scanning only queues states, so the latest row does not change while it is walked.
        const range = self.scanable_state_history.rowRange(self.scanable_state_history.len() - 1);
        for (self.scanable_state_history.dataSlice()[range.start..range.end]) |state| {
            if (self.skip_expired_states and self.isExpiredState(state)) continue;
            try self.scan(state, ch);
        }
        if (self.tmp_process_state_queue.len == 0 and self.tmp_states_to_be_added.items.len == 0) {
            if (self.has_char_budget_rules) {
                _ = self.char_count_history.pop();
            }
            return false;
        }
        _ = try self.rule_id_to_completable_states.pushRow(self.gpa, &.{});
        if (self.capture_tracking) {
            _ = try self.capture_event_history.pushRow(self.gpa, &.{});
        }
        try self.processQueue();
        try self.finishRow(false);
        return true;
    }

    /// Finalizes the row built by the processing loop: removes committed lazy states and
    /// records completion, scanable states and (unless already pushed) the character rows.
    fn finishRow(self: *EarleyParser, push_char_count: bool) Allocator.Error!void {
        if (self.tmp_completed_lazy_occurrences.items.len != 0) {
            self.removeCommittedLazyStates();
        }
        try self.is_completed.append(self.gpa, self.tmp_accept_stop_token);
        _ = try self.scanable_state_history.pushRow(self.gpa, self.tmp_states_to_be_added.items);
        if (self.has_char_budget_rules) {
            if (push_char_count) {
                try self.char_count_history.append(self.gpa, self.currentCharIndex());
            }
            try self.char_budget_entry_history.append(self.gpa, self.tmp_char_budget_entered);
        }
    }

    /// Removes the states of the lazy occurrences completed in the current row
    /// (committed-shortest matching).
    pub fn removeCommittedLazyStates(self: *EarleyParser) void {
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

    fn fsmStateFlags(self: *EarleyParser, rule_id: i32, state_id: i32) Allocator.Error!u8 {
        const index = self.fsm_state_offsets.items[@intCast(rule_id)] + @as(usize, @intCast(state_id));
        if (index < self.fsm_state_flags_cache.items.len) {
            const entry = self.fsm_state_flags_cache.items[index];
            if (entry & 0xFF != 0 and entry >> 8 == @as(u64, @intCast(rule_id))) {
                return @truncate(entry);
            }
        }
        return self.initializeFsmStateFlags(rule_id, state_id);
    }

    fn initializeFsmStateFlags(self: *EarleyParser, rule_id: i32, state_id: i32) Allocator.Error!u8 {
        const fsm = self.perRuleFsm(rule_id);
        const offset = self.fsm_state_offsets.items[@intCast(rule_id)];
        const required_len = offset + @as(usize, @intCast(fsm.numStates()));
        if (self.fsm_state_flags_cache.items.len < required_len) {
            try self.fsm_state_flags_cache.appendNTimes(
                self.gpa,
                0,
                required_len - self.fsm_state_flags_cache.items.len,
            );
        }
        var flags = FSM_STATE_INITIALIZED;
        if (fsm.isEndState(state_id)) {
            flags |= FSM_STATE_END;
        }
        const edges = fsm.stateEdges(state_id);
        if (edges.len != 0) {
            flags |= FSM_STATE_HAS_EDGES;
        }
        for (edges) |edge| {
            if (edge.isCharRange() or edge.isToken() or edge.isExcludeToken()) {
                flags |= FSM_STATE_SCANABLE;
            } else if (edge.isRuleRef() or edge.isEpsilon() or edge.isRepeatRef()) {
                flags |= FSM_STATE_NON_TERMINAL;
            }
        }
        self.fsm_state_flags_cache.items[offset + @as(usize, @intCast(state_id))] =
            @as(u64, @intCast(rule_id)) << 8 | flags;
        return flags;
    }

    /// The initial state expanded from the root rule of the grammar.
    pub fn rootInitialState(self: *const EarleyParser) ParserState {
        const root_rule_id = self.grammar.rootRuleId();
        var state = ParserState.init(
            root_rule_id,
            self.grammar.rootRule().body_expr_id,
            self.perRuleFsm(root_rule_id).startState(),
            ParserState.NO_PREV_INPUT_POS,
        );
        state.budget_deadline = self.deadlineForRule(root_rule_id, -1);
        state.active_temperature_rule_id = self.resolveActiveTemperatureRule(root_rule_id, -1);
        state.char_budget_deadline = self.charDeadlineForRule(root_rule_id, -1);
        return state;
    }

    /// Pushes `state` and expands it through the predict/complete loop into a new position.
    pub fn pushStateAndExpand(self: *EarleyParser, state: ParserState) Allocator.Error!void {
        self.tmp_states_visited_in_queue.clear();
        self.tmp_accept_stop_token = false;
        self.tmp_states_to_be_added.clearRetainingCapacity();
        self.tmp_completed_lazy_occurrences.clearRetainingCapacity();
        try self.enqueue(state);
        _ = try self.rule_id_to_completable_states.pushRow(self.gpa, &.{});
        if (self.capture_tracking) {
            _ = try self.capture_event_history.pushRow(self.gpa, &.{});
        }
        try self.processQueue();
        try self.finishRow(true);
    }

    /// Clears dynamic parsing history while retaining grammar-derived caches and container
    /// capacities, then expands `initial_state`.
    pub fn resetWithInitialState(self: *EarleyParser, initial_state: ParserState) Allocator.Error!void {
        self.freeCaptureRowsFrom(0);
        self.is_completed.clearRetainingCapacity();
        self.rule_id_to_completable_states.popBack(self.rule_id_to_completable_states.len());
        self.scanable_state_history.popBack(self.scanable_state_history.len());
        self.capture_event_history.popBack(self.capture_event_history.len());
        self.char_count_history.clearRetainingCapacity();
        self.char_budget_entry_history.clearRetainingCapacity();
        self.tmp_states_to_be_added.clearRetainingCapacity();
        self.tmp_process_state_queue.head = 0;
        self.tmp_process_state_queue.len = 0;
        self.tmp_states_visited_in_queue.clear();
        self.tmp_completed_lazy_occurrences.clearRetainingCapacity();
        self.stop_token_is_accepted = false;
        self.tmp_accept_stop_token = false;
        self.tmp_char_budget_entered = false;
        self.current_token_index = -1;
        self.skip_expired_states = false;
        self.capture_recording = false;
        try self.pushStateAndExpand(initial_state);
    }

    /// Resets the parser to the freshly-expanded root rule.
    pub fn reset(self: *EarleyParser) Allocator.Error!void {
        return self.resetWithInitialState(self.rootInitialState());
    }

    /// Records the completable parent pairs for a predicted rule reference, applying the
    /// right-recursion optimization when allowed. Returns whether the child becomes a root.
    fn addCompletableParents(
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
            self.ruleNeedsCaptureEvent(state.rule_id) or self.ruleNeedsCaptureEvent(ref_rule_id))
        {
            try self.rule_id_to_completable_states.pushInLatestRow(self.gpa, .{
                .referenced_rule_id = ref_rule_id,
                .parent_state = parent_entry,
            });
            return false;
        }
        if (state.rule_start_pos == ParserState.NO_PREV_INPUT_POS) {
            return true;
        }
        // The parents live in an earlier row, so appending to the latest row leaves them in place;
        // duplicates are checked against the latest row as it was before the loop.
        const parents = self.rule_id_to_completable_states.rowRange(@intCast(state.rule_start_pos));
        const latest = self.rule_id_to_completable_states.rowRange(self.rule_id_to_completable_states.len() - 1);
        const data = self.rule_id_to_completable_states.dataSlice();
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
                try self.rule_id_to_completable_states.pushInLatestRow(self.gpa, .{
                    .referenced_rule_id = ref_rule_id,
                    .parent_state = parent_state,
                });
            }
        }
        return false;
    }

    /// Enqueues the start state of a newly predicted occurrence of `ref_rule_id`.
    fn enqueueRuleStart(
        self: *EarleyParser,
        state: ParserState,
        ref_rule_id: i32,
        right_recursion_to_root: bool,
    ) Allocator.Error!void {
        const ref_rule = self.grammar.rule(ref_rule_id);
        if (ref_rule.max_chars >= 0) {
            self.tmp_char_budget_entered = true;
        }
        const start_pos: i32 = if (right_recursion_to_root)
            ParserState.NO_PREV_INPUT_POS
        else
            @as(i32, @intCast(self.rule_id_to_completable_states.len())) - 1;
        var new_state = ParserState.init(
            ref_rule_id,
            ref_rule.body_expr_id,
            self.perRuleFsm(ref_rule_id).startState(),
            start_pos,
        );
        new_state.budget_deadline = self.deadlineForRule(ref_rule_id, state.budget_deadline);
        new_state.active_temperature_rule_id =
            self.resolveActiveTemperatureRule(ref_rule_id, state.active_temperature_rule_id);
        new_state.char_budget_deadline = self.charDeadlineForRule(ref_rule_id, state.char_budget_deadline);
        try self.enqueue(new_state);
    }

    /// Predicts a rule reference or repeat element in an IR sequence (lookahead path).
    fn expandNextRuleRefElement(
        self: *EarleyParser,
        state: ParserState,
        sequence_id: i32,
        sub_element_expr_id: i32,
    ) Allocator.Error!void {
        const sequence_len: i32 = @intCast(self.grammar.expr(sequence_id).len());
        const sub_expr = self.grammar.expr(sub_element_expr_id);
        std.debug.assert(sub_expr.ty == .RuleRef or sub_expr.ty == .Repeat);
        const ref_rule_id = sub_expr.data[0];
        const is_right_recursion = state.element_id == sequence_len - 1 and sub_expr.ty != .Repeat;
        const right_recursion_to_root =
            try self.addCompletableParents(state, ref_rule_id, is_right_recursion, state);
        if (self.rule_is_nullable[@intCast(ref_rule_id)]) {
            try self.enqueue(state.atElement(state.element_id + 1));
        }
        try self.enqueueRuleStart(state, ref_rule_id, right_recursion_to_root);
    }

    /// Predicts the rule references, repeat references, and epsilon edges of an FSM state.
    fn expandNextRuleRefElementOnFsm(self: *EarleyParser, state: ParserState) Allocator.Error!void {
        const fsm = self.perRuleFsm(state.rule_id);
        const edges = fsm.stateEdges(state.element_id);
        for (edges) |edge| {
            if (edge.isEpsilon()) {
                try self.enqueue(state.atElement(edge.target));
                continue;
            }
            const target = edge.target;
            var ref_rule_id: i32 = undefined;
            var is_repeat = false;
            if (edge.isRuleRef()) {
                ref_rule_id = edge.refRuleId();
            } else if (edge.isRepeatRef()) {
                const info = self.grammar.completeFsm().repeatEdgeInfo(edge.auxIndex());
                if (state.repeat_count >= info.lower()) {
                    try self.enqueue(state.atElement(target));
                }
                if (state.repeat_count >= info.upper()) {
                    continue;
                }
                ref_rule_id = info.ruleId();
                is_repeat = true;
            } else {
                continue;
            }

            const target_flags = try self.fsmStateFlags(state.rule_id, target);
            const is_right_recursion =
                !is_repeat and target_flags & FSM_STATE_HAS_EDGES == 0 and target_flags & FSM_STATE_END != 0;
            // For repeat edges the parent entry keeps the source state and the repeat count; for
            // rule references it is the post-transition state.
            const parent_entry = if (is_repeat)
                state.atElementWithRepeat(state.element_id, state.repeat_count)
            else
                state.atElement(target);
            const right_recursion_to_root =
                try self.addCompletableParents(state, ref_rule_id, is_right_recursion, parent_entry);
            if (!is_repeat and self.rule_is_nullable[@intCast(ref_rule_id)]) {
                try self.enqueue(state.atElement(target));
            }
            try self.enqueueRuleStart(state, ref_rule_id, right_recursion_to_root);
        }
    }

    /// Advances an IR-path byte-string element by one input byte.
    pub fn advanceByteString(self: *EarleyParser, state: ParserState, ch: u8, expr_id: i32) Allocator.Error!void {
        const expr = self.grammar.expr(expr_id);
        std.debug.assert(@as(i32, @intCast(expr.len())) > state.sub_element_id);
        if (@as(u8, @intCast(expr.data[@intCast(state.sub_element_id)])) != ch) return;
        var new_state = state;
        new_state.sub_element_id += 1;
        if (new_state.sub_element_id == @as(i32, @intCast(expr.len()))) {
            new_state.element_id += 1;
            new_state.sub_element_id = 0;
            try self.enqueue(new_state);
        } else {
            try self.tmp_states_to_be_added.append(self.gpa, new_state);
        }
    }

    /// Shared UTF-8 handling of character classes. `star` keeps the state on the same element
    /// after a full codepoint is matched.
    fn advanceCharacterClassImpl(
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
                const matches_range = rangesOverlap(class_data, codepoint, codepoint);
                if (matches_range != is_negative) {
                    try self.enqueue(finish(new_state, star));
                }
            } else {
                // Check whether the partial codepoint could still match any range. Negative
                // classes always continue and verify on the final byte.
                const remaining_bytes = new_state.sub_element_id;
                const shift: u5 = @intCast(6 * remaining_bytes);
                const min_codepoint = new_state.partial_codepoint << shift;
                const max_codepoint = min_codepoint | ((@as(i32, 1) << shift) - 1);
                if (is_negative or rangesOverlap(class_data, min_codepoint, max_codepoint)) {
                    try self.tmp_states_to_be_added.append(self.gpa, new_state);
                }
            }
            return;
        }

        // Non-ASCII first bytes.
        if (ch >= 0x80) {
            const decoded = support.encoding.handleUtf8FirstByte(ch) orelse return;
            std.debug.assert(decoded.consumed > 1);
            const remaining: u5 = @intCast(6 * (@as(i32, @intCast(decoded.consumed)) - 1));
            const min_codepoint = decoded.codepoint << remaining;
            const max_codepoint = min_codepoint | ((@as(i32, 1) << remaining) - 1);
            if (is_negative or rangesOverlap(class_data, min_codepoint, max_codepoint)) {
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

    fn advanceCharacterClass(self: *EarleyParser, state: ParserState, ch: u8, expr_id: i32) Allocator.Error!void {
        std.debug.assert(self.grammar.expr(expr_id).ty == .CharacterClass);
        return self.advanceCharacterClassImpl(state, ch, expr_id, false);
    }

    fn advanceCharacterClassStar(self: *EarleyParser, state: ParserState, ch: u8, expr_id: i32) Allocator.Error!void {
        std.debug.assert(self.grammar.expr(expr_id).ty == .CharacterClassStar);
        return self.advanceCharacterClassImpl(state, ch, expr_id, true);
    }

    /// Enqueues a post-scan state: scanable leaves skip the predict/complete queue.
    fn enqueueScanTarget(self: *EarleyParser, new_state: ParserState) Allocator.Error!void {
        const flags = try self.fsmStateFlags(new_state.rule_id, new_state.element_id);
        if (flags & FSM_STATE_NON_TERMINAL == 0 and flags & FSM_STATE_END == 0 and flags & FSM_STATE_SCANABLE != 0) {
            try self.enqueueWithoutProcessing(new_state);
        } else {
            try self.enqueue(new_state);
        }
    }

    fn advanceFsm(self: *EarleyParser, state: ParserState, ch: u8) Allocator.Error!void {
        const value: i32 = ch;
        const fsm = self.perRuleFsm(state.rule_id);
        const edges = fsm.stateEdges(state.element_id);
        // `edges` lives in immutable grammar storage and `enqueueScanTarget` only touches queues/flags.
        for (edges) |edge| {
            if (edge.isCharRange() and edge.min <= value and value <= edge.max) {
                try self.enqueueScanTarget(state.withElement(edge.target));
            }
        }
    }

    fn scanAtomicToken(self: *EarleyParser, state: ParserState, token_id: i32) Allocator.Error!void {
        if (state.rule_id == -1) return;
        const fsm = self.perRuleFsm(state.rule_id);
        const edges = fsm.stateEdges(state.element_id);
        for (edges) |edge| {
            const matches = blk: {
                if (edge.isToken()) {
                    break :blk fsm.compact().tokenEdgeInfo(edge.auxIndex()).contains(token_id);
                } else if (edge.isExcludeToken()) {
                    break :blk fsm.compact().excludeTokenEdgeInfo(edge.auxIndex()).accepts(token_id);
                } else {
                    break :blk false;
                }
            };
            if (matches) try self.enqueueScanTarget(state.withElement(edge.target));
        }
    }

    /// Advances the parser by accepting a whole token via token/exclude-token edges, consuming
    /// `token_char_count` codepoints. Returns false (state unchanged) if no state advances.
    pub fn advanceAtomicToken(self: *EarleyParser, token_id: i32, token_char_count: i32) Allocator.Error!bool {
        std.debug.assert(self.tmp_process_state_queue.len == 0);
        self.tmp_states_visited_in_queue.clear();
        self.tmp_states_to_be_added.clearRetainingCapacity();
        self.tmp_accept_stop_token = false;
        self.tmp_completed_lazy_occurrences.clearRetainingCapacity();
        if (self.has_char_budget_rules) {
            self.tmp_char_budget_entered = self.char_budget_entry_history.items[self.char_budget_entry_history.items.len - 1];
            try self.char_count_history.append(self.gpa, self.currentCharIndex() + token_char_count);
        }
        // Scanning only queues states, so the latest row does not change while it is walked.
        const range = self.scanable_state_history.rowRange(self.scanable_state_history.len() - 1);
        for (self.scanable_state_history.dataSlice()[range.start..range.end]) |state| {
            if (self.skip_expired_states and self.isExpiredState(state)) continue;
            try self.scanAtomicToken(state, token_id);
        }
        if (self.tmp_process_state_queue.len == 0 and self.tmp_states_to_be_added.items.len == 0) {
            if (self.has_char_budget_rules) {
                _ = self.char_count_history.pop();
            }
            return false;
        }
        _ = try self.rule_id_to_completable_states.pushRow(self.gpa, &.{});
        if (self.capture_tracking) {
            _ = try self.capture_event_history.pushRow(self.gpa, &.{});
        }
        try self.processQueue();
        try self.finishRow(false);
        return true;
    }

    /// Enqueues `state` for prediction/completion if it was not visited this round.
    pub fn enqueue(self: *EarleyParser, state: ParserState) Allocator.Error!void {
        if (!self.tmp_states_visited_in_queue.isVisited(state)) {
            try self.tmp_process_state_queue.pushBack(self.gpa, state);
            try self.tmp_states_visited_in_queue.insert(self.gpa, state);
        }
    }

    /// Adds `state` directly to the next scanable row if it was not visited this round.
    pub fn enqueueWithoutProcessing(self: *EarleyParser, state: ParserState) Allocator.Error!void {
        if (!self.tmp_states_visited_in_queue.isVisited(state)) {
            try self.tmp_states_visited_in_queue.insert(self.gpa, state);
            try self.tmp_states_to_be_added.append(self.gpa, state);
        }
    }

    /// Pushes one state as a new temporary position to check (without expanding it).
    pub fn pushOneStateToCheck(self: *EarleyParser, state: ParserState) Allocator.Error!void {
        const completed = self.isRootCompleted();
        try self.pushStatesToCheck(&.{state}, completed);
    }

    /// Pushes a temporary parser row for token-mask checking.
    pub fn pushStatesToCheck(self: *EarleyParser, states: []const ParserState, completed: bool) Allocator.Error!void {
        _ = try self.rule_id_to_completable_states.pushRow(self.gpa, &.{});
        try self.is_completed.append(self.gpa, completed);
        _ = try self.scanable_state_history.pushRow(self.gpa, states);
        if (self.capture_tracking) {
            _ = try self.capture_event_history.pushRow(self.gpa, &.{});
        }
        if (self.has_char_budget_rules) {
            try self.char_count_history.append(self.gpa, self.currentCharIndex());
            const entered = self.char_budget_entry_history.items[self.char_budget_entry_history.items.len - 1];
            try self.char_budget_entry_history.append(self.gpa, entered);
        }
    }

    /// Pushes a character-count row for a parser row created by the matcher.
    pub fn pushCharCountRow(self: *EarleyParser, char_count: i32, char_budget_entered: bool) Allocator.Error!void {
        if (self.has_char_budget_rules) {
            try self.char_count_history.append(self.gpa, char_count);
            try self.char_budget_entry_history.append(self.gpa, char_budget_entered);
        }
    }

    /// The number of codepoints accepted so far.
    pub fn currentCharIndex(self: *const EarleyParser) i32 {
        if (self.char_count_history.items.len == 0) return 0;
        return self.char_count_history.items[self.char_count_history.items.len - 1];
    }

    /// Whether a character-budgeted occurrence was entered since the initial row.
    pub fn hasEnteredCharBudget(self: *const EarleyParser) bool {
        if (!self.has_char_budget_rules) return false;
        if (self.char_budget_entry_history.items.len == 0) return false;
        return self.char_budget_entry_history.items[self.char_budget_entry_history.items.len - 1];
    }

    /// Copies the capture events of the latest input position (deep copy; caller owns).
    pub fn copyLastCaptureRow(self: *const EarleyParser, gpa: Allocator) Allocator.Error!ArrayList(CaptureEvent) {
        var out: ArrayList(CaptureEvent) = .empty;
        errdefer {
            for (out.items) |*ev| ev.deinit(gpa);
            out.deinit(gpa);
        }
        if (self.capture_tracking) {
            try out.ensureTotalCapacity(gpa, self.capture_event_history.back().len);
            for (self.capture_event_history.back()) |event|
                out.appendAssumeCapacity(try event.dupe(gpa));
        }
        return out;
    }

    /// Pushes a new row of capture events (deep-cloning into `self.gpa`), keeping the
    /// capture history aligned with the state history when a position is created outside `advance`.
    pub fn pushCaptureRow(self: *EarleyParser, events: []const CaptureEvent) Allocator.Error!void {
        if (!self.capture_tracking) return;
        const cloned = try self.gpa.alloc(CaptureEvent, events.len);
        defer self.gpa.free(cloned);
        var initialized: usize = 0;
        errdefer for (cloned[0..initialized]) |*ev| ev.deinit(self.gpa);
        for (events, 0..) |ev, i| {
            cloned[i] = try ev.dupe(self.gpa);
            initialized += 1;
        }
        _ = try self.capture_event_history.pushRow(self.gpa, cloned);
        initialized = 0;
    }

    /// A copy of the latest history row (deep; caller owns, call `deinit`).
    pub fn latestRow(self: *const EarleyParser, gpa: Allocator) Allocator.Error!ParserRow {
        var row: ParserRow = .{};
        errdefer row.deinit(gpa);
        try row.states.appendSlice(gpa, self.latestScanableStates());
        try row.completable_states.appendSlice(gpa, self.latestCompletableStates());
        row.completed = self.isRootCompleted();
        row.capture_events = try self.copyLastCaptureRow(gpa);
        return row;
    }

    /// Replaces the latest history row (deep-cloning capture events into `self.gpa`).
    pub fn replaceLatestRow(self: *EarleyParser, row: ParserRow) Allocator.Error!void {
        self.scanable_state_history.popBack(1);
        _ = try self.scanable_state_history.pushRow(self.gpa, row.states.items);
        self.rule_id_to_completable_states.popBack(1);
        _ = try self.rule_id_to_completable_states.pushRow(self.gpa, row.completable_states.items);
        self.is_completed.items[self.is_completed.items.len - 1] = row.completed;
        if (self.capture_tracking) {
            const len = self.capture_event_history.len();
            self.freeCaptureRowsFrom(len - 1);
            self.capture_event_history.popBack(1);
            try self.pushCaptureRow(row.capture_events.items);
        }
    }

    /// A human-readable dump of the latest scanable states (caller owns).
    pub fn printStates(self: *const EarleyParser, gpa: Allocator) Allocator.Error![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        const w = &aw.writer;
        w.print("There are {d} steps in history. Last step: [\n", .{self.scanable_state_history.len()}) catch return error.OutOfMemory;
        for (self.scanable_state_history.back()) |state| {
            w.print("{f}, \n", .{state}) catch return error.OutOfMemory;
        }
        w.writeAll("]") catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }
};

/// Whether `[min_codepoint, max_codepoint]` overlaps any range in a character-class payload.
fn rangesOverlap(class_data: []const i32, min_codepoint: i32, max_codepoint: i32) bool {
    var i: usize = 1;
    while (i + 1 < class_data.len) : (i += 2) {
        if (max_codepoint >= class_data[i] and min_codepoint <= class_data[i + 1]) return true;
    }
    return false;
}

test "ParserState member array roundtrip, formatting, and ordering" {
    const gpa = std.testing.allocator;
    const s = ParserState.init(3, 7, 2, ParserState.NO_PREV_INPUT_POS);
    const arr = s.serializeMemberArray();
    try std.testing.expectEqual(@as(usize, 10), arr.len);
    const back = ParserState.fromMemberArray(&arr).?;
    try std.testing.expect(s.eql(back));
    const short: []const i32 = arr[0..5];
    try std.testing.expect(ParserState.fromMemberArray(short) == null);
    try std.testing.expect(!s.eql(back.atElement(4)));
    try std.testing.expect(s.lessThan(back.atElement(4)));

    const text = try s.display(gpa);
    defer gpa.free(text);
    const formatted = try std.fmt.allocPrint(gpa, "{f}", .{s});
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings(
        "ParserState(rule_id=3, sequence_id=7, element_id=2, rule_start_pos=-1, sub_element_id=0)",
        text,
    );
    try std.testing.expectEqualStrings(text, formatted);

    const key = s.cacheKey();
    try std.testing.expectEqual(@as(i32, 3), key.rule_id);
    try std.testing.expectEqual(@as(i32, 7), key.sequence_id);
    try std.testing.expectEqual(@as(i32, 2), key.element_id);
    try std.testing.expectEqual(@as(i32, 0), key.sub_element_id);
}

test "RepeatDetector switches to the hash set" {
    const gpa = std.testing.allocator;
    var detector = RepeatDetector.init();
    defer detector.deinit(gpa);
    for (0..TRANSITION_THRESHOLD + 5) |i| {
        const state = ParserState.init(@intCast(i), 0, 0, 0);
        try detector.insert(gpa, state);
        try std.testing.expect(!detector.isVisited(ParserState.init(@intCast(i + 1000), 0, 0, 0)));
        try std.testing.expect(detector.isVisited(state));
    }
    detector.clear();
    try std.testing.expect(!detector.isVisited(ParserState.init(0, 0, 0, 0)));
}

test "EarleyParser resetWithInitialState, dupe, row snapshot, and OOM safety" {
    const gpa = std.testing.allocator;
    var builder = try grammar_mod.GrammarBuilder.init(gpa);
    defer builder.deinit();
    const bs0 = try builder.addByteString("a");
    const r0 = try builder.addRuleNamed("r0", bs0);
    const bs1 = try builder.addByteString("b");
    const r1 = try builder.addRuleNamed("r1", bs1);
    var grammar = try builder.intoGrammarWithRootId(r0);
    defer grammar.deinit();

    var f = try fsm_mod.Fsm.init(gpa, 4);
    defer f.deinit();
    try f.addEdge(0, 1, 'a', 'a');
    try f.addEdge(2, 3, 'b', 'b');
    var complete = try fsm_mod.CompactFsm.fromFsm(gpa, &f);
    defer complete.deinit();

    var v0 = try fsm_mod.CompactFsmWithStartEnd.init(gpa, complete.retain(), 0, &.{1}, true);
    defer v0.deinit();
    var s0 = fsm_mod.CompactFsmWithStartEndWithSize.init(try v0.cloneWithShared(gpa), 1, 2);
    defer s0.deinit();

    var v1 = try fsm_mod.CompactFsmWithStartEnd.init(gpa, complete.retain(), 2, &.{3}, true);
    defer v1.deinit();
    var s1 = fsm_mod.CompactFsmWithStartEndWithSize.init(try v1.cloneWithShared(gpa), 1, 2);
    defer s1.deinit();

    try grammar.setFsms(complete, &.{ s0, s1 });
    grammar.setOptimized(true);

    var ep = try EarleyParser.init(gpa, &grammar, null);
    defer ep.deinit();
    try std.testing.expect(!ep.isRootCompleted());
    try std.testing.expect(try ep.advance('a'));
    try std.testing.expect(ep.isRootCompleted());

    var cloned = try ep.dupe(gpa);
    defer cloned.deinit();
    try std.testing.expect(cloned.isRootCompleted());

    const dumped = try ep.printStates(gpa);
    defer gpa.free(dumped);
    try std.testing.expect(std.mem.indexOf(u8, dumped, "steps in history") != null);

    var row = try ep.latestRow(gpa);
    defer row.deinit(gpa);
    try ep.replaceLatestRow(row);

    const flags_cap_before = ep.fsm_state_flags_cache.capacity;
    const alt_init = ParserState.init(r1, grammar.rule(r1).body_expr_id, 2, ParserState.NO_PREV_INPUT_POS);
    try ep.resetWithInitialState(alt_init);
    try std.testing.expect(!ep.isRootCompleted());
    try std.testing.expectEqual(@as(usize, 1), ep.scanable_state_history.len());
    try std.testing.expectEqual(flags_cap_before, ep.fsm_state_flags_cache.capacity);
    try std.testing.expect(!try ep.advance('a'));
    try std.testing.expect(try ep.advance('b'));
    try std.testing.expect(ep.isRootCompleted());

    try ep.reset();
    try std.testing.expect(try ep.advance('a'));
    try std.testing.expect(ep.isRootCompleted());

    const check_oom = struct {
        fn run(alloc: Allocator, g: *const Grammar) !void {
            var p = try EarleyParser.init(alloc, g, null);
            defer p.deinit();
            _ = try p.advance('a');
            var p2 = try p.dupe(alloc);
            defer p2.deinit();
        }
    }.run;
    try std.testing.checkAllAllocationFailures(gpa, check_oom, .{&grammar});
}
