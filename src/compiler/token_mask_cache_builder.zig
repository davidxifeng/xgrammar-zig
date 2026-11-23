//! Adaptive token-mask cache builder (`token_mask_cache_builder.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const adaptive_token_mask = @import("adaptive_token_mask.zig");
const AdaptiveTokenMask = adaptive_token_mask.AdaptiveTokenMask;
const AdaptiveTokenMaskStoreType = adaptive_token_mask.AdaptiveTokenMaskStoreType;
const rule_level_cache = @import("rule_level_cache.zig");
const RuleLevelCache = rule_level_cache.RuleLevelCache;
const tag_dispatch_optimization_mod = @import("tag_dispatch_optimization.zig");
const TagDispatchSecondSlicingBitsets = tag_dispatch_optimization_mod.TagDispatchSecondSlicingBitsets;

const functor = @import("../functor/mod.zig");
const grammar_mod = @import("../grammar/mod.zig");
const Grammar = grammar_mod.Grammar;
const GrammarExprType = grammar_mod.GrammarExprType;
const NO_EXPR = grammar_mod.NO_EXPR;
const parser_mod = @import("../parser/mod.zig");
const EarleyError = parser_mod.earley_parser.EarleyError;
const EarleyParser = parser_mod.EarleyParser;
const ParserState = parser_mod.ParserState;
const support = @import("../support/mod.zig");
const DynamicBitset = support.DynamicBitset;
const common_prefix_len = support.common_prefix_len;
const hash_combine = support.hash_combine;
const intset_complement = support.intset_complement;
const intset_difference = support.intset_difference;
const intset_union = support.intset_union;
const tokenizer_mod = @import("../tokenizer/mod.zig");
const SortedDecodedToken = tokenizer_mod.tokenizer_info.SortedDecodedToken;
const TokenizerInfo = tokenizer_mod.tokenizer_info.TokenizerInfo;

const FirstCharMask = [256]bool;

const Interval = struct {
    start: i32,
    end: i32,
};

fn unwrap_earley_bool(res: EarleyError!bool) Allocator.Error!bool {
    return res catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}

fn unwrap_earley_void(res: EarleyError!void) Allocator.Error!void {
    return res catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}

/// Earley parser wrapper that builds one `AdaptiveTokenMask` for a fixed initial state.
pub const GrammarMatcherForTokenMaskCache = struct {
    allocator: Allocator,
    parser: *EarleyParser,
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
        const parser = EarleyParser.new(allocator, grammar, init_state) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };
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
    }

    /// Builds the adaptive token mask for the seeded parser state.
    pub fn get_adaptive_token_mask(
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
            self.grammar.per_rule_fsm_hash(self.init_rule_id) != null;

        var fsm_hash: ?u64 = null;
        var new_state_id: i32 = -1;
        const lookahead_id = self.grammar.rule(self.init_rule_id).lookahead_assertion_id;
        const is_exact_lookahead = self.grammar.rule(self.init_rule_id).is_exact_lookahead;
        var lookahead_hash: ?u64 = null;

        if (rule_level_cache_is_available) {
            lookahead_hash = try functor.grammar_fsm_hash_sequence(self.allocator, self.grammar, lookahead_id);
            const original_to_new_id = self.grammar.fsm_new_state_ids(self.init_rule_id);
            fsm_hash = self.grammar.per_rule_fsm_hash(self.init_rule_id);
            for (original_to_new_id) |pair| {
                if (pair.original == self.initial_state.element_id) {
                    new_state_id = pair.normalized;
                    break;
                }
            }
            std.debug.assert(new_state_id != -1);
            const fsm = self.grammar.per_rule_fsm(self.init_rule_id).?;
            const rlc = self.rule_level_cache.?;
            if (lookahead_hash) |lh| {
                const combined_hash = hash_combine(&.{
                    fsm_hash.?,
                    lh,
                    @intFromBool(is_exact_lookahead),
                });
                if (try rlc.get_cache(self.allocator, combined_hash, new_state_id, fsm.get_node_num(), fsm.get_edge_num())) |cached| {
                    return cached;
                }
            }
            if (try rlc.get_cache(self.allocator, fsm_hash.?, new_state_id, fsm.get_node_num(), fsm.get_edge_num())) |cached_mut| {
                var cache = cached_mut;
                errdefer cache.deinit();
                try self.adapt_cache_with_lookahead(&cache, is_root_rule);
                return cache;
            }
        }

        var first_character_mask: FirstCharMask = @splat(false);
        self.get_first_character_mask(&first_character_mask);

        const token_edge_accepted = try self.take_token_edge_accepted_indices();

        const has_any_first_char = blk: {
            for (first_character_mask) |b| {
                if (b) break :blk true;
            }
            break :blk false;
        };
        const rejected_filled = if (!has_any_first_char)
            false
        else
            try self.get_token_mask_with_first_character_check(&first_character_mask, is_root_rule, token_edge_accepted);

        // Token edges are rechecked at runtime when a character budget is present because
        // accepting one can enter a budgeted rule within the same token.
        if (token_edge_accepted.len != 0) {
            if (self.parser.has_char_budget_rules) {
                try intset_union(self.allocator, &self.tmp_uncertain_indices, token_edge_accepted);
            } else {
                try intset_union(self.allocator, &self.tmp_accepted_indices, token_edge_accepted);
                intset_difference(&self.tmp_uncertain_indices, token_edge_accepted);
            }
            intset_difference(&self.tmp_rejected_indices, token_edge_accepted);
        }

        const sorted = self.tokenizer_info.sorted_decoded_vocab;
        const vocab_size: usize = @intCast(self.tokenizer_info.vocab_size);
        var return_value = if (rejected_filled)
            try AdaptiveTokenMask.from_classifications(
                self.allocator,
                vocab_size,
                sorted,
                self.tmp_accepted_indices.items,
                self.tmp_rejected_indices.items,
                self.tmp_uncertain_indices.items,
            )
        else
            try AdaptiveTokenMask.from_accepted_and_uncertain(
                self.allocator,
                vocab_size,
                sorted,
                self.tmp_accepted_indices.items,
                self.tmp_uncertain_indices.items,
            );
        errdefer return_value.deinit();

        if (rule_level_cache_is_available) {
            try self.store_rule_level_cache(
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
        return return_value;
    }

    fn store_rule_level_cache(
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
        const fsm = self.grammar.per_rule_fsm(self.init_rule_id).?;
        const sorted = self.tokenizer_info.sorted_decoded_vocab;
        const vocab_size: usize = @intCast(self.tokenizer_info.vocab_size);

        if (lookahead_id == NO_EXPR and !is_root_rule) {
            _ = try rlc.add_cache(fsm_hash, new_state_id, fsm.get_node_num(), fsm.get_edge_num(), return_value);
            return;
        }

        try intset_union(self.allocator, &self.tmp_uncertain_indices, self.tmp_rejected_by_lookahead_indices.items);
        try intset_union(self.allocator, &self.tmp_uncertain_indices, self.tmp_accepted_by_lookahead_indices.items);

        var base_mask = if (rejected_filled) blk: {
            var rej_wo = try sorted_set_difference(
                self.allocator,
                self.tmp_rejected_indices.items,
                self.tmp_rejected_by_lookahead_indices.items,
            );
            defer rej_wo.deinit(self.allocator);
            var acc_wo = try sorted_set_difference(
                self.allocator,
                self.tmp_accepted_indices.items,
                self.tmp_accepted_by_lookahead_indices.items,
            );
            defer acc_wo.deinit(self.allocator);
            break :blk try AdaptiveTokenMask.from_classifications(
                self.allocator,
                vocab_size,
                sorted,
                acc_wo.items,
                rej_wo.items,
                self.tmp_uncertain_indices.items,
            );
        } else blk: {
            var acc_wo = try sorted_set_difference(
                self.allocator,
                self.tmp_accepted_indices.items,
                self.tmp_accepted_by_lookahead_indices.items,
            );
            defer acc_wo.deinit(self.allocator);
            break :blk try AdaptiveTokenMask.from_accepted_and_uncertain(
                self.allocator,
                vocab_size,
                sorted,
                acc_wo.items,
                self.tmp_uncertain_indices.items,
            );
        };
        defer base_mask.deinit();
        _ = try rlc.add_cache(fsm_hash, new_state_id, fsm.get_node_num(), fsm.get_edge_num(), &base_mask);

        if (lookahead_hash) |lh| {
            const combined = hash_combine(&.{ fsm_hash, lh, @intFromBool(is_exact_lookahead) });
            _ = try rlc.add_cache(combined, new_state_id, fsm.get_node_num(), fsm.get_edge_num(), return_value);
        }
    }

    /// Adapts a crossing rule-level cache entry with lookahead.
    fn adapt_cache_with_lookahead(
        self: *GrammarMatcherForTokenMaskCache,
        cache: *AdaptiveTokenMask,
        is_root_rule: bool,
    ) Allocator.Error!void {
        const sorted_decoded_vocab = self.tokenizer_info.sorted_decoded_vocab;
        const subtree_nodes_range = self.tokenizer_info.trie_subtree_nodes_range;
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
                    const lcp_len = common_prefix_len(token, prev);
                    if (lcp_len > prev_matched_size) {
                        accepted = false;
                    } else if (lcp_len < prev_matched_size) {
                        const pop_cnt: usize = @intCast(prev_matched_size - lcp_len);
                        self.parser.pop_last_states(prev_matched_size - lcp_len);
                        self.tmp_can_reach_end_stack.shrinkRetainingCapacity(self.tmp_can_reach_end_stack.items.len - pop_cnt);
                        self.tmp_can_reach_end_prefix_or_stack.shrinkRetainingCapacity(self.tmp_can_reach_end_prefix_or_stack.items.len - pop_cnt);
                    }
                    prev_matched_size = @min(prev_matched_size, lcp_len);
                }

                prev_token = token;

                if (accepted) {
                    const start_j: usize = @intCast(prev_matched_size);
                    for (token[start_j..], start_j..) |byte, j| {
                        if (!try unwrap_earley_bool(self.parser.advance(byte))) {
                            accepted = false;
                            break;
                        }
                        const completed = self.parser.is_root_completed();
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
                    const la = try is_token_pass_lookahead_assertion(
                        self.parser,
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

        // Replace cache.uncertain_indices cleanly without leaking old slice.
        self.allocator.free(cache.uncertain_indices);
        cache.uncertain_indices = try self.allocator.dupe(i32, self.tmp_uncertain_indices.items);

        switch (cache.store_type) {
            .Accepted => {
                if (cache.accepted_indices.len + self.tmp_accepted_indices.items.len < AdaptiveTokenMask.USE_BITSET_THRESHOLD) {
                    var list: std.ArrayList(i32) = .empty;
                    defer list.deinit(self.allocator);
                    try list.appendSlice(self.allocator, cache.accepted_indices);
                    try intset_union(self.allocator, &list, self.tmp_accepted_indices.items);
                    self.allocator.free(cache.accepted_indices);
                    cache.accepted_indices = try list.toOwnedSlice(self.allocator);
                } else {
                    cache.store_type = .AcceptedBitset;
                    var accepted_bitset = try DynamicBitset.init(self.allocator, @intCast(self.tokenizer_info.vocab_size));
                    errdefer accepted_bitset.deinit();
                    for (cache.accepted_indices) |idx| {
                        const tid: usize = @intCast(sorted_decoded_vocab[@intCast(idx)].id);
                        accepted_bitset.set(tid, true);
                    }
                    for (self.tmp_accepted_indices.items) |idx| {
                        const tid: usize = @intCast(sorted_decoded_vocab[@intCast(idx)].id);
                        accepted_bitset.set(tid, true);
                    }
                    self.allocator.free(cache.accepted_indices);
                    cache.accepted_indices = try self.allocator.alloc(i32, 0);
                    cache.accepted_bitset.deinit();
                    cache.accepted_bitset = accepted_bitset;
                }
            },
            .Rejected => {
                if (cache.rejected_indices.len + self.tmp_rejected_indices.items.len < AdaptiveTokenMask.USE_BITSET_THRESHOLD) {
                    var list: std.ArrayList(i32) = .empty;
                    defer list.deinit(self.allocator);
                    try list.appendSlice(self.allocator, cache.rejected_indices);
                    try intset_union(self.allocator, &list, self.tmp_rejected_indices.items);
                    self.allocator.free(cache.rejected_indices);
                    cache.rejected_indices = try list.toOwnedSlice(self.allocator);
                } else {
                    cache.store_type = .AcceptedBitset;
                    var accepted_bitset = try DynamicBitset.init(self.allocator, @intCast(self.tokenizer_info.vocab_size));
                    errdefer accepted_bitset.deinit();
                    accepted_bitset.set_all();
                    for (self.tokenizer_info.special_token_ids) |special_id| {
                        accepted_bitset.reset(@intCast(special_id));
                    }
                    for (cache.uncertain_indices) |idx| {
                        accepted_bitset.reset(@intCast(sorted_decoded_vocab[@intCast(idx)].id));
                    }
                    for (cache.rejected_indices) |idx| {
                        accepted_bitset.reset(@intCast(sorted_decoded_vocab[@intCast(idx)].id));
                    }
                    for (self.tmp_rejected_indices.items) |idx| {
                        accepted_bitset.reset(@intCast(sorted_decoded_vocab[@intCast(idx)].id));
                    }
                    self.allocator.free(cache.rejected_indices);
                    cache.rejected_indices = try self.allocator.alloc(i32, 0);
                    cache.accepted_bitset.deinit();
                    cache.accepted_bitset = accepted_bitset;
                }
            },
            .AcceptedBitset => {
                for (self.tmp_accepted_indices.items) |idx| {
                    const tid: usize = @intCast(sorted_decoded_vocab[@intCast(idx)].id);
                    cache.accepted_bitset.set(tid, true);
                }
            },
        }
    }

    fn get_speculative_calculation(self: *const GrammarMatcherForTokenMaskCache) struct { can_apply: bool, mask: FirstCharMask } {
        const rule = self.grammar.rule(self.init_rule_id);
        if (rule.is_lazy) {
            return .{ .can_apply = false, .mask = @splat(false) };
        }
        const rule_body = self.grammar.expr(rule.body_expr_id);
        const fsm = self.grammar.per_rule_fsm(self.init_rule_id).?.get_fsm();

        if (rule_body.ty == GrammarExprType.TagDispatch) {
            var speculative_mask: FirstCharMask = @splat(false);
            for (fsm.get_fsm().state_edges(self.initial_state.element_id)) |edge| {
                if (edge.target != fsm.get_start()) continue;
                if (!edge.is_char_range()) continue;
                var ch = edge.min;
                while (ch <= edge.max) : (ch += 1) {
                    speculative_mask[@intCast(ch)] = true;
                }
            }
            return .{ .can_apply = true, .mask = speculative_mask };
        }

        var can_be_applied = false;
        var speculative_mask: FirstCharMask = @splat(false);
        std.debug.assert(self.initial_state.element_id < fsm.num_states());
        const compact = fsm.get_fsm();
        for (compact.state_edges(self.initial_state.element_id)) |edge| {
            if (!edge.is_char_range()) continue;
            if (edge.target == self.initial_state.element_id) {
                can_be_applied = true;
                var ch = edge.min;
                while (ch <= edge.max) : (ch += 1) {
                    speculative_mask[@intCast(ch)] = true;
                }
                continue;
            }
            if (fsm.get_start() == self.initial_state.element_id) {
                for (compact.state_edges(edge.target)) |next_edge| {
                    const matches = (next_edge.is_rule_ref() and next_edge.ref_rule_id() == self.init_rule_id) or
                        (next_edge.is_repeat_ref() and compact.repeat_edge_info(next_edge.aux_index()).rule_id() == self.init_rule_id);
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

    fn get_token_mask_with_first_character_check(
        self: *GrammarMatcherForTokenMaskCache,
        first_char_mask: *const FirstCharMask,
        is_root_rule: bool,
        token_edge_accepted: []const i32,
    ) Allocator.Error!bool {
        const sorted_decoded_vocab = self.tokenizer_info.sorted_decoded_vocab;
        const subtree_nodes_range = self.tokenizer_info.trie_subtree_nodes_range;
        var possible_intervals: std.ArrayList(Interval) = .empty;
        defer possible_intervals.deinit(self.allocator);
        const possible_token_num = try get_possible_token_intervals(
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

        std.debug.assert(self.init_rule_id != -1 and self.grammar.per_rule_fsm(self.init_rule_id) != null);
        const spec = self.get_speculative_calculation();
        var speculative_calculation = spec.can_apply;
        const speculative_mask = spec.mask;
        if (self.parser.has_char_budget_rules) {
            speculative_calculation = false;
        }

        var prev_matched_size: i32 = 0;
        var last_rejected_range: i32 = 0;
        const rule = self.grammar.rule(self.init_rule_id);
        const is_exact_lookahead = rule.is_exact_lookahead;
        const definite_accepted_bitset: ?*const DynamicBitset = if (self.grammar.expr(rule.body_expr_id).ty == GrammarExprType.TagDispatch) blk: {
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
                    const lcp_len = common_prefix_len(token, prev);
                    if (lcp_len > prev_matched_size) {
                        accepted = false;
                    } else if (lcp_len < prev_matched_size) {
                        const pop_cnt: usize = @intCast(prev_matched_size - lcp_len);
                        self.parser.pop_last_states(prev_matched_size - lcp_len);
                        self.tmp_can_reach_end_stack.shrinkRetainingCapacity(self.tmp_can_reach_end_stack.items.len - pop_cnt);
                        self.tmp_can_reach_end_prefix_or_stack.shrinkRetainingCapacity(self.tmp_can_reach_end_prefix_or_stack.items.len - pop_cnt);
                    }
                    prev_matched_size = @min(prev_matched_size, lcp_len);
                }

                prev_token = token;

                if (accepted) {
                    const start_j: usize = @intCast(prev_matched_size);
                    for (token[start_j..], start_j..) |byte, j| {
                        if (!try unwrap_earley_bool(self.parser.advance(byte))) {
                            accepted = false;
                            break;
                        }
                        const completed = self.parser.is_root_completed();
                        try self.tmp_can_reach_end_stack.append(self.allocator, completed);
                        const prev_or = self.tmp_can_reach_end_prefix_or_stack.items[self.tmp_can_reach_end_prefix_or_stack.items.len - 1];
                        try self.tmp_can_reach_end_prefix_or_stack.append(self.allocator, completed or prev_or);
                        prev_matched_size = @as(i32, @intCast(j)) + 1;
                    }
                }

                const can_reach_end = self.tmp_can_reach_end_prefix_or_stack.items[self.tmp_can_reach_end_prefix_or_stack.items.len - 1];

                if (accepted) {
                    if (self.parser.has_entered_char_budget()) {
                        try self.tmp_uncertain_indices.append(self.allocator, i);
                    } else {
                        try self.tmp_accepted_indices.append(self.allocator, i);
                    }
                } else if (can_reach_end and prev_matched_size > 0) {
                    const la = try is_token_pass_lookahead_assertion(
                        self.parser,
                        self.grammar,
                        self.init_rule_id,
                        token,
                        self.tmp_can_reach_end_stack.items,
                    );
                    if (!is_root_rule and la.accepted) {
                        if (la.can_reach_end or !is_exact_lookahead or self.parser.has_entered_char_budget()) {
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

        self.parser.pop_last_states(prev_matched_size);

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

    fn get_first_character_mask(self: *const GrammarMatcherForTokenMaskCache, first_character_mask: *FirstCharMask) void {
        @memset(first_character_mask, false);
        const fsm = self.grammar.per_rule_fsm(self.init_rule_id).?.get_fsm();
        for (fsm.get_fsm().state_edges(self.initial_state.element_id)) |edge| {
            if (edge.is_char_range()) {
                var c = edge.min;
                while (c <= edge.max) : (c += 1) {
                    first_character_mask[@intCast(c)] = true;
                }
            }
        }
    }

    fn take_token_edge_accepted_indices(self: *GrammarMatcherForTokenMaskCache) Allocator.Error![]const i32 {
        self.tmp_token_edge_accepted.clearRetainingCapacity();
        self.tmp_token_edge_excluded.clearRetainingCapacity();

        const fsm = self.grammar.per_rule_fsm(self.init_rule_id).?.get_fsm();
        const compact = fsm.get_fsm();
        const edges = compact.state_edges(self.initial_state.element_id);
        const sorted_size: i32 = @intCast(self.tokenizer_info.sorted_decoded_vocab.len);
        const tid_to_sorted = self.tokenizer_info.token_id_to_sorted_vocab_index;
        var has_exclude_token = false;

        for (edges) |edge| {
            if (edge.is_token()) {
                const info = compact.token_edge_info(edge.aux_index());
                for (info.token_ids()) |tid| {
                    if (tid >= 0 and @as(usize, @intCast(tid)) < tid_to_sorted.len) {
                        const sorted_idx = tid_to_sorted[@intCast(tid)];
                        if (sorted_idx >= 0) {
                            try self.tmp_token_edge_accepted.append(self.allocator, sorted_idx);
                        }
                    }
                }
            } else if (edge.is_exclude_token()) {
                has_exclude_token = true;
                const info = compact.exclude_token_edge_info(edge.aux_index());
                for (info.token_ids()) |tid| {
                    if (tid >= 0 and @as(usize, @intCast(tid)) < tid_to_sorted.len) {
                        const sorted_idx = tid_to_sorted[@intCast(tid)];
                        if (sorted_idx >= 0) {
                            try self.tmp_token_edge_excluded.append(self.allocator, sorted_idx);
                        }
                    }
                }
            }
        }

        sort_and_dedup(&self.tmp_token_edge_accepted);
        if (!has_exclude_token) {
            return self.tmp_token_edge_accepted.items;
        }

        sort_and_dedup(&self.tmp_token_edge_excluded);
        intset_difference(&self.tmp_token_edge_excluded, self.tmp_token_edge_accepted.items);
        var comp = try intset_complement(self.allocator, sorted_size, self.tmp_token_edge_excluded.items);
        self.tmp_token_edge_accepted.deinit(self.allocator);
        self.tmp_token_edge_accepted = comp;
        _ = &comp;
        return self.tmp_token_edge_accepted.items;
    }
};

fn sort_and_dedup(list: *std.ArrayList(i32)) void {
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
pub fn get_possible_token_intervals(
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
            const left = lower_bound_sorted_vocab(sorted_decoded_vocab, matched_size, &[_]u8{last_end});
            const right = lower_bound_sorted_vocab(sorted_decoded_vocab, left, &[_]u8{ch});
            try possible_intervals.append(allocator, .{ .start = @intCast(left), .end = @intCast(right) });
            possible_token_num += @as(i32, @intCast(right)) - @as(i32, @intCast(left));
            matched_size = right;
            last_interval_end = null;
        }
    }

    if (last_interval_end) |last_end| {
        const left = lower_bound_sorted_vocab(sorted_decoded_vocab, matched_size, &[_]u8{last_end});
        try possible_intervals.append(allocator, .{ .start = @intCast(left), .end = @intCast(sorted_decoded_vocab.len) });
        possible_token_num += @as(i32, @intCast(sorted_decoded_vocab.len)) - @as(i32, @intCast(left));
    }

    return possible_token_num;
}

fn lower_bound_sorted_vocab(
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

pub fn is_token_pass_lookahead_assertion(
    parser: *EarleyParser,
    grammar: *const Grammar,
    init_rule_id: i32,
    token: []const u8,
    can_reach_end_stack: []const bool,
) Allocator.Error!struct { accepted: bool, can_reach_end: bool } {
    var accepted = true;
    var can_reach_end = true;
    const lookahead_assertion_id = grammar.rule(init_rule_id).lookahead_assertion_id;
    if (lookahead_assertion_id == NO_EXPR) {
        return .{ .accepted = accepted, .can_reach_end = can_reach_end };
    }

    var lookahead_state = ParserState.new(-1, lookahead_assertion_id, 0, ParserState.NO_PREV_INPUT_POS);
    lookahead_state.budget_deadline = 0;
    try unwrap_earley_void(parser.push_state_and_expand(lookahead_state));
    const token_len: i32 = @intCast(token.len);

    if (parser.is_root_completed()) {
        parser.pop_last_states(1);
        return .{ .accepted = accepted, .can_reach_end = can_reach_end };
    }

    var rev_i: usize = can_reach_end_stack.len;
    while (rev_i > 0) {
        rev_i -= 1;
        if (!can_reach_end_stack[rev_i]) continue;
        const i_i32: i32 = @intCast(rev_i);
        var last_accept_pos: i32 = i_i32 - 1;
        for (token[rev_i..], rev_i..) |byte, pos| {
            if (!try unwrap_earley_bool(parser.advance(byte))) {
                break;
            }
            last_accept_pos = @intCast(pos);
            if (parser.is_root_completed()) {
                parser.pop_last_states(@as(i32, @intCast(pos)) - i_i32 + 2);
                return .{ .accepted = accepted, .can_reach_end = can_reach_end };
            }
        }
        if (last_accept_pos == token_len - 1) {
            parser.pop_last_states(last_accept_pos - i_i32 + 2);
            can_reach_end = false;
            return .{ .accepted = accepted, .can_reach_end = can_reach_end };
        }
        parser.pop_last_states(last_accept_pos - i_i32 + 1);
    }

    parser.pop_last_states(1);
    can_reach_end = false;
    accepted = false;
    return .{ .accepted = accepted, .can_reach_end = can_reach_end };
}

fn sorted_set_difference(allocator: Allocator, left: []const i32, right: []const i32) Allocator.Error!std.ArrayList(i32) {
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
