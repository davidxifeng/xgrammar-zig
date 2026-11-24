//! Thread-safe LRU cache for crossing-grammar adaptive token masks (`rule_level_cache.rs`).

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;

const AdaptiveTokenMask = @import("AdaptiveTokenMask.zig").AdaptiveTokenMask;
const support = @import("../support.zig");
const AutoLruCache = support.AutoLruCache;
const ThreadSafeAllocator = support.ThreadSafeAllocator;
const hashCombine = support.hashCombine;

/// Unlimited cache size sentinel (matches C++ `kUnlimitedSize`).
pub const UNLIMITED_SIZE: usize = std.math.maxInt(usize);

/// The cache is sharded to reduce lock contention: token mask cache generation queries and inserts
/// from all compilation threads, and a single global mutex would serialize them.
const NUM_SHARDS: usize = 16;

const NodeKey = struct {
    fsm_hash: u64,
    fsm_new_node_id: i32,
    state_cnt: i32,
    edge_cnt: i32,
};

fn lockMutex(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) {
        std.atomic.spinLoopHint();
    }
}

/// One shard of the cache, with its own O(1) LRU order and memory budget.
const CacheState = struct {
    allocator: Allocator,
    max_cache_memory_size: usize,
    current_cache_memory_size: i64,
    lru: AutoLruCache(NodeKey, AdaptiveTokenMask),

    fn init(allocator: Allocator, max_cache_memory_size: usize) CacheState {
        return .{
            .allocator = allocator,
            .max_cache_memory_size = max_cache_memory_size,
            .current_cache_memory_size = 0,
            .lru = AutoLruCache(NodeKey, AdaptiveTokenMask).init(),
        };
    }

    fn deinit(self: *CacheState) void {
        self.clear();
        self.lru.deinit(self.allocator);
    }

    fn clear(self: *CacheState) void {
        while (self.lru.popLru()) |entry| {
            var mask = entry.value;
            mask.deinit(self.allocator);
        }
        self.lru.clearRetainingCapacity();
        self.current_cache_memory_size = 0;
    }

    fn get(
        self: *CacheState,
        out_allocator: Allocator,
        fsm_hash: u64,
        fsm_new_node_id: i32,
        state_cnt: i32,
        edge_cnt: i32,
    ) Allocator.Error!?AdaptiveTokenMask {
        const key = NodeKey{
            .fsm_hash = fsm_hash,
            .fsm_new_node_id = fsm_new_node_id,
            .state_cnt = state_cnt,
            .edge_cnt = edge_cnt,
        };
        const mask = self.lru.getPtr(key) orelse return null;
        return try mask.dupe(out_allocator);
    }

    fn add(
        self: *CacheState,
        fsm_hash: u64,
        fsm_new_node_id: i32,
        state_cnt: i32,
        edge_cnt: i32,
        token_mask: *const AdaptiveTokenMask,
    ) Allocator.Error!bool {
        const key = NodeKey{
            .fsm_hash = fsm_hash,
            .fsm_new_node_id = fsm_new_node_id,
            .state_cnt = state_cnt,
            .edge_cnt = edge_cnt,
        };
        const new_item_size = token_mask.memorySizeBytes();
        if (self.max_cache_memory_size != UNLIMITED_SIZE and new_item_size > self.max_cache_memory_size) {
            return false;
        }
        if (self.lru.contains(key)) {
            return false;
        }

        if (self.max_cache_memory_size != UNLIMITED_SIZE) {
            while (@as(i128, self.current_cache_memory_size) >
                @as(i128, self.max_cache_memory_size) - @as(i128, new_item_size))
            {
                const oldest = self.lru.popLru() orelse break;
                var removed_mask = oldest.value;
                self.current_cache_memory_size -= @as(i64, @intCast(removed_mask.memorySizeBytes()));
                removed_mask.deinit(self.allocator);
            }
        }

        var stored = try token_mask.dupe(self.allocator);
        errdefer stored.deinit(self.allocator);
        if (try self.lru.put(self.allocator, key, stored)) |prev| {
            var prev_mask = prev.value;
            self.current_cache_memory_size -= @as(i64, @intCast(prev_mask.memorySizeBytes()));
            prev_mask.deinit(self.allocator);
        }
        self.current_cache_memory_size += @as(i64, @intCast(new_item_size));
        return true;
    }
};

const Shard = struct {
    mutex: std.atomic.Mutex = .unlocked,
    state: CacheState,

    fn lock(self: *Shard) void {
        lockMutex(&self.mutex);
    }

    fn unlock(self: *Shard) void {
        self.mutex.unlock();
    }
};

fn isStatelessAllocator(a: Allocator) bool {
    if (a.vtable == std.testing.failing_allocator.vtable) return true;
    if (builtin.link_libc and a.vtable == std.heap.c_allocator.vtable) return true;
    if (!builtin.single_threaded and a.vtable == std.heap.smp_allocator.vtable) return true;
    return false;
}

/// Thread-safe LRU cache keyed by `(fsm_hash, new_state_id, state_cnt, edge_cnt)`, sharded by
/// `(fsm_hash, new_state_id)`. Eviction is performed per shard, each owning an equal share of the
/// memory budget.
///
/// Internal allocations are serialized through an embedded `ThreadSafeAllocator` wrapping
/// `backing_allocator` so concurrent reads/evictions/inserts across shards cannot race.
pub const RuleLevelCache = struct {
    backing_allocator: Allocator,
    ts_alloc: ThreadSafeAllocator,
    shards: [NUM_SHARDS]Shard,
    max_cache_memory_size: usize,

    /// Creates a heap-allocated cache with the given memory budget (`UNLIMITED_SIZE` = unlimited).
    pub fn init(allocator: Allocator, max_cache_memory_size: usize) Allocator.Error!*RuleLevelCache {
        const shard_max_size = if (max_cache_memory_size == UNLIMITED_SIZE)
            UNLIMITED_SIZE
        else
            max_cache_memory_size / NUM_SHARDS;
        const self = try allocator.create(RuleLevelCache);
        self.* = .{
            .backing_allocator = allocator,
            .ts_alloc = .{ .child = allocator },
            .shards = undefined,
            .max_cache_memory_size = max_cache_memory_size,
        };
        const ts = self.ts_alloc.allocator();
        for (&self.shards) |*s| {
            s.* = .{
                .mutex = .unlocked,
                .state = CacheState.init(ts, shard_max_size),
            };
        }
        return self;
    }

    pub fn deinit(self: *RuleLevelCache) void {
        const a = self.backing_allocator;
        for (&self.shards) |*s| {
            s.state.deinit();
        }
        a.destroy(self);
    }

    /// Returns a mutex-serialized allocator view backed by `self.backing_allocator`.
    /// Sharing this allocator with worker threads prevents concurrent races on non-thread-safe
    /// backing allocators such as `std.testing.allocator`.
    pub fn threadSafeAllocator(self: *RuleLevelCache) Allocator {
        return self.ts_alloc.allocator();
    }

    /// Whether `other` refers to the same backing allocator instance as `self`.
    pub fn sharesBackingAllocator(self: *const RuleLevelCache, other: Allocator) bool {
        if (self.backing_allocator.vtable != other.vtable) return false;
        if (isStatelessAllocator(other)) return true;
        return self.backing_allocator.ptr == other.ptr;
    }

    fn shardFor(self: *RuleLevelCache, fsm_hash: u64, fsm_new_node_id: i32) *Shard {
        // Match Rust `fsm_new_node_id as u64` sign extension.
        const node_u64: u64 = @bitCast(@as(i64, fsm_new_node_id));
        const index = hashCombine(&.{ fsm_hash, node_u64 }) % NUM_SHARDS;
        return &self.shards[index];
    }

    /// Returns a cloned cached adaptive token mask in `out_allocator`, if present.
    pub fn getCache(
        self: *RuleLevelCache,
        out_allocator: Allocator,
        fsm_hash: u64,
        fsm_new_node_id: i32,
        state_cnt: i32,
        edge_cnt: i32,
    ) Allocator.Error!?AdaptiveTokenMask {
        const s = self.shardFor(fsm_hash, fsm_new_node_id);
        s.lock();
        defer s.unlock();
        return s.state.get(out_allocator, fsm_hash, fsm_new_node_id, state_cnt, edge_cnt);
    }

    /// Inserts an adaptive token mask into the cache (deep-copied into the cache's allocator).
    pub fn addCache(
        self: *RuleLevelCache,
        fsm_hash: u64,
        fsm_new_node_id: i32,
        state_cnt: i32,
        edge_cnt: i32,
        token_mask: *const AdaptiveTokenMask,
    ) Allocator.Error!bool {
        const s = self.shardFor(fsm_hash, fsm_new_node_id);
        s.lock();
        defer s.unlock();
        return s.state.add(fsm_hash, fsm_new_node_id, state_cnt, edge_cnt, token_mask);
    }

    /// Clears all cached entries.
    pub fn clearCache(self: *RuleLevelCache) void {
        for (&self.shards) |*s| {
            s.lock();
            defer s.unlock();
            s.state.clear();
        }
    }

    /// The configured memory budget (`UNLIMITED_SIZE` = unlimited).
    pub fn maxSize(self: *const RuleLevelCache) usize {
        return self.max_cache_memory_size;
    }
};

test {
    std.testing.refAllDecls(RuleLevelCache);
}
