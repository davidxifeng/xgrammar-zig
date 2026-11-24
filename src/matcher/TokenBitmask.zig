//! Token bitmasks for grammar-guided generation (`token_bitmask.rs`),
//! owning/borrowed views, `@ctz`-accelerated mask queries, and `@Vector(8, f32)` SIMD logit masking.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Diagnostic = @import("../Diagnostic.zig").Diagnostic;
const matcher_mod = @import("../matcher.zig");
const MatcherError = matcher_mod.MatcherError;

/// Bits packed per bitmask word.
pub const BITS_PER_WORD: usize = 32;

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
pub fn dlType() BitmaskDlType {
    return .{
        .code = 0,
        .bits = 32,
        .lanes = 1,
    };
}

/// The number of `i32` words needed to hold `vocab_size` bits: `ceil(vocab_size / 32)`.
pub fn bitmaskSize(vocab_size: usize) usize {
    return std.math.divCeil(usize, vocab_size, BITS_PER_WORD) catch unreachable;
}

/// Resets every word in `words` to all-ones (`-1`, every token allowed).
pub fn resetBitmaskWords(words: []i32) void {
    @memset(words, -1);
}

/// Half-open `[start, end)` word indices for one row in a batched bitmask buffer.
pub const RowRange = struct {
    start: usize,
    end: usize,
};

/// Validates a raw bitmask `shape` for `vocab_size` and returns the word range `[start, end)`
/// of row `index`, populating `diag` on error when provided.
pub fn bitmaskRowRange(
    allocator: Allocator,
    shape: []const i64,
    vocab_size: usize,
    index: usize,
    diag: ?*Diagnostic,
) MatcherError!RowRange {
    const buffer_size: usize = bitmaskSize(vocab_size);
    const buffer_size_i64: i64 = std.math.cast(i64, buffer_size) orelse return error.InvalidArgument;
    if (shape.len == 1) {
        if (shape[0] != buffer_size_i64) {
            if (diag) |d| try d.setFmt(
                allocator,
                .message,
                "The provided bitmask's shape is not valid: should be ({d}, )",
                .{buffer_size},
            );
            return error.InvalidArgument;
        }
        if (index != 0) {
            if (diag) |d| d.setStatic(.message, "The index should be 0 when the bitmask is 1D");
            return error.InvalidArgument;
        }
    } else if (shape.len == 2) {
        if (shape[1] != buffer_size_i64 or shape[0] < 0) {
            if (diag) |d| try d.setFmt(
                allocator,
                .message,
                "The provided bitmask's shape is not valid: should be (batch_size, {d})",
                .{buffer_size},
            );
            return error.InvalidArgument;
        }
        if (index >= @as(usize, @intCast(shape[0]))) {
            if (diag) |d| d.setStatic(.message, "The provided index is out of bounds");
            return error.InvalidArgument;
        }
    } else {
        if (diag) |d| try d.setFmt(
            allocator,
            .message,
            "The provided bitmask's shape is not valid: should be (batch_size, {d})",
            .{buffer_size},
        );
        return error.InvalidArgument;
    }
    const start = index * buffer_size;
    return .{ .start = start, .end = start + buffer_size };
}

/// Owned batched token bitmask buffer (`batch_size * bitmaskSize(vocab_size)` words).
pub const TokenBitmask = struct {
    allocator: Allocator,
    words: []i32,
    batch_size: usize,
    vocab_size: usize,
    words_per_row: usize,

    /// Allocates an owned batched bitmask initialized to all-ones (every token allowed).
    pub fn init(allocator: Allocator, batch_size: usize, vocab_size: usize) Allocator.Error!TokenBitmask {
        const wpr = bitmaskSize(vocab_size);
        const total = batch_size * wpr;
        const words = try allocator.alloc(i32, total);
        @memset(words, -1);
        return .{
            .allocator = allocator,
            .words = words,
            .batch_size = batch_size,
            .vocab_size = vocab_size,
            .words_per_row = wpr,
        };
    }

    /// Allocates an owned single-row bitmask initialized to all-ones.
    pub fn initSingle(allocator: Allocator, vocab_size: usize) Allocator.Error!TokenBitmask {
        return init(allocator, 1, vocab_size);
    }

    pub fn deinit(self: *TokenBitmask) void {
        self.allocator.free(self.words);
        self.* = undefined;
    }

    /// Returns a borrowed mutable non-owning view over this bitmask (no `deinit`).
    pub fn view(self: *TokenBitmask) TokenBitmaskView {
        return .{
            .words = self.words,
            .batch_size = self.batch_size,
            .vocab_size = self.vocab_size,
            .words_per_row = self.words_per_row,
        };
    }

    /// Returns a borrowed read-only non-owning view over this bitmask (no `deinit`).
    pub fn constView(self: *const TokenBitmask) TokenBitmaskConstView {
        return .{
            .words = self.words,
            .batch_size = self.batch_size,
            .vocab_size = self.vocab_size,
            .words_per_row = self.words_per_row,
        };
    }

    pub inline fn vocabSize(self: *const TokenBitmask) usize {
        return self.vocab_size;
    }

    pub inline fn batchSize(self: *const TokenBitmask) usize {
        return self.batch_size;
    }

    pub inline fn wordsPerRow(self: *const TokenBitmask) usize {
        return self.words_per_row;
    }

    pub fn shape(self: *const TokenBitmask) [2]i64 {
        return self.constView().shape();
    }

    pub fn row(self: *TokenBitmask, row_idx: usize) []i32 {
        return self.view().row(row_idx);
    }

    pub fn constRow(self: *const TokenBitmask, row_idx: usize) []const i32 {
        return self.constView().constRow(row_idx);
    }

    pub fn reset(self: *TokenBitmask) void {
        self.view().reset();
    }

    pub fn resetRow(self: *TokenBitmask, row_idx: usize) void {
        self.view().resetRow(row_idx);
    }

    pub fn isAllowed(self: *const TokenBitmask, token_id: usize) bool {
        return self.constView().isAllowed(token_id);
    }

    pub fn isAllowedInRow(self: *const TokenBitmask, row_idx: usize, token_id: usize) bool {
        return self.constView().isAllowedInRow(row_idx, token_id);
    }

    pub fn setAllowed(self: *TokenBitmask, token_id: usize, allowed: bool) void {
        self.view().setAllowed(token_id, allowed);
    }

    pub fn setAllowedInRow(self: *TokenBitmask, row_idx: usize, token_id: usize, allowed: bool) void {
        self.view().setAllowedInRow(row_idx, token_id, allowed);
    }

    pub fn countAllowed(self: *const TokenBitmask) usize {
        return self.constView().countAllowed();
    }

    pub fn countAllowedInRow(self: *const TokenBitmask, row_idx: usize) usize {
        return self.constView().countAllowedInRow(row_idx);
    }

    pub fn singleAllowedToken(self: *const TokenBitmask) ?u32 {
        return self.constView().singleAllowedToken();
    }

    pub fn singleAllowedTokenInRow(self: *const TokenBitmask, row_idx: usize) ?u32 {
        return self.constView().singleAllowedTokenInRow(row_idx);
    }

    pub fn maskedTokens(self: *const TokenBitmask, allocator: Allocator, row_idx: usize) Allocator.Error![]u32 {
        return self.constView().maskedTokens(allocator, row_idx);
    }

    pub fn applyToLogits(self: *const TokenBitmask, logits: []f32) void {
        self.constView().applyToLogits(logits);
    }

    pub fn applyRowToLogits(self: *const TokenBitmask, row_idx: usize, logits: []f32) void {
        self.constView().applyRowToLogits(row_idx, logits);
    }

    pub fn applyBatchToLogits(self: *const TokenBitmask, logits: []f32, indices: ?[]const usize) void {
        self.constView().applyBatchToLogits(logits, indices);
    }
};

/// Borrowed mutable non-owning view over caller-owned `[]i32` words.
/// Does not own memory and has no `deinit()`.
pub const TokenBitmaskView = struct {
    words: []i32,
    batch_size: usize,
    vocab_size: usize,
    words_per_row: usize,

    /// Validates that `words` holds at least `batch_size * bitmaskSize(vocab_size)` words
    /// and returns a view over the exact prefix.
    pub fn init(words: []i32, batch_size: usize, vocab_size: usize) MatcherError!TokenBitmaskView {
        const wpr = bitmaskSize(vocab_size);
        const needed = std.math.mul(usize, batch_size, wpr) catch return error.InvalidArgument;
        if (words.len < needed) return error.InvalidArgument;
        return .{
            .words = words[0..needed],
            .batch_size = batch_size,
            .vocab_size = vocab_size,
            .words_per_row = wpr,
        };
    }

    pub inline fn asConst(self: TokenBitmaskView) TokenBitmaskConstView {
        return .{
            .words = self.words,
            .batch_size = self.batch_size,
            .vocab_size = self.vocab_size,
            .words_per_row = self.words_per_row,
        };
    }

    pub inline fn vocabSize(self: TokenBitmaskView) usize {
        return self.vocab_size;
    }

    pub inline fn batchSize(self: TokenBitmaskView) usize {
        return self.batch_size;
    }

    pub inline fn wordsPerRow(self: TokenBitmaskView) usize {
        return self.words_per_row;
    }

    pub fn shape(self: TokenBitmaskView) [2]i64 {
        return self.asConst().shape();
    }

    pub fn row(self: TokenBitmaskView, row_idx: usize) []i32 {
        std.debug.assert(row_idx < self.batch_size);
        const start = row_idx * self.words_per_row;
        return self.words[start .. start + self.words_per_row];
    }

    pub fn constRow(self: TokenBitmaskView, row_idx: usize) []const i32 {
        return self.asConst().constRow(row_idx);
    }

    pub fn rowRange(self: TokenBitmaskView, row_idx: usize) MatcherError!RowRange {
        return self.asConst().rowRange(row_idx);
    }

    pub fn rowRangeDiag(
        self: TokenBitmaskView,
        allocator: Allocator,
        row_idx: usize,
        diag: ?*Diagnostic,
    ) MatcherError!RowRange {
        return self.asConst().rowRangeDiag(allocator, row_idx, diag);
    }

    pub fn reset(self: TokenBitmaskView) void {
        @memset(self.words, -1);
    }

    pub fn resetRow(self: TokenBitmaskView, row_idx: usize) void {
        @memset(self.row(row_idx), -1);
    }

    pub fn isAllowed(self: TokenBitmaskView, token_id: usize) bool {
        return self.asConst().isAllowed(token_id);
    }

    pub fn isAllowedInRow(self: TokenBitmaskView, row_idx: usize, token_id: usize) bool {
        return self.asConst().isAllowedInRow(row_idx, token_id);
    }

    pub fn setAllowed(self: TokenBitmaskView, token_id: usize, allowed: bool) void {
        self.setAllowedInRow(0, token_id, allowed);
    }

    pub fn setAllowedInRow(self: TokenBitmaskView, row_idx: usize, token_id: usize, allowed: bool) void {
        std.debug.assert(token_id < self.vocab_size);
        const rw = self.row(row_idx);
        const word_idx = token_id / BITS_PER_WORD;
        const bit_idx: u5 = @intCast(token_id % BITS_PER_WORD);
        const bit_mask: u32 = @as(u32, 1) << bit_idx;
        var u: u32 = @bitCast(rw[word_idx]);
        if (allowed) {
            u |= bit_mask;
        } else {
            u &= ~bit_mask;
        }
        rw[word_idx] = @bitCast(u);
    }

    pub fn countAllowed(self: TokenBitmaskView) usize {
        return self.asConst().countAllowed();
    }

    pub fn countAllowedInRow(self: TokenBitmaskView, row_idx: usize) usize {
        return self.asConst().countAllowedInRow(row_idx);
    }

    pub fn singleAllowedToken(self: TokenBitmaskView) ?u32 {
        return self.asConst().singleAllowedToken();
    }

    pub fn singleAllowedTokenInRow(self: TokenBitmaskView, row_idx: usize) ?u32 {
        return self.asConst().singleAllowedTokenInRow(row_idx);
    }

    pub fn maskedTokens(self: TokenBitmaskView, allocator: Allocator, row_idx: usize) Allocator.Error![]u32 {
        return self.asConst().maskedTokens(allocator, row_idx);
    }

    pub fn applyToLogits(self: TokenBitmaskView, logits: []f32) void {
        self.asConst().applyToLogits(logits);
    }

    pub fn applyRowToLogits(self: TokenBitmaskView, row_idx: usize, logits: []f32) void {
        self.asConst().applyRowToLogits(row_idx, logits);
    }

    pub fn applyBatchToLogits(self: TokenBitmaskView, logits: []f32, indices: ?[]const usize) void {
        self.asConst().applyBatchToLogits(logits, indices);
    }
};

/// Borrowed read-only non-owning view over caller-owned `[]const i32` words.
/// Does not own memory and has no `deinit()`.
pub const TokenBitmaskConstView = struct {
    words: []const i32,
    batch_size: usize,
    vocab_size: usize,
    words_per_row: usize,

    pub fn init(words: []const i32, batch_size: usize, vocab_size: usize) MatcherError!TokenBitmaskConstView {
        const wpr = bitmaskSize(vocab_size);
        const needed = std.math.mul(usize, batch_size, wpr) catch return error.InvalidArgument;
        if (words.len < needed) return error.InvalidArgument;
        return .{
            .words = words[0..needed],
            .batch_size = batch_size,
            .vocab_size = vocab_size,
            .words_per_row = wpr,
        };
    }

    pub inline fn vocabSize(self: TokenBitmaskConstView) usize {
        return self.vocab_size;
    }

    pub inline fn batchSize(self: TokenBitmaskConstView) usize {
        return self.batch_size;
    }

    pub inline fn wordsPerRow(self: TokenBitmaskConstView) usize {
        return self.words_per_row;
    }

    pub fn shape(self: TokenBitmaskConstView) [2]i64 {
        return .{ @intCast(self.batch_size), @intCast(self.words_per_row) };
    }

    pub fn constRow(self: TokenBitmaskConstView, row_idx: usize) []const i32 {
        std.debug.assert(row_idx < self.batch_size);
        const start = row_idx * self.words_per_row;
        return self.words[start .. start + self.words_per_row];
    }

    pub fn rowRange(self: TokenBitmaskConstView, row_idx: usize) MatcherError!RowRange {
        if (row_idx >= self.batch_size) return error.InvalidArgument;
        const start = row_idx * self.words_per_row;
        return .{ .start = start, .end = start + self.words_per_row };
    }

    pub fn rowRangeDiag(
        self: TokenBitmaskConstView,
        allocator: Allocator,
        row_idx: usize,
        diag: ?*Diagnostic,
    ) MatcherError!RowRange {
        if (row_idx >= self.batch_size) {
            if (diag) |d| {
                try d.setFmt(
                    allocator,
                    .message,
                    "The provided index {d} is out of bounds for batch size {d}",
                    .{ row_idx, self.batch_size },
                );
            }
            return error.InvalidArgument;
        }
        const start = row_idx * self.words_per_row;
        return .{ .start = start, .end = start + self.words_per_row };
    }

    pub fn isAllowed(self: TokenBitmaskConstView, token_id: usize) bool {
        return self.isAllowedInRow(0, token_id);
    }

    pub fn isAllowedInRow(self: TokenBitmaskConstView, row_idx: usize, token_id: usize) bool {
        if (token_id >= self.vocab_size) return false;
        return bitIsSet(self.constRow(row_idx), token_id);
    }

    pub fn countAllowed(self: TokenBitmaskConstView) usize {
        return self.countAllowedInRow(0);
    }

    pub fn countAllowedInRow(self: TokenBitmaskConstView, row_idx: usize) usize {
        return countAllowedBits(self.constRow(row_idx), self.vocab_size);
    }

    pub fn singleAllowedToken(self: TokenBitmaskConstView) ?u32 {
        return self.singleAllowedTokenInRow(0);
    }

    pub fn singleAllowedTokenInRow(self: TokenBitmaskConstView, row_idx: usize) ?u32 {
        return singleTokenInRow(self.constRow(row_idx), self.vocab_size);
    }

    pub fn maskedTokens(self: TokenBitmaskConstView, allocator: Allocator, row_idx: usize) Allocator.Error![]u32 {
        return getMaskedTokensFromRow(allocator, self.constRow(row_idx), self.vocab_size);
    }

    pub fn applyToLogits(self: TokenBitmaskConstView, logits: []f32) void {
        self.applyRowToLogits(0, logits);
    }

    pub fn applyRowToLogits(self: TokenBitmaskConstView, row_idx: usize, logits: []f32) void {
        std.debug.assert(logits.len >= self.vocab_size);
        applySimdMask(logits[0..self.vocab_size], self.constRow(row_idx), self.vocab_size);
    }

    pub fn applyBatchToLogits(self: TokenBitmaskConstView, logits: []f32, indices: ?[]const usize) void {
        applyTokenBitmaskInplaceCpuBatch(logits, self.words, self.vocab_size, self.batch_size, indices);
    }
};

inline fn bitIsSet(row_words: []const i32, token: usize) bool {
    const word = token / BITS_PER_WORD;
    const offset: u5 = @intCast(token % BITS_PER_WORD);
    return ((@as(u32, @bitCast(row_words[word])) >> offset) & 1) != 0;
}

inline fn lastWordMask(vocab_size: usize) u32 {
    const rem = vocab_size % BITS_PER_WORD;
    if (rem == 0) return 0xFFFF_FFFF;
    return (@as(u32, 1) << @as(u5, @intCast(rem))) - 1;
}

fn countAllowedBits(r: []const i32, vocab_size: usize) usize {
    if (vocab_size == 0) return 0;
    const last_idx = (vocab_size - 1) / BITS_PER_WORD;
    var total: usize = 0;
    for (r[0..last_idx]) |w| {
        total += @popCount(@as(u32, @bitCast(w)));
    }
    const tail_masked = @as(u32, @bitCast(r[last_idx])) & lastWordMask(vocab_size);
    total += @popCount(tail_masked);
    return total;
}

fn singleTokenInRow(r: []const i32, vocab_size: usize) ?u32 {
    if (vocab_size == 0) return null;
    const last_idx = (vocab_size - 1) / BITS_PER_WORD;
    var count: usize = 0;
    var found: u32 = 0;
    for (r[0 .. last_idx + 1], 0..) |w, word_idx| {
        var u: u32 = @bitCast(w);
        if (word_idx == last_idx) u &= lastWordMask(vocab_size);
        const pop = @popCount(u);
        if (pop == 0) continue;
        count += pop;
        if (count > 1) return null;
        found = @intCast(word_idx * BITS_PER_WORD + @ctz(u));
    }
    if (count == 1) return found;
    return null;
}

fn getMaskedTokensFromRow(allocator: Allocator, r: []const i32, vocab_size: usize) Allocator.Error![]u32 {
    if (vocab_size == 0) return allocator.alloc(u32, 0);
    const num_allowed = countAllowedBits(r, vocab_size);
    const num_rejected = vocab_size - num_allowed;
    const out = try allocator.alloc(u32, num_rejected);
    if (num_rejected == 0) return out;

    const last_idx = (vocab_size - 1) / BITS_PER_WORD;
    const last_mask = lastWordMask(vocab_size);
    var write: usize = 0;
    for (r[0 .. last_idx + 1], 0..) |w, word_idx| {
        var rejected: u32 = ~@as(u32, @bitCast(w));
        if (word_idx == last_idx) rejected &= last_mask;
        const base: u32 = @intCast(word_idx * BITS_PER_WORD);
        while (rejected != 0) {
            const bit: u32 = @ctz(rejected);
            out[write] = base + bit;
            write += 1;
            rejected &= rejected - 1;
        }
    }
    std.debug.assert(write == num_rejected);
    return out;
}

/// Returns the ids of rejected (zero-bit) tokens in batch entry `index` (caller owns slice).
pub fn getMaskedTokensFromBitmask(
    allocator: Allocator,
    bitmask: []const i32,
    vocab_size: usize,
    index: usize,
) Allocator.Error![]u32 {
    const wpr = bitmaskSize(vocab_size);
    const start = index * wpr;
    std.debug.assert(start + wpr <= bitmask.len);
    return getMaskedTokensFromRow(allocator, bitmask[start .. start + wpr], vocab_size);
}

/// Returns the sole allowed token id in batch entry `index`, or `null` when zero or multiple tokens are allowed.
pub fn isSingleTokenBitmask(
    bitmask: []const i32,
    vocab_size: usize,
    index: usize,
) ?u32 {
    const wpr = bitmaskSize(vocab_size);
    const start = index * wpr;
    std.debug.assert(start + wpr <= bitmask.len);
    return singleTokenInRow(bitmask[start .. start + wpr], vocab_size);
}

/// Applies a single-row bitmask to `logits` in place, setting every rejected token's logit to `-inf`.
pub fn applyTokenBitmaskInplaceCpu(
    logits: []f32,
    bitmask: []const i32,
    vocab_size: usize,
) void {
    applyTokenBitmaskInplaceCpuBatch(logits, bitmask, vocab_size, 1, null);
}

/// Applies bitmask rows to a batched `f32` logits buffer in place using `@Vector(8, f32)` SIMD.
pub fn applyTokenBitmaskInplaceCpuBatch(
    logits: []f32,
    bitmask: []const i32,
    vocab_size: usize,
    batch_size: usize,
    indices: ?[]const usize,
) void {
    const words = bitmaskSize(vocab_size);
    std.debug.assert(logits.len >= batch_size * vocab_size);

    if (indices) |idxs| {
        for (idxs) |row_idx| {
            applyRow(logits, bitmask, vocab_size, batch_size, words, row_idx);
        }
    } else {
        std.debug.assert(bitmask.len >= batch_size * words);
        for (0..batch_size) |row_idx| {
            applyRow(logits, bitmask, vocab_size, batch_size, words, row_idx);
        }
    }
}

fn applyRow(
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
    applySimdMask(logits_row, bm, vocab);
}

fn applySimdMask(logits_row: []f32, bm: []const i32, vocab: usize) void {
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
        const w = bm[t >> 5];
        if (w == -1) return;
        if (w == 0) {
            @memset(logits_row[t..vocab], -std.math.inf(f32));
            return;
        }
        const uword: u32 = @bitCast(w);
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

fn applyScalarMaskRef(logits_row: []f32, bm: []const i32, vocab: usize) void {
    for (0..vocab) |t| {
        if (!bitIsSet(bm, t)) {
            logits_row[t] = -std.math.inf(f32);
        }
    }
}

test "SIMD applyTokenBitmaskInplaceCpu matches scalar bit-for-bit across edge vocab sizes and float values" {
    const a = std.testing.allocator;
    const edge_vocabs = [_]usize{ 1, 7, 8, 31, 32, 33, 63, 64, 65, 100 };
    const edge_floats = [_]f32{
        0.0,
        -0.0,
        1.5,
        -42.25,
        std.math.inf(f32),
        -std.math.inf(f32),
        std.math.nan(f32),
        @bitCast(@as(u32, 0x7FC0_1234)), // payload NaN
        @bitCast(@as(u32, 0x0000_0001)), // subnormal
    };
    const patterns = [_]u32{
        0x0000_0000,
        0xFFFF_FFFF,
        0xAAAA_5555,
        0x8000_0001,
        0x0F0F_F0F0,
        0x0102_0408,
    };

    for (edge_vocabs) |vocab| {
        var bm = try TokenBitmask.initSingle(a, vocab);
        defer bm.deinit();

        const simd_logits = try a.alloc(f32, vocab);
        defer a.free(simd_logits);
        const scalar_logits = try a.alloc(f32, vocab);
        defer a.free(scalar_logits);

        for (patterns, 0..) |pat_base, p_idx| {
            for (bm.words, 0..) |*w, w_idx| {
                const mixed: u32 = pat_base ^ @as(u32, @truncate(w_idx * 0x9E37_79B9 + p_idx));
                w.* = if (p_idx == 0) 0 else if (p_idx == 1) -1 else @bitCast(mixed);
            }
            for (0..vocab) |t| {
                const v = edge_floats[(t + p_idx) % edge_floats.len];
                simd_logits[t] = v;
                scalar_logits[t] = v;
            }

            bm.applyToLogits(simd_logits);
            applyScalarMaskRef(scalar_logits, bm.words, vocab);

            for (simd_logits, scalar_logits) |got, exp| {
                try std.testing.expectEqual(@as(u32, @bitCast(exp)), @as(u32, @bitCast(got)));
            }

            // Also verify maskedTokens and singleAllowedToken against scalar reference.
            const masked = try bm.maskedTokens(a, 0);
            defer a.free(masked);
            var expected_allowed: usize = 0;
            var sole: ?u32 = null;
            var expected_masked_idx: usize = 0;
            for (0..vocab) |t| {
                if (bm.isAllowed(t)) {
                    expected_allowed += 1;
                    sole = if (expected_allowed == 1) @intCast(t) else null;
                } else {
                    try std.testing.expectEqual(@as(u32, @intCast(t)), masked[expected_masked_idx]);
                    expected_masked_idx += 1;
                }
            }
            try std.testing.expectEqual(masked.len, expected_masked_idx);
            try std.testing.expectEqual(expected_allowed, bm.countAllowed());
            try std.testing.expectEqual(sole, bm.singleAllowedToken());
        }
    }
}

test "TokenBitmaskView non-owning slice view, dlType, bitmaskRowRange, and batch logit application" {
    const a = std.testing.allocator;
    const dl = dlType();
    try std.testing.expectEqual(@as(u8, 0), dl.code);
    try std.testing.expectEqual(@as(u8, 32), dl.bits);
    try std.testing.expectEqual(@as(u16, 1), dl.lanes);

    var raw = [_]i32{ -1, -1, -1, -1 };
    const view = try TokenBitmaskView.init(&raw, 2, 35);
    try std.testing.expectEqual(@as(usize, 2), view.batchSize());
    try std.testing.expectEqual(@as(usize, 35), view.vocabSize());
    try std.testing.expectEqual(@as(usize, 2), view.wordsPerRow());

    view.setAllowedInRow(0, 1, false);
    view.setAllowedInRow(1, 34, false);
    try std.testing.expect(!view.isAllowedInRow(0, 1));
    try std.testing.expect(view.isAllowedInRow(0, 34));
    try std.testing.expect(!view.isAllowedInRow(1, 34));
    try std.testing.expectEqual(@as(usize, 34), view.countAllowedInRow(0));
    try std.testing.expectEqual(@as(usize, 34), view.countAllowedInRow(1));

    const m0 = try view.maskedTokens(a, 0);
    defer a.free(m0);
    try std.testing.expectEqualSlices(u32, &.{1}, m0);

    const m1 = try view.maskedTokens(a, 1);
    defer a.free(m1);
    try std.testing.expectEqualSlices(u32, &.{34}, m1);

    // Partial batch application using indices = &.{1}.
    var logits: [70]f32 = undefined;
    for (&logits, 0..) |*slot, i| slot.* = @floatFromInt(i);
    view.applyBatchToLogits(&logits, &.{1});
    // Row 0 was untouched by indices=&.{1}; row 1 token 34 is -inf.
    try std.testing.expectEqual(@as(f32, 1.0), logits[1]);
    try std.testing.expectEqual(-std.math.inf(f32), logits[35 + 34]);
    try std.testing.expectEqual(@as(f32, 35.0), logits[35]);

    // Too-small backing slice fails cleanly.
    var small = [_]i32{-1};
    try std.testing.expectError(error.InvalidArgument, TokenBitmaskView.init(&small, 2, 35));

    // Shape validation diagnostics.
    var diag: Diagnostic = .{};
    defer diag.deinit(a);
    try std.testing.expectError(error.InvalidArgument, bitmaskRowRange(a, &.{ 2, 1 }, 35, 0, &diag));
    try std.testing.expectEqual(Diagnostic.Kind.message, diag.kind);
    try std.testing.expectError(error.InvalidArgument, bitmaskRowRange(a, &.{ 2, 2 }, 35, 2, &diag));
    try std.testing.expectError(error.InvalidArgument, bitmaskRowRange(a, &.{2}, 35, 1, &diag));
}

test {
    std.testing.refAllDecls(@This());
}
