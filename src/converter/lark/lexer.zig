//! Tokenizer for the Lark grammar syntax (`lark_lexer.rs`).
//!
//! Tokens and their strings are allocated from the caller's (document arena) allocator.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Diagnostic = @import("../../Diagnostic.zig").Diagnostic;
const support = @import("../../support.zig");
const ast = @import("ast.zig");

const LarkError = ast.LarkError;
const LarkLocation = ast.LarkLocation;
const LarkToken = ast.LarkToken;
const LarkTokenType = ast.LarkTokenType;

/// Splits a Lark source into `LarkToken`s, tracking 1-based line and byte columns.
pub const LarkLexer = struct {
    gpa: Allocator,
    /// Receives the failure payload; diagnostic buffers are owned by `diag`.
    diag: ?*Diagnostic,
    /// Scratch for token strings and the token list (typically the document arena).
    arena: Allocator,
    source: []const u8,
    position: usize = 0,
    line: i32 = 1,
    column: i32 = 1,

    /// Tokenizes the whole source, ending with an `End` token.
    pub fn tokenize(self: *LarkLexer) LarkError!std.ArrayList(LarkToken) {
        var result: std.ArrayList(LarkToken) = .empty;
        errdefer result.deinit(self.arena);
        while (self.position < self.source.len) {
            const c = self.source[self.position];
            if (c == ' ' or c == '\t' or c == 0x0C) {
                self.advance();
                continue;
            }
            if (c == '\r' or c == '\n') {
                const location = self.currentLocation();
                self.advance();
                if (c == '\r' and self.peekChar(0) == '\n') {
                    self.advance();
                }
                try result.append(self.arena, .{
                    .ty = .Newline,
                    .text = "\n",
                    .flags = "",
                    .location = location,
                });
                continue;
            }
            if (c == '#' or (c == '/' and self.peekChar(1) == '/')) {
                self.skipComment();
                continue;
            }

            const location = self.currentLocation();
            const next = self.peekChar(1);
            const token: LarkToken = switch (c) {
                ':' => if (next == ':') self.simpleToken(.DoubleColon, 2) else self.simpleToken(.Colon, 1),
                ',' => self.simpleToken(.Comma, 1),
                '.' => if (next == '.') self.simpleToken(.DotDot, 2) else self.simpleToken(.Dot, 1),
                '-' => blk: {
                    if (next == '>') break :blk self.simpleToken(.Arrow, 2);
                    if (nextIsDigit(next)) break :blk self.lexNumber();
                    return self.err(location, "unexpected '-' character");
                },
                '+' => if (nextIsDigit(next)) self.lexNumber() else self.simpleToken(.Plus, 1),
                '=' => self.simpleToken(.Equals, 1),
                '(' => self.simpleToken(.LParen, 1),
                ')' => self.simpleToken(.RParen, 1),
                '[' => self.simpleToken(.LBracket, 1),
                ']' => self.simpleToken(.RBracket, 1),
                '{' => self.simpleToken(.LBrace, 1),
                '}' => self.simpleToken(.RBrace, 1),
                '|' => self.simpleToken(.Pipe, 1),
                '&' => self.simpleToken(.And, 1),
                '~' => self.simpleToken(.Tilde, 1),
                '?' => if (nextIsAlphaOrUnderscore(next)) self.lexName() else self.simpleToken(.Question, 1),
                '*' => self.simpleToken(.Star, 1),
                '!' => blk: {
                    if (nextIsAlphaOrUnderscore(next)) break :blk self.lexName();
                    return self.err(location, "unexpected '!' character");
                },
                '"' => try self.lexString(),
                '/' => try self.lexRegex(),
                '<' => try self.lexSpecialToken(),
                '@' => try self.lexGrammarRef(),
                '%' => try self.lexDirective(),
                else => blk: {
                    if (isAsciiAlphabetic(c) or c == '_') break :blk self.lexName();
                    if (isAsciiDigit(c)) break :blk self.lexNumber();
                    const character: u21 = cp_blk: {
                        const decoded = sliceCodepoint(self.source[self.position..]) catch break :cp_blk 0xFFFD;
                        break :cp_blk std.unicode.utf8Decode(decoded) catch 0xFFFD;
                    };
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(character, &buf) catch blk2: {
                        buf[0] = 0xEF;
                        buf[1] = 0xBF;
                        buf[2] = 0xBD;
                        break :blk2 3;
                    };
                    return self.errFmt(location, "unexpected character '{s}'", .{buf[0..len]});
                },
            };
            try result.append(self.arena, token);
        }
        try result.append(self.arena, .{
            .ty = .End,
            .text = "",
            .flags = "",
            .location = self.currentLocation(),
        });
        return result;
    }

    fn err(self: *const LarkLexer, location: LarkLocation, message: []const u8) LarkError {
        return ast.failLocated(self.gpa, self.diag, self.source, location, message);
    }

    fn errFmt(self: *const LarkLexer, location: LarkLocation, comptime fmt: []const u8, args: anytype) LarkError {
        return ast.failLocatedFmt(self.gpa, self.diag, self.source, location, fmt, args);
    }

    fn peekChar(self: *const LarkLexer, offset: usize) u8 {
        if (self.position + offset >= self.source.len) return 0;
        return self.source[self.position + offset];
    }

    fn currentLocation(self: *const LarkLexer) LarkLocation {
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

    fn advanceTo(self: *LarkLexer, end_position: usize) void {
        while (self.position < end_position) {
            self.advance();
        }
    }

    fn slice(self: *const LarkLexer, start: usize, end: usize) []const u8 {
        return self.source[start..end];
    }

    fn simpleToken(self: *LarkLexer, ty: LarkTokenType, length: usize) LarkToken {
        const location = self.currentLocation();
        const text = self.slice(self.position, self.position + length);
        self.advanceTo(self.position + length);
        return .{ .ty = ty, .text = text, .flags = "", .location = location };
    }

    fn skipComment(self: *LarkLexer) void {
        while (self.position < self.source.len and self.source[self.position] != '\n' and self.source[self.position] != '\r') {
            self.advance();
        }
    }

    fn lexName(self: *LarkLexer) LarkToken {
        const location = self.currentLocation();
        const start = self.position;
        if (self.source[self.position] == '!' or self.source[self.position] == '?') {
            self.advance();
        }
        while (self.position < self.source.len) {
            const c = self.source[self.position];
            if (!isAsciiAlphanumeric(c) and c != '_' and c != '-') break;
            self.advance();
        }
        return .{ .ty = .Name, .text = self.slice(start, self.position), .flags = "", .location = location };
    }

    fn advanceDigits(self: *LarkLexer) void {
        while (isAsciiDigit(self.peekChar(0))) {
            self.advance();
        }
    }

    fn lexNumber(self: *LarkLexer) LarkToken {
        const location = self.currentLocation();
        const start = self.position;
        if (self.source[self.position] == '+' or self.source[self.position] == '-') {
            self.advance();
        }
        self.advanceDigits();
        if (self.peekChar(0) == '.' and self.peekChar(1) != '.') {
            self.advance();
            self.advanceDigits();
        }
        if (self.peekChar(0) == 'e' or self.peekChar(0) == 'E') {
            self.advance();
            if (self.peekChar(0) == '+' or self.peekChar(0) == '-') {
                self.advance();
            }
            self.advanceDigits();
        }
        return .{ .ty = .Number, .text = self.slice(start, self.position), .flags = "", .location = location };
    }

    fn lexString(self: *LarkLexer) LarkError!LarkToken {
        const location = self.currentLocation();
        const start = self.position;
        self.advance();
        var escaped = false;
        while (self.position < self.source.len) {
            const c = self.source[self.position];
            if (!escaped and c == '"') {
                self.advance();
                if (self.peekChar(0) == 'i') {
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

    fn lexRegex(self: *LarkLexer) LarkError!LarkToken {
        const location = self.currentLocation();
        self.advance();
        const pattern_start = self.position;
        var escaped = false;
        while (self.position < self.source.len) {
            const c = self.source[self.position];
            if (!escaped and c == '/') {
                const pattern = self.slice(pattern_start, self.position);
                self.advance();
                const flags_start = self.position;
                while (isAsciiAlphabetic(self.peekChar(0))) {
                    self.advance();
                }
                return .{
                    .ty = .Regex,
                    .text = pattern,
                    .flags = self.slice(flags_start, self.position),
                    .location = location,
                };
            }
            escaped = !escaped and c == '\\';
            self.advance();
        }
        return self.err(location, "unterminated regular expression");
    }

    fn lexSpecialToken(self: *LarkLexer) LarkError!LarkToken {
        const location = self.currentLocation();
        const start = self.position;
        self.advance();
        while (self.position < self.source.len and self.source[self.position] != '>') {
            const c = self.source[self.position];
            if (isCSpace(c) or c == '<') {
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

    fn lexGrammarRef(self: *LarkLexer) LarkError!LarkToken {
        const location = self.currentLocation();
        const start = self.position;
        self.advance();
        while (isAsciiAlphanumeric(self.peekChar(0)) or self.peekChar(0) == '_' or self.peekChar(0) == '-') {
            self.advance();
        }
        if (self.position == start + 1) {
            return self.err(location, "empty grammar reference");
        }
        return .{ .ty = .GrammarRef, .text = self.slice(start, self.position), .flags = "", .location = location };
    }

    fn lexDirective(self: *LarkLexer) LarkError!LarkToken {
        const location = self.currentLocation();
        const start = self.position;
        self.advance();
        while (isAsciiAlphabetic(self.peekChar(0)) or self.peekChar(0) == '_') {
            self.advance();
        }
        const directive = self.slice(start, self.position);
        const ty: LarkTokenType = if (std.mem.eql(u8, directive, "%json"))
            return self.lexJsonValue(.Json, location, directive)
        else if (std.mem.eql(u8, directive, "%regex"))
            return self.lexJsonValue(.RegexExt, location, directive)
        else if (std.mem.eql(u8, directive, "%grammar_options"))
            return self.lexJsonValue(.GrammarOptions, location, directive)
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

    /// Parses one JSON value from the remaining source and re-serializes it with object
    /// keys in sorted order (`BTreeMap` parity).
    fn lexJsonValue(self: *LarkLexer, ty: LarkTokenType, location: LarkLocation, directive: []const u8) LarkError!LarkToken {
        while (self.position < self.source.len and isCSpace(self.source[self.position])) {
            self.advance();
        }
        const rest = self.source[@min(self.position, self.source.len)..];
        const end = (try jsonValueEnd(self.gpa, rest)) orelse {
            return self.errFmt(location, "failed to parse JSON value after {s}: EOF while parsing a value", .{directive});
        };
        const value = support.parseJson(self.arena, rest[0..end]) catch |parse_error| switch (parse_error) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.errFmt(
                location,
                "failed to parse JSON value after {s}: {s}",
                .{ directive, @errorName(parse_error) },
            ),
        };
        self.advanceTo(self.position + end);
        const text = try serializeJsonValueSorted(self.arena, value);
        return .{ .ty = ty, .text = text, .flags = "", .location = location };
    }
};

/// Whether `byte` is whitespace in the C locale (`std::isspace`).
pub fn isCSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == 0x0B or byte == 0x0C or byte == '\r';
}

fn nextIsDigit(next: u8) bool {
    return isAsciiDigit(next);
}

fn nextIsAlphaOrUnderscore(next: u8) bool {
    return isAsciiAlphabetic(next) or next == '_';
}

fn isAsciiAlphabetic(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isAsciiDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isAsciiAlphanumeric(c: u8) bool {
    return isAsciiAlphabetic(c) or isAsciiDigit(c);
}

fn sliceCodepoint(bytes: []const u8) ![]const u8 {
    const len = try std.unicode.utf8ByteSequenceLength(bytes[0]);
    if (len > bytes.len) return error.InvalidUtf8;
    _ = try std.unicode.utf8Decode(bytes[0..len]);
    return bytes[0..len];
}

/// The byte offset just past the first JSON value in `rest`, or null when none parses.
fn jsonValueEnd(allocator: Allocator, rest: []const u8) Allocator.Error!?usize {
    var scanner = std.json.Scanner.initCompleteInput(allocator, rest);
    defer scanner.deinit();
    var depth: usize = 0;
    while (true) {
        const token = scanner.next() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
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

/// Compact JSON serialization with object keys in sorted order.
pub fn serializeJsonValueSorted(allocator: Allocator, value: std.json.Value) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    writeJsonValueSorted(&aw.writer, allocator, value) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeJsonValueSorted(
    writer: *std.Io.Writer,
    allocator: Allocator,
    value: std.json.Value,
) (Allocator.Error || std.Io.Writer.Error)!void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |i| try writer.print("{d}", .{i}),
        .float => |f| try writer.print("{d}", .{f}),
        .number_string => |s| try writer.writeAll(s),
        .string => |s| try writeJsonString(writer, s),
        .array => |array| {
            try writer.writeByte('[');
            for (array.items, 0..) |item, i| {
                if (i != 0) try writer.writeByte(',');
                try writeJsonValueSorted(writer, allocator, item);
            }
            try writer.writeByte(']');
        },
        .object => |object| {
            var keys: std.ArrayList([]const u8) = .empty;
            defer keys.deinit(allocator);
            var it = object.iterator();
            while (it.next()) |entry| try keys.append(allocator, entry.key_ptr.*);
            std.mem.sort([]const u8, keys.items, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lessThan);
            try writer.writeByte('{');
            for (keys.items, 0..) |key, i| {
                if (i != 0) try writer.writeByte(',');
                try writeJsonString(writer, key);
                try writer.writeByte(':');
                try writeJsonValueSorted(writer, allocator, object.get(key).?);
            }
            try writer.writeByte('}');
        },
    }
}

fn writeJsonString(writer: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x08 => try writer.writeAll("\\b"),
            0x0C => try writer.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

test "LarkLexer tokenizes directives, JSON sorting, and reports located errors with zero leaks" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();

    var diag: Diagnostic = .{};
    defer diag.deinit(a);

    var lexer = LarkLexer{
        .gpa = a,
        .diag = &diag,
        .arena = arena_state.allocator(),
        .source = "start: %json {\"b\": 1, \"a\": [true, \"\\u0001\"]} /abc/iu\n",
    };
    const tokens = try lexer.tokenize();
    try std.testing.expectEqual(LarkTokenType.Name, tokens.items[0].ty);
    try std.testing.expectEqual(LarkTokenType.Colon, tokens.items[1].ty);
    try std.testing.expectEqual(LarkTokenType.Json, tokens.items[2].ty);
    try std.testing.expectEqualStrings("{\"a\":[true,\"\\u0001\"],\"b\":1}", tokens.items[2].text);
    try std.testing.expectEqual(LarkTokenType.Regex, tokens.items[3].ty);
    try std.testing.expectEqualStrings("abc", tokens.items[3].text);
    try std.testing.expectEqualStrings("iu", tokens.items[3].flags);
    try std.testing.expectEqual(LarkTokenType.End, tokens.items[5].ty);

    // Unterminated string produces located diagnostic cleanly.
    var bad_lexer = LarkLexer{
        .gpa = a,
        .diag = &diag,
        .arena = arena_state.allocator(),
        .source = "start: \"unterminated",
    };
    try std.testing.expectError(error.Lark, bad_lexer.tokenize());
    const msg = try diag.formatAlloc(a);
    defer a.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "line 1, column 8: unterminated string literal") != null);
}
