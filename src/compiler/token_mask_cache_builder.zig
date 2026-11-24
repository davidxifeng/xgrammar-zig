//! Adaptive token-mask cache builder (`token_mask_cache_builder.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const adaptive_token_mask = @import("AdaptiveTokenMask.zig");
const AdaptiveTokenMask = adaptive_token_mask.AdaptiveTokenMask;
const AdaptiveTokenMaskCache = adaptive_token_mask.AdaptiveTokenMaskCache;
const compileTaskState = adaptive_token_mask.compileTaskState;
const rule_level_cache = @import("rule_level_cache.zig");
const RuleLevelCache = rule_level_cache.RuleLevelCache;
const tag_dispatch_optimization_mod = @import("tag_dispatch_optimization.zig");
const TagDispatchSecondSlicingBitsets = tag_dispatch_optimization_mod.TagDispatchSecondSlicingBitsets;

const functor = @import("../functor.zig");
const grammar_mod = @import("../grammar.zig");
const Grammar = grammar_mod.Grammar;
const NO_EXPR = grammar_mod.NO_EXPR;
const parser_mod = @import("../parser.zig");
const EarleyParser = parser_mod.EarleyParser;
const ParserState = parser_mod.ParserState;
const support = @import("../support.zig");
const DynamicBitset = support.DynamicBitset;
const ThreadSafeAllocator = support.ThreadSafeAllocator;
const commonPrefixLen = support.commonPrefixLen;
const hashCombine = support.hashCombine;
const intsetComplement = support.intsetComplement;
const intsetDifference = support.intsetDifference;
const intsetUnion = support.intsetUnion;
const tokenizer_mod = @import("../tokenizer.zig");
const SortedDecodedToken = tokenizer_mod.SortedDecodedToken;
const TokenizerInfo = tokenizer_mod.TokenizerInfo;

const FirstCharMask = [256]bool;

const Interval = struct {
    start: i32,
    end: i32,
};

/// Earley parser wrapper that builds `AdaptiveTokenMask`s across reachable states
/// of a fixed `Grammar`, reusing a single value-embedded `EarleyParser` and scratch
/// buffers via `resetForState`.
pub const GrammarMatcherForTokenMaskCache = struct {
    allocator: Allocator,
    parser: EarleyParser,
    init_rule_id: i32,
    initial_state: ParserState,
    tag_dispatch_rule_id_to_second_slicing_bitset: *const TagDispatchSecondSlicingBitsets,
    grammar: *const Grammar,
    tokenizer_info: *const TokenizerInfo,
    rule_level_cache: ?*RuleLevelCache,
    tmp_accepted_indices: std.ArrayList(i32),
    tmp_rejected_indices: std.ArrayList(i32),
    tmp_uncertain_indices: std.ArrayList(i32),
    tmp_rejected_by_lookahead_indices: std.ArrayList(i32),
    tmp_accepted_by_lookahead_indices: std.ArrayList(i32),
    tmp_can_reach_end_stack: std.ArrayList(bool),
    tmp_can_reach_end_prefix_or_stack: std.ArrayList(bool),
    tmp_token_edge_accepted: std.ArrayList(i32),
    tmp_token_edge_excluded: std.ArrayList(i32),

    pub fn init(
        allocator: Allocator,
        grammar: *const Grammar,
        init_state: ParserState,
        tag_dispatch_rule_id_to_second_slicing_bitset: *const TagDispatchSecondSlicingBitsets,
        tokenizer_info: *const TokenizerInfo,
        rl_cache: ?*RuleLevelCache,
    ) Allocator.Error!GrammarMatcherForTokenMaskCache {
        const parser = try EarleyParser.init(allocator, grammar, init_state);
        return .{
            .allocator = allocator,
            .parser = parser,
            .init_rule_id = init_state.rule_id,
            .initial_state = init_state,
            .tag_dispatch_rule_id_to_second_slicing_bitset = tag_dispatch_rule_id_to_second_slicing_bitset,
            .grammar = grammar,
            .tokenizer_info = tokenizer_info,
            .rule_level_cache = rl_cache,
            .tmp_accepted_indices = .empty,
            .tmp_rejected_indices = .empty,
            .tmp_uncertain_indices = .empty,
            .tmp_rejected_by_lookahead_indices = .empty,
            .tmp_accepted_by_lookahead_indices = .empty,
            .tmp_can_reach_end_stack = .empty,
            .tmp_can_reach_end_prefix_or_stack = .empty,
            .tmp_token_edge_accepted = .empty,
            .tmp_token_edge_excluded = .empty,
        };
    }

    pub fn deinit(self: *GrammarMatcherForTokenMaskCache) void {
        const a = self.allocator;
        self.parser.deinit();
        self.tmp_accepted_indices.deinit(a);
        self.tmp_rejected_indices.deinit(a);
        self.tmp_uncertain_indices.deinit(a);
        self.tmp_rejected_by_lookahead_indices.deinit(a);
        self.tmp_accepted_by_lookahead_indices.deinit(a);
        self.tmp_can_reach_end_stack.deinit(a);
        self.tmp_can_reach_end_prefix_or_stack.deinit(a);
        self.tmp_token_edge_accepted.deinit(a);
        self.tmp_token_edge_excluded.deinit(a);
        self.* = undefined;
    }

    /// Rebinds this matcher and its embedded `EarleyParser` to `state`, retaining all
    /// grammar-level parser caches and temporary slice capacities.
    pub fn resetForState(self: *GrammarMatcherForTokenMaskCache, state: ParserState) Allocator.Error!void {
        try self.parser.resetWithInitialState(state);
        self.init_rule_id = state.rule_id;
        self.initial_state = state;
        self.tmp_accepted_indices.clearRetainingCapacity();
        self.tmp_rejected_indices.clearRetainingCapacity();
        self.tmp_uncertain_indices.clearRetainingCapacity();
        self.tmp_rejected_by_lookahead_indices.clearRetainingCapacity();
        self.tmp_accepted_by_lookahead_indices.clearRetainingCapacity();
        self.tmp_can_reach_end_stack.clearRetainingCapacity();
        self.tmp_can_reach_end_prefix_or_stack.clearRetainingCapacity();
        self.tmp_token_edge_accepted.clearRetainingCapacity();
        self.tmp_token_edge_excluded.clearRetainingCapacity();
    }

    /// Builds the adaptive token mask for the current initial parser state.
    pub fn getAdaptiveTokenMask(
        self: *GrammarMatcherForTokenMaskCache,
        is_root_rule: bool,
    ) Allocator.Error!AdaptiveTokenMask {
        self.tmp_accepted_indices.clearRetainingCapacity();
        self.tmp_rejected_indices.clearRetainingCapacity();
        self.tmp_uncertain_indices.clearRetainingCapacity();
        self.tmp_rejected_by_lookahead_indices.clearRetainingCapacity();
        self.tmp_accepted_by_lookahead_indices.clearRetainingCapacity();
        self.tmp_can_reach_end_prefix_or_stack.clearRetainingCapacity();
        self.tmp_can_reach_end_stack.clearRetainingCapacity();
        try self.tmp_can_reach_end_stack.append(self.allocator, false);
        try self.tmp_can_reach_end_prefix_or_stack.append(self.allocator, false);

        const rule_level_cache_is_available = !self.parser.has_char_budget_rules and
            self.rule_level_cache != null and
            self.grammar.perRuleFsmHash(self.init_rule_id) != null;

        var fsm_hash: ?u64 = null;
        var new_state_id: i32 = -1;
        const lookahead_id = self.grammar.rule(self.init_rule_id).lookahead_assertion_id;
        const is_exact_lookahead = self.grammar.rule(self.init_rule_id).is_exact_lookahead;
        var lookahead_hash: ?u64 = null;
        var has_repeat_parent_ctx = false;
        var repeat_parent_hash: u64 = 0;
        if (lookahead_id == NO_EXPR and is_exact_lookahead) {
            var repeat_parent_states: std.ArrayList(RepeatParentContinuation) = .empty;
            defer repeat_parent_states.deinit(self.allocator);
            repeat_parent_hash = try collectRepeatParentContinuations(
                self.allocator,
                self.grammar,
                self.init_rule_id,
                &repeat_parent_states,
            );
            has_repeat_parent_ctx = repeat_parent_states.items.len > 0;
        }

        if (rule_level_cache_is_available) {
            lookahead_hash = try functor.hashSequence(self.allocator, self.grammar, lookahead_id);
            const original_to_new_id = self.grammar.fsmNewStateIds(self.init_rule_id);
            fsm_hash = self.grammar.perRuleFsmHash(self.init_rule_id);
            for (original_to_new_id) |pair| {
                if (pair.original == self.initial_state.element_id) {
                    new_state_id = pair.normalized;
                    break;
                }
            }
            std.debug.assert(new_state_id != -1);
            const fsm = self.grammar.perRuleFsm(self.init_rule_id).?;
            const rlc = self.rule_level_cache.?;
            if (lookahead_hash) |lh| {
                const combined_hash = hashCombine(&.{
                    fsm_hash.?,
                    lh,
                    @intFromBool(is_exact_lookahead),
                });
                if (try rlc.getCache(self.allocator, combined_hash, new_state_id, fsm.nodeNum(), fsm.edgeNum())) |cached| {
                    return cached;
                }
            } else if (has_repeat_parent_ctx) {
                const combined_hash = hashCombine(&.{
                    fsm_hash.?,
                    repeat_parent_hash,
                    @intFromBool(true),
                });
                if (try rlc.getCache(self.allocator, combined_hash, new_state_id, fsm.nodeNum(), fsm.edgeNum())) |cached| {
                    return cached;
                }
            }
            if (!has_repeat_parent_ctx) {
                if (try rlc.getCache(self.allocator, fsm_hash.?, new_state_id, fsm.nodeNum(), fsm.edgeNum())) |cached_mut| {
                    var cache = cached_mut;
                    errdefer cache.deinit(self.allocator);
                    try self.adaptCacheWithLookahead(&cache, is_root_rule);
                    return cache;
                }
            }
        }

        var first_character_mask: FirstCharMask = @splat(false);
        self.getFirstCharacterMask(&first_character_mask);

        const token_edge_accepted = try self.takeTokenEdgeAcceptedIndices();

        const has_any_first_char = blk: {
            for (first_character_mask) |b| {
                if (b) break :blk true;
            }
            break :blk false;
        };
        const rejected_filled = if (!has_any_first_char)
            false
        else
            try self.getTokenMaskWithFirstCharacterCheck(&first_character_mask, is_root_rule, token_edge_accepted);

        // Token edges are rechecked at runtime when a character budget is present because
        // accepting one can enter a budgeted rule within the same token.
        if (token_edge_accepted.len != 0) {
            if (self.parser.has_char_budget_rules) {
                try intsetUnion(self.allocator, &self.tmp_uncertain_indices, token_edge_accepted);
            } else {
                try intsetUnion(self.allocator, &self.tmp_accepted_indices, token_edge_accepted);
                intsetDifference(&self.tmp_uncertain_indices, token_edge_accepted);
            }
            intsetDifference(&self.tmp_rejected_indices, token_edge_accepted);
        }

        const sorted = self.tokenizer_info.sortedDecodedVocab();
        const vocab_size = self.tokenizer_info.vocabSize();
        var return_value = if (rejected_filled)
            try AdaptiveTokenMask.fromClassifications(
                self.allocator,
                vocab_size,
                sorted,
                self.tmp_accepted_indices.items,
                self.tmp_rejected_indices.items,
                self.tmp_uncertain_indices.items,
            )
        else
            try AdaptiveTokenMask.fromAcceptedAndUncertain(
                self.allocator,
                vocab_size,
                sorted,
                self.tmp_accepted_indices.items,
                self.tmp_uncertain_indices.items,
            );
        errdefer return_value.deinit(self.allocator);

        if (rule_level_cache_is_available) {
            if (has_repeat_parent_ctx) {
                const fsm = self.grammar.perRuleFsm(self.init_rule_id).?;
                const combined_hash = hashCombine(&.{
                    fsm_hash.?,
                    repeat_parent_hash,
                    @intFromBool(true),
                });
                _ = try self.rule_level_cache.?.addCache(
                    combined_hash,
                    new_state_id,
                    fsm.nodeNum(),
                    fsm.edgeNum(),
                    &return_value,
                );
            } else {
                try self.storeRuleLevelCache(
                    fsm_hash.?,
                    new_state_id,
                    lookahead_id,
                    is_root_rule,
                    is_exact_lookahead,
                    lookahead_hash,
                    &return_value,
                    rejected_filled,
                );
            }
        }
        return return_value;
    }

    fn storeRuleLevelCache(
        self: *GrammarMatcherForTokenMaskCache,
        fsm_hash: u64,
        new_state_id: i32,
        lookahead_id: i32,
        is_root_rule: bool,
        is_exact_lookahead: bool,
        lookahead_hash: ?u64,
        return_value: *const AdaptiveTokenMask,
        rejected_filled: bool,
    ) Allocator.Error!void {
        const rlc = self.rule_level_cache.?;
        const fsm = self.grammar.perRuleFsm(self.init_rule_id).?;
        const sorted = self.tokenizer_info.sortedDecodedVocab();
        const vocab_size = self.tokenizer_info.vocabSize();

        if (lookahead_id == NO_EXPR and !is_root_rule) {
            _ = try rlc.addCache(fsm_hash, new_state_id, fsm.nodeNum(), fsm.edgeNum(), return_value);
            return;
        }

        try intsetUnion(self.allocator, &self.tmp_uncertain_indices, self.tmp_rejected_by_lookahead_indices.items);
        try intsetUnion(self.allocator, &self.tmp_uncertain_indices, self.tmp_accepted_by_lookahead_indices.items);

        var base_mask = if (rejected_filled) blk: {
            var rej_wo = try sortedSetDifference(
                self.allocator,
                self.tmp_rejected_indices.items,
                self.tmp_rejected_by_lookahead_indices.items,
            );
            defer rej_wo.deinit(self.allocator);
            var acc_wo = try sortedSetDifference(
                self.allocator,
                self.tmp_accepted_indices.items,
                self.tmp_accepted_by_lookahead_indices.items,
            );
            defer acc_wo.deinit(self.allocator);
            break :blk try AdaptiveTokenMask.fromClassifications(
                self.allocator,
                vocab_size,
                sorted,
                acc_wo.items,
                rej_wo.items,
                self.tmp_uncertain_indices.items,
            );
        } else blk: {
            var acc_wo = try sortedSetDifference(
                self.allocator,
                self.tmp_accepted_indices.items,
                self.tmp_accepted_by_lookahead_indices.items,
            );
            defer acc_wo.deinit(self.allocator);
            break :blk try AdaptiveTokenMask.fromAcceptedAndUncertain(
                self.allocator,
                vocab_size,
                sorted,
                acc_wo.items,
                self.tmp_uncertain_indices.items,
            );
        };
        defer base_mask.deinit(self.allocator);
        _ = try rlc.addCache(fsm_hash, new_state_id, fsm.nodeNum(), fsm.edgeNum(), &base_mask);

        if (lookahead_hash) |lh| {
            const combined = hashCombine(&.{ fsm_hash, lh, @intFromBool(is_exact_lookahead) });
            _ = try rlc.addCache(combined, new_state_id, fsm.nodeNum(), fsm.edgeNum(), return_value);
        }
    }

    /// Adapts a crossing rule-level cache entry with lookahead.
    fn adaptCacheWithLookahead(
        self: *GrammarMatcherForTokenMaskCache,
        cache: *AdaptiveTokenMask,
        is_root_rule: bool,
    ) Allocator.Error!void {
        const sorted_decoded_vocab = self.tokenizer_info.sortedDecodedVocab();
        const subtree_nodes_range = self.tokenizer_info.trieSubtreeNodesRange();
        const rule = self.grammar.rule(self.init_rule_id);
        const is_exact_lookahead = rule.is_exact_lookahead;

        var prev_token: ?[]const u8 = null;
        var prev_matched_size: i32 = 0;
        var last_rejected_range: i32 = 0;

        self.tmp_rejected_indices.clearRetainingCapacity();
        self.tmp_uncertain_indices.clearRetainingCapacity();
        self.tmp_accepted_indices.clearRetainingCapacity();

        if (is_root_rule) {
            try self.tmp_rejected_indices.appendSlice(self.allocator, cache.uncertain_indices);
        } else {
            const lookahead_id = rule.lookahead_assertion_id;
            if (lookahead_id == NO_EXPR) {
                return;
            }
            for (cache.uncertain_indices) |uncertain_index| {
                const u_idx: usize = @intCast(uncertain_index);
                const token = sorted_decoded_vocab[u_idx].token;
                var accepted = true;

                if (uncertain_index < last_rejected_range) {
                    try self.tmp_rejected_indices.append(self.allocator, uncertain_index);
                    continue;
                }

                if (prev_token) |prev| {
                    const lcp_len = commonPrefixLen(token, prev);
                    if (lcp_len > prev_matched_size) {
                        accepted = false;
                    } else if (lcp_len < prev_matched_size) {
                        const pop_cnt: usize = @intCast(prev_matched_size - lcp_len);
                        self.parser.popLastStates(prev_matched_size - lcp_len);
                        self.tmp_can_reach_end_stack.shrinkRetainingCapacity(self.tmp_can_reach_end_stack.items.len - pop_cnt);
                        self.tmp_can_reach_end_prefix_or_stack.shrinkRetainingCapacity(self.tmp_can_reach_end_prefix_or_stack.items.len - pop_cnt);
                    }
                    prev_matched_size = @min(prev_matched_size, lcp_len);
                }

                prev_token = token;

                if (accepted) {
                    const start_j: usize = @intCast(prev_matched_size);
                    for (token[start_j..], start_j..) |byte, j| {
                        if (!try self.parser.advance(byte)) {
                            accepted = false;
                            break;
                        }
                        const completed = self.parser.isRootCompleted();
                        try self.tmp_can_reach_end_stack.append(self.allocator, completed);
                        const prev_or = self.tmp_can_reach_end_prefix_or_stack.items[self.tmp_can_reach_end_prefix_or_stack.items.len - 1];
                        try self.tmp_can_reach_end_prefix_or_stack.append(self.allocator, completed or prev_or);
                        prev_matched_size = @as(i32, @intCast(j)) + 1;
                    }
                }

                std.debug.assert(self.tmp_can_reach_end_prefix_or_stack.items.len != 0);
                const can_reach_end = self.tmp_can_reach_end_prefix_or_stack.items[self.tmp_can_reach_end_prefix_or_stack.items.len - 1];

                std.debug.assert(!accepted); // "all tokens are at least uncertain"
                if (can_reach_end and prev_matched_size > 0) {
                    const la = try isTokenPassLookaheadAssertion(
                        &self.parser,
                        self.grammar,
                        self.init_rule_id,
                        token,
                        self.tmp_can_reach_end_stack.items,
                    );
                    if (la.accepted) {
                        if (la.can_reach_end or !is_exact_lookahead) {
                            try self.tmp_uncertain_indices.append(self.allocator, uncertain_index);
                        } else {
                            try self.tmp_accepted_indices.append(self.allocator, uncertain_index);
                        }
                    } else {
                        try self.tmp_rejected_indices.append(self.allocator, uncertain_index);
                        last_rejected_range = subtree_nodes_range[u_idx];
                    }
                } else {
                    try self.tmp_rejected_indices.append(self.allocator, uncertain_index);
                    last_rejected_range = subtree_nodes_range[u_idx];
                }
            }
        }

        const new_uncertain: []i32 = if (self.tmp_uncertain_indices.items.len == 0)
            &.{}
        else
            try self.allocator.dupe(i32, self.tmp_uncertain_indices.items);
        if (cache.uncertain_indices.len > 0) self.allocator.free(cache.uncertain_indices);
        cache.uncertain_indices = new_uncertain;

        switch (cache.storage) {
            .accepted => |*acc_slice| {
                if (acc_slice.len + self.tmp_accepted_indices.items.len < AdaptiveTokenMask.USE_BITSET_THRESHOLD) {
                    var list: std.ArrayList(i32) = .empty;
                    defer list.deinit(self.allocator);
                    try list.appendSlice(self.allocator, acc_slice.*);
                    try intsetUnion(self.allocator, &list, self.tmp_accepted_indices.items);
                    if (acc_slice.len > 0) self.allocator.free(acc_slice.*);
                    acc_slice.* = try list.toOwnedSlice(self.allocator);
                } else {
                    var accepted_bitset = try DynamicBitset.init(self.allocator, self.tokenizer_info.vocabSize());
                    errdefer accepted_bitset.deinit(self.allocator);
                    for (acc_slice.*) |idx| {
                        const tid: usize = @intCast(sorted_decoded_vocab[@intCast(idx)].id);
                        accepted_bitset.set(tid, true);
                    }
                    for (self.tmp_accepted_indices.items) |idx| {
                        const tid: usize = @intCast(sorted_decoded_vocab[@intCast(idx)].id);
                        accepted_bitset.set(tid, true);
                    }
                    if (acc_slice.len > 0) self.allocator.free(acc_slice.*);
                    cache.storage = .{ .accepted_bitset = accepted_bitset };
                }
            },
            .rejected => |*rej_slice| {
                if (rej_slice.len + self.tmp_rejected_indices.items.len < AdaptiveTokenMask.USE_BITSET_THRESHOLD) {
                    var list: std.ArrayList(i32) = .empty;
                    defer list.deinit(self.allocator);
                    try list.appendSlice(self.allocator, rej_slice.*);
                    try intsetUnion(self.allocator, &list, self.tmp_rejected_indices.items);
                    if (rej_slice.len > 0) self.allocator.free(rej_slice.*);
                    rej_slice.* = try list.toOwnedSlice(self.allocator);
                } else {
                    var accepted_bitset = try DynamicBitset.init(self.allocator, self.tokenizer_info.vocabSize());
                    errdefer accepted_bitset.deinit(self.allocator);
                    accepted_bitset.setAll();
                    for (self.tokenizer_info.specialTokenIds()) |special_id| {
                        accepted_bitset.reset(@intCast(special_id));
                    }
                    for (cache.uncertain_indices) |idx| {
                        accepted_bitset.reset(@intCast(sorted_decoded_vocab[@intCast(idx)].id));
                    }
                    for (rej_slice.*) |idx| {
                        accepted_bitset.reset(@intCast(sorted_decoded_vocab[@intCast(idx)].id));
                    }
                    for (self.tmp_rejected_indices.items) |idx| {
                        accepted_bitset.reset(@intCast(sorted_decoded_vocab[@intCast(idx)].id));
                    }
                    if (rej_slice.len > 0) self.allocator.free(rej_slice.*);
                    cache.storage = .{ .accepted_bitset = accepted_bitset };
                }
            },
            .accepted_bitset => |*bs| {
                for (self.tmp_accepted_indices.items) |idx| {
                    const tid: usize = @intCast(sorted_decoded_vocab[@intCast(idx)].id);
                    bs.set(tid, true);
                }
            },
        }
    }

    fn getSpeculativeCalculation(self: *const GrammarMatcherForTokenMaskCache) struct { can_apply: bool, mask: FirstCharMask } {
        const rule = self.grammar.rule(self.init_rule_id);
        if (rule.is_lazy) {
            return .{ .can_apply = false, .mask = @splat(false) };
        }
        const rule_body = self.grammar.expr(rule.body_expr_id);
        const fsm = self.grammar.perRuleFsm(self.init_rule_id).?;
        const compact = fsm.compact();

        if (rule_body.ty == .TagDispatch) {
            var speculative_mask: FirstCharMask = @splat(false);
            for (compact.stateEdges(self.initial_state.element_id)) |edge| {
                if (edge.target != fsm.startState()) continue;
                if (!edge.isCharRange()) continue;
                var ch = edge.min;
                while (ch <= edge.max) : (ch += 1) {
                    speculative_mask[@intCast(ch)] = true;
                }
            }
            return .{ .can_apply = true, .mask = speculative_mask };
        }

        var can_be_applied = false;
        var speculative_mask: FirstCharMask = @splat(false);
        std.debug.assert(self.initial_state.element_id < fsm.numStates());
        for (compact.stateEdges(self.initial_state.element_id)) |edge| {
            if (!edge.isCharRange()) continue;
            if (edge.target == self.initial_state.element_id) {
                can_be_applied = true;
                var ch = edge.min;
                while (ch <= edge.max) : (ch += 1) {
                    speculative_mask[@intCast(ch)] = true;
                }
                continue;
            }
            if (fsm.startState() == self.initial_state.element_id) {
                for (compact.stateEdges(edge.target)) |next_edge| {
                    const matches = (next_edge.isRuleRef() and next_edge.refRuleId() == self.init_rule_id) or
                        (next_edge.isRepeatRef() and compact.repeatEdgeInfo(next_edge.auxIndex()).ruleId() == self.init_rule_id);
                    if (matches) {
                        can_be_applied = true;
                        var ch = edge.min;
                        while (ch <= edge.max) : (ch += 1) {
                            speculative_mask[@intCast(ch)] = true;
                        }
                        break;
                    }
                }
            }
        }
        return .{ .can_apply = can_be_applied, .mask = speculative_mask };
    }

    fn getTokenMaskWithFirstCharacterCheck(
        self: *GrammarMatcherForTokenMaskCache,
        first_char_mask: *const FirstCharMask,
        is_root_rule: bool,
        token_edge_accepted: []const i32,
    ) Allocator.Error!bool {
        const sorted_decoded_vocab = self.tokenizer_info.sortedDecodedVocab();
        const subtree_nodes_range = self.tokenizer_info.trieSubtreeNodesRange();
        var possible_intervals: std.ArrayList(Interval) = .empty;
        defer possible_intervals.deinit(self.allocator);
        const possible_token_num = try getPossibleTokenIntervals(
            self.allocator,
            sorted_decoded_vocab,
            first_char_mask,
            &possible_intervals,
        );

        try self.tmp_accepted_indices.ensureUnusedCapacity(self.allocator, @intCast(@max(possible_token_num, 0)));
        var fill_reject_indices =
            (@as(i32, @intCast(sorted_decoded_vocab.len)) - possible_token_num) < @as(i32, @intCast(AdaptiveTokenMask.USE_BITSET_THRESHOLD));

        std.debug.assert(possible_intervals.items.len != 0);

        if (possible_intervals.items[0].start != 0 and fill_reject_indices) {
            var k: i32 = 0;
            while (k < possible_intervals.items[0].start) : (k += 1) {
                try self.tmp_rejected_indices.append(self.allocator, k);
            }
        }

        std.debug.assert(self.init_rule_id != -1 and self.grammar.perRuleFsm(self.init_rule_id) != null);
        const spec = self.getSpeculativeCalculation();
        var speculative_calculation = spec.can_apply;
        const speculative_mask = spec.mask;
        if (self.parser.has_char_budget_rules) {
            speculative_calculation = false;
        }

        var prev_matched_size: i32 = 0;
        var last_rejected_range: i32 = 0;
        const rule = self.grammar.rule(self.init_rule_id);
        const is_exact_lookahead = rule.is_exact_lookahead;
        const definite_accepted_bitset: ?*const DynamicBitset = if (self.grammar.expr(rule.body_expr_id).ty == .TagDispatch) blk: {
            std.debug.assert(self.tag_dispatch_rule_id_to_second_slicing_bitset.contains(self.init_rule_id));
            break :blk self.tag_dispatch_rule_id_to_second_slicing_bitset.get(self.init_rule_id).?;
        } else null;

        var prev_token: ?[]const u8 = null;
        var skip_ptr: usize = 0;
        const skip_size = token_edge_accepted.len;

        for (possible_intervals.items, 0..) |interval, interval_idx| {
            var i = interval.start;
            while (i < interval.end) {
                while (skip_ptr < skip_size and token_edge_accepted[skip_ptr] < i) {
                    skip_ptr += 1;
                }
                if (skip_ptr < skip_size and token_edge_accepted[skip_ptr] == i) {
                    i += 1;
                    continue;
                }

                if (i < last_rejected_range) {
                    if (fill_reject_indices) {
                        try self.tmp_rejected_indices.append(self.allocator, i);
                        fill_reject_indices = self.tmp_rejected_indices.items.len < AdaptiveTokenMask.USE_BITSET_THRESHOLD;
                    } else {
                        i = last_rejected_range - 1;
                    }
                    i += 1;
                    continue;
                }

                const ui: usize = @intCast(i);
                const token = sorted_decoded_vocab[ui].token;

                if (speculative_calculation) {
                    if (definite_accepted_bitset) |definite_bitset| {
                        if (token.len == 0) {
                            try self.tmp_accepted_indices.append(self.allocator, i);
                            i += 1;
                            continue;
                        }
                        if (speculative_mask[token[0]] and definite_bitset.get(ui)) {
                            try self.tmp_accepted_indices.append(self.allocator, i);
                            i += 1;
                            continue;
                        }
                    } else {
                        const all_accepted = blk: {
                            for (token) |ch| {
                                if (!std.ascii.isAscii(ch) or !speculative_mask[ch]) break :blk false;
                            }
                            break :blk true;
                        };
                        if (all_accepted) {
                            try self.tmp_accepted_indices.append(self.allocator, i);
                            i += 1;
                            continue;
                        }
                    }
                }

                var accepted = true;
                if (prev_token) |prev| {
                    const lcp_len = commonPrefixLen(token, prev);
                    if (lcp_len > prev_matched_size) {
                        accepted = false;
                    } else if (lcp_len < prev_matched_size) {
                        const pop_cnt: usize = @intCast(prev_matched_size - lcp_len);
                        self.parser.popLastStates(prev_matched_size - lcp_len);
                        self.tmp_can_reach_end_stack.shrinkRetainingCapacity(self.tmp_can_reach_end_stack.items.len - pop_cnt);
                        self.tmp_can_reach_end_prefix_or_stack.shrinkRetainingCapacity(self.tmp_can_reach_end_prefix_or_stack.items.len - pop_cnt);
                    }
                    prev_matched_size = @min(prev_matched_size, lcp_len);
                }

                prev_token = token;

                if (accepted) {
                    const start_j: usize = @intCast(prev_matched_size);
                    for (token[start_j..], start_j..) |byte, j| {
                        if (!try self.parser.advance(byte)) {
                            accepted = false;
                            break;
                        }
                        const completed = self.parser.isRootCompleted();
                        try self.tmp_can_reach_end_stack.append(self.allocator, completed);
                        const prev_or = self.tmp_can_reach_end_prefix_or_stack.items[self.tmp_can_reach_end_prefix_or_stack.items.len - 1];
                        try self.tmp_can_reach_end_prefix_or_stack.append(self.allocator, completed or prev_or);
                        prev_matched_size = @as(i32, @intCast(j)) + 1;
                    }
                }

                const can_reach_end = self.tmp_can_reach_end_prefix_or_stack.items[self.tmp_can_reach_end_prefix_or_stack.items.len - 1];

                if (accepted) {
                    if (self.parser.hasEnteredCharBudget()) {
                        try self.tmp_uncertain_indices.append(self.allocator, i);
                    } else {
                        try self.tmp_accepted_indices.append(self.allocator, i);
                    }
                } else if (can_reach_end and prev_matched_size > 0) {
                    const la = try isTokenPassLookaheadAssertion(
                        &self.parser,
                        self.grammar,
                        self.init_rule_id,
                        token,
                        self.tmp_can_reach_end_stack.items,
                    );
                    if (!is_root_rule and la.accepted) {
                        if (la.can_reach_end or !is_exact_lookahead or self.parser.hasEnteredCharBudget()) {
                            try self.tmp_uncertain_indices.append(self.allocator, i);
                        } else {
                            try self.tmp_accepted_indices.append(self.allocator, i);
                            try self.tmp_accepted_by_lookahead_indices.append(self.allocator, i);
                        }
                    } else {
                        const end = subtree_nodes_range[ui];
                        var j = i;
                        while (j < end) : (j += 1) {
                            try self.tmp_rejected_indices.append(self.allocator, j);
                            try self.tmp_rejected_by_lookahead_indices.append(self.allocator, j);
                        }
                        i = end - 1;
                    }
                } else if (prev_matched_size > 0 and hasTokenEdgeInLatestStates(self.grammar, self.parser.latestScanableStates())) {
                    // #942: A token whose prefix entered a token-level Token/ExcludeToken state
                    // may finish atomically even though byte-by-byte advancing stopped at the boundary.
                    const mid_ok = try self.parser.advanceAtomicToken(sorted_decoded_vocab[ui].id, 0);
                    if (mid_ok) {
                        self.parser.popLastStates(1);
                        try self.tmp_uncertain_indices.append(self.allocator, i);
                    } else if (fill_reject_indices) {
                        try self.tmp_rejected_indices.append(self.allocator, i);
                        fill_reject_indices = self.tmp_rejected_indices.items.len < AdaptiveTokenMask.USE_BITSET_THRESHOLD;
                    }
                } else {
                    try self.tmp_rejected_indices.append(self.allocator, i);
                    last_rejected_range = subtree_nodes_range[ui];
                    fill_reject_indices = self.tmp_rejected_indices.items.len < AdaptiveTokenMask.USE_BITSET_THRESHOLD;
                }
                i += 1;
            }

            if (interval_idx + 1 != possible_intervals.items.len and fill_reject_indices) {
                const next_interval = possible_intervals.items[interval_idx + 1];
                var j = interval.end;
                while (j < next_interval.start) : (j += 1) {
                    try self.tmp_rejected_indices.append(self.allocator, j);
                }
                fill_reject_indices = self.tmp_rejected_indices.items.len < AdaptiveTokenMask.USE_BITSET_THRESHOLD;
            }
        }

        self.parser.popLastStates(prev_matched_size);

        const last_end = possible_intervals.items[possible_intervals.items.len - 1].end;
        const sorted_len_i32: i32 = @intCast(sorted_decoded_vocab.len);
        if (last_end != sorted_len_i32 and fill_reject_indices) {
            var k = last_end;
            while (k < sorted_len_i32) : (k += 1) {
                try self.tmp_rejected_indices.append(self.allocator, k);
            }
        }

        return fill_reject_indices;
    }

    fn getFirstCharacterMask(self: *const GrammarMatcherForTokenMaskCache, first_character_mask: *FirstCharMask) void {
        @memset(first_character_mask, false);
        const fsm = self.grammar.perRuleFsm(self.init_rule_id).?;
        for (fsm.stateEdges(self.initial_state.element_id)) |edge| {
            if (edge.isCharRange()) {
                var c = edge.min;
                while (c <= edge.max) : (c += 1) {
                    first_character_mask[@intCast(c)] = true;
                }
            }
        }
    }

    fn takeTokenEdgeAcceptedIndices(self: *GrammarMatcherForTokenMaskCache) Allocator.Error![]const i32 {
        self.tmp_token_edge_accepted.clearRetainingCapacity();
        self.tmp_token_edge_excluded.clearRetainingCapacity();

        const fsm = self.grammar.perRuleFsm(self.init_rule_id).?;
        const compact = fsm.compact();
        const edges = compact.stateEdges(self.initial_state.element_id);
        const sorted_size: i32 = @intCast(self.tokenizer_info.sortedDecodedVocab().len);
        const tid_to_sorted = self.tokenizer_info.tokenIdToSortedVocabIndex();
        var has_exclude_token = false;

        for (edges) |edge| {
            if (edge.isToken()) {
                const info = compact.tokenEdgeInfo(edge.auxIndex());
                for (info.tokenIds()) |tid| {
                    if (tid >= 0 and @as(usize, @intCast(tid)) < tid_to_sorted.len) {
                        const sorted_idx = tid_to_sorted[@intCast(tid)];
                        if (sorted_idx >= 0) {
                            try self.tmp_token_edge_accepted.append(self.allocator, sorted_idx);
                        }
                    }
                }
            } else if (edge.isExcludeToken()) {
                has_exclude_token = true;
                const info = compact.excludeTokenEdgeInfo(edge.auxIndex());
                for (info.tokenIds()) |tid| {
                    if (tid >= 0 and @as(usize, @intCast(tid)) < tid_to_sorted.len) {
                        const sorted_idx = tid_to_sorted[@intCast(tid)];
                        if (sorted_idx >= 0) {
                            try self.tmp_token_edge_excluded.append(self.allocator, sorted_idx);
                        }
                    }
                }
            }
        }

        sortAndDedup(&self.tmp_token_edge_accepted);
        if (!has_exclude_token) {
            return self.tmp_token_edge_accepted.items;
        }

        sortAndDedup(&self.tmp_token_edge_excluded);
        intsetDifference(&self.tmp_token_edge_excluded, self.tmp_token_edge_accepted.items);
        const comp = try intsetComplement(self.allocator, sorted_size, self.tmp_token_edge_excluded.items);
        self.tmp_token_edge_accepted.deinit(self.allocator);
        self.tmp_token_edge_accepted = comp;
        return self.tmp_token_edge_accepted.items;
    }
};

/// Builds the adaptive token-mask cache for every scanable reachable FSM state.
///
/// When `max_threads` allows (> 1) and there are at least 4 states to precompute, workers
/// run in parallel across OS threads; each worker owns one reused
/// `GrammarMatcherForTokenMaskCache` backed by a mutex-protected `ThreadSafeAllocator`
/// wrapping `allocator` (and sharing `rl_cache`'s lock when using the same backing allocator).
pub fn buildAdaptiveTokenMaskCache(
    allocator: Allocator,
    grammar: *const Grammar,
    tokenizer_info: *const TokenizerInfo,
    max_threads: ?u32,
    rl_cache: ?*RuleLevelCache,
) Allocator.Error!AdaptiveTokenMaskCache {
    var cache = AdaptiveTokenMaskCache.init(allocator);
    errdefer cache.deinit();

    if (tokenizer_info.vocabSize() == 0) {
        return cache;
    }

    var tag_dispatch_bitsets = try tag_dispatch_optimization_mod.tagDispatchOptimization(allocator, grammar, tokenizer_info);
    defer tag_dispatch_bitsets.deinit();

    const Task = struct {
        state: ParserState,
        is_root_rule: bool,
    };
    var tasks: std.ArrayList(Task) = .empty;
    defer tasks.deinit(allocator);

    const root_rule_id = grammar.rootRuleId();
    const num_rules: i32 = @intCast(grammar.numRules());
    var rule_id: i32 = 0;
    while (rule_id < num_rules) : (rule_id += 1) {
        const rule = grammar.rule(rule_id);
        const sized_fsm = grammar.perRuleFsm(rule_id) orelse unreachable;
        var reachable = try sized_fsm.fsm.reachableStates(allocator);
        defer reachable.deinit();

        var states_list: std.ArrayList(i32) = .empty;
        defer states_list.deinit(allocator);
        var it = reachable.keyIterator();
        while (it.next()) |elem_ptr| {
            if (sized_fsm.isScanableState(elem_ptr.*)) {
                try states_list.append(allocator, elem_ptr.*);
            }
        }
        std.mem.sortUnstable(i32, states_list.items, {}, std.sort.asc(i32));
        for (states_list.items) |element_id| {
            try tasks.append(allocator, .{
                .state = compileTaskState(rule_id, rule.body_expr_id, element_id),
                .is_root_rule = rule_id == root_rule_id,
            });
        }
    }

    if (tasks.items.len == 0) {
        return cache;
    }

    const cpu_count = std.Thread.getCpuCount() catch 1;
    const requested: usize = if (max_threads) |mt|
        (if (mt == 0) cpu_count else @as(usize, mt))
    else
        cpu_count;
    const worker_total = if (requested <= 1 or tasks.items.len < 4) 1 else @min(requested, tasks.items.len);

    if (worker_total <= 1) {
        var matcher = try GrammarMatcherForTokenMaskCache.init(
            allocator,
            grammar,
            tasks.items[0].state,
            &tag_dispatch_bitsets,
            tokenizer_info,
            rl_cache,
        );
        defer matcher.deinit();

        for (tasks.items, 0..) |task, idx| {
            if (idx > 0) {
                try matcher.resetForState(task.state);
            }
            var mask = try matcher.getAdaptiveTokenMask(task.is_root_rule);
            errdefer mask.deinit(allocator);
            try cache.put(task.state.cacheKey(), mask);
        }
        return cache;
    }

    const results = try allocator.alloc(?AdaptiveTokenMask, tasks.items.len);
    defer allocator.free(results);
    @memset(results, null);
    errdefer {
        for (results) |*slot| {
            if (slot.*) |*m| m.deinit(allocator);
        }
    }

    var local_ts: ThreadSafeAllocator = .{ .child = allocator };
    const ts_alloc: Allocator = if (rl_cache) |rlc|
        (if (rlc.sharesBackingAllocator(allocator)) rlc.threadSafeAllocator() else local_ts.allocator())
    else
        local_ts.allocator();

    const ParallelCtx = struct {
        tasks: []const Task,
        results: []?AdaptiveTokenMask,
        grammar: *const Grammar,
        tag_dispatch_bitsets: *const TagDispatchSecondSlicingBitsets,
        tokenizer_info: *const TokenizerInfo,
        rl_cache: ?*RuleLevelCache,
        ts_alloc: Allocator,
        next_idx: std.atomic.Value(usize),
        had_oom: std.atomic.Value(bool),

        fn run(ctx: *@This()) void {
            var maybe_matcher: ?GrammarMatcherForTokenMaskCache = null;
            defer if (maybe_matcher) |*m| m.deinit();

            while (!ctx.had_oom.load(.acquire)) {
                const idx = ctx.next_idx.fetchAdd(1, .monotonic);
                if (idx >= ctx.tasks.len) break;

                const task = ctx.tasks[idx];
                if (maybe_matcher) |*m| {
                    m.resetForState(task.state) catch {
                        ctx.had_oom.store(true, .release);
                        break;
                    };
                } else {
                    maybe_matcher = GrammarMatcherForTokenMaskCache.init(
                        ctx.ts_alloc,
                        ctx.grammar,
                        task.state,
                        ctx.tag_dispatch_bitsets,
                        ctx.tokenizer_info,
                        ctx.rl_cache,
                    ) catch {
                        ctx.had_oom.store(true, .release);
                        break;
                    };
                }

                // `mask` is allocated via `ctx.ts_alloc` (which forwards directly to `allocator`
                // under mutex protection), so ownership transfers to `cache` with no extra copy.
                const mask = maybe_matcher.?.getAdaptiveTokenMask(task.is_root_rule) catch {
                    ctx.had_oom.store(true, .release);
                    break;
                };
                ctx.results[idx] = mask;
            }
        }
    };

    var ctx = ParallelCtx{
        .tasks = tasks.items,
        .results = results,
        .grammar = grammar,
        .tag_dispatch_bitsets = &tag_dispatch_bitsets,
        .tokenizer_info = tokenizer_info,
        .rl_cache = rl_cache,
        .ts_alloc = ts_alloc,
        .next_idx = std.atomic.Value(usize).init(0),
        .had_oom = std.atomic.Value(bool).init(false),
    };

    const extra_threads = worker_total - 1;
    const threads = try allocator.alloc(?std.Thread, extra_threads);
    defer allocator.free(threads);
    @memset(threads, null);

    for (threads) |*slot| {
        slot.* = std.Thread.spawn(.{}, ParallelCtx.run, .{&ctx}) catch null;
    }
    ParallelCtx.run(&ctx);
    for (threads) |slot| {
        if (slot) |t| t.join();
    }

    if (ctx.had_oom.load(.acquire)) {
        return error.OutOfMemory;
    }

    for (tasks.items, 0..) |task, idx| {
        var mask = results[idx] orelse unreachable;
        results[idx] = null;
        errdefer mask.deinit(allocator);
        try cache.put(task.state.cacheKey(), mask);
    }

    return cache;
}

fn sortAndDedup(list: *std.ArrayList(i32)) void {
    if (list.items.len <= 1) return;
    std.mem.sortUnstable(i32, list.items, {}, std.sort.asc(i32));
    var write: usize = 0;
    for (list.items, 0..) |v, read| {
        if (read == 0 or v != list.items[read - 1]) {
            list.items[write] = v;
            write += 1;
        }
    }
    list.items.len = write;
}

/// Returns sorted-vocab index intervals whose first byte falls in `first_char_mask`.
pub fn getPossibleTokenIntervals(
    allocator: Allocator,
    sorted_decoded_vocab: []const SortedDecodedToken,
    first_char_mask: *const FirstCharMask,
    possible_intervals: *std.ArrayList(Interval),
) Allocator.Error!i32 {
    possible_intervals.clearRetainingCapacity();
    var possible_token_num: i32 = 0;
    var matched_size: usize = 0;
    var last_interval_end: ?u8 = null;

    var ch_i: usize = 0;
    while (ch_i <= 255) : (ch_i += 1) {
        const ch: u8 = @intCast(ch_i);
        if (first_char_mask[ch]) {
            if (last_interval_end == null) {
                last_interval_end = ch;
            }
        } else if (last_interval_end) |last_end| {
            const left = lowerBoundSortedVocab(sorted_decoded_vocab, matched_size, &[_]u8{last_end});
            const right = lowerBoundSortedVocab(sorted_decoded_vocab, left, &[_]u8{ch});
            try possible_intervals.append(allocator, .{ .start = @intCast(left), .end = @intCast(right) });
            possible_token_num += @as(i32, @intCast(right)) - @as(i32, @intCast(left));
            matched_size = right;
            last_interval_end = null;
        }
    }

    if (last_interval_end) |last_end| {
        const left = lowerBoundSortedVocab(sorted_decoded_vocab, matched_size, &[_]u8{last_end});
        try possible_intervals.append(allocator, .{ .start = @intCast(left), .end = @intCast(sorted_decoded_vocab.len) });
        possible_token_num += @as(i32, @intCast(sorted_decoded_vocab.len)) - @as(i32, @intCast(left));
    }

    return possible_token_num;
}

fn lowerBoundSortedVocab(
    sorted_decoded_vocab: []const SortedDecodedToken,
    start: usize,
    key: []const u8,
) usize {
    var lo: usize = start;
    var hi: usize = sorted_decoded_vocab.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (std.mem.order(u8, sorted_decoded_vocab[mid].token, key) == .lt) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

pub const LookaheadAssertionResult = struct {
    accepted: bool,
    can_reach_end: bool,
};

pub fn isTokenPassLookaheadAssertion(
    parser: *EarleyParser,
    grammar: *const Grammar,
    init_rule_id: i32,
    token: []const u8,
    can_reach_end_stack: []const bool,
) Allocator.Error!LookaheadAssertionResult {
    var accepted = true;
    var can_reach_end = true;
    const lookahead_assertion_id = grammar.rule(init_rule_id).lookahead_assertion_id;
    if (lookahead_assertion_id == NO_EXPR) {
        if (!grammar.rule(init_rule_id).is_exact_lookahead) {
            return .{ .accepted = accepted, .can_reach_end = can_reach_end };
        }
        // #903: Classify a bounded-repeat body alongside its parent rule's post-repeat states
        // so invalid post-repeat continuations are rejected statically instead of marked uncertain.
        var parent_conts: std.ArrayList(RepeatParentContinuation) = .empty;
        defer parent_conts.deinit(parser.gpa);
        _ = try collectRepeatParentContinuations(parser.gpa, grammar, init_rule_id, &parent_conts);
        if (parent_conts.items.len == 0) {
            return .{ .accepted = accepted, .can_reach_end = can_reach_end };
        }
        return checkRepeatParentLookahead(parser, grammar, init_rule_id, token, can_reach_end_stack, parent_conts.items);
    }

    var lookahead_state = ParserState.init(-1, lookahead_assertion_id, 0, ParserState.NO_PREV_INPUT_POS);
    lookahead_state.budget_deadline = 0;
    try parser.pushStateAndExpand(lookahead_state);
    const token_len: i32 = @intCast(token.len);

    if (parser.isRootCompleted()) {
        parser.popLastStates(1);
        return .{ .accepted = accepted, .can_reach_end = can_reach_end };
    }

    var rev_i: usize = can_reach_end_stack.len;
    while (rev_i > 0) {
        rev_i -= 1;
        if (!can_reach_end_stack[rev_i]) continue;
        const i_i32: i32 = @intCast(rev_i);
        var last_accept_pos: i32 = i_i32 - 1;
        for (token[rev_i..], rev_i..) |byte, pos| {
            if (!try parser.advance(byte)) {
                break;
            }
            last_accept_pos = @intCast(pos);
            if (parser.isRootCompleted()) {
                parser.popLastStates(@as(i32, @intCast(pos)) - i_i32 + 2);
                return .{ .accepted = accepted, .can_reach_end = can_reach_end };
            }
        }
        if (last_accept_pos == token_len - 1) {
            parser.popLastStates(last_accept_pos - i_i32 + 2);
            can_reach_end = false;
            return .{ .accepted = accepted, .can_reach_end = can_reach_end };
        }
        parser.popLastStates(last_accept_pos - i_i32 + 1);
    }

    parser.popLastStates(1);
    can_reach_end = false;
    accepted = false;
    return .{ .accepted = accepted, .can_reach_end = can_reach_end };
}

fn hasTokenEdgeInLatestStates(grammar: *const Grammar, states: []const ParserState) bool {
    for (states) |st| {
        const wse = grammar.perRuleFsm(st.rule_id) orelse continue;
        for (wse.stateEdges(st.element_id)) |edge| {
            if (edge.isExcludeToken() or edge.isToken()) return true;
        }
    }
    return false;
}

const RepeatParentContinuation = struct {
    parent_rule_id: i32,
    parent_body_expr_id: i32,
    target_elem_id: i32,
};

fn collectRepeatParentContinuations(
    gpa: Allocator,
    grammar: *const Grammar,
    body_rule_id: i32,
    out: *std.ArrayList(RepeatParentContinuation),
) Allocator.Error!u64 {
    var hash_val: u64 = 0;
    const num_rules: i32 = @intCast(grammar.numRules());
    var p_id: i32 = 0;
    while (p_id < num_rules) : (p_id += 1) {
        const wse = grammar.perRuleFsm(p_id) orelse continue;
        const compact = wse.compact();
        const parent_body = grammar.rule(p_id).body_expr_id;
        var s: i32 = 0;
        while (s < wse.numStates()) : (s += 1) {
            for (compact.stateEdges(s)) |edge| {
                if (edge.isRuleRef() and edge.refRuleId() == body_rule_id) {
                    out.clearRetainingCapacity();
                    return 0;
                }
                if (edge.isRepeatRef()) {
                    const info = compact.repeatEdgeInfo(edge.auxIndex());
                    if (info.ruleId() == body_rule_id) {
                        try out.append(gpa, .{
                            .parent_rule_id = p_id,
                            .parent_body_expr_id = parent_body,
                            .target_elem_id = edge.target,
                        });
                        const p_hash = grammar.perRuleFsmHash(p_id) orelse @as(u64, @intCast(p_id));
                        hash_val = hashCombine(&.{
                            hash_val,
                            p_hash,
                            @bitCast(@as(i64, edge.target)),
                        });
                    }
                }
            }
        }
    }
    return hash_val;
}

fn checkRepeatParentLookahead(
    parser: *EarleyParser,
    grammar: *const Grammar,
    body_rule_id: i32,
    token: []const u8,
    can_reach_end_stack: []const bool,
    conts: []const RepeatParentContinuation,
) Allocator.Error!LookaheadAssertionResult {
    const body_wse = grammar.perRuleFsm(body_rule_id) orelse
        return .{ .accepted = true, .can_reach_end = true };
    const body_expr_id = grammar.rule(body_rule_id).body_expr_id;
    const body_start = body_wse.startState();

    var frontier: std.ArrayList(usize) = .empty;
    defer frontier.deinit(parser.gpa);
    var visited: std.ArrayList(bool) = .empty;
    defer visited.deinit(parser.gpa);
    try visited.appendNTimes(parser.gpa, false, token.len + 1);

    var idx: usize = can_reach_end_stack.len;
    while (idx > 0) {
        idx -= 1;
        if (can_reach_end_stack[idx] and idx < token.len and !visited.items[idx]) {
            visited.items[idx] = true;
            try frontier.append(parser.gpa, idx);
        }
    }

    var cursor: usize = 0;
    while (cursor < frontier.items.len) : (cursor += 1) {
        const p = frontier.items[cursor];

        // Continuation 1: exiting the Repeat into a parent's post-repeat state.
        for (conts) |cont| {
            const p_state = ParserState.init(cont.parent_rule_id, cont.parent_body_expr_id, cont.target_elem_id, ParserState.NO_PREV_INPUT_POS);
            try parser.pushStateAndExpand(p_state);
            if (parser.isRootCompleted()) {
                parser.popLastStates(1);
                return .{ .accepted = true, .can_reach_end = true };
            }
            var accepted_bytes: i32 = 0;
            var ok = true;
            for (token[p..]) |byte| {
                if (!try parser.advance(byte)) {
                    ok = false;
                    break;
                }
                accepted_bytes += 1;
                if (parser.isRootCompleted()) {
                    parser.popLastStates(accepted_bytes + 1);
                    return .{ .accepted = true, .can_reach_end = true };
                }
            }
            parser.popLastStates(accepted_bytes + 1);
            if (ok) {
                return .{ .accepted = true, .can_reach_end = true };
            }
        }

        // Continuation 2: another repetition of the repeat body rule.
        const body_state = ParserState.init(body_rule_id, body_expr_id, body_start, ParserState.NO_PREV_INPUT_POS);
        try parser.pushStateAndExpand(body_state);
        var body_bytes: i32 = 0;
        var body_full = true;
        for (token[p..], p..) |byte, byte_pos| {
            if (!try parser.advance(byte)) {
                body_full = false;
                break;
            }
            body_bytes += 1;
            const next_pos = byte_pos + 1;
            if (parser.isRootCompleted()) {
                if (next_pos == token.len) {
                    parser.popLastStates(body_bytes + 1);
                    return .{ .accepted = true, .can_reach_end = true };
                }
                if (!visited.items[next_pos]) {
                    visited.items[next_pos] = true;
                    try frontier.append(parser.gpa, next_pos);
                }
            }
        }
        parser.popLastStates(body_bytes + 1);
        if (body_full) {
            return .{ .accepted = true, .can_reach_end = true };
        }
    }

    return .{ .accepted = false, .can_reach_end = false };
}

fn sortedSetDifference(allocator: Allocator, left: []const i32, right: []const i32) Allocator.Error!std.ArrayList(i32) {
    var result: std.ArrayList(i32) = .empty;
    errdefer result.deinit(allocator);
    var left_idx: usize = 0;
    var right_idx: usize = 0;
    while (left_idx < left.len and right_idx < right.len) {
        if (left[left_idx] < right[right_idx]) {
            try result.append(allocator, left[left_idx]);
            left_idx += 1;
        } else if (left[left_idx] > right[right_idx]) {
            right_idx += 1;
        } else {
            left_idx += 1;
            right_idx += 1;
        }
    }
    while (left_idx < left.len) {
        try result.append(allocator, left[left_idx]);
        left_idx += 1;
    }
    return result;
}

test {
    std.testing.refAllDecls(GrammarMatcherForTokenMaskCache);
}
