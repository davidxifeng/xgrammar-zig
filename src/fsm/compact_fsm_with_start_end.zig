//! A `CompactFsm` paired with a start state and accepting-state set.

const std = @import("std");
const Allocator = std.mem.Allocator;

const compact_fsm_mod = @import("compact_fsm.zig");
const CompactFsm = compact_fsm_mod.CompactFsm;
const fsm_mod = @import("fsm.zig");
const StateSet = fsm_mod.StateSet;
const state_set_from = fsm_mod.state_set_from;

/// A compact finite-state machine with a designated start state and accepting-state set (a
/// sorted, deduplicated list of state ids).
pub const CompactFsmWithStartEnd = struct {
    fsm: CompactFsm,
    start: i32,
    ends: std.ArrayList(i32),
    is_dfa: bool,
    edge_num: usize,

    /// Creates a compact FSM-with-start/end from its parts. `ends` need not be sorted or
    /// deduplicated (the list is consumed).
    pub fn new(allocator: Allocator, fsm: CompactFsm, start: i32, ends_in: std.ArrayList(i32), is_dfa: bool) Allocator.Error!CompactFsmWithStartEnd {
        _ = allocator;
        var ends = ends_in;
        std.mem.sortUnstable(i32, ends.items, {}, std.sort.asc(i32));
        var write: usize = 0;
        for (ends.items, 0..) |v, read| {
            if (read == 0 or v != ends.items[read - 1]) {
                ends.items[write] = v;
                write += 1;
            }
        }
        ends.items.len = write;
        return .{ .fsm = fsm, .start = start, .ends = ends, .is_dfa = is_dfa, .edge_num = fsm.num_edges() };
    }

    /// Shares the underlying storage and copies the end list.
    pub fn clone(self: *const CompactFsmWithStartEnd, allocator: Allocator) Allocator.Error!CompactFsmWithStartEnd {
        var ends: std.ArrayList(i32) = .empty;
        try ends.appendSlice(allocator, self.ends.items);
        return .{ .fsm = self.fsm.clone(), .start = self.start, .ends = ends, .is_dfa = self.is_dfa, .edge_num = self.edge_num };
    }

    /// Frees one reference of the shared storage and the end list.
    pub fn deinit(self: *CompactFsmWithStartEnd) void {
        const allocator = self.fsm.shared.allocator;
        self.fsm.deinit();
        self.ends.deinit(allocator);
    }

    /// The underlying compact FSM.
    pub fn get_fsm(self: *const CompactFsmWithStartEnd) CompactFsm {
        return self.fsm;
    }

    /// The start state.
    pub fn get_start(self: *const CompactFsmWithStartEnd) i32 {
        return self.start;
    }

    /// The accepting states, as a sorted, deduplicated list of state ids.
    pub fn get_ends(self: *const CompactFsmWithStartEnd) []const i32 {
        return self.ends.items;
    }

    /// Whether this machine is known to be a DFA.
    pub fn get_is_dfa(self: *const CompactFsmWithStartEnd) bool {
        return self.is_dfa;
    }

    /// Edge count captured when this view was built (matches C++ `edge_num_`).
    pub fn get_edge_num(self: *const CompactFsmWithStartEnd) usize {
        return self.edge_num;
    }

    /// The number of states.
    pub fn num_states(self: *const CompactFsmWithStartEnd) i32 {
        return self.fsm.num_states();
    }

    /// Whether `state` is an accepting state (binary search over the sorted ends).
    pub fn is_end_state(self: *const CompactFsmWithStartEnd, state: i32) bool {
        return std.mem.indexOfScalar(i32, self.ends.items, state) != null;
    }

    /// Whether `state` has an outgoing character/token edge (can consume input).
    pub fn is_scanable_state(self: *const CompactFsmWithStartEnd, state: i32) bool {
        for (self.fsm.state_edges(state)) |e| {
            if (e.is_char_range() or e.is_token() or e.is_exclude_token()) return true;
        }
        return false;
    }

    /// Whether `state` has an outgoing rule/epsilon/repeat edge (is non-terminal).
    pub fn is_non_terminal_state(self: *const CompactFsmWithStartEnd, state: i32) bool {
        for (self.fsm.state_edges(state)) |e| {
            if (e.is_rule_ref() or e.is_epsilon() or e.is_repeat_ref()) return true;
        }
        return false;
    }

    /// All states reachable from the start state (caller owns the set).
    pub fn reachable_states(self: *const CompactFsmWithStartEnd) Allocator.Error!StateSet {
        return self.fsm.reachable_states(self.fsm.shared.allocator, &.{self.start});
    }

    /// Whether the FSM accepts `input` (treating it as a byte sequence).
    pub fn accept_string(self: *const CompactFsmWithStartEnd, input: []const u8) Allocator.Error!bool {
        const a = self.fsm.shared.allocator;
        var states = try state_set_from(a, &.{self.start});
        defer states.deinit();
        try self.fsm.epsilon_closure(&states);
        var result = StateSet.init(a);
        defer result.deinit();
        for (input) |byte| {
            try self.fsm.advance_char(&states, @intCast(byte), &result);
            if (result.count() == 0) return false;
            std.mem.swap(StateSet, &states, &result);
        }
        var it = states.keyIterator();
        while (it.next()) |s| {
            if (self.is_end_state(s.*)) return true;
        }
        return false;
    }
};
