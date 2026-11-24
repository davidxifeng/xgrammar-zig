//! Collapses the UTF-8 byte paths of a byte automaton into codepoint transitions
//! (`utf8_range_collapser.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const fsm_mod = @import("../fsm.zig");
const FsmWithStartEnd = fsm_mod.FsmWithStartEnd;

/// A `(target, min, max)` codepoint transition.
pub const CodepointRange = [3]i32;

/// Turns the byte transitions of a leaf automaton into codepoint intervals, so that a
/// string automaton can be emitted as character classes (EBNF string literals denote
/// codepoints, not raw bytes). Only productive states (those that can still reach an
/// accepting state) are kept, and multi-byte suffixes are memoized so wide Unicode
/// classes are not enumerated per codepoint.
pub const Utf8RangeCollapser = struct {
    gpa: Allocator,
    fsm: *const FsmWithStartEnd,
    productive: []bool,
    suffix_cache: std.AutoHashMapUnmanaged(SuffixKey, std.ArrayList(CodepointRange)) = .empty,

    const SuffixKey = struct { state: i32, remaining: i32 };

    const LEADING_MIN = [4]i32{ 0, 0xc2, 0xe0, 0xf0 };
    const LEADING_MAX = [4]i32{ 0, 0xdf, 0xef, 0xf4 };
    const CODEPOINT_MIN = [4]i32{ 0, 0x80, 0x800, 0x10000 };
    const CODEPOINT_MAX = [4]i32{ 0, 0x7ff, 0xffff, 0x10ffff };

    /// Analyzes `fsm`, whose edges must all be byte ranges.
    pub fn init(gpa: Allocator, fsm: *const FsmWithStartEnd) Allocator.Error!Utf8RangeCollapser {
        const num_states: usize = @intCast(fsm.numStates());
        const predecessors = try gpa.alloc(std.ArrayList(i32), num_states);
        for (predecessors) |*list| list.* = .empty;
        defer {
            for (predecessors) |*list| list.deinit(gpa);
            gpa.free(predecessors);
        }

        var state: i32 = 0;
        while (state < fsm.numStates()) : (state += 1) {
            for (fsm.getFsm().stateEdges(state)) |edge| {
                try predecessors[@intCast(edge.target)].append(gpa, state);
            }
        }

        const productive = try gpa.alloc(bool, num_states);
        errdefer gpa.free(productive);
        @memset(productive, false);

        var worklist: std.ArrayList(i32) = .empty;
        defer worklist.deinit(gpa);
        var scan: i32 = 0;
        while (scan < fsm.numStates()) : (scan += 1) {
            if (fsm.isEndState(scan)) try worklist.append(gpa, scan);
        }
        for (worklist.items) |s| productive[@intCast(s)] = true;
        var index: usize = 0;
        while (index < worklist.items.len) : (index += 1) {
            for (predecessors[@intCast(worklist.items[index])].items) |s| {
                if (!productive[@intCast(s)]) {
                    productive[@intCast(s)] = true;
                    try worklist.append(gpa, s);
                }
            }
        }

        return .{
            .gpa = gpa,
            .fsm = fsm,
            .productive = productive,
        };
    }

    pub fn deinit(self: *Utf8RangeCollapser) void {
        self.gpa.free(self.productive);
        var it = self.suffix_cache.valueIterator();
        while (it.next()) |list| list.deinit(self.gpa);
        self.suffix_cache.deinit(self.gpa);
    }

    /// Whether an accepting state is reachable from `state`.
    pub fn isProductive(self: *const Utf8RangeCollapser, state: i32) bool {
        return self.productive[@intCast(state)];
    }

    /// The merged `(target, min, max)` codepoint transitions out of `state`, sorted by
    /// target. The returned list is owned by the caller (allocated from `self.gpa`).
    pub fn stateRanges(self: *Utf8RangeCollapser, state: i32) Allocator.Error!std.ArrayList(CodepointRange) {
        var ranges: std.ArrayList(CodepointRange) = .empty;
        defer ranges.deinit(self.gpa);
        for (self.fsm.getFsm().stateEdges(state)) |edge| {
            if (!self.productive[@intCast(edge.target)]) {
                continue;
            }
            if (edge.min < 128) {
                try ranges.append(self.gpa, .{ edge.target, edge.min, @min(edge.max, 127) });
            }
            var remaining: usize = 1;
            while (remaining <= 3) : (remaining += 1) {
                const min = @max(edge.min, LEADING_MIN[remaining]);
                const max = @min(edge.max, LEADING_MAX[remaining]);
                if (min > max) {
                    continue;
                }
                const mask: i32 = @intCast((@as(u32, 1) << @intCast(6 - remaining)) - 1);
                var unicode_ranges: std.ArrayList(CodepointRange) = .empty;
                defer unicode_ranges.deinit(self.gpa);
                var suffix = try self.suffixRanges(edge.target, @intCast(remaining));
                defer suffix.deinit(self.gpa);
                for (suffix.items) |r| {
                    try appendRange(
                        self.gpa,
                        &unicode_ranges,
                        min & mask,
                        max & mask,
                        6 * @as(i32, @intCast(remaining)),
                        r,
                    );
                }
                // The byte automaton can contain non-canonical UTF-8 paths. Never turn an
                // overlong encoding into a second transition for an ASCII character
                // (bypassing exclusions).
                for (unicode_ranges.items) |r| {
                    const min_cp = @max(r[1], CODEPOINT_MIN[remaining]);
                    const max_cp = @min(r[2], CODEPOINT_MAX[remaining]);
                    if (min_cp <= max_cp) {
                        try ranges.append(self.gpa, .{ r[0], min_cp, max_cp });
                    }
                }
            }
        }
        return merge(self.gpa, ranges.items);
    }

    /// The codepoint suffixes of `remaining` continuation bytes starting at `state`.
    fn suffixRanges(self: *Utf8RangeCollapser, state: i32, remaining: i32) Allocator.Error!std.ArrayList(CodepointRange) {
        if (self.suffix_cache.get(.{ .state = state, .remaining = remaining })) |cached| {
            return cloneRanges(self.gpa, cached);
        }
        var ranges: std.ArrayList(CodepointRange) = .empty;
        defer ranges.deinit(self.gpa);
        if (remaining == 0) {
            try ranges.append(self.gpa, .{ state, 0, 0 });
        } else {
            for (self.fsm.getFsm().stateEdges(state)) |edge| {
                if (!self.productive[@intCast(edge.target)]) {
                    continue;
                }
                const min = @max(edge.min, 0x80);
                const max = @min(edge.max, 0xbf);
                if (min > max) {
                    continue;
                }
                var suffix = try self.suffixRanges(edge.target, remaining - 1);
                defer suffix.deinit(self.gpa);
                for (suffix.items) |r| {
                    try appendRange(self.gpa, &ranges, min & 0x3f, max & 0x3f, 6 * (remaining - 1), r);
                }
            }
        }
        var merged = try merge(self.gpa, ranges.items);
        errdefer merged.deinit(self.gpa);
        var cached_copy = try cloneRanges(self.gpa, merged);
        errdefer cached_copy.deinit(self.gpa);
        try self.suffix_cache.put(self.gpa, .{ .state = state, .remaining = remaining }, cached_copy);
        return merged;
    }

    /// Sorts `items` in place and returns merged adjacent or overlapping ranges per target.
    fn merge(gpa: Allocator, items: []CodepointRange) Allocator.Error!std.ArrayList(CodepointRange) {
        std.mem.sort(CodepointRange, items, {}, struct {
            fn lessThan(_: void, a: CodepointRange, b: CodepointRange) bool {
                if (a[0] != b[0]) return a[0] < b[0];
                if (a[1] != b[1]) return a[1] < b[1];
                return a[2] < b[2];
            }
        }.lessThan);
        var merged: std.ArrayList(CodepointRange) = .empty;
        errdefer merged.deinit(gpa);
        for (items) |r| {
            if (merged.items.len > 0) {
                const last = &merged.items[merged.items.len - 1];
                if (last[0] == r[0] and r[1] <= last[2] + 1) {
                    last[2] = @max(last[2], r[2]);
                    continue;
                }
            }
            try merged.append(gpa, r);
        }
        return merged;
    }

    /// Prefixes the suffix range with every leading value in `[min, max]`, shifted by
    /// `shift`.
    fn appendRange(
        gpa: Allocator,
        ranges: *std.ArrayList(CodepointRange),
        min: i32,
        max: i32,
        shift: i32,
        suffix: CodepointRange,
    ) Allocator.Error!void {
        const target = suffix[0];
        const suffix_min = suffix[1];
        const suffix_max = suffix[2];
        if (suffix_min == 0 and suffix_max == (@as(i32, 1) << @intCast(shift)) - 1) {
            try ranges.append(gpa, .{ target, min << @intCast(shift), (max << @intCast(shift)) | suffix_max });
        } else {
            var prefix = min;
            while (prefix <= max) : (prefix += 1) {
                try ranges.append(gpa, .{ target, (prefix << @intCast(shift)) | suffix_min, (prefix << @intCast(shift)) | suffix_max });
            }
        }
    }
};

fn cloneRanges(gpa: Allocator, ranges: std.ArrayList(CodepointRange)) Allocator.Error!std.ArrayList(CodepointRange) {
    var out: std.ArrayList(CodepointRange) = .empty;
    try out.appendSlice(gpa, ranges.items);
    return out;
}

test "Utf8RangeCollapser collapses ASCII and multi-byte UTF-8 transitions with zero leaks" {
    const a = std.testing.allocator;
    const Fsm = fsm_mod.Fsm;
    // Build a small UTF-8 NFA accepting:
    // - 'a'..'c' (0->1)
    // - U+00E9 ('é', 0xC3 0xA9): 0->2->1
    // - dead branch 0->3 (non-productive)
    var fsm = try Fsm.init(a, 4);
    errdefer fsm.deinit();
    try fsm.addEdge(0, 1, 'a', 'c');
    try fsm.addEdge(0, 2, 0xC3, 0xC3);
    try fsm.addEdge(2, 1, 0xA9, 0xA9);
    try fsm.addEdge(0, 3, 'z', 'z');

    var ends: std.ArrayList(i32) = .empty;
    errdefer ends.deinit(a);
    try ends.append(a, 1);

    var wse = FsmWithStartEnd.init(a, fsm, 0, ends, false);
    defer wse.deinit();

    var collapser = try Utf8RangeCollapser.init(a, &wse);
    defer collapser.deinit();

    try std.testing.expect(collapser.isProductive(0));
    try std.testing.expect(collapser.isProductive(1));
    try std.testing.expect(collapser.isProductive(2));
    try std.testing.expect(!collapser.isProductive(3));

    var ranges = try collapser.stateRanges(0);
    defer ranges.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), ranges.items.len);
    try std.testing.expectEqual(CodepointRange{ 1, 'a', 'c' }, ranges.items[0]);
    try std.testing.expectEqual(CodepointRange{ 1, 0xE9, 0xE9 }, ranges.items[1]);
}
