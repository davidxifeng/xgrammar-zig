//! Computes structural hashes and normalized state-id mappings for per-rule FSMs (`fsm_hasher`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const fsm_mod = @import("../fsm.zig");
const CompactFsm = fsm_mod.CompactFsm;
const FsmEdge = fsm_mod.FsmEdge;
const sortEdges = fsm_mod.sortEdges;
const grammar_mod = @import("../grammar.zig");
const FsmStatePair = grammar_mod.FsmStatePair;
const Grammar = grammar_mod.Grammar;
const NO_EXPR = grammar_mod.NO_EXPR;
const support = @import("../support.zig");
const hashCombineBinary = support.hashCombineBinary;
const analysis_passes = @import("analysis_passes.zig");

const NOT_END_STATE_FLAG: i32 = -0x100;
const END_STATE_FLAG: i32 = -0x200;
const SELF_RECURSION_FLAG: i32 = -0x300;
const SIMPLE_CYCLE_FLAG: i32 = -0x400;
const UNKNOWN_FLAG: i32 = -0x500;
const REPEAT_EDGE_FLAG: i32 = -0x600;
const CHAR_EDGE_FLAG: i32 = -0x700;
const TOKEN_EDGE_FLAG: i32 = -0x800;
const EXCLUDE_TOKEN_EDGE_FLAG: i32 = -0x900;
const EPSILON_EDGE_FLAG: i32 = -0xA00;

fn foldU64ToI32(v: u64) i32 {
    const folded: u32 = @truncate(v ^ (v >> 32));
    return @bitCast(folded);
}

fn hashNonRuleEdge(
    seed: u64,
    compact: CompactFsm,
    edge: FsmEdge,
    current_new_state_id: i32,
    next_new_state_id: i32,
) u64 {
    if (edge.isEpsilon()) {
        return hashCombineI32(seed, &.{ EPSILON_EDGE_FLAG, current_new_state_id, next_new_state_id });
    } else if (edge.isToken()) {
        var h = hashCombineI32(seed, &.{ TOKEN_EDGE_FLAG, current_new_state_id, next_new_state_id });
        const ids = compact.tokenEdgeInfo(edge.auxIndex()).tokenIds();
        h = hashCombineI32(h, &.{@intCast(ids.len)});
        return hashCombineI32(h, ids);
    } else if (edge.isExcludeToken()) {
        var h = hashCombineI32(seed, &.{ EXCLUDE_TOKEN_EDGE_FLAG, current_new_state_id, next_new_state_id });
        const ids = compact.excludeTokenEdgeInfo(edge.auxIndex()).tokenIds();
        h = hashCombineI32(h, &.{@intCast(ids.len)});
        return hashCombineI32(h, ids);
    }
    return hashCombineI32(seed, &.{ CHAR_EDGE_FLAG, current_new_state_id, edge.min, edge.max, next_new_state_id });
}

fn hashCombine(seed: u64, values: []const u64) u64 {
    var result = seed;
    for (values) |value| {
        hashCombineBinary(&result, value);
    }
    return result;
}

fn hashCombineI32(seed: u64, values: []const i32) u64 {
    var result = seed;
    for (values) |value| {
        hashCombineBinary(&result, @bitCast(@as(i64, value)));
    }
    return result;
}

/// Computes per-rule FSM hashes and normalized state-id mappings on `grammar`.
pub fn apply(allocator: Allocator, grammar: *Grammar) Allocator.Error!void {
    var hasher = GrammarFsmHasher{
        .allocator = allocator,
        .grammar = grammar,
        .visited = .empty,
        .ref_graph_from_referrer_to_referee = .empty,
        .ref_graph_from_referee_to_referrer = .empty,
        .sorted_edges = .empty,
        .has_inward_edges = .empty,
        .fsm_state_offsets = .empty,
        .per_rule_fsm_hashes = .empty,
        .per_rule_fsm_new_state_ids = .empty,
        .ready_queue = .empty,
    };
    defer hasher.deinitTemps();
    try hasher.run();
}

const GrammarFsmHasher = struct {
    allocator: Allocator,
    grammar: *Grammar,
    visited: std.ArrayList(bool),
    ref_graph_from_referrer_to_referee: std.ArrayList(std.ArrayList(i32)),
    ref_graph_from_referee_to_referrer: std.ArrayList(std.ArrayList(i32)),
    sorted_edges: std.ArrayList(std.ArrayList(FsmEdge)),
    has_inward_edges: std.ArrayList(bool),
    fsm_state_offsets: std.ArrayList(usize),
    per_rule_fsm_hashes: std.ArrayList(?u64),
    per_rule_fsm_new_state_ids: std.ArrayList([]const FsmStatePair),
    ready_queue: std.Deque(i32),

    fn deinitTemps(self: *GrammarFsmHasher) void {
        const gpa = self.allocator;
        self.visited.deinit(gpa);
        for (self.ref_graph_from_referrer_to_referee.items) |*l| l.deinit(gpa);
        self.ref_graph_from_referrer_to_referee.deinit(gpa);
        for (self.ref_graph_from_referee_to_referrer.items) |*l| l.deinit(gpa);
        self.ref_graph_from_referee_to_referrer.deinit(gpa);
        for (self.sorted_edges.items) |*l| l.deinit(gpa);
        self.sorted_edges.deinit(gpa);
        self.has_inward_edges.deinit(gpa);
        self.fsm_state_offsets.deinit(gpa);
        self.per_rule_fsm_hashes.deinit(gpa);
        for (self.per_rule_fsm_new_state_ids.items) |pairs| gpa.free(pairs);
        self.per_rule_fsm_new_state_ids.deinit(gpa);
        self.ready_queue.deinit(gpa);
    }

    fn run(self: *GrammarFsmHasher) Allocator.Error!void {
        const gpa = self.allocator;
        const num_rules = self.grammar.numRules();
        try self.per_rule_fsm_hashes.appendNTimes(gpa, null, num_rules);
        try self.per_rule_fsm_new_state_ids.appendNTimes(gpa, &.{}, num_rules);
        try self.visited.appendNTimes(gpa, false, num_rules);
        {
            var offsets = try self.grammar.fsmStateOffsets(gpa);
            defer offsets.deinit(gpa);
            try self.fsm_state_offsets.appendSlice(gpa, offsets.items);
        }

        {
            const referee_to_referrer = try analysis_passes.ruleRefGraph(gpa, self.grammar);
            defer {
                for (referee_to_referrer) |*refs| refs.deinit(gpa);
                gpa.free(referee_to_referrer);
            }
            try self.ref_graph_from_referee_to_referrer.ensureTotalCapacity(gpa, referee_to_referrer.len);
            for (referee_to_referrer) |refs| {
                var copy: std.ArrayList(i32) = .empty;
                errdefer copy.deinit(gpa);
                try copy.appendSlice(gpa, refs.items);
                self.ref_graph_from_referee_to_referrer.appendAssumeCapacity(copy);
            }
        }
        try self.ref_graph_from_referrer_to_referee.appendNTimes(gpa, .empty, num_rules);
        for (self.ref_graph_from_referee_to_referrer.items, 0..) |referrers, referee| {
            for (referrers.items) |referrer| {
                try self.ref_graph_from_referrer_to_referee.items[@intCast(referrer)].append(gpa, @intCast(referee));
            }
        }

        {
            const complete = self.grammar.completeFsm();
            try self.collectSortedEdges(0, complete);
            for (self.grammar.perRuleFsmsSlice(), 0..) |view_opt, rule_id| {
                if (view_opt) |v| {
                    try self.collectSortedEdges(self.fsm_state_offsets.items[rule_id], v.compact());
                }
            }
        }

        // #963: RegexFsmBuilder can lower large repetitions into helper rules referenced via
        // FSM RepeatRef/RuleRef edges absent from the AST. Supplement the ref graph from FSM edges.
        for (self.grammar.perRuleFsmsSlice(), 0..) |view_opt, referrer_idx| {
            const view = view_opt orelse continue;
            const referrer: i32 = @intCast(referrer_idx);
            const compact = view.compact();
            var reachable = try view.fsm.reachableStates(gpa);
            defer reachable.deinit();
            var it = reachable.keyIterator();
            while (it.next()) |s_ptr| {
                for (compact.stateEdges(s_ptr.*)) |edge| {
                    const referee: i32 = if (edge.isRuleRef())
                        edge.refRuleId()
                    else if (edge.isRepeatRef())
                        compact.repeatEdgeInfo(edge.auxIndex()).ruleId()
                    else
                        continue;
                    if (referee == referrer) continue;
                    const ref_to_rr = &self.ref_graph_from_referee_to_referrer.items[@intCast(referee)];
                    if (std.mem.indexOfScalar(i32, ref_to_rr.items, referrer) == null) {
                        try ref_to_rr.append(gpa, referrer);
                    }
                    const rr_to_ref = &self.ref_graph_from_referrer_to_referee.items[@intCast(referrer)];
                    if (std.mem.indexOfScalar(i32, rr_to_ref.items, referee) == null) {
                        try rr_to_ref.append(gpa, referee);
                    }
                }
            }
        }

        for (self.grammar.perRuleFsmsSlice(), 0..) |view, i| {
            if (view == null) self.visited.items[i] = true;
        }

        for (0..num_rules) |rule_id| {
            if (self.isReadyToHash(@intCast(rule_id))) try self.ready_queue.pushBack(gpa, @intCast(rule_id));
        }
        while (true) {
            const current_operating_index = self.ready_queue.popFront() orelse {
                if (!try self.findSimpleCycle()) break;
                continue;
            };
            if (!self.isReadyToHash(current_operating_index)) continue;
            self.visited.items[@intCast(current_operating_index)] = true;
            const hash_value = try self.hashFsm(current_operating_index);
            self.per_rule_fsm_hashes.items[@intCast(current_operating_index)] = hash_value;
            try self.removeHashedFsmFromRefGraph(current_operating_index);
        }

        var partial_hashed_list: std.ArrayList(struct { rule_id: i32, hash: u64 }) = .empty;
        defer partial_hashed_list.deinit(gpa);
        for (0..self.grammar.numRules()) |rule_id| {
            if (self.per_rule_fsm_hashes.items[rule_id] != null) continue;
            const view = self.grammar.perRuleFsm(@intCast(rule_id)) orelse continue;
            const start = view.startState();
            if (self.has_inward_edges.items[self.fsm_state_offsets.items[rule_id] + @as(usize, @intCast(start))]) continue;
            if (try self.isPartialHashable(@intCast(rule_id))) |hash_value| {
                try partial_hashed_list.append(gpa, .{ .rule_id = @intCast(rule_id), .hash = hash_value });
            }
        }
        for (partial_hashed_list.items) |entry| {
            self.per_rule_fsm_hashes.items[@intCast(entry.rule_id)] = entry.hash;
        }

        try self.grammar.setFsmHashData(
            self.per_rule_fsm_hashes.items,
            self.per_rule_fsm_new_state_ids.items,
        );
    }

    fn collectSortedEdges(self: *GrammarFsmHasher, offset: usize, compact: CompactFsm) Allocator.Error!void {
        if (offset != self.sorted_edges.items.len) return;
        try self.has_inward_edges.resize(self.allocator, offset + @as(usize, @intCast(compact.numStates())));
        for (self.has_inward_edges.items[@min(self.has_inward_edges.items.len, offset)..]) |*b| b.* = false;
        for (0..@intCast(compact.numStates())) |state| {
            var edges: std.ArrayList(FsmEdge) = .empty;
            errdefer edges.deinit(self.allocator);
            try edges.appendSlice(self.allocator, compact.stateEdges(@intCast(state)));
            sortEdges(edges.items);
            for (edges.items) |edge| {
                self.has_inward_edges.items[offset + @as(usize, @intCast(edge.target))] = true;
            }
            try self.sorted_edges.append(self.allocator, edges);
        }
    }

    fn findSimpleCycle(self: *GrammarFsmHasher) Allocator.Error!bool {
        const gpa = self.allocator;
        const not_simple_cycle = try gpa.dupe(bool, self.visited.items);
        defer gpa.free(not_simple_cycle);
        const in_stack = try gpa.alloc(bool, self.ref_graph_from_referee_to_referrer.items.len);
        defer gpa.free(in_stack);
        @memset(in_stack, false);
        var dfs_stack: std.ArrayList(i32) = .empty;
        defer dfs_stack.deinit(gpa);
        var simple_cycle: std.ArrayList(i32) = .empty;
        defer simple_cycle.deinit(gpa);

        for (0..not_simple_cycle.len) |i| {
            if (not_simple_cycle[i]) continue;
            dfs_stack.clearRetainingCapacity();
            simple_cycle.clearRetainingCapacity();
            try dfs_stack.append(gpa, @intCast(i));
            var current_fsm_index: i32 = @intCast(i);
            in_stack[@intCast(current_fsm_index)] = true;
            while (self.ref_graph_from_referrer_to_referee.items[@intCast(current_fsm_index)].items.len == 1 and
                !not_simple_cycle[@intCast(current_fsm_index)])
            {
                const next = self.ref_graph_from_referrer_to_referee.items[@intCast(current_fsm_index)].items[0];
                std.debug.assert(current_fsm_index != next);
                not_simple_cycle[@intCast(current_fsm_index)] = true;
                current_fsm_index = next;
                if (in_stack[@intCast(current_fsm_index)]) {
                    try simple_cycle.append(gpa, current_fsm_index);
                    while (dfs_stack.items[dfs_stack.items.len - 1] != current_fsm_index) {
                        try simple_cycle.append(gpa, dfs_stack.pop().?);
                    }
                    break;
                }
                try dfs_stack.append(gpa, current_fsm_index);
                in_stack[@intCast(current_fsm_index)] = true;
            }
            if (simple_cycle.items.len != 0) {
                try self.hashSimpleCycle(simple_cycle.items);
                return true;
            }
            for (dfs_stack.items) |state| {
                in_stack[@intCast(state)] = false;
            }
        }
        return false;
    }

    fn hashSimpleCycle(self: *GrammarFsmHasher, simple_cycle: []const i32) Allocator.Error!void {
        const gpa = self.allocator;
        for (simple_cycle) |cycle_id| {
            self.visited.items[@intCast(cycle_id)] = true;
            self.per_rule_fsm_hashes.items[@intCast(cycle_id)] = @bitCast(@as(i64, SIMPLE_CYCLE_FLAG));
        }

        var local_cycle_hash: std.ArrayList(u64) = .empty;
        defer local_cycle_hash.deinit(gpa);
        for (simple_cycle) |cycle_id| {
            try local_cycle_hash.append(gpa, try self.hashFsm(cycle_id));
        }
        const local_cycle_hash_copy = try gpa.dupe(u64, local_cycle_hash.items);
        defer gpa.free(local_cycle_hash_copy);
        for (0..local_cycle_hash.items.len) |i| {
            var current_hash: u64 = 0;
            for (0..local_cycle_hash.items.len) |j| {
                current_hash = hashCombine(current_hash, &.{local_cycle_hash_copy[(i + j) % local_cycle_hash.items.len]});
            }
            local_cycle_hash.items[i] = current_hash;
        }

        for (simple_cycle, 0..) |cycle_id, i| {
            self.per_rule_fsm_hashes.items[@intCast(cycle_id)] = local_cycle_hash.items[i];
            try self.removeHashedFsmFromRefGraph(cycle_id);
        }
    }

    fn isReadyToHash(self: *const GrammarFsmHasher, fsm_index: i32) bool {
        const referees = &self.ref_graph_from_referrer_to_referee.items[@intCast(fsm_index)];
        if (self.visited.items[@intCast(fsm_index)]) return false;
        if (referees.items.len == 0) return true;
        return referees.items.len == 1 and referees.items[0] == fsm_index;
    }

    fn removeHashedFsmFromRefGraph(self: *GrammarFsmHasher, fsm_index: i32) Allocator.Error!void {
        for (self.ref_graph_from_referee_to_referrer.items[@intCast(fsm_index)].items) |referer| {
            const referees = &self.ref_graph_from_referrer_to_referee.items[@intCast(referer)];
            var write: usize = 0;
            for (referees.items) |rule_id| {
                if (rule_id != fsm_index) {
                    referees.items[write] = rule_id;
                    write += 1;
                }
            }
            referees.shrinkRetainingCapacity(write);
            if (self.isReadyToHash(referer)) {
                try self.ready_queue.pushBack(self.allocator, referer);
            }
        }
    }

    const HashI32TargetList = std.ArrayList(struct { hash: i32, target: i32 });
    const HashU64TargetList = std.ArrayList(struct { hash: u64, target: i32 });

    const StateIdMap = struct {
        lookup: std.AutoHashMapUnmanaged(i32, i32) = .empty,
        order: std.ArrayList(i32) = .empty,

        fn init(gpa: Allocator, start: i32) Allocator.Error!StateIdMap {
            var map = StateIdMap{};
            errdefer map.deinit(gpa);
            try map.lookup.put(gpa, start, 0);
            try map.order.append(gpa, start);
            return map;
        }

        fn deinit(self: *StateIdMap, gpa: Allocator) void {
            self.lookup.deinit(gpa);
            self.order.deinit(gpa);
        }

        fn get(self: *const StateIdMap, old: i32) i32 {
            return self.lookup.get(old).?;
        }

        fn getOrInsert(self: *StateIdMap, gpa: Allocator, old: i32) Allocator.Error!struct { id: i32, inserted: bool } {
            if (self.lookup.get(old)) |new_id| return .{ .id = new_id, .inserted = false };
            const new_id: i32 = @intCast(self.lookup.count());
            try self.lookup.put(gpa, old, new_id);
            try self.order.append(gpa, old);
            return .{ .id = new_id, .inserted = true };
        }
    };

    fn sortHashTargets(list: anytype) void {
        if (list.items.len == 0) return;
        const Elem = @TypeOf(list.items[0]);
        std.mem.sortUnstable(Elem, list.items, {}, struct {
            fn less(_: void, a: Elem, b: Elem) bool {
                return a.hash < b.hash or (a.hash == b.hash and a.target < b.target);
            }
        }.less);
        var write: usize = 0;
        for (list.items, 0..) |item, read| {
            if (read == 0 or list.items[write - 1].hash != item.hash or list.items[write - 1].target != item.target) {
                list.items[write] = item;
                write += 1;
            }
        }
        list.shrinkRetainingCapacity(write);
    }

    fn isPartialHashable(self: *GrammarFsmHasher, fsm_index: i32) Allocator.Error!?u64 {
        const gpa = self.allocator;
        var hash_result: u64 = 0;
        const view = self.grammar.perRuleFsm(fsm_index).?;
        const compact = view.compact();
        const start_state = view.startState();
        const offset = self.fsm_state_offsets.items[@intCast(fsm_index)];
        var state_map = try StateIdMap.init(gpa, start_state);
        defer state_map.deinit(gpa);
        var bfs_queue: std.Deque(i32) = .empty;
        defer bfs_queue.deinit(gpa);
        try bfs_queue.pushBack(gpa, start_state);
        var hash_and_target: HashU64TargetList = .empty;
        defer hash_and_target.deinit(gpa);

        while (bfs_queue.popFront()) |current_old_state_id| {
            const is_start = current_old_state_id == start_state;
            const current_new_state_id = state_map.get(current_old_state_id);

            if (view.isEndState(current_old_state_id)) {
                hash_result = hashCombineI32(hash_result, &.{ current_new_state_id, END_STATE_FLAG, END_STATE_FLAG, current_new_state_id });
            } else {
                hash_result = hashCombineI32(hash_result, &.{ current_new_state_id, NOT_END_STATE_FLAG, NOT_END_STATE_FLAG, current_new_state_id });
            }

            var unhashed_rules_count: i32 = 0;
            hash_and_target.clearRetainingCapacity();
            for (self.sorted_edges.items[offset + @as(usize, @intCast(current_old_state_id))].items) |edge| {
                if (edge.isRuleRef()) {
                    const ok = try self.hashRuleLikeEdge(
                        &hash_and_target,
                        &unhashed_rules_count,
                        is_start,
                        fsm_index,
                        edge.refRuleId(),
                        edge.target,
                    );
                    if (!ok) return null;
                } else if (edge.isRepeatRef()) {
                    const info = compact.repeatEdgeInfo(edge.auxIndex());
                    const before_len = hash_and_target.items.len;
                    const ok = try self.hashRuleLikeEdge(
                        &hash_and_target,
                        &unhashed_rules_count,
                        is_start,
                        fsm_index,
                        info.ruleId(),
                        edge.target,
                    );
                    if (!ok) return null;
                    if (hash_and_target.items.len > before_len) {
                        var last = &hash_and_target.items[hash_and_target.items.len - 1];
                        last.hash = hashCombineI32(last.hash, &.{ REPEAT_EDGE_FLAG, info.lower(), info.upper() });
                    }
                }
            }

            sortHashTargets(&hash_and_target);
            for (hash_and_target.items) |candidate| {
                const res = try state_map.getOrInsert(gpa, candidate.target);
                if (res.inserted) try bfs_queue.pushBack(gpa, candidate.target);
                hash_result = hashCombine(hash_result, &.{ @bitCast(@as(i64, current_new_state_id)), candidate.hash, @bitCast(@as(i64, res.id)) });
            }

            for (self.sorted_edges.items[offset + @as(usize, @intCast(current_old_state_id))].items) |edge| {
                const res = try state_map.getOrInsert(gpa, edge.target);
                if (res.inserted) try bfs_queue.pushBack(gpa, edge.target);
                if (edge.isRuleRef() or edge.isRepeatRef()) continue;
                hash_result = hashNonRuleEdge(hash_result, compact, edge, current_new_state_id, res.id);
            }
        }

        const mapping = try sortedMapping(gpa, &state_map);
        gpa.free(self.per_rule_fsm_new_state_ids.items[@intCast(fsm_index)]);
        self.per_rule_fsm_new_state_ids.items[@intCast(fsm_index)] = mapping;
        return hash_result;
    }

    fn hashRuleLikeEdge(
        self: *const GrammarFsmHasher,
        hash_and_target: *HashU64TargetList,
        unhashed_rules_count: *i32,
        is_start: bool,
        fsm_index: i32,
        ref_rule_id: i32,
        target: i32,
    ) Allocator.Error!bool {
        const gpa = self.allocator;
        if (ref_rule_id == fsm_index) {
            try hash_and_target.append(gpa, .{ .hash = @bitCast(@as(i64, SELF_RECURSION_FLAG)), .target = target });
            return true;
        }
        if (self.per_rule_fsm_hashes.items[@intCast(ref_rule_id)] == null) {
            if (!is_start) return false;
            unhashed_rules_count.* += 1;
            if (unhashed_rules_count.* > 1) return false;
            try hash_and_target.append(gpa, .{ .hash = @bitCast(@as(i64, UNKNOWN_FLAG)), .target = target });
            return true;
        }
        const hash = self.per_rule_fsm_hashes.items[@intCast(ref_rule_id)].?;
        try hash_and_target.append(gpa, .{ .hash = hash, .target = target });
        return true;
    }

    fn hashFsm(self: *GrammarFsmHasher, fsm_index: i32) Allocator.Error!u64 {
        const gpa = self.allocator;
        var hash_result: u64 = 0;
        const view = self.grammar.perRuleFsm(fsm_index).?;
        const compact = view.compact();
        const start_state = view.startState();
        const offset = self.fsm_state_offsets.items[@intCast(fsm_index)];
        var state_map = try StateIdMap.init(gpa, start_state);
        defer state_map.deinit(gpa);
        var bfs_queue: std.Deque(i32) = .empty;
        defer bfs_queue.deinit(gpa);
        try bfs_queue.pushBack(gpa, start_state);
        var hash_and_target: HashI32TargetList = .empty;
        defer hash_and_target.deinit(gpa);

        while (bfs_queue.popFront()) |current_old_state_id| {
            const current_new_state_id = state_map.get(current_old_state_id);

            if (view.isEndState(current_old_state_id)) {
                hash_result = hashCombineI32(hash_result, &.{ current_new_state_id, END_STATE_FLAG, END_STATE_FLAG, current_new_state_id });
            } else {
                hash_result = hashCombineI32(hash_result, &.{ current_new_state_id, NOT_END_STATE_FLAG, NOT_END_STATE_FLAG, current_new_state_id });
            }

            hash_and_target.clearRetainingCapacity();
            for (self.sorted_edges.items[offset + @as(usize, @intCast(current_old_state_id))].items) |edge| {
                if (edge.isRuleRef()) {
                    const ref_rule_id = edge.refRuleId();
                    if (ref_rule_id == fsm_index) {
                        try hash_and_target.append(gpa, .{ .hash = SELF_RECURSION_FLAG, .target = edge.target });
                    } else {
                        std.debug.assert(self.per_rule_fsm_hashes.items[@intCast(ref_rule_id)] != null);
                        const hash = self.per_rule_fsm_hashes.items[@intCast(ref_rule_id)].?;
                        try hash_and_target.append(gpa, .{ .hash = foldU64ToI32(hash), .target = edge.target });
                    }
                } else if (edge.isRepeatRef()) {
                    const info = compact.repeatEdgeInfo(edge.auxIndex());
                    const ref_rule_id = info.ruleId();
                    if (ref_rule_id == fsm_index) {
                        const repeat_hash = hashCombineI32(@bitCast(@as(i64, SELF_RECURSION_FLAG)), &.{ REPEAT_EDGE_FLAG, info.lower(), info.upper() });
                        try hash_and_target.append(gpa, .{ .hash = foldU64ToI32(repeat_hash), .target = edge.target });
                    } else {
                        std.debug.assert(self.per_rule_fsm_hashes.items[@intCast(ref_rule_id)] != null);
                        const base_hash = self.per_rule_fsm_hashes.items[@intCast(ref_rule_id)].?;
                        const repeat_hash = hashCombineI32(base_hash, &.{ REPEAT_EDGE_FLAG, info.lower(), info.upper() });
                        try hash_and_target.append(gpa, .{ .hash = foldU64ToI32(repeat_hash), .target = edge.target });
                    }
                }
            }

            sortHashTargets(&hash_and_target);
            for (hash_and_target.items) |candidate| {
                const res = try state_map.getOrInsert(gpa, candidate.target);
                if (res.inserted) try bfs_queue.pushBack(gpa, candidate.target);
                hash_result = hashCombineI32(hash_result, &.{ current_new_state_id, candidate.hash, res.id });
            }

            for (self.sorted_edges.items[offset + @as(usize, @intCast(current_old_state_id))].items) |edge| {
                const res = try state_map.getOrInsert(gpa, edge.target);
                if (res.inserted) try bfs_queue.pushBack(gpa, edge.target);
                if (edge.isRuleRef() or edge.isRepeatRef()) continue;
                hash_result = hashNonRuleEdge(hash_result, compact, edge, current_new_state_id, res.id);
            }
        }

        const mapping = try sortedMapping(gpa, &state_map);
        gpa.free(self.per_rule_fsm_new_state_ids.items[@intCast(fsm_index)]);
        self.per_rule_fsm_new_state_ids.items[@intCast(fsm_index)] = mapping;
        return hash_result;
    }

    fn sortedMapping(gpa: Allocator, state_map: *const StateIdMap) Allocator.Error![]const FsmStatePair {
        const mapping = try gpa.alloc(FsmStatePair, state_map.order.items.len);
        for (state_map.order.items, 0..) |old, i| {
            mapping[i] = .{ .original = old, .normalized = state_map.lookup.get(old).? };
        }
        std.mem.sortUnstable(FsmStatePair, mapping, {}, struct {
            fn less(_: void, a: FsmStatePair, b: FsmStatePair) bool {
                return a.original < b.original;
            }
        }.less);
        return mapping;
    }
};

/// Hashes a sequence expression (e.g. a lookahead assertion) for rule-level cache lookup.
pub fn hashSequence(allocator: Allocator, grammar: *const Grammar, sequence_id: i32) Allocator.Error!?u64 {
    _ = allocator;
    if (sequence_id == NO_EXPR) return null;
    const sequence_expr = grammar.expr(sequence_id);
    std.debug.assert(sequence_expr.ty == .Sequence);
    var hash_result: u64 = 0;
    for (sequence_expr.data) |expr_id| {
        const e = grammar.expr(expr_id);
        hash_result = hashCombineI32(hash_result, &.{ e.ty.asI32(), @intCast(e.data.len) });
        switch (e.ty) {
            .ByteString, .CharacterClass, .CharacterClassStar, .EmptyStr, .Token, .ExcludeToken, .Regex, .Substring => {
                for (e.data) |element| {
                    hash_result = hashCombineI32(hash_result, &.{element});
                }
            },
            .RuleRef => {
                const hash = grammar.perRuleFsmHash(e.data[0]) orelse return null;
                hash_result = hashCombine(hash_result, &.{hash});
            },
            .Repeat => {
                const hash = grammar.perRuleFsmHash(e.data[0]) orelse return null;
                hash_result = hashCombine(hash_result, &.{hash});
                hash_result = hashCombineI32(hash_result, &.{ e.data[1], e.data[2] });
            },
            .Sequence, .Choices, .TagDispatch, .TokenTagDispatch => return null,
        }
    }
    return hash_result;
}

test "fsm_hasher distinguishes grammars and populates state mappings" {
    const gpa = std.testing.allocator;
    const normalizer = @import("normalizer.zig");
    const optimizer = @import("optimizer.zig");

    var g1 = try normalizer.fromEbnf(gpa, "root ::= [a-b]{2,3}", "root", null);
    defer g1.deinit();
    var o1 = try optimizer.optimizeGrammar(gpa, &g1, null);
    defer o1.deinit();
    try apply(gpa, &o1);

    var g2 = try normalizer.fromEbnf(gpa, "root ::= [a-b]{2,4}", "root", null);
    defer g2.deinit();
    var o2 = try optimizer.optimizeGrammar(gpa, &g2, null);
    defer o2.deinit();
    try apply(gpa, &o2);

    const h1 = o1.perRuleFsmHash(0).?;
    const h2 = o2.perRuleFsmHash(0).?;
    try std.testing.expect(h1 != h2);
    try std.testing.expect(o1.fsmNewStateIds(0).len > 0);
}
