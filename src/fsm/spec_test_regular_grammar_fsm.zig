//! Port of `external/xgrammar/tests/cpp/test_regular_grammar_fsm.cc` (spec tests).
//!
//! Preserves EBNF terminal and call semantics when flattening regular grammars.

const std = @import("std");

/// The C++ `FromRegularGrammar` default state limit.
const MAX_NUM_STATES: i32 = 100_000;

test "test_repeated_calls_have_separate_returns" {
    const gpa = std.testing.allocator;
    const functor_mod = @import("../functor/mod.zig");
    const grammar = try functor_mod.grammar_normalizer_mod.from_ebnf(
        gpa,
        "root ::= part \"x\" part \"y\"\npart ::= \"a\" part | \"b\"\n",
        "root",
        null,
    );
    defer grammar.deinit();

    var fsm = try functor_mod.GrammarFsmBuilder.from_regular_grammar(gpa, grammar, MAX_NUM_STATES, null);
    defer fsm.deinit();
    for ([_][]const u8{ "bxby", "abxby", "bxaaby", "aaabxaaaby" }) |text| {
        try std.testing.expect(try fsm.accept_string(text));
    }
    for ([_][]const u8{ "", "by", "bxy", "bxay", "abxay", "bybx", "bxbyy" }) |text| {
        try std.testing.expect(!(try fsm.accept_string(text)));
    }
}

test "test_recursive_callee_cannot_use_callers_optional_exit" {
    const gpa = std.testing.allocator;
    const functor_mod = @import("../functor/mod.zig");
    const grammar = try functor_mod.grammar_normalizer_mod.from_ebnf(
        gpa,
        "root ::= part? \"z\" part*\npart ::= \"a\" part | \"b\"\n",
        "root",
        null,
    );
    defer grammar.deinit();

    var fsm = try functor_mod.GrammarFsmBuilder.from_regular_grammar(gpa, grammar, MAX_NUM_STATES, null);
    defer fsm.deinit();
    for ([_][]const u8{ "z", "bz", "abz", "zb", "zaab", "bzab", "abzbaab" }) |text| {
        try std.testing.expect(try fsm.accept_string(text));
    }
    for ([_][]const u8{ "az", "za", "bza", "aaz", "zba" }) |text| {
        try std.testing.expect(!(try fsm.accept_string(text)));
    }
}

test "test_regex_fallback_matches_original_grammar" {
    const gpa = std.testing.allocator;
    const tokenizer_mod = @import("../tokenizer/mod.zig");
    const converter_mod = @import("../converter/mod.zig");
    const functor_mod = @import("../functor/mod.zig");
    const compiler_mod = @import("../compiler/mod.zig");
    const matcher_mod = @import("../matcher/mod.zig");

    var tok = try tokenizer_mod.TokenizerInfo.new(gpa, &.{}, .Raw, null, null, false, null);
    defer tok.deinit();
    const comp = try compiler_mod.GrammarCompiler.new(gpa, &tok, 1, false, -1);
    defer comp.deinit();

    const patterns = [_][]const u8{
        "(ab|c){1,3}d?",
        "(a*b)+c{2,}",
        "(ab|){0,3}z",
        "[é你]+|a\\s\\D",
        "[^你]",
        "^[a-zA-Z0-9\\.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9-]+\\.[a-zA-Z]{2,}$",
    };
    const samples = [_][]const u8{
        "",
        "ab",
        "abc",
        "abccd",
        "d",
        "cccc",
        "bcc",
        "aabbccc",
        "abcc",
        "acccc",
        "z",
        "abz",
        "ababz",
        "abababz",
        "ababababz",
        "é你é",
        "你",
        "a b",
        "a 1",
        "a\tb",
        "name@example.com",
        "name@example",
        "name@.com",
        "<|close|>",
    };
    for (patterns) |pattern| {
        const g = try converter_mod.from_regex(gpa, pattern, null);
        defer g.deinit();
        var fsm = try functor_mod.GrammarFsmBuilder.from_regular_grammar(gpa, g, MAX_NUM_STATES, null);
        defer fsm.deinit();
        var compiled = try comp.compile_grammar(g, null);
        defer compiled.deinit();
        var matcher = try matcher_mod.GrammarMatcher.from_compiled_grammar(gpa, &compiled, true);
        defer matcher.deinit();
        for (samples) |sample| {
            try matcher.reset();
            const expected = (try matcher.accept_string(sample)) and matcher.is_terminated();
            try std.testing.expectEqual(expected, try fsm.accept_string(sample));
        }
    }
}

test "test_rejects_unsupported_recursion_and_bounds" {
    const gpa = std.testing.allocator;
    const functor_mod = @import("../functor/mod.zig");
    const converter_mod = @import("../converter/mod.zig");

    for ([_][]const u8{
        "root ::= \"a\" root \"b\" | \"\"",
        "root ::= \"a\" child | \"\"\nchild ::= \"b\" root | \"c\"",
        "root ::= Token(1)",
    }) |source| {
        const grammar = try functor_mod.grammar_normalizer_mod.from_ebnf(gpa, source, "root", null);
        defer grammar.deinit();
        var msg: ?[]u8 = null;
        try std.testing.expectError(
            error.Flatten,
            functor_mod.GrammarFsmBuilder.from_regular_grammar(gpa, grammar, MAX_NUM_STATES, &msg),
        );
        if (msg) |m| gpa.free(m);
    }
    const regex_grammar = try converter_mod.from_regex(gpa, "(ab){100}", null);
    defer regex_grammar.deinit();
    var msg: ?[]u8 = null;
    try std.testing.expectError(
        error.Flatten,
        functor_mod.GrammarFsmBuilder.from_regular_grammar(gpa, regex_grammar, 10, &msg),
    );
    if (msg) |m| gpa.free(m);
}
