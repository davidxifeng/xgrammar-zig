//! Pure-Zig port of xgrammar-rs 0.2.8 — structured generation core (`lib.rs`).

const std = @import("std");

pub const config = @import("config.zig");
pub const support = @import("support/mod.zig");
pub const tokenizer = @import("tokenizer/mod.zig");
pub const grammar = @import("grammar/mod.zig");
pub const parser = @import("parser/mod.zig");
pub const fsm = @import("fsm/mod.zig");
pub const functor = @import("functor/mod.zig");
pub const converter = @import("converter/mod.zig");
pub const compiler = @import("compiler/mod.zig");
pub const matcher = @import("matcher/mod.zig");
pub const testing = @import("testing.zig");

/// Library version mirroring xgrammar-rs `VERSION`.
pub const VERSION = "0.2.8";
pub const version = VERSION;

// Mirror xgrammar-rs `lib.rs` root re-exports:
pub const CompileError = compiler.CompileError;
pub const CompileErrorInfo = compiler.CompileErrorInfo;
pub const CompiledGrammar = compiler.CompiledGrammar;
pub const GrammarCompiler = compiler.GrammarCompiler;
pub const JsonSchemaOptions = GrammarCompiler.JsonSchemaOptions;

pub const SERIALIZATION_VERSION = config.SERIALIZATION_VERSION;
pub const get_serialization_version = config.get_serialization_version;

pub const JsonFormat = converter.JsonFormat;
pub const RegexError = converter.RegexError;
pub const SchemaError = converter.SchemaError;
pub const SchemaErrorKind = converter.SchemaErrorKind;
pub const StructuralTagError = converter.StructuralTagError;
pub const StructuralTagItem = converter.StructuralTagItem;
pub const generate_float_range_regex = converter.generate_float_range_regex;
pub const generate_float_range_regex_with_options = converter.generate_float_range_regex_with_options;
pub const generate_range_regex = converter.generate_range_regex;
pub const json_schema_to_ebnf = converter.json_schema_to_ebnf;
pub const regex_to_ebnf = converter.regex_to_ebnf;

pub const DeserializeError = grammar.DeserializeError;
pub const Grammar = grammar.Grammar;

pub const BatchGrammarMatcher = matcher.BatchGrammarMatcher;
pub const BitmaskDlType = matcher.BitmaskDlType;
pub const GrammarMatcher = matcher.GrammarMatcher;
pub const MatcherError = matcher.MatcherError;
pub const MatcherErrorInfo = matcher.MatcherErrorInfo;
pub const TokenBitmask = matcher.TokenBitmask;
pub const allocate_token_bitmask = matcher.allocate_token_bitmask;
pub const apply_token_bitmask_inplace_cpu = matcher.apply_token_bitmask_inplace_cpu;
pub const apply_token_bitmask_inplace_cpu_batch = matcher.apply_token_bitmask_inplace_cpu_batch;
pub const get_bitmask_dl_type = matcher.get_bitmask_dl_type;
pub const get_bitmask_size = matcher.get_bitmask_size;
pub const get_masked_tokens_from_bitmask = matcher.get_masked_tokens_from_bitmask;
pub const is_single_token_bitmask = matcher.is_single_token_bitmask;
pub const reset_token_bitmask = matcher.reset_token_bitmask;

pub const AutoLruCache = support.AutoLruCache;
pub const LruCache = support.LruCache;
pub const RecursionError = support.RecursionError;
pub const getMaxRecursionDepth = support.getMaxRecursionDepth;
pub const get_max_recursion_depth = support.get_max_recursion_depth;
pub const resetRecursionDepth = support.resetRecursionDepth;
pub const reset_recursion_depth = support.reset_recursion_depth;
pub const setMaxRecursionDepth = support.setMaxRecursionDepth;
pub const set_max_recursion_depth = support.set_max_recursion_depth;

pub const print_token_by_ids = testing.print_token_by_ids;

pub const HfMetadata = tokenizer.HfMetadata;
pub const TokenizerError = tokenizer.TokenizerError;
pub const TokenizerInfo = tokenizer.TokenizerInfo;
pub const UnknownVocabType = tokenizer.UnknownVocabType;
pub const VocabType = tokenizer.VocabType;
pub const decode_token = tokenizer.decode_token;
pub const decode_token_bytes = tokenizer.decode_token_bytes;
pub const detect_metadata_from_hf = tokenizer.detect_metadata_from_hf;

// --- High-level Zig-idiomatic grammar constructors ---

pub fn parseEbnf(
    allocator: std.mem.Allocator,
    ebnf_str: []const u8,
    root_rule_name: []const u8,
) (std.mem.Allocator.Error || parser.EbnfError || functor.FunctorError)!*Grammar {
    return functor.grammar_normalizer_mod.from_ebnf(allocator, ebnf_str, root_rule_name, null);
}

pub fn builtinJsonGrammar(allocator: std.mem.Allocator) std.mem.Allocator.Error!*Grammar {
    return functor.grammar_normalizer_mod.builtin_json_grammar(allocator);
}

pub fn fromJsonSchema(
    allocator: std.mem.Allocator,
    schema: []const u8,
    options: JsonSchemaOptions,
) SchemaError!*Grammar {
    return converter.from_json_schema_with_any_order(
        allocator,
        schema,
        options.any_whitespace,
        options.indent,
        options.separators,
        options.strict_mode,
        options.max_whitespace_cnt,
        options.any_order,
        null,
    );
}

pub fn fromRegex(allocator: std.mem.Allocator, regex_str: []const u8) RegexError!*Grammar {
    return converter.from_regex(allocator, regex_str, null);
}

pub fn fromLark(
    allocator: std.mem.Allocator,
    lark_str: []const u8,
    tokenizer_info: ?*const TokenizerInfo,
    named_grammars: []const converter.NamedGrammar,
) converter.LarkError!*Grammar {
    return converter.from_lark(allocator, lark_str, tokenizer_info, named_grammars, null);
}

pub fn fromStructuralTag(allocator: std.mem.Allocator, json: []const u8) StructuralTagError!*Grammar {
    return converter.from_structural_tag(allocator, json, null);
}

test {
    _ = config;
    _ = support;
    _ = tokenizer;
    _ = grammar;
    _ = parser;
    _ = fsm;
    _ = functor;
    _ = converter;
    _ = compiler;
    _ = matcher;
    _ = testing;
    _ = @import("tests.zig");
}
