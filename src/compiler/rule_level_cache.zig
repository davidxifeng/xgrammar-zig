//! Thread-safe LRU cache for crossing-grammar adaptive token masks (`rule_level_cache.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const adaptive_token_mask = @import("adaptive_token_mask.zig");
const AdaptiveTokenMask = adaptive_token_mask.AdaptiveTokenMask;
const support = @import("../support/mod.zig");
const AutoLruCache = support.AutoLruCache;
const hash_combine = support.hash_combine;

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

    fn deinit(self: *CacheState, alloc_mutex: *std.atomic.Mutex) void {
        self.clear(alloc_mutex);
        lockMutex(alloc_mutex);
        defer alloc_mutex.unlock();
        self.lru.deinit(self.allocator);
    }

    fn clear(self: *CacheState, alloc_mutex: *std.atomic.Mutex) void {
        lockMutex(alloc_mutex);
        defer alloc_mutex.unlock();
        while (self.lru.popLru()) |entry| {
            var mask = entry.value;
            mask.deinit();
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
        return try mask.clone(out_allocator);
    }

    fn add(
        self: *CacheState,
        alloc_mutex: *std.atomic.Mutex,
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
        const new_item_size = token_mask.memory_size_bytes();
        if (self.max_cache_memory_size != UNLIMITED_SIZE and new_item_size > self.max_cache_memory_size) {
            return false;
        }
        if (self.lru.contains(key)) {
            return false;
        }

        lockMutex(alloc_mutex);
        defer alloc_mutex.unlock();

        if (self.max_cache_memory_size != UNLIMITED_SIZE) {
            while (@as(i128, self.current_cache_memory_size) >
                @as(i128, self.max_cache_memory_size) - @as(i128, new_item_size))
            {
                const oldest = self.lru.popLru() orelse break;
                var removed_mask = oldest.value;
                self.current_cache_memory_size -= @as(i64, @intCast(removed_mask.memory_size_bytes()));
                removed_mask.deinit();
            }
        }

        var stored = try token_mask.clone(self.allocator);
        errdefer stored.deinit();
        if (try self.lru.put(self.allocator, key, stored)) |prev| {
            var prev_mask = prev.value;
            self.current_cache_memory_size -= @as(i64, @intCast(prev_mask.memory_size_bytes()));
            prev_mask.deinit();
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

/// Thread-safe LRU cache keyed by `(fsm_hash, new_state_id, state_cnt, edge_cnt)`, sharded by
/// `(fsm_hash, new_state_id)`. Eviction is performed per shard, each owning an equal share of the
/// memory budget.
pub const RuleLevelCache = struct {
    allocator: Allocator,
    alloc_mutex: std.atomic.Mutex,
    shards: [NUM_SHARDS]Shard,
    max_cache_memory_size: usize,

    /// Creates a heap-allocated cache with the given memory budget (`UNLIMITED_SIZE` = unlimited).
    pub fn new(allocator: Allocator, max_cache_memory_size: usize) Allocator.Error!*RuleLevelCache {
        const shard_max_size = if (max_cache_memory_size == UNLIMITED_SIZE)
            UNLIMITED_SIZE
        else
            max_cache_memory_size / NUM_SHARDS;
        const self = try allocator.create(RuleLevelCache);
        self.allocator = allocator;
        self.alloc_mutex = .unlocked;
        self.max_cache_memory_size = max_cache_memory_size;
        for (&self.shards) |*s| {
            s.* = .{
                .mutex = .unlocked,
                .state = CacheState.init(allocator, shard_max_size),
            };
        }
        return self;
    }

    pub fn deinit(self: *RuleLevelCache) void {
        const a = self.allocator;
        for (&self.shards) |*s| {
            s.state.deinit(&self.alloc_mutex);
        }
        a.destroy(self);
    }

    fn shard_for(self: *RuleLevelCache, fsm_hash: u64, fsm_new_node_id: i32) *Shard {
        // Match Rust `fsm_new_node_id as u64` sign extension.
        const node_u64: u64 = @bitCast(@as(i64, fsm_new_node_id));
        const index = hash_combine(&.{ fsm_hash, node_u64 }) % NUM_SHARDS;
        return &self.shards[index];
    }

    /// Returns a cloned cached adaptive token mask in `out_allocator`, if present.
    pub fn get_cache(
        self: *RuleLevelCache,
        out_allocator: Allocator,
        fsm_hash: u64,
        fsm_new_node_id: i32,
        state_cnt: i32,
        edge_cnt: i32,
    ) Allocator.Error!?AdaptiveTokenMask {
        const s = self.shard_for(fsm_hash, fsm_new_node_id);
        s.lock();
        defer s.unlock();
        return s.state.get(out_allocator, fsm_hash, fsm_new_node_id, state_cnt, edge_cnt);
    }

    /// Inserts an adaptive token mask into the cache (deep-copied into the cache's allocator).
    pub fn add_cache(
        self: *RuleLevelCache,
        fsm_hash: u64,
        fsm_new_node_id: i32,
        state_cnt: i32,
        edge_cnt: i32,
        token_mask: *const AdaptiveTokenMask,
    ) Allocator.Error!bool {
        const s = self.shard_for(fsm_hash, fsm_new_node_id);
        s.lock();
        defer s.unlock();
        return s.state.add(&self.alloc_mutex, fsm_hash, fsm_new_node_id, state_cnt, edge_cnt, token_mask);
    }

    /// Clears all cached entries.
    pub fn clear_cache(self: *RuleLevelCache) void {
        for (&self.shards) |*s| {
            s.lock();
            defer s.unlock();
            s.state.clear(&self.alloc_mutex);
        }
    }

    /// The configured memory budget (`UNLIMITED_SIZE` = unlimited).
    pub fn max_size(self: *const RuleLevelCache) usize {
        return self.max_cache_memory_size;
    }
};
