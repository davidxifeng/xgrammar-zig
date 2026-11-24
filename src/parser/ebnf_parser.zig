//! EBNF parser, macro IR, rule attributes, and `EbnfError` / `Diagnostic` reporting.
//!
//! Produces the raw (un-normalized) BNF AST (`Grammar` returned by value via zero-copy
//! `GrammarBuilder.intoGrammar`), including the built-in macros (`TagDispatch`, `Token`,
//! `ExcludeToken`, `TokenTagDispatch`, `Regex`, `Substring`).
//!
//! Temporary parser scratch structures live in a per-call arena while the built `Grammar`
//! and any `Diagnostic` messages are allocated from the caller's `gpa`. The `flags` branch
//! of `Regex(...)` rewrites dots via `fsm.rewriteRegexDots` and prefixes `(?i)` for
//! case-insensitivity (dot rewriting applies whenever `flags` is present).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;

const Diagnostic = @import("../Diagnostic.zig").Diagnostic;
const ebnf_lexer = @import("ebnf_lexer.zig");
const fsm_mod = @import("../fsm.zig");
const grammar_mod = @import("../grammar.zig");
const support = @import("../support.zig");

const CharacterClassElement = grammar_mod.CharacterClassElement;
const Compact2dArrayError = support.Compact2dArrayError;
const Grammar = grammar_mod.Grammar;
const GrammarBuilder = grammar_mod.GrammarBuilder;
const NO_EXPR = grammar_mod.NO_EXPR;
const SuffixStopInfo = grammar_mod.SuffixStopInfo;
const TagDispatch = grammar_mod.TagDispatch;
const TagRulePair = grammar_mod.TagRulePair;
const Token = ebnf_lexer.Token;
const TokenTagDispatch = grammar_mod.TokenTagDispatch;
const TokenType = ebnf_lexer.TokenType;
const TriggerRulePair = grammar_mod.TriggerRulePair;

const MAX_NEST_LAYER: i32 = 1000;

/// A failure while converting EBNF text to a grammar.
pub const EbnfError = error{
    /// The lexer rejected the input.
    Lexer,
    /// The parser rejected the token stream.
    Parser,
    /// A normalization pass failed.
    Normalization,
};

/// Rule attributes attached to a rule-definition identifier by the lexer.
pub const RuleAttributes = struct {
    /// The token budget, or `-1`.
    max_tokens: i32,
    /// The character budget, or `-1`.
    max_chars: i32,
    /// The capture name, or empty.
    capture_name: []const u8,
    /// The capture-hidden suffix/stop metadata (the `rule_id` field is unused).
    suffix_stop_info: SuffixStopInfo,
    /// Whether the rule is lazy (committed-shortest).
    is_lazy: bool,
    /// The sampling temperature.
    temperature: ?f32,
};

/// A parsed macro argument value: a string, integer, boolean, identifier, or tuple of
/// nested values.
pub const MacroValue = union(enum) {
    /// A string literal.
    Str: []const u8,
    /// An integer literal.
    Int: i64,
    /// A boolean literal.
    Bool: bool,
    /// A bare identifier (a rule reference).
    Identifier: []const u8,
    /// A parenthesized tuple of values.
    Tuple: ArrayList(MacroValue),

    /// Value equality across variants and tuple elements.
    pub fn eql(a: MacroValue, b: MacroValue) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .Str => |s| std.mem.eql(u8, s, b.Str),
            .Int => |v| v == b.Int,
            .Bool => |v| v == b.Bool,
            .Identifier => |s| std.mem.eql(u8, s, b.Identifier),
            .Tuple => |t| {
                if (t.items.len != b.Tuple.items.len) return false;
                for (t.items, b.Tuple.items) |x, y| {
                    if (!x.eql(y)) return false;
                }
                return true;
            },
        };
    }

    /// Deep copy into `allocator`.
    pub fn dupe(self: MacroValue, allocator: Allocator) Allocator.Error!MacroValue {
        return switch (self) {
            .Str => |s| .{ .Str = try allocator.dupe(u8, s) },
            .Int => |v| .{ .Int = v },
            .Bool => |v| .{ .Bool = v },
            .Identifier => |s| .{ .Identifier = try allocator.dupe(u8, s) },
            .Tuple => |t| blk: {
                var copy: ArrayList(MacroValue) = .empty;
                errdefer {
                    for (copy.items) |*item| item.deinit(allocator);
                    copy.deinit(allocator);
                }
                try copy.ensureTotalCapacity(allocator, t.items.len);
                for (t.items) |item| {
                    copy.appendAssumeCapacity(try item.dupe(allocator));
                }
                break :blk .{ .Tuple = copy };
            },
        };
    }

    /// Releases owned payload storage (arena users need not call this).
    pub fn deinit(self: *MacroValue, allocator: Allocator) void {
        switch (self.*) {
            .Str, .Identifier => |s| allocator.free(s),
            .Tuple => |*t| {
                for (t.items) |*item| item.deinit(allocator);
                t.deinit(allocator);
            },
            else => {},
        }
    }
};

/// One named macro argument (`name=value`).
pub const NamedArgument = struct {
    name: []const u8,
    value: MacroValue,
};

/// The positional and named arguments of a macro call.
pub const MacroArguments = struct {
    /// Positional arguments, in order.
    positional: ArrayList(MacroValue) = .empty,
    /// Named arguments, in encounter order.
    named: ArrayList(NamedArgument) = .empty,

    /// Returns the value of the named argument `name`, if present.
    pub fn namedValue(self: *const MacroArguments, name: []const u8) ?*const MacroValue {
        for (self.named.items) |*arg| {
            if (std.mem.eql(u8, arg.name, name)) return &arg.value;
        }
        return null;
    }

    /// Deep copy into `allocator`.
    pub fn dupe(self: MacroArguments, allocator: Allocator) Allocator.Error!MacroArguments {
        var out: MacroArguments = .{};
        errdefer out.deinit(allocator);
        try out.positional.ensureTotalCapacity(allocator, self.positional.items.len);
        for (self.positional.items) |arg| {
            out.positional.appendAssumeCapacity(try arg.dupe(allocator));
        }
        try out.named.ensureTotalCapacity(allocator, self.named.items.len);
        for (self.named.items) |arg| {
            const name_copy = try allocator.dupe(u8, arg.name);
            errdefer allocator.free(name_copy);
            const val_copy = try arg.value.dupe(allocator);
            out.named.appendAssumeCapacity(.{ .name = name_copy, .value = val_copy });
        }
        return out;
    }

    /// Releases owned payload storage (arena users need not call this).
    pub fn deinit(self: *MacroArguments, allocator: Allocator) void {
        for (self.positional.items) |*arg| arg.deinit(allocator);
        self.positional.deinit(allocator);
        for (self.named.items) |*arg| {
            allocator.free(arg.name);
            arg.value.deinit(allocator);
        }
        self.named.deinit(allocator);
    }
};

/// Parses an EBNF grammar string into the raw (un-normalized) BNF AST (`Grammar` by value).
///
/// On `error.Lexer` or `error.Parser`, populates `diag` (with `.ebnf_lexer` or `.ebnf_parser`)
/// using `gpa`, so the diagnostic remains valid after this call returns.
pub fn ebnfToGrammarNoNormalization(
    gpa: Allocator,
    ebnf_string: []const u8,
    root_rule_name: []const u8,
    diag: ?*Diagnostic,
) (Allocator.Error || Compact2dArrayError || EbnfError)!Grammar {
    var tokens = try ebnf_lexer.tokenize(gpa, ebnf_string, diag);
    defer {
        ebnf_lexer.freeTokens(gpa, tokens.items);
        tokens.deinit(gpa);
    }

    var arena = ArenaAllocator.init(gpa);
    defer arena.deinit();

    var builder = try GrammarBuilder.init(gpa);
    defer builder.deinit();

    var parser = Parser.init(arena.allocator(), gpa, &builder, tokens.items, root_rule_name, diag);
    return parser.parse();
}

const Parser = struct {
    /// Temporary per-call arena for scratch containers and macro IR.
    arena: Allocator,
    /// Caller's allocator for diagnostics and error propagation.
    gpa: Allocator,
    diag: ?*Diagnostic,
    builder: *GrammarBuilder,
    tokens: []const Token,
    pos: usize,
    cur_rule_name: []const u8,
    root_rule_name: []const u8,
    nest_layer_guard: i32,

    fn init(
        arena: Allocator,
        gpa: Allocator,
        builder: *GrammarBuilder,
        tokens: []const Token,
        root_rule_name: []const u8,
        diag: ?*Diagnostic,
    ) Parser {
        return .{
            .arena = arena,
            .gpa = gpa,
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
        const last: isize = @as(isize, @intCast(self.tokens.len)) - 1;
        var idx = @as(isize, @intCast(self.pos)) + delta;
        idx = @max(@min(idx, last), 0);
        return &self.tokens[@intCast(idx)];
    }

    fn cur(self: *const Parser) *const Token {
        return self.peek(0);
    }

    fn consume(self: *Parser, cnt: usize) void {
        self.pos += cnt;
    }

    /// Reports a parser error at the current token, allocating the message directly from `gpa`.
    fn fail(self: *Parser, message: []const u8) (Allocator.Error || EbnfError) {
        return self.failAt(0, message);
    }

    fn failAt(self: *Parser, delta: isize, message: []const u8) (Allocator.Error || EbnfError) {
        return self.failAtFmt(delta, "{s}", .{message});
    }

    fn failFmt(self: *Parser, comptime fmt: []const u8, args: anytype) (Allocator.Error || EbnfError) {
        return self.failAtFmt(0, fmt, args);
    }

    fn failAtFmt(
        self: *Parser,
        delta: isize,
        comptime fmt: []const u8,
        args: anytype,
    ) (Allocator.Error || EbnfError) {
        const token = self.peek(delta);
        if (self.diag) |d| {
            try d.setLocatedFmt(
                self.gpa,
                .ebnf_parser,
                @intCast(@max(token.line, 0)),
                @intCast(@max(token.column, 0)),
                "",
                fmt,
                args,
            );
        }
        return error.Parser;
    }

    fn expect(self: *Parser, ty: TokenType, message: []const u8) (Allocator.Error || EbnfError)!void {
        if (self.cur().ty != ty) return self.fail(message);
        self.consume(1);
    }

    /// The current token's string payload, or empty. Borrowed from `tokens`.
    fn curStr(self: *const Parser) []const u8 {
        return self.cur().value.asStr() orelse "";
    }

    fn parseIdentifier(self: *Parser) (Allocator.Error || EbnfError)![]const u8 {
        if (self.cur().ty != .Identifier) return self.fail("Expect identifier");
        const id = self.curStr();
        self.consume(1);
        return id;
    }

    fn parseCharClass(self: *Parser) (Allocator.Error || EbnfError)!i32 {
        try self.expect(.LBracket, "Expect [ in character class");

        var elements: ArrayList(CharacterClassElement) = .empty;
        defer elements.deinit(self.arena);
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
                .CharInCharClass => self.cur().value.asCodepoint() orelse 0,
                .Dash => @intCast('-'),
                else => return self.failFmt("Unexpected character in character class: {s}", .{self.cur().lexeme}),
            };
            self.consume(1);

            const is_range = self.cur().ty == .Dash and
                (self.peek(1).ty == .CharInCharClass or self.peek(1).ty == .Dash);
            if (is_range) {
                const upper: i32 = switch (self.peek(1).ty) {
                    .CharInCharClass => self.peek(1).value.asCodepoint() orelse 0,
                    else => @intCast('-'),
                };
                if (lower > upper) {
                    return self.failAt(-1, "Invalid character class: lower bound is larger than upper bound");
                }
                try elements.append(self.arena, CharacterClassElement.init(lower, upper));
                self.consume(2);
            } else {
                try elements.append(self.arena, CharacterClassElement.init(lower, lower));
            }
        }

        try self.expect(.RBracket, "Expect ] in character class");
        return self.builder.addCharacterClass(elements.items, is_negated);
    }

    fn parseString(self: *Parser) (Allocator.Error || EbnfError)!i32 {
        if (self.cur().ty != .StringLiteral) return self.fail("Expect string literal");
        const value = self.curStr();
        self.consume(1);
        if (value.len == 0) {
            return self.builder.addEmptyStr();
        } else {
            return self.builder.addByteString(value);
        }
    }

    fn parseRuleRef(self: *Parser) (Allocator.Error || EbnfError)!i32 {
        const name = try self.parseIdentifier();
        const rule_id = try self.builder.getRuleId(name);
        if (rule_id == NO_EXPR) {
            return self.failAtFmt(-1, "Rule \"{s}\" is not defined", .{name});
        }
        return self.builder.addRuleRef(rule_id);
    }

    /// Parses a single macro value: a string, integer, boolean, identifier, or tuple.
    fn parseMacroValue(self: *Parser) (Allocator.Error || EbnfError)!MacroValue {
        switch (self.cur().ty) {
            .StringLiteral => {
                const value = self.curStr();
                self.consume(1);
                return .{ .Str = value };
            },
            .IntegerLiteral => {
                const value = self.cur().value.asInt() orelse 0;
                self.consume(1);
                return .{ .Int = value };
            },
            .BooleanLiteral => {
                const value = self.cur().value.asBool() orelse false;
                self.consume(1);
                return .{ .Bool = value };
            },
            .Identifier => {
                const name = self.curStr();
                self.consume(1);
                return .{ .Identifier = name };
            },
            .LParen => {
                // Nested tuples recurse once per layer, so guard the depth the same way the
                // ordinary parenthesis path does to avoid a stack overflow on deeply nested input.
                self.nest_layer_guard += 1;
                if (self.nest_layer_guard > MAX_NEST_LAYER) {
                    return self.failAt(-1, "Nest layer exceeded the maximum limit");
                }
                self.consume(1);
                var elements: ArrayList(MacroValue) = .empty;
                if (self.cur().ty != .RParen) {
                    while (true) {
                        try elements.append(self.arena, try self.parseMacroValue());
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
    fn parseMacroArguments(self: *Parser) (Allocator.Error || EbnfError)!MacroArguments {
        try self.expect(.LParen, "Expect ( after macro function name");
        var args: MacroArguments = .{};
        if (self.cur().ty != .RParen) {
            while (true) {
                if (self.cur().ty == .Identifier and self.peek(1).ty == .Equal) {
                    const name = self.curStr();
                    self.consume(2); // Consume identifier and =
                    const value = try self.parseMacroValue();
                    try args.named.append(self.arena, .{ .name = name, .value = value });
                } else {
                    try args.positional.append(self.arena, try self.parseMacroValue());
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

    fn parseTagDispatch(self: *Parser) (Allocator.Error || EbnfError)!i32 {
        self.consume(1); // Consume TagDispatch operator
        const start = self.pos;
        const args = try self.parseMacroArguments();
        const delta: isize = @as(isize, @intCast(start)) - @as(isize, @intCast(self.pos));

        for (args.named.items) |named| {
            if (!std.mem.eql(u8, named.name, "loop_after_dispatch") and !std.mem.eql(u8, named.name, "excludes")) {
                return self.failAtFmt(delta, "Unknown named argument for TagDispatch: {s}", .{named.name});
            }
        }

        var tag_rule_pairs: ArrayList(struct { []const u8, i32 }) = .empty;
        defer tag_rule_pairs.deinit(self.arena);
        for (args.positional.items) |*arg| {
            const elements = switch (arg.*) {
                .Tuple => |*t| t,
                else => return self.failAt(delta, "Each tag dispatch element must be a tuple"),
            };
            if (elements.items.len != 2) {
                return self.failAt(delta, "Each tag dispatch element must be a pair (tag, rule)");
            }
            const tag = switch (elements.items[0]) {
                .Str => |s| s,
                else => return self.failAt(delta, "Tag must be a non-empty string literal"),
            };
            if (tag.len == 0) {
                return self.failAt(delta, "Tag must be a non-empty string literal");
            }
            const rule_name = switch (elements.items[1]) {
                .Identifier => |s| s,
                else => return self.failAt(delta, "Rule reference must be an identifier"),
            };
            const rule_id = try self.builder.getRuleId(rule_name);
            if (rule_id == NO_EXPR) {
                return self.failAtFmt(delta, "Rule \"{s}\" is not defined", .{rule_name});
            }
            try tag_rule_pairs.append(self.arena, .{ tag, rule_id });
        }

        var loop_after_dispatch = true;
        if (args.namedValue("loop_after_dispatch")) |value| {
            loop_after_dispatch = switch (value.*) {
                .Bool => |b| b,
                else => return self.failAt(delta, "loop_after_dispatch must be a boolean literal"),
            };
        }

        var excludes: ArrayList([]const u8) = .empty;
        defer excludes.deinit(self.arena);
        if (args.namedValue("excludes")) |value| {
            const elements = switch (value.*) {
                .Tuple => |*t| t,
                else => return self.failAt(delta, "excludes must be a tuple"),
            };
            for (elements.items) |element| {
                const s = switch (element) {
                    .Str => |s| s,
                    else => return self.failAt(delta, "Exclude must be a non-empty string literal"),
                };
                if (s.len == 0) {
                    return self.failAt(delta, "Exclude must be a non-empty string literal");
                }
                try excludes.append(self.arena, s);
            }
        }

        for (excludes.items) |exclude| {
            for (tag_rule_pairs.items) |pair| {
                if (std.mem.startsWith(u8, pair[0], exclude)) {
                    return self.failAtFmt(
                        delta,
                        "Exclude string must not be a prefix of trigger string: {s}",
                        .{exclude},
                    );
                }
            }
        }

        var pairs: ArrayList(TagRulePair) = .empty;
        defer pairs.deinit(self.arena);
        for (tag_rule_pairs.items) |pair| try pairs.append(self.arena, .{ .tag = @constCast(pair[0]), .rule_id = pair[1] });
        var exclude_dupe: ArrayList([]u8) = .empty;
        defer exclude_dupe.deinit(self.arena);
        for (excludes.items) |exclude| try exclude_dupe.append(self.arena, @constCast(exclude));
        const tag_dispatch = TagDispatch{
            .tag_rule_pairs = pairs,
            .loop_after_dispatch = loop_after_dispatch,
            .excludes = exclude_dupe,
        };
        return self.builder.addTagDispatch(&tag_dispatch);
    }

    fn parseRegexMacro(self: *Parser) (Allocator.Error || EbnfError)!i32 {
        self.consume(1); // Consume Regex identifier
        const start = self.pos;
        const args = try self.parseMacroArguments();
        const delta: isize = @as(isize, @intCast(start)) - @as(isize, @intCast(self.pos));

        if (args.positional.items.len != 1) {
            return self.failAt(delta, "Regex expects exactly one string argument");
        }
        const pattern_value = switch (args.positional.items[0]) {
            .Str => |s| s,
            else => return self.failAt(delta, "Regex pattern must be a string literal"),
        };
        for (args.named.items) |named| {
            if (!std.mem.eql(u8, named.name, "json_string") and !std.mem.eql(u8, named.name, "flags")) {
                return self.failAtFmt(delta, "Regex does not support the named argument {s}", .{named.name});
            }
        }
        var json_string = false;
        if (args.namedValue("json_string")) |value| {
            json_string = switch (value.*) {
                .Bool => |b| b,
                else => return self.failAt(delta, "json_string must be a boolean"),
            };
        }
        const pattern = pattern_value;
        if (args.namedValue("flags")) |value| {
            const flags = switch (value.*) {
                .Str => |s| s,
                else => return self.failAt(delta, "flags must be a string"),
            };
            var case_insensitive = false;
            var dot_all = false;
            var indices = std.unicode.Utf8View.initUnchecked(flags).iterator();
            while (indices.nextCodepoint()) |flag| {
                switch (flag) {
                    'i' => case_insensitive = true,
                    's' => dot_all = true,
                    // XGrammar regular expressions use Unicode codepoint semantics by default.
                    'u' => {},
                    else => return self.failAtFmt(
                        delta,
                        "regular-expression flag '{u}' is not supported",
                        .{flag},
                    ),
                }
            }
            // The flags argument opts into the standard dot semantics: '.' does not match '\n'
            // unless the 's' flag is given. Without the argument the pattern is stored verbatim,
            // where the engine's '.' matches every codepoint.
            var rewritten = try fsm_mod.rewriteRegexDots(self.arena, pattern, dot_all);
            if (case_insensitive and !std.mem.startsWith(u8, rewritten, "(?i)")) {
                rewritten = try std.mem.concat(self.arena, u8, &.{ "(?i)", rewritten });
            }
            return self.builder.addRegex(rewritten, json_string);
        }
        return self.builder.addRegex(pattern, json_string);
    }

    fn parseSubstringMacro(self: *Parser) (Allocator.Error || EbnfError)!i32 {
        self.consume(1); // Consume Substring identifier
        const start = self.pos;
        const args = try self.parseMacroArguments();
        const delta: isize = @as(isize, @intCast(start)) - @as(isize, @intCast(self.pos));

        if (args.named.items.len != 0) {
            return self.failAt(delta, "Substring() does not accept named arguments");
        }
        var chunks: ArrayList([]const u8) = .empty;
        defer chunks.deinit(self.arena);
        for (args.positional.items) |*arg| {
            switch (arg.*) {
                .Str => |chunk| try chunks.append(self.arena, chunk),
                else => return self.failAt(delta, "Substring() arguments must be strings"),
            }
        }
        return self.builder.addSubstring(chunks.items);
    }

    fn parseTokenSet(self: *Parser) (Allocator.Error || EbnfError)!i32 {
        self.consume(1); // Consume Token identifier
        const start = self.pos;
        const args = try self.parseMacroArguments();
        const delta: isize = @as(isize, @intCast(start)) - @as(isize, @intCast(self.pos));

        if (args.named.items.len != 0) {
            return self.failAt(delta, "Token() does not accept named arguments");
        }
        if (args.positional.items.len == 0) {
            return self.failAt(delta, "Token() requires at least one integer argument");
        }
        var token_ids: ArrayList(i32) = .empty;
        defer token_ids.deinit(self.arena);
        for (args.positional.items) |*arg| {
            const value = switch (arg.*) {
                .Int => |v| v,
                else => return self.failAt(delta, "Token() arguments must be non-negative integers"),
            };
            if (value < 0) {
                return self.failAt(delta, "Token() arguments must be non-negative integers");
            }
            try token_ids.append(self.arena, @intCast(value));
        }
        std.mem.sort(i32, token_ids.items, {}, std.sort.asc(i32));
        dedupI32(&token_ids);
        return self.builder.addTokenSet(token_ids.items);
    }

    fn parseExcludeToken(self: *Parser) (Allocator.Error || EbnfError)!i32 {
        self.consume(1); // Consume ExcludeToken identifier
        const start = self.pos;
        const args = try self.parseMacroArguments();
        const delta: isize = @as(isize, @intCast(start)) - @as(isize, @intCast(self.pos));

        if (args.named.items.len != 0) {
            return self.failAt(delta, "ExcludeToken() does not accept named arguments");
        }
        if (args.positional.items.len == 0) {
            return self.failAt(delta, "ExcludeToken() requires at least one integer argument");
        }
        var token_ids: ArrayList(i32) = .empty;
        defer token_ids.deinit(self.arena);
        for (args.positional.items) |*arg| {
            const value = switch (arg.*) {
                .Int => |v| v,
                else => return self.failAt(delta, "ExcludeToken() arguments must be non-negative integers"),
            };
            if (value < 0) {
                return self.failAt(delta, "ExcludeToken() arguments must be non-negative integers");
            }
            try token_ids.append(self.arena, @intCast(value));
        }
        std.mem.sort(i32, token_ids.items, {}, std.sort.asc(i32));
        dedupI32(&token_ids);
        return self.builder.addExcludeTokenSet(token_ids.items);
    }

    fn parseTokenTagDispatch(self: *Parser) (Allocator.Error || EbnfError)!i32 {
        self.consume(1); // Consume TokenTagDispatch identifier
        const start = self.pos;
        const args = try self.parseMacroArguments();
        const delta: isize = @as(isize, @intCast(start)) - @as(isize, @intCast(self.pos));

        for (args.named.items) |named| {
            if (!std.mem.eql(u8, named.name, "loop_after_dispatch") and !std.mem.eql(u8, named.name, "excludes")) {
                return self.failAtFmt(delta, "Unknown named argument for TokenTagDispatch: {s}", .{named.name});
            }
        }

        var trigger_rule_pairs: ArrayList(struct { i32, i32 }) = .empty;
        defer trigger_rule_pairs.deinit(self.arena);
        for (args.positional.items) |*arg| {
            const elements = switch (arg.*) {
                .Tuple => |*t| t,
                else => return self.failAt(delta, "Each TokenTagDispatch element must be a pair (token_id, rule)"),
            };
            if (elements.items.len != 2) {
                return self.failAt(delta, "Each TokenTagDispatch element must be a pair (token_id, rule)");
            }
            const token_id = switch (elements.items[0]) {
                .Int => |v| v,
                else => return self.failAt(delta, "Token trigger ID must be a non-negative integer"),
            };
            if (token_id < 0) {
                return self.failAt(delta, "Token trigger ID must be a non-negative integer");
            }
            const rule_name = switch (elements.items[1]) {
                .Identifier => |s| s,
                else => return self.failAt(delta, "Rule reference must be an identifier"),
            };
            const rule_id = try self.builder.getRuleId(rule_name);
            if (rule_id == NO_EXPR) {
                return self.failAtFmt(delta, "Rule \"{s}\" is not defined", .{rule_name});
            }
            try trigger_rule_pairs.append(self.arena, .{ @intCast(token_id), rule_id });
        }

        var loop_after_dispatch = true;
        if (args.namedValue("loop_after_dispatch")) |value| {
            loop_after_dispatch = switch (value.*) {
                .Bool => |b| b,
                else => return self.failAt(delta, "loop_after_dispatch must be a boolean"),
            };
        }

        var excludes: ArrayList(i32) = .empty;
        defer excludes.deinit(self.arena);
        if (args.namedValue("excludes")) |value| {
            const elements = switch (value.*) {
                .Tuple => |*t| t,
                else => return self.failAt(delta, "excludes must be a tuple"),
            };
            for (elements.items) |element| {
                const token_id = switch (element) {
                    .Int => |v| v,
                    else => return self.failAt(delta, "Exclude token ID must be a non-negative integer"),
                };
                if (token_id < 0) {
                    return self.failAt(delta, "Exclude token ID must be a non-negative integer");
                }
                try excludes.append(self.arena, @intCast(token_id));
            }
        }

        for (excludes.items) |exclude_id| {
            for (trigger_rule_pairs.items) |pair| {
                if (pair[0] == exclude_id) {
                    return self.failAtFmt(
                        delta,
                        "Token trigger ID {d} must not overlap with exclude token ID",
                        .{pair[0]},
                    );
                }
            }
        }

        var pairs: ArrayList(TriggerRulePair) = .empty;
        defer pairs.deinit(self.arena);
        for (trigger_rule_pairs.items) |pair| try pairs.append(self.arena, .{ .token_id = pair[0], .rule_id = pair[1] });
        const ttd = TokenTagDispatch{
            .trigger_rule_pairs = pairs,
            .loop_after_dispatch = loop_after_dispatch,
            .excludes = excludes,
        };
        return self.builder.addTokenTagDispatch(&ttd);
    }

    fn parseElement(self: *Parser) (Allocator.Error || EbnfError)!i32 {
        switch (self.cur().ty) {
            .LParen => {
                self.nest_layer_guard += 1;
                if (self.nest_layer_guard > MAX_NEST_LAYER) {
                    return self.failAt(-1, "Nest layer exceeded the maximum limit");
                }
                self.consume(1);
                if (self.cur().ty == .RParen) {
                    self.consume(1);
                    self.nest_layer_guard -= 1;
                    return self.builder.addEmptyStr();
                }
                const expr = try self.parseChoices();
                try self.expect(.RParen, "Expect )");
                self.nest_layer_guard -= 1;
                return expr;
            },
            .LBracket => return self.parseCharClass(),
            .StringLiteral => return self.parseString(),
            .Identifier => {
                const name = self.curStr();
                if (std.mem.eql(u8, name, "TagDispatch")) {
                    return self.parseTagDispatch();
                } else if (std.mem.eql(u8, name, "Token")) {
                    return self.parseTokenSet();
                } else if (std.mem.eql(u8, name, "ExcludeToken")) {
                    return self.parseExcludeToken();
                } else if (std.mem.eql(u8, name, "TokenTagDispatch")) {
                    return self.parseTokenTagDispatch();
                } else if (std.mem.eql(u8, name, "Regex")) {
                    return self.parseRegexMacro();
                } else if (std.mem.eql(u8, name, "Substring")) {
                    return self.parseSubstringMacro();
                } else {
                    return self.parseRuleRef();
                }
            },
            else => return self.failFmt("Expect element, but got {s}", .{self.cur().lexeme}),
        }
    }

    fn parseInteger(self: *Parser) (Allocator.Error || EbnfError)!i64 {
        if (self.cur().ty != .IntegerLiteral) {
            return self.failFmt("Expect integer, but got {s}", .{self.cur().lexeme});
        }
        const num = self.cur().value.asInt() orelse 0;
        self.consume(1);
        return num;
    }

    /// Parses `{m}`, `{m,}`, `{m,n}`, or the printer's `{m, -1}` (unbounded), returning
    /// `(lower, upper)` with `upper == -1` meaning unbounded.
    const RepetitionRange = struct { lower: i64, upper: i64 };

    fn parseRepetitionRange(self: *Parser) (Allocator.Error || EbnfError)!RepetitionRange {
        try self.expect(.LBrace, "Expect {");
        const lower = try self.parseInteger();
        if (lower < 0) {
            return self.failAt(-1, "Lower bound cannot be negative");
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
                const upper = try self.parseInteger();
                if (upper < lower) {
                    return self.failAtFmt(-1, "Lower bound is larger than upper bound: {d} > {d}", .{ lower, upper });
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

    fn handleStarQuantifier(self: *Parser, grammar_expr_id: i32) (Allocator.Error || EbnfError)!i32 {
        // A character-class star has a dedicated expr type: [a-z]*
        {
            const expr = self.builder.grammarExpr(grammar_expr_id);
            if (expr.ty == .CharacterClass) {
                const cc = try expr.characterClass(self.arena);
                defer self.arena.free(cc.ranges);
                return self.builder.addCharacterClassStar(cc.ranges, cc.is_negative);
            }
        }
        // Otherwise: a*  -->  rule ::= a rule | ""
        const new_rule_name = try self.builder.getNewRuleName(self.cur_rule_name);
        const new_rule_id = try self.builder.addEmptyRule(new_rule_name);
        const ref_to_new_rule = try self.builder.addRuleRef(new_rule_id);
        const empty = try self.builder.addEmptyStr();
        const seq = try self.builder.addSequence(&.{ grammar_expr_id, ref_to_new_rule });
        const body = try self.builder.addChoices(&.{ empty, seq });
        self.builder.updateRuleBody(new_rule_id, body);
        return self.builder.addRuleRef(new_rule_id);
    }

    fn handlePlusQuantifier(self: *Parser, grammar_expr_id: i32) (Allocator.Error || EbnfError)!i32 {
        // a+  -->  rule ::= a rule | a
        const new_rule_name = try self.builder.getNewRuleName(self.cur_rule_name);
        const new_rule_id = try self.builder.addEmptyRule(new_rule_name);
        const ref_to_new_rule = try self.builder.addRuleRef(new_rule_id);
        const seq = try self.builder.addSequence(&.{ grammar_expr_id, ref_to_new_rule });
        const body = try self.builder.addChoices(&.{ seq, grammar_expr_id });
        self.builder.updateRuleBody(new_rule_id, body);
        return self.builder.addRuleRef(new_rule_id);
    }

    fn handleQuestionQuantifier(self: *Parser, grammar_expr_id: i32) (Allocator.Error || EbnfError)!i32 {
        // a?  -->  rule ::= a | empty
        const new_rule_name = try self.builder.getNewRuleName(self.cur_rule_name);
        const empty = try self.builder.addEmptyStr();
        const body = try self.builder.addChoices(&.{ empty, grammar_expr_id });
        const new_rule_id = try self.builder.addRuleNamed(new_rule_name, body);
        return self.builder.addRuleRef(new_rule_id);
    }

    fn parseElementWithQuantifier(self: *Parser) (Allocator.Error || EbnfError)!i32 {
        const grammar_expr_id = try self.parseElement();
        switch (self.cur().ty) {
            .Star => {
                self.consume(1);
                return self.handleStarQuantifier(grammar_expr_id);
            },
            .Plus => {
                self.consume(1);
                return self.handlePlusQuantifier(grammar_expr_id);
            },
            .Question => {
                self.consume(1);
                return self.handleQuestionQuantifier(grammar_expr_id);
            },
            .LBrace => {
                const range = try self.parseRepetitionRange();
                const name = self.cur_rule_name;
                return self.builder.addRepeatFromExpr(
                    name,
                    grammar_expr_id,
                    @intCast(range.lower),
                    if (range.upper == -1) -1 else @intCast(range.upper),
                );
            },
            else => return grammar_expr_id,
        }
    }

    fn parseSequence(self: *Parser) (Allocator.Error || EbnfError)!i32 {
        var elements: ArrayList(i32) = .empty;
        defer elements.deinit(self.arena);
        try elements.append(self.arena, try self.parseElementWithQuantifier());
        outer: while (true) {
            switch (self.cur().ty) {
                .Pipe, .RParen, .LookaheadLParen, .RuleName, .EndOfFile => break :outer,
                else => {},
            }
            try elements.append(self.arena, try self.parseElementWithQuantifier());
        }
        return self.builder.addSequence(elements.items);
    }

    fn parseChoices(self: *Parser) (Allocator.Error || EbnfError)!i32 {
        var choices: ArrayList(i32) = .empty;
        defer choices.deinit(self.arena);
        try choices.append(self.arena, try self.parseSequence());
        while (self.cur().ty == .Pipe) {
            self.consume(1);
            try choices.append(self.arena, try self.parseSequence());
        }
        return self.builder.addChoices(choices.items);
    }

    fn parseLookaheadAssertion(self: *Parser) (Allocator.Error || EbnfError)!i32 {
        try self.expect(.LookaheadLParen, "Expect (= in lookahead assertion");
        const result = try self.parseChoices();
        try self.expect(.RParen, "Expect )");
        return result;
    }

    /// One parsed rule.
    const ParsedRule = struct {
        name: []const u8,
        body_expr_id: i32,
        lookahead_assertion_id: i32,
        attributes: ?RuleAttributes,
    };

    fn parseRule(self: *Parser) (Allocator.Error || EbnfError)!ParsedRule {
        if (self.cur().ty != .RuleName) return self.fail("Expect rule name");
        self.cur_rule_name = self.curStr();
        const attributes = self.cur().rule_attributes;
        self.consume(1);
        try self.expect(.Assign, "Expect ::=");

        const body_id = try self.parseChoices();
        const lookahead_id = if (self.cur().ty == .LookaheadLParen)
            try self.parseLookaheadAssertion()
        else
            NO_EXPR;
        return .{
            .name = self.cur_rule_name,
            .body_expr_id = body_id,
            .lookahead_assertion_id = lookahead_id,
            .attributes = attributes,
        };
    }

    fn initRuleNames(self: *Parser) (Allocator.Error || EbnfError)!void {
        for (self.tokens, 0..) |*token, i| {
            if (token.ty == .RuleName) {
                const name = token.value.asStr() orelse "";
                if (try self.builder.getRuleId(name) != NO_EXPR) {
                    return self.failAtFmt(
                        @as(isize, @intCast(i)) - @as(isize, @intCast(self.pos)),
                        "Rule \"{s}\" is defined multiple times",
                        .{name},
                    );
                }
                _ = try self.builder.addEmptyRule(name);
            }
        }
        if (try self.builder.getRuleId(self.root_rule_name) == NO_EXPR) {
            return self.failFmt("The root rule with name \"{s}\" is not found", .{self.root_rule_name});
        }
    }

    fn parse(self: *Parser) (Allocator.Error || Compact2dArrayError || EbnfError)!Grammar {
        try self.initRuleNames();
        while (self.cur().ty != .EndOfFile) {
            const parsed = try self.parseRule();
            try self.builder.updateRuleBodyByName(parsed.name, parsed.body_expr_id);
            try self.builder.updateLookaheadAssertionByName(parsed.name, parsed.lookahead_assertion_id);
            if (parsed.attributes) |attributes| {
                const rule_id = try self.builder.getRuleId(parsed.name);
                const info = attributes.suffix_stop_info;
                const num_rules = self.builder.numRules();
                if (info.body_rule_id != -1 and
                    !((info.body_rule_id >= 0 and info.body_rule_id < num_rules) and
                        (info.marker_rule_id >= 0 and info.marker_rule_id < num_rules)))
                {
                    return self.fail("Capture-hidden helper rule ids must both be -1 or valid rule ids.");
                }
                self.builder.updateMaxTokens(rule_id, attributes.max_tokens);
                self.builder.updateMaxChars(rule_id, attributes.max_chars);
                try self.builder.updateCaptureName(rule_id, attributes.capture_name);
                try self.builder.updateSuffixStopInfo(rule_id, info);
                self.builder.updateLazy(rule_id, attributes.is_lazy);
                self.builder.updateRuleTemperature(rule_id, attributes.temperature);
            }
        }
        return self.builder.intoGrammar(self.root_rule_name, null) catch |e| switch (e) {
            error.RootRuleNotFound => {
                if (self.diag) |d| {
                    try d.setLocatedFmt(
                        self.gpa,
                        .ebnf_parser,
                        1,
                        1,
                        "",
                        "root rule \"{s}\" was never added",
                        .{self.root_rule_name},
                    );
                }
                return error.Parser;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
    }
};

fn dedupI32(list: *ArrayList(i32)) void {
    var write: usize = 0;
    for (list.items, 0..) |value, i| {
        if (i == 0 or value != list.items[i - 1]) {
            list.items[write] = value;
            write += 1;
        }
    }
    list.items.len = write;
}

test "MacroArguments namedValue, dupe, and eql" {
    const gpa = std.testing.allocator;
    var args: MacroArguments = .{};
    defer args.deinit(gpa);
    try args.positional.append(gpa, .{ .Str = try gpa.dupe(u8, "a") });
    try args.named.append(gpa, .{
        .name = try gpa.dupe(u8, "flag"),
        .value = .{ .Bool = true },
    });
    try std.testing.expect(args.namedValue("flag").?.Bool);
    try std.testing.expect(args.namedValue("missing") == null);

    var copy = try args.dupe(gpa);
    defer copy.deinit(gpa);
    try std.testing.expect(copy.positional.items[0].eql(args.positional.items[0]));
    try std.testing.expect(copy.namedValue("flag").?.eql(.{ .Bool = true }));
}

test "ebnfToGrammarNoNormalization Diagnostic and zero-copy grammar" {
    const gpa = std.testing.allocator;
    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);

    var g = try ebnfToGrammarNoNormalization(
        gpa,
        "root[max_tokens=4, capture=\"out\", lazy, temperature=0.5] ::= [a-z]+ | \"ok\"",
        "root",
        &diag,
    );
    defer g.deinit();
    try std.testing.expectEqual(@as(i32, 4), g.rootRule().max_tokens);
    try std.testing.expectEqualStrings("out", g.rootRule().capture_name);
    try std.testing.expect(g.rootRule().is_lazy);
    try std.testing.expectEqual(@as(?f32, 0.5), g.rootRule().temperature);

    // Lexer error surfaces through Diagnostic with .ebnf_lexer
    try std.testing.expectError(error.Lexer, ebnfToGrammarNoNormalization(gpa, "root ::= @", "root", &diag));
    try std.testing.expectEqual(Diagnostic.Kind.ebnf_lexer, diag.kind);

    // Parser error surfaces through Diagnostic with .ebnf_parser (allocated from gpa, outlives arena)
    try std.testing.expectError(error.Parser, ebnfToGrammarNoNormalization(gpa, "other ::= \"x\"", "root", &diag));
    try std.testing.expectEqual(Diagnostic.Kind.ebnf_parser, diag.kind);
    const msg = try diag.formatAlloc(gpa);
    defer gpa.free(msg);
    try std.testing.expectEqualStrings(
        "EBNF parser error at line 1, column 1: The root rule with name \"root\" is not found",
        msg,
    );
}
