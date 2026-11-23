//! Integration tests ported from `tests/rust_api.rs` and parser/testing parity checks.

const std = @import("std");
const xgrammar = @import("xgrammar.zig");

const testing = std.testing;

test "root_api_compiles_and_drives_a_matcher" {
    const a = testing.allocator;
    const grammar = try xgrammar.converter.from_regex(a, "a+", null);
    defer grammar.deinit();
    var tokenizer = try xgrammar.TokenizerInfo.new(a, &.{ "a", "b", "</s>" }, .Raw, null, null, false, null);
    defer tokenizer.deinit();
    const compiler = try xgrammar.GrammarCompiler.with_defaults(a, &tokenizer);
    defer compiler.deinit();
    var compiled = try compiler.compile_grammar(grammar, null);
    defer compiled.deinit();
    var matcher = try xgrammar.GrammarMatcher.from_compiled_grammar(a, &compiled, false);
    defer matcher.deinit();
    const bitmask = try xgrammar.allocate_token_bitmask(a, 1, tokenizer.vocab_size);
    defer a.free(bitmask);

    const shape = [2]i64{ 1, xgrammar.get_bitmask_size(tokenizer.vocab_size) };
    _ = try matcher.fill_next_token_bitmask(bitmask, &shape, 0, null);
    const masked = try xgrammar.get_masked_tokens_from_bitmask(a, bitmask, tokenizer.vocab_size, 0);
    defer a.free(masked);
    try testing.expectEqualSlices(i32, &.{ 1, 2 }, masked);
    try testing.expect(try matcher.accept_token(0));
    try testing.expect(matcher.is_completed());
}

test "distinct_serialized_rule_graphs_preserve_mask_walks" {
    const a = testing.allocator;
    var tokenizer = try xgrammar.TokenizerInfo.new(a, &.{ "a", "b", "</s>" }, .Raw, null, &.{2}, false, null);
    defer tokenizer.deinit();
    const comp = try xgrammar.GrammarCompiler.with_defaults(a, &tokenizer);
    defer comp.deinit();
    const regex_g = try xgrammar.converter.from_regex(a, "a+", null);
    defer regex_g.deinit();
    var compiled = try comp.compile_grammar(regex_g, null);
    defer compiled.deinit();

    const original_json = try compiled.serialize_json(a);
    defer a.free(original_json);

    for ([_]bool{ false, true }) |pad_aux| {
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const value = try xgrammar.support.parse_json(sa, original_json);
        const per_rule = value.object.get("grammar").?.object.get("per_rule_fsms").?.array.items[0].array.items[0].array.items[0].object;
        if (pad_aux) {
            try per_rule.getPtr("edge_aux_data").?.array.append(.{ .integer = 0 });
        } else {
            const offsets = &per_rule.getPtr("edges").?.object.getPtr("indptr_").?.array;
            try offsets.append(offsets.items[offsets.items.len - 1]);
        }
        var restored = try xgrammar.CompiledGrammar.deserialize_json_value(a, value, &tokenizer, null);
        defer restored.deinit();

        var expected = try xgrammar.GrammarMatcher.from_compiled_grammar(a, &compiled, false);
        defer expected.deinit();
        var actual = try xgrammar.GrammarMatcher.from_compiled_grammar(a, &restored, false);
        defer actual.deinit();

        const shape = [2]i64{ 1, xgrammar.get_bitmask_size(tokenizer.vocab_size) };
        for ([_]i32{ 0, 0, 2 }) |token| {
            const expected_mask = try xgrammar.allocate_token_bitmask(a, 1, tokenizer.vocab_size);
            defer a.free(expected_mask);
            const actual_mask = try a.dupe(i32, expected_mask);
            defer a.free(actual_mask);
            try testing.expectEqual(
                try expected.fill_next_token_bitmask(expected_mask, &shape, 0, null),
                try actual.fill_next_token_bitmask(actual_mask, &shape, 0, null),
            );
            try testing.expectEqualSlices(i32, expected_mask, actual_mask);
            try testing.expectEqual(try expected.accept_token(token), try actual.accept_token(token));
            try testing.expectEqual(expected.is_completed(), actual.is_completed());
        }
    }
}

test "shared_rule_storage_keeps_accepting_states_per_rule" {
    const a = testing.allocator;
    var tokenizer = try xgrammar.TokenizerInfo.new(a, &.{ "a", "b", "</s>" }, .Raw, null, &.{2}, false, null);
    defer tokenizer.deinit();
    const comp = try xgrammar.GrammarCompiler.with_defaults(a, &tokenizer);
    defer comp.deinit();
    const ebnf_g = try xgrammar.functor.grammar_normalizer_mod.from_ebnf(
        a,
        "root ::= \"a\" second\nsecond ::= \"b\"",
        "root",
        null,
    );
    defer ebnf_g.deinit();
    var compiled = try comp.compile_grammar(ebnf_g, null);
    defer compiled.deinit();

    const json_str = try compiled.serialize_json(a);
    defer a.free(json_str);
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const value = try xgrammar.support.parse_json(scratch.allocator(), json_str);

    const per_rule = value.object.get("grammar").?.object.get("per_rule_fsms").?.array;
    const root_start = per_rule.items[0].array.items[0].array.items[1];
    per_rule.items[1].array.items[0].array.items[1] = root_start;
    var ends_arr = std.json.Array.init(scratch.allocator());
    try ends_arr.append(root_start);
    per_rule.items[1].array.items[0].array.items[2] = .{ .array = ends_arr };

    var restored = try xgrammar.CompiledGrammar.deserialize_json_value(a, value, &tokenizer, null);
    defer restored.deinit();
    var matcher = try xgrammar.GrammarMatcher.from_compiled_grammar(a, &restored, false);
    defer matcher.deinit();
    try testing.expect(try matcher.accept_token(0));
    try testing.expect(matcher.is_completed());
    try testing.expect(try matcher.accept_token(2));
    try testing.expect(matcher.is_terminated());
}

test "earley parser clone produces independent divergent parses" {
    const a = testing.allocator;
    const g = try xgrammar.functor.grammar_normalizer_mod.from_ebnf(a, "root ::= \"ab\" | \"ac\"", "root", null);
    defer g.deinit();
    const opt = try xgrammar.functor.grammar_optimizer(a, g, null);
    defer opt.deinit();

    const p1 = try xgrammar.parser.EarleyParser.new(a, opt, null);
    defer p1.deinit();
    try testing.expect(try p1.advance('a'));

    const p2 = try p1.clone(a);
    defer p2.deinit();

    try testing.expect(try p1.advance('b'));
    try testing.expect(p1.is_root_completed());
    try testing.expect(!p2.is_root_completed());

    try testing.expect(!(try p2.advance('b' + 2))); // 'd'
    try testing.expect(try p2.advance('c'));
    try testing.expect(p2.is_root_completed());
}

test "testing print_grammar_fsms and is_rule_fsm_accept_string" {
    const a = testing.allocator;
    const g = try xgrammar.functor.grammar_normalizer_mod.from_ebnf(a, "root ::= [a-z] [a-z]*", "root", null);
    defer g.deinit();
    const opt = try xgrammar.functor.grammar_optimizer(a, g, null);
    defer opt.deinit();

    const dumped = try xgrammar.testing.print_grammar_fsms(a, opt);
    defer a.free(dumped);
    try testing.expect(std.mem.indexOf(u8, dumped, "Rule 0: root, FSM: CompactFSM(") != null);
    try testing.expect(try xgrammar.testing.is_rule_fsm_accept_string(opt, 0, "abc"));
    try testing.expect(!(try xgrammar.testing.is_rule_fsm_accept_string(opt, 0, "")));
    try testing.expect(!(try xgrammar.testing.is_rule_fsm_accept_string(opt, 0, "123")));
}

test {
    _ = @import("oracle_parity_test.zig");
}
