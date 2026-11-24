//! Pure-Zig port of xgrammar-rs 0.2.8 — structured generation core.

const std = @import("std");

/// Library version mirroring xgrammar-rs `VERSION`.
pub const version = "0.2.8";

/// Internal subsystem namespaces exposed for advanced integrations and regression suites.
pub const internal = struct {
    pub const config = @import("config.zig");
    pub const support = @import("support.zig");
    pub const tokenizer = @import("tokenizer.zig");
    pub const fsm = @import("fsm.zig");
    pub const grammar = @import("grammar.zig");
    pub const parser = @import("parser.zig");
    pub const functor = @import("functor.zig");
    pub const converter = @import("converter.zig");
    pub const compiler = @import("compiler.zig");
    pub const matcher = @import("matcher.zig");
};

// Serialization metadata & unified diagnostics
pub const serialization_version = internal.config.serialization_version;
pub const getSerializationVersion = internal.config.getSerializationVersion;
pub const Diagnostic = @import("Diagnostic.zig").Diagnostic;

// Tokenizer types & helpers
pub const VocabType = internal.tokenizer.VocabType;
pub const HfMetadata = internal.tokenizer.HfMetadata;
pub const TokenizerInfo = internal.tokenizer.TokenizerInfo;
pub const TokenizerError = internal.tokenizer.TokenizerError;
pub const detectMetadataFromHf = internal.tokenizer.detectMetadataFromHf;
pub const decodeToken = internal.tokenizer.decodeToken;
pub const decodeTokenBytes = internal.tokenizer.decodeTokenBytes;

// Grammar AST, constructors & serialization
pub const Grammar = internal.grammar.Grammar;
pub const DeserializeError = internal.grammar.DeserializeError;

// External schema converters (JSON Schema, regex, ranges, Lark, structural tags)
pub const JsonFormat = internal.converter.JsonFormat;
pub const Separators = internal.converter.Separators;
pub const JsonSchemaOptions = internal.converter.JsonSchemaOptions;
pub const FloatRangeOptions = internal.converter.FloatRangeOptions;
pub const StructuralTagItem = internal.converter.StructuralTagItem;
pub const NamedGrammar = internal.converter.NamedGrammar;
pub const SchemaError = internal.converter.SchemaError;
pub const RegexError = internal.converter.RegexError;
pub const LarkError = internal.converter.LarkError;
pub const StructuralTagError = internal.converter.StructuralTagError;
pub const jsonSchemaToEbnf = internal.converter.jsonSchemaToEbnf;
pub const regexToEbnf = internal.converter.regexToEbnf;
pub const generateRangeRegex = internal.converter.generateRangeRegex;
pub const generateFloatRangeRegex = internal.converter.generateFloatRangeRegex;
pub const generateFloatRangeRegexWithOptions = internal.converter.generateFloatRangeRegexWithOptions;

// Compiler & cached artifacts
pub const CompiledGrammar = internal.compiler.CompiledGrammar;
pub const GrammarCompiler = internal.compiler.GrammarCompiler;
pub const CompileError = internal.compiler.CompileError;

// Matcher, batching & token bitmasks
pub const TokenBitmask = internal.matcher.TokenBitmask;
pub const TokenBitmaskView = internal.matcher.TokenBitmaskView;
pub const TokenBitmaskConstView = internal.matcher.TokenBitmaskConstView;
pub const BitmaskDlType = internal.matcher.BitmaskDlType;
pub const GrammarMatcher = internal.matcher.GrammarMatcher;
pub const BatchMatcher = internal.matcher.BatchMatcher;
pub const Capture = internal.matcher.Capture;
pub const MatcherError = internal.matcher.MatcherError;
pub const bitmaskSize = internal.matcher.bitmaskSize;
pub const dlType = internal.matcher.dlType;
pub const resetBitmaskWords = internal.matcher.resetBitmaskWords;
pub const getMaskedTokensFromBitmask = internal.matcher.getMaskedTokensFromBitmask;
pub const isSingleTokenBitmask = internal.matcher.isSingleTokenBitmask;
pub const applyTokenBitmaskInplaceCpu = internal.matcher.applyTokenBitmaskInplaceCpu;
pub const applyTokenBitmaskInplaceCpuBatch = internal.matcher.applyTokenBitmaskInplaceCpuBatch;

// Support caches & recursion depth guards
pub const LruCache = internal.support.LruCache;
pub const AutoLruCache = internal.support.AutoLruCache;
pub const RecursionError = internal.support.RecursionError;
pub const getMaxRecursionDepth = internal.support.getMaxRecursionDepth;
pub const setMaxRecursionDepth = internal.support.setMaxRecursionDepth;
pub const resetRecursionDepth = internal.support.resetRecursionDepth;

// Test & debug utilities
pub const testing = @import("testing.zig");

test "public decls analyze cleanly" {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(Diagnostic);
    std.testing.refAllDecls(TokenizerInfo);
    std.testing.refAllDecls(Grammar);
    std.testing.refAllDecls(GrammarCompiler);
    std.testing.refAllDecls(CompiledGrammar);
    std.testing.refAllDecls(TokenBitmask);
    std.testing.refAllDecls(TokenBitmaskView);
    std.testing.refAllDecls(GrammarMatcher);
    std.testing.refAllDecls(BatchMatcher);
    std.testing.refAllDecls(VocabType);
    std.testing.refAllDecls(JsonFormat);
}

test {
    _ = internal.config;
    _ = internal.support;
    _ = internal.tokenizer;
    _ = internal.fsm;
    _ = internal.grammar;
    _ = internal.parser;
    _ = internal.functor;
    _ = internal.converter;
    _ = internal.compiler;
    _ = internal.matcher;
    _ = testing;
    _ = @import("tests.zig");
}
