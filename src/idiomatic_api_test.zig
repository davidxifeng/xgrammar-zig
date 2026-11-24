//! Tests for Zig 0.17 idiomatic APIs, SIMD TokenBitmask, parallel compilation & batch matching,
//! O(1) LRU eviction, `{f}` formatting, and regression checks for fixed refactoring bugs.

const std = @import("std");
const testing = std.testing;
const xgrammar = @import("xgrammar.zig");

const CountingAllocator = struct {
    child: std.mem.Allocator,
    alloc_calls: usize = 0,
    resize_calls: usize = 0,
    remap_calls: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.alloc_calls += 1;
        return self.child.vtable.alloc(self.child.ptr, len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.resize_calls += 1;
        return self.child.vtable.resize(self.child.ptr, memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.remap_calls += 1;
        return self.child.vtable.remap(self.child.ptr, memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.vtable.free(self.child.ptr, memory, alignment, ret_addr);
    }
};

test "idiomatic Zig 0.17 workflow with SIMD TokenBitmask, BatchMatcher, and Grammar format" {
    const a = testing.allocator;

    // 75-token vocab exercises: word 0 (0..31), word 1 (32..63), word 2 (64..74 = 11 tail tokens -> 8-lane SIMD + 3-lane scalar tail).
    var vocab_storage: [75][]u8 = undefined;
    var vocab_slices: [75][]const u8 = undefined;
    var owned_count: usize = 0;
    defer for (vocab_storage[0..owned_count]) |s| a.free(s);

    const fixed = [_][]const u8{ "{\"ok\": ", "true", "false", "}", "bad", "</s>" };
    for (fixed, 0..) |s, i| {
        vocab_storage[i] = try a.dupe(u8, s);
        vocab_slices[i] = vocab_storage[i];
        owned_count += 1;
    }
    for (fixed.len..vocab_storage.len) |i| {
        vocab_storage[i] = try std.fmt.allocPrint(a, "tok_{d}", .{i});
        vocab_slices[i] = vocab_storage[i];
        owned_count += 1;
    }

    var tok = try xgrammar.TokenizerInfo.init(a, &vocab_slices, .{
        .vocab_type = .raw,
        .stop_token_ids = &.{5},
    });
    defer tok.deinit();
    try testing.expectEqual(@as(usize, 75), tok.vocabSize());
    try testing.expectEqual(xgrammar.VocabType.raw, tok.vocabType());

    var compiler = try xgrammar.GrammarCompiler.init(a, &tok, .{ .max_threads = 4 });
    defer compiler.deinit();

    const schema =
        \\{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"],"additionalProperties":false}
    ;
    var compiled = try compiler.compileJsonSchema(schema, .{
        .any_whitespace = false,
        .strict_mode = true,
    });
    defer compiled.deinit();

    // Verify Grammar `{f}` formatting works cleanly.
    const formatted_grammar = try std.fmt.allocPrint(a, "{f}", .{compiled.grammar().*});
    defer a.free(formatted_grammar);
    try testing.expect(std.mem.indexOf(u8, formatted_grammar, "root ::=") != null);

    var matcher = try xgrammar.GrammarMatcher.init(a, &compiled, .{});
    defer matcher.deinit();

    var bm = try xgrammar.TokenBitmask.initSingle(a, tok.vocabSize());
    defer bm.deinit();

    try testing.expect(try matcher.fillNextTokenBitmask(&bm, 0, null));
    try testing.expectEqual(@as(usize, 1), bm.countAllowed());
    try testing.expectEqual(@as(?u32, 0), bm.singleAllowedToken());

    var logits: [75]f32 = undefined;
    for (&logits, 0..) |*v, i| v.* = @floatFromInt(i + 1);
    bm.applyToLogits(&logits);
    try testing.expectEqual(@as(f32, 1.0), logits[0]);
    for (logits[1..]) |v| try testing.expectEqual(-std.math.inf(f32), v);

    const jf = try matcher.findJumpForwardString(a, null);
    defer a.free(jf);
    try testing.expectEqualStrings("{\"ok\": ", jf);

    try testing.expect(try matcher.acceptToken(0, null));
    bm.reset();
    try testing.expect(try matcher.fillNextTokenBitmask(&bm, 0, null));
    try testing.expectEqual(@as(usize, 2), bm.countAllowed());
    try testing.expect(bm.isAllowed(1));
    try testing.expect(bm.isAllowed(2));
    try testing.expect(bm.singleAllowedToken() == null);

    try testing.expect(try matcher.acceptToken(1, null)); // true
    try testing.expect(try matcher.acceptToken(3, null)); // }
    try testing.expect(matcher.isCompleted());
    try testing.expect(!matcher.isTerminated());
    try testing.expect(try matcher.acceptToken(5, null)); // </s>
    try testing.expect(matcher.isTerminated());

    // BatchMatcher sequential vs multi-threaded bitmask equality with 0 leaks.
    var batch_seq_bm = try xgrammar.TokenBitmask.init(a, 6, tok.vocabSize());
    defer batch_seq_bm.deinit();
    var batch_par_bm = try xgrammar.TokenBitmask.init(a, 6, tok.vocabSize());
    defer batch_par_bm.deinit();

    var matchers: [6]xgrammar.GrammarMatcher = undefined;
    var created: usize = 0;
    defer for (matchers[0..created]) |*m| m.deinit();
    for (&matchers, 0..) |*m, idx| {
        m.* = try xgrammar.GrammarMatcher.init(a, &compiled, .{});
        created += 1;
        if (idx % 2 == 1) _ = try m.acceptToken(0, null);
    }

    var bm_seq = xgrammar.BatchMatcher.init(a, .{ .max_threads = 1 });
    defer bm_seq.deinit();
    try bm_seq.fillNextTokenBitmask(&matchers, &batch_seq_bm, null, null);

    var bm_par = xgrammar.BatchMatcher.init(a, .{ .max_threads = 4 });
    defer bm_par.deinit();
    try bm_par.fillNextTokenBitmask(&matchers, &batch_par_bm, null, null);

    try testing.expectEqualSlices(i32, batch_seq_bm.words, batch_par_bm.words);

    const acc = try bm_par.acceptTokenBatch(a, &matchers, &.{ 0, 1, 4, 2, 0, 1 }, null);
    defer a.free(acc);
    try testing.expectEqualSlices(bool, &.{ true, true, false, true, true, true }, acc);
}

test "parallel max_threads=4 compilation matches single-threaded max_threads=1 deterministically" {
    const a = testing.allocator;

    var tok = try xgrammar.TokenizerInfo.init(a, &.{
        "{",  "}", ":", ",", "\"", "user", "tags", "true",
        "42", "a", "b", "c", "[",  "]",    " ",    "</s>",
    }, .{ .stop_token_ids = &.{15} });
    defer tok.deinit();

    const schema =
        \\{"type":"object","properties":{"user":{"type":"object","properties":{"name":{"type":"string"},"active":{"type":"boolean"}},"required":["name","active"]},"tags":{"type":"array","items":{"type":"string"}},"score":{"type":"integer"}},"required":["user","tags","score"]}
    ;

    var c1 = try xgrammar.GrammarCompiler.init(a, &tok, .{ .max_threads = 1, .cache_enabled = false });
    defer c1.deinit();
    var g1 = try c1.compileJsonSchema(schema, .{ .strict_mode = true });
    defer g1.deinit();

    var c4 = try xgrammar.GrammarCompiler.init(a, &tok, .{ .max_threads = 4, .cache_enabled = true });
    defer c4.deinit();
    var g4 = try c4.compileJsonSchema(schema, .{ .strict_mode = true });
    defer g4.deinit();

    const s1 = try g1.serializeJson(a);
    defer a.free(s1);
    const s4 = try g4.serializeJson(a);
    defer a.free(s4);
    try testing.expectEqualStrings(s1, s4);
}

test "GrammarCompiler O(1) LRU cache evicts oldest compiled grammar under tight max_memory_bytes" {
    const a = testing.allocator;
    var tok = try xgrammar.TokenizerInfo.init(a, &.{ "a", "b", "c", "</s>" }, .{});
    defer tok.deinit();

    var compiler = try xgrammar.GrammarCompiler.init(a, &tok, .{
        .max_threads = 1,
        .cache_enabled = true,
        .max_memory_bytes = 2500,
    });
    defer compiler.deinit();

    var cg_a = try compiler.compileRegex("a+", null);
    const one_size = cg_a.memorySizeBytes();
    cg_a.deinit();

    var cg_b = try compiler.compileRegex("b+", null);
    cg_b.deinit();
    var cg_c = try compiler.compileRegex("c+", null);
    cg_c.deinit();

    const limit = compiler.cacheLimitBytes() orelse std.math.maxInt(usize);
    try testing.expect(compiler.cacheSizeBytes() <= limit or compiler.cacheSizeBytes() <= one_size);
    compiler.clearCache();
    try testing.expectEqual(@as(usize, 0), compiler.cacheSizeBytes());
}

test "SIMD TokenBitmask handles full-zero, full-one, mixed words, borrowed views, and tail tokens accurately" {
    const a = testing.allocator;
    var bm = try xgrammar.TokenBitmask.initSingle(a, 75);
    defer bm.deinit();

    @memset(bm.words, 0);
    bm.setAllowed(0, true);
    bm.setAllowed(5, true);
    bm.setAllowed(31, true);
    bm.setAllowed(64, true);
    bm.setAllowed(71, true);
    bm.setAllowed(74, true);

    try testing.expectEqual(@as(usize, 6), bm.countAllowed());

    var logits: [75]f32 = undefined;
    for (&logits, 0..) |*v, i| v.* = @floatFromInt(i);
    bm.applyToLogits(&logits);

    for (logits, 0..) |val, idx| {
        const expected_allowed = idx == 0 or idx == 5 or idx == 31 or idx == 64 or idx == 71 or idx == 74;
        if (expected_allowed) {
            try testing.expectEqual(@as(f32, @floatFromInt(idx)), val);
        } else {
            try testing.expectEqual(-std.math.inf(f32), val);
        }
    }

    // Borrowed non-owning TokenBitmaskView (no deinit) + full all-ones fast path.
    var raw = [_]i32{ -1, -1, -1 };
    const borrowed = try xgrammar.TokenBitmaskView.init(&raw, 1, 75);
    try testing.expectEqual(@as(usize, 75), borrowed.asConst().countAllowed());
}

test "Grammar static constructors fromEbnf, fromRegex, fromJsonSchema, fromLark, fromStructuralTag, unionOf, concatOf, builtinJson" {
    const a = testing.allocator;
    var g1 = try xgrammar.Grammar.fromEbnf(a, "root ::= [a-z]+", .{});
    defer g1.deinit();
    try testing.expect(g1.numRules() >= 1);

    var g2 = try xgrammar.Grammar.fromRegex(a, "[0-9]{2,3}", null);
    defer g2.deinit();

    var g3 = try xgrammar.Grammar.fromJsonSchema(a, "{\"type\":\"boolean\"}", .{});
    defer g3.deinit();

    var g4 = try xgrammar.Grammar.builtinJson(a);
    defer g4.deinit();
    try testing.expect(g4.numExprs() > 0);

    var g5 = try xgrammar.Grammar.fromLark(a, "start: \"ok\"", .{});
    defer g5.deinit();

    var g6 = try xgrammar.Grammar.fromStructuralTag(
        a,
        "{\"format\":{\"type\":\"const_string\",\"value\":\"hi\"}}",
        null,
    );
    defer g6.deinit();

    var gu = try xgrammar.Grammar.unionOf(a, &.{ g1, g2 });
    defer gu.deinit();
    var gc = try xgrammar.Grammar.concatOf(a, &.{ g1, g2 });
    defer gc.deinit();
    try testing.expect(gu.numRules() > 0 and gc.numRules() > 0);
}

test "regression: refactored bug fixes across Grammar, Diagnostic, DynamicBitset, HF metadata, threads, zero-alloc" {
    const a = testing.allocator;

    // 1. Grammar.rootRule() with non-zero root_rule_id.
    {
        var exprs = try xgrammar.internal.support.Compact2dArray(i32).init(a);
        defer exprs.deinit(a);
        _ = try exprs.pushRowNoncontiguous(a, xgrammar.internal.grammar.GrammarExprType.ByteString.asI32(), &.{'a'});
        _ = try exprs.pushRowNoncontiguous(a, xgrammar.internal.grammar.GrammarExprType.ByteString.asI32(), &.{'b'});
        const rules = [_]xgrammar.internal.grammar.Rule{
            xgrammar.internal.grammar.Rule.init("helper", 0),
            xgrammar.internal.grammar.Rule.init("entry", 1),
        };
        var g = try xgrammar.Grammar.fromParts(a, &rules, &exprs, 1);
        defer g.deinit();
        try testing.expectEqualStrings("entry", g.rootRule().name);
    }

    // 2. Grammar.fromJsonSchema forwards options.diag on invalid schema with 0 leaks.
    {
        var diag: xgrammar.Diagnostic = .{};
        defer diag.deinit(a);
        try testing.expectError(
            error.InvalidSchema,
            xgrammar.Grammar.fromJsonSchema(a, "{invalid_json", .{ .diag = &diag }),
        );
        try testing.expect(diag.kind == .message);
        try testing.expect(diag.message.len > 0);
    }

    // 3. Non-arena Grammar.serializeJson, CompiledGrammar.serializeJson, and fixed-buffer zero-alloc Grammar.format.
    {
        var tok = try xgrammar.TokenizerInfo.init(a, &.{ "a", "b", "</s>" }, .{});
        defer tok.deinit();
        var comp = try xgrammar.GrammarCompiler.init(a, &tok, .{ .max_threads = 1 });
        defer comp.deinit();
        var cg = try comp.compileEbnf("root ::= \"ab\"+", .{});
        defer cg.deinit();

        const g_json = try cg.grammar().serializeJson(a);
        defer a.free(g_json);
        const cg_json = try cg.serializeJson(a);
        defer a.free(cg_json);
        try testing.expect(g_json.len > 0 and cg_json.len > 0);

        // Zero-alloc Grammar.format directly into fixed stack buffer.
        var stack_buf: [512]u8 = undefined;
        var fixed_writer = std.Io.Writer.fixed(&stack_buf);
        try fixed_writer.print("{f}", .{cg.grammar().*});
        try testing.expect(std.mem.indexOf(u8, fixed_writer.buffered(), "root ::=") != null);
    }

    // 4. Double Grammar.setFsms releases prior per_rule_fsms cleanly with 0 leaks.
    {
        var fsm = try xgrammar.internal.fsm.Fsm.init(a, 2);
        defer fsm.deinit();
        try fsm.addEdge(0, 1, 'x', 'x');
        var complete = try xgrammar.internal.fsm.CompactFsm.fromFsm(a, &fsm);
        defer complete.deinit();

        var exprs = try xgrammar.internal.support.Compact2dArray(i32).init(a);
        defer exprs.deinit(a);
        _ = try exprs.pushRowNoncontiguous(a, xgrammar.internal.grammar.GrammarExprType.EmptyStr.asI32(), &.{});
        const rules = [_]xgrammar.internal.grammar.Rule{xgrammar.internal.grammar.Rule.init("root", 0)};
        var g = try xgrammar.Grammar.fromParts(a, &rules, &exprs, 0);
        defer g.deinit();

        var view = try xgrammar.internal.fsm.CompactFsmWithStartEnd.init(a, complete.retain(), 0, &.{1}, false);
        defer view.deinit();
        var sized = xgrammar.internal.fsm.CompactFsmWithStartEndWithSize.init(try view.dupe(a), 1, 2);
        defer sized.deinit();

        try g.setFsms(complete, &.{sized});
        try g.setFsms(complete, &.{sized});
    }

    // 5. DynamicBitset.findFirstOne / findFirstZero on non-32-multiple sizes with dirty padding bits.
    {
        var bs = try xgrammar.internal.support.DynamicBitset.init(a, 35);
        defer bs.deinit(a);
        bs.setAll();
        try testing.expectEqual(@as(?usize, null), bs.findFirstZero());
        bs.resetAll();
        bs.data[1] = 0xFFFF_FFF8; // bits >= 35 set in padding only!
        try testing.expectEqual(@as(?usize, null), bs.findFirstOne());
    }

    // 6. detectMetadataFromHf with non-arena allocator has 0 leaks.
    {
        const backend = "{\"model\":{\"type\":\"ByteLevel\"}}";
        const meta_json = try xgrammar.TokenizerInfo.detectMetadataFromHf(a, backend);
        defer a.free(meta_json);
        try testing.expect(std.mem.indexOf(u8, meta_json, "vocab_type") != null);
    }

    // 7. Diagnostic reuse, clear, and `{f}` formatting with 0 leaks.
    {
        var diag: xgrammar.Diagnostic = .{};
        defer diag.deinit(a);
        try diag.setFmt(a, .message, "err {d}", .{1});
        try diag.setLocatedFmt(a, .lark_located, 1, 3, "a: b", "bad", .{});
        const formatted = try diag.formatAlloc(a);
        defer a.free(formatted);
        try testing.expect(std.mem.indexOf(u8, formatted, "line 1, column 3") != null);
        diag.clear(a);
        try testing.expectEqual(xgrammar.Diagnostic.Kind.none, diag.kind);
    }

    // 8. Concurrent CompactFsm and CompiledGrammar retain/deinit across threads.
    {
        var tok = try xgrammar.TokenizerInfo.init(a, &.{ "a", "b", "</s>" }, .{});
        defer tok.deinit();
        var comp = try xgrammar.GrammarCompiler.init(a, &tok, .{ .max_threads = 1 });
        defer comp.deinit();
        var cg = try comp.compileEbnf("root ::= \"a\"+", .{});
        defer cg.deinit();

        const shared_fsm = cg.grammar().completeFsm();
        const Worker = struct {
            fn run(base_cg: *const xgrammar.CompiledGrammar, base_fsm: xgrammar.internal.fsm.CompactFsm) void {
                for (0..64) |_| {
                    var c = base_cg.retain();
                    var f = base_fsm.retain();
                    f.deinit();
                    c.deinit();
                }
            }
        };
        var threads: [4]std.Thread = undefined;
        for (&threads) |*t| {
            t.* = try std.Thread.spawn(.{}, Worker.run, .{ &cg, shared_fsm });
        }
        for (threads) |t| t.join();
    }

    // 9. Zero heap allocations during warmed-up GrammarMatcher.fillNextTokenBitmask.
    {
        var counter = CountingAllocator{ .child = a };
        const ca = counter.allocator();

        var tok = try xgrammar.TokenizerInfo.init(ca, &.{ "a", "b", "c", "</s>" }, .{ .stop_token_ids = &.{3} });
        defer tok.deinit();
        var comp = try xgrammar.GrammarCompiler.init(ca, &tok, .{ .max_threads = 1 });
        defer comp.deinit();
        var cg = try comp.compileEbnf("root ::= [a-b]+", .{});
        defer cg.deinit();

        var m = try xgrammar.GrammarMatcher.init(ca, &cg, .{});
        defer m.deinit();
        var bm = try xgrammar.TokenBitmask.initSingle(ca, tok.vocabSize());
        defer bm.deinit();

        // Warmup capacities.
        _ = try m.fillNextTokenBitmask(&bm, 0, null);
        _ = try m.acceptToken(0, null);
        bm.reset();
        _ = try m.fillNextTokenBitmask(&bm, 0, null);

        const before_alloc = counter.alloc_calls;
        const before_resize = counter.resize_calls;
        const before_remap = counter.remap_calls;

        for (0..8) |_| {
            bm.reset();
            _ = try m.fillNextTokenBitmask(&bm, 0, null);
        }

        try testing.expectEqual(before_alloc, counter.alloc_calls);
        try testing.expectEqual(before_resize, counter.resize_calls);
        try testing.expectEqual(before_remap, counter.remap_calls);
    }
}
