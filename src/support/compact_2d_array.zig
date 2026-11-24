//! Compressed-sparse-row (CSR) 2D array (unmanaged; allocator passed on mutation/deinit).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

/// Error returned when a CSR representation fails its invariants.
pub const Compact2dArrayError = error{
    /// `indptr` was empty (it must contain at least the leading `0`).
    EmptyIndptr,
    /// `indptr` did not start with `0`.
    NonZeroStart,
    /// `indptr` was not non-decreasing.
    NotMonotonic,
    /// The final `indptr` entry did not equal `data.len`.
    BadEnd,
};

/// Unmanaged 2D array stored in Compressed Sparse Row (CSR) format.
///
/// Two parallel lists back it:
/// - `data` — all row elements, concatenated;
/// - `indptr` — the start offset of each row in `data`; its last element equals
///   `data.items.len`, so row `i` occupies `data[indptr[i]..indptr[i + 1]]`.
pub fn Compact2dArray(comptime T: type) type {
    return struct {
        const Self = @This();

        data: ArrayList(T) = .empty,
        indptr: ArrayList(i32) = .empty,

        pub const Iterator = struct {
            array: *const Self,
            index: usize = 0,

            pub fn next(it: *Iterator) ?[]const T {
                if (it.index >= it.array.len()) return null;
                const r = it.array.row(it.index);
                it.index += 1;
                return r;
            }
        };

        /// Creates an empty array (zero rows).
        pub fn init(allocator: Allocator) Allocator.Error!Self {
            var indptr: ArrayList(i32) = .empty;
            try indptr.append(allocator, 0);
            return .{ .data = .empty, .indptr = indptr };
        }

        /// Releases all memory.
        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.data.deinit(allocator);
            self.indptr.deinit(allocator);
            self.* = undefined;
        }

        /// Deep-copies `self` into `allocator`.
        pub fn dupe(self: *const Self, allocator: Allocator) Allocator.Error!Self {
            var data_copy: ArrayList(T) = .empty;
            errdefer data_copy.deinit(allocator);
            try data_copy.appendSlice(allocator, self.data.items);
            var indptr_copy: ArrayList(i32) = .empty;
            errdefer indptr_copy.deinit(allocator);
            try indptr_copy.appendSlice(allocator, self.indptr.items);
            return .{ .data = data_copy, .indptr = indptr_copy };
        }

        /// Builds an array directly from a CSR representation (copies both inputs),
        /// validating the invariants.
        pub fn initFromDataAndIndptr(
            allocator: Allocator,
            data: []const T,
            indptr: []const i32,
        ) (Compact2dArrayError || Allocator.Error)!Self {
            if (indptr.len == 0) return error.EmptyIndptr;
            if (indptr[0] != 0) return error.NonZeroStart;
            var k: usize = 0;
            while (k + 1 < indptr.len) : (k += 1) {
                if (indptr[k] > indptr[k + 1]) return error.NotMonotonic;
            }
            if (@as(usize, @intCast(indptr[indptr.len - 1])) != data.len) return error.BadEnd;
            var data_list: ArrayList(T) = .empty;
            errdefer data_list.deinit(allocator);
            try data_list.appendSlice(allocator, data);
            var indptr_list: ArrayList(i32) = .empty;
            errdefer indptr_list.deinit(allocator);
            try indptr_list.appendSlice(allocator, indptr);
            return .{ .data = data_list, .indptr = indptr_list };
        }

        /// Builds an array from per-row sizes, with every element set to `default`.
        pub fn initFromRowSizes(allocator: Allocator, row_sizes: []const i32, default: T) Allocator.Error!Self {
            var out = try Self.init(allocator);
            errdefer out.deinit(allocator);
            try out.resetWithRowSizes(allocator, row_sizes, default);
            return out;
        }

        /// Number of rows.
        pub fn len(self: *const Self) usize {
            return if (self.indptr.items.len == 0) 0 else self.indptr.items.len - 1;
        }

        /// Whether there are zero rows.
        pub fn isEmpty(self: *const Self) bool {
            return self.len() == 0;
        }

        /// Total number of elements across all rows.
        pub fn dataLen(self: *const Self) usize {
            return self.data.items.len;
        }

        /// Returns row `i` as a slice, or `null` if out of bounds.
        pub fn get(self: *const Self, i: usize) ?[]const T {
            if (i >= self.len()) return null;
            const r = self.rowRange(i);
            return self.data.items[r.start..r.end];
        }

        /// Positions of row `i` within `data`. Panics if `i` is out of bounds.
        pub fn rowRange(self: *const Self, i: usize) struct { start: usize, end: usize } {
            std.debug.assert(i < self.len());
            return .{
                .start = @intCast(self.indptr.items[i]),
                .end = @intCast(self.indptr.items[i + 1]),
            };
        }

        /// Returns row `i` as a slice. Panics if `i` is out of bounds.
        pub fn row(self: *const Self, i: usize) []const T {
            return self.get(i) orelse std.debug.panic("row index out of bounds", .{});
        }

        /// Returns row `i` as a mutable slice. Panics if `i` is out of bounds.
        pub fn rowMut(self: *Self, i: usize) []T {
            std.debug.assert(i < self.len());
            const r = self.rowRange(i);
            return self.data.items[r.start..r.end];
        }

        /// Returns the last row. Panics if there are no rows.
        pub fn back(self: *const Self) []const T {
            std.debug.assert(!self.isEmpty());
            return self.row(self.len() - 1);
        }

        /// Value iterator yielding each row as `[]const T`.
        pub fn iterator(self: *const Self) Iterator {
            return .{ .array = self };
        }

        /// The flat backing data buffer.
        pub fn dataSlice(self: *const Self) []const T {
            return self.data.items;
        }

        /// The row-offset (index pointer) buffer.
        pub fn indptrSlice(self: *const Self) []const i32 {
            return self.indptr.items;
        }

        /// Removes the last `cnt` rows. Panics if `cnt` exceeds the number of rows.
        pub fn popBack(self: *Self, cnt: usize) void {
            std.debug.assert(cnt <= self.len());
            self.indptr.shrinkRetainingCapacity(self.indptr.items.len - cnt);
            const new_data_len: usize = @intCast(self.indptr.items[self.indptr.items.len - 1]);
            self.data.shrinkRetainingCapacity(new_data_len);
        }

        /// Resets the array to `row_sizes.len` rows of `default`-valued elements.
        pub fn resetWithRowSizes(self: *Self, allocator: Allocator, row_sizes: []const i32, default: T) Allocator.Error!void {
            self.indptr.clearRetainingCapacity();
            try self.indptr.ensureTotalCapacity(allocator, row_sizes.len + 1);
            self.indptr.appendAssumeCapacity(0);
            var acc: i32 = 0;
            for (row_sizes) |size| {
                std.debug.assert(size >= 0);
                std.debug.assert(size <= std.math.maxInt(i32) - acc);
                acc += size;
                self.indptr.appendAssumeCapacity(acc);
            }
            self.data.clearRetainingCapacity();
            try self.data.ensureTotalCapacity(allocator, @intCast(acc));
            self.data.items.len += @intCast(acc);
            @memset(self.data.items, default);
        }

        /// Appends a new row, returning its index.
        pub fn pushRow(self: *Self, allocator: Allocator, new_data: []const T) Allocator.Error!usize {
            self.checkCanAppendData(new_data.len);
            try self.data.appendSlice(allocator, new_data);
            try self.indptr.append(allocator, @intCast(self.data.items.len));
            return self.indptr.items.len - 2;
        }

        /// Appends a new row consisting of one leading element followed by `rest`.
        pub fn pushRowNoncontiguous(self: *Self, allocator: Allocator, first: T, rest: []const T) Allocator.Error!usize {
            self.checkCanAppendData(rest.len + 1);
            try self.data.append(allocator, first);
            try self.data.appendSlice(allocator, rest);
            try self.indptr.append(allocator, @intCast(self.data.items.len));
            return self.indptr.items.len - 2;
        }

        /// Appends one element to the most recently inserted row.
        pub fn pushInLatestRow(self: *Self, allocator: Allocator, new_data: T) Allocator.Error!void {
            std.debug.assert(!self.isEmpty());
            self.checkCanAppendData(1);
            try self.data.append(allocator, new_data);
            self.indptr.items[self.indptr.items.len - 1] += 1;
        }

        fn checkCanAppendData(self: *const Self, additional: usize) void {
            std.debug.assert(additional <= @as(usize, std.math.maxInt(i32)) - self.data.items.len);
        }
    };
}

/// Streams `Compact2dArray(i32)` in C++ reflection form `{"data_":[...],"indptr_":[...]}`.
pub fn writeJson(self: *const Compact2dArray(i32), jw: *std.json.Stringify) std.json.Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("data_");
    try jw.beginArray();
    for (self.data.items) |v| try jw.write(v);
    try jw.endArray();
    try jw.objectField("indptr_");
    try jw.beginArray();
    for (self.indptr.items) |v| try jw.write(v);
    try jw.endArray();
    try jw.endObject();
}

/// Deserializes the C++ reflection form.
pub fn deserializeJsonValue(
    allocator: Allocator,
    value: std.json.Value,
) (Compact2dArrayError || Allocator.Error || error{InvalidJson})!Compact2dArray(i32) {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidJson,
    };
    const data_value = obj.get("data_") orelse return error.InvalidJson;
    const indptr_value = obj.get("indptr_") orelse return error.InvalidJson;
    const data_arr = switch (data_value) {
        .array => |a| a,
        else => return error.InvalidJson,
    };
    const indptr_arr = switch (indptr_value) {
        .array => |a| a,
        else => return error.InvalidJson,
    };
    var data = try allocator.alloc(i32, data_arr.items.len);
    defer allocator.free(data);
    for (data_arr.items, 0..) |item, i| {
        data[i] = switch (item) {
            .integer => |n| std.math.cast(i32, n) orelse return error.InvalidJson,
            else => return error.InvalidJson,
        };
    }
    var indptr = try allocator.alloc(i32, indptr_arr.items.len);
    defer allocator.free(indptr);
    for (indptr_arr.items, 0..) |item, i| {
        indptr[i] = switch (item) {
            .integer => |n| std.math.cast(i32, n) orelse return error.InvalidJson,
            else => return error.InvalidJson,
        };
    }
    return Compact2dArray(i32).initFromDataAndIndptr(allocator, data, indptr);
}

test "compact 2d array push and access" {
    const alloc = std.testing.allocator;
    var arr = try Compact2dArray(i32).init(alloc);
    defer arr.deinit(alloc);
    try std.testing.expect(arr.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), arr.len());
    try std.testing.expectEqual(@as(usize, 1), arr.indptrSlice().len);

    const row_index0 = try arr.pushRow(alloc, &.{ 1, 2, 3 });
    const row_index1 = try arr.pushRow(alloc, &.{4});
    try std.testing.expectEqual(@as(usize, 0), row_index0);
    try std.testing.expectEqual(@as(usize, 1), row_index1);
    try std.testing.expectEqual(@as(usize, 2), arr.len());
    try std.testing.expectEqual(@as(usize, 4), arr.dataLen());

    try std.testing.expectEqualSlices(i32, &.{ 1, 2, 3 }, arr.row(0));
    try std.testing.expectEqualSlices(i32, &.{4}, arr.row(1));
    try std.testing.expectEqualSlices(i32, &.{4}, arr.back());
    try std.testing.expect(arr.get(2) == null);
    try std.testing.expectEqual(@as(usize, 3), arr.rowRange(1).start);
    try std.testing.expectEqual(@as(usize, 4), arr.rowRange(1).end);

    arr.rowMut(1)[0] = 40;
    try std.testing.expectEqualSlices(i32, &.{40}, arr.row(1));

    try arr.pushInLatestRow(alloc, 41);
    try std.testing.expectEqualSlices(i32, &.{ 40, 41 }, arr.row(1));
    try std.testing.expectEqual(@as(usize, 5), arr.dataLen());
}

test "compact 2d array noncontiguous and popBack" {
    const alloc = std.testing.allocator;
    var arr = try Compact2dArray(i32).init(alloc);
    defer arr.deinit(alloc);
    const row_index0 = try arr.pushRowNoncontiguous(alloc, 9, &.{ 1, 2 });
    try std.testing.expectEqual(@as(usize, 0), row_index0);
    try std.testing.expectEqualSlices(i32, &.{ 9, 1, 2 }, arr.row(0));

    _ = try arr.pushRow(alloc, &.{7});
    arr.popBack(1);
    try std.testing.expectEqual(@as(usize, 1), arr.len());
    try std.testing.expectEqual(@as(usize, 3), arr.dataLen());
    arr.popBack(1);
    try std.testing.expect(arr.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), arr.dataLen());
}

test "compact 2d array initFromDataAndIndptr validation" {
    const alloc = std.testing.allocator;
    {
        var arr = try Compact2dArray(i32).initFromDataAndIndptr(alloc, &.{ 1, 2, 3 }, &.{ 0, 2, 3 });
        defer arr.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 2), arr.len());
        try std.testing.expectEqualSlices(i32, &.{ 1, 2 }, arr.row(0));
        try std.testing.expectEqualSlices(i32, &.{3}, arr.row(1));
    }
    try std.testing.expectError(error.EmptyIndptr, Compact2dArray(i32).initFromDataAndIndptr(alloc, &.{}, &.{}));
    try std.testing.expectError(error.NonZeroStart, Compact2dArray(i32).initFromDataAndIndptr(alloc, &.{ 1, 2 }, &.{ 1, 2 }));
    try std.testing.expectError(error.NotMonotonic, Compact2dArray(i32).initFromDataAndIndptr(alloc, &.{ 1, 2 }, &.{ 0, 2, 1 }));
    try std.testing.expectError(error.BadEnd, Compact2dArray(i32).initFromDataAndIndptr(alloc, &.{ 1, 2 }, &.{ 0, 3 }));
}

test "compact 2d array resetWithRowSizes and iterator" {
    const alloc = std.testing.allocator;
    var arr = try Compact2dArray(i32).initFromRowSizes(alloc, &.{ 2, 0, 3 }, -1);
    defer arr.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), arr.len());
    try std.testing.expectEqual(@as(usize, 5), arr.dataLen());
    try std.testing.expectEqualSlices(i32, &.{ -1, -1 }, arr.row(0));
    try std.testing.expectEqualSlices(i32, &.{}, arr.row(1));
    try std.testing.expectEqualSlices(i32, &.{ -1, -1, -1 }, arr.row(2));

    var total: i32 = 0;
    var rows: usize = 0;
    var it = arr.iterator();
    while (it.next()) |r| {
        rows += 1;
        for (r) |v| total += v;
    }
    try std.testing.expectEqual(@as(usize, 3), rows);
    try std.testing.expectEqual(@as(i32, -5), total);

    try arr.resetWithRowSizes(alloc, &.{1}, 0);
    try std.testing.expectEqual(@as(usize, 1), arr.len());
    try std.testing.expectEqualSlices(i32, &.{0}, arr.row(0));
}

test "compact 2d array json round-trip" {
    const alloc = std.testing.allocator;
    var arr = try Compact2dArray(i32).initFromDataAndIndptr(alloc, &.{ 1, 2, 3 }, &.{ 0, 2, 3 });
    defer arr.deinit(alloc);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    try writeJson(&arr, &jw);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const parsed = try @import("json_parse.zig").parseJson(arena.allocator(), aw.written());
    var restored = try deserializeJsonValue(alloc, parsed);
    defer restored.deinit(alloc);
    try std.testing.expectEqualSlices(i32, arr.dataSlice(), restored.dataSlice());
    try std.testing.expectEqualSlices(i32, arr.indptrSlice(), restored.indptrSlice());

    try std.testing.expectError(error.InvalidJson, deserializeJsonValue(alloc, .{ .integer = 1 }));
}
