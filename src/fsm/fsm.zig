//! A mutable finite-state machine stored as an adjacency list.
//!
//! States are integer ids; each state owns a list of `FsmEdge`. Aux-bearing edges (repeat,
//! token, exclude-token) index into the shared `edge_aux_data` buffer.

const std = @import("std");
const Allocator = std.mem.Allocator;

const fsm_edge = @import("fsm_edge.zig");
pub const FsmEdge = fsm_edge.FsmEdge;
pub const edge_type = fsm_edge.edge_type;
pub const RepeatEdgeRef = fsm_edge.RepeatEdgeRef;
pub const TokenEdgeRef = fsm_edge.TokenEdgeRef;
pub const ExcludeTokenEdgeRef = fsm_edge.ExcludeTokenEdgeRef;
const sortEdges = fsm_edge.sortEdges;

const support = @import("support/mod.zig");
const encoding = support.encoding;

/// Sentinel returned by `Fsm.next_state` when no transition exists.
pub const NO_NEXT_STATE: i32 = -1;

/// A set of state ids (`HashSet<i32>` in Rust).
pub const StateSet = std.AutoHashMap(i32, void);

/// Whether two state sets hold the same elements.
pub fn state_set_eql(a: StateSet, b: StateSet) bool {
    if (a.count() != b.count()) return false;
    var it = a.keyIterator();
    while (it.next()) |k| {
        if (!b.contains(k.*)) return false;
    }
    return true;
}

/// Creates a set containing `states` (duplicates removed).
pub fn state_set_from(allocator: Allocator, states: []const i32) Allocator.Error!StateSet {
    var set = StateSet.init(allocator);
    for (states) |s| try set.put(s, {});
    return set;
}

/// The kind of transition to follow when advancing (epsilon is handled implicitly via the
/// epsilon closure, so it is not a query kind).
pub const EdgeKind = enum {
    /// Match a character value against `[min, max]` ranges.
    CharRange,
    /// Match a rule-reference edge by rule id.
    RuleRef,
    /// Follow the end-of-string edge.
    Eos,
    /// Follow the single repeat-reference edge.
    RepeatRef,
};

/// A finite-state machine: per-state edge lists plus a shared auxiliary-data buffer.
pub const Fsm = struct {
    /// The allocator backing every list of this FSM (freed by `deinit`).
    allocator: Allocator,
    edges: std.ArrayList(std.ArrayList(FsmEdge)),
    edge_aux_data: std.ArrayList(i32),

    /// Creates an FSM with `num_states` states and no edges.
    pub fn new(allocator: Allocator, state_count: usize) Allocator.Error!Fsm {
        const edges = try allocator.alloc(std.ArrayList(FsmEdge), state_count);
        for (edges) |*e| e.* = .empty;
        return .{
            .allocator = allocator,
            .edges = .fromOwnedSlice(edges),
            .edge_aux_data = .empty,
        };
    }

    /// The empty FSM (`Fsm::default()`).
    pub fn empty(allocator: Allocator) Allocator.Error!Fsm {
        return Fsm.new(allocator, 0);
    }

    /// Creates an FSM from explicit edge lists and aux data (both lists are consumed).
    pub fn from_edges(
        allocator: Allocator,
        edges: []std.ArrayList(FsmEdge),
        edge_aux_data: std.ArrayList(i32),
    ) Allocator.Error!Fsm {
        return .{
            .allocator = allocator,
            .edges = .fromOwnedSlice(edges),
            .edge_aux_data = edge_aux_data,
        };
    }

    /// Frees all storage owned by this FSM.
    pub fn deinit(self: *Fsm) void {
        for (self.edges.items) |*e| e.deinit(self.allocator);
        self.edges.deinit(self.allocator);
        self.edge_aux_data.deinit(self.allocator);
    }

    /// Deep copy into `allocator`.
    pub fn clone(self: *const Fsm, allocator: Allocator) Allocator.Error!Fsm {
        const edges = try allocator.alloc(std.ArrayList(FsmEdge), self.edges.items.len);
        for (self.edges.items, 0..) |e, i| {
            edges[i] = .empty;
            try edges[i].appendSlice(allocator, e.items);
        }
        var aux: std.ArrayList(i32) = .empty;
        try aux.appendSlice(allocator, self.edge_aux_data.items);
        return .{
            .allocator = allocator,
            .edges = .fromOwnedSlice(edges),
            .edge_aux_data = aux,
        };
    }

    /// The number of states.
    pub fn num_states(self: *const Fsm) i32 {
        return @intCast(self.edges.items.len);
    }

    /// All states' edge lists.
    pub fn edges_slice(self: *const Fsm) []const std.ArrayList(FsmEdge) {
        return self.edges.items;
    }

    /// The outgoing edges of `state`.
    pub fn state_edges(self: *const Fsm, state: i32) []const FsmEdge {
        return self.edges.items[@intCast(state)].items;
    }

    /// A mutable reference to the outgoing edge list of `state`.
    pub fn state_edges_mut(self: *Fsm, state: i32) *std.ArrayList(FsmEdge) {
        return &self.edges.items[@intCast(state)];
    }

    /// The shared auxiliary-data buffer.
    pub fn edge_aux_data_slice(self: *const Fsm) []const i32 {
        return self.edge_aux_data.items;
    }

    /// Replaces the shared auxiliary-data buffer (the old buffer is freed; `data` is consumed).
    pub fn set_edge_aux_data(self: *Fsm, data: std.ArrayList(i32)) void {
        self.edge_aux_data.deinit(self.allocator);
        self.edge_aux_data = data;
    }

    /// Renders the given `states` (or all states, if null) as a multi-line edge listing —
    /// a port of `EdgesToString`. Allocated from `self.allocator`.
    pub fn edges_to_string(self: *const Fsm, states: ?[]const i32) Allocator.Error![]u8 {
        const a = self.allocator;
        var result: std.ArrayList(u8) = .empty;
        try result.appendSlice(a, "[\n");
        if (states) |list| {
            for (list) |state| try self.render_state(&result, state);
        } else {
            for (0..@intCast(self.num_states())) |i|
                try self.render_state(&result, @intCast(i));
        }
        try result.appendSlice(a, "]");
        return result.toOwnedSlice(a);
    }

    fn render_state(self: *const Fsm, result: *std.ArrayList(u8), state: i32) Allocator.Error!void {
        const a = self.allocator;
        try result.print(a, "{d}: [", .{state});
        const edges = self.edges.items[@intCast(state)].items;
        for (edges, 0..) |edge, j| {
            if (edge.min >= 0 and edge.min != edge.max) {
                const lo = try encoding.escape_codepoint(a, edge.min, &.{});
                defer a.free(lo);
                const hi = try encoding.escape_codepoint(a, edge.max, &.{});
                defer a.free(hi);
                try result.print(a, "[{s}-{s}]->{d}", .{ lo, hi, edge.target });
            } else if (edge.min >= 0) {
                const c = try encoding.escape_codepoint(a, edge.min, &.{});
                defer a.free(c);
                try result.print(a, "'{s}'->{d}", .{ c, edge.target });
            } else if (edge.is_rule_ref()) {
                try result.print(a, "Rule({d})->{d}", .{ edge.max, edge.target });
            } else if (edge.is_epsilon()) {
                try result.print(a, "Eps->{d}", .{edge.target});
            } else if (edge.is_eos()) {
                try result.print(a, "EOS->{d}", .{edge.target});
            } else if (edge.is_repeat_ref()) {
                const info = self.repeat_edge_info(edge.max);
                try result.print(a, "Repeat(rule={d}, min={d}, max={d})->{d}", .{ info.rule_id(), info.lower(), info.upper(), edge.target });
            } else if (edge.is_token()) {
                const info = self.token_edge_info(edge.max);
                try result.appendSlice(a, "Token(");
                for (info.token_ids(), 0..) |id, k| {
                    if (k > 0) try result.appendSlice(a, ", ");
                    try result.print(a, "{d}", .{id});
                }
                try result.print(a, ")->{d}", .{edge.target});
            } else if (edge.is_exclude_token()) {
                const info = self.exclude_token_edge_info(edge.max);
                try result.appendSlice(a, "ExcludeToken(");
                for (info.token_ids(), 0..) |id, k| {
                    if (k > 0) try result.appendSlice(a, ", ");
                    try result.print(a, "{d}", .{id});
                }
                try result.print(a, ")->{d}", .{edge.target});
            }
            if (j < edges.len - 1) try result.appendSlice(a, ", ");
        }
        try result.appendSlice(a, "]\n");
    }

    /// Adds a new state, returning its id.
    pub fn add_state(self: *Fsm) Allocator.Error!i32 {
        try self.edges.append(self.allocator, .empty);
        return @intCast(self.edges.items.len - 1);
    }

    /// Adds a character-range edge `from -[min,max]-> to`.
    pub fn add_edge(self: *Fsm, from: i32, to: i32, min: i32, max: i32) Allocator.Error!void {
        try self.edges.items[@intCast(from)].append(self.allocator, FsmEdge.new(min, max, to));
    }

    /// Adds an epsilon edge.
    pub fn add_epsilon_edge(self: *Fsm, from: i32, to: i32) Allocator.Error!void {
        try self.edges.items[@intCast(from)].append(self.allocator, FsmEdge.new(edge_type.EPSILON, 0, to));
    }

    /// Adds a rule-reference edge.
    pub fn add_rule_edge(self: *Fsm, from: i32, to: i32, rule_id: i32) Allocator.Error!void {
        try self.edges.items[@intCast(from)].append(self.allocator, FsmEdge.new(edge_type.RULE_REF, rule_id, to));
    }

    /// Adds an end-of-string edge.
    pub fn add_eos_edge(self: *Fsm, from: i32, to: i32) Allocator.Error!void {
        try self.edges.items[@intCast(from)].append(self.allocator, FsmEdge.new(edge_type.EOS, 0, to));
    }

    /// Adds a repeat-reference edge (the source state must have no other outgoing edges).
    ///
    /// Panics (debug builds) if the source state already has edges.
    pub fn add_repeat_edge(self: *Fsm, from: i32, to: i32, rule_id: i32, lower: i32, upper: i32) Allocator.Error!void {
        const list = &self.edges.items[@intCast(from)];
        std.debug.assert(list.items.len == 0); // a state with a repeat-ref edge must have no other outgoing edges
        const aux_index: i32 = @intCast(self.edge_aux_data.items.len);
        try self.edge_aux_data.appendSlice(self.allocator, &.{ rule_id, lower, upper });
        try list.append(self.allocator, FsmEdge.new(edge_type.REPEAT_REF, aux_index, to));
    }

    fn push_token_aux(self: *Fsm, token_ids: []const i32) Allocator.Error!i32 {
        const aux_index: i32 = @intCast(self.edge_aux_data.items.len);
        try self.edge_aux_data.append(self.allocator, @intCast(token_ids.len));
        try self.edge_aux_data.appendSlice(self.allocator, token_ids);
        return aux_index;
    }

    /// Adds a token-set edge.
    ///
    /// Panics (debug builds) if `token_ids` is empty.
    pub fn add_token_edge(self: *Fsm, from: i32, to: i32, token_ids: []const i32) Allocator.Error!void {
        std.debug.assert(token_ids.len != 0); // token set must not be empty
        const aux_index = try self.push_token_aux(token_ids);
        try self.edges.items[@intCast(from)].append(self.allocator, FsmEdge.new(edge_type.TOKEN, aux_index, to));
    }

    /// Adds an exclude-token-set edge.
    ///
    /// Panics (debug builds) if `token_ids` is empty.
    pub fn add_exclude_token_edge(self: *Fsm, from: i32, to: i32, token_ids: []const i32) Allocator.Error!void {
        std.debug.assert(token_ids.len != 0); // token exclude set must not be empty
        const aux_index = try self.push_token_aux(token_ids);
        try self.edges.items[@intCast(from)].append(self.allocator, FsmEdge.new(edge_type.EXCLUDE_TOKEN, aux_index, to));
    }

    /// The repeat-edge aux view at `idx`.
    pub fn repeat_edge_info(self: *const Fsm, idx: i32) RepeatEdgeRef {
        return .{ .data = self.edge_aux_data.items[@intCast(idx)..] };
    }

    /// The token-edge aux view at `idx`.
    pub fn token_edge_info(self: *const Fsm, idx: i32) TokenEdgeRef {
        return .{ .data = self.edge_aux_data.items[@intCast(idx)..] };
    }

    /// The exclude-token-edge aux view at `idx`.
    pub fn exclude_token_edge_info(self: *const Fsm, idx: i32) ExcludeTokenEdgeRef {
        return .{ .data = self.edge_aux_data.items[@intCast(idx)..] };
    }

    /// The first state reachable from `from` on `value` via an edge of `kind`, or
    /// `NO_NEXT_STATE`.
    pub fn next_state(self: *const Fsm, from: i32, value: i32, kind: EdgeKind) i32 {
        const edges = self.edges.items[@intCast(from)].items;
        switch (kind) {
            .CharRange => {
                for (edges) |e| {
                    if (e.is_char_range() and e.min <= value and e.max >= value) return e.target;
                }
                return NO_NEXT_STATE;
            },
            .RuleRef => {
                for (edges) |e| {
                    if (e.is_rule_ref() and e.ref_rule_id() == value) return e.target;
                }
                return NO_NEXT_STATE;
            },
            .Eos => {
                for (edges) |e| {
                    if (e.is_eos()) return e.target;
                }
                return NO_NEXT_STATE;
            },
            .RepeatRef => {
                std.debug.assert(edges.len == 1 and edges[0].is_repeat_ref());
                return edges[0].target;
            },
        }
    }

    /// Expands `state_set` in place with all states reachable via epsilon transitions.
    pub fn epsilon_closure(self: *const Fsm, state_set: *StateSet) Allocator.Error!void {
        var queue: std.ArrayList(i32) = .empty;
        defer queue.deinit(self.allocator);
        var it = state_set.keyIterator();
        while (it.next()) |k| try queue.append(self.allocator, k.*);
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const current = queue.items[head];
            for (self.edges.items[@intCast(current)].items) |e| {
                if (e.is_epsilon()) {
                    const gop = try state_set.getOrPut(e.target);
                    if (!gop.found_existing) try queue.append(self.allocator, e.target);
                }
            }
        }
    }

    /// Advances the (epsilon-closed) set `from` on `value` via edges of `kind`, storing the
    /// epsilon-closed successor set in `result`.
    pub fn advance(
        self: *const Fsm,
        from: *const StateSet,
        value: i32,
        result: *StateSet,
        kind: EdgeKind,
        from_is_closure: bool,
    ) Allocator.Error!void {
        var owned_closure: ?StateSet = null;
        defer if (owned_closure) |*s| s.deinit();
        const start_closure: *StateSet = if (from_is_closure)
            @constCast(from)
        else blk: {
            const closure = try clone_set(self.allocator, from);
            owned_closure = closure;
            try self.epsilon_closure(&owned_closure.?);
            break :blk &owned_closure.?;
        };

        result.clearRetainingCapacity();
        var it = start_closure.keyIterator();
        while (it.next()) |state_key| {
            const state = state_key.*;
            for (self.edges.items[@intCast(state)].items) |e| {
                const matches = switch (kind) {
                    .CharRange => e.is_char_range() and e.min <= value and e.max >= value,
                    .RuleRef => e.is_rule_ref() and e.ref_rule_id() == value,
                    .Eos => e.is_eos(),
                    .RepeatRef => e.is_repeat_ref(),
                };
                if (matches) try result.put(e.target, {});
            }
        }
        try self.epsilon_closure(result);
    }

    /// The set of rule ids referenced by `state`'s outgoing edges.
    pub fn possible_rules(self: *const Fsm, allocator: Allocator, state: i32) Allocator.Error!StateSet {
        var rules = StateSet.init(allocator);
        errdefer rules.deinit();
        for (self.edges.items[@intCast(state)].items) |e| {
            if (e.is_rule_ref()) try rules.put(e.ref_rule_id(), {});
        }
        return rules;
    }

    /// All states reachable from `from` (following every edge as a plain transition).
    /// The caller owns the returned set.
    pub fn reachable_states(self: *const Fsm, allocator: Allocator, from: []const i32) Allocator.Error!StateSet {
        var result = StateSet.init(allocator);
        errdefer result.deinit();
        var queue: std.ArrayList(i32) = .empty;
        defer queue.deinit(allocator);
        for (from) |s| {
            try result.put(s, {});
            try queue.append(allocator, s);
        }
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const current = queue.items[head];
            for (self.edges.items[@intCast(current)].items) |e| {
                const gop = try result.getOrPut(e.target);
                if (!gop.found_existing) try queue.append(allocator, e.target);
            }
        }
        return result;
    }

    /// Appends a copy of `other`'s states and edges, returning the state-id offset (so
    /// `other`'s state `s` becomes `offset + s`). Aux indices are rebased onto this FSM's
    /// `edge_aux_data`.
    pub fn add_fsm(self: *Fsm, other: *const Fsm) Allocator.Error!i32 {
        const old_num_states = self.num_states();
        const aux_offset: i32 = @intCast(self.edge_aux_data.items.len);
        try self.edge_aux_data.appendSlice(self.allocator, other.edge_aux_data.items);
        const old_len = self.edges.items.len;
        try self.edges.resize(self.allocator, old_len + other.edges.items.len);
        for (old_len..self.edges.items.len) |i| self.edges.items[i] = .empty;
        for (other.edges.items, 0..) |_, i| {
            const from = old_num_states + @as(i32, @intCast(i));
            for (state_edges.items) |e| {
                const max: i32 = if (e.is_aux_edge() and aux_offset > 0) e.max + aux_offset else e.max;
                try self.edges.items[@intCast(from)].append(
                    self.allocator,
                    FsmEdge.new(e.min, max, e.target + old_num_states),
                );
            }
        }
        return old_num_states;
    }

    /// Rebuilds the FSM under `state_mapping` (old id → new id), dropping epsilon self-loops
    /// and de-duplicating edges per state. The caller owns the result.
    pub fn rebuild_with_mapping(self: *const Fsm, allocator: Allocator, state_mapping: []const i32, new_num_states: i32) Allocator.Error!Fsm {
        var new_edges = try allocator.alloc(std.ArrayList(FsmEdge), @intCast(new_num_states));
        for (new_edges) |*e| e.* = .empty;
        for (self.edges.items, 0..) |_, i| {
            for (state_edges.items) |e| {
                if (e.is_epsilon() and state_mapping[i] == state_mapping[@intCast(e.target)]) continue;
                try new_edges[@intCast(state_mapping[i])].append(
                    allocator,
                    FsmEdge.new(e.min, e.max, state_mapping[@intCast(e.target)]),
                );
            }
        }
        for (new_edges) |*row| {
            sortEdges(row.items);
            const kept = dedup_edges(row.items);
            row.items.len = kept.len;
        }
        var aux: std.ArrayList(i32) = .empty;
        try aux.appendSlice(allocator, self.edge_aux_data.items);
        return .{
            .allocator = allocator,
            .edges = .fromOwnedSlice(new_edges),
            .edge_aux_data = aux,
        };
    }

    /// Sorts each state's outgoing edges lexicographically.
    pub fn sort_edges(self: *Fsm) void {
        for (self.edges.items) |*row| sortEdges(row.items);
    }
};

/// Removes adjacent duplicate edges (requires a sorted slice).
fn dedup_edges(edges: []FsmEdge) []FsmEdge {
    if (edges.len == 0) return edges;
    var write: usize = 1;
    var read: usize = 1;
    while (read < edges.len) : (read += 1) {
        const a = edges[read];
        const b = edges[write - 1];
        if (a.min != b.min or a.max != b.max or a.target != b.target) {
            edges[write] = a;
            write += 1;
        }
    }
    return edges[0..write];
}

/// A copy of `set`, allocated from `allocator` (caller owns it).
pub fn clone_set(allocator: Allocator, set: *const StateSet) Allocator.Error!StateSet {
    var copy = StateSet.init(allocator);
    errdefer copy.deinit();
    var it = set.keyIterator();
    while (it.next()) |k| try copy.put(k.*, {});
    return copy;
}
