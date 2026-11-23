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

test "test_regex_fallback_matches_original_grammar_skipped_until_matcher" {
    // Needs GrammarCompiler + GrammarMatcher (Wave D/E).
    return error.SkipZigTest;
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
