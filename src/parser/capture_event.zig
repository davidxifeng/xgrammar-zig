//! A completion event of a captured rule (`capture_event.rs`).

const std = @import("std");

const capture_occurrence = @import("capture_occurrence.zig");

const CaptureOccurrence = capture_occurrence.CaptureOccurrence;

/// Recorded when a captured (or capture-hiding) rule is completed during parsing. The matched
/// span is `[start_pos, r)` in input positions, where `r` is the history row at which the event
/// is recorded.
pub const CaptureEvent = struct {
    /// The id of the completed rule.
    rule_id: i32,
    /// The position where the rule started matching. `NO_PREV_INPUT_POS` means position 0 (the
    /// rule acts as the root).
    start_pos: i32,
    /// The unadjusted start position of this rule occurrence. Differs from `start_pos` for the
    /// zero-width event inserted after a dynamic-dispatch marker.
    occurrence_start_pos: i32,
    /// Number of trailing bytes hidden only from this rule's own capture.
    hidden_suffix_bytes: i32,
    /// Number of trailing bytes hidden from every containing capture.
    hidden_stop_bytes: i32,
    /// The captured rule occurrences whose concrete Earley parent chains contain this stop
    /// completion. Includes this rule's occurrence when the rule itself is captured.
    stop_capture_targets: std.ArrayList(CaptureOccurrence) = .empty,
};

/// Deep clone into the caller's allocator (Rust `Clone`; the list is copied).
pub fn clone(self: CaptureEvent, gpa: std.mem.Allocator) std.mem.Allocator.Error!CaptureEvent {
    return .{
        .rule_id = self.rule_id,
        .start_pos = self.start_pos,
        .occurrence_start_pos = self.occurrence_start_pos,
        .hidden_suffix_bytes = self.hidden_suffix_bytes,
        .hidden_stop_bytes = self.hidden_stop_bytes,
        .stop_capture_targets = try self.stop_capture_targets.clone(gpa),
    };
}

/// Rust `PartialEq`.
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

/// Releases the target list (callers using an arena need not call this).
pub fn deinit(self: *CaptureEvent, gpa: std.mem.Allocator) void {
    self.stop_capture_targets.deinit(gpa);
}
