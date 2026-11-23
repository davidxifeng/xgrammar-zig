//! One history row of the Earley parser (`parser_row.rs`).

const std = @import("std");

const capture_event = @import("capture_event.zig");
const parser_state = @import("parser_state.zig");

const CaptureEvent = capture_event.CaptureEvent;
const ParserState = parser_state.ParserState;

/// One completable parent pair (Rust tuple `(i32, ParserState)`).
pub const CompletableState = struct {
    referenced_rule_id: i32,
    parent_state: ParserState,
};

/// The parser state recorded at one input position: the scanable states, the completable
/// parent pairs, whether the root rule is completed, and the capture events.
pub const ParserRow = struct {
    /// The scanable states.
    states: std.ArrayList(ParserState) = .empty,
    /// The `(referenced_rule_id, parent_state)` pairs awaiting completion.
    completable_states: std.ArrayList(CompletableState) = .empty,
    /// Whether the root rule is completed.
    completed: bool = false,
    /// The capture events recorded at this position.
    capture_events: std.ArrayList(CaptureEvent) = .empty,

    /// Rust `Clone` (deep over the event list).
    pub fn clone(self: ParserRow, gpa: std.mem.Allocator) std.mem.Allocator.Error!ParserRow {
        var out = ParserRow{
            .states = try self.states.clone(gpa),
            .completable_states = try self.completable_states.clone(gpa),
            .completed = self.completed,
            .capture_events = .empty,
        };
        errdefer out.deinit(gpa);
        try out.capture_events.ensureTotalCapacity(gpa, self.capture_events.items.len);
        for (self.capture_events.items) |event|
            out.capture_events.appendAssumeCapacity(try capture_event.clone(event, gpa));
        return out;
    }

    /// Rust `PartialEq`.
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
            if (!capture_event.eql(x, y)) return false;
        }
        return true;
    }

    /// Releases the row's lists (arena users need not call this).
    pub fn deinit(self: *ParserRow, gpa: std.mem.Allocator) void {
        self.states.deinit(gpa);
        self.completable_states.deinit(gpa);
        for (self.capture_events.items) |*event| capture_event.deinit(event, gpa);
        self.capture_events.deinit(gpa);
    }
};
