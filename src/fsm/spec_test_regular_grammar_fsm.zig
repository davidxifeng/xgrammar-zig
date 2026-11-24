//! Port of `external/xgrammar/tests/cpp/test_regular_grammar_fsm.cc` (spec tests).
//!
//! Preserves EBNF terminal and call semantics when flattening regular grammars.

const std = @import("std");

const Diagnostic = @import("../Diagnostic.zig").Diagnostic;
const compiler_mod = @import("../compiler.zig");
const converter_mod = @import("../converter.zig");
const functor_mod = @import("../functor.zig");
const matcher_mod = @import("../matcher.zig");
const tokenizer_mod = @import("../tokenizer.zig");

/// The C++ `FromRegularGrammar` default state limit.
const MAX_NUM_STATES: i32 = 100_000;

test "test_repeated_calls_have_separate_returns" {
    const gpa = std.testing.allocator;
    var grammar = try functor_mod.fromEbnf(
        gpa,
        "root ::= part \"x\" part \"y\"\npart ::= \"a\" part | \"b\"\n",
        "root",
        null,
    );
    defer grammar.deinit();

    var fsm = try functor_mod.GrammarFsmBuilder.fromRegularGrammar(gpa, &grammar, MAX_NUM_STATES, null);
    defer fsm.deinit();
    for ([_][]const u8{ "bxby", "abxby", "bxaaby", "aaabxaaaby" }) |text| {
        try std.testing.expect(try fsm.acceptString(text));
    }
    for ([_][]const u8{ "", "by", "bxy", "bxay", "abxay", "bybx", "bxbyy" }) |text| {
        try std.testing.expect(!(try fsm.acceptString(text)));
    }
}

test "test_recursive_callee_cannot_use_callers_optional_exit" {
    const gpa = std.testing.allocator;
    var grammar = try functor_mod.fromEbnf(
        gpa,
        "root ::= part? \"z\" part*\npart ::= \"a\" part | \"b\"\n",
        "root",
        null,
    );
    defer grammar.deinit();

    var fsm = try functor_mod.GrammarFsmBuilder.fromRegularGrammar(gpa, &grammar, MAX_NUM_STATES, null);
    defer fsm.deinit();
    for ([_][]const u8{ "z", "bz", "abz", "zb", "zaab", "bzab", "abzbaab" }) |text| {
        try std.testing.expect(try fsm.acceptString(text));
    }
    for ([_][]const u8{ "az", "za", "bza", "aaz", "zba" }) |text| {
        try std.testing.expect(!(try fsm.acceptString(text)));
    }
}

test "test_regex_fallback_matches_original_grammar" {
    const gpa = std.testing.allocator;

    var tok = try tokenizer_mod.TokenizerInfo.init(gpa, &.{}, .{});
    defer tok.deinit();
    var comp = try compiler_mod.GrammarCompiler.init(gpa, &tok, .{
        .max_threads = 1,
        .cache_enabled = false,
    });
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
        var g = try converter_mod.fromRegex(gpa, pattern, null);
        defer g.deinit();
        var fsm = try functor_mod.GrammarFsmBuilder.fromRegularGrammar(gpa, &g, MAX_NUM_STATES, null);
        defer fsm.deinit();
        var compiled = try comp.compileGrammar(&g, null);
        defer compiled.deinit();
        var matcher = try matcher_mod.GrammarMatcher.init(gpa, &compiled, .{
            .terminate_without_stop_token = true,
        });
        defer matcher.deinit();
        for (samples) |sample| {
            try matcher.reset();
            const expected = (try matcher.acceptString(sample, null)) and matcher.isTerminated();
            try std.testing.expectEqual(expected, try fsm.acceptString(sample));
        }
    }
}

test "test_rejects_unsupported_recursion_and_bounds" {
    const gpa = std.testing.allocator;
    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);

    for ([_][]const u8{
        "root ::= \"a\" root \"b\" | \"\"",
        "root ::= \"a\" child | \"\"\nchild ::= \"b\" root | \"c\"",
        "root ::= Token(1)",
    }) |source| {
        var grammar = try functor_mod.fromEbnf(gpa, source, "root", null);
        defer grammar.deinit();
        try std.testing.expectError(
            error.Flatten,
            functor_mod.GrammarFsmBuilder.fromRegularGrammar(gpa, &grammar, MAX_NUM_STATES, &diag),
        );
    }
    var regex_grammar = try converter_mod.fromRegex(gpa, "(ab){100}", null);
    defer regex_grammar.deinit();
    try std.testing.expectError(
        error.Flatten,
        functor_mod.GrammarFsmBuilder.fromRegularGrammar(gpa, &regex_grammar, 10, &diag),
    );
}
