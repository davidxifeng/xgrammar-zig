//! Regression tests for all 12 mlc-ai/xgrammar v0.2.9 correctness fixes tracked in docs/UPSTREAM.md.

const std = @import("std");
const testing = std.testing;
const xgrammar = @import("xgrammar.zig");

test "v0.2.9 #943: rule-level cache hashes distinguish repeat bounds and character ranges" {
    const a = testing.allocator;
    const g1 = try xgrammar.parseEbnf(a, "root ::= [a-b]{2,3}", "root");
    defer g1.deinit();
    const o1 = try xgrammar.functor.grammar_optimizer(a, g1, null);
    defer o1.deinit();
    try xgrammar.functor.grammar_fsm_hasher(a, o1);

    const g2 = try xgrammar.parseEbnf(a, "root ::= [a-b]{2,4}", "root");
    defer g2.deinit();
    const o2 = try xgrammar.functor.grammar_optimizer(a, g2, null);
    defer o2.deinit();
    try xgrammar.functor.grammar_fsm_hasher(a, o2);

    const g3 = try xgrammar.parseEbnf(a, "root ::= [c-d]{2,3}", "root");
    defer g3.deinit();
    const o3 = try xgrammar.functor.grammar_optimizer(a, g3, null);
    defer o3.deinit();
    try xgrammar.functor.grammar_fsm_hasher(a, o3);

    const h1 = o1.per_rule_fsm_hash(0).?;
    const h2 = o2.per_rule_fsm_hash(0).?;
    const h3 = o3.per_rule_fsm_hash(0).?;
    try testing.expect(h1 != h2);
    try testing.expect(h1 != h3);
    try testing.expect(h2 != h3);

    // Also verify end-to-end compilation under a shared RuleLevelCache distinguishes repeat bounds.
    var tok = try xgrammar.TokenizerInfo.init(a, &.{ "a", "b", "c", "d", "</s>" }, .{
        .stop_token_ids = &.{4},
    });
    defer tok.deinit();
    const comp = try xgrammar.GrammarCompiler.init(a, &tok, .{ .max_threads = 1, .cache_enabled = true });
    defer comp.deinit();
    var c1 = try comp.compileEbnf("root ::= [a-b]{2,3}", "root");
    defer c1.deinit();
    var c2 = try comp.compileEbnf("root ::= [a-b]{2,4}", "root");
    defer c2.deinit();
    var m2 = try xgrammar.GrammarMatcher.init(a, &c2, .{});
    defer m2.deinit();
    try testing.expect(try m2.acceptString("abab"));
    try testing.expect(m2.isCompleted());
}

test "v0.2.9 #985: GrammarCompiler schema cache key avoids separator delimiter collisions" {
    const a = testing.allocator;
    var tok = try xgrammar.TokenizerInfo.init(a, &.{ "[", "1", ",", ":", ",:", "2", "]", "</s>" }, .{
        .stop_token_ids = &.{7},
    });
    defer tok.deinit();

    const compiler = try xgrammar.GrammarCompiler.init(a, &tok, .{ .max_threads = 1, .cache_enabled = true });
    defer compiler.deinit();

    const schema = "{\"type\":\"array\",\"items\":{\"type\":\"integer\"}}";
    var c1 = try compiler.compileJsonSchema(schema, .{
        .any_whitespace = false,
        .separators = .{ .item = "a,b", .colon = "c" },
    });
    defer c1.deinit();

    var c2 = try compiler.compileJsonSchema(schema, .{
        .any_whitespace = false,
        .separators = .{ .item = "a", .colon = "b,c" },
    });
    defer c2.deinit();

    try testing.expect(!c1.sharesStorage(&c2));
    var m1 = try xgrammar.GrammarMatcher.init(a, &c1, .{});
    defer m1.deinit();
    var m2 = try xgrammar.GrammarMatcher.init(a, &c2, .{});
    defer m2.deinit();
    try testing.expect(try m1.acceptString("[1a,b2]"));
    try testing.expect(!(try m2.acceptString("[1a,b2]")));
}

test "v0.2.9 #949 and #963: large regex repeat preserves forbidden JSON bytes and caches cleanly" {
    const a = testing.allocator;
    var tok = try xgrammar.TokenizerInfo.init(a, &.{ "\"", "a", "\\n", "</s>" }, .{
        .stop_token_ids = &.{3},
    });
    defer tok.deinit();

    const compiler = try xgrammar.GrammarCompiler.init(a, &tok, .{ .max_threads = 1, .cache_enabled = true });
    defer compiler.deinit();

    const schema = "{\"type\":\"string\",\"pattern\":\"^.{130,132}$\"}";
    var c1 = try compiler.compileJsonSchema(schema, .{ .strict_mode = true });
    defer c1.deinit();
    var c2 = try compiler.compileJsonSchema(schema, .{ .strict_mode = true });
    defer c2.deinit();
    try testing.expect(c1.sharesStorage(&c2));

    var m = try xgrammar.GrammarMatcher.init(a, &c1, .{});
    defer m.deinit();
    try testing.expect(try m.acceptString("\""));
    // Unescaped double quote must remain forbidden inside counted repeat body (#949).
    try testing.expect(!(try m.acceptString("\"")));
    // Valid JSON string chars can repeat 130 times cleanly (#963).
    var buf: [130]u8 = @splat('a');
    try testing.expect(try m.acceptString(&buf));
    try testing.expect(try m.acceptString("\""));
    try testing.expect(m.isCompleted());
}

test "v0.2.9 #977: regex \\s and \\S follow ECMAScript whitespace class" {
    const a = testing.allocator;
    var tok = try xgrammar.TokenizerInfo.init(a, &.{ "\xC2\xA0", "\xE3\x80\x80", "\xEF\xBB\xBF", "x", "</s>" }, .{
        .stop_token_ids = &.{4},
    });
    defer tok.deinit();

    const compiler = try xgrammar.GrammarCompiler.init(a, &tok, .{ .max_threads = 1 });
    defer compiler.deinit();

    var cs = try compiler.compileRegex("^\\s+$");
    defer cs.deinit();
    var ms = try xgrammar.GrammarMatcher.init(a, &cs, .{});
    defer ms.deinit();
    try testing.expect(try ms.acceptToken(0)); // U+00A0 NBSP
    try testing.expect(try ms.acceptToken(1)); // U+3000 Ideographic space
    try testing.expect(try ms.acceptToken(2)); // U+FEFF BOM
    try testing.expect(!(try ms.acceptToken(3))); // 'x'
    try testing.expect(ms.isCompleted());

    var cS = try compiler.compileRegex("^\\S$");
    defer cS.deinit();
    var mS = try xgrammar.GrammarMatcher.init(a, &cS, .{});
    defer mS.deinit();
    try testing.expect(!(try mS.acceptString("\xC2\xA0")));
    try testing.expect(!(try mS.acceptString("\xE3\x80\x80")));
    try testing.expect(try mS.acceptString("x"));
}

test "v0.2.9 #710: stop token is allowed and accepted when it completes the grammar" {
    const a = testing.allocator;
    var tok = try xgrammar.TokenizerInfo.init(a, &.{ "ok", "}", "</s>" }, .{
        .stop_token_ids = &.{ 1, 2 },
    });
    defer tok.deinit();

    const compiler = try xgrammar.GrammarCompiler.init(a, &tok, .{ .max_threads = 1 });
    defer compiler.deinit();
    var compiled = try compiler.compileEbnf("root ::= \"ok}\"", "root");
    defer compiled.deinit();

    var m = try xgrammar.GrammarMatcher.init(a, &compiled, .{});
    defer m.deinit();
    var bm = try xgrammar.TokenBitmask.init(a, 3);
    defer bm.deinit();

    // At start, neither stop token completes the grammar.
    _ = try m.fillBitmask(&bm);
    try testing.expect(bm.isAllowed(0));
    try testing.expect(!bm.isAllowed(1));
    try testing.expect(!bm.isAllowed(2));

    try testing.expect(try m.acceptToken(0)); // "ok"
    bm.reset();
    _ = try m.fillBitmask(&bm);
    // Token 1 ("}") is in stop_token_ids AND completes root -> must be unmasked!
    try testing.expect(bm.isAllowed(1));
    try testing.expect(!bm.isAllowed(2));

    try testing.expect(try m.acceptToken(1));
    try testing.expect(m.isCompleted());
    try testing.expect(m.isTerminated());

    // Rollback restores non-terminated state cleanly.
    try m.rollback(1, null);
    try testing.expect(!m.isTerminated());
    try testing.expect(!m.isCompleted());
}

test "v0.2.9 #942: token starting in literal and finishing in ExcludeToken free-text region" {
    const a = testing.allocator;
    var builder = try xgrammar.grammar.GrammarBuilder.new(a);
    defer builder.deinit();
    const prefix = try builder.add_byte_string("pre:");
    const free_tok = try builder.add_exclude_token_set(&.{2}); // exclude stop id 2
    const seq = try builder.add_sequence(&.{ prefix, free_tok });
    const choices = try builder.add_choices(&.{seq});
    _ = try builder.add_rule_named("root", choices);
    const g = try builder.into_grammar(a, "root", null);
    defer g.deinit();

    var tok = try xgrammar.TokenizerInfo.init(a, &.{ "pre:body", "bad", "</s>" }, .{
        .stop_token_ids = &.{2},
    });
    defer tok.deinit();

    const compiler = try xgrammar.GrammarCompiler.init(a, &tok, .{ .max_threads = 1 });
    defer compiler.deinit();
    var compiled = try compiler.compileGrammar(g);
    defer compiled.deinit();

    var m = try xgrammar.GrammarMatcher.init(a, &compiled, .{});
    defer m.deinit();
    var bm = try xgrammar.TokenBitmask.init(a, 3);
    defer bm.deinit();

    _ = try m.fillBitmask(&bm);
    try testing.expect(bm.isAllowed(0)); // "pre:body" spans literal + ExcludeToken
    try testing.expect(!bm.isAllowed(1));
    try testing.expect(!bm.isAllowed(2));

    try testing.expect(try m.acceptToken(0));
    try testing.expect(m.isCompleted());
    try m.rollback(1, null);
    try testing.expect(!m.isCompleted());
}

test "v0.2.9 #929: JSON Schema $ref resolves through array indices" {
    const a = testing.allocator;
    const schema =
        \\{"$defs":{"pair":[{"type":"integer"},{"type":"string"}]},"type":"object","properties":{"n":{"$ref":"#/$defs/pair/0"}},"required":["n"],"additionalProperties":false}
    ;
    var tok = try xgrammar.TokenizerInfo.init(a, &.{ "{\"n\": ", "42", "\"s\"", "}", "</s>" }, .{
        .stop_token_ids = &.{4},
    });
    defer tok.deinit();

    const compiler = try xgrammar.GrammarCompiler.init(a, &tok, .{ .max_threads = 1 });
    defer compiler.deinit();
    var compiled = try compiler.compileJsonSchema(schema, .{ .any_whitespace = false });
    defer compiled.deinit();

    var m = try xgrammar.GrammarMatcher.init(a, &compiled, .{});
    defer m.deinit();
    try testing.expect(try m.acceptString("{\"n\": 42}"));
    try testing.expect(m.isCompleted());

    try m.reset();
    try testing.expect(!(try m.acceptString("{\"n\": \"s\"}")));
}

test "v0.2.9 #926: schema literals preserve shortest JSON numbers" {
    const a = testing.allocator;
    const schema =
        \\{"type":"object","properties":{"a":{"const":0.1},"b":{"enum":[0.25,0.5]}},"required":["a","b"]}
    ;
    const ebnf = try xgrammar.json_schema_to_ebnf(a, schema, false, null, null, true, null, .Json, false, &.{}, null);
    defer a.free(ebnf);
    try testing.expect(std.mem.indexOf(u8, ebnf, "0.1") != null);
    try testing.expect(std.mem.indexOf(u8, ebnf, "0.100000") == null);
    try testing.expect(std.mem.indexOf(u8, ebnf, "0.25") != null);
}

test "v0.2.9 #948: generic JSON object/array rules preserve custom separators" {
    const a = testing.allocator;
    const schema = "{\"type\":\"array\"}";
    var tok = try xgrammar.TokenizerInfo.init(a, &.{ "[", "1", ",", ", ", "2", "]", "</s>" }, .{
        .stop_token_ids = &.{6},
    });
    defer tok.deinit();

    const compiler = try xgrammar.GrammarCompiler.init(a, &tok, .{ .max_threads = 1 });
    defer compiler.deinit();
    var compiled = try compiler.compileJsonSchema(schema, .{
        .any_whitespace = false,
        .separators = .{ .item = ",", .colon = ":" },
    });
    defer compiled.deinit();

    var m = try xgrammar.GrammarMatcher.init(a, &compiled, .{});
    defer m.deinit();
    try testing.expect(try m.acceptString("[1,2]"));
    try testing.expect(m.isCompleted());

    try m.reset();
    try testing.expect(!(try m.acceptString("[1, 2]")));
}

test "v0.2.9 #1012: find_jump_forward_string stays on whole UTF-8 characters" {
    const a = testing.allocator;
    var tok = try xgrammar.TokenizerInfo.init(a, &.{ "<0xE4>", "<0xB8>", "<0xAD>", "!", "</s>" }, .{
        .vocab_type = .ByteFallback,
        .stop_token_ids = &.{4},
    });
    defer tok.deinit();

    const compiler = try xgrammar.GrammarCompiler.init(a, &tok, .{ .max_threads = 1 });
    defer compiler.deinit();
    var compiled = try compiler.compileEbnf("root ::= \"中!\"", "root");
    defer compiled.deinit();

    var m = try xgrammar.GrammarMatcher.init(a, &compiled, .{});
    defer m.deinit();
    // Whole jump-forward from start is valid UTF-8 ("中!").
    const jf_start = try m.findJumpForwardString(a);
    defer a.free(jf_start);
    try testing.expectEqualStrings("中!", jf_start);

    // After accepting only byte 0 (<0xE4>) of "中", remaining continuation bytes must not split codepoint.
    try testing.expect(try m.acceptToken(0));
    const jf_mid = try m.findJumpForwardString(a);
    defer a.free(jf_mid);
    try testing.expectEqualStrings("", jf_mid);
}

test "v0.2.9 #903: bounded-string repeat classifies body with parent to prune invalid continuations" {
    const a = testing.allocator;
    var tok = try xgrammar.TokenizerInfo.init(a, &.{ "\"", "a", "abc", "a1", "a ", "a\"", "</s>" }, .{
        .stop_token_ids = &.{6},
    });
    defer tok.deinit();

    const compiler = try xgrammar.GrammarCompiler.init(a, &tok, .{ .max_threads = 1 });
    defer compiler.deinit();
    var compiled = try compiler.compileEbnf("root ::= \"\\\"\" [a-z]{3,5} \"\\\"\"", "root");
    defer compiled.deinit();

    var body_rule_id: ?i32 = null;
    var rid: i32 = 0;
    while (rid < compiled.grammar().numRules()) : (rid += 1) {
        if (rid != compiled.grammar().root_rule_id and compiled.grammar().rule(rid).is_exact_lookahead) {
            body_rule_id = rid;
            break;
        }
    }
    try testing.expect(body_rule_id != null);
    const body_fsm = compiled.grammar().per_rule_fsm(body_rule_id.?).?.get_fsm();
    const state = xgrammar.parser.ParserState.new(
        body_rule_id.?,
        compiled.grammar().rule(body_rule_id.?).body_expr_id,
        body_fsm.get_start(),
        xgrammar.parser.ParserState.NO_PREV_INPUT_POS,
    );
    const cached_mask = compiled.adaptiveTokenMaskCache().get(state.cache_key()).?;
    const sorted = tok.sorted_decoded_vocab;
    for (cached_mask.uncertain_indices) |sidx| {
        const t = sorted[@intCast(sidx)].token;
        try testing.expect(!std.mem.eql(u8, t, "a1"));
        try testing.expect(!std.mem.eql(u8, t, "a "));
    }

    var m = try xgrammar.GrammarMatcher.init(a, &compiled, .{});
    defer m.deinit();
    try testing.expect(try m.acceptString("\"abcd\""));
    try testing.expect(m.isCompleted());
    try m.reset();
    try testing.expect(!(try m.acceptString("\"ab\"")));
    try testing.expect(!(try m.acceptString("\"a1b\"")));
}
