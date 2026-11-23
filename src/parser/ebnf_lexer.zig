//! The EBNF lexer (`ebnf_lexer.rs`).
//!
//! Token strings are duplicated with the caller's allocator; on failure the partial token
//! list is freed before the error surfaces (Rust frees via `Drop`). `input` must be valid
//! UTF-8 (Rust's `&str` guarantees it; invalid bytes are copied verbatim instead of replaced
//! with `U+FFFD` as `String::from_utf8_lossy` would).

const std = @import("std");

const lexer_error = @import("lexer_error.zig");
const rule_attributes = @import("rule_attributes.zig");
const token_mod = @import("token.zig");
const token_type = @import("token_type.zig");
const support = @import("../support/mod.zig");
const grammar = @import("../grammar/mod.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const LexerError = lexer_error.LexerError;
const LexerFailure = lexer_error.LexerFailure;
const RuleAttributes = rule_attributes.RuleAttributes;
const SuffixStopInfo = grammar.SuffixStopInfo;
const Token = token_mod.Token;
const TokenValue = token_mod.TokenValue;
const TokenType = token_type.TokenType;

/// Largest integer literal permitted in a grammar (`1e15`).
const MAX_INTEGER_IN_GRAMMAR: i64 = 1_000_000_000_000_000;

/// Escapes recognized inside a character class (each maps to itself), e.g. `\.`, `\-`, `\*`.
const REGEX_ESCAPE_CHARS = [_]support.encoding.ByteEscape{
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

fn is_regex_special_escape(c: u8) bool {
    return c == 'd' or c == 'D' or c == 's' or c == 'S' or c == 'w' or c == 'W';
}

/// Result of one lexer step: a single token or several (a character class).
const Next = union(enum) {
    one: Token,
    many: ArrayList(Token),
};

/// Tokenizes an EBNF grammar string.
///
/// On `error.Lexer` the diagnostic (with source position) is written into `diag` when
/// present; the message is allocated with `gpa` and freed by the caller.
pub fn tokenize(
    gpa: Allocator,
    input: []const u8,
    diag: ?*LexerError,
) (Allocator.Error || LexerFailure)!ArrayList(Token) {
    var lexer = Lexer.new(gpa, input, diag);
    errdefer lexer.deinit_tokens();
    return lexer.run();
}

const Lexer = struct {
    gpa: Allocator,
    diag: ?*LexerError,
    input: []const u8,
    pos: usize,
    line: i32,
    column: i32,
    tokens: ArrayList(Token) = .empty,

    fn new(gpa: Allocator, input: []const u8, diag: ?*LexerError) Lexer {
        return .{ .gpa = gpa, .diag = diag, .input = input, .pos = 0, .line = 1, .column = 1 };
    }

    fn deinit_tokens(self: *Lexer) void {
        token_mod.free_tokens(self.gpa, self.tokens.items);
        self.tokens.deinit(self.gpa);
    }

    fn push_token(self: *Lexer, token: Token) Allocator.Error!void {
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

    /// Writes the diagnostic and yields `error.Lexer`.
    fn fail(self: *Lexer, message: []const u8) LexerFailure {
        if (self.diag) |d| {
            d.* = .{
                .line = self.line,
                .column = self.column,
                .message = self.gpa.dupe(u8, message) catch "",
            };
        }
        return error.Lexer;
    }

    fn char_fail(self: *Lexer, e: support.encoding.CharHandlingError) LexerFailure {
        return self.fail(switch (e) {
            error.InvalidUtf8 => "Invalid UTF8 sequence",
            error.InvalidEscape => "Invalid escape sequence",
            error.InvalidLatin1 => "Invalid Latin-1 sequence",
        });
    }

    fn slice_string(self: *const Lexer, start: usize, end: usize) Allocator.Error![]u8 {
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

    fn consume_space(self: *Lexer) void {
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

    fn is_name_char(c: u8, is_first: bool) bool {
        return c == '_' or c == '-' or c == '.' or
            (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (!is_first and c >= '0' and c <= '9');
    }

    fn parse_identifier(self: *Lexer) (Allocator.Error || LexerFailure)![]u8 {
        const start = self.pos;
        var first = true;
        while (self.cur() != 0 and is_name_char(self.cur(), first)) {
            self.consume(1);
            first = false;
        }
        if (self.pos == start) return self.fail("Expect identifier");
        return self.slice_string(start, self.pos);
    }

    fn parse_identifier_or_boolean(self: *Lexer) (Allocator.Error || LexerFailure)!Token {
        const line = self.line;
        const column = self.column;
        const id = try self.parse_identifier();
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
        const attrs = try self.parse_rule_attributes(id, line, column);
        return .{
            .ty = .Identifier,
            .lexeme = try self.gpa.dupe(u8, id),
            .value = .{ .Str = try self.gpa.dupe(u8, id) },
            .line = line,
            .column = column,
            .rule_attributes = attrs,
        };
    }

    /// Parses the attribute block of a rule definition, e.g. `name[max_tokens=10] ::= ...`,
    /// `name[capture="x"]`, `name[lazy]`, `name[temperature=0.7]`, or a comma-separated
    /// combination. The bracket group is treated as an attribute block only when it is followed
    /// by `::=`; otherwise it is left to be lexed as a character class.
    fn parse_rule_attributes(
        self: *Lexer,
        identifier: []const u8,
        line: i32,
        column: i32,
    ) (Allocator.Error || LexerFailure)!?RuleAttributes {
        if (self.cur() != '[') return null;
        var delta: isize = 1;

        const skip_space = struct {
            fn f(lexer: *const Lexer, d: *isize) void {
                while (lexer.peek(d.*) == ' ' or lexer.peek(d.*) == '\t') {
                    d.* += 1;
                }
            }
        }.f;
        const match_keyword = struct {
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
        const parse_integer_value = struct {
            fn f(lexer: *const Lexer, d: *isize, value: *i64) bool {
                skip_space(lexer, d);
                if (lexer.peek(d.*) != '=') return false;
                d.* += 1;
                skip_space(lexer, d);
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
        const parse_string_value = struct {
            fn f(lexer: *Lexer, d: *isize, value: *ArrayList(u8)) Allocator.Error!bool {
                skip_space(lexer, d);
                if (lexer.peek(d.*) != '=') return false;
                d.* += 1;
                skip_space(lexer, d);
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
        const parse_float_value = struct {
            fn f(lexer: *const Lexer, d: *isize, value: *f64) bool {
                skip_space(lexer, d);
                if (lexer.peek(d.*) != '=') return false;
                d.* += 1;
                skip_space(lexer, d);
                var text: ArrayList(u8) = .empty;
                defer text.deinit(lexer.gpa);
                while (true) {
                    const c = lexer.peek(d.*);
                    const ok = (c >= '0' and c <= '9') or c == '.' or c == 'e' or c == 'E' or c == '+' or c == '-';
                    if (!ok) break;
                    text.append(lexer.gpa, c) catch return false;
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
        errdefer capture_value.deinit(self.gpa);
        var stop_capture_value: ArrayList(u8) = .empty;
        errdefer stop_capture_value.deinit(self.gpa);
        // Parse a comma-separated attribute list. Each attribute may appear at most once.
        while (matched) {
            skip_space(self, &delta);
            if (!has_max_tokens and match_keyword(self, &delta, "max_tokens")) {
                has_max_tokens = true;
                matched = parse_integer_value(self, &delta, &max_tokens);
            } else if (!has_max_chars and match_keyword(self, &delta, "max_chars")) {
                has_max_chars = true;
                matched = parse_integer_value(self, &delta, &max_chars);
            } else if (!has_suffix_bytes and match_keyword(self, &delta, "capture_hidden_suffix_bytes")) {
                has_suffix_bytes = true;
                matched = parse_integer_value(self, &delta, &suffix_bytes);
            } else if (!has_stop_bytes and match_keyword(self, &delta, "capture_hidden_stop_bytes")) {
                has_stop_bytes = true;
                matched = parse_integer_value(self, &delta, &stop_bytes);
            } else if (!has_body_rule_id and match_keyword(self, &delta, "capture_hidden_body_rule_id")) {
                has_body_rule_id = true;
                matched = parse_integer_value(self, &delta, &body_rule_id);
            } else if (!has_marker_rule_id and match_keyword(self, &delta, "capture_hidden_marker_rule_id")) {
                has_marker_rule_id = true;
                matched = parse_integer_value(self, &delta, &marker_rule_id);
            } else if (!has_stop_capture and match_keyword(self, &delta, "stop_capture")) {
                has_stop_capture = true;
                matched = try parse_string_value(self, &delta, &stop_capture_value);
            } else if (!has_capture and match_keyword(self, &delta, "capture")) {
                has_capture = true;
                skip_space(self, &delta);
                if (self.peek(delta) == '=') {
                    matched = try parse_string_value(self, &delta, &capture_value);
                } else {
                    capture_value.clearRetainingCapacity();
                    try capture_value.appendSlice(self.gpa, identifier);
                }
            } else if (!has_lazy and match_keyword(self, &delta, "lazy")) {
                has_lazy = true;
            } else if (!has_temperature and match_keyword(self, &delta, "temperature")) {
                has_temperature = true;
                matched = parse_float_value(self, &delta, &temperature);
            } else {
                matched = false;
            }
            if (!matched) break;
            skip_space(self, &delta);
            if (self.peek(delta) == ',') {
                delta += 1;
                continue;
            }
            break;
        }
        if (matched) {
            skip_space(self, &delta);
            matched = self.peek(delta) == ']';
            delta += 1;
        }
        if (matched) {
            var after_bracket = delta;
            skip_space(self, &after_bracket);
            matched = self.peek(after_bracket) == ':' and
                self.peek(after_bracket + 1) == ':' and
                self.peek(after_bracket + 2) == '=';
        }
        if (!matched) return null;

        const error_at = struct {
            fn f(lexer: *Lexer, l: i32, c: i32, msg: []const u8) LexerFailure {
                if (lexer.diag) |d| {
                    d.* = .{ .line = l, .column = c, .message = lexer.gpa.dupe(u8, msg) catch "" };
                }
                return error.Lexer;
            }
        }.f;
        if (has_capture and capture_value.items.len == 0)
            return error_at(self, line, column, "The capture name must not be empty");
        if (has_stop_capture and stop_capture_value.items.len == 0)
            return error_at(self, line, column, "The stop capture name must not be empty");
        if (has_body_rule_id != has_marker_rule_id)
            return error_at(self, line, column, "The capture-hidden body and marker rule ids must be specified together");
        if ((has_suffix_bytes and suffix_bytes <= 0) or (has_stop_bytes and stop_bytes <= 0))
            return error_at(self, line, column, "The number of capture-hidden bytes must be positive");
        if (has_max_chars and max_chars < 0)
            return error_at(self, line, column, "The max_chars rule attribute must be non-negative");
        const max_i32: i64 = std.math.maxInt(i32);
        const oversized = [_]bool{ has_max_chars and max_chars > max_i32, has_suffix_bytes and suffix_bytes > max_i32, has_stop_bytes and stop_bytes > max_i32, has_body_rule_id and body_rule_id > max_i32, has_marker_rule_id and marker_rule_id > max_i32 };
        for (oversized) |over| {
            if (over) return error_at(self, line, column, "The rule attribute value is too large");
        }
        const f32_max: f64 = std.math.floatMax(f32);
        if (has_temperature and !(std.math.isFinite(temperature) and temperature >= 0.0 and temperature <= f32_max))
            return error_at(self, line, column, "The temperature must be a finite non-negative number");

        self.consume(@intCast(delta));
        const capture_name = try self.gpa.dupe(u8, capture_value.items);
        errdefer self.gpa.free(capture_name);
        const stop_capture_name = try self.gpa.dupe(u8, stop_capture_value.items);
        errdefer self.gpa.free(stop_capture_name);
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

    fn parse_string(self: *Lexer) (Allocator.Error || LexerFailure)!Token {
        const line = self.line;
        const column = self.column;
        const start_pos = self.pos;
        self.consume(1); // opening quote

        var bytes: ArrayList(u8) = .empty;
        defer bytes.deinit(self.gpa);
        while (self.cur() != 0 and self.cur() != '"' and self.cur() != '\n' and self.cur() != '\r') {
            const decoded = support.encoding.parse_next_utf8_or_escaped(self.input[self.pos..], &.{}) catch |e|
                return self.char_fail(e);
            self.consume(decoded.consumed);
            const encoded = try support.encoding.char_to_utf8_bytes(self.gpa, decoded.codepoint);
            defer self.gpa.free(encoded);
            try bytes.appendSlice(self.gpa, encoded);
        }
        if (self.cur() != '"') return self.fail("Expect \" in string literal");
        self.consume(1); // closing quote

        return .{
            .ty = .StringLiteral,
            .lexeme = try self.slice_string(start_pos, self.pos),
            .value = .{ .Str = try self.gpa.dupe(u8, bytes.items) },
            .line = line,
            .column = column,
            .rule_attributes = null,
        };
    }

    fn parse_char_class(self: *Lexer) (Allocator.Error || LexerFailure)!void {
        try self.push_token(try self.punct(.LBracket, "[", self.line, self.column));
        self.consume(1); // '['

        if (self.cur() == '^') {
            try self.push_token(try self.punct(.Caret, "^", self.line, self.column));
            self.consume(1);
        }

        while (self.cur() != 0 and self.cur() != ']') {
            if (self.cur() == '\r' or self.cur() == '\n') {
                return self.fail("Character class should not contain newline");
            } else if (self.cur() == '-') {
                try self.push_token(try self.punct(.Dash, "-", self.line, self.column));
                self.consume(1);
            } else if (self.cur() == '\\' and is_regex_special_escape(self.peek(1))) {
                const line = self.line;
                const column = self.column;
                const lexeme = try self.slice_string(self.pos, self.pos + 2);
                errdefer self.gpa.free(lexeme);
                const value = try self.slice_string(self.pos + 1, self.pos + 2);
                errdefer self.gpa.free(value);
                try self.push_token(.{
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
                const decoded = support.encoding.parse_next_utf8_or_escaped(self.input[self.pos..], &REGEX_ESCAPE_CHARS) catch |e|
                    return self.char_fail(e);
                const lexeme = try self.slice_string(self.pos, self.pos + decoded.consumed);
                errdefer self.gpa.free(lexeme);
                try self.push_token(.{
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
        try self.push_token(try self.punct(.RBracket, "]", self.line, self.column));
        self.consume(1); // ']'
    }

    fn parse_integer(self: *Lexer) (Allocator.Error || LexerFailure)!Token {
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
                const msg = try std.fmt.allocPrint(self.gpa, "Integer is too large: parsed {d}, max allowed is {d}", .{ num, MAX_INTEGER_IN_GRAMMAR });
                defer self.gpa.free(msg);
                return self.fail(msg);
            }
        }

        return .{
            .ty = .IntegerLiteral,
            .lexeme = try self.slice_string(start_pos, self.pos),
            .value = .{ .Int = if (is_negative) -num else num },
            .line = line,
            .column = column,
            .rule_attributes = null,
        };
    }

    fn next_token(self: *Lexer) (Allocator.Error || LexerFailure)!Next {
        self.consume_space();
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
            '"' => return .{ .one = try self.parse_string() },
            '[' => {
                var many: ArrayList(Token) = .empty;
                errdefer {
                    token_mod.free_tokens(self.gpa, many.items);
                    many.deinit(self.gpa);
                }
                try self.parse_char_class_into(&many);
                return .{ .many = many };
            },
            else => |c| {
                if (is_name_char(c, true)) {
                    // Note: `-` is a name char, so negatives like `-1` lex as identifiers here.
                    return .{ .one = try self.parse_identifier_or_boolean() };
                } else if (std.ascii.isDigit(c) or c == '+') {
                    return .{ .one = try self.parse_integer() };
                } else {
                    const msg = try std.fmt.allocPrint(self.gpa, "Unexpected character: {c}", .{c});
                    defer self.gpa.free(msg);
                    return self.fail(msg);
                }
            },
        }
    }

    /// Character-class variant of `parse_char_class` collecting into the caller's list
    /// (Rust returns `Vec<Token>` from `next_token`'s `Next::Many`).
    fn parse_char_class_into(self: *Lexer, tokens: *ArrayList(Token)) (Allocator.Error || LexerFailure)!void {
        const saved = self.tokens;
        self.tokens = tokens.*;
        defer {
            tokens.* = self.tokens;
            self.tokens = saved;
        }
        return self.parse_char_class();
    }

    /// Promotes each identifier immediately left of `::=` to a `TokenType.RuleName`.
    fn convert_identifier_to_rule_name(self: *Lexer, tokens: []Token) (Allocator.Error || LexerFailure)!void {
        for (tokens, 0..) |*token, i| {
            if (token.ty != .Assign) continue;
            if (i == 0) {
                if (self.diag) |d| d.* = .{
                    .line = token.line,
                    .column = token.column,
                    .message = try self.gpa.dupe(u8, "Assign should not be the first token"),
                };
                return error.Lexer;
            }
            const prev = tokens[i - 1];
            if (prev.ty != .Identifier) {
                if (self.diag) |d| d.* = .{
                    .line = prev.line,
                    .column = prev.column,
                    .message = try self.gpa.dupe(u8, "Assign should be preceded by an identifier"),
                };
                return error.Lexer;
            }
            if (i >= 2 and tokens[i - 2].line == prev.line) {
                if (self.diag) |d| d.* = .{
                    .line = prev.line,
                    .column = prev.column,
                    .message = try self.gpa.dupe(u8, "The rule name should be at the beginning of the line"),
                };
                return error.Lexer;
            }
            tokens[i - 1].ty = .RuleName;
        }
    }

    fn run(self: *Lexer) (Allocator.Error || LexerFailure)!ArrayList(Token) {
        while (true) {
            var next = try self.next_token();
            switch (next) {
                .one => |token| {
                    const is_eof = token.ty == .EndOfFile;
                    try self.push_token(token);
                    if (is_eof) break;
                },
                .many => |*many| {
                    defer many.deinit(self.gpa);
                    try self.tokens.appendSlice(self.gpa, many.items);
                },
            }
        }
        try self.convert_identifier_to_rule_name(self.tokens.items);
        return self.tokens;
    }
};
