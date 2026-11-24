//! The compiled grammar: preprocessing results of a `GrammarMatcher` (`compiled_grammar.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const adaptive_token_mask_mod = @import("AdaptiveTokenMask.zig");
const AdaptiveTokenMaskCache = adaptive_token_mask_mod.AdaptiveTokenMaskCache;
const rule_level_cache_mod = @import("rule_level_cache.zig");
const RuleLevelCache = rule_level_cache_mod.RuleLevelCache;
const token_mask_cache_builder = @import("token_mask_cache_builder.zig");

const config = @import("../config.zig");
const Diagnostic = @import("../Diagnostic.zig").Diagnostic;
const grammar_mod = @import("../grammar.zig");
const DeserializeError = grammar_mod.DeserializeError;
const DeserializeErrorAll = grammar_mod.serialization.DeserializeErrorAll;
const Grammar = grammar_mod.Grammar;
const support = @import("../support.zig");
const tokenizer_mod = @import("../tokenizer.zig");
const TokenizerInfo = tokenizer_mod.TokenizerInfo;

const CompiledGrammarShared = struct {
    allocator: Allocator,
    refs: std.atomic.Value(usize),
    grammar: Grammar,
    tokenizer_info: TokenizerInfo,
    adaptive_token_mask_cache: AdaptiveTokenMaskCache,
};

/// Refcounted value handle to a compiled grammar, holding shared ownership of the
/// optimized `Grammar`, `TokenizerInfo`, and precomputed `AdaptiveTokenMaskCache`.
pub const CompiledGrammar = struct {
    shared: *CompiledGrammarShared,

    /// Creates a compiled grammar from an already-optimized grammar, tokenizer info, and cache,
    /// taking ownership of all three.
    pub fn init(
        allocator: Allocator,
        grammar_in: Grammar,
        tokenizer: TokenizerInfo,
        cache: AdaptiveTokenMaskCache,
    ) Allocator.Error!CompiledGrammar {
        const shared = try allocator.create(CompiledGrammarShared);
        shared.* = .{
            .allocator = allocator,
            .refs = std.atomic.Value(usize).init(1),
            .grammar = grammar_in,
            .tokenizer_info = tokenizer,
            .adaptive_token_mask_cache = cache,
        };
        return .{ .shared = shared };
    }

    pub fn retain(self: *const CompiledGrammar) CompiledGrammar {
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
        self.* = undefined;
    }

    /// Whether two handles point to the same underlying compiled grammar (Rust `Arc::ptr_eq`).
    pub fn sharesStorage(self: *const CompiledGrammar, other: *const CompiledGrammar) bool {
        return self.shared == other.shared;
    }

    /// Gets the associated grammar.
    pub fn grammar(self: *const CompiledGrammar) *const Grammar {
        return &self.shared.grammar;
    }

    /// Gets the associated tokenizer info.
    pub fn tokenizerInfo(self: *const CompiledGrammar) *const TokenizerInfo {
        return &self.shared.tokenizer_info;
    }

    /// Gets the precomputed adaptive token-mask cache.
    pub fn adaptiveTokenMaskCache(self: *const CompiledGrammar) *const AdaptiveTokenMaskCache {
        return &self.shared.adaptive_token_mask_cache;
    }

    /// Builds a compiled grammar, including the adaptive token-mask cache.
    /// Takes ownership of `grammar_in` and retains `tokenizer`.
    /// On error, frees `grammar_in` as well.
    pub fn build(
        allocator: Allocator,
        grammar_in: Grammar,
        tokenizer: *const TokenizerInfo,
        max_threads: ?u32,
        rl_cache: ?*RuleLevelCache,
    ) Allocator.Error!CompiledGrammar {
        var g = grammar_in;
        errdefer g.deinit();
        var tok_copy = tokenizer.retain();
        errdefer tok_copy.deinit();
        var cache = try token_mask_cache_builder.buildAdaptiveTokenMaskCache(
            allocator,
            &g,
            &tok_copy,
            max_threads,
            rl_cache,
        );
        errdefer cache.deinit();
        return init(allocator, g, tok_copy, cache);
    }

    /// Returns the approximate memory usage of the compiled grammar in bytes.
    pub fn memorySizeBytes(self: *const CompiledGrammar) usize {
        const g = self.grammar();
        const t = self.tokenizerInfo();
        const exprs = g.numExprs() * 4;
        const rules = g.numRules() * 32;
        var vocab: usize = 0;
        for (t.decodedVocab()) |tok| vocab += tok.len + 16;
        const cache = self.adaptiveTokenMaskCache().memorySizeBytes();
        return exprs + rules + vocab + cache;
    }

    /// Streams the `"v16"` JSON representation directly to `jw` with keys in strict
    /// lexicographic order (`__VERSION__` < `adaptive_token_mask_cache` < `grammar` <
    /// `tokenizer_metadata`) and zero intermediate DOM tree.
    pub fn writeJson(self: *const CompiledGrammar, jw: *std.json.Stringify) std.json.Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("__VERSION__");
        try jw.write(config.serialization_version);
        try jw.objectField("adaptive_token_mask_cache");
        try self.adaptiveTokenMaskCache().writeJson(jw);
        try jw.objectField("grammar");
        try self.grammar().writeJsonEmbedded(jw);
        try jw.objectField("tokenizer_metadata");
        try self.tokenizerInfo().writeMetadataJson(jw);
        try jw.endObject();
    }

    /// Returns the serialized `"v16"` JSON string of the compiled grammar (caller owns).
    pub fn serializeJson(self: *const CompiledGrammar, allocator: Allocator) Allocator.Error![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        var jw: std.json.Stringify = .{ .writer = &aw.writer };
        self.writeJson(&jw) catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }

    /// Deserializes a compiled grammar from JSON text and validates it against `tokenizer`.
    pub fn deserializeJson(
        allocator: Allocator,
        json_str: []const u8,
        tokenizer: *const TokenizerInfo,
        diag: ?*Diagnostic,
    ) DeserializeErrorAll!CompiledGrammar {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const value = support.parseJson(scratch.allocator(), json_str) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                if (diag) |d| try d.setCopy(allocator, .deserialize_invalid_json, @errorName(err));
                return error.InvalidJson;
            },
        };
        return deserializeJsonValue(allocator, value, tokenizer, diag);
    }

    /// Deserializes a compiled grammar from a parsed JSON value.
    pub fn deserializeJsonValue(
        allocator: Allocator,
        value: std.json.Value,
        tokenizer: *const TokenizerInfo,
        diag: ?*Diagnostic,
    ) DeserializeErrorAll!CompiledGrammar {
        const obj = switch (value) {
            .object => |o| o,
            else => return failFormat(allocator, diag, "missing __VERSION__"),
        };

        const ver_val = obj.get("__VERSION__") orelse return failFormat(allocator, diag, "missing __VERSION__");
        switch (ver_val) {
            .string => |ver| {
                if (!std.mem.eql(u8, ver, config.serialization_version)) {
                    if (diag) |d| try d.setVersionMismatch(allocator, config.serialization_version, ver);
                    return error.Version;
                }
            },
            else => return failFormat(allocator, diag, "missing __VERSION__"),
        }

        const grammar_value = obj.get("grammar") orelse return failFormat(allocator, diag, "missing grammar");
        const metadata = obj.get("tokenizer_metadata") orelse return failFormat(allocator, diag, "missing tokenizer_metadata");
        try tokenizer.checkMetadataMatch(metadata, diag);

        var g = try grammar_mod.deserializeJsonValueEmbedded(allocator, grammar_value, diag);
        errdefer g.deinit();

        const cache_value = obj.get("adaptive_token_mask_cache") orelse
            return failFormat(allocator, diag, "Expect a 'adaptive_token_mask_cache' field");
        var cache = try AdaptiveTokenMaskCache.deserializeJsonValue(allocator, cache_value, diag);
        errdefer cache.deinit();

        const num_sorted_tokens: i32 = @intCast(tokenizer.sortedDecodedVocab().len);
        const vocab_size = tokenizer.vocabSize();
        for (cache.map.values()) |*mask| {
            const storage_ok = switch (mask.storage) {
                .accepted => |idxs| indicesOk(idxs, num_sorted_tokens),
                .rejected => |idxs| indicesOk(idxs, num_sorted_tokens),
                .accepted_bitset => |bs| bs.len() == vocab_size,
            };
            if (!storage_ok or !indicesOk(mask.uncertain_indices, num_sorted_tokens)) {
                return failFormat(
                    allocator,
                    diag,
                    "adaptive_token_mask_cache contains a mask that does not match the tokenizer",
                );
            }
        }

        var tok_copy = tokenizer.retain();
        errdefer tok_copy.deinit();
        return init(allocator, g, tok_copy, cache);
    }
};

fn indicesOk(indices: []const i32, limit: i32) bool {
    for (indices) |idx| {
        if (idx < 0 or idx >= limit) return false;
    }
    return true;
}

fn failFormat(
    allocator: Allocator,
    diag: ?*Diagnostic,
    msg: []const u8,
) (DeserializeError || Allocator.Error) {
    if (diag) |d| try d.setCopy(allocator, .deserialize_format, msg);
    return error.Format;
}

test {
    std.testing.refAllDecls(CompiledGrammar);
}
