//! Converts a (JavaScript-flavored) regex into EBNF and normalized `Grammar`
//! (`regex_converter.rs` + `regex_error.rs`).
//!
//! Reference:
//! <https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Regular_expressions>.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Diagnostic = @import("../Diagnostic.zig").Diagnostic;
const functor = @import("../functor.zig");
const grammar_mod = @import("../grammar.zig");
const Grammar = grammar_mod.Grammar;
const support = @import("../support.zig");
const Codepoint = support.Codepoint;
const ByteEscape = support.encoding.ByteEscape;
const escapeCodepoint = support.encoding.escapeCodepoint;
const parseNextEscaped = support.encoding.parseNextEscaped;

const log = std.log.scoped(.xgrammar);

/// Errors raised while converting a regular expression to EBNF or a `Grammar`.
pub const RegexError = error{
    Regex,
    OutOfMemory,
};

/// Constructs a normalized `Grammar` from a regular expression string.
///
/// On failure, `diag` (if given) is populated with `.regex` kind and 1-based offset
/// (or offset `0` for downstream EBNF/normalization errors).
pub fn fromRegex(gpa: Allocator, regex: []const u8, diag: ?*Diagnostic) RegexError!Grammar {
    return fromRegexWithOptions(gpa, regex, false, diag);
}

/// Constructs a normalized `Grammar` from a regular expression string.
/// If `print_converted_ebnf` is true, logs the intermediate EBNF at info level.
pub fn fromRegexWithOptions(
    gpa: Allocator,
    regex: []const u8,
    print_converted_ebnf: bool,
    diag: ?*Diagnostic,
) RegexError!Grammar {
    const ebnf = try regexToEbnf(gpa, regex, true, diag);
    defer gpa.free(ebnf);
    if (print_converted_ebnf) {
        log.info("{s}", .{ebnf});
    }
    var ebnf_diag: Diagnostic = .{};
    defer ebnf_diag.deinit(gpa);
    return functor.fromEbnf(gpa, ebnf, "root", if (diag != null) &ebnf_diag else null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (diag) |d| {
                try d.setAtOffsetFmt(gpa, .regex, 0, "{f}", .{ebnf_diag});
            }
            return error.Regex;
        },
    };
}

/// Escapes recognized in `handleCharEscape` (each maps to itself); takes precedence over
/// the built-in C-style escapes in `parseNextEscaped`.
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

/// Converts `regex` to an EBNF body. With `with_rule_name`, wraps it as a full `root` rule.
/// On failure, `diag` (if given) receives `.regex` diagnostic with 1-based offset.
pub fn regexToEbnf(
    gpa: Allocator,
    regex: []const u8,
    with_rule_name: bool,
    diag: ?*Diagnostic,
) RegexError![]u8 {
    // NUL is never meaningful in a regex, and the converter uses it as its end sentinel.
    if (std.mem.indexOfScalar(u8, regex, 0)) |position| {
        if (diag) |d| {
            try d.setAtOffsetFmt(gpa, .regex, position + 1, "The regex must not contain null characters.", .{});
        }
        return error.Regex;
    }
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const chars = try utf8Codepoints(arena.allocator(), regex);
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

/// Decodes UTF-8 text into its codepoint slice (`0xFFFD` on ill-formed sequences).
fn utf8Codepoints(allocator: Allocator, text: []const u8) Allocator.Error![]Codepoint {
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
    diag: ?*Diagnostic,
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

    fn curChar(self: *const RegexConverter) Codepoint {
        return self.peek(0);
    }

    fn remaining(self: *const RegexConverter) usize {
        return self.end - self.cur;
    }

    /// Records the failure in `diag` (1-based position) and returns `error.Regex`.
    fn fail(self: *const RegexConverter, message: []const u8) RegexError {
        if (self.diag) |d| {
            try d.setAtOffsetFmt(self.gpa, .regex, self.cur + 1, "{s}", .{message});
        }
        return error.Regex;
    }

    /// Appends an EBNF segment, prefixing a space when the result is non-empty.
    fn addSegment(self: *RegexConverter, element: []const u8) Allocator.Error!void {
        if (self.result.items.len != 0) {
            try self.result.append(self.arena, ' ');
        }
        try self.result.appendSlice(self.arena, element);
    }

    fn handleCharacterClass(self: *RegexConverter) RegexError![]u8 {
        var char_class: std.ArrayList(u8) = .empty;
        try char_class.append(self.arena, '[');
        self.cur += 1;
        if (self.curChar() == ']') {
            return self.fail("Empty character class is not allowed in regex.");
        }
        while (self.curChar() != ']' and self.cur != self.end) {
            if (self.curChar() == '\\') {
                const escaped = try self.handleEscapeInCharClass();
                defer self.arena.free(escaped);
                try char_class.appendSlice(self.arena, escaped);
            } else {
                try appendCodepoint(&char_class, self.arena, self.curChar());
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
    fn handleRepetitionRange(self: *RegexConverter) RegexError![]u8 {
        var result: std.ArrayList(u8) = .empty;
        try result.append(self.arena, '{');
        self.cur += 1;
        if (!isAsciiDigit(self.curChar())) {
            return self.fail("Invalid repetition count.");
        }
        while (isAsciiDigit(self.curChar())) {
            try result.append(self.arena, @intCast(self.curChar()));
            self.cur += 1;
        }
        if (self.curChar() != ',' and self.curChar() != '}') {
            return self.fail("Invalid repetition count.");
        }
        try result.append(self.arena, @intCast(self.curChar()));
        self.cur += 1;
        if (self.peek(-1) == '}') {
            return result.toOwnedSlice(self.arena);
        }
        if (!isAsciiDigit(self.curChar()) and self.curChar() != '}') {
            return self.fail("Invalid repetition count.");
        }
        while (isAsciiDigit(self.curChar())) {
            try result.append(self.arena, @intCast(self.curChar()));
            self.cur += 1;
        }
        if (self.curChar() != '}') {
            return self.fail("Invalid repetition count.");
        }
        try result.append(self.arena, '}');
        self.cur += 1;
        return result.toOwnedSlice(self.arena);
    }

    /// Parses an escape sequence beginning at the current `\`, mirroring `parseNextEscaped`.
    fn tryParseEscaped(self: *const RegexConverter) ?support.encoding.Decoded {
        const rem = self.remaining();
        var stack_buf: [64]u8 = undefined;
        const need_heap = rem > stack_buf.len and self.peek(1) == 'x';
        const slice: []u8 = if (need_heap)
            self.arena.alloc(u8, rem) catch return null
        else
            stack_buf[0..@min(rem, stack_buf.len)];
        defer if (need_heap) self.arena.free(slice);
        for (slice, 0..) |*dst, idx| {
            const c = self.chars[self.cur + idx];
            dst.* = if (c < 128) @intCast(c) else 0xFF;
        }
        return parseNextEscaped(slice, &CHAR_ESCAPE_MAP) catch null;
    }

    fn handleCharEscape(self: *RegexConverter) RegexError![]u8 {
        const c1 = self.peek(1);
        const rem = self.remaining();
        if (rem < 2 or (c1 == 'u' and rem < 5) or (c1 == 'x' and rem < 4) or (c1 == 'c' and rem < 3)) {
            return self.fail("Escape sequence is not finished.");
        }

        if (self.tryParseEscaped()) |decoded| {
            self.cur += decoded.consumed;
            return escapeCodepoint(self.arena, decoded.codepoint, &.{});
        } else if (c1 == 'u' and self.peek(2) == '{') {
            self.cur += 3;
            var len: usize = 0;
            var value: Codepoint = 0;
            while (len <= 6) {
                const ch = self.peek(@intCast(len));
                if (ch < 0 or ch > 0x7F) break;
                const digit = std.fmt.charToDigit(@intCast(ch), 16) catch break;
                value = value * 16 + digit;
                len += 1;
            }
            if (len == 0 or len > 6 or self.peek(@intCast(len)) != '}') {
                return self.fail("Invalid Unicode escape sequence.");
            }
            self.cur += len + 1;
            return escapeCodepoint(self.arena, value, &.{});
        } else if (c1 == 'c') {
            self.cur += 2;
            if (!isAsciiAlphabetic(self.curChar())) {
                return self.fail("Invalid control character escape sequence.");
            }
            self.cur += 1;
            return escapeCodepoint(self.arena, @mod(self.peek(-1), 32), &.{});
        } else {
            // Unrecognized escape: match the character itself.
            self.cur += 2;
            return escapeCodepoint(self.arena, self.peek(-1), &.{});
        }
    }

    fn handleEscapeInCharClass(self: *RegexConverter) RegexError![]u8 {
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
                const res = try self.handleCharEscape();
                if (std.mem.eql(u8, res, "]") or std.mem.eql(u8, res, "-")) {
                    break :blk std.fmt.allocPrint(self.arena, "\\{s}", .{res});
                }
                break :blk res;
            },
        };
    }

    fn handleEscape(self: *RegexConverter) RegexError![]u8 {
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
                const escaped = try self.handleCharEscape();
                break :blk std.fmt.allocPrint(self.arena, "\"{s}\"", .{escaped});
            },
        };
    }

    fn handleGroupModifier(self: *RegexConverter) RegexError!void {
        if (self.cur == self.end) {
            return self.fail("Group modifier is not finished.");
        }
        switch (self.curChar()) {
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
                while (self.cur != self.end and isAsciiAlphabetic(self.curChar())) {
                    self.cur += 1;
                }
                if (self.cur == self.end or self.curChar() != '>') {
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
            switch (self.curChar()) {
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
                    const class = try self.handleCharacterClass();
                    defer self.arena.free(class);
                    try self.addSegment(class);
                },
                '(' => {
                    is_empty = false;
                    self.cur += 1;
                    self.parenthesis_level += 1;
                    try self.addSegment("(");
                    if (self.cur != self.end and self.curChar() == '?') {
                        self.cur += 1;
                        try self.handleGroupModifier();
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
                        try self.addSegment("\"\"");
                    }
                    self.parenthesis_level -= 1;
                    try self.addSegment(")");
                    self.cur += 1;
                },
                '*', '+', '?' => {
                    is_empty = false;
                    try self.result.append(self.arena, @intCast(self.curChar()));
                    self.cur += 1;
                    if (self.cur != self.end and self.curChar() == '?') {
                        // Ignore the non-greedy modifier; repetition is non-deterministic.
                        self.cur += 1;
                    }
                    if (self.cur != self.end and
                        (self.curChar() == '{' or self.curChar() == '*' or self.curChar() == '+' or self.curChar() == '?'))
                    {
                        return self.fail("Two consecutive repetition modifiers are not allowed.");
                    }
                },
                '{' => {
                    is_empty = false;
                    const range = try self.handleRepetitionRange();
                    defer self.arena.free(range);
                    try self.result.appendSlice(self.arena, range);
                    if (self.cur != self.end and self.curChar() == '?') {
                        self.cur += 1;
                    }
                    if (self.cur != self.end and
                        (self.curChar() == '{' or self.curChar() == '*' or self.curChar() == '+' or self.curChar() == '?'))
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
                        try self.addSegment("\"\"");
                    }
                    try self.addSegment("|");
                    self.cur += 1;
                },
                '\\' => {
                    is_empty = false;
                    const escaped = try self.handleEscape();
                    defer self.arena.free(escaped);
                    try self.addSegment(escaped);
                },
                '.' => {
                    is_empty = false;
                    try self.addSegment("[\\u0000-\\U0010FFFF]");
                    self.cur += 1;
                },
                else => |c| {
                    is_empty = false;
                    const escaped = try escapeCodepoint(self.arena, c, &.{});
                    defer self.arena.free(escaped);
                    const segment = try std.fmt.allocPrint(self.arena, "\"{s}\"", .{escaped});
                    defer self.arena.free(segment);
                    try self.addSegment(segment);
                    self.cur += 1;
                },
            }
        }
        if (self.parenthesis_level != 0) {
            return self.fail("The parenthesis is not closed.");
        }
        const last: u8 = if (self.result.items.len != 0) self.result.items[self.result.items.len - 1] else 0;
        if (last == '|') {
            try self.addSegment("\"\"");
        }
        if (is_empty) {
            try self.addSegment("\"\"");
        }
        return self.result.toOwnedSlice(self.arena);
    }
};

fn isAsciiDigit(c: Codepoint) bool {
    return c >= '0' and c <= '9';
}

fn isAsciiAlphabetic(c: Codepoint) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn appendCodepoint(list: *std.ArrayList(u8), allocator: Allocator, c: Codepoint) Allocator.Error!void {
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(@intCast(c), &buf) catch {
        try list.append(allocator, 0xEF);
        try list.append(allocator, 0xBF);
        try list.append(allocator, 0xBD);
        return;
    };
    try list.appendSlice(allocator, buf[0..len]);
}

test "regexToEbnf and fromRegex basic conversion and zero-leak diagnostics" {
    const a = std.testing.allocator;

    const ebnf = try regexToEbnf(a, "^[a-z]{2,3}|foo$", true, null);
    defer a.free(ebnf);
    try std.testing.expectEqualStrings("root ::= [a-z]{2,3} | \"f\" \"o\" \"o\"\n", ebnf);

    var g = try fromRegex(a, "a(b|c)+", null);
    defer g.deinit();
    try std.testing.expect(g.numRules() >= 1);

    // Invalid regex with diag == null (zero leaks).
    try std.testing.expectError(error.Regex, fromRegex(a, "(abc", null));
    try std.testing.expectError(error.Regex, fromRegex(a, "a[]b", null));
    try std.testing.expectError(error.Regex, fromRegex(a, "a\x00b", null));
    try std.testing.expectError(error.Regex, fromRegex(a, "a{10,5}", null));

    // Reusable Diagnostic across multiple errors (direct regex failure and downstream EBNF failure).
    var diag: Diagnostic = .{};
    defer diag.deinit(a);

    try std.testing.expectError(error.Regex, fromRegex(a, "a[]b", &diag));
    const msg1 = try diag.formatAlloc(a);
    defer a.free(msg1);
    try std.testing.expectEqualStrings("Regex parsing error at position 3: Empty character class is not allowed in regex.", msg1);

    // Downstream EBNF error: position must be 0 and prior diag buffer must be freed cleanly.
    try std.testing.expectError(error.Regex, fromRegex(a, "+a", &diag));
    const msg2 = try diag.formatAlloc(a);
    defer a.free(msg2);
    try std.testing.expect(std.mem.startsWith(u8, msg2, "Regex parsing error at position 0: "));

    // NUL byte diagnostic.
    try std.testing.expectError(error.Regex, regexToEbnf(a, "a\x00b", false, &diag));
    const msg3 = try diag.formatAlloc(a);
    defer a.free(msg3);
    try std.testing.expectEqualStrings("Regex parsing error at position 2: The regex must not contain null characters.", msg3);
}
