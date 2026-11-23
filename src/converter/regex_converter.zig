//! Converts a (JavaScript-flavored) regex into EBNF (`regex_converter.rs`).
//!
//! The grammar reference is
//! <https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Regular_expressions>.

const std = @import("std");
const Allocator = std.mem.Allocator;
const support = @import("../support/mod.zig");
const grammar_mod = @import("../grammar/mod.zig");
const Grammar = grammar_mod.Grammar;
const parser_mod = @import("../parser/mod.zig");
const functor = @import("../functor/mod.zig");
const regex_error_mod = @import("regex_error.zig");
const RegexError = regex_error_mod.RegexError;
const RegexErrorInfo = regex_error_mod.RegexErrorInfo;
const Codepoint = support.Codepoint;
const escape_codepoint = support.encoding.escape_codepoint;
const parse_next_escaped = support.encoding.parse_next_escaped;
const ByteEscape = support.encoding.ByteEscape;
const CodepointEscape = support.encoding.CodepointEscape;

/// Constructs a grammar from a regular expression string (Rust `Grammar::from_regex`).
///
/// On failure, `diag` (if given) receives the position and message; its `format_message`
/// reproduces the Rust `Display` text.
pub fn from_regex(gpa: Allocator, regex: []const u8, diag: ?*RegexErrorInfo) RegexError!*Grammar {
    return from_regex_with_options(gpa, regex, false, diag);
}

/// Constructs a grammar from a regular expression string (Rust
/// `Grammar::from_regex_with_options`). If `print_converted_ebnf` is true, the converted
/// EBNF string is printed; for debugging purposes.
pub fn from_regex_with_options(gpa: Allocator, regex: []const u8, print_converted_ebnf: bool, diag: ?*RegexErrorInfo) RegexError!*Grammar {
    const ebnf = try regex_to_ebnf(gpa, regex, true, diag);
    defer gpa.free(ebnf);
    if (print_converted_ebnf) {
        std.debug.print("{s}\n", .{ebnf});
    }
    var ebnf_diag: parser_mod.EbnfErrorInfo = undefined;
    const built = functor.grammar_normalizer_mod.from_ebnf(gpa, ebnf, "root", &ebnf_diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (diag) |d| {
                d.* = .{
                    .position = 0,
                    .message = try gpa.dupe(u8, try parser_mod.ebnf_error.message_of(ebnf_diag, gpa)),
                };
            }
            return error.Regex;
        },
    };
    return built;
}

/// Escapes recognized in `HandleCharEscape` (each maps to itself); takes precedence over
/// the built-in C-style escapes in `parse_next_escaped`.
const CHAR_ESCAPE_MAP = [_]ByteEscape{
    .{ .byte = '^', .codepoint = 0x5E },
    .{ .byte = '$', .codepoint = 0x24 },
    .{ .byte = '.', .codepoint = 0x2E },
    .{ .byte = '*', .codepoint = 0x2A },
    .{ .byte = '+', .codepoint = 0x2B },
    .{ .byte = '?', .codepoint = 0x3F },
    .{ .byte = '\\', .codepoint = 0x5C },
    .{ .byte = '(', .codepoint = 0x28 },
    .{ .byte = ')', .codepoint = 0x29 },
    .{ .byte = '[', .codepoint = 0x5B },
    .{ .byte = ']', .codepoint = 0x5D },
    .{ .byte = '{', .codepoint = 0x7B },
    .{ .byte = '}', .codepoint = 0x7D },
    .{ .byte = '|', .codepoint = 0x7C },
    .{ .byte = '/', .codepoint = 0x2F },
    .{ .byte = '-', .codepoint = 0x2D },
};

/// Converts `regex` to an EBNF body. With `with_rule_name`, wraps it as a full `root` rule
/// (Rust `regex_to_ebnf`). On failure `diag` receives position and message.
pub fn regex_to_ebnf(gpa: Allocator, regex: []const u8, with_rule_name: bool, diag: ?*RegexErrorInfo) RegexError![]u8 {
    // NUL is never meaningful in a regex, and the converter uses it as its end sentinel.
    if (std.mem.indexOfScalar(u8, regex, 0)) |position| {
        if (diag) |d| d.* = .{
            .position = position + 1,
            .message = try gpa.dupe(u8, "The regex must not contain null characters."),
        };
        return error.Regex;
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const chars = try utf8_codepoints(arena.allocator(), regex);
    var converter = RegexConverter{
        .gpa = gpa,
        .diag = diag,
        .arena = arena.allocator(),
        .chars = chars,
        .end = chars.len,
    };
    const body = try converter.convert();
    if (with_rule_name) {
        return std.fmt.allocPrint(gpa, "root ::= {s}\n", .{body});
    }
    return gpa.dupe(u8, body);
}

/// Decodes a `&str` (valid UTF-8 by contract) into its codepoint list.
fn utf8_codepoints(allocator: Allocator, text: []const u8) Allocator.Error![]Codepoint {
    var out: std.ArrayList(Codepoint) = .empty;
    try out.ensureTotalCapacity(allocator, text.len);
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            out.appendAssumeCapacity(0xFFFD);
            i += 1;
            continue;
        };
        if (i + len > text.len) {
            out.appendAssumeCapacity(0xFFFD);
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(text[i .. i + len]) catch 0xFFFD;
        out.appendAssumeCapacity(cp);
        i += len;
    }
    return out.toOwnedSlice(allocator);
}

const RegexConverter = struct {
    gpa: Allocator,
    diag: ?*RegexErrorInfo,
    /// Scratch arena: all intermediate strings and the result live here; only the final
    /// EBNF and diagnostics are copied to `gpa`.
    arena: Allocator,
    chars: []Codepoint,
    cur: usize = 0,
    end: usize,
    result: std.ArrayList(u8) = .empty,
    parenthesis_level: i32 = 0,

    fn peek(self: *const RegexConverter, delta: isize) Codepoint {
        const idx = @as(isize, @intCast(self.cur)) + delta;
        if (idx < 0) return 0;
        if (idx >= self.chars.len) return 0;
        return self.chars[@intCast(idx)];
    }

    fn cur_char(self: *const RegexConverter) Codepoint {
        return self.peek(0);
    }

    fn remaining(self: *const RegexConverter) usize {
        return self.end - self.cur;
    }

    /// Records the failure and returns `error.Regex` (Rust `RegexError` construction).
    fn fail(self: *const RegexConverter, message: []const u8) RegexError {
        if (self.diag) |d| {
            d.* = .{
                .position = self.cur + 1,
                .message = self.gpa.dupe(u8, message) catch return error.OutOfMemory,
            };
        }
        return error.Regex;
    }

    /// Appends an EBNF segment, prefixing a space when the result is non-empty.
    fn add_segment(self: *RegexConverter, element: []const u8) Allocator.Error!void {
        if (self.result.items.len != 0) {
            try self.result.append(self.arena, ' ');
        }
        try self.result.appendSlice(self.arena, element);
    }

    fn handle_character_class(self: *RegexConverter) RegexError![]u8 {
        var char_class: std.ArrayList(u8) = .empty;
        try char_class.append(self.arena, '[');
        self.cur += 1;
        if (self.cur_char() == ']') {
            return self.fail("Empty character class is not allowed in regex.");
        }
        while (self.cur_char() != ']' and self.cur != self.end) {
            if (self.cur_char() == '\\') {
                const escaped = try self.handle_escape_in_char_class();
                defer self.arena.free(escaped);
                try char_class.appendSlice(self.arena, escaped);
            } else {
                try append_codepoint(&char_class, self.arena, self.cur_char());
                self.cur += 1;
            }
        }
        if (self.cur == self.end) {
            return self.fail("Unclosed '['");
        }
        try char_class.append(self.arena, ']');
        self.cur += 1;
        return char_class.toOwnedSlice(self.arena);
    }

    // {x}, {x,}, {x,y}
    fn handle_repetition_range(self: *RegexConverter) RegexError![]u8 {
        var result: std.ArrayList(u8) = .empty;
        try result.append(self.arena, '{');
        self.cur += 1;
        if (!is_ascii_digit(self.cur_char())) {
            return self.fail("Invalid repetition count.");
        }
        while (is_ascii_digit(self.cur_char())) {
            try result.append(self.arena, @intCast(self.cur_char()));
            self.cur += 1;
        }
        if (self.cur_char() != ',' and self.cur_char() != '}') {
            return self.fail("Invalid repetition count.");
        }
        try result.append(self.arena, @intCast(self.cur_char()));
        self.cur += 1;
        if (self.peek(-1) == '}') {
            return result.toOwnedSlice(self.arena);
        }
        if (!is_ascii_digit(self.cur_char()) and self.cur_char() != '}') {
            return self.fail("Invalid repetition count.");
        }
        while (is_ascii_digit(self.cur_char())) {
            try result.append(self.arena, @intCast(self.cur_char()));
            self.cur += 1;
        }
        if (self.cur_char() != '}') {
            return self.fail("Invalid repetition count.");
        }
        try result.append(self.arena, '}');
        self.cur += 1;
        return result.toOwnedSlice(self.arena);
    }

    /// Parses an escape sequence beginning at the current `\`, mirroring `ParseNextEscaped`.
    fn try_parse_escaped(self: *const RegexConverter) ?support.encoding.Decoded {
        var i: usize = self.cur;
        var bytes: std.ArrayList(u8) = .empty;
        while (i < self.end) : (i += 1) {
            const c = self.chars[i];
            bytes.append(self.arena, if (c < 128) @intCast(c) else 0xFF) catch return null;
        }
        return parse_next_escaped(bytes.items, &CHAR_ESCAPE_MAP) catch null;
    }

    fn handle_char_escape(self: *RegexConverter) RegexError![]u8 {
        const c1 = self.peek(1);
        const rem = self.remaining();
        if (rem < 2 or (c1 == 'u' and rem < 5) or (c1 == 'x' and rem < 4) or (c1 == 'c' and rem < 3)) {
            return self.fail("Escape sequence is not finished.");
        }

        if (self.try_parse_escaped()) |decoded| {
            self.cur += decoded.consumed;
            return escape_codepoint(self.arena, decoded.codepoint, &.{});
        } else if (c1 == 'u' and self.peek(2) == '{') {
            self.cur += 3;
            var len: usize = 0;
            var value: Codepoint = 0;
            while (len <= 6) {
                const digit = std.fmt.charToDigit(@intCast(self.peek(@intCast(len))), 16) catch break;
                value = value * 16 + digit;
                len += 1;
            }
            if (len == 0 or len > 6 or self.peek(@intCast(len)) != '}') {
                return self.fail("Invalid Unicode escape sequence.");
            }
            self.cur += len + 1;
            return escape_codepoint(self.arena, value, &.{});
        } else if (c1 == 'c') {
            self.cur += 2;
            if (!is_ascii_alphabetic(self.cur_char())) {
                return self.fail("Invalid control character escape sequence.");
            }
            self.cur += 1;
            return escape_codepoint(self.arena, @mod(self.peek(-1), 32), &.{});
        } else {
            // Unrecognized escape: match the character itself.
            self.cur += 2;
            return escape_codepoint(self.arena, self.peek(-1), &.{});
        }
    }

    fn handle_escape_in_char_class(self: *RegexConverter) RegexError![]u8 {
        if (self.remaining() < 2) {
            return self.fail("Escape sequence is not finished.");
        }
        return switch (self.peek(1)) {
            'd' => blk: {
                self.cur += 2;
                break :blk self.arena.dupe(u8, "0-9");
            },
            'D' => blk: {
                self.cur += 2;
                break :blk self.arena.dupe(u8, "\\x00-\\x2F\\x3A-\\U0010FFFF");
            },
            'w' => blk: {
                self.cur += 2;
                break :blk self.arena.dupe(u8, "a-zA-Z0-9_");
            },
            'W' => blk: {
                self.cur += 2;
                break :blk self.arena.dupe(u8, "\\x00-\\x2F\\x3A-\\x40\\x5B-\\x5E\\x60\\x7B-\\U0010FFFF");
            },
            's' => blk: {
                self.cur += 2;
                break :blk self.arena.dupe(u8, "\\f\\n\\r\\t\\v\\u0020\\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff");
            },
            'S' => blk: {
                self.cur += 2;
                break :blk self.arena.dupe(u8, "\\x00-\\x08\\x0E-\\x1F\\x21-\\x9F\\xA1-\\u167F\\u1681-\\u1FFF\\u200B-\\u2027\\u202A-\\u202E\\u2030-\\u205E\\u2060-\\u2FFF\\u3001-\\uFEFE\\uFF00-\\U0010FFFF");
            },
            else => blk: {
                const res = try self.handle_char_escape();
                if (std.mem.eql(u8, res, "]") or std.mem.eql(u8, res, "-")) {
                    break :blk std.fmt.allocPrint(self.arena, "\\{s}", .{res});
                }
                break :blk res;
            },
        };
    }

    fn handle_escape(self: *RegexConverter) RegexError![]u8 {
        if (self.remaining() < 2) {
            return self.fail("Escape sequence is not finished.");
        }
        return switch (self.peek(1)) {
            'd' => blk: {
                self.cur += 2;
                break :blk self.arena.dupe(u8, "[0-9]");
            },
            'D' => blk: {
                self.cur += 2;
                break :blk self.arena.dupe(u8, "[^0-9]");
            },
            'w' => blk: {
                self.cur += 2;
                break :blk self.arena.dupe(u8, "[a-zA-Z0-9_]");
            },
            'W' => blk: {
                self.cur += 2;
                break :blk self.arena.dupe(u8, "[^a-zA-Z0-9_]");
            },
            's' => blk: {
                self.cur += 2;
                break :blk self.arena.dupe(u8, "[\\f\\n\\r\\t\\v\\u0020\\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff]");
            },
            'S' => blk: {
                self.cur += 2;
                break :blk self.arena.dupe(u8, "[^\\f\\n\\r\\t\\v\\u0020\\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff]");
            },
            '1'...'9', 'k' => self.fail("Backreference is not supported yet."),
            'p', 'P' => self.fail("Unicode character class escape sequence is not supported yet."),
            'b', 'B' => self.fail("Word boundary is not supported yet."),
            else => blk: {
                const escaped = try self.handle_char_escape();
                break :blk std.fmt.allocPrint(self.arena, "\"{s}\"", .{escaped});
            },
        };
    }

    fn handle_group_modifier(self: *RegexConverter) RegexError!void {
        if (self.cur == self.end) {
            return self.fail("Group modifier is not finished.");
        }
        switch (self.cur_char()) {
            ':' => {
                self.cur += 1;
            },
            '=', '!' => {
                return self.fail("Lookahead is not supported yet.");
            },
            '<' => {
                if (self.cur + 1 != self.end and (self.peek(1) == '=' or self.peek(1) == '!')) {
                    return self.fail("Lookbehind is not supported yet.");
                }
                self.cur += 1;
                while (self.cur != self.end and is_ascii_alphabetic(self.cur_char())) {
                    self.cur += 1;
                }
                if (self.cur == self.end or self.cur_char() != '>') {
                    return self.fail("Invalid named capturing group.");
                }
                self.cur += 1;
            },
            else => {
                return self.fail("Group modifier flag is not supported yet.");
            },
        }
    }

    fn convert(self: *RegexConverter) RegexError![]u8 {
        var is_empty = true;
        while (self.cur != self.end) {
            switch (self.cur_char()) {
                '^' => {
                    // '^' is only meaningful at the start; elsewhere it is ignored.
                    self.cur += 1;
                },
                '$' => {
                    // '$' is only meaningful at the end; elsewhere it is ignored.
                    self.cur += 1;
                },
                '[' => {
                    is_empty = false;
                    const class = try self.handle_character_class();
                    defer self.arena.free(class);
                    try self.add_segment(class);
                },
                '(' => {
                    is_empty = false;
                    self.cur += 1;
                    self.parenthesis_level += 1;
                    try self.add_segment("(");
                    if (self.cur != self.end and self.cur_char() == '?') {
                        self.cur += 1;
                        try self.handle_group_modifier();
                    }
                },
                ')' => {
                    is_empty = false;
                    if (self.parenthesis_level == 0) {
                        return self.fail("Unmatched ')'");
                    }
                    // Emit an explicit empty string for an empty alternative, including
                    // patterns such as `(a|$)` where `$` was ignored just before `)`.
                    if (self.result.items.len != 0 and self.result.items[self.result.items.len - 1] == '|') {
                        try self.add_segment("\"\"");
                    }
                    self.parenthesis_level -= 1;
                    try self.add_segment(")");
                    self.cur += 1;
                },
                '*', '+', '?' => {
                    is_empty = false;
                    try self.result.append(self.arena, @intCast(self.cur_char()));
                    self.cur += 1;
                    if (self.cur != self.end and self.cur_char() == '?') {
                        // Ignore the non-greedy modifier; repetition is non-deterministic.
                        self.cur += 1;
                    }
                    if (self.cur != self.end and
                        (self.cur_char() == '{' or self.cur_char() == '*' or self.cur_char() == '+' or self.cur_char() == '?'))
                    {
                        return self.fail("Two consecutive repetition modifiers are not allowed.");
                    }
                },
                '{' => {
                    is_empty = false;
                    const range = try self.handle_repetition_range();
                    defer self.arena.free(range);
                    try self.result.appendSlice(self.arena, range);
                    if (self.cur != self.end and self.cur_char() == '?') {
                        self.cur += 1;
                    }
                    if (self.cur != self.end and
                        (self.cur_char() == '{' or self.cur_char() == '*' or self.cur_char() == '+' or self.cur_char() == '?'))
                    {
                        return self.fail("Two consecutive repetition modifiers are not allowed.");
                    }
                },
                '|' => {
                    is_empty = false;
                    // A leading, consecutive, or group-leading `|` has an empty left-hand
                    // alternative. EBNF needs that alternative to be explicit.
                    const last: u8 = if (self.result.items.len != 0) self.result.items[self.result.items.len - 1] else 0;
                    if (self.result.items.len == 0 or last == '|' or last == '(') {
                        try self.add_segment("\"\"");
                    }
                    try self.add_segment("|");
                    self.cur += 1;
                },
                '\\' => {
                    is_empty = false;
                    const escaped = try self.handle_escape();
                    defer self.arena.free(escaped);
                    try self.add_segment(escaped);
                },
                '.' => {
                    is_empty = false;
                    try self.add_segment("[\\u0000-\\U0010FFFF]");
                    self.cur += 1;
                },
                else => |c| {
                    is_empty = false;
                    const escaped = try escape_codepoint(self.arena, c, &.{});
                    defer self.arena.free(escaped);
                    const segment = try std.fmt.allocPrint(self.arena, "\"{s}\"", .{escaped});
                    defer self.arena.free(segment);
                    try self.add_segment(segment);
                    self.cur += 1;
                },
            }
        }
        if (self.parenthesis_level != 0) {
            return self.fail("The parenthesis is not closed.");
        }
        const last: u8 = if (self.result.items.len != 0) self.result.items[self.result.items.len - 1] else 0;
        if (last == '|') {
            try self.add_segment("\"\"");
        }
        if (is_empty) {
            try self.add_segment("\"\"");
        }
        return self.result.toOwnedSlice(self.arena);
    }
};

fn is_ascii_digit(c: Codepoint) bool {
    return c >= '0' and c <= '9';
}

fn is_ascii_alphabetic(c: Codepoint) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn append_codepoint(list: *std.ArrayList(u8), allocator: Allocator, c: Codepoint) Allocator.Error!void {
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(@intCast(c), &buf) catch {
        try list.append(allocator, 0xEF);
        try list.append(allocator, 0xBF);
        try list.append(allocator, 0xBD);
        return;
    };
    try list.appendSlice(allocator, buf[0..len]);
}
