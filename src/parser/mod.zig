//! EBNF lexing and parsing into the BNF AST (`mod.rs`): one dedicated type per file,
//! re-exported here.

const std = @import("std");

pub const capture_event = @import("capture_event.zig");
pub const capture_occurrence = @import("capture_occurrence.zig");
pub const earley_parser = @import("earley_parser.zig");
pub const ebnf_error = @import("ebnf_error.zig");
pub const ebnf_lexer = @import("ebnf_lexer.zig");
pub const ebnf_parser = @import("ebnf_parser.zig");
pub const lexer_error = @import("lexer_error.zig");
pub const macro_ir = @import("macro_ir.zig");
pub const parse_error = @import("parse_error.zig");
pub const parser_row = @import("parser_row.zig");
pub const parser_state = @import("parser_state.zig");
pub const parser_state_cache_key = @import("parser_state_cache_key.zig");
pub const repeat_detector = @import("repeat_detector.zig");
pub const rule_attributes = @import("rule_attributes.zig");
pub const token = @import("token.zig");
pub const token_type = @import("token_type.zig");

pub const CaptureEvent = capture_event.CaptureEvent;
pub const CaptureOccurrence = capture_occurrence.CaptureOccurrence;
pub const EarleyParser = earley_parser.EarleyParser;
pub const EbnfError = ebnf_error.EbnfError;
pub const EbnfErrorInfo = ebnf_error.EbnfErrorInfo;
pub const tokenize = ebnf_lexer.tokenize;
pub const ebnf_to_grammar_no_normalization = ebnf_parser.ebnf_to_grammar_no_normalization;
pub const LexerError = lexer_error.LexerError;
pub const MacroArguments = macro_ir.MacroArguments;
pub const MacroValue = macro_ir.MacroValue;
pub const ParserError = parse_error.ParserError;
pub const ParserRow = parser_row.ParserRow;
pub const ParserState = parser_state.ParserState;
pub const ParserStateCacheKey = parser_state_cache_key.ParserStateCacheKey;
pub const RepeatDetector = repeat_detector.RepeatDetector;
pub const RuleAttributes = rule_attributes.RuleAttributes;
pub const Token = token.Token;
pub const TokenValue = token.TokenValue;
pub const TokenType = token_type.TokenType;

test {
    _ = capture_event;
    _ = capture_occurrence;
    _ = earley_parser;
    _ = ebnf_error;
    _ = ebnf_lexer;
    _ = ebnf_parser;
    _ = lexer_error;
    _ = macro_ir;
    _ = parse_error;
    _ = parser_row;
    _ = parser_state;
    _ = parser_state_cache_key;
    _ = repeat_detector;
    _ = rule_attributes;
    _ = token;
    _ = token_type;
    _ = @import("parser_spec_test.zig");
}
