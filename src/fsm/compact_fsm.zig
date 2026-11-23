//! A finite-state machine in compressed-sparse-row form.
//!
//! Same semantics as `Fsm` but with the per-state edge lists packed into one `Compact2dArray`,
//! which is cheaper to store/serialize and to scan. Build one with `CompactFsm.from_fsm` and
//! convert back with `CompactFsm.to_fsm`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const fsm_mod = @import("fsm.zig");
const Fsm = fsm_mod.Fsm;
const StateSet = fsm_mod.StateSet;
const clone_set = fsm_mod.clone_set;
const state_set_from = fsm_mod.state_set_from;
const fsm_edge_mod = @import("fsm_edge.zig");
const FsmEdge = fsm_edge_mod.FsmEdge;
const sortEdges = fsm_edge_mod.sortEdges;
const support = @import("support/mod.zig");
const Compact2dArray = support.Compact2dArray;

/// The shared immutable storage behind one or more `CompactFsm` handles
/// (the Rust `Arc` pair; reference-counted so clones are cheap — the C++ pimpl
/// `CompactFSM`: every generated per-rule FSM can share the complete FSM's storage).
pub const CompactFsmShared = struct {
    allocator: Allocator,
    refs: usize,
    edges: Compact2dArray(FsmEdge),
    edge_aux_data: []i32,

    fn create(allocator: Allocator, edges: Compact2dArray(FsmEdge), edge_aux_data: []i32) Allocator.Error!*CompactFsmShared {
        const shared = try allocator.create(CompactFsmShared);
        shared.* = .{ .allocator = allocator, .refs = 1, .edges = edges, .edge_aux_data = edge_aux_data };
        return shared;
    }

    fn retain(self: *CompactFsmShared) void {
        self.refs += 1;
    }

    fn release(self: *CompactFsmShared) void {
        self.refs -= 1;
        if (self.refs == 0) {
            self.edges.deinit();
            self.allocator.free(self.edge_aux_data);
            self.allocator.destroy(self);
        }
    }
};

/// A finite-state machine stored as CSR rows of edges plus a shared auxiliary-data buffer.
pub const CompactFsm = struct {
    shared: *CompactFsmShared,

    /// Builds a compact FSM from `fsm`, sorting each state's edges (matching the C++
    /// `ToCompact`, which sorts before packing).
    pub fn from_fsm(allocator: Allocator, fsm: *const Fsm) Allocator.Error!CompactFsm {
        var sorted = try fsm.clone(allocator);
        defer sorted.deinit();
        sorted.sort_edges();
        var edges = try Compact2dArray(FsmEdge).init(allocator);
        errdefer edges.deinit();
        for (0..@intCast(sorted.num_states())) |state| {
            _ = try edges.push_row(sorted.state_edges(@intCast(state)));
        }
        const aux = try allocator.dupe(i32, sorted.edge_aux_data_slice());
        return .{ .shared = try CompactFsmShared.create(allocator, edges, aux) };
    }

    /// The empty compact FSM (`CompactFsm::default()`).
    pub fn empty(allocator: Allocator) Allocator.Error!CompactFsm {
        var edges = try Compact2dArray(FsmEdge).init(allocator);
        errdefer edges.deinit();
        return .{ .shared = try CompactFsmShared.create(allocator, edges, try allocator.dupe(i32, &.{})) };
    }

    /// Expands back into an adjacency-list `Fsm`. The caller owns the result.
    pub fn to_fsm(self: CompactFsm, allocator: Allocator) Allocator.Error!Fsm {
        var edges = try allocator.alloc(std.ArrayList(FsmEdge), self.num_states());
        for (edges) |*e| e.* = .empty;
        for (edges, 0..) |*e, i| {
            try e.appendSlice(allocator, self.state_edges(@intCast(i)));
        }
        var aux: std.ArrayList(i32) = .empty;
        try aux.appendSlice(allocator, self.edge_aux_data());
        return .{
            .allocator = allocator,
            .edges = .fromOwnedSlice(edges),
            .edge_aux_data = aux,
        };
    }

    /// Shares the immutable storage; both handles release it on `deinit`.
    pub fn clone(self: CompactFsm) CompactFsm {
        self.shared.retain();
        return .{ .shared = self.shared };
    }

    /// Releases one reference to the shared storage.
    pub fn deinit(self: *CompactFsm) void {
        self.shared.release();
    }

    /// Whether two FSMs share both immutable storage buffers (`Arc::ptr_eq` on both).
    pub fn shares_storage(self: CompactFsm, other: CompactFsm) bool {
        return self.shared == other.shared;
    }

    /// Whether two FSMs have equal contents (the derived Rust `PartialEq`).
    pub fn eql(self: CompactFsm, other: CompactFsm) bool {
        return std.mem.eql(i32, self.shared.edge_aux_data, other.shared.edge_aux_data) and
            std.mem.eql(i32, self.shared.edges.indptr_slice(), other.shared.edges.indptr_slice()) and
            std.mem.eql(FsmEdge, self.shared.edges.data_slice(), other.shared.edges.data_slice());
    }

    /// The number of states.
    pub fn num_states(self: CompactFsm) i32 {
        return @intCast(self.shared.edges.len());
    }

    /// The outgoing edges of `state`.
    pub fn state_edges(self: CompactFsm, state: i32) []const FsmEdge {
        return self.shared.edges.row(@intCast(state));
    }

    /// The shared auxiliary-data buffer.
    pub fn edge_aux_data(self: CompactFsm) []const i32 {
        return self.shared.edge_aux_data;
    }

    /// The total number of edges across all states.
    pub fn num_edges(self: CompactFsm) usize {
        return self.shared.edges.data_len();
    }

    /// Rebuilds a compact FSM from serialized CSR parts (the Rust `pub(crate) from_parts`;
    /// made public — the JSON deserializer in serialization.zig uses it).
    pub fn from_parts(allocator: Allocator, edges: Compact2dArray(FsmEdge), edge_aux_data: []i32) Allocator.Error!CompactFsm {
        return .{ .shared = try CompactFsmShared.create(allocator, edges, edge_aux_data) };
    }

    /// Borrow the CSR edge table (used by JSON serialization; Rust `pub(crate) edges_table`).
    pub fn edges_table(self: CompactFsm) *const Compact2dArray(FsmEdge) {
        return &self.shared.edges;
    }

    /// The repeat-edge aux view at `idx`.
    pub fn repeat_edge_info(self: CompactFsm, idx: i32) @import("fsm_edge.zig").RepeatEdgeRef {
        return .{ .data = self.shared.edge_aux_data[@intCast(idx)..] };
    }

    /// The token-edge aux view at `idx`.
    pub fn token_edge_info(self: CompactFsm, idx: i32) @import("fsm_edge.zig").TokenEdgeRef {
        return .{ .data = self.shared.edge_aux_data[@intCast(idx)..] };
    }

    /// The exclude-token-edge aux view at `idx`.
    pub fn exclude_token_edge_info(self: CompactFsm, idx: i32) @import("fsm_edge.zig").ExcludeTokenEdgeRef {
        return .{ .data = self.shared.edge_aux_data[@intCast(idx)..] };
    }

    /// Expands `state_set` in place with all states reachable via epsilon transitions.
    pub fn epsilon_closure(self: CompactFsm, state_set: *StateSet) Allocator.Error!void {
        var queue: std.ArrayList(i32) = .empty;
        defer queue.deinit(self.shared.allocator);
        var it = state_set.keyIterator();
        while (it.next()) |k| try queue.append(self.shared.allocator, k.*);
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const current = queue.items[head];
            for (self.state_edges(current)) |e| {
                if (e.is_epsilon()) {
                    const gop = try state_set.getOrPut(e.target);
                    if (!gop.found_existing) try queue.append(self.shared.allocator, e.target);
                }
            }
        }
    }

    /// Advances the (epsilon-closed) set `from` on character `value`, storing the
    /// epsilon-closed successor set in `result`.
    pub fn advance_char(self: CompactFsm, from: *const StateSet, value: i32, result: *StateSet) Allocator.Error!void {
        result.clearRetainingCapacity();
        var it = from.keyIterator();
        while (it.next()) |state_key| {
            for (self.state_edges(state_key.*)) |e| {
                if (e.is_char_range() and e.min <= value and e.max >= value) {
                    try result.put(e.target, {});
                }
            }
        }
        try self.epsilon_closure(result);
    }

    /// All states reachable from `from` (following every edge as a plain transition).
    /// The caller owns the set.
    pub fn reachable_states(self: CompactFsm, allocator: Allocator, from: []const i32) Allocator.Error!StateSet {
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
            for (self.state_edges(current)) |e| {
                const gop = try result.getOrPut(e.target);
                if (!gop.found_existing) try queue.append(allocator, e.target);
            }
        }
        return result;
    }
};

test "compact roundtrip and sharing" {
    const a = std.testing.allocator;
    var fsm = try Fsm.new(a, 3);
    defer fsm.deinit();
    try fsm.add_edge(0, 1, 'a', 'a');
    try fsm.add_edge(0, 1, 'a', 'a');
    try fsm.add_edge(1, 2, 'b', 'c');
    try fsm.add_epsilon_edge(0, 0);
    var compact = try CompactFsm.from_fsm(a, &fsm);
    defer compact.deinit();
    try std.testing.expectEqual(@as(i32, 3), compact.num_states());
    var back = try compact.to_fsm(a);
    defer back.deinit();
    // from_fsm sorts edges: 0 has eps + 'a', both survive.
    var compact2 = try CompactFsm.from_fsm(a, &back);
    defer compact2.deinit();
    try std.testing.expect(compact.eql(compact2));
    try std.testing.expect(!compact.shares_storage(compact2));
    const cloned = compact.clone();
    defer cloned.deinit();
    try std.testing.expect(compact.shares_storage(cloned));
}
