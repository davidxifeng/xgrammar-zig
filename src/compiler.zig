//! Grammar compilation: preprocessing a grammar and tokenizer into a `CompiledGrammar`
//! for use by `GrammarMatcher`, with rule-level and grammar-level caches (`compiler`).

const std = @import("std");

const config = @import("config.zig");
const converter = @import("converter.zig");
const Diagnostic = @import("Diagnostic.zig").Diagnostic;
const functor = @import("functor.zig");
const support = @import("support.zig");
const tokenizer_mod = @import("tokenizer.zig");

pub const adaptive_token_mask = @import("compiler/AdaptiveTokenMask.zig");
pub const compiled_grammar = @import("compiler/CompiledGrammar.zig");
pub const grammar_compiler = @import("compiler/GrammarCompiler.zig");
pub const rule_level_cache = @import("compiler/rule_level_cache.zig");
pub const tag_dispatch_optimization = @import("compiler/tag_dispatch_optimization.zig");
pub const token_mask_cache_builder = @import("compiler/token_mask_cache_builder.zig");

pub const AdaptiveTokenMask = adaptive_token_mask.AdaptiveTokenMask;
pub const AdaptiveTokenMaskStorage = adaptive_token_mask.Storage;
pub const AdaptiveTokenMaskStoreType = adaptive_token_mask.StoreType;
pub const AdaptiveTokenMaskCache = adaptive_token_mask.AdaptiveTokenMaskCache;
pub const CompiledGrammar = compiled_grammar.CompiledGrammar;
pub const CompileError = grammar_compiler.CompileError;
pub const GrammarCompiler = grammar_compiler.GrammarCompiler;
pub const RuleLevelCache = rule_level_cache.RuleLevelCache;
pub const buildAdaptiveTokenMaskCache = token_mask_cache_builder.buildAdaptiveTokenMaskCache;

test {
    _ = adaptive_token_mask;
    _ = compiled_grammar;
    _ = grammar_compiler;
    _ = rule_level_cache;
    _ = tag_dispatch_optimization;
    _ = token_mask_cache_builder;
    std.testing.refAllDecls(@This());
}

test "AdaptiveTokenMask variants, json roundtrip, key order, and OOM safety" {
    const a = std.testing.allocator;
    var tok = try tokenizer_mod.TokenizerInfo.init(a, &.{ "a", "b", "c", "</s>" }, .{});
    defer tok.deinit();
    const sorted = tok.sortedDecodedVocab();

    // Accepted variant roundtrip + lexicographic JSON key order check.
    {
        var mask = try AdaptiveTokenMask.fromAcceptedAndUncertain(a, 4, sorted, &.{ 0, 2 }, &.{1});
        defer mask.deinit(a);
        try std.testing.expectEqual(AdaptiveTokenMaskStoreType.accepted, mask.storeType());
        try std.testing.expectEqual(@as(usize, 12), mask.memorySizeBytes());

        var aw: std.Io.Writer.Allocating = .init(a);
        defer aw.deinit();
        var jw: std.json.Stringify = .{ .writer = &aw.writer };
        try mask.writeJson(&jw);
        try std.testing.expectEqualStrings(
            "{\"accepted_bitset\":[0,0],\"accepted_indices\":[0,2],\"rejected_indices\":[],\"store_type\":0,\"uncertain_indices\":[1]}",
            aw.written(),
        );

        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const val = try support.parseJson(arena.allocator(), aw.written());
        var restored = try AdaptiveTokenMask.deserializeJsonValue(a, val, null);
        defer restored.deinit(a);
        try std.testing.expect(mask.eql(&restored));
    }

    // Rejected variant roundtrip.
    {
        var mask = try AdaptiveTokenMask.fromClassifications(a, 4, sorted, &.{ 0, 1 }, &.{2}, &.{});
        defer mask.deinit(a);
        try std.testing.expectEqual(AdaptiveTokenMaskStoreType.rejected, mask.storeType());

        var aw: std.Io.Writer.Allocating = .init(a);
        defer aw.deinit();
        var jw: std.json.Stringify = .{ .writer = &aw.writer };
        try mask.writeJson(&jw);
        try std.testing.expectEqualStrings(
            "{\"accepted_bitset\":[0,0],\"accepted_indices\":[],\"rejected_indices\":[2],\"store_type\":1,\"uncertain_indices\":[]}",
            aw.written(),
        );

        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const val = try support.parseJson(arena.allocator(), aw.written());
        var restored = try AdaptiveTokenMask.deserializeJsonValue(a, val, null);
        defer restored.deinit(a);
        try std.testing.expect(mask.eql(&restored));
    }

    // AcceptedBitset threshold test (>= 1000).
    {
        var raw_vocab: [1005][]u8 = undefined;
        var raw_slices: [1005][]const u8 = undefined;
        for (0..1005) |i| {
            raw_vocab[i] = try std.fmt.allocPrint(a, "t{d:0>4}", .{i});
            raw_slices[i] = raw_vocab[i];
        }
        defer for (&raw_vocab) |s| a.free(s);

        var big_tok = try tokenizer_mod.TokenizerInfo.init(a, &raw_slices, .{});
        defer big_tok.deinit();

        var acc: [1000]i32 = undefined;
        for (&acc, 0..) |*slot, i| slot.* = @intCast(i);
        var bs_mask = try AdaptiveTokenMask.fromAcceptedAndUncertain(a, 1005, big_tok.sortedDecodedVocab(), &acc, &.{1001});
        defer bs_mask.deinit(a);
        try std.testing.expectEqual(AdaptiveTokenMaskStoreType.accepted_bitset, bs_mask.storeType());

        var duped = try bs_mask.dupe(a);
        defer duped.deinit(a);
        try std.testing.expect(bs_mask.eql(&duped));

        var aw: std.Io.Writer.Allocating = .init(a);
        defer aw.deinit();
        var jw: std.json.Stringify = .{ .writer = &aw.writer };
        try bs_mask.writeJson(&jw);

        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const val = try support.parseJson(arena.allocator(), aw.written());
        var restored = try AdaptiveTokenMask.deserializeJsonValue(a, val, null);
        defer restored.deinit(a);
        try std.testing.expect(bs_mask.eql(&restored));

        // OOM safety across deserialization of bitset mask.
        const check_oom = struct {
            fn run(alloc: std.mem.Allocator, json_val: std.json.Value) !void {
                var d: Diagnostic = .{};
                defer d.deinit(alloc);
                var m = try AdaptiveTokenMask.deserializeJsonValue(alloc, json_val, &d);
                defer m.deinit(alloc);
                var dup = try m.dupe(alloc);
                defer dup.deinit(alloc);
            }
        }.run;
        try std.testing.checkAllAllocationFailures(a, check_oom, .{val});
    }

    // Malformed AdaptiveTokenMask diagnostics without leaks.
    {
        var diag: Diagnostic = .{};
        defer diag.deinit(a);
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const bad_st = try support.parseJson(
            arena.allocator(),
            "{\"accepted_bitset\":[0,0],\"accepted_indices\":[],\"rejected_indices\":[],\"store_type\":9,\"uncertain_indices\":[]}",
        );
        try std.testing.expectError(error.Format, AdaptiveTokenMask.deserializeJsonValue(a, bad_st, &diag));
        try std.testing.expectEqual(Diagnostic.Kind.deserialize_format, diag.kind);

        const bad_bs = try support.parseJson(
            arena.allocator(),
            "{\"accepted_bitset\":[32,99],\"accepted_indices\":[0],\"rejected_indices\":[],\"store_type\":0,\"uncertain_indices\":[]}",
        );
        try std.testing.expectError(error.Format, AdaptiveTokenMask.deserializeJsonValue(a, bad_bs, &diag));
        try std.testing.expectEqual(Diagnostic.Kind.deserialize_format, diag.kind);
    }
}

test "rule level cache basic insert get clear, lru eviction, and concurrent access" {
    const a = std.testing.allocator;
    var tok = try tokenizer_mod.TokenizerInfo.init(a, &.{ "a", "b", "c", "</s>" }, .{});
    defer tok.deinit();
    const sorted = tok.sortedDecodedVocab();

    var m1 = try AdaptiveTokenMask.fromAcceptedAndUncertain(a, 4, sorted, &.{ 0, 1 }, &.{2});
    defer m1.deinit(a);
    var m2 = try AdaptiveTokenMask.fromAcceptedAndUncertain(a, 4, sorted, &.{1}, &.{});
    defer m2.deinit(a);

    const rlc = try RuleLevelCache.init(a, rule_level_cache.UNLIMITED_SIZE);
    defer rlc.deinit();
    try std.testing.expectEqual(rule_level_cache.UNLIMITED_SIZE, rlc.maxSize());
    try std.testing.expect(try rlc.addCache(100, 0, 2, 1, &m1));
    // Duplicate key returns false.
    try std.testing.expect(!(try rlc.addCache(100, 0, 2, 1, &m1)));

    var got = (try rlc.getCache(a, 100, 0, 2, 1)).?;
    defer got.deinit(a);
    try std.testing.expect(got.eql(&m1));
    try std.testing.expect((try rlc.getCache(a, 999, 0, 2, 1)) == null);

    rlc.clearCache();
    try std.testing.expect((try rlc.getCache(a, 100, 0, 2, 1)) == null);

    // Budgeted shard eviction.
    const mask_bytes = m1.memorySizeBytes();
    const bounded = try RuleLevelCache.init(a, mask_bytes * 16); // exactly 1 mask per shard
    defer bounded.deinit();
    try std.testing.expect(try bounded.addCache(7, 1, 2, 1, &m1));
    try std.testing.expect(try bounded.addCache(7, 1, 2, 2, &m2));
    try std.testing.expect((try bounded.getCache(a, 7, 1, 2, 1)) == null);
    var got2 = (try bounded.getCache(a, 7, 1, 2, 2)).?;
    defer got2.deinit(a);
    try std.testing.expect(got2.eql(&m2));

    // Concurrent multi-threaded get/add/clear stress on RuleLevelCache with std.testing.allocator.
    const Worker = struct {
        fn run(cache: *RuleLevelCache, mask: *const AdaptiveTokenMask, tid: usize) void {
            const ts = cache.threadSafeAllocator();
            for (0..64) |i| {
                const h: u64 = @intCast((i + tid * 3) % 8);
                const node: i32 = @intCast((i + tid) % 5);
                _ = cache.addCache(h, node, 4, 4, mask) catch unreachable;
                if (cache.getCache(ts, h, node, 4, 4) catch unreachable) |fetched| {
                    var copy = fetched;
                    copy.deinit(ts);
                }
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ bounded, &m1, i });
    }
    for (threads) |t| t.join();
}

test "grammar compiler compile methods, caching, diagnostics, and compiled grammar json roundtrip" {
    const a = std.testing.allocator;
    var tok = try tokenizer_mod.TokenizerInfo.init(
        a,
        &.{ "{", "}", "\"", ":", ",", "true", "false", "123", "abc", "</s>" },
        .{ .vocab_size = 12 },
    );
    defer tok.deinit();

    var compiler_inst = try GrammarCompiler.init(a, &tok, .{});
    defer compiler_inst.deinit();

    try std.testing.expectEqual(@as(usize, 0), compiler_inst.cacheSizeBytes());
    try std.testing.expect(compiler_inst.cacheLimitBytes() == null);
    try std.testing.expect(compiler_inst.maxThreads() == null);

    var builtin1 = try compiler_inst.compileBuiltinJson(null);
    defer builtin1.deinit();
    var builtin2 = try compiler_inst.compileBuiltinJson(null);
    defer builtin2.deinit();
    try std.testing.expect(builtin1.sharesStorage(&builtin2));
    try std.testing.expect(compiler_inst.cacheSizeBytes() > 0);
    try std.testing.expect(builtin1.adaptiveTokenMaskCache().count() > 0);

    var schema = try compiler_inst.compileJsonSchema(
        "{\"type\":\"object\",\"properties\":{\"ok\":{\"type\":\"boolean\"}},\"required\":[\"ok\"],\"additionalProperties\":false}",
        .{ .any_whitespace = true, .strict_mode = true },
    );
    defer schema.deinit();
    try std.testing.expect(!schema.sharesStorage(&builtin1));

    var regex_c = try compiler_inst.compileRegex("[a-z]+", null);
    defer regex_c.deinit();

    var ebnf_c = try compiler_inst.compileEbnf("root ::= \"true\" | \"false\"", .{});
    defer ebnf_c.deinit();

    var raw_g = try @import("functor.zig").fromEbnf(a, "root ::= \"123\"", "root", null);
    defer raw_g.deinit();
    var compiled_g = try compiler_inst.compileGrammar(&raw_g, null);
    defer compiled_g.deinit();

    // Streaming JSON roundtrip + top-level key order check on CompiledGrammar.
    const serialized = try schema.serializeJson(a);
    defer a.free(serialized);
    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const parsed = try support.parseJson(arena.allocator(), serialized);
        const expected_keys = [_][]const u8{
            "__VERSION__",
            "adaptive_token_mask_cache",
            "grammar",
            "tokenizer_metadata",
        };
        const keys = parsed.object.keys();
        try std.testing.expectEqual(expected_keys.len, keys.len);
        for (expected_keys, keys) |want, got| try std.testing.expectEqualStrings(want, got);
        try std.testing.expectEqualStrings(config.serialization_version, parsed.object.get("__VERSION__").?.string);
    }

    var restored = try CompiledGrammar.deserializeJson(a, serialized, &tok, null);
    defer restored.deinit();
    const reserialized = try restored.serializeJson(a);
    defer a.free(reserialized);
    try std.testing.expectEqualStrings(serialized, reserialized);

    // Out-of-range token id error check via Diagnostic.
    var diag: Diagnostic = .{};
    defer diag.deinit(a);
    const bad = compiler_inst.compileLark("start: <[99]>", .{ .diag = &diag });
    try std.testing.expectError(error.TokenIdOutOfRange, bad);
    try std.testing.expectEqual(Diagnostic.Kind.compile_token_id_out_of_range, diag.kind);
    const msg = try diag.formatAlloc(a);
    defer a.free(msg);
    try std.testing.expectEqualStrings("Token id 99 in the grammar is out of the vocabulary range [0, 12)", msg);

    // Reuse same Diagnostic across EBNF, Regex, Schema, StructuralTag errors with zero leaks.
    try std.testing.expectError(error.Parser, compiler_inst.compileEbnf("other ::= \"a\"", .{ .diag = &diag }));
    try std.testing.expectEqual(Diagnostic.Kind.ebnf_parser, diag.kind);
    try std.testing.expectError(error.Regex, compiler_inst.compileRegex("a[]b", &diag));
    try std.testing.expectEqual(Diagnostic.Kind.regex, diag.kind);
    try std.testing.expectError(error.InvalidSchema, compiler_inst.compileJsonSchema("{bad", .{ .diag = &diag }));
    try std.testing.expectEqual(Diagnostic.Kind.message, diag.kind);
    try std.testing.expectError(error.InvalidJson, compiler_inst.compileStructuralTag("{bad", &diag));
    try std.testing.expectEqual(Diagnostic.Kind.structural_tag_invalid_json, diag.kind);

    // CompiledGrammar deserialize error diagnostics (invalid json, version, metadata mismatch).
    try std.testing.expectError(error.InvalidJson, CompiledGrammar.deserializeJson(a, "{", &tok, &diag));
    try std.testing.expectEqual(Diagnostic.Kind.deserialize_invalid_json, diag.kind);
    try std.testing.expectError(error.Version, CompiledGrammar.deserializeJson(a, "{\"__VERSION__\":\"v15\"}", &tok, &diag));
    try std.testing.expectEqual(Diagnostic.Kind.deserialize_version, diag.kind);
    var other_tok = try tokenizer_mod.TokenizerInfo.init(a, &.{"x"}, .{});
    defer other_tok.deinit();
    try std.testing.expectError(error.Format, CompiledGrammar.deserializeJson(a, serialized, &other_tok, &diag));
    try std.testing.expectEqual(Diagnostic.Kind.deserialize_format, diag.kind);

    compiler_inst.clearCache();
    try std.testing.expectEqual(@as(usize, 0), compiler_inst.cacheSizeBytes());
}

test "rule level cache crossing reuse with lookahead and tag dispatch" {
    const a = std.testing.allocator;
    var tok = try tokenizer_mod.TokenizerInfo.init(
        a,
        &.{ "a", "b", "c", "aa", "<t>", "</t>", "x", "y", "</s>" },
        .{ .vocab_size = 10 },
    );
    defer tok.deinit();

    var compiler_inst = try GrammarCompiler.init(a, &tok, .{});
    defer compiler_inst.deinit();

    // First EBNF populates rule-level cache without lookahead.
    var g1 = try compiler_inst.compileEbnf("word ::= [a-c]+\nroot ::= word", .{});
    defer g1.deinit();
    // Second EBNF uses an identical `word` rule with a lookahead assertion, triggering
    // `adaptCacheWithLookahead` from the rule-level cache hit.
    var g2 = try compiler_inst.compileEbnf("word ::= [a-c]+\nroot ::= word \"x\"", .{});
    defer g2.deinit();
    try std.testing.expect(g2.adaptiveTokenMaskCache().count() > 0);

    // Structural tag triggers `tagDispatchOptimization` + `token` edge paths.
    var st = try compiler_inst.compileStructuralTag(
        "{\"format\":{\"type\":\"triggered_tags\",\"triggers\":[\"<t>\"],\"tags\":[{\"begin\":\"<t>\",\"content\":{\"type\":\"any_text\"},\"end\":\"</t>\"}]}}",
        null,
    );
    defer st.deinit();
    try std.testing.expect(st.adaptiveTokenMaskCache().count() > 0);
}

test "parallel max_threads=4 cache build matches single-threaded deterministically under std.testing.allocator" {
    const a = std.testing.allocator;
    var tok = try tokenizer_mod.TokenizerInfo.init(a, &.{
        "{",  "}", ":", ",", "\"", "user", "tags", "true",
        "42", "a", "b", "c", "[",  "]",    " ",    "</s>",
    }, .{ .stop_token_ids = &.{15} });
    defer tok.deinit();

    const schema =
        \\{"type":"object","properties":{"user":{"type":"object","properties":{"name":{"type":"string"},"active":{"type":"boolean"}},"required":["name","active"]},"tags":{"type":"array","items":{"type":"string"}},"score":{"type":"integer"}},"required":["user","tags","score"]}
    ;

    var c1 = try GrammarCompiler.init(a, &tok, .{ .max_threads = 1, .cache_enabled = false });
    defer c1.deinit();
    var g1 = try c1.compileJsonSchema(schema, .{ .strict_mode = true });
    defer g1.deinit();

    // With cache_enabled=true (exercises shared RuleLevelCache + ThreadSafeAllocator across 4 threads).
    var c4 = try GrammarCompiler.init(a, &tok, .{ .max_threads = 4, .cache_enabled = true });
    defer c4.deinit();
    var g4 = try c4.compileJsonSchema(schema, .{ .strict_mode = true });
    defer g4.deinit();

    // Also test uncached parallel build (rl_cache == null) with a complex grammar.
    var c4_uncached = try GrammarCompiler.init(a, &tok, .{ .max_threads = 4, .cache_enabled = false });
    defer c4_uncached.deinit();
    var g4_uncached = try c4_uncached.compileJsonSchema(schema, .{ .strict_mode = true });
    defer g4_uncached.deinit();

    const s1 = try g1.serializeJson(a);
    defer a.free(s1);
    const s4 = try g4.serializeJson(a);
    defer a.free(s4);
    const s4u = try g4_uncached.serializeJson(a);
    defer a.free(s4u);
    try std.testing.expectEqualStrings(s1, s4);
    try std.testing.expectEqualStrings(s1, s4u);

    // Repeat with builtin JSON (many states) across 4 threads + rule-level cache.
    var b1 = try c1.compileBuiltinJson(null);
    defer b1.deinit();
    var b4 = try c4.compileBuiltinJson(null);
    defer b4.deinit();
    const bs1 = try b1.serializeJson(a);
    defer a.free(bs1);
    const bs4 = try b4.serializeJson(a);
    defer a.free(bs4);
    try std.testing.expectEqualStrings(bs1, bs4);
}

test "cache_enabled=false disables caching and max_memory_bytes evicts oldest grammars" {
    const a = std.testing.allocator;
    var tok = try tokenizer_mod.TokenizerInfo.init(a, &.{ "a", "b", "c", "</s>" }, .{});
    defer tok.deinit();

    // Uncached compiler must never share storage or accumulate cache size.
    {
        var uncached = try GrammarCompiler.init(a, &tok, .{ .max_threads = 1, .cache_enabled = false });
        defer uncached.deinit();
        var r1 = try uncached.compileRegex("a+", null);
        defer r1.deinit();
        var r2 = try uncached.compileRegex("a+", null);
        defer r2.deinit();
        try std.testing.expect(!r1.sharesStorage(&r2));
        try std.testing.expectEqual(@as(usize, 0), uncached.cacheSizeBytes());

        var l1 = try uncached.compileLark("start: \"a\"", .{});
        defer l1.deinit();
        var l2 = try uncached.compileLark("start: \"a\"", .{});
        defer l2.deinit();
        try std.testing.expect(!l1.sharesStorage(&l2));
    }

    // Budgeted compiler evicts oldest compiled grammar when exceeding grammar cache limit.
    {
        var bounded = try GrammarCompiler.init(a, &tok, .{
            .max_threads = 1,
            .cache_enabled = true,
            .max_memory_bytes = 2500,
        });
        defer bounded.deinit();
        try std.testing.expectEqual(@as(?usize, 2500), bounded.cacheLimitBytes());

        var cg_a = try bounded.compileRegex("a+", null);
        const one_size = cg_a.memorySizeBytes();
        cg_a.deinit();

        var cg_b = try bounded.compileRegex("b+", null);
        cg_b.deinit();
        var cg_c = try bounded.compileRegex("c+", null);
        cg_c.deinit();

        try std.testing.expect(bounded.cacheSizeBytes() <= bounded.cacheLimitBytes().? or bounded.cacheSizeBytes() <= one_size);
        bounded.clearCache();
        try std.testing.expectEqual(@as(usize, 0), bounded.cacheSizeBytes());
    }
}

test "CompiledGrammar retain and deinit across threads is race-free" {
    var ts = support.ThreadSafeAllocator{ .child = std.testing.allocator };
    const backing = ts.allocator();

    var tok = try tokenizer_mod.TokenizerInfo.init(backing, &.{ "a", "b", "c", "</s>" }, .{});
    defer tok.deinit();

    var cg = blk: {
        var compiler_inst = try GrammarCompiler.init(backing, &tok, .{ .max_threads = 2, .cache_enabled = true });
        defer compiler_inst.deinit();
        break :blk try compiler_inst.compileRegex("[a-c]+", null);
    };
    // Compiler is already destroyed; CompiledGrammar must survive cleanly.
    defer cg.deinit();

    const Worker = struct {
        fn run(base: *const CompiledGrammar) void {
            for (0..64) |_| {
                var handle = base.retain();
                std.debug.assert(handle.sharesStorage(base));
                std.debug.assert(handle.adaptiveTokenMaskCache().count() > 0);
                handle.deinit();
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{&cg});
    }
    for (threads) |t| t.join();
}

test "AdaptiveTokenMaskCache out-of-order put, overwrite, dupe, and unsorted JSON sort" {
    const a = std.testing.allocator;
    const parser_mod = @import("parser.zig");
    var tok = try tokenizer_mod.TokenizerInfo.init(a, &.{ "a", "b", "</s>" }, .{});
    defer tok.deinit();
    const sorted = tok.sortedDecodedVocab();

    var cache = AdaptiveTokenMaskCache.init(a);
    defer cache.deinit();

    const k2 = parser_mod.ParserStateCacheKey{ .rule_id = 2, .sequence_id = 0, .element_id = 0, .sub_element_id = 0 };
    const k0 = parser_mod.ParserStateCacheKey{ .rule_id = 0, .sequence_id = 0, .element_id = 0, .sub_element_id = 0 };
    const k1 = parser_mod.ParserStateCacheKey{ .rule_id = 1, .sequence_id = 0, .element_id = 0, .sub_element_id = 0 };

    try cache.put(k2, try AdaptiveTokenMask.fromAcceptedAndUncertain(a, 3, sorted, &.{0}, &.{}));
    try cache.put(k0, try AdaptiveTokenMask.fromAcceptedAndUncertain(a, 3, sorted, &.{1}, &.{}));
    try cache.put(k1, try AdaptiveTokenMask.fromAcceptedAndUncertain(a, 3, sorted, &.{ 0, 1 }, &.{}));
    // Overwrite k0 cleanly without leaking previous mask.
    try cache.put(k0, try AdaptiveTokenMask.fromAcceptedAndUncertain(a, 3, sorted, &.{}, &.{0}));
    try std.testing.expectEqual(@as(usize, 3), cache.count());
    try std.testing.expectEqualSlices(i32, &.{0}, cache.get(k0).?.uncertain_indices);

    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    try cache.writeJson(&jw);

    var duped = try cache.dupe(a);
    defer duped.deinit();
    var aw2: std.Io.Writer.Allocating = .init(a);
    defer aw2.deinit();
    var jw2: std.json.Stringify = .{ .writer = &aw2.writer };
    try duped.writeJson(&jw2);
    try std.testing.expectEqualStrings(aw.written(), aw2.written());

    // Deserializing unsorted entries produces canonical sorted writeJson output.
    const unsorted_json =
        "[[[2,0,0,-1,0,0,0,0,-1,-1],{\"accepted_bitset\":[0,0],\"accepted_indices\":[0],\"rejected_indices\":[],\"store_type\":0,\"uncertain_indices\":[]}]," ++
        "[[0,0,0,-1,0,0,0,0,-1,-1],{\"accepted_bitset\":[0,0],\"accepted_indices\":[],\"rejected_indices\":[],\"store_type\":0,\"uncertain_indices\":[0]}]," ++
        "[[1,0,0,-1,0,0,0,0,-1,-1],{\"accepted_bitset\":[0,0],\"accepted_indices\":[0,1],\"rejected_indices\":[],\"store_type\":0,\"uncertain_indices\":[]}]]";
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const val = try support.parseJson(arena.allocator(), unsorted_json);
    var restored = try AdaptiveTokenMaskCache.deserializeJsonValue(a, val, null);
    defer restored.deinit();

    var aw3: std.Io.Writer.Allocating = .init(a);
    defer aw3.deinit();
    var jw3: std.json.Stringify = .{ .writer = &aw3.writer };
    try restored.writeJson(&jw3);
    try std.testing.expectEqualStrings(aw.written(), aw3.written());
}

test "CompiledGrammar build/serialize/AdaptiveTokenMaskCache OOM safety and mask validation errors" {
    const a = std.testing.allocator;
    var tok = try tokenizer_mod.TokenizerInfo.init(a, &.{ "a", "b", "c", "</s>" }, .{});
    defer tok.deinit();

    var compiler_inst = try GrammarCompiler.init(a, &tok, .{ .max_threads = 1 });
    defer compiler_inst.deinit();
    var cg = try compiler_inst.compileRegex("[a-c]+", null);
    defer cg.deinit();
    const json = try cg.serializeJson(a);
    defer a.free(json);

    // OOM safety on AdaptiveTokenMaskCache.deserializeJsonValue, CompiledGrammar.build, and serializeJson.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const parsed = try support.parseJson(arena.allocator(), json);
    const cache_val = parsed.object.get("adaptive_token_mask_cache").?;

    const check_oom = struct {
        fn run(
            alloc: std.mem.Allocator,
            cv: std.json.Value,
            g_src: *const @import("grammar.zig").Grammar,
            t: *const tokenizer_mod.TokenizerInfo,
        ) !void {
            var diag: Diagnostic = .{};
            defer diag.deinit(alloc);
            var c = try AdaptiveTokenMaskCache.deserializeJsonValue(alloc, cv, &diag);
            defer c.deinit();

            const g_copy = try g_src.dupe(alloc);
            var built = try CompiledGrammar.build(alloc, g_copy, t, 1, null);
            defer built.deinit();

            const out = try built.serializeJson(alloc);
            alloc.free(out);
        }
    }.run;
    try std.testing.checkAllAllocationFailures(a, check_oom, .{ cache_val, cg.grammar(), &tok });

    // Inject out-of-range sorted vocab index into adaptive_token_mask_cache and verify rejection + no leaks.
    var diag: Diagnostic = .{};
    defer diag.deinit(a);
    const needle = "\"uncertain_indices\":[";
    const pos = std.mem.indexOf(u8, json, needle).?;
    const insert = if (json[pos + needle.len] == ']') "999" else "999,";
    const corrupted = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ json[0 .. pos + needle.len], insert, json[pos + needle.len ..] });
    defer a.free(corrupted);
    try std.testing.expectError(error.Format, CompiledGrammar.deserializeJson(a, corrupted, &tok, &diag));
    try std.testing.expectEqual(Diagnostic.Kind.deserialize_format, diag.kind);
}

test "GrammarCompiler cache keys distinguish json_format, excludes, and Lark NamedGrammars" {
    const a = std.testing.allocator;
    var tok = try tokenizer_mod.TokenizerInfo.init(a, &.{ "{", "}", "\"", ":", ",", "a", "b", "c", "x", "item", "</s>" }, .{});
    defer tok.deinit();

    var compiler_inst = try GrammarCompiler.init(a, &tok, .{ .max_threads = 1, .cache_enabled = true });
    defer compiler_inst.deinit();

    // JsonSchemaOptions.json_format and .excludes must not collide in the cache.
    const schema = "{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"string\"}},\"required\":[\"x\"]}";
    var js_plain = try compiler_inst.compileJsonSchema(schema, .{});
    defer js_plain.deinit();
    var js_qwen = try compiler_inst.compileJsonSchema(schema, .{ .json_format = .qwen_xml });
    defer js_qwen.deinit();
    var js_excl = try compiler_inst.compileJsonSchema(schema, .{ .excludes = &.{"bad"} });
    defer js_excl.deinit();
    try std.testing.expect(!js_plain.sharesStorage(&js_qwen));
    try std.testing.expect(!js_plain.sharesStorage(&js_excl));

    // Lark caching with NamedGrammar ordering and equivalent Grammar objects.
    const NamedGrammar = converter.NamedGrammar;
    var first = try compiler_inst.compileLark("start: \"a\"", .{});
    defer first.deinit();
    var repeated = try compiler_inst.compileLark("start: \"a\"", .{});
    defer repeated.deinit();
    try std.testing.expect(first.sharesStorage(&repeated));

    const named_grammars = [_]NamedGrammar{
        .{ .lark = .{ .name = "left", .source = "start: \"a\"" } },
        .{ .lark = .{ .name = "right", .source = "start: \"b\"" } },
    };
    var with_named = try compiler_inst.compileLark("start: @left @right", .{ .named_grammars = &named_grammars });
    defer with_named.deinit();
    const reversed = [_]NamedGrammar{ named_grammars[1], named_grammars[0] };
    var with_reordered = try compiler_inst.compileLark("start: @left @right", .{ .named_grammars = &reversed });
    defer with_reordered.deinit();
    try std.testing.expect(with_named.sharesStorage(&with_reordered));

    const diff_named = [_]NamedGrammar{
        .{ .lark = .{ .name = "left", .source = "start: \"a\"" } },
        .{ .lark = .{ .name = "right", .source = "start: \"c\"" } },
    };
    var with_diff = try compiler_inst.compileLark("start: @left @right", .{ .named_grammars = &diff_named });
    defer with_diff.deinit();
    try std.testing.expect(!with_named.sharesStorage(&with_diff));

    var item1 = try converter.fromLark(a, "start: \"item\"", null, &.{}, null);
    defer item1.deinit();
    var item2 = try converter.fromLark(a, "start: \"item\"", null, &.{}, null);
    defer item2.deinit();
    var g1 = try compiler_inst.compileLark("start: @item", .{
        .named_grammars = &.{.{ .grammar = .{ .name = "item", .grammar = &item1 } }},
    });
    defer g1.deinit();
    var g2 = try compiler_inst.compileLark("start: @item", .{
        .named_grammars = &.{.{ .grammar = .{ .name = "item", .grammar = &item2 } }},
    });
    defer g2.deinit();
    try std.testing.expect(g1.sharesStorage(&g2));
}
