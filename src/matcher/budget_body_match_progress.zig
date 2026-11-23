//! Incremental body-FSM progress of a budgeted suffix/stop rule occurrence
//! (`budget_body_match_progress.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const fsm = @import("../fsm/mod.zig");
pub const StateSet = fsm.fsm.StateSet;

/// The body FSM states reached after consuming `[begin_byte, end_byte)` of the accepted input.
pub const BudgetBodyMatchProgress = struct {
    begin_byte: i64,
    end_byte: i64,
    states: StateSet,
    temporary_input_snapshot: std.ArrayList(u8),

    pub fn deinit(self: *BudgetBodyMatchProgress, allocator: Allocator) void {
        self.states.deinit();
        self.temporary_input_snapshot.deinit(allocator);
    }

    pub fn clone(self: *const BudgetBodyMatchProgress, allocator: Allocator) Allocator.Error!BudgetBodyMatchProgress {
        var states_copy = try fsm.fsm.clone_set(allocator, &self.states);
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
