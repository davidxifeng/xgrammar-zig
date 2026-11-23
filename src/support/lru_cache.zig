//! Intrusive array-backed O(1) LRU cache (`HashMapUnmanaged` + doubly-linked index list).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Generic O(1) LRU cache mapping `K -> V` with deterministic LRU-to-MRU ordering.
/// Node storage lives in a flat `ArrayList` with an intrusive free-list to avoid
/// per-entry heap allocations and linear array shifts (`orderedRemove`).
pub fn LruCache(comptime K: type, comptime V: type, comptime Context: type) type {
    return struct {
        const Self = @This();
        const NONE: u32 = std.math.maxInt(u32);

        pub const Entry = struct {
            key: K,
            value: V,
        };

        const Node = struct {
            key: K,
            value: V,
            prev: u32,
            next: u32,
            alive: bool,
        };

        pub const ValueIterator = struct {
            cache: *const Self,
            cur: u32,

            pub fn next(self: *ValueIterator) ?*const V {
                if (self.cur == NONE) return null;
                const node = &self.cache.nodes.items[self.cur];
                self.cur = node.next;
                return &node.value;
            }
        };

        map: std.HashMapUnmanaged(K, u32, Context, std.hash_map.default_max_load_percentage),
        nodes: std.ArrayList(Node),
        head: u32, // least recently used
        tail: u32, // most recently used
        free_head: u32,

        pub const empty: Self = .{
            .map = .empty,
            .nodes = .empty,
            .head = NONE,
            .tail = NONE,
            .free_head = NONE,
        };

        pub fn init() Self {
            return .empty;
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.map.deinit(allocator);
            self.nodes.deinit(allocator);
            self.* = .empty;
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.map.clearRetainingCapacity();
            self.nodes.clearRetainingCapacity();
            self.head = NONE;
            self.tail = NONE;
            self.free_head = NONE;
        }

        pub fn count(self: *const Self) usize {
            return self.map.count();
        }

        pub fn contains(self: *const Self, key: K) bool {
            return self.map.contains(key);
        }

        /// Looks up `key` in O(1), promotes it to MRU on hit, and returns a mutable pointer to its value.
        pub fn getPtr(self: *Self, key: K) ?*V {
            const idx = self.map.get(key) orelse return null;
            self.moveToBack(idx);
            return &self.nodes.items[idx].value;
        }

        /// Looks up `key` without modifying LRU order.
        pub fn getPtrNoTouch(self: *const Self, key: K) ?*const V {
            const idx = self.map.get(key) orelse return null;
            return &self.nodes.items[idx].value;
        }

        /// Inserts or updates `key -> value` in O(1) and marks it MRU.
        /// If `key` was already present, returns the evicted previous `(key, value)` pair so the caller can release owned resources.
        pub fn put(self: *Self, allocator: Allocator, key: K, value: V) Allocator.Error!?Entry {
            if (self.map.getEntry(key)) |kv| {
                const idx = kv.value_ptr.*;
                const old = Entry{
                    .key = self.nodes.items[idx].key,
                    .value = self.nodes.items[idx].value,
                };
                kv.key_ptr.* = key;
                self.nodes.items[idx].key = key;
                self.nodes.items[idx].value = value;
                self.moveToBack(idx);
                return old;
            }
            const idx = try self.allocNode(allocator, .{
                .key = key,
                .value = value,
                .prev = NONE,
                .next = NONE,
                .alive = true,
            });
            errdefer self.recycleNode(idx);
            try self.map.putNoClobber(allocator, key, idx);
            self.appendBack(idx);
            return null;
        }

        /// Pops and returns the least-recently-used `(key, value)` pair in O(1), or `null` if empty.
        pub fn popLru(self: *Self) ?Entry {
            if (self.head == NONE) return null;
            const idx = self.head;
            const node = self.nodes.items[idx];
            const removed = self.map.remove(node.key);
            std.debug.assert(removed);
            self.unlink(idx);
            self.recycleNode(idx);
            return .{ .key = node.key, .value = node.value };
        }

        /// Removes `key` in O(1) if present and returns its stored `(key, value)` pair.
        pub fn remove(self: *Self, key: K) ?Entry {
            const removed = self.map.fetchRemove(key) orelse return null;
            const idx = removed.value;
            const node = self.nodes.items[idx];
            self.unlink(idx);
            self.recycleNode(idx);
            return .{ .key = node.key, .value = node.value };
        }

        /// Iterates stored values from LRU to MRU without mutating order.
        pub fn valueIterator(self: *const Self) ValueIterator {
            return .{ .cache = self, .cur = self.head };
        }

        fn allocNode(self: *Self, allocator: Allocator, node: Node) Allocator.Error!u32 {
            if (self.free_head != NONE) {
                const idx = self.free_head;
                self.free_head = self.nodes.items[idx].next;
                self.nodes.items[idx] = node;
                return idx;
            }
            const idx: u32 = @intCast(self.nodes.items.len);
            try self.nodes.append(allocator, node);
            return idx;
        }

        fn recycleNode(self: *Self, idx: u32) void {
            self.nodes.items[idx].alive = false;
            self.nodes.items[idx].prev = NONE;
            self.nodes.items[idx].next = self.free_head;
            self.free_head = idx;
        }

        fn appendBack(self: *Self, idx: u32) void {
            const node = &self.nodes.items[idx];
            node.prev = self.tail;
            node.next = NONE;
            if (self.tail != NONE) {
                self.nodes.items[self.tail].next = idx;
            } else {
                self.head = idx;
            }
            self.tail = idx;
        }

        fn unlink(self: *Self, idx: u32) void {
            const node = &self.nodes.items[idx];
            if (node.prev != NONE) {
                self.nodes.items[node.prev].next = node.next;
            } else {
                self.head = node.next;
            }
            if (node.next != NONE) {
                self.nodes.items[node.next].prev = node.prev;
            } else {
                self.tail = node.prev;
            }
            node.prev = NONE;
            node.next = NONE;
        }

        fn moveToBack(self: *Self, idx: u32) void {
            if (self.tail == idx) return;
            self.unlink(idx);
            self.appendBack(idx);
        }
    };
}

/// Convenience alias using `std.hash_map.AutoContext(K)`.
pub fn AutoLruCache(comptime K: type, comptime V: type) type {
    return LruCache(K, V, std.hash_map.AutoContext(K));
}

test "LruCache O(1) touch, overwrite, popLru, remove, and slot reuse" {
    const a = std.testing.allocator;
    var lru = AutoLruCache(i32, i32).init();
    defer lru.deinit(a);

    try std.testing.expect((try lru.put(a, 1, 10)) == null);
    try std.testing.expect((try lru.put(a, 2, 20)) == null);
    try std.testing.expect((try lru.put(a, 3, 30)) == null);

    // Touch key 1 -> order from LRU becomes [2, 3, 1].
    const p1 = lru.getPtr(1).?;
    try std.testing.expectEqual(@as(i32, 10), p1.*);
    p1.* = 11;

    // Overwrite key 2 -> order becomes [3, 1, 2].
    const old2 = (try lru.put(a, 2, 22)).?;
    try std.testing.expectEqual(@as(i32, 20), old2.value);

    // Pop LRU -> key 3 first, then 1, then 2.
    const e1 = lru.popLru().?;
    try std.testing.expectEqual(@as(i32, 3), e1.key);
    try std.testing.expectEqual(@as(i32, 30), e1.value);

    const rem1 = lru.remove(1).?;
    try std.testing.expectEqual(@as(i32, 11), rem1.value);

    // Re-insert reuses recycled node slots cleanly.
    try std.testing.expect((try lru.put(a, 4, 40)) == null);
    try std.testing.expectEqual(@as(usize, 2), lru.count());
    try std.testing.expectEqual(@as(i32, 2), lru.popLru().?.key);
    try std.testing.expectEqual(@as(i32, 4), lru.popLru().?.key);
    try std.testing.expect(lru.popLru() == null);
}
