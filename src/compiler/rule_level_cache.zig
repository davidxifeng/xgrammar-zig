//! Thread-safe LRU cache for crossing-grammar adaptive token masks (`rule_level_cache.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const adaptive_token_mask = @import("adaptive_token_mask.zig");
const AdaptiveTokenMask = adaptive_token_mask.AdaptiveTokenMask;
const support = @import("../support/mod.zig");
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

/// One shard of the cache, with its own LRU order and memory budget.
const CacheState = struct {
    allocator: Allocator,
    max_cache_memory_size: usize,
    current_cache_memory_size: i64,
    order: std.ArrayList(NodeKey),
    cache: std.AutoHashMapUnmanaged(NodeKey, AdaptiveTokenMask),

    fn init(allocator: Allocator, max_cache_memory_size: usize) CacheState {
        return .{
            .allocator = allocator,
            .max_cache_memory_size = max_cache_memory_size,
            .current_cache_memory_size = 0,
            .order = .empty,
            .cache = .empty,
        };
    }

    fn deinit(self: *CacheState) void {
        self.clear();
        self.order.deinit(self.allocator);
        self.cache.deinit(self.allocator);
    }

    fn clear(self: *CacheState) void {
        var it = self.cache.valueIterator();
        while (it.next()) |mask| {
            mask.deinit();
        }
        self.cache.clearRetainingCapacity();
        self.order.clearRetainingCapacity();
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
        const mask = self.cache.getPtr(key) orelse return null;
        const cloned = try mask.clone(out_allocator);
        for (self.order.items, 0..) |entry, pos| {
            if (std.meta.eql(entry, key)) {
                const moved = self.order.orderedRemove(pos);
                self.order.appendAssumeCapacity(moved);
                break;
            }
        }
        return cloned;
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
        if (self.max_cache_memory_size != UNLIMITED_SIZE and token_mask.memory_size_bytes() > self.max_cache_memory_size) {
            return false;
        }
        if (self.cache.contains(key)) {
            return false;
        }

        if (self.max_cache_memory_size != UNLIMITED_SIZE) {
            const new_item_size = token_mask.memory_size_bytes();
            while (@as(i128, self.current_cache_memory_size) >
                @as(i128, self.max_cache_memory_size) - @as(i128, new_item_size))
            {
                if (self.order.items.len == 0) break;
                const oldest = self.order.orderedRemove(0);
                if (self.cache.fetchRemove(oldest)) |removed| {
                    var removed_mask = removed.value;
                    self.current_cache_memory_size -= @as(i64, @intCast(removed_mask.memory_size_bytes()));
                    removed_mask.deinit();
                }
            }
        }

        var stored = try token_mask.clone(self.allocator);
        errdefer stored.deinit();
        try self.order.ensureUnusedCapacity(self.allocator, 1);
        try self.cache.put(self.allocator, key, stored);
        self.order.appendAssumeCapacity(key);
        self.current_cache_memory_size += @as(i64, @intCast(stored.memory_size_bytes()));
        return true;
    }
};

const Shard = struct {
    mutex: std.atomic.Mutex = .unlocked,
    state: CacheState,

    fn lock(self: *Shard) void {
        while (!self.mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
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
            s.state.deinit();
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
        return s.state.add(fsm_hash, fsm_new_node_id, state_cnt, edge_cnt, token_mask);
    }

    /// Clears all cached entries.
    pub fn clear_cache(self: *RuleLevelCache) void {
        for (&self.shards) |*s| {
            s.lock();
            defer s.unlock();
            s.state.clear();
        }
    }

    /// The configured memory budget (`UNLIMITED_SIZE` = unlimited).
    pub fn max_size(self: *const RuleLevelCache) usize {
        return self.max_cache_memory_size;
    }
};
