//! Port of `external/xgrammar/tests/cpp/test_parser.cc` (the `XGrammarLexerTest` suite),
//! via the crate's `tests/cpp/test_parser.rs`.
//!
//! The two "invalid UTF-8 byte sequence" sub-cases of `lexer_error_cases` are omitted (as in
//! the Rust port): the safe `tokenize` API is given valid UTF-8 input, so that error path is
//! unreachable through the public API.

const std = @import("std");
const testing = std.testing;

const parser = @import("mod.zig");

const LexerError = parser.LexerError;
const Token = parser.Token;
const TokenValue = parser.TokenValue;
const TokenType = parser.TokenType;
const free_tokens = parser.token.free_tokens;

fn lex(input: []const u8) []Token {
    const gpa = testing.allocator;
    var list = parser.tokenize(gpa, input, null) catch unreachable;
    return list.toOwnedSlice(gpa) catch unreachable;
}

fn lex_fail(input: []const u8) []u8 {
    const gpa = testing.allocator;
    var diag = LexerError{};
    if (parser.tokenize(gpa, input, &diag)) |_| {
        unreachable; // expected a lexer failure
    } else |e| switch (e) {
        error.Lexer => {
            defer if (diag.message.len > 0) gpa.free(diag.message);
            return diag.format_message(gpa) catch unreachable;
        },
        error.OutOfMemory => unreachable,
    }
}

fn cp(c: u21) TokenValue {
    return .{ .Codepoint = @intCast(c) };
}

fn expect_value(tokens: []Token, i: usize, expected: TokenValue) !void {
    try testing.expect(tokens[i].value.eql(expected));
}

test "basic_tokenization" {
    const gpa = testing.allocator;
    const input = "rule1 ::= \"string\" | [a-z] | 123 | (expr) | {1,3} | * | + | ? | true | false";
    const tokens = lex(input);
    defer {
        free_tokens(gpa, tokens);
        gpa.free(tokens);
    }
    try testing.expectEqual(@as(usize, 32), tokens.len); // 31 tokens + EOF

    try testing.expectEqual(TokenType.RuleName, tokens[0].ty);
    try testing.expectEqualStrings("rule1", tokens[0].lexeme);

    try testing.expectEqual(TokenType.Assign, tokens[1].ty);
    try testing.expectEqualStrings("::=", tokens[1].lexeme);

    try testing.expectEqual(TokenType.StringLiteral, tokens[2].ty);
    try testing.expectEqualStrings("\"string\"", tokens[2].lexeme);
    try expect_value(tokens, 2, .{ .Str = "string" });

    try testing.expectEqual(TokenType.Pipe, tokens[3].ty);

    try testing.expectEqual(TokenType.LBracket, tokens[4].ty);
    try testing.expectEqual(TokenType.CharInCharClass, tokens[5].ty);
    try testing.expectEqualStrings("a", tokens[5].lexeme);
    try expect_value(tokens, 5, cp('a'));
    try testing.expectEqual(TokenType.Dash, tokens[6].ty);
    try testing.expectEqual(TokenType.CharInCharClass, tokens[7].ty);
    try testing.expectEqualStrings("z", tokens[7].lexeme);
    try expect_value(tokens, 7, cp('z'));
    try testing.expectEqual(TokenType.RBracket, tokens[8].ty);

    try testing.expectEqual(TokenType.Pipe, tokens[9].ty);

    try testing.expectEqual(TokenType.IntegerLiteral, tokens[10].ty);
    try testing.expectEqualStrings("123", tokens[10].lexeme);
    try expect_value(tokens, 10, .{ .Int = 123 });

    try testing.expectEqual(TokenType.Pipe, tokens[11].ty);

    try testing.expectEqual(TokenType.LParen, tokens[12].ty);
    try testing.expectEqual(TokenType.Identifier, tokens[13].ty);
    try testing.expectEqual(TokenType.RParen, tokens[14].ty);

    try testing.expectEqual(TokenType.Pipe, tokens[15].ty);

    try testing.expectEqual(TokenType.LBrace, tokens[16].ty);
    try testing.expectEqual(TokenType.IntegerLiteral, tokens[17].ty);
    try testing.expectEqual(TokenType.Comma, tokens[18].ty);
    try testing.expectEqual(TokenType.IntegerLiteral, tokens[19].ty);
    try testing.expectEqual(TokenType.RBrace, tokens[20].ty);

    try testing.expectEqual(TokenType.Pipe, tokens[21].ty);
    try testing.expectEqual(TokenType.Star, tokens[22].ty);
    try testing.expectEqual(TokenType.Pipe, tokens[23].ty);
    try testing.expectEqual(TokenType.Plus, tokens[24].ty);
    try testing.expectEqual(TokenType.Pipe, tokens[25].ty);
    try testing.expectEqual(TokenType.Question, tokens[26].ty);
    try testing.expectEqual(TokenType.Pipe, tokens[27].ty);

    try testing.expectEqual(TokenType.BooleanLiteral, tokens[28].ty);
    try testing.expectEqualStrings("true", tokens[28].lexeme);
    try expect_value(tokens, 28, .{ .Bool = true });

    try testing.expectEqual(TokenType.Pipe, tokens[29].ty);

    try testing.expectEqual(TokenType.BooleanLiteral, tokens[30].ty);
    try expect_value(tokens, 30, .{ .Bool = false });

    try testing.expectEqual(TokenType.EndOfFile, tokens[31].ty);
}

test "comments_and_whitespace" {
    const gpa = testing.allocator;
    const input = "rule1 ::= expr1 # This is a comment\n  | expr2 # Another comment";
    const tokens = lex(input);
    defer {
        free_tokens(gpa, tokens);
        gpa.free(tokens);
    }

    try testing.expectEqual(@as(usize, 6), tokens.len); // 5 tokens + EOF
    try testing.expectEqual(TokenType.RuleName, tokens[0].ty);
    try testing.expectEqualStrings("rule1", tokens[0].lexeme);
    try testing.expectEqual(TokenType.Assign, tokens[1].ty);
    try testing.expectEqual(TokenType.Identifier, tokens[2].ty);
    try testing.expectEqualStrings("expr1", tokens[2].lexeme);
    try testing.expectEqual(TokenType.Pipe, tokens[3].ty);
    try testing.expectEqual(TokenType.Identifier, tokens[4].ty);
    try testing.expectEqualStrings("expr2", tokens[4].lexeme);
}

test "string_literals" {
    const gpa = testing.allocator;
    const input = "rule ::= \"normal string\" | \"escaped \\\"quotes\\\"\" | \"\\n\\r\\t\\\\\"";
    const tokens = lex(input);
    defer {
        free_tokens(gpa, tokens);
        gpa.free(tokens);
    }

    try testing.expectEqual(@as(usize, 8), tokens.len); // 7 tokens + EOF
    try testing.expectEqual(TokenType.StringLiteral, tokens[2].ty);
    try expect_value(tokens, 2, .{ .Str = "normal string" });

    try testing.expectEqual(TokenType.StringLiteral, tokens[4].ty);
    try expect_value(tokens, 4, .{ .Str = "escaped \"quotes\"" });

    try testing.expectEqual(TokenType.StringLiteral, tokens[6].ty);
    try expect_value(tokens, 6, .{ .Str = "\n\r\t\\" });
}

test "character_classes" {
    const gpa = testing.allocator;
    const input = "rule ::= [a-z] | [0-9] | [^a-z] | [\\-\\]\\\\] | [\\u0041-\\u005A] | [测试] | " ++
        "[\\t\\r\\n] | [\\b\\f]";
    const tokens = lex(input);
    defer {
        free_tokens(gpa, tokens);
        gpa.free(tokens);
    }

    try testing.expectEqual(@as(usize, 49), tokens.len); // 48 tokens + EOF

    // [a-z]
    try testing.expectEqual(TokenType.LBracket, tokens[2].ty);
    try testing.expectEqual(TokenType.CharInCharClass, tokens[3].ty);
    try testing.expectEqualStrings("a", tokens[3].lexeme);
    try expect_value(tokens, 3, cp('a'));
    try testing.expectEqual(TokenType.Dash, tokens[4].ty);
    try testing.expectEqual(TokenType.CharInCharClass, tokens[5].ty);
    try testing.expectEqualStrings("z", tokens[5].lexeme);
    try expect_value(tokens, 5, cp('z'));
    try testing.expectEqual(TokenType.RBracket, tokens[6].ty);

    try testing.expectEqual(TokenType.Pipe, tokens[7].ty);

    // [0-9]
    try testing.expectEqual(TokenType.LBracket, tokens[8].ty);
    try expect_value(tokens, 9, cp('0'));
    try testing.expectEqual(TokenType.Dash, tokens[10].ty);
    try expect_value(tokens, 11, cp('9'));
    try testing.expectEqual(TokenType.RBracket, tokens[12].ty);

    try testing.expectEqual(TokenType.Pipe, tokens[13].ty);

    // [^a-z]
    try testing.expectEqual(TokenType.LBracket, tokens[14].ty);
    try testing.expectEqual(TokenType.Caret, tokens[15].ty);
    try expect_value(tokens, 16, cp('a'));
    try testing.expectEqual(TokenType.Dash, tokens[17].ty);
    try expect_value(tokens, 18, cp('z'));
    try testing.expectEqual(TokenType.RBracket, tokens[19].ty);

    try testing.expectEqual(TokenType.Pipe, tokens[20].ty);

    // [\-\]\\]
    try testing.expectEqual(TokenType.LBracket, tokens[21].ty);
    try testing.expectEqual(TokenType.CharInCharClass, tokens[22].ty);
    try testing.expectEqualStrings("\\-", tokens[22].lexeme);
    try expect_value(tokens, 22, cp('-'));
    try testing.expectEqualStrings("\\]", tokens[23].lexeme);
    try expect_value(tokens, 23, cp(']'));
    try testing.expectEqualStrings("\\\\", tokens[24].lexeme);
    try expect_value(tokens, 24, cp('\\'));
    try testing.expectEqual(TokenType.RBracket, tokens[25].ty);

    try testing.expectEqual(TokenType.Pipe, tokens[26].ty);

    // [A-Z]
    try testing.expectEqual(TokenType.LBracket, tokens[27].ty);
    try testing.expectEqualStrings("\\u0041", tokens[28].lexeme);
    try expect_value(tokens, 28, .{ .Codepoint = 0x41 });
    try testing.expectEqual(TokenType.Dash, tokens[29].ty);
    try testing.expectEqualStrings("\\u005A", tokens[30].lexeme);
    try expect_value(tokens, 30, .{ .Codepoint = 0x5A });
    try testing.expectEqual(TokenType.RBracket, tokens[31].ty);

    try testing.expectEqual(TokenType.Pipe, tokens[32].ty);

    // [测试]
    try testing.expectEqual(TokenType.LBracket, tokens[33].ty);
    try testing.expectEqualStrings("测", tokens[34].lexeme);
    try expect_value(tokens, 34, .{ .Codepoint = 0x6D4B });
    try testing.expectEqualStrings("试", tokens[35].lexeme);
    try expect_value(tokens, 35, .{ .Codepoint = 0x8BD5 });
    try testing.expectEqual(TokenType.RBracket, tokens[36].ty);

    try testing.expectEqual(TokenType.Pipe, tokens[37].ty);

    // [\t\r\n]
    try testing.expectEqual(TokenType.LBracket, tokens[38].ty);
    try testing.expectEqualStrings("\\t", tokens[39].lexeme);
    try expect_value(tokens, 39, cp('\t'));
    try testing.expectEqualStrings("\\r", tokens[40].lexeme);
    try expect_value(tokens, 40, cp('\r'));
    try testing.expectEqualStrings("\\n", tokens[41].lexeme);
    try expect_value(tokens, 41, cp('\n'));
    try testing.expectEqual(TokenType.RBracket, tokens[42].ty);

    try testing.expectEqual(TokenType.Pipe, tokens[43].ty);

    // [\b\f]
    try testing.expectEqual(TokenType.LBracket, tokens[44].ty);
    try testing.expectEqualStrings("\\b", tokens[45].lexeme);
    try expect_value(tokens, 45, .{ .Codepoint = 0x08 });
    try testing.expectEqualStrings("\\f", tokens[46].lexeme);
    try expect_value(tokens, 46, .{ .Codepoint = 0x0C });
    try testing.expectEqual(TokenType.RBracket, tokens[47].ty);
}

test "boolean_values" {
    const gpa = testing.allocator;
    const input = "rule ::= true | false";
    const tokens = lex(input);
    defer {
        free_tokens(gpa, tokens);
        gpa.free(tokens);
    }

    try testing.expectEqual(@as(usize, 6), tokens.len); // 5 tokens + EOF
    try testing.expectEqual(TokenType.BooleanLiteral, tokens[2].ty);
    try testing.expectEqualStrings("true", tokens[2].lexeme);
    try expect_value(tokens, 2, .{ .Bool = true });

    try testing.expectEqual(TokenType.BooleanLiteral, tokens[4].ty);
    try expect_value(tokens, 4, .{ .Bool = false });
}

test "lookahead_assertion" {
    const gpa = testing.allocator;
    const input = "rule ::= \"a\" (= lookahead)";
    const tokens = lex(input);
    defer {
        free_tokens(gpa, tokens);
        gpa.free(tokens);
    }

    try testing.expectEqual(@as(usize, 7), tokens.len); // 6 tokens + EOF
    try testing.expectEqual(TokenType.LookaheadLParen, tokens[3].ty);
    try testing.expectEqualStrings("(=", tokens[3].lexeme);
    try testing.expectEqual(TokenType.RParen, tokens[5].ty);
}

test "line_and_column_tracking" {
    const gpa = testing.allocator;
    const input = "rule1 ::= expr1\nrule2 ::= expr2";
    const tokens = lex(input);
    defer {
        free_tokens(gpa, tokens);
        gpa.free(tokens);
    }

    try testing.expectEqual(@as(usize, 7), tokens.len); // 6 tokens + EOF

    // First line tokens
    try testing.expectEqual(@as(i32, 1), tokens[0].line);
    try testing.expectEqual(@as(i32, 1), tokens[0].column);
    try testing.expectEqual(@as(i32, 1), tokens[1].line);
    try testing.expectEqual(@as(i32, 7), tokens[1].column);
    try testing.expectEqual(@as(i32, 1), tokens[2].line);
    try testing.expectEqual(@as(i32, 11), tokens[2].column);

    // Second line tokens
    try testing.expectEqual(@as(i32, 2), tokens[3].line);
    try testing.expectEqual(@as(i32, 1), tokens[3].column);
    try testing.expectEqual(@as(i32, 2), tokens[4].line);
    try testing.expectEqual(@as(i32, 7), tokens[4].column);
    try testing.expectEqual(@as(i32, 2), tokens[5].line);
    try testing.expectEqual(@as(i32, 11), tokens[5].column);
}

test "complex_grammar" {
    const gpa = testing.allocator;
    const input = "# JSON Grammar\n" ++
        "root ::= value\n" ++
        "value ::= object | array | string | number | \"true\" | \"false\" | \"null\"\n" ++
        "object ::= \"{\" (member (\",\" member)*)? \"}\"\n" ++
        "member ::= string \":\" value\n" ++
        "array ::= \"[\" (value (\",\" value)*)? \"]\"\n" ++
        "string ::= \"\\\"\" char* \"\\\"\"\n" ++
        "char ::= [^\"\\\\] | \"\\\\\\\"\"\n" ++
        "number ::= int frac? exp?\n" ++
        "int ::= \"-\"? ([1-9] [0-9]* | \"0\")\n" ++
        "frac ::= \".\" [0-9]+\n" ++
        "exp ::= [eE] [+\\-]? [0-9]+";

    const tokens = lex(input);
    defer {
        free_tokens(gpa, tokens);
        gpa.free(tokens);
    }
    try testing.expect(tokens.len > 50);
    try testing.expectEqual(TokenType.EndOfFile, tokens[tokens.len - 1].ty);
}

test "edge_cases" {
    const gpa = testing.allocator;
    // Empty input
    {
        const tokens = lex("");
        defer {
            free_tokens(gpa, tokens);
            gpa.free(tokens);
        }
        try testing.expectEqual(@as(usize, 1), tokens.len);
        try testing.expectEqual(TokenType.EndOfFile, tokens[0].ty);
    }

    // Only whitespace and comments
    {
        const tokens = lex("  \t\n # Comment\n  # Another comment");
        defer {
            free_tokens(gpa, tokens);
            gpa.free(tokens);
        }
        try testing.expectEqual(@as(usize, 1), tokens.len);
        try testing.expectEqual(TokenType.EndOfFile, tokens[0].ty);
    }

    // Various newline formats
    {
        const tokens = lex("rule1 ::= expr1\nrule2 ::= expr2\r\nrule3 ::= expr3\rrule4 ::= expr4");
        defer {
            free_tokens(gpa, tokens);
            gpa.free(tokens);
        }
        try testing.expectEqual(@as(usize, 13), tokens.len); // 12 tokens + EOF
    }

    // Integer boundary (15 digits, the max allowed)
    {
        const tokens = lex("rule ::= 999999999999999");
        defer {
            free_tokens(gpa, tokens);
            gpa.free(tokens);
        }
        try testing.expectEqual(@as(usize, 4), tokens.len); // 3 tokens + EOF
        try testing.expectEqual(TokenType.IntegerLiteral, tokens[2].ty);
        try testing.expectEqualStrings("999999999999999", tokens[2].lexeme);
    }

    // Special identifiers
    {
        const tokens = lex("rule-name ::= _special.identifier-123");
        defer {
            free_tokens(gpa, tokens);
            gpa.free(tokens);
        }
        try testing.expectEqual(@as(usize, 4), tokens.len); // 3 tokens + EOF
        try testing.expectEqual(TokenType.RuleName, tokens[0].ty);
        try testing.expectEqualStrings("rule-name", tokens[0].lexeme);
        try testing.expectEqual(TokenType.Identifier, tokens[2].ty);
        try testing.expectEqualStrings("_special.identifier-123", tokens[2].lexeme);
    }
}

test "quantifier_tokens" {
    const gpa = testing.allocator;
    const input = "rule ::= expr? | expr* | expr+ | expr{1} | expr{1,} | expr{1,5}";
    const tokens = lex(input);
    defer {
        free_tokens(gpa, tokens);
        gpa.free(tokens);
    }

    try testing.expectEqual(TokenType.Question, tokens[3].ty);
    try testing.expectEqual(TokenType.Star, tokens[6].ty);
    try testing.expectEqual(TokenType.Plus, tokens[9].ty);
    try testing.expectEqual(TokenType.LBrace, tokens[12].ty);
    try testing.expectEqual(TokenType.IntegerLiteral, tokens[13].ty);
    try testing.expectEqual(TokenType.RBrace, tokens[14].ty);
    try testing.expectEqual(TokenType.LBrace, tokens[17].ty);
    try testing.expectEqual(TokenType.IntegerLiteral, tokens[18].ty);
    try testing.expectEqual(TokenType.Comma, tokens[19].ty);
    try testing.expectEqual(TokenType.RBrace, tokens[20].ty);
}

test "utf8_handling" {
    const gpa = testing.allocator;
    // Build the input without literal `\u`/`\U` escapes in the source, which the harness
    // would otherwise decode; the backslash is injected at runtime.
    const input = try std.fmt.allocPrint(gpa, "rule ::= \"UTF-8: \\u00A9 \\u2603 \\U0001F600\"", .{});
    defer gpa.free(input);
    const tokens = lex(input);
    defer {
        free_tokens(gpa, tokens);
        gpa.free(tokens);
    }

    try testing.expectEqual(@as(usize, 4), tokens.len); // 3 tokens + EOF
    try testing.expectEqual(TokenType.StringLiteral, tokens[2].ty);
    try expect_value(tokens, 2, .{ .Str = "UTF-8: © ☃ 😀" });
}

fn expect_lex_error(input: []const u8, needle: []const u8) !void {
    const gpa = testing.allocator;
    const message = lex_fail(input);
    defer gpa.free(message);
    if (std.mem.indexOf(u8, message, needle) == null) {
        std.debug.print("error message: {s}\n", .{message});
        return error.TestUnexpectedResult;
    }
}

test "lexer_error_cases" {
    // Unterminated string
    try expect_lex_error("rule ::= \"unterminated string", "Expect \" in string literal");

    // Unterminated character class
    try expect_lex_error("rule ::= [a-z", "Unterminated character class");

    // Unterminated character class with escaped bracket
    try expect_lex_error("rule ::= [a-z\\-\\\\\\]", "Unterminated character class");

    // Invalid escape sequence in string
    try expect_lex_error("rule ::= \"\\z\"", "Invalid escape sequence");

    // Newline in character class
    try expect_lex_error("rule ::= [a-z\n]", "Character class should not contain newline");

    // Invalid escape sequence in character class
    try expect_lex_error("rule ::= [\\z]", "Invalid escape sequence");

    // Integer too large (> 1e15)
    try expect_lex_error("rule ::= expr{1000000000000000000}", "Integer is too large");

    // Unexpected character
    try expect_lex_error("rule ::= @", "Unexpected character");

    // Unexpected colon
    try expect_lex_error("rule : expr", "Unexpected character: ':'");

    // Assign preceded by a non-identifier
    try expect_lex_error("\"string\" ::= expr", "Assign should be preceded by an identifier");

    // Assign as the first token
    try expect_lex_error("::= expr", "Assign should not be the first token");

    // Rule name not at the beginning of the line
    try expect_lex_error("token token ::= expr", "The rule name should be at the beginning of the line");
}

// ---------------------------------------------------------------------------
// EBNF parser: Regex macro flag handling (needs fsm::rewrite_regex_dots only;
// no Grammar fsm hooks, so these run unconditionally).
// ---------------------------------------------------------------------------

fn regex_expr_of(grammar: anytype) @TypeOf(grammar.expr(0)) {
    // rule body = choices -> sequence -> the single Regex element
    const choices = grammar.expr(grammar.rule(0).body_expr_id);
    const sequence = grammar.expr(choices.data[0]);
    return grammar.expr(sequence.data[0]);
}

fn regex_pattern_of(input: []const u8) []u8 {
    const gpa = testing.allocator;
    const grammar = parser.ebnf_to_grammar_no_normalization(gpa, input, "root", null) catch unreachable;
    defer grammar.deinit();
    const body = regex_expr_of(grammar);
    return body.regex_pattern(gpa) catch unreachable;
}

fn regex_pattern_fails(input: []const u8) []u8 {
    const gpa = testing.allocator;
    var diag = parser.ebnf_error.EbnfErrorInfo{ .normalization = "" };
    if (parser.ebnf_to_grammar_no_normalization(gpa, input, "root", &diag)) |_| {
        unreachable; // expected a parser failure
    } else |e| switch (e) {
        error.Parser => {
            const message = gpa.dupe(u8, diag.parser.message) catch unreachable;
            if (diag.parser.message.len > 0) gpa.free(diag.parser.message);
            return message;
        },
        else => unreachable,
    }
}

test "regex macro without flags stores the pattern verbatim" {
    const gpa = testing.allocator;
    const pattern = regex_pattern_of("root ::= Regex(\"a.c\")");
    defer gpa.free(pattern);
    try testing.expectEqualStrings("a.c", pattern);
}

test "regex macro dot-all flag keeps dots" {
    const gpa = testing.allocator;
    const pattern = regex_pattern_of("root ::= Regex(\"a.c\", flags=\"s\")");
    defer gpa.free(pattern);
    try testing.expectEqualStrings("a.c", pattern);
}

test "regex macro default dot semantics rewrite dots to not-newline" {
    const gpa = testing.allocator;
    const pattern = regex_pattern_of("root ::= Regex(\"a.c\", flags=\"i\")");
    defer gpa.free(pattern);
    try testing.expectEqualStrings("(?i)a[^\\n]c", pattern);
}

test "regex macro unicode flag alone still rewrites dots (flags presence opts in)" {
    const gpa = testing.allocator;
    const pattern = regex_pattern_of("root ::= Regex(\"a.c\", flags=\"u\")");
    defer gpa.free(pattern);
    try testing.expectEqualStrings("a[^\\n]c", pattern);
}

test "regex macro case-insensitive plus dot-all" {
    const gpa = testing.allocator;
    const pattern = regex_pattern_of("root ::= Regex(\"a.c\", flags=\"is\")");
    defer gpa.free(pattern);
    try testing.expectEqualStrings("(?i)a.c", pattern);
}

test "regex macro rejects unsupported flags" {
    const gpa = testing.allocator;
    const message = regex_pattern_fails("root ::= Regex(\"a\", flags=\"x\")");
    defer gpa.free(message);
    try testing.expect(std.mem.indexOf(u8, message, "regular-expression flag 'x' is not supported") != null);
}

test "regex macro json_string argument is honored" {
    const gpa = testing.allocator;
    const input = "root ::= Regex(\"a\", json_string=true)";
    const grammar = parser.ebnf_to_grammar_no_normalization(gpa, input, "root", null) catch unreachable;
    defer grammar.deinit();
    const body = regex_expr_of(grammar);
    try testing.expect(body.regex_is_json_string());
}

// ---------------------------------------------------------------------------
// Earley parser: the FSM runtime is wired to `Grammar.complete_fsm` /
// `Grammar.per_rule_fsms` (WaveGrammar's hooks). Until those fields are
// installed the constructor surfaces `error.FsmNotInstalled`; this suite
// un-gates automatically once they land (解除条件: 字段安装 + 编译器波提供
// optimize 后的 grammar;当前由 fsm/compiler 波的集成测试覆盖端到端路径).
// ---------------------------------------------------------------------------
test "earley parser fsm hook gate" {
    const EarleyParser = parser.EarleyParser;
    const installed = comptime parser.earley_parser.grammar_fsm_installed;
    const grammar_mod = @import("../grammar/mod.zig");
    if (!installed) {
        // Constructing a parser over a grammar without fsm hooks reports the gate.
        var builder = try grammar_mod.GrammarBuilder.new(testing.allocator);
        defer builder.deinit();
        const bs = try builder.add_byte_string("a");
        _ = try builder.add_rule_named("root", bs);
        const grammar = try builder.into_grammar_with_root_id(testing.allocator, 0);
        defer grammar.deinit();
        grammar.set_optimized(true);
        if (EarleyParser.new(testing.allocator, grammar, null)) |p| {
            p.deinit();
            return error.TestUnexpectedResult; // hooks installed but gate constant says otherwise
        } else |e| switch (e) {
            error.FsmNotInstalled => {},
            else => return e,
        }
        return;
    }
    // Hooks installed: run a real advance over an optimized grammar.
    const functor_mod = @import("../functor/mod.zig");
    var builder = try grammar_mod.GrammarBuilder.new(testing.allocator);
    defer builder.deinit();
    const bs = try builder.add_byte_string("a");
    _ = try builder.add_rule_named("root", bs);
    const grammar = try builder.into_grammar_with_root_id(testing.allocator, 0);
    defer grammar.deinit();
    const normalized = try functor_mod.grammar_normalizer(testing.allocator, grammar);
    defer normalized.deinit();
    const optimized = try functor_mod.grammar_optimizer(testing.allocator, normalized, null);
    defer optimized.deinit();
    const ep = try EarleyParser.new(testing.allocator, optimized, null);
    defer ep.deinit();
    try testing.expect(!ep.is_root_completed());
    try testing.expect(try ep.advance('a'));
    try testing.expect(ep.is_root_completed());
    try testing.expect(!try ep.advance('b'));
}
