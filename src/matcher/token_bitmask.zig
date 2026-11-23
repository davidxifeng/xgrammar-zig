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

/// If exactly one token is allowed in batch entry `index`, returns `.{ .is_single = true, .token_id = id }`;
/// otherwise `.{ .is_single = false, .token_id = -1 }`.
pub fn is_single_token_bitmask(
    bitmask: []const i32,
    vocab_size: i32,
    index: i32,
) struct { is_single: bool, token_id: i32 } {
    const r = bitmask_row(bitmask, vocab_size, index);
    var found: i32 = -1;
    var count: usize = 0;
    var t: i32 = 0;
    while (t < vocab_size) : (t += 1) {
        if (bit_is_set(r, t)) {
            count += 1;
            if (count > 1) return .{ .is_single = false, .token_id = -1 };
            found = t;
        }
    }
    if (count == 1) {
        return .{ .is_single = true, .token_id = found };
    }
    return .{ .is_single = false, .token_id = -1 };
}

/// Applies a single-row bitmask to `logits` in place, setting every rejected token's logit to `-inf`.
pub fn apply_token_bitmask_inplace_cpu(
    logits: []f32,
    bitmask: []const i32,
    vocab_size: i32,
) void {
    apply_token_bitmask_inplace_cpu_batch(logits, bitmask, vocab_size, 1, null);
}

/// Applies bitmask rows to a batched float32 logits buffer in place.
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
            apply_row(logits, bitmask, vocab_size, vocab, batch, words, row_idx);
        }
    } else {
        std.debug.assert(bitmask.len == batch * words);
        for (0..batch) |row_idx| {
            apply_row(logits, bitmask, vocab_size, vocab, batch, words, row_idx);
        }
    }
}

fn apply_row(
    logits: []f32,
    bitmask: []const i32,
    vocab_size: i32,
    vocab: usize,
    batch: usize,
    words: usize,
    row_idx: usize,
) void {
    std.debug.assert(row_idx < batch);
    std.debug.assert((row_idx + 1) * words <= bitmask.len);
    const bm = bitmask[row_idx * words .. (row_idx + 1) * words];
    const logits_row = logits[row_idx * vocab .. (row_idx + 1) * vocab];
    var token: i32 = 0;
    while (token < vocab_size) : (token += 1) {
        if (!bit_is_set(bm, token)) {
            logits_row[@intCast(token)] = -std.math.inf(f32);
        }
    }
}
