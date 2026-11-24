//! EBNF lexing, EBNF-to-BNF parsing, and the incremental Earley parser.

const std = @import("std");

pub const ebnf_lexer = @import("parser/ebnf_lexer.zig");
pub const ebnf_parser = @import("parser/ebnf_parser.zig");
pub const earley_parser = @import("parser/EarleyParser.zig");

pub const Token = ebnf_lexer.Token;
pub const TokenType = ebnf_lexer.TokenType;
pub const TokenValue = ebnf_lexer.TokenValue;
pub const LexerError = ebnf_lexer.LexerError;
pub const tokenize = ebnf_lexer.tokenize;
pub const freeTokens = ebnf_lexer.freeTokens;

pub const RuleAttributes = ebnf_parser.RuleAttributes;
pub const MacroArguments = ebnf_parser.MacroArguments;
pub const MacroValue = ebnf_parser.MacroValue;
pub const NamedArgument = ebnf_parser.NamedArgument;
pub const EbnfError = ebnf_parser.EbnfError;
pub const ebnfToGrammarNoNormalization = ebnf_parser.ebnfToGrammarNoNormalization;

pub const EarleyParser = earley_parser.EarleyParser;
pub const EarleyError = earley_parser.EarleyError;
pub const ParserState = earley_parser.ParserState;
pub const ParserStateCacheKey = earley_parser.ParserStateCacheKey;
pub const ParserRow = earley_parser.ParserRow;
pub const CompletableState = earley_parser.CompletableState;
pub const RepeatDetector = earley_parser.RepeatDetector;
pub const CaptureEvent = earley_parser.CaptureEvent;
pub const CaptureOccurrence = earley_parser.CaptureOccurrence;

test {
    _ = ebnf_lexer;
    _ = ebnf_parser;
    _ = earley_parser;
    _ = @import("parser/parser_spec_test.zig");
    std.testing.refAllDecls(@This());
}
