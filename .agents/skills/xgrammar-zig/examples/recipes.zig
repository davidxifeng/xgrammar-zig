const std = @import("std");
const xgrammar = @import("xgrammar");

test "recipe 1: end-to-end JSON Schema constrained decoding loop" {
    const a = std.testing.allocator;

    const vocab = [_][]const u8{
        "{", "\"name\"", ":", "\"", "alice", "}", "<eos>", "INVALID",
    };
    var tok = try xgrammar.TokenizerInfo.init(a, &vocab, .{
        .vocab_type = .raw,
        .stop_token_ids = &.{6},
    });
    defer tok.deinit();

    var compiler = try xgrammar.GrammarCompiler.init(a, &tok, .{});
    defer compiler.deinit();

    var diag: xgrammar.Diagnostic = .{};
    defer diag.deinit(a);

    const schema =
        \\{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}
    ;
    var compiled = try compiler.compileJsonSchema(schema, .{
        .any_whitespace = false,
        .separators = .{ .item = ",", .colon = ":" },
        .diag = &diag,
    });
    defer compiled.deinit();

    var matcher = try xgrammar.GrammarMatcher.init(a, &compiled, .{ .diag = &diag });
    defer matcher.deinit();

    var bitmask = try xgrammar.TokenBitmask.initSingle(a, tok.vocabSize());
    defer bitmask.deinit();

    // First step only permits opening '{' (token 0) — note deterministic jump-forward prefix too.
    const need_apply_start = try matcher.fillNextTokenBitmask(&bitmask, 0, &diag);
    try std.testing.expect(need_apply_start);
    try std.testing.expectEqual(@as(?u32, 0), bitmask.singleAllowedToken());

    const jump = try matcher.findJumpForwardString(a, &diag);
    defer a.free(jump);
    try std.testing.expectEqualStrings("{\"name\":\"", jump);

    var logits = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 99.0 };
    if (need_apply_start) bitmask.applyToLogits(&logits);
    try std.testing.expectEqual(@as(f32, 1.0), logits[0]);
    try std.testing.expectEqual(-std.math.inf(f32), logits[7]);

    // Step through {"name":"alice"}
    const seq = [_]u32{ 0, 1, 2, 3, 4, 3, 5 };
    for (seq) |tok_id| {
        try std.testing.expect(try matcher.acceptToken(tok_id, &diag));
    }
    try std.testing.expect(matcher.isCompleted());
    try std.testing.expect(!matcher.isTerminated());

    // After '}' only the stop token (6) is permitted.
    try std.testing.expect(try matcher.fillNextTokenBitmask(&bitmask, 0, &diag));
    try std.testing.expectEqual(@as(?u32, 6), bitmask.singleAllowedToken());
    try std.testing.expect(try matcher.acceptToken(6, &diag));
    try std.testing.expect(matcher.isTerminated());

    // Filling after termination returns error.Terminated cleanly.
    try std.testing.expectError(error.Terminated, matcher.fillNextTokenBitmask(&bitmask, 0, &diag));
}

test "recipe 2: Hugging Face metadata detection and VocabType decoding" {
    const a = std.testing.allocator;

    const hf_backend_json =
        \\{"model":{"type":"BPE","byte_fallback":true},"normalizer":null,"pre_tokenizer":{"type":"Metaspace","add_prefix_space":true},"decoder":{"type":"Sequence","decoders":[{"type":"Replace","pattern":{"String":"▁"},"content":" "},{"type":"ByteFallback"}]}}
    ;

    // Form A: typed HfMetadata struct for TokenizerInfo.init
    const hf_meta = try xgrammar.detectMetadataFromHf(a, hf_backend_json);
    try std.testing.expectEqual(xgrammar.VocabType.byte_fallback, hf_meta.vocab_type);

    // Form B: JSON metadata string for TokenizerInfo.fromVocabAndMetadata
    const meta_json = try xgrammar.TokenizerInfo.detectMetadataFromHf(a, hf_backend_json);
    defer a.free(meta_json);

    const vocab = [_][]const u8{ "▁hi", "<0x41>", "</s>" };
    var tok = try xgrammar.TokenizerInfo.fromVocabAndMetadata(a, &vocab, meta_json, null);
    defer tok.deinit();
    try std.testing.expectEqual(xgrammar.VocabType.byte_fallback, tok.vocabType());

    const decoded_sp = try xgrammar.decodeToken(a, "▁hello", .byte_fallback);
    defer a.free(decoded_sp);
    try std.testing.expectEqualStrings(" hello", decoded_sp);

    const decoded_byte = try xgrammar.decodeTokenBytes(a, "<0x41>", .byte_fallback);
    defer a.free(decoded_byte);
    try std.testing.expectEqualStrings("A", decoded_byte);
}

test "recipe 3: XML tool-calling formats and numeric range regexes" {
    const a = std.testing.allocator;

    const schema =
        \\{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer"}},"required":["query"]}
    ;
    const ebnf = try xgrammar.jsonSchemaToEbnf(a, schema, .{
        .json_format = .qwen_xml,
        .excludes = &.{"</tool_call>"},
    });
    defer a.free(ebnf);
    try std.testing.expect(std.mem.indexOf(u8, ebnf, "<parameter=") != null);
    try std.testing.expect(std.mem.indexOf(u8, ebnf, "</parameter>") != null);

    const vocab = [_][]const u8{ "0", "1", "2", "-", ".", "5", "<eos>" };
    var tok = try xgrammar.TokenizerInfo.init(a, &vocab, .{
        .vocab_type = .raw,
        .stop_token_ids = &.{6},
    });
    defer tok.deinit();

    var compiler = try xgrammar.GrammarCompiler.init(a, &tok, .{});
    defer compiler.deinit();

    var deepseek_cg = try compiler.compileJsonSchema(schema, .{
        .json_format = .deepseek_xml,
        .any_order = true,
    });
    defer deepseek_cg.deinit();

    const int_range_re = try xgrammar.generateRangeRegex(a, -5, 25);
    defer a.free(int_range_re);
    var int_cg = try compiler.compileRegex(int_range_re, null);
    defer int_cg.deinit();

    const float_range_re = try xgrammar.generateFloatRangeRegexWithOptions(a, 0.0, 2.5, .{
        .exclusive_start = true,
        .exclusive_end = false,
    });
    defer a.free(float_range_re);
    var float_cg = try compiler.compileRegex(float_range_re, null);
    defer float_cg.deinit();

    var matcher = try xgrammar.GrammarMatcher.init(a, &float_cg, .{});
    defer matcher.deinit();
    try std.testing.expect(try matcher.acceptString("1.5", null));
    try std.testing.expect(matcher.isCompleted());
}

test "recipe 4: Lark grammar with NamedGrammar, captures, and per-rule temperature" {
    const a = std.testing.allocator;

    var inner_grammar = try xgrammar.Grammar.fromEbnf(a, "root ::= [0-9]+", .{});
    defer inner_grammar.deinit();

    const vocab = [_][]const u8{ "id", ":", " ", "4", "2", ",", "o", "k", "<eos>" };
    var tok = try xgrammar.TokenizerInfo.init(a, &vocab, .{
        .vocab_type = .raw,
        .stop_token_ids = &.{8},
    });
    defer tok.deinit();

    var compiler = try xgrammar.GrammarCompiler.init(a, &tok, .{});
    defer compiler.deinit();

    const lark_src =
        \\start: "id:" code "," word
        \\code [capture="code_val", temperature=0.3]: @digits
        \\word [capture="word_val"]: @word_src
    ;
    var compiled = try compiler.compileLark(lark_src, .{
        .named_grammars = &.{
            xgrammar.NamedGrammar.fromGrammar("digits", &inner_grammar),
            xgrammar.NamedGrammar.fromLarkSource("word_src", "start: /[a-z]+/"),
        },
    });
    defer compiled.deinit();

    var matcher = try xgrammar.GrammarMatcher.init(a, &compiled, .{
        .default_temperature = 1.0,
    });
    defer matcher.deinit();

    try std.testing.expect(try matcher.acceptString("id:", null));
    try std.testing.expectEqual(@as(?f32, 0.3), matcher.temperature());

    try std.testing.expect(try matcher.acceptString("42", null));
    try std.testing.expect(try matcher.acceptString(",", null));
    try std.testing.expectEqual(@as(?f32, 1.0), matcher.temperature());

    try std.testing.expect(try matcher.acceptString("ok", null));

    const caps = try matcher.getCaptures(a, true);
    defer xgrammar.Capture.freeSlice(a, caps);
    try std.testing.expectEqual(@as(usize, 2), caps.len);
    try std.testing.expectEqualStrings("code_val", caps[0].name);
    try std.testing.expectEqualStrings("42", caps[0].bytes);
    try std.testing.expectEqualStrings("word_val", caps[1].name);
    try std.testing.expectEqualStrings("ok", caps[1].bytes);
}

test "recipe 5: Structural Tag with tokenizer-resolved token triggers" {
    const a = std.testing.allocator;

    const vocab = [_][]const u8{ "hi ", "<|call|>", "{", "\"x\"", ":", "1", "}", "<|/call|>", "<eos>" };
    var tok = try xgrammar.TokenizerInfo.init(a, &vocab, .{
        .vocab_type = .raw,
        .stop_token_ids = &.{8},
    });
    defer tok.deinit();

    var compiler = try xgrammar.GrammarCompiler.init(a, &tok, .{});
    defer compiler.deinit();

    const structural_tag_json =
        \\{
        \\  "type": "structural_tag",
        \\  "format": {
        \\    "type": "sequence",
        \\    "elements": [
        \\      {"type": "any_text", "excludes": ["<|call|>"]},
        \\      {
        \\        "type": "tag",
        \\        "begin": {"type": "token", "token": "<|call|>"},
        \\        "content": {
        \\          "type": "json_schema",
        \\          "json_schema": {"type":"object","properties":{"x":{"type":"integer"}},"required":["x"]}
        \\        },
        \\        "end": {"type": "token", "token": "<|/call|>"}
        \\      }
        \\    ]
        \\  }
        \\}
    ;

    var compiled = try compiler.compileStructuralTag(structural_tag_json, null);
    defer compiled.deinit();

    var matcher = try xgrammar.GrammarMatcher.init(a, &compiled, .{});
    defer matcher.deinit();

    // Accepts prefix text, then <|/call|>-delimited JSON via resolved special token IDs.
    try std.testing.expect(try matcher.acceptToken(0, null)); // "hi "
    try std.testing.expect(try matcher.acceptToken(1, null)); // "<|call|>"
    try std.testing.expect(try matcher.acceptToken(2, null)); // "{"
    try std.testing.expect(try matcher.acceptToken(3, null)); // "\"x\""
    try std.testing.expect(try matcher.acceptToken(4, null)); // ":"
    try std.testing.expect(try matcher.acceptToken(5, null)); // "1"
    try std.testing.expect(try matcher.acceptToken(6, null)); // "}"
    try std.testing.expect(try matcher.acceptToken(7, null)); // "<|/call|>"
    try std.testing.expect(matcher.isCompleted());
}

test "recipe 6: BatchMatcher with external TokenBitmaskView and SIMD batch masking" {
    const a = std.testing.allocator;

    const vocab = [_][]const u8{ "a", "b", "c", "<eos>" };
    var tok = try xgrammar.TokenizerInfo.init(a, &vocab, .{
        .vocab_type = .raw,
        .stop_token_ids = &.{3},
    });
    defer tok.deinit();

    var compiler = try xgrammar.GrammarCompiler.init(a, &tok, .{});
    defer compiler.deinit();

    var cg_a = try compiler.compileEbnf("root ::= \"a\"", .{});
    defer cg_a.deinit();
    var cg_b = try compiler.compileEbnf("root ::= \"b\"", .{});
    defer cg_b.deinit();

    var matchers = [_]xgrammar.GrammarMatcher{
        try xgrammar.GrammarMatcher.init(a, &cg_a, .{}),
        try xgrammar.GrammarMatcher.init(a, &cg_b, .{}),
    };
    defer for (&matchers) |*m| m.deinit();

    var batch = xgrammar.BatchMatcher.init(a, .{ .max_threads = 2 });
    defer batch.deinit();

    // Wrap a caller-owned i32 slice with TokenBitmaskView (zero internal buffer ownership).
    const words_per_row = xgrammar.bitmaskSize(tok.vocabSize());
    const raw_words = try a.alloc(i32, 2 * words_per_row);
    defer a.free(raw_words);
    xgrammar.resetBitmaskWords(raw_words);

    const view = try xgrammar.TokenBitmaskView.init(raw_words, 2, tok.vocabSize());
    try batch.fillNextTokenBitmaskView(&matchers, view, null, null);

    try std.testing.expectEqual(@as(?u32, 0), view.singleAllowedTokenInRow(0));
    try std.testing.expectEqual(@as(?u32, 1), view.singleAllowedTokenInRow(1));

    var logits = [_]f32{ 1.0, 2.0, 3.0, 4.0, 1.0, 2.0, 3.0, 4.0 };
    const const_view = try xgrammar.TokenBitmaskConstView.init(raw_words, 2, tok.vocabSize());
    try batch.applyBitmaskViewInplaceBatch(const_view, &logits, null, null);

    try std.testing.expectEqual(@as(f32, 1.0), logits[0]); // row 0 allows 'a'
    try std.testing.expectEqual(-std.math.inf(f32), logits[1]);
    try std.testing.expectEqual(-std.math.inf(f32), logits[4]); // row 1 allows 'b'
    try std.testing.expectEqual(@as(f32, 2.0), logits[5]);

    var accepted: [2]bool = undefined;
    try batch.acceptTokenBatchInto(&accepted, &matchers, &.{ 0, 1 }, null);
    try std.testing.expect(accepted[0] and accepted[1]);
}

test "recipe 7: speculative draft tree validation, fork, and rollback" {
    const a = std.testing.allocator;

    const vocab = [_][]const u8{ "a", "b", "x", "<eos>" };
    var tok = try xgrammar.TokenizerInfo.init(a, &vocab, .{
        .vocab_type = .raw,
        .stop_token_ids = &.{3},
    });
    defer tok.deinit();

    var compiler = try xgrammar.GrammarCompiler.init(a, &tok, .{});
    defer compiler.deinit();

    var cg = try compiler.compileEbnf("root ::= [ab]+", .{});
    defer cg.deinit();

    var matcher = try xgrammar.GrammarMatcher.init(a, &cg, .{ .default_temperature = 0.8 });
    defer matcher.deinit();

    // Draft tree: node 0 ('a') -> child 1 ('a'), sibling of child 1 -> node 2 ('x', invalid)
    var bm = try xgrammar.TokenBitmask.init(a, 3, tok.vocabSize());
    defer bm.deinit();
    var temps: [3]f32 = undefined;

    const ok = try matcher.traverseDraftTree(
        &.{ 1, -1, -1 },
        &.{ -1, 2, -1 },
        &.{ 0, 0, 2 },
        &bm,
        1.0,
        &temps,
        null,
    );
    try std.testing.expect(ok);
    try std.testing.expect(bm.isAllowedInRow(0, 0));
    try std.testing.expect(!bm.isAllowedInRow(2, 0)); // invalid branch 'x' has 0 allowed tokens

    // Fork and rollback without mutating shared compiled artifacts.
    var branch = try matcher.fork();
    defer branch.deinit();

    try std.testing.expect(try branch.acceptToken(0, null));
    try std.testing.expect(try branch.acceptToken(1, null));
    try branch.rollback(1, null);
    try std.testing.expect(!matcher.isCompleted()); // original untouched
    try std.testing.expect(branch.isCompleted()); // branch still has token 'a'
}

test "recipe 8: v16 serialization and reusable Diagnostic with {f} formatting" {
    const a = std.testing.allocator;

    try std.testing.expectEqualStrings("v16", xgrammar.getSerializationVersion());

    const vocab = [_][]const u8{ "ok", "<eos>" };
    var tok = try xgrammar.TokenizerInfo.init(a, &vocab, .{
        .vocab_type = .raw,
        .stop_token_ids = &.{1},
    });
    defer tok.deinit();

    var compiler = try xgrammar.GrammarCompiler.init(a, &tok, .{});
    defer compiler.deinit();

    var compiled = try compiler.compileEbnf("root ::= \"ok\"", .{});
    defer compiled.deinit();

    const tok_json = try tok.serializeJson(a);
    defer a.free(tok_json);
    const cg_json = try compiled.serializeJson(a);
    defer a.free(cg_json);

    var diag: xgrammar.Diagnostic = .{};
    defer diag.deinit(a);

    var tok2 = try xgrammar.TokenizerInfo.deserializeJson(a, tok_json, &diag);
    defer tok2.deinit();
    var cg2 = try xgrammar.CompiledGrammar.deserializeJson(a, cg_json, &tok2, &diag);
    defer cg2.deinit();

    var matcher = try xgrammar.GrammarMatcher.init(a, &cg2, .{});
    defer matcher.deinit();
    try std.testing.expect(try matcher.acceptToken(0, &diag));
    try std.testing.expect(matcher.isCompleted());

    // Reusing Diagnostic across multiple failures frees prior allocations automatically.
    try std.testing.expectError(error.Regex, xgrammar.Grammar.fromRegex(a, "a[]b", &diag));
    const msg1 = try std.fmt.allocPrint(a, "{f}", .{diag});
    defer a.free(msg1);
    try std.testing.expect(std.mem.indexOf(u8, msg1, "Empty character class") != null);

    try std.testing.expectError(error.InvalidSchema, xgrammar.Grammar.fromJsonSchema(a, "{bad", .{ .diag = &diag }));
    const msg2 = try std.fmt.allocPrint(a, "{f}", .{diag});
    defer a.free(msg2);
    try std.testing.expect(std.mem.startsWith(u8, msg2, "Failed to parse JSON:"));
}
