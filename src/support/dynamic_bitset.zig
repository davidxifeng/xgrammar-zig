//! Unmanaged runtime-sized bitset over a `u32` word array.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Bits packed per backing word.
pub const BITS_PER_BLOCK: usize = 32;

/// An unmanaged bitset whose length is fixed at construction time.
///
/// Bits `0..size` are addressable; the final word may contain unused high padding bits
/// (e.g. after `setAll`). Queries respect `size` and never return padding indices.
pub const DynamicBitset = struct {
    size: usize = 0,
    data: []u32 = &.{},

    pub const JsonError = error{ InvalidJson, OutOfMemory };
    pub const empty: DynamicBitset = .{};

    /// Minimal `u32` buffer length needed to hold `element_size` bits.
    pub fn bufferSize(element_size: usize) usize {
        return std.math.divCeil(usize, element_size, BITS_PER_BLOCK) catch unreachable;
    }

    /// Creates a bitset of `size` bits, all cleared.
    pub fn init(allocator: Allocator, size: usize) Allocator.Error!DynamicBitset {
        const words = bufferSize(size);
        if (words == 0) return .{ .size = 0, .data = &.{} };
        const data = try allocator.alloc(u32, words);
        @memset(data, 0);
        return .{ .size = size, .data = data };
    }

    /// Releases the backing buffer.
    pub fn deinit(self: *DynamicBitset, allocator: Allocator) void {
        if (self.data.len > 0) allocator.free(self.data);
        self.* = .{};
    }

    /// Deep copy in `allocator`.
    pub fn dupe(self: *const DynamicBitset, allocator: Allocator) Allocator.Error!DynamicBitset {
        if (self.data.len == 0) return .{ .size = self.size, .data = &.{} };
        return .{ .size = self.size, .data = try allocator.dupe(u32, self.data) };
    }

    pub fn len(self: *const DynamicBitset) usize {
        return self.size;
    }

    pub fn isEmpty(self: *const DynamicBitset) bool {
        return self.size == 0;
    }

    pub fn asWords(self: *const DynamicBitset) []const u32 {
        return self.data;
    }

    pub fn get(self: *const DynamicBitset, index: usize) bool {
        std.debug.assert(index < self.size);
        return (self.data[index / BITS_PER_BLOCK] >> @intCast(index % BITS_PER_BLOCK)) & 1 == 1;
    }

    pub fn setAll(self: *DynamicBitset) void {
        @memset(self.data, std.math.maxInt(u32));
    }

    pub fn resetAll(self: *DynamicBitset) void {
        @memset(self.data, 0);
    }

    pub fn set(self: *DynamicBitset, index: usize, value: bool) void {
        std.debug.assert(index < self.size);
        const word = &self.data[index / BITS_PER_BLOCK];
        const mask = @as(u32, 1) << @intCast(index % BITS_PER_BLOCK);
        if (value) {
            word.* |= mask;
        } else {
            word.* &= ~mask;
        }
    }

    pub fn reset(self: *DynamicBitset, index: usize) void {
        self.set(index, false);
    }

    pub fn orAssign(self: *DynamicBitset, other: *const DynamicBitset) void {
        std.debug.assert(self.data.len <= other.data.len);
        for (self.data, other.data[0..self.data.len]) |*dst, src| {
            dst.* |= src;
        }
    }

    /// Index of the first set bit in `0..size`, or `null`.
    pub fn findFirstOne(self: *const DynamicBitset) ?usize {
        if (self.size == 0) return null;
        return self.doFindOneFrom(0);
    }

    /// Index of the first set bit strictly after `pos` in `0..size`, or `null`.
    pub fn findNextOne(self: *const DynamicBitset, pos: usize) ?usize {
        if (self.size == 0 or pos >= self.size - 1) return null;
        const pos1 = pos + 1;
        const blk = pos1 / BITS_PER_BLOCK;
        const ind: u5 = @intCast(pos1 % BITS_PER_BLOCK);
        const fore = self.data[blk] >> ind;
        const result = if (fore != 0)
            pos1 + @as(usize, @ctz(fore))
        else
            self.doFindOneFrom(blk + 1);
        return if (result) |r| (if (r < self.size) r else null) else null;
    }

    /// Index of the first cleared bit in `0..size`, or `null`.
    pub fn findFirstZero(self: *const DynamicBitset) ?usize {
        if (self.size == 0) return null;
        return self.doFindZeroFrom(0);
    }

    /// Index of the first cleared bit strictly after `pos` in `0..size`, or `null`.
    pub fn findNextZero(self: *const DynamicBitset, pos: usize) ?usize {
        if (self.size == 0 or pos >= self.size - 1) return null;
        const pos1 = pos + 1;
        const blk = pos1 / BITS_PER_BLOCK;
        const ind: u5 = @intCast(pos1 % BITS_PER_BLOCK);
        const fore = (~self.data[blk]) >> ind;
        const result = if (fore != 0)
            pos1 + @as(usize, @ctz(fore))
        else
            self.doFindZeroFrom(blk + 1);
        return if (result) |r| (if (r < self.size) r else null) else null;
    }

    pub fn count(self: *const DynamicBitset) usize {
        var total: usize = 0;
        for (self.data) |w| total += @popCount(w);
        return total;
    }

    pub fn all(self: *const DynamicBitset) bool {
        if (self.size == 0) return true;
        const last = self.data.len - 1;
        for (self.data[0..last]) |w| {
            if (w != std.math.maxInt(u32)) return false;
        }
        return (self.data[last] & self.lastBlockMask()) == self.lastBlockMask();
    }

    pub fn any(self: *const DynamicBitset) bool {
        if (self.size == 0) return false;
        const last = self.data.len - 1;
        for (self.data[0..last]) |w| {
            if (w != 0) return true;
        }
        return (self.data[last] & self.lastBlockMask()) != 0;
    }

    fn lastBlockMask(self: *const DynamicBitset) u32 {
        if (self.size % BITS_PER_BLOCK == 0) return std.math.maxInt(u32);
        const remaining: u5 = @intCast(self.size % BITS_PER_BLOCK);
        return (@as(u32, 1) << remaining) - 1;
    }

    fn doFindOneFrom(self: *const DynamicBitset, first_block: usize) ?usize {
        if (first_block >= self.data.len) return null;
        var pos: ?usize = null;
        for (self.data[first_block..], first_block..) |w, i| {
            if (w != 0) {
                pos = i;
                break;
            }
        }
        const p = pos orelse return null;
        const bit = p * BITS_PER_BLOCK + @as(usize, @ctz(self.data[p]));
        return if (bit < self.size) bit else null;
    }

    fn doFindZeroFrom(self: *const DynamicBitset, first_block: usize) ?usize {
        if (first_block >= self.data.len) return null;
        var pos: ?usize = null;
        for (self.data[first_block..], first_block..) |w, i| {
            if (w != std.math.maxInt(u32)) {
                pos = i;
                break;
            }
        }
        const p = pos orelse return null;
        const bit = p * BITS_PER_BLOCK + @as(usize, @ctz(~self.data[p]));
        return if (bit < self.size) bit else null;
    }

    /// Streams in C++ JSON format: `[size, buffer_size, ...u32 words]`.
    pub fn writeJsonCpp(self: *const DynamicBitset, jw: *std.json.Stringify) std.json.Stringify.Error!void {
        try jw.beginArray();
        try jw.write(self.size);
        try jw.write(bufferSize(self.size));
        for (self.data) |word| {
            try jw.write(word);
        }
        try jw.endArray();
    }

    /// Deserializes the C++ JSON array format.
    pub fn deserializeJsonValueCpp(allocator: Allocator, value: std.json.Value) JsonError!DynamicBitset {
        const arr = switch (value) {
            .array => |a| a,
            else => return error.InvalidJson,
        };
        if (arr.items.len < 2) return error.InvalidJson;
        const size_i64 = switch (arr.items[0]) {
            .integer => |n| n,
            else => return error.InvalidJson,
        };
        if (size_i64 < 0) return error.InvalidJson;
        const size: usize = @intCast(size_i64);
        const buffer_size_i64 = switch (arr.items[1]) {
            .integer => |n| n,
            else => return error.InvalidJson,
        };
        if (buffer_size_i64 < 0) return error.InvalidJson;
        const buffer_size_v: usize = @intCast(buffer_size_i64);
        const expected = bufferSize(size);
        if (buffer_size_v != expected) return error.InvalidJson;
        if (arr.items.len != 2 + buffer_size_v) return error.InvalidJson;
        if (buffer_size_v == 0) return .{ .size = 0, .data = &.{} };
        const data = try allocator.alloc(u32, buffer_size_v);
        errdefer allocator.free(data);
        for (arr.items[2..], 0..) |item, i| {
            const word = switch (item) {
                .integer => |n| n,
                else => return error.InvalidJson,
            };
            if (word < 0 or word > std.math.maxInt(u32)) return error.InvalidJson;
            data[i] = @intCast(word);
        }
        return .{ .size = size, .data = data };
    }
};

test "dynamic bitset basic set/get/reset" {
    const alloc = std.testing.allocator;
    var bs = try DynamicBitset.init(alloc, 70);
    defer bs.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), bs.asWords().len);
    try std.testing.expectEqual(@as(usize, 70), bs.len());
    try std.testing.expect(!bs.isEmpty());

    try std.testing.expect(!bs.get(0));
    bs.set(0, true);
    bs.set(32, true);
    bs.set(69, true);
    try std.testing.expect(bs.get(0));
    try std.testing.expect(bs.get(32));
    try std.testing.expect(bs.get(69));
    try std.testing.expect(!bs.get(1));
    try std.testing.expectEqual(@as(usize, 3), bs.count());

    bs.reset(32);
    try std.testing.expect(!bs.get(32));
    try std.testing.expectEqual(@as(usize, 2), bs.count());

    bs.setAll();
    try std.testing.expectEqual(@as(usize, 96), bs.count());
    try std.testing.expect(bs.all());
    // Clear all valid bits in 0..70 while leaving padding bits set: findFirstOne must return null.
    for (0..70) |i| bs.reset(i);
    try std.testing.expect(bs.findFirstOne() == null);
    bs.resetAll();
    try std.testing.expectEqual(@as(usize, 0), bs.count());
    try std.testing.expect(!bs.any());
}

test "dynamic bitset find one/zero with padding" {
    const alloc = std.testing.allocator;
    var bs = try DynamicBitset.init(alloc, 33);
    defer bs.deinit(alloc);
    try std.testing.expect(bs.findFirstOne() == null);
    try std.testing.expect(bs.findFirstZero().? == 0);

    bs.set(5, true);
    try std.testing.expectEqual(@as(usize, 5), bs.findFirstOne().?);
    try std.testing.expectEqual(@as(usize, 0), bs.findFirstZero().?);
    try std.testing.expectEqual(@as(usize, 5), bs.findNextOne(0).?);
    try std.testing.expectEqual(@as(usize, 1), bs.findNextZero(0).?);

    bs.set(32, true);
    try std.testing.expectEqual(@as(usize, 5), bs.findFirstOne().?);
    try std.testing.expectEqual(@as(usize, 32), bs.findNextOne(6).?);
    try std.testing.expectEqual(@as(usize, 32), bs.findNextOne(5).?);
    try std.testing.expect(bs.findNextOne(32) == null);
    try std.testing.expect(bs.any());
    try std.testing.expect(!bs.all());
    try std.testing.expectEqual(@as(usize, 2), bs.count());
}

test "dynamic bitset orAssign and dupe" {
    const alloc = std.testing.allocator;
    var a = try DynamicBitset.init(alloc, 40);
    defer a.deinit(alloc);
    var b = try DynamicBitset.init(alloc, 40);
    defer b.deinit(alloc);
    a.set(3, true);
    b.set(39, true);
    a.orAssign(&b);
    try std.testing.expect(a.get(3));
    try std.testing.expect(a.get(39));
    try std.testing.expectEqual(@as(usize, 2), a.count());

    var c = try a.dupe(alloc);
    defer c.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), c.count());
    try std.testing.expectEqualSlices(u32, a.asWords(), c.asWords());
}

test "dynamic bitset empty" {
    const alloc = std.testing.allocator;
    var bs = try DynamicBitset.init(alloc, 0);
    defer bs.deinit(alloc);
    try std.testing.expect(bs.isEmpty());
    try std.testing.expect(bs.len() == 0);
    try std.testing.expect(bs.all());
    try std.testing.expect(!bs.any());
    try std.testing.expect(bs.findFirstOne() == null);
    try std.testing.expect(bs.findFirstZero() == null);
    try std.testing.expect(bs.findNextOne(0) == null);
    try std.testing.expect(bs.findNextZero(0) == null);
}

test "dynamic bitset json round-trip" {
    const alloc = std.testing.allocator;
    var bs = try DynamicBitset.init(alloc, 65);
    defer bs.deinit(alloc);
    bs.set(1, true);
    bs.set(64, true);

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    try bs.writeJsonCpp(&jw);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const val = try @import("json_parse.zig").parseJson(arena.allocator(), aw.written());
    var restored = try DynamicBitset.deserializeJsonValueCpp(alloc, val);
    defer restored.deinit(alloc);
    try std.testing.expectEqual(bs.size, restored.size);
    try std.testing.expectEqualSlices(u32, bs.asWords(), restored.asWords());
}
