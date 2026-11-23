//! Port of `external/xgrammar/tests/cpp/test_regular_grammar_fsm.cc` (spec tests).
//!
//! Preserves EBNF terminal and call semantics when flattening regular grammars.
//!
//! Every test here compares against `GrammarCompiler`/`GrammarMatcher` oracles (matcher
//! wave, Wave E); the regex-fallback case additionally needs `converter::from_regex`
//! (converter wave). `functor::GrammarFsmBuilder::from_regular_grammar` itself is delivered;
//! the gating stays until the matcher wave lands — see the delivery report.

const std = @import("std");

/// The C++ `FromRegularGrammar` default state limit.
const MAX_NUM_STATES: i32 = 100_000;

test "test_repeated_calls_have_separate_returns_skipped_until_matcher" {
    // Grammar::from_ebnf("root ::= part \"x\" part \"y\"\npart ::= \"a\" part | \"b\"\n");
    // fsm = GrammarFsmBuilder::from_regular_grammar(&grammar, MAX_NUM_STATES)
    // accept: bxby, abxby, bxaaby, aaabxaaaby; reject: "", by, bxy, bxay, abxay, bybx, bxbyy.
    return error.SkipZigTest;
}

test "test_recursive_callee_cannot_use_callers_optional_exit_skipped_until_matcher" {
    // Grammar::from_ebnf("root ::= part? \"z\" part*\npart ::= \"a\" part | \"b\"\n");
    // accept: z, bz, abz, zb, zaab, bzab, abzbaab; reject: az, za, bza, aaz, zba.
    return error.SkipZigTest;
}

test "test_regex_fallback_matches_original_grammar_skipped_until_matcher_and_converter" {
    // Needs GrammarFsmBuilder::from_regular_grammar + converter::from_regex +
    // GrammarCompiler + GrammarMatcher for the (ab|c){1,3}d?, (a*b)+c{2,}, (ab|){0,3}z,
    // [é你]+|a\s\D, [^你] and email patterns. 待 matcher 波(Wave E)+ converter 波.
    return error.SkipZigTest;
}

test "test_rejects_unsupported_recursion_and_bounds_skipped_until_matcher" {
    // from_regular_grammar must reject "a" root "b" | "" style non-regular recursion,
    // Token(1) expressions, and honor the state limit (e.g. (ab){100} with limit 10).
    return error.SkipZigTest;
}
