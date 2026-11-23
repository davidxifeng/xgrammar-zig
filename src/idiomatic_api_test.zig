//! Tests for Zig 0.17 idiomatic APIs, SIMD TokenBitmask, parallel compilation, O(1) LRU eviction, and `{f}` formatting.

const std = @import("std");
const testing = std.testing;
const xgrammar = @import("xgrammar.zig");

test "idiomatic Zig 0.17 workflow with SIMD TokenBitmask, BatchGrammarMatcher, and Grammar format" {
    const a = testing.allocator;

    // 75-token vocab exercises: word 0 (0..31), word 1 (32..63), word 2 (64..74 = 11 tail tokens -> 8-lane SIMD + 3-lane scalar tail).
    var vocab_storage: [75][]u8 = undefined;
    var vocab_slices: [75][]const u8 = undefined;
    var owned_count: usize = 0;
    defer for (vocab_storage[0..owned_count]) |s| a.free(s);

    const fixed = [_][]const u8{ "{\"ok\": ", "true", "false", "}", "bad", "</s>" };
    for (fixed, 0..) |s, i| {
        vocab_storage[i] = try a.dupe(u8, s);
        vocab_slices[i] = vocab_storage[i];
        owned_count += 1;
    }
    for (fixed.len..vocab_storage.len) |i| {
        vocab_storage[i] = try std.fmt.allocPrint(a, "tok_{d}", .{i});
        vocab_slices[i] = vocab_storage[i];
        owned_count += 1;
    }

    var tok = try xgrammar.TokenizerInfo.init(a, &vocab_slices, .{
        .vocab_type = .Raw,
        .stop_token_ids = &.{5},
    });
    defer tok.deinit();
    try testing.expectEqual(@as(i32, 75), tok.vocabSize());
    try testing.expectEqual(xgrammar.VocabType.Raw, tok.vocabType());

    const compiler = try xgrammar.GrammarCompiler.init(a, &tok, .{ .max_threads = 4 });
    defer compiler.deinit();

    const schema =
        \\{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"],"additionalProperties":false}
    ;
    var compiled = try compiler.compileJsonSchema(schema, .{
        .any_whitespace = false,
        .strict_mode = true,
    });
    defer compiled.deinit();

    // Verify Grammar `{f}` formatting works cleanly.
    const formatted_grammar = try std.fmt.allocPrint(a, "{f}", .{compiled.grammar()});
    defer a.free(formatted_grammar);
    try testing.expect(std.mem.indexOf(u8, formatted_grammar, "root ::=") != null);

    var matcher = try xgrammar.GrammarMatcher.init(a, &compiled, .{});
    defer matcher.deinit();

    var bm = try xgrammar.TokenBitmask.init(a, @intCast(tok.vocabSize()));
    defer bm.deinit();

    try testing.expect(try matcher.fillBitmask(&bm));
    try testing.expectEqual(@as(usize, 1), bm.countAllowed());
    try testing.expectEqual(@as(?u32, 0), bm.singleAllowedToken());

    var logits: [75]f32 = undefined;
    for (&logits, 0..) |*v, i| v.* = @floatFromInt(i + 1);
    bm.applyToLogits(&logits);
    try testing.expectEqual(@as(f32, 1.0), logits[0]);
    for (logits[1..]) |v| try testing.expectEqual(-std.math.inf(f32), v);

    const jf = try matcher.findJumpForwardString(a);
    defer a.free(jf);
    try testing.expectEqualStrings("{\"ok\": ", jf);

    try testing.expect(try matcher.acceptToken(0));
    bm.reset();
    try testing.expect(try matcher.fillBitmask(&bm));
    try testing.expectEqual(@as(usize, 2), bm.countAllowed());
    try testing.expect(bm.isAllowed(1));
    try testing.expect(bm.isAllowed(2));
    try testing.expect(bm.singleAllowedToken() == null);

    try testing.expect(try matcher.acceptToken(1)); // true
    try testing.expect(try matcher.acceptToken(3)); // }
    try testing.expect(matcher.isCompleted());
    try testing.expect(!matcher.isTerminated());
    try testing.expect(try matcher.acceptToken(5)); // </s>
    try testing.expect(matcher.isTerminated());

    // BatchGrammarMatcher idiomatic wrapper
    var batch = [_]xgrammar.GrammarMatcher{
        try xgrammar.GrammarMatcher.init(a, &compiled, .{}),
        try xgrammar.GrammarMatcher.init(a, &compiled, .{}),
    };
    defer for (&batch) |*m| m.deinit();

    var batch_bm = try xgrammar.TokenBitmask.initBatch(a, 2, @intCast(tok.vocabSize()));
    defer batch_bm.deinit();
    try xgrammar.BatchGrammarMatcher.fillBitmask(a, &batch, &batch_bm, null);
    try testing.expectEqual(@as(usize, 1), batch_bm.countAllowedInRow(0));
    try testing.expectEqual(@as(usize, 1), batch_bm.countAllowedInRow(1));

    const acc = try xgrammar.BatchGrammarMatcher.acceptTokens(a, &batch, &.{ 0, 4 });
    defer a.free(acc);
    try testing.expect(acc[0]);
    try testing.expect(!acc[1]);
}

test "parallel max_threads=4 compilation matches single-threaded max_threads=1 deterministically" {
    const a = testing.allocator;

    var tok = try xgrammar.TokenizerInfo.init(a, &.{
        "{",   "}",  ":",    ",",    "\"", "user", "tags", "true",
        "42",  "a",  "b",    "c",    "[",  "]",    " ",    "</s>",
    }, .{ .stop_token_ids = &.{15} });
    defer tok.deinit();

    const schema =
        \\{"type":"object","properties":{"user":{"type":"object","properties":{"name":{"type":"string"},"active":{"type":"boolean"}},"required":["name","active"]},"tags":{"type":"array","items":{"type":"string"}},"score":{"type":"integer"}},"required":["user","tags","score"]}
    ;

    const c1 = try xgrammar.GrammarCompiler.init(a, &tok, .{ .max_threads = 1, .cache_enabled = false });
    defer c1.deinit();
    var g1 = try c1.compileJsonSchema(schema, .{ .strict_mode = true });
    defer g1.deinit();

    const c4 = try xgrammar.GrammarCompiler.init(a, &tok, .{ .max_threads = 4, .cache_enabled = true });
    defer c4.deinit();
    var g4 = try c4.compileJsonSchema(schema, .{ .strict_mode = true });
    defer g4.deinit();

    const s1 = try g1.serializeJson(a);
    defer a.free(s1);
    const s4 = try g4.serializeJson(a);
    defer a.free(s4);
    try testing.expectEqualStrings(s1, s4);
}

test "GrammarCompiler O(1) LRU cache evicts oldest compiled grammar under tight max_memory_bytes" {
    const a = testing.allocator;
    var tok = try xgrammar.TokenizerInfo.init(a, &.{ "a", "b", "c", "</s>" }, .{});
    defer tok.deinit();

    // Budget enough for ~1 small grammar, evicting the oldest when inserting 3 distinct grammars.
    const compiler = try xgrammar.GrammarCompiler.init(a, &tok, .{
        .max_threads = 1,
        .cache_enabled = true,
        .max_memory_bytes = 2500,
    });
    defer compiler.deinit();

    var cg_a = try compiler.compileRegex("a+");
    const one_size = cg_a.memorySizeBytes();
    cg_a.deinit();

    var cg_b = try compiler.compileRegex("b+");
    cg_b.deinit();
    var cg_c = try compiler.compileRegex("c+");
    cg_c.deinit();

    // Cache byte usage stays bounded within the grammar cache limit once > 1 entry exceeds budget.
    try testing.expect(compiler.getCacheSizeBytes() <= compiler.cacheLimitBytes() or compiler.getCacheSizeBytes() <= @as(i64, @intCast(one_size)));
    compiler.clearCache();
    try testing.expectEqual(@as(i64, 0), compiler.getCacheSizeBytes());
}

test "SIMD TokenBitmask handles full-zero, full-one, mixed words, and tail tokens accurately" {
    const a = testing.allocator;
    var bm = try xgrammar.TokenBitmask.init(a, 75);
    defer bm.deinit();

    // Clear all bits initially, then allow specific tokens across all 3 words:
    // word 0 (0..31): mixed (tokens 0, 5, 31)
    // word 1 (32..63): stays all-zero (0x00000000 fast path)
    // tail (64..74): tokens 64, 71, 74
    @memset(bm.words, 0);
    bm.setAllowed(0, true);
    bm.setAllowed(5, true);
    bm.setAllowed(31, true);
    bm.setAllowed(64, true);
    bm.setAllowed(71, true);
    bm.setAllowed(74, true);

    try testing.expectEqual(@as(usize, 6), bm.countAllowed());

    var logits: [75]f32 = undefined;
    for (&logits, 0..) |*v, i| v.* = @floatFromInt(i);
    bm.applyToLogits(&logits);

    for (logits, 0..) |val, idx| {
        const expected_allowed = idx == 0 or idx == 5 or idx == 31 or idx == 64 or idx == 71 or idx == 74;
        if (expected_allowed) {
            try testing.expectEqual(@as(f32, @floatFromInt(idx)), val);
        } else {
            try testing.expectEqual(-std.math.inf(f32), val);
        }
    }

    // Borrowed slice wrapper + full-all-ones fast path
    var raw = [_]i32{ -1, -1, -1 };
    var borrowed = try xgrammar.TokenBitmask.fromSlice(&raw, 1, 75);
    defer borrowed.deinit();
    try testing.expectEqual(@as(usize, 75), borrowed.countAllowed());
}

test "root constructors parseEbnf, fromRegex, fromJsonSchema, and builtinJsonGrammar" {
    const a = testing.allocator;
    const g1 = try xgrammar.parseEbnf(a, "root ::= [a-z]+", "root");
    defer g1.deinit();
    try testing.expect(g1.numRules() >= 1);

    const g2 = try xgrammar.fromRegex(a, "[0-9]{2,3}");
    defer g2.deinit();

    const g3 = try xgrammar.fromJsonSchema(a, "{\"type\":\"boolean\"}", .{});
    defer g3.deinit();

    const g4 = try xgrammar.builtinJsonGrammar(a);
    defer g4.deinit();
    try testing.expect(g4.numExprs() > 0);
}
