//! Packed UTF-8 character ranges.
//!
//! The packed format stores the UTF-8 bytes of one codepoint left-aligned to its encoded length,
//! big-endian in a `u32`: a 2-byte character is `(byte0 << 8) | byte1`. Ranges of packed values
//! become FSM edges, with intermediate states for the continuation bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fsm_mod = @import("fsm.zig");
const Fsm = fsm_mod.Fsm;

/// The largest 1-byte (ASCII) packed value.
pub const MAX_1_BYTE_UNICODE: u32 = 0x7F;
const MIN_2_BYTES_UNICODE: u32 = 0xC080;
const MAX_2_BYTES_UNICODE: u32 = 0xDFBF;
const MIN_3_BYTES_UNICODE: u32 = 0x00E0_8080;
const MAX_3_BYTES_UNICODE: u32 = 0x00EF_BFBF;
const MIN_4_BYTES_UNICODE: u32 = 0xF080_8080;
const MAX_4_BYTES_UNICODE: u32 = 0xF7BF_BFBF;

/// Converts a Unicode codepoint to the packed UTF-8 format.
pub fn codepoint_to_packed_utf8(codepoint: u32) u32 {
    if (codepoint <= 0x7F) {
        return codepoint;
    } else if (codepoint <= 0x7FF) {
        const byte0 = 0xC0 | ((codepoint >> 6) & 0x1F);
        const byte1 = 0x80 | (codepoint & 0x3F);
        return (byte0 << 8) | byte1;
    } else if (codepoint <= 0xFFFF) {
        const byte0 = 0xE0 | ((codepoint >> 12) & 0x0F);
        const byte1 = 0x80 | ((codepoint >> 6) & 0x3F);
        const byte2 = 0x80 | (codepoint & 0x3F);
        return (byte0 << 16) | (byte1 << 8) | byte2;
    } else {
        const byte0 = 0xF0 | ((codepoint >> 18) & 0x07);
        const byte1 = 0x80 | ((codepoint >> 12) & 0x3F);
        const byte2 = 0x80 | ((codepoint >> 6) & 0x3F);
        const byte3 = 0x80 | (codepoint & 0x3F);
        return (byte0 << 24) | (byte1 << 16) | (byte2 << 8) | byte3;
    }
}

/// Adds edges (with intermediate states for multi-byte characters) from `from` to `to`
/// accepting every UTF-8 encoded character in the packed range `[min, max]`. Both bounds are
/// clamped to valid packed values first.
///
/// Panics if `min > max`.
pub fn add_packed_utf8_range_edges(fsm: *Fsm, from: i32, to: i32, min_in: u32, max_in: u32) Allocator.Error!void {
    var min = min_in;
    var max = max_in;
    std.debug.assert(min <= max); // invalid character range
    if (max > MAX_4_BYTES_UNICODE) {
        max = MAX_4_BYTES_UNICODE;
    } else if (max > MAX_3_BYTES_UNICODE) {
        if (max < MIN_4_BYTES_UNICODE) max = MAX_3_BYTES_UNICODE;
    } else if (max > MAX_2_BYTES_UNICODE) {
        if (max < MIN_3_BYTES_UNICODE) max = MAX_2_BYTES_UNICODE;
    } else if (max < MIN_2_BYTES_UNICODE and max > MAX_1_BYTE_UNICODE) {
        max = MAX_1_BYTE_UNICODE;
    }

    if (min > MAX_4_BYTES_UNICODE) {
        min = MAX_4_BYTES_UNICODE;
    } else if (min > MAX_3_BYTES_UNICODE) {
        if (min < MIN_4_BYTES_UNICODE) min = MIN_4_BYTES_UNICODE;
    } else if (min > MAX_2_BYTES_UNICODE) {
        if (min < MIN_3_BYTES_UNICODE) min = MIN_3_BYTES_UNICODE;
    } else if (min < MIN_2_BYTES_UNICODE and min > MAX_1_BYTE_UNICODE) {
        min = MIN_2_BYTES_UNICODE;
    }

    // Split the range at the encoded-length boundaries.
    const length_ranges = [_][2]u32{
        .{ 0, MAX_1_BYTE_UNICODE },
        .{ MIN_2_BYTES_UNICODE, MAX_2_BYTES_UNICODE },
        .{ MIN_3_BYTES_UNICODE, MAX_3_BYTES_UNICODE },
        .{ MIN_4_BYTES_UNICODE, MAX_4_BYTES_UNICODE },
    };
    for (length_ranges) |length_range| {
        if (min <= length_range[1] and max >= length_range[0]) {
            try add_same_length_character_range(
                fsm,
                from,
                to,
                @max(min, length_range[0]),
                @min(max, length_range[1]),
            );
        }
    }
}

/// Adds the packed range `[min, max]` whose bounds have the same encoded length.
fn add_same_length_character_range(fsm: *Fsm, from: i32, to: i32, min: u32, max: u32) Allocator.Error!void {
    const byte = struct {
        fn f(value: u32, i: u32) i32 {
            return @intCast((value >> @as(u5, @intCast(8 * i))) & 0xFF);
        }
    }.f;
    // ASCII.
    if (byte(max, 1) == 0) {
        try fsm.add_edge(from, to, byte(min, 0), byte(max, 0));
        return;
    }
    // The index of the leading byte, and the masks of the trailing bytes.
    const lead: u5 = if (byte(max, 3) != 0) 3 else if (byte(max, 2) != 0) 2 else 1;
    const tail_mask = (@as(u32, 1) << @as(u5, 8 * lead)) - 1;
    const tail_min: u32 = 0x8080_8080 & tail_mask;
    const tail_max: u32 = 0xBFBF_BFBF & tail_mask;
    var lead_min = byte(min, lead);
    var lead_max = byte(max, lead);

    if (lead_min == lead_max) {
        const next = try fsm.add_state();
        try fsm.add_edge(from, next, lead_min, lead_max);
        try add_same_length_character_range(fsm, next, to, min & tail_mask, max & tail_mask);
        return;
    }
    if (min & tail_mask == tail_min) {
        lead_min -= 1;
    } else {
        const next = try fsm.add_state();
        try fsm.add_edge(from, next, lead_min, lead_min);
        try add_same_length_character_range(fsm, next, to, min & tail_mask, tail_max);
    }
    if (max & tail_mask == tail_max) {
        lead_max += 1;
    } else {
        const next = try fsm.add_state();
        try fsm.add_edge(from, next, lead_max, lead_max);
        try add_same_length_character_range(fsm, next, to, tail_min, max & tail_mask);
    }
    if (lead_max - lead_min > 1) {
        // Full lead bytes in between, each followed by any continuation bytes.
        var current = try fsm.add_state();
        try fsm.add_edge(from, current, lead_min + 1, lead_max - 1);
        for (1..lead) |_| {
            const next = try fsm.add_state();
            try fsm.add_edge(current, next, 0x80, 0xBF);
            current = next;
        }
        try fsm.add_edge(current, to, 0x80, 0xBF);
    }
}

test "codepoint_to_packed_utf8" {
    try std.testing.expectEqual(@as(u32, 'a'), codepoint_to_packed_utf8('a'));
    try std.testing.expectEqual(@as(u32, 0xC3A9), codepoint_to_packed_utf8(0xE9));
    try std.testing.expectEqual(@as(u32, 0xE4BDA0), codepoint_to_packed_utf8(0x4F60));
    try std.testing.expectEqual(@as(u32, 0xF09F9880), codepoint_to_packed_utf8(0x1F600));
}

test "add_packed_utf8_range_edges basic ascii" {
    const a = std.testing.allocator;
    var fsm = try Fsm.new(a, 1);
    defer fsm.deinit();
    try add_packed_utf8_range_edges(&fsm, 0, 0, 'a', 'c');
    try std.testing.expectEqual(@as(i32, 1), fsm.num_states());
}
