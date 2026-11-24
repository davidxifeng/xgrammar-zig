//! A mutable finite-state machine stored as an adjacency list, plus per-rule slice metadata.
//!
//! States are integer ids; each state owns a list of `FsmEdge`. Aux-bearing edges (repeat,
//! token, exclude-token) index into the shared `edge_aux_data` buffer.

const std = @import("std");
const Allocator = std.mem.Allocator;

const edge_mod = @import("edge.zig");
pub const FsmEdge = edge_mod.FsmEdge;
pub const edge_type = edge_mod.edge_type;
pub const RepeatEdgeRef = edge_mod.RepeatEdgeRef;
pub const TokenEdgeRef = edge_mod.TokenEdgeRef;
pub const ExcludeTokenEdgeRef = edge_mod.ExcludeTokenEdgeRef;

const support = @import("../support.zig");
const encoding = support.encoding;

/// Sentinel returned by `Fsm.nextState` when no transition exists.
pub const NO_NEXT_STATE: i32 = -1;

/// A set of state ids.
pub const StateSet = std.AutoHashMap(i32, void);

/// Whether two state sets hold the same elements.
pub fn stateSetEql(a: StateSet, b: StateSet) bool {
    if (a.count() != b.count()) return false;
    var it = a.keyIterator();
    while (it.next()) |k| {
        if (!b.contains(k.*)) return false;
    }
    return true;
}

/// Creates a set containing `states` (duplicates removed).
pub fn stateSetFrom(allocator: Allocator, states: []const i32) Allocator.Error!StateSet {
    var set = StateSet.init(allocator);
    errdefer set.deinit();
    for (states) |s| try set.put(s, {});
    return set;
}

/// A copy of `set`, allocated from `allocator` (caller owns it).
pub fn cloneSet(allocator: Allocator, set: *const StateSet) Allocator.Error!StateSet {
    var copy = StateSet.init(allocator);
    errdefer copy.deinit();
    var it = set.keyIterator();
    while (it.next()) |k| try copy.put(k.*, {});
    return copy;
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

/// Per-rule FSM slice metadata after merging into a shared complete FSM:
/// start state, accepting-state set (indexed into the complete FSM), and pre-merge sizes.
pub const FsmSliceMeta = struct {
    allocator: Allocator,
    start: i32,
    ends: std.ArrayList(i32),
    edge_num: i32,
    node_num: i32,

    /// Creates the metadata from its parts (`ends` is consumed).
    pub fn init(
        allocator: Allocator,
        start: i32,
        ends: std.ArrayList(i32),
        edge_num: i32,
        node_num: i32,
    ) FsmSliceMeta {
        return .{
            .allocator = allocator,
            .start = start,
            .ends = ends,
            .edge_num = edge_num,
            .node_num = node_num,
        };
    }

    /// Frees the storage owned by this metadata.
    pub fn deinit(self: *FsmSliceMeta) void {
        self.ends.deinit(self.allocator);
    }

    /// The rule's start state (within the complete FSM).
    pub fn startState(self: *const FsmSliceMeta) i32 {
        return self.start;
    }

    /// The rule's accepting states (within the complete FSM).
    pub fn endsSlice(self: *const FsmSliceMeta) []const i32 {
        return self.ends.items;
    }

    /// The number of edges in the rule's FSM before merging.
    pub fn edgeNum(self: *const FsmSliceMeta) i32 {
        return self.edge_num;
    }

    /// The number of states in the rule's FSM before merging.
    pub fn nodeNum(self: *const FsmSliceMeta) i32 {
        return self.node_num;
    }
};

/// A finite-state machine: per-state edge lists plus a shared auxiliary-data buffer.
pub const Fsm = struct {
    /// The allocator backing every list of this FSM (freed by `deinit`).
    allocator: Allocator,
    edges: std.ArrayList(std.ArrayList(FsmEdge)),
    edge_aux_data: std.ArrayList(i32),

    /// Creates an FSM with `state_count` states and no edges.
    pub fn init(allocator: Allocator, state_count: usize) Allocator.Error!Fsm {
        const edges = try allocator.alloc(std.ArrayList(FsmEdge), state_count);
        for (edges) |*e| e.* = .empty;
        return .{
            .allocator = allocator,
            .edges = .fromOwnedSlice(edges),
            .edge_aux_data = .empty,
        };
    }

    /// The empty FSM.
    pub fn empty(allocator: Allocator) Allocator.Error!Fsm {
        return Fsm.init(allocator, 0);
    }

    /// Creates an FSM from explicit edge lists and aux data (both lists are consumed).
    pub fn fromEdges(
        allocator: Allocator,
        edges: []std.ArrayList(FsmEdge),
        edge_aux_data: std.ArrayList(i32),
    ) Fsm {
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
    pub fn dupe(self: *const Fsm, allocator: Allocator) Allocator.Error!Fsm {
        const edges = try allocator.alloc(std.ArrayList(FsmEdge), self.edges.items.len);
        var initialized: usize = 0;
        errdefer {
            for (edges[0..initialized]) |*e| e.deinit(allocator);
            allocator.free(edges);
        }
        for (self.edges.items, 0..) |e, i| {
            edges[i] = .empty;
            initialized += 1;
            try edges[i].appendSlice(allocator, e.items);
        }
        var aux: std.ArrayList(i32) = .empty;
        errdefer aux.deinit(allocator);
        try aux.appendSlice(allocator, self.edge_aux_data.items);
        return .{
            .allocator = allocator,
            .edges = .fromOwnedSlice(edges),
            .edge_aux_data = aux,
        };
    }

    /// Converts this FSM into a packed `CompactFsm` allocated on `allocator`.
    pub fn toCompact(self: *const Fsm, allocator: Allocator) Allocator.Error!@import("CompactFsm.zig").CompactFsm {
        return @import("CompactFsm.zig").CompactFsm.fromFsm(allocator, self);
    }

    /// The number of states.
    pub fn numStates(self: *const Fsm) i32 {
        return @intCast(self.edges.items.len);
    }

    /// All states' edge lists.
    pub fn edgesSlice(self: *const Fsm) []const std.ArrayList(FsmEdge) {
        return self.edges.items;
    }

    /// The outgoing edges of `state`.
    pub fn stateEdges(self: *const Fsm, state: i32) []const FsmEdge {
        return self.edges.items[@intCast(state)].items;
    }

    /// A mutable reference to the outgoing edge list of `state`.
    pub fn stateEdgesMut(self: *Fsm, state: i32) *std.ArrayList(FsmEdge) {
        return &self.edges.items[@intCast(state)];
    }

    /// The shared auxiliary-data buffer.
    pub fn edgeAuxDataSlice(self: *const Fsm) []const i32 {
        return self.edge_aux_data.items;
    }

    /// Replaces the shared auxiliary-data buffer (the old buffer is freed; `data` is consumed).
    pub fn setEdgeAuxData(self: *Fsm, data: std.ArrayList(i32)) void {
        self.edge_aux_data.deinit(self.allocator);
        self.edge_aux_data = data;
    }

    /// Streams the given `states` (or all states, if null) as a multi-line edge listing
    /// directly to `writer` without heap allocation.
    pub fn writeEdges(
        self: *const Fsm,
        writer: *std.Io.Writer,
        states: ?[]const i32,
    ) std.Io.Writer.Error!void {
        try writer.writeAll("[\n");
        if (states) |list| {
            for (list) |state| try self.writeStateEdges(writer, state);
        } else {
            for (0..@intCast(self.numStates())) |i| {
                try self.writeStateEdges(writer, @intCast(i));
            }
        }
        try writer.writeByte(']');
    }

    /// Renders the given `states` (or all states, if null) as a multi-line edge listing.
    /// Caller owns the returned slice allocated from `allocator`.
    pub fn edgesToString(self: *const Fsm, allocator: Allocator, states: ?[]const i32) Allocator.Error![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        self.writeEdges(&aw.writer, states) catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }

    pub fn format(self: Fsm, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return self.writeEdges(writer, null);
    }

    fn writeStateEdges(self: *const Fsm, writer: *std.Io.Writer, state: i32) std.Io.Writer.Error!void {
        try writer.print("{d}: [", .{state});
        const edges = self.edges.items[@intCast(state)].items;
        for (edges, 0..) |edge, j| {
            if (edge.min >= 0 and edge.min != edge.max) {
                try writer.writeByte('[');
                try encoding.writeEscapedCodepoint(writer, edge.min, &.{});
                try writer.writeByte('-');
                try encoding.writeEscapedCodepoint(writer, edge.max, &.{});
                try writer.print("]->{d}", .{edge.target});
            } else if (edge.min >= 0) {
                try writer.writeByte('\'');
                try encoding.writeEscapedCodepoint(writer, edge.min, &.{});
                try writer.print("'->{d}", .{edge.target});
            } else if (edge.isRuleRef()) {
                try writer.print("Rule({d})->{d}", .{ edge.max, edge.target });
            } else if (edge.isEpsilon()) {
                try writer.print("Eps->{d}", .{edge.target});
            } else if (edge.isEos()) {
                try writer.print("EOS->{d}", .{edge.target});
            } else if (edge.isRepeatRef()) {
                const info = self.repeatEdgeInfo(edge.max);
                try writer.print("Repeat(rule={d}, min={d}, max={d})->{d}", .{
                    info.ruleId(), info.lower(), info.upper(), edge.target,
                });
            } else if (edge.isToken()) {
                const info = self.tokenEdgeInfo(edge.max);
                try writer.writeAll("Token(");
                for (info.tokenIds(), 0..) |id, k| {
                    if (k > 0) try writer.writeAll(", ");
                    try writer.print("{d}", .{id});
                }
                try writer.print(")->{d}", .{edge.target});
            } else if (edge.isExcludeToken()) {
                const info = self.excludeTokenEdgeInfo(edge.max);
                try writer.writeAll("ExcludeToken(");
                for (info.tokenIds(), 0..) |id, k| {
                    if (k > 0) try writer.writeAll(", ");
                    try writer.print("{d}", .{id});
                }
                try writer.print(")->{d}", .{edge.target});
            }
            if (j < edges.len - 1) try writer.writeAll(", ");
        }
        try writer.writeAll("]\n");
    }

    /// Adds a new state, returning its id.
    pub fn addState(self: *Fsm) Allocator.Error!i32 {
        try self.edges.append(self.allocator, .empty);
        return @intCast(self.edges.items.len - 1);
    }

    /// Adds a character-range edge `from -[min,max]-> to`.
    pub fn addEdge(self: *Fsm, from: i32, to: i32, min: i32, max: i32) Allocator.Error!void {
        try self.edges.items[@intCast(from)].append(self.allocator, FsmEdge.init(min, max, to));
    }

    /// Adds an epsilon edge.
    pub fn addEpsilonEdge(self: *Fsm, from: i32, to: i32) Allocator.Error!void {
        try self.edges.items[@intCast(from)].append(self.allocator, FsmEdge.init(edge_type.EPSILON, 0, to));
    }

    /// Adds a rule-reference edge.
    pub fn addRuleEdge(self: *Fsm, from: i32, to: i32, rule_id: i32) Allocator.Error!void {
        try self.edges.items[@intCast(from)].append(self.allocator, FsmEdge.init(edge_type.RULE_REF, rule_id, to));
    }

    /// Adds an end-of-string edge.
    pub fn addEosEdge(self: *Fsm, from: i32, to: i32) Allocator.Error!void {
        try self.edges.items[@intCast(from)].append(self.allocator, FsmEdge.init(edge_type.EOS, 0, to));
    }

    /// Adds a repeat-reference edge (the source state must have no other outgoing edges).
    pub fn addRepeatEdge(self: *Fsm, from: i32, to: i32, rule_id: i32, lower: i32, upper: i32) Allocator.Error!void {
        const list = &self.edges.items[@intCast(from)];
        std.debug.assert(list.items.len == 0);
        const aux_index: i32 = @intCast(self.edge_aux_data.items.len);
        try self.edge_aux_data.appendSlice(self.allocator, &.{ rule_id, lower, upper });
        try list.append(self.allocator, FsmEdge.init(edge_type.REPEAT_REF, aux_index, to));
    }

    fn pushTokenAux(self: *Fsm, token_ids: []const i32) Allocator.Error!i32 {
        const aux_index: i32 = @intCast(self.edge_aux_data.items.len);
        try self.edge_aux_data.append(self.allocator, @intCast(token_ids.len));
        try self.edge_aux_data.appendSlice(self.allocator, token_ids);
        return aux_index;
    }

    /// Adds a token-set edge.
    pub fn addTokenEdge(self: *Fsm, from: i32, to: i32, token_ids: []const i32) Allocator.Error!void {
        std.debug.assert(token_ids.len != 0);
        const aux_index = try self.pushTokenAux(token_ids);
        try self.edges.items[@intCast(from)].append(self.allocator, FsmEdge.init(edge_type.TOKEN, aux_index, to));
    }

    /// Adds an exclude-token-set edge.
    pub fn addExcludeTokenEdge(self: *Fsm, from: i32, to: i32, token_ids: []const i32) Allocator.Error!void {
        std.debug.assert(token_ids.len != 0);
        const aux_index = try self.pushTokenAux(token_ids);
        try self.edges.items[@intCast(from)].append(self.allocator, FsmEdge.init(edge_type.EXCLUDE_TOKEN, aux_index, to));
    }

    /// The repeat-edge aux view at `idx`.
    pub fn repeatEdgeInfo(self: *const Fsm, idx: i32) RepeatEdgeRef {
        return .{ .data = self.edge_aux_data.items[@intCast(idx)..] };
    }

    /// The token-edge aux view at `idx`.
    pub fn tokenEdgeInfo(self: *const Fsm, idx: i32) TokenEdgeRef {
        return .{ .data = self.edge_aux_data.items[@intCast(idx)..] };
    }

    /// The exclude-token-edge aux view at `idx`.
    pub fn excludeTokenEdgeInfo(self: *const Fsm, idx: i32) ExcludeTokenEdgeRef {
        return .{ .data = self.edge_aux_data.items[@intCast(idx)..] };
    }

    /// The first state reachable from `from` on `value` via an edge of `kind`, or
    /// `NO_NEXT_STATE`.
    pub fn nextState(self: *const Fsm, from: i32, value: i32, kind: EdgeKind) i32 {
        const edges = self.edges.items[@intCast(from)].items;
        switch (kind) {
            .CharRange => {
                for (edges) |e| {
                    if (e.isCharRange() and e.min <= value and e.max >= value) return e.target;
                }
                return NO_NEXT_STATE;
            },
            .RuleRef => {
                for (edges) |e| {
                    if (e.isRuleRef() and e.refRuleId() == value) return e.target;
                }
                return NO_NEXT_STATE;
            },
            .Eos => {
                for (edges) |e| {
                    if (e.isEos()) return e.target;
                }
                return NO_NEXT_STATE;
            },
            .RepeatRef => {
                std.debug.assert(edges.len == 1 and edges[0].isRepeatRef());
                return edges[0].target;
            },
        }
    }

    /// Expands `state_set` in place with all states reachable via epsilon transitions.
    pub fn epsilonClosure(self: *const Fsm, state_set: *StateSet) Allocator.Error!void {
        const a = state_set.allocator;
        var queue: std.ArrayList(i32) = .empty;
        defer queue.deinit(a);
        var it = state_set.keyIterator();
        while (it.next()) |k| try queue.append(a, k.*);
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const current = queue.items[head];
            for (self.edges.items[@intCast(current)].items) |e| {
                if (e.isEpsilon()) {
                    const gop = try state_set.getOrPut(e.target);
                    if (!gop.found_existing) try queue.append(a, e.target);
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
        const a = result.allocator;
        var owned_closure: ?StateSet = null;
        defer if (owned_closure) |*s| s.deinit();
        const start_closure: *StateSet = if (from_is_closure)
            @constCast(from)
        else blk: {
            owned_closure = try cloneSet(a, from);
            try self.epsilonClosure(&owned_closure.?);
            break :blk &owned_closure.?;
        };

        result.clearRetainingCapacity();
        var it = start_closure.keyIterator();
        while (it.next()) |state_key| {
            const state = state_key.*;
            for (self.edges.items[@intCast(state)].items) |e| {
                const matches = switch (kind) {
                    .CharRange => e.isCharRange() and e.min <= value and e.max >= value,
                    .RuleRef => e.isRuleRef() and e.refRuleId() == value,
                    .Eos => e.isEos(),
                    .RepeatRef => e.isRepeatRef(),
                };
                if (matches) try result.put(e.target, {});
            }
        }
        try self.epsilonClosure(result);
    }

    /// The set of rule ids referenced by `state`'s outgoing edges.
    pub fn possibleRules(self: *const Fsm, allocator: Allocator, state: i32) Allocator.Error!StateSet {
        var rules = StateSet.init(allocator);
        errdefer rules.deinit();
        for (self.edges.items[@intCast(state)].items) |e| {
            if (e.isRuleRef()) try rules.put(e.refRuleId(), {});
        }
        return rules;
    }

    /// All states reachable from `from` (following every edge as a plain transition).
    /// The caller owns the returned set.
    pub fn reachableStates(self: *const Fsm, allocator: Allocator, from: []const i32) Allocator.Error!StateSet {
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
    pub fn addFsm(self: *Fsm, other: *const Fsm) Allocator.Error!i32 {
        const old_num_states = self.numStates();
        const aux_offset: i32 = @intCast(self.edge_aux_data.items.len);
        try self.edge_aux_data.appendSlice(self.allocator, other.edge_aux_data.items);
        const old_len = self.edges.items.len;
        try self.edges.resize(self.allocator, old_len + other.edges.items.len);
        for (old_len..self.edges.items.len) |i| self.edges.items[i] = .empty;
        for (other.edges.items, 0..) |other_row, i| {
            const from = old_num_states + @as(i32, @intCast(i));
            for (other_row.items) |e| {
                const max: i32 = if (e.isAuxEdge() and aux_offset > 0) e.max + aux_offset else e.max;
                try self.edges.items[@intCast(from)].append(
                    self.allocator,
                    FsmEdge.init(e.min, max, e.target + old_num_states),
                );
            }
        }
        return old_num_states;
    }

    /// Rebuilds the FSM under `state_mapping` (old id -> new id), dropping epsilon self-loops
    /// and de-duplicating edges per state. The caller owns the result.
    pub fn rebuildWithMapping(self: *const Fsm, allocator: Allocator, state_mapping: []const i32, new_num_states: i32) Allocator.Error!Fsm {
        var new_edges = try allocator.alloc(std.ArrayList(FsmEdge), @intCast(new_num_states));
        for (new_edges) |*e| e.* = .empty;
        errdefer {
            for (new_edges) |*e| e.deinit(allocator);
            allocator.free(new_edges);
        }
        for (self.edges.items, 0..) |src_row, i| {
            for (src_row.items) |e| {
                if (e.isEpsilon() and state_mapping[i] == state_mapping[@intCast(e.target)]) continue;
                try new_edges[@intCast(state_mapping[i])].append(
                    allocator,
                    FsmEdge.init(e.min, e.max, state_mapping[@intCast(e.target)]),
                );
            }
        }
        for (new_edges) |*row| {
            edge_mod.sortEdges(row.items);
            const kept = dedupEdges(row.items);
            row.items.len = kept.len;
        }
        var aux: std.ArrayList(i32) = .empty;
        errdefer aux.deinit(allocator);
        try aux.appendSlice(allocator, self.edge_aux_data.items);
        return .{
            .allocator = allocator,
            .edges = .fromOwnedSlice(new_edges),
            .edge_aux_data = aux,
        };
    }

    /// Sorts each state's outgoing edges lexicographically.
    pub fn sortEdges(self: *Fsm) void {
        for (self.edges.items) |*row| edge_mod.sortEdges(row.items);
    }
};

/// Removes adjacent duplicate edges (requires a sorted slice).
fn dedupEdges(edges: []FsmEdge) []FsmEdge {
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

test "fsm basic edges and streaming format" {
    const a = std.testing.allocator;
    var fsm = try Fsm.init(a, 3);
    defer fsm.deinit();
    try fsm.addEdge(0, 1, 'a', 'z');
    try fsm.addEpsilonEdge(0, 2);
    try fsm.addRuleEdge(1, 2, 4);
    try fsm.addEosEdge(2, 2);

    try std.testing.expectEqual(@as(i32, 3), fsm.numStates());
    try std.testing.expectEqual(@as(i32, 1), fsm.nextState(0, 'm', .CharRange));
    try std.testing.expectEqual(@as(i32, 2), fsm.nextState(1, 4, .RuleRef));
    try std.testing.expectEqual(@as(i32, 2), fsm.nextState(2, 0, .Eos));
    try std.testing.expectEqual(NO_NEXT_STATE, fsm.nextState(0, '0', .CharRange));

    const rendered = try fsm.edgesToString(a, null);
    defer a.free(rendered);
    try std.testing.expectEqualStrings(
        "[\n0: [[a-z]->1, Eps->2]\n1: [Rule(4)->2]\n2: [EOS->2]\n]",
        rendered,
    );

    const fmt_rendered = try std.fmt.allocPrint(a, "{f}", .{fsm});
    defer a.free(fmt_rendered);
    try std.testing.expectEqualStrings(rendered, fmt_rendered);

    var rules = try fsm.possibleRules(a, 1);
    defer rules.deinit();
    try std.testing.expect(rules.contains(4));

    var duped = try fsm.dupe(a);
    defer duped.deinit();
    try std.testing.expectEqual(@as(i32, 3), duped.numStates());
}
