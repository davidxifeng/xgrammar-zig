//! The compiled grammar: preprocessing results of a `GrammarMatcher` (`compiled_grammar.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const adaptive_token_mask_mod = @import("adaptive_token_mask.zig");
const AdaptiveTokenMask = adaptive_token_mask_mod.AdaptiveTokenMask;
const AdaptiveTokenMaskCache = adaptive_token_mask_mod.AdaptiveTokenMaskCache;
const AdaptiveTokenMaskStoreType = adaptive_token_mask_mod.AdaptiveTokenMaskStoreType;
const build_adaptive_token_mask_cache = adaptive_token_mask_mod.build_adaptive_token_mask_cache;
const deserialize_cache_json_value = adaptive_token_mask_mod.deserialize_cache_json_value;
const serialize_cache_json_value = adaptive_token_mask_mod.serialize_cache_json_value;
const rule_level_cache_mod = @import("rule_level_cache.zig");
const RuleLevelCache = rule_level_cache_mod.RuleLevelCache;

const config = @import("../config.zig");
const grammar_mod = @import("../grammar/mod.zig");
const DeserializeError = grammar_mod.DeserializeError;
const DeserializeErrorAll = grammar_mod.serialization.DeserializeErrorAll;
const DeserializeErrorInfo = grammar_mod.DeserializeErrorInfo;
const Grammar = grammar_mod.Grammar;
const grammar_ser = grammar_mod.serialization;
const support = @import("../support/mod.zig");
const tokenizer_mod = @import("../tokenizer/mod.zig");
const TokenizerInfo = tokenizer_mod.tokenizer_info.TokenizerInfo;

const CompiledGrammarShared = struct {
    allocator: Allocator,
    refs: std.atomic.Value(usize),
    grammar: *Grammar,
    tokenizer_info: TokenizerInfo,
    adaptive_token_mask_cache: AdaptiveTokenMaskCache,
};

/// The compiled grammar of a `GrammarMatcher`, holding refcounted shared ownership of the
/// optimized grammar, tokenizer info, and precomputed adaptive token-mask cache.
pub const CompiledGrammar = struct {
    shared: *CompiledGrammarShared,

    /// Creates a compiled grammar from an already-optimized grammar, tokenizer info, and cache,
    /// taking ownership of all three.
    pub fn new(
        allocator: Allocator,
        grammar_ptr: *Grammar,
        tokenizer: TokenizerInfo,
        cache: AdaptiveTokenMaskCache,
    ) Allocator.Error!CompiledGrammar {
        const shared = try allocator.create(CompiledGrammarShared);
        shared.* = .{
            .allocator = allocator,
            .refs = std.atomic.Value(usize).init(1),
            .grammar = grammar_ptr,
            .tokenizer_info = tokenizer,
            .adaptive_token_mask_cache = cache,
        };
        return .{ .shared = shared };
    }

    pub fn clone(self: *const CompiledGrammar) CompiledGrammar {
        _ = self.shared.refs.fetchAdd(1, .monotonic);
        return .{ .shared = self.shared };
    }

    pub fn deinit(self: *CompiledGrammar) void {
        if (self.shared.refs.fetchSub(1, .acq_rel) == 1) {
            const a = self.shared.allocator;
            self.shared.adaptive_token_mask_cache.deinit();
            self.shared.tokenizer_info.deinit();
            self.shared.grammar.deinit();
            a.destroy(self.shared);
        }
    }

    /// Whether two handles point to the same underlying compiled grammar (Rust `Arc::ptr_eq`).
    pub fn shares_storage(self: *const CompiledGrammar, other: *const CompiledGrammar) bool {
        return self.shared == other.shared;
    }

    pub const sharesStorage = shares_storage;

    /// Gets the associated grammar.
    pub fn grammar(self: *const CompiledGrammar) *const Grammar {
        return self.shared.grammar;
    }

    /// Gets the associated tokenizer info.
    pub fn tokenizer_info(self: *const CompiledGrammar) *const TokenizerInfo {
        return &self.shared.tokenizer_info;
    }

    pub const tokenizerInfo = tokenizer_info;

    /// Gets the precomputed adaptive token-mask cache.
    pub fn adaptive_token_mask_cache(self: *const CompiledGrammar) *const AdaptiveTokenMaskCache {
        return &self.shared.adaptive_token_mask_cache;
    }

    pub const adaptiveTokenMaskCache = adaptive_token_mask_cache;

    /// Builds a compiled grammar, including the adaptive token-mask cache.
    /// Takes ownership of `grammar_ptr` on success; clones `tokenizer` into the compiled grammar.
    /// On error, frees `grammar_ptr` as well.
    pub fn build(
        allocator: Allocator,
        grammar_ptr: *Grammar,
        tokenizer: *const TokenizerInfo,
        max_threads: i32,
        rl_cache: ?*RuleLevelCache,
    ) Allocator.Error!CompiledGrammar {
        errdefer grammar_ptr.deinit();
        var tok_copy = tokenizer.cloneShared();
        errdefer tok_copy.deinit();
        var cache = try build_adaptive_token_mask_cache(
            allocator,
            grammar_ptr,
            &tok_copy,
            max_threads,
            rl_cache,
        );
        errdefer cache.deinit();
        return CompiledGrammar.new(allocator, grammar_ptr, tok_copy, cache);
    }

    /// Returns the approximate memory usage of the compiled grammar in bytes.
    pub fn memory_size_bytes(self: *const CompiledGrammar) usize {
        const g = self.grammar();
        const t = self.tokenizer_info();
        const exprs = @as(usize, @intCast(g.num_exprs())) * 4;
        const rules = @as(usize, @intCast(g.num_rules())) * 32;
        var vocab: usize = 0;
        for (t.decoded_vocab) |tok| vocab += tok.len + 16;
        const cache = self.adaptive_token_mask_cache().memory_size_bytes();
        return exprs + rules + vocab + cache;
    }

    pub const memorySizeBytes = memory_size_bytes;

    /// Returns the serialized JSON string of the compiled grammar (caller owns).
    pub fn serialize_json(self: *const CompiledGrammar, allocator: Allocator) Allocator.Error![]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const val = try self.serialize_json_value(arena.allocator());
        return std.json.Stringify.valueAlloc(allocator, val, .{});
    }

    pub const serializeJson = serialize_json;

    /// Serializes the compiled grammar to a JSON value inside `arena_allocator`.
    /// Keys are inserted in lexicographic order to match serde_json's BTreeMap order.
    pub fn serialize_json_value(self: *const CompiledGrammar, allocator: Allocator) Allocator.Error!std.json.Value {
        const grammar_val = try grammar_ser.serialize_json_value_embedded(self.grammar(), allocator);
        const metadata_val = try TokenizerInfo.metadata_value_into(allocator, self.tokenizer_info());
        const cache_val = try serialize_cache_json_value(self.adaptive_token_mask_cache(), allocator);

        var obj = std.json.ObjectMap.empty;
        // Key order: __VERSION__ < adaptive_token_mask_cache < grammar < tokenizer_metadata.
        try obj.put(allocator, "__VERSION__", .{ .string = config.SERIALIZATION_VERSION });
        try obj.put(allocator, "adaptive_token_mask_cache", cache_val);
        try obj.put(allocator, "grammar", grammar_val);
        try obj.put(allocator, "tokenizer_metadata", metadata_val);
        return .{ .object = obj };
    }

    /// Deserializes a compiled grammar and binds it to `tokenizer`.
    pub fn deserialize_json(
        allocator: Allocator,
        json_str: []const u8,
        tokenizer: *const TokenizerInfo,
        diag: ?*DeserializeErrorInfo,
    ) DeserializeErrorAll!CompiledGrammar {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const value = support.parse_json(scratch.allocator(), json_str) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                if (diag) |d| d.* = .{ .InvalidJson = @errorName(err) };
                return error.InvalidJson;
            },
        };
        return CompiledGrammar.deserialize_json_value(allocator, value, tokenizer, diag);
    }

    pub fn deserializeJson(
        allocator: Allocator,
        json_str: []const u8,
        tokenizer: *const TokenizerInfo,
    ) DeserializeErrorAll!CompiledGrammar {
        return deserialize_json(allocator, json_str, tokenizer, null);
    }

    /// Deserializes a compiled grammar from a JSON value.
    pub fn deserialize_json_value(
        allocator: Allocator,
        value: std.json.Value,
        tokenizer: *const TokenizerInfo,
        diag: ?*DeserializeErrorInfo,
    ) DeserializeErrorAll!CompiledGrammar {
        const fail_fmt = struct {
            fn f(a: Allocator, d: ?*DeserializeErrorInfo, msg: []const u8) DeserializeError {
                if (d) |dd| dd.* = .{ .Format = a.dupe(u8, msg) catch "" };
                return error.Format;
            }
        }.f;

        const obj = switch (value) {
            .object => |o| o,
            else => return fail_fmt(allocator, diag, "missing __VERSION__"),
        };

        const ver_val = obj.get("__VERSION__") orelse return fail_fmt(allocator, diag, "missing __VERSION__");
        switch (ver_val) {
            .string => |ver| {
                if (!std.mem.eql(u8, ver, config.SERIALIZATION_VERSION)) {
                    if (diag) |d| {
                        d.* = .{ .Version = .{
                            .expected = config.SERIALIZATION_VERSION,
                            .got = try allocator.dupe(u8, ver),
                        } };
                    }
                    return error.Version;
                }
            },
            else => return fail_fmt(allocator, diag, "missing __VERSION__"),
        }

        const grammar_value = obj.get("grammar") orelse return fail_fmt(allocator, diag, "missing grammar");
        const metadata = obj.get("tokenizer_metadata") orelse return fail_fmt(allocator, diag, "missing tokenizer_metadata");
        try tokenizer.check_metadata_match(metadata, diag);

        const g = try grammar_ser.deserialize_json_value_embedded(allocator, grammar_value, diag);
        errdefer g.deinit();

        const cache_value = obj.get("adaptive_token_mask_cache") orelse
            return fail_fmt(allocator, diag, "Expect a 'adaptive_token_mask_cache' field");
        var cache = try deserialize_cache_json_value(allocator, cache_value, diag);
        errdefer cache.deinit();

        const num_sorted_tokens: i32 = @intCast(tokenizer.sorted_decoded_vocab.len);
        const indices_ok = struct {
            fn ok(indices: []const i32, limit: i32) bool {
                for (indices) |idx| {
                    if (idx < 0 or idx >= limit) return false;
                }
                return true;
            }
        }.ok;

        var it = cache.map.valueIterator();
        while (it.next()) |mask| {
            const bitset_ok = mask.store_type != AdaptiveTokenMaskStoreType.AcceptedBitset or
                mask.accepted_bitset.len() == @as(usize, @intCast(tokenizer.vocab_size));
            if (!bitset_ok or
                !indices_ok(mask.accepted_indices, num_sorted_tokens) or
                !indices_ok(mask.rejected_indices, num_sorted_tokens) or
                !indices_ok(mask.uncertain_indices, num_sorted_tokens))
            {
                return fail_fmt(allocator, diag, "adaptive_token_mask_cache contains a mask that does not match the tokenizer");
            }
        }

        var tok_copy = tokenizer.cloneShared();
        errdefer tok_copy.deinit();
        return CompiledGrammar.new(allocator, g, tok_copy, cache);
    }
};
