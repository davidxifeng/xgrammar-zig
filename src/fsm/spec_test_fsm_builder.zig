//! Port of `external/xgrammar/tests/cpp/test_fsm_builder.cc` (spec tests).
//!
//! Covers `TrieFsmBuilder`, `RegexFsmBuilder`, and `GrammarFsmBuilder`
//! (tag-dispatch, token-tag-dispatch, byte-string, rule-ref, character-class,
//! sequence, choices, and `buildWithForbiddenChars` / `jsonStringForbiddenChars`).

const std = @import("std");
const Diagnostic = @import("../Diagnostic.zig").Diagnostic;
const fsm_mod = @import("../fsm.zig");
const functor_mod = @import("../functor.zig");
const grammar_mod = @import("../grammar.zig");

const GrammarFsmBuilder = functor_mod.GrammarFsmBuilder;
const GrammarBuilder = grammar_mod.GrammarBuilder;
const GrammarExpr = grammar_mod.GrammarExpr;
const TagDispatch = grammar_mod.TagDispatch;
const TokenTagDispatch = grammar_mod.TokenTagDispatch;
const CompactFsm = fsm_mod.CompactFsm;
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

fn buildErr(a: A, regex: []const u8) ![]u8 {
    var diag: Diagnostic = .{};
    defer diag.deinit(a);
    if (RegexFsmBuilder.build(a, regex, null, "", &diag)) |built| {
        var mut = built;
        mut.deinit();
        return error.TestUnexpectedResult;
    } else |_| {
        return diag.formatAlloc(a);
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
    var compact = try CompactFsm.fromFsm(a, fsm.getFsm());
    defer compact.deinit();

    try std.testing.expectEqual(@as(i32, 0), fsm.startState());

    const next = struct {
        fn f(fsm_wse: *const FsmWithStartEnd, state: i32, c: u8) i32 {
            return fsm_wse.getFsm().nextState(state, c, .CharRange);
        }
    }.f;

    // "hello".
    try std.testing.expectEqual(@as(i32, 1), next(&fsm, fsm.startState(), 'h'));
    try std.testing.expectEqual(@as(i32, 2), next(&fsm, 1, 'e'));
    try std.testing.expectEqual(@as(i32, 3), next(&fsm, 2, 'l'));
    try std.testing.expectEqual(@as(i32, 4), next(&fsm, 3, 'l'));
    try std.testing.expectEqual(@as(i32, 5), next(&fsm, 4, 'o'));
    try std.testing.expect(fsm.isEndState(5));

    // "hil" (prefix of "hili", not itself a pattern).
    try std.testing.expectEqual(@as(i32, 1), next(&fsm, fsm.startState(), 'h'));
    try std.testing.expectEqual(@as(i32, 6), next(&fsm, 1, 'i'));
    try std.testing.expectEqual(@as(i32, 13), next(&fsm, 6, 'l'));
    try std.testing.expect(!fsm.isEndState(13));

    // Walk failure: "goe" has no transition after "go".
    try std.testing.expectEqual(@as(i32, 15), next(&fsm, fsm.startState(), 'g'));
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
        const fsm = fsm_wse.getFsm();
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
                var state = fsm_wse.startState();
                for (input) |byte| {
                    state = fsm.nextState(state, byte, .CharRange);
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

    var m1 = try build(a, "a{0}");
    defer m1.deinit();
    try std.testing.expect(try m1.acceptString(""));
    try std.testing.expect(!try m1.acceptString("a"));

    var m2 = try build(a, "a{0,0}");
    defer m2.deinit();
    try std.testing.expect(try m2.acceptString(""));
    try std.testing.expect(!try m2.acceptString("a"));

    var m3 = try build(a, "(ab){0}");
    defer m3.deinit();
    try std.testing.expect(try m3.acceptString(""));
    try std.testing.expect(!try m3.acceptString("ab"));

    var m4 = try build(a, "ba{0}c");
    defer m4.deinit();
    try std.testing.expect(try m4.acceptString("bc"));
    try std.testing.expect(!try m4.acceptString("bac"));

    var m5 = try build(a, "ba{0}c");
    defer m5.deinit();
    var s5 = try m5.simplifyEpsilon(a);
    defer s5.deinit();
    var merged5 = try s5.mergeEquivalentStates(a);
    defer merged5.deinit();
    try std.testing.expect(try merged5.acceptString("bc"));
    try std.testing.expect(!try merged5.acceptString("bac"));

    try std.testing.expectError(error.RegexParse, build(a, "a{3,1}"));
    try std.testing.expectError(error.RegexParse, build(a, "a{1,0}"));
}

test "test_regex_case_insensitive_flag" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();

    var m1 = try build(a, "(?i)abc");
    defer m1.deinit();
    try std.testing.expect(try m1.acceptString("abc"));
    try std.testing.expect(try m1.acceptString("ABC"));
    try std.testing.expect(try m1.acceptString("aBc"));
    try std.testing.expect(!try m1.acceptString("abd"));

    var m2 = try build(a, "(?i)(ab|cd)+");
    defer m2.deinit();
    try std.testing.expect(try m2.acceptString("aBcD"));
    try std.testing.expect(!try m2.acceptString("ac"));

    var m3 = try build(a, "(?i)[a-dx]");
    defer m3.deinit();
    try std.testing.expect(try m3.acceptString("b"));
    try std.testing.expect(try m3.acceptString("B"));
    try std.testing.expect(try m3.acceptString("X"));
    try std.testing.expect(!try m3.acceptString("e"));
    try std.testing.expect(!try m3.acceptString("E"));

    var m4 = try build(a, "(?i)[^k]");
    defer m4.deinit();
    try std.testing.expect(try m4.acceptString("a"));
    try std.testing.expect(!try m4.acceptString("k"));
    try std.testing.expect(!try m4.acceptString("K"));

    var m5 = try build(a, "(?i)Σ");
    defer m5.deinit();
    try std.testing.expect(try m5.acceptString("Σ"));
    try std.testing.expect(!try m5.acceptString("σ"));

    var m6 = try build(a, "abc");
    defer m6.deinit();
    try std.testing.expect(!try m6.acceptString("ABC"));
}

test "test_regex_escapes" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();

    var m1 = try build(a, "\\x41B\\u{43}");
    defer m1.deinit();
    try std.testing.expect(try m1.acceptString("ABC"));

    var m2 = try build(a, "\\u{1F600}");
    defer m2.deinit();
    try std.testing.expect(try m2.acceptString("😀"));
    try std.testing.expect(!try m2.acceptString("😁"));

    var m3 = try build(a, "[A-C]+");
    defer m3.deinit();
    try std.testing.expect(try m3.acceptString("ABC"));
    try std.testing.expect(!try m3.acceptString("D"));

    var m4 = try build(a, "好*");
    defer m4.deinit();
    try std.testing.expect(try m4.acceptString(""));
    try std.testing.expect(try m4.acceptString("好好"));
    try std.testing.expect(!try m4.acceptString("\xbd"));

    var m5 = try build(a, "\\s+");
    defer m5.deinit();
    try std.testing.expect(try m5.acceptString(" \t\n\r\x0c\x0b"));
    try std.testing.expect(!try m5.acceptString("\x00"));
    try std.testing.expect(!try m5.acceptString("\x01"));

    var m6 = try build(a, "\\S");
    defer m6.deinit();
    try std.testing.expect(try m6.acceptString("好"));
    try std.testing.expect(try m6.acceptString("\x00"));
    try std.testing.expect(!try m6.acceptString(" "));
}

test "test_regex_unsupported_features" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();

    try std.testing.expectError(error.RegexParse, build(a, "a\\b"));
    try std.testing.expectError(error.RegexParse, build(a, "a\\B"));
    try std.testing.expectError(error.RegexParse, build(a, "\\p{L}"));
    try std.testing.expectError(error.RegexParse, build(a, "(a)\\1"));
    try std.testing.expectError(error.RegexParse, build(a, "(?<name>a)\\k<name>"));
    try std.testing.expectError(error.RegexParse, build(a, "(?<=a)b"));
    try std.testing.expectError(error.RegexParse, build(a, "[]"));
    try std.testing.expectError(error.RegexParse, build(a, "[^]"));

    var m1 = try build(a, "a(?=b)c");
    defer m1.deinit();
    try std.testing.expect(try m1.acceptString("ac"));
    var m2 = try build(a, "a(?!b)c");
    defer m2.deinit();
    try std.testing.expect(try m2.acceptString("ac"));

    var m3 = try build(a, "(?<name>ab)+");
    defer m3.deinit();
    try std.testing.expect(try m3.acceptString("abab"));
    var m4 = try build(a, "(?P<name>ab)c");
    defer m4.deinit();
    try std.testing.expect(try m4.acceptString("abc"));

    var m5 = try build(a, "a^b$c");
    defer m5.deinit();
    try std.testing.expect(try m5.acceptString("abc"));

    var m6 = try build(a, "a*?b+?c??(de){1,2}?");
    defer m6.deinit();
    try std.testing.expect(try m6.acceptString("aabbcde"));
    try std.testing.expect(try m6.acceptString("bdede"));

    var m7 = try build(a, "(a|)b");
    defer m7.deinit();
    try std.testing.expect(try m7.acceptString("ab"));
    try std.testing.expect(try m7.acceptString("b"));
    var m8 = try build(a, "a|");
    defer m8.deinit();
    try std.testing.expect(try m8.acceptString("a"));
    try std.testing.expect(try m8.acceptString(""));
}

test "test_regex_error_messages" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();

    try std.testing.expectEqualStrings(
        "Regex parsing error at position 1: There is nothing to repeat before '+'",
        try buildErr(a, "+a"),
    );
    try std.testing.expectEqualStrings(
        "Regex parsing error at position 3: Unmatched ')'",
        try buildErr(a, "ab)"),
    );
    try std.testing.expectEqualStrings(
        "Regex parsing error at position 2: Unmatched ']'",
        try buildErr(a, "a]"),
    );
    try std.testing.expectEqualStrings(
        "Regex parsing error at position 2: The parenthesis is not closed",
        try buildErr(a, "a(bc"),
    );
    try std.testing.expectEqualStrings(
        "Regex parsing error at position 2: Unclosed '['",
        try buildErr(a, "a[bc"),
    );
    try std.testing.expectEqualStrings(
        "Regex parsing error at position 2: Empty character class is not allowed in regex",
        try buildErr(a, "a[]"),
    );
    try std.testing.expectEqualStrings(
        "Regex parsing error at position 2: Invalid repetition count: expected a number after '{'",
        try buildErr(a, "a{,2}"),
    );
    try std.testing.expectEqualStrings(
        "Regex parsing error at position 2: Invalid repetition count: the lower bound 3 is larger than the upper bound 1",
        try buildErr(a, "a{3,1}"),
    );
    try std.testing.expectEqualStrings(
        "Regex parsing error at position 2: Invalid repetition count: the count 9999999999 is too large",
        try buildErr(a, "a{1,9999999999}"),
    );
    try std.testing.expectEqualStrings(
        "Regex parsing error at position 2: Word boundary assertion \\b is not supported in regex",
        try buildErr(a, "a\\b"),
    );
    try std.testing.expectEqualStrings(
        "Regex parsing error at position 1: Invalid named capturing group",
        try buildErr(a, "(?<name)a"),
    );
    try std.testing.expectEqualStrings(
        "Regex parsing error at position 5: There is nothing to repeat before '+'",
        try buildErr(a, "(?i)+a"),
    );
}

test "test_regex_matches_empty" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const matches_empty = struct {
        fn f(al: A, regex: []const u8) !bool {
            var diag: Diagnostic = .{};
            defer diag.deinit(al);
            return RegexFsmBuilder.matchesEmpty(al, regex, &diag);
        }
    };
    try std.testing.expect(try matches_empty.f(a, "a*"));
    try std.testing.expect(try matches_empty.f(a, "(a|)"));
    try std.testing.expect(try matches_empty.f(a, "a{0,10}"));
    try std.testing.expect(try matches_empty.f(a, "(ab)?"));
    try std.testing.expect(!try matches_empty.f(a, "a+"));
    try std.testing.expect(!try matches_empty.f(a, "a{1,10}"));
    try std.testing.expect(!try matches_empty.f(a, "ab|cd"));
    try std.testing.expect(!try matches_empty.f(a, "(abc){2,1000000}"));
    try std.testing.expect(try matches_empty.f(a, "(abc){0,1000000}"));
    try std.testing.expect(try matches_empty.f(a, "(?i)A*"));
    var diag: Diagnostic = .{};
    defer diag.deinit(a);
    try std.testing.expectError(error.RegexParse, RegexFsmBuilder.matchesEmpty(a, "\\b", &diag));
}

test "test_regex_large_repeat_without_builder" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();

    var m1 = try build(a, "a{2,300}");
    defer m1.deinit();
    try std.testing.expect(!try m1.acceptString("a"));
    try std.testing.expect(try m1.acceptString("aa"));
    const a300 = try a.alloc(u8, 300);
    @memset(a300, 'a');
    const a301 = try a.alloc(u8, 301);
    @memset(a301, 'a');
    try std.testing.expect(try m1.acceptString(a300));
    try std.testing.expect(!try m1.acceptString(a301));

    try std.testing.expectError(error.RepeatTooLarge, build(a, "(abcdefghij){1,100000}"));
}

// ---------------------------------------------------------------------------
// GrammarFsmBuilder tests
// ---------------------------------------------------------------------------

fn tagDispatch(a: A, pairs: []const [2][]const u8, loop_after: bool, excludes: []const []const u8) !TagDispatch {
    var td: TagDispatch = .empty;
    errdefer td.deinit(a);
    for (pairs) |pair| {
        try td.tag_rule_pairs.append(a, .{
            .tag = try a.dupe(u8, pair[0]),
            .rule_id = try std.fmt.parseInt(i32, pair[1], 10),
        });
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
    var td = try tagDispatch(a, &.{ .{ "hel", "1" }, .{ "hi", "2" }, .{ "哈", "3" } }, true, &.{});
    defer td.deinit(a);
    var fsm = (try GrammarFsmBuilder.tagDispatch(a, &td)).?;
    defer fsm.deinit();
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
    const actual = try fsm.toStringRepr(a);
    try std.testing.expectEqualStrings(expected, actual);
}

test "test_tag_dispatch_fsm_builder2" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var td = try tagDispatch(a, &.{ .{ "hel", "1" }, .{ "hi", "2" }, .{ "哈", "3" } }, false, &.{});
    defer td.deinit(a);
    var fsm = (try GrammarFsmBuilder.tagDispatch(a, &td)).?;
    defer fsm.deinit();
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
    const actual = try fsm.toStringRepr(a);
    try std.testing.expectEqualStrings(expected, actual);
}

test "test_tag_dispatch_fsm_builder3" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var td = try tagDispatch(a, &.{ .{ "hel", "1" }, .{ "hi", "2" }, .{ "哈", "3" } }, true, &.{ "hos", "eos" });
    defer td.deinit(a);
    var fsm = (try GrammarFsmBuilder.tagDispatch(a, &td)).?;
    defer fsm.deinit();
    const printed = try fsm.toStringRepr(a);
    try std.testing.expect(std.mem.indexOf(u8, printed, "Rule(1)->0") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "Rule(2)->0") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "Rule(3)->0") != null);
}

test "test_token_tag_dispatch_fsm_builder" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var ttd: TokenTagDispatch = .empty;
    defer ttd.deinit(a);
    try ttd.trigger_rule_pairs.append(a, .{ .token_id = 3, .rule_id = 1 });
    try ttd.trigger_rule_pairs.append(a, .{ .token_id = 5, .rule_id = 2 });
    ttd.loop_after_dispatch = false;
    try ttd.excludes.append(a, 7);
    var fsm = try GrammarFsmBuilder.tokenTagDispatch(a, &ttd);
    defer fsm.deinit();
    const printed = try fsm.toStringRepr(a);
    try std.testing.expect(std.mem.indexOf(u8, printed, "Token(") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "ExcludeToken(") != null);
}

test "test_byte_string_fsm_builder1" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const data = [_]i32{ 'h', 'e', 'l', 'l', 'o' };
    const expr = GrammarExpr{ .ty = .ByteString, .data = &data };
    var fsm = try GrammarFsmBuilder.byteString(a, expr);
    defer fsm.deinit();
    const expected = "FSM(num_states=6, start=0, end=[5], edges=[" ++
        "\n0: ['h'->1]" ++
        "\n1: ['e'->2]" ++
        "\n2: ['l'->3]" ++
        "\n3: ['l'->4]" ++
        "\n4: ['o'->5]" ++
        "\n5: []" ++
        "\n])";
    const actual = try fsm.toStringRepr(a);
    try std.testing.expectEqualStrings(expected, actual);
}

test "test_byte_string_fsm_builder2" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var data: std.ArrayList(i32) = .empty;
    for ("你好") |byte| try data.append(a, byte);
    const expr = GrammarExpr{ .ty = .ByteString, .data = data.items };
    var fsm = try GrammarFsmBuilder.byteString(a, expr);
    defer fsm.deinit();
    const expected = "FSM(num_states=7, start=0, end=[6], edges=[" ++
        "\n0: ['\\xe4'->1]" ++
        "\n1: ['\\xbd'->2]" ++
        "\n2: ['\\xa0'->3]" ++
        "\n3: ['\\xe5'->4]" ++
        "\n4: ['\\xa5'->5]" ++
        "\n5: ['\\xbd'->6]" ++
        "\n6: []" ++
        "\n])";
    const actual = try fsm.toStringRepr(a);
    try std.testing.expectEqualStrings(expected, actual);
}

test "test_rule_ref_fsm_builder" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const data = [_]i32{1};
    const expr = GrammarExpr{ .ty = .RuleRef, .data = &data };
    var fsm = try GrammarFsmBuilder.ruleRef(a, expr);
    defer fsm.deinit();
    const expected = "FSM(num_states=2, start=0, end=[1], edges=[" ++
        "\n0: [Rule(1)->1]" ++
        "\n1: []" ++
        "\n])";
    const actual = try fsm.toStringRepr(a);
    try std.testing.expectEqualStrings(expected, actual);
}

test "test_character_class_fsm_builder1" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const data = [_]i32{ 0, 'a', 'z', 'A', 'Z' };
    const expr = GrammarExpr{ .ty = .CharacterClass, .data = &data };
    var fsm = try GrammarFsmBuilder.characterClass(a, expr);
    defer fsm.deinit();
    const expected = "FSM(num_states=2, start=0, end=[1], edges=[" ++
        "\n0: [[a-z]->1, [A-Z]->1]" ++
        "\n1: []" ++
        "\n])";
    const actual = try fsm.toStringRepr(a);
    try std.testing.expectEqualStrings(expected, actual);
}

test "test_character_class_fsm_builder2" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const data = [_]i32{ 0, 'a', 'z', 'A', 'Z' };
    const expr = GrammarExpr{ .ty = .CharacterClassStar, .data = &data };
    var fsm = try GrammarFsmBuilder.characterClass(a, expr);
    defer fsm.deinit();
    const expected = "FSM(num_states=1, start=0, end=[0], edges=[" ++
        "\n0: [[a-z]->0, [A-Z]->0]" ++
        "\n])";
    const actual = try fsm.toStringRepr(a);
    try std.testing.expectEqualStrings(expected, actual);
}

test "test_character_class_fsm_builder3" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const data = [_]i32{ 1, 'a', 'z', 'A', 'Z' };
    const expr = GrammarExpr{ .ty = .CharacterClass, .data = &data };
    var fsm = try GrammarFsmBuilder.characterClass(a, expr);
    defer fsm.deinit();
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
    const actual = try fsm.toStringRepr(a);
    try std.testing.expectEqualStrings(expected, actual);
}

test "test_character_class_fsm_builder4" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const data = [_]i32{ 1, 'a', 'z', 'A', 'Z' };
    const expr = GrammarExpr{ .ty = .CharacterClassStar, .data = &data };
    var fsm = try GrammarFsmBuilder.characterClass(a, expr);
    defer fsm.deinit();
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
    const actual = try fsm.toStringRepr(a);
    try std.testing.expectEqualStrings(expected, actual);
}

test "test_sequence_fsm_builder" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var diag: Diagnostic = .{};
    defer diag.deinit(a);
    var grammar = try functor_mod.fromEbnf(
        a,
        "root ::= rule1 rule2 rule3\n" ++
            "rule1 ::= \"a\" [a-z]* rule3\n" ++
            "rule2 ::= \"c\" [A-Z] rule3\n" ++
            "rule3 ::= \"a\" rule3\n",
        "root",
        &diag,
    );
    defer grammar.deinit();

    var root = try GrammarFsmBuilder.choices(a, grammar.expr(grammar.rootRule().body_expr_id), &grammar);
    defer root.deinit();
    try std.testing.expectEqualStrings(
        "FSM(num_states=4, start=2, end=[3], edges=[" ++
            "\n0: [Rule(2)->1]" ++
            "\n1: [Rule(3)->3]" ++
            "\n2: [Rule(1)->0]" ++
            "\n3: []" ++
            "\n])",
        try root.toStringRepr(a),
    );

    var rule1 = try GrammarFsmBuilder.choices(a, grammar.expr(grammar.rule(1).body_expr_id), &grammar);
    defer rule1.deinit();
    try std.testing.expectEqualStrings(
        "FSM(num_states=3, start=1, end=[2], edges=[" ++
            "\n0: [Rule(3)->2, [a-z]->0]" ++
            "\n1: ['a'->0]" ++
            "\n2: []" ++
            "\n])",
        try rule1.toStringRepr(a),
    );

    var rule2 = try GrammarFsmBuilder.choices(a, grammar.expr(grammar.rule(2).body_expr_id), &grammar);
    defer rule2.deinit();
    try std.testing.expectEqualStrings(
        "FSM(num_states=4, start=2, end=[3], edges=[" ++
            "\n0: [[A-Z]->1]" ++
            "\n1: [Rule(3)->3]" ++
            "\n2: ['c'->0]" ++
            "\n3: []" ++
            "\n])",
        try rule2.toStringRepr(a),
    );

    var rule3 = try GrammarFsmBuilder.choices(a, grammar.expr(grammar.rule(3).body_expr_id), &grammar);
    defer rule3.deinit();
    try std.testing.expectEqualStrings(
        "FSM(num_states=3, start=1, end=[2], edges=[" ++
            "\n0: [Rule(3)->2]" ++
            "\n1: ['a'->0]" ++
            "\n2: []" ++
            "\n])",
        try rule3.toStringRepr(a),
    );
}

test "test_choices_fsm_builder" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var diag: Diagnostic = .{};
    defer diag.deinit(a);
    var grammar = try functor_mod.fromEbnf(
        a,
        "root ::= rule1 | rule2\n" ++
            "rule1 ::= \"\" | \"hello\" rule2\n" ++
            "rule2 ::= [a-z]* \"A\" | \"B\" rule2\n",
        "root",
        &diag,
    );
    defer grammar.deinit();

    var root = try GrammarFsmBuilder.choices(a, grammar.expr(grammar.rootRule().body_expr_id), &grammar);
    defer root.deinit();
    try std.testing.expectEqualStrings(
        "FSM(num_states=3, start=0, end=[1, 2], edges=[" ++
            "\n0: [Rule(1)->1, Rule(2)->2]" ++
            "\n1: []" ++
            "\n2: []" ++
            "\n])",
        try root.toStringRepr(a),
    );

    var rule1 = try GrammarFsmBuilder.choices(a, grammar.expr(grammar.rule(1).body_expr_id), &grammar);
    defer rule1.deinit();
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
        try rule1.toStringRepr(a),
    );

    var rule2 = try GrammarFsmBuilder.choices(a, grammar.expr(grammar.rule(2).body_expr_id), &grammar);
    defer rule2.deinit();
    try std.testing.expectEqualStrings(
        "FSM(num_states=4, start=1, end=[0], edges=[" ++
            "\n0: []" ++
            "\n1: [Eps->2, 'B'->3]" ++
            "\n2: ['A'->0, [a-z]->2]" ++
            "\n3: [Rule(2)->0]" ++
            "\n])",
        try rule2.toStringRepr(a),
    );
}

test "test_regex_build_with_forbidden_chars" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const T = struct {
        fn buildForbidden(al: A, regex: []const u8) !FsmWithStartEnd {
            return RegexFsmBuilder.buildWithForbiddenChars(al, regex, GrammarFsmBuilder.jsonStringForbiddenChars(), null, "", null);
        }
    };

    var m1 = try T.buildForbidden(a, "\\S+");
    defer m1.deinit();
    try std.testing.expect(try m1.acceptString("abc"));
    try std.testing.expect(try m1.acceptString("a!~z"));
    try std.testing.expect(!try m1.acceptString("a\"b"));
    try std.testing.expect(!try m1.acceptString("a\\b"));
    try std.testing.expect(!try m1.acceptString("a b"));

    var m2 = try T.buildForbidden(a, "[ -~]+");
    defer m2.deinit();
    try std.testing.expect(try m2.acceptString("A z!"));
    try std.testing.expect(!try m2.acceptString("\""));
    try std.testing.expect(!try m2.acceptString("\\"));

    var m3 = try T.buildForbidden(a, ".");
    defer m3.deinit();
    try std.testing.expect(try m3.acceptString("a"));
    try std.testing.expect(!try m3.acceptString("\t"));
    try std.testing.expect(!try m3.acceptString("\n"));
    try std.testing.expect(!try m3.acceptString("\""));

    var m4 = try T.buildForbidden(a, "(ab)*");
    defer m4.deinit();
    try std.testing.expect(try m4.acceptString(""));
    try std.testing.expect(try m4.acceptString("abab"));
    try std.testing.expect(!try m4.acceptString("a"));

    var m5 = try T.buildForbidden(a, "a\"b");
    defer m5.deinit();
    try std.testing.expect(!try m5.acceptString("a\"b"));
    try std.testing.expect(!try m5.acceptString("ab"));
    try std.testing.expect(!try m5.acceptString(""));

    var m6 = try T.buildForbidden(a, ".+");
    defer m6.deinit();
    try std.testing.expect(try m6.acceptString("你好"));
}

test "test_regex_build_with_forbidden_chars_preserves_repeat_aux_data" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var builder = try GrammarBuilder.init(a);
    defer builder.deinit();

    var m = try RegexFsmBuilder.buildWithForbiddenChars(a, "[^\n\r]{1,129}", GrammarFsmBuilder.jsonStringForbiddenChars(), &builder, "", null);
    defer m.deinit();
    const fsm = m.getFsm();
    const aux_data = fsm.edgeAuxDataSlice();
    try std.testing.expect(aux_data.len != 0);

    var found_repeat_edge = false;
    for (0..@intCast(fsm.numStates())) |state| {
        for (fsm.stateEdges(@intCast(state))) |edge| {
            if (!edge.isRepeatRef()) continue;
            found_repeat_edge = true;
            try std.testing.expect(edge.auxIndex() >= 0);
            try std.testing.expect(edge.auxIndex() + 2 < @as(i32, @intCast(aux_data.len)));

            const repeat_info = fsm.repeatEdgeInfo(edge.auxIndex());
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

    var m1 = try GrammarFsmBuilder.regex(a, "(ab)+", false, null);
    defer m1.deinit();
    try std.testing.expect(!try m1.acceptString(""));
    try std.testing.expect(!try m1.acceptString("a"));
    try std.testing.expect(try m1.acceptString("ab"));
    try std.testing.expect(try m1.acceptString("abab"));

    var m2 = try GrammarFsmBuilder.regex(a, "[0-9]{5}$", false, null);
    defer m2.deinit();
    try std.testing.expect(try m2.acceptString("12345"));
    try std.testing.expect(!try m2.acceptString("1234"));
    try std.testing.expect(!try m2.acceptString("123456"));

    var m3 = try GrammarFsmBuilder.regex(a, "\\S+", true, null);
    defer m3.deinit();
    try std.testing.expect(try m3.acceptString("abc"));
    try std.testing.expect(!try m3.acceptString("a\"b"));
    try std.testing.expect(!try m3.acceptString("a\\b"));

    var m4 = try GrammarFsmBuilder.regex(a, "\\S+", false, null);
    defer m4.deinit();
    try std.testing.expect(try m4.acceptString("a\"b"));

    try std.testing.expectError(error.RegexParse, GrammarFsmBuilder.regex(a, "+a", false, null));
}
