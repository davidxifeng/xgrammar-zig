//! External schema converters: regular expressions, numeric range regexes,
//! JSON Schema (plain JSON + 8 XML tool-calling formats), Lark grammars,
//! and structural tags.

const std = @import("std");

pub const range_regex = @import("converter/range_regex.zig");
pub const regex_mod = @import("converter/regex.zig");
pub const utf8_range_collapser = @import("converter/utf8_range_collapser.zig");

pub const json_schema_spec = @import("converter/json_schema/spec.zig");
pub const json_schema_parser = @import("converter/json_schema/parser.zig");
pub const json_schema_generator = @import("converter/json_schema/generator.zig");
pub const json_schema_xml = @import("converter/json_schema/xml.zig");
pub const json_schema_xml_cohere = @import("converter/json_schema/xml_cohere.zig");
pub const json_schema_xml_minimax = @import("converter/json_schema/xml_minimax.zig");
pub const json_schema = @import("converter/json_schema/converter.zig");

pub const lark_ast = @import("converter/lark/ast.zig");
pub const lark_lexer = @import("converter/lark/lexer.zig");
pub const lark_parser = @import("converter/lark/parser.zig");
pub const lark = @import("converter/lark/compiler.zig");

pub const structural_tag_format = @import("converter/structural_tag/format.zig");
pub const structural_tag_parser = @import("converter/structural_tag/parser.zig");
pub const structural_tag = @import("converter/structural_tag/converter.zig");

// Numeric range regex utilities
pub const FloatRangeOptions = range_regex.FloatRangeOptions;
pub const generateRangeRegex = range_regex.generateRangeRegex;
pub const generateFloatRangeRegex = range_regex.generateFloatRangeRegex;
pub const generateFloatRangeRegexWithOptions = range_regex.generateFloatRangeRegexWithOptions;

// Regex converter
pub const RegexError = regex_mod.RegexError;
pub const regexToEbnf = regex_mod.regexToEbnf;
pub const fromRegex = regex_mod.fromRegex;
pub const fromRegexWithOptions = regex_mod.fromRegexWithOptions;

// JSON Schema + XML tool-calling converter
pub const JsonFormat = json_schema_spec.JsonFormat;
pub const SchemaError = json_schema_parser.SchemaError;
pub const Separators = json_schema.Separators;
pub const JsonSchemaOptions = json_schema.JsonSchemaOptions;
pub const jsonSchemaToEbnf = json_schema.jsonSchemaToEbnf;
pub const jsonSchemaToGrammar = json_schema.jsonSchemaToGrammar;
pub const fromJsonSchema = json_schema.fromJsonSchema;

// Lark converter
pub const LarkError = lark_ast.LarkError;
pub const NamedGrammar = lark_ast.NamedGrammar;
pub const NamedGrammarRegistry = lark_ast.NamedGrammarRegistry;
pub const fromLark = lark.fromLark;

// Structural-tag converter
pub const StructuralTagError = structural_tag_parser.StructuralTagError;
pub const StructuralTagItem = structural_tag_format.StructuralTagItem;
pub const fromStructuralTag = structural_tag.fromStructuralTag;
pub const fromStructuralTagWithTokenizer = structural_tag.fromStructuralTagWithTokenizer;

test {
    _ = range_regex;
    _ = regex_mod;
    _ = utf8_range_collapser;
    _ = json_schema_spec;
    _ = json_schema_parser;
    _ = json_schema_generator;
    _ = json_schema_xml;
    _ = json_schema_xml_cohere;
    _ = json_schema_xml_minimax;
    _ = json_schema;
    _ = lark_ast;
    _ = lark_lexer;
    _ = lark_parser;
    _ = lark;
    _ = structural_tag_format;
    _ = structural_tag_parser;
    _ = structural_tag;
    _ = @import("converter/spec_test.zig");
    _ = @import("converter/lark_spec_test.zig");
    std.testing.refAllDecls(@This());
}
