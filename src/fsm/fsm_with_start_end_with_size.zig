//! Per-rule FSM slice metadata after merging into a shared complete FSM.
//!
//! When each rule's FSM is folded into one shared `complete_fsm`, what the compiler needs to
//! keep per rule is its start state, accepting-state set (indexed into the complete FSM), and
//! its original edge/node counts. (The C++ also kept a redundant copy of the growing complete
//! FSM; that copy is never read, so it is omitted here.)

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The start state, accepting set, and pre-merge sizes of a rule's FSM within a shared FSM.
pub const FsmWithStartEndWithSize = struct {
    /// Backs `ends` (freed by `deinit`).
    allocator: Allocator,
    start: i32,
    ends: std.ArrayList(i32),
    edge_num: i32,
    node_num: i32,

    /// Creates the metadata from its parts (`ends` is consumed).
    pub fn new(
        allocator: Allocator,
        start: i32,
        ends: std.ArrayList(i32),
        edge_num: i32,
        node_num: i32,
    ) Allocator.Error!FsmWithStartEndWithSize {
        return .{ .allocator = allocator, .start = start, .ends = ends, .edge_num = edge_num, .node_num = node_num };
    }

    /// Frees the storage owned by this metadata.
    pub fn deinit(self: *FsmWithStartEndWithSize) void {
        self.ends.deinit(self.allocator);
    }

    /// The rule's start state (within the complete FSM).
    pub fn get_start(self: *const FsmWithStartEndWithSize) i32 {
        return self.start;
    }

    /// The rule's accepting states (sorted state ids within the complete FSM).
    pub fn get_ends(self: *const FsmWithStartEndWithSize) []const i32 {
        return self.ends.items;
    }

    /// The number of edges in the rule's FSM before merging.
    pub fn get_edge_num(self: *const FsmWithStartEndWithSize) i32 {
        return self.edge_num;
    }

    /// The number of states in the rule's FSM before merging.
    pub fn get_node_num(self: *const FsmWithStartEndWithSize) i32 {
        return self.node_num;
    }
};
