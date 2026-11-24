//! Port of `external/xgrammar/tests/cpp/test_parser.cc` (the `XGrammarLexerTest` suite),
//! plus EBNF parser macro/flag specs and Earley parser smoke tests.
//!
//! The two "invalid UTF-8 byte sequence" sub-cases of `lexer_error_cases` are omitted (as in
//! the Rust port): the safe `tokenize` API is given valid UTF-8 input, so that error path is
//! unreachable through the public API.

const std = @import("std");
const testing = std.testing;

const Diagnostic = @import("../Diagnostic.zig").Diagnostic;
const fsm_mod = @import("../fsm.zig");
const grammar_mod = @import("../grammar.zig");
const parser = @import("../parser.zig");

const Token = parser.Token;
const TokenValue = parser.TokenValue;
const TokenType = parser.TokenType;
const freeTokens = parser.freeTokens;

fn lex(input: []const u8) []Token {
    const gpa = testing.allocator;
    var list = parser.tokenize(gpa, input, null) catch unreachable;
    return list.toOwnedSlice(gpa) catch unreachable;
}

fn lexFail(input: []const u8) []u8 {
    const gpa = testing.allocator;
    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);
    if (parser.tokenize(gpa, input, &diag)) |_| {
        unreachable; // expected a lexer failure
    } else |e| switch (e) {
        error.Lexer => {
            std.debug.assert(diag.kind == .ebnf_lexer);
            return diag.formatAlloc(gpa) catch unreachable;
        },
        error.OutOfMemory => unreachable,
    }
}

fn cp(c: u21) TokenValue {
    return .{ .Codepoint = @intCast(c) };
}

fn expectValue(tokens: []Token, i: usize, expected: TokenValue) !void {
    try testing.expect(tokens[i].value.eql(expected));
}

test "basic_tokenization" {
    const gpa = testing.allocator;
    const input = "rule1 ::= \"string\" | [a-z] | 123 | (expr) | {1,3} | * | + | ? | true | false";
    const tokens = lex(input);
    defer {
        freeTokens(gpa, tokens);
        gpa.free(tokens);
    }
    try testing.expectEqual(@as(usize, 32), tokens.len); // 31 tokens + EOF

    try testing.expectEqual(TokenType.RuleName, tokens[0].ty);
    try testing.expectEqualStrings("rule1", tokens[0].lexeme);

    try testing.expectEqual(TokenType.Assign, tokens[1].ty);
    try testing.expectEqualStrings("::=", tokens[1].lexeme);

    try testing.expectEqual(TokenType.StringLiteral, tokens[2].ty);
    try testing.expectEqualStrings("\"string\"", tokens[2].lexeme);
    try expectValue(tokens, 2, .{ .Str = "string" });

    try testing.expectEqual(TokenType.Pipe, tokens[3].ty);

    try testing.expectEqual(TokenType.LBracket, tokens[4].ty);
    try testing.expectEqual(TokenType.CharInCharClass, tokens[5].ty);
    try testing.expectEqualStrings("a", tokens[5].lexeme);
    try expectValue(tokens, 5, cp('a'));
    try testing.expectEqual(TokenType.Dash, tokens[6].ty);
    try testing.expectEqual(TokenType.CharInCharClass, tokens[7].ty);
    try testing.expectEqualStrings("z", tokens[7].lexeme);
    try expectValue(tokens, 7, cp('z'));
    try testing.expectEqual(TokenType.RBracket, tokens[8].ty);

    try testing.expectEqual(TokenType.Pipe, tokens[9].ty);

    try testing.expectEqual(TokenType.IntegerLiteral, tokens[10].ty);
    try testing.expectEqualStrings("123", tokens[10].lexeme);
    try expectValue(tokens, 10, .{ .Int = 123 });

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
    try expectValue(tokens, 28, .{ .Bool = true });

    try testing.expectEqual(TokenType.Pipe, tokens[29].ty);

    try testing.expectEqual(TokenType.BooleanLiteral, tokens[30].ty);
    try expectValue(tokens, 30, .{ .Bool = false });

    try testing.expectEqual(TokenType.EndOfFile, tokens[31].ty);
}

test "comments_and_whitespace" {
    const gpa = testing.allocator;
    const input = "rule1 ::= expr1 # This is a comment\n  | expr2 # Another comment";
    const tokens = lex(input);
    defer {
        freeTokens(gpa, tokens);
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
        freeTokens(gpa, tokens);
        gpa.free(tokens);
    }

    try testing.expectEqual(@as(usize, 8), tokens.len); // 7 tokens + EOF
    try testing.expectEqual(TokenType.StringLiteral, tokens[2].ty);
    try expectValue(tokens, 2, .{ .Str = "normal string" });

    try testing.expectEqual(TokenType.StringLiteral, tokens[4].ty);
    try expectValue(tokens, 4, .{ .Str = "escaped \"quotes\"" });

    try testing.expectEqual(TokenType.StringLiteral, tokens[6].ty);
    try expectValue(tokens, 6, .{ .Str = "\n\r\t\\" });
}

test "character_classes" {
    const gpa = testing.allocator;
    const input = "rule ::= [a-z] | [0-9] | [^a-z] | [\\-\\]\\\\] | [\\u0041-\\u005A] | [测试] | " ++
        "[\\t\\r\\n] | [\\b\\f]";
    const tokens = lex(input);
    defer {
        freeTokens(gpa, tokens);
        gpa.free(tokens);
    }

    try testing.expectEqual(@as(usize, 49), tokens.len); // 48 tokens + EOF

    // [a-z]
    try testing.expectEqual(TokenType.LBracket, tokens[2].ty);
    try testing.expectEqual(TokenType.CharInCharClass, tokens[3].ty);
    try testing.expectEqualStrings("a", tokens[3].lexeme);
    try expectValue(tokens, 3, cp('a'));
    try testing.expectEqual(TokenType.Dash, tokens[4].ty);
    try testing.expectEqual(TokenType.CharInCharClass, tokens[5].ty);
    try testing.expectEqualStrings("z", tokens[5].lexeme);
    try expectValue(tokens, 5, cp('z'));
    try testing.expectEqual(TokenType.RBracket, tokens[6].ty);

    try testing.expectEqual(TokenType.Pipe, tokens[7].ty);

    // [0-9]
    try testing.expectEqual(TokenType.LBracket, tokens[8].ty);
    try expectValue(tokens, 9, cp('0'));
    try testing.expectEqual(TokenType.Dash, tokens[10].ty);
    try expectValue(tokens, 11, cp('9'));
    try testing.expectEqual(TokenType.RBracket, tokens[12].ty);

    try testing.expectEqual(TokenType.Pipe, tokens[13].ty);

    // [^a-z]
    try testing.expectEqual(TokenType.LBracket, tokens[14].ty);
    try testing.expectEqual(TokenType.Caret, tokens[15].ty);
    try expectValue(tokens, 16, cp('a'));
    try testing.expectEqual(TokenType.Dash, tokens[17].ty);
    try expectValue(tokens, 18, cp('z'));
    try testing.expectEqual(TokenType.RBracket, tokens[19].ty);

    try testing.expectEqual(TokenType.Pipe, tokens[20].ty);

    // [\-\]\\]
    try testing.expectEqual(TokenType.LBracket, tokens[21].ty);
    try testing.expectEqual(TokenType.CharInCharClass, tokens[22].ty);
    try testing.expectEqualStrings("\\-", tokens[22].lexeme);
    try expectValue(tokens, 22, cp('-'));
    try testing.expectEqualStrings("\\]", tokens[23].lexeme);
    try expectValue(tokens, 23, cp(']'));
    try testing.expectEqualStrings("\\\\", tokens[24].lexeme);
    try expectValue(tokens, 24, cp('\\'));
    try testing.expectEqual(TokenType.RBracket, tokens[25].ty);

    try testing.expectEqual(TokenType.Pipe, tokens[26].ty);

    // [A-Z]
    try testing.expectEqual(TokenType.LBracket, tokens[27].ty);
    try testing.expectEqualStrings("\\u0041", tokens[28].lexeme);
    try expectValue(tokens, 28, .{ .Codepoint = 0x41 });
    try testing.expectEqual(TokenType.Dash, tokens[29].ty);
    try testing.expectEqualStrings("\\u005A", tokens[30].lexeme);
    try expectValue(tokens, 30, .{ .Codepoint = 0x5A });
    try testing.expectEqual(TokenType.RBracket, tokens[31].ty);

    try testing.expectEqual(TokenType.Pipe, tokens[32].ty);

    // [测试]
    try testing.expectEqual(TokenType.LBracket, tokens[33].ty);
    try testing.expectEqualStrings("测", tokens[34].lexeme);
    try expectValue(tokens, 34, .{ .Codepoint = 0x6D4B });
    try testing.expectEqualStrings("试", tokens[35].lexeme);
    try expectValue(tokens, 35, .{ .Codepoint = 0x8BD5 });
    try testing.expectEqual(TokenType.RBracket, tokens[36].ty);

    try testing.expectEqual(TokenType.Pipe, tokens[37].ty);

    // [\t\r\n]
    try testing.expectEqual(TokenType.LBracket, tokens[38].ty);
    try testing.expectEqualStrings("\\t", tokens[39].lexeme);
    try expectValue(tokens, 39, cp('\t'));
    try testing.expectEqualStrings("\\r", tokens[40].lexeme);
    try expectValue(tokens, 40, cp('\r'));
    try testing.expectEqualStrings("\\n", tokens[41].lexeme);
    try expectValue(tokens, 41, cp('\n'));
    try testing.expectEqual(TokenType.RBracket, tokens[42].ty);

    try testing.expectEqual(TokenType.Pipe, tokens[43].ty);

    // [\b\f]
    try testing.expectEqual(TokenType.LBracket, tokens[44].ty);
    try testing.expectEqualStrings("\\b", tokens[45].lexeme);
    try expectValue(tokens, 45, .{ .Codepoint = 0x08 });
    try testing.expectEqualStrings("\\f", tokens[46].lexeme);
    try expectValue(tokens, 46, .{ .Codepoint = 0x0C });
    try testing.expectEqual(TokenType.RBracket, tokens[47].ty);
}

test "boolean_values" {
    const gpa = testing.allocator;
    const input = "rule ::= true | false";
    const tokens = lex(input);
    defer {
        freeTokens(gpa, tokens);
        gpa.free(tokens);
    }

    try testing.expectEqual(@as(usize, 6), tokens.len); // 5 tokens + EOF
    try testing.expectEqual(TokenType.BooleanLiteral, tokens[2].ty);
    try testing.expectEqualStrings("true", tokens[2].lexeme);
    try expectValue(tokens, 2, .{ .Bool = true });

    try testing.expectEqual(TokenType.BooleanLiteral, tokens[4].ty);
    try expectValue(tokens, 4, .{ .Bool = false });
}

test "lookahead_assertion" {
    const gpa = testing.allocator;
    const input = "rule ::= \"a\" (= lookahead)";
    const tokens = lex(input);
    defer {
        freeTokens(gpa, tokens);
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
        freeTokens(gpa, tokens);
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
        freeTokens(gpa, tokens);
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
            freeTokens(gpa, tokens);
            gpa.free(tokens);
        }
        try testing.expectEqual(@as(usize, 1), tokens.len);
        try testing.expectEqual(TokenType.EndOfFile, tokens[0].ty);
    }

    // Only whitespace and comments
    {
        const tokens = lex("  \t\n # Comment\n  # Another comment");
        defer {
            freeTokens(gpa, tokens);
            gpa.free(tokens);
        }
        try testing.expectEqual(@as(usize, 1), tokens.len);
        try testing.expectEqual(TokenType.EndOfFile, tokens[0].ty);
    }

    // Various newline formats
    {
        const tokens = lex("rule1 ::= expr1\nrule2 ::= expr2\r\nrule3 ::= expr3\rrule4 ::= expr4");
        defer {
            freeTokens(gpa, tokens);
            gpa.free(tokens);
        }
        try testing.expectEqual(@as(usize, 13), tokens.len); // 12 tokens + EOF
    }

    // Integer boundary (15 digits, the max allowed)
    {
        const tokens = lex("rule ::= 999999999999999");
        defer {
            freeTokens(gpa, tokens);
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
            freeTokens(gpa, tokens);
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
        freeTokens(gpa, tokens);
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
        freeTokens(gpa, tokens);
        gpa.free(tokens);
    }

    try testing.expectEqual(@as(usize, 4), tokens.len); // 3 tokens + EOF
    try testing.expectEqual(TokenType.StringLiteral, tokens[2].ty);
    try expectValue(tokens, 2, .{ .Str = "UTF-8: © ☃ 😀" });
}

fn expectLexError(input: []const u8, needle: []const u8) !void {
    const gpa = testing.allocator;
    const message = lexFail(input);
    defer gpa.free(message);
    if (std.mem.indexOf(u8, message, needle) == null) {
        std.debug.print("error message: {s}\n", .{message});
        return error.TestUnexpectedResult;
    }
}

test "lexer_error_cases" {
    // Unterminated string
    try expectLexError("rule ::= \"unterminated string", "Expect \" in string literal");

    // Unterminated character class
    try expectLexError("rule ::= [a-z", "Unterminated character class");

    // Unterminated character class with escaped bracket
    try expectLexError("rule ::= [a-z\\-\\\\\\]", "Unterminated character class");

    // Invalid escape sequence in string
    try expectLexError("rule ::= \"\\z\"", "Invalid escape sequence");

    // Newline in character class
    try expectLexError("rule ::= [a-z\n]", "Character class should not contain newline");

    // Invalid escape sequence in character class
    try expectLexError("rule ::= [\\z]", "Invalid escape sequence");

    // Integer too large (> 1e15)
    try expectLexError("rule ::= expr{1000000000000000000}", "Integer is too large");

    // Unexpected character
    try expectLexError("rule ::= @", "Unexpected character");

    // Unexpected colon
    try expectLexError("rule : expr", "Unexpected character: ':'");

    // Assign preceded by a non-identifier
    try expectLexError("\"string\" ::= expr", "Assign should be preceded by an identifier");

    // Assign as the first token
    try expectLexError("::= expr", "Assign should not be the first token");

    // Rule name not at the beginning of the line
    try expectLexError("token token ::= expr", "The rule name should be at the beginning of the line");
}

// ---------------------------------------------------------------------------
// EBNF parser: Regex macro flag handling & macros
// ---------------------------------------------------------------------------

fn regexExprOf(grammar: *const grammar_mod.Grammar) grammar_mod.GrammarExpr {
    // rule body = choices -> sequence -> the single Regex element
    const choices = grammar.expr(grammar.rule(0).body_expr_id);
    const sequence = grammar.expr(choices.data[0]);
    return grammar.expr(sequence.data[0]);
}

fn regexPatternOf(input: []const u8) []u8 {
    const gpa = testing.allocator;
    var grammar = parser.ebnfToGrammarNoNormalization(gpa, input, "root", null) catch unreachable;
    defer grammar.deinit();
    const body = regexExprOf(&grammar);
    return body.regexPattern(gpa) catch unreachable;
}

fn regexPatternFails(input: []const u8) []u8 {
    const gpa = testing.allocator;
    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);
    if (parser.ebnfToGrammarNoNormalization(gpa, input, "root", &diag)) |_| {
        unreachable; // expected a parser failure
    } else |e| switch (e) {
        error.Parser => {
            std.debug.assert(diag.kind == .ebnf_parser);
            return diag.formatAlloc(gpa) catch unreachable;
        },
        else => unreachable,
    }
}

test "regex macro without flags stores the pattern verbatim" {
    const gpa = testing.allocator;
    const pattern = regexPatternOf("root ::= Regex(\"a.c\")");
    defer gpa.free(pattern);
    try testing.expectEqualStrings("a.c", pattern);
}

test "regex macro dot-all flag keeps dots" {
    const gpa = testing.allocator;
    const pattern = regexPatternOf("root ::= Regex(\"a.c\", flags=\"s\")");
    defer gpa.free(pattern);
    try testing.expectEqualStrings("a.c", pattern);
}

test "regex macro default dot semantics rewrite dots to not-newline" {
    const gpa = testing.allocator;
    const pattern = regexPatternOf("root ::= Regex(\"a.c\", flags=\"i\")");
    defer gpa.free(pattern);
    try testing.expectEqualStrings("(?i)a[^\\n]c", pattern);
}

test "regex macro unicode flag alone still rewrites dots (flags presence opts in)" {
    const gpa = testing.allocator;
    const pattern = regexPatternOf("root ::= Regex(\"a.c\", flags=\"u\")");
    defer gpa.free(pattern);
    try testing.expectEqualStrings("a[^\\n]c", pattern);
}

test "regex macro case-insensitive plus dot-all" {
    const gpa = testing.allocator;
    const pattern = regexPatternOf("root ::= Regex(\"a.c\", flags=\"is\")");
    defer gpa.free(pattern);
    try testing.expectEqualStrings("(?i)a.c", pattern);
}

test "regex macro rejects unsupported flags" {
    const gpa = testing.allocator;
    const message = regexPatternFails("root ::= Regex(\"a\", flags=\"x\")");
    defer gpa.free(message);
    try testing.expect(std.mem.indexOf(u8, message, "regular-expression flag 'x' is not supported") != null);
}

test "regex macro json_string argument is honored" {
    const gpa = testing.allocator;
    const input = "root ::= Regex(\"a\", json_string=true)";
    var grammar = parser.ebnfToGrammarNoNormalization(gpa, input, "root", null) catch unreachable;
    defer grammar.deinit();
    const body = regexExprOf(&grammar);
    try testing.expect(body.regexIsJsonString());
}

test "earley parser advances on optimized grammar" {
    const EarleyParser = parser.EarleyParser;
    const Fsm = fsm_mod.Fsm;
    const CompactFsm = fsm_mod.CompactFsm;
    const CompactFsmWithStartEnd = fsm_mod.CompactFsmWithStartEnd;
    const CompactFsmWithStartEndWithSize = fsm_mod.CompactFsmWithStartEndWithSize;

    var builder = try grammar_mod.GrammarBuilder.init(testing.allocator);
    defer builder.deinit();
    const bs = try builder.addByteString("a");
    _ = try builder.addRuleNamed("root", bs);
    var grammar = try builder.intoGrammarWithRootId(0);
    defer grammar.deinit();

    var f = try Fsm.init(testing.allocator, 2);
    defer f.deinit();
    try f.addEdge(0, 1, 'a', 'a');
    var complete = try CompactFsm.fromFsm(testing.allocator, &f);
    defer complete.deinit();

    var view = try CompactFsmWithStartEnd.init(testing.allocator, complete.retain(), 0, &.{1}, true);
    defer view.deinit();
    var sized = CompactFsmWithStartEndWithSize.init(try view.cloneWithShared(testing.allocator), 1, 2);
    defer sized.deinit();

    try grammar.setFsms(complete, &.{sized});
    grammar.setOptimized(true);

    var ep = try EarleyParser.init(testing.allocator, &grammar, null);
    defer ep.deinit();
    try testing.expect(!ep.isRootCompleted());
    try testing.expect(try ep.advance('a'));
    try testing.expect(ep.isRootCompleted());
    try testing.expect(!try ep.advance('b'));
}

test "ebnf parser macros, quantifiers, diagnostics, and OOM safety" {
    const gpa = testing.allocator;
    const src =
        \\a ::= "x"+ | "y"? | [0-9]* | ("z" | "w")*
        \\b ::= a{2} | a{1, 3} | a{2, -1}
        \\td ::= TagDispatch(("<a>", a), ("<b>", b), loop_after_dispatch=false, excludes=("c"))
        \\tok ::= Token(3, 1, 3) | ExcludeToken(5, 2)
        \\ttd ::= TokenTagDispatch((7, a), loop_after_dispatch=true, excludes=(9,))
        \\sub ::= Substring("hello", "world")
        \\root ::= (td | tok | ttd | sub) (= "end")
    ;
    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);
    var g = try parser.ebnfToGrammarNoNormalization(gpa, src, "root", &diag);
    defer g.deinit();
    try testing.expectEqualStrings("root", g.rootRule().name);
    try testing.expect(g.rootRule().lookahead_assertion_id != grammar_mod.NO_EXPR);

    const err_cases = [_]struct { ebnf: []const u8, needle: []const u8 }{
        .{ .ebnf = "root ::= undef", .needle = "Rule \"undef\" is not defined" },
        .{ .ebnf = "root ::= \"a\"\nroot ::= \"b\"", .needle = "Rule \"root\" is defined multiple times" },
        .{ .ebnf = "root ::= [z-a]", .needle = "lower bound is larger than upper bound" },
        .{ .ebnf = "root ::= \"a\"{5, 2}", .needle = "Lower bound is larger than upper bound" },
        .{ .ebnf = "root ::= TagDispatch((\"\", root))", .needle = "Tag must be a non-empty string literal" },
        .{ .ebnf = "root ::= Token()", .needle = "Token() requires at least one integer argument" },
        .{ .ebnf = "root ::= ExcludeToken(foo=1)", .needle = "ExcludeToken() does not accept named arguments" },
        .{ .ebnf = "root ::= Substring(1)", .needle = "Substring() arguments must be strings" },
    };
    for (err_cases) |tc| {
        const msg = regexPatternFails(tc.ebnf);
        defer gpa.free(msg);
        try testing.expect(std.mem.indexOf(u8, msg, tc.needle) != null);
    }

    const check_oom = struct {
        fn run(alloc: std.mem.Allocator) !void {
            var d: Diagnostic = .{};
            defer d.deinit(alloc);
            var parsed = parser.ebnfToGrammarNoNormalization(
                alloc,
                "a[capture=\"x\", max_chars=5] ::= [a-z]+\nroot ::= TagDispatch((\"k\", a))",
                "root",
                &d,
            ) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return,
            };
            parsed.deinit();
        }
    }.run;
    try testing.checkAllAllocationFailures(gpa, check_oom, .{});
}

test "earley parser captures, budgets, atomic tokens, IR lookahead, and resetWithInitialState" {
    const gpa = testing.allocator;
    const EarleyParser = parser.EarleyParser;
    const ParserState = parser.ParserState;
    const Fsm = fsm_mod.Fsm;
    const CompactFsm = fsm_mod.CompactFsm;
    const CompactFsmWithStartEnd = fsm_mod.CompactFsmWithStartEnd;
    const CompactFsmWithStartEndWithSize = fsm_mod.CompactFsmWithStartEndWithSize;

    var builder = try grammar_mod.GrammarBuilder.init(gpa);
    defer builder.deinit();
    // Rule 0: root -> rule_ref(1)
    // Rule 1: cap[capture="cap", max_chars=2, max_tokens=2] -> "ab"
    // Rule 2: tok_rule -> Token(10)
    // Rule 3: la_holder -> IR sequence ("xy" [α-ω]) for IR-path testing
    const bs_ab = try builder.addByteString("ab");
    const r_cap = try builder.addRuleNamed("cap", bs_ab);
    try builder.updateCaptureName(r_cap, "cap");
    builder.updateMaxChars(r_cap, 2);
    builder.updateMaxTokens(r_cap, 2);

    const ref_cap = try builder.addRuleRef(r_cap);
    const r_root = try builder.addRuleNamed("root", ref_cap);

    const tok_expr = try builder.addTokenSet(&.{10});
    const r_tok = try builder.addRuleNamed("tok", tok_expr);

    const ir_bs = try builder.addByteString("xy");
    const ir_cc = try builder.addCharacterClass(&.{grammar_mod.CharacterClassElement.init('α', 'ω')}, false);
    const ir_seq = try builder.addSequence(&.{ ir_bs, ir_cc });

    var grammar = try builder.intoGrammarWithRootId(r_root);
    defer grammar.deinit();

    var f = try Fsm.init(gpa, 7);
    defer f.deinit();
    try f.addEdge(0, 1, 'a', 'a');
    try f.addEdge(1, 2, 'b', 'b');
    try f.addRuleEdge(3, 4, r_cap);
    // Token edge on state 5 -> 6 for token_id = 10
    try f.addTokenEdge(5, 6, &.{10});

    var complete = try CompactFsm.fromFsm(gpa, &f);
    defer complete.deinit();

    var v_cap = try CompactFsmWithStartEnd.init(gpa, complete.retain(), 0, &.{2}, true);
    defer v_cap.deinit();
    var s_cap = CompactFsmWithStartEndWithSize.init(try v_cap.cloneWithShared(gpa), 2, 3);
    defer s_cap.deinit();

    var v_root = try CompactFsmWithStartEnd.init(gpa, complete.retain(), 3, &.{4}, false);
    defer v_root.deinit();
    var s_root = CompactFsmWithStartEndWithSize.init(try v_root.cloneWithShared(gpa), 1, 2);
    defer s_root.deinit();

    var v_tok = try CompactFsmWithStartEnd.init(gpa, complete.retain(), 5, &.{6}, true);
    defer v_tok.deinit();
    var s_tok = CompactFsmWithStartEndWithSize.init(try v_tok.cloneWithShared(gpa), 1, 2);
    defer s_tok.deinit();

    try grammar.setFsms(complete, &.{ s_cap, s_root, s_tok });
    grammar.setOptimized(true);

    var ep = try EarleyParser.init(gpa, &grammar, null);
    defer ep.deinit();
    ep.capture_recording = true;
    try testing.expect(try ep.advance('a'));
    try testing.expect(try ep.advance('b'));
    try testing.expect(ep.isRootCompleted());
    try testing.expectEqual(@as(i32, 2), ep.currentCharIndex());
    try testing.expect(ep.hasEnteredCharBudget());
    try testing.expectEqual(@as(usize, 1), ep.capture_event_history.back().len);

    // Pop and re-advance
    ep.popLastStates(1);
    try testing.expect(!ep.isRootCompleted());
    try testing.expect(try ep.advance('b'));
    try testing.expect(ep.isRootCompleted());

    // Reset with atomic token rule initial state
    const tok_init = ParserState.init(r_tok, grammar.rule(r_tok).body_expr_id, 5, ParserState.NO_PREV_INPUT_POS);
    try ep.resetWithInitialState(tok_init);
    try testing.expect(!try ep.advanceAtomicToken(99, 1));
    try testing.expect(try ep.advanceAtomicToken(10, 1));
    try testing.expect(ep.isRootCompleted());

    // Reset with IR lookahead sequence ("xy" followed by UTF-8 'β')
    const ir_init = ParserState.init(-1, ir_seq, 0, ParserState.NO_PREV_INPUT_POS);
    try ep.resetWithInitialState(ir_init);
    try testing.expect(try ep.advance('x'));
    try testing.expect(try ep.advance('y'));
    try testing.expect(try ep.advance(0xCE));
    try testing.expect(try ep.advance(0xB2)); // UTF-8 'β' (U+03B2)
    try testing.expect(ep.isRootCompleted());

    const check_oom = struct {
        fn run(alloc: std.mem.Allocator, g: *const grammar_mod.Grammar, tok_state: ParserState) !void {
            var p = try EarleyParser.init(alloc, g, null);
            defer p.deinit();
            p.capture_recording = true;
            _ = try p.advance('a');
            _ = try p.advance('b');
            var p2 = try p.dupe(alloc);
            defer p2.deinit();
            try p2.resetWithInitialState(tok_state);
            _ = try p2.advanceAtomicToken(10, 1);
        }
    }.run;
    try testing.checkAllAllocationFailures(gpa, check_oom, .{ &grammar, tok_init });
}
