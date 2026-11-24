---
name: xgrammar-zig
description: Use xgrammar-zig (`xgrammar`) in Zig 0.17.1 for grammar-constrained LLM decoding across JSON Schema, EBNF, Regex, Lark, and Structural Tags. Use whenever integrating `xgrammar` into `build.zig`, configuring `TokenizerInfo` or Hugging Face metadata, compiling grammars with `GrammarCompiler`, running `GrammarMatcher`/`BatchMatcher`/`TokenBitmask` logit masking, validating speculative draft trees, or serializing compiled artifacts without reading library source files.
---

# Using xgrammar-zig

`xgrammar-zig` is a pure-Zig (0.17.1), zero-dependency port of XGrammar (`0.2.8`, serialization `"v16"`). Every public symbol is re-exported at the root of `@import("xgrammar")`.

Agents integrating or calling `xgrammar-zig` should use this skill together with its reference files and runnable examples—**you do not need to read `src/`** to use the library correctly.

## Quick Setup (`build.zig`)

Expose `src/xgrammar.zig` as module `"xgrammar"` (this repo's `build.zig` already defines it):

```zig
const xgrammar_mod = b.addModule("xgrammar", .{
    .root_source_file = b.path("src/xgrammar.zig"), // or dependency.module("xgrammar")
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("xgrammar", xgrammar_mod);
```

Then in Zig:

```zig
const xgrammar = @import("xgrammar");
```

## Choosing a Grammar Entry Point

Prefer compiling via `GrammarCompiler` in inference pipelines (handles normalization, adaptive token mask caching, and LRU caching automatically). Use standalone `Grammar.from*` constructors when inspecting, combining, serializing, or passing `NamedGrammar`s.

| Constraint need | Compiler method (`GrammarCompiler`) | Standalone constructor (`Grammar`) |
| --- | --- | --- |
| Arbitrary valid JSON | `compileBuiltinJson(diag)` | `Grammar.builtinJson(alloc)` |
| JSON Schema / XML tool calls | `compileJsonSchema(schema, opts)` | `Grammar.fromJsonSchema(alloc, schema, opts)` |
| Regular expression | `compileRegex(regex, diag)` | `Grammar.fromRegex(alloc, regex, diag)` |
| Numeric range regex -> regex | Feed `generateRangeRegex` / `generateFloatRangeRegex` into `compileRegex` | — |
| XGrammar EBNF | `compileEbnf(ebnf, opts)` | `Grammar.fromEbnf(alloc, ebnf, opts)` |
| Lark grammar (`.lark`) | `compileLark(lark, opts)` | `Grammar.fromLark(alloc, lark, opts)` |
| Structural tags (tool-call routing) | `compileStructuralTag(json, diag)` | `Grammar.fromStructuralTag[WithTokenizer](alloc, json, ...)` |
| Union / concat grammars | Combine `Grammar`s -> `compileGrammar(&g, diag)` | `Grammar.unionOf(alloc, &gs)` / `Grammar.concatOf(alloc, &gs)` |

See [references/grammar-formats.md](references/grammar-formats.md) for all 9 `JsonFormat` XML schemas, EBNF macros/attributes, supported Lark `%import common.*` & directives, and all 20 Structural Tag JSON formats.

## Core Constrained-Decoding Loop

```zig
const std = @import("std");
const xgrammar = @import("xgrammar");

pub fn decodeStepByStep(allocator: std.mem.Allocator) !void {
    // 1. Describe the model vocabulary & stop tokens (vocab_size defaults to encoded_vocab.len).
    const vocab = [_][]const u8{
        "{", "}", "\"name\"", ":", "\"", "alice", "\"", "<eos>",
    };
    var tok = try xgrammar.TokenizerInfo.init(allocator, &vocab, .{
        .vocab_type = .raw, // or .byte_level (GPT-2/Llama3/Qwen) / .byte_fallback (SentencePiece)
        .stop_token_ids = &.{7},
    });
    defer tok.deinit();

    // 2. Create a compiler (caches compiled grammars in an LRU cache by default).
    var compiler = try xgrammar.GrammarCompiler.init(allocator, &tok, .{});
    defer compiler.deinit();

    // Optional reusable Diagnostic: pass .diag = &diag on calls to inspect errors.
    var diag: xgrammar.Diagnostic = .{};
    defer diag.deinit(allocator);

    const schema =
        \\{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}
    ;
    var compiled = try compiler.compileJsonSchema(schema, .{ .diag = &diag });
    defer compiled.deinit();

    // 3. Create matcher & single-row token bitmask buffer.
    var matcher = try xgrammar.GrammarMatcher.init(allocator, &compiled, .{ .diag = &diag });
    defer matcher.deinit();

    var bitmask = try xgrammar.TokenBitmask.initSingle(allocator, tok.vocabSize());
    defer bitmask.deinit();

    // 4. Autoregressive generation loop.
    var logits = [_]f32{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
    while (!matcher.isTerminated()) {
        // Skip masking when all tokens are permitted (`need_apply == false`).
        const need_apply = try matcher.fillNextTokenBitmask(&bitmask, 0, &diag);

        // Optional fast-path: if only 1 token is allowed, skip full softmax/sampling.
        if (bitmask.singleAllowedToken()) |forced_id| {
            _ = forced_id;
        }

        // Optional jump-forward speculative constant bytes (caller owns returned slice).
        const jump = try matcher.findJumpForwardString(allocator, &diag);
        allocator.free(jump);

        if (need_apply) {
            bitmask.applyToLogits(&logits); // sets rejected logits to -inf via @Vector(8, f32) SIMD
        }

        // Sample next_token_id from `logits`, then advance matcher:
        const next_token_id: u32 = 0; // replace with argmax/sampler output
        const accepted = try matcher.acceptToken(next_token_id, &diag);
        if (!accepted) break;
    }
}
```

## Ownership, Reference Counting & Error Diagnostics

| Type / Function | How to construct | Lifetime / sharing | Cleanup required |
| --- | --- | --- | --- |
| `TokenizerInfo` | `init`, `fromVocabAndMetadata`, `deserializeJson` | Ref-counted internal storage (`retain()`, `dupe()`, `sharesStorage()`) | `tok.deinit()` |
| `Grammar` | `Grammar.from*`, `unionOf`, `concatOf`, `deserializeJson` | Owns arena/storage; `dupe(alloc)` deep-copies | `g.deinit()` |
| `GrammarCompiler` | `GrammarCompiler.init(alloc, &tok, opts)` | Retains `TokenizerInfo`; caches `CompiledGrammar`s | `compiler.deinit()` |
| `CompiledGrammar` | `compiler.compile*`, `CompiledGrammar.deserializeJson*` | Ref-counted (`retain()`, `sharesStorage()`). Holds retained `Grammar` + `TokenizerInfo` | `compiled.deinit()` |
| `GrammarMatcher` | `GrammarMatcher.init(alloc, &compiled, opts)` | Retains `CompiledGrammar`; `fork()` / `clone(alloc)` share `CompiledGrammar` | `matcher.deinit()` |
| `TokenBitmask` | `TokenBitmask.init` / `initSingle` | Owns `[]i32` word buffer | `bitmask.deinit()` |
| `TokenBitmaskView` / `ConstView` | `TokenBitmaskView.init(words, batch, vocab)` | **Non-owning** view over caller `[]i32` / `[]const i32` | None (caller owns slice) |
| `BatchMatcher` | `BatchMatcher.init(alloc, .{})` | Stateless thread-count config | `batch.deinit()` |
| `Diagnostic` | `var diag: Diagnostic = .{};` | Reusable across calls; auto-frees old message before storing new one. Keep `.diag = null` on hot paths | `diag.deinit(alloc)` |
| `[]Capture` | `matcher.getCaptures(alloc, deduplicate)` | Caller owns slice + each `.name` & `.bytes` | `xgrammar.Capture.freeSlice(alloc, captures)` |
| Slice outputs (`[]u8`, `[]u32`) | `toStringEbnf`, `serializeJson`, `findJumpForwardString`, `jsonSchemaToEbnf`, `regexToEbnf`, `generate*Regex`, `maskedTokens`, `dumpMetadata`, `TokenizerInfo.detectMetadataFromHf` | Caller owns returned slice | `alloc.free(slice)` |

## High-Value Patterns

### 1. Hugging Face `tokenizer.json` Auto-Detection

**Important distinction** — `xgrammar` provides two `detectMetadataFromHf` functions with different return types:
- `xgrammar.TokenizerInfo.detectMetadataFromHf(alloc, backend_json)` -> returns `[]u8` metadata JSON (`{"add_prefix_space":...,"vocab_type":...}`) ready for `TokenizerInfo.fromVocabAndMetadata(alloc, encoded_vocab, meta_json, &diag)`.
- `xgrammar.detectMetadataFromHf(alloc, backend_json)` -> returns `HfMetadata` (`struct { vocab_type: VocabType, add_prefix_space: bool }`) ready for `TokenizerInfo.init`.

### 2. Batched Inference (`BatchMatcher`) & External Buffers (`TokenBitmaskView`)

```zig
var batch = xgrammar.BatchMatcher.init(allocator, .{ .max_threads = 4 });
defer batch.deinit();

var bitmask = try xgrammar.TokenBitmask.init(allocator, matchers.len, vocab_size);
defer bitmask.deinit();

try batch.fillNextTokenBitmask(matchers, &bitmask, active_indices, &diag);
try batch.applyBitmaskInplaceBatch(&bitmask, batch_logits, active_indices, &diag);
try batch.acceptTokenBatchInto(accepted_out, matchers, next_tokens, &diag);
```

When writing masks into pre-allocated tensor/GPU staging buffers (`[batch_size, bitmaskSize(vocab_size)]` of `i32`), wrap the slice in `TokenBitmaskView.init(words, batch_size, vocab_size)` and call `fillNextTokenBitmaskView` / `batch.fillNextTokenBitmaskView` or the lower-level `Raw` shape variants.

### 3. Speculative Decoding (`traverseDraftTree`, `fork`, `rollback`)

- `matcher.rollback(n, &diag)` rewinds history by `n` accepted tokens (returns `error.RollbackTooFar` if `n > history.len`).
- `matcher.fork()` clones the matcher state while sharing the compiled grammar.
- `matcher.traverseDraftTree(retrieve_next_token, retrieve_next_sibling, draft_tokens, &bitmask, time_threshold, temperatures, &diag)` evaluates a draft token tree in one pass, filling one bitmask row per tree node (and optionally per-node temperatures from `[temperature=...]` rule attributes).

### 4. Serialization & Compiled Cache Reuse (`"v16"`)

- Save/load `TokenizerInfo` with `serializeJson` / `deserializeJson`.
- Save/load `CompiledGrammar` with `compiled.serializeJson(alloc)` / `CompiledGrammar.deserializeJson(alloc, json, &tok, &diag)`. Note that `CompiledGrammar` deserialization validates compatibility against `tok` and emits `error.Format` / `error.Version` / `error.InvalidJson` if mismatched.

## Critical Zig 0.17.1 & Library Pitfalls

1. **Use `{f}` (not `{}`) to format `Grammar` and `Diagnostic`**: both implement Zig 0.17's `format(self, writer: *std.Io.Writer) !void`. Writing `std.debug.print("{f}\n", .{diag})` avoids comptime formatting errors.
2. **`fillNextTokenBitmask` returns `!bool` (`need_apply`)**: `true` means at least one token in `0..vocabSize()` is disallowed; `false` means **every** token is allowed and you can skip calling `applyToLogits`. Calling `fillNextTokenBitmask` after a stop token was accepted returns `error.Terminated`.
3. **Bitmask word initialization**: `TokenBitmask.init` initializes all words to `-1` (`0xFFFF_FFFF`, all allowed), and `fillNextTokenBitmask` updates/resets the target row. If reusing a raw buffer via `TokenBitmaskView`, you can reset words explicitly with `view.reset()`, `view.resetRow(i)`, or `xgrammar.resetBitmaskWords(words)`.
4. **Stop tokens & `isTerminated()` vs `isCompleted()`**:
   - `isCompleted()` becomes `true` as soon as the root rule can validly finish—valid tokens or a stop token may still follow.
   - `isTerminated()` becomes `true` after a stop token is accepted (or immediately upon `isCompleted()` if `GrammarMatcher.Options.terminate_without_stop_token = true`).
5. **Structural Tags with string token triggers**: `Grammar.fromStructuralTag` has no tokenizer (`vocab = null`), so formats referencing tokens by string (e.g., `{"type":"token","token":"<tool>"}`) fail with `InvalidStructuralTag` unless you use `Grammar.fromStructuralTagWithTokenizer(alloc, json, &tok, diag)` or `compiler.compileStructuralTag(json, diag)`.
6. **Thread-safety & matcher resets**: `GrammarCompiler` synchronizes its internal cache with a mutex; individual `GrammarMatcher` instances are stateful and not shared concurrently across threads for the same sequence (`BatchMatcher` parallelizes *across distinct matchers*). Reuse a matcher across requests with `try matcher.reset()`.

## Where to Look Next

- **Complete API Reference**: [references/api-reference.md](references/api-reference.md) — exact structs, defaults, functions, accessors, and error sets for every symbol in `xgrammar`.
- **Grammar Formats Guide**: [references/grammar-formats.md](references/grammar-formats.md) — JSON Schema & 9 XML tool formats, EBNF macros/attributes, Lark directives & `common.*` imports, Regex & Range helpers, and all 20 Structural Tag JSON schemas.
- **Tested Runnable Examples**: [examples/recipes.zig](examples/recipes.zig) — self-contained `zig test` recipes covering JSON Schema, HF detection, XML tool calls, Lark captures/temperatures, Structural Tags, `BatchMatcher` + `TokenBitmaskView`, speculative `traverseDraftTree`/`fork`/`rollback`, and `"v16"` serialization with zero memory leaks.
