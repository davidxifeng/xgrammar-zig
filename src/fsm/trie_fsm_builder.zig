//! Builds a trie / Aho-Corasick FSM from a set of byte patterns.
//!
//! Without back edges this is a plain prefix trie; with `add_back_edges` it is completed into
//! an Aho-Corasick automaton whose every non-end state has a transition for all 256 byte values
//! (a failing match resumes from the longest proper suffix that is still a trie path).

const std = @import("std");
const Allocator = std.mem.Allocator;

const fsm_mod = @import("fsm.zig");
const Fsm = fsm_mod.Fsm;
const EdgeKind = fsm_mod.EdgeKind;
const NO_NEXT_STATE = fsm_mod.NO_NEXT_STATE;
const StateSet = fsm_mod.StateSet;
const fsm_edge_mod = @import("fsm_edge.zig");
const FsmEdge = fsm_edge_mod.FsmEdge;
const fsm_with_start_end = @import("fsm_with_start_end.zig");
const FsmWithStartEnd = fsm_with_start_end.FsmWithStartEnd;

/// Options and entry point for trie construction.
pub const TrieFsmBuilder = struct {
    /// Builds a trie FSM from `patterns`. The caller owns the result.
    ///
    /// - `excluded_patterns`: patterns whose terminal states are pruned (only meaningful with
    ///   `add_back_edges`).
    /// - `end_states`: if non-null, receives each pattern's terminal state id in input order.
    /// - `allow_overlap`: when `false`, returns null if any pattern is empty or is a prefix
    ///   of (or extends) another.
    /// - `add_back_edges`: completes the trie into an Aho-Corasick automaton.
    ///
    /// Returns null if construction fails the overlap constraint.
    pub fn build(
        allocator: Allocator,
        patterns: []const []const u8,
        excluded_patterns: []const []const u8,
        end_states: ?*std.ArrayList(i32),
        allow_overlap: bool,
        add_back_edges: bool,
    ) Allocator.Error!?FsmWithStartEnd {
        var fsm = try Fsm.new(allocator, 1);
        errdefer fsm.deinit();
        const start: i32 = 0;
        var ends = StateSet.init(allocator);
        defer ends.deinit();
        var collected_ends: std.ArrayList(i32) = .empty;
        defer collected_ends.deinit(allocator);

        for (patterns) |pattern| {
            const end = try insert_pattern(&fsm, pattern, &ends, allow_overlap) orelse {
                fsm.deinit();
                return null;
            };
            try ends.put(end, {});
            try collected_ends.append(allocator, end);
        }

        var dead_states = StateSet.init(allocator);
        defer dead_states.deinit();
        if (add_back_edges) {
            for (excluded_patterns) |pattern| {
                const end = try insert_pattern(&fsm, pattern, &ends, allow_overlap) orelse {
                    fsm.deinit();
                    return null;
                };
                try ends.put(end, {});
                try dead_states.put(end, {});
            }

            try add_back_edges_impl(&fsm, start, &ends, &dead_states);

            if (dead_states.count() != 0) {
                for (0..@intCast(fsm.num_states())) |state| {
                    const list = fsm.state_edges_mut(@intCast(state));
                    var write: usize = 0;
                    for (list.items) |e| {
                        if (!dead_states.contains(e.target)) {
                            list.items[write] = e;
                            write += 1;
                        }
                    }
                    list.items.len = write;
                }
            }
        } else if (excluded_patterns.len != 0) {
            std.debug.print("Excluded patterns are ignored when back edges are not added.\n", .{});
        }

        if (end_states) |out| {
            out.clearRetainingCapacity();
            try out.appendSlice(allocator, collected_ends.items);
        }

        var ends_list: std.ArrayList(i32) = .empty;
        errdefer ends_list.deinit(allocator);
        var it = ends.keyIterator();
        while (it.next()) |k| try ends_list.append(allocator, k.*);
        return try FsmWithStartEnd.new(allocator, fsm, start, ends_list, false);
    }

    /// Walks/extends the trie along `pattern`'s bytes, returning its terminal state, or null
    /// if the overlap constraint is violated.
    fn insert_pattern(fsm: *Fsm, pattern: []const u8, ends: *const StateSet, allow_overlap: bool) Allocator.Error!?i32 {
        if (!allow_overlap and pattern.len == 0) return null;
        var current: i32 = 0;
        for (pattern) |byte| {
            const ch: i32 = byte;
            var next = fsm.next_state(current, ch, .CharRange);
            if (next == NO_NEXT_STATE) {
                next = try fsm.add_state();
                try fsm.add_edge(current, next, ch, ch);
            }
            current = next;
            if (!allow_overlap and ends.contains(current)) return null;
        }
        if (!allow_overlap and fsm.state_edges(current).len != 0) return null;
        return current;
    }

    /// Completes the trie into an Aho-Corasick automaton (the C++ `AddBackEdges`).
    ///
    /// When matching fails at state `u` on byte `b`, the matcher must resume from the longest
    /// proper suffix of `u`'s prefix that is still a trie path (the failure state) and retry `b`
    /// there. Falling back only to the start state loses matches that begin inside an
    /// already-followed branch: with patterns `{"bcd", "abce"}` on input `"abcd"`, after `"abc"`
    /// the byte 'd' must reach the `"bcd"` end through the failure state `"bc"`.
    ///
    /// States whose failure state is dead (an excluded suffix completed at an explicit trie
    /// node) are added to `dead_states`.
    fn add_back_edges_impl(fsm: *Fsm, start: i32, ends: *const StateSet, dead_states: *StateSet) Allocator.Error!void {
        const num_states: usize = @intCast(fsm.num_states());

        // Step 1. The BFS order of the trie (a tree here), so shallower states come first.
        var bfs_order: std.ArrayList(i32) = .empty;
        defer bfs_order.deinit(fsm.allocator);
        try bfs_order.append(fsm.allocator, start);
        var head: usize = 0;
        while (head < bfs_order.items.len) : (head += 1) {
            const state = bfs_order.items[head];
            for (fsm.state_edges(state)) |e| {
                try bfs_order.append(fsm.allocator, e.target);
            }
        }
        std.debug.assert(bfs_order.items.len == num_states);

        // Step 2. The failure links and the fully resolved transition table: `delta[u][b]` is the
        // trie child when it exists and `delta[fail[u]][b]` otherwise. `fail[u]` is strictly
        // shallower than `u`, so its row is already final when `u` is processed in BFS order.
        const fail = try fsm.allocator.alloc(i32, num_states);
        defer fsm.allocator.free(fail);
        @memset(fail, start);
        const delta = try fsm.allocator.alloc([256]i32, num_states);
        defer fsm.allocator.free(delta);
        for (delta, 0..) |*row, u| {
            @memset(row, NO_NEXT_STATE);
            for (fsm.state_edges(@intCast(u))) |e| {
                row[@intCast(e.min)] = e.target;
            }
        }
        for (bfs_order.items) |u| {
            // A trie child can complete an excluded suffix without entering its terminal state:
            // with excludes {"abc", "xabcq"}, the state for "xabc" has failure state "abc".
            if (dead_states.contains(fail[@intCast(u)])) {
                try dead_states.put(u, {});
            }
            const fail_row: ?[]const i32 = if (u != start) &delta[@intCast(fail[@intCast(u)])] else null;
            const delta_row = &delta[@intCast(u)];
            for (delta_row, 0..) |*entry, byte| {
                // Rows of deeper states are untouched so far, so a set entry is a trie child.
                const fallback: i32 = if (fail_row) |row| row[byte] else start;
                if (entry.* == NO_NEXT_STATE) {
                    entry.* = fallback;
                } else {
                    fail[@intCast(entry.*)] = fallback;
                }
            }
        }

        // Step 3. Replace the edges of every non-end state with its resolved row, compressing
        // runs of bytes with the same target into range edges.
        for (delta, 0..) |row, u| {
            if (@as(i32, @intCast(u)) != start and ends.contains(@intCast(u))) continue;
            var new_edges: std.ArrayList(FsmEdge) = .empty;
            defer new_edges.deinit(fsm.allocator);
            var byte: usize = 0;
            while (byte < 256) {
                var range_end = byte;
                while (range_end + 1 < 256 and row[range_end + 1] == row[byte]) range_end += 1;
                try new_edges.append(fsm.allocator, FsmEdge.new(@intCast(byte), @intCast(range_end), row[byte]));
                byte = range_end + 1;
            }
            const list = fsm.state_edges_mut(@intCast(u));
            list.clearRetainingCapacity();
            try list.appendSlice(fsm.allocator, new_edges.items);
        }
    }
};
