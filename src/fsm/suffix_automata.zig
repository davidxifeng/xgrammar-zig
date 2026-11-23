//! Suffix automaton construction for substring expressions.

const std = @import("std");
const Allocator = std.mem.Allocator;

const fsm_mod = @import("fsm.zig");
const Fsm = fsm_mod.Fsm;
const fsm_with_start_end = @import("fsm_with_start_end.zig");
const FsmWithStartEnd = fsm_with_start_end.FsmWithStartEnd;

/// One chunk-labeled transition of a suffix-automaton state.
const Transition = struct { chunk: []const u8, target: i32 };

/// Builds the automaton of a substring expression via a chunk-level suffix automaton.
pub const SuffixAutomata = struct {
    /// Builds an FSM that accepts exactly the contiguous subsequences of `chunks`, including the
    /// empty one. The caller owns the result.
    ///
    /// A suffix automaton is built over the chunk sequence (each chunk is one symbol), so the
    /// number of automaton states grows linearly with the number of chunks, and every automaton
    /// state is accepting. Each chunk-labeled transition is then expanded into a chain of byte
    /// transitions; an empty chunk becomes an epsilon transition. Chunks may be empty or
    /// repeated.
    pub fn build(allocator: Allocator, chunks: []const []const u8) Allocator.Error!FsmWithStartEnd {
        // Step 1. The standard online construction over the chunk sequence. State `i` has the
        // longest-string length `lengths[i]`, the suffix link `links[i]`, and the chunk-labeled
        // `transitions[i]`.
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
            while (parent != -1 and !transitions_has_chunk(&transitions.items[@intCast(parent)], chunk)) {
                try transitions.items[@intCast(parent)].append(allocator, .{ .chunk = chunk, .target = @intCast(current) });
                parent = links.items[@intCast(parent)];
            }
            if (parent == -1) {
                links.items[current] = 0;
            } else {
                const target = transitions_get(&transitions.items[@intCast(parent)], chunk).?;
                if (lengths.items[@intCast(parent)] + 1 == lengths.items[@intCast(target)]) {
                    links.items[current] = target;
                } else {
                    const clone: i32 = @intCast(lengths.items.len);
                    try lengths.append(allocator, lengths.items[@intCast(parent)] + 1);
                    try links.append(allocator, links.items[@intCast(target)]);
                    var cloned: std.ArrayList(Transition) = .empty;
                    try cloned.appendSlice(allocator, transitions.items[@intCast(target)].items);
                    try transitions.append(allocator, cloned);
                    while (parent != -1 and transitions_get(&transitions.items[@intCast(parent)], chunk) == target) {
                        transitions.items[@intCast(parent)].items[transitions_index(&transitions.items[@intCast(parent)], chunk).?] = .{ .chunk = chunk, .target = clone };
                        parent = links.items[@intCast(parent)];
                    }
                    links.items[@intCast(target)] = clone;
                    links.items[current] = clone;
                }
            }
            last = current;
        }

        // Step 2. Expand into a byte-level FSM: automaton state `i` is FSM state `i`, and a
        // chunk-labeled transition becomes a chain of byte edges through fresh states. The
        // Rust BTreeMap iterates chunks in lexicographic order; sort to match.
        const num_states = lengths.items.len;
        var fsm = try Fsm.new(allocator, num_states);
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
                    try fsm.add_epsilon_edge(@intCast(index), t.target);
                    continue;
                }
                const last_byte: i32 = t.chunk[t.chunk.len - 1];
                const prefix = t.chunk[0 .. t.chunk.len - 1];
                var current_state: i32 = @intCast(index);
                for (prefix) |byte| {
                    const next_state = try fsm.add_state();
                    try fsm.add_edge(current_state, next_state, byte, byte);
                    current_state = next_state;
                }
                try fsm.add_edge(current_state, t.target, last_byte, last_byte);
            }
        }
        var ends: std.ArrayList(i32) = .empty;
        errdefer ends.deinit(allocator);
        for (0..num_states) |i| try ends.append(allocator, @intCast(i));
        return FsmWithStartEnd.new(allocator, fsm, 0, ends, false);
    }
};

fn transitions_has_chunk(list: *const std.ArrayList(Transition), chunk: []const u8) bool {
    return transitions_index(list, chunk) != null;
}

fn transitions_index(list: *const std.ArrayList(Transition), chunk: []const u8) ?usize {
    for (list.items, 0..) |t, i| {
        if (std.mem.eql(u8, t.chunk, chunk)) return i;
    }
    return null;
}

fn transitions_get(list: *const std.ArrayList(Transition), chunk: []const u8) ?i32 {
    if (transitions_index(list, chunk)) |i| return list.items[i].target;
    return null;
}
