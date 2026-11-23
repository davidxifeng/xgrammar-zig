//! Collapses the UTF-8 byte paths of a byte automaton into codepoint transitions
//! (`utf8_range_collapser.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const fsm_mod = @import("../fsm/mod.zig");
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
    suffix_cache: std.AutoHashMap(SuffixKey, std.ArrayList(CodepointRange)),

    const SuffixKey = struct { state: i32, remaining: i32 };

    const LEADING_MIN = [4]i32{ 0, 0xc2, 0xe0, 0xf0 };
    const LEADING_MAX = [4]i32{ 0, 0xdf, 0xef, 0xf4 };
    const CODEPOINT_MIN = [4]i32{ 0, 0x80, 0x800, 0x10000 };
    const CODEPOINT_MAX = [4]i32{ 0, 0x7ff, 0xffff, 0x10ffff };

    /// Analyzes `fsm`, whose edges must all be byte ranges.
    pub fn init(gpa: Allocator, fsm: *const FsmWithStartEnd) Allocator.Error!Utf8RangeCollapser {
        const num_states: usize = @intCast(fsm.num_states());
        var predecessors = try gpa.alloc(std.ArrayList(i32), num_states);
        for (predecessors) |*list| list.* = .empty;
        var state: i32 = 0;
        while (state < fsm.num_states()) : (state += 1) {
            for (fsm.get_fsm().state_edges(state)) |edge| {
                try predecessors[@intCast(edge.target)].append(gpa, state);
            }
        }
        defer {
            for (predecessors) |*list| list.deinit(gpa);
            gpa.free(predecessors);
        }
        const productive = try gpa.alloc(bool, num_states);
        @memset(productive, false);
        var worklist: std.ArrayList(i32) = .empty;
        var scan: i32 = 0;
        while (scan < fsm.num_states()) : (scan += 1) {
            if (fsm.is_end_state(scan)) try worklist.append(gpa, scan);
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
        worklist.deinit(gpa);
        return .{
            .gpa = gpa,
            .fsm = fsm,
            .productive = productive,
            .suffix_cache = std.AutoHashMap(SuffixKey, std.ArrayList(CodepointRange)).init(gpa),
        };
    }

    pub fn deinit(self: *Utf8RangeCollapser) void {
        self.gpa.free(self.productive);
        var it = self.suffix_cache.valueIterator();
        while (it.next()) |list| list.deinit(self.gpa);
        self.suffix_cache.deinit();
    }

    /// Whether an accepting state is reachable from `state`.
    pub fn is_productive(self: *const Utf8RangeCollapser, state: i32) bool {
        return self.productive[@intCast(state)];
    }

    /// The merged `(target, min, max)` codepoint transitions out of `state`, sorted by
    /// target. The returned list is owned by the caller (allocated from `self.gpa`).
    pub fn state_ranges(self: *Utf8RangeCollapser, state: i32) Allocator.Error!std.ArrayList(CodepointRange) {
        var ranges: std.ArrayList(CodepointRange) = .empty;
        errdefer ranges.deinit(self.gpa);
        for (self.fsm.get_fsm().state_edges(state)) |edge| {
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
                var suffix = try self.suffix_ranges(edge.target, @intCast(remaining));
                defer suffix.deinit(self.gpa);
                for (suffix.items) |r| {
                    try append_range(
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
        return merge(self.gpa, ranges);
    }

    /// The codepoint suffixes of `remaining` continuation bytes starting at `state`.
    fn suffix_ranges(self: *Utf8RangeCollapser, state: i32, remaining: i32) Allocator.Error!std.ArrayList(CodepointRange) {
        if (self.suffix_cache.get(.{ .state = state, .remaining = remaining })) |cached| {
            return clone_ranges(self.gpa, cached);
        }
        var ranges: std.ArrayList(CodepointRange) = .empty;
        errdefer ranges.deinit(self.gpa);
        if (remaining == 0) {
            try ranges.append(self.gpa, .{ state, 0, 0 });
        } else {
            for (self.fsm.get_fsm().state_edges(state)) |edge| {
                if (!self.productive[@intCast(edge.target)]) {
                    continue;
                }
                const min = @max(edge.min, 0x80);
                const max = @min(edge.max, 0xbf);
                if (min > max) {
                    continue;
                }
                var suffix = try self.suffix_ranges(edge.target, remaining - 1);
                defer suffix.deinit(self.gpa);
                for (suffix.items) |r| {
                    try append_range(self.gpa, &ranges, min & 0x3f, max & 0x3f, 6 * (remaining - 1), r);
                }
            }
        }
        var merged = try merge(self.gpa, ranges);
        errdefer merged.deinit(self.gpa);
        try self.suffix_cache.put(.{ .state = state, .remaining = remaining }, try clone_ranges(self.gpa, merged));
        return merged;
    }

    /// Sorts the ranges and merges adjacent or overlapping ranges of the same target.
    /// Consumes `ranges` (ownership transfers to the result or back to the caller on the
    /// error path).
    fn merge(gpa: Allocator, ranges_in: std.ArrayList(CodepointRange)) Allocator.Error!std.ArrayList(CodepointRange) {
        var ranges = ranges_in;
        const items = ranges.items;
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
        ranges.deinit(gpa);
        return merged;
    }

    /// Prefixes the suffix range with every leading value in `[min, max]`, shifted by
    /// `shift`.
    fn append_range(
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

fn clone_ranges(gpa: Allocator, ranges: std.ArrayList(CodepointRange)) Allocator.Error!std.ArrayList(CodepointRange) {
    var out: std.ArrayList(CodepointRange) = .empty;
    try out.appendSlice(gpa, ranges.items);
    return out;
}
