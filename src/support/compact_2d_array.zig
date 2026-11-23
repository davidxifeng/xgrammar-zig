//! Compressed-sparse-row (CSR) 2D array.

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
    /// The final `indptr` entry did not equal `data.len()`.
    BadEnd,
};

/// A 2D array stored in Compressed Sparse Row (CSR) format: every row may have a
/// different length, and all rows live contiguously in one backing buffer.
///
/// Two parallel lists back it:
/// - `data` — all row elements, concatenated;
/// - `indptr` — the start offset of each row in `data`; its last element equals
///   `data.items.len`, so row `i` occupies `data[indptr[i]..indptr[i + 1]]`.
///
/// Rows are immutable once inserted (you can still mutate their elements in place via
/// `row_mut`).
pub fn Compact2dArray(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,
        data: ArrayList(T),
        indptr: ArrayList(i32),

        /// Creates an empty array (zero rows).
        pub fn init(allocator: Allocator) Allocator.Error!Self {
            var indptr: ArrayList(i32) = .empty;
            try indptr.append(allocator, 0);
            return .{ .allocator = allocator, .data = .empty, .indptr = indptr };
        }

        /// Releases all memory.
        pub fn deinit(self: *Self) void {
            self.data.deinit(self.allocator);
            self.indptr.deinit(self.allocator);
            self.* = undefined;
        }

        /// Builds an array directly from a CSR representation (copies both inputs),
        /// validating the invariants.
        pub fn init_from_data_and_indptr(allocator: Allocator, data: []const T, indptr: []const i32) (Compact2dArrayError || Allocator.Error)!Self {
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
            return .{ .allocator = allocator, .data = data_list, .indptr = indptr_list };
        }

        /// Number of rows.
        pub fn len(self: *const Self) usize {
            return self.indptr.items.len - 1;
        }

        /// Whether there are zero rows.
        pub fn is_empty(self: *const Self) bool {
            return self.len() == 0;
        }

        /// Total number of elements across all rows.
        pub fn data_len(self: *const Self) usize {
            return self.data.items.len;
        }

        /// Returns row `i` as a slice, or `null` if out of bounds.
        pub fn get(self: *const Self, i: usize) ?[]const T {
            if (i >= self.len()) return null;
            const r = self.row_range(i);
            return self.data.items[r.start..r.end];
        }

        /// The positions of row `i` within `data`. They stay valid while rows are
        /// appended, so a row can be walked by index while the array grows.
        ///
        /// Panics if `i` is out of bounds.
        pub fn row_range(self: *const Self, i: usize) struct { start: usize, end: usize } {
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
        pub fn row_mut(self: *Self, i: usize) []T {
            std.debug.assert(i < self.len());
            const r = self.row_range(i);
            return self.data.items[r.start..r.end];
        }

        /// Returns the last row. Panics if there are no rows.
        pub fn back(self: *const Self) []const T {
            std.debug.assert(!self.is_empty());
            return self.row(self.len() - 1);
        }

        /// Iterates over the rows as slices.
        ///
        /// Deviation note: Rust exposes an `impl Iterator`; in Zig the caller drives the
        /// loop via `len`/`row_range` (or uses this helper with an `anytype` visitor).
        pub fn iter(self: *const Self, context: anytype, comptime visit: fn (@TypeOf(context), []const T) anyerror!void) anyerror!void {
            var i: usize = 0;
            while (i < self.len()) : (i += 1) {
                try visit(context, self.row(i));
            }
        }

        /// The flat backing data buffer.
        pub fn data_slice(self: *const Self) []const T {
            return self.data.items;
        }

        /// The row-offset (index pointer) buffer.
        pub fn indptr_slice(self: *const Self) []const i32 {
            return self.indptr.items;
        }

        /// Removes the last `cnt` rows. Panics if `cnt` exceeds the number of rows.
        pub fn pop_back(self: *Self, cnt: usize) void {
            std.debug.assert(cnt <= self.len());
            self.indptr.shrinkRetainingCapacity(self.indptr.items.len - cnt);
            const new_data_len: usize = @intCast(self.indptr.items[self.indptr.items.len - 1]);
            self.data.shrinkRetainingCapacity(new_data_len);
        }

        /// Builds an array from per-row sizes, with every element set to `default`.
        pub fn init_from_row_sizes(allocator: Allocator, row_sizes: []const i32, default: T) Allocator.Error!Self {
            var out = try Self.init(allocator);
            errdefer out.deinit();
            try out.reset_with_row_sizes(row_sizes, default);
            return out;
        }

        /// Resets the array to `row_sizes.len` rows of `default`-valued elements.
        ///
        /// Panics if any row size is negative, or if the total size exceeds the `i32` limit.
        pub fn reset_with_row_sizes(self: *Self, row_sizes: []const i32, default: T) Allocator.Error!void {
            self.indptr.clearRetainingCapacity();
            try self.indptr.ensureTotalCapacity(self.allocator, row_sizes.len + 1);
            self.indptr.appendAssumeCapacity(0);
            var acc: i32 = 0;
            for (row_sizes) |size| {
                std.debug.assert(size >= 0);
                std.debug.assert(size <= std.math.maxInt(i32) - acc);
                acc += size;
                self.indptr.appendAssumeCapacity(acc);
            }
            self.data.clearRetainingCapacity();
            try self.data.ensureTotalCapacity(self.allocator, @intCast(acc));
            self.data.items.len += @intCast(acc);
            @memset(self.data.items, default);
        }

        /// Appends a new row, returning its index.
        ///
        /// Panics (via the limit guard) if the total size would exceed the `i32` limit.
        pub fn push_row(self: *Self, new_data: []const T) Allocator.Error!usize {
            self.check_can_append_data(new_data.len);
            try self.data.appendSlice(self.allocator, new_data);
            try self.indptr.append(self.allocator, @intCast(self.data.items.len));
            return self.indptr.items.len - 2;
        }

        /// Appends a new row consisting of one leading element followed by `rest`.
        ///
        /// Mirrors the C++ `PushBackNonContiguous`, used by the grammar-expression encoding.
        pub fn push_row_noncontiguous(self: *Self, first: T, rest: []const T) Allocator.Error!usize {
            self.check_can_append_data(rest.len + 1);
            try self.data.append(self.allocator, first);
            try self.data.appendSlice(self.allocator, rest);
            try self.indptr.append(self.allocator, @intCast(self.data.items.len));
            return self.indptr.items.len - 2;
        }

        /// Appends one element to the most recently inserted row.
        ///
        /// Panics if the array has no rows yet, or (via the limit guard) if the total
        /// size would exceed the `i32` limit.
        pub fn push_in_latest_row(self: *Self, new_data: T) Allocator.Error!void {
            std.debug.assert(!self.is_empty());
            self.check_can_append_data(1);
            try self.data.append(self.allocator, new_data);
            self.indptr.items[self.indptr.items.len - 1] += 1;
        }

        /// Guards the `i32` row offsets before appending `additional` elements, so a
        /// pathological grammar fails loudly instead of wrapping the offsets.
        fn check_can_append_data(self: *const Self, additional: usize) void {
            std.debug.assert(additional <= @as(usize, std.math.maxInt(i32)) - self.data.items.len);
        }
    };
}

/// Serializes in the C++ reflection form `{"data_":[...],"indptr_":[...]}` —
/// only defined for `Compact2dArray(i32)` like the Rust impl.
pub fn serialize_json_value(self: *const Compact2dArray(i32), allocator: Allocator) Allocator.Error!std.json.Value {
    var obj = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer obj.deinit(allocator);
    var data = std.json.Array.init(allocator);
    errdefer data.deinit();
    var indptr = std.json.Array.init(allocator);
    errdefer indptr.deinit();
    for (self.data.items) |v| try data.append(.{ .integer = v });
    for (self.indptr.items) |v| try indptr.append(.{ .integer = v });
    try obj.put(allocator, "data_", .{ .array = data });
    try obj.put(allocator, "indptr_", .{ .array = indptr });
    return .{ .object = obj };
}

/// Deserializes the C++ reflection form. On a shape error returns `error.InvalidJson`
/// (the Rust version returns a message string).
pub fn deserialize_json_value(allocator: Allocator, value: std.json.Value) (Compact2dArrayError || Allocator.Error || error{InvalidJson})!Compact2dArray(i32) {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidJson, // "compact 2d array expects a JSON object"
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
    return Compact2dArray(i32).init_from_data_and_indptr(allocator, data, indptr);
}

test "compact 2d array push and access" {
    const alloc = std.testing.allocator;
    var arr = try Compact2dArray(i32).init(alloc);
    defer arr.deinit();
    try std.testing.expect(arr.is_empty());
    try std.testing.expectEqual(@as(usize, 0), arr.len());
    try std.testing.expectEqual(@as(usize, 1), arr.indptr_slice().len);

    const row_index0 = try arr.push_row(&.{ 1, 2, 3 });
    const row_index1 = try arr.push_row(&.{ 4 });
    try std.testing.expectEqual(@as(usize, 0), row_index0);
    try std.testing.expectEqual(@as(usize, 1), row_index1);
    try std.testing.expectEqual(@as(usize, 2), arr.len());
    try std.testing.expectEqual(@as(usize, 4), arr.data_len());

    try std.testing.expectEqualSlices(i32, &.{ 1, 2, 3 }, arr.row(0));
    try std.testing.expectEqualSlices(i32, &.{4}, arr.row(1));
    try std.testing.expectEqualSlices(i32, &.{4}, arr.back());
    try std.testing.expect(arr.get(2) == null);
    try std.testing.expectEqual(@as(usize, 3), arr.row_range(1).start);
    try std.testing.expectEqual(@as(usize, 4), arr.row_range(1).end);

    // In-place mutation through row_mut.
    arr.row_mut(1)[0] = 40;
    try std.testing.expectEqualSlices(i32, &.{40}, arr.row(1));

    // push_in_latest_row extends the last row.
    try arr.push_in_latest_row(41);
    try std.testing.expectEqualSlices(i32, &.{ 40, 41 }, arr.row(1));
    try std.testing.expectEqual(@as(usize, 5), arr.data_len());
}

test "compact 2d array noncontiguous and pop_back" {
    const alloc = std.testing.allocator;
    var arr = try Compact2dArray(i32).init(alloc);
    defer arr.deinit();
    const row_index0 = try arr.push_row_noncontiguous(9, &.{ 1, 2 });
    try std.testing.expectEqual(@as(usize, 0), row_index0);
    try std.testing.expectEqualSlices(i32, &.{ 9, 1, 2 }, arr.row(0));

    _ = try arr.push_row(&.{7});
    arr.pop_back(1);
    try std.testing.expectEqual(@as(usize, 1), arr.len());
    try std.testing.expectEqual(@as(usize, 3), arr.data_len());
    arr.pop_back(1);
    try std.testing.expect(arr.is_empty());
    try std.testing.expectEqual(@as(usize, 0), arr.data_len());
}

test "compact 2d array from_data_and_indptr validation" {
    const alloc = std.testing.allocator;
    // Valid.
    {
        var arr = try Compact2dArray(i32).init_from_data_and_indptr(alloc, &.{ 1, 2, 3 }, &.{ 0, 2, 3 });
        defer arr.deinit();
        try std.testing.expectEqual(@as(usize, 2), arr.len());
        try std.testing.expectEqualSlices(i32, &.{ 1, 2 }, arr.row(0));
        try std.testing.expectEqualSlices(i32, &.{3}, arr.row(1));
    }
    // Empty indptr.
    try std.testing.expectError(error.EmptyIndptr, Compact2dArray(i32).init_from_data_and_indptr(alloc, &.{}, &.{}));
    // Does not start with 0.
    try std.testing.expectError(error.NonZeroStart, Compact2dArray(i32).init_from_data_and_indptr(alloc, &.{ 1, 2 }, &.{ 1, 2 }));
    // Not non-decreasing.
    try std.testing.expectError(error.NotMonotonic, Compact2dArray(i32).init_from_data_and_indptr(alloc, &.{ 1, 2 }, &.{ 0, 2, 1 }));
    // Bad end.
    try std.testing.expectError(error.BadEnd, Compact2dArray(i32).init_from_data_and_indptr(alloc, &.{ 1, 2 }, &.{ 0, 3 }));
}

test "compact 2d array reset_with_row_sizes and iter" {
    const alloc = std.testing.allocator;
    var arr = try Compact2dArray(i32).init_from_row_sizes(alloc, &.{ 2, 0, 3 }, -1);
    defer arr.deinit();
    try std.testing.expectEqual(@as(usize, 3), arr.len());
    try std.testing.expectEqual(@as(usize, 5), arr.data_len());
    try std.testing.expectEqualSlices(i32, &.{ -1, -1 }, arr.row(0));
    try std.testing.expectEqualSlices(i32, &.{}, arr.row(1));
    try std.testing.expectEqualSlices(i32, &.{ -1, -1, -1 }, arr.row(2));

    const Counter = struct {
        total: i32 = 0,
        rows: usize = 0,
        fn visit(self: *@This(), row: []const i32) anyerror!void {
            self.rows += 1;
            for (row) |v| self.total += v;
        }
    };
    var counter = Counter{};
    try arr.iter(&counter, Counter.visit);
    try std.testing.expectEqual(@as(usize, 3), counter.rows);
    try std.testing.expectEqual(@as(i32, -5), counter.total);

    // reset_with_row_sizes on an existing array.
    try arr.reset_with_row_sizes(&.{1}, 0);
    try std.testing.expectEqual(@as(usize, 1), arr.len());
    try std.testing.expectEqualSlices(i32, &.{0}, arr.row(0));
}

test "compact 2d array json round-trip" {
    const alloc = std.testing.allocator;
    var arr = try Compact2dArray(i32).init_from_data_and_indptr(alloc, &.{ 1, 2, 3 }, &.{ 0, 2, 3 });
    defer arr.deinit();

    // The Value owns nested ArrayLists; build and free it through an arena.
    var value_arena = std.heap.ArenaAllocator.init(alloc);
    defer value_arena.deinit();
    const value = try serialize_json_value(&arr, value_arena.allocator());
    var restored = try deserialize_json_value(alloc, value);
    defer restored.deinit();
    try std.testing.expectEqualSlices(i32, arr.data_slice(), restored.data_slice());
    try std.testing.expectEqualSlices(i32, arr.indptr_slice(), restored.indptr_slice());

    // Shape errors.
    try std.testing.expectError(error.InvalidJson, deserialize_json_value(alloc, .{ .integer = 1 }));
    var bad = try std.json.ObjectMap.init(alloc, &.{}, &.{});
    defer bad.deinit(alloc);
    var bad_arr = std.json.Array.init(alloc);
    defer bad_arr.deinit();
    try bad.put(alloc, "data_", .{ .array = bad_arr });
    try std.testing.expectError(error.InvalidJson, deserialize_json_value(alloc, .{ .object = bad }));
}
