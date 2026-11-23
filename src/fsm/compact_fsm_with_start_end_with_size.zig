//! A `CompactFsmWithStartEnd` bundled with its pre-merge edge/node counts.
//! `CompactFSMWithStartEndWithSize` in `cpp/fsm.h`. This is the per-rule FSM stored on a
//! compiled grammar.

const std = @import("std");
const Allocator = std.mem.Allocator;

const compact_fsm_with_start_end = @import("compact_fsm_with_start_end.zig");
const CompactFsmWithStartEnd = compact_fsm_with_start_end.CompactFsmWithStartEnd;

/// A compact per-rule FSM plus the edge/node counts of the rule's FSM before it was merged
/// into the shared complete FSM.
pub const CompactFsmWithStartEndWithSize = struct {
    fsm: CompactFsmWithStartEnd,
    edge_num: i32,
    node_num: i32,

    /// Creates the wrapper from its parts (takes over one reference of `fsm`).
    pub fn new(fsm: CompactFsmWithStartEnd, edge_num: i32, node_num: i32) CompactFsmWithStartEndWithSize {
        return .{ .fsm = fsm, .edge_num = edge_num, .node_num = node_num };
    }

    /// Shares the underlying storage (one extra reference) and copies the end list.
    pub fn clone(self: *const CompactFsmWithStartEndWithSize, allocator: Allocator) Allocator.Error!CompactFsmWithStartEndWithSize {
        return .{ .fsm = try self.fsm.clone(allocator), .edge_num = self.edge_num, .node_num = self.node_num };
    }

    /// Releases the storage and the end list.
    pub fn deinit(self: *CompactFsmWithStartEndWithSize) void {
        self.fsm.deinit();
    }

    /// The compact FSM with its start/accepting states.
    pub fn get_fsm(self: *const CompactFsmWithStartEndWithSize) *const CompactFsmWithStartEnd {
        return &self.fsm;
    }

    /// The rule's edge count before merging.
    pub fn get_edge_num(self: *const CompactFsmWithStartEndWithSize) i32 {
        return self.edge_num;
    }

    /// The rule's node count before merging.
    pub fn get_node_num(self: *const CompactFsmWithStartEndWithSize) i32 {
        return self.node_num;
    }
};
