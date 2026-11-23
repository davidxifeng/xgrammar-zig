//! The EBNF parser (`ebnf_parser.rs`).
//!
//! Produces the raw (un-normalized) BNF AST, including the four macros (`TagDispatch`,
//! `Token`, `ExcludeToken`, `TokenTagDispatch`).
//!
//! The parser keeps its token strings and macro values in a per-call arena (Rust frees via
//! `Drop`); the built `Grammar` is allocated with the caller's backing allocator and owns
//! itself. The `flags` branch of `Regex(...)` needs the fsm wave's `rewrite_regex_dots`
//! and surfaces `error.NotImplementedInWaveFsm` until it lands.

const std = @import("std");

const ebnf_error = @import("ebnf_error.zig");
const ebnf_lexer = @import("ebnf_lexer.zig");
const lexer_error = @import("lexer_error.zig");
const macro_ir = @import("macro_ir.zig");
const parse_error = @import("parse_error.zig");
const rule_attributes = @import("rule_attributes.zig");
const token_mod = @import("token.zig");
const token_type = @import("token_type.zig");
const grammar = @import("../grammar/mod.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const CharacterClassElement = grammar.CharacterClassElement;
const EbnfError = ebnf_error.EbnfError;
const EbnfErrorInfo = ebnf_error.EbnfErrorInfo;
const Grammar = grammar.Grammar;
const GrammarBuilder = grammar.GrammarBuilder;
const GrammarExprType = grammar.GrammarExprType;
const MacroArguments = macro_ir.MacroArguments;
const MacroValue = macro_ir.MacroValue;
const NO_EXPR = grammar.NO_EXPR;
const ParserError = parse_error.ParserError;
const RuleAttributes = rule_attributes.RuleAttributes;
const TagDispatch = grammar.TagDispatch;
const Token = token_mod.Token;
const TokenTagDispatch = grammar.TokenTagDispatch;
const TokenType = token_type.TokenType;

const MAX_NEST_LAYER: i32 = 1000;

/// Parses an EBNF grammar string into the raw (un-normalized) BNF AST.
///
/// On `EbnfError` the diagnostic is written into `diag` when present (the message text is
/// allocated with `gpa`; the caller frees `info`'s message, see [`ebnf_error.message_of`]).
pub fn ebnf_to_grammar_no_normalization(
    gpa: Allocator,
    ebnf_string: []const u8,
    root_rule_name: []const u8,
    diag: ?*EbnfErrorInfo,
) (Allocator.Error || EbnfError)!*Grammar {
    var arena = ArenaAllocator.init(gpa);
    defer arena.deinit();
    const arena_gpa = arena.allocator();

    var lexer_diag = lexer_error.LexerError{};
    const tokens = ebnf_lexer.tokenize(arena_gpa, ebnf_string, &lexer_diag) catch |e| switch (e) {
        error.Lexer => return ebnf_error.report(diag, .{ .lexer = lexer_diag }),
        error.OutOfMemory => return error.OutOfMemory,
    };

    var builder = try GrammarBuilder.new(gpa);
    errdefer builder.deinit();
    var parser = Parser.new(arena_gpa, gpa, builder, tokens, root_rule_name, diag);
    return parser.parse();
}

const Parser = struct {
    gpa: Allocator,
    /// Backing allocator for the builder and the built grammar (outlives the call).
    builder_backing: Allocator,
    diag: ?*EbnfErrorInfo,
    builder: GrammarBuilder,
    tokens: ArrayList(Token),
    pos: usize,
    cur_rule_name: []const u8,
    root_rule_name: []const u8,
    nest_layer_guard: i32,

    fn new(
        gpa: Allocator,
        builder_backing: Allocator,
        builder: GrammarBuilder,
        tokens: ArrayList(Token),
        root_rule_name: []const u8,
        diag: ?*EbnfErrorInfo,
    ) Parser {
        return .{
            .gpa = gpa,
            .builder_backing = builder_backing,
            .diag = diag,
            .builder = builder,
            .tokens = tokens,
            .pos = 0,
            .cur_rule_name = "",
            .root_rule_name = root_rule_name,
            .nest_layer_guard = 0,
        };
    }

    fn peek(self: *const Parser, delta: isize) *const Token {
        const last: isize = @as(isize, @intCast(self.tokens.items.len)) - 1;
        var idx = @as(isize, @intCast(self.pos)) + delta;
        idx = @max(@min(idx, last), 0);
        return &self.tokens.items[@intCast(idx)];
    }

    fn cur(self: *const Parser) *const Token {
        return self.peek(0);
    }

    fn consume(self: *Parser, cnt: usize) void {
        self.pos += cnt;
    }

    /// Reports a parser error at the current token; `message` is duplicated into the
    /// diagnostic when present.
    fn fail(self: *Parser, message: []const u8) EbnfError {
        return self.fail_at(0, message);
    }

    fn fail_at(self: *Parser, delta: isize, message: []const u8) EbnfError {
        const token = self.peek(delta);
        if (self.diag) |d| {
            d.* = .{ .parser = .{
                .line = token.line,
                .column = token.column,
                .message = self.gpa.dupe(u8, message) catch "",
            } };
        }
        return error.Parser;
    }

    fn fail_print(self: *Parser, comptime fmt: []const u8, args: anytype) EbnfError {
        const message = std.fmt.allocPrint(self.gpa, fmt, args) catch return error.Parser;
        defer self.gpa.free(message);
        return self.fail(message);
    }

    fn fail_at_print(self: *Parser, delta: isize, comptime fmt: []const u8, args: anytype) EbnfError {
        const message = std.fmt.allocPrint(self.gpa, fmt, args) catch return error.Parser;
        defer self.gpa.free(message);
        return self.fail_at(delta, message);
    }

    fn expect(self: *Parser, ty: TokenType, message: []const u8) EbnfError!void {
        if (self.cur().ty != ty) return self.fail(message);
        self.consume(1);
    }

    /// The current token's string payload, or empty. Borrowed; dupe when stored.
    fn cur_str(self: *const Parser) []const u8 {
        return self.cur().value.as_str() orelse "";
    }

    fn parse_identifier(self: *Parser) (Allocator.Error || EbnfError)![]const u8 {
        if (self.cur().ty != .Identifier) return self.fail("Expect identifier");
        const id = self.cur_str();
        self.consume(1);
        return id; // arena-owned; callers dupe when they retain it
    }

    fn parse_char_class(self: *Parser) (Allocator.Error || EbnfError)!i32 {
        try self.expect(.LBracket, "Expect [ in character class");

        var elements: ArrayList(CharacterClassElement) = .empty;
        defer elements.deinit(self.gpa);
        var is_negated = false;
        if (self.cur().ty == .Caret) {
            is_negated = true;
            self.consume(1);
        }

        while (self.cur().ty != .RBracket and self.cur().ty != .EndOfFile) {
            if (self.cur().ty == .EscapeInCharClass) {
                return self.fail("Character class escape is not supported yet in EBNF");
            }
            const lower: i32 = switch (self.cur().ty) {
                .CharInCharClass => self.cur().value.as_codepoint() orelse 0,
                .Dash => @intCast('-'),
                else => return self.fail_print("Unexpected character in character class: {s}", .{self.cur().lexeme}),
            };
            self.consume(1);

            const is_range = self.cur().ty == .Dash and
                (self.peek(1).ty == .CharInCharClass or self.peek(1).ty == .Dash);
            if (is_range) {
                const upper: i32 = switch (self.peek(1).ty) {
                    .CharInCharClass => self.peek(1).value.as_codepoint() orelse 0,
                    else => @intCast('-'),
                };
                if (lower > upper) {
                    return self.fail_at(-1, "Invalid character class: lower bound is larger than upper bound");
                }
                try elements.append(self.gpa, CharacterClassElement.new(lower, upper));
                self.consume(2);
            } else {
                try elements.append(self.gpa, CharacterClassElement.new(lower, lower));
            }
        }

        try self.expect(.RBracket, "Expect ] in character class");
        return self.builder.add_character_class(elements.items, is_negated);
    }

    fn parse_string(self: *Parser) (Allocator.Error || EbnfError)!i32 {
        if (self.cur().ty != .StringLiteral) return self.fail("Expect string literal");
        const value = self.cur_str();
        self.consume(1);
        if (value.len == 0) {
            return self.builder.add_empty_str();
        } else {
            return self.builder.add_byte_string(value);
        }
    }

    fn parse_rule_ref(self: *Parser) (Allocator.Error || EbnfError)!i32 {
        const name = try self.parse_identifier();
        const rule_id = try self.builder.get_rule_id(name);
        if (rule_id == NO_EXPR) {
            return self.fail_at_print(-1, "Rule \"{s}\" is not defined", .{name});
        }
        return self.builder.add_rule_ref(rule_id);
    }

    /// Parses a single macro value: a string, integer, boolean, identifier, or tuple.
    fn parse_macro_value(self: *Parser) (Allocator.Error || EbnfError)!MacroValue {
        switch (self.cur().ty) {
            .StringLiteral => {
                const value = self.cur_str();
                self.consume(1);
                return .{ .Str = value };
            },
            .IntegerLiteral => {
                const value = self.cur().value.as_int() orelse 0;
                self.consume(1);
                return .{ .Int = value };
            },
            .BooleanLiteral => {
                const value = self.cur().value.as_bool() orelse false;
                self.consume(1);
                return .{ .Bool = value };
            },
            .Identifier => {
                const name = self.cur_str();
                self.consume(1);
                return .{ .Identifier = name };
            },
            .LParen => {
                // Nested tuples recurse once per layer, so guard the depth the same way the
                // ordinary parenthesis path does to avoid a stack overflow on deeply nested input.
                self.nest_layer_guard += 1;
                if (self.nest_layer_guard > MAX_NEST_LAYER) {
                    return self.fail_at(-1, "Nest layer exceeded the maximum limit");
                }
                self.consume(1);
                var elements: ArrayList(MacroValue) = .empty;
                errdefer elements.deinit(self.gpa);
                if (self.cur().ty != .RParen) {
                    while (true) {
                        try elements.append(self.gpa, try self.parse_macro_value());
                        if (self.cur().ty == .Comma) {
                            self.consume(1);
                            if (self.cur().ty == .RParen) break;
                        } else if (self.cur().ty == .RParen) {
                            break;
                        } else {
                            return self.fail("Expect , or ) in tuple");
                        }
                    }
                }
                self.consume(1); // Consume )
                self.nest_layer_guard -= 1;
                return .{ .Tuple = elements };
            },
            else => return self.fail("Expect string, integer, boolean, or tuple in macro argument"),
        }
    }

    /// Parses a macro argument list (positional and named arguments).
    fn parse_macro_arguments(self: *Parser) (Allocator.Error || EbnfError)!MacroArguments {
        try self.expect(.LParen, "Expect ( after macro function name");
        var args = MacroArguments{};
        errdefer args.deinit(self.gpa);
        if (self.cur().ty != .RParen) {
            while (true) {
                if (self.cur().ty == .Identifier and self.peek(1).ty == .Equal) {
                    const name = self.cur_str();
                    self.consume(2); // Consume identifier and =
                    const value = try self.parse_macro_value();
                    try args.named.append(self.gpa, .{ .name = name, .value = value });
                } else {
                    try args.positional.append(self.gpa, try self.parse_macro_value());
                }
                if (self.cur().ty == .Comma) {
                    self.consume(1);
                } else if (self.cur().ty == .RParen) {
                    break;
                } else {
                    return self.fail("Expect , or ) in macro arguments");
                }
            }
        }
        try self.expect(.RParen, "Expect ) after macro arguments");
        return args;
    }

    fn parse_tag_dispatch(self: *Parser) (Allocator.Error || EbnfError)!i32 {
        self.consume(1); // Consume TagDispatch operator
        const start = self.pos;
        var args = try self.parse_macro_arguments();
        errdefer args.deinit(self.gpa);
        const delta: isize = @as(isize, @intCast(start)) - @as(isize, @intCast(self.pos));

        for (args.named.items) |named| {
            if (!std.mem.eql(u8, named.name, "loop_after_dispatch") and !std.mem.eql(u8, named.name, "excludes")) {
                return self.fail_at_print(delta, "Unknown named argument for TagDispatch: {s}", .{named.name});
            }
        }

        var tag_rule_pairs: ArrayList(struct { []const u8, i32 }) = .empty;
        defer tag_rule_pairs.deinit(self.gpa);
        for (args.positional.items) |*arg| {
            const elements = switch (arg.*) {
                .Tuple => |*t| t,
                else => return self.fail_at(delta, "Each tag dispatch element must be a tuple"),
            };
            if (elements.items.len != 2) {
                return self.fail_at(delta, "Each tag dispatch element must be a pair (tag, rule)");
            }
            const tag = switch (elements.items[0]) {
                .Str => |s| s,
                else => return self.fail_at(delta, "Tag must be a non-empty string literal"),
            };
            if (tag.len == 0) {
                return self.fail_at(delta, "Tag must be a non-empty string literal");
            }
            const rule_name = switch (elements.items[1]) {
                .Identifier => |s| s,
                else => return self.fail_at(delta, "Rule reference must be an identifier"),
            };
            const rule_id = try self.builder.get_rule_id(rule_name);
            if (rule_id == NO_EXPR) {
                return self.fail_at_print(delta, "Rule \"{s}\" is not defined", .{rule_name});
            }
            try tag_rule_pairs.append(self.gpa, .{ tag, rule_id });
        }

        var loop_after_dispatch = true;
        if (args.named_value("loop_after_dispatch")) |value| {
            loop_after_dispatch = switch (value.*) {
                .Bool => |b| b,
                else => return self.fail_at(delta, "loop_after_dispatch must be a boolean literal"),
            };
        }

        var excludes: ArrayList([]const u8) = .empty;
        defer excludes.deinit(self.gpa);
        if (args.named_value("excludes")) |value| {
            const elements = switch (value.*) {
                .Tuple => |*t| t,
                else => return self.fail_at(delta, "excludes must be a tuple"),
            };
            for (elements.items) |element| {
                const s = switch (element) {
                    .Str => |s| s,
                    else => return self.fail_at(delta, "Exclude must be a non-empty string literal"),
                };
                if (s.len == 0) {
                    return self.fail_at(delta, "Exclude must be a non-empty string literal");
                }
                try excludes.append(self.gpa, s);
            }
        }

        for (excludes.items) |exclude| {
            for (tag_rule_pairs.items) |pair| {
                if (std.mem.startsWith(u8, pair[0], exclude)) {
                    return self.fail_at_print(
                        delta,
                        "Exclude string must not be a prefix of trigger string: {s}",
                        .{exclude},
                    );
                }
            }
        }

        var pairs: ArrayList(grammar.tag_dispatch.TagRulePair) = .empty;
        defer pairs.deinit(self.gpa);
        for (tag_rule_pairs.items) |pair| try pairs.append(self.gpa, .{ .tag = @constCast(pair[0]), .rule_id = pair[1] });
        var exclude_dupe: ArrayList([]u8) = .empty;
        defer exclude_dupe.deinit(self.gpa);
        for (excludes.items) |exclude| try exclude_dupe.append(self.gpa, @constCast(exclude));
        const tag_dispatch = TagDispatch{
            .tag_rule_pairs = pairs,
            .loop_after_dispatch = loop_after_dispatch,
            .excludes = exclude_dupe,
        };
        return self.builder.add_tag_dispatch(&tag_dispatch);
    }

    fn parse_regex_macro(self: *Parser) (Allocator.Error || EbnfError)!i32 {
        self.consume(1); // Consume Regex identifier
        const start = self.pos;
        var args = try self.parse_macro_arguments();
        errdefer args.deinit(self.gpa);
        const delta: isize = @as(isize, @intCast(start)) - @as(isize, @intCast(self.pos));

        if (args.positional.items.len != 1) {
            return self.fail_at(delta, "Regex expects exactly one string argument");
        }
        const pattern_value = switch (args.positional.items[0]) {
            .Str => |s| s,
            else => return self.fail_at(delta, "Regex pattern must be a string literal"),
        };
        for (args.named.items) |named| {
            if (!std.mem.eql(u8, named.name, "json_string") and !std.mem.eql(u8, named.name, "flags")) {
                return self.fail_at_print(delta, "Regex does not support the named argument {s}", .{named.name});
            }
        }
        var json_string = false;
        if (args.named_value("json_string")) |value| {
            json_string = switch (value.*) {
                .Bool => |b| b,
                else => return self.fail_at(delta, "json_string must be a boolean"),
            };
        }
        const pattern = pattern_value;
        if (args.named_value("flags")) |value| {
            const flags = switch (value.*) {
                .Str => |s| s,
                else => return self.fail_at(delta, "flags must be a string"),
            };
            var indices = std.unicode.Utf8View.initUnchecked(flags).iterator();
            while (indices.nextCodepoint()) |flag| {
                switch (flag) {
                    // XGrammar regular expressions use Unicode codepoint semantics by default.
                    'u' => {},
                    else => {
                        // 'i' / 's' need fsm::rewrite_regex_dots（fsm 波未落地）。
                        return self.fail_at_print(
                            delta,
                            "regular-expression flag '{u}' is not supported",
                            .{flag},
                        );
                    },
                }
            }
            // The flags argument opts into the standard dot semantics: '.' does not match '\n'
            // unless the 's' flag is given; case-insensitivity prefixes `(?i)`. Both need
            // fsm::rewrite_regex_dots（fsm 波未落地，参照 ebnf_parser.rs parse_regex_macro 与
            // fsm/rewrite_regex_dots.rs）。
            return error.NotImplementedInWaveFsm;
        }
        return self.builder.add_regex(pattern, json_string);
    }

    fn parse_substring_macro(self: *Parser) (Allocator.Error || EbnfError)!i32 {
        self.consume(1); // Consume Substring identifier
        const start = self.pos;
        var args = try self.parse_macro_arguments();
        errdefer args.deinit(self.gpa);
        const delta: isize = @as(isize, @intCast(start)) - @as(isize, @intCast(self.pos));

        if (args.named.items.len != 0) {
            return self.fail_at(delta, "Substring() does not accept named arguments");
        }
        var chunks: ArrayList([]const u8) = .empty;
        defer chunks.deinit(self.gpa);
        for (args.positional.items) |*arg| {
            switch (arg.*) {
                .Str => |chunk| try chunks.append(self.gpa, chunk),
                else => return self.fail_at(delta, "Substring() arguments must be strings"),
            }
        }
        return self.builder.add_substring(chunks.items);
    }

    fn parse_token_set(self: *Parser) (Allocator.Error || EbnfError)!i32 {
        self.consume(1); // Consume Token identifier
        const start = self.pos;
        var args = try self.parse_macro_arguments();
        errdefer args.deinit(self.gpa);
        const delta: isize = @as(isize, @intCast(start)) - @as(isize, @intCast(self.pos));

        if (args.named.items.len != 0) {
            return self.fail_at(delta, "Token() does not accept named arguments");
        }
        if (args.positional.items.len == 0) {
            return self.fail_at(delta, "Token() requires at least one integer argument");
        }
        var token_ids: ArrayList(i32) = .empty;
        defer token_ids.deinit(self.gpa);
        for (args.positional.items) |*arg| {
            const value = switch (arg.*) {
                .Int => |v| v,
                else => return self.fail_at(delta, "Token() arguments must be non-negative integers"),
            };
            if (value < 0) {
                return self.fail_at(delta, "Token() arguments must be non-negative integers");
            }
            try token_ids.append(self.gpa, @intCast(value));
        }
        std.mem.sort(i32, token_ids.items, {}, std.sort.asc(i32));
        dedup_i32(&token_ids);
        return self.builder.add_token_set(token_ids.items);
    }

    fn parse_exclude_token(self: *Parser) (Allocator.Error || EbnfError)!i32 {
        self.consume(1); // Consume ExcludeToken identifier
        const start = self.pos;
        var args = try self.parse_macro_arguments();
        errdefer args.deinit(self.gpa);
        const delta: isize = @as(isize, @intCast(start)) - @as(isize, @intCast(self.pos));

        if (args.named.items.len != 0) {
            return self.fail_at(delta, "ExcludeToken() does not accept named arguments");
        }
        if (args.positional.items.len == 0) {
            return self.fail_at(delta, "ExcludeToken() requires at least one integer argument");
        }
        var token_ids: ArrayList(i32) = .empty;
        defer token_ids.deinit(self.gpa);
        for (args.positional.items) |*arg| {
            const value = switch (arg.*) {
                .Int => |v| v,
                else => return self.fail_at(delta, "ExcludeToken() arguments must be non-negative integers"),
            };
            if (value < 0) {
                return self.fail_at(delta, "ExcludeToken() arguments must be non-negative integers");
            }
            try token_ids.append(self.gpa, @intCast(value));
        }
        std.mem.sort(i32, token_ids.items, {}, std.sort.asc(i32));
        dedup_i32(&token_ids);
        return self.builder.add_exclude_token_set(token_ids.items);
    }

    fn parse_token_tag_dispatch(self: *Parser) (Allocator.Error || EbnfError)!i32 {
        self.consume(1); // Consume TokenTagDispatch identifier
        const start = self.pos;
        var args = try self.parse_macro_arguments();
        errdefer args.deinit(self.gpa);
        const delta: isize = @as(isize, @intCast(start)) - @as(isize, @intCast(self.pos));

        for (args.named.items) |named| {
            if (!std.mem.eql(u8, named.name, "loop_after_dispatch") and !std.mem.eql(u8, named.name, "excludes")) {
                return self.fail_at_print(delta, "Unknown named argument for TokenTagDispatch: {s}", .{named.name});
            }
        }

        var trigger_rule_pairs: ArrayList(struct { i32, i32 }) = .empty;
        defer trigger_rule_pairs.deinit(self.gpa);
        for (args.positional.items) |*arg| {
            const elements = switch (arg.*) {
                .Tuple => |*t| t,
                else => return self.fail_at(delta, "Each TokenTagDispatch element must be a pair (token_id, rule)"),
            };
            if (elements.items.len != 2) {
                return self.fail_at(delta, "Each TokenTagDispatch element must be a pair (token_id, rule)");
            }
            const token_id = switch (elements.items[0]) {
                .Int => |v| v,
                else => return self.fail_at(delta, "Token trigger ID must be a non-negative integer"),
            };
            if (token_id < 0) {
                return self.fail_at(delta, "Token trigger ID must be a non-negative integer");
            }
            const rule_name = switch (elements.items[1]) {
                .Identifier => |s| s,
                else => return self.fail_at(delta, "Rule reference must be an identifier"),
            };
            const rule_id = try self.builder.get_rule_id(rule_name);
            if (rule_id == NO_EXPR) {
                return self.fail_at_print(delta, "Rule \"{s}\" is not defined", .{rule_name});
            }
            try trigger_rule_pairs.append(self.gpa, .{ @intCast(token_id), rule_id });
        }

        var loop_after_dispatch = true;
        if (args.named_value("loop_after_dispatch")) |value| {
            loop_after_dispatch = switch (value.*) {
                .Bool => |b| b,
                else => return self.fail_at(delta, "loop_after_dispatch must be a boolean"),
            };
        }

        var excludes: ArrayList(i32) = .empty;
        defer excludes.deinit(self.gpa);
        if (args.named_value("excludes")) |value| {
            const elements = switch (value.*) {
                .Tuple => |*t| t,
                else => return self.fail_at(delta, "excludes must be a tuple"),
            };
            for (elements.items) |element| {
                const token_id = switch (element) {
                    .Int => |v| v,
                    else => return self.fail_at(delta, "Exclude token ID must be a non-negative integer"),
                };
                if (token_id < 0) {
                    return self.fail_at(delta, "Exclude token ID must be a non-negative integer");
                }
                try excludes.append(self.gpa, @intCast(token_id));
            }
        }

        for (excludes.items) |exclude_id| {
            for (trigger_rule_pairs.items) |pair| {
                if (pair[0] == exclude_id) {
                    return self.fail_at_print(
                        delta,
                        "Token trigger ID {d} must not overlap with exclude token ID",
                        .{pair[0]},
                    );
                }
            }
        }

        var pairs: ArrayList(grammar.token_tag_dispatch.TriggerRulePair) = .empty;
        defer pairs.deinit(self.gpa);
        for (trigger_rule_pairs.items) |pair| try pairs.append(self.gpa, .{ .token_id = pair[0], .rule_id = pair[1] });
        var ttd = TokenTagDispatch{
            .trigger_rule_pairs = pairs,
            .loop_after_dispatch = loop_after_dispatch,
            .excludes = excludes,
        };
        defer ttd.trigger_rule_pairs.deinit(self.gpa);
        defer ttd.excludes.deinit(self.gpa);
        return self.builder.add_token_tag_dispatch(&ttd);
    }

    fn parse_element(self: *Parser) (Allocator.Error || EbnfError)!i32 {
        switch (self.cur().ty) {
            .LParen => {
                self.nest_layer_guard += 1;
                if (self.nest_layer_guard > MAX_NEST_LAYER) {
                    return self.fail_at(-1, "Nest layer exceeded the maximum limit");
                }
                self.consume(1);
                if (self.cur().ty == .RParen) {
                    self.consume(1);
                    self.nest_layer_guard -= 1;
                    return self.builder.add_empty_str();
                }
                const expr = try self.parse_choices();
                try self.expect(.RParen, "Expect )");
                self.nest_layer_guard -= 1;
                return expr;
            },
            .LBracket => return self.parse_char_class(),
            .StringLiteral => return self.parse_string(),
            .Identifier => {
                const name = self.cur_str();
                if (std.mem.eql(u8, name, "TagDispatch")) {
                    return self.parse_tag_dispatch();
                } else if (std.mem.eql(u8, name, "Token")) {
                    return self.parse_token_set();
                } else if (std.mem.eql(u8, name, "ExcludeToken")) {
                    return self.parse_exclude_token();
                } else if (std.mem.eql(u8, name, "TokenTagDispatch")) {
                    return self.parse_token_tag_dispatch();
                } else if (std.mem.eql(u8, name, "Regex")) {
                    return self.parse_regex_macro();
                } else if (std.mem.eql(u8, name, "Substring")) {
                    return self.parse_substring_macro();
                } else {
                    return self.parse_rule_ref();
                }
            },
            else => return self.fail_print("Expect element, but got {s}", .{self.cur().lexeme}),
        }
    }

    fn parse_integer(self: *Parser) (Allocator.Error || EbnfError)!i64 {
        if (self.cur().ty != .IntegerLiteral) {
            return self.fail_print("Expect integer, but got {s}", .{self.cur().lexeme});
        }
        const num = self.cur().value.as_int() orelse 0;
        self.consume(1);
        return num;
    }

    /// Parses `{m}`, `{m,}`, `{m,n}`, or the printer's `{m, -1}` (unbounded), returning
    /// `(lower, upper)` with `upper == -1` meaning unbounded.
    const RepetitionRange = struct { lower: i64, upper: i64 };

    fn parse_repetition_range(self: *Parser) (Allocator.Error || EbnfError)!RepetitionRange {
        try self.expect(.LBrace, "Expect {");
        const lower = try self.parse_integer();
        if (lower < 0) {
            return self.fail_at(-1, "Lower bound cannot be negative");
        }

        switch (self.cur().ty) {
            .Comma => {
                self.consume(1);
                if (self.cur().ty == .RBrace) {
                    self.consume(1);
                    return .{ .lower = lower, .upper = -1 };
                }
                // The printer emits `{n, -1}` for unbounded upper bounds, and `-` is a
                // name char, so the lexer yields Identifier("-1"). Accept it as `{n,}`.
                if (self.cur().ty == .Identifier and std.mem.eql(u8, self.cur().lexeme, "-1")) {
                    self.consume(1);
                    try self.expect(.RBrace, "Expect }");
                    return .{ .lower = lower, .upper = -1 };
                }
                const upper = try self.parse_integer();
                if (upper < lower) {
                    return self.fail_at_print(-1, "Lower bound is larger than upper bound: {d} > {d}", .{ lower, upper });
                }
                try self.expect(.RBrace, "Expect }");
                return .{ .lower = lower, .upper = upper };
            },
            .RBrace => {
                self.consume(1);
                return .{ .lower = lower, .upper = lower };
            },
            else => return self.fail("Expect ',' or '}' in repetition range"),
        }
    }

    fn handle_star_quantifier(self: *Parser, grammar_expr_id: i32) (Allocator.Error || EbnfError)!i32 {
        // A character-class star has a dedicated expr type: [a-z]*
        {
            const expr = self.builder.grammar_expr(grammar_expr_id);
            if (expr.ty == .CharacterClass) {
                const cc = try expr.character_class(self.gpa);
                defer self.gpa.free(cc.ranges);
                return self.builder.add_character_class_star(cc.ranges, cc.is_negative);
            }
        }
        // Otherwise: a*  -->  rule ::= a rule | ""
        const new_rule_name = try self.builder.get_new_rule_name(self.cur_rule_name);
        const new_rule_id = try self.builder.add_empty_rule(new_rule_name);
        const ref_to_new_rule = try self.builder.add_rule_ref(new_rule_id);
        const empty = try self.builder.add_empty_str();
        const seq = try self.builder.add_sequence(&.{ grammar_expr_id, ref_to_new_rule });
        const body = try self.builder.add_choices(&.{ empty, seq });
        self.builder.update_rule_body(new_rule_id, body);
        return self.builder.add_rule_ref(new_rule_id);
    }

    fn handle_plus_quantifier(self: *Parser, grammar_expr_id: i32) (Allocator.Error || EbnfError)!i32 {
        // a+  -->  rule ::= a rule | a
        const new_rule_name = try self.builder.get_new_rule_name(self.cur_rule_name);
        const new_rule_id = try self.builder.add_empty_rule(new_rule_name);
        const ref_to_new_rule = try self.builder.add_rule_ref(new_rule_id);
        const seq = try self.builder.add_sequence(&.{ grammar_expr_id, ref_to_new_rule });
        const body = try self.builder.add_choices(&.{ seq, grammar_expr_id });
        self.builder.update_rule_body(new_rule_id, body);
        return self.builder.add_rule_ref(new_rule_id);
    }

    fn handle_question_quantifier(self: *Parser, grammar_expr_id: i32) (Allocator.Error || EbnfError)!i32 {
        // a?  -->  rule ::= a | empty
        const new_rule_name = try self.builder.get_new_rule_name(self.cur_rule_name);
        const empty = try self.builder.add_empty_str();
        const body = try self.builder.add_choices(&.{ empty, grammar_expr_id });
        const new_rule_id = try self.builder.add_rule_named(new_rule_name, body);
        return self.builder.add_rule_ref(new_rule_id);
    }

    fn parse_element_with_quantifier(self: *Parser) (Allocator.Error || EbnfError)!i32 {
        const grammar_expr_id = try self.parse_element();
        switch (self.cur().ty) {
            .Star => {
                self.consume(1);
                return self.handle_star_quantifier(grammar_expr_id);
            },
            .Plus => {
                self.consume(1);
                return self.handle_plus_quantifier(grammar_expr_id);
            },
            .Question => {
                self.consume(1);
                return self.handle_question_quantifier(grammar_expr_id);
            },
            .LBrace => {
                const range = try self.parse_repetition_range();
                const name = self.cur_rule_name;
                return self.builder.add_repeat_from_expr(
                    name,
                    grammar_expr_id,
                    @intCast(range.lower),
                    if (range.upper == -1) -1 else @intCast(range.upper),
                );
            },
            else => return grammar_expr_id,
        }
    }

    fn parse_sequence(self: *Parser) (Allocator.Error || EbnfError)!i32 {
        var elements: ArrayList(i32) = .empty;
        defer elements.deinit(self.gpa);
        try elements.append(self.gpa, try self.parse_element_with_quantifier());
        outer: while (true) {
            switch (self.cur().ty) {
                .Pipe, .RParen, .LookaheadLParen, .RuleName, .EndOfFile => break :outer,
                else => {},
            }
            try elements.append(self.gpa, try self.parse_element_with_quantifier());
        }
        return self.builder.add_sequence(elements.items);
    }

    fn parse_choices(self: *Parser) (Allocator.Error || EbnfError)!i32 {
        var choices: ArrayList(i32) = .empty;
        defer choices.deinit(self.gpa);
        try choices.append(self.gpa, try self.parse_sequence());
        while (self.cur().ty == .Pipe) {
            self.consume(1);
            try choices.append(self.gpa, try self.parse_sequence());
        }
        return self.builder.add_choices(choices.items);
    }

    fn parse_lookahead_assertion(self: *Parser) (Allocator.Error || EbnfError)!i32 {
        try self.expect(.LookaheadLParen, "Expect (= in lookahead assertion");
        const result = try self.parse_choices();
        try self.expect(.RParen, "Expect )");
        return result;
    }

    /// One parsed rule (Rust tuple `(String, i32, i32, Option<RuleAttributes>)`).
    const ParsedRule = struct {
        name: []const u8,
        body_expr_id: i32,
        lookahead_assertion_id: i32,
        attributes: ?RuleAttributes,
    };

    fn parse_rule(self: *Parser) (Allocator.Error || EbnfError)!ParsedRule {
        if (self.cur().ty != .RuleName) return self.fail("Expect rule name");
        self.cur_rule_name = self.cur_str();
        const attributes = self.cur().rule_attributes;
        self.consume(1);
        try self.expect(.Assign, "Expect ::=");

        const body_id = try self.parse_choices();
        const lookahead_id = if (self.cur().ty == .LookaheadLParen)
            try self.parse_lookahead_assertion()
        else
            NO_EXPR;
        return .{
            .name = self.cur_rule_name,
            .body_expr_id = body_id,
            .lookahead_assertion_id = lookahead_id,
            .attributes = attributes,
        };
    }

    fn init_rule_names(self: *Parser) (Allocator.Error || EbnfError)!void {
        for (self.tokens.items, 0..) |*token, i| {
            if (token.ty == .RuleName) {
                const name = token.value.as_str() orelse "";
                if (try self.builder.get_rule_id(name) != NO_EXPR) {
                    return self.fail_at_print(
                        @as(isize, @intCast(i)) - @as(isize, @intCast(self.pos)),
                        "Rule \"{s}\" is defined multiple times",
                        .{name},
                    );
                }
                _ = try self.builder.add_empty_rule(name);
            }
        }
        if (try self.builder.get_rule_id(self.root_rule_name) == NO_EXPR) {
            return self.fail_print("The root rule with name \"{s}\" is not found", .{self.root_rule_name});
        }
    }

    fn parse(self: *Parser) (Allocator.Error || EbnfError)!*Grammar {
        try self.init_rule_names();
        while (self.cur().ty != .EndOfFile) {
            const parsed = try self.parse_rule();
            self.builder.update_rule_body_by_name(parsed.name, parsed.body_expr_id);
            self.builder.update_lookahead_assertion_by_name(parsed.name, parsed.lookahead_assertion_id);
            if (parsed.attributes) |attributes| {
                const rule_id = try self.builder.get_rule_id(parsed.name);
                const info = attributes.suffix_stop_info;
                const num_rules = self.builder.num_rules();
                if (info.body_rule_id != -1 and
                    !((info.body_rule_id >= 0 and info.body_rule_id < num_rules) and
                        (info.marker_rule_id >= 0 and info.marker_rule_id < num_rules)))
                {
                    return self.fail("Capture-hidden helper rule ids must both be -1 or valid rule ids.");
                }
                self.builder.update_max_tokens(rule_id, attributes.max_tokens);
                self.builder.update_max_chars(rule_id, attributes.max_chars);
                try self.builder.update_capture_name(rule_id, attributes.capture_name);
                try self.builder.update_suffix_stop_info(rule_id, info);
                self.builder.update_lazy(rule_id, attributes.is_lazy);
                self.builder.update_rule_temperature(rule_id, attributes.temperature);
            }
        }
        var mutable_missing: ?[]const u8 = null;
        const built = self.builder.into_grammar(self.builder_backing, self.root_rule_name, &mutable_missing) catch |e| switch (e) {
            error.RootRuleNotFound => {
                const name = mutable_missing orelse "";
                const message = std.fmt.allocPrint(self.gpa, "root rule \"{s}\" was never added", .{name}) catch
                    return error.Parser;
                defer self.gpa.free(message);
                self.builder.deinit();
                if (self.diag) |d| d.* = .{ .parser = .{
                    .line = 0,
                    .column = 0,
                    .message = self.gpa.dupe(u8, message) catch "",
                } };
                return error.Parser;
            },
            else => return e,
        };
        self.builder.deinit();
        return built;
    }
};

fn dedup_i32(list: *ArrayList(i32)) void {
    var write: usize = 0;
    for (list.items, 0..) |value, i| {
        if (i == 0 or value != list.items[i - 1]) {
            list.items[write] = value;
            write += 1;
        }
    }
    list.items.len = write;
}
