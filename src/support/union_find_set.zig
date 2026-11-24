//! A disjoint-set (union-find) structure with deterministic partition output.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub fn UnionFindSet(comptime T: type) type {
    const ParentAndSize = struct {
        parent: T,
        size: usize,
    };

    return struct {
        const Self = @This();
        pub const HashMap = std.AutoHashMapUnmanaged(T, ParentAndSize);

        allocator: Allocator,
        parent_and_size: HashMap,

        pub fn init(allocator: Allocator) Self {
            return .{
                .allocator = allocator,
                .parent_and_size = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            self.parent_and_size.deinit(self.allocator);
        }

        pub fn add(self: *Self, element: T) Allocator.Error!bool {
            if (self.parent_and_size.contains(element)) return false;
            try self.parent_and_size.put(self.allocator, element, .{ .parent = element, .size = 1 });
            return true;
        }

        pub fn clear(self: *Self) void {
            self.parent_and_size.clearRetainingCapacity();
        }

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
        pub fn unite(self: *Self, a: T, b: T) void {
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

        pub fn contains(self: *const Self, element: T) bool {
            return self.parent_and_size.contains(element);
        }

        /// All sets, each sorted ascending, ordered by their smallest element.
        pub fn getAllSets(self: *Self, allocator: Allocator) Allocator.Error!ArrayList(ArrayList(T)) {
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

test "union find add, contains, find, unite" {
    const alloc = std.testing.allocator;
    var uf = UnionFindSet(u32).init(alloc);
    defer uf.deinit();

    try std.testing.expect(try uf.add(10));
    try std.testing.expect(try uf.add(20));
    try std.testing.expect(try uf.add(30));
    try std.testing.expect(!try uf.add(10));

    try std.testing.expect(uf.contains(20));
    try std.testing.expect(!uf.contains(99));

    uf.unite(10, 20);
    uf.unite(20, 30);
    try std.testing.expectEqual(uf.find(30), uf.find(10));

    uf.clear();
    try std.testing.expect(!uf.contains(10));
}

test "union find getAllSets deterministic" {
    const alloc = std.testing.allocator;
    var uf = UnionFindSet(i32).init(alloc);
    defer uf.deinit();
    const elements = [_]i32{ 7, 3, 5, 1, 9, 4 };
    for (elements) |e| _ = try uf.add(e);
    uf.unite(7, 9);
    uf.unite(3, 5);

    var sets = try uf.getAllSets(alloc);
    defer {
        for (sets.items) |*s| s.deinit(alloc);
        sets.deinit(alloc);
    }

    try std.testing.expectEqual(@as(usize, 4), sets.items.len);
    try std.testing.expectEqualSlices(i32, &.{1}, sets.items[0].items);
    try std.testing.expectEqualSlices(i32, &.{ 3, 5 }, sets.items[1].items);
    try std.testing.expectEqualSlices(i32, &.{4}, sets.items[2].items);
    try std.testing.expectEqualSlices(i32, &.{ 7, 9 }, sets.items[3].items);
}
