//! Port of `external/xgrammar/tests/cpp/test_fsm_builder.cc` (spec tests).
//!
//! Covers the trie builder and the regex builder (`RegexFsmBuilder`). The per-expression
//! `GrammarFsmBuilder` tests (tag-dispatch, token-tag-dispatch, byte-string, rule-ref,
//! character-class, sequence, choices) and the `build_with_forbidden_chars` tests that need
//! `GrammarFsmBuilder::json_string_forbidden_chars` are translated but gated behind the
//! functor wave (`error.SkipZigTest` until functor lands) — see the delivery report.

const std = @import("std");
const fsm_mod = @import("mod.zig");
const functor_mod = @import("../functor/mod.zig");
const grammar_mod = @import("../grammar/mod.zig");
const GrammarFsmBuilder = functor_mod.GrammarFsmBuilder;
const GrammarExpr = grammar_mod.GrammarExpr;
const TagDispatch = grammar_mod.TagDispatch;
const TagRulePair = grammar_mod.tag_dispatch.TagRulePair;
const TokenTagDispatch = grammar_mod.TokenTagDispatch;
const TriggerRulePair = grammar_mod.token_tag_dispatch.TriggerRulePair;
const CompactFsm = fsm_mod.CompactFsm;
const EdgeKind = fsm_mod.EdgeKind;
const FsmWithStartEnd = fsm_mod.FsmWithStartEnd;
const NO_NEXT_STATE = fsm_mod.NO_NEXT_STATE;
const RegexFsmBuilder = fsm_mod.RegexFsmBuilder;
const TrieFsmBuilder = fsm_mod.TrieFsmBuilder;

const A = std.mem.Allocator;

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

fn build(a: A, regex: []const u8) !FsmWithStartEnd {
    return RegexFsmBuilder.build(a, regex, null, "", null);
}

fn build_err(a: A, regex: []const u8) ![]u8 {
    var msg: ?[]u8 = null;
    if (RegexFsmBuilder.build(a, regex, null, "", &msg)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {
        return msg.?;
    }
}

test "test_trie_fsm_builder" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const patterns = [_][]const u8{ "hello", "hi", "哈哈", "哈", "hili", "good" };
    const fsm_opt = try TrieFsmBuilder.build(a, &patterns, &.{}, null, true, false);
    var fsm = fsm_opt.?;
    defer fsm.deinit();

    // A compact round-trip is constructible from the built trie.
    var compact = try CompactFsm.from_fsm(a, fsm.get_fsm());
    defer compact.deinit();

    try std.testing.expectEqual(@as(i32, 0), fsm.get_start());

    const next = struct {
        fn f(fsm_wse: *const FsmWithStartEnd, state: i32, c: u8) i32 {
            return fsm_wse.get_fsm().next_state(state, c, .CharRange);
        }
    }.f;

    // "hello".
    try std.testing.expectEqual(@as(i32, 1), next(&fsm, fsm.get_start(), 'h'));
    try std.testing.expectEqual(@as(i32, 2), next(&fsm, 1, 'e'));
    try std.testing.expectEqual(@as(i32, 3), next(&fsm, 2, 'l'));
    try std.testing.expectEqual(@as(i32, 4), next(&fsm, 3, 'l'));
    try std.testing.expectEqual(@as(i32, 5), next(&fsm, 4, 'o'));
    try std.testing.expect(fsm.is_end_state(5));

    // "hil" (prefix of "hili", not itself a pattern).
    try std.testing.expectEqual(@as(i32, 1), next(&fsm, fsm.get_start(), 'h'));
    try std.testing.expectEqual(@as(i32, 6), next(&fsm, 1, 'i'));
    try std.testing.expectEqual(@as(i32, 13), next(&fsm, 6, 'l'));
    try std.testing.expect(!fsm.is_end_state(13));

    // Walk failure: "goe" has no transition after "go".
    try std.testing.expectEqual(@as(i32, 15), next(&fsm, fsm.get_start(), 'g'));
    try std.testing.expectEqual(@as(i32, 16), next(&fsm, 15, 'o'));
    try std.testing.expectEqual(@as(i32, -1), next(&fsm, 16, 'e'));
}

test "test_trie_excluded_suffixes" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // Following a longer pattern must not hide an excluded suffix at an explicit trie node,
    // including suffixes inherited through multiple failure links.
    const excluded_sets = [_][]const []const u8{
        &.{ "b", "abx" },
        &.{ "abx", "b" },
        &.{ "b", "abx", "xabxx" },
        &.{ "ab", "ab", "abx" },
    };
    for (excluded_sets) |excludes| {
        const fsm_opt = try TrieFsmBuilder.build(a, &.{}, excludes, null, true, true);
        var fsm_wse = fsm_opt.?;
        defer fsm_wse.deinit();
        const fsm = fsm_wse.get_fsm();
        // Compare the byte FSM against an independent substring predicate for every string up to
        // length five, rather than depending on generated state numbers.
        var inputs: std.ArrayList([]u8) = .empty;
        try inputs.append(a, try a.dupe(u8, ""));
        for (0..6) |length| {
            var next_inputs: std.ArrayList([]u8) = .empty;
            for (inputs.items) |input| {
                var expected = true;
                for (excludes) |excluded| {
                    if (input.len >= excluded.len) {
                        for (0..input.len - excluded.len + 1) |start| {
                            if (std.mem.eql(u8, input[start .. start + excluded.len], excluded)) expected = false;
                        }
                    }
                }
                var state = fsm_wse.get_start();
                for (input) |byte| {
                    state = fsm.next_state(state, byte, .CharRange);
                    if (state == NO_NEXT_STATE) break;
                }
                try std.testing.expectEqual(expected, state != NO_NEXT_STATE);
                if (length < 5) {
                    for ("abx") |byte| {
                        const extended = try a.alloc(u8, input.len + 1);
                        @memcpy(extended[0..input.len], input);
                        extended[input.len] = byte;
                        try next_inputs.append(a, extended);
                    }
                }
            }
            inputs = next_inputs;
        }
    }
}

// ---------------------------------------------------------------------------
// Regex builder tests (no GrammarBuilder).
// ---------------------------------------------------------------------------

test "test_regex_repeat_zero" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // {0} / {0,0} matches exactly the empty string (ECMA-262 semantics, and consistent
    // with the EBNF parser and the CFG fallback path).
    var m1 = try build(a, "a{0}");
    defer m1.deinit();
    try std.testing.expect(try m1.accept_string(""));
    try std.testing.expect(!try m1.accept_string("a"));

    var m2 = try build(a, "a{0,0}");
    defer m2.deinit();
    try std.testing.expect(try m2.accept_string(""));
    try std.testing.expect(!try m2.accept_string("a"));

    var m3 = try build(a, "(ab){0}");
    defer m3.deinit();
    try std.testing.expect(try m3.accept_string(""));
    try std.testing.expect(!try m3.accept_string("ab"));

    // In a concatenation the {0} element contributes nothing.
    var m4 = try build(a, "ba{0}c");
    defer m4.deinit();
    try std.testing.expect(try m4.accept_string("bc"));
    try std.testing.expect(!try m4.accept_string("bac"));

    // The empty-string FSM survives the simplification passes.
    var m5 = try build(a, "ba{0}c");
    defer m5.deinit();
    var s5 = try m5.simplify_epsilon(a);
    defer s5.deinit();
    var merged5 = try s5.merge_equivalent_states(a);
    defer merged5.deinit();
    try std.testing.expect(try merged5.accept_string("bc"));
    try std.testing.expect(!try merged5.accept_string("bac"));

    // A lower bound larger than the upper bound is an error in every regex dialect.
    try std.testing.expectError(error.RegexParse, build(a, "a{3,1}"));
    try std.testing.expectError(error.RegexParse, build(a, "a{1,0}"));
}

test "test_regex_case_insensitive_flag" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();

    var m1 = try build(a, "(?i)abc");
    defer m1.deinit();
    try std.testing.expect(try m1.accept_string("abc"));
    try std.testing.expect(try m1.accept_string("ABC"));
    try std.testing.expect(try m1.accept_string("aBc"));
    try std.testing.expect(!try m1.accept_string("abd"));

    var m2 = try build(a, "(?i)(ab|cd)+");
    defer m2.deinit();
    try std.testing.expect(try m2.accept_string("aBcD"));
    try std.testing.expect(!try m2.accept_string("ac"));

    var m3 = try build(a, "(?i)[a-dx]");
    defer m3.deinit();
    try std.testing.expect(try m3.accept_string("b"));
    try std.testing.expect(try m3.accept_string("B"));
    try std.testing.expect(try m3.accept_string("X"));
    try std.testing.expect(!try m3.accept_string("e"));
    try std.testing.expect(!try m3.accept_string("E"));

    var m4 = try build(a, "(?i)[^k]");
    defer m4.deinit();
    try std.testing.expect(try m4.accept_string("a"));
    try std.testing.expect(!try m4.accept_string("k"));
    try std.testing.expect(!try m4.accept_string("K"));

    // Only ASCII letters are folded; non-ASCII characters match literally.
    var m5 = try build(a, "(?i)Σ");
    defer m5.deinit();
    try std.testing.expect(try m5.accept_string("Σ"));
    try std.testing.expect(!try m5.accept_string("σ"));

    // Without the prefix the match stays case-sensitive.
    var m6 = try build(a, "abc");
    defer m6.deinit();
    try std.testing.expect(!try m6.accept_string("ABC"));
}

test "test_regex_escapes" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();

    // \xHH, \uHHHH and \u{...} escapes, both standalone and inside classes.
    var m1 = try build(a, "\\x41B\\u{43}");
    defer m1.deinit();
    try std.testing.expect(try m1.accept_string("ABC"));

    var m2 = try build(a, "\\u{1F600}");
    defer m2.deinit();
    try std.testing.expect(try m2.accept_string("😀"));
    try std.testing.expect(!try m2.accept_string("😁"));

    var m3 = try build(a, "[A-C]+");
    defer m3.deinit();
    try std.testing.expect(try m3.accept_string("ABC"));
    try std.testing.expect(!try m3.accept_string("D"));

    // A quantifier after a multi-byte character applies to the whole codepoint.
    var m4 = try build(a, "好*");
    defer m4.deinit();
    try std.testing.expect(try m4.accept_string(""));
    try std.testing.expect(try m4.accept_string("好好"));
    try std.testing.expect(!try m4.accept_string("\xbd"));

    // \s follows ECMAScript WhiteSpace + LineTerminator (ASCII whitespace + U+00A0, U+3000, U+FEFF, ...).
    var m5 = try build(a, "\\s+");
    defer m5.deinit();
    try std.testing.expect(try m5.accept_string(" \t\n\r\x0c\x0b"));
    try std.testing.expect(!try m5.accept_string("\x00"));
    try std.testing.expect(!try m5.accept_string("\x01"));

    // \S is the codepoint-domain complement, so non-ASCII characters are accepted.
    var m6 = try build(a, "\\S");
    defer m6.deinit();
    try std.testing.expect(try m6.accept_string("好"));
    try std.testing.expect(try m6.accept_string("\x00"));
    try std.testing.expect(!try m6.accept_string(" "));
}

test "test_regex_unsupported_features" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // Word boundaries, Unicode properties and backreferences raise errors.
    try std.testing.expectError(error.RegexParse, build(a, "a\\b"));
    try std.testing.expectError(error.RegexParse, build(a, "a\\B"));
    try std.testing.expectError(error.RegexParse, build(a, "\\p{L}"));
    try std.testing.expectError(error.RegexParse, build(a, "(a)\\1"));
    try std.testing.expectError(error.RegexParse, build(a, "(?<name>a)\\k<name>"));
    try std.testing.expectError(error.RegexParse, build(a, "(?<=a)b"));
    try std.testing.expectError(error.RegexParse, build(a, "[]"));
    try std.testing.expectError(error.RegexParse, build(a, "[^]"));

    // Lookahead assertions are ignored with a warning (treated as the empty string).
    var m1 = try build(a, "a(?=b)c");
    defer m1.deinit();
    try std.testing.expect(try m1.accept_string("ac"));
    var m2 = try build(a, "a(?!b)c");
    defer m2.deinit();
    try std.testing.expect(try m2.accept_string("ac"));

    // Named groups compile like plain groups; the name is ignored.
    var m3 = try build(a, "(?<name>ab)+");
    defer m3.deinit();
    try std.testing.expect(try m3.accept_string("abab"));
    var m4 = try build(a, "(?P<name>ab)c");
    defer m4.deinit();
    try std.testing.expect(try m4.accept_string("abc"));

    // Mid-pattern anchors are ignored with a warning.
    var m5 = try build(a, "a^b$c");
    defer m5.deinit();
    try std.testing.expect(try m5.accept_string("abc"));

    // Non-greedy quantifiers behave like their greedy counterparts.
    var m6 = try build(a, "a*?b+?c??(de){1,2}?");
    defer m6.deinit();
    try std.testing.expect(try m6.accept_string("aabbcde"));
    try std.testing.expect(try m6.accept_string("bdede"));

    // Empty alternatives match the empty string.
    var m7 = try build(a, "(a|)b");
    defer m7.deinit();
    try std.testing.expect(try m7.accept_string("ab"));
    try std.testing.expect(try m7.accept_string("b"));
    var m8 = try build(a, "a|");
    defer m8.deinit();
    try std.testing.expect(try m8.accept_string("a"));
    try std.testing.expect(try m8.accept_string(""));
}

test "test_regex_error_messages" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // Parse errors mirror the RegexConverter format and carry the 1-based position.
    try std.testing.expectEqualStrings(
        "Regex parsing error at position 1: There is nothing to repeat before '+'",
        try build_err(a, "+a"),
    );
    try std.testing.expectEqualStrings(
        "Regex parsing error at position 3: Unmatched ')'",
        try build_err(a, "ab)"),
    );
    try std.testing.expectEqualStrings(
        "Regex parsing error at position 2: Unmatched ']'",
        try build_err(a, "a]"),
    );
    try std.testing.expectEqualStrings(
        "Regex parsing error at position 2: The parenthesis is not closed",
        try build_err(a, "a(bc"),
    );
    try std.testing.expectEqualStrings(
        "Regex parsing error at position 2: Unclosed '['",
        try build_err(a, "a[bc"),
    );
    try std.testing.expectEqualStrings(
        "Regex parsing error at position 2: Empty character class is not allowed in regex",
        try build_err(a, "a[]"),
    );
    try std.testing.expectEqualStrings(
        "Regex parsing error at position 2: Invalid repetition count: expected a number after '{'",
        try build_err(a, "a{,2}"),
    );
    try std.testing.expectEqualStrings(
        "Regex parsing error at position 2: Invalid repetition count: the lower bound 3 is larger than the upper bound 1",
        try build_err(a, "a{3,1}"),
    );
    try std.testing.expectEqualStrings(
        "Regex parsing error at position 2: Invalid repetition count: the count 9999999999 is too large",
        try build_err(a, "a{1,9999999999}"),
    );
    try std.testing.expectEqualStrings(
        "Regex parsing error at position 2: Word boundary assertion \\b is not supported in regex",
        try build_err(a, "a\\b"),
    );
    try std.testing.expectEqualStrings(
        "Regex parsing error at position 1: Invalid named capturing group",
        try build_err(a, "(?<name)a"),
    );
    // The position includes the "(?i)" prefix when present.
    try std.testing.expectEqualStrings(
        "Regex parsing error at position 5: There is nothing to repeat before '+'",
        try build_err(a, "(?i)+a"),
    );
}

test "test_regex_matches_empty" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const matches_empty = struct {
        fn f(al: A, regex: []const u8) !bool {
            var msg: ?[]u8 = null;
            if (RegexFsmBuilder.matches_empty(al, regex, &msg)) |v| return v else |_| return error.TestUnexpectedResult;
        }
    };
    try std.testing.expect(try matches_empty.f(a, "a*"));
    try std.testing.expect(try matches_empty.f(a, "(a|)"));
    try std.testing.expect(try matches_empty.f(a, "a{0,10}"));
    try std.testing.expect(try matches_empty.f(a, "(ab)?"));
    try std.testing.expect(!try matches_empty.f(a, "a+"));
    try std.testing.expect(!try matches_empty.f(a, "a{1,10}"));
    try std.testing.expect(!try matches_empty.f(a, "ab|cd"));
    // No FSM is built, so huge bounded repetitions are cheap to check.
    try std.testing.expect(!try matches_empty.f(a, "(abc){2,1000000}"));
    try std.testing.expect(try matches_empty.f(a, "(abc){0,1000000}"));
    try std.testing.expect(try matches_empty.f(a, "(?i)A*"));
    var msg: ?[]u8 = null;
    try std.testing.expectError(error.RegexParse, RegexFsmBuilder.matches_empty(a, "\\b", &msg));
}

test "test_regex_large_repeat_without_builder" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // Without a GrammarBuilder, moderate repetitions are unrolled physically.
    var m1 = try build(a, "a{2,300}");
    defer m1.deinit();
    try std.testing.expect(!try m1.accept_string("a"));
    try std.testing.expect(try m1.accept_string("aa"));
    const a300 = try a.alloc(u8, 300);
    @memset(a300, 'a');
    const a301 = try a.alloc(u8, 301);
    @memset(a301, 'a');
    try std.testing.expect(try m1.accept_string(a300));
    try std.testing.expect(!try m1.accept_string(a301));

    // Repetitions whose estimated state count is too large report an error instead of hanging.
    try std.testing.expectError(error.RepeatTooLarge, build(a, "(abcdefghij){1,100000}"));
}

// ---------------------------------------------------------------------------
// Tests below need `functor::GrammarFsmBuilder` (delivered and wired).
// ---------------------------------------------------------------------------

/// Builds a `TagDispatch` from string tags.
fn tag_dispatch(a: A, pairs: []const [2][]const u8, loop_after: bool, excludes: []const []const u8) !TagDispatch {
    var td = TagDispatch.empty();
    for (pairs) |pair| {
        try td.tag_rule_pairs.append(a, .{ .tag = try a.dupe(u8, pair[0]), .rule_id = try std.fmt.parseInt(i32, pair[1], 10) });
    }
    td.loop_after_dispatch = loop_after;
    for (excludes) |e| {
        try td.excludes.append(a, try a.dupe(u8, e));
    }
    return td;
}

test "test_tag_dispatch_fsm_builder1" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const td = try tag_dispatch(a, &.{ .{ "hel", "1" }, .{ "hi", "2" }, .{ "哈", "3" } }, true, &.{});
    const fsm_opt = try GrammarFsmBuilder.tag_dispatch(a, &td);
    const fsm = fsm_opt.?;
    const expected = "FSM(num_states=8, start=0, end=[0, 1, 2, 5, 6], edges=[" ++
        "\n0: [[\\0-g]->0, 'h'->1, [i-\\xe4]->0, '\\xe5'->5, [\\xe6-\\xff]->0]" ++
        "\n1: [[\\0-d]->0, 'e'->2, [f-g]->0, 'h'->1, 'i'->4, [j-\\xe4]->0, '\\xe5'->5, [\\xe6-\\xff]->0]" ++
        "\n2: [[\\0-g]->0, 'h'->1, [i-k]->0, 'l'->3, [m-\\xe4]->0, '\\xe5'->5, [\\xe6-\\xff]->0]" ++
        "\n3: [Rule(1)->0]" ++
        "\n4: [Rule(2)->0]" ++
        "\n5: [[\\0-g]->0, 'h'->1, [i-\\x92]->0, '\\x93'->6, [\\x94-\\xe4]->0, '\\xe5'->5, [\\xe6-\\xff]->0]" ++
        "\n6: [[\\0-g]->0, 'h'->1, [i-\\x87]->0, '\\x88'->7, [\\x89-\\xe4]->0, '\\xe5'->5, [\\xe6-\\xff]->0]" ++
        "\n7: [Rule(3)->0]" ++
        "\n])";
    const actual = try fsm.to_string_repr();
    try std.testing.expectEqualStrings(expected, actual);
}

test "test_tag_dispatch_fsm_builder2" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const td = try tag_dispatch(a, &.{ .{ "hel", "1" }, .{ "hi", "2" }, .{ "哈", "3" } }, false, &.{});
    const fsm_opt = try GrammarFsmBuilder.tag_dispatch(a, &td);
    const fsm = fsm_opt.?;
    const expected = "FSM(num_states=11, start=0, end=[0, 1, 2, 5, 6, 8, 9, 10], edges=[" ++
        "\n0: [[\\0-g]->0, 'h'->1, [i-\\xe4]->0, '\\xe5'->5, [\\xe6-\\xff]->0]" ++
        "\n1: [[\\0-d]->0, 'e'->2, [f-g]->0, 'h'->1, 'i'->4, [j-\\xe4]->0, '\\xe5'->5, [\\xe6-\\xff]->0]" ++
        "\n2: [[\\0-g]->0, 'h'->1, [i-k]->0, 'l'->3, [m-\\xe4]->0, '\\xe5'->5, [\\xe6-\\xff]->0]" ++
        "\n3: [Rule(1)->8]" ++
        "\n4: [Rule(2)->9]" ++
        "\n5: [[\\0-g]->0, 'h'->1, [i-\\x92]->0, '\\x93'->6, [\\x94-\\xe4]->0, '\\xe5'->5, [\\xe6-\\xff]->0]" ++
        "\n6: [[\\0-g]->0, 'h'->1, [i-\\x87]->0, '\\x88'->7, [\\x89-\\xe4]->0, '\\xe5'->5, [\\xe6-\\xff]->0]" ++
        "\n7: [Rule(3)->10]" ++
        "\n8: []" ++
        "\n9: []" ++
        "\n10: []" ++
        "\n])";
    const actual = try fsm.to_string_repr();
    try std.testing.expectEqualStrings(expected, actual);
}

test "test_tag_dispatch_fsm_builder3" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const td = try tag_dispatch(a, &.{ .{ "hel", "1" }, .{ "hi", "2" }, .{ "哈", "3" } }, true, &.{ "hos", "eos" });
    const fsm_opt = try GrammarFsmBuilder.tag_dispatch(a, &td);
    const fsm = fsm_opt.?;
    const printed = try fsm.to_string_repr();
    try std.testing.expect(std.mem.indexOf(u8, printed, "Rule(1)->0") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "Rule(2)->0") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "Rule(3)->0") != null);
}

test "test_token_tag_dispatch_fsm_builder" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var ttd = TokenTagDispatch.empty();
    try ttd.trigger_rule_pairs.append(a, .{ .token_id = 3, .rule_id = 1 });
    try ttd.trigger_rule_pairs.append(a, .{ .token_id = 5, .rule_id = 2 });
    ttd.loop_after_dispatch = false;
    try ttd.excludes.append(a, 7);
    var fsm = try GrammarFsmBuilder.token_tag_dispatch(a, &ttd);
    const printed = try fsm.to_string_repr();
    try std.testing.expect(std.mem.indexOf(u8, printed, "Token(") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "ExcludeToken(") != null);
}

test "test_byte_string_fsm_builder1" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const data = [_]i32{ 'h', 'e', 'l', 'l', 'o' };
    const expr = GrammarExpr{ .ty = .ByteString, .data = &data };
    var fsm = try GrammarFsmBuilder.byte_string(a, expr);
    const expected = "FSM(num_states=6, start=0, end=[5], edges=[" ++
        "\n0: ['h'->1]" ++
        "\n1: ['e'->2]" ++
        "\n2: ['l'->3]" ++
        "\n3: ['l'->4]" ++
        "\n4: ['o'->5]" ++
        "\n5: []" ++
        "\n])";
    const actual = try fsm.to_string_repr();
    try std.testing.expectEqualStrings(expected, actual);
}

test "test_byte_string_fsm_builder2" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var data: std.ArrayList(i32) = .empty;
    for ("你好") |byte| try data.append(a, byte);
    const expr = GrammarExpr{ .ty = .ByteString, .data = data.items };
    var fsm = try GrammarFsmBuilder.byte_string(a, expr);
    const expected = "FSM(num_states=7, start=0, end=[6], edges=[" ++
        "\n0: ['\\xe4'->1]" ++
        "\n1: ['\\xbd'->2]" ++
        "\n2: ['\\xa0'->3]" ++
        "\n3: ['\\xe5'->4]" ++
        "\n4: ['\\xa5'->5]" ++
        "\n5: ['\\xbd'->6]" ++
        "\n6: []" ++
        "\n])";
    const actual = try fsm.to_string_repr();
    try std.testing.expectEqualStrings(expected, actual);
}

test "test_rule_ref_fsm_builder" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const data = [_]i32{1};
    const expr = GrammarExpr{ .ty = .RuleRef, .data = &data };
    var fsm = try GrammarFsmBuilder.rule_ref(a, expr);
    const expected = "FSM(num_states=2, start=0, end=[1], edges=[" ++
        "\n0: [Rule(1)->1]" ++
        "\n1: []" ++
        "\n])";
    const actual = try fsm.to_string_repr();
    try std.testing.expectEqualStrings(expected, actual);
}

test "test_character_class_fsm_builder1" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const data = [_]i32{ 0, 'a', 'z', 'A', 'Z' };
    const expr = GrammarExpr{ .ty = .CharacterClass, .data = &data };
    var fsm = try GrammarFsmBuilder.character_class(a, expr);
    const expected = "FSM(num_states=2, start=0, end=[1], edges=[" ++
        "\n0: [[a-z]->1, [A-Z]->1]" ++
        "\n1: []" ++
        "\n])";
    const actual = try fsm.to_string_repr();
    try std.testing.expectEqualStrings(expected, actual);
}

test "test_character_class_fsm_builder2" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const data = [_]i32{ 0, 'a', 'z', 'A', 'Z' };
    const expr = GrammarExpr{ .ty = .CharacterClassStar, .data = &data };
    var fsm = try GrammarFsmBuilder.character_class(a, expr);
    const expected = "FSM(num_states=1, start=0, end=[0], edges=[" ++
        "\n0: [[a-z]->0, [A-Z]->0]" ++
        "\n])";
    const actual = try fsm.to_string_repr();
    try std.testing.expectEqualStrings(expected, actual);
}

test "test_character_class_fsm_builder3" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const data = [_]i32{ 1, 'a', 'z', 'A', 'Z' };
    const expr = GrammarExpr{ .ty = .CharacterClass, .data = &data };
    var fsm = try GrammarFsmBuilder.character_class(a, expr);
    const expected = "FSM(num_states=16, start=0, end=[1], edges=[" ++
        "\n0: [[\\0-@]->1, [[-`]->1, [{-\\x7f]->1, [\\xc2-\\xdf]->2, '\\xe0'->3, [\\xe1-\\xef]->5, '\\xf0'->7, '\\xf4'->10, [\\xf1-\\xf3]->13]" ++
        "\n1: []" ++
        "\n2: [[\\x80-\\xbf]->1]" ++
        "\n3: [[\\xa0-\\xbf]->4]" ++
        "\n4: [[\\x80-\\xbf]->1]" ++
        "\n5: [[\\x80-\\xbf]->6]" ++
        "\n6: [[\\x80-\\xbf]->1]" ++
        "\n7: [[\\x90-\\xbf]->8]" ++
        "\n8: [[\\x80-\\xbf]->9]" ++
        "\n9: [[\\x80-\\xbf]->1]" ++
        "\n10: [[\\x80-\\x8f]->11]" ++
        "\n11: [[\\x80-\\xbf]->12]" ++
        "\n12: [[\\x80-\\xbf]->1]" ++
        "\n13: [[\\x80-\\xbf]->14]" ++
        "\n14: [[\\x80-\\xbf]->15]" ++
        "\n15: [[\\x80-\\xbf]->1]" ++
        "\n])";
    const actual = try fsm.to_string_repr();
    try std.testing.expectEqualStrings(expected, actual);
}

test "test_character_class_fsm_builder4" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const data = [_]i32{ 1, 'a', 'z', 'A', 'Z' };
    const expr = GrammarExpr{ .ty = .CharacterClassStar, .data = &data };
    var fsm = try GrammarFsmBuilder.character_class(a, expr);
    const expected = "FSM(num_states=15, start=0, end=[0], edges=[" ++
        "\n0: [[\\0-@]->0, [[-`]->0, [{-\\x7f]->0, [\\xc2-\\xdf]->1, '\\xe0'->2, [\\xe1-\\xef]->4, '\\xf0'->6, '\\xf4'->9, [\\xf1-\\xf3]->12]" ++
        "\n1: [[\\x80-\\xbf]->0]" ++
        "\n2: [[\\xa0-\\xbf]->3]" ++
        "\n3: [[\\x80-\\xbf]->0]" ++
        "\n4: [[\\x80-\\xbf]->5]" ++
        "\n5: [[\\x80-\\xbf]->0]" ++
        "\n6: [[\\x90-\\xbf]->7]" ++
        "\n7: [[\\x80-\\xbf]->8]" ++
        "\n8: [[\\x80-\\xbf]->0]" ++
        "\n9: [[\\x80-\\x8f]->10]" ++
        "\n10: [[\\x80-\\xbf]->11]" ++
        "\n11: [[\\x80-\\xbf]->0]" ++
        "\n12: [[\\x80-\\xbf]->13]" ++
        "\n13: [[\\x80-\\xbf]->14]" ++
        "\n14: [[\\x80-\\xbf]->0]" ++
        "\n])";
    const actual = try fsm.to_string_repr();
    try std.testing.expectEqualStrings(expected, actual);
}

test "test_sequence_fsm_builder" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var diag: @import("../parser/ebnf_error.zig").EbnfErrorInfo = undefined;
    const grammar = try functor_mod.grammar_normalizer_mod.from_ebnf(
        a,
        "root ::= rule1 rule2 rule3\n" ++
            "rule1 ::= \"a\" [a-z]* rule3\n" ++
            "rule2 ::= \"c\" [A-Z] rule3\n" ++
            "rule3 ::= \"a\" rule3\n",
        "root",
        &diag,
    );

    const root = try GrammarFsmBuilder.choices(a, grammar.expr(grammar.root_rule().body_expr_id), grammar);
    try std.testing.expectEqualStrings(
        "FSM(num_states=4, start=2, end=[3], edges=[" ++
            "\n0: [Rule(2)->1]" ++
            "\n1: [Rule(3)->3]" ++
            "\n2: [Rule(1)->0]" ++
            "\n3: []" ++
            "\n])",
        try root.to_string_repr(),
    );

    const rule1 = try GrammarFsmBuilder.choices(a, grammar.expr(grammar.rule(1).body_expr_id), grammar);
    try std.testing.expectEqualStrings(
        "FSM(num_states=3, start=1, end=[2], edges=[" ++
            "\n0: [Rule(3)->2, [a-z]->0]" ++
            "\n1: ['a'->0]" ++
            "\n2: []" ++
            "\n])",
        try rule1.to_string_repr(),
    );

    const rule2 = try GrammarFsmBuilder.choices(a, grammar.expr(grammar.rule(2).body_expr_id), grammar);
    try std.testing.expectEqualStrings(
        "FSM(num_states=4, start=2, end=[3], edges=[" ++
            "\n0: [[A-Z]->1]" ++
            "\n1: [Rule(3)->3]" ++
            "\n2: ['c'->0]" ++
            "\n3: []" ++
            "\n])",
        try rule2.to_string_repr(),
    );

    const rule3 = try GrammarFsmBuilder.choices(a, grammar.expr(grammar.rule(3).body_expr_id), grammar);
    try std.testing.expectEqualStrings(
        "FSM(num_states=3, start=1, end=[2], edges=[" ++
            "\n0: [Rule(3)->2]" ++
            "\n1: ['a'->0]" ++
            "\n2: []" ++
            "\n])",
        try rule3.to_string_repr(),
    );
}

test "test_choices_fsm_builder" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var diag: @import("../parser/ebnf_error.zig").EbnfErrorInfo = undefined;
    const grammar = try functor_mod.grammar_normalizer_mod.from_ebnf(
        a,
        "root ::= rule1 | rule2\n" ++
            "rule1 ::= \"\" | \"hello\" rule2\n" ++
            "rule2 ::= [a-z]* \"A\" | \"B\" rule2\n",
        "root",
        &diag,
    );

    const root = try GrammarFsmBuilder.choices(a, grammar.expr(grammar.root_rule().body_expr_id), grammar);
    try std.testing.expectEqualStrings(
        "FSM(num_states=3, start=0, end=[1, 2], edges=[" ++
            "\n0: [Rule(1)->1, Rule(2)->2]" ++
            "\n1: []" ++
            "\n2: []" ++
            "\n])",
        try root.to_string_repr(),
    );

    const rule1 = try GrammarFsmBuilder.choices(a, grammar.expr(grammar.rule(1).body_expr_id), grammar);
    try std.testing.expectEqualStrings(
        "FSM(num_states=7, start=0, end=[0, 6], edges=[" ++
            "\n0: ['h'->2]" ++
            "\n1: [Rule(2)->6]" ++
            "\n2: ['e'->3]" ++
            "\n3: ['l'->4]" ++
            "\n4: ['l'->5]" ++
            "\n5: ['o'->1]" ++
            "\n6: []" ++
            "\n])",
        try rule1.to_string_repr(),
    );

    const rule2 = try GrammarFsmBuilder.choices(a, grammar.expr(grammar.rule(2).body_expr_id), grammar);
    try std.testing.expectEqualStrings(
        "FSM(num_states=4, start=1, end=[0], edges=[" ++
            "\n0: []" ++
            "\n1: [Eps->2, 'B'->3]" ++
            "\n2: ['A'->0, [a-z]->2]" ++
            "\n3: [Rule(2)->0]" ++
            "\n])",
        try rule2.to_string_repr(),
    );
}

test "test_regex_build_with_forbidden_chars" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // \S matches any non-whitespace byte. With the JSON forbidden characters removed, the
    // quote and the backslash must be rejected while other printable characters stay.
    const forbidden = GrammarFsmBuilder.json_string_forbidden_chars();
    const T = struct {
        fn buildForbidden(al: A, regex: []const u8) !FsmWithStartEnd {
            return RegexFsmBuilder.build_with_forbidden_chars(al, regex, GrammarFsmBuilder.json_string_forbidden_chars(), null, "", null);
        }
    };
    _ = forbidden;
    var m1 = try T.buildForbidden(a, "\\S+");
    try std.testing.expect(try m1.accept_string("abc"));
    try std.testing.expect(try m1.accept_string("a!~z"));
    try std.testing.expect(!try m1.accept_string("a\"b"));
    try std.testing.expect(!try m1.accept_string("a\\b"));
    try std.testing.expect(!try m1.accept_string("a b"));

    // A positive class spanning the quote and the backslash is split around them.
    var m2 = try T.buildForbidden(a, "[ -~]+");
    try std.testing.expect(try m2.accept_string("A z!"));
    try std.testing.expect(!try m2.accept_string("\""));
    try std.testing.expect(!try m2.accept_string("\\"));

    // . matches any byte; the control characters must be rejected as well.
    var m3 = try T.buildForbidden(a, ".");
    try std.testing.expect(try m3.accept_string("a"));
    try std.testing.expect(!try m3.accept_string("\t"));
    try std.testing.expect(!try m3.accept_string("\n"));
    try std.testing.expect(!try m3.accept_string("\""));

    // Epsilon transitions are preserved: the pattern still accepts the empty string.
    var m4 = try T.buildForbidden(a, "(ab)*");
    try std.testing.expect(try m4.accept_string(""));
    try std.testing.expect(try m4.accept_string("abab"));
    try std.testing.expect(!try m4.accept_string("a"));

    // A pattern that requires a forbidden character becomes the empty language.
    var m5 = try T.buildForbidden(a, "a\"b");
    try std.testing.expect(!try m5.accept_string("a\"b"));
    try std.testing.expect(!try m5.accept_string("ab"));
    try std.testing.expect(!try m5.accept_string(""));

    // Multi-byte UTF-8 characters (bytes >= 0x80) are not affected by the JSON exclusion.
    var m6 = try T.buildForbidden(a, ".+");
    try std.testing.expect(try m6.accept_string("你好"));
}

test "test_regex_build_with_forbidden_chars_preserves_repeat_aux_data" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var builder = try grammar_mod.GrammarBuilder.new(a);

    var m = try RegexFsmBuilder.build_with_forbidden_chars(a, "[^\n\r]{1,129}", GrammarFsmBuilder.json_string_forbidden_chars(), &builder, "", null);
    const fsm = m.get_fsm();
    const aux_data = fsm.edge_aux_data_slice();
    try std.testing.expect(aux_data.len != 0);

    var found_repeat_edge = false;
    for (0..@intCast(fsm.num_states())) |state| {
        for (fsm.state_edges(@intCast(state))) |edge| {
            if (!edge.is_repeat_ref()) continue;
            found_repeat_edge = true;
            try std.testing.expect(edge.aux_index() >= 0);
            try std.testing.expect(edge.aux_index() + 2 < @as(i32, @intCast(aux_data.len)));

            const repeat_info = fsm.repeat_edge_info(edge.aux_index());
            try std.testing.expectEqual(@as(i32, 1), repeat_info.lower());
            try std.testing.expectEqual(@as(i32, 129), repeat_info.upper());
        }
    }
    try std.testing.expect(found_repeat_edge);
}

test "test_grammar_fsm_builder_regex" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // The compiled regex automaton must preserve the language after simplification.
    var m1 = try GrammarFsmBuilder.regex(a, "(ab)+", false, null);
    try std.testing.expect(!try m1.accept_string(""));
    try std.testing.expect(!try m1.accept_string("a"));
    try std.testing.expect(try m1.accept_string("ab"));
    try std.testing.expect(try m1.accept_string("abab"));

    var m2 = try GrammarFsmBuilder.regex(a, "[0-9]{5}$", false, null);
    try std.testing.expect(try m2.accept_string("12345"));
    try std.testing.expect(!try m2.accept_string("1234"));
    try std.testing.expect(!try m2.accept_string("123456"));

    // json_string excludes the JSON forbidden characters.
    var m3 = try GrammarFsmBuilder.regex(a, "\\S+", true, null);
    try std.testing.expect(try m3.accept_string("abc"));
    try std.testing.expect(!try m3.accept_string("a\"b"));
    try std.testing.expect(!try m3.accept_string("a\\b"));

    // Without the flag, the quote is accepted.
    var m4 = try GrammarFsmBuilder.regex(a, "\\S+", false, null);
    try std.testing.expect(try m4.accept_string("a\"b"));

    // Invalid patterns report an error.
    try std.testing.expectError(error.RegexParse, GrammarFsmBuilder.regex(a, "+a", false, null));
}
