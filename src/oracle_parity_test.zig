//! Golden bit-for-bit parity tests verified against `tools/oracle-rs/target/release/oracle`
//! (xgrammar-rs 0.2.8).

const std = @import("std");
const testing = std.testing;
const xgrammar = @import("xgrammar.zig");

const GoldenStep = struct {
    token_id: i32,
    fill_ok: bool,
    accepted: bool,
    bitmask: []const u32,
    completed: bool,
    terminated: bool,
};

fn verifySequence(
    compiled: *const xgrammar.CompiledGrammar,
    vocab_size: i32,
    steps: []const GoldenStep,
    expected_jump_forward_bytes: []const u8,
) !void {
    const a = testing.allocator;
    var matcher = try xgrammar.GrammarMatcher.from_compiled_grammar(a, compiled, false);
    defer matcher.deinit();

    const bm_size = xgrammar.get_bitmask_size(vocab_size);
    const shape = [2]i64{ 1, bm_size };

    for (steps) |step| {
        const bitmask = try xgrammar.allocate_token_bitmask(a, 1, vocab_size);
        defer a.free(bitmask);

        const fill_ok = if (matcher.fill_next_token_bitmask(bitmask, &shape, 0, null)) |ok|
            ok
        else |err| switch (err) {
            error.Terminated => false,
            else => return err,
        };
        const accepted = try matcher.accept_token(step.token_id);

        try testing.expectEqual(step.fill_ok, fill_ok);
        try testing.expectEqual(step.accepted, accepted);
        try testing.expectEqual(step.bitmask.len, bitmask.len);
        for (step.bitmask, bitmask) |exp_u32, actual_i32| {
            try testing.expectEqual(exp_u32, @as(u32, @bitCast(actual_i32)));
        }
        try testing.expectEqual(step.completed, matcher.is_completed());
        try testing.expectEqual(step.terminated, matcher.is_terminated());
    }

    const jf = try matcher.find_jump_forward_string(a, null);
    defer a.free(jf);
    try testing.expectEqualSlices(u8, expected_jump_forward_bytes, jf);
}

test "oracle parity: json_schema_strict_no_ws" {
    const a = testing.allocator;
    var tok = try xgrammar.TokenizerInfo.new(
        a,
        &.{ "{\"ok\": ", "{\"ok\":", "true", "false", "123", "\"hi\"", ",", "}", "bad", "</s>" },
        .Raw,
        null,
        &.{9},
        false,
        null,
    );
    defer tok.deinit();

    const comp = try xgrammar.GrammarCompiler.with_defaults(a, &tok);
    defer comp.deinit();

    const schema =
        \\{"type":"object","properties":{"ok":{"type":"boolean"},"n":{"type":"integer"},"s":{"type":"string","enum":["hi","bye"]}},"required":["ok"],"additionalProperties":false}
    ;
    var compiled = try comp.compile_json_schema(schema, false, null, null, true, null, null);
    defer compiled.deinit();

    try verifySequence(&compiled, tok.vocab_size, &.{
        .{ .token_id = 0, .fill_ok = true, .accepted = true, .bitmask = &.{3}, .completed = false, .terminated = false },
        .{ .token_id = 2, .fill_ok = true, .accepted = true, .bitmask = &.{12}, .completed = false, .terminated = false },
        .{ .token_id = 7, .fill_ok = true, .accepted = true, .bitmask = &.{192}, .completed = true, .terminated = false },
    }, "");

    try verifySequence(&compiled, tok.vocab_size, &.{
        .{ .token_id = 0, .fill_ok = true, .accepted = true, .bitmask = &.{3}, .completed = false, .terminated = false },
        .{ .token_id = 8, .fill_ok = true, .accepted = false, .bitmask = &.{12}, .completed = false, .terminated = false },
        .{ .token_id = 2, .fill_ok = true, .accepted = true, .bitmask = &.{12}, .completed = false, .terminated = false },
        .{ .token_id = 7, .fill_ok = true, .accepted = true, .bitmask = &.{192}, .completed = true, .terminated = false },
    }, "");

    try verifySequence(&compiled, tok.vocab_size, &.{
        .{ .token_id = 1, .fill_ok = true, .accepted = true, .bitmask = &.{3}, .completed = false, .terminated = false },
        .{ .token_id = 3, .fill_ok = true, .accepted = false, .bitmask = &.{0}, .completed = false, .terminated = false },
        .{ .token_id = 7, .fill_ok = true, .accepted = false, .bitmask = &.{0}, .completed = false, .terminated = false },
    }, " ");
}

test "oracle parity: json_schema_ws_nested" {
    const a = testing.allocator;
    var tok = try xgrammar.TokenizerInfo.new(
        a,
        &.{ "{", "\"user\"", ":", " ", "\"name\"", "\"Ada\"", "\"level\"", "42", ",", "}", "invalid", "</s>" },
        .Raw,
        null,
        &.{11},
        false,
        null,
    );
    defer tok.deinit();

    const comp = try xgrammar.GrammarCompiler.with_defaults(a, &tok);
    defer comp.deinit();

    const schema =
        \\{"type":"object","properties":{"user":{"type":"object","properties":{"name":{"type":"string"},"level":{"type":"integer"}},"required":["name","level"]}},"required":["user"]}
    ;
    var compiled = try comp.compile_json_schema(schema, true, null, null, false, null, null);
    defer compiled.deinit();

    try verifySequence(&compiled, tok.vocab_size, &.{
        .{ .token_id = 0, .fill_ok = true, .accepted = true, .bitmask = &.{1}, .completed = false, .terminated = false },
        .{ .token_id = 1, .fill_ok = true, .accepted = true, .bitmask = &.{10}, .completed = false, .terminated = false },
        .{ .token_id = 2, .fill_ok = true, .accepted = true, .bitmask = &.{12}, .completed = false, .terminated = false },
        .{ .token_id = 0, .fill_ok = true, .accepted = true, .bitmask = &.{9}, .completed = false, .terminated = false },
        .{ .token_id = 4, .fill_ok = true, .accepted = true, .bitmask = &.{24}, .completed = false, .terminated = false },
        .{ .token_id = 2, .fill_ok = true, .accepted = true, .bitmask = &.{12}, .completed = false, .terminated = false },
        .{ .token_id = 5, .fill_ok = true, .accepted = true, .bitmask = &.{122}, .completed = false, .terminated = false },
        .{ .token_id = 8, .fill_ok = true, .accepted = true, .bitmask = &.{264}, .completed = false, .terminated = false },
        .{ .token_id = 6, .fill_ok = true, .accepted = true, .bitmask = &.{72}, .completed = false, .terminated = false },
        .{ .token_id = 2, .fill_ok = true, .accepted = true, .bitmask = &.{12}, .completed = false, .terminated = false },
        .{ .token_id = 7, .fill_ok = true, .accepted = true, .bitmask = &.{136}, .completed = false, .terminated = false },
        .{ .token_id = 9, .fill_ok = true, .accepted = true, .bitmask = &.{904}, .completed = false, .terminated = false },
        .{ .token_id = 9, .fill_ok = true, .accepted = true, .bitmask = &.{776}, .completed = true, .terminated = false },
    }, "");

    try verifySequence(&compiled, tok.vocab_size, &.{
        .{ .token_id = 0, .fill_ok = true, .accepted = true, .bitmask = &.{1}, .completed = false, .terminated = false },
        .{ .token_id = 3, .fill_ok = true, .accepted = true, .bitmask = &.{10}, .completed = false, .terminated = false },
        .{ .token_id = 1, .fill_ok = true, .accepted = true, .bitmask = &.{10}, .completed = false, .terminated = false },
        .{ .token_id = 10, .fill_ok = true, .accepted = false, .bitmask = &.{12}, .completed = false, .terminated = false },
    }, "");
}

test "oracle parity: ebnf_recursion_lookahead_utf8" {
    const a = testing.allocator;
    var tok = try xgrammar.TokenizerInfo.new(
        a,
        &.{ "(", ")", "中", "文", "abc", "x", "y", "!", "</s>" },
        .Raw,
        null,
        &.{8},
        false,
        null,
    );
    defer tok.deinit();

    const comp = try xgrammar.GrammarCompiler.with_defaults(a, &tok);
    defer comp.deinit();

    var compiled = try comp.compile_grammar_ebnf(
        "root ::= expr \"!\"\nexpr ::= \"(\" expr \")\" | [a-z]+ | \"中文\"",
        "root",
        null,
    );
    defer compiled.deinit();

    try verifySequence(&compiled, tok.vocab_size, &.{
        .{ .token_id = 0, .fill_ok = true, .accepted = true, .bitmask = &.{117}, .completed = false, .terminated = false },
        .{ .token_id = 4, .fill_ok = true, .accepted = true, .bitmask = &.{117}, .completed = false, .terminated = false },
        .{ .token_id = 1, .fill_ok = true, .accepted = true, .bitmask = &.{114}, .completed = false, .terminated = false },
        .{ .token_id = 7, .fill_ok = true, .accepted = true, .bitmask = &.{128}, .completed = true, .terminated = false },
    }, "");

    try verifySequence(&compiled, tok.vocab_size, &.{
        .{ .token_id = 0, .fill_ok = true, .accepted = true, .bitmask = &.{117}, .completed = false, .terminated = false },
        .{ .token_id = 2, .fill_ok = true, .accepted = true, .bitmask = &.{117}, .completed = false, .terminated = false },
        .{ .token_id = 7, .fill_ok = true, .accepted = false, .bitmask = &.{8}, .completed = false, .terminated = false },
    }, "文)!");
}

test "oracle parity: byte_fallback_padded_prefix_space and multiword enum" {
    const a = testing.allocator;
    var tok = try xgrammar.TokenizerInfo.new(
        a,
        &.{ "<unk>", "▁hello", "<0xE4>", "<0xB8>", "<0xAD>", "a", "b", "!", "</s>" },
        .ByteFallback,
        16,
        &.{8},
        true,
        null,
    );
    defer tok.deinit();

    const comp = try xgrammar.GrammarCompiler.with_defaults(a, &tok);
    defer comp.deinit();

    var compiled = try comp.compile_grammar_ebnf(
        "root ::= (\"hello\" | \"中\" | \"ab\")+ \"!\"",
        "root",
        null,
    );
    defer compiled.deinit();

    try verifySequence(&compiled, tok.vocab_size, &.{
        .{ .token_id = 1, .fill_ok = true, .accepted = false, .bitmask = &.{36}, .completed = false, .terminated = false },
        .{ .token_id = 2, .fill_ok = true, .accepted = true, .bitmask = &.{36}, .completed = false, .terminated = false },
        .{ .token_id = 3, .fill_ok = true, .accepted = true, .bitmask = &.{8}, .completed = false, .terminated = false },
        .{ .token_id = 4, .fill_ok = true, .accepted = true, .bitmask = &.{16}, .completed = false, .terminated = false },
        .{ .token_id = 5, .fill_ok = true, .accepted = true, .bitmask = &.{164}, .completed = false, .terminated = false },
        .{ .token_id = 6, .fill_ok = true, .accepted = true, .bitmask = &.{64}, .completed = false, .terminated = false },
        .{ .token_id = 7, .fill_ok = true, .accepted = true, .bitmask = &.{164}, .completed = true, .terminated = false },
    }, "");

    try verifySequence(&compiled, tok.vocab_size, &.{
        .{ .token_id = 2, .fill_ok = true, .accepted = true, .bitmask = &.{36}, .completed = false, .terminated = false },
        .{ .token_id = 5, .fill_ok = true, .accepted = false, .bitmask = &.{8}, .completed = false, .terminated = false },
    }, &.{ 0xB8, 0xAD });
}
