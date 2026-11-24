//! EBNF lexer, token definitions, and `LexerError` / `Diagnostic` reporting.
//!
//! Token strings are duplicated with the caller's allocator; on failure the partial token
//! list is freed before the error surfaces. `input` must be valid UTF-8 (invalid bytes
//! are copied verbatim instead of replaced with `U+FFFD`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const Diagnostic = @import("../Diagnostic.zig").Diagnostic;
const support = @import("../support.zig");
const encoding = support.encoding;
const RuleAttributes = @import("ebnf_parser.zig").RuleAttributes;

/// The kind of a lexical token produced by the EBNF lexer.
pub const TokenType = enum {
    /// The name of a rule definition (the identifier left of `::=`).
    RuleName,
    /// A reference to a rule or a macro name.
    Identifier,
    /// A `"..."` string literal.
    StringLiteral,
    /// `true` or `false`.
    BooleanLiteral,
    /// An integer literal.
    IntegerLiteral,
    /// `(`
    LParen,
    /// `)`
    RParen,
    /// `{`
    LBrace,
    /// `}`
    RBrace,
    /// `|`
    Pipe,
    /// `,`
    Comma,
    /// End of input.
    EndOfFile,
    /// `::=`
    Assign,
    /// `=`
    Equal,
    /// `*`
    Star,
    /// `+`
    Plus,
    /// `?`
    Question,
    /// `[`
    LBracket,
    /// `]`
    RBracket,
    /// `-`
    Dash,
    /// `^`
    Caret,
    /// A literal character inside a character class (possibly an escaped non-special char).
    CharInCharClass,
    /// A special escape inside a character class, e.g. `\S`, `\d`.
    EscapeInCharClass,
    /// `(=` — the start of a lookahead assertion.
    LookaheadLParen,
};

/// The processed payload attached to a token.
pub const TokenValue = union(enum) {
    /// No payload (punctuation, EOF, …).
    None,
    /// An integer literal value.
    Int: i64,
    /// A boolean literal value.
    Bool: bool,
    /// A decoded string: the value of a string literal, or an identifier's text.
    Str: []const u8,
    /// A codepoint, for a literal character in a character class.
    Codepoint: i32,

    /// The integer value, if this is `Int`.
    pub fn asInt(self: TokenValue) ?i64 {
        return switch (self) {
            .Int => |v| v,
            else => null,
        };
    }

    /// The boolean value, if this is `Bool`.
    pub fn asBool(self: TokenValue) ?bool {
        return switch (self) {
            .Bool => |v| v,
            else => null,
        };
    }

    /// The string value, if this is `Str`.
    pub fn asStr(self: TokenValue) ?[]const u8 {
        return switch (self) {
            .Str => |s| s,
            else => null,
        };
    }

    /// The codepoint value, if this is `Codepoint`.
    pub fn asCodepoint(self: TokenValue) ?i32 {
        return switch (self) {
            .Codepoint => |c| c,
            else => null,
        };
    }

    /// Value equality for token payloads.
    pub fn eql(a: TokenValue, b: TokenValue) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .None => true,
            .Int => |v| v == b.Int,
            .Bool => |v| v == b.Bool,
            .Str => |s| std.mem.eql(u8, s, b.Str),
            .Codepoint => |c| c == b.Codepoint,
        };
    }
};

/// A single lexical token: its kind, the original source text, a processed value, and the
/// 1-based source position where it began.
pub const Token = struct {
    /// The token kind.
    ty: TokenType,
    /// The original source text of the token.
    lexeme: []const u8,
    /// The processed value.
    value: TokenValue,
    /// 1-based line where the token starts.
    line: i32,
    /// 1-based column where the token starts.
    column: i32,
    /// The attribute block of a rule-definition identifier, e.g. `name[max_tokens=10] ::= ...`.
    rule_attributes: ?RuleAttributes = null,

    /// Structural equality for tests.
    pub fn eql(a: Token, b: Token) bool {
        return a.ty == b.ty and std.mem.eql(u8, a.lexeme, b.lexeme) and
            a.value.eql(b.value) and a.line == b.line and a.column == b.column;
    }
};

/// Releases the heap strings of a single token.
pub fn freeToken(allocator: Allocator, token: Token) void {
    allocator.free(token.lexeme);
    switch (token.value) {
        .Str => |s| allocator.free(s),
        else => {},
    }
    if (token.rule_attributes) |attrs| {
        allocator.free(attrs.capture_name);
        allocator.free(attrs.suffix_stop_info.stop_capture_name);
    }
}

/// Releases the heap strings of a token list produced by `tokenize`.
pub fn freeTokens(allocator: Allocator, tokens: []const Token) void {
    for (tokens) |token| {
        freeToken(allocator, token);
    }
}

/// Error set returned by the EBNF lexer.
pub const LexerError = error{ Lexer, OutOfMemory };

/// Largest integer literal permitted in a grammar (`1e15`).
const MAX_INTEGER_IN_GRAMMAR: i64 = 1_000_000_000_000_000;

/// Escapes recognized inside a character class (each maps to itself), e.g. `\.`, `\-`, `\*`.
const REGEX_ESCAPE_CHARS = [_]encoding.ByteEscape{
    .{ .byte = '^', .codepoint = 0x5E },
    .{ .byte = '$', .codepoint = 0x24 },
    .{ .byte = '\\', .codepoint = 0x5C },
    .{ .byte = '.', .codepoint = 0x2E },
    .{ .byte = '*', .codepoint = 0x2A },
    .{ .byte = '+', .codepoint = 0x2B },
    .{ .byte = '?', .codepoint = 0x3F },
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

fn isRegexSpecialEscape(c: u8) bool {
    return c == 'd' or c == 'D' or c == 's' or c == 'S' or c == 'w' or c == 'W';
}

/// Result of one lexer step: a single token or several (a character class).
const Next = union(enum) {
    one: Token,
    many: ArrayList(Token),
};

/// Tokenizes an EBNF grammar string.
///
/// On `error.Lexer`, populates `diag` (kind `.ebnf_lexer`) with the 1-based line and column
/// when present; any allocated strings inside `diag` are owned by `allocator`.
pub fn tokenize(
    allocator: Allocator,
    input: []const u8,
    diag: ?*Diagnostic,
) LexerError!ArrayList(Token) {
    var lexer = Lexer.init(allocator, input, diag);
    errdefer lexer.deinitTokens();
    return lexer.run();
}

const Lexer = struct {
    gpa: Allocator,
    diag: ?*Diagnostic,
    input: []const u8,
    pos: usize,
    line: i32,
    column: i32,
    tokens: ArrayList(Token) = .empty,

    fn init(gpa: Allocator, input: []const u8, diag: ?*Diagnostic) Lexer {
        return .{ .gpa = gpa, .diag = diag, .input = input, .pos = 0, .line = 1, .column = 1 };
    }

    fn deinitTokens(self: *Lexer) void {
        freeTokens(self.gpa, self.tokens.items);
        self.tokens.deinit(self.gpa);
    }

    fn pushToken(self: *Lexer, token: Token) Allocator.Error!void {
        errdefer freeToken(self.gpa, token);
        try self.tokens.append(self.gpa, token);
    }

    fn peek(self: *const Lexer, delta: isize) u8 {
        const idx = @as(isize, @intCast(self.pos)) + delta;
        if (idx < 0) return 0;
        const index: usize = @intCast(idx);
        if (index >= self.input.len) return 0;
        return self.input[index];
    }

    fn cur(self: *const Lexer) u8 {
        return self.peek(0);
    }

    fn consume(self: *Lexer, cnt: usize) void {
        for (0..cnt) |_| {
            const b = self.cur();
            if (b == '\n' or (b == '\r' and self.peek(1) != '\n')) {
                self.line += 1;
                self.column = 1;
            } else {
                self.column += 1;
            }
            self.pos += 1;
        }
    }

    /// Writes the diagnostic into `diag` (with `.ebnf_lexer`) and yields `error.Lexer` (or `OutOfMemory`).
    fn fail(self: *Lexer, message: []const u8) LexerError {
        return self.failAtFmt(self.line, self.column, "{s}", .{message});
    }

    fn failAtFmt(
        self: *Lexer,
        line: i32,
        column: i32,
        comptime fmt: []const u8,
        args: anytype,
    ) LexerError {
        if (self.diag) |d| {
            try d.setLocatedFmt(
                self.gpa,
                .ebnf_lexer,
                @intCast(@max(line, 0)),
                @intCast(@max(column, 0)),
                "",
                fmt,
                args,
            );
        }
        return error.Lexer;
    }

    fn charFail(self: *Lexer, e: encoding.CharHandlingError) LexerError {
        return self.fail(switch (e) {
            error.InvalidUtf8 => "Invalid UTF8 sequence",
            error.InvalidEscape => "Invalid escape sequence",
            error.InvalidLatin1 => "Invalid Latin-1 sequence",
        });
    }

    fn sliceString(self: *const Lexer, start: usize, end: usize) Allocator.Error![]u8 {
        return self.gpa.dupe(u8, self.input[start..end]);
    }

    fn punct(
        self: *const Lexer,
        ty: TokenType,
        lexeme: []const u8,
        line: i32,
        column: i32,
    ) Allocator.Error!Token {
        return .{
            .ty = ty,
            .lexeme = try self.gpa.dupe(u8, lexeme),
            .value = .None,
            .line = line,
            .column = column,
            .rule_attributes = null,
        };
    }

    fn consumeSpace(self: *Lexer) void {
        while (self.cur() != 0 and (self.cur() == ' ' or self.cur() == '\t' or self.cur() == '#' or self.cur() == '\n' or self.cur() == '\r')) {
            self.consume(1);
            if (self.peek(-1) == '#') {
                while (self.cur() != 0 and self.cur() != '\n' and self.cur() != '\r') {
                    self.consume(1);
                }
                if (self.cur() == 0) return;
                self.consume(1);
                if (self.peek(-1) == '\r' and self.cur() == '\n') {
                    self.consume(1);
                }
            }
        }
    }

    fn isNameChar(c: u8, is_first: bool) bool {
        return c == '_' or c == '-' or c == '.' or
            (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (!is_first and c >= '0' and c <= '9');
    }

    fn parseIdentifier(self: *Lexer) LexerError![]u8 {
        const start = self.pos;
        var first = true;
        while (self.cur() != 0 and isNameChar(self.cur(), first)) {
            self.consume(1);
            first = false;
        }
        if (self.pos == start) return self.fail("Expect identifier");
        return self.sliceString(start, self.pos);
    }

    fn parseIdentifierOrBoolean(self: *Lexer) LexerError!Token {
        const line = self.line;
        const column = self.column;
        const id = try self.parseIdentifier();
        defer self.gpa.free(id);
        if (std.mem.eql(u8, id, "true") or std.mem.eql(u8, id, "false")) {
            const value = std.mem.eql(u8, id, "true");
            return .{
                .ty = .BooleanLiteral,
                .lexeme = try self.gpa.dupe(u8, id),
                .value = .{ .Bool = value },
                .line = line,
                .column = column,
                .rule_attributes = null,
            };
        }
        const attrs = try self.parseRuleAttributes(id, line, column);
        errdefer if (attrs) |a| {
            self.gpa.free(a.capture_name);
            self.gpa.free(a.suffix_stop_info.stop_capture_name);
        };
        const lexeme = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(lexeme);
        const val_str = try self.gpa.dupe(u8, id);
        return .{
            .ty = .Identifier,
            .lexeme = lexeme,
            .value = .{ .Str = val_str },
            .line = line,
            .column = column,
            .rule_attributes = attrs,
        };
    }

    /// Parses the attribute block of a rule definition, e.g. `name[max_tokens=10] ::= ...`,
    /// `name[capture="x"]`, `name[lazy]`, `name[temperature=0.7]`, or a comma-separated
    /// combination. The bracket group is treated as an attribute block only when it is followed
    /// by `::=`; otherwise it is left to be lexed as a character class.
    fn parseRuleAttributes(
        self: *Lexer,
        identifier: []const u8,
        line: i32,
        column: i32,
    ) LexerError!?RuleAttributes {
        if (self.cur() != '[') return null;
        var delta: isize = 1;

        const skipSpace = struct {
            fn f(lexer: *const Lexer, d: *isize) void {
                while (lexer.peek(d.*) == ' ' or lexer.peek(d.*) == '\t') {
                    d.* += 1;
                }
            }
        }.f;
        const matchKeyword = struct {
            fn f(lexer: *const Lexer, d: *isize, keyword: []const u8) bool {
                var matched = true;
                for (keyword, 0..) |b, i| {
                    if (lexer.peek(d.* + @as(isize, @intCast(i))) != b) {
                        matched = false;
                        break;
                    }
                }
                if (matched) d.* += @intCast(keyword.len);
                return matched;
            }
        }.f;
        const parseIntegerValue = struct {
            fn f(lexer: *const Lexer, d: *isize, value: *i64) bool {
                skipSpace(lexer, d);
                if (lexer.peek(d.*) != '=') return false;
                d.* += 1;
                skipSpace(lexer, d);
                value.* = 0;
                var digits: usize = 0;
                while (std.ascii.isDigit(lexer.peek(d.*)) and digits < 10) {
                    value.* = value.* * 10 + @as(i64, lexer.peek(d.*) - '0');
                    d.* += 1;
                    digits += 1;
                }
                return digits > 0 and !std.ascii.isDigit(lexer.peek(d.*));
            }
        }.f;
        const parseStringValue = struct {
            fn f(lexer: *Lexer, d: *isize, value: *ArrayList(u8)) Allocator.Error!bool {
                skipSpace(lexer, d);
                if (lexer.peek(d.*) != '=') return false;
                d.* += 1;
                skipSpace(lexer, d);
                if (lexer.peek(d.*) != '"') return false;
                d.* += 1;
                while (lexer.peek(d.*) != '"') {
                    const c = lexer.peek(d.*);
                    if (c == 0 or c == '\n' or c == '\r' or c == '\\') return false;
                    try value.append(lexer.gpa, c);
                    d.* += 1;
                }
                d.* += 1;
                return true;
            }
        }.f;
        const parseFloatValue = struct {
            fn f(lexer: *const Lexer, d: *isize, value: *f64) Allocator.Error!bool {
                skipSpace(lexer, d);
                if (lexer.peek(d.*) != '=') return false;
                d.* += 1;
                skipSpace(lexer, d);
                var text: ArrayList(u8) = .empty;
                defer text.deinit(lexer.gpa);
                while (true) {
                    const c = lexer.peek(d.*);
                    const ok = (c >= '0' and c <= '9') or c == '.' or c == 'e' or c == 'E' or c == '+' or c == '-';
                    if (!ok) break;
                    try text.append(lexer.gpa, c);
                    d.* += 1;
                }
                // Like std::stod, use the longest prefix that parses as a number.
                var len = text.items.len;
                while (len > 0) : (len -= 1) {
                    if (std.fmt.parseFloat(f64, text.items[0..len])) |parsed| {
                        value.* = parsed;
                        return true;
                    } else |_| {}
                }
                return false;
            }
        }.f;

        var matched = true;
        var has_max_tokens = false;
        var has_max_chars = false;
        var has_capture = false;
        var has_lazy = false;
        var has_temperature = false;
        var has_suffix_bytes = false;
        var has_stop_bytes = false;
        var has_body_rule_id = false;
        var has_marker_rule_id = false;
        var has_stop_capture = false;
        var max_tokens: i64 = -1;
        var max_chars: i64 = -1;
        var suffix_bytes: i64 = 0;
        var stop_bytes: i64 = 0;
        var body_rule_id: i64 = -1;
        var marker_rule_id: i64 = -1;
        var temperature: f64 = 0.0;
        var capture_value: ArrayList(u8) = .empty;
        defer capture_value.deinit(self.gpa);
        var stop_capture_value: ArrayList(u8) = .empty;
        defer stop_capture_value.deinit(self.gpa);

        // Parse a comma-separated attribute list. Each attribute may appear at most once.
        while (matched) {
            skipSpace(self, &delta);
            if (!has_max_tokens and matchKeyword(self, &delta, "max_tokens")) {
                has_max_tokens = true;
                matched = parseIntegerValue(self, &delta, &max_tokens);
            } else if (!has_max_chars and matchKeyword(self, &delta, "max_chars")) {
                has_max_chars = true;
                matched = parseIntegerValue(self, &delta, &max_chars);
            } else if (!has_suffix_bytes and matchKeyword(self, &delta, "capture_hidden_suffix_bytes")) {
                has_suffix_bytes = true;
                matched = parseIntegerValue(self, &delta, &suffix_bytes);
            } else if (!has_stop_bytes and matchKeyword(self, &delta, "capture_hidden_stop_bytes")) {
                has_stop_bytes = true;
                matched = parseIntegerValue(self, &delta, &stop_bytes);
            } else if (!has_body_rule_id and matchKeyword(self, &delta, "capture_hidden_body_rule_id")) {
                has_body_rule_id = true;
                matched = parseIntegerValue(self, &delta, &body_rule_id);
            } else if (!has_marker_rule_id and matchKeyword(self, &delta, "capture_hidden_marker_rule_id")) {
                has_marker_rule_id = true;
                matched = parseIntegerValue(self, &delta, &marker_rule_id);
            } else if (!has_stop_capture and matchKeyword(self, &delta, "stop_capture")) {
                has_stop_capture = true;
                matched = try parseStringValue(self, &delta, &stop_capture_value);
            } else if (!has_capture and matchKeyword(self, &delta, "capture")) {
                has_capture = true;
                skipSpace(self, &delta);
                if (self.peek(delta) == '=') {
                    matched = try parseStringValue(self, &delta, &capture_value);
                } else {
                    capture_value.clearRetainingCapacity();
                    try capture_value.appendSlice(self.gpa, identifier);
                }
            } else if (!has_lazy and matchKeyword(self, &delta, "lazy")) {
                has_lazy = true;
            } else if (!has_temperature and matchKeyword(self, &delta, "temperature")) {
                has_temperature = true;
                matched = try parseFloatValue(self, &delta, &temperature);
            } else {
                matched = false;
            }
            if (!matched) break;
            skipSpace(self, &delta);
            if (self.peek(delta) == ',') {
                delta += 1;
                continue;
            }
            break;
        }
        if (matched) {
            skipSpace(self, &delta);
            matched = self.peek(delta) == ']';
            delta += 1;
        }
        if (matched) {
            var after_bracket = delta;
            skipSpace(self, &after_bracket);
            matched = self.peek(after_bracket) == ':' and
                self.peek(after_bracket + 1) == ':' and
                self.peek(after_bracket + 2) == '=';
        }
        if (!matched) return null;

        if (has_capture and capture_value.items.len == 0)
            return self.failAtFmt(line, column, "The capture name must not be empty", .{});
        if (has_stop_capture and stop_capture_value.items.len == 0)
            return self.failAtFmt(line, column, "The stop capture name must not be empty", .{});
        if (has_body_rule_id != has_marker_rule_id)
            return self.failAtFmt(line, column, "The capture-hidden body and marker rule ids must be specified together", .{});
        if ((has_suffix_bytes and suffix_bytes <= 0) or (has_stop_bytes and stop_bytes <= 0))
            return self.failAtFmt(line, column, "The number of capture-hidden bytes must be positive", .{});
        if (has_max_chars and max_chars < 0)
            return self.failAtFmt(line, column, "The max_chars rule attribute must be non-negative", .{});
        const max_i32: i64 = std.math.maxInt(i32);
        const oversized = [_]bool{
            has_max_tokens and max_tokens > max_i32,
            has_max_chars and max_chars > max_i32,
            has_suffix_bytes and suffix_bytes > max_i32,
            has_stop_bytes and stop_bytes > max_i32,
            has_body_rule_id and body_rule_id > max_i32,
            has_marker_rule_id and marker_rule_id > max_i32,
        };
        for (oversized) |over| {
            if (over) return self.failAtFmt(line, column, "The rule attribute value is too large", .{});
        }
        const f32_max: f64 = std.math.floatMax(f32);
        if (has_temperature and !(std.math.isFinite(temperature) and temperature >= 0.0 and temperature <= f32_max))
            return self.failAtFmt(line, column, "The temperature must be a finite non-negative number", .{});

        self.consume(@intCast(delta));
        const capture_name = try capture_value.toOwnedSlice(self.gpa);
        errdefer self.gpa.free(capture_name);
        const stop_capture_name = try stop_capture_value.toOwnedSlice(self.gpa);
        return RuleAttributes{
            .max_tokens = @intCast(max_tokens),
            .max_chars = @intCast(max_chars),
            .capture_name = capture_name,
            .suffix_stop_info = .{
                .rule_id = -1,
                .hidden_suffix_bytes = @intCast(suffix_bytes),
                .hidden_stop_bytes = @intCast(stop_bytes),
                .body_rule_id = @intCast(body_rule_id),
                .marker_rule_id = @intCast(marker_rule_id),
                .stop_capture_name = stop_capture_name,
            },
            .is_lazy = has_lazy,
            .temperature = if (has_temperature) @floatCast(temperature) else null,
        };
    }

    fn parseString(self: *Lexer) LexerError!Token {
        const line = self.line;
        const column = self.column;
        const start_pos = self.pos;
        self.consume(1); // opening quote

        var bytes: ArrayList(u8) = .empty;
        defer bytes.deinit(self.gpa);
        while (self.cur() != 0 and self.cur() != '"' and self.cur() != '\n' and self.cur() != '\r') {
            const decoded = encoding.parseNextUtf8OrEscaped(self.input[self.pos..], &.{}) catch |e|
                return self.charFail(e);
            self.consume(decoded.consumed);
            const encoded = try encoding.charToUtf8Bytes(self.gpa, decoded.codepoint);
            defer self.gpa.free(encoded);
            try bytes.appendSlice(self.gpa, encoded);
        }
        if (self.cur() != '"') return self.fail("Expect \" in string literal");
        self.consume(1); // closing quote

        const lexeme = try self.sliceString(start_pos, self.pos);
        errdefer self.gpa.free(lexeme);
        const str_val = try bytes.toOwnedSlice(self.gpa);
        return .{
            .ty = .StringLiteral,
            .lexeme = lexeme,
            .value = .{ .Str = str_val },
            .line = line,
            .column = column,
            .rule_attributes = null,
        };
    }

    fn parseCharClass(self: *Lexer) LexerError!void {
        try self.pushToken(try self.punct(.LBracket, "[", self.line, self.column));
        self.consume(1); // '['

        if (self.cur() == '^') {
            try self.pushToken(try self.punct(.Caret, "^", self.line, self.column));
            self.consume(1);
        }

        while (self.cur() != 0 and self.cur() != ']') {
            if (self.cur() == '\r' or self.cur() == '\n') {
                return self.fail("Character class should not contain newline");
            } else if (self.cur() == '-') {
                try self.pushToken(try self.punct(.Dash, "-", self.line, self.column));
                self.consume(1);
            } else if (self.cur() == '\\' and isRegexSpecialEscape(self.peek(1))) {
                const line = self.line;
                const column = self.column;
                try self.tokens.ensureUnusedCapacity(self.gpa, 1);
                const lexeme = try self.sliceString(self.pos, self.pos + 2);
                errdefer self.gpa.free(lexeme);
                const value = try self.sliceString(self.pos + 1, self.pos + 2);
                self.tokens.appendAssumeCapacity(.{
                    .ty = .EscapeInCharClass,
                    .lexeme = lexeme,
                    .value = .{ .Str = value },
                    .line = line,
                    .column = column,
                    .rule_attributes = null,
                });
                self.consume(2);
            } else {
                const line = self.line;
                const column = self.column;
                const decoded = encoding.parseNextUtf8OrEscaped(self.input[self.pos..], &REGEX_ESCAPE_CHARS) catch |e|
                    return self.charFail(e);
                try self.tokens.ensureUnusedCapacity(self.gpa, 1);
                const lexeme = try self.sliceString(self.pos, self.pos + decoded.consumed);
                self.tokens.appendAssumeCapacity(.{
                    .ty = .CharInCharClass,
                    .lexeme = lexeme,
                    .value = .{ .Codepoint = decoded.codepoint },
                    .line = line,
                    .column = column,
                    .rule_attributes = null,
                });
                self.consume(decoded.consumed);
            }
        }

        if (self.cur() == 0) return self.fail("Unterminated character class");
        try self.pushToken(try self.punct(.RBracket, "]", self.line, self.column));
        self.consume(1); // ']'
    }

    fn parseInteger(self: *Lexer) LexerError!Token {
        const line = self.line;
        const column = self.column;
        const start_pos = self.pos;

        var is_negative = false;
        if (self.cur() == '-') {
            is_negative = true;
            self.consume(1);
        } else if (self.cur() == '+') {
            self.consume(1);
        }

        var num: i64 = 0;
        while (self.cur() != 0 and std.ascii.isDigit(self.cur())) {
            num = num * 10 + @as(i64, self.cur() - '0');
            self.consume(1);
            if (num > MAX_INTEGER_IN_GRAMMAR) {
                return self.failAtFmt(
                    self.line,
                    self.column,
                    "Integer is too large: parsed {d}, max allowed is {d}",
                    .{ num, MAX_INTEGER_IN_GRAMMAR },
                );
            }
        }

        return .{
            .ty = .IntegerLiteral,
            .lexeme = try self.sliceString(start_pos, self.pos),
            .value = .{ .Int = if (is_negative) -num else num },
            .line = line,
            .column = column,
            .rule_attributes = null,
        };
    }

    fn nextToken(self: *Lexer) LexerError!Next {
        self.consumeSpace();
        const line = self.line;
        const column = self.column;

        if (self.cur() == 0) {
            return .{ .one = try self.punct(.EndOfFile, "", line, column) };
        }

        switch (self.cur()) {
            '(' => {
                if (self.peek(1) == '=') {
                    self.consume(2);
                    return .{ .one = try self.punct(.LookaheadLParen, "(=", line, column) };
                } else {
                    self.consume(1);
                    return .{ .one = try self.punct(.LParen, "(", line, column) };
                }
            },
            ')' => {
                self.consume(1);
                return .{ .one = try self.punct(.RParen, ")", line, column) };
            },
            '{' => {
                self.consume(1);
                return .{ .one = try self.punct(.LBrace, "{", line, column) };
            },
            '}' => {
                self.consume(1);
                return .{ .one = try self.punct(.RBrace, "}", line, column) };
            },
            '|' => {
                self.consume(1);
                return .{ .one = try self.punct(.Pipe, "|", line, column) };
            },
            ',' => {
                self.consume(1);
                return .{ .one = try self.punct(.Comma, ",", line, column) };
            },
            '*' => {
                self.consume(1);
                return .{ .one = try self.punct(.Star, "*", line, column) };
            },
            '+' => {
                self.consume(1);
                return .{ .one = try self.punct(.Plus, "+", line, column) };
            },
            '?' => {
                self.consume(1);
                return .{ .one = try self.punct(.Question, "?", line, column) };
            },
            '=' => {
                self.consume(1);
                return .{ .one = try self.punct(.Equal, "=", line, column) };
            },
            ':' => {
                if (self.peek(1) == ':' and self.peek(2) == '=') {
                    self.consume(3);
                    return .{ .one = try self.punct(.Assign, "::=", line, column) };
                } else {
                    return self.fail("Unexpected character: ':'");
                }
            },
            '"' => return .{ .one = try self.parseString() },
            '[' => {
                var many: ArrayList(Token) = .empty;
                errdefer {
                    freeTokens(self.gpa, many.items);
                    many.deinit(self.gpa);
                }
                try self.parseCharClassInto(&many);
                return .{ .many = many };
            },
            else => |c| {
                if (isNameChar(c, true)) {
                    // Note: `-` is a name char, so negatives like `-1` lex as identifiers here.
                    return .{ .one = try self.parseIdentifierOrBoolean() };
                } else if (std.ascii.isDigit(c) or c == '+') {
                    return .{ .one = try self.parseInteger() };
                } else {
                    return self.failAtFmt(self.line, self.column, "Unexpected character: {c}", .{c});
                }
            },
        }
    }

    /// Character-class variant of `parseCharClass` collecting into `tokens`.
    fn parseCharClassInto(self: *Lexer, tokens: *ArrayList(Token)) LexerError!void {
        const saved = self.tokens;
        self.tokens = tokens.*;
        defer {
            tokens.* = self.tokens;
            self.tokens = saved;
        }
        return self.parseCharClass();
    }

    /// Promotes each identifier immediately left of `::=` to a `TokenType.RuleName`.
    fn convertIdentifierToRuleName(self: *Lexer, tokens: []Token) LexerError!void {
        for (tokens, 0..) |*token, i| {
            if (token.ty != .Assign) continue;
            if (i == 0) {
                return self.failAtFmt(token.line, token.column, "Assign should not be the first token", .{});
            }
            const prev = tokens[i - 1];
            if (prev.ty != .Identifier) {
                return self.failAtFmt(prev.line, prev.column, "Assign should be preceded by an identifier", .{});
            }
            if (i >= 2 and tokens[i - 2].line == prev.line) {
                return self.failAtFmt(prev.line, prev.column, "The rule name should be at the beginning of the line", .{});
            }
            tokens[i - 1].ty = .RuleName;
        }
    }

    fn run(self: *Lexer) LexerError!ArrayList(Token) {
        while (true) {
            var next = try self.nextToken();
            switch (next) {
                .one => |token| {
                    const is_eof = token.ty == .EndOfFile;
                    try self.pushToken(token);
                    if (is_eof) break;
                },
                .many => |*many| {
                    errdefer {
                        freeTokens(self.gpa, many.items);
                        many.deinit(self.gpa);
                    }
                    try self.tokens.appendSlice(self.gpa, many.items);
                    many.deinit(self.gpa);
                },
            }
        }
        try self.convertIdentifierToRuleName(self.tokens.items);
        return self.tokens;
    }
};

test "TokenValue accessors and equality" {
    const int_v: TokenValue = .{ .Int = 42 };
    const bool_v: TokenValue = .{ .Bool = true };
    const str_v: TokenValue = .{ .Str = "abc" };
    const cp_v: TokenValue = .{ .Codepoint = 'A' };
    try std.testing.expectEqual(@as(?i64, 42), int_v.asInt());
    try std.testing.expectEqual(@as(?bool, true), bool_v.asBool());
    try std.testing.expectEqualStrings("abc", str_v.asStr().?);
    try std.testing.expectEqual(@as(?i32, 'A'), cp_v.asCodepoint());
    try std.testing.expect(int_v.asBool() == null);
    try std.testing.expect(int_v.eql(.{ .Int = 42 }));
    try std.testing.expect(!int_v.eql(bool_v));
}

test "ebnf_lexer Diagnostic format and OOM safety" {
    const gpa = std.testing.allocator;
    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);

    try std.testing.expectError(error.Lexer, tokenize(gpa, "root ::= @", &diag));
    try std.testing.expectEqual(Diagnostic.Kind.ebnf_lexer, diag.kind);
    try std.testing.expectEqualStrings("Unexpected character: @", diag.message);
    const formatted = try diag.formatAlloc(gpa);
    defer gpa.free(formatted);
    try std.testing.expectEqualStrings("EBNF lexer error at line 1, column 10: Unexpected character: @", formatted);

    const check_oom = struct {
        fn run(alloc: Allocator) !void {
            var d: Diagnostic = .{};
            defer d.deinit(alloc);
            var tokens = tokenize(alloc, "r[max_tokens=5, capture=\"cap\", temperature=0.5] ::= [a-z] \"ok\" | 123", &d) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Lexer => return,
            };
            freeTokens(alloc, tokens.items);
            tokens.deinit(alloc);
        }
    }.run;
    try std.testing.checkAllAllocationFailures(gpa, check_oom, .{});
}
