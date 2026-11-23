//! Port of `external/xgrammar/tests/cpp/test_fsm.cc` (spec tests).
//!
//! Ported from `build` → `accept_string` acceptance through the full automata pipeline
//! (DFA conversion, minimization, epsilon simplification, state merging, intersection,
//! complement, and the compact representation).

const std = @import("std");
const fsm_mod = @import("mod.zig");
const CompactFsm = fsm_mod.CompactFsm;
const CompactFsmWithStartEnd = fsm_mod.CompactFsmWithStartEnd;
const Fsm = fsm_mod.Fsm;
const FsmWithStartEnd = fsm_mod.FsmWithStartEnd;
const RegexFsmBuilder = fsm_mod.RegexFsmBuilder;

const A = std.mem.Allocator;

/// Per-test arena: Value trees and message buffers have no recursive free.
fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

/// Whether some character-range edge out of state 0 covers `c` — mirrors the in-test lambda
/// the C++ uses to probe a single character class's first state.
fn state0_accepts_char(fsm_wse: *const FsmWithStartEnd, c: u8) bool {
    for (fsm_wse.get_fsm().state_edges(0)) |e| {
        if (e.min <= c and e.max >= c) return true;
    }
    return false;
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

test "basic_build_test" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();

    // Test 1: literal string with an escape.
    var fsm_wse = try build(a, "abcd\\n");
    defer fsm_wse.deinit();
    try std.testing.expect(try fsm_wse.accept_string("abcd\n"));

    // Test 2: a class mixing a leading dash, a range, and an escape.
    var fsm_wse2 = try build(a, "[-a-z\\n]");
    defer fsm_wse2.deinit();
    for ("abcd-\n") |c| {
        try std.testing.expect(state0_accepts_char(&fsm_wse2, c));
    }

    // Test 3: digit class.
    var fsm_wse3 = try build(a, "[\\d]");
    defer fsm_wse3.deinit();
    for ("1234567890") |c| {
        try std.testing.expect(state0_accepts_char(&fsm_wse3, c));
    }

    // Test 4: negated digit class.
    var fsm_wse4 = try build(a, "[^\\d]");
    defer fsm_wse4.deinit();
    for ("1234567890") |c| {
        try std.testing.expect(!state0_accepts_char(&fsm_wse4, c));
    }
    for ("abz") |c| {
        try std.testing.expect(state0_accepts_char(&fsm_wse4, c));
    }

    // Test 5: multibyte literal.
    var fsm_wse5 = try build(a, "你好a");
    defer fsm_wse5.deinit();
    try std.testing.expect(try fsm_wse5.accept_string("你好a"));

    // Test 6: empty groups accept the empty string.
    var fsm_wse6 = try build(a, "(())()()");
    defer fsm_wse6.deinit();
    try std.testing.expect(try fsm_wse6.accept_string(""));

    // Test 7: a class with duplicates collapses to merged ranges (two: a-d and x-z).
    var fsm_wse7 = try build(a, "[abcdabcdxyzxyz]");
    defer fsm_wse7.deinit();
    try std.testing.expect(try fsm_wse7.accept_string("a"));
    try std.testing.expect(!try fsm_wse7.accept_string("e"));
    try std.testing.expectEqual(@as(usize, 2), fsm_wse7.get_fsm().state_edges(0).len);
}

test "connection_test" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();

    // Test 1: literal, class, and trailing literals concatenated.
    var m1 = try build(a, " [a-zA-Z0-9]--");
    defer m1.deinit();
    try std.testing.expect(try m1.accept_string(" a--"));

    // Test 2: alternation of a literal and a class.
    var m2 = try build(a, "aaa|[\\d]");
    defer m2.deinit();
    try std.testing.expect(try m2.accept_string("aaa"));
    try std.testing.expect(try m2.accept_string("1"));

    // Test 3: nested alternation in groups.
    var m3 = try build(a, "(([\\d]|[\\w])|aaa)");
    defer m3.deinit();
    try std.testing.expect(try m3.accept_string("aaa"));
    try std.testing.expect(try m3.accept_string("1"));
    try std.testing.expect(!try m3.accept_string("1a"));
}

test "symbol_test" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();

    // Test 1: `+` quantifier.
    var m1 = try build(a, "1[\\d]+");
    defer m1.deinit();
    try std.testing.expect(try m1.accept_string("1111"));
    try std.testing.expect(!try m1.accept_string("1"));

    // Test 2: `*` quantifier.
    var m2 = try build(a, "1[1]*");
    defer m2.deinit();
    try std.testing.expect(try m2.accept_string("1111"));
    try std.testing.expect(try m2.accept_string("1"));

    // Test 3: `?` quantifier.
    var m3 = try build(a, "1[\\d]?");
    defer m3.deinit();
    try std.testing.expect(!try m3.accept_string("1111"));
    try std.testing.expect(try m3.accept_string("1"));
    try std.testing.expect(try m3.accept_string("11"));

    // Test 4: quantified literal spaces.
    var m4 = try build(a, " * * + ? *");
    defer m4.deinit();
    try std.testing.expect(try m4.accept_string(" "));
    try std.testing.expect(try m4.accept_string("      "));
}

test "integrated_test" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var m = try build(a, "((naive|bbb|[\\d]+)*[\\w])|  +");
    defer m.deinit();
    for ([_][]const u8{ "naive1", "bbbnaive114514W", "    ", "123", "_" }) |s| {
        try std.testing.expect(try m.accept_string(s));
    }
    for ([_][]const u8{ "naive", "bbbbbb", "naive   ", "123 ", "aaa" }) |s| {
        try std.testing.expect(!try m.accept_string(s));
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
        try std.testing.expect(try m.accept_string(email));
    }
    for ([_][]const u8{ "@google.test", "hello@", "hello@.test", "+++asd@b.test", "hello" }) |email| {
        try std.testing.expect(!try m.accept_string(email));
    }
}

test "test_time" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var m = try build(a, "(\\d{1,2}):(\\d{2})(:(\\d{2}))?");
    defer m.deinit();
    for ([_][]const u8{ "1:34", "23:59", "00:00", "01:02:03", "23:59:59" }) |time| {
        try std.testing.expect(try m.accept_string(time));
    }
    for ([_][]const u8{ "19", "12:6", "12:34:", "12:34:5", "12:34:567", "12:123", "12:", ":34:23", "::" }) |time| {
        try std.testing.expect(!try m.accept_string(time));
    }
}

test "function_test" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();

    // Test 1: compact round-trip.
    var m1 = try build(a, "[\\d\\d\\d]+123");
    defer m1.deinit();
    try std.testing.expect(try m1.accept_string("123456123"));
    var compact = try CompactFsm.from_fsm(a, m1.get_fsm());
    defer compact.deinit();
    var compact_wse = try CompactFsmWithStartEnd.new(a, compact.clone(), m1.get_start(), blk: {
        var ends: std.ArrayList(i32) = .empty;
        try ends.appendSlice(a, m1.get_ends());
        break :blk ends;
    }, false);
    defer compact_wse.deinit();
    try std.testing.expect(try compact_wse.accept_string("123456123"));
    var roundtrip = try FsmWithStartEnd.new(a, try compact.to_fsm(a), m1.get_start(), blk: {
        var ends: std.ArrayList(i32) = .empty;
        try ends.appendSlice(a, m1.get_ends());
        break :blk ends;
    }, false);
    defer roundtrip.deinit();
    try std.testing.expect(try roundtrip.accept_string("123456123"));

    // Test 2: DFA conversion removes epsilons and de-duplicates transitions.
    var m2 = try build(a, "([abc]|[\\d])+");
    defer m2.deinit();
    try std.testing.expect(try m2.accept_string("abc3"));
    var dfa = try m2.to_dfa(a);
    defer dfa.deinit();
    try std.testing.expect(try dfa.accept_string("abc3"));
    for (dfa.get_fsm().edges_slice()) |es| {
        for (es.items) |e| try std.testing.expect(!e.is_epsilon());
        var rules = std.AutoHashMap(i32, void).init(a);
        defer rules.deinit();
        var chars = std.AutoHashMap(i32, void).init(a);
        defer chars.deinit();
        for (es.items) |e| {
            if (e.is_rule_ref()) {
                try std.testing.expect(!rules.contains(e.ref_rule_id())); // duplicate rule edge
                try rules.put(e.ref_rule_id(), {});
                continue;
            }
            var c = e.min;
            while (c <= e.max) : (c += 1) {
                try std.testing.expect(!chars.contains(c)); // duplicate char transition
                try chars.put(c, {});
            }
        }
    }

    // Test 3: minimization.
    var minimized = try dfa.minimize_dfa(a);
    defer minimized.deinit();
    try std.testing.expect(try minimized.accept_string("abc3"));
    try std.testing.expectEqual(@as(i32, 2), minimized.get_fsm().num_states());

    // Test 4: complement.
    var complement = try minimized.not(a);
    defer complement.deinit();
    try std.testing.expect(!try complement.accept_string("abc3"));
    try std.testing.expect(try complement.accept_string("abcd"));

    // Test 5: bounded and unbounded repetition.
    var m5 = try build(a, "[\\d]{1,5}");
    defer m5.deinit();
    try std.testing.expect(try m5.accept_string("123"));
    try std.testing.expect(try m5.accept_string("12345"));
    try std.testing.expect(!try m5.accept_string("123456"));
    try std.testing.expect(!try m5.accept_string("1234567"));
    var m6 = try build(a, "[\\d]{6}");
    defer m6.deinit();
    try std.testing.expect(try m6.accept_string("123456"));
    try std.testing.expect(!try m6.accept_string("1234567"));
    var m7 = try build(a, "[\\d]{6, }");
    defer m7.deinit();
    try std.testing.expect(try m7.accept_string("123456"));
    try std.testing.expect(try m7.accept_string("1234567"));

    // Test 6: epsilon simplification preserves acceptance and shrinks states.
    var m8 = try build(a, "[a][b][c][d]");
    defer m8.deinit();
    try std.testing.expect(try m8.accept_string("abcd"));
    var simplified = try m8.simplify_epsilon(a);
    defer simplified.deinit();
    try std.testing.expectEqual(@as(i32, 5), simplified.get_fsm().num_states());
    try std.testing.expect(try simplified.accept_string("abcd"));

    // Test 7: shared-prefix merge.
    var m9 = try build(a, "abc|abd");
    defer m9.deinit();
    try std.testing.expect(try m9.accept_string("abc"));
    var simplified9 = try m9.simplify_epsilon(a);
    defer simplified9.deinit();
    var merged = try simplified9.merge_equivalent_states(a);
    defer merged.deinit();
    try std.testing.expect(try merged.accept_string("abc"));
    try std.testing.expect(!try merged.accept_string("abcd"));
    try std.testing.expectEqual(@as(i32, 4), merged.get_fsm().num_states());

    // Test 8: shared-suffix merge.
    var m10 = try build(a, "acd|bcd");
    defer m10.deinit();
    try std.testing.expect(try m10.accept_string("acd"));
    var simplified10 = try m10.simplify_epsilon(a);
    defer simplified10.deinit();
    var merged10 = try simplified10.merge_equivalent_states(a);
    defer merged10.deinit();
    try std.testing.expect(try merged10.accept_string("acd"));
    try std.testing.expect(!try merged10.accept_string("abcd"));
    try std.testing.expectEqual(@as(i32, 4), merged10.get_fsm().num_states());

    // Test 9: star simplification.
    var m11 = try build(a, "ab*");
    defer m11.deinit();
    try std.testing.expect(try m11.accept_string("abbb"));
    var simplified11 = try m11.simplify_epsilon(a);
    defer simplified11.deinit();
    try std.testing.expect(try simplified11.accept_string("abbb"));
    try std.testing.expectEqual(@as(i32, 2), simplified11.get_fsm().num_states());

    // Test 10: intersection.
    var left = try build(a, "[c-f]+");
    defer left.deinit();
    var right = try build(a, "[d-h]*");
    defer right.deinit();
    var intersection = try FsmWithStartEnd.intersect(a, &left, &right);
    defer intersection.deinit();
    try std.testing.expect(try intersection.accept_string("de"));
    try std.testing.expect(try intersection.accept_string("def"));
    try std.testing.expect(!try intersection.accept_string(""));
    try std.testing.expect(!try intersection.accept_string("cd"));
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

    var intersection = try FsmWithStartEnd.intersect_with_limit(a, &bounded, &repeated, 4096);
    defer intersection.deinit();
    try std.testing.expect(try intersection.accept_string(a1001));
    try std.testing.expect(!try intersection.accept_string(a1000));
    try std.testing.expectError(error.StateLimitExceeded, FsmWithStartEnd.intersect_with_limit(a, &bounded, &repeated, 1000));
}

test "determinization_bounds_subset_states" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var fsm_owned = try Fsm.new(a, 7);
    try fsm_owned.add_edge(0, 0, 'a', 'b');
    try fsm_owned.add_edge(0, 1, 'a', 'a');
    for (1..6) |i| {
        try fsm_owned.add_edge(@intCast(i), @intCast(i + 1), 'a', 'b');
    }
    var nfa = try FsmWithStartEnd.new(a, fsm_owned, 0, blk: {
        var ends: std.ArrayList(i32) = .empty;
        try ends.append(a, 6);
        break :blk ends;
    }, false);
    defer nfa.deinit();
    try std.testing.expectError(error.StateLimitExceeded, nfa.to_dfa_with_limit(a, 16));
    var dfa = try nfa.to_dfa_with_limit(a, 64);
    defer dfa.deinit();
    try std.testing.expectEqual(@as(i32, 64), dfa.num_states());
    try std.testing.expect(try dfa.accept_string("abbbbb"));
    try std.testing.expect(!try dfa.accept_string("bbbbbb"));
    try std.testing.expect(!try dfa.accept_string("abbbb"));
}

test "intersection_bounds_product_states" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var pairs_owned = try Fsm.new(a, 2);
    var triples_owned = try Fsm.new(a, 3);
    for (0..2) |i| {
        try pairs_owned.add_edge(@intCast(i), @intCast((i + 1) % 2), 'a', 'a');
    }
    for (0..3) |i| {
        try triples_owned.add_edge(@intCast(i), @intCast((i + 1) % 3), 'a', 'a');
    }
    var lhs = try FsmWithStartEnd.new(a, pairs_owned, 0, blk: {
        var ends: std.ArrayList(i32) = .empty;
        try ends.append(a, 0);
        break :blk ends;
    }, false);
    defer lhs.deinit();
    var rhs = try FsmWithStartEnd.new(a, triples_owned, 0, blk: {
        var ends: std.ArrayList(i32) = .empty;
        try ends.append(a, 0);
        break :blk ends;
    }, false);
    defer rhs.deinit();
    try std.testing.expectError(error.StateLimitExceeded, FsmWithStartEnd.intersect_with_limit(a, &lhs, &rhs, 4));
    var intersection = try FsmWithStartEnd.intersect_with_limit(a, &lhs, &rhs, 6);
    defer intersection.deinit();
    try std.testing.expect(try intersection.accept_string("aaaaaa"));
    try std.testing.expect(!try intersection.accept_string("aaaaa"));
}

test "merge_equivalent_states_keeps_start_state_separate" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // [a-z]* [a-z] "c" "d": the start state loops on [a-z] and also leads to state 1 on [a-z].
    // State 1 is only reached from the start state, but the start state is also entered without
    // any edge, so the two must not be merged; otherwise "cd" would be accepted.
    var fsm_owned = try Fsm.new(a, 4);
    try fsm_owned.add_edge(0, 0, 'a', 'z');
    try fsm_owned.add_edge(0, 1, 'a', 'z');
    try fsm_owned.add_edge(1, 2, 'c', 'c');
    try fsm_owned.add_edge(2, 3, 'd', 'd');
    var nfa = try FsmWithStartEnd.new(a, fsm_owned, 0, blk: {
        var ends: std.ArrayList(i32) = .empty;
        try ends.append(a, 3);
        break :blk ends;
    }, false);
    defer nfa.deinit();
    var merged = try nfa.merge_equivalent_states(a);
    defer merged.deinit();
    try std.testing.expect(!try merged.accept_string("cd"));
    try std.testing.expect(try merged.accept_string("acd"));
    try std.testing.expect(try merged.accept_string("xyzcd"));
    try std.testing.expect(!try merged.accept_string("d"));
}

/// Builds an FSM with `num_states` states and no edges by hand for the merge/epsilon oracles.
fn manual_fsm(a: A, num_states: i32) !FsmWithStartEnd {
    return FsmWithStartEnd.new(a, try Fsm.new(a, @intCast(num_states)), 0, .empty, false);
}

test "merging_nodes_test" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var fsm_wse = try manual_fsm(a, 10);
    defer fsm_wse.deinit();
    fsm_wse.set_start_state(0);
    fsm_wse.add_end_state(9);
    const edges = [_][3]i32{
        .{ 0, 1, 'a' }, .{ 0, 2, 'a' }, .{ 1, 3, 'b' }, .{ 1, 3, 'c' }, .{ 1, 4, 'b' }, .{ 1, 4, 'c' },
        .{ 2, 5, 'b' }, .{ 2, 5, 'c' }, .{ 2, 6, 'b' }, .{ 2, 6, 'c' }, .{ 3, 7, 'd' }, .{ 4, 7, 'd' },
        .{ 5, 8, 'd' }, .{ 6, 8, 'd' }, .{ 7, 9, 'e' }, .{ 8, 9, 'e' },
    };
    for (edges) |edge| {
        try fsm_wse.fsm_mut().add_edge(edge[0], edge[1], edge[2], edge[2]);
    }
    var merged = try fsm_wse.merge_equivalent_states(a);
    defer merged.deinit();
    const expected = "FSM(num_states=5, start=3, end=[4], edges=[\n" ++
        "0: ['d'->2]\n" ++
        "1: ['b'->0, 'c'->0]\n" ++
        "2: ['e'->4]\n" ++
        "3: ['a'->1]\n" ++
        "4: []\n" ++
        "])";
    const actual = try merged.to_string_repr();
    try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expectEqual(@as(i32, 5), merged.get_fsm().num_states());
}

test "merge_equivalent_states_no_cross_rule_chaining" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var fsm_wse = try manual_fsm(a, 7);
    defer fsm_wse.deinit();
    fsm_wse.set_start_state(0);
    fsm_wse.add_end_state(6);
    // 2 and 3 are equivalent successors of 0 under 'x' (Case 1).
    try fsm_wse.fsm_mut().add_edge(0, 2, 'x', 'x');
    try fsm_wse.fsm_mut().add_edge(0, 3, 'x', 'x');
    // 1 is another predecessor of 4 under 'a' (Case 2 candidate with 2).
    try fsm_wse.fsm_mut().add_edge(0, 1, 'y', 'y');
    try fsm_wse.fsm_mut().add_edge(1, 4, 'a', 'a');
    try fsm_wse.fsm_mut().add_edge(2, 4, 'a', 'a');
    try fsm_wse.fsm_mut().add_edge(3, 5, 'b', 'b');
    try fsm_wse.fsm_mut().add_edge(4, 6, 'm', 'm');
    try fsm_wse.fsm_mut().add_edge(5, 6, 'n', 'n');
    var merged = try fsm_wse.merge_equivalent_states(a);
    defer merged.deinit();
    try std.testing.expect(try merged.accept_string("xam"));
    try std.testing.expect(try merged.accept_string("xbn"));
    try std.testing.expect(try merged.accept_string("yam"));
    // Should not over-merge and introduce this path.
    try std.testing.expect(!try merged.accept_string("ybn"));
}

test "simplify_epsilon_preserves_acceptance" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();

    // (ab)+ : the accepting state's only edge is an epsilon back to the non-accepting start.
    // Merging the two states would wrongly make the start state accepting.
    var m1 = try build(a, "(ab)+");
    defer m1.deinit();
    var s1 = try m1.simplify_epsilon(a);
    defer s1.deinit();
    try std.testing.expect(!try s1.accept_string(""));
    try std.testing.expect(!try s1.accept_string("a"));
    try std.testing.expect(try s1.accept_string("ab"));
    try std.testing.expect(try s1.accept_string("abab"));

    var m2 = try build(a, "a+");
    defer m2.deinit();
    var s2 = try m2.simplify_epsilon(a);
    defer s2.deinit();
    try std.testing.expect(!try s2.accept_string(""));
    try std.testing.expect(try s2.accept_string("a"));
    try std.testing.expect(try s2.accept_string("aaa"));

    // Hand-built: accepting state 1 has a single epsilon edge to non-accepting state 2, and
    // state 2 is also reachable via another path (0 -b-> 2). Merging 1 and 2 would wrongly
    // accept "b". The language is {"a", "ac", "bc"}.
    var m3 = try manual_fsm(a, 4);
    defer m3.deinit();
    m3.set_start_state(0);
    m3.add_end_state(1);
    m3.add_end_state(3);
    try m3.fsm_mut().add_edge(0, 1, 'a', 'a');
    try m3.fsm_mut().add_epsilon_edge(1, 2);
    try m3.fsm_mut().add_edge(0, 2, 'b', 'b');
    try m3.fsm_mut().add_edge(2, 3, 'c', 'c');
    var s3 = try m3.simplify_epsilon(a);
    defer s3.deinit();
    try std.testing.expect(try s3.accept_string("a"));
    try std.testing.expect(try s3.accept_string("ac"));
    try std.testing.expect(try s3.accept_string("bc"));
    try std.testing.expect(!try s3.accept_string("b"));
    try std.testing.expect(!try s3.accept_string(""));

    // The safe direction still merges: non-accepting state with a single epsilon edge into an
    // accepting state.
    var m4 = try manual_fsm(a, 3);
    defer m4.deinit();
    m4.set_start_state(0);
    m4.add_end_state(2);
    try m4.fsm_mut().add_edge(0, 1, 'a', 'a');
    try m4.fsm_mut().add_epsilon_edge(1, 2);
    var s4 = try m4.simplify_epsilon(a);
    defer s4.deinit();
    try std.testing.expectEqual(@as(i32, 2), s4.get_fsm().num_states());
    try std.testing.expect(try s4.accept_string("a"));
    try std.testing.expect(!try s4.accept_string(""));
}

test "epsilon_simplification_test" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var fsm_wse = try manual_fsm(a, 10);
    defer fsm_wse.deinit();
    fsm_wse.set_start_state(0);
    fsm_wse.add_end_state(9);
    try fsm_wse.fsm_mut().add_epsilon_edge(0, 1);
    try fsm_wse.fsm_mut().add_epsilon_edge(0, 2);
    try fsm_wse.fsm_mut().add_edge(1, 3, 'b', 'b');
    try fsm_wse.fsm_mut().add_epsilon_edge(1, 3);
    try fsm_wse.fsm_mut().add_edge(1, 4, 'b', 'b');
    try fsm_wse.fsm_mut().add_edge(3, 3, 'c', 'c');
    try fsm_wse.fsm_mut().add_epsilon_edge(2, 5);
    try fsm_wse.fsm_mut().add_edge(2, 5, 'c', 'c');
    try fsm_wse.fsm_mut().add_edge(2, 6, 'b', 'b');
    try fsm_wse.fsm_mut().add_edge(2, 6, 'c', 'c');
    try fsm_wse.fsm_mut().add_epsilon_edge(3, 7);
    try fsm_wse.fsm_mut().add_epsilon_edge(4, 7);
    try fsm_wse.fsm_mut().add_epsilon_edge(5, 8);
    try fsm_wse.fsm_mut().add_epsilon_edge(6, 8);
    try fsm_wse.fsm_mut().add_epsilon_edge(7, 9);
    try fsm_wse.fsm_mut().add_epsilon_edge(8, 9);
    var simplified = try fsm_wse.simplify_epsilon(a);
    defer simplified.deinit();
    const expected = "FSM(num_states=3, start=0, end=[1], edges=[\n" ++
        "0: [Eps->1, Eps->2, 'b'->1, 'b'->2, 'c'->1]\n" ++
        "1: []\n" ++
        "2: [Eps->1, 'c'->2]\n" ++
        "])";
    const actual = try simplified.to_string_repr();
    try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expectEqual(@as(i32, 3), simplified.get_fsm().num_states());
}

test "efficiency_test" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // ([a-z]0123456789){10}, written as 10 concatenated 52-way alternations, exercises the
    // full simplify → merge → DFA → minimize pipeline. The minimal DFA has 111 states.
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
    var simplified = try fsm_wse.simplify_epsilon(a);
    fsm_wse.deinit();
    var merged = try simplified.merge_equivalent_states(a);
    simplified.deinit();
    var dfa = try merged.to_dfa(a);
    merged.deinit();
    var minimized = try dfa.minimize_dfa(a);
    dfa.deinit();
    defer minimized.deinit();
    try std.testing.expectEqual(@as(i32, 111), minimized.get_fsm().num_states());
}
