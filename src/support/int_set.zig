//! Sorted integer-set operations.
//!
//! All inputs are assumed to be **sorted and duplicate-free**. Intersection and
//! difference mutate the left operand in place (reusing its allocation); union rebuilds
//! it via an O(n+m) merge.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

/// Replaces `lhs` with the sorted union `lhs ∪ rhs`.
pub fn intset_union(allocator: Allocator, lhs: *ArrayList(i32), rhs: []const i32) Allocator.Error!void {
    var merged: ArrayList(i32) = .empty;
    errdefer merged.deinit(allocator);
    try merged.ensureTotalCapacity(allocator, lhs.items.len + rhs.len);
    var i: usize = 0;
    var j: usize = 0;
    while (i < lhs.items.len and j < rhs.len) {
        if (lhs.items[i] < rhs[j]) {
            try merged.append(allocator, lhs.items[i]);
            i += 1;
        } else if (lhs.items[i] > rhs[j]) {
            try merged.append(allocator, rhs[j]);
            j += 1;
        } else {
            try merged.append(allocator, lhs.items[i]);
            i += 1;
            j += 1;
        }
    }
    try merged.appendSlice(allocator, lhs.items[i..]);
    try merged.appendSlice(allocator, rhs[j..]);
    lhs.deinit(allocator);
    lhs.* = merged;
}

/// Replaces `lhs` with the sorted intersection `lhs ∩ rhs`, in place.
///
/// As a special case, `lhs == [-1]` denotes the universal set, so the result is `rhs`.
pub fn intset_intersection(allocator: Allocator, lhs: *ArrayList(i32), rhs: []const i32) Allocator.Error!void {
    if (lhs.items.len == 1 and lhs.items[0] == -1) {
        lhs.clearRetainingCapacity();
        try lhs.appendSlice(allocator, rhs);
        return;
    }
    var write: usize = 0;
    var i: usize = 0;
    var j: usize = 0;
    while (i < lhs.items.len and j < rhs.len) {
        if (lhs.items[i] < rhs[j]) {
            i += 1;
        } else if (lhs.items[i] > rhs[j]) {
            j += 1;
        } else {
            lhs.items[write] = lhs.items[i];
            write += 1;
            i += 1;
            j += 1;
        }
    }
    lhs.shrinkRetainingCapacity(write);
}

/// Replaces `lhs` with the sorted difference `lhs − rhs`, in place.
pub fn intset_difference(lhs: *ArrayList(i32), rhs: []const i32) void {
    var write: usize = 0;
    var i: usize = 0;
    var j: usize = 0;
    while (i < lhs.items.len and j < rhs.len) {
        if (lhs.items[i] < rhs[j]) {
            lhs.items[write] = lhs.items[i];
            write += 1;
            i += 1;
        } else if (lhs.items[i] > rhs[j]) {
            j += 1;
        } else {
            i += 1;
            j += 1;
        }
    }
    while (i < lhs.items.len) {
        lhs.items[write] = lhs.items[i];
        write += 1;
        i += 1;
    }
    lhs.shrinkRetainingCapacity(write);
}

/// Returns `[0, n) − excluded`. `excluded` must be sorted with values in `[0, n)`.
pub fn intset_complement(allocator: Allocator, n: i32, excluded: []const i32) Allocator.Error!ArrayList(i32) {
    var result: ArrayList(i32) = .empty;
    errdefer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, @intCast(@max(0, n) -| excluded.len));
    var it: usize = 0;
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        if (it < excluded.len and excluded[it] == i) {
            it += 1;
        } else {
            try result.append(allocator, i);
        }
    }
    return result;
}

fn expectList(expected: []const i32, actual: *const ArrayList(i32)) !void {
    try std.testing.expectEqualSlices(i32, expected, actual.items);
}

test "intset_union" {
    const alloc = std.testing.allocator;
    var lhs = ArrayList(i32).empty;
    defer lhs.deinit(alloc);
    try lhs.appendSlice(alloc, &.{ 1, 3, 5 });
    try intset_union(alloc, &lhs, &.{ 3, 4, 6, 7 });
    try expectList(&.{ 1, 3, 4, 5, 6, 7 }, &lhs);

    // Historical mishandled case: `[3] ∪ [1, 3]`.
    var lhs2 = ArrayList(i32).empty;
    defer lhs2.deinit(alloc);
    try lhs2.appendSlice(alloc, &.{3});
    try intset_union(alloc, &lhs2, &.{ 1, 3 });
    try expectList(&.{ 1, 3 }, &lhs2);

    // Empty rhs / lhs.
    var lhs3 = ArrayList(i32).empty;
    defer lhs3.deinit(alloc);
    try lhs3.appendSlice(alloc, &.{2});
    try intset_union(alloc, &lhs3, &.{});
    try expectList(&.{2}, &lhs3);
    try intset_union(alloc, &lhs3, &.{ 0, 2, 9 });
    try expectList(&.{ 0, 2, 9 }, &lhs3);
}

test "intset_intersection" {
    const alloc = std.testing.allocator;
    var lhs = ArrayList(i32).empty;
    defer lhs.deinit(alloc);
    try lhs.appendSlice(alloc, &.{ 1, 3, 5, 7 });
    try intset_intersection(alloc, &lhs, &.{ 3, 7, 9 });
    try expectList(&.{ 3, 7 }, &lhs);

    // Universal set special case.
    var lhs2 = ArrayList(i32).empty;
    defer lhs2.deinit(alloc);
    try lhs2.appendSlice(alloc, &.{-1});
    try intset_intersection(alloc, &lhs2, &.{ 2, 4 });
    try expectList(&.{ 2, 4 }, &lhs2);

    // Empty result.
    var lhs3 = ArrayList(i32).empty;
    defer lhs3.deinit(alloc);
    try lhs3.appendSlice(alloc, &.{1});
    try intset_intersection(alloc, &lhs3, &.{2});
    try expectList(&.{}, &lhs3);
}

test "intset_difference" {
    const alloc = std.testing.allocator;
    var lhs = ArrayList(i32).empty;
    defer lhs.deinit(alloc);
    try lhs.appendSlice(alloc, &.{ 1, 3, 5, 7 });
    intset_difference(&lhs, &.{ 3, 8 });
    try expectList(&.{ 1, 5, 7 }, &lhs);

    // rhs exhausted: remaining lhs elements are kept.
    var lhs2 = ArrayList(i32).empty;
    defer lhs2.deinit(alloc);
    try lhs2.appendSlice(alloc, &.{ 0, 1, 2 });
    intset_difference(&lhs2, &.{0});
    try expectList(&.{ 1, 2 }, &lhs2);

    // Full removal.
    var lhs3 = ArrayList(i32).empty;
    defer lhs3.deinit(alloc);
    try lhs3.appendSlice(alloc, &.{ 4, 5 });
    intset_difference(&lhs3, &.{ 4, 5 });
    try expectList(&.{}, &lhs3);
}

test "intset_complement" {
    const alloc = std.testing.allocator;
    var result = try intset_complement(alloc, 5, &.{ 1, 3 });
    defer result.deinit(alloc);
    try expectList(&.{ 0, 2, 4 }, &result);

    var result2 = try intset_complement(alloc, 3, &.{});
    defer result2.deinit(alloc);
    try expectList(&.{ 0, 1, 2 }, &result2);

    var result3 = try intset_complement(alloc, 2, &.{ 0, 1 });
    defer result3.deinit(alloc);
    try expectList(&.{}, &result3);
}
