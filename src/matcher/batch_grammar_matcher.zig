//! Batched matcher operations for processing multiple `GrammarMatcher`s
//! (`batch_grammar_matcher.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const error_mod = @import("error.zig");
const MatcherError = error_mod.MatcherError;
const MatcherErrorInfo = error_mod.MatcherErrorInfo;
const grammar_matcher = @import("grammar_matcher.zig");
const GrammarMatcher = grammar_matcher.GrammarMatcher;
const token_bitmask_mod = @import("token_bitmask.zig");
const TokenBitmask = token_bitmask_mod.TokenBitmask;

fn check_batch_size(
    allocator: Allocator,
    matchers: usize,
    other: usize,
    other_name: []const u8,
    diag: ?*MatcherErrorInfo,
) MatcherError!void {
    if (matchers == other) return;
    return error_mod.set_invalid_arg_fmt(
        diag,
        allocator,
        "The size of matchers ({d}) and {s} ({d}) should be the same.",
        .{ matchers, other_name, other },
    );
}

/// A batched helper for driving multiple `GrammarMatcher`s together.
pub const BatchGrammarMatcher = struct {
    max_threads: i32,

    pub fn new(max_threads_arg: i32) BatchGrammarMatcher {
        return .{ .max_threads = max_threads_arg };
    }

    pub fn default() BatchGrammarMatcher {
        return BatchGrammarMatcher.new(-1);
    }

    pub fn get_max_threads(self: *const BatchGrammarMatcher) i32 {
        return self.max_threads;
    }

    /// A batched version of `GrammarMatcher.accept_token` (caller owns returned slice).
    pub fn batch_accept_token(
        allocator: Allocator,
        matchers: []GrammarMatcher,
        token_ids: []const i32,
        diag: ?*MatcherErrorInfo,
    ) MatcherError![]bool {
        try check_batch_size(allocator, matchers.len, token_ids.len, "token_ids", diag);
        const out = try allocator.alloc(bool, matchers.len);
        errdefer allocator.free(out);
        for (matchers, token_ids, 0..) |*matcher, token_id, i| {
            out[i] = try matcher.accept_token(token_id);
        }
        return out;
    }

    /// A batched version of `GrammarMatcher.accept_bytes` (caller owns returned slice).
    pub fn batch_accept_string(
        allocator: Allocator,
        matchers: []GrammarMatcher,
        inputs: []const []const u8,
        diag: ?*MatcherErrorInfo,
    ) MatcherError![]bool {
        try check_batch_size(allocator, matchers.len, inputs.len, "input_strs", diag);
        const out = try allocator.alloc(bool, matchers.len);
        errdefer allocator.free(out);
        for (matchers, inputs, 0..) |*matcher, input, i| {
            out[i] = try matcher.accept_bytes(input);
        }
        return out;
    }

    /// A batched version of `GrammarMatcher.rollback`.
    pub fn batch_rollback(
        allocator: Allocator,
        matchers: []GrammarMatcher,
        num_tokens: []const i32,
        diag: ?*MatcherErrorInfo,
    ) MatcherError!void {
        try check_batch_size(allocator, matchers.len, num_tokens.len, "num_tokens", diag);
        for (matchers, num_tokens) |*matcher, count| {
            try matcher.rollback(count, diag);
        }
    }

    /// A batched version of `GrammarMatcher.fill_next_token_bitmask`.
    pub fn batch_fill_next_token_bitmask(
        allocator: Allocator,
        matchers: []GrammarMatcher,
        bitmask: []i32,
        shape: []const i64,
        indices: ?[]const i32,
        diag: ?*MatcherErrorInfo,
    ) MatcherError!void {
        if (indices) |idxs| {
            try check_batch_size(allocator, idxs.len, matchers.len, "matchers", diag);
        }
        const rows: i64 = if (shape.len > 0) shape[0] else 0;
        for (matchers, 0..) |*matcher, batch_id| {
            const index: i32 = if (indices) |idxs| idxs[batch_id] else @intCast(batch_id);
            if (index < 0 or @as(i64, index) >= rows) {
                return error_mod.set_invalid_arg_fmt(
                    diag,
                    allocator,
                    "The index {d} is out of range [0, {d}) for batch_id {d}.",
                    .{ index, rows, batch_id },
                );
            }
            _ = try matcher.fill_next_token_bitmask(bitmask, shape, index, diag);
        }
    }

    /// Writes the temperature of each matcher (`-1` when none applies) into `temperatures`.
    pub fn batch_fill_temperature(
        allocator: Allocator,
        matchers: []const GrammarMatcher,
        temperatures: []f32,
        indices: ?[]const i32,
        diag: ?*MatcherErrorInfo,
    ) MatcherError!void {
        if (indices) |idxs| {
            if (idxs.len != matchers.len) {
                return error_mod.set_invalid_arg(
                    diag,
                    allocator,
                    "The indices size must match the number of matchers",
                );
            }
        }
        for (matchers, 0..) |matcher, i| {
            const position: i64 = if (indices) |idxs| idxs[i] else @intCast(i);
            if (position < 0 or @as(u64, @intCast(position)) >= temperatures.len) {
                return error_mod.set_invalid_arg_fmt(
                    diag,
                    allocator,
                    "The index {d} is out of bounds for the temperatures tensor",
                    .{position},
                );
            }
            temperatures[@intCast(position)] = matcher.temperature() orelse -1.0;
        }
    }

    // --- Idiomatic Zig 0.17 methods ---

    pub fn fillBitmask(
        allocator: Allocator,
        matchers: []GrammarMatcher,
        bitmask: *TokenBitmask,
        indices: ?[]const i32,
    ) MatcherError!void {
        const s = bitmask.shape();
        return batch_fill_next_token_bitmask(allocator, matchers, bitmask.words, &s, indices, null);
    }

    pub fn acceptTokens(
        allocator: Allocator,
        matchers: []GrammarMatcher,
        token_ids: []const i32,
    ) MatcherError![]bool {
        return batch_accept_token(allocator, matchers, token_ids, null);
    }

    pub fn acceptStrings(
        allocator: Allocator,
        matchers: []GrammarMatcher,
        inputs: []const []const u8,
    ) MatcherError![]bool {
        return batch_accept_string(allocator, matchers, inputs, null);
    }
};
