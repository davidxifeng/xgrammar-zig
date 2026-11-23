//! A disjoint-set (union-find) structure.
//!
//! Used by the FSM simplification passes to coalesce equivalent states. Only the elements
//! explicitly `add`ed participate; `get_all_sets` returns the partition in a deterministic
//! order (each set ascending, sets ordered by their smallest element) so downstream state
//! renumbering is reproducible.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

/// A union-find set over copyable, comparable, hashable elements with union-by-size and
/// path compression.
///
/// Deviation note: the method mirrors Rust `union`, which is a Zig keyword, so it is
/// named `union_`.
pub fn UnionFindSet(comptime T: type) type {
    const ParentAndSize = struct {
        parent: T,
        size: usize,
    };

    return struct {
        const Self = @This();
        pub const HashMap = std.AutoHashMap(T, ParentAndSize);

        allocator: Allocator,
        /// element → (parent, subtree size)
        parent_and_size: HashMap,

        /// Creates an empty set.
        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .parent_and_size = HashMap.init(allocator),
            };
        }

        /// Releases all memory.
        pub fn deinit(self: *Self) void {
            self.parent_and_size.deinit();
        }

        /// Adds `element` as a new singleton set. Returns `false` if it already exists.
        pub fn add(self: *Self, element: T) Allocator.Error!bool {
            if (self.parent_and_size.contains(element)) return false;
            try self.parent_and_size.put(element, .{ .parent = element, .size = 1 });
            return true;
        }

        /// Removes all elements.
        pub fn clear(self: *Self) void {
            self.parent_and_size.clearRetainingCapacity();
        }

        /// The representative of the set containing `element` (with path compression).
        ///
        /// The Rust version panics when `element` was never added; here the missing
        /// element is an `unreachable` invariant.
        pub fn find(self: *Self, element: T) T {
            const entry = self.parent_and_size.getPtr(element) orelse
                std.debug.panic("element not found in union-find set", .{});
            if (entry.parent != element) {
                const root = self.find(entry.parent);
                self.parent_and_size.getPtr(element).?.parent = root;
                return root;
            }
            return element;
        }

        /// Merges the sets containing `a` and `b` (union by size).
        ///
        /// Panics like the Rust version if either element was never added.
        pub fn union_(self: *Self, a: T, b: T) void {
            var root_a = self.find(a);
            var root_b = self.find(b);
            if (root_a == root_b) return;
            const size_a = self.parent_and_size.getPtr(root_a).?.size;
            const size_b = self.parent_and_size.getPtr(root_b).?.size;
            if (size_a < size_b) {
                std.mem.swap(T, &root_a, &root_b);
            }
            self.parent_and_size.getPtr(root_b).?.parent = root_a;
            self.parent_and_size.getPtr(root_a).?.size = size_a + size_b;
        }

        /// Whether `element` has been added — mirrors the C++ `Count`.
        pub fn count(self: *const Self, element: T) bool {
            return self.parent_and_size.contains(element);
        }

        /// All sets, each sorted ascending, ordered by their smallest element.
        ///
        /// Caller owns the returned outer list and every inner list.
        pub fn get_all_sets(self: *Self, allocator: Allocator) Allocator.Error!ArrayList(ArrayList(T)) {
            var root_to_set = std.AutoHashMap(T, usize).init(allocator);
            defer root_to_set.deinit();
            var result: ArrayList(ArrayList(T)) = .empty;
            errdefer {
                for (result.items) |*set| set.deinit(allocator);
                result.deinit(allocator);
            }

            var it = self.parent_and_size.keyIterator();
            while (it.next()) |key| {
                const value = key.*;
                const root = self.find(value);
                const gop = try root_to_set.getOrPut(root);
                if (!gop.found_existing) {
                    try result.append(allocator, .empty);
                    gop.value_ptr.* = result.items.len - 1;
                }
                try result.items[gop.value_ptr.*].append(allocator, value);
            }
            for (result.items) |*set| {
                std.mem.sort(T, set.items, {}, std.sort.asc(T));
            }
            std.mem.sort(ArrayList(T), result.items, {}, setLessThan);
            return result;
        }

        fn setLessThan(_: void, a: ArrayList(T), b: ArrayList(T)) bool {
            return a.items[0] < b.items[0];
        }
    };
}

test "union find add, count, find, union" {
    const alloc = std.testing.allocator;
    var uf = UnionFindSet(u32).init(alloc);
    defer uf.deinit();

    try std.testing.expect(try uf.add(10));
    try std.testing.expect(try uf.add(20));
    try std.testing.expect(try uf.add(30));
    try std.testing.expect(!try uf.add(10));

    try std.testing.expect(uf.count(20));
    try std.testing.expect(!uf.count(99));

    uf.union_(10, 20);
    uf.union_(20, 30);
    try std.testing.expectEqual(uf.find(30), uf.find(10));

    uf.clear();
    try std.testing.expect(!uf.count(10));
}

test "union find get_all_sets deterministic" {
    const alloc = std.testing.allocator;
    var uf = UnionFindSet(i32).init(alloc);
    defer uf.deinit();
    // Insertion order deliberately scrambled.
    const elements = [_]i32{ 7, 3, 5, 1, 9, 4 };
    for (elements) |e| _ = try uf.add(e);
    uf.union_(7, 9);
    uf.union_(3, 5);

    var sets = try uf.get_all_sets(alloc);
    defer {
        for (sets.items) |*s| s.deinit(alloc);
        sets.deinit(alloc);
    }

    try std.testing.expectEqual(@as(usize, 4), sets.items.len);
    try std.testing.expectEqualSlices(i32, &.{1}, sets.items[0].items);
    try std.testing.expectEqualSlices(i32, &.{ 3, 5 }, sets.items[1].items);
    try std.testing.expectEqualSlices(i32, &.{4}, sets.items[2].items);
    try std.testing.expectEqualSlices(i32, &.{ 7, 9 }, sets.items[3].items);

    // Determinism across calls despite hash iteration order.
    var sets2 = try uf.get_all_sets(alloc);
    defer {
        for (sets2.items) |*s| s.deinit(alloc);
        sets2.deinit(alloc);
    }
    try std.testing.expectEqual(sets.items.len, sets2.items.len);
    for (sets.items, sets2.items) |a, b| {
        try std.testing.expectEqualSlices(i32, a.items, b.items);
    }
}
