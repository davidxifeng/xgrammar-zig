//! Port of `external/xgrammar/tests/cpp/test_fsm.cc` (spec tests).
//!
//! Ported from `build` -> `acceptString` acceptance through the full automata pipeline
//! (DFA conversion, minimization, epsilon simplification, state merging, intersection,
//! complement, and the compact representation).

const std = @import("std");
const fsm_mod = @import("../fsm.zig");
const CompactFsm = fsm_mod.CompactFsm;
const CompactFsmWithStartEnd = fsm_mod.CompactFsmWithStartEnd;
const Fsm = fsm_mod.Fsm;
const FsmWithStartEnd = fsm_mod.FsmWithStartEnd;
const RegexFsmBuilder = fsm_mod.RegexFsmBuilder;

const A = std.mem.Allocator;

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

fn state0AcceptsChar(fsm_wse: *const FsmWithStartEnd, c: u8) bool {
    for (fsm_wse.getFsm().stateEdges(0)) |e| {
        if (e.min <= c and e.max >= c) return true;
    }
    return false;
}

fn build(a: A, regex: []const u8) !FsmWithStartEnd {
    return RegexFsmBuilder.build(a, regex, null, "", null);
}

test "basic_build_test" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();

    // Test 1: literal string with an escape.
    var fsm_wse = try build(a, "abcd\\n");
    defer fsm_wse.deinit();
    try std.testing.expect(try fsm_wse.acceptString("abcd\n"));

    // Test 2: a class mixing a leading dash, a range, and an escape.
    var fsm_wse2 = try build(a, "[-a-z\\n]");
    defer fsm_wse2.deinit();
    for ("abcd-\n") |c| {
        try std.testing.expect(state0AcceptsChar(&fsm_wse2, c));
    }

    // Test 3: digit class.
    var fsm_wse3 = try build(a, "[\\d]");
    defer fsm_wse3.deinit();
    for ("1234567890") |c| {
        try std.testing.expect(state0AcceptsChar(&fsm_wse3, c));
    }

    // Test 4: negated digit class.
    var fsm_wse4 = try build(a, "[^\\d]");
    defer fsm_wse4.deinit();
    for ("1234567890") |c| {
        try std.testing.expect(!state0AcceptsChar(&fsm_wse4, c));
    }
    for ("abz") |c| {
        try std.testing.expect(state0AcceptsChar(&fsm_wse4, c));
    }

    // Test 5: multibyte literal.
    var fsm_wse5 = try build(a, "你好a");
    defer fsm_wse5.deinit();
    try std.testing.expect(try fsm_wse5.acceptString("你好a"));

    // Test 6: empty groups accept the empty string.
    var fsm_wse6 = try build(a, "(())()()");
    defer fsm_wse6.deinit();
    try std.testing.expect(try fsm_wse6.acceptString(""));

    // Test 7: a class with duplicates collapses to merged ranges (two: a-d and x-z).
    var fsm_wse7 = try build(a, "[abcdabcdxyzxyz]");
    defer fsm_wse7.deinit();
    try std.testing.expect(try fsm_wse7.acceptString("a"));
    try std.testing.expect(!try fsm_wse7.acceptString("e"));
    try std.testing.expectEqual(@as(usize, 2), fsm_wse7.getFsm().stateEdges(0).len);
}

test "connection_test" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();

    // Test 1: literal, class, and trailing literals concatenated.
    var m1 = try build(a, " [a-zA-Z0-9]--");
    defer m1.deinit();
    try std.testing.expect(try m1.acceptString(" a--"));

    // Test 2: alternation of a literal and a class.
    var m2 = try build(a, "aaa|[\\d]");
    defer m2.deinit();
    try std.testing.expect(try m2.acceptString("aaa"));
    try std.testing.expect(try m2.acceptString("1"));

    // Test 3: nested alternation in groups.
    var m3 = try build(a, "(([\\d]|[\\w])|aaa)");
    defer m3.deinit();
    try std.testing.expect(try m3.acceptString("aaa"));
    try std.testing.expect(try m3.acceptString("1"));
    try std.testing.expect(!try m3.acceptString("1a"));
}

test "symbol_test" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();

    // Test 1: `+` quantifier.
    var m1 = try build(a, "1[\\d]+");
    defer m1.deinit();
    try std.testing.expect(try m1.acceptString("1111"));
    try std.testing.expect(!try m1.acceptString("1"));

    // Test 2: `*` quantifier.
    var m2 = try build(a, "1[1]*");
    defer m2.deinit();
    try std.testing.expect(try m2.acceptString("1111"));
    try std.testing.expect(try m2.acceptString("1"));

    // Test 3: `?` quantifier.
    var m3 = try build(a, "1[\\d]?");
    defer m3.deinit();
    try std.testing.expect(!try m3.acceptString("1111"));
    try std.testing.expect(try m3.acceptString("1"));
    try std.testing.expect(try m3.acceptString("11"));

    // Test 4: quantified literal spaces.
    var m4 = try build(a, " * * + ? *");
    defer m4.deinit();
    try std.testing.expect(try m4.acceptString(" "));
    try std.testing.expect(try m4.acceptString("      "));
}

test "integrated_test" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var m = try build(a, "((naive|bbb|[\\d]+)*[\\w])|  +");
    defer m.deinit();
    for ([_][]const u8{ "naive1", "bbbnaive114514W", "    ", "123", "_" }) |s| {
        try std.testing.expect(try m.acceptString(s));
    }
    for ([_][]const u8{ "naive", "bbbbbb", "naive   ", "123 ", "aaa" }) |s| {
        try std.testing.expect(!try m.acceptString(s));
    }
}

test "test_email" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var m = try build(a, "(\\w+)(\\.\\w+)*@(\\w+)(\\.\\w+)+");
    defer m.deinit();
    for ([_][]const u8{
        "asnjdaj_19032910@google.com.test",
        "12393089340190@a.b.c.d.f.e.org.test",
        "as____________as@abc.me.test",
        "ooooohhhhh@123456.test",
        "ajidoa@a.test",
    }) |email| {
        try std.testing.expect(try m.acceptString(email));
    }
    for ([_][]const u8{ "@google.test", "hello@", "hello@.test", "+++asd@b.test", "hello" }) |email| {
        try std.testing.expect(!try m.acceptString(email));
    }
}

test "test_time" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var m = try build(a, "(\\d{1,2}):(\\d{2})(:(\\d{2}))?");
    defer m.deinit();
    for ([_][]const u8{ "1:34", "23:59", "00:00", "01:02:03", "23:59:59" }) |time| {
        try std.testing.expect(try m.acceptString(time));
    }
    for ([_][]const u8{ "19", "12:6", "12:34:", "12:34:5", "12:34:567", "12:123", "12:", ":34:23", "::" }) |time| {
        try std.testing.expect(!try m.acceptString(time));
    }
}

test "function_test" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();

    // Test 1: compact round-trip.
    var m1 = try build(a, "[\\d\\d\\d]+123");
    defer m1.deinit();
    try std.testing.expect(try m1.acceptString("123456123"));
    var compact = try CompactFsm.fromFsm(a, m1.getFsm());
    defer compact.deinit();
    var compact_wse = try CompactFsmWithStartEnd.init(a, compact.retain(), m1.startState(), m1.endsSlice(), false);
    defer compact_wse.deinit();
    try std.testing.expect(try compact_wse.acceptString(a, "123456123"));
    var roundtrip_ends: std.ArrayList(i32) = .empty;
    try roundtrip_ends.appendSlice(a, m1.endsSlice());
    var roundtrip = FsmWithStartEnd.init(a, try compact.toFsm(a), m1.startState(), roundtrip_ends, false);
    defer roundtrip.deinit();
    try std.testing.expect(try roundtrip.acceptString("123456123"));

    // Test 2: DFA conversion removes epsilons and de-duplicates transitions.
    var m2 = try build(a, "([abc]|[\\d])+");
    defer m2.deinit();
    try std.testing.expect(try m2.acceptString("abc3"));
    var dfa = try m2.toDfa(a);
    defer dfa.deinit();
    try std.testing.expect(try dfa.acceptString("abc3"));
    for (dfa.getFsm().edgesSlice()) |es| {
        for (es.items) |e| try std.testing.expect(!e.isEpsilon());
        var rules = std.AutoHashMap(i32, void).init(a);
        defer rules.deinit();
        var chars = std.AutoHashMap(i32, void).init(a);
        defer chars.deinit();
        for (es.items) |e| {
            if (e.isRuleRef()) {
                try std.testing.expect(!rules.contains(e.refRuleId()));
                try rules.put(e.refRuleId(), {});
                continue;
            }
            var c = e.min;
            while (c <= e.max) : (c += 1) {
                try std.testing.expect(!chars.contains(c));
                try chars.put(c, {});
            }
        }
    }

    // Test 3: minimization.
    var minimized = try dfa.minimizeDfa(a);
    defer minimized.deinit();
    try std.testing.expect(try minimized.acceptString("abc3"));
    try std.testing.expectEqual(@as(i32, 2), minimized.getFsm().numStates());

    // Test 4: complement.
    var complement = try minimized.not(a);
    defer complement.deinit();
    try std.testing.expect(!try complement.acceptString("abc3"));
    try std.testing.expect(try complement.acceptString("abcd"));

    // Test 5: bounded and unbounded repetition.
    var m5 = try build(a, "[\\d]{1,5}");
    defer m5.deinit();
    try std.testing.expect(try m5.acceptString("123"));
    try std.testing.expect(try m5.acceptString("12345"));
    try std.testing.expect(!try m5.acceptString("123456"));
    try std.testing.expect(!try m5.acceptString("1234567"));
    var m6 = try build(a, "[\\d]{6}");
    defer m6.deinit();
    try std.testing.expect(try m6.acceptString("123456"));
    try std.testing.expect(!try m6.acceptString("1234567"));
    var m7 = try build(a, "[\\d]{6, }");
    defer m7.deinit();
    try std.testing.expect(try m7.acceptString("123456"));
    try std.testing.expect(try m7.acceptString("1234567"));

    // Test 6: epsilon simplification preserves acceptance and shrinks states.
    var m8 = try build(a, "[a][b][c][d]");
    defer m8.deinit();
    try std.testing.expect(try m8.acceptString("abcd"));
    var simplified = try m8.simplifyEpsilon(a);
    defer simplified.deinit();
    try std.testing.expectEqual(@as(i32, 5), simplified.getFsm().numStates());
    try std.testing.expect(try simplified.acceptString("abcd"));

    // Test 7: shared-prefix merge.
    var m9 = try build(a, "abc|abd");
    defer m9.deinit();
    try std.testing.expect(try m9.acceptString("abc"));
    var simplified9 = try m9.simplifyEpsilon(a);
    defer simplified9.deinit();
    var merged = try simplified9.mergeEquivalentStates(a);
    defer merged.deinit();
    try std.testing.expect(try merged.acceptString("abc"));
    try std.testing.expect(!try merged.acceptString("abcd"));
    try std.testing.expectEqual(@as(i32, 4), merged.getFsm().numStates());

    // Test 8: shared-suffix merge.
    var m10 = try build(a, "acd|bcd");
    defer m10.deinit();
    try std.testing.expect(try m10.acceptString("acd"));
    var simplified10 = try m10.simplifyEpsilon(a);
    defer simplified10.deinit();
    var merged10 = try simplified10.mergeEquivalentStates(a);
    defer merged10.deinit();
    try std.testing.expect(try merged10.acceptString("acd"));
    try std.testing.expect(!try merged10.acceptString("abcd"));
    try std.testing.expectEqual(@as(i32, 4), merged10.getFsm().numStates());

    // Test 9: star simplification.
    var m11 = try build(a, "ab*");
    defer m11.deinit();
    try std.testing.expect(try m11.acceptString("abbb"));
    var simplified11 = try m11.simplifyEpsilon(a);
    defer simplified11.deinit();
    try std.testing.expect(try simplified11.acceptString("abbb"));
    try std.testing.expectEqual(@as(i32, 2), simplified11.getFsm().numStates());

    // Test 10: intersection.
    var left = try build(a, "[c-f]+");
    defer left.deinit();
    var right = try build(a, "[d-h]*");
    defer right.deinit();
    var intersection = try FsmWithStartEnd.intersect(a, &left, &right);
    defer intersection.deinit();
    try std.testing.expect(try intersection.acceptString("de"));
    try std.testing.expect(try intersection.acceptString("def"));
    try std.testing.expect(!try intersection.acceptString(""));
    try std.testing.expect(!try intersection.acceptString("cd"));
}

test "intersection_uses_configured_state_limit" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var bounded = try build(a, "a{1001}");
    defer bounded.deinit();
    var repeated = try build(a, "a*");
    defer repeated.deinit();

    const a1001 = try a.alloc(u8, 1001);
    @memset(a1001, 'a');
    const a1000 = a1001[0..1000];

    var intersection = try FsmWithStartEnd.intersectWithLimit(a, &bounded, &repeated, 4096);
    defer intersection.deinit();
    try std.testing.expect(try intersection.acceptString(a1001));
    try std.testing.expect(!try intersection.acceptString(a1000));
    try std.testing.expectError(error.StateLimitExceeded, FsmWithStartEnd.intersectWithLimit(a, &bounded, &repeated, 1000));
}

test "determinization_bounds_subset_states" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var fsm_owned = try Fsm.init(a, 7);
    try fsm_owned.addEdge(0, 0, 'a', 'b');
    try fsm_owned.addEdge(0, 1, 'a', 'a');
    for (1..6) |i| {
        try fsm_owned.addEdge(@intCast(i), @intCast(i + 1), 'a', 'b');
    }
    var nfa = FsmWithStartEnd.init(a, fsm_owned, 0, blk: {
        var ends: std.ArrayList(i32) = .empty;
        try ends.append(a, 6);
        break :blk ends;
    }, false);
    defer nfa.deinit();
    try std.testing.expectError(error.StateLimitExceeded, nfa.toDfaWithLimit(a, 16));
    var dfa = try nfa.toDfaWithLimit(a, 64);
    defer dfa.deinit();
    try std.testing.expectEqual(@as(i32, 64), dfa.numStates());
    try std.testing.expect(try dfa.acceptString("abbbbb"));
    try std.testing.expect(!try dfa.acceptString("bbbbbb"));
    try std.testing.expect(!try dfa.acceptString("abbbb"));
}

test "intersection_bounds_product_states" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var pairs_owned = try Fsm.init(a, 2);
    var triples_owned = try Fsm.init(a, 3);
    for (0..2) |i| {
        try pairs_owned.addEdge(@intCast(i), @intCast((i + 1) % 2), 'a', 'a');
    }
    for (0..3) |i| {
        try triples_owned.addEdge(@intCast(i), @intCast((i + 1) % 3), 'a', 'a');
    }
    var lhs = FsmWithStartEnd.init(a, pairs_owned, 0, blk: {
        var ends: std.ArrayList(i32) = .empty;
        try ends.append(a, 0);
        break :blk ends;
    }, false);
    defer lhs.deinit();
    var rhs = FsmWithStartEnd.init(a, triples_owned, 0, blk: {
        var ends: std.ArrayList(i32) = .empty;
        try ends.append(a, 0);
        break :blk ends;
    }, false);
    defer rhs.deinit();
    try std.testing.expectError(error.StateLimitExceeded, FsmWithStartEnd.intersectWithLimit(a, &lhs, &rhs, 4));
    var intersection = try FsmWithStartEnd.intersectWithLimit(a, &lhs, &rhs, 6);
    defer intersection.deinit();
    try std.testing.expect(try intersection.acceptString("aaaaaa"));
    try std.testing.expect(!try intersection.acceptString("aaaaa"));
}

test "merge_equivalent_states_keeps_start_state_separate" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var fsm_owned = try Fsm.init(a, 4);
    try fsm_owned.addEdge(0, 0, 'a', 'z');
    try fsm_owned.addEdge(0, 1, 'a', 'z');
    try fsm_owned.addEdge(1, 2, 'c', 'c');
    try fsm_owned.addEdge(2, 3, 'd', 'd');
    var nfa = FsmWithStartEnd.init(a, fsm_owned, 0, blk: {
        var ends: std.ArrayList(i32) = .empty;
        try ends.append(a, 3);
        break :blk ends;
    }, false);
    defer nfa.deinit();
    var merged = try nfa.mergeEquivalentStates(a);
    defer merged.deinit();
    try std.testing.expect(!try merged.acceptString("cd"));
    try std.testing.expect(try merged.acceptString("acd"));
    try std.testing.expect(try merged.acceptString("xyzcd"));
    try std.testing.expect(!try merged.acceptString("d"));
}

fn manualFsm(a: A, num_states: i32) !FsmWithStartEnd {
    return FsmWithStartEnd.init(a, try Fsm.init(a, @intCast(num_states)), 0, .empty, false);
}

test "merging_nodes_test" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var fsm_wse = try manualFsm(a, 10);
    defer fsm_wse.deinit();
    fsm_wse.setStartState(0);
    try fsm_wse.addEndState(9);
    const edges = [_][3]i32{
        .{ 0, 1, 'a' }, .{ 0, 2, 'a' }, .{ 1, 3, 'b' }, .{ 1, 3, 'c' }, .{ 1, 4, 'b' }, .{ 1, 4, 'c' },
        .{ 2, 5, 'b' }, .{ 2, 5, 'c' }, .{ 2, 6, 'b' }, .{ 2, 6, 'c' }, .{ 3, 7, 'd' }, .{ 4, 7, 'd' },
        .{ 5, 8, 'd' }, .{ 6, 8, 'd' }, .{ 7, 9, 'e' }, .{ 8, 9, 'e' },
    };
    for (edges) |edge| {
        try fsm_wse.fsmMut().addEdge(edge[0], edge[1], edge[2], edge[2]);
    }
    var merged = try fsm_wse.mergeEquivalentStates(a);
    defer merged.deinit();
    const expected = "FSM(num_states=5, start=3, end=[4], edges=[\n" ++
        "0: ['d'->2]\n" ++
        "1: ['b'->0, 'c'->0]\n" ++
        "2: ['e'->4]\n" ++
        "3: ['a'->1]\n" ++
        "4: []\n" ++
        "])";
    const actual = try merged.toStringRepr(a);
    try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expectEqual(@as(i32, 5), merged.getFsm().numStates());
}

test "merge_equivalent_states_no_cross_rule_chaining" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var fsm_wse = try manualFsm(a, 7);
    defer fsm_wse.deinit();
    fsm_wse.setStartState(0);
    try fsm_wse.addEndState(6);
    try fsm_wse.fsmMut().addEdge(0, 2, 'x', 'x');
    try fsm_wse.fsmMut().addEdge(0, 3, 'x', 'x');
    try fsm_wse.fsmMut().addEdge(0, 1, 'y', 'y');
    try fsm_wse.fsmMut().addEdge(1, 4, 'a', 'a');
    try fsm_wse.fsmMut().addEdge(2, 4, 'a', 'a');
    try fsm_wse.fsmMut().addEdge(3, 5, 'b', 'b');
    try fsm_wse.fsmMut().addEdge(4, 6, 'm', 'm');
    try fsm_wse.fsmMut().addEdge(5, 6, 'n', 'n');
    var merged = try fsm_wse.mergeEquivalentStates(a);
    defer merged.deinit();
    try std.testing.expect(try merged.acceptString("xam"));
    try std.testing.expect(try merged.acceptString("xbn"));
    try std.testing.expect(try merged.acceptString("yam"));
    try std.testing.expect(!try merged.acceptString("ybn"));
}

test "simplify_epsilon_preserves_acceptance" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();

    var m1 = try build(a, "(ab)+");
    defer m1.deinit();
    var s1 = try m1.simplifyEpsilon(a);
    defer s1.deinit();
    try std.testing.expect(!try s1.acceptString(""));
    try std.testing.expect(!try s1.acceptString("a"));
    try std.testing.expect(try s1.acceptString("ab"));
    try std.testing.expect(try s1.acceptString("abab"));

    var m2 = try build(a, "a+");
    defer m2.deinit();
    var s2 = try m2.simplifyEpsilon(a);
    defer s2.deinit();
    try std.testing.expect(!try s2.acceptString(""));
    try std.testing.expect(try s2.acceptString("a"));
    try std.testing.expect(try s2.acceptString("aaa"));

    var m3 = try manualFsm(a, 4);
    defer m3.deinit();
    m3.setStartState(0);
    try m3.addEndState(1);
    try m3.addEndState(3);
    try m3.fsmMut().addEdge(0, 1, 'a', 'a');
    try m3.fsmMut().addEpsilonEdge(1, 2);
    try m3.fsmMut().addEdge(0, 2, 'b', 'b');
    try m3.fsmMut().addEdge(2, 3, 'c', 'c');
    var s3 = try m3.simplifyEpsilon(a);
    defer s3.deinit();
    try std.testing.expect(try s3.acceptString("a"));
    try std.testing.expect(try s3.acceptString("ac"));
    try std.testing.expect(try s3.acceptString("bc"));
    try std.testing.expect(!try s3.acceptString("b"));
    try std.testing.expect(!try s3.acceptString(""));

    var m4 = try manualFsm(a, 3);
    defer m4.deinit();
    m4.setStartState(0);
    try m4.addEndState(2);
    try m4.fsmMut().addEdge(0, 1, 'a', 'a');
    try m4.fsmMut().addEpsilonEdge(1, 2);
    var s4 = try m4.simplifyEpsilon(a);
    defer s4.deinit();
    try std.testing.expectEqual(@as(i32, 2), s4.getFsm().numStates());
    try std.testing.expect(try s4.acceptString("a"));
    try std.testing.expect(!try s4.acceptString(""));
}

test "epsilon_simplification_test" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var fsm_wse = try manualFsm(a, 10);
    defer fsm_wse.deinit();
    fsm_wse.setStartState(0);
    try fsm_wse.addEndState(9);
    try fsm_wse.fsmMut().addEpsilonEdge(0, 1);
    try fsm_wse.fsmMut().addEpsilonEdge(0, 2);
    try fsm_wse.fsmMut().addEdge(1, 3, 'b', 'b');
    try fsm_wse.fsmMut().addEpsilonEdge(1, 3);
    try fsm_wse.fsmMut().addEdge(1, 4, 'b', 'b');
    try fsm_wse.fsmMut().addEdge(3, 3, 'c', 'c');
    try fsm_wse.fsmMut().addEpsilonEdge(2, 5);
    try fsm_wse.fsmMut().addEdge(2, 5, 'c', 'c');
    try fsm_wse.fsmMut().addEdge(2, 6, 'b', 'b');
    try fsm_wse.fsmMut().addEdge(2, 6, 'c', 'c');
    try fsm_wse.fsmMut().addEpsilonEdge(3, 7);
    try fsm_wse.fsmMut().addEpsilonEdge(4, 7);
    try fsm_wse.fsmMut().addEpsilonEdge(5, 8);
    try fsm_wse.fsmMut().addEpsilonEdge(6, 8);
    try fsm_wse.fsmMut().addEpsilonEdge(7, 9);
    try fsm_wse.fsmMut().addEpsilonEdge(8, 9);
    var simplified = try fsm_wse.simplifyEpsilon(a);
    defer simplified.deinit();
    const expected = "FSM(num_states=3, start=0, end=[1], edges=[\n" ++
        "0: [Eps->1, Eps->2, 'b'->1, 'b'->2, 'c'->1]\n" ++
        "1: []\n" ++
        "2: [Eps->1, 'c'->2]\n" ++
        "])";
    const actual = try simplified.toStringRepr(a);
    try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expectEqual(@as(i32, 3), simplified.getFsm().numStates());
}

test "efficiency_test" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var group: std.ArrayList(u8) = .empty;
    for (0..52) |i| {
        if (i > 0) try group.appendSlice(a, "|");
        const letter: u8 = @intCast('a' + i / 2);
        try group.print(a, "{c}0123456789", .{letter});
    }
    var regex: std.ArrayList(u8) = .empty;
    for (0..10) |_| {
        try regex.print(a, "({s})", .{group.items});
    }
    var fsm_wse = try build(a, regex.items);
    var simplified = try fsm_wse.simplifyEpsilon(a);
    fsm_wse.deinit();
    var merged = try simplified.mergeEquivalentStates(a);
    simplified.deinit();
    var dfa = try merged.toDfa(a);
    merged.deinit();
    var minimized = try dfa.minimizeDfa(a);
    dfa.deinit();
    defer minimized.deinit();
    try std.testing.expectEqual(@as(i32, 111), minimized.getFsm().numStates());
}
