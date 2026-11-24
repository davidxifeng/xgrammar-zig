//! Grammar-guided generation: token bitmasks, stateful `GrammarMatcher`, and parallel `BatchMatcher`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Unified error set for matcher construction, token bitmask views, and decoding operations.
/// Detailed diagnostic messages are populated through `?*Diagnostic`.
pub const MatcherError = Allocator.Error || error{
    /// The matcher already accepted the stop token.
    Terminated,
    /// `override_stop_tokens` was empty.
    EmptyOverrideStopTokens,
    /// An override stop token id is outside the vocabulary.
    StopTokenOutOfRange,
    /// The default temperature is negative or not finite.
    InvalidDefaultTemperature,
    /// More tokens were rolled back than recorded.
    RollbackTooFar,
    /// A bitmask, temperature, or draft-tree argument has an invalid shape, dtype, or index.
    InvalidArgument,
};

pub const token_bitmask = @import("matcher/TokenBitmask.zig");
pub const grammar_matcher = @import("matcher/GrammarMatcher.zig");
pub const batch_mod = @import("matcher/batch.zig");

pub const BITS_PER_WORD = token_bitmask.BITS_PER_WORD;
pub const BitmaskDlType = token_bitmask.BitmaskDlType;
pub const TokenBitmask = token_bitmask.TokenBitmask;
pub const TokenBitmaskView = token_bitmask.TokenBitmaskView;
pub const TokenBitmaskConstView = token_bitmask.TokenBitmaskConstView;
pub const dlType = token_bitmask.dlType;
pub const bitmaskSize = token_bitmask.bitmaskSize;
pub const bitmaskRowRange = token_bitmask.bitmaskRowRange;
pub const resetBitmaskWords = token_bitmask.resetBitmaskWords;
pub const getMaskedTokensFromBitmask = token_bitmask.getMaskedTokensFromBitmask;
pub const isSingleTokenBitmask = token_bitmask.isSingleTokenBitmask;
pub const applyTokenBitmaskInplaceCpu = token_bitmask.applyTokenBitmaskInplaceCpu;
pub const applyTokenBitmaskInplaceCpuBatch = token_bitmask.applyTokenBitmaskInplaceCpuBatch;

pub const Capture = grammar_matcher.Capture;
pub const GrammarMatcher = grammar_matcher.GrammarMatcher;

pub const BatchMatcher = batch_mod.BatchMatcher;

test {
    _ = token_bitmask;
    _ = grammar_matcher;
    _ = batch_mod;
    std.testing.refAllDecls(@This());
}

test "matcher core json workflow, jump forward, rollback, fork, bitmask, and batch" {
    const a = std.testing.allocator;
    const tokenizer_mod = @import("tokenizer.zig");
    const compiler_mod = @import("compiler.zig");
    const Diagnostic = @import("Diagnostic.zig").Diagnostic;

    var tok = try tokenizer_mod.TokenizerInfo.init(
        a,
        &.{ "{\"ok\":", "true", "false", "}", "bad", "</s>" },
        .{},
    );
    defer tok.deinit();

    var comp = try compiler_mod.GrammarCompiler.init(a, &tok, .{});
    defer comp.deinit();

    var compiled = try comp.compileJsonSchema(
        "{\"type\":\"object\",\"properties\":{\"ok\":{\"type\":\"boolean\"}},\"required\":[\"ok\"],\"additionalProperties\":false}",
        .{
            .any_whitespace = false,
            .separators = .{ .item = ",", .colon = ":" },
            .strict_mode = true,
        },
    );
    defer compiled.deinit();

    var matcher = try GrammarMatcher.init(a, &compiled, .{});
    defer matcher.deinit();

    // Jump-forward string at start must be `{"ok":`.
    const jf0 = try matcher.findJumpForwardString(a, null);
    defer a.free(jf0);
    try std.testing.expectEqualStrings("{\"ok\":", jf0);

    var bitmask = try TokenBitmask.initSingle(a, tok.vocabSize());
    defer bitmask.deinit();

    try std.testing.expect(try matcher.fillNextTokenBitmask(&bitmask, 0, null));
    try std.testing.expectEqual(@as(?u32, 0), bitmask.singleAllowedToken());

    // Fork independent branch.
    var forked = try matcher.fork();
    defer forked.deinit();

    try std.testing.expect(try matcher.acceptToken(0, null));
    try std.testing.expect(!matcher.isCompleted());
    try std.testing.expect(try matcher.fillNextTokenBitmask(&bitmask, 0, null));
    try std.testing.expect(try matcher.acceptToken(1, null));
    try std.testing.expect(!matcher.isCompleted());
    try std.testing.expect(try matcher.acceptToken(3, null));
    try std.testing.expect(matcher.isCompleted());
    try std.testing.expect(!matcher.isTerminated());

    // Apply logits check before accepting stop token.
    var logits = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0 };
    try std.testing.expect(try matcher.fillNextTokenBitmask(&bitmask, 0, null));
    bitmask.applyToLogits(&logits);
    try std.testing.expectEqual(@as(f32, 6.0), logits[5]);
    try std.testing.expectEqual(-std.math.inf(f32), logits[0]);

    // Rollback 1 token ("}"), re-accept via forked / rollback check.
    try matcher.rollback(1, null);
    try std.testing.expect(!matcher.isCompleted());
    try std.testing.expect(try matcher.acceptString("}", null));
    try std.testing.expect(matcher.isCompleted());
    try std.testing.expect(try matcher.acceptToken(5, null)); // </s>
    try std.testing.expect(matcher.isTerminated());

    // Forked branch still at initial position.
    try std.testing.expect(try forked.acceptString("{\"ok\":false}", null));
    try std.testing.expect(forked.isCompleted());

    // Terminated matcher returns error.Terminated with Diagnostic on fillNextTokenBitmask & findJumpForwardString.
    var diag: Diagnostic = .{};
    defer diag.deinit(a);
    try std.testing.expectError(error.Terminated, matcher.fillNextTokenBitmask(&bitmask, 0, &diag));
    try std.testing.expectEqual(Diagnostic.Kind.matcher_terminated, diag.kind);
    try std.testing.expectError(error.Terminated, matcher.findJumpForwardString(a, &diag));
    try std.testing.expectEqual(Diagnostic.Kind.matcher_terminated, diag.kind);

    // Out-of-range token id returns false cleanly (matching upstream behavior).
    try std.testing.expect(!try forked.acceptToken(999, null));

    // Batch operations.
    var batch_matchers = [_]GrammarMatcher{
        try GrammarMatcher.init(a, &compiled, .{}),
        try GrammarMatcher.init(a, &compiled, .{}),
    };
    defer for (&batch_matchers) |*m| m.deinit();

    var bm2 = try TokenBitmask.init(a, 2, tok.vocabSize());
    defer bm2.deinit();
    var batch = BatchMatcher.init(a, .{ .max_threads = 2 });
    defer batch.deinit();
    try batch.fillNextTokenBitmask(&batch_matchers, &bm2, null, null);
    const res = try batch.acceptTokenBatch(a, &batch_matchers, &.{ 0, 4 }, null);
    defer a.free(res);
    try std.testing.expect(res[0]);
    try std.testing.expect(!res[1]);
}

test "matcher captures, budgets, draft tree, diagnostics, and OOM safety" {
    const a = std.testing.allocator;
    const tokenizer_mod = @import("tokenizer.zig");
    const compiler_mod = @import("compiler.zig");
    const Diagnostic = @import("Diagnostic.zig").Diagnostic;

    var tok = try tokenizer_mod.TokenizerInfo.init(
        a,
        &.{ "a", "b", "x", "y", "</s>" },
        .{},
    );
    defer tok.deinit();

    var comp = try compiler_mod.GrammarCompiler.init(a, &tok, .{});
    defer comp.deinit();

    var cg = try comp.compileEbnf(
        "root ::= cap \"-\"? [a-b]+\ncap[capture=\"tag\", max_tokens=2, temperature=0.5] ::= [xy]+",
        .{},
    );
    defer cg.deinit();

    var m = try GrammarMatcher.init(a, &cg, .{});
    defer m.deinit();
    try std.testing.expectEqual(@as(?f32, 0.5), m.temperature());
    try std.testing.expect(try m.acceptString("xy", null));
    try std.testing.expect(try m.acceptString("ab", null));
    try std.testing.expect(m.isCompleted());
    const caps = try m.getCaptures(a, true);
    defer Capture.freeSlice(a, caps);
    try std.testing.expectEqual(@as(usize, 1), caps.len);
    try std.testing.expectEqualStrings("tag", caps[0].name);
    try std.testing.expectEqualStrings("xy", caps[0].bytes);

    // debugPrintInternalState streams cleanly without allocations.
    var state_aw: std.Io.Writer.Allocating = .init(a);
    defer state_aw.deinit();
    try m.debugPrintInternalState(&state_aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, state_aw.written(), "steps in history") != null);

    // Draft tree test: root -> token 0 ("a") or sibling -> token 1 ("b").
    var cg_tree = try comp.compileEbnf("root ::= [ab]+", .{});
    defer cg_tree.deinit();
    var mt = try GrammarMatcher.init(a, &cg_tree, .{});
    defer mt.deinit();

    var bm = try TokenBitmask.init(a, 3, tok.vocabSize());
    defer bm.deinit();
    var temps: [3]f32 = undefined;
    const ok = try mt.traverseDraftTree(
        &.{ 1, -1, -1 },
        &.{ -1, 2, -1 },
        &.{ 0, 0, 2 },
        &bm,
        1.0,
        &temps,
        null,
    );
    try std.testing.expect(ok);
    const masked_node0 = try bm.maskedTokens(a, 0);
    defer a.free(masked_node0);
    // Nodes 0 and 1 can accept "a" (0) or "b" (1); token "x" (2) at node 2 is rejected -> node 2 row zeroed.
    try std.testing.expect(std.mem.indexOfScalar(u32, masked_node0, 2) != null);
    try std.testing.expectEqual(@as(i32, 0), bm.constRow(2)[0]);

    // Option & rollback diagnostics.
    var diag: Diagnostic = .{};
    defer diag.deinit(a);
    try std.testing.expectError(
        error.EmptyOverrideStopTokens,
        GrammarMatcher.init(a, &cg_tree, .{ .override_stop_tokens = &.{}, .diag = &diag }),
    );
    try std.testing.expectEqual(Diagnostic.Kind.matcher_empty_override_stop_tokens, diag.kind);

    try std.testing.expectError(
        error.StopTokenOutOfRange,
        GrammarMatcher.init(a, &cg_tree, .{ .override_stop_tokens = &.{99}, .diag = &diag }),
    );
    try std.testing.expectEqual(Diagnostic.Kind.matcher_stop_token_out_of_range, diag.kind);

    try std.testing.expectError(
        error.InvalidDefaultTemperature,
        GrammarMatcher.init(a, &cg_tree, .{ .default_temperature = -0.1, .diag = &diag }),
    );
    try std.testing.expectEqual(Diagnostic.Kind.matcher_invalid_default_temperature, diag.kind);

    try std.testing.expectError(error.RollbackTooFar, mt.rollback(5, &diag));
    try std.testing.expectEqual(Diagnostic.Kind.matcher_rollback_too_far, diag.kind);

    // OOM safety on GrammarMatcher.init and fork.
    const check_oom = struct {
        fn run(alloc: Allocator, compiled: *const compiler_mod.CompiledGrammar) !void {
            var base = try GrammarMatcher.init(alloc, compiled, .{ .default_temperature = 0.7 });
            defer base.deinit();
            var cloned = try base.fork();
            defer cloned.deinit();
        }
    }.run;
    try std.testing.checkAllAllocationFailures(a, check_oom, .{&cg});
}

test "BatchMatcher parallel max_threads=4 matches sequential max_threads=1 bit-for-bit across states" {
    const a = std.testing.allocator;
    const tokenizer_mod = @import("tokenizer.zig");
    const compiler_mod = @import("compiler.zig");
    const Diagnostic = @import("Diagnostic.zig").Diagnostic;

    var tok = try tokenizer_mod.TokenizerInfo.init(a, &.{
        "{",   "}",     ":",   ",",    "\"", "user", "tags", "true",
        "42",  "a",     "b",   "c",    "[",  "]",    " ",    "alpha",
        "aba", "false", "123", "</s>",
    }, .{ .stop_token_ids = &.{19} });
    defer tok.deinit();

    var comp = try compiler_mod.GrammarCompiler.init(a, &tok, .{ .max_threads = 1 });
    defer comp.deinit();

    var cg_json = try comp.compileJsonSchema(
        "{\"type\":\"object\",\"properties\":{\"user\":{\"type\":\"string\"},\"tags\":{\"type\":\"array\",\"items\":{\"type\":\"boolean\"}}},\"required\":[\"user\",\"tags\"],\"additionalProperties\":false}",
        .{ .any_whitespace = true, .strict_mode = true },
    );
    defer cg_json.deinit();

    var cg_ebnf = try comp.compileEbnf(
        "root ::= expr \";\"?\nexpr ::= \"(\" expr \")\" | [a-c]+",
        .{},
    );
    defer cg_ebnf.deinit();

    var seq_matchers = [_]GrammarMatcher{
        try GrammarMatcher.init(a, &cg_json, .{}),
        try GrammarMatcher.init(a, &cg_json, .{}),
        try GrammarMatcher.init(a, &cg_json, .{}),
        try GrammarMatcher.init(a, &cg_json, .{}),
        try GrammarMatcher.init(a, &cg_ebnf, .{}),
        try GrammarMatcher.init(a, &cg_ebnf, .{}),
        try GrammarMatcher.init(a, &cg_ebnf, .{}),
        try GrammarMatcher.init(a, &cg_ebnf, .{}),
    };
    defer for (&seq_matchers) |*m| m.deinit();

    // Advance each matcher to a distinct grammar state.
    try std.testing.expect(try seq_matchers[0].acceptString("{", null));
    try std.testing.expect(try seq_matchers[1].acceptString("{\"user\":", null));
    try std.testing.expect(try seq_matchers[2].acceptString("{\"user\":\"alpha\",\"tags\":[", null));
    try std.testing.expect(try seq_matchers[3].acceptString("{\"user\":\"a\",\"tags\":[true]}", null));
    try std.testing.expect(try seq_matchers[4].acceptString("(", null));
    try std.testing.expect(try seq_matchers[5].acceptString("(ab", null));
    try std.testing.expect(try seq_matchers[6].acceptString("((a", null));
    try std.testing.expect(try seq_matchers[7].acceptString("aba", null));

    var par_matchers: [8]GrammarMatcher = undefined;
    var forked_count: usize = 0;
    defer for (par_matchers[0..forked_count]) |*m| m.deinit();
    for (&seq_matchers, 0..) |*m, i| {
        par_matchers[i] = try m.fork();
        forked_count += 1;
    }

    var bm_seq = try TokenBitmask.init(a, 8, tok.vocabSize());
    defer bm_seq.deinit();
    var bm_par = try TokenBitmask.init(a, 8, tok.vocabSize());
    defer bm_par.deinit();

    var seq_runner = BatchMatcher.init(a, .{ .max_threads = 1 });
    defer seq_runner.deinit();
    var par_runner = BatchMatcher.init(a, .{ .max_threads = 4 });
    defer par_runner.deinit();

    try seq_runner.fillNextTokenBitmask(&seq_matchers, &bm_seq, null, null);
    try par_runner.fillNextTokenBitmask(&par_matchers, &bm_par, null, null);
    try std.testing.expectEqualSlices(i32, bm_seq.words, bm_par.words);

    // Also test permuted distinct indices across workers.
    const perm = [_]usize{ 7, 2, 5, 0, 4, 1, 6, 3 };
    bm_seq.reset();
    bm_par.reset();
    try seq_runner.fillNextTokenBitmask(&seq_matchers, &bm_seq, &perm, null);
    try par_runner.fillNextTokenBitmask(&par_matchers, &bm_par, &perm, null);
    try std.testing.expectEqualSlices(i32, bm_seq.words, bm_par.words);

    // Duplicate row indices safely fall back to sequential execution.
    const dup_indices = [_]usize{ 0, 1, 2, 3, 4, 5, 6, 6 };
    try par_runner.fillNextTokenBitmask(&par_matchers, &bm_par, &dup_indices, null);

    // Batch string/token/rollback/temperature/apply helpers.
    var temps: [8]f32 = undefined;
    try par_runner.fillTemperatureBatch(&par_matchers, &temps, null, null);
    for (temps) |t| try std.testing.expectEqual(@as(f32, -1.0), t);

    const logits = try a.alloc(f32, 8 * tok.vocabSize());
    defer a.free(logits);
    for (logits, 0..) |*slot, i| slot.* = @floatFromInt(i + 1);
    try par_runner.applyBitmaskInplaceBatch(&bm_par, logits, null, null);

    // Worker error + Diagnostic capture without memory leaks.
    try std.testing.expect(try par_matchers[3].acceptToken(19, null)); // terminate matcher 3
    var diag: Diagnostic = .{};
    defer diag.deinit(a);
    try std.testing.expectError(
        error.Terminated,
        par_runner.fillNextTokenBitmask(&par_matchers, &bm_par, null, &diag),
    );
    try std.testing.expectEqual(Diagnostic.Kind.matcher_terminated, diag.kind);
}

test "GrammarMatcher.fillNextTokenBitmask performs zero heap allocations after warmup" {
    const CountingAllocator = struct {
        child: Allocator,
        alloc_calls: usize = 0,
        resize_grow_calls: usize = 0,
        remap_calls: usize = 0,
        active: bool = false,

        fn allocator(self: *@This()) Allocator {
            return .{ .ptr = self, .vtable = &vtable };
        }

        const vtable: Allocator.VTable = .{
            .alloc = allocFn,
            .resize = resizeFn,
            .remap = remapFn,
            .free = freeFn,
        };

        fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.active) self.alloc_calls += 1;
            return self.child.vtable.alloc(self.child.ptr, len, alignment, ret_addr);
        }

        fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.active and new_len > memory.len) self.resize_grow_calls += 1;
            return self.child.vtable.resize(self.child.ptr, memory, alignment, new_len, ret_addr);
        }

        fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.active and new_len > memory.len) self.remap_calls += 1;
            return self.child.vtable.remap(self.child.ptr, memory, alignment, new_len, ret_addr);
        }

        fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.child.vtable.free(self.child.ptr, memory, alignment, ret_addr);
        }
    };

    const tokenizer_mod = @import("tokenizer.zig");
    const compiler_mod = @import("compiler.zig");

    const base_alloc = std.testing.allocator;
    var counter = CountingAllocator{ .child = base_alloc };
    const ca = counter.allocator();

    // Vocab with prefix chains ("a", "ab", "abc", "abd") + JSON tokens + stop token so
    // adaptive masks exercise both `.accepted` and `.rejected` stores and uncertain-token scans.
    var tok = try tokenizer_mod.TokenizerInfo.init(
        base_alloc,
        &.{ "{", "}", "\"", ":", ",", "a", "ab", "abc", "abd", "true", "false", " ", "x", "y", "</s>" },
        .{ .stop_token_ids = &.{14} },
    );
    defer tok.deinit();

    var comp = try compiler_mod.GrammarCompiler.init(base_alloc, &tok, .{ .max_threads = 1 });
    defer comp.deinit();

    // Grammar with both uncertain prefixes and rejected-store masks (many accepted tokens).
    var cg = try comp.compileEbnf(
        "root ::= \"{\" pair \"}\" | [a-d]+ [xy]*\npair ::= \"\\\"\" [a-z]+ \"\\\":\" (\"true\" | \"false\")",
        .{},
    );
    defer cg.deinit();

    var matcher = try GrammarMatcher.init(ca, &cg, .{});
    defer matcher.deinit();

    var bm = try TokenBitmask.initSingle(base_alloc, tok.vocabSize());
    defer bm.deinit();

    // Warmup pass across initial and advanced states so all scratch & parser buffers reach capacity.
    _ = try matcher.fillNextTokenBitmask(&bm, 0, null);
    try std.testing.expect(try matcher.acceptToken(5, null)); // "a" -> exercises uncertain + rejected-set paths
    _ = try matcher.fillNextTokenBitmask(&bm, 0, null);
    try matcher.reset();

    // Warmup call at root and at state after "a", then measure repeat calls with CountingAllocator active.
    _ = try matcher.fillNextTokenBitmask(&bm, 0, null);
    counter.active = true;
    for (0..5) |_| {
        _ = try matcher.fillNextTokenBitmask(&bm, 0, null);
    }
    counter.active = false;
    try std.testing.expectEqual(@as(usize, 0), counter.alloc_calls);
    try std.testing.expectEqual(@as(usize, 0), counter.resize_grow_calls);
    try std.testing.expectEqual(@as(usize, 0), counter.remap_calls);

    try std.testing.expect(try matcher.acceptToken(5, null)); // "a"
    _ = try matcher.fillNextTokenBitmask(&bm, 0, null);
    counter.active = true;
    for (0..5) |_| {
        _ = try matcher.fillNextTokenBitmask(&bm, 0, null);
    }
    counter.active = false;
    try std.testing.expectEqual(@as(usize, 0), counter.alloc_calls);
    try std.testing.expectEqual(@as(usize, 0), counter.resize_grow_calls);
    try std.testing.expectEqual(@as(usize, 0), counter.remap_calls);
}
