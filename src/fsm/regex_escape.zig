//! One parsed regex escape sequence.

const std = @import("std");
const Allocator = std.mem.Allocator;

const support = @import("../support/mod.zig");
const encoding = support.encoding;

/// The largest Unicode codepoint.
pub const MAX_CODEPOINT: u32 = 0x10_FFFF;

/// An inclusive range of Unicode codepoints (`CodepointRange` in fsm/mod.rs).
pub const CodepointRange = struct { low: u32, high: u32 };

pub const ParseError = Allocator.Error || error{
    /// Unsupported or malformed escape (message via `err_msg`).
    InvalidEscape,
};

/// A parsed regex escape: a single codepoint, or a (possibly negated) set of codepoint ranges
/// for class escapes like `\d`, `\D`, `\w`, `\W`, `\s`, `\S`.
pub const RegexEscape = union(enum) {
    /// A single codepoint.
    Single: u32,
    /// A class escape.
    Class: struct {
        /// The ranges of the (non-negated) class.
        ranges: []CodepointRange,
        /// Whether the escape matches the complement of `ranges`.
        negated: bool,
    },

    /// Frees the storage owned by this escape.
    pub fn deinit(self: RegexEscape, allocator: Allocator) void {
        switch (self) {
            .Class => |c| allocator.free(c.ranges),
            .Single => {},
        }
    }

    /// Parses the escape sequence starting at `regex[pos.*] == '\\'`, advancing `pos` past it.
    /// Inside a character class (`in_class`), `\b` is the backspace character instead of a word
    /// boundary assertion.
    ///
    /// On error, `err_msg` (a `*?[]u8`) receives the statically-known message when non-null;
    /// the caller keeps Rust's wording verbatim in the call sites below.
    pub fn parse(
        allocator: Allocator,
        regex: []const u8,
        pos: *usize,
        in_class: bool,
        err_msg: *?[]const u8,
    ) ParseError!RegexEscape {
        std.debug.assert(regex[pos.*] == '\\');
        const escaped = if (pos.* + 1 < regex.len) regex[pos.* + 1] else return invalid(err_msg, "Regex ends with a trailing backslash");
        pos.* += 2;
        switch (escaped) {
            'n' => return .{ .Single = 0x0A },
            't' => return .{ .Single = 0x09 },
            'r' => return .{ .Single = 0x0D },
            'f' => return .{ .Single = 0x0C },
            'v' => return .{ .Single = 0x0B },
            'a' => return .{ .Single = 0x07 },
            'e' => return .{ .Single = 0x1B },
            '0' => return .{ .Single = 0 },
            'b' => {
                if (in_class) return .{ .Single = 0x08 };
                return invalid(err_msg, "Word boundary assertion \\b is not supported in regex");
            },
            'B' => return invalid(err_msg, "Word boundary assertion \\B is not supported in regex"),
            'p', 'P' => return invalid(err_msg, "Unicode property escape \\p / \\P is not supported in regex"),
            'k' => return invalid(err_msg, "Backreference \\k is not supported in regex"),
            '1'...'9' => return invalid(
                err_msg,
                std.fmt.allocPrint(allocator, "Backreference \\{c} is not supported in regex", .{escaped}) catch |e| return e,
            ),
            'd', 'D' => return class_escape(allocator, &.{.{ '0', '9' }}, escaped == 'D'),
            'w', 'W' => return class_escape(
                allocator,
                &.{ .{ '0', '9' }, .{ 'A', 'Z' }, .{ '_', '_' }, .{ 'a', 'z' } },
                escaped == 'W',
            ),
            's', 'S' => return class_escape(allocator, &.{.{ 0x09, 0x0D }, .{ ' ', ' ' }}, escaped == 'S'),
            'x' => {
                const codepoint = if (pos.* + 2 <= regex.len)
                    hex_value(regex[pos.* .. pos.* + 2]) orelse
                        return invalid(err_msg, "\\x must be followed by two hexadecimal digits in regex")
                else
                    return invalid(err_msg, "\\x must be followed by two hexadecimal digits in regex");
                pos.* += 2;
                return .{ .Single = codepoint };
            },
            'u' => {
                if (pos.* < regex.len and regex[pos.*] == '{') {
                    const digits_begin = pos.* + 1;
                    var close: ?usize = null;
                    for (regex[digits_begin..], digits_begin..) |c, i| {
                        if (c == '}') {
                            close = i;
                            break;
                        }
                    }
                    const close_idx = close orelse
                        return invalid(err_msg, "\\u{...} must contain one to six hexadecimal digits in regex");
                    if (!(close_idx > digits_begin and close_idx <= pos.* + 7)) {
                        return invalid(err_msg, "\\u{...} must contain one to six hexadecimal digits in regex");
                    }
                    const codepoint = hex_value(regex[digits_begin..close_idx]) orelse
                        return invalid(err_msg, "\\u{...} must contain one to six hexadecimal digits in regex");
                    if (codepoint > MAX_CODEPOINT) {
                        return invalid(err_msg, "\\u{...} escape is beyond the Unicode range in regex");
                    }
                    pos.* = close_idx + 1;
                    return .{ .Single = codepoint };
                }
                const codepoint = if (pos.* + 4 <= regex.len)
                    hex_value(regex[pos.* .. pos.* + 4]) orelse
                        return invalid(err_msg, "\\u must be followed by four hexadecimal digits in regex")
                else
                    return invalid(err_msg, "\\u must be followed by four hexadecimal digits in regex");
                pos.* += 4;
                return .{ .Single = codepoint };
            },
            'c' => {
                if (pos.* < regex.len and std.ascii.isAlphabetic(regex[pos.*])) {
                    const letter = regex[pos.*];
                    pos.* += 1;
                    return .{ .Single = letter & 0x1F };
                }
                return invalid(err_msg, "\\c must be followed by a letter in regex");
            },
            0x80...0xFF => {
                // A multi-byte UTF-8 character after the backslash matches literally.
                const decoded = encoding.parse_next_utf8(regex[pos.* - 1 ..]) catch
                    return invalid(err_msg, "Invalid UTF-8 in regex escape sequence");
                pos.* += decoded.consumed - 1;
                return .{ .Single = @intCast(decoded.codepoint) };
            },
            else => {
                return .{ .Single = escaped };
            },
        }
    }
};

fn invalid(err_msg: *?[]const u8, message: []const u8) ParseError {
    err_msg.* = message;
    return error.InvalidEscape;
}

fn class_escape(allocator: Allocator, bounds: []const [2]u32, negated: bool) ParseError!RegexEscape {
    const ranges = try allocator.alloc(CodepointRange, bounds.len);
    for (bounds, 0..) |b, i| ranges[i] = .{ .low = b[0], .high = b[1] };
    return .{ .Class = .{ .ranges = ranges, .negated = negated } };
}

/// The value of a non-empty run of hexadecimal digits, or null if any byte is not one.
fn hex_value(digits: []const u8) ?u32 {
    var value: u32 = 0;
    for (digits) |digit| {
        const hex = encoding.hex_char_to_int(digit) orelse return null;
        value = value * 16 + hex;
    }
    return value;
}
