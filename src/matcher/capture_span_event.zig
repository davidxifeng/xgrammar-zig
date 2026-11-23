//! A capture event flattened out of the parser history, with its marker resolved to bytes
//! (`capture_span_event.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const parser = @import("../parser/mod.zig");
const CaptureOccurrence = parser.CaptureOccurrence;

/// A capture event positioned by history rows, used while materializing captures.
pub const CaptureSpanEvent = struct {
    rule_id: i32,
    start_row: i32,
    occurrence_start_pos: i32,
    end_row: i32,
    hidden_suffix_bytes: i32,
    hidden_stop_bytes: i32,
    stop_capture_targets: std.ArrayList(CaptureOccurrence),
    marker_present: bool,
    marker_start_byte: i64,

    pub fn deinit(self: *CaptureSpanEvent, allocator: Allocator) void {
        self.stop_capture_targets.deinit(allocator);
    }
};
