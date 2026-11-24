//! Integration tests ported from `tests/rust_api.rs` and parser/testing parity checks.

const std = @import("std");
const xgrammar = @import("xgrammar.zig");

const testing = std.testing;

test "root API compiles and drives a matcher" {
    const a = testing.allocator;
    var grammar = try xgrammar.Grammar.fromRegex(a, "a+", null);
    defer grammar.deinit();
    var tokenizer = try xgrammar.TokenizerInfo.init(a, &.{ "a", "b", "</s>" }, .{});
    defer tokenizer.deinit();
    var compiler = try xgrammar.GrammarCompiler.init(a, &tokenizer, .{});
    defer compiler.deinit();
    var compiled = try compiler.compileGrammar(&grammar, null);
    defer compiled.deinit();
    var matcher = try xgrammar.GrammarMatcher.init(a, &compiled, .{});
    defer matcher.deinit();
    var bitmask = try xgrammar.TokenBitmask.initSingle(a, tokenizer.vocabSize());
    defer bitmask.deinit();

    _ = try matcher.fillNextTokenBitmask(&bitmask, 0, null);
    const masked = try bitmask.maskedTokens(a, 0);
    defer a.free(masked);
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, masked);
    try testing.expect(try matcher.acceptToken(0, null));
    try testing.expect(matcher.isCompleted());
}

test "distinct serialized rule graphs preserve mask walks" {
    const a = testing.allocator;
    var tokenizer = try xgrammar.TokenizerInfo.init(a, &.{ "a", "b", "</s>" }, .{ .stop_token_ids = &.{2} });
    defer tokenizer.deinit();
    var comp = try xgrammar.GrammarCompiler.init(a, &tokenizer, .{});
    defer comp.deinit();
    var regex_g = try xgrammar.Grammar.fromRegex(a, "a+", null);
    defer regex_g.deinit();
    var compiled = try comp.compileGrammar(&regex_g, null);
    defer compiled.deinit();

    const original_json = try compiled.serializeJson(a);
    defer a.free(original_json);

    for ([_]bool{ false, true }) |pad_aux| {
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const value = try xgrammar.internal.support.parseJson(sa, original_json);
        const per_rule = value.object.get("grammar").?.object.get("per_rule_fsms").?.array.items[0].array.items[0].array.items[0].object;
        if (pad_aux) {
            try per_rule.getPtr("edge_aux_data").?.array.append(.{ .integer = 0 });
        } else {
            const offsets = &per_rule.getPtr("edges").?.object.getPtr("indptr_").?.array;
            try offsets.append(offsets.items[offsets.items.len - 1]);
        }
        var restored = try xgrammar.CompiledGrammar.deserializeJsonValue(a, value, &tokenizer, null);
        defer restored.deinit();

        var expected = try xgrammar.GrammarMatcher.init(a, &compiled, .{});
        defer expected.deinit();
        var actual = try xgrammar.GrammarMatcher.init(a, &restored, .{});
        defer actual.deinit();

        for ([_]u32{ 0, 0, 2 }) |token| {
            var expected_mask = try xgrammar.TokenBitmask.initSingle(a, tokenizer.vocabSize());
            defer expected_mask.deinit();
            var actual_mask = try xgrammar.TokenBitmask.initSingle(a, tokenizer.vocabSize());
            defer actual_mask.deinit();
            try testing.expectEqual(
                try expected.fillNextTokenBitmask(&expected_mask, 0, null),
                try actual.fillNextTokenBitmask(&actual_mask, 0, null),
            );
            try testing.expectEqualSlices(i32, expected_mask.words, actual_mask.words);
            try testing.expectEqual(try expected.acceptToken(token, null), try actual.acceptToken(token, null));
            try testing.expectEqual(expected.isCompleted(), actual.isCompleted());
        }
    }
}

test "shared rule storage keeps accepting states per rule" {
    const a = testing.allocator;
    var tokenizer = try xgrammar.TokenizerInfo.init(a, &.{ "a", "b", "</s>" }, .{ .stop_token_ids = &.{2} });
    defer tokenizer.deinit();
    var comp = try xgrammar.GrammarCompiler.init(a, &tokenizer, .{});
    defer comp.deinit();
    var ebnf_g = try xgrammar.Grammar.fromEbnf(a, "root ::= \"a\" second\nsecond ::= \"b\"", .{});
    defer ebnf_g.deinit();
    var compiled = try comp.compileGrammar(&ebnf_g, null);
    defer compiled.deinit();

    const json_str = try compiled.serializeJson(a);
    defer a.free(json_str);
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const value = try xgrammar.internal.support.parseJson(scratch.allocator(), json_str);

    const per_rule = value.object.get("grammar").?.object.get("per_rule_fsms").?.array;
    const root_start = per_rule.items[0].array.items[0].array.items[1];
    per_rule.items[1].array.items[0].array.items[1] = root_start;
    var ends_arr = std.json.Array.init(scratch.allocator());
    try ends_arr.append(root_start);
    per_rule.items[1].array.items[0].array.items[2] = .{ .array = ends_arr };

    var restored = try xgrammar.CompiledGrammar.deserializeJsonValue(a, value, &tokenizer, null);
    defer restored.deinit();
    var matcher = try xgrammar.GrammarMatcher.init(a, &restored, .{});
    defer matcher.deinit();
    try testing.expect(try matcher.acceptToken(0, null));
    try testing.expect(matcher.isCompleted());
    try testing.expect(try matcher.acceptToken(2, null));
    try testing.expect(matcher.isTerminated());
}

test "EarleyParser dupe produces independent divergent parses" {
    const a = testing.allocator;
    var g = try xgrammar.Grammar.fromEbnf(a, "root ::= \"ab\" | \"ac\"", .{});
    defer g.deinit();
    var opt = try xgrammar.internal.functor.optimizeGrammar(a, &g, null);
    defer opt.deinit();

    var p1 = try xgrammar.internal.parser.EarleyParser.init(a, &opt, null);
    defer p1.deinit();
    try testing.expect(try p1.advance('a'));

    var p2 = try p1.dupe(a);
    defer p2.deinit();

    try testing.expect(try p1.advance('b'));
    try testing.expect(p1.isRootCompleted());
    try testing.expect(!p2.isRootCompleted());

    try testing.expect(!(try p2.advance('b' + 2))); // 'd'
    try testing.expect(try p2.advance('c'));
    try testing.expect(p2.isRootCompleted());
}

test "testing printGrammarFsms and isRuleFsmAcceptString" {
    const a = testing.allocator;
    var g = try xgrammar.Grammar.fromEbnf(a, "root ::= [a-z] [a-z]*", .{});
    defer g.deinit();
    var opt = try xgrammar.internal.functor.optimizeGrammar(a, &g, null);
    defer opt.deinit();

    const dumped = try xgrammar.testing.printGrammarFsms(a, &opt);
    defer a.free(dumped);
    try testing.expect(std.mem.indexOf(u8, dumped, "Rule 0: root, FSM: CompactFSM(") != null);
    try testing.expect(try xgrammar.testing.isRuleFsmAcceptString(a, &opt, 0, "abc"));
    try testing.expect(!(try xgrammar.testing.isRuleFsmAcceptString(a, &opt, 0, "")));
    try testing.expect(!(try xgrammar.testing.isRuleFsmAcceptString(a, &opt, 0, "123")));
}

test {
    _ = @import("oracle_parity_test.zig");
    _ = @import("idiomatic_api_test.zig");
    _ = @import("upstream_v029_test.zig");
}
