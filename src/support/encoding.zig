//! UTF-8 and escape-sequence encoding/decoding.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub const Codepoint = i32;

pub const CharHandlingError = error{
    InvalidUtf8,
    InvalidEscape,
    InvalidLatin1,
};

pub const CodepointEscape = struct {
    codepoint: Codepoint,
    escape: []const u8,
};

pub const ByteEscape = struct {
    byte: u8,
    codepoint: Codepoint,
};

pub const Decoded = struct {
    codepoint: Codepoint,
    consumed: usize,
};

pub fn charToUtf8Bytes(allocator: Allocator, codepoint: Codepoint) Allocator.Error![]u8 {
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

/// Writes `codepoint` as UTF-8 bytes to `writer` without heap allocation.
pub fn writeUtf8Bytes(writer: *std.Io.Writer, codepoint: Codepoint) std.Io.Writer.Error!void {
    std.debug.assert(codepoint >= 0 and codepoint <= 0x10_FFFF);
    const cp: u32 = @intCast(codepoint);
    var buf: [4]u8 = undefined;
    const len: usize = switch (cp) {
        0...0x7F => blk: {
            buf[0] = @intCast(cp);
            break :blk 1;
        },
        0x80...0x7FF => blk: {
            buf[0] = @intCast(0xC0 | ((cp >> 6) & 0x1F));
            buf[1] = @intCast(0x80 | (cp & 0x3F));
            break :blk 2;
        },
        0x800...0xFFFF => blk: {
            buf[0] = @intCast(0xE0 | ((cp >> 12) & 0x0F));
            buf[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
            buf[2] = @intCast(0x80 | (cp & 0x3F));
            break :blk 3;
        },
        else => blk: {
            buf[0] = @intCast(0xF0 | ((cp >> 18) & 0x07));
            buf[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
            buf[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
            buf[3] = @intCast(0x80 | (cp & 0x3F));
            break :blk 4;
        },
    };
    try writer.writeAll(buf[0..len]);
}

pub fn handleUtf8FirstByte(byte: u8) ?Decoded {
    const entry: struct { usize, u8, Codepoint } = switch (byte) {
        0x00...0x7F => .{ 1, 0x7F, @as(Codepoint, byte) },
        0xC0...0xDF => .{ 2, 0x1F, @as(Codepoint, byte) },
        0xE0...0xEF => .{ 3, 0x0F, @as(Codepoint, byte) },
        0xF0...0xF7 => .{ 4, 0x07, @as(Codepoint, byte) },
        else => return null,
    };
    return .{ .codepoint = entry[2] & entry[1], .consumed = entry[0] };
}

pub fn parseNextUtf8(bytes: []const u8) CharHandlingError!Decoded {
    const first = if (bytes.len == 0) return error.InvalidUtf8 else bytes[0];
    const initial = handleUtf8FirstByte(first) orelse return error.InvalidUtf8;
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

pub fn parseUtf8(allocator: Allocator, bytes: []const u8, preserve_invalid_bytes: bool) (CharHandlingError || Allocator.Error)!ArrayList(Codepoint) {
    var codepoints: ArrayList(Codepoint) = .empty;
    errdefer codepoints.deinit(allocator);
    var rest = bytes;
    while (rest.len > 0) {
        const first = rest[0];
        if (parseNextUtf8(rest)) |decoded| {
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

pub fn hexCharToInt(c: u8) ?u32 {
    return switch (c) {
        '0'...'9' => @as(u32, c - '0'),
        'a'...'f' => @as(u32, c - 'a') + 10,
        'A'...'F' => @as(u32, c - 'A') + 10,
        else => null,
    };
}

fn defaultCodepointEscape(codepoint: Codepoint) ?[]const u8 {
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

fn writeHexPadded(writer: *std.Io.Writer, value: u32, width: usize) std.Io.Writer.Error!void {
    const digits = "0123456789abcdef";
    var i: usize = width;
    while (i > 0) : (i -= 1) {
        const shift: u5 = @intCast((i - 1) * 4);
        const nibble: u4 = @truncate(value >> shift);
        try writer.writeByte(digits[nibble]);
    }
}

/// Streams escaped representation of `codepoint` to `writer` without heap allocations.
pub fn writeEscapedCodepoint(
    writer: *std.Io.Writer,
    codepoint: Codepoint,
    additional_escape_map: []const CodepointEscape,
) std.Io.Writer.Error!void {
    for (additional_escape_map) |entry| {
        if (entry.codepoint == codepoint) {
            try writer.writeAll(entry.escape);
            return;
        }
    }
    if (defaultCodepointEscape(codepoint)) |s| {
        try writer.writeAll(s);
        return;
    }
    if (codepoint >= 0x20 and codepoint <= 0x7E) {
        try writer.writeByte(@intCast(codepoint));
        return;
    }
    const cp: u32 = @intCast(codepoint);
    const entry: struct { u8, usize } = if (cp <= 0xFF)
        .{ 'x', 2 }
    else if (cp <= 0xFFFF)
        .{ 'u', 4 }
    else
        .{ 'U', 8 };
    try writer.writeByte('\\');
    try writer.writeByte(entry[0]);
    try writeHexPadded(writer, cp, entry[1]);
}

/// Streams escaped representation of `raw` bytes to `writer` with zero heap allocations.
pub fn writeEscapedBytes(writer: *std.Io.Writer, raw: []const u8) std.Io.Writer.Error!void {
    var rest = raw;
    while (rest.len > 0) {
        if (parseNextUtf8(rest)) |decoded| {
            try writeEscapedCodepoint(writer, decoded.codepoint, &.{});
            rest = rest[decoded.consumed..];
        } else |_| {
            try writeEscapedCodepoint(writer, @intCast(rest[0]), &.{});
            rest = rest[1..];
        }
    }
}

pub fn escapeCodepoint(allocator: Allocator, codepoint: Codepoint, additional_escape_map: []const CodepointEscape) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    writeEscapedCodepoint(&aw.writer, codepoint, additional_escape_map) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

pub fn escapeByte(allocator: Allocator, raw_char: u8) Allocator.Error![]u8 {
    return escapeCodepoint(allocator, @intCast(raw_char), &.{});
}

pub fn escapeBytes(allocator: Allocator, raw: []const u8) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    writeEscapedBytes(&aw.writer, raw) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

pub fn escapeStr(allocator: Allocator, raw: []const u8) Allocator.Error![]u8 {
    return escapeBytes(allocator, raw);
}

fn defaultEscapeToCodepoint(escape_char: u8) ?Codepoint {
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

pub fn parseNextEscaped(data: []const u8, additional_escape_map: []const ByteEscape) CharHandlingError!Decoded {
    if (data.len < 2 or data[0] != '\\') return error.InvalidEscape;
    const second = data[1];
    if (second > 128) return error.InvalidEscape;

    for (additional_escape_map) |entry| {
        if (entry.byte == second) return .{ .codepoint = entry.codepoint, .consumed = 2 };
    }
    if (defaultEscapeToCodepoint(second)) |cp| return .{ .codepoint = cp, .consumed = 2 };

    switch (second) {
        'x' => {
            var len: usize = 0;
            var codepoint: Codepoint = 0;
            while (2 + len < data.len) : (len += 1) {
                const digit = hexCharToInt(data[2 + len]) orelse break;
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
                const digit = hexCharToInt(data[2 + i]) orelse return error.InvalidEscape;
                codepoint = codepoint * 16 + @as(Codepoint, @intCast(digit));
            }
            return .{ .codepoint = codepoint, .consumed = len + 2 };
        },
        else => return error.InvalidEscape,
    }
}

pub fn parseNextUtf8OrEscaped(data: []const u8, additional_escape_map: []const ByteEscape) CharHandlingError!Decoded {
    if (data.len > 0 and data[0] == '\\') {
        return parseNextEscaped(data, additional_escape_map);
    }
    return parseNextUtf8(data);
}

pub fn latin1ToBytes(allocator: Allocator, latin1: []const u8) (CharHandlingError || Allocator.Error)![]u8 {
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

pub fn byteToLatin1(allocator: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    var result: ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    try result.ensureTotalCapacity(allocator, bytes.len);
    for (bytes) |b| {
        if (b < 0x80) {
            result.appendAssumeCapacity(b);
        } else {
            result.appendAssumeCapacity(@intCast(0xC0 | (b >> 6)));
            result.appendAssumeCapacity(@intCast(0x80 | (b & 0x3F)));
        }
    }
    return result.toOwnedSlice(allocator);
}

/// Streams `bytes` as Latin-1 UTF-8 directly to `writer` (helper for streaming JSON serialization).
pub fn writeLatin1(writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    for (bytes) |b| {
        if (b < 0x80) {
            try writer.writeByte(b);
        } else {
            try writer.writeAll(&.{
                @intCast(0xC0 | (b >> 6)),
                @intCast(0x80 | (b & 0x3F)),
            });
        }
    }
}

test "charToUtf8Bytes" {
    const alloc = std.testing.allocator;
    {
        const b = try charToUtf8Bytes(alloc, 'A');
        defer alloc.free(b);
        try std.testing.expectEqualSlices(u8, "A", b);
    }
    {
        const b = try charToUtf8Bytes(alloc, 0x4E2D);
        defer alloc.free(b);
        try std.testing.expectEqualSlices(u8, "中", b);
    }
    {
        const b = try charToUtf8Bytes(alloc, 0x1F600);
        defer alloc.free(b);
        try std.testing.expectEqualSlices(u8, "😀", b);
    }
    {
        const b = try charToUtf8Bytes(alloc, 0xD800);
        defer alloc.free(b);
        try std.testing.expectEqual(@as(usize, 3), b.len);
    }
}

test "escape and parse roundtrips" {
    const alloc = std.testing.allocator;
    const s = try escapeStr(alloc, "a\n中");
    defer alloc.free(s);
    try std.testing.expectEqualStrings("a\\n\\u4e2d", s);

    const b = try escapeBytes(alloc, &.{ 'a', 0xFF });
    defer alloc.free(b);
    try std.testing.expectEqualStrings("a\\xff", b);

    const d = try parseNextEscaped("\\U0001F600x", &.{});
    try std.testing.expectEqual(@as(Codepoint, 0x1F600), d.codepoint);
    try std.testing.expectEqual(@as(usize, 10), d.consumed);

    const raw = [_]u8{ 0, 0x7F, 0x80, 0xE9, 0xFF };
    const lat = try byteToLatin1(alloc, &raw);
    defer alloc.free(lat);
    const back = try latin1ToBytes(alloc, lat);
    defer alloc.free(back);
    try std.testing.expectEqualSlices(u8, &raw, back);
}
