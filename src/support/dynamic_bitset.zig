//! Runtime-sized bitset over a `u32` word array.
//!
//! This is the owned form; the matcher's external-buffer (DLTensor) view lands in M6.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Bits packed per backing word.
pub const BITS_PER_BLOCK: usize = 32;

/// A bitset whose length is fixed at construction time.
///
/// Bits `0..len` are addressable; the final word may contain unused high padding bits
/// (e.g. after `set_all`). Scans that could return a padding index are bounded by `len`.
pub const DynamicBitset = struct {
    allocator: Allocator,
    size: usize,
    data: []u32,

    /// Error set for the JSON round-trip helpers (Rust returns message strings).
    pub const JsonError = error{ InvalidJson, OutOfMemory };

    /// Minimal `u32` buffer length needed to hold `element_size` bits.
    pub fn buffer_size(element_size: usize) usize {
        return std.math.divCeil(usize, element_size, BITS_PER_BLOCK) catch unreachable;
    }

    /// Creates a bitset of `size` bits, all cleared.
    pub fn init(allocator: Allocator, size: usize) Allocator.Error!DynamicBitset {
        const data = try allocator.alloc(u32, buffer_size(size));
        @memset(data, 0);
        return .{ .allocator = allocator, .size = size, .data = data };
    }

    /// Releases the backing buffer.
    pub fn deinit(self: *DynamicBitset) void {
        self.allocator.free(self.data);
        self.* = undefined;
    }

    /// Deep copy in `allocator` (Rust `Clone`).
    pub fn clone(self: *const DynamicBitset, allocator: Allocator) Allocator.Error!DynamicBitset {
        const data = try allocator.dupe(u32, self.data);
        return .{ .allocator = allocator, .size = self.size, .data = data };
    }

    /// Number of addressable bits.
    pub fn len(self: *const DynamicBitset) usize {
        return self.size;
    }

    /// Whether the bitset holds zero bits.
    pub fn is_empty(self: *const DynamicBitset) bool {
        return self.size == 0;
    }

    /// The raw backing words.
    pub fn as_words(self: *const DynamicBitset) []const u32 {
        return self.data;
    }

    /// Returns the bit at `index`. Panics if `index >= len`.
    pub fn get(self: *const DynamicBitset, index: usize) bool {
        std.debug.assert(index < self.size);
        return (self.data[index / BITS_PER_BLOCK] >> @intCast(index % BITS_PER_BLOCK)) & 1 == 1;
    }

    /// Sets every bit (including padding bits in the final word) to `true`.
    pub fn set_all(self: *DynamicBitset) void {
        @memset(self.data, std.math.maxInt(u32));
    }

    /// Clears every bit.
    pub fn reset_all(self: *DynamicBitset) void {
        @memset(self.data, 0);
    }

    /// Sets the bit at `index` to `value`. Panics if `index >= len`.
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

    /// Clears the bit at `index`. Panics if `index >= len`.
    pub fn reset(self: *DynamicBitset, index: usize) void {
        self.set(index, false);
    }

    /// Bitwise-ORs `other` into `self`.
    ///
    /// Panics if `self`'s buffer is larger than `other`'s (mirrors the C++ contract that
    /// `self` must be no larger than `other`).
    pub fn or_assign(self: *DynamicBitset, other: *const DynamicBitset) void {
        std.debug.assert(self.data.len <= other.data.len);
        for (self.data, other.data) |*dst, src| {
            dst.* |= src;
        }
    }

    /// Index of the first set bit, or `null`.
    pub fn find_first_one(self: *const DynamicBitset) ?usize {
        return self.do_find_one_from(0);
    }

    /// Index of the first set bit strictly after `pos`, or `null`.
    pub fn find_next_one(self: *const DynamicBitset, pos: usize) ?usize {
        if (self.size == 0 or pos >= self.size - 1) return null;
        const pos1 = pos + 1;
        const blk = pos1 / BITS_PER_BLOCK;
        const ind: u5 = @intCast(pos1 % BITS_PER_BLOCK);
        const fore = self.data[blk] >> ind;
        const result = if (fore != 0)
            pos1 + @as(usize, @ctz(fore))
        else
            self.do_find_one_from(blk + 1);
        if (result) |r| {
            if (r < self.size) return r;
        }
        return null;
    }

    /// Index of the first cleared bit, or `null`.
    pub fn find_first_zero(self: *const DynamicBitset) ?usize {
        return self.do_find_zero_from(0);
    }

    /// Index of the first cleared bit strictly after `pos`, or `null`.
    pub fn find_next_zero(self: *const DynamicBitset, pos: usize) ?usize {
        if (self.size == 0 or pos >= self.size - 1) return null;
        const pos1 = pos + 1;
        const blk = pos1 / BITS_PER_BLOCK;
        const ind: u5 = @intCast(pos1 % BITS_PER_BLOCK);
        const fore = (~self.data[blk]) >> ind;
        const result = if (fore != 0)
            pos1 + @as(usize, @ctz(fore))
        else
            self.do_find_zero_from(blk + 1);
        if (result) |r| {
            if (r < self.size) return r;
        }
        return null;
    }

    /// Number of set bits across the whole backing buffer (including any padding bits).
    pub fn count(self: *const DynamicBitset) usize {
        var total: usize = 0;
        for (self.data) |w| total += @popCount(w);
        return total;
    }

    /// Whether every addressable bit is set.
    pub fn all(self: *const DynamicBitset) bool {
        if (self.size == 0) return true;
        const last = self.data.len - 1;
        for (self.data[0..last]) |w| {
            if (w != std.math.maxInt(u32)) return false;
        }
        return (self.data[last] & self.last_block_mask()) == self.last_block_mask();
    }

    /// Whether any addressable bit is set (padding bits in the final word are ignored).
    pub fn any(self: *const DynamicBitset) bool {
        if (self.size == 0) return false;
        const last = self.data.len - 1;
        for (self.data[0..last]) |w| {
            if (w != 0) return true;
        }
        return (self.data[last] & self.last_block_mask()) != 0;
    }

    /// The mask of the addressable bits in the final word.
    fn last_block_mask(self: *const DynamicBitset) u32 {
        if (self.size % BITS_PER_BLOCK == 0) return std.math.maxInt(u32);
        const remaining: u5 = @intCast(self.size % BITS_PER_BLOCK);
        return (@as(u32, 1) << remaining) - 1;
    }

    fn do_find_one_from(self: *const DynamicBitset, first_block: usize) ?usize {
        var pos: ?usize = null;
        for (self.data[first_block..], first_block..) |w, i| {
            if (w != 0) {
                pos = i;
                break;
            }
        }
        const p = pos orelse return null;
        return p * BITS_PER_BLOCK + @as(usize, @ctz(self.data[p]));
    }

    fn do_find_zero_from(self: *const DynamicBitset, first_block: usize) ?usize {
        var pos: ?usize = null;
        for (self.data[first_block..], first_block..) |w, i| {
            if (w != std.math.maxInt(u32)) {
                pos = i;
                break;
            }
        }
        const p = pos orelse return null;
        return p * BITS_PER_BLOCK + @as(usize, @ctz(~self.data[p]));
    }

    /// Serializes in the C++ JSON format: `[size, buffer_size, ...u32 words]`.
    pub fn serialize_json_value_cpp(self: *const DynamicBitset, allocator: Allocator) Allocator.Error!std.json.Value {
        var arr = std.json.Array.init(allocator);
        errdefer arr.deinit();
        try arr.append(.{ .integer = @intCast(self.size) });
        try arr.append(.{ .integer = @intCast(buffer_size(self.size)) });
        for (self.data) |word| {
            try arr.append(.{ .integer = @intCast(word) });
        }
        return .{ .array = arr };
    }

    /// Deserializes the C++ JSON array format. On a shape error returns
    /// `error.InvalidJson` (the Rust version returns a message string).
    pub fn deserialize_json_value_cpp(allocator: Allocator, value: std.json.Value) JsonError!DynamicBitset {
        const arr = switch (value) {
            .array => |a| a,
            else => return error.InvalidJson, // "dynamic bitset expects a JSON array"
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
        const expected = buffer_size(size);
        if (buffer_size_v != expected) return error.InvalidJson;
        if (arr.items.len != 2 + buffer_size_v) return error.InvalidJson;
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
        return .{ .allocator = allocator, .size = size, .data = data };
    }
};

test "dynamic bitset basic set/get/reset" {
    var bs = try DynamicBitset.init(std.testing.allocator, 70);
    defer bs.deinit();
    try std.testing.expectEqual(@as(usize, 3), bs.as_words().len);
    try std.testing.expectEqual(@as(usize, 70), bs.len());
    try std.testing.expect(!bs.is_empty());

    try std.testing.expect(!bs.get(0));
    bs.set(0, true);
    bs.set(32, true);
    bs.set(69, true);
    try std.testing.expect(bs.get(0));
    try std.testing.expect(bs.get(32));
    try std.testing.expect(bs.get(69));
    try std.testing.expect(!bs.get(1));
    try std.testing.expectEqual(@as(usize, 3), bs.count()); // includes padding? padding is 0 here

    bs.reset(32);
    try std.testing.expect(!bs.get(32));
    try std.testing.expectEqual(@as(usize, 2), bs.count());

    bs.set_all();
    try std.testing.expectEqual(@as(usize, 96), bs.count()); // 3 words fully set
    try std.testing.expect(bs.all());
    bs.reset_all();
    try std.testing.expectEqual(@as(usize, 0), bs.count());
    try std.testing.expect(!bs.any());
}

test "dynamic bitset find one/zero with padding" {
    var bs = try DynamicBitset.init(std.testing.allocator, 33);
    defer bs.deinit();
    try std.testing.expect(bs.find_first_one() == null);
    try std.testing.expect(bs.find_first_zero().? == 0);

    bs.set(5, true);
    try std.testing.expectEqual(@as(usize, 5), bs.find_first_one().?);
    try std.testing.expectEqual(@as(usize, 0), bs.find_first_zero().?);
    try std.testing.expectEqual(@as(usize, 5), bs.find_next_one(0).?);
    try std.testing.expectEqual(@as(usize, 1), bs.find_next_zero(0).?);

    bs.set(32, true);
    try std.testing.expectEqual(@as(usize, 5), bs.find_first_one().?);
    try std.testing.expectEqual(@as(usize, 32), bs.find_next_one(6).?);
    try std.testing.expectEqual(@as(usize, 32), bs.find_next_one(5).?);
    try std.testing.expect(bs.find_next_one(32) == null);
    // any/all with padding: word 1 has only bit 0 set (bit 32); padding bits clear.
    try std.testing.expect(bs.any());
    try std.testing.expect(!bs.all());
    try std.testing.expectEqual(@as(usize, 2), bs.count()); // padding bits still count in count()
}

test "dynamic bitset or_assign and clone" {
    var a = try DynamicBitset.init(std.testing.allocator, 40);
    defer a.deinit();
    var b = try DynamicBitset.init(std.testing.allocator, 40);
    defer b.deinit();
    a.set(3, true);
    b.set(39, true);
    a.or_assign(&b);
    try std.testing.expect(a.get(3));
    try std.testing.expect(a.get(39));
    try std.testing.expectEqual(@as(usize, 2), a.count());

    var c = try a.clone(std.testing.allocator);
    defer c.deinit();
    try std.testing.expectEqual(@as(usize, 2), c.count());
    try std.testing.expectEqualSlices(u32, a.as_words(), c.as_words());
}

test "dynamic bitset empty" {
    var bs = try DynamicBitset.init(std.testing.allocator, 0);
    defer bs.deinit();
    try std.testing.expect(bs.is_empty());
    try std.testing.expect(bs.len() == 0);
    try std.testing.expect(bs.all());
    try std.testing.expect(!bs.any());
    try std.testing.expect(bs.find_first_one() == null);
    try std.testing.expect(bs.find_first_zero() == null);
    try std.testing.expect(bs.find_next_one(0) == null);
    try std.testing.expect(bs.find_next_zero(0) == null);
}

test "dynamic bitset json round-trip" {
    const alloc = std.testing.allocator;
    var bs = try DynamicBitset.init(alloc, 65);
    defer bs.deinit();
    bs.set(1, true);
    bs.set(64, true);

    const value = try bs.serialize_json_value_cpp(alloc);
    // Value owns its array; free it manually after use.
    var restored = try DynamicBitset.deserialize_json_value_cpp(alloc, value);
    defer restored.deinit();
    try std.testing.expectEqual(bs.size, restored.size);
    try std.testing.expectEqualSlices(u32, bs.as_words(), restored.as_words());
    value.array.deinit();

    // Shape errors.
    var bad = std.json.Array.init(alloc);
    defer bad.deinit();
    try bad.append(.{ .integer = 65 });
    try std.testing.expectError(error.InvalidJson, DynamicBitset.deserialize_json_value_cpp(alloc, .{ .array = bad }));

    var bad2 = std.json.Array.init(alloc);
    defer bad2.deinit();
    try bad2.append(.{ .integer = 65 });
    try bad2.append(.{ .integer = 1 }); // buffer_size mismatch (expected 3)
    try std.testing.expectError(error.InvalidJson, DynamicBitset.deserialize_json_value_cpp(alloc, .{ .array = bad2 }));

    try std.testing.expectError(error.InvalidJson, DynamicBitset.deserialize_json_value_cpp(alloc, .{ .integer = 1 }));
}
