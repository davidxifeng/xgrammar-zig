//! Sorted integer-set operations (inputs must be sorted and duplicate-free).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

/// Replaces `lhs` with the sorted union `lhs ∪ rhs`.
pub fn intsetUnion(allocator: Allocator, lhs: *ArrayList(i32), rhs: []const i32) Allocator.Error!void {
    var merged: ArrayList(i32) = .empty;
    errdefer merged.deinit(allocator);
    try merged.ensureTotalCapacity(allocator, lhs.items.len + rhs.len);
    var i: usize = 0;
    var j: usize = 0;
    while (i < lhs.items.len and j < rhs.len) {
        if (lhs.items[i] < rhs[j]) {
            merged.appendAssumeCapacity(lhs.items[i]);
            i += 1;
        } else if (lhs.items[i] > rhs[j]) {
            merged.appendAssumeCapacity(rhs[j]);
            j += 1;
        } else {
            merged.appendAssumeCapacity(lhs.items[i]);
            i += 1;
            j += 1;
        }
    }
    merged.appendSliceAssumeCapacity(lhs.items[i..]);
    merged.appendSliceAssumeCapacity(rhs[j..]);
    lhs.deinit(allocator);
    lhs.* = merged;
}

/// Replaces `lhs` with the sorted intersection `lhs ∩ rhs`, in place.
/// As a special case, `lhs == [-1]` denotes the universal set, so the result is `rhs`.
pub fn intsetIntersection(allocator: Allocator, lhs: *ArrayList(i32), rhs: []const i32) Allocator.Error!void {
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
pub fn intsetDifference(lhs: *ArrayList(i32), rhs: []const i32) void {
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
pub fn intsetComplement(allocator: Allocator, n: i32, excluded: []const i32) Allocator.Error!ArrayList(i32) {
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

test "intsetUnion" {
    const alloc = std.testing.allocator;
    var lhs = ArrayList(i32).empty;
    defer lhs.deinit(alloc);
    try lhs.appendSlice(alloc, &.{ 1, 3, 5 });
    try intsetUnion(alloc, &lhs, &.{ 3, 4, 6, 7 });
    try expectList(&.{ 1, 3, 4, 5, 6, 7 }, &lhs);

    var lhs2 = ArrayList(i32).empty;
    defer lhs2.deinit(alloc);
    try lhs2.appendSlice(alloc, &.{3});
    try intsetUnion(alloc, &lhs2, &.{ 1, 3 });
    try expectList(&.{ 1, 3 }, &lhs2);
}

test "intsetIntersection" {
    const alloc = std.testing.allocator;
    var lhs = ArrayList(i32).empty;
    defer lhs.deinit(alloc);
    try lhs.appendSlice(alloc, &.{ 1, 3, 5, 7 });
    try intsetIntersection(alloc, &lhs, &.{ 3, 7, 9 });
    try expectList(&.{ 3, 7 }, &lhs);

    var lhs2 = ArrayList(i32).empty;
    defer lhs2.deinit(alloc);
    try lhs2.appendSlice(alloc, &.{-1});
    try intsetIntersection(alloc, &lhs2, &.{ 2, 4 });
    try expectList(&.{ 2, 4 }, &lhs2);
}

test "intsetDifference" {
    const alloc = std.testing.allocator;
    var lhs = ArrayList(i32).empty;
    defer lhs.deinit(alloc);
    try lhs.appendSlice(alloc, &.{ 1, 3, 5, 7 });
    intsetDifference(&lhs, &.{ 3, 8 });
    try expectList(&.{ 1, 5, 7 }, &lhs);
}

test "intsetComplement" {
    const alloc = std.testing.allocator;
    var result = try intsetComplement(alloc, 5, &.{ 1, 3 });
    defer result.deinit(alloc);
    try expectList(&.{ 0, 2, 4 }, &result);
}
