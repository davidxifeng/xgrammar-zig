//! Tokenizer for the Lark grammar syntax (`lark_lexer.rs`).
//!
//! Tokens and their strings are allocated from the caller's (document arena) allocator.
//! Rust `Result<_, LarkError>` → `LarkError!T` with an optional `?*LarkErrorInfo` diag.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lark_error = @import("lark_error.zig");
const lark_location = @import("lark_location.zig");
const lark_token = @import("lark_token.zig");
const lark_token_type = @import("lark_token_type.zig");
const support = @import("../support/mod.zig");
const LarkError = lark_error.LarkError;
const LarkErrorInfo = lark_error.LarkErrorInfo;
const LarkLocation = lark_location.LarkLocation;
const LarkToken = lark_token.LarkToken;
const LarkTokenType = lark_token_type.LarkTokenType;
const parse_json = support.json_parse.parse_json;

/// Splits a Lark source into `LarkToken`s, tracking 1-based line and byte columns.
pub const LarkLexer = struct {
    gpa: Allocator,
    /// Receives the failure payload; message strings are allocated from `gpa`.
    diag: ?*?LarkErrorInfo,
    /// Scratch for token strings and the token list (typically the document arena).
    arena: Allocator,
    source: []const u8,
    position: usize = 0,
    line: i32 = 1,
    column: i32 = 1,

    /// Tokenizes the whole source, ending with an `End` token.
    pub fn tokenize(self: *LarkLexer) LarkError!std.ArrayList(LarkToken) {
        var result: std.ArrayList(LarkToken) = .empty;
        while (self.position < self.source.len) {
            const c = self.source[self.position];
            if (c == ' ' or c == '\t' or c == 0x0C) {
                self.advance();
                continue;
            }
            if (c == '\r' or c == '\n') {
                const location = self.current_location();
                self.advance();
                if (c == '\r' and self.peek_char(0) == '\n') {
                    self.advance();
                }
                try result.append(self.arena, LarkToken{ .ty = .Newline, .text = "\n", .flags = "", .location = location });
                continue;
            }
            if (c == '#' or (c == '/' and self.peek_char(1) == '/')) {
                self.skip_comment();
                continue;
            }

            const location = self.current_location();
            const next = self.peek_char(1);
            const token: LarkToken = switch (c) {
                ':' => if (next == ':') self.simple_token(.DoubleColon, 2) else self.simple_token(.Colon, 1),
                ',' => self.simple_token(.Comma, 1),
                '.' => if (next == '.') self.simple_token(.DotDot, 2) else self.simple_token(.Dot, 1),
                '-' => blk: {
                    if (next == '>') break :blk self.simple_token(.Arrow, 2);
                    if (next_is_digit(next)) break :blk self.lex_number();
                    return self.err(location, "unexpected '-' character");
                },
                '+' => if (next_is_digit(next)) self.lex_number() else self.simple_token(.Plus, 1),
                '=' => self.simple_token(.Equals, 1),
                '(' => self.simple_token(.LParen, 1),
                ')' => self.simple_token(.RParen, 1),
                '[' => self.simple_token(.LBracket, 1),
                ']' => self.simple_token(.RBracket, 1),
                '{' => self.simple_token(.LBrace, 1),
                '}' => self.simple_token(.RBrace, 1),
                '|' => self.simple_token(.Pipe, 1),
                '&' => self.simple_token(.And, 1),
                '~' => self.simple_token(.Tilde, 1),
                '?' => if (next_is_alpha_or_underscore(next)) self.lex_name() else self.simple_token(.Question, 1),
                '*' => self.simple_token(.Star, 1),
                '!' => blk: {
                    if (next_is_alpha_or_underscore(next)) break :blk self.lex_name();
                    return self.err(location, "unexpected '!' character");
                },
                '"' => try self.lex_string(),
                '/' => try self.lex_regex(),
                '<' => try self.lex_special_token(),
                '@' => try self.lex_grammar_ref(),
                '%' => try self.lex_directive(),
                else => blk: {
                    if (is_ascii_alphabetic(c) or c == '_') break :blk self.lex_name();
                    if (is_ascii_digit(c)) break :blk self.lex_number();
                    const character: u21 = cp_blk: {
                        const decoded = slice_codepoint(self.source[self.position..]) catch break :cp_blk 0xFFFD;
                        break :cp_blk std.unicode.utf8Decode(decoded) catch 0xFFFD;
                    };
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(character, &buf) catch blk2: {
                        buf[0] = 0xEF;
                        buf[1] = 0xBF;
                        buf[2] = 0xBD;
                        break :blk2 3;
                    };
                    const message = try std.fmt.allocPrint(self.gpa, "unexpected character '{s}'", .{buf[0..len]});
                    defer self.gpa.free(message);
                    return self.err(location, message);
                },
            };
            try result.append(self.arena, token);
        }
        try result.append(self.arena, LarkToken{ .ty = .End, .text = "", .flags = "", .location = self.current_location() });
        return result;
    }

    fn err(self: *LarkLexer, location: LarkLocation, message: []const u8) LarkError {
        if (self.diag) |d| {
            lark_error.set_info(d, try lark_error.at(self.gpa, self.source, location, message), self.gpa) catch return error.OutOfMemory;
        }
        return error.Lark;
    }

    fn peek_char(self: *const LarkLexer, offset: usize) u8 {
        if (self.position + offset >= self.source.len) return 0;
        return self.source[self.position + offset];
    }

    fn current_location(self: *const LarkLexer) LarkLocation {
        return .{ .line = self.line, .column = self.column };
    }

    fn advance(self: *LarkLexer) void {
        if (self.position >= self.source.len) return;
        const c = self.source[self.position];
        self.position += 1;
        if (c == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
    }

    fn advance_to(self: *LarkLexer, end_position: usize) void {
        while (self.position < end_position) {
            self.advance();
        }
    }

    fn slice(self: *const LarkLexer, start: usize, end: usize) []const u8 {
        // The source is a `&str` (UTF-8 valid by contract); slice verbatim.
        return self.source[start..end];
    }

    fn simple_token(self: *LarkLexer, ty: LarkTokenType, length: usize) LarkToken {
        const location = self.current_location();
        const text = self.slice(self.position, self.position + length);
        self.advance_to(self.position + length);
        return .{ .ty = ty, .text = text, .flags = "", .location = location };
    }

    fn skip_comment(self: *LarkLexer) void {
        while (self.position < self.source.len and self.source[self.position] != '\n' and self.source[self.position] != '\r') {
            self.advance();
        }
    }

    fn lex_name(self: *LarkLexer) LarkToken {
        const location = self.current_location();
        const start = self.position;
        if (self.source[self.position] == '!' or self.source[self.position] == '?') {
            self.advance();
        }
        while (self.position < self.source.len) {
            const c = self.source[self.position];
            if (!is_ascii_alphanumeric(c) and c != '_' and c != '-') break;
            self.advance();
        }
        return .{ .ty = .Name, .text = self.slice(start, self.position), .flags = "", .location = location };
    }

    fn advance_digits(self: *LarkLexer) void {
        while (is_ascii_digit(self.peek_char(0))) {
            self.advance();
        }
    }

    fn lex_number(self: *LarkLexer) LarkToken {
        const location = self.current_location();
        const start = self.position;
        if (self.source[self.position] == '+' or self.source[self.position] == '-') {
            self.advance();
        }
        self.advance_digits();
        if (self.peek_char(0) == '.' and self.peek_char(1) != '.') {
            self.advance();
            self.advance_digits();
        }
        if (self.peek_char(0) == 'e' or self.peek_char(0) == 'E') {
            self.advance();
            if (self.peek_char(0) == '+' or self.peek_char(0) == '-') {
                self.advance();
            }
            self.advance_digits();
        }
        return .{ .ty = .Number, .text = self.slice(start, self.position), .flags = "", .location = location };
    }

    fn lex_string(self: *LarkLexer) LarkError!LarkToken {
        const location = self.current_location();
        const start = self.position;
        self.advance();
        var escaped = false;
        while (self.position < self.source.len) {
            const c = self.source[self.position];
            if (!escaped and c == '"') {
                self.advance();
                if (self.peek_char(0) == 'i') {
                    self.advance();
                }
                return .{ .ty = .String, .text = self.slice(start, self.position), .flags = "", .location = location };
            }
            if (c == '\n' or c == '\r') break;
            escaped = !escaped and c == '\\';
            self.advance();
        }
        return self.err(location, "unterminated string literal");
    }

    fn lex_regex(self: *LarkLexer) LarkError!LarkToken {
        const location = self.current_location();
        self.advance();
        const pattern_start = self.position;
        var escaped = false;
        while (self.position < self.source.len) {
            const c = self.source[self.position];
            if (!escaped and c == '/') {
                const pattern = self.slice(pattern_start, self.position);
                self.advance();
                const flags_start = self.position;
                while (is_ascii_alphabetic(self.peek_char(0))) {
                    self.advance();
                }
                return .{ .ty = .Regex, .text = pattern, .flags = self.slice(flags_start, self.position), .location = location };
            }
            escaped = !escaped and c == '\\';
            self.advance();
        }
        return self.err(location, "unterminated regular expression");
    }

    fn lex_special_token(self: *LarkLexer) LarkError!LarkToken {
        const location = self.current_location();
        const start = self.position;
        self.advance();
        while (self.position < self.source.len and self.source[self.position] != '>') {
            const c = self.source[self.position];
            if (is_c_space(c) or c == '<') {
                return self.err(location, "invalid special token");
            }
            self.advance();
        }
        if (self.position == self.source.len) {
            return self.err(location, "unterminated special token");
        }
        self.advance();
        return .{ .ty = .SpecialToken, .text = self.slice(start, self.position), .flags = "", .location = location };
    }

    fn lex_grammar_ref(self: *LarkLexer) LarkError!LarkToken {
        const location = self.current_location();
        const start = self.position;
        self.advance();
        while (is_ascii_alphanumeric(self.peek_char(0)) or self.peek_char(0) == '_' or self.peek_char(0) == '-') {
            self.advance();
        }
        if (self.position == start + 1) {
            return self.err(location, "empty grammar reference");
        }
        return .{ .ty = .GrammarRef, .text = self.slice(start, self.position), .flags = "", .location = location };
    }

    fn lex_directive(self: *LarkLexer) LarkError!LarkToken {
        const location = self.current_location();
        const start = self.position;
        self.advance();
        while (is_ascii_alphabetic(self.peek_char(0)) or self.peek_char(0) == '_') {
            self.advance();
        }
        const directive = self.slice(start, self.position);
        const ty: LarkTokenType = if (std.mem.eql(u8, directive, "%json"))
            return self.lex_json_value(.Json, location, directive)
        else if (std.mem.eql(u8, directive, "%regex"))
            return self.lex_json_value(.RegexExt, location, directive)
        else if (std.mem.eql(u8, directive, "%grammar_options"))
            return self.lex_json_value(.GrammarOptions, location, directive)
        else if (std.mem.eql(u8, directive, "%import"))
            .Import
        else if (std.mem.eql(u8, directive, "%ignore"))
            .Ignore
        else if (std.mem.eql(u8, directive, "%lark"))
            .Lark
        else if (std.mem.eql(u8, directive, "%if"))
            .If
        else
            .UnsupportedDirective;
        return .{ .ty = ty, .text = directive, .flags = "", .location = location };
    }

    /// Parses one JSON value from the remaining source and re-serializes it as the token
    /// text. The re-serialization sorts object keys (Rust `serde_json::Value::to_string`
    /// uses `BTreeMap` key order; PORTING.md trap 1).
    fn lex_json_value(self: *LarkLexer, ty: LarkTokenType, location: LarkLocation, directive: []const u8) LarkError!LarkToken {
        while (self.position < self.source.len and is_c_space(self.source[self.position])) {
            self.advance();
        }
        const rest = self.source[@min(self.position, self.source.len)..];
        const end = json_value_end(self.arena, rest) orelse {
            const message = try std.fmt.allocPrint(self.gpa, "failed to parse JSON value after {s}: EOF while parsing a value", .{directive});
            defer self.gpa.free(message);
            return self.err(location, message);
        };
        const value = parse_json(self.arena, rest[0..end]) catch |parse_error| {
            const message = try std.fmt.allocPrint(self.gpa, "failed to parse JSON value after {s}: {s}", .{ directive, @errorName(parse_error) });
            defer self.gpa.free(message);
            return self.err(location, message);
        };
        self.advance_to(self.position + end);
        const text = serialize_json_value_sorted(self.arena, value) catch return error.OutOfMemory;
        return .{ .ty = ty, .text = text, .flags = "", .location = location };
    }
};

/// Whether `byte` is whitespace in the C locale (`std::isspace`).
pub fn is_c_space(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == 0x0B or byte == 0x0C or byte == '\r';
}

fn next_is_digit(next: u8) bool {
    return is_ascii_digit(next);
}

fn next_is_alpha_or_underscore(next: u8) bool {
    return is_ascii_alphabetic(next) or next == '_';
}

fn is_ascii_alphabetic(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn is_ascii_digit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn is_ascii_alphanumeric(c: u8) bool {
    return is_ascii_alphabetic(c) or is_ascii_digit(c);
}

/// Decodes the codepoint starting at `bytes` (possibly a replacement for invalid input).
fn slice_codepoint(bytes: []const u8) ![]const u8 {
    const len = try std.unicode.utf8ByteSequenceLength(bytes[0]);
    if (len > bytes.len) return error.InvalidUtf8;
    _ = try std.unicode.utf8Decode(bytes[0..len]);
    return bytes[0..len];
}

/// The byte offset just past the first JSON value in `rest`, or null when none parses
/// (serde_json `Deserializer::into_iter::<Value>()` + `byte_offset` semantics).
fn json_value_end(allocator: Allocator, rest: []const u8) ?usize {
    var scanner = std.json.Scanner.initCompleteInput(allocator, rest);
    defer scanner.deinit();
    var depth: usize = 0;
    while (true) {
        const token = scanner.next() catch return null;
        switch (token) {
            .object_begin, .array_begin => depth += 1,
            .object_end, .array_end => {
                depth -= 1;
                if (depth == 0) return scanner.cursor;
            },
            .true, .false, .null, .string, .allocated_string, .number, .allocated_number => {
                if (depth == 0) return scanner.cursor;
            },
            .partial_number,
            .partial_string,
            .partial_string_escaped_1,
            .partial_string_escaped_2,
            .partial_string_escaped_3,
            .partial_string_escaped_4,
            => {},
            .end_of_document => return null,
        }
    }
}

/// Compact JSON serialization with object keys in sorted (Rust `BTreeMap`) order.
pub fn serialize_json_value_sorted(allocator: Allocator, value: std.json.Value) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try write_json_value_sorted(&out, allocator, value);
    return out.toOwnedSlice(allocator);
}

fn write_json_value_sorted(out: *std.ArrayList(u8), allocator: Allocator, value: std.json.Value) Allocator.Error!void {
    switch (value) {
        .null => try out.appendSlice(allocator, "null"),
        .bool => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| try out.appendSlice(allocator, std.fmt.allocPrint(allocator, "{d}", .{i}) catch return error.OutOfMemory),
        .float => |f| try out.appendSlice(allocator, std.fmt.allocPrint(allocator, "{d}", .{f}) catch return error.OutOfMemory),
        .number_string => |s| try out.appendSlice(allocator, s),
        .string => |s| try write_json_string(out, allocator, s),
        .array => |array| {
            try out.append(allocator, '[');
            for (array.items, 0..) |item, i| {
                if (i != 0) try out.append(allocator, ',');
                try write_json_value_sorted(out, allocator, item);
            }
            try out.append(allocator, ']');
        },
        .object => |object| {
            // serde_json Map = BTreeMap: keys in dictionary order.
            var keys: std.ArrayList([]const u8) = .empty;
            defer keys.deinit(allocator);
            var it = object.iterator();
            while (it.next()) |entry| try keys.append(allocator, entry.key_ptr.*);
            std.mem.sort([]const u8, keys.items, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lessThan);
            try out.append(allocator, '{');
            for (keys.items, 0..) |key, i| {
                if (i != 0) try out.append(allocator, ',');
                try write_json_string(out, allocator, key);
                try out.append(allocator, ':');
                try write_json_value_sorted(out, allocator, object.get(key).?);
            }
            try out.append(allocator, '}');
        },
    }
}

fn write_json_string(out: *std.ArrayList(u8), allocator: Allocator, s: []const u8) Allocator.Error!void {
    try out.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0x08 => try out.appendSlice(allocator, "\\b"),
            0x0C => try out.appendSlice(allocator, "\\f"),
            else => {
                if (c < 0x20) {
                    const hex = std.fmt.allocPrint(allocator, "\\u{x:0>4}", .{c}) catch return error.OutOfMemory;
                    defer allocator.free(hex);
                    try out.appendSlice(allocator, hex);
                } else {
                    try out.append(allocator, c);
                }
            },
        }
    }
    try out.append(allocator, '"');
}
