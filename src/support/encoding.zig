//! UTF-8 and escape-sequence encoding/decoding.
//!
//! Upstream signals failures via negative sentinel codepoints; this port uses
//! error unions with [`CharHandlingError`] instead, and operates on byte slices rather
//! than NUL-terminated pointers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

/// A Unicode codepoint (or a raw byte value treated as one).
pub const Codepoint = i32;

/// Failure when handling characters.
pub const CharHandlingError = error{
    /// The UTF-8 byte sequence is invalid.
    InvalidUtf8,
    /// The escape sequence is invalid.
    InvalidEscape,
    /// The Latin-1 string is invalid.
    InvalidLatin1,
};

/// One entry of the caller-supplied escape map for `escape_codepoint`
/// (Rust tuple `(Codepoint, &str)`).
pub const CodepointEscape = struct {
    codepoint: Codepoint,
    escape: []const u8,
};

/// One entry of the caller-supplied escape map for `parse_next_escaped`
/// (Rust tuple `(u8, Codepoint)`).
pub const ByteEscape = struct {
    byte: u8,
    codepoint: Codepoint,
};

/// Decoded first codepoint plus the number of bytes consumed (Rust tuple return).
pub const Decoded = struct {
    codepoint: Codepoint,
    consumed: usize,
};

/// Encodes a codepoint to its raw UTF-8 bytes (allocated; never panics on surrogates,
/// unlike a `String`). Caller owns the returned slice.
pub fn char_to_utf8_bytes(allocator: Allocator, codepoint: Codepoint) Allocator.Error![]u8 {
    std.debug.assert(codepoint >= 0 and codepoint <= 0x10_FFFF);
    const cp: u32 = @intCast(codepoint);
    return switch (cp) {
        0...0x7F => blk: {
            const out = try allocator.alloc(u8, 1);
            out[0] = @intCast(cp);
            break :blk out;
        },
        0x80...0x7FF => blk: {
            const out = try allocator.alloc(u8, 2);
            out[0] = @intCast(0xC0 | ((cp >> 6) & 0x1F));
            out[1] = @intCast(0x80 | (cp & 0x3F));
            break :blk out;
        },
        0x800...0xFFFF => blk: {
            const out = try allocator.alloc(u8, 3);
            out[0] = @intCast(0xE0 | ((cp >> 12) & 0x0F));
            out[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
            out[2] = @intCast(0x80 | (cp & 0x3F));
            break :blk out;
        },
        else => blk: {
            const out = try allocator.alloc(u8, 4);
            out[0] = @intCast(0xF0 | ((cp >> 18) & 0x07));
            out[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
            out[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
            out[3] = @intCast(0x80 | (cp & 0x3F));
            break :blk out;
        },
    };
}

/// Decodes a UTF-8 leading byte into `(total_bytes, initial_codepoint_bits)`, or `null`
/// if the byte cannot start a sequence.
pub fn handle_utf8_first_byte(byte: u8) ?Decoded {
    const entry: struct { usize, u8, Codepoint } = switch (byte) {
        0x00...0x7F => .{ 1, 0x7F, @as(Codepoint, byte) },
        0xC0...0xDF => .{ 2, 0x1F, @as(Codepoint, byte) },
        0xE0...0xEF => .{ 3, 0x0F, @as(Codepoint, byte) },
        0xF0...0xF7 => .{ 4, 0x07, @as(Codepoint, byte) },
        else => return null,
    };
    return .{ .codepoint = entry[2] & entry[1], .consumed = entry[0] };
}

/// Decodes the first codepoint of `bytes`, returning it and how many bytes it consumed.
///
/// Returns `error.InvalidUtf8` if `bytes` is empty or not valid UTF-8 at its start.
pub fn parse_next_utf8(bytes: []const u8) CharHandlingError!Decoded {
    const first = if (bytes.len == 0) return error.InvalidUtf8 else bytes[0];
    const initial = handle_utf8_first_byte(first) orelse return error.InvalidUtf8;
    var res = initial.codepoint;
    var i: usize = 1;
    while (i < initial.consumed) : (i += 1) {
        if (i >= bytes.len) return error.InvalidUtf8;
        const b = bytes[i];
        if ((b & 0xC0) == 0x80) {
            res = (res << 6) | @as(Codepoint, b & 0x3F);
        } else {
            return error.InvalidUtf8;
        }
    }
    return .{ .codepoint = res, .consumed = initial.consumed };
}

/// Decodes every codepoint in `bytes` into a caller-owned `ArrayList`.
///
/// On invalid UTF-8: if `preserve_invalid_bytes`, the offending byte is emitted verbatim
/// as a codepoint and decoding continues; otherwise the whole call fails.
pub fn parse_utf8(allocator: Allocator, bytes: []const u8, preserve_invalid_bytes: bool) (CharHandlingError || Allocator.Error)!ArrayList(Codepoint) {
    var codepoints: ArrayList(Codepoint) = .empty;
    errdefer codepoints.deinit(allocator);
    var rest = bytes;
    while (rest.len > 0) {
        const first = rest[0];
        if (parse_next_utf8(rest)) |decoded| {
            try codepoints.append(allocator, decoded.codepoint);
            rest = rest[decoded.consumed..];
        } else |err| {
            if (preserve_invalid_bytes) {
                try codepoints.append(allocator, @intCast(first));
                rest = rest[1..];
            } else {
                return err;
            }
        }
    }
    return codepoints;
}

/// Converts a hex digit (`0-9a-fA-F`) to its value.
pub fn hex_char_to_int(c: u8) ?u32 {
    return switch (c) {
        '0'...'9' => @as(u32, c - '0'),
        'a'...'f' => @as(u32, c - 'a') + 10,
        'A'...'F' => @as(u32, c - 'A') + 10,
        else => null,
    };
}

fn default_codepoint_escape(codepoint: Codepoint) ?[]const u8 {
    return switch (codepoint) {
        0x27 => "\\'",
        0x22 => "\\\"",
        0x3F => "\\?",
        0x5C => "\\\\",
        0x07 => "\\a",
        0x08 => "\\b",
        0x0C => "\\f",
        0x0A => "\\n",
        0x0D => "\\r",
        0x09 => "\\t",
        0x0B => "\\v",
        0x00 => "\\0",
        0x1B => "\\e",
        else => null,
    };
}

fn append_hex_padded(out: *ArrayList(u8), allocator: Allocator, value: u32, width: usize) Allocator.Error!void {
    const digits = "0123456789abcdef";
    var i: usize = width;
    while (i > 0) : (i -= 1) {
        const shift: u5 = @intCast((i - 1) * 4);
        const nibble: u4 = @truncate(value >> shift);
        try out.append(allocator, digits[nibble]);
    }
}

/// Escapes a codepoint into a printable string. `additional_escape_map` (codepoint →
/// escape) takes precedence over the built-in C-style escapes; non-printable codepoints
/// fall back to `\xNN` / `\uNNNN` / `\UNNNNNNNN`. Caller owns the returned slice.
pub fn escape_codepoint(allocator: Allocator, codepoint: Codepoint, additional_escape_map: []const CodepointEscape) Allocator.Error![]u8 {
    for (additional_escape_map) |entry| {
        if (entry.codepoint == codepoint) return allocator.dupe(u8, entry.escape);
    }
    if (default_codepoint_escape(codepoint)) |s| return allocator.dupe(u8, s);
    if (codepoint >= 0x20 and codepoint <= 0x7E) {
        return allocator.dupe(u8, &.{ @intCast(codepoint) });
    }
    const cp: u32 = @intCast(codepoint);
    const entry: struct { u8, usize } = if (cp <= 0xFF)
        .{ 'x', 2 }
    else if (cp <= 0xFFFF)
        .{ 'u', 4 }
    else
        .{ 'U', 8 };
    var out: ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, 2 + entry[1]);
    try out.append(allocator, '\\');
    try out.append(allocator, entry[0]);
    try append_hex_padded(&out, allocator, cp, entry[1]);
    return out.toOwnedSlice(allocator);
}

/// Escapes a single raw byte into a printable string.
pub fn escape_byte(allocator: Allocator, raw_char: u8) Allocator.Error![]u8 {
    return escape_codepoint(allocator, @intCast(raw_char), &.{});
}

/// Escapes a raw byte sequence (decoding UTF-8, preserving invalid bytes) into a printable
/// form. Caller owns the returned slice.
pub fn escape_bytes(allocator: Allocator, raw: []const u8) Allocator.Error![]u8 {
    var codepoints = parse_utf8(allocator, raw, true) catch unreachable;
    defer codepoints.deinit(allocator);
    var out: ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (codepoints.items) |cp| {
        const escaped = try escape_codepoint(allocator, cp, &.{});
        defer allocator.free(escaped);
        try out.appendSlice(allocator, escaped);
    }
    return out.toOwnedSlice(allocator);
}

/// Escapes a whole string (decoding UTF-8, preserving invalid bytes) into a printable form.
pub fn escape_str(allocator: Allocator, raw: []const u8) Allocator.Error![]u8 {
    return escape_bytes(allocator, raw);
}

fn default_escape_to_codepoint(escape_char: u8) ?Codepoint {
    return switch (escape_char) {
        '\'' => 0x27,
        '"' => 0x22,
        '?' => 0x3F,
        '\\' => 0x5C,
        '/' => 0x2F,
        'a' => 0x07,
        'b' => 0x08,
        'f' => 0x0C,
        'n' => 0x0A,
        'r' => 0x0D,
        't' => 0x09,
        'v' => 0x0B,
        '0' => 0x00,
        'e' => 0x1B,
        else => null,
    };
}

/// Parses the first escape sequence in `data`, which must begin with `\`.
///
/// `additional_escape_map` (escape char → codepoint) takes precedence over the built-in
/// C-style escapes. Supports `\xHH...` (arbitrary-length hex), `\uHHHH`, and `\UHHHHHHHH`.
pub fn parse_next_escaped(data: []const u8, additional_escape_map: []const ByteEscape) CharHandlingError!Decoded {
    if (data.len == 0 or data[0] != '\\') return error.InvalidEscape;
    if (data.len < 2) return error.InvalidEscape;
    const second = data[1];
    if (second > 128) return error.InvalidEscape;

    for (additional_escape_map) |entry| {
        if (entry.byte == second) return .{ .codepoint = entry.codepoint, .consumed = 2 };
    }
    if (default_escape_to_codepoint(second)) |cp| return .{ .codepoint = cp, .consumed = 2 };

    switch (second) {
        'x' => {
            // arbitrary-length hex
            var len: usize = 0;
            var codepoint: Codepoint = 0;
            while (2 + len < data.len) : (len += 1) {
                const digit = hex_char_to_int(data[2 + len]) orelse break;
                codepoint = codepoint * 16 + @as(Codepoint, @intCast(digit));
            }
            if (len == 0) return error.InvalidEscape;
            return .{ .codepoint = codepoint, .consumed = len + 2 };
        },
        'u', 'U' => {
            const len: usize = if (second == 'u') 4 else 8;
            var codepoint: Codepoint = 0;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                if (2 + i >= data.len) return error.InvalidEscape;
                const digit = hex_char_to_int(data[2 + i]) orelse return error.InvalidEscape;
                codepoint = codepoint * 16 + @as(Codepoint, @intCast(digit));
            }
            return .{ .codepoint = codepoint, .consumed = len + 2 };
        },
        else => return error.InvalidEscape,
    }
}

/// Decodes the first codepoint of `data`, transparently handling a leading `\` escape.
pub fn parse_next_utf8_or_escaped(data: []const u8, additional_escape_map: []const ByteEscape) CharHandlingError!Decoded {
    if (data.len > 0 and data[0] == '\\') {
        return parse_next_escaped(data, additional_escape_map);
    }
    return parse_next_utf8(data);
}

/// Converts a Latin-1 string (whose non-ASCII chars are UTF-8-encoded in `latin1`) to its
/// raw byte sequence. Caller owns the returned slice.
pub fn latin1_to_bytes(allocator: Allocator, latin1: []const u8) (CharHandlingError || Allocator.Error)![]u8 {
    var result: ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, latin1.len);
    var i: usize = 0;
    while (i < latin1.len) {
        const c1 = latin1[i];
        if (c1 < 0x80) {
            try result.append(allocator, c1);
            i += 1;
        } else {
            if (i + 1 >= latin1.len) return error.InvalidLatin1;
            const c2 = latin1[i + 1];
            if ((c2 & 0xC0) != 0x80) return error.InvalidLatin1;
            const code = (@as(u32, c1 & 0x1F) << 6) | @as(u32, c2 & 0x3F);
            if (code < 0x80 or code > 0xFF) return error.InvalidLatin1;
            try result.append(allocator, @intCast(code));
            i += 2;
        }
    }
    return result.toOwnedSlice(allocator);
}

/// Converts a raw byte sequence to a Latin-1 string (each byte becomes the same-valued
/// codepoint). Caller owns the returned slice.
pub fn byte_to_latin1(allocator: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    var result: ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, bytes.len);
    for (bytes) |b| {
        if (b < 0x80) {
            result.appendAssumeCapacity(b);
        } else {
            // Two-byte UTF-8 for codepoints 0x80..=0xFF.
            result.appendAssumeCapacity(@intCast(0xC0 | (b >> 6)));
            result.appendAssumeCapacity(@intCast(0x80 | (b & 0x3F)));
        }
    }
    return result.toOwnedSlice(allocator);
}

test "char_to_utf8_bytes" {
    const alloc = std.testing.allocator;
    // ASCII
    {
        const b = try char_to_utf8_bytes(alloc, 'A');
        defer alloc.free(b);
        try std.testing.expectEqualSlices(u8, "A", b);
    }
    // 中文 (U+4E2D)
    {
        const b = try char_to_utf8_bytes(alloc, 0x4E2D);
        defer alloc.free(b);
        try std.testing.expectEqualSlices(u8, "中", b);
    }
    // Two-byte: é U+00E9
    {
        const b = try char_to_utf8_bytes(alloc, 0xE9);
        defer alloc.free(b);
        try std.testing.expectEqualSlices(u8, "é", b);
    }
    // Four-byte: U+1F600
    {
        const b = try char_to_utf8_bytes(alloc, 0x1F600);
        defer alloc.free(b);
        try std.testing.expectEqualSlices(u8, "😀", b);
    }
    // Surrogate range does not panic (Rust doc contract).
    {
        const b = try char_to_utf8_bytes(alloc, 0xD800);
        defer alloc.free(b);
        try std.testing.expectEqual(@as(usize, 3), b.len);
    }
}

test "handle_utf8_first_byte" {
    try std.testing.expectEqual(@as(usize, 1), handle_utf8_first_byte(0x41).?.consumed);
    try std.testing.expectEqual(@as(Codepoint, 0x41), handle_utf8_first_byte(0x41).?.codepoint);
    try std.testing.expectEqual(@as(usize, 3), handle_utf8_first_byte(0xE4).?.consumed);
    try std.testing.expectEqual(@as(Codepoint, 0x04), handle_utf8_first_byte(0xE4).?.codepoint);
    try std.testing.expectEqual(@as(usize, 4), handle_utf8_first_byte(0xF0).?.consumed);
    try std.testing.expect(handle_utf8_first_byte(0x80) == null); // continuation
    try std.testing.expect(handle_utf8_first_byte(0xF8) == null); // > F7
}

test "parse_next_utf8" {
    // 中 = E4 B8 AD
    const decoded = try parse_next_utf8("中abc");
    try std.testing.expectEqual(@as(Codepoint, 0x4E2D), decoded.codepoint);
    try std.testing.expectEqual(@as(usize, 3), decoded.consumed);

    try std.testing.expectError(error.InvalidUtf8, parse_next_utf8(""));
    try std.testing.expectError(error.InvalidUtf8, parse_next_utf8(&.{0xE4, 0xB8})); // truncated
    try std.testing.expectError(error.InvalidUtf8, parse_next_utf8(&.{0xE4, 'x', 'y'})); // bad continuation
    try std.testing.expectError(error.InvalidUtf8, parse_next_utf8(&.{0x80})); // lone continuation
}

test "parse_utf8 preserve_invalid" {
    const alloc = std.testing.allocator;
    // Valid text mixed with an invalid byte (0xFF).
    {
        var cps = try parse_utf8(alloc, "a\xff中", true);
        defer cps.deinit(alloc);
        try std.testing.expectEqualSlices(Codepoint, &.{ 'a', 0xFF, 0x4E2D }, cps.items);
    }
    {
        try std.testing.expectError(error.InvalidUtf8, parse_utf8(alloc, "a\xff", false));
    }
    {
        var cps = try parse_utf8(alloc, "", false);
        defer cps.deinit(alloc);
        try std.testing.expectEqual(@as(usize, 0), cps.items.len);
    }
}

test "hex_char_to_int" {
    try std.testing.expectEqual(@as(u32, 0), hex_char_to_int('0').?);
    try std.testing.expectEqual(@as(u32, 9), hex_char_to_int('9').?);
    try std.testing.expectEqual(@as(u32, 10), hex_char_to_int('a').?);
    try std.testing.expectEqual(@as(u32, 15), hex_char_to_int('F').?);
    try std.testing.expect(hex_char_to_int('g') == null);
    try std.testing.expect(hex_char_to_int(' ') == null);
}

test "escape_codepoint" {
    const alloc = std.testing.allocator;
    // Built-in C-style escapes.
    const cases = [_]struct { Codepoint, []const u8 }{
        .{ 0x27, "\\'" },
        .{ 0x22, "\\\"" },
        .{ 0x5C, "\\\\" },
        .{ 0x0A, "\\n" },
        .{ 0x09, "\\t" },
        .{ 0x1B, "\\e" },
        .{ 0x00, "\\0" },
    };
    for (cases) |case| {
        const s = try escape_codepoint(alloc, case[0], &.{});
        defer alloc.free(s);
        try std.testing.expectEqualStrings(case[1], s);
    }
    // Printable ASCII.
    {
        const s = try escape_codepoint(alloc, 'k', &.{});
        defer alloc.free(s);
        try std.testing.expectEqualStrings("k", s);
    }
    // Hex fallback widths.
    {
        const s = try escape_codepoint(alloc, 0x1F, &.{});
        defer alloc.free(s);
        try std.testing.expectEqualStrings("\\x1f", s);
    }
    {
        const s = try escape_codepoint(alloc, 0x4E2D, &.{});
        defer alloc.free(s);
        try std.testing.expectEqualStrings("\\u4e2d", s);
    }
    {
        const s = try escape_codepoint(alloc, 0x1F600, &.{});
        defer alloc.free(s);
        try std.testing.expectEqualStrings("\\U0001f600", s);
    }
    // Additional escape map takes precedence.
    {
        const map = [_]CodepointEscape{.{ .codepoint = 'A', .escape = "@A@" }};
        const s = try escape_codepoint(alloc, 'A', &map);
        defer alloc.free(s);
        try std.testing.expectEqualStrings("@A@", s);
    }
}

test "escape_byte_and_str" {
    const alloc = std.testing.allocator;
    {
        const s = try escape_byte(alloc, 0x0A);
        defer alloc.free(s);
        try std.testing.expectEqualStrings("\\n", s);
    }
    {
        const s = try escape_str(alloc, "a\n中");
        defer alloc.free(s);
        try std.testing.expectEqualStrings("a\\n\\u4e2d", s);
    }
    // Invalid bytes preserved verbatim as \xNN.
    {
        const s = try escape_bytes(alloc, &.{ 'a', 0xFF });
        defer alloc.free(s);
        try std.testing.expectEqualStrings("a\\xff", s);
    }
}

test "parse_next_escaped" {
    const alloc_extra = [_]ByteEscape{.{ .byte = '.', .codepoint = 0x1234 }};

    // Default escapes.
    {
        const d = try parse_next_escaped("\\nrest", &.{});
        try std.testing.expectEqual(@as(Codepoint, 0x0A), d.codepoint);
        try std.testing.expectEqual(@as(usize, 2), d.consumed);
    }
    // Additional map takes precedence over defaults.
    {
        const map = [_]ByteEscape{.{ .byte = 'n', .codepoint = 0x99 }};
        const d = try parse_next_escaped("\\nrest", &map);
        try std.testing.expectEqual(@as(Codepoint, 0x99), d.codepoint);
    }
    {
        const d = try parse_next_escaped("\\.x", &alloc_extra);
        try std.testing.expectEqual(@as(Codepoint, 0x1234), d.codepoint);
    }
    // Arbitrary-length hex.
    {
        const d = try parse_next_escaped("\\x4E2D rest", &.{});
        try std.testing.expectEqual(@as(Codepoint, 0x4E2D), d.codepoint);
        try std.testing.expectEqual(@as(usize, 6), d.consumed);
    }
    // \u and \U fixed widths.
    {
        const d = try parse_next_escaped("\\u0041", &.{});
        try std.testing.expectEqual(@as(Codepoint, 0x41), d.codepoint);
        try std.testing.expectEqual(@as(usize, 6), d.consumed);
    }
    {
        const d = try parse_next_escaped("\\U0001F600x", &.{});
        try std.testing.expectEqual(@as(Codepoint, 0x1F600), d.codepoint);
        try std.testing.expectEqual(@as(usize, 10), d.consumed);
    }
    // Errors.
    try std.testing.expectError(error.InvalidEscape, parse_next_escaped("no backslash", &.{}));
    try std.testing.expectError(error.InvalidEscape, parse_next_escaped("\\", &.{}));
    try std.testing.expectError(error.InvalidEscape, parse_next_escaped("\\q", &.{}));
    try std.testing.expectError(error.InvalidEscape, parse_next_escaped("\\x", &.{})); // no digits
    try std.testing.expectError(error.InvalidEscape, parse_next_escaped("\\xg", &.{})); // bad hex
    try std.testing.expectError(error.InvalidEscape, parse_next_escaped("\\u04", &.{})); // short
    try std.testing.expectError(error.InvalidEscape, parse_next_escaped(&.{ 0x5C, 0xFF }, &.{})); // escape char byte > 128
    // \x with hex digits is valid arbitrary-length hex, not an error.
}

test "parse_next_utf8_or_escaped" {
    {
        const d = try parse_next_utf8_or_escaped("中", &.{});
        try std.testing.expectEqual(@as(Codepoint, 0x4E2D), d.codepoint);
        try std.testing.expectEqual(@as(usize, 3), d.consumed);
    }
    {
        const d = try parse_next_utf8_or_escaped("\\t", &.{});
        try std.testing.expectEqual(@as(Codepoint, 0x09), d.codepoint);
        try std.testing.expectEqual(@as(usize, 2), d.consumed);
    }
    try std.testing.expectError(error.InvalidEscape, parse_next_utf8_or_escaped("\\q", &.{}));
    try std.testing.expectError(error.InvalidUtf8, parse_next_utf8_or_escaped("", &.{}));
}

test "latin1 conversions round-trip" {
    const alloc = std.testing.allocator;
    {
        const b = try latin1_to_bytes(alloc, "ab\xC3\xA9");
        defer alloc.free(b);
        try std.testing.expectEqualSlices(u8, &.{ 'a', 'b', 0xE9 }, b);
    }
    // Range check: U+0100 is out of Latin-1.
    try std.testing.expectError(error.InvalidLatin1, latin1_to_bytes(alloc, "\xC4\x80"));
    // Truncated sequence.
    try std.testing.expectError(error.InvalidLatin1, latin1_to_bytes(alloc, &.{0xC3}));
    // Continuation byte expected but missing.
    try std.testing.expectError(error.InvalidLatin1, latin1_to_bytes(alloc, &.{ 0xC3, 'a' }));

    // byte_to_latin1: each byte becomes the same-valued codepoint (UTF-8 encoded).
    {
        const s = try byte_to_latin1(alloc, &.{ 'a', 0xE9 });
        defer alloc.free(s);
        try std.testing.expectEqualSlices(u8, "a\xC3\xA9", s);
    }
    // Round-trip: latin1_to_bytes ∘ byte_to_latin1 is identity.
    {
        const raw = [_]u8{ 0, 0x7F, 0x80, 0xE9, 0xFF };
        const s = try byte_to_latin1(alloc, &raw);
        defer alloc.free(s);
        const b = try latin1_to_bytes(alloc, s);
        defer alloc.free(b);
        try std.testing.expectEqualSlices(u8, &raw, b);
    }
}
