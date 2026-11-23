//! Token bitmasks for grammar-guided generation (`token_bitmask.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const error_mod = @import("error.zig");
const MatcherError = error_mod.MatcherError;
const MatcherErrorInfo = error_mod.MatcherErrorInfo;

/// Bits per bitmask word.
pub const BITS_PER_WORD: i32 = 32;

/// DLPack-compatible int32 type descriptor for token bitmasks.
pub const BitmaskDlType = struct {
    /// DLDataType code: `kDLInt` = 0.
    code: u8,
    /// Bits per element.
    bits: u8,
    /// Lanes (always 1).
    lanes: u16,
};

/// Returns the DLPack dtype for token bitmasks: signed 32-bit integer, one lane.
pub fn get_bitmask_dl_type() BitmaskDlType {
    return .{
        .code = 0,
        .bits = 32,
        .lanes = 1,
    };
}

/// The number of `i32` words needed to hold `vocab_size` bits: `ceil(vocab_size / 32)`.
pub fn get_bitmask_size(vocab_size: i32) i32 {
    return @divTrunc(vocab_size + BITS_PER_WORD - 1, BITS_PER_WORD);
}

/// Validates a bitmask of `shape` for `vocab_size` and returns the word range `[start, end)`
/// of row `index`.
pub fn bitmask_row_range(
    allocator: Allocator,
    shape: []const i64,
    vocab_size: i32,
    index: i32,
    diag: ?*MatcherErrorInfo,
) MatcherError!struct { start: usize, end: usize } {
    const buffer_size: i64 = get_bitmask_size(vocab_size);
    if (shape.len == 1) {
        if (shape[0] != buffer_size) {
            return error_mod.set_invalid_arg_fmt(
                diag,
                allocator,
                "The provided bitmask's shape is not valid: should be ({d}, )",
                .{buffer_size},
            );
        }
        if (index != 0) {
            return error_mod.set_invalid_arg(
                diag,
                allocator,
                "The index should be 0 when the bitmask is 1D",
            );
        }
    } else if (shape.len == 2) {
        if (shape[1] != buffer_size) {
            return error_mod.set_invalid_arg_fmt(
                diag,
                allocator,
                "The provided bitmask's shape is not valid: should be (batch_size, {d})",
                .{buffer_size},
            );
        }
        if (index < 0 or @as(i64, index) >= shape[0]) {
            return error_mod.set_invalid_arg(
                diag,
                allocator,
                "The provided index is out of bounds",
            );
        }
    } else {
        return error_mod.set_invalid_arg_fmt(
            diag,
            allocator,
            "The provided bitmask's shape is not valid: should be (batch_size, {d})",
            .{buffer_size},
        );
    }
    const start: usize = @as(usize, @intCast(index)) * @as(usize, @intCast(buffer_size));
    return .{ .start = start, .end = start + @as(usize, @intCast(buffer_size)) };
}

/// Allocates a `batch_size * get_bitmask_size(vocab_size)` bitmask buffer, initialized to
/// all-ones (`-1`, every token allowed). Caller owns the returned slice.
pub fn allocate_token_bitmask(allocator: Allocator, batch_size: i32, vocab_size: i32) Allocator.Error![]i32 {
    const total: usize = @intCast(batch_size * get_bitmask_size(vocab_size));
    const buf = try allocator.alloc(i32, total);
    @memset(buf, -1);
    return buf;
}

/// Resets every word to all-ones (every token allowed).
pub fn reset_token_bitmask(bitmask: []i32) void {
    @memset(bitmask, -1);
}

fn bit_is_set(row_words: []const i32, token: i32) bool {
    const word: usize = @intCast(@divTrunc(token, BITS_PER_WORD));
    const offset: u5 = @intCast(@rem(token, BITS_PER_WORD));
    return ((@as(u32, @bitCast(row_words[word])) >> offset) & 1) != 0;
}

fn bitmask_row(bitmask: []const i32, vocab_size: i32, index: i32) []const i32 {
    const size: usize = @intCast(get_bitmask_size(vocab_size));
    const start: usize = @as(usize, @intCast(index)) * size;
    return bitmask[start .. start + size];
}

/// Returns the ids of rejected (zero-bit) tokens in batch entry `index` (caller owns slice).
pub fn get_masked_tokens_from_bitmask(
    allocator: Allocator,
    bitmask: []const i32,
    vocab_size: i32,
    index: i32,
) Allocator.Error![]i32 {
    const r = bitmask_row(bitmask, vocab_size, index);
    var out: std.ArrayList(i32) = .empty;
    errdefer out.deinit(allocator);
    var t: i32 = 0;
    while (t < vocab_size) : (t += 1) {
        if (!bit_is_set(r, t)) {
            try out.append(allocator, t);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// First-class managed or borrowed token bitmask with SIMD logit masking and fast bit queries.
pub const TokenBitmask = struct {
    words: []i32,
    batch_size: usize,
    vocab_size: usize,
    words_per_row: usize,
    owned_allocator: ?Allocator = null,

    /// Allocates an owned single-row bitmask with all tokens allowed.
    pub fn init(allocator: Allocator, vocab_size: usize) Allocator.Error!TokenBitmask {
        return initBatch(allocator, 1, vocab_size);
    }

    /// Allocates an owned batched bitmask (`batch_size * ceil(vocab_size / 32)` words), initialized to all-ones.
    pub fn initBatch(allocator: Allocator, batch_size: usize, vocab_size: usize) Allocator.Error!TokenBitmask {
        const wpr: usize = @intCast(get_bitmask_size(@intCast(vocab_size)));
        const words = try allocator.alloc(i32, batch_size * wpr);
        @memset(words, -1);
        return .{
            .words = words,
            .batch_size = batch_size,
            .vocab_size = vocab_size,
            .words_per_row = wpr,
            .owned_allocator = allocator,
        };
    }

    /// Wraps a caller-owned bitmask buffer without taking ownership.
    pub fn fromSlice(words: []i32, batch_size: usize, vocab_size: usize) MatcherError!TokenBitmask {
        const wpr: usize = @intCast(get_bitmask_size(@intCast(vocab_size)));
        if (words.len < batch_size * wpr) return error.InvalidArgument;
        return .{
            .words = words[0 .. batch_size * wpr],
            .batch_size = batch_size,
            .vocab_size = vocab_size,
            .words_per_row = wpr,
            .owned_allocator = null,
        };
    }

    pub fn deinit(self: *TokenBitmask) void {
        if (self.owned_allocator) |a| {
            a.free(self.words);
        }
        self.* = undefined;
    }

    pub fn shape(self: TokenBitmask) [2]i64 {
        return .{ @intCast(self.batch_size), @intCast(self.words_per_row) };
    }

    pub fn reset(self: *TokenBitmask) void {
        @memset(self.words, -1);
    }

    pub fn resetRow(self: *TokenBitmask, row: usize) void {
        std.debug.assert(row < self.batch_size);
        @memset(self.rowWordsMut(row), -1);
    }

    pub fn rowWords(self: TokenBitmask, row: usize) []const i32 {
        std.debug.assert(row < self.batch_size);
        const start = row * self.words_per_row;
        return self.words[start .. start + self.words_per_row];
    }

    pub fn rowWordsMut(self: *TokenBitmask, row: usize) []i32 {
        std.debug.assert(row < self.batch_size);
        const start = row * self.words_per_row;
        return self.words[start .. start + self.words_per_row];
    }

    pub fn isAllowed(self: TokenBitmask, token_id: usize) bool {
        return self.isAllowedInRow(0, token_id);
    }

    pub fn isAllowedInRow(self: TokenBitmask, row: usize, token_id: usize) bool {
        if (token_id >= self.vocab_size) return false;
        return bit_is_set(self.rowWords(row), @intCast(token_id));
    }

    pub fn setAllowed(self: *TokenBitmask, token_id: usize, allowed: bool) void {
        self.setAllowedInRow(0, token_id, allowed);
    }

    pub fn setAllowedInRow(self: *TokenBitmask, row: usize, token_id: usize, allowed: bool) void {
        std.debug.assert(token_id < self.vocab_size);
        const rw = self.rowWordsMut(row);
        const word_idx = token_id / 32;
        const bit_idx: u5 = @intCast(token_id % 32);
        const bit_mask: u32 = @as(u32, 1) << bit_idx;
        var u: u32 = @bitCast(rw[word_idx]);
        if (allowed) {
            u |= bit_mask;
        } else {
            u &= ~bit_mask;
        }
        rw[word_idx] = @bitCast(u);
    }

    pub fn countAllowed(self: TokenBitmask) usize {
        return self.countAllowedInRow(0);
    }

    pub fn countAllowedInRow(self: TokenBitmask, row: usize) usize {
        return count_allowed_bits(self.rowWords(row), self.vocab_size);
    }

    pub fn singleAllowedToken(self: TokenBitmask) ?u32 {
        return self.singleAllowedTokenInRow(0);
    }

    pub fn singleAllowedTokenInRow(self: TokenBitmask, row: usize) ?u32 {
        const res = single_token_in_row(self.rowWords(row), self.vocab_size);
        return if (res.is_single) @intCast(res.token_id) else null;
    }

    pub fn applyToLogits(self: TokenBitmask, logits: []f32) void {
        self.applyRowToLogits(0, logits);
    }

    pub fn applyRowToLogits(self: TokenBitmask, row: usize, logits: []f32) void {
        std.debug.assert(logits.len >= self.vocab_size);
        apply_simd_mask(logits[0..self.vocab_size], self.rowWords(row), self.vocab_size);
    }

    pub fn applyBatchToLogits(self: TokenBitmask, logits: []f32, indices: ?[]const i32) void {
        apply_token_bitmask_inplace_cpu_batch(
            logits,
            self.words,
            @intCast(self.vocab_size),
            @intCast(self.batch_size),
            indices,
        );
    }
};

fn last_word_mask(vocab_size: usize) u32 {
    const rem = vocab_size % 32;
    if (rem == 0) return 0xFFFF_FFFF;
    return (@as(u32, 1) << @as(u5, @intCast(rem))) - 1;
}

fn count_allowed_bits(r: []const i32, vocab_size: usize) usize {
    if (vocab_size == 0) return 0;
    const last_idx = (vocab_size - 1) / 32;
    var total: usize = 0;
    for (r[0..last_idx]) |w| {
        total += @popCount(@as(u32, @bitCast(w)));
    }
    const tail_masked = @as(u32, @bitCast(r[last_idx])) & last_word_mask(vocab_size);
    total += @popCount(tail_masked);
    return total;
}

pub const SingleTokenResult = struct {
    is_single: bool,
    token_id: i32,
};

fn single_token_in_row(r: []const i32, vocab_size: usize) SingleTokenResult {
    if (vocab_size == 0) return .{ .is_single = false, .token_id = -1 };
    const last_idx = (vocab_size - 1) / 32;
    var count: usize = 0;
    var found: i32 = -1;
    for (r[0 .. last_idx + 1], 0..) |w, word_idx| {
        var u: u32 = @bitCast(w);
        if (word_idx == last_idx) u &= last_word_mask(vocab_size);
        const pop = @popCount(u);
        if (pop == 0) continue;
        count += pop;
        if (count > 1) return .{ .is_single = false, .token_id = -1 };
        found = @intCast(word_idx * 32 + @ctz(u));
    }
    if (count == 1) {
        return .{ .is_single = true, .token_id = found };
    }
    return .{ .is_single = false, .token_id = -1 };
}

/// If exactly one token is allowed in batch entry `index`, returns `.{ .is_single = true, .token_id = id }`;
/// otherwise `.{ .is_single = false, .token_id = -1 }`.
pub fn is_single_token_bitmask(
    bitmask: []const i32,
    vocab_size: i32,
    index: i32,
) SingleTokenResult {
    const r = bitmask_row(bitmask, vocab_size, index);
    return single_token_in_row(r, @intCast(@max(vocab_size, 0)));
}

/// Applies a single-row bitmask to `logits` in place, setting every rejected token's logit to `-inf`.
pub fn apply_token_bitmask_inplace_cpu(
    logits: []f32,
    bitmask: []const i32,
    vocab_size: i32,
) void {
    apply_token_bitmask_inplace_cpu_batch(logits, bitmask, vocab_size, 1, null);
}

/// Applies bitmask rows to a batched float32 logits buffer in place using `@Vector(8, f32)` SIMD.
pub fn apply_token_bitmask_inplace_cpu_batch(
    logits: []f32,
    bitmask: []const i32,
    vocab_size: i32,
    batch_size: i32,
    indices: ?[]const i32,
) void {
    const words: usize = @intCast(get_bitmask_size(vocab_size));
    const vocab: usize = @intCast(vocab_size);
    const batch: usize = @intCast(batch_size);
    std.debug.assert(logits.len >= batch * vocab);

    if (indices) |idxs| {
        for (idxs) |row_i32| {
            const row_idx: usize = @intCast(row_i32);
            apply_row(logits, bitmask, vocab, batch, words, row_idx);
        }
    } else {
        std.debug.assert(bitmask.len == batch * words);
        for (0..batch) |row_idx| {
            apply_row(logits, bitmask, vocab, batch, words, row_idx);
        }
    }
}

fn apply_row(
    logits: []f32,
    bitmask: []const i32,
    vocab: usize,
    batch: usize,
    words: usize,
    row_idx: usize,
) void {
    std.debug.assert(row_idx < batch);
    std.debug.assert((row_idx + 1) * words <= bitmask.len);
    const bm = bitmask[row_idx * words .. (row_idx + 1) * words];
    const logits_row = logits[row_idx * vocab .. (row_idx + 1) * vocab];
    apply_simd_mask(logits_row, bm, vocab);
}

fn apply_simd_mask(logits_row: []f32, bm: []const i32, vocab: usize) void {
    if (vocab == 0) return;
    const mask_bits: @Vector(8, u8) = .{ 1, 2, 4, 8, 16, 32, 64, 128 };
    const zeros_u8: @Vector(8, u8) = @splat(0);
    const neg_inf: @Vector(8, f32) = @splat(-std.math.inf(f32));

    var t: usize = 0;
    while (t + 32 <= vocab) : (t += 32) {
        const w = bm[t >> 5];
        if (w == -1) continue;
        if (w == 0) {
            @memset(logits_row[t .. t + 32], -std.math.inf(f32));
            continue;
        }
        const uword: u32 = @bitCast(w);
        inline for (0..4) |lane_group| {
            const byte_bits: u8 = @truncate(uword >> @intCast(lane_group * 8));
            const pred = (@as(@Vector(8, u8), @splat(byte_bits)) & mask_bits) != zeros_u8;
            const base = t + lane_group * 8;
            const cur: @Vector(8, f32) = logits_row[base..][0..8].*;
            logits_row[base..][0..8].* = @select(f32, pred, cur, neg_inf);
        }
    }
    if (t < vocab) {
        const uword: u32 = @bitCast(bm[t >> 5]);
        var bit_off: usize = 0;
        while (t + 8 <= vocab) {
            const byte_bits: u8 = @truncate(uword >> @as(u5, @intCast(bit_off)));
            const pred = (@as(@Vector(8, u8), @splat(byte_bits)) & mask_bits) != zeros_u8;
            const cur: @Vector(8, f32) = logits_row[t..][0..8].*;
            logits_row[t..][0..8].* = @select(f32, pred, cur, neg_inf);
            t += 8;
            bit_off += 8;
        }
        while (t < vocab) {
            if (((uword >> @as(u5, @intCast(bit_off))) & 1) == 0) {
                logits_row[t] = -std.math.inf(f32);
            }
            t += 1;
            bit_off += 1;
        }
    }
}
