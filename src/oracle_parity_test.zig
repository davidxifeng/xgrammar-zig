//! Golden bit-for-bit parity tests verified against `tools/oracle-rs/target/release/oracle`
//! (xgrammar-rs 0.2.8).

const std = @import("std");
const testing = std.testing;
const xgrammar = @import("xgrammar.zig");

const GoldenStep = struct {
    token_id: u32,
    fill_ok: bool,
    accepted: bool,
    bitmask: []const u32,
    completed: bool,
    terminated: bool,
};

fn verifySequence(
    compiled: *const xgrammar.CompiledGrammar,
    vocab_size: usize,
    steps: []const GoldenStep,
    expected_jump_forward_bytes: []const u8,
) !void {
    const a = testing.allocator;
    var matcher = try xgrammar.GrammarMatcher.init(a, compiled, .{});
    defer matcher.deinit();

    var bitmask = try xgrammar.TokenBitmask.initSingle(a, vocab_size);
    defer bitmask.deinit();

    for (steps) |step| {
        bitmask.reset();
        const fill_ok = if (matcher.fillNextTokenBitmask(&bitmask, 0, null)) |ok|
            ok
        else |err| switch (err) {
            error.Terminated => false,
            else => return err,
        };
        const accepted = try matcher.acceptToken(step.token_id, null);

        try testing.expectEqual(step.fill_ok, fill_ok);
        try testing.expectEqual(step.accepted, accepted);
        try testing.expectEqual(step.bitmask.len, bitmask.words.len);
        for (step.bitmask, bitmask.words) |exp_u32, actual_i32| {
            try testing.expectEqual(exp_u32, @as(u32, @bitCast(actual_i32)));
        }
        try testing.expectEqual(step.completed, matcher.isCompleted());
        try testing.expectEqual(step.terminated, matcher.isTerminated());
    }

    const jf = try matcher.findJumpForwardString(a, null);
    defer a.free(jf);
    try testing.expectEqualSlices(u8, expected_jump_forward_bytes, jf);
}

test "oracle parity: json_schema_strict_no_ws" {
    const a = testing.allocator;
    var tok = try xgrammar.TokenizerInfo.init(
        a,
        &.{ "{\"ok\": ", "{\"ok\":", "true", "false", "123", "\"hi\"", ",", "}", "bad", "</s>" },
        .{ .stop_token_ids = &.{9} },
    );
    defer tok.deinit();

    var comp = try xgrammar.GrammarCompiler.init(a, &tok, .{});
    defer comp.deinit();

    const schema =
        \\{"type":"object","properties":{"ok":{"type":"boolean"},"n":{"type":"integer"},"s":{"type":"string","enum":["hi","bye"]}},"required":["ok"],"additionalProperties":false}
    ;
    var compiled = try comp.compileJsonSchema(schema, .{
        .any_whitespace = false,
        .strict_mode = true,
    });
    defer compiled.deinit();

    try verifySequence(&compiled, tok.vocabSize(), &.{
        .{ .token_id = 0, .fill_ok = true, .accepted = true, .bitmask = &.{3}, .completed = false, .terminated = false },
        .{ .token_id = 2, .fill_ok = true, .accepted = true, .bitmask = &.{12}, .completed = false, .terminated = false },
        .{ .token_id = 7, .fill_ok = true, .accepted = true, .bitmask = &.{192}, .completed = true, .terminated = false },
    }, "");

    try verifySequence(&compiled, tok.vocabSize(), &.{
        .{ .token_id = 0, .fill_ok = true, .accepted = true, .bitmask = &.{3}, .completed = false, .terminated = false },
        .{ .token_id = 8, .fill_ok = true, .accepted = false, .bitmask = &.{12}, .completed = false, .terminated = false },
        .{ .token_id = 2, .fill_ok = true, .accepted = true, .bitmask = &.{12}, .completed = false, .terminated = false },
        .{ .token_id = 7, .fill_ok = true, .accepted = true, .bitmask = &.{192}, .completed = true, .terminated = false },
    }, "");

    try verifySequence(&compiled, tok.vocabSize(), &.{
        .{ .token_id = 1, .fill_ok = true, .accepted = true, .bitmask = &.{3}, .completed = false, .terminated = false },
        .{ .token_id = 3, .fill_ok = true, .accepted = false, .bitmask = &.{0}, .completed = false, .terminated = false },
        .{ .token_id = 7, .fill_ok = true, .accepted = false, .bitmask = &.{0}, .completed = false, .terminated = false },
    }, " ");
}

test "oracle parity: json_schema_ws_nested" {
    const a = testing.allocator;
    var tok = try xgrammar.TokenizerInfo.init(
        a,
        &.{ "{", "\"user\"", ":", " ", "\"name\"", "\"Ada\"", "\"level\"", "42", ",", "}", "invalid", "</s>" },
        .{ .stop_token_ids = &.{11} },
    );
    defer tok.deinit();

    var comp = try xgrammar.GrammarCompiler.init(a, &tok, .{});
    defer comp.deinit();

    const schema =
        \\{"type":"object","properties":{"user":{"type":"object","properties":{"name":{"type":"string"},"level":{"type":"integer"}},"required":["name","level"]}},"required":["user"]}
    ;
    var compiled = try comp.compileJsonSchema(schema, .{
        .any_whitespace = true,
        .strict_mode = false,
    });
    defer compiled.deinit();

    try verifySequence(&compiled, tok.vocabSize(), &.{
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

    try verifySequence(&compiled, tok.vocabSize(), &.{
        .{ .token_id = 0, .fill_ok = true, .accepted = true, .bitmask = &.{1}, .completed = false, .terminated = false },
        .{ .token_id = 3, .fill_ok = true, .accepted = true, .bitmask = &.{10}, .completed = false, .terminated = false },
        .{ .token_id = 1, .fill_ok = true, .accepted = true, .bitmask = &.{10}, .completed = false, .terminated = false },
        .{ .token_id = 10, .fill_ok = true, .accepted = false, .bitmask = &.{12}, .completed = false, .terminated = false },
    }, "");
}

test "oracle parity: ebnf_recursion_lookahead_utf8" {
    const a = testing.allocator;
    var tok = try xgrammar.TokenizerInfo.init(
        a,
        &.{ "(", ")", "中", "文", "abc", "x", "y", "!", "</s>" },
        .{ .stop_token_ids = &.{8} },
    );
    defer tok.deinit();

    var comp = try xgrammar.GrammarCompiler.init(a, &tok, .{});
    defer comp.deinit();

    var compiled = try comp.compileEbnf(
        "root ::= expr \"!\"\nexpr ::= \"(\" expr \")\" | [a-z]+ | \"中文\"",
        .{},
    );
    defer compiled.deinit();

    try verifySequence(&compiled, tok.vocabSize(), &.{
        .{ .token_id = 0, .fill_ok = true, .accepted = true, .bitmask = &.{117}, .completed = false, .terminated = false },
        .{ .token_id = 4, .fill_ok = true, .accepted = true, .bitmask = &.{117}, .completed = false, .terminated = false },
        .{ .token_id = 1, .fill_ok = true, .accepted = true, .bitmask = &.{114}, .completed = false, .terminated = false },
        .{ .token_id = 7, .fill_ok = true, .accepted = true, .bitmask = &.{128}, .completed = true, .terminated = false },
    }, "");

    try verifySequence(&compiled, tok.vocabSize(), &.{
        .{ .token_id = 0, .fill_ok = true, .accepted = true, .bitmask = &.{117}, .completed = false, .terminated = false },
        .{ .token_id = 2, .fill_ok = true, .accepted = true, .bitmask = &.{117}, .completed = false, .terminated = false },
        .{ .token_id = 7, .fill_ok = true, .accepted = false, .bitmask = &.{8}, .completed = false, .terminated = false },
    }, "文)!");
}

test "oracle parity: byte_fallback_padded_prefix_space and multiword enum" {
    const a = testing.allocator;
    var tok = try xgrammar.TokenizerInfo.init(
        a,
        &.{ "<unk>", "▁hello", "<0xE4>", "<0xB8>", "<0xAD>", "a", "b", "!", "</s>" },
        .{
            .vocab_type = .byte_fallback,
            .vocab_size = 16,
            .stop_token_ids = &.{8},
            .add_prefix_space = true,
        },
    );
    defer tok.deinit();

    var comp = try xgrammar.GrammarCompiler.init(a, &tok, .{});
    defer comp.deinit();

    var compiled = try comp.compileEbnf(
        "root ::= (\"hello\" | \"中\" | \"ab\")+ \"!\"",
        .{},
    );
    defer compiled.deinit();

    try verifySequence(&compiled, tok.vocabSize(), &.{
        .{ .token_id = 1, .fill_ok = true, .accepted = false, .bitmask = &.{36}, .completed = false, .terminated = false },
        .{ .token_id = 2, .fill_ok = true, .accepted = true, .bitmask = &.{36}, .completed = false, .terminated = false },
        .{ .token_id = 3, .fill_ok = true, .accepted = true, .bitmask = &.{8}, .completed = false, .terminated = false },
        .{ .token_id = 4, .fill_ok = true, .accepted = true, .bitmask = &.{16}, .completed = false, .terminated = false },
        .{ .token_id = 5, .fill_ok = true, .accepted = true, .bitmask = &.{164}, .completed = false, .terminated = false },
        .{ .token_id = 6, .fill_ok = true, .accepted = true, .bitmask = &.{64}, .completed = false, .terminated = false },
        .{ .token_id = 7, .fill_ok = true, .accepted = true, .bitmask = &.{164}, .completed = true, .terminated = false },
    }, "");

    // v0.2.9 (#1012): findJumpForwardString aligns to whole UTF-8 codepoint boundaries,
    // returning "" instead of mid-codepoint continuation bytes 0xB8 0xAD.
    try verifySequence(&compiled, tok.vocabSize(), &.{
        .{ .token_id = 2, .fill_ok = true, .accepted = true, .bitmask = &.{36}, .completed = false, .terminated = false },
        .{ .token_id = 5, .fill_ok = true, .accepted = false, .bitmask = &.{8}, .completed = false, .terminated = false },
    }, "");
}
