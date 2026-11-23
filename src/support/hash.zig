//! Hash combining.

const std = @import("std");

/// The boost `hash_combine` golden-ratio mixing constant.
const HASH_MIX: u64 = 0x9e37_79b9_7f4a_7c15;

/// Mixes `value` into `seed` (boost `hash_combine`).
pub inline fn hash_combine_binary(seed: *u64, value: u64) void {
    seed.* ^= value +% HASH_MIX +% (seed.* << 6) +% (seed.* >> 2);
}

/// Combines a sequence of (already-hashed) values into a single hash, starting from a
/// zero seed.
pub fn hash_combine(values: []const u64) u64 {
    var seed: u64 = 0;
    for (values) |value| {
        hash_combine_binary(&seed, value);
    }
    return seed;
}

test "hash_combine" {
    // Deterministic and order-sensitive.
    const a = hash_combine(&.{ 1, 2, 3 });
    const b = hash_combine(&.{ 1, 2, 3 });
    const c = hash_combine(&.{ 3, 2, 1 });
    try std.testing.expectEqual(a, b);
    try std.testing.expect(a != c);

    // Empty sequence hashes to zero.
    try std.testing.expectEqual(@as(u64, 0), hash_combine(&.{}));

    // Matches a manual fold with hash_combine_binary.
    var seed: u64 = 0;
    hash_combine_binary(&seed, 42);
    hash_combine_binary(&seed, 7);
    try std.testing.expectEqual(seed, hash_combine(&.{ 42, 7 }));
}
