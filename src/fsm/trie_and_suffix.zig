//! Trie / Aho-Corasick FSM construction (`TrieFsmBuilder`) and suffix automaton
//! construction for substring expressions (`SuffixAutomata`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const fsm_mod = @import("Fsm.zig");
const Fsm = fsm_mod.Fsm;
const NO_NEXT_STATE = fsm_mod.NO_NEXT_STATE;
const StateSet = fsm_mod.StateSet;
const edge_mod = @import("edge.zig");
const FsmEdge = edge_mod.FsmEdge;
const automata = @import("fsm_automata.zig");
const FsmWithStartEnd = automata.FsmWithStartEnd;

const log = std.log.scoped(.xgrammar);

/// Builds a trie / Aho-Corasick FSM from a set of byte patterns.
///
/// Without back edges this is a plain prefix trie; with `add_back_edges` it is completed into
/// an Aho-Corasick automaton whose every non-end state has a transition for all 256 byte values.
pub const TrieFsmBuilder = struct {
    /// Builds a trie FSM from `patterns`. The caller owns the result.
    /// Returns null if construction fails the `!allow_overlap` constraint.
    pub fn build(
        allocator: Allocator,
        patterns: []const []const u8,
        excluded_patterns: []const []const u8,
        end_states: ?*std.ArrayList(i32),
        allow_overlap: bool,
        add_back_edges: bool,
    ) Allocator.Error!?FsmWithStartEnd {
        var fsm = try Fsm.init(allocator, 1);
        errdefer fsm.deinit();
        const start: i32 = 0;
        var ends = StateSet.init(allocator);
        defer ends.deinit();
        var collected_ends: std.ArrayList(i32) = .empty;
        defer collected_ends.deinit(allocator);

        for (patterns) |pattern| {
            const end = try insertPattern(&fsm, pattern, &ends, allow_overlap) orelse {
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
                const end = try insertPattern(&fsm, pattern, &ends, allow_overlap) orelse {
                    fsm.deinit();
                    return null;
                };
                try ends.put(end, {});
                try dead_states.put(end, {});
            }

            try addBackEdgesImpl(&fsm, start, &ends, &dead_states);

            if (dead_states.count() != 0) {
                for (0..@intCast(fsm.numStates())) |state| {
                    const list = fsm.stateEdgesMut(@intCast(state));
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
            log.warn("Excluded patterns are ignored when back edges are not added.", .{});
        }

        if (end_states) |out| {
            out.clearRetainingCapacity();
            try out.appendSlice(allocator, collected_ends.items);
        }

        var ends_list: std.ArrayList(i32) = .empty;
        errdefer ends_list.deinit(allocator);
        var it = ends.keyIterator();
        while (it.next()) |k| try ends_list.append(allocator, k.*);
        return FsmWithStartEnd.init(allocator, fsm, start, ends_list, false);
    }

    fn insertPattern(fsm: *Fsm, pattern: []const u8, ends: *const StateSet, allow_overlap: bool) Allocator.Error!?i32 {
        if (!allow_overlap and pattern.len == 0) return null;
        var current: i32 = 0;
        for (pattern) |byte| {
            const ch: i32 = byte;
            var next = fsm.nextState(current, ch, .CharRange);
            if (next == NO_NEXT_STATE) {
                next = try fsm.addState();
                try fsm.addEdge(current, next, ch, ch);
            }
            current = next;
            if (!allow_overlap and ends.contains(current)) return null;
        }
        if (!allow_overlap and fsm.stateEdges(current).len != 0) return null;
        return current;
    }

    fn addBackEdgesImpl(fsm: *Fsm, start: i32, ends: *const StateSet, dead_states: *StateSet) Allocator.Error!void {
        const num_states: usize = @intCast(fsm.numStates());

        // Step 1. BFS order of the trie so shallower states come first.
        var bfs_order: std.ArrayList(i32) = .empty;
        defer bfs_order.deinit(fsm.allocator);
        try bfs_order.append(fsm.allocator, start);
        var head: usize = 0;
        while (head < bfs_order.items.len) : (head += 1) {
            const state = bfs_order.items[head];
            for (fsm.stateEdges(state)) |e| {
                try bfs_order.append(fsm.allocator, e.target);
            }
        }
        std.debug.assert(bfs_order.items.len == num_states);

        // Step 2. Failure links and fully resolved transition table.
        const fail = try fsm.allocator.alloc(i32, num_states);
        defer fsm.allocator.free(fail);
        @memset(fail, start);
        const delta = try fsm.allocator.alloc([256]i32, num_states);
        defer fsm.allocator.free(delta);
        for (delta, 0..) |*row, u| {
            @memset(row, NO_NEXT_STATE);
            for (fsm.stateEdges(@intCast(u))) |e| {
                row[@intCast(e.min)] = e.target;
            }
        }
        for (bfs_order.items) |u| {
            if (dead_states.contains(fail[@intCast(u)])) {
                try dead_states.put(u, {});
            }
            const fail_row: ?[]const i32 = if (u != start) &delta[@intCast(fail[@intCast(u)])] else null;
            const delta_row = &delta[@intCast(u)];
            for (delta_row, 0..) |*entry, byte| {
                const fallback: i32 = if (fail_row) |row| row[byte] else start;
                if (entry.* == NO_NEXT_STATE) {
                    entry.* = fallback;
                } else {
                    fail[@intCast(entry.*)] = fallback;
                }
            }
        }

        // Step 3. Replace edges of every non-end state with its resolved row, run-length compressed.
        for (delta, 0..) |row, u| {
            if (@as(i32, @intCast(u)) != start and ends.contains(@intCast(u))) continue;
            var new_edges: std.ArrayList(FsmEdge) = .empty;
            defer new_edges.deinit(fsm.allocator);
            var byte: usize = 0;
            while (byte < 256) {
                var range_end = byte;
                while (range_end + 1 < 256 and row[range_end + 1] == row[byte]) range_end += 1;
                try new_edges.append(fsm.allocator, FsmEdge.init(@intCast(byte), @intCast(range_end), row[byte]));
                byte = range_end + 1;
            }
            const list = fsm.stateEdgesMut(@intCast(u));
            list.clearRetainingCapacity();
            try list.appendSlice(fsm.allocator, new_edges.items);
        }
    }
};

const Transition = struct { chunk: []const u8, target: i32 };

/// Builds the automaton of a substring expression via a chunk-level suffix automaton.
pub const SuffixAutomata = struct {
    /// Builds an FSM accepting all contiguous subsequences of `chunks` (including empty).
    pub fn build(allocator: Allocator, chunks: []const []const u8) Allocator.Error!FsmWithStartEnd {
        var lengths: std.ArrayList(i32) = .empty;
        defer lengths.deinit(allocator);
        var links: std.ArrayList(i32) = .empty;
        defer links.deinit(allocator);
        var transitions: std.ArrayList(std.ArrayList(Transition)) = .empty;
        defer {
            for (transitions.items) |*t| t.deinit(allocator);
            transitions.deinit(allocator);
        }
        try lengths.append(allocator, 0);
        try links.append(allocator, -1);
        try transitions.append(allocator, .empty);
        var last: usize = 0;
        for (chunks) |chunk| {
            const current = lengths.items.len;
            try lengths.append(allocator, lengths.items[last] + 1);
            try links.append(allocator, -1);
            try transitions.append(allocator, .empty);

            var parent: i32 = @intCast(last);
            while (parent != -1 and !transitionsHasChunk(&transitions.items[@intCast(parent)], chunk)) {
                try transitions.items[@intCast(parent)].append(allocator, .{ .chunk = chunk, .target = @intCast(current) });
                parent = links.items[@intCast(parent)];
            }
            if (parent == -1) {
                links.items[current] = 0;
            } else {
                const target = transitionsGet(&transitions.items[@intCast(parent)], chunk).?;
                if (lengths.items[@intCast(parent)] + 1 == lengths.items[@intCast(target)]) {
                    links.items[current] = target;
                } else {
                    const clone: i32 = @intCast(lengths.items.len);
                    try lengths.append(allocator, lengths.items[@intCast(parent)] + 1);
                    try links.append(allocator, links.items[@intCast(target)]);
                    var cloned: std.ArrayList(Transition) = .empty;
                    errdefer cloned.deinit(allocator);
                    try cloned.appendSlice(allocator, transitions.items[@intCast(target)].items);
                    try transitions.append(allocator, cloned);
                    while (parent != -1 and transitionsGet(&transitions.items[@intCast(parent)], chunk) == target) {
                        transitions.items[@intCast(parent)].items[transitionsIndex(&transitions.items[@intCast(parent)], chunk).?] = .{ .chunk = chunk, .target = clone };
                        parent = links.items[@intCast(parent)];
                    }
                    links.items[@intCast(target)] = clone;
                    links.items[current] = clone;
                }
            }
            last = current;
        }

        const num_states = lengths.items.len;
        var fsm = try Fsm.init(allocator, num_states);
        errdefer fsm.deinit();
        var sorted: std.ArrayList(Transition) = .empty;
        defer sorted.deinit(allocator);
        for (transitions.items, 0..) |state_transitions, index| {
            sorted.clearRetainingCapacity();
            try sorted.appendSlice(allocator, state_transitions.items);
            std.mem.sortUnstable(Transition, sorted.items, {}, struct {
                fn less(_: void, a: Transition, b: Transition) bool {
                    return std.mem.order(u8, a.chunk, b.chunk) == .lt;
                }
            }.less);
            for (sorted.items) |t| {
                if (t.chunk.len == 0) {
                    try fsm.addEpsilonEdge(@intCast(index), t.target);
                    continue;
                }
                const last_byte: i32 = t.chunk[t.chunk.len - 1];
                const prefix = t.chunk[0 .. t.chunk.len - 1];
                var current_state: i32 = @intCast(index);
                for (prefix) |byte| {
                    const next_state = try fsm.addState();
                    try fsm.addEdge(current_state, next_state, byte, byte);
                    current_state = next_state;
                }
                try fsm.addEdge(current_state, t.target, last_byte, last_byte);
            }
        }
        var ends: std.ArrayList(i32) = .empty;
        errdefer ends.deinit(allocator);
        for (0..num_states) |i| try ends.append(allocator, @intCast(i));
        return FsmWithStartEnd.init(allocator, fsm, 0, ends, false);
    }
};

fn transitionsHasChunk(list: *const std.ArrayList(Transition), chunk: []const u8) bool {
    return transitionsIndex(list, chunk) != null;
}

fn transitionsIndex(list: *const std.ArrayList(Transition), chunk: []const u8) ?usize {
    for (list.items, 0..) |t, i| {
        if (std.mem.eql(u8, t.chunk, chunk)) return i;
    }
    return null;
}

fn transitionsGet(list: *const std.ArrayList(Transition), chunk: []const u8) ?i32 {
    if (transitionsIndex(list, chunk)) |i| return list.items[i].target;
    return null;
}

test "TrieFsmBuilder and SuffixAutomata" {
    const a = std.testing.allocator;

    // Overlap detection.
    try std.testing.expect((try TrieFsmBuilder.build(a, &.{ "ab", "abc" }, &.{}, null, false, false)) == null);

    var end_states: std.ArrayList(i32) = .empty;
    defer end_states.deinit(a);
    var trie = (try TrieFsmBuilder.build(a, &.{ "he", "she" }, &.{}, &end_states, true, true)).?;
    defer trie.deinit();
    try std.testing.expectEqual(@as(usize, 2), end_states.items.len);
    try std.testing.expect(trie.isEndState(end_states.items[0]));

    // SuffixAutomata accepts contiguous chunk subsequences and empty string.
    var sa = try SuffixAutomata.build(a, &.{ "ab", "", "cd" });
    defer sa.deinit();
    try std.testing.expect(try sa.acceptString(""));
    try std.testing.expect(try sa.acceptString("ab"));
    try std.testing.expect(try sa.acceptString("cd"));
    try std.testing.expect(try sa.acceptString("abcd"));
    try std.testing.expect(!try sa.acceptString("ac"));
}
