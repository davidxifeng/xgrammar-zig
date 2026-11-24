//! An FSM paired with a start state and a set of accepting states, plus automata operations
//! (DFA conversion, Hopcroft minimization, complement, intersection, epsilon simplification,
//! and equivalent-state merging).

const std = @import("std");
const Allocator = std.mem.Allocator;

const fsm_mod = @import("Fsm.zig");
const Fsm = fsm_mod.Fsm;
const FsmSliceMeta = fsm_mod.FsmSliceMeta;
const StateSet = fsm_mod.StateSet;
const cloneSet = fsm_mod.cloneSet;
const stateSetFrom = fsm_mod.stateSetFrom;
const stateSetEql = fsm_mod.stateSetEql;
const edge_mod = @import("edge.zig");
const FsmEdge = edge_mod.FsmEdge;
const edge_type = edge_mod.edge_type;
const support = @import("../support.zig");
const Compact2dArray = support.Compact2dArray;
const UnionFindSet = support.UnionFindSet;

pub const FsmWithStartEndWithSize = FsmSliceMeta;

/// State-count ceiling for `simplifyEpsilon` (`1e8`).
const SIMPLIFY_EPSILON_MAX_STATES: i32 = 100_000_000;
/// State-count ceiling for `mergeEquivalentStates` (`1e5`).
const MERGE_STATES_MAX_STATES: i32 = 100_000;
/// State-count ceiling for `toDfa` / `minimizeDfa` (`1e3`).
const DFA_MAX_STATES: i32 = 1_000;
/// State-count ceiling for `not` / `intersect` (`1e6`).
const NOT_INTERSECT_MAX_STATES: i32 = 1_000_000;

/// Errors of the automata operations.
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
    pub fn init(allocator: Allocator, fsm: Fsm, start: i32, ends: std.ArrayList(i32), is_dfa: bool) FsmWithStartEnd {
        var ends_list = ends;
        normalizeEnds(&ends_list);
        return .{
            .allocator = allocator,
            .fsm = fsm,
            .start = start,
            .ends = ends_list,
            .is_dfa = is_dfa,
        };
    }

    /// Frees all storage owned by this machine.
    pub fn deinit(self: *FsmWithStartEnd) void {
        self.fsm.deinit();
        self.ends.deinit(self.allocator);
    }

    fn normalizeEnds(ends: *std.ArrayList(i32)) void {
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
    pub fn dupe(self: *const FsmWithStartEnd, allocator: Allocator) Allocator.Error!FsmWithStartEnd {
        var fsm = try self.fsm.dupe(allocator);
        errdefer fsm.deinit();
        var ends: std.ArrayList(i32) = .empty;
        errdefer ends.deinit(allocator);
        try ends.appendSlice(allocator, self.ends.items);
        return .{
            .allocator = allocator,
            .fsm = fsm,
            .start = self.start,
            .ends = ends,
            .is_dfa = self.is_dfa,
        };
    }

    /// The underlying FSM.
    pub fn getFsm(self: *const FsmWithStartEnd) *const Fsm {
        return &self.fsm;
    }

    /// A mutable reference to the underlying FSM.
    pub fn fsmMut(self: *FsmWithStartEnd) *Fsm {
        return &self.fsm;
    }

    /// The start state.
    pub fn startState(self: *const FsmWithStartEnd) i32 {
        return self.start;
    }

    /// The accepting states, as a sorted, deduplicated list of state ids.
    pub fn endsSlice(self: *const FsmWithStartEnd) []const i32 {
        return self.ends.items;
    }

    /// Whether `state` is an accepting state.
    pub fn isEndState(self: *const FsmWithStartEnd, state: i32) bool {
        const items = self.ends.items;
        if (items.len <= 8) {
            for (items) |e| {
                if (e == state) return true;
            }
            return false;
        }
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid] < state) {
                lo = mid + 1;
            } else if (items[mid] > state) {
                hi = mid;
            } else {
                return true;
            }
        }
        return false;
    }

    /// Whether this machine is known to be a DFA.
    pub fn isDfa(self: *const FsmWithStartEnd) bool {
        return self.is_dfa;
    }

    /// The number of states.
    pub fn numStates(self: *const FsmWithStartEnd) i32 {
        return self.fsm.numStates();
    }

    /// Sets the start state.
    pub fn setStartState(self: *FsmWithStartEnd, state: i32) void {
        self.start = state;
    }

    /// Marks `state` as accepting.
    pub fn addEndState(self: *FsmWithStartEnd, state: i32) Allocator.Error!void {
        std.debug.assert(state >= 0 and state < self.numStates());
        var lo: usize = 0;
        var hi: usize = self.ends.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.ends.items[mid] < state) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo < self.ends.items.len and self.ends.items[lo] == state) return;
        try self.ends.insert(self.allocator, lo, state);
    }

    /// Replaces the accepting-state set. `ends` need not be sorted or deduplicated (consumed).
    pub fn setEndStates(self: *FsmWithStartEnd, ends: std.ArrayList(i32)) void {
        var ends_list = ends;
        normalizeEnds(&ends_list);
        self.ends.deinit(self.allocator);
        self.ends = ends_list;
    }

    /// Adds a new (non-accepting) state, returning its id.
    pub fn addState(self: *FsmWithStartEnd) Allocator.Error!i32 {
        return self.fsm.addState();
    }

    /// Whether `state` has an outgoing character/token edge (can consume input).
    pub fn isScanableState(self: *const FsmWithStartEnd, state: i32) bool {
        for (self.fsm.stateEdges(state)) |e| {
            if (e.isCharRange() or e.isToken() or e.isExcludeToken()) return true;
        }
        return false;
    }

    /// Whether `state` has an outgoing rule/epsilon/repeat edge (is non-terminal).
    pub fn isNonTerminalState(self: *const FsmWithStartEnd, state: i32) bool {
        for (self.fsm.stateEdges(state)) |e| {
            if (e.isRuleRef() or e.isEpsilon() or e.isRepeatRef()) return true;
        }
        return false;
    }

    /// Whether the FSM accepts the byte sequence `input` (which need not be valid UTF-8).
    pub fn acceptString(self: *const FsmWithStartEnd, input: []const u8) Allocator.Error!bool {
        var states = try stateSetFrom(self.allocator, &.{self.start});
        defer states.deinit();
        try self.fsm.epsilonClosure(&states);
        var result = StateSet.init(self.allocator);
        defer result.deinit();
        for (input) |byte| {
            try self.fsm.advance(&states, @intCast(byte), &result, .CharRange, false);
            if (result.count() == 0) return false;
            std.mem.swap(StateSet, &states, &result);
        }
        var it = states.keyIterator();
        while (it.next()) |s| {
            if (self.isEndState(s.*)) return true;
        }
        return false;
    }

    /// The set of states reachable from the start state (caller owns the set).
    pub fn reachableStates(self: *const FsmWithStartEnd) Allocator.Error!StateSet {
        return self.fsm.reachableStates(self.allocator, &.{self.start});
    }

    /// Whether the FSM is a leaf (contains no rule or repeat references).
    pub fn isLeaf(self: *const FsmWithStartEnd) Allocator.Error!bool {
        var reachable = try self.reachableStates();
        defer reachable.deinit();
        var it = reachable.keyIterator();
        while (it.next()) |state_key| {
            for (self.fsm.stateEdges(state_key.*)) |e| {
                if (e.isRuleRef() or e.isRepeatRef()) return false;
            }
        }
        return true;
    }

    /// `self*` — zero or more repetitions (a fresh accepting start state loops back).
    pub fn star(self: *const FsmWithStartEnd, allocator: Allocator) Allocator.Error!FsmWithStartEnd {
        var fsm = try self.fsm.dupe(allocator);
        errdefer fsm.deinit();
        const new_start = try fsm.addState();
        for (self.ends.items) |end| try fsm.addEpsilonEdge(end, new_start);
        try fsm.addEpsilonEdge(new_start, self.start);
        var ends: std.ArrayList(i32) = .empty;
        errdefer ends.deinit(allocator);
        try ends.append(allocator, new_start);
        return FsmWithStartEnd.init(allocator, fsm, new_start, ends, false);
    }

    /// `self+` — one or more repetitions (each end loops back to the start).
    pub fn plus(self: *const FsmWithStartEnd, allocator: Allocator) Allocator.Error!FsmWithStartEnd {
        var fsm = try self.fsm.dupe(allocator);
        errdefer fsm.deinit();
        for (self.ends.items) |end| try fsm.addEpsilonEdge(end, self.start);
        var ends: std.ArrayList(i32) = .empty;
        errdefer ends.deinit(allocator);
        try ends.appendSlice(allocator, self.ends.items);
        return FsmWithStartEnd.init(allocator, fsm, self.start, ends, false);
    }

    /// `self?` — zero or one repetition (start may epsilon-skip to an end).
    pub fn optional(self: *const FsmWithStartEnd, allocator: Allocator) Allocator.Error!FsmWithStartEnd {
        var fsm = try self.fsm.dupe(allocator);
        errdefer fsm.deinit();
        if (self.ends.items.len > 0) {
            try fsm.addEpsilonEdge(self.start, self.ends.items[0]);
        }
        var ends: std.ArrayList(i32) = .empty;
        errdefer ends.deinit(allocator);
        try ends.appendSlice(allocator, self.ends.items);
        return FsmWithStartEnd.init(allocator, fsm, self.start, ends, false);
    }

    /// The union of `fsms` (a fresh start state epsilon-links to each). The caller owns the
    /// result; the inputs are untouched.
    pub fn unionOf(allocator: Allocator, fsms: []const FsmWithStartEnd) Allocator.Error!FsmWithStartEnd {
        std.debug.assert(fsms.len != 0);
        if (fsms.len == 1) return fsms[0].dupe(allocator);
        var fsm = try Fsm.init(allocator, 1);
        errdefer fsm.deinit();
        const start: i32 = 0;
        var ends: std.ArrayList(i32) = .empty;
        errdefer ends.deinit(allocator);
        for (fsms) |sub| {
            const offset = try fsm.addFsm(&sub.fsm);
            try fsm.addEpsilonEdge(start, offset + sub.start);
            for (sub.ends.items) |end| try ends.append(allocator, offset + end);
        }
        return FsmWithStartEnd.init(allocator, fsm, start, ends, false);
    }

    /// The concatenation of `fsms` (each machine's ends epsilon-link to the next's start).
    pub fn concat(allocator: Allocator, fsms: []const FsmWithStartEnd) Allocator.Error!FsmWithStartEnd {
        std.debug.assert(fsms.len != 0);
        if (fsms.len == 1) return fsms[0].dupe(allocator);
        var fsm = try Fsm.empty(allocator);
        errdefer fsm.deinit();
        var start: i32 = 0;
        var previous_ends: std.ArrayList(i32) = .empty;
        errdefer previous_ends.deinit(allocator);
        for (fsms, 0..) |sub, i| {
            const offset = try fsm.addFsm(&sub.fsm);
            if (i == 0) {
                start = offset + sub.start;
            } else {
                const this_start = offset + sub.start;
                for (previous_ends.items) |end| try fsm.addEpsilonEdge(end, this_start);
            }
            previous_ends.clearRetainingCapacity();
            for (sub.ends.items) |end| try previous_ends.append(allocator, offset + end);
        }
        return FsmWithStartEnd.init(allocator, fsm, start, previous_ends, false);
    }

    /// Appends this machine's states/edges into `complete` (a shared FSM), returning the
    /// resulting start state, accepting set, and pre-merge sizes.
    pub fn addToCompleteFsm(self: *const FsmWithStartEnd, complete: *Fsm) Allocator.Error!FsmSliceMeta {
        const offset = try complete.addFsm(&self.fsm);
        const n = self.numStates();
        const new_start = offset + self.start;
        var new_ends: std.ArrayList(i32) = .empty;
        errdefer new_ends.deinit(complete.allocator);
        for (self.ends.items) |end| try new_ends.append(complete.allocator, offset + end);
        var edge_num: usize = 0;
        for (0..@intCast(n)) |i| edge_num += self.fsm.edges.items[i].items.len;
        return FsmSliceMeta.init(complete.allocator, new_start, new_ends, @intCast(edge_num), n);
    }

    /// Rebuilds this machine under `state_mapping` (old id -> new id), collapsing the merged
    /// states. The result is not flagged as a DFA.
    pub fn rebuildWithMapping(
        self: *const FsmWithStartEnd,
        allocator: Allocator,
        state_mapping: []const i32,
        new_num_states: i32,
    ) Allocator.Error!FsmWithStartEnd {
        var new_fsm = try self.fsm.rebuildWithMapping(allocator, state_mapping, new_num_states);
        errdefer new_fsm.deinit();
        var new_ends: std.ArrayList(i32) = .empty;
        errdefer new_ends.deinit(allocator);
        for (self.ends.items) |end| try new_ends.append(allocator, state_mapping[@intCast(end)]);
        return FsmWithStartEnd.init(allocator, new_fsm, state_mapping[@intCast(self.start)], new_ends, false);
    }

    /// The complement of this machine (a leaf DFA accepting exactly the strings it rejects).
    pub fn not(self: *const FsmWithStartEnd, allocator: Allocator) AutomataError!FsmWithStartEnd {
        if (!try self.isLeaf()) return error.NotLeaf;
        var result = if (self.is_dfa)
            try self.dupe(allocator)
        else
            try self.toDfaWithLimit(allocator, NOT_INTERSECT_MAX_STATES);
        errdefer result.deinit();

        var new_final: std.ArrayList(i32) = .empty;
        defer new_final.deinit(allocator);
        for (0..@intCast(result.numStates())) |i| {
            if (!result.isEndState(@intCast(i))) try new_final.append(allocator, @intCast(i));
        }
        const accept_all = try result.addState();
        try new_final.append(allocator, accept_all);
        for (0..@intCast(result.numStates())) |i| {
            var char_set: [256]bool = @splat(false);
            for (result.fsm.stateEdges(@intCast(i))) |e| {
                if (e.isCharRange()) {
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
                try result.fsmMut().addEdge(@intCast(i), accept_all, @intCast(left), @intCast(right - 1));
                left = right;
            }
        }
        var final = std.ArrayList(i32).empty;
        errdefer final.deinit(allocator);
        try final.appendSlice(allocator, new_final.items);
        result.setEndStates(final);
        return result;
    }

    /// The intersection of two leaf machines (the product DFA), with a `1e6` state limit.
    pub fn intersect(allocator: Allocator, lhs: *const FsmWithStartEnd, rhs: *const FsmWithStartEnd) AutomataError!FsmWithStartEnd {
        return intersectWithLimit(allocator, lhs, rhs, NOT_INTERSECT_MAX_STATES);
    }

    /// The intersection of two leaf machines (the product DFA). Both the DFA conversion of each
    /// operand and the product are bounded by `max_result_num_states`.
    pub fn intersectWithLimit(
        allocator: Allocator,
        lhs: *const FsmWithStartEnd,
        rhs: *const FsmWithStartEnd,
        max_result_num_states: i32,
    ) AutomataError!FsmWithStartEnd {
        if (!try lhs.isLeaf() or !try rhs.isLeaf()) return error.NotLeaf;
        var lhs_owned = try lhs.toDfaWithLimit(allocator, max_result_num_states);
        defer lhs_owned.deinit();
        var rhs_owned = try rhs.toDfaWithLimit(allocator, max_result_num_states);
        defer rhs_owned.deinit();

        var result = FsmWithStartEnd.init(allocator, try Fsm.init(allocator, 0), 0, .empty, true);
        errdefer result.deinit();

        var state_map = std.AutoHashMap(u64, i32).init(allocator);
        defer state_map.deinit();
        var queue: std.ArrayList(u64) = .empty;
        defer queue.deinit(allocator);

        const start_pair = packPair(lhs_owned.start, rhs_owned.start);
        try queue.append(allocator, start_pair);
        _ = try result.addState();
        try state_map.put(start_pair, 0);

        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const pair = queue.items[head];
            const lhs_state: i32 = @intCast(@as(i64, @bitCast(pair)) >> 32);
            const rhs_state: i32 = @bitCast(@as(u32, @truncate(pair)));
            const from = state_map.get(pair).?;
            if (lhs_owned.isEndState(lhs_state) and rhs_owned.isEndState(rhs_state)) {
                try result.addEndState(from);
            }
            for (lhs_owned.fsm.stateEdges(lhs_state)) |le| {
                for (rhs_owned.fsm.stateEdges(rhs_state)) |re| {
                    if (le.min > re.max or re.min > le.max) continue;
                    const min_v = @max(le.min, re.min);
                    const max_v = @min(le.max, re.max);
                    const key = packPair(le.target, re.target);
                    const target = state_map.get(key) orelse blk: {
                        if (result.numStates() >= max_result_num_states) return error.StateLimitExceeded;
                        const t = try result.addState();
                        try state_map.put(key, t);
                        try queue.append(allocator, key);
                        break :blk t;
                    };
                    try result.fsmMut().addEdge(from, target, min_v, max_v);
                }
            }
        }
        return result;
    }

    /// Simplifies epsilon transitions by merging chains of epsilon-only states.
    pub fn simplifyEpsilon(self: *const FsmWithStartEnd, allocator: Allocator) Allocator.Error!FsmWithStartEnd {
        if (self.is_dfa or self.numStates() > SIMPLIFY_EPSILON_MAX_STATES) {
            return self.dupe(allocator);
        }
        const n: usize = @intCast(self.numStates());
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
            for (self.fsm.stateEdges(@intCast(i))) |e| {
                if (e.isExcludeToken()) has_exclude_token[i] = true;
            }
        }

        for (0..n) |i| {
            const edges = self.fsm.stateEdges(@intCast(i));
            for (edges) |e| {
                in_degree[@intCast(e.target)] += 1;
                if (e.isEpsilon()) {
                    // a -epsilon-> b is a's only edge. Never merge an accepting a into a
                    // non-accepting b: the merged state would accept every other path into b.
                    if (edges.len == 1 and
                        !has_exclude_token[i] and
                        !has_exclude_token[@intCast(e.target)] and
                        (!self.isEndState(@intCast(i)) or self.isEndState(e.target)))
                    {
                        _ = try union_find.add(@intCast(i));
                        _ = try union_find.add(e.target);
                        union_find.unite(@intCast(i), e.target);
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
            if (union_find.contains(@intCast(i))) {
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
                union_find.unite(from, to);
            }
        }

        var eq_classes = try union_find.getAllSets(allocator);
        defer {
            for (eq_classes.items) |*set| set.deinit(allocator);
            eq_classes.deinit(allocator);
        }
        if (eq_classes.items.len == 0) {
            return self.dupe(allocator);
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
        return self.rebuildWithMapping(allocator, new_to_old, cnt);
    }

    /// Merges equivalent states (shared-prefix and shared-suffix collapsing), iterating to a
    /// fixed point. Returns an unchanged copy if it exceeds the state limit.
    pub fn mergeEquivalentStates(self: *const FsmWithStartEnd, allocator: Allocator) Allocator.Error!FsmWithStartEnd {
        if (MERGE_STATES_MAX_STATES < self.numStates() or self.numStates() < 4) {
            return self.dupe(allocator);
        }
        var result = try self.dupe(allocator);
        errdefer result.deinit();
        result.fsmMut().sortEdges();
        var union_find = UnionFindSet(i32).init(allocator);
        defer union_find.deinit();
        var changed = true;
        while (changed) {
            changed = try mergeEquivalentPass(&result, allocator, &union_find);
        }
        return result;
    }

    /// Converts this NFA into an equivalent DFA via subset construction, with a `1e3` limit.
    pub fn toDfa(self: *const FsmWithStartEnd, allocator: Allocator) AutomataError!FsmWithStartEnd {
        return self.toDfaWithLimit(allocator, DFA_MAX_STATES);
    }

    /// Converts this NFA into an equivalent DFA via subset construction.
    pub fn toDfaWithLimit(self: *const FsmWithStartEnd, allocator: Allocator, max_num_states: i32) AutomataError!FsmWithStartEnd {
        if (self.numStates() > max_num_states) return error.StateLimitExceeded;
        var dfa = FsmWithStartEnd.init(allocator, try Fsm.init(allocator, 0), 0, .empty, true);
        errdefer dfa.deinit();

        var closures: std.ArrayList(StateSet) = .empty;
        defer {
            for (closures.items) |*c| c.deinit();
            closures.deinit(allocator);
        }
        try closures.append(allocator, try self.epsilonClosureOf(allocator, self.start));

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
            var interval_ends: std.ArrayList(i32) = .empty;
            defer interval_ends.deinit(allocator);
            var allowed: [256]bool = @splat(false);
            _ = try dfa.addState();
            var closure_it = closures.items[now_process].keyIterator();
            while (closure_it.next()) |state_key| {
                const state = state_key.*;
                if (self.isEndState(state)) try dfa.addEndState(@intCast(now_process));
                for (self.fsm.stateEdges(state)) |e| {
                    if (e.isCharRange()) {
                        try sortedInsertI32(allocator, &interval_ends, e.min);
                        try sortedInsertI32(allocator, &interval_ends, e.max + 1);
                        var c = e.min;
                        while (c <= e.max) : (c += 1) allowed[@intCast(c)] = true;
                    } else if (e.isRuleRef()) {
                        try rules.put(e.refRuleId(), {});
                    } else if (e.isRepeatRef()) {
                        try repeat_aux.put(e.auxIndex(), {});
                    } else if (e.isToken()) {
                        try token_aux.put(e.auxIndex(), {});
                    } else if (e.isExcludeToken()) {
                        try exclude_aux.put(e.auxIndex(), {});
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
                    if (!allowed[@intCast(c)]) {
                        all = false;
                        break;
                    }
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
                    for (self.fsm.stateEdges(state_key.*)) |e| {
                        if (e.isCharRange() and lo >= e.min and hi <= e.max and !next_closure.contains(e.target)) {
                            var closure = try self.epsilonClosureOf(allocator, e.target);
                            defer closure.deinit();
                            var cit = closure.keyIterator();
                            while (cit.next()) |k| try next_closure.put(k.*, {});
                        }
                    }
                }
                const target = try findOrAddClosure(allocator, &closures, &next_closure, max_num_states);
                try dfa.fsmMut().addEdge(@intCast(now_process), target, lo, hi);
            }

            var rules_list = try sortedSetItems(allocator, &rules);
            defer rules_list.deinit(allocator);
            for (rules_list.items) |rule| {
                var next_closure = StateSet.init(allocator);
                defer next_closure.deinit();
                closure_it = closures.items[now_process].keyIterator();
                while (closure_it.next()) |state_key| {
                    for (self.fsm.stateEdges(state_key.*)) |e| {
                        if (e.isRuleRef() and e.refRuleId() == rule and !next_closure.contains(e.target)) {
                            var closure = try self.epsilonClosureOf(allocator, e.target);
                            defer closure.deinit();
                            var cit = closure.keyIterator();
                            while (cit.next()) |k| try next_closure.put(k.*, {});
                        }
                    }
                }
                const target = try findOrAddClosure(allocator, &closures, &next_closure, max_num_states);
                try dfa.fsmMut().addRuleEdge(@intCast(now_process), target, rule);
            }

            try self.dfaAuxTransitions(allocator, &dfa, &closures, now_process, &repeat_aux, edge_type.REPEAT_REF, max_num_states);
            try self.dfaAuxTransitions(allocator, &dfa, &closures, now_process, &token_aux, edge_type.TOKEN, max_num_states);
            try self.dfaAuxTransitions(allocator, &dfa, &closures, now_process, &exclude_aux, edge_type.EXCLUDE_TOKEN, max_num_states);
        }
        var aux: std.ArrayList(i32) = .empty;
        errdefer aux.deinit(allocator);
        try aux.appendSlice(allocator, self.fsm.edge_aux_data.items);
        dfa.fsmMut().setEdgeAuxData(aux);
        return dfa;
    }

    fn epsilonClosureOf(self: *const FsmWithStartEnd, allocator: Allocator, state: i32) Allocator.Error!StateSet {
        var closure = try stateSetFrom(allocator, &.{state});
        errdefer closure.deinit();
        try self.fsm.epsilonClosure(&closure);
        return closure;
    }

    fn findOrAddClosure(
        allocator: Allocator,
        closures: *std.ArrayList(StateSet),
        next_closure: *const StateSet,
        max_num_states: i32,
    ) AutomataError!i32 {
        for (closures.items, 0..) |*c, j| {
            if (stateSetEql(c.*, next_closure.*)) return @intCast(j);
        }
        if (closures.items.len >= max_num_states) return error.StateLimitExceeded;
        try closures.append(allocator, try cloneSet(allocator, next_closure));
        return @intCast(closures.items.len - 1);
    }

    fn dfaAuxTransitions(
        self: *const FsmWithStartEnd,
        allocator: Allocator,
        dfa: *FsmWithStartEnd,
        closures: *std.ArrayList(StateSet),
        now_process: usize,
        aux_indices: *const StateSet,
        kind: i32,
        max_num_states: i32,
    ) AutomataError!void {
        var aux_vec = try sortedSetItems(allocator, aux_indices);
        defer aux_vec.deinit(allocator);
        for (aux_vec.items) |aux_idx| {
            var next_closure = StateSet.init(allocator);
            defer next_closure.deinit();
            var closure_it = closures.items[now_process].keyIterator();
            while (closure_it.next()) |state_key| {
                for (self.fsm.stateEdges(state_key.*)) |e| {
                    if (e.min == kind and e.auxIndex() == aux_idx and !next_closure.contains(e.target)) {
                        var closure = try self.epsilonClosureOf(allocator, e.target);
                        defer closure.deinit();
                        var cit = closure.keyIterator();
                        while (cit.next()) |k| try next_closure.put(k.*, {});
                    }
                }
            }
            const target = try findOrAddClosure(allocator, closures, &next_closure, max_num_states);
            try dfa.fsmMut().addEdge(@intCast(now_process), target, kind, aux_idx);
        }
    }

    /// Minimizes a DFA (converting first if needed) via Hopcroft partition refinement.
    pub fn minimizeDfa(self: *const FsmWithStartEnd, allocator: Allocator) AutomataError!FsmWithStartEnd {
        if (self.numStates() > DFA_MAX_STATES) return error.StateLimitExceeded;
        var now_fsm = if (self.is_dfa)
            try self.dupe(allocator)
        else
            try self.toDfa(allocator);
        defer now_fsm.deinit();
        const n: usize = @intCast(now_fsm.numStates());

        // precursors[target] = list of ((min, max), source).
        var precursors = try allocator.alloc(std.ArrayList(Precursor), n);
        for (precursors) |*p| p.* = .empty;
        defer {
            for (precursors) |*p| p.deinit(allocator);
            allocator.free(precursors);
        }
        for (0..n) |i| {
            for (now_fsm.fsm.stateEdges(@intCast(i))) |e| {
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
            if (now_fsm.isEndState(@intCast(i))) {
                try final_states.put(@intCast(i), {});
            } else {
                try non_final.put(@intCast(i), {});
            }
        }
        try partitions.append(allocator, try cloneSet(allocator, &final_states));
        try partitions.append(allocator, try cloneSet(allocator, &non_final));
        try working.append(allocator, try cloneSet(allocator, &final_states));
        try working.append(allocator, try cloneSet(allocator, &non_final));

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
                    const gop = try findOrPutGroup(allocator, &possible, prec.min, prec.max);
                    if (!gop.set.contains(prec.source)) try gop.set.put(prec.source, {});
                }
            }
            sortGroups(&possible);

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
                        var inter_set = try stateSetFrom(allocator, intersection.items);
                        errdefer inter_set.deinit();
                        var diff_set = try stateSetFrom(allocator, difference.items);
                        errdefer diff_set.deinit();

                        var in_working: ?usize = null;
                        for (working.items, 0..) |*w, wi| {
                            if (stateSetEql(w.*, partitions.items[i])) {
                                in_working = wi;
                                break;
                            }
                        }
                        if (in_working) |pos| {
                            var w_inter = try cloneSet(allocator, &inter_set);
                            errdefer w_inter.deinit();
                            var w_diff = try cloneSet(allocator, &diff_set);
                            errdefer w_diff.deinit();
                            try working.ensureUnusedCapacity(allocator, 1);
                            try partitions.ensureUnusedCapacity(allocator, 1);
                            working.items[pos].deinit();
                            working.items[pos] = w_inter;
                            working.appendAssumeCapacity(w_diff);
                        } else if (difference.items.len < intersection.items.len) {
                            var w_diff = try cloneSet(allocator, &diff_set);
                            errdefer w_diff.deinit();
                            try working.ensureUnusedCapacity(allocator, 1);
                            try partitions.ensureUnusedCapacity(allocator, 1);
                            working.appendAssumeCapacity(w_diff);
                        } else {
                            var w_inter = try cloneSet(allocator, &inter_set);
                            errdefer w_inter.deinit();
                            try working.ensureUnusedCapacity(allocator, 1);
                            try partitions.ensureUnusedCapacity(allocator, 1);
                            working.appendAssumeCapacity(w_inter);
                        }
                        partitions.items[i].deinit();
                        partitions.items[i] = inter_set;
                        partitions.appendAssumeCapacity(diff_set);
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
        return now_fsm.rebuildWithMapping(allocator, state_mapping, @intCast(partitions.items.len));
    }

    /// Streams this machine the way the C++ `ToString` does.
    pub fn writeRepr(
        self: *const FsmWithStartEnd,
        writer: *std.Io.Writer,
        allocator: Allocator,
    ) Allocator.Error!void {
        var reachable_set = try self.fsm.reachableStates(allocator, &.{self.start});
        defer reachable_set.deinit();
        var reachable = try sortedSetItems(allocator, &reachable_set);
        defer reachable.deinit(allocator);
        writer.print("FSM(num_states={d}, start={d}, end=[", .{
            self.numStates(),
            self.start,
        }) catch return error.OutOfMemory;
        for (self.ends.items, 0..) |end, i| {
            if (i > 0) writer.writeAll(", ") catch return error.OutOfMemory;
            writer.print("{d}", .{end}) catch return error.OutOfMemory;
        }
        writer.writeAll("], edges=") catch return error.OutOfMemory;
        self.fsm.writeEdges(writer, reachable.items) catch return error.OutOfMemory;
        writer.writeByte(')') catch return error.OutOfMemory;
    }

    /// Renders this machine the way the C++ `ToString` does. Caller owns the returned slice.
    pub fn toStringRepr(self: *const FsmWithStartEnd, allocator: Allocator) Allocator.Error![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        try self.writeRepr(&aw.writer, allocator);
        return aw.toOwnedSlice();
    }
};

const EndpointEdge = struct {
    peer: i32,
    min: i32,
    max: i32,
};

fn endpointLess(_: void, a: EndpointEdge, b: EndpointEdge) bool {
    if (a.peer != b.peer) return a.peer < b.peer;
    if (a.min != b.min) return a.min < b.min;
    return a.max < b.max;
}

const Precursor = struct { min: i32, max: i32, source: i32 };

const PossibleGroup = struct {
    min: i32,
    max: i32,
    set: StateSet,
};

fn groupLess(_: void, a: PossibleGroup, b: PossibleGroup) bool {
    if (a.min != b.min) return a.min < b.min;
    return a.max < b.max;
}

fn sortGroups(groups: *std.ArrayList(PossibleGroup)) void {
    std.mem.sortUnstable(PossibleGroup, groups.items, {}, groupLess);
}

fn findOrPutGroup(
    allocator: Allocator,
    groups: *std.ArrayList(PossibleGroup),
    min: i32,
    max: i32,
) Allocator.Error!*PossibleGroup {
    for (groups.items) |*g| {
        if (g.min == min and g.max == max) return g;
    }
    try groups.append(allocator, .{ .min = min, .max = max, .set = StateSet.init(allocator) });
    return &groups.items[groups.items.len - 1];
}

fn packPair(a: i32, b: i32) u64 {
    return (@as(u64, @as(u32, @bitCast(a))) << 32) | @as(u64, @as(u32, @bitCast(b)));
}

fn sortedSetItems(allocator: Allocator, set: *const StateSet) Allocator.Error!std.ArrayList(i32) {
    var list: std.ArrayList(i32) = .empty;
    errdefer list.deinit(allocator);
    try list.ensureTotalCapacity(allocator, set.count());
    var it = set.keyIterator();
    while (it.next()) |k| list.appendAssumeCapacity(k.*);
    std.mem.sortUnstable(i32, list.items, {}, std.sort.asc(i32));
    return list;
}

fn sortedInsertI32(allocator: Allocator, list: *std.ArrayList(i32), value: i32) Allocator.Error!void {
    var lo: usize = 0;
    var hi: usize = list.items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (list.items[mid] < value) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    if (lo < list.items.len and list.items[lo] == value) return;
    try list.insert(allocator, lo, value);
}

/// One fixed-point pass of `mergeEquivalentStates`; returns whether anything merged.
fn mergeEquivalentPass(
    result: *FsmWithStartEnd,
    allocator: Allocator,
    union_find: *UnionFindSet(i32),
) Allocator.Error!bool {
    const n: usize = @intCast(result.numStates());
    union_find.clear();

    const incoming_sizes = try allocator.alloc(i32, n);
    defer allocator.free(incoming_sizes);
    @memset(incoming_sizes, 0);
    const outgoing_sizes = try allocator.alloc(i32, n);
    defer allocator.free(outgoing_sizes);
    @memset(outgoing_sizes, 0);
    for (outgoing_sizes, 0..) |*out_size, source| {
        const edges = result.fsm.stateEdges(@intCast(source));
        out_size.* = @intCast(edges.len);
        for (edges) |e| incoming_sizes[@intCast(e.target)] += 1;
    }
    const zero_edge = EndpointEdge{ .peer = 0, .min = 0, .max = 0 };
    var incoming = try Compact2dArray(EndpointEdge).initFromRowSizes(allocator, incoming_sizes, zero_edge);
    defer incoming.deinit(allocator);
    var outgoing = try Compact2dArray(EndpointEdge).initFromRowSizes(allocator, outgoing_sizes, zero_edge);
    defer outgoing.deinit(allocator);
    const incoming_pos = try allocator.alloc(usize, n);
    defer allocator.free(incoming_pos);
    @memset(incoming_pos, 0);
    const outgoing_pos = try allocator.alloc(usize, n);
    defer allocator.free(outgoing_pos);
    @memset(outgoing_pos, 0);
    for (0..n) |source| {
        for (result.fsm.stateEdges(@intCast(source))) |e| {
            const t: usize = @intCast(e.target);
            incoming.rowMut(t)[incoming_pos[t]] = .{ .peer = @intCast(source), .min = e.min, .max = e.max };
            incoming_pos[t] += 1;
            const row = outgoing.rowMut(source);
            row[outgoing_pos[source]] = .{ .peer = e.target, .min = e.min, .max = e.max };
            outgoing_pos[source] += 1;
        }
        std.mem.sortUnstable(EndpointEdge, outgoing.rowMut(source), {}, endpointLess);
    }

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
        if (in_distinct[i_usize] != 1 or union_find.contains(i) or i == result.start) continue;
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
                result.isEndState(sibling) != result.isEndState(i))
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
                union_find.unite(i, sibling);
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
            if (result.isEndState(i)) {
                try no_succ_end.append(allocator, i);
            } else {
                try no_succ_non_end.append(allocator, i);
            }
            continue;
        }
        if (outgoing_count != 1 or union_find.contains(i)) continue;
        const next_state = single_out[i_usize];
        const node_edges = outgoing.row(i_usize);
        const siblings = incoming.row(@intCast(next_state));
        var group_begin: usize = 0;
        while (group_begin < siblings.len) {
            const sibling = siblings[group_begin].peer;
            while (group_begin < siblings.len and siblings[group_begin].peer == sibling) group_begin += 1;
            if (sibling <= i or
                union_find.contains(sibling) or
                out_distinct[@intCast(sibling)] != 1 or
                result.isEndState(i) != result.isEndState(sibling))
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
                union_find.unite(i, sibling);
                equiv_precursor = true;
            }
        }
    }

    if (no_succ_end.items.len > 1) {
        for (no_succ_end.items[1..]) |state| {
            _ = try union_find.add(no_succ_end.items[0]);
            _ = try union_find.add(state);
            union_find.unite(no_succ_end.items[0], state);
            equiv_precursor = true;
        }
    }
    if (no_succ_non_end.items.len > 1) {
        for (no_succ_non_end.items[1..]) |state| {
            _ = try union_find.add(no_succ_non_end.items[0]);
            _ = try union_find.add(state);
            union_find.unite(no_succ_non_end.items[0], state);
            equiv_precursor = true;
        }
    }

    const changed = equiv_successor or equiv_precursor;
    if (changed) {
        var eq_classes = try union_find.getAllSets(allocator);
        defer {
            for (eq_classes.items) |*set| set.deinit(allocator);
            eq_classes.deinit(allocator);
        }
        const old_to_new = try allocator.alloc(i32, @intCast(result.numStates()));
        defer allocator.free(old_to_new);
        @memset(old_to_new, -1);
        for (eq_classes.items, 0..) |class, i| {
            for (class.items) |state| old_to_new[@intCast(state)] = @intCast(i);
        }
        var cnt: i32 = @intCast(eq_classes.items.len);
        for (0..@intCast(result.numStates())) |i| {
            if (old_to_new[i] == -1) {
                old_to_new[i] = cnt;
                cnt += 1;
            }
        }
        const merged = try result.rebuildWithMapping(allocator, old_to_new, cnt);
        result.deinit();
        result.* = merged;
        result.fsmMut().sortEdges();
    }
    return changed;
}

test "fsm_automata basic operations and end state binary search" {
    const a = std.testing.allocator;
    var f = try Fsm.init(a, 15);
    try f.addEdge(0, 1, 'a', 'a');
    var ends: std.ArrayList(i32) = .empty;
    for (1..15) |i| try ends.append(a, @intCast(i));
    var wse = FsmWithStartEnd.init(a, f, 0, ends, false);
    defer wse.deinit();
    try std.testing.expect(!wse.isEndState(0));
    try std.testing.expect(wse.isEndState(1));
    try std.testing.expect(wse.isEndState(14));
    try std.testing.expect(!wse.isEndState(99));
    try std.testing.expect(try wse.acceptString("a"));
    try std.testing.expect(!try wse.acceptString("b"));
}
