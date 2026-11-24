//! Builds NFAs from byte-oriented regexes (`RegexFsmBuilder`), packed UTF-8 character
//! range lowering, and standard dot-semantics rewriting.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Diagnostic = @import("../Diagnostic.zig").Diagnostic;
const fsm_mod = @import("Fsm.zig");
const Fsm = fsm_mod.Fsm;
const automata = @import("fsm_automata.zig");
const FsmWithStartEnd = automata.FsmWithStartEnd;
const regex_ir = @import("regex_ir.zig");
const RegexIr = regex_ir.RegexIr;
const RegexError = regex_ir.RegexError;
const GrammarBuilder = @import("../grammar.zig").GrammarBuilder;

/// The largest 1-byte (ASCII) packed value.
pub const MAX_1_BYTE_UNICODE: u32 = 0x7F;
const MIN_2_BYTES_UNICODE: u32 = 0xC080;
const MAX_2_BYTES_UNICODE: u32 = 0xDFBF;
const MIN_3_BYTES_UNICODE: u32 = 0x00E0_8080;
const MAX_3_BYTES_UNICODE: u32 = 0x00EF_BFBF;
const MIN_4_BYTES_UNICODE: u32 = 0xF080_8080;
const MAX_4_BYTES_UNICODE: u32 = 0xF7BF_BFBF;

/// Converts a Unicode codepoint to the packed UTF-8 format (big-endian bytes in `u32`).
pub fn codepointToPackedUtf8(codepoint: u32) u32 {
    if (codepoint <= 0x7F) {
        return codepoint;
    } else if (codepoint <= 0x7FF) {
        const byte0 = 0xC0 | ((codepoint >> 6) & 0x1F);
        const byte1 = 0x80 | (codepoint & 0x3F);
        return (byte0 << 8) | byte1;
    } else if (codepoint <= 0xFFFF) {
        const byte0 = 0xE0 | ((codepoint >> 12) & 0x0F);
        const byte1 = 0x80 | ((codepoint >> 6) & 0x3F);
        const byte2 = 0x80 | (codepoint & 0x3F);
        return (byte0 << 16) | (byte1 << 8) | byte2;
    } else {
        const byte0 = 0xF0 | ((codepoint >> 18) & 0x07);
        const byte1 = 0x80 | ((codepoint >> 12) & 0x3F);
        const byte2 = 0x80 | ((codepoint >> 6) & 0x3F);
        const byte3 = 0x80 | (codepoint & 0x3F);
        return (byte0 << 24) | (byte1 << 16) | (byte2 << 8) | byte3;
    }
}

/// Adds edges (with intermediate states for multi-byte characters) from `from` to `to`
/// accepting every UTF-8 encoded character in the packed range `[min_in, max_in]`.
pub fn addPackedUtf8RangeEdges(fsm: *Fsm, from: i32, to: i32, min_in: u32, max_in: u32) Allocator.Error!void {
    var min = min_in;
    var max = max_in;
    std.debug.assert(min <= max);
    if (max > MAX_4_BYTES_UNICODE) {
        max = MAX_4_BYTES_UNICODE;
    } else if (max > MAX_3_BYTES_UNICODE) {
        if (max < MIN_4_BYTES_UNICODE) max = MAX_3_BYTES_UNICODE;
    } else if (max > MAX_2_BYTES_UNICODE) {
        if (max < MIN_3_BYTES_UNICODE) max = MAX_2_BYTES_UNICODE;
    } else if (max < MIN_2_BYTES_UNICODE and max > MAX_1_BYTE_UNICODE) {
        max = MAX_1_BYTE_UNICODE;
    }

    if (min > MAX_4_BYTES_UNICODE) {
        min = MAX_4_BYTES_UNICODE;
    } else if (min > MAX_3_BYTES_UNICODE) {
        if (min < MIN_4_BYTES_UNICODE) min = MIN_4_BYTES_UNICODE;
    } else if (min > MAX_2_BYTES_UNICODE) {
        if (min < MIN_3_BYTES_UNICODE) min = MIN_3_BYTES_UNICODE;
    } else if (min < MIN_2_BYTES_UNICODE and min > MAX_1_BYTE_UNICODE) {
        min = MIN_2_BYTES_UNICODE;
    }

    const length_ranges = [_][2]u32{
        .{ 0, MAX_1_BYTE_UNICODE },
        .{ MIN_2_BYTES_UNICODE, MAX_2_BYTES_UNICODE },
        .{ MIN_3_BYTES_UNICODE, MAX_3_BYTES_UNICODE },
        .{ MIN_4_BYTES_UNICODE, MAX_4_BYTES_UNICODE },
    };
    for (length_ranges) |length_range| {
        if (min <= length_range[1] and max >= length_range[0]) {
            try addSameLengthCharacterRange(
                fsm,
                from,
                to,
                @max(min, length_range[0]),
                @min(max, length_range[1]),
            );
        }
    }
}

fn addSameLengthCharacterRange(fsm: *Fsm, from: i32, to: i32, min: u32, max: u32) Allocator.Error!void {
    const byte = struct {
        fn f(value: u32, i: u32) i32 {
            return @intCast((value >> @as(u5, @intCast(8 * i))) & 0xFF);
        }
    }.f;
    if (byte(max, 1) == 0) {
        try fsm.addEdge(from, to, byte(min, 0), byte(max, 0));
        return;
    }
    const lead: u5 = if (byte(max, 3) != 0) 3 else if (byte(max, 2) != 0) 2 else 1;
    const tail_mask = (@as(u32, 1) << @as(u5, 8 * lead)) - 1;
    const tail_min: u32 = 0x8080_8080 & tail_mask;
    const tail_max: u32 = 0xBFBF_BFBF & tail_mask;
    var lead_min = byte(min, lead);
    var lead_max = byte(max, lead);

    if (lead_min == lead_max) {
        const next = try fsm.addState();
        try fsm.addEdge(from, next, lead_min, lead_max);
        try addSameLengthCharacterRange(fsm, next, to, min & tail_mask, max & tail_mask);
        return;
    }
    if (min & tail_mask == tail_min) {
        lead_min -= 1;
    } else {
        const next = try fsm.addState();
        try fsm.addEdge(from, next, lead_min, lead_min);
        try addSameLengthCharacterRange(fsm, next, to, min & tail_mask, tail_max);
    }
    if (max & tail_mask == tail_max) {
        lead_max += 1;
    } else {
        const next = try fsm.addState();
        try fsm.addEdge(from, next, lead_max, lead_max);
        try addSameLengthCharacterRange(fsm, next, to, tail_min, max & tail_mask);
    }
    if (lead_max - lead_min > 1) {
        var current = try fsm.addState();
        try fsm.addEdge(from, current, lead_min + 1, lead_max - 1);
        for (1..lead) |_| {
            const next = try fsm.addState();
            try fsm.addEdge(current, next, 0x80, 0xBF);
            current = next;
        }
        try fsm.addEdge(current, to, 0x80, 0xBF);
    }
}

/// Rewrites every unescaped `.` outside character classes to `[^\n]` unless
/// `dot_matches_newline` is true. Allocated from `allocator`.
pub fn rewriteRegexDots(allocator: Allocator, pattern: []const u8, dot_matches_newline: bool) Allocator.Error![]u8 {
    if (dot_matches_newline) {
        return allocator.dupe(u8, pattern);
    }
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, pattern.len);
    var escaped = false;
    var in_character_class = false;
    for (pattern) |c| {
        if (escaped) {
            try result.append(allocator, c);
            escaped = false;
            continue;
        }
        switch (c) {
            '\\' => {
                try result.append(allocator, c);
                escaped = true;
            },
            '[' => {
                try result.append(allocator, c);
                in_character_class = true;
            },
            ']' => {
                try result.append(allocator, c);
                in_character_class = false;
            },
            '.' => {
                if (!in_character_class) {
                    try result.appendSlice(allocator, "[^\\n]");
                } else {
                    try result.append(allocator, c);
                }
            },
            else => try result.append(allocator, c),
        }
    }
    return result.toOwnedSlice(allocator);
}

/// Converts regexes into FSMs.
pub const RegexFsmBuilder = struct {
    /// Builds an FSM accepting the language of `regex`. A leading `(?i)` makes the match ASCII
    /// case-insensitive.
    pub fn build(
        allocator: Allocator,
        regex: []const u8,
        builder: ?*GrammarBuilder,
        rule_hint: []const u8,
        diag: ?*Diagnostic,
    ) RegexError!FsmWithStartEnd {
        var ir = try RegexIr.parse(allocator, regex, builder, rule_hint, diag);
        defer ir.deinit();
        return ir.build(diag);
    }

    /// Builds the FSM of `regex` (see `build`), then removes the forbidden bytes from
    /// every character edge.
    pub fn buildWithForbiddenChars(
        allocator: Allocator,
        regex: []const u8,
        forbidden_chars: *const [256]bool,
        builder: ?*GrammarBuilder,
        rule_hint: []const u8,
        diag: ?*Diagnostic,
    ) RegexError!FsmWithStartEnd {
        var any = false;
        for (forbidden_chars) |f| {
            if (f) {
                any = true;
                break;
            }
        }
        var ir = try RegexIr.parseWithOptions(allocator, regex, builder, rule_hint, any, diag);
        defer ir.deinit();
        var fsm_wse = try ir.build(diag);
        errdefer fsm_wse.deinit();
        if (!any) return fsm_wse;

        var new_fsm = try Fsm.init(allocator, @intCast(fsm_wse.numStates()));
        errdefer new_fsm.deinit();
        for (0..@intCast(fsm_wse.numStates())) |state| {
            for (fsm_wse.getFsm().stateEdges(@intCast(state))) |edge| {
                if (!edge.isCharRange()) {
                    try new_fsm.addEdge(@intCast(state), edge.target, edge.min, edge.max);
                    continue;
                }
                var range_start: ?i32 = null;
                var c = edge.min;
                while (c <= edge.max + 1) : (c += 1) {
                    if (c <= edge.max and !forbidden_chars[@intCast(c)]) {
                        if (range_start == null) range_start = c;
                    } else if (range_start) |start| {
                        try new_fsm.addEdge(@intCast(state), edge.target, start, c - 1);
                        range_start = null;
                    }
                }
            }
        }
        var aux: std.ArrayList(i32) = .empty;
        errdefer aux.deinit(allocator);
        try aux.appendSlice(allocator, fsm_wse.getFsm().edgeAuxDataSlice());
        new_fsm.setEdgeAuxData(aux);
        var ends: std.ArrayList(i32) = .empty;
        errdefer ends.deinit(allocator);
        try ends.appendSlice(allocator, fsm_wse.endsSlice());
        const result = FsmWithStartEnd.init(allocator, new_fsm, fsm_wse.startState(), ends, false);
        fsm_wse.deinit();
        return result;
    }

    /// Whether `regex` matches the empty string without building an FSM.
    pub fn matchesEmpty(allocator: Allocator, regex: []const u8, diag: ?*Diagnostic) RegexError!bool {
        var ir = try RegexIr.parse(allocator, regex, null, "", diag);
        defer ir.deinit();
        return ir.matchesEmpty();
    }
};

test "codepointToPackedUtf8 and addPackedUtf8RangeEdges" {
    try std.testing.expectEqual(@as(u32, 'a'), codepointToPackedUtf8('a'));
    try std.testing.expectEqual(@as(u32, 0xC3A9), codepointToPackedUtf8(0xE9));
    try std.testing.expectEqual(@as(u32, 0xE4BDA0), codepointToPackedUtf8(0x4F60));
    try std.testing.expectEqual(@as(u32, 0xF09F9880), codepointToPackedUtf8(0x1F600));

    const a = std.testing.allocator;
    var fsm = try Fsm.init(a, 1);
    defer fsm.deinit();
    try addPackedUtf8RangeEdges(&fsm, 0, 0, 'a', 'c');
    try std.testing.expectEqual(@as(i32, 1), fsm.numStates());
}

test "rewriteRegexDots" {
    const a = std.testing.allocator;
    const r1 = try rewriteRegexDots(a, "a.c", false);
    defer a.free(r1);
    try std.testing.expectEqualStrings("a[^\\n]c", r1);
    const r2 = try rewriteRegexDots(a, "[.].", false);
    defer a.free(r2);
    try std.testing.expectEqualStrings("[.][^\\n]", r2);
    const r3 = try rewriteRegexDots(a, "a.", true);
    defer a.free(r3);
    try std.testing.expectEqualStrings("a.", r3);
    const r4 = try rewriteRegexDots(a, "\\.", false);
    defer a.free(r4);
    try std.testing.expectEqualStrings("\\.", r4);
}

test "RegexFsmBuilder build, forbidden chars, matchesEmpty, and Diagnostic" {
    const a = std.testing.allocator;
    var diag: Diagnostic = .{};
    defer diag.deinit(a);

    var m = try RegexFsmBuilder.build(a, "a[0-9]+", null, "", &diag);
    defer m.deinit();
    try std.testing.expect(try m.acceptString("a42"));
    try std.testing.expect(!try m.acceptString("a"));

    var forbidden: [256]bool = @splat(false);
    forbidden['"'] = true;
    forbidden['\\'] = true;
    var mf = try RegexFsmBuilder.buildWithForbiddenChars(a, "[ -~]+", &forbidden, null, "", &diag);
    defer mf.deinit();
    try std.testing.expect(try mf.acceptString("abc"));
    try std.testing.expect(!try mf.acceptString("a\"b"));
    try std.testing.expect(!try mf.acceptString("a\\b"));

    try std.testing.expect(try RegexFsmBuilder.matchesEmpty(a, "a*", &diag));
    try std.testing.expect(!try RegexFsmBuilder.matchesEmpty(a, "a+", &diag));
    try std.testing.expectError(error.RegexParse, RegexFsmBuilder.build(a, "+a", null, "", &diag));
    const formatted = try diag.formatAlloc(a);
    defer a.free(formatted);
    try std.testing.expectEqualStrings("Regex parsing error at position 1: There is nothing to repeat before '+'", formatted);

    // Large repeat with GrammarBuilder lowers into RepeatSubrule / Repeat edge without unrolling.
    var gb = try GrammarBuilder.init(a);
    defer gb.deinit();
    var m_large = try RegexFsmBuilder.build(a, "(?i)a{200}", &gb, "tok", &diag);
    defer m_large.deinit();
    try std.testing.expectEqual(@as(i32, 1), gb.numRules());
    try std.testing.expect(gb.getRule(0).is_exact_lookahead);
    var m_unbounded = try RegexFsmBuilder.build(a, "b{150,}", &gb, "tok", &diag);
    defer m_unbounded.deinit();
    try std.testing.expectEqual(@as(i32, 2), gb.numRules());
}
