//! Computes structural hashes for per-rule FSMs (`grammar_fsm_hasher.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_mod = @import("../grammar/mod.zig");
const FsmStatePair = grammar_mod.FsmStatePair;
const Grammar = grammar_mod.Grammar;
const GrammarExprType = grammar_mod.GrammarExprType;
const NO_EXPR = grammar_mod.NO_EXPR;
const fsm_mod = @import("../fsm/mod.zig");
const FsmEdge = fsm_mod.FsmEdge;
const sortEdges = @import("../fsm/fsm_edge.zig").sortEdges;
const allow_empty_rule_analyzer = @import("allow_empty_rule_analyzer.zig");
const support = @import("../support/mod.zig");
const hash_combine_binary = support.hash.hash_combine_binary;

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

fn fold_u64_to_i32(v: u64) i32 {
    const folded: u32 = @truncate(v ^ (v >> 32));
    return @bitCast(folded);
}

fn hash_non_rule_edge(seed: u64, fsm: *const fsm_mod.CompactFsmWithStartEnd, edge: FsmEdge, current_new_state_id: i32, next_new_state_id: i32) u64 {
    if (edge.is_epsilon()) {
        return hash_combine_i32(seed, &.{ EPSILON_EDGE_FLAG, current_new_state_id, next_new_state_id });
    } else if (edge.is_token()) {
        var h = hash_combine_i32(seed, &.{ TOKEN_EDGE_FLAG, current_new_state_id, next_new_state_id });
        const ids = fsm.get_fsm().token_edge_info(edge.aux_index()).token_ids();
        h = hash_combine_i32(h, &.{@intCast(ids.len)});
        return hash_combine_i32(h, ids);
    } else if (edge.is_exclude_token()) {
        var h = hash_combine_i32(seed, &.{ EXCLUDE_TOKEN_EDGE_FLAG, current_new_state_id, next_new_state_id });
        const ids = fsm.get_fsm().exclude_token_edge_info(edge.aux_index()).token_ids();
        h = hash_combine_i32(h, &.{@intCast(ids.len)});
        return hash_combine_i32(h, ids);
    }
    return hash_combine_i32(seed, &.{ CHAR_EDGE_FLAG, current_new_state_id, edge.min, edge.max, next_new_state_id });
}

fn hash_combine(seed: u64, values: []const u64) u64 {
    var result = seed;
    for (values) |value| {
        hash_combine_binary(&result, value);
    }
    return result;
}

fn hash_combine_i32(seed: u64, values: []const i32) u64 {
    var result = seed;
    for (values) |value| {
        // Rust `i32 as u64` sign-extends.
        hash_combine_binary(&result, @bitCast(@as(i64, value)));
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
    defer hasher.deinit_temps();
    try hasher.apply();
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
    /// The worklist of FSMs whose references are all hashed (except possibly a
    /// self-recursion). Maintained incrementally so that the main hashing loop is O(V + E)
    /// instead of rescanning all rules after each hashed FSM.
    ready_queue: std.Deque(i32),

    fn deinit_temps(self: *GrammarFsmHasher) void {
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

    fn apply(self: *GrammarFsmHasher) Allocator.Error!void {
        const gpa = self.allocator;
        const num_rules: usize = @intCast(self.grammar.num_rules());
        try self.per_rule_fsm_hashes.appendNTimes(gpa, null, num_rules);
        try self.per_rule_fsm_new_state_ids.appendNTimes(gpa, &.{}, num_rules);
        try self.visited.appendNTimes(gpa, false, num_rules);
        {
            var offsets = try self.grammar.fsm_state_offsets(gpa);
            defer offsets.deinit(gpa);
            try self.fsm_state_offsets.appendSlice(gpa, offsets.items);
        }

        {
            const referee_to_referrer = try allow_empty_rule_analyzer.rule_ref_graph(gpa, self.grammar);
            defer {
                for (referee_to_referrer) |*refs| refs.deinit(gpa);
                gpa.free(referee_to_referrer);
            }
            try self.ref_graph_from_referee_to_referrer.ensureTotalCapacity(gpa, referee_to_referrer.len);
            for (referee_to_referrer) |refs| {
                var copy: std.ArrayList(i32) = .empty;
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

        // The complete FSM occupies offset 0; per-rule FSMs follow at their offsets. Both
        // the complete FSM and each per-rule FSM's state edge lists are sorted here, so all
        // later hashing sees a deterministic edge order (PORTING: Rust sorts `FsmEdge`
        // by `(min, max, target)` via derived `Ord`).
        {
            const complete = self.grammar.complete_fsm;
            try collect_sorted_edges(self, 0, &complete);
            for (self.grammar.per_rule_fsms_slice(), 0..) |view, rule_id| {
                if (view) |v| {
                    const compact = v.get_fsm().get_fsm();
                    const offset = self.fsm_state_offsets.items[rule_id];
                    try collect_sorted_edges(self, offset, &compact);
                }
            }
        }

        // #963: RegexFsmBuilder can lower large repetitions into new helper rules referenced via
        // FSM RepeatRef/RuleRef edges absent from the AST. Supplement the ref graph from FSM edges.
        for (self.grammar.per_rule_fsms_slice(), 0..) |view_opt, referrer_idx| {
            const view = view_opt orelse continue;
            const referrer: i32 = @intCast(referrer_idx);
            const fsm = view.get_fsm();
            const compact = fsm.get_fsm();
            var reachable = try fsm.reachable_states();
            defer reachable.deinit();
            var it = reachable.keyIterator();
            while (it.next()) |s_ptr| {
                for (compact.state_edges(s_ptr.*)) |edge| {
                    const referee: i32 = if (edge.is_rule_ref())
                        edge.ref_rule_id()
                    else if (edge.is_repeat_ref())
                        compact.repeat_edge_info(edge.aux_index()).rule_id()
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

        for (self.grammar.per_rule_fsms_slice(), 0..) |view, i| {
            if (view == null) self.visited.items[i] = true;
        }

        // Hash the FSMs which can be hashed: terminal FSMs, or self-recursion FSMs. When no
        // FSM is ready, try to break a simple cycle in the reference graph and continue.
        for (0..num_rules) |rule_id| {
            if (self.is_ready_to_hash(@intCast(rule_id))) try self.ready_queue.pushBack(gpa, @intCast(rule_id));
        }
        while (true) {
            const current_operating_index = self.ready_queue.popFront() orelse {
                if (!try self.find_simple_cycle()) break;
                continue;
            };
            // Skip stale entries: an FSM may be pushed multiple times before it is processed.
            if (!self.is_ready_to_hash(current_operating_index)) continue;
            self.visited.items[@intCast(current_operating_index)] = true;
            const hash_value = try self.hash_fsm(current_operating_index);
            self.per_rule_fsm_hashes.items[@intCast(current_operating_index)] = hash_value;
            try self.remove_hashed_fsm_from_ref_graph(current_operating_index);
        }

        var partial_hashed_list: std.ArrayList(struct { rule_id: i32, hash: u64 }) = .empty;
        defer partial_hashed_list.deinit(gpa);
        for (0..@intCast(self.grammar.num_rules())) |rule_id| {
            if (self.per_rule_fsm_hashes.items[rule_id] != null) continue;
            const view = self.grammar.per_rule_fsm(@intCast(rule_id)) orelse continue;
            const start = view.get_fsm().get_start();
            if (self.has_inward_edges.items[self.fsm_state_offsets.items[rule_id] + @as(usize, @intCast(start))]) continue;
            if (try self.is_partial_hashable(@intCast(rule_id))) |hash_value| {
                try partial_hashed_list.append(gpa, .{ .rule_id = @intCast(rule_id), .hash = hash_value });
            }
        }
        for (partial_hashed_list.items) |entry| {
            self.per_rule_fsm_hashes.items[@intCast(entry.rule_id)] = entry.hash;
        }

        try self.grammar.set_fsm_hash_data(
            self.per_rule_fsm_hashes.items,
            self.per_rule_fsm_new_state_ids.items,
        );
    }

    /// Sorts `compact`'s per-state edges into `sorted_edges` at `offset`, updating
    /// `has_inward_edges`. Only contiguous offsets land in the table (Rust skips a gap).
    fn collect_sorted_edges(self: *GrammarFsmHasher, offset: usize, compact: *const fsm_mod.CompactFsm) Allocator.Error!void {
        if (offset != self.sorted_edges.items.len) return;
        try self.has_inward_edges.resize(self.allocator, offset + @as(usize, @intCast(compact.num_states())));
        for (self.has_inward_edges.items[@min(self.has_inward_edges.items.len, offset)..]) |*b| b.* = false;
        for (0..@intCast(compact.num_states())) |state| {
            var edges: std.ArrayList(FsmEdge) = .empty;
            try edges.appendSlice(self.allocator, compact.state_edges(@intCast(state)));
            sortEdges(edges.items);
            for (edges.items) |edge| {
                self.has_inward_edges.items[offset + @as(usize, @intCast(edge.target))] = true;
            }
            try self.sorted_edges.append(self.allocator, edges);
        }
    }

    fn find_simple_cycle(self: *GrammarFsmHasher) Allocator.Error!bool {
        const gpa = self.allocator;
        const not_simple_cycle = try gpa.dupe(bool, self.visited.items);
        defer gpa.free(not_simple_cycle);
        // Allocated once and cleaned up after each walk, to avoid an O(num_rules)
        // allocation per start.
        var in_stack = try gpa.alloc(bool, self.ref_graph_from_referee_to_referrer.items.len);
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
                std.debug.assert(current_fsm_index != next); // Self-recursion cycle found in the reference graph, which is not allowed.
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
                try self.hash_simple_cycle(simple_cycle.items);
                return true;
            }
            // Without a cycle nothing was popped, so the stack holds every walked state.
            for (dfs_stack.items) |state| {
                in_stack[@intCast(state)] = false;
            }
        }
        return false;
    }

    fn hash_simple_cycle(self: *GrammarFsmHasher, simple_cycle: []const i32) Allocator.Error!void {
        const gpa = self.allocator;
        for (simple_cycle) |cycle_id| {
            self.visited.items[@intCast(cycle_id)] = true;
            self.per_rule_fsm_hashes.items[@intCast(cycle_id)] = @bitCast(@as(i64, SIMPLE_CYCLE_FLAG));
        }

        var local_cycle_hash: std.ArrayList(u64) = .empty;
        defer local_cycle_hash.deinit(gpa);
        for (simple_cycle) |cycle_id| {
            try local_cycle_hash.append(gpa, try self.hash_fsm(cycle_id));
        }
        const local_cycle_hash_copy = try gpa.dupe(u64, local_cycle_hash.items);
        defer gpa.free(local_cycle_hash_copy);
        for (0..local_cycle_hash.items.len) |i| {
            var current_hash: u64 = 0;
            for (0..local_cycle_hash.items.len) |j| {
                current_hash = hash_combine(current_hash, &.{local_cycle_hash_copy[(i + j) % local_cycle_hash.items.len]});
            }
            local_cycle_hash.items[i] = current_hash;
        }

        for (simple_cycle, 0..) |cycle_id, i| {
            self.per_rule_fsm_hashes.items[@intCast(cycle_id)] = local_cycle_hash.items[i];
            try self.remove_hashed_fsm_from_ref_graph(cycle_id);
        }
    }

    /// Whether an FSM is not hashed yet and references no unhashed FSM other than itself.
    fn is_ready_to_hash(self: *GrammarFsmHasher, fsm_index: i32) bool {
        const referees = &self.ref_graph_from_referrer_to_referee.items[@intCast(fsm_index)];
        if (self.visited.items[@intCast(fsm_index)]) return false;
        if (referees.items.len == 0) return true;
        return referees.items.len == 1 and referees.items[0] == fsm_index;
    }

    /// Removes a hashed FSM from the reference graph, queueing the referrers that become
    /// ready.
    fn remove_hashed_fsm_from_ref_graph(self: *GrammarFsmHasher, fsm_index: i32) Allocator.Error!void {
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
            if (self.is_ready_to_hash(referer)) {
                try self.ready_queue.pushBack(self.allocator, referer);
            }
        }
    }

    /// Per-state `(hash, target)` candidates, iterated in sorted order (Rust `BTreeSet`).
    const HashI32TargetList = std.ArrayList(struct { hash: i32, target: i32 });
    const HashU64TargetList = std.ArrayList(struct { hash: u64, target: i32 });

    /// The per-rule mapping state: old id → new id (new ids assigned in BFS discovery
    /// order, like Rust inserts into a `BTreeMap` and sizes by entry count); the output
    /// mapping is emitted sorted by old id (Rust `BTreeMap` iteration order).
    const StateIdMap = struct {
        lookup: std.AutoHashMap(i32, i32),
        order: std.ArrayList(i32),

        fn init(gpa: Allocator, start: i32) Allocator.Error!StateIdMap {
            var map = StateIdMap{ .lookup = std.AutoHashMap(i32, i32).init(gpa), .order = .empty };
            try map.lookup.put(start, 0);
            try map.order.append(gpa, start);
            return map;
        }

        fn deinit(self: *StateIdMap, gpa: Allocator) void {
            self.lookup.deinit();
            self.order.deinit(gpa);
        }

        fn contains(self: *const StateIdMap, old: i32) bool {
            return self.lookup.contains(old);
        }

        fn get(self: *const StateIdMap, old: i32) i32 {
            return self.lookup.get(old).?;
        }

        fn get_or_insert(self: *StateIdMap, gpa: Allocator, old: i32) Allocator.Error!struct { id: i32, inserted: bool } {
            if (self.lookup.get(old)) |new_id| return .{ .id = new_id, .inserted = false };
            const new_id: i32 = @intCast(self.lookup.count());
            try self.lookup.put(old, new_id);
            try self.order.append(gpa, old);
            return .{ .id = new_id, .inserted = true };
        }
    };

    /// Sorts and dedups `(hash, target)` candidates (Rust `BTreeSet` iteration).
    fn sort_hash_targets(list: anytype) void {
        const Elem = @TypeOf(list.items[0]);
        std.mem.sort(Elem, list.items, {}, struct {
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

    fn is_partial_hashable(self: *GrammarFsmHasher, fsm_index: i32) Allocator.Error!?u64 {
        const gpa = self.allocator;
        var hash_result: u64 = 0;
        const view = self.grammar.per_rule_fsm(fsm_index).?;
        const wse = view.get_fsm();
        const offset = self.fsm_state_offsets.items[@intCast(fsm_index)];
        var state_map = try StateIdMap.init(gpa, wse.get_start());
        defer state_map.deinit(gpa);
        var bfs_queue: std.Deque(i32) = .empty;
        defer bfs_queue.deinit(gpa);
        try bfs_queue.pushBack(gpa, wse.get_start());
        var hash_and_target = HashU64TargetList.empty;
        defer hash_and_target.deinit(gpa);

        while (bfs_queue.popFront()) |current_old_state_id| {
            const is_start = current_old_state_id == wse.get_start();
            const current_new_state_id = state_map.get(current_old_state_id);

            if (wse.is_end_state(current_old_state_id)) {
                hash_result = hash_combine_i32(hash_result, &.{ current_new_state_id, END_STATE_FLAG, END_STATE_FLAG, current_new_state_id });
            } else {
                hash_result = hash_combine_i32(hash_result, &.{ current_new_state_id, NOT_END_STATE_FLAG, NOT_END_STATE_FLAG, current_new_state_id });
            }

            var unhashed_rules_count: i32 = 0;
            hash_and_target.clearRetainingCapacity();
            for (self.sorted_edges.items[offset + @as(usize, @intCast(current_old_state_id))].items) |edge| {
                if (edge.is_rule_ref()) {
                    const ok = try hash_rule_like_edge(
                        self,
                        &hash_and_target,
                        &unhashed_rules_count,
                        is_start,
                        fsm_index,
                        edge.ref_rule_id(),
                        edge.target,
                    );
                    if (!ok) return null;
                } else if (edge.is_repeat_ref()) {
                    const info = wse.get_fsm().repeat_edge_info(edge.aux_index());
                    const before_len = hash_and_target.items.len;
                    const ok = try hash_rule_like_edge(
                        self,
                        &hash_and_target,
                        &unhashed_rules_count,
                        is_start,
                        fsm_index,
                        info.rule_id(),
                        edge.target,
                    );
                    if (!ok) return null;
                    if (hash_and_target.items.len > before_len) {
                        var last = &hash_and_target.items[hash_and_target.items.len - 1];
                        last.hash = hash_combine_i32(last.hash, &.{ REPEAT_EDGE_FLAG, info.lower(), info.upper() });
                    }
                }
            }

            sort_hash_targets(&hash_and_target);
            for (hash_and_target.items) |candidate| {
                const res = try state_map.get_or_insert(gpa, candidate.target);
                if (res.inserted) try bfs_queue.pushBack(gpa, candidate.target);
                hash_result = hash_combine(hash_result, &.{ @bitCast(@as(i64, current_new_state_id)), candidate.hash, @bitCast(@as(i64, res.id)) });
            }

            for (self.sorted_edges.items[offset + @as(usize, @intCast(current_old_state_id))].items) |edge| {
                const res = try state_map.get_or_insert(gpa, edge.target);
                if (res.inserted) try bfs_queue.pushBack(gpa, edge.target);
                if (edge.is_rule_ref() or edge.is_repeat_ref()) continue;
                hash_result = hash_non_rule_edge(hash_result, wse, edge, current_new_state_id, res.id);
            }
        }

        const mapping = try sorted_mapping(gpa, &state_map);
        gpa.free(self.per_rule_fsm_new_state_ids.items[@intCast(fsm_index)]);
        self.per_rule_fsm_new_state_ids.items[@intCast(fsm_index)] = mapping;
        return hash_result;
    }

    /// The local shape of Rust's `hash_rule_like_edge` closure: returns whether the
    /// rule-like edge can contribute, recording its `(hash, target)` candidate.
    fn hash_rule_like_edge(
        self: *GrammarFsmHasher,
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
        const hash: u64 = self.per_rule_fsm_hashes.items[@intCast(ref_rule_id)].?;
        try hash_and_target.append(gpa, .{ .hash = hash, .target = target });
        return true;
    }

    fn hash_fsm(self: *GrammarFsmHasher, fsm_index: i32) Allocator.Error!u64 {
        const gpa = self.allocator;
        var hash_result: u64 = 0;
        const view = self.grammar.per_rule_fsm(fsm_index).?;
        const wse = view.get_fsm();
        const offset = self.fsm_state_offsets.items[@intCast(fsm_index)];
        var state_map = try StateIdMap.init(gpa, wse.get_start());
        defer state_map.deinit(gpa);
        var bfs_queue: std.Deque(i32) = .empty;
        defer bfs_queue.deinit(gpa);
        try bfs_queue.pushBack(gpa, wse.get_start());
        var hash_and_target = HashI32TargetList.empty;
        defer hash_and_target.deinit(gpa);

        while (bfs_queue.popFront()) |current_old_state_id| {
            const current_new_state_id = state_map.get(current_old_state_id);

            if (wse.is_end_state(current_old_state_id)) {
                hash_result = hash_combine_i32(hash_result, &.{ current_new_state_id, END_STATE_FLAG, END_STATE_FLAG, current_new_state_id });
            } else {
                hash_result = hash_combine_i32(hash_result, &.{ current_new_state_id, NOT_END_STATE_FLAG, NOT_END_STATE_FLAG, current_new_state_id });
            }

            hash_and_target.clearRetainingCapacity();
            for (self.sorted_edges.items[offset + @as(usize, @intCast(current_old_state_id))].items) |edge| {
                if (edge.is_rule_ref()) {
                    const ref_rule_id = edge.ref_rule_id();
                    if (ref_rule_id == fsm_index) {
                        try hash_and_target.append(gpa, .{ .hash = SELF_RECURSION_FLAG, .target = edge.target });
                    } else {
                        std.debug.assert(self.per_rule_fsm_hashes.items[@intCast(ref_rule_id)] != null);
                        const hash: u64 = self.per_rule_fsm_hashes.items[@intCast(ref_rule_id)].?;
                        try hash_and_target.append(gpa, .{ .hash = fold_u64_to_i32(hash), .target = edge.target });
                    }
                } else if (edge.is_repeat_ref()) {
                    const info = wse.get_fsm().repeat_edge_info(edge.aux_index());
                    const ref_rule_id = info.rule_id();
                    if (ref_rule_id == fsm_index) {
                        const repeat_hash = hash_combine_i32(@bitCast(@as(i64, SELF_RECURSION_FLAG)), &.{ REPEAT_EDGE_FLAG, info.lower(), info.upper() });
                        try hash_and_target.append(gpa, .{ .hash = fold_u64_to_i32(repeat_hash), .target = edge.target });
                    } else {
                        std.debug.assert(self.per_rule_fsm_hashes.items[@intCast(ref_rule_id)] != null);
                        const base_hash: u64 = self.per_rule_fsm_hashes.items[@intCast(ref_rule_id)].?;
                        const repeat_hash = hash_combine_i32(base_hash, &.{ REPEAT_EDGE_FLAG, info.lower(), info.upper() });
                        try hash_and_target.append(gpa, .{ .hash = fold_u64_to_i32(repeat_hash), .target = edge.target });
                    }
                }
            }

            sort_hash_targets(&hash_and_target);
            for (hash_and_target.items) |candidate| {
                const res = try state_map.get_or_insert(gpa, candidate.target);
                if (res.inserted) try bfs_queue.pushBack(gpa, candidate.target);
                hash_result = hash_combine_i32(hash_result, &.{ current_new_state_id, candidate.hash, res.id });
            }

            for (self.sorted_edges.items[offset + @as(usize, @intCast(current_old_state_id))].items) |edge| {
                const res = try state_map.get_or_insert(gpa, edge.target);
                if (res.inserted) try bfs_queue.pushBack(gpa, edge.target);
                if (edge.is_rule_ref() or edge.is_repeat_ref()) continue;
                hash_result = hash_non_rule_edge(hash_result, wse, edge, current_new_state_id, res.id);
            }
        }

        const mapping = try sorted_mapping(gpa, &state_map);
        gpa.free(self.per_rule_fsm_new_state_ids.items[@intCast(fsm_index)]);
        self.per_rule_fsm_new_state_ids.items[@intCast(fsm_index)] = mapping;
        return hash_result;
    }

    /// Emits `state_map` sorted by old id (Rust collects a `BTreeMap`).
    fn sorted_mapping(gpa: Allocator, state_map: *const StateIdMap) Allocator.Error![]const FsmStatePair {
        const mapping = try gpa.alloc(FsmStatePair, state_map.order.items.len);
        for (state_map.order.items, 0..) |old, i| {
            mapping[i] = .{ .original = old, .normalized = state_map.lookup.get(old).? };
        }
        std.mem.sort(FsmStatePair, mapping, {}, struct {
            fn less(_: void, a: FsmStatePair, b: FsmStatePair) bool {
                return a.original < b.original;
            }
        }.less);
        return mapping;
    }
};

/// Hashes a sequence expression for rule-level cache lookup.
pub fn hash_sequence(allocator: Allocator, grammar: *const Grammar, sequence_id: i32) Allocator.Error!?u64 {
    _ = allocator;
    if (sequence_id == NO_EXPR) return null;
    const sequence_expr = grammar.expr(sequence_id);
    std.debug.assert(sequence_expr.ty == .Sequence); // GrammarExpr is not a sequence
    var hash_result: u64 = 0;
    for (sequence_expr.data) |expr_id| {
        const expr = grammar.expr(expr_id);
        hash_result = hash_combine_i32(hash_result, &.{ expr.ty.as_i32(), @intCast(expr.data.len) });
        switch (expr.ty) {
            .ByteString, .CharacterClass, .CharacterClassStar, .EmptyStr, .Token, .ExcludeToken, .Regex, .Substring => {
                for (expr.data) |element| {
                    hash_result = hash_combine_i32(hash_result, &.{element});
                }
            },
            .RuleRef => {
                const hash = grammar.per_rule_fsm_hash(expr.data[0]) orelse return null;
                hash_result = hash_combine(hash_result, &.{hash});
            },
            .Repeat => {
                const hash = grammar.per_rule_fsm_hash(expr.data[0]) orelse return null;
                hash_result = hash_combine(hash_result, &.{hash});
                hash_result = hash_combine_i32(hash_result, &.{ expr.data[1], expr.data[2] });
            },
            .Sequence, .Choices, .TagDispatch, .TokenTagDispatch => return null,
        }
    }
    return hash_result;
}
