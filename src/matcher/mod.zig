//! Grammar-guided generation: stateful matchers that drive constrained decoding (`matcher/mod.rs`).

const std = @import("std");

pub const batch_grammar_matcher = @import("batch_grammar_matcher.zig");
pub const budget_body_match_progress = @import("budget_body_match_progress.zig");
pub const capture_span_event = @import("capture_span_event.zig");
pub const error_mod = @import("error.zig");
pub const grammar_matcher = @import("grammar_matcher.zig");
pub const token_bitmask = @import("token_bitmask.zig");

// pub use batch_grammar_matcher::BatchGrammarMatcher;
pub const BatchGrammarMatcher = batch_grammar_matcher.BatchGrammarMatcher;
// pub use error::MatcherError;
pub const MatcherError = error_mod.MatcherError;
pub const MatcherErrorInfo = error_mod.MatcherErrorInfo;
// pub use grammar_matcher::GrammarMatcher;
pub const Capture = grammar_matcher.Capture;
pub const GrammarMatcher = grammar_matcher.GrammarMatcher;
pub const free_captures = grammar_matcher.free_captures;
// pub use token_bitmask::{...};
pub const BitmaskDlType = token_bitmask.BitmaskDlType;
pub const allocate_token_bitmask = token_bitmask.allocate_token_bitmask;
pub const apply_token_bitmask_inplace_cpu = token_bitmask.apply_token_bitmask_inplace_cpu;
pub const apply_token_bitmask_inplace_cpu_batch = token_bitmask.apply_token_bitmask_inplace_cpu_batch;
pub const bitmask_row_range = token_bitmask.bitmask_row_range;
pub const get_bitmask_dl_type = token_bitmask.get_bitmask_dl_type;
pub const get_bitmask_size = token_bitmask.get_bitmask_size;
pub const get_masked_tokens_from_bitmask = token_bitmask.get_masked_tokens_from_bitmask;
pub const is_single_token_bitmask = token_bitmask.is_single_token_bitmask;
pub const reset_token_bitmask = token_bitmask.reset_token_bitmask;

test {
    _ = batch_grammar_matcher;
    _ = budget_body_match_progress;
    _ = capture_span_event;
    _ = error_mod;
    _ = grammar_matcher;
    _ = token_bitmask;
}

test "matcher core json workflow, jump forward, rollback, fork, bitmask, and batch" {
    const a = std.testing.allocator;
    const tokenizer_mod = @import("../tokenizer/mod.zig");
    const compiler_mod = @import("../compiler/mod.zig");

    var tok = try tokenizer_mod.TokenizerInfo.new(
        a,
        &.{ "{\"ok\":", "true", "false", "}", "bad", "</s>" },
        .Raw,
        null,
        null,
        false,
        null,
    );
    defer tok.deinit();

    const comp = try compiler_mod.GrammarCompiler.with_defaults(a, &tok);
    defer comp.deinit();

    var compiled = try comp.compile_json_schema(
        "{\"type\":\"object\",\"properties\":{\"ok\":{\"type\":\"boolean\"}},\"required\":[\"ok\"],\"additionalProperties\":false}",
        false,
        null,
        .{ .item = ",", .colon = ":" },
        true,
        null,
        null,
    );
    defer compiled.deinit();

    var matcher = try GrammarMatcher.from_compiled_grammar(a, &compiled, false);
    defer matcher.deinit();

    // Jump-forward string at start must be `{"ok":`.
    const jf0 = try matcher.find_jump_forward_string(a, null);
    defer a.free(jf0);
    try std.testing.expectEqualStrings("{\"ok\":", jf0);

    const bm_size = get_bitmask_size(tok.vocab_size);
    const shape = [2]i64{ 1, bm_size };
    const bitmask = try allocate_token_bitmask(a, 1, tok.vocab_size);
    defer a.free(bitmask);

    try std.testing.expect(try matcher.fill_next_token_bitmask(bitmask, &shape, 0, null));
    const single = is_single_token_bitmask(bitmask, tok.vocab_size, 0);
    try std.testing.expect(single.is_single);
    try std.testing.expectEqual(@as(i32, 0), single.token_id);

    // Fork independent branch.
    var forked = try matcher.fork();
    defer forked.deinit();

    try std.testing.expect(try matcher.accept_token(0));
    try std.testing.expect(!matcher.is_completed());
    try std.testing.expect(try matcher.fill_next_token_bitmask(bitmask, &shape, 0, null));
    try std.testing.expect(try matcher.accept_token(1));
    try std.testing.expect(!matcher.is_completed());
    try std.testing.expect(try matcher.accept_token(3));
    try std.testing.expect(matcher.is_completed());
    try std.testing.expect(!matcher.is_terminated());

    // Apply logits check before accepting stop token.
    var logits = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0 };
    try std.testing.expect(try matcher.fill_next_token_bitmask(bitmask, &shape, 0, null));
    apply_token_bitmask_inplace_cpu(&logits, bitmask, tok.vocab_size);
    try std.testing.expectEqual(@as(f32, 6.0), logits[5]);
    try std.testing.expect(logits[0] == -std.math.inf(f32));

    // Rollback 1 token ("}"), re-accept via forked / rollback check.
    try matcher.rollback(1, null);
    try std.testing.expect(!matcher.is_completed());
    try std.testing.expect(try matcher.accept_string("}"));
    try std.testing.expect(matcher.is_completed());
    try std.testing.expect(try matcher.accept_token(5)); // </s>
    try std.testing.expect(matcher.is_terminated());

    // Forked branch still at initial position.
    try std.testing.expect(try forked.accept_string("{\"ok\":false}"));
    try std.testing.expect(forked.is_completed());

    // Terminated matcher returns error.Terminated on fill_next_token_bitmask.
    try std.testing.expectError(error.Terminated, matcher.fill_next_token_bitmask(bitmask, &shape, 0, null));

    // Batch operations.
    var batch = [_]GrammarMatcher{
        try GrammarMatcher.from_compiled_grammar(a, &compiled, false),
        try GrammarMatcher.from_compiled_grammar(a, &compiled, false),
    };
    defer for (&batch) |*m| m.deinit();
    const bm2 = try allocate_token_bitmask(a, 2, tok.vocab_size);
    defer a.free(bm2);
    const shape2 = [2]i64{ 2, bm_size };
    try BatchGrammarMatcher.batch_fill_next_token_bitmask(a, &batch, bm2, &shape2, null, null);
    const res = try BatchGrammarMatcher.batch_accept_token(a, &batch, &.{ 0, 4 }, null);
    defer a.free(res);
    try std.testing.expect(res[0]);
    try std.testing.expect(!res[1]);
}

test "matcher captures, budgets, and draft tree" {
    const a = std.testing.allocator;
    const tokenizer_mod = @import("../tokenizer/mod.zig");
    const compiler_mod = @import("../compiler/mod.zig");

    var tok = try tokenizer_mod.TokenizerInfo.new(
        a,
        &.{ "a", "b", "x", "y", "</s>" },
        .Raw,
        null,
        null,
        false,
        null,
    );
    defer tok.deinit();

    const comp = try compiler_mod.GrammarCompiler.with_defaults(a, &tok);
    defer comp.deinit();

    var cg = try comp.compile_grammar_ebnf(
        "root ::= cap \"-\"? [a-b]+\ncap[capture=\"tag\", max_tokens=2, temperature=0.5] ::= [xy]+",
        "root",
        null,
    );
    defer cg.deinit();

    var m = try GrammarMatcher.from_compiled_grammar(a, &cg, false);
    defer m.deinit();
    try std.testing.expectEqual(@as(?f32, 0.5), m.temperature());
    try std.testing.expect(try m.accept_string("xy"));
    try std.testing.expect(try m.accept_string("ab"));
    try std.testing.expect(m.is_completed());
    const caps = try m.get_captures(a, true);
    defer free_captures(a, caps);
    try std.testing.expectEqual(@as(usize, 1), caps.len);
    try std.testing.expectEqualStrings("tag", caps[0].name);
    try std.testing.expectEqualStrings("xy", caps[0].bytes);

    // Draft tree test: root -> token 0 ("a") or sibling -> token 1 ("b").
    var cg_tree = try comp.compile_grammar_ebnf("root ::= [ab]+", "root", null);
    defer cg_tree.deinit();
    var mt = try GrammarMatcher.from_compiled_grammar(a, &cg_tree, false);
    defer mt.deinit();
    const words = get_bitmask_size(tok.vocab_size);
    const bm = try allocate_token_bitmask(a, 3, tok.vocab_size);
    defer a.free(bm);
    const ok = try mt.traverse_draft_tree(
        &.{ 1, -1, -1 },
        &.{ -1, 2, -1 },
        &.{ 0, 0, 2 },
        bm,
        1.0,
        null,
        null,
    );
    try std.testing.expect(ok);
    const masked_node0 = try get_masked_tokens_from_bitmask(a, bm, tok.vocab_size, 0);
    defer a.free(masked_node0);
    // Nodes 0 and 1 can accept "a" (0) or "b" (1); token "x" (2) at node 2 is rejected -> node 2 row zeroed.
    _ = words;
    try std.testing.expect(std.mem.indexOfScalar(i32, masked_node0, 2) != null);
    try std.testing.expectEqual(@as(i32, 0), bm[2]);
}
