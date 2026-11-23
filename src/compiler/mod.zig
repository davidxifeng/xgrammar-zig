//! Grammar compilation: preprocessing a grammar and tokenizer into a `CompiledGrammar`
//! for use by `GrammarMatcher`, with a result cache (`mod.rs`).

const std = @import("std");

pub const adaptive_token_mask = @import("adaptive_token_mask.zig");
pub const compiled_grammar = @import("compiled_grammar.zig");
pub const error_mod = @import("error.zig");
pub const grammar_compiler = @import("grammar_compiler.zig");
pub const rule_level_cache = @import("rule_level_cache.zig");
pub const tag_dispatch_optimization = @import("tag_dispatch_optimization.zig");
pub const token_mask_cache_builder = @import("token_mask_cache_builder.zig");

// pub use adaptive_token_mask::{AdaptiveTokenMask, AdaptiveTokenMaskCache, AdaptiveTokenMaskStoreType};
pub const AdaptiveTokenMask = adaptive_token_mask.AdaptiveTokenMask;
pub const AdaptiveTokenMaskCache = adaptive_token_mask.AdaptiveTokenMaskCache;
pub const AdaptiveTokenMaskStoreType = adaptive_token_mask.AdaptiveTokenMaskStoreType;
// pub use compiled_grammar::CompiledGrammar;
pub const CompiledGrammar = compiled_grammar.CompiledGrammar;
// pub use error::CompileError;
pub const CompileError = error_mod.CompileError;
pub const CompileErrorInfo = error_mod.CompileErrorInfo;
// pub use grammar_compiler::GrammarCompiler;
pub const GrammarCompiler = grammar_compiler.GrammarCompiler;
// pub use rule_level_cache::RuleLevelCache;
pub const RuleLevelCache = rule_level_cache.RuleLevelCache;

test {
    _ = adaptive_token_mask;
    _ = compiled_grammar;
    _ = error_mod;
    _ = grammar_compiler;
    _ = rule_level_cache;
    _ = tag_dispatch_optimization;
    _ = token_mask_cache_builder;
}

test "rule level cache basic insert get clear and lru eviction" {
    const a = std.testing.allocator;
    const tokenizer_mod = @import("../tokenizer/mod.zig");
    var tok = try tokenizer_mod.TokenizerInfo.new(a, &.{ "a", "b", "c", "</s>" }, .Raw, null, null, false, null);
    defer tok.deinit();

    var m1 = try AdaptiveTokenMask.from_accepted_and_uncertain(a, 4, tok.sorted_decoded_vocab, &.{ 0, 1 }, &.{2});
    defer m1.deinit();
    var m2 = try AdaptiveTokenMask.from_accepted_and_uncertain(a, 4, tok.sorted_decoded_vocab, &.{1}, &.{});
    defer m2.deinit();

    const rlc = try RuleLevelCache.new(a, rule_level_cache.UNLIMITED_SIZE);
    defer rlc.deinit();
    try std.testing.expectEqual(rule_level_cache.UNLIMITED_SIZE, rlc.max_size());
    try std.testing.expect(try rlc.add_cache(100, 0, 2, 1, &m1));
    // Duplicate key returns false.
    try std.testing.expect(!(try rlc.add_cache(100, 0, 2, 1, &m1)));

    var got = (try rlc.get_cache(a, 100, 0, 2, 1)).?;
    defer got.deinit();
    try std.testing.expect(got.eql(&m1));
    try std.testing.expect((try rlc.get_cache(a, 999, 0, 2, 1)) == null);

    rlc.clear_cache();
    try std.testing.expect((try rlc.get_cache(a, 100, 0, 2, 1)) == null);

    // Budgeted shard eviction.
    const mask_bytes = m1.memory_size_bytes();
    const bounded = try RuleLevelCache.new(a, mask_bytes * 16); // exactly 1 mask per shard
    defer bounded.deinit();
    try std.testing.expect(try bounded.add_cache(7, 1, 2, 1, &m1));
    try std.testing.expect(try bounded.add_cache(7, 1, 2, 2, &m2));
    try std.testing.expect((try bounded.get_cache(a, 7, 1, 2, 1)) == null);
    var got2 = (try bounded.get_cache(a, 7, 1, 2, 2)).?;
    defer got2.deinit();
    try std.testing.expect(got2.eql(&m2));
}

test "grammar compiler compile methods, caching, and compiled grammar json roundtrip" {
    const a = std.testing.allocator;
    const tokenizer_mod = @import("../tokenizer/mod.zig");
    var tok = try tokenizer_mod.TokenizerInfo.new(
        a,
        &.{ "{", "}", "\"", ":", ",", "true", "false", "123", "abc", "</s>" },
        .Raw,
        12,
        null,
        false,
        null,
    );
    defer tok.deinit();

    const compiler_inst = try GrammarCompiler.with_defaults(a, &tok);
    defer compiler_inst.deinit();

    try std.testing.expectEqual(@as(i64, 0), compiler_inst.get_cache_size_bytes());
    try std.testing.expectEqual(@as(i64, -1), compiler_inst.cache_limit_bytes());
    try std.testing.expectEqual(@as(i32, 8), compiler_inst.get_max_threads());

    var builtin1 = try compiler_inst.compile_builtin_json_grammar();
    defer builtin1.deinit();
    var builtin2 = try compiler_inst.compile_builtin_json_grammar();
    defer builtin2.deinit();
    try std.testing.expect(builtin1.shares_storage(&builtin2));
    try std.testing.expect(compiler_inst.get_cache_size_bytes() > 0);
    try std.testing.expect(builtin1.adaptive_token_mask_cache().count() > 0);

    var schema = try compiler_inst.compile_json_schema(
        "{\"type\":\"object\",\"properties\":{\"ok\":{\"type\":\"boolean\"}},\"required\":[\"ok\"],\"additionalProperties\":false}",
        true,
        null,
        null,
        true,
        null,
        null,
    );
    defer schema.deinit();
    try std.testing.expect(!schema.shares_storage(&builtin1));

    var regex_c = try compiler_inst.compile_regex("[a-z]+", null);
    defer regex_c.deinit();

    var ebnf_c = try compiler_inst.compile_grammar_ebnf("root ::= \"true\" | \"false\"", "root", null);
    defer ebnf_c.deinit();

    // JSON roundtrip on CompiledGrammar.
    const serialized = try schema.serialize_json(a);
    defer a.free(serialized);
    var restored = try CompiledGrammar.deserialize_json(a, serialized, &tok, null);
    defer restored.deinit();
    const reserialized = try restored.serialize_json(a);
    defer a.free(reserialized);
    try std.testing.expectEqualStrings(serialized, reserialized);

    // Out-of-range token id error check.
    var diag: CompileErrorInfo = undefined;
    const bad = compiler_inst.compile_lark("start: <[99]>", &.{}, &diag);
    try std.testing.expectError(error.TokenIdOutOfRange, bad);
    defer diag.deinit(a);
    const msg = try diag.format_message(a);
    defer a.free(msg);
    try std.testing.expectEqualStrings("Token id 99 in the grammar is out of the vocabulary range [0, 12)", msg);

    compiler_inst.clear_cache();
    try std.testing.expectEqual(@as(i64, 0), compiler_inst.get_cache_size_bytes());
}

test "rule level cache crossing reuse with lookahead and tag dispatch" {
    const a = std.testing.allocator;
    const tokenizer_mod = @import("../tokenizer/mod.zig");
    var tok = try tokenizer_mod.TokenizerInfo.new(
        a,
        &.{ "a", "b", "c", "aa", "<t>", "</t>", "x", "y", "</s>" },
        .Raw,
        10,
        null,
        false,
        null,
    );
    defer tok.deinit();

    const compiler_inst = try GrammarCompiler.with_defaults(a, &tok);
    defer compiler_inst.deinit();

    // First EBNF populates rule-level cache without lookahead.
    var g1 = try compiler_inst.compile_grammar_ebnf("word ::= [a-c]+\nroot ::= word", "root", null);
    defer g1.deinit();
    // Second EBNF uses an identical `word` rule with a lookahead assertion, triggering
    // `adapt_cache_with_lookahead` from the rule-level cache hit!
    var g2 = try compiler_inst.compile_grammar_ebnf("word ::= [a-c]+\nroot ::= word \"x\"", "root", null);
    defer g2.deinit();
    try std.testing.expect(g2.adaptive_token_mask_cache().count() > 0);

    // Structural tag triggers `tag_dispatch_optimization` + `token_edge` paths.
    var st = try compiler_inst.compile_structural_tag(
        "{\"format\":{\"type\":\"triggered_tags\",\"triggers\":[\"<t>\"],\"tags\":[{\"begin\":\"<t>\",\"content\":{\"type\":\"any_text\"},\"end\":\"</t>\"}]}}",
        null,
    );
    defer st.deinit();
    try std.testing.expect(st.adaptive_token_mask_cache().count() > 0);
}
