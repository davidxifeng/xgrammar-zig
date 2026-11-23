//! Tracks which parser states have already been enqueued this round (`repeat_detector.rs`).
//!
//! Like the C++, small rounds use a linear scan over a vector and switch to a hash set once
//! more than [`TRANSITION_THRESHOLD`] states were inserted.

const std = @import("std");

const parser_state = @import("parser_state.zig");

const ParserState = parser_state.ParserState;

/// The number of states scanned linearly before switching to the hash set.
const TRANSITION_THRESHOLD: usize = 50;

/// A set of visited parser states used to deduplicate the processing queue.
pub const RepeatDetector = struct {
    visited_vector: std.ArrayList(ParserState) = .empty,
    visited_set: std.AutoHashMapUnmanaged(ParserState, void) = .empty,

    /// Creates an empty detector.
    pub fn new() RepeatDetector {
        return .{};
    }

    /// Whether `state` has already been inserted.
    pub fn is_visited(self: *const RepeatDetector, state: ParserState) bool {
        if (self.visited_vector.items.len > TRANSITION_THRESHOLD) {
            return self.visited_set.contains(state);
        }
        // Compare whole states at once: states queued together usually share their leading
        // fields, so a field-by-field comparison branches deep and mispredicts.
        const key = state.serialize_member_array();
        for (self.visited_vector.items) |visited| {
            const fields = visited.serialize_member_array();
            var differences: i32 = 0;
            for (fields, key) |a, b| differences |= a ^ b;
            if (differences == 0) return true;
        }
        return false;
    }

    /// Records `state` as visited.
    pub fn insert(self: *RepeatDetector, gpa: std.mem.Allocator, state: ParserState) std.mem.Allocator.Error!void {
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

    /// Clears all recorded states.
    pub fn clear(self: *RepeatDetector) void {
        if (self.visited_vector.items.len > TRANSITION_THRESHOLD) {
            self.visited_set.clearRetainingCapacity();
        }
        self.visited_vector.clearRetainingCapacity();
    }

    /// Releases both containers.
    pub fn deinit(self: *RepeatDetector, gpa: std.mem.Allocator) void {
        self.visited_vector.deinit(gpa);
        self.visited_set.deinit(gpa);
    }
};

test "repeat detector switches to the hash set" {
    const gpa = std.testing.allocator;
    var detector = RepeatDetector.new();
    defer detector.deinit(gpa);
    for (0..TRANSITION_THRESHOLD + 5) |i| {
        const state = ParserState.new(@intCast(i), 0, 0, 0);
        try detector.insert(gpa, state);
        try std.testing.expect(!detector.is_visited(ParserState.new(@intCast(i + 1000), 0, 0, 0)));
        try std.testing.expect(detector.is_visited(state));
    }
    detector.clear();
    try std.testing.expect(!detector.is_visited(ParserState.new(0, 0, 0, 0)));
}
