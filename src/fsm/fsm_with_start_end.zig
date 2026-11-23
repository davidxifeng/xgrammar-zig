//! An FSM paired with a start state and a set of accepting states.
//! `FSMWithStartEnd` (over `FSM`) in `cpp/fsm.{h,cc}`.
//!
//! This carries the regex/grammar building algebra (`concat`, `union`, `star`, `plus`,
//! `optional`) plus string acceptance used to test built machines.

const std = @import("std");
const Allocator = std.mem.Allocator;

const fsm_mod = @import("fsm.zig");
const Fsm = fsm_mod.Fsm;
const EdgeKind = fsm_mod.EdgeKind;
const StateSet = fsm_mod.StateSet;
const clone_set = fsm_mod.clone_set;
const state_set_from = fsm_mod.state_set_from;
const state_set_eql = fsm_mod.state_set_eql;
const fsm_edge = @import("fsm_edge.zig");
const FsmEdge = fsm_edge.FsmEdge;
const edge_type = fsm_edge.edge_type;
const support = @import("../support/mod.zig");
const Compact2dArray = support.Compact2dArray;
const union_find_set = support.union_find_set;
const UnionFindSet = union_find_set.UnionFindSet;
const with_size_mod = @import("fsm_with_start_end_with_size.zig");
const FsmWithStartEndWithSize = with_size_mod.FsmWithStartEndWithSize;

/// State-count ceiling for `simplify_epsilon` (`1e8`).
const SIMPLIFY_EPSILON_MAX_STATES: i32 = 100_000_000;
/// State-count ceiling for `merge_equivalent_states` (`1e5`).
const MERGE_STATES_MAX_STATES: i32 = 100_000;
/// State-count ceiling for `to_dfa` / `minimize_dfa` (`1e3`).
const DFA_MAX_STATES: i32 = 1_000;
/// State-count ceiling for `not` / `intersect` (`1e6`).
const NOT_INTERSECT_MAX_STATES: i32 = 1_000_000;

/// Errors of the automata operations (`Result<_, String>` in Rust: the message text is
/// dropped, only the error kind is preserved — see PORTING.md deviation).
pub const AutomataError = Allocator.Error || error{
    /// `not`/`intersect` on a machine with rule/repeat references.
    NotLeaf,
    /// DFA conversion or the product exceeded the configured state limit.
    StateLimitExceeded,
};

/// A finite-state machine with a designated start state and accepting-state set.
///
/// The accepting states are stored sparsely, as a sorted, deduplicated list of state ids: an
/// FSM view over a large shared FSM usually has only a few accepting states, while the state id
/// space can be huge.
pub const FsmWithStartEnd = struct {
    /// Backs every allocation of this machine (freed by `deinit`).
    allocator: Allocator,
    fsm: Fsm,
    start: i32,
    ends: std.ArrayList(i32),
    is_dfa: bool,

    /// Creates an FSM-with-start/end from its parts. `ends` need not be sorted or deduplicated;
    /// the list is consumed.
    pub fn new(allocator: Allocator, fsm: Fsm, start: i32, ends: std.ArrayList(i32), is_dfa: bool) Allocator.Error!FsmWithStartEnd {
        var ends_list = ends;
        normalize_ends(&ends_list);
        return .{ .allocator = allocator, .fsm = fsm, .start = start, .ends = ends_list, .is_dfa = is_dfa };
    }

    /// Frees all storage owned by this machine.
    pub fn deinit(self: *FsmWithStartEnd) void {
        self.fsm.deinit();
        self.ends.deinit(self.allocator);
    }

    fn normalize_ends(ends: *std.ArrayList(i32)) void {
        std.mem.sortUnstable(i32, ends.items, {}, std.sort.asc(i32));
        var write: usize = 0;
        for (ends.items, 0..) |v, read| {
            if (read == 0 or v != ends.items[read - 1]) {
                ends.items[write] = v;
                write += 1;
            }
        }
        ends.items.len = write;
    }

    /// Deep copy into `allocator`.
    pub fn clone(self: *const FsmWithStartEnd, allocator: Allocator) Allocator.Error!FsmWithStartEnd {
        const fsm = try self.fsm.clone(allocator);
        errdefer @constCast(&fsm).deinit();
        var ends: std.ArrayList(i32) = .empty;
        try ends.appendSlice(allocator, self.ends.items);
        return .{ .allocator = allocator, .fsm = fsm, .start = self.start, .ends = ends, .is_dfa = self.is_dfa };
    }

    /// Returns a copy (Rust `copy`).
    pub fn copy(self: *const FsmWithStartEnd, allocator: Allocator) Allocator.Error!FsmWithStartEnd {
        return self.clone(allocator);
    }

    /// The underlying FSM.
    pub fn get_fsm(self: *const FsmWithStartEnd) *const Fsm {
        return &self.fsm;
    }

    /// A mutable reference to the underlying FSM (Rust `fsm_mut`).
    pub fn fsm_mut(self: *FsmWithStartEnd) *Fsm {
        return &self.fsm;
    }

    /// The start state.
    pub fn get_start(self: *const FsmWithStartEnd) i32 {
        return self.start;
    }

    /// The accepting states, as a sorted, deduplicated list of state ids.
    pub fn get_ends(self: *const FsmWithStartEnd) []const i32 {
        return self.ends.items;
    }

    /// Whether `state` is an accepting state.
    pub fn is_end_state(self: *const FsmWithStartEnd, state: i32) bool {
        return std.mem.indexOfScalar(i32, self.ends.items, state) != null;
    }

    /// Whether this machine is known to be a DFA.
    pub fn get_is_dfa(self: *const FsmWithStartEnd) bool {
        return self.is_dfa;
    }

    /// The number of states.
    pub fn num_states(self: *const FsmWithStartEnd) i32 {
        return self.fsm.num_states();
    }

    /// Sets the start state.
    pub fn set_start_state(self: *FsmWithStartEnd, state: i32) void {
        self.start = state;
    }

    /// Marks `state` as accepting.
    pub fn add_end_state(self: *FsmWithStartEnd, state: i32) void {
        std.debug.assert(state < self.num_states()); // end state out of range
        if (std.mem.indexOfScalar(i32, self.ends.items, state) == null) {
            // Rust keeps `ends` sorted via binary-search insertion.
            var pos: usize = 0;
            while (pos < self.ends.items.len and self.ends.items[pos] < state) pos += 1;
            self.ends.insert(self.allocator, pos, state) catch |e| switch (e) {
                error.OutOfMemory => @panic("out of memory"),
            };
        }
    }

    /// Replaces the accepting-state set. `ends` need not be sorted or deduplicated (consumed).
    pub fn set_end_states(self: *FsmWithStartEnd, ends: std.ArrayList(i32)) void {
        var ends_list = ends;
        normalize_ends(&ends_list);
        self.ends.deinit(self.allocator);
        self.ends = ends_list;
    }

    /// Adds a new (non-accepting) state, returning its id.
    pub fn add_state(self: *FsmWithStartEnd) Allocator.Error!i32 {
        return self.fsm.add_state();
    }

    /// Whether `state` has an outgoing character/token edge (can consume input).
    pub fn is_scanable_state(self: *const FsmWithStartEnd, state: i32) bool {
        for (self.fsm.state_edges(state)) |e| {
            if (e.is_char_range() or e.is_token() or e.is_exclude_token()) return true;
        }
        return false;
    }

    /// Whether `state` has an outgoing rule/epsilon/repeat edge (is non-terminal).
    pub fn is_non_terminal_state(self: *const FsmWithStartEnd, state: i32) bool {
        for (self.fsm.state_edges(state)) |e| {
            if (e.is_rule_ref() or e.is_epsilon() or e.is_repeat_ref()) return true;
        }
        return false;
    }

    /// Whether the FSM accepts the byte sequence `input` (which need not be valid UTF-8).
    pub fn accept_string(self: *const FsmWithStartEnd, input: []const u8) Allocator.Error!bool {
        var states = try state_set_from(self.allocator, &.{self.start});
        defer states.deinit();
        try self.fsm.epsilon_closure(&states);
        var result = StateSet.init(self.allocator);
        defer result.deinit();
        for (input) |byte| {
            try self.fsm.advance(&states, @intCast(byte), &result, .CharRange, false);
            if (result.count() == 0) return false;
            std.mem.swap(StateSet, &states, &result);
        }
        var it = states.keyIterator();
        while (it.next()) |s| {
            if (self.is_end_state(s.*)) return true;
        }
        return false;
    }

    /// The set of states reachable from the start state (caller owns the set).
    pub fn reachable_states(self: *const FsmWithStartEnd) Allocator.Error!StateSet {
        return self.fsm.reachable_states(self.allocator, &.{self.start});
    }

    /// Whether the FSM is a leaf (contains no rule or repeat references).
    pub fn is_leaf(self: *const FsmWithStartEnd) Allocator.Error!bool {
        var reachable = try self.reachable_states();
        defer reachable.deinit();
        var it = reachable.keyIterator();
        while (it.next()) |state_key| {
            for (self.fsm.state_edges(state_key.*)) |e| {
                if (e.is_rule_ref() or e.is_repeat_ref()) return false;
            }
        }
        return true;
    }

    /// `self*` — zero or more repetitions (a fresh accepting start state loops back).
    /// The caller owns the result.
    pub fn star(self: *const FsmWithStartEnd, allocator: Allocator) Allocator.Error!FsmWithStartEnd {
        var fsm = try self.fsm.clone(allocator);
        errdefer @constCast(&fsm).deinit();
        const new_start = try fsm.add_state();
        for (self.ends.items) |end| try fsm.add_epsilon_edge(end, new_start);
        try fsm.add_epsilon_edge(new_start, self.start);
        var ends: std.ArrayList(i32) = .empty;
        try ends.append(allocator, new_start);
        return FsmWithStartEnd.new(allocator, fsm, new_start, ends, false);
    }

    /// `self+` — one or more repetitions (each end loops back to the start).
    pub fn plus(self: *const FsmWithStartEnd, allocator: Allocator) Allocator.Error!FsmWithStartEnd {
        var fsm = try self.fsm.clone(allocator);
        errdefer @constCast(&fsm).deinit();
        for (self.ends.items) |end| try fsm.add_epsilon_edge(end, self.start);
        var ends: std.ArrayList(i32) = .empty;
        try ends.appendSlice(allocator, self.ends.items);
        return FsmWithStartEnd.new(allocator, fsm, self.start, ends, false);
    }

    /// `self?` — zero or one repetition (start may epsilon-skip to an end).
    pub fn optional(self: *const FsmWithStartEnd, allocator: Allocator) Allocator.Error!FsmWithStartEnd {
        var fsm = try self.fsm.clone(allocator);
        errdefer @constCast(&fsm).deinit();
        if (self.ends.items.len > 0) {
            try fsm.add_epsilon_edge(self.start, self.ends.items[0]);
        }
        var ends: std.ArrayList(i32) = .empty;
        try ends.appendSlice(allocator, self.ends.items);
        return FsmWithStartEnd.new(allocator, fsm, self.start, ends, false);
    }

    /// The union of `fsms` (a fresh start state epsilon-links to each). The caller owns the
    /// result; the inputs are untouched.
    ///
    /// Panics if `fsms` is empty.
    pub fn union_(allocator: Allocator, fsms: []const FsmWithStartEnd) Allocator.Error!FsmWithStartEnd {
        std.debug.assert(fsms.len != 0); // union of 0 FSMs is not allowed
        if (fsms.len == 1) return fsms[0].clone(allocator);
        var fsm = try Fsm.new(allocator, 1);
        errdefer @constCast(&fsm).deinit();
        const start: i32 = 0;
        var ends: std.ArrayList(i32) = .empty;
        errdefer ends.deinit(allocator);
        for (fsms) |sub| {
            const offset = try fsm.add_fsm(&sub.fsm);
            try fsm.add_epsilon_edge(start, offset + sub.start);
            for (sub.ends.items) |end| try ends.append(allocator, offset + end);
        }
        return FsmWithStartEnd.new(allocator, fsm, start, ends, false);
    }

    /// The concatenation of `fsms` (each machine's ends epsilon-link to the next's start).
    ///
    /// Panics if `fsms` is empty.
    pub fn concat(allocator: Allocator, fsms: []const FsmWithStartEnd) Allocator.Error!FsmWithStartEnd {
        std.debug.assert(fsms.len != 0); // concatenation of 0 FSMs is not allowed
        if (fsms.len == 1) return fsms[0].clone(allocator);
        var fsm = try Fsm.empty(allocator);
        errdefer @constCast(&fsm).deinit();
        var start: i32 = 0;
        var previous_ends: std.ArrayList(i32) = .empty;
        errdefer previous_ends.deinit(allocator);
        for (fsms, 0..) |sub, i| {
            const offset = try fsm.add_fsm(&sub.fsm);
            if (i == 0) {
                start = offset + sub.start;
            } else {
                const this_start = offset + sub.start;
                for (previous_ends.items) |end| try fsm.add_epsilon_edge(end, this_start);
            }
            previous_ends.clearRetainingCapacity();
            for (sub.ends.items) |end| try previous_ends.append(allocator, offset + end);
        }
        return FsmWithStartEnd.new(allocator, fsm, start, previous_ends, false);
    }

    /// Appends this machine's states/edges into `complete` (a shared FSM), returning the
    /// resulting start state, accepting set, and pre-merge sizes.
    pub fn add_to_complete_fsm(self: *const FsmWithStartEnd, complete: *Fsm) Allocator.Error!FsmWithStartEndWithSize {
        const offset = try complete.add_fsm(&self.fsm);
        const n = self.num_states();
        const new_start = offset + self.start;
        // The ends of each returned view must not scale with the size of the complete FSM: this
        // runs once per rule, so a dense representation costs O(num_rules * num_total_states).
        var new_ends: std.ArrayList(i32) = .empty;
        errdefer new_ends.deinit(complete.allocator);
        for (self.ends.items) |end| try new_ends.append(complete.allocator, offset + end);
        var edge_num: usize = 0;
        for (0..@intCast(n)) |i| edge_num += self.fsm.edges.items[i].items.len;
        return FsmWithStartEndWithSize.new(complete.allocator, new_start, new_ends, @intCast(edge_num), n);
    }

    /// Rebuilds this machine under `state_mapping` (old id → new id), collapsing the merged
    /// states. The result is not flagged as a DFA.
    pub fn rebuild_with_mapping(self: *const FsmWithStartEnd, allocator: Allocator, state_mapping: []const i32, new_num_states: i32) Allocator.Error!FsmWithStartEnd {
        const new_fsm = try self.fsm.rebuild_with_mapping(allocator, state_mapping, new_num_states);
        errdefer @constCast(&new_fsm).deinit();
        var new_ends: std.ArrayList(i32) = .empty;
        errdefer new_ends.deinit(allocator);
        for (self.ends.items) |end| try new_ends.append(allocator, state_mapping[@intCast(end)]);
        return FsmWithStartEnd.new(allocator, new_fsm, state_mapping[@intCast(self.start)], new_ends, false);
    }

    /// The complement of this machine (a leaf DFA accepting exactly the strings it rejects).
    /// The caller owns the result.
    pub fn not(self: *const FsmWithStartEnd, allocator: Allocator) AutomataError!FsmWithStartEnd {
        if (!try self.is_leaf()) return error.NotLeaf;
        var result = if (self.is_dfa)
            try self.copy(allocator)
        else
            try self.to_dfa_with_limit(allocator, NOT_INTERSECT_MAX_STATES);
        errdefer result.deinit();

        var new_final: std.ArrayList(i32) = .empty;
        defer new_final.deinit(allocator);
        for (0..@intCast(result.num_states())) |i| {
            if (!result.is_end_state(@intCast(i))) try new_final.append(allocator, @intCast(i));
        }
        const accept_all = try result.add_state();
        try new_final.append(allocator, accept_all);
        for (0..@intCast(result.num_states())) |i| {
            var char_set: [256]bool = @splat(false);
            for (result.fsm.state_edges(@intCast(i))) |e| {
                if (e.is_char_range()) {
                    var c = e.min;
                    while (c <= e.max) : (c += 1) char_set[@intCast(c)] = true;
                }
            }
            var left: usize = 0;
            while (left < 256) {
                if (char_set[left]) {
                    left += 1;
                    continue;
                }
                var right = left + 1;
                while (right < 256 and !char_set[right]) right += 1;
                try result.fsm_mut().add_edge(@intCast(i), accept_all, @intCast(left), @intCast(right - 1));
                left = right;
            }
        }
        var final = std.ArrayList(i32).empty;
        try final.appendSlice(allocator, new_final.items);
        result.set_end_states(final);
        return result;
    }

    /// The intersection of two leaf machines (the product DFA), with a `1e6` state limit.
    pub fn intersect(allocator: Allocator, lhs: *const FsmWithStartEnd, rhs: *const FsmWithStartEnd) AutomataError!FsmWithStartEnd {
        return intersect_with_limit(allocator, lhs, rhs, NOT_INTERSECT_MAX_STATES);
    }

    /// The intersection of two leaf machines (the product DFA). Both the DFA conversion of each
    /// operand and the product are bounded by `max_result_num_states`.
    pub fn intersect_with_limit(allocator: Allocator, lhs: *const FsmWithStartEnd, rhs: *const FsmWithStartEnd, max_result_num_states: i32) AutomataError!FsmWithStartEnd {
        if (!try lhs.is_leaf() or !try rhs.is_leaf()) return error.NotLeaf;
        const lhs_dfa = try lhs.to_dfa_with_limit(allocator, max_result_num_states);
        var lhs_owned = lhs_dfa;
        errdefer lhs_owned.deinit();
        const rhs_dfa = try rhs.to_dfa_with_limit(allocator, max_result_num_states);
        var rhs_owned = rhs_dfa;
        errdefer rhs_owned.deinit();
        var result = try FsmWithStartEnd.new(allocator, try Fsm.new(allocator, 0), 0, .empty, true);
        errdefer result.deinit();
        // HashMap<(i32, i32), i32>: key packed as (lhs << 32) | (rhs as u32).
        var state_map = std.AutoHashMap(u64, i32).init(allocator);
        defer state_map.deinit();
        var queue: std.ArrayList(u64) = .empty;
        defer queue.deinit(allocator);
        const start_pair = pack_pair(lhs_owned.start, rhs_owned.start);
        try queue.append(allocator, start_pair);
        _ = try result.add_state();
        try state_map.put(start_pair, 0);
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const pair = queue.items[head];
            const lhs_state: i32 = @intCast(@as(i64, @bitCast(pair)) >> 32);
            const rhs_state: i32 = @bitCast(@as(u32, @truncate(pair)));
            const from = state_map.get(pair).?;
            if (lhs_owned.is_end_state(lhs_state) and rhs_owned.is_end_state(rhs_state)) {
                result.add_end_state(from);
            }
            for (lhs_owned.fsm.state_edges(lhs_state)) |le| {
                for (rhs_owned.fsm.state_edges(rhs_state)) |re| {
                    if (le.min > re.max or re.min > le.max) continue;
                    const min_v = @max(le.min, re.min);
                    const max_v = @min(le.max, re.max);
                    const key = pack_pair(le.target, re.target);
                    const target = state_map.get(key) orelse blk: {
                        if (result.num_states() >= max_result_num_states) return error.StateLimitExceeded;
                        const t = try result.add_state();
                        try state_map.put(key, t);
                        try queue.append(allocator, key);
                        break :blk t;
                    };
                    try result.fsm_mut().add_edge(from, target, min_v, max_v);
                }
            }
        }
        const out = result;
        lhs_owned.deinit();
        rhs_owned.deinit();
        return out;
    }

    /// Simplifies epsilon transitions by merging chains of epsilon-only states.
    /// The caller owns the result.
    pub fn simplify_epsilon(self: *const FsmWithStartEnd, allocator: Allocator) Allocator.Error!FsmWithStartEnd {
        if (self.is_dfa or self.num_states() > SIMPLIFY_EPSILON_MAX_STATES) {
            return self.clone(allocator);
        }
        const n: usize = @intCast(self.num_states());
        var union_find = UnionFindSet(i32).init(allocator);
        defer union_find.deinit();
        const in_degree = try allocator.alloc(i32, n);
        defer allocator.free(in_degree);
        @memset(in_degree, 0);
        var epsilon_edges: std.ArrayList([2]i32) = .empty;
        defer epsilon_edges.deinit(allocator);

        const has_exclude_token = try allocator.alloc(bool, n);
        defer allocator.free(has_exclude_token);
        @memset(has_exclude_token, false);
        for (0..n) |i| {
            for (self.fsm.state_edges(@intCast(i))) |e| {
                if (e.is_exclude_token()) has_exclude_token[i] = true;
            }
        }

        for (0..n) |i| {
            const edges = self.fsm.state_edges(@intCast(i));
            for (edges) |e| {
                in_degree[@intCast(e.target)] += 1;
                if (e.is_epsilon()) {
                    // a -epsilon-> b is a's only edge. Never merge an accepting a into a
                    // non-accepting b: the merged state would accept every other path into b.
                    if (edges.len == 1 and
                        !has_exclude_token[i] and
                        !has_exclude_token[@intCast(e.target)] and
                        (!self.is_end_state(@intCast(i)) or self.is_end_state(e.target)))
                    {
                        _ = try union_find.add(@intCast(i));
                        _ = try union_find.add(e.target);
                        union_find.union_(@intCast(i), e.target);
                        in_degree[@intCast(e.target)] -= 1;
                    } else {
                        try epsilon_edges.append(allocator, .{ @intCast(i), e.target });
                    }
                }
            }
        }

        // Build the equivalent-node mapping, folding in-degree into representatives.
        const equiv_node = try allocator.alloc(i32, n);
        defer allocator.free(equiv_node);
        for (0..n) |i| {
            if (union_find.count(@intCast(i))) {
                equiv_node[i] = union_find.find(@intCast(i));
                if (equiv_node[i] == @as(i32, @intCast(i))) continue;
                in_degree[@intCast(equiv_node[i])] += in_degree[i];
            } else {
                equiv_node[i] = @intCast(i);
            }
        }

        const start_rep = equiv_node[@intCast(self.start)];
        for (epsilon_edges.items) |edge| {
            const from = equiv_node[@intCast(edge[0])];
            const to = equiv_node[@intCast(edge[1])];
            if (in_degree[@intCast(to)] == 1 and
                start_rep != to and
                !has_exclude_token[@intCast(edge[0])] and
                !has_exclude_token[@intCast(edge[1])])
            {
                _ = try union_find.add(from);
                _ = try union_find.add(to);
                union_find.union_(from, to);
            }
        }

        var eq_classes = try union_find.get_all_sets(allocator);
        defer {
            for (eq_classes.items) |*set| set.deinit(allocator);
            eq_classes.deinit(allocator);
        }
        if (eq_classes.items.len == 0) {
            return self.clone(allocator);
        }
        const new_to_old = try allocator.alloc(i32, n);
        defer allocator.free(new_to_old);
        @memset(new_to_old, -1);
        for (eq_classes.items, 0..) |class, i| {
            for (class.items) |state| new_to_old[@intCast(state)] = @intCast(i);
        }
        var cnt: i32 = @intCast(eq_classes.items.len);
        for (0..n) |i| {
            if (new_to_old[i] == -1) {
                new_to_old[i] = cnt;
                cnt += 1;
            }
        }
        return self.rebuild_with_mapping(allocator, new_to_old, cnt);
    }

    /// Merges equivalent states (shared-prefix and shared-suffix collapsing), iterating to a
    /// fixed point. Returns an unchanged copy if it exceeds the state limit.
    pub fn merge_equivalent_states(self: *const FsmWithStartEnd, allocator: Allocator) Allocator.Error!FsmWithStartEnd {
        if (MERGE_STATES_MAX_STATES < self.num_states()) {
            return self.clone(allocator);
        }
        if (self.num_states() < 4) {
            return self.copy(allocator);
        }
        var result = try self.copy(allocator);
        errdefer result.deinit();
        result.fsm_mut().sort_edges();
        var union_find = UnionFindSet(i32).init(allocator);
        defer union_find.deinit();
        var changed = true;
        while (changed) {
            changed = try merge_equivalent_pass(&result, allocator, &union_find);
        }
        return result;
    }

    /// Converts this NFA into an equivalent DFA via subset construction, with a `1e3` limit.
    /// The caller owns the result.
    pub fn to_dfa(self: *const FsmWithStartEnd, allocator: Allocator) AutomataError!FsmWithStartEnd {
        return self.to_dfa_with_limit(allocator, DFA_MAX_STATES);
    }

    /// Converts this NFA into an equivalent DFA via subset construction.
    pub fn to_dfa_with_limit(self: *const FsmWithStartEnd, allocator: Allocator, max_num_states: i32) AutomataError!FsmWithStartEnd {
        if (self.num_states() > max_num_states) return error.StateLimitExceeded;
        var dfa = try FsmWithStartEnd.new(allocator, try Fsm.new(allocator, 0), 0, .empty, true);
        errdefer dfa.deinit();

        var closures: std.ArrayList(StateSet) = .empty;
        defer {
            for (closures.items) |*c| c.deinit();
            closures.deinit(allocator);
        }
        try closures.append(allocator, try self.epsilon_closure_of(allocator, self.start));

        var now_process: usize = 0;
        while (now_process < closures.items.len) : (now_process += 1) {
            var rules = StateSet.init(allocator);
            defer rules.deinit();
            var repeat_aux = StateSet.init(allocator);
            defer repeat_aux.deinit();
            var token_aux = StateSet.init(allocator);
            defer token_aux.deinit();
            var exclude_aux = StateSet.init(allocator);
            defer exclude_aux.deinit();
            // BTreeSet<i32>: kept as a sorted unique list.
            var interval_ends: std.ArrayList(i32) = .empty;
            defer interval_ends.deinit(allocator);
            var allowed: [256]bool = @splat(false);
            _ = try dfa.add_state();
            var closure_it = closures.items[now_process].keyIterator();
            while (closure_it.next()) |state_key| {
                const state = state_key.*;
                if (self.is_end_state(state)) dfa.add_end_state(@intCast(now_process));
                for (self.fsm.state_edges(state)) |e| {
                    if (e.is_char_range()) {
                        try sorted_insert_i32(allocator, &interval_ends, e.min);
                        try sorted_insert_i32(allocator, &interval_ends, e.max + 1);
                        var c = e.min;
                        while (c <= e.max) : (c += 1) allowed[@intCast(c)] = true;
                    } else if (e.is_rule_ref()) {
                        try rules.put(e.ref_rule_id(), {});
                    } else if (e.is_repeat_ref()) {
                        try repeat_aux.put(e.aux_index(), {});
                    } else if (e.is_token()) {
                        try token_aux.put(e.aux_index(), {});
                    } else if (e.is_exclude_token()) {
                        try exclude_aux.put(e.aux_index(), {});
                    }
                }
            }

            // Reduce the character transitions to maximal all-allowed intervals.
            var intervals: std.ArrayList([2]i32) = .empty;
            defer intervals.deinit(allocator);
            var last: i32 = -1;
            for (interval_ends.items) |end| {
                if (last == -1) {
                    last = end;
                    continue;
                }
                var all = true;
                var c = last;
                while (c < end) : (c += 1) {
                    if (!allowed[@intCast(c)]) all = false;
                }
                if (all) try intervals.append(allocator, .{ last, end - 1 });
                last = end;
            }

            for (intervals.items) |interval| {
                const lo = interval[0];
                const hi = interval[1];
                var next_closure = StateSet.init(allocator);
                defer next_closure.deinit();
                closure_it = closures.items[now_process].keyIterator();
                while (closure_it.next()) |state_key| {
                    for (self.fsm.state_edges(state_key.*)) |e| {
                        if (e.is_char_range() and lo >= e.min and hi <= e.max and !next_closure.contains(e.target)) {
                            var closure = try self.epsilon_closure_of(allocator, e.target);
                            defer closure.deinit();
                            var cit = closure.keyIterator();
                            while (cit.next()) |k| try next_closure.put(k.*, {});
                        }
                    }
                }
                const target = try find_or_add_closure(allocator, &closures, &next_closure, max_num_states);
                try dfa.fsm_mut().add_edge(@intCast(now_process), target, lo, hi);
            }

            var rules_list = try sorted_set_items(allocator, &rules);
            defer rules_list.deinit(allocator);
            for (rules_list.items) |rule| {
                var next_closure = StateSet.init(allocator);
                defer next_closure.deinit();
                closure_it = closures.items[now_process].keyIterator();
                while (closure_it.next()) |state_key| {
                    for (self.fsm.state_edges(state_key.*)) |e| {
                        if (e.is_rule_ref() and e.ref_rule_id() == rule and !next_closure.contains(e.target)) {
                            var closure = try self.epsilon_closure_of(allocator, e.target);
                            defer closure.deinit();
                            var cit = closure.keyIterator();
                            while (cit.next()) |k| try next_closure.put(k.*, {});
                        }
                    }
                }
                const target = try find_or_add_closure(allocator, &closures, &next_closure, max_num_states);
                try dfa.fsm_mut().add_rule_edge(@intCast(now_process), target, rule);
            }

            try self.dfa_aux_transitions(allocator, &dfa, &closures, now_process, &repeat_aux, edge_type.REPEAT_REF, max_num_states);
            try self.dfa_aux_transitions(allocator, &dfa, &closures, now_process, &token_aux, edge_type.TOKEN, max_num_states);
            try self.dfa_aux_transitions(allocator, &dfa, &closures, now_process, &exclude_aux, edge_type.EXCLUDE_TOKEN, max_num_states);
        }
        var aux: std.ArrayList(i32) = .empty;
        try aux.appendSlice(allocator, self.fsm.edge_aux_data.items);
        dfa.fsm_mut().set_edge_aux_data(aux);
        return dfa;
    }

    /// The epsilon closure of `state` (caller owns the set).
    fn epsilon_closure_of(self: *const FsmWithStartEnd, allocator: Allocator, state: i32) Allocator.Error!StateSet {
        var closure = try state_set_from(allocator, &.{state});
        errdefer closure.deinit();
        try self.fsm.epsilon_closure(&closure);
        return closure;
    }

    /// The DFA state of `next_closure`, adding it if it is new.
    fn find_or_add_closure(allocator: Allocator, closures: *std.ArrayList(StateSet), next_closure: *const StateSet, max_num_states: i32) AutomataError!i32 {
        for (closures.items, 0..) |*c, j| {
            if (state_set_eql(c.*, next_closure.*)) return @intCast(j);
        }
        if (closures.items.len >= max_num_states) return error.StateLimitExceeded;
        try closures.append(allocator, try clone_set(allocator, next_closure));
        return @intCast(closures.items.len - 1);
    }

    fn dfa_aux_transitions(
        self: *const FsmWithStartEnd,
        allocator: Allocator,
        dfa: *FsmWithStartEnd,
        closures: *std.ArrayList(StateSet),
        now_process: usize,
        aux_indices: *const StateSet,
        kind: i32,
        max_num_states: i32,
    ) AutomataError!void {
        var aux_vec = try sorted_set_items(allocator, aux_indices);
        defer aux_vec.deinit(allocator);
        for (aux_vec.items) |aux_idx| {
            var next_closure = StateSet.init(allocator);
            defer next_closure.deinit();
            var closure_it = closures.items[now_process].keyIterator();
            while (closure_it.next()) |state_key| {
                for (self.fsm.state_edges(state_key.*)) |e| {
                    if (e.min == kind and e.aux_index() == aux_idx and !next_closure.contains(e.target)) {
                        var closure = try self.epsilon_closure_of(allocator, e.target);
                        defer closure.deinit();
                        var cit = closure.keyIterator();
                        while (cit.next()) |k| try next_closure.put(k.*, {});
                    }
                }
            }
            const target = try find_or_add_closure(allocator, closures, &next_closure, max_num_states);
            try dfa.fsm_mut().add_edge(@intCast(now_process), target, kind, aux_idx);
        }
    }

    /// Minimizes a DFA (converting first if needed) via partition refinement.
    /// The caller owns the result.
    pub fn minimize_dfa(self: *const FsmWithStartEnd, allocator: Allocator) AutomataError!FsmWithStartEnd {
        if (self.num_states() > DFA_MAX_STATES) return error.StateLimitExceeded;
        var now_fsm = if (self.is_dfa)
            try self.copy(allocator)
        else
            try self.to_dfa(allocator);
        errdefer now_fsm.deinit();
        const n: usize = @intCast(now_fsm.num_states());

        // precursors[target] = list of ((min, max), source).
        var precursors = try allocator.alloc(std.ArrayList(Precursor), n);
        for (precursors) |*p| p.* = .empty;
        defer {
            for (precursors) |*p| p.deinit(allocator);
            allocator.free(precursors);
        }
        for (0..n) |i| {
            for (now_fsm.fsm.state_edges(@intCast(i))) |e| {
                try precursors[@intCast(e.target)].append(allocator, .{ .min = e.min, .max = e.max, .source = @intCast(i) });
            }
        }

        var partitions: std.ArrayList(StateSet) = .empty;
        defer {
            for (partitions.items) |*p| p.deinit();
            partitions.deinit(allocator);
        }
        var working: std.ArrayList(StateSet) = .empty;
        defer {
            for (working.items) |*p| p.deinit();
            working.deinit(allocator);
        }
        var final_states = StateSet.init(allocator);
        defer final_states.deinit();
        var non_final = StateSet.init(allocator);
        defer non_final.deinit();
        for (0..n) |i| {
            if (now_fsm.is_end_state(@intCast(i))) {
                try final_states.put(@intCast(i), {});
            } else {
                try non_final.put(@intCast(i), {});
            }
        }
        try partitions.append(allocator, try clone_set(allocator, &final_states));
        try partitions.append(allocator, try clone_set(allocator, &non_final));
        try working.append(allocator, try clone_set(allocator, &final_states));
        try working.append(allocator, try clone_set(allocator, &non_final));

        // BTreeMap<(min,max), HashSet>: transitions sorted lexicographically per pass.
        var possible: std.ArrayList(PossibleGroup) = .empty;
        defer {
            for (possible.items) |*p| p.set.deinit();
            possible.deinit(allocator);
        }

        while (working.pop()) |current_owned| {
            var current = current_owned;
            defer current.deinit();
            for (possible.items) |*p| p.set.deinit();
            possible.clearRetainingCapacity();
            var cur_it = current.keyIterator();
            while (cur_it.next()) |state_key| {
                for (precursors[@intCast(state_key.*)].items) |prec| {
                    const gop = try find_or_put_group(allocator, &possible, prec.min, prec.max);
                    if (!gop.set.contains(prec.source)) try gop.set.put(prec.source, {});
                }
            }
            sort_groups(&possible);

            for (possible.items) |group| {
                const precursors_set = &group.set;
                var i: usize = 0;
                while (i < partitions.items.len) : (i += 1) {
                    var intersection: std.ArrayList(i32) = .empty;
                    defer intersection.deinit(allocator);
                    var difference: std.ArrayList(i32) = .empty;
                    defer difference.deinit(allocator);
                    var pit = partitions.items[i].keyIterator();
                    while (pit.next()) |s| {
                        if (precursors_set.contains(s.*)) {
                            try intersection.append(allocator, s.*);
                        } else {
                            try difference.append(allocator, s.*);
                        }
                    }
                    if (intersection.items.len != 0 and difference.items.len != 0) {
                        const inter_set = try state_set_from(allocator, intersection.items);
                        const diff_set = try state_set_from(allocator, difference.items);
                        var in_working: ?usize = null;
                        for (working.items, 0..) |*w, wi| {
                            if (state_set_eql(w.*, partitions.items[i])) {
                                in_working = wi;
                                break;
                            }
                        }
                        if (in_working) |pos| {
                            working.items[pos].deinit();
                            working.items[pos] = try clone_set(allocator, &inter_set);
                            try working.append(allocator, try clone_set(allocator, &diff_set));
                        } else if (difference.items.len < intersection.items.len) {
                            try working.append(allocator, try clone_set(allocator, &diff_set));
                        } else {
                            try working.append(allocator, try clone_set(allocator, &inter_set));
                        }
                        partitions.items[i].deinit();
                        partitions.items[i] = inter_set;
                        try partitions.append(allocator, diff_set);
                    }
                }
            }
        }

        const state_mapping = try allocator.alloc(i32, n);
        defer allocator.free(state_mapping);
        @memset(state_mapping, -1);
        for (partitions.items, 0..) |partition, i| {
            var pit = partition.keyIterator();
            while (pit.next()) |state| state_mapping[@intCast(state.*)] = @intCast(i);
        }
        const out = try now_fsm.rebuild_with_mapping(allocator, state_mapping, @intCast(partitions.items.len));
        now_fsm.deinit();
        return out;
    }

    /// Renders this machine the way the C++ `ToString` does (used by tests as the oracle).
    pub fn to_string_repr(self: *const FsmWithStartEnd) Allocator.Error![]u8 {
        const a = self.allocator;
        var reachable_set = try self.reachable_states();
        defer reachable_set.deinit();
        var reachable = try sorted_set_items(a, &reachable_set);
        defer reachable.deinit(a);
        var ends_text: std.ArrayList(u8) = .empty;
        defer ends_text.deinit(a);
        for (self.ends.items, 0..) |end, i| {
            if (i > 0) try ends_text.appendSlice(a, ", ");
            var buf: [16]u8 = undefined;
            const piece = std.fmt.bufPrint(&buf, "{d}", .{end}) catch unreachable;
            try ends_text.appendSlice(a, piece);
        }
        const edges_text = try self.fsm.edges_to_string(reachable.items);
        defer a.free(edges_text);
        return std.fmt.allocPrint(a, "FSM(num_states={d}, start={d}, end=[{s}], edges={s})", .{
            self.num_states(),
            self.start,
            ends_text.items,
            edges_text,
        });
    }
};

/// A compact endpoint-edge view used by `merge_equivalent_states`; `peer` is the source in
/// incoming rows and the target in outgoing rows.
const EndpointEdge = struct {
    peer: i32,
    min: i32,
    max: i32,
};

fn endpoint_less(_: void, a: EndpointEdge, b: EndpointEdge) bool {
    if (a.peer != b.peer) return a.peer < b.peer;
    if (a.min != b.min) return a.min < b.min;
    return a.max < b.max;
}

/// One `precursors[target]` entry of `minimize_dfa`.
const Precursor = struct { min: i32, max: i32, source: i32 };

/// One BTreeMap entry of `minimize_dfa`'s `possible` map (iteration in sorted key order).
const PossibleGroup = struct {
    min: i32,
    max: i32,
    set: StateSet,
};

fn group_less(_: void, a: PossibleGroup, b: PossibleGroup) bool {
    if (a.min != b.min) return a.min < b.min;
    return a.max < b.max;
}

fn sort_groups(groups: *std.ArrayList(PossibleGroup)) void {
    std.mem.sortUnstable(PossibleGroup, groups.items, {}, group_less);
}

fn find_or_put_group(allocator: Allocator, groups: *std.ArrayList(PossibleGroup), min: i32, max: i32) Allocator.Error!*PossibleGroup {
    for (groups.items) |*g| {
        if (g.min == min and g.max == max) return g;
    }
    try groups.append(allocator, .{ .min = min, .max = max, .set = StateSet.init(allocator) });
    return &groups.items[groups.items.len - 1];
}

fn pack_pair(a: i32, b: i32) u64 {
    return (@as(u64, @as(u32, @bitCast(a))) << 32) | @as(u64, @as(u32, @bitCast(b)));
}

/// Sorted unique list copy of a state set.
fn sorted_set_items(allocator: Allocator, set: *const StateSet) Allocator.Error!std.ArrayList(i32) {
    var list: std.ArrayList(i32) = .empty;
    errdefer list.deinit(allocator);
    var it = set.keyIterator();
    while (it.next()) |k| try list.append(allocator, k.*);
    std.mem.sortUnstable(i32, list.items, {}, std.sort.asc(i32));
    return list;
}

fn sorted_insert_i32(allocator: Allocator, list: *std.ArrayList(i32), value: i32) Allocator.Error!void {
    var pos: usize = 0;
    while (pos < list.items.len and list.items[pos] < value) pos += 1;
    if (pos < list.items.len and list.items[pos] == value) return;
    try list.insert(allocator, pos, value);
}

/// One fixed-point pass of `merge_equivalent_states`; returns whether anything merged.
fn merge_equivalent_pass(result: *FsmWithStartEnd, allocator: Allocator, union_find: *UnionFindSet(i32)) Allocator.Error!bool {
    const n: usize = @intCast(result.num_states());
    union_find.clear();

    // CSR rows of incoming/outgoing endpoint edges (peer, min, max).
    const incoming_sizes = try allocator.alloc(i32, n);
    defer allocator.free(incoming_sizes);
    @memset(incoming_sizes, 0);
    const outgoing_sizes = try allocator.alloc(i32, n);
    defer allocator.free(outgoing_sizes);
    @memset(outgoing_sizes, 0);
    for (outgoing_sizes, 0..) |*out_size, source| {
        const edges = result.fsm.state_edges(@intCast(source));
        out_size.* = @intCast(edges.len);
        for (edges) |e| incoming_sizes[@intCast(e.target)] += 1;
    }
    const zero_edge = EndpointEdge{ .peer = 0, .min = 0, .max = 0 };
    var incoming = try Compact2dArray(EndpointEdge).init_from_row_sizes(allocator, incoming_sizes, zero_edge);
    defer incoming.deinit();
    var outgoing = try Compact2dArray(EndpointEdge).init_from_row_sizes(allocator, outgoing_sizes, zero_edge);
    defer outgoing.deinit();
    const incoming_pos = try allocator.alloc(usize, n);
    defer allocator.free(incoming_pos);
    @memset(incoming_pos, 0);
    const outgoing_pos = try allocator.alloc(usize, n);
    defer allocator.free(outgoing_pos);
    @memset(outgoing_pos, 0);
    for (0..n) |source| {
        const edges = try allocator.dupe(FsmEdge, result.fsm.state_edges(@intCast(source)));
        defer allocator.free(edges);
        for (edges) |e| {
            const t: usize = @intCast(e.target);
            incoming.row_mut(t)[incoming_pos[t]] = .{ .peer = @intCast(source), .min = e.min, .max = e.max };
            incoming_pos[t] += 1;
            const row = outgoing.row_mut(source);
            row[outgoing_pos[source]] = .{ .peer = e.target, .min = e.min, .max = e.max };
            outgoing_pos[source] += 1;
        }
        std.mem.sortUnstable(EndpointEdge, outgoing.row_mut(source), {}, endpoint_less);
    }

    // States with exactly one distinct predecessor / successor.
    const in_distinct = try allocator.alloc(i32, n);
    defer allocator.free(in_distinct);
    @memset(in_distinct, 0);
    const out_distinct = try allocator.alloc(i32, n);
    defer allocator.free(out_distinct);
    @memset(out_distinct, 0);
    const single_in = try allocator.alloc(i32, n);
    defer allocator.free(single_in);
    @memset(single_in, -1);
    const single_out = try allocator.alloc(i32, n);
    defer allocator.free(single_out);
    @memset(single_out, -1);
    for (0..n) |state| {
        const in_row = incoming.row(state);
        if (in_row.len != 0) {
            in_distinct[state] = 1;
            single_in[state] = in_row[0].peer;
            var k: usize = 0;
            while (k + 1 < in_row.len) : (k += 1) {
                if (in_row[k + 1].peer != in_row[k].peer) {
                    in_distinct[state] += 1;
                    single_in[state] = -1;
                }
            }
        }
        const out_row = outgoing.row(state);
        if (out_row.len != 0) {
            out_distinct[state] = 1;
            single_out[state] = out_row[0].peer;
            var k: usize = 0;
            while (k + 1 < out_row.len) : (k += 1) {
                if (out_row[k + 1].peer != out_row[k].peer) {
                    out_distinct[state] += 1;
                    single_out[state] = -1;
                }
            }
        }
    }

    // Case 1: shared prefix — ab | ac | ad -> a(b | c | d).
    var equiv_successor = false;
    for (0..n) |i_usize| {
        const i: i32 = @intCast(i_usize);
        // The start state is also entered without taking any edge, so it is never
        // equivalent to a state only reached through the start state's own self-loop.
        if (in_distinct[i_usize] != 1 or union_find.count(i) or i == result.start) continue;
        const previous = single_in[i_usize];
        const edges_to_i = incoming.row(i_usize);
        const siblings = outgoing.row(@intCast(previous));
        var group_begin: usize = 0;
        while (group_begin < siblings.len) {
            const sibling = siblings[group_begin].peer;
            var group_end = group_begin + 1;
            while (group_end < siblings.len and siblings[group_end].peer == sibling) group_end += 1;
            group_begin = group_end;
            if (sibling <= i or
                in_distinct[@intCast(sibling)] != 1 or
                sibling == result.start or
                result.is_end_state(sibling) != result.is_end_state(i))
            {
                continue;
            }
            const edges_to_sibling = incoming.row(@intCast(sibling));
            if (edges_to_i.len != edges_to_sibling.len) continue;
            var is_equiv = true;
            for (edges_to_i, edges_to_sibling) |a, b| {
                if (!(a.min == b.min and a.max == b.max)) is_equiv = false;
            }
            if (is_equiv) {
                _ = try union_find.add(i);
                _ = try union_find.add(sibling);
                union_find.union_(i, sibling);
                equiv_successor = true;
            }
        }
    }

    // Case 2: shared suffix — ba | ca | da -> (b | c | d)a.
    var equiv_precursor = false;
    var no_succ_end: std.ArrayList(i32) = .empty;
    defer no_succ_end.deinit(allocator);
    var no_succ_non_end: std.ArrayList(i32) = .empty;
    defer no_succ_non_end.deinit(allocator);
    for (0..n) |i_usize| {
        const i: i32 = @intCast(i_usize);
        const outgoing_count = out_distinct[i_usize];
        if (outgoing_count == 0) {
            if (result.is_end_state(i)) {
                try no_succ_end.append(allocator, i);
            } else {
                try no_succ_non_end.append(allocator, i);
            }
            continue;
        }
        if (outgoing_count != 1 or union_find.count(i)) continue;
        const next_state = single_out[i_usize];
        const node_edges = outgoing.row(i_usize);
        const siblings = incoming.row(@intCast(next_state));
        var group_begin: usize = 0;
        while (group_begin < siblings.len) {
            const sibling = siblings[group_begin].peer;
            while (group_begin < siblings.len and siblings[group_begin].peer == sibling) group_begin += 1;
            if (sibling <= i or
                union_find.count(sibling) or
                out_distinct[@intCast(sibling)] != 1 or
                result.is_end_state(i) != result.is_end_state(sibling))
            {
                continue;
            }
            const sibling_edges = outgoing.row(@intCast(sibling));
            if (sibling_edges.len != node_edges.len) continue;
            var is_equiv = true;
            for (sibling_edges, node_edges) |a, b| {
                if (!(a.min == b.min and a.max == b.max)) is_equiv = false;
            }
            if (is_equiv) {
                _ = try union_find.add(i);
                _ = try union_find.add(sibling);
                union_find.union_(i, sibling);
                equiv_precursor = true;
            }
        }
    }

    if (no_succ_end.items.len > 1) {
        for (no_succ_end.items[1..]) |state| {
            _ = try union_find.add(no_succ_end.items[0]);
            _ = try union_find.add(state);
            union_find.union_(no_succ_end.items[0], state);
            equiv_precursor = true;
        }
    }
    if (no_succ_non_end.items.len > 1) {
        for (no_succ_non_end.items[1..]) |state| {
            _ = try union_find.add(no_succ_non_end.items[0]);
            _ = try union_find.add(state);
            union_find.union_(no_succ_non_end.items[0], state);
            equiv_precursor = true;
        }
    }

    const changed = equiv_successor or equiv_precursor;
    if (changed) {
        var eq_classes = try union_find.get_all_sets(allocator);
        defer {
            for (eq_classes.items) |*set| set.deinit(allocator);
            eq_classes.deinit(allocator);
        }
        const old_to_new = try allocator.alloc(i32, @intCast(result.num_states()));
        defer allocator.free(old_to_new);
        @memset(old_to_new, -1);
        for (eq_classes.items, 0..) |class, i| {
            for (class.items) |state| old_to_new[@intCast(state)] = @intCast(i);
        }
        var cnt: i32 = @intCast(eq_classes.items.len);
        for (0..@intCast(result.num_states())) |i| {
            if (old_to_new[i] == -1) {
                old_to_new[i] = cnt;
                cnt += 1;
            }
        }
        const merged = try result.rebuild_with_mapping(allocator, old_to_new, cnt);
        result.deinit();
        result.* = merged;
        result.fsm_mut().sort_edges();
    }
    return changed;
}
