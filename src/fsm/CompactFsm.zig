//! Finite-state machines in compressed-sparse-row (CSR) form, with atomic reference
//! counting and thread-safe read traversal.

const std = @import("std");
const Allocator = std.mem.Allocator;

const fsm_mod = @import("Fsm.zig");
const Fsm = fsm_mod.Fsm;
const StateSet = fsm_mod.StateSet;
const stateSetFrom = fsm_mod.stateSetFrom;
const edge_mod = @import("edge.zig");
const FsmEdge = edge_mod.FsmEdge;
const RepeatEdgeRef = edge_mod.RepeatEdgeRef;
const TokenEdgeRef = edge_mod.TokenEdgeRef;
const ExcludeTokenEdgeRef = edge_mod.ExcludeTokenEdgeRef;
const sortEdges = edge_mod.sortEdges;
const support = @import("../support.zig");
const Compact2dArray = support.Compact2dArray;

/// The shared immutable storage behind one or more `CompactFsm` handles.
/// Reference-counted atomically so `retain()`/`deinit()` are thread-safe across compiler workers.
pub const CompactFsmShared = struct {
    allocator: Allocator,
    refs: std.atomic.Value(usize),
    edges: Compact2dArray(FsmEdge),
    edge_aux_data: []i32,

    fn create(
        allocator: Allocator,
        edges: Compact2dArray(FsmEdge),
        edge_aux_data: []i32,
    ) Allocator.Error!*CompactFsmShared {
        const shared = try allocator.create(CompactFsmShared);
        shared.* = .{
            .allocator = allocator,
            .refs = std.atomic.Value(usize).init(1),
            .edges = edges,
            .edge_aux_data = edge_aux_data,
        };
        return shared;
    }

    pub fn retain(self: *CompactFsmShared) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *CompactFsmShared) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            const a = self.allocator;
            self.edges.deinit(a);
            a.free(self.edge_aux_data);
            a.destroy(self);
        }
    }
};

/// A finite-state machine stored as CSR rows of edges plus a shared auxiliary-data buffer.
pub const CompactFsm = struct {
    shared: *CompactFsmShared,

    /// Builds a compact FSM from `fsm`, sorting each state's edges using a single reused scratch buffer.
    pub fn fromFsm(allocator: Allocator, fsm: *const Fsm) Allocator.Error!CompactFsm {
        var edges = try Compact2dArray(FsmEdge).init(allocator);
        errdefer edges.deinit(allocator);

        var scratch: std.ArrayList(FsmEdge) = .empty;
        defer scratch.deinit(allocator);

        for (0..@intCast(fsm.numStates())) |state| {
            const row = fsm.stateEdges(@intCast(state));
            scratch.clearRetainingCapacity();
            try scratch.appendSlice(allocator, row);
            sortEdges(scratch.items);
            _ = try edges.pushRow(allocator, scratch.items);
        }
        const aux = try allocator.dupe(i32, fsm.edgeAuxDataSlice());
        errdefer allocator.free(aux);
        return .{ .shared = try CompactFsmShared.create(allocator, edges, aux) };
    }

    /// The empty compact FSM.
    pub fn empty(allocator: Allocator) Allocator.Error!CompactFsm {
        var edges = try Compact2dArray(FsmEdge).init(allocator);
        errdefer edges.deinit(allocator);
        const aux = try allocator.dupe(i32, &.{});
        errdefer allocator.free(aux);
        return .{ .shared = try CompactFsmShared.create(allocator, edges, aux) };
    }

    /// Expands back into an adjacency-list `Fsm`. The caller owns the result.
    pub fn toFsm(self: CompactFsm, allocator: Allocator) Allocator.Error!Fsm {
        const edges = try allocator.alloc(std.ArrayList(FsmEdge), @intCast(self.numStates()));
        var initialized: usize = 0;
        errdefer {
            for (edges[0..initialized]) |*e| e.deinit(allocator);
            allocator.free(edges);
        }
        for (edges, 0..) |*e, i| {
            e.* = .empty;
            initialized += 1;
            try e.appendSlice(allocator, self.stateEdges(@intCast(i)));
        }
        var aux: std.ArrayList(i32) = .empty;
        errdefer aux.deinit(allocator);
        try aux.appendSlice(allocator, self.edgeAuxData());
        return .{
            .allocator = allocator,
            .edges = .fromOwnedSlice(edges),
            .edge_aux_data = aux,
        };
    }

    /// Increments the atomic refcount and returns a shared handle; both handles release on `deinit`.
    pub fn retain(self: CompactFsm) CompactFsm {
        self.shared.retain();
        return .{ .shared = self.shared };
    }

    /// Releases one reference to the shared storage.
    pub fn deinit(self: *CompactFsm) void {
        self.shared.release();
    }

    /// Whether two handles share the same immutable storage.
    pub fn sharesStorage(self: CompactFsm, other: CompactFsm) bool {
        return self.shared == other.shared;
    }

    /// Whether two FSMs have equal contents.
    pub fn eql(self: CompactFsm, other: CompactFsm) bool {
        if (!std.mem.eql(i32, self.shared.edge_aux_data, other.shared.edge_aux_data)) return false;
        if (!std.mem.eql(i32, self.shared.edges.indptrSlice(), other.shared.edges.indptrSlice())) return false;
        const a = self.shared.edges.dataSlice();
        const b = other.shared.edges.dataSlice();
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            if (!x.eql(y)) return false;
        }
        return true;
    }

    /// The number of states.
    pub fn numStates(self: CompactFsm) i32 {
        return @intCast(self.shared.edges.len());
    }

    /// The outgoing edges of `state`.
    pub fn stateEdges(self: CompactFsm, state: i32) []const FsmEdge {
        return self.shared.edges.row(@intCast(state));
    }

    /// The shared auxiliary-data buffer.
    pub fn edgeAuxData(self: CompactFsm) []const i32 {
        return self.shared.edge_aux_data;
    }

    /// The total number of edges across all states.
    pub fn numEdges(self: CompactFsm) usize {
        return self.shared.edges.dataLen();
    }

    /// Rebuilds a compact FSM from CSR parts owned by `allocator`.
    pub fn fromParts(
        allocator: Allocator,
        edges: Compact2dArray(FsmEdge),
        aux_data: []i32,
    ) Allocator.Error!CompactFsm {
        return .{ .shared = try CompactFsmShared.create(allocator, edges, aux_data) };
    }

    /// Borrows the CSR edge table.
    pub fn edgesTable(self: CompactFsm) *const Compact2dArray(FsmEdge) {
        return &self.shared.edges;
    }

    /// The repeat-edge aux view at `idx`.
    pub fn repeatEdgeInfo(self: CompactFsm, idx: i32) RepeatEdgeRef {
        return .{ .data = self.shared.edge_aux_data[@intCast(idx)..] };
    }

    /// The token-edge aux view at `idx`.
    pub fn tokenEdgeInfo(self: CompactFsm, idx: i32) TokenEdgeRef {
        return .{ .data = self.shared.edge_aux_data[@intCast(idx)..] };
    }

    /// The exclude-token-edge aux view at `idx`.
    pub fn excludeTokenEdgeInfo(self: CompactFsm, idx: i32) ExcludeTokenEdgeRef {
        return .{ .data = self.shared.edge_aux_data[@intCast(idx)..] };
    }

    /// Expands `state_set` in place with all states reachable via epsilon transitions.
    /// Allocates temporary BFS queue from caller-supplied `allocator` (thread-safe).
    pub fn epsilonClosure(self: CompactFsm, allocator: Allocator, state_set: *StateSet) Allocator.Error!void {
        var queue: std.ArrayList(i32) = .empty;
        defer queue.deinit(allocator);
        var it = state_set.keyIterator();
        while (it.next()) |k| try queue.append(allocator, k.*);
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const current = queue.items[head];
            for (self.stateEdges(current)) |e| {
                if (e.isEpsilon()) {
                    const gop = try state_set.getOrPut(e.target);
                    if (!gop.found_existing) try queue.append(allocator, e.target);
                }
            }
        }
    }

    /// Advances the (epsilon-closed) set `from` on character `value`, storing the
    /// epsilon-closed successor set in `result`.
    pub fn advanceChar(
        self: CompactFsm,
        allocator: Allocator,
        from: *const StateSet,
        value: i32,
        result: *StateSet,
    ) Allocator.Error!void {
        result.clearRetainingCapacity();
        var it = from.keyIterator();
        while (it.next()) |state_key| {
            for (self.stateEdges(state_key.*)) |e| {
                if (e.isCharRange() and e.min <= value and e.max >= value) {
                    try result.put(e.target, {});
                }
            }
        }
        try self.epsilonClosure(allocator, result);
    }

    /// All states reachable from `from` (following every edge as a plain transition).
    /// The caller owns the returned set.
    pub fn reachableStates(self: CompactFsm, allocator: Allocator, from: []const i32) Allocator.Error!StateSet {
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
            for (self.stateEdges(current)) |e| {
                const gop = try result.getOrPut(e.target);
                if (!gop.found_existing) try queue.append(allocator, e.target);
            }
        }
        return result;
    }
};

/// A compact finite-state machine with a designated start state and accepting-state set
/// (stored as a sorted, deduplicated slice of state ids).
pub const CompactFsmWithStartEnd = struct {
    allocator: Allocator,
    fsm: CompactFsm,
    start: i32,
    ends: []i32,
    is_dfa: bool,
    edge_num: usize,

    /// Creates a compact FSM-with-start/end. `ends_in` need not be sorted or deduplicated.
    /// Takes ownership of one reference of `fsm` on success.
    pub fn init(
        allocator: Allocator,
        fsm: CompactFsm,
        start: i32,
        ends_in: []const i32,
        is_dfa: bool,
    ) Allocator.Error!CompactFsmWithStartEnd {
        const ends = try normalizeEndsSlice(allocator, ends_in);
        return .{
            .allocator = allocator,
            .fsm = fsm,
            .start = start,
            .ends = ends,
            .is_dfa = is_dfa,
            .edge_num = fsm.numEdges(),
        };
    }

    fn normalizeEndsSlice(allocator: Allocator, ends_in: []const i32) Allocator.Error![]i32 {
        if (ends_in.len == 0) return &.{};
        var buf = try allocator.dupe(i32, ends_in);
        errdefer allocator.free(buf);
        std.mem.sortUnstable(i32, buf, {}, std.sort.asc(i32));
        var write: usize = 0;
        for (buf, 0..) |v, read| {
            if (read == 0 or v != buf[read - 1]) {
                buf[write] = v;
                write += 1;
            }
        }
        if (write == buf.len) return buf;
        const exact = try allocator.dupe(i32, buf[0..write]);
        allocator.free(buf);
        return exact;
    }

    /// Shares the underlying `CompactFsm` storage (atomic refcount +1) and copies `ends` in `allocator`.
    pub fn cloneWithShared(self: *const CompactFsmWithStartEnd, allocator: Allocator) Allocator.Error!CompactFsmWithStartEnd {
        const ends_copy: []i32 = if (self.ends.len == 0) &.{} else try allocator.dupe(i32, self.ends);
        return .{
            .allocator = allocator,
            .fsm = self.fsm.retain(),
            .start = self.start,
            .ends = ends_copy,
            .is_dfa = self.is_dfa,
            .edge_num = self.edge_num,
        };
    }

    /// Alias for `cloneWithShared`.
    pub fn dupe(self: *const CompactFsmWithStartEnd, allocator: Allocator) Allocator.Error!CompactFsmWithStartEnd {
        return self.cloneWithShared(allocator);
    }

    /// Releases one reference of the shared storage and frees `ends`.
    pub fn deinit(self: *CompactFsmWithStartEnd) void {
        if (self.ends.len > 0) self.allocator.free(self.ends);
        self.fsm.deinit();
    }

    /// The number of states.
    pub fn numStates(self: *const CompactFsmWithStartEnd) i32 {
        return self.fsm.numStates();
    }

    /// Whether `state` is an accepting state.
    pub fn isEndState(self: *const CompactFsmWithStartEnd, state: i32) bool {
        if (self.ends.len <= 8) {
            for (self.ends) |e| {
                if (e == state) return true;
            }
            return false;
        }
        var lo: usize = 0;
        var hi: usize = self.ends.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.ends[mid] < state) {
                lo = mid + 1;
            } else if (self.ends[mid] > state) {
                hi = mid;
            } else {
                return true;
            }
        }
        return false;
    }

    /// Whether `state` has an outgoing character/token edge (can consume input).
    pub fn isScanableState(self: *const CompactFsmWithStartEnd, state: i32) bool {
        for (self.fsm.stateEdges(state)) |e| {
            if (e.isCharRange() or e.isToken() or e.isExcludeToken()) return true;
        }
        return false;
    }

    /// Whether `state` has an outgoing rule/epsilon/repeat edge (is non-terminal).
    pub fn isNonTerminalState(self: *const CompactFsmWithStartEnd, state: i32) bool {
        for (self.fsm.stateEdges(state)) |e| {
            if (e.isRuleRef() or e.isEpsilon() or e.isRepeatRef()) return true;
        }
        return false;
    }

    /// All states reachable from the start state (caller owns the set).
    pub fn reachableStates(self: *const CompactFsmWithStartEnd, allocator: Allocator) Allocator.Error!StateSet {
        return self.fsm.reachableStates(allocator, &.{self.start});
    }

    /// Whether the FSM accepts `input` (treating it as a byte sequence).
    pub fn acceptString(self: *const CompactFsmWithStartEnd, allocator: Allocator, input: []const u8) Allocator.Error!bool {
        var states = try stateSetFrom(allocator, &.{self.start});
        defer states.deinit();
        try self.fsm.epsilonClosure(allocator, &states);
        var result = StateSet.init(allocator);
        defer result.deinit();
        for (input) |byte| {
            try self.fsm.advanceChar(allocator, &states, @intCast(byte), &result);
            if (result.count() == 0) return false;
            std.mem.swap(StateSet, &states, &result);
        }
        var it = states.keyIterator();
        while (it.next()) |s| {
            if (self.isEndState(s.*)) return true;
        }
        return false;
    }
};

/// A compact per-rule FSM plus the edge/node counts of the rule's FSM before merging
/// into the shared complete FSM.
pub const CompactFsmWithStartEndWithSize = struct {
    fsm: CompactFsmWithStartEnd,
    edge_num: i32,
    node_num: i32,

    /// Creates the wrapper from its parts (takes over ownership of `fsm`).
    pub fn init(fsm: CompactFsmWithStartEnd, edge_num: i32, node_num: i32) CompactFsmWithStartEndWithSize {
        return .{ .fsm = fsm, .edge_num = edge_num, .node_num = node_num };
    }

    /// Shares the underlying `CompactFsm` storage (one extra reference) and copies `ends` in `allocator`.
    pub fn cloneWithShared(self: *const CompactFsmWithStartEndWithSize, allocator: Allocator) Allocator.Error!CompactFsmWithStartEndWithSize {
        return .{
            .fsm = try self.fsm.cloneWithShared(allocator),
            .edge_num = self.edge_num,
            .node_num = self.node_num,
        };
    }

    /// Alias for `cloneWithShared`.
    pub fn dupe(self: *const CompactFsmWithStartEndWithSize, allocator: Allocator) Allocator.Error!CompactFsmWithStartEndWithSize {
        return self.cloneWithShared(allocator);
    }

    /// Releases the storage and the end list.
    pub fn deinit(self: *CompactFsmWithStartEndWithSize) void {
        self.fsm.deinit();
    }

    // --- Convenience pass-throughs ---

    pub inline fn compact(self: *const CompactFsmWithStartEndWithSize) CompactFsm {
        return self.fsm.fsm;
    }

    pub inline fn startState(self: *const CompactFsmWithStartEndWithSize) i32 {
        return self.fsm.start;
    }

    pub inline fn ends(self: *const CompactFsmWithStartEndWithSize) []const i32 {
        return self.fsm.ends;
    }

    pub inline fn isDfa(self: *const CompactFsmWithStartEndWithSize) bool {
        return self.fsm.is_dfa;
    }

    pub inline fn numStates(self: *const CompactFsmWithStartEndWithSize) i32 {
        return self.fsm.fsm.numStates();
    }

    pub inline fn stateEdges(self: *const CompactFsmWithStartEndWithSize, state: i32) []const FsmEdge {
        return self.fsm.fsm.stateEdges(state);
    }

    pub inline fn isEndState(self: *const CompactFsmWithStartEndWithSize, state: i32) bool {
        return self.fsm.isEndState(state);
    }

    pub inline fn isScanableState(self: *const CompactFsmWithStartEndWithSize, state: i32) bool {
        return self.fsm.isScanableState(state);
    }

    pub inline fn isNonTerminalState(self: *const CompactFsmWithStartEndWithSize, state: i32) bool {
        return self.fsm.isNonTerminalState(state);
    }

    pub inline fn edgeNum(self: *const CompactFsmWithStartEndWithSize) i32 {
        return self.edge_num;
    }

    pub inline fn nodeNum(self: *const CompactFsmWithStartEndWithSize) i32 {
        return self.node_num;
    }

    pub inline fn sharesStorage(self: *const CompactFsmWithStartEndWithSize, other: CompactFsm) bool {
        return self.fsm.fsm.sharesStorage(other);
    }
};

test "compact roundtrip, sharing, and binary search ends" {
    const a = std.testing.allocator;
    var fsm = try Fsm.init(a, 3);
    defer fsm.deinit();
    try fsm.addEdge(0, 1, 'a', 'a');
    try fsm.addEdge(0, 1, 'a', 'a');
    try fsm.addEdge(1, 2, 'b', 'c');
    try fsm.addEpsilonEdge(0, 0);

    var compact = try CompactFsm.fromFsm(a, &fsm);
    defer compact.deinit();
    try std.testing.expectEqual(@as(i32, 3), compact.numStates());
    var back = try compact.toFsm(a);
    defer back.deinit();
    var compact2 = try back.toCompact(a);
    defer compact2.deinit();
    try std.testing.expect(compact.eql(compact2));
    try std.testing.expect(!compact.sharesStorage(compact2));

    var retained = compact.retain();
    defer retained.deinit();
    try std.testing.expect(compact.sharesStorage(retained));

    var wse = try CompactFsmWithStartEnd.init(a, compact.retain(), 0, &.{ 2, 2, 1 }, false);
    defer wse.deinit();
    try std.testing.expectEqualSlices(i32, &.{ 1, 2 }, wse.ends);
    try std.testing.expect(try wse.acceptString(a, "ab"));
    try std.testing.expect(!try wse.acceptString(a, "az"));

    var sized = CompactFsmWithStartEndWithSize.init(try wse.cloneWithShared(a), 4, 3);
    defer sized.deinit();
    try std.testing.expect(sized.sharesStorage(compact));
    try std.testing.expectEqual(@as(i32, 0), sized.startState());
    try std.testing.expect(sized.isEndState(2));
    try std.testing.expectEqual(@as(i32, 4), sized.edgeNum());
    try std.testing.expectEqual(@as(i32, 3), sized.nodeNum());
}

test "CompactFsm multi-threaded retain, release, and acceptString race-free" {
    var ts = support.ThreadSafeAllocator{ .child = std.testing.allocator };
    const backing = ts.allocator();

    var fsm = try Fsm.init(backing, 4);
    defer fsm.deinit();
    try fsm.addEdge(0, 1, 'a', 'z');
    try fsm.addEpsilonEdge(1, 2);
    try fsm.addEdge(2, 3, '0', '9');

    var base = try CompactFsm.fromFsm(backing, &fsm);
    defer base.deinit();

    const Worker = struct {
        fn run(shared_fsm: CompactFsm, alloc: Allocator) void {
            var local_alloc = std.heap.ArenaAllocator.init(alloc);
            defer local_alloc.deinit();
            const aa = local_alloc.allocator();
            for (0..32) |_| {
                var handle = shared_fsm.retain();
                defer handle.deinit();
                var wse = CompactFsmWithStartEnd.init(aa, handle.retain(), 0, &.{3}, false) catch unreachable;
                defer wse.deinit();
                std.debug.assert(wse.acceptString(aa, "x7") catch unreachable);
                std.debug.assert(!(wse.acceptString(aa, "xx") catch unreachable));
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ base, backing });
    }
    for (threads) |t| t.join();
}
