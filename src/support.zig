//! Foundational utilities: UTF-8 encoding, compact CSR arrays, dynamic bitsets,
//! integer-set operations, hashing, LRU cache, recursion guard, union-find, and a
//! thread-safe allocator adapter.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const compact_2d_array = @import("support/compact_2d_array.zig");
pub const dynamic_bitset = @import("support/dynamic_bitset.zig");
pub const encoding = @import("support/encoding.zig");
pub const int_set = @import("support/int_set.zig");
pub const json_parse = @import("support/json_parse.zig");
pub const lru_cache = @import("support/lru_cache.zig");
pub const recursion_guard = @import("support/recursion_guard.zig");
pub const union_find_set = @import("support/union_find_set.zig");

pub const Compact2dArray = compact_2d_array.Compact2dArray;
pub const Compact2dArrayError = compact_2d_array.Compact2dArrayError;
pub const BITS_PER_BLOCK = dynamic_bitset.BITS_PER_BLOCK;
pub const DynamicBitset = dynamic_bitset.DynamicBitset;
pub const CharHandlingError = encoding.CharHandlingError;
pub const Codepoint = encoding.Codepoint;
pub const byteToLatin1 = encoding.byteToLatin1;
pub const charToUtf8Bytes = encoding.charToUtf8Bytes;
pub const escapeByte = encoding.escapeByte;
pub const escapeBytes = encoding.escapeBytes;
pub const escapeCodepoint = encoding.escapeCodepoint;
pub const escapeStr = encoding.escapeStr;
pub const handleUtf8FirstByte = encoding.handleUtf8FirstByte;
pub const hexCharToInt = encoding.hexCharToInt;
pub const latin1ToBytes = encoding.latin1ToBytes;
pub const parseNextEscaped = encoding.parseNextEscaped;
pub const parseNextUtf8 = encoding.parseNextUtf8;
pub const parseNextUtf8OrEscaped = encoding.parseNextUtf8OrEscaped;
pub const parseUtf8 = encoding.parseUtf8;
pub const intsetComplement = int_set.intsetComplement;
pub const intsetDifference = int_set.intsetDifference;
pub const intsetIntersection = int_set.intsetIntersection;
pub const intsetUnion = int_set.intsetUnion;
pub const parseJson = json_parse.parseJson;
pub const AutoLruCache = lru_cache.AutoLruCache;
pub const LruCache = lru_cache.LruCache;
pub const default_max_recursion_depth = recursion_guard.default_max_recursion_depth;
pub const max_reasonable_recursion_depth = recursion_guard.max_reasonable_recursion_depth;
pub const RecursionError = recursion_guard.RecursionError;
pub const RecursionGuard = recursion_guard.RecursionGuard;
pub const getMaxRecursionDepth = recursion_guard.getMaxRecursionDepth;
pub const resetRecursionDepth = recursion_guard.resetRecursionDepth;
pub const setMaxRecursionDepth = recursion_guard.setMaxRecursionDepth;
pub const UnionFindSet = union_find_set.UnionFindSet;

/// Length of the longest common prefix of `a` and `b`.
pub fn commonPrefixLen(a: []const u8, b: []const u8) i32 {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n and a[i] == b[i]) : (i += 1) {}
    return @intCast(i);
}

const hash_mix: u64 = 0x9e37_79b9_7f4a_7c15;

/// Mixes `value` into `seed` (boost `hash_combine`).
pub inline fn hashCombineBinary(seed: *u64, value: u64) void {
    seed.* ^= value +% hash_mix +% (seed.* << 6) +% (seed.* >> 2);
}

/// Combines a sequence of hash values into a single hash starting from zero.
pub fn hashCombine(values: []const u64) u64 {
    var seed: u64 = 0;
    for (values) |value| {
        hashCombineBinary(&seed, value);
    }
    return seed;
}

/// Mutex-serialized wrapper around any `std.mem.Allocator` for safe concurrent use
/// (including `std.testing.allocator`) from worker threads.
pub const ThreadSafeAllocator = struct {
    child: Allocator,
    mutex: std.atomic.Mutex = .unlocked,

    pub fn allocator(self: *ThreadSafeAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn lock(self: *ThreadSafeAllocator) void {
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ThreadSafeAllocator = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.mutex.unlock();
        return self.child.vtable.alloc(self.child.ptr, len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *ThreadSafeAllocator = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.mutex.unlock();
        return self.child.vtable.resize(self.child.ptr, memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *ThreadSafeAllocator = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.mutex.unlock();
        return self.child.vtable.remap(self.child.ptr, memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *ThreadSafeAllocator = @ptrCast(@alignCast(ctx));
        self.lock();
        defer self.mutex.unlock();
        self.child.vtable.free(self.child.ptr, memory, alignment, ret_addr);
    }
};

test "commonPrefixLen and hashCombine" {
    try std.testing.expectEqual(@as(i32, 0), commonPrefixLen("abc", "xyz"));
    try std.testing.expectEqual(@as(i32, 3), commonPrefixLen("abcd", "abce"));
    try std.testing.expectEqual(@as(i32, 2), commonPrefixLen("ab", "abZ"));

    const a = hashCombine(&.{ 1, 2, 3 });
    const b = hashCombine(&.{ 1, 2, 3 });
    const c = hashCombine(&.{ 3, 2, 1 });
    try std.testing.expectEqual(a, b);
    try std.testing.expect(a != c);
}

test "ThreadSafeAllocator multi-thread arena stress" {
    var ts = ThreadSafeAllocator{ .child = std.testing.allocator };
    const Worker = struct {
        fn run(backing: Allocator) void {
            var arena = std.heap.ArenaAllocator.init(backing);
            defer arena.deinit();
            const aa = arena.allocator();
            for (0..64) |i| {
                const s = aa.alloc(u64, i + 1) catch unreachable;
                s[0] = i;
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ts.allocator()});
    }
    for (threads) |t| t.join();
}

test {
    _ = compact_2d_array;
    _ = dynamic_bitset;
    _ = encoding;
    _ = int_set;
    _ = json_parse;
    _ = lru_cache;
    _ = recursion_guard;
    _ = union_find_set;
    _ = @import("Diagnostic.zig");
}
