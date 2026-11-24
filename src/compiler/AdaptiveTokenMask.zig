//! Adaptive token-mask representation and per-state cache (`adaptive_token_mask.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const Diagnostic = @import("../Diagnostic.zig").Diagnostic;
const grammar_mod = @import("../grammar.zig");
const DeserializeError = grammar_mod.DeserializeError;
const parser_mod = @import("../parser.zig");
const ParserState = parser_mod.ParserState;
const ParserStateCacheKey = parser_mod.ParserStateCacheKey;
const support = @import("../support.zig");
const DynamicBitset = support.DynamicBitset;
const tokenizer_mod = @import("../tokenizer.zig");
const SortedDecodedToken = tokenizer_mod.SortedDecodedToken;

/// How accepted/rejected sorted-vocab indices are stored (mirrors C++ `StoreType`).
pub const StoreType = enum(i32) {
    /// Store accepted indices; rejected = complement - uncertain.
    accepted = 0,
    /// Store rejected indices; accepted = complement - uncertain.
    rejected = 1,
    /// Store accepted token ids in a bitset indexed by token id.
    accepted_bitset = 2,

    pub fn fromInt(
        allocator: Allocator,
        value: i32,
        diag: ?*Diagnostic,
    ) (DeserializeError || Allocator.Error)!StoreType {
        return std.enums.fromInt(StoreType, value) orelse failFormat(
            allocator,
            diag,
            "invalid adaptive token mask store_type {d}",
            .{value},
        );
    }
};

pub const AdaptiveTokenMaskStoreType = StoreType;

/// Tagged union over the active token-classification backing representation.
pub const Storage = union(enum) {
    accepted: []i32,
    rejected: []i32,
    accepted_bitset: DynamicBitset,
};

/// Precomputed token classification for one parser state (mirrors C++ `AdaptiveTokenMask`).
///
/// Indices in `accepted`, `rejected`, and `uncertain_indices` refer to positions in
/// `TokenizerInfo.sortedDecodedVocab()`, while `accepted_bitset` is indexed by token id.
pub const AdaptiveTokenMask = struct {
    storage: Storage,
    uncertain_indices: []i32,

    /// Threshold above which accepted/rejected lists switch to a bitset (mirrors C++).
    pub const USE_BITSET_THRESHOLD: usize = 1000;

    pub fn deinit(self: *AdaptiveTokenMask, allocator: Allocator) void {
        freeStorage(&self.storage, allocator);
        if (self.uncertain_indices.len > 0) allocator.free(self.uncertain_indices);
        self.* = undefined;
    }

    pub fn dupe(self: *const AdaptiveTokenMask, allocator: Allocator) Allocator.Error!AdaptiveTokenMask {
        var storage: Storage = switch (self.storage) {
            .accepted => |indices| .{ .accepted = try dupeI32Slice(allocator, indices) },
            .rejected => |indices| .{ .rejected = try dupeI32Slice(allocator, indices) },
            .accepted_bitset => |*bs| .{ .accepted_bitset = try bs.dupe(allocator) },
        };
        errdefer freeStorage(&storage, allocator);
        const uncertain = try dupeI32Slice(allocator, self.uncertain_indices);
        return .{
            .storage = storage,
            .uncertain_indices = uncertain,
        };
    }

    pub fn eql(a: *const AdaptiveTokenMask, b: *const AdaptiveTokenMask) bool {
        if (!std.mem.eql(i32, a.uncertain_indices, b.uncertain_indices)) return false;
        return switch (a.storage) {
            .accepted => |x| switch (b.storage) {
                .accepted => |y| std.mem.eql(i32, x, y),
                else => false,
            },
            .rejected => |x| switch (b.storage) {
                .rejected => |y| std.mem.eql(i32, x, y),
                else => false,
            },
            .accepted_bitset => |x| switch (b.storage) {
                .accepted_bitset => |y| x.size == y.size and std.mem.eql(u32, x.asWords(), y.asWords()),
                else => false,
            },
        };
    }

    pub inline fn storeType(self: *const AdaptiveTokenMask) StoreType {
        return switch (self.storage) {
            .accepted => .accepted,
            .rejected => .rejected,
            .accepted_bitset => .accepted_bitset,
        };
    }

    /// Builds a mask from accepted, rejected, and uncertain sorted-vocab indices.
    pub fn fromClassifications(
        allocator: Allocator,
        vocab_size: usize,
        sorted_decoded_vocab: []const SortedDecodedToken,
        accepted_indices: []const i32,
        rejected_indices: []const i32,
        uncertain_indices: []const i32,
    ) Allocator.Error!AdaptiveTokenMask {
        const size_acc = accepted_indices.len;
        const size_rej = rejected_indices.len;
        const store_type: StoreType = if (size_acc >= USE_BITSET_THRESHOLD and size_rej >= USE_BITSET_THRESHOLD)
            .accepted_bitset
        else if (size_acc < size_rej)
            .accepted
        else
            .rejected;

        return initWithStoreType(
            allocator,
            store_type,
            vocab_size,
            sorted_decoded_vocab,
            accepted_indices,
            rejected_indices,
            uncertain_indices,
        );
    }

    /// Builds a mask storing only accepted indices (rejected inferred at runtime).
    pub fn fromAcceptedAndUncertain(
        allocator: Allocator,
        vocab_size: usize,
        sorted_decoded_vocab: []const SortedDecodedToken,
        accepted_indices: []const i32,
        uncertain_indices: []const i32,
    ) Allocator.Error!AdaptiveTokenMask {
        const store_type: StoreType = if (accepted_indices.len >= USE_BITSET_THRESHOLD)
            .accepted_bitset
        else
            .accepted;

        return initWithStoreType(
            allocator,
            store_type,
            vocab_size,
            sorted_decoded_vocab,
            accepted_indices,
            &.{},
            uncertain_indices,
        );
    }

    fn initWithStoreType(
        allocator: Allocator,
        store_type: StoreType,
        vocab_size: usize,
        sorted_decoded_vocab: []const SortedDecodedToken,
        accepted_indices: []const i32,
        rejected_indices: []const i32,
        uncertain_indices: []const i32,
    ) Allocator.Error!AdaptiveTokenMask {
        var storage: Storage = switch (store_type) {
            .accepted_bitset => blk: {
                var bs = try DynamicBitset.init(allocator, vocab_size);
                for (accepted_indices) |idx| {
                    const token_id: usize = @intCast(sorted_decoded_vocab[@intCast(idx)].id);
                    bs.set(token_id, true);
                }
                break :blk .{ .accepted_bitset = bs };
            },
            .accepted => .{ .accepted = try dupeI32Slice(allocator, accepted_indices) },
            .rejected => .{ .rejected = try dupeI32Slice(allocator, rejected_indices) },
        };
        errdefer freeStorage(&storage, allocator);

        const unc_out = try dupeI32Slice(allocator, uncertain_indices);
        return .{
            .storage = storage,
            .uncertain_indices = unc_out,
        };
    }

    /// Approximate memory footprint in bytes.
    pub fn memorySizeBytes(self: *const AdaptiveTokenMask) usize {
        const storage_bytes: usize = switch (self.storage) {
            .accepted => |indices| indices.len * @sizeOf(i32),
            .rejected => |indices| indices.len * @sizeOf(i32),
            .accepted_bitset => |bs| bs.asWords().len * @sizeOf(u32),
        };
        return storage_bytes + self.uncertain_indices.len * @sizeOf(i32);
    }

    /// Streams the `v16` JSON representation directly to `jw` with keys in strict
    /// lexicographic order (`accepted_bitset` < `accepted_indices` < `rejected_indices`
    /// < `store_type` < `uncertain_indices`).
    pub fn writeJson(self: *const AdaptiveTokenMask, jw: *std.json.Stringify) std.json.Stringify.Error!void {
        try jw.beginObject();

        try jw.objectField("accepted_bitset");
        switch (self.storage) {
            .accepted_bitset => |*bs| try bs.writeJsonCpp(jw),
            else => try DynamicBitset.empty.writeJsonCpp(jw),
        }

        try jw.objectField("accepted_indices");
        try writeI32Array(jw, switch (self.storage) {
            .accepted => |indices| indices,
            else => &.{},
        });

        try jw.objectField("rejected_indices");
        try writeI32Array(jw, switch (self.storage) {
            .rejected => |indices| indices,
            else => &.{},
        });

        try jw.objectField("store_type");
        try jw.write(@backingInt(self.storeType()));

        try jw.objectField("uncertain_indices");
        try writeI32Array(jw, self.uncertain_indices);

        try jw.endObject();
    }

    /// Deserializes from a parsed JSON value into `allocator`.
    pub fn deserializeJsonValue(
        allocator: Allocator,
        value: std.json.Value,
        diag: ?*Diagnostic,
    ) (DeserializeError || Allocator.Error)!AdaptiveTokenMask {
        const obj = switch (value) {
            .object => |o| o,
            else => return failFormat(allocator, diag, "adaptive token mask must be a JSON object", .{}),
        };
        const st_val = obj.get("store_type") orelse
            return failFormat(allocator, diag, "adaptive token mask missing store_type", .{});
        const st_i32 = switch (st_val) {
            .integer => |n| std.math.cast(i32, n) orelse
                return failFormat(allocator, diag, "adaptive token mask missing store_type", .{}),
            else => return failFormat(allocator, diag, "adaptive token mask missing store_type", .{}),
        };
        const store_type = try StoreType.fromInt(allocator, st_i32, diag);

        const accepted_val = obj.get("accepted_indices") orelse
            return failFormat(allocator, diag, "adaptive token mask missing accepted_indices", .{});
        const rejected_val = obj.get("rejected_indices") orelse
            return failFormat(allocator, diag, "adaptive token mask missing rejected_indices", .{});
        const uncertain_val = obj.get("uncertain_indices") orelse
            return failFormat(allocator, diag, "adaptive token mask missing uncertain_indices", .{});
        const bitset_val = obj.get("accepted_bitset") orelse
            return failFormat(allocator, diag, "adaptive token mask missing accepted_bitset", .{});

        // Validate all array shapes before allocating storage so malformed entries cannot leak.
        const acc_items = try validateI32Array(
            allocator,
            accepted_val,
            "adaptive token mask missing accepted_indices",
            "adaptive token mask accepted_indices must be integers",
            diag,
        );
        const rej_items = try validateI32Array(
            allocator,
            rejected_val,
            "adaptive token mask missing rejected_indices",
            "adaptive token mask rejected_indices must be integers",
            diag,
        );
        const unc_items = try validateI32Array(
            allocator,
            uncertain_val,
            "adaptive token mask missing uncertain_indices",
            "adaptive token mask uncertain_indices must be integers",
            diag,
        );

        var bs = DynamicBitset.deserializeJsonValueCpp(allocator, bitset_val) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidJson => return failFormat(allocator, diag, "invalid accepted_bitset in adaptive token mask", .{}),
        };
        var bs_owned = true;
        errdefer if (bs_owned) bs.deinit(allocator);

        var storage: Storage = switch (store_type) {
            .accepted_bitset => blk: {
                bs_owned = false;
                break :blk .{ .accepted_bitset = bs };
            },
            .accepted => blk: {
                bs.deinit(allocator);
                bs_owned = false;
                break :blk .{ .accepted = try materializeI32Array(allocator, acc_items) };
            },
            .rejected => blk: {
                bs.deinit(allocator);
                bs_owned = false;
                break :blk .{ .rejected = try materializeI32Array(allocator, rej_items) };
            },
        };
        errdefer freeStorage(&storage, allocator);

        const uncertain_indices = try materializeI32Array(allocator, unc_items);
        return .{
            .storage = storage,
            .uncertain_indices = uncertain_indices,
        };
    }
};

fn freeStorage(storage: *Storage, allocator: Allocator) void {
    switch (storage.*) {
        .accepted => |indices| if (indices.len > 0) allocator.free(indices),
        .rejected => |indices| if (indices.len > 0) allocator.free(indices),
        .accepted_bitset => |*bs| bs.deinit(allocator),
    }
}

fn dupeI32Slice(allocator: Allocator, slice: []const i32) Allocator.Error![]i32 {
    if (slice.len == 0) return &.{};
    return allocator.dupe(i32, slice);
}

fn writeI32Array(jw: *std.json.Stringify, slice: []const i32) std.json.Stringify.Error!void {
    try jw.beginArray();
    for (slice) |v| try jw.write(v);
    try jw.endArray();
}

fn failFormat(
    allocator: Allocator,
    diag: ?*Diagnostic,
    comptime fmt: []const u8,
    args: anytype,
) (DeserializeError || Allocator.Error) {
    if (diag) |d| try d.setFmt(allocator, .deserialize_format, fmt, args);
    return error.Format;
}

fn validateI32Array(
    allocator: Allocator,
    value: std.json.Value,
    not_array_msg: []const u8,
    not_int_msg: []const u8,
    diag: ?*Diagnostic,
) (DeserializeError || Allocator.Error)![]const std.json.Value {
    const arr = switch (value) {
        .array => |a| a,
        else => return failFormat(allocator, diag, "{s}", .{not_array_msg}),
    };
    for (arr.items) |item| {
        switch (item) {
            .integer => |n| _ = std.math.cast(i32, n) orelse
                return failFormat(allocator, diag, "{s}", .{not_int_msg}),
            else => return failFormat(allocator, diag, "{s}", .{not_int_msg}),
        }
    }
    return arr.items;
}

fn materializeI32Array(allocator: Allocator, items: []const std.json.Value) Allocator.Error![]i32 {
    if (items.len == 0) return &.{};
    const out = try allocator.alloc(i32, items.len);
    for (items, 0..) |item, i| {
        out[i] = @intCast(item.integer);
    }
    return out;
}

pub const ParserStateCacheKeyContext = struct {
    pub fn hash(_: ParserStateCacheKeyContext, key: ParserStateCacheKey) u32 {
        const fields = [4]i32{ key.rule_id, key.sequence_id, key.element_id, key.sub_element_id };
        return @truncate(std.hash.Wyhash.hash(0, std.mem.asBytes(&fields)));
    }

    pub fn eql(_: ParserStateCacheKeyContext, a: ParserStateCacheKey, b: ParserStateCacheKey, _: usize) bool {
        return a.rule_id == b.rule_id and
            a.sequence_id == b.sequence_id and
            a.element_id == b.element_id and
            a.sub_element_id == b.sub_element_id;
    }
};

fn keyLessThan(a: ParserStateCacheKey, b: ParserStateCacheKey) bool {
    if (a.rule_id != b.rule_id) return a.rule_id < b.rule_id;
    if (a.sequence_id != b.sequence_id) return a.sequence_id < b.sequence_id;
    if (a.element_id != b.element_id) return a.element_id < b.element_id;
    return a.sub_element_id < b.sub_element_id;
}

/// The parser state a mask is computed for: the C++ compiler constructs it as
/// `ParserState(rule_id, body_expr_id, element_id, kNoPrevInputPos, 0)`, whose fifth argument
/// is the token budget deadline.
pub fn compileTaskState(rule_id: i32, sequence_id: i32, element_id: i32) ParserState {
    var s = ParserState.init(rule_id, sequence_id, element_id, ParserState.NO_PREV_INPUT_POS);
    s.budget_deadline = 0;
    return s;
}

/// Mapping from parser-state cache keys to precomputed masks, kept sorted by key for
/// zero-allocation deterministic JSON streaming.
pub const AdaptiveTokenMaskCache = struct {
    allocator: Allocator,
    map: std.ArrayHashMapUnmanaged(ParserStateCacheKey, AdaptiveTokenMask, ParserStateCacheKeyContext, false),

    pub fn init(allocator: Allocator) AdaptiveTokenMaskCache {
        return .{ .allocator = allocator, .map = .empty };
    }

    pub fn deinit(self: *AdaptiveTokenMaskCache) void {
        for (self.map.values()) |*mask| {
            mask.deinit(self.allocator);
        }
        self.map.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn dupe(self: *const AdaptiveTokenMaskCache, allocator: Allocator) Allocator.Error!AdaptiveTokenMaskCache {
        var out = AdaptiveTokenMaskCache.init(allocator);
        errdefer out.deinit();
        try out.map.ensureTotalCapacity(allocator, self.map.count());
        for (self.map.keys(), self.map.values()) |key, *mask| {
            const cloned_mask = try mask.dupe(allocator);
            out.map.putAssumeCapacity(key, cloned_mask);
        }
        return out;
    }

    pub fn get(self: *const AdaptiveTokenMaskCache, key: ParserStateCacheKey) ?*const AdaptiveTokenMask {
        return self.map.getPtr(key);
    }

    pub fn put(self: *AdaptiveTokenMaskCache, key: ParserStateCacheKey, mask: AdaptiveTokenMask) Allocator.Error!void {
        const gop = try self.map.getOrPut(self.allocator, key);
        if (gop.found_existing) {
            gop.value_ptr.deinit(self.allocator);
        }
        gop.value_ptr.* = mask;
        if (!gop.found_existing) {
            const n = self.map.count();
            if (n > 1 and !keyLessThan(self.map.keys()[n - 2], key)) {
                self.sort();
            }
        }
    }

    pub fn count(self: *const AdaptiveTokenMaskCache) usize {
        return self.map.count();
    }

    pub fn memorySizeBytes(self: *const AdaptiveTokenMaskCache) usize {
        var total: usize = 0;
        for (self.map.values()) |*mask| {
            total += mask.memorySizeBytes();
        }
        return total;
    }

    fn sort(self: *AdaptiveTokenMaskCache) void {
        const SortCtx = struct {
            keys: []const ParserStateCacheKey,
            pub fn lessThan(ctx: @This(), a_idx: usize, b_idx: usize) bool {
                return keyLessThan(ctx.keys[a_idx], ctx.keys[b_idx]);
            }
        };
        self.map.sortUnstable(SortCtx{ .keys = self.map.keys() });
    }

    /// Streams the cache directly as `[[ParserState member array, AdaptiveTokenMask], ...]`.
    pub fn writeJson(self: *const AdaptiveTokenMaskCache, jw: *std.json.Stringify) std.json.Stringify.Error!void {
        try jw.beginArray();
        for (self.map.keys(), self.map.values()) |key, *mask| {
            try jw.beginArray();
            var state = compileTaskState(key.rule_id, key.sequence_id, key.element_id);
            state.sub_element_id = key.sub_element_id;
            const members = state.serializeMemberArray();
            try jw.beginArray();
            for (members) |m| try jw.write(m);
            try jw.endArray();
            try mask.writeJson(jw);
            try jw.endArray();
        }
        try jw.endArray();
    }

    /// Deserializes a cache from JSON into `allocator`.
    pub fn deserializeJsonValue(
        allocator: Allocator,
        value: std.json.Value,
        diag: ?*Diagnostic,
    ) (DeserializeError || Allocator.Error)!AdaptiveTokenMaskCache {
        const entries = switch (value) {
            .array => |a| a,
            else => return failFormat(allocator, diag, "adaptive_token_mask_cache must be a JSON array", .{}),
        };
        var cache = AdaptiveTokenMaskCache.init(allocator);
        errdefer cache.deinit();

        var members_buf: [10]i32 = undefined;
        for (entries.items) |entry| {
            const pair = switch (entry) {
                .array => |a| a,
                else => return failFormat(allocator, diag, "adaptive token mask cache entry must be a pair", .{}),
            };
            if (pair.items.len != 2) {
                return failFormat(allocator, diag, "adaptive token mask cache entry must have two elements", .{});
            }
            const member_arr = switch (pair.items[0]) {
                .array => |a| a,
                else => return failFormat(allocator, diag, "adaptive token mask cache key must be an array", .{}),
            };
            if (member_arr.items.len != 10) {
                return failFormat(allocator, diag, "parser state member array must have 10 fields", .{});
            }
            for (member_arr.items, 0..) |item, i| {
                members_buf[i] = switch (item) {
                    .integer => |n| std.math.cast(i32, n) orelse
                        return failFormat(allocator, diag, "parser state member array must contain integers", .{}),
                    else => return failFormat(allocator, diag, "parser state member array must contain integers", .{}),
                };
            }
            const state = ParserState.fromMemberArray(&members_buf) orelse
                return failFormat(allocator, diag, "parser state member array must have 10 fields", .{});

            var mask = try AdaptiveTokenMask.deserializeJsonValue(allocator, pair.items[1], diag);
            var mask_moved = false;
            errdefer if (!mask_moved) mask.deinit(allocator);

            const gop = try cache.map.getOrPut(allocator, state.cacheKey());
            if (gop.found_existing) {
                gop.value_ptr.deinit(allocator);
            }
            gop.value_ptr.* = mask;
            mask_moved = true;
        }
        cache.sort();
        return cache;
    }
};

/// Re-exported cache builder from `token_mask_cache_builder.zig`.
pub const buildAdaptiveTokenMaskCache = @import("token_mask_cache_builder.zig").buildAdaptiveTokenMaskCache;

test {
    std.testing.refAllDecls(StoreType);
    std.testing.refAllDecls(AdaptiveTokenMask);
    std.testing.refAllDecls(AdaptiveTokenMaskCache);
}
