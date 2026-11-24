//! Batched matcher operations for processing multiple `GrammarMatcher`s
//! (`batch_grammar_matcher.rs`), with worker-thread parallel bitmask filling.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Diagnostic = @import("../Diagnostic.zig").Diagnostic;
const matcher_mod = @import("../matcher.zig");
const MatcherError = matcher_mod.MatcherError;
const grammar_matcher = @import("GrammarMatcher.zig");
const GrammarMatcher = grammar_matcher.GrammarMatcher;
const token_bitmask = @import("TokenBitmask.zig");
const TokenBitmask = token_bitmask.TokenBitmask;
const TokenBitmaskConstView = token_bitmask.TokenBitmaskConstView;
const TokenBitmaskView = token_bitmask.TokenBitmaskView;
const applyTokenBitmaskInplaceCpuBatch = token_bitmask.applyTokenBitmaskInplaceCpuBatch;
const bitmaskSize = token_bitmask.bitmaskSize;

/// Batched coordinator for driving multiple `GrammarMatcher`s together.
pub const BatchMatcher = struct {
    allocator: Allocator,
    max_threads: ?u32,

    pub const Options = struct {
        max_threads: ?u32 = null,
    };

    pub fn init(allocator: Allocator, options: Options) BatchMatcher {
        return .{
            .allocator = allocator,
            .max_threads = options.max_threads,
        };
    }

    pub fn deinit(self: *BatchMatcher) void {
        self.* = undefined;
    }

    pub inline fn maxThreads(self: *const BatchMatcher) ?u32 {
        return self.max_threads;
    }

    /// Returns the resolved worker thread count (`>= 1`), treating `null` or `0` as hardware concurrency.
    pub fn effectiveThreads(self: *const BatchMatcher) usize {
        const cpu_count = std.Thread.getCpuCount() catch 1;
        const requested: usize = if (self.max_threads) |mt|
            (if (mt == 0) cpu_count else @as(usize, mt))
        else
            cpu_count;
        return @max(requested, 1);
    }

    fn checkBatchSize(
        self: *const BatchMatcher,
        matchers_len: usize,
        other_len: usize,
        other_name: []const u8,
        diag: ?*Diagnostic,
    ) MatcherError!void {
        if (matchers_len == other_len) return;
        if (diag) |d| {
            try d.setFmt(
                self.allocator,
                .message,
                "The size of matchers ({d}) and {s} ({d}) should be the same.",
                .{ matchers_len, other_name, other_len },
            );
        }
        return error.InvalidArgument;
    }

    fn indicesAreDistinct(self: *const BatchMatcher, indices: ?[]const usize) Allocator.Error!bool {
        const idxs = indices orelse return true;
        if (idxs.len <= 1) return true;
        if (idxs.len <= 32) {
            for (idxs, 0..) |a, i| {
                for (idxs[i + 1 ..]) |b| {
                    if (a == b) return false;
                }
            }
            return true;
        }
        const sorted = try self.allocator.dupe(usize, idxs);
        defer self.allocator.free(sorted);
        std.mem.sortUnstable(usize, sorted, {}, std.sort.asc(usize));
        for (0..sorted.len - 1) |i| {
            if (sorted[i] == sorted[i + 1]) return false;
        }
        return true;
    }

    /// Fills `bitmask` rows for `matchers` (optionally indexed by `indices`), parallelizing across
    /// disjoint matchers and rows when `effectiveThreads() > 1`, `matchers.len >= 2`, and target
    /// rows are distinct.
    pub fn fillNextTokenBitmask(
        self: *const BatchMatcher,
        matchers: []GrammarMatcher,
        bitmask: *TokenBitmask,
        indices: ?[]const usize,
        diag: ?*Diagnostic,
    ) MatcherError!void {
        return self.fillNextTokenBitmaskView(matchers, bitmask.view(), indices, diag);
    }

    /// Fills borrowed `view` rows for `matchers` (shared implementation with `fillNextTokenBitmask`
    /// and `fillNextTokenBitmaskRaw`).
    pub fn fillNextTokenBitmaskView(
        self: *const BatchMatcher,
        matchers: []GrammarMatcher,
        view: TokenBitmaskView,
        indices: ?[]const usize,
        diag: ?*Diagnostic,
    ) MatcherError!void {
        if (indices) |idxs| {
            try self.checkBatchSize(idxs.len, matchers.len, "matchers", diag);
        }
        if (matchers.len == 0) return;

        // Validate all row indices and matcher vocab sizes upfront before spawning workers.
        for (matchers, 0..) |*matcher, batch_id| {
            const row_idx = if (indices) |idxs| idxs[batch_id] else batch_id;
            if (row_idx >= view.batch_size) {
                if (diag) |d| {
                    try d.setFmt(
                        self.allocator,
                        .message,
                        "The index {d} is out of range [0, {d}) for batch_id {d}.",
                        .{ row_idx, view.batch_size, batch_id },
                    );
                }
                return error.InvalidArgument;
            }
            const matcher_vocab = matcher.tokenizerInfo().vocabSize();
            if (view.vocab_size != matcher_vocab) {
                if (diag) |d| {
                    try d.setFmt(
                        self.allocator,
                        .message,
                        "The provided bitmask vocab_size ({d}) does not match tokenizer vocab_size ({d})",
                        .{ view.vocab_size, matcher_vocab },
                    );
                }
                return error.InvalidArgument;
            }
        }

        const effective = self.effectiveThreads();
        const can_parallelize = effective > 1 and matchers.len >= 2 and try self.indicesAreDistinct(indices);

        if (!can_parallelize) {
            for (matchers, 0..) |*matcher, batch_id| {
                const row_idx = if (indices) |idxs| idxs[batch_id] else batch_id;
                _ = try matcher.fillNextTokenBitmaskView(view, row_idx, diag);
            }
            return;
        }

        const ParallelCtx = struct {
            matchers: []GrammarMatcher,
            view: TokenBitmaskView,
            indices: ?[]const usize,
            want_diag: bool,
            next_idx: std.atomic.Value(usize),
            has_error: std.atomic.Value(bool),
            err_mutex: std.atomic.Mutex,
            first_error: ?MatcherError,
            winning_diag: Diagnostic,
            winning_diag_alloc: Allocator,

            fn lockErr(ctx: *@This()) void {
                while (!ctx.err_mutex.tryLock()) {
                    std.atomic.spinLoopHint();
                }
            }

            fn recordError(
                ctx: *@This(),
                err: MatcherError,
                local_diag: *Diagnostic,
                matcher_alloc: Allocator,
            ) void {
                ctx.lockErr();
                defer ctx.err_mutex.unlock();
                if (ctx.first_error == null) {
                    ctx.first_error = err;
                    ctx.winning_diag = local_diag.*;
                    ctx.winning_diag_alloc = matcher_alloc;
                    local_diag.* = .{};
                    ctx.has_error.store(true, .release);
                } else {
                    local_diag.deinit(matcher_alloc);
                }
            }

            fn run(ctx: *@This()) void {
                while (!ctx.has_error.load(.acquire)) {
                    const idx = ctx.next_idx.fetchAdd(1, .monotonic);
                    if (idx >= ctx.matchers.len) break;

                    const row_idx = if (ctx.indices) |idxs| idxs[idx] else idx;
                    var local_diag: Diagnostic = .{};
                    const diag_ptr: ?*Diagnostic = if (ctx.want_diag) &local_diag else null;

                    _ = ctx.matchers[idx].fillNextTokenBitmaskView(ctx.view, row_idx, diag_ptr) catch |err| {
                        ctx.recordError(err, &local_diag, ctx.matchers[idx].allocator);
                        continue;
                    };
                }
            }
        };

        var ctx = ParallelCtx{
            .matchers = matchers,
            .view = view,
            .indices = indices,
            .want_diag = diag != null,
            .next_idx = std.atomic.Value(usize).init(0),
            .has_error = std.atomic.Value(bool).init(false),
            .err_mutex = .unlocked,
            .first_error = null,
            .winning_diag = .{},
            .winning_diag_alloc = self.allocator,
        };

        const worker_total = @min(effective, matchers.len);
        const extra_threads = worker_total - 1;
        var stack_threads: [64]?std.Thread = undefined;
        const heap_threads: ?[]?std.Thread = if (extra_threads > stack_threads.len)
            try self.allocator.alloc(?std.Thread, extra_threads)
        else
            null;
        defer if (heap_threads) |ht| self.allocator.free(ht);

        const threads = if (heap_threads) |ht| ht else stack_threads[0..extra_threads];
        @memset(threads, null);

        for (threads) |*slot| {
            slot.* = std.Thread.spawn(.{}, ParallelCtx.run, .{&ctx}) catch null;
        }
        ParallelCtx.run(&ctx);
        for (threads) |slot| {
            if (slot) |t| t.join();
        }

        if (ctx.first_error) |err| {
            if (diag) |d| {
                d.clear(self.allocator);
                d.* = ctx.winning_diag;
            } else {
                ctx.winning_diag.deinit(ctx.winning_diag_alloc);
            }
            return err;
        }
    }

    /// Fills raw `bitmask` of `shape` for `matchers` using the shared `fillNextTokenBitmaskView` path.
    pub fn fillNextTokenBitmaskRaw(
        self: *const BatchMatcher,
        matchers: []GrammarMatcher,
        bitmask: []i32,
        shape: []const i64,
        indices: ?[]const usize,
        diag: ?*Diagnostic,
    ) MatcherError!void {
        if (indices) |idxs| {
            try self.checkBatchSize(idxs.len, matchers.len, "matchers", diag);
        }
        if (matchers.len == 0) return;

        const vocab_size = matchers[0].tokenizerInfo().vocabSize();
        const expected_wpr = bitmaskSize(vocab_size);
        const expected_wpr_i64: i64 = std.math.cast(i64, expected_wpr) orelse return error.InvalidArgument;

        const batch_rows: usize = if (shape.len == 1) blk: {
            if (shape[0] != expected_wpr_i64) {
                if (diag) |d| try d.setFmt(
                    self.allocator,
                    .message,
                    "The provided bitmask's shape is not valid: should be ({d}, )",
                    .{expected_wpr},
                );
                return error.InvalidArgument;
            }
            break :blk 1;
        } else if (shape.len == 2) blk: {
            if (shape[0] < 0 or shape[1] != expected_wpr_i64) {
                if (diag) |d| try d.setFmt(
                    self.allocator,
                    .message,
                    "The provided bitmask's shape is not valid: should be (batch_size, {d})",
                    .{expected_wpr},
                );
                return error.InvalidArgument;
            }
            break :blk @intCast(shape[0]);
        } else {
            if (diag) |d| try d.setFmt(
                self.allocator,
                .message,
                "The provided bitmask's shape is not valid: should be (batch_size, {d})",
                .{expected_wpr},
            );
            return error.InvalidArgument;
        };

        const view = TokenBitmaskView.init(bitmask, batch_rows, vocab_size) catch {
            if (diag) |d| d.setStatic(.message, "The provided bitmask buffer is smaller than its shape");
            return error.InvalidArgument;
        };
        return self.fillNextTokenBitmaskView(matchers, view, indices, diag);
    }

    /// Batched `GrammarMatcher.acceptToken`, returning a caller-owned `[]bool`.
    pub fn acceptTokenBatch(
        self: *const BatchMatcher,
        allocator: Allocator,
        matchers: []GrammarMatcher,
        token_ids: []const u32,
        diag: ?*Diagnostic,
    ) MatcherError![]bool {
        try self.checkBatchSize(matchers.len, token_ids.len, "token_ids", diag);
        const out = try allocator.alloc(bool, matchers.len);
        errdefer allocator.free(out);
        for (matchers, token_ids, 0..) |*matcher, token_id, i| {
            out[i] = try matcher.acceptToken(token_id, diag);
        }
        return out;
    }

    /// Zero-allocation variant of `acceptTokenBatch` writing into caller-supplied `out`.
    pub fn acceptTokenBatchInto(
        self: *const BatchMatcher,
        out: []bool,
        matchers: []GrammarMatcher,
        token_ids: []const u32,
        diag: ?*Diagnostic,
    ) MatcherError!void {
        try self.checkBatchSize(matchers.len, token_ids.len, "token_ids", diag);
        try self.checkBatchSize(matchers.len, out.len, "out", diag);
        for (matchers, token_ids, 0..) |*matcher, token_id, i| {
            out[i] = try matcher.acceptToken(token_id, diag);
        }
    }

    /// Batched `GrammarMatcher.acceptString`, returning a caller-owned `[]bool`.
    pub fn acceptStringBatch(
        self: *const BatchMatcher,
        allocator: Allocator,
        matchers: []GrammarMatcher,
        inputs: []const []const u8,
        diag: ?*Diagnostic,
    ) MatcherError![]bool {
        try self.checkBatchSize(matchers.len, inputs.len, "input_strs", diag);
        const out = try allocator.alloc(bool, matchers.len);
        errdefer allocator.free(out);
        for (matchers, inputs, 0..) |*matcher, input, i| {
            out[i] = try matcher.acceptString(input, diag);
        }
        return out;
    }

    /// Zero-allocation variant of `acceptStringBatch` writing into caller-supplied `out`.
    pub fn acceptStringBatchInto(
        self: *const BatchMatcher,
        out: []bool,
        matchers: []GrammarMatcher,
        inputs: []const []const u8,
        diag: ?*Diagnostic,
    ) MatcherError!void {
        try self.checkBatchSize(matchers.len, inputs.len, "input_strs", diag);
        try self.checkBatchSize(matchers.len, out.len, "out", diag);
        for (matchers, inputs, 0..) |*matcher, input, i| {
            out[i] = try matcher.acceptString(input, diag);
        }
    }

    /// Batched `GrammarMatcher.rollback`, validating history depth upfront before rolling back.
    pub fn rollbackBatch(
        self: *const BatchMatcher,
        matchers: []GrammarMatcher,
        num_tokens: []const usize,
        diag: ?*Diagnostic,
    ) MatcherError!void {
        try self.checkBatchSize(matchers.len, num_tokens.len, "num_tokens", diag);
        for (matchers, num_tokens) |*matcher, count| {
            if (count > matcher.token_length_history.items.len) {
                return matcher.rollback(count, diag);
            }
        }
        for (matchers, num_tokens) |*matcher, count| {
            try matcher.rollback(count, diag);
        }
    }

    /// Writes the sampling temperature of each matcher (`-1.0` when none applies) into `temperatures`.
    pub fn fillTemperatureBatch(
        self: *const BatchMatcher,
        matchers: []const GrammarMatcher,
        temperatures: []f32,
        indices: ?[]const usize,
        diag: ?*Diagnostic,
    ) MatcherError!void {
        if (indices) |idxs| {
            if (idxs.len != matchers.len) {
                if (diag) |d| d.setStatic(.message, "The indices size must match the number of matchers");
                return error.InvalidArgument;
            }
        }
        for (matchers, 0..) |_, i| {
            const position = if (indices) |idxs| idxs[i] else i;
            if (position >= temperatures.len) {
                if (diag) |d| {
                    try d.setFmt(
                        self.allocator,
                        .message,
                        "The index {d} is out of bounds for the temperatures tensor",
                        .{position},
                    );
                }
                return error.InvalidArgument;
            }
        }
        for (matchers, 0..) |matcher, i| {
            const position = if (indices) |idxs| idxs[i] else i;
            temperatures[position] = matcher.temperature() orelse -1.0;
        }
    }

    /// Applies `bitmask` to batched `logits` in place, validating dimensions and indices.
    pub fn applyBitmaskInplaceBatch(
        self: *const BatchMatcher,
        bitmask: *const TokenBitmask,
        logits: []f32,
        indices: ?[]const usize,
        diag: ?*Diagnostic,
    ) MatcherError!void {
        return self.applyBitmaskViewInplaceBatch(bitmask.constView(), logits, indices, diag);
    }

    /// Applies read-only bitmask `view` to batched `logits` in place.
    pub fn applyBitmaskViewInplaceBatch(
        self: *const BatchMatcher,
        view: TokenBitmaskConstView,
        logits: []f32,
        indices: ?[]const usize,
        diag: ?*Diagnostic,
    ) MatcherError!void {
        const needed_logits = std.math.mul(usize, view.batch_size, view.vocab_size) catch {
            if (diag) |d| d.setStatic(.message, "Logits buffer size overflow");
            return error.InvalidArgument;
        };
        if (logits.len < needed_logits) {
            if (diag) |d| {
                try d.setFmt(
                    self.allocator,
                    .message,
                    "The logits buffer length ({d}) is smaller than batch_size * vocab_size ({d})",
                    .{ logits.len, needed_logits },
                );
            }
            return error.InvalidArgument;
        }
        if (indices) |idxs| {
            for (idxs) |row_idx| {
                if (row_idx >= view.batch_size) {
                    if (diag) |d| {
                        try d.setFmt(
                            self.allocator,
                            .message,
                            "The index {d} is out of range [0, {d})",
                            .{ row_idx, view.batch_size },
                        );
                    }
                    return error.InvalidArgument;
                }
            }
        }
        applyTokenBitmaskInplaceCpuBatch(logits, view.words, view.vocab_size, view.batch_size, indices);
    }
};

test {
    std.testing.refAllDecls(BatchMatcher);
}
