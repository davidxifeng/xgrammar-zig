//! Adaptive token-mask cache (`adaptive_token_mask.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const rule_level_cache = @import("rule_level_cache.zig");
const RuleLevelCache = rule_level_cache.RuleLevelCache;
const tag_dispatch_opt_mod = @import("tag_dispatch_optimization.zig");
const token_mask_cache_builder = @import("token_mask_cache_builder.zig");
const GrammarMatcherForTokenMaskCache = token_mask_cache_builder.GrammarMatcherForTokenMaskCache;

const grammar_mod = @import("../grammar/mod.zig");
const DeserializeError = grammar_mod.DeserializeError;
const DeserializeErrorInfo = grammar_mod.DeserializeErrorInfo;
const Grammar = grammar_mod.Grammar;
const parser_mod = @import("../parser/mod.zig");
const ParserState = parser_mod.ParserState;
const ParserStateCacheKey = parser_mod.ParserStateCacheKey;
const support = @import("../support/mod.zig");
const DynamicBitset = support.DynamicBitset;
const tokenizer_mod = @import("../tokenizer/mod.zig");
const SortedDecodedToken = tokenizer_mod.tokenizer_info.SortedDecodedToken;
const TokenizerInfo = tokenizer_mod.tokenizer_info.TokenizerInfo;

/// How accepted/rejected sorted-vocab indices are stored (mirrors C++ `StoreType`).
pub const AdaptiveTokenMaskStoreType = enum(i32) {
    /// Store accepted indices; rejected = complement - uncertain.
    Accepted = 0,
    /// Store rejected indices; accepted = complement - uncertain.
    Rejected = 1,
    /// Store accepted token ids in a bitset indexed by token id.
    AcceptedBitset = 2,

    pub fn from_i32(allocator: Allocator, value: i32, diag: ?*DeserializeErrorInfo) DeserializeError!AdaptiveTokenMaskStoreType {
        return switch (value) {
            0 => .Accepted,
            1 => .Rejected,
            2 => .AcceptedBitset,
            else => {
                if (diag) |d| {
                    d.* = .{ .Format = std.fmt.allocPrint(allocator, "invalid adaptive token mask store_type {d}", .{value}) catch "" };
                }
                return error.Format;
            },
        };
    }
};

/// Precomputed token classification for one parser state (mirrors C++ `AdaptiveTokenMask`).
///
/// Indices refer to positions in `TokenizerInfo.sorted_decoded_vocab`, not token ids.
pub const AdaptiveTokenMask = struct {
    store_type: AdaptiveTokenMaskStoreType,
    accepted_indices: []i32,
    rejected_indices: []i32,
    accepted_bitset: DynamicBitset,
    uncertain_indices: []i32,

    /// Threshold above which accepted/rejected lists switch to a bitset (mirrors C++).
    pub const USE_BITSET_THRESHOLD: usize = 1000;

    pub fn deinit(self: *AdaptiveTokenMask) void {
        const a = self.accepted_bitset.allocator;
        a.free(self.accepted_indices);
        a.free(self.rejected_indices);
        a.free(self.uncertain_indices);
        self.accepted_bitset.deinit();
    }

    pub fn clone(self: *const AdaptiveTokenMask, allocator: Allocator) Allocator.Error!AdaptiveTokenMask {
        var bitset = try self.accepted_bitset.clone(allocator);
        errdefer bitset.deinit();
        const accepted = try allocator.dupe(i32, self.accepted_indices);
        errdefer allocator.free(accepted);
        const rejected = try allocator.dupe(i32, self.rejected_indices);
        errdefer allocator.free(rejected);
        const uncertain = try allocator.dupe(i32, self.uncertain_indices);
        return .{
            .store_type = self.store_type,
            .accepted_indices = accepted,
            .rejected_indices = rejected,
            .accepted_bitset = bitset,
            .uncertain_indices = uncertain,
        };
    }

    pub fn eql(a: *const AdaptiveTokenMask, b: *const AdaptiveTokenMask) bool {
        return a.store_type == b.store_type and
            std.mem.eql(i32, a.accepted_indices, b.accepted_indices) and
            std.mem.eql(i32, a.rejected_indices, b.rejected_indices) and
            std.mem.eql(i32, a.uncertain_indices, b.uncertain_indices) and
            a.accepted_bitset.size == b.accepted_bitset.size and
            std.mem.eql(u32, a.accepted_bitset.as_words(), b.accepted_bitset.as_words());
    }

    /// Builds a mask from accepted, rejected, and uncertain sorted-vocab indices.
    pub fn from_classifications(
        allocator: Allocator,
        vocab_size: usize,
        sorted_decoded_vocab: []const SortedDecodedToken,
        accepted_indices: []const i32,
        rejected_indices: []const i32,
        uncertain_indices: []const i32,
    ) Allocator.Error!AdaptiveTokenMask {
        const size_acc = accepted_indices.len;
        const size_rej = rejected_indices.len;
        const store_type: AdaptiveTokenMaskStoreType = if (size_acc >= USE_BITSET_THRESHOLD and size_rej >= USE_BITSET_THRESHOLD)
            .AcceptedBitset
        else if (size_acc < size_rej)
            .Accepted
        else
            .Rejected;

        var accepted_bitset = try DynamicBitset.init(allocator, if (store_type == .AcceptedBitset) vocab_size else 0);
        errdefer accepted_bitset.deinit();

        const acc_out: []i32 = try allocator.alloc(i32, if (store_type == .Accepted) accepted_indices.len else 0);
        errdefer allocator.free(acc_out);
        const rej_out: []i32 = try allocator.alloc(i32, if (store_type == .Rejected) rejected_indices.len else 0);
        errdefer allocator.free(rej_out);

        switch (store_type) {
            .AcceptedBitset => {
                for (accepted_indices) |idx| {
                    const token_id: usize = @intCast(sorted_decoded_vocab[@intCast(idx)].id);
                    accepted_bitset.set(token_id, true);
                }
            },
            .Accepted => @memcpy(acc_out, accepted_indices),
            .Rejected => @memcpy(rej_out, rejected_indices),
        }

        const unc_out = try allocator.dupe(i32, uncertain_indices);
        return .{
            .store_type = store_type,
            .accepted_indices = acc_out,
            .rejected_indices = rej_out,
            .accepted_bitset = accepted_bitset,
            .uncertain_indices = unc_out,
        };
    }

    /// Builds a mask storing only accepted indices (rejected inferred at runtime).
    pub fn from_accepted_and_uncertain(
        allocator: Allocator,
        vocab_size: usize,
        sorted_decoded_vocab: []const SortedDecodedToken,
        accepted_indices: []const i32,
        uncertain_indices: []const i32,
    ) Allocator.Error!AdaptiveTokenMask {
        const store_type: AdaptiveTokenMaskStoreType = if (accepted_indices.len >= USE_BITSET_THRESHOLD)
            .AcceptedBitset
        else
            .Accepted;

        var accepted_bitset = try DynamicBitset.init(allocator, if (store_type == .AcceptedBitset) vocab_size else 0);
        errdefer accepted_bitset.deinit();

        const acc_out: []i32 = try allocator.alloc(i32, if (store_type == .Accepted) accepted_indices.len else 0);
        errdefer allocator.free(acc_out);
        const rej_out: []i32 = try allocator.alloc(i32, 0);
        errdefer allocator.free(rej_out);

        switch (store_type) {
            .AcceptedBitset => {
                for (accepted_indices) |idx| {
                    const token_id: usize = @intCast(sorted_decoded_vocab[@intCast(idx)].id);
                    accepted_bitset.set(token_id, true);
                }
            },
            .Accepted => @memcpy(acc_out, accepted_indices),
            .Rejected => unreachable,
        }

        const unc_out = try allocator.dupe(i32, uncertain_indices);
        return .{
            .store_type = store_type,
            .accepted_indices = acc_out,
            .rejected_indices = rej_out,
            .accepted_bitset = accepted_bitset,
            .uncertain_indices = unc_out,
        };
    }

    /// Approximate memory footprint in bytes.
    pub fn memory_size_bytes(self: *const AdaptiveTokenMask) usize {
        return self.accepted_indices.len * 4 +
            self.rejected_indices.len * 4 +
            self.uncertain_indices.len * 4 +
            self.accepted_bitset.as_words().len * 4;
    }

    /// Serializes to a JSON object using `arena_allocator` (keys sorted lexicographically to
    /// match serde_json's BTreeMap order).
    pub fn serialize_json_value(self: *const AdaptiveTokenMask, allocator: Allocator) Allocator.Error!std.json.Value {
        var obj = std.json.ObjectMap.empty;
        // Key order: accepted_bitset < accepted_indices < rejected_indices < store_type < uncertain_indices.
        try obj.put(allocator, "accepted_bitset", try self.accepted_bitset.serialize_json_value_cpp(allocator));
        try obj.put(allocator, "accepted_indices", try i32_slice_json(allocator, self.accepted_indices));
        try obj.put(allocator, "rejected_indices", try i32_slice_json(allocator, self.rejected_indices));
        try obj.put(allocator, "store_type", .{ .integer = @intFromEnum(self.store_type) });
        try obj.put(allocator, "uncertain_indices", try i32_slice_json(allocator, self.uncertain_indices));
        return .{ .object = obj };
    }

    /// Deserializes from a JSON object into `allocator`.
    pub fn deserialize_json_value(
        allocator: Allocator,
        value: std.json.Value,
        diag: ?*DeserializeErrorInfo,
    ) (DeserializeError || Allocator.Error)!AdaptiveTokenMask {
        const obj = switch (value) {
            .object => |o| o,
            else => return fail_format(allocator, diag, "adaptive token mask must be a JSON object"),
        };
        const st_val = obj.get("store_type") orelse return fail_format(allocator, diag, "adaptive token mask missing store_type");
        const st_i32 = switch (st_val) {
            .integer => |n| std.math.cast(i32, n) orelse return fail_format(allocator, diag, "adaptive token mask missing store_type"),
            else => return fail_format(allocator, diag, "adaptive token mask missing store_type"),
        };
        const store_type = try AdaptiveTokenMaskStoreType.from_i32(allocator, st_i32, diag);

        const accepted_indices = try parse_i32_array(
            allocator,
            obj.get("accepted_indices") orelse return fail_format(allocator, diag, "adaptive token mask missing accepted_indices"),
            "adaptive token mask missing accepted_indices",
            "adaptive token mask accepted_indices must be integers",
            diag,
        );
        errdefer allocator.free(accepted_indices);

        const rejected_indices = try parse_i32_array(
            allocator,
            obj.get("rejected_indices") orelse return fail_format(allocator, diag, "adaptive token mask missing rejected_indices"),
            "adaptive token mask missing rejected_indices",
            "adaptive token mask rejected_indices must be integers",
            diag,
        );
        errdefer allocator.free(rejected_indices);

        const uncertain_indices = try parse_i32_array(
            allocator,
            obj.get("uncertain_indices") orelse return fail_format(allocator, diag, "adaptive token mask missing uncertain_indices"),
            "adaptive token mask missing uncertain_indices",
            "adaptive token mask uncertain_indices must be integers",
            diag,
        );
        errdefer allocator.free(uncertain_indices);

        const bitset_val = obj.get("accepted_bitset") orelse return fail_format(allocator, diag, "adaptive token mask missing accepted_bitset");
        const accepted_bitset = DynamicBitset.deserialize_json_value_cpp(allocator, bitset_val) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidJson => return fail_format(allocator, diag, "invalid accepted_bitset in adaptive token mask"),
        };

        return .{
            .store_type = store_type,
            .accepted_indices = accepted_indices,
            .rejected_indices = rejected_indices,
            .accepted_bitset = accepted_bitset,
            .uncertain_indices = uncertain_indices,
        };
    }
};

fn i32_slice_json(allocator: Allocator, slice: []const i32) Allocator.Error!std.json.Value {
    var arr = std.json.Array.init(allocator);
    try arr.ensureTotalCapacity(slice.len);
    for (slice) |v| arr.appendAssumeCapacity(.{ .integer = v });
    return .{ .array = arr };
}

fn fail_format(allocator: Allocator, diag: ?*DeserializeErrorInfo, msg: []const u8) DeserializeError {
    if (diag) |d| {
        d.* = .{ .Format = allocator.dupe(u8, msg) catch "" };
    }
    return error.Format;
}

fn parse_i32_array(
    allocator: Allocator,
    value: std.json.Value,
    not_array_msg: []const u8,
    not_int_msg: []const u8,
    diag: ?*DeserializeErrorInfo,
) (DeserializeError || Allocator.Error)![]i32 {
    const arr = switch (value) {
        .array => |a| a,
        else => return fail_format(allocator, diag, not_array_msg),
    };
    const out = try allocator.alloc(i32, arr.items.len);
    errdefer allocator.free(out);
    for (arr.items, 0..) |item, i| {
        out[i] = switch (item) {
            .integer => |n| std.math.cast(i32, n) orelse return fail_format(allocator, diag, not_int_msg),
            else => return fail_format(allocator, diag, not_int_msg),
        };
    }
    return out;
}

pub const ParserStateCacheKeyContext = struct {
    pub fn hash(_: ParserStateCacheKeyContext, key: ParserStateCacheKey) u64 {
        const fields = [4]i32{ key.rule_id, key.sequence_id, key.element_id, key.sub_element_id };
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&fields));
    }

    pub fn eql(_: ParserStateCacheKeyContext, a: ParserStateCacheKey, b: ParserStateCacheKey) bool {
        return a.rule_id == b.rule_id and
            a.sequence_id == b.sequence_id and
            a.element_id == b.element_id and
            a.sub_element_id == b.sub_element_id;
    }
};

/// Mapping from parser-state cache keys to precomputed masks.
pub const AdaptiveTokenMaskCache = struct {
    allocator: Allocator,
    map: std.HashMapUnmanaged(ParserStateCacheKey, AdaptiveTokenMask, ParserStateCacheKeyContext, 80),

    pub fn init(allocator: Allocator) AdaptiveTokenMaskCache {
        return .{ .allocator = allocator, .map = .empty };
    }

    pub fn deinit(self: *AdaptiveTokenMaskCache) void {
        var it = self.map.valueIterator();
        while (it.next()) |mask| {
            mask.deinit();
        }
        self.map.deinit(self.allocator);
    }

    pub fn clone(self: *const AdaptiveTokenMaskCache, allocator: Allocator) Allocator.Error!AdaptiveTokenMaskCache {
        var out = AdaptiveTokenMaskCache.init(allocator);
        errdefer out.deinit();
        try out.map.ensureTotalCapacity(allocator, self.map.count());
        var it = self.map.iterator();
        while (it.next()) |entry| {
            const cloned_mask = try entry.value_ptr.clone(allocator);
            out.map.putAssumeCapacity(entry.key_ptr.*, cloned_mask);
        }
        return out;
    }

    pub fn get(self: *const AdaptiveTokenMaskCache, key: ParserStateCacheKey) ?*const AdaptiveTokenMask {
        return self.map.getPtr(key);
    }

    pub fn put(self: *AdaptiveTokenMaskCache, key: ParserStateCacheKey, mask: AdaptiveTokenMask) Allocator.Error!void {
        const gop = try self.map.getOrPut(self.allocator, key);
        if (gop.found_existing) {
            gop.value_ptr.deinit();
        }
        gop.value_ptr.* = mask;
    }

    pub fn count(self: *const AdaptiveTokenMaskCache) usize {
        return self.map.count();
    }

    pub fn memory_size_bytes(self: *const AdaptiveTokenMaskCache) usize {
        var total: usize = 0;
        var it = self.map.valueIterator();
        while (it.next()) |mask| {
            total += mask.memory_size_bytes();
        }
        return total;
    }
};

/// The parser state a mask is computed for: the C++ compiler constructs it as
/// `ParserState(rule_id, body_expr_id, element_id, kNoPrevInputPos, 0)`, whose fifth argument
/// is the token budget deadline.
fn compile_task_state(rule_id: i32, sequence_id: i32, element_id: i32) ParserState {
    var s = ParserState.new(rule_id, sequence_id, element_id, ParserState.NO_PREV_INPUT_POS);
    s.budget_deadline = 0;
    return s;
}

/// Serializes the cache as `List[Tuple[ParserState member array, AdaptiveTokenMask]]`.
pub fn serialize_cache_json_value(
    cache: *const AdaptiveTokenMaskCache,
    allocator: Allocator,
) Allocator.Error!std.json.Value {
    const Entry = struct {
        key: ParserStateCacheKey,
        mask: *const AdaptiveTokenMask,
    };
    var entries = try std.ArrayList(Entry).initCapacity(allocator, cache.count());
    defer entries.deinit(allocator);
    var it = cache.map.iterator();
    while (it.next()) |kv| {
        entries.appendAssumeCapacity(.{ .key = kv.key_ptr.*, .mask = kv.value_ptr });
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            if (a.key.rule_id != b.key.rule_id) return a.key.rule_id < b.key.rule_id;
            if (a.key.sequence_id != b.key.sequence_id) return a.key.sequence_id < b.key.sequence_id;
            if (a.key.element_id != b.key.element_id) return a.key.element_id < b.key.element_id;
            return a.key.sub_element_id < b.key.sub_element_id;
        }
    }.less);

    var arr = std.json.Array.init(allocator);
    try arr.ensureTotalCapacity(entries.items.len);
    for (entries.items) |entry| {
        var state = compile_task_state(entry.key.rule_id, entry.key.sequence_id, entry.key.element_id);
        state.sub_element_id = entry.key.sub_element_id;
        const members = state.serialize_member_array();
        var members_arr = std.json.Array.init(allocator);
        try members_arr.ensureTotalCapacity(members.len);
        for (members) |m| members_arr.appendAssumeCapacity(.{ .integer = m });

        var pair = std.json.Array.init(allocator);
        try pair.ensureTotalCapacity(2);
        pair.appendAssumeCapacity(.{ .array = members_arr });
        pair.appendAssumeCapacity(try entry.mask.serialize_json_value(allocator));
        arr.appendAssumeCapacity(.{ .array = pair });
    }
    return .{ .array = arr };
}

/// Deserializes a cache from JSON into `allocator`.
pub fn deserialize_cache_json_value(
    allocator: Allocator,
    value: std.json.Value,
    diag: ?*DeserializeErrorInfo,
) (DeserializeError || Allocator.Error)!AdaptiveTokenMaskCache {
    const entries = switch (value) {
        .array => |a| a,
        else => return fail_format(allocator, diag, "adaptive_token_mask_cache must be a JSON array"),
    };
    var cache = AdaptiveTokenMaskCache.init(allocator);
    errdefer cache.deinit();

    var members_buf: [10]i32 = undefined;
    for (entries.items) |entry| {
        const pair = switch (entry) {
            .array => |a| a,
            else => return fail_format(allocator, diag, "adaptive token mask cache entry must be a pair"),
        };
        if (pair.items.len != 2) {
            return fail_format(allocator, diag, "adaptive token mask cache entry must have two elements");
        }
        const member_arr = switch (pair.items[0]) {
            .array => |a| a,
            else => return fail_format(allocator, diag, "adaptive token mask cache key must be an array"),
        };
        if (member_arr.items.len != 10) {
            return fail_format(allocator, diag, "parser state member array must have 10 fields");
        }
        for (member_arr.items, 0..) |item, i| {
            members_buf[i] = switch (item) {
                .integer => |n| std.math.cast(i32, n) orelse return fail_format(allocator, diag, "parser state member array must contain integers"),
                else => return fail_format(allocator, diag, "parser state member array must contain integers"),
            };
        }
        const state = ParserState.from_member_array(&members_buf) orelse
            return fail_format(allocator, diag, "parser state member array must have 10 fields");
        var mask = try AdaptiveTokenMask.deserialize_json_value(allocator, pair.items[1], diag);
        errdefer mask.deinit();
        try cache.put(state.cache_key(), mask);
    }
    return cache;
}

/// Builds the adaptive token-mask cache for every scanable reachable FSM state.
pub fn build_adaptive_token_mask_cache(
    allocator: Allocator,
    grammar: *const Grammar,
    tokenizer_info: *const TokenizerInfo,
    max_threads: i32,
    rl_cache: ?*RuleLevelCache,
) Allocator.Error!AdaptiveTokenMaskCache {
    _ = max_threads; // rayon: parallel execution lands in Milestone 4
    var cache = AdaptiveTokenMaskCache.init(allocator);
    errdefer cache.deinit();

    if (tokenizer_info.vocab_size == 0) {
        return cache;
    }

    var tag_dispatch_bitsets = try tag_dispatch_opt_mod.tag_dispatch_optimization(allocator, grammar, tokenizer_info);
    defer tag_dispatch_bitsets.deinit();

    const Task = struct {
        state: ParserState,
        is_root_rule: bool,
    };
    var tasks: std.ArrayList(Task) = .empty;
    defer tasks.deinit(allocator);

    const root_rule_id = grammar.root_rule_id;
    var rule_id: i32 = 0;
    while (rule_id < grammar.num_rules()) : (rule_id += 1) {
        const rule = grammar.rule(rule_id);
        const sized_fsm = grammar.per_rule_fsm(rule_id) orelse unreachable;
        const fsm = sized_fsm.get_fsm();
        var reachable = try fsm.reachable_states();
        defer reachable.deinit();

        var states_list: std.ArrayList(i32) = .empty;
        defer states_list.deinit(allocator);
        var it = reachable.keyIterator();
        while (it.next()) |elem_ptr| {
            if (fsm.is_scanable_state(elem_ptr.*)) {
                try states_list.append(allocator, elem_ptr.*);
            }
        }
        std.mem.sortUnstable(i32, states_list.items, {}, std.sort.asc(i32));
        for (states_list.items) |element_id| {
            try tasks.append(allocator, .{
                .state = compile_task_state(rule_id, rule.body_expr_id, element_id),
                .is_root_rule = rule_id == root_rule_id,
            });
        }
    }

    if (tasks.items.len == 0) {
        return cache;
    }

    for (tasks.items) |task| {
        var matcher = try GrammarMatcherForTokenMaskCache.init(
            allocator,
            grammar,
            task.state,
            &tag_dispatch_bitsets,
            tokenizer_info,
            rl_cache,
        );
        defer matcher.deinit();
        var mask = try matcher.get_adaptive_token_mask(task.is_root_rule);
        errdefer mask.deinit();
        try cache.put(task.state.cache_key(), mask);
    }

    return cache;
}
