# xgrammar-zig

**English** | [中文](README.zh-CN.md) | [日本語](README.ja.md)

Pure-Zig (**Zig 0.17.1**, zero external dependencies) port of **xgrammar-rs 0.2.8** (XGrammar-2 architecture) for grammar-constrained LLM decoding (JSON Schema / EBNF / Regex / Lark / Structural Tag -> token bitmask & logit masking), with idiomatic Zig 0.17 APIs and full bit-for-bit parity against the Rust reference oracle.

## Features

- **Zero-dependency pure Zig 0.17.1** codebase (`support -> tokenizer -> grammar -> parser/fsm/functor -> converter -> compiler -> matcher`).
- **Bit-for-bit Rust oracle parity**: verified via `tools/oracle.zig` (`zig-out/bin/xgrammar-oracle`) against `tools/oracle-rs/target/release/oracle` across `json_schema`, `ebnf`, `raw` / `byte_fallback` vocabularies, padded `vocab_size`, multi-byte UTF-8, multi-word bitmasks, and partial UTF-8 jump-forward strings.
- **Zig 0.17 idiomatic API** (alongside 1:1 `snake_case` parity APIs):
  - Default-valued `InitOptions` / `JsonSchemaOptions` on `TokenizerInfo.init`, `GrammarCompiler.init`, `compileJsonSchema`, and `GrammarMatcher.init`
  - First-class `TokenBitmask` with `@Vector(8, f32)` SIMD `applyToLogits` / `applyBatchToLogits`, `@popCount` + `@ctz` `countAllowed` / `singleAllowedToken`
  - `Grammar.format` supporting `{f}` formatting (`std.fmt.allocPrint(allocator, "{f}", .{grammar})`)
- **Performance & concurrency**:
  - Sharded thread-safe `RuleLevelCache` & `GrammarCompiler` cache backed by O(1) intrusive doubly-linked `LruCache` (`src/support/lru_cache.zig`)
  - Deterministic multi-threaded `build_adaptive_token_mask_cache` using `std.Thread.spawn` and thread-private scratch arenas (`max_threads`)

## Quickstart (Zig 0.17)

```zig
const std = @import("std");
const xgrammar = @import("xgrammar");

pub fn example(allocator: std.mem.Allocator) !void {
    const vocab = [_][]const u8{ "{\"ok\": ", "true", "false", "}", "</s>" };

    var tok = try xgrammar.TokenizerInfo.init(allocator, &vocab, .{
        .vocab_type = .Raw,
        .stop_token_ids = &.{4},
    });
    defer tok.deinit();

    const compiler = try xgrammar.GrammarCompiler.init(allocator, &tok, .{
        .max_threads = 4,
    });
    defer compiler.deinit();

    const schema =
        \\{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"],"additionalProperties":false}
    ;
    var compiled = try compiler.compileJsonSchema(schema, .{
        .any_whitespace = false,
        .strict_mode = true,
    });
    defer compiled.deinit();

    var matcher = try xgrammar.GrammarMatcher.init(allocator, &compiled, .{});
    defer matcher.deinit();

    var bitmask = try xgrammar.TokenBitmask.init(allocator, @intCast(tok.vocabSize()));
    defer bitmask.deinit();

    _ = try matcher.fillBitmask(&bitmask);
    var logits = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0 };
    bitmask.applyToLogits(&logits);
    _ = try matcher.acceptToken(0); // `{"ok": `
}
```

## Layout

- `src/` — Core library modules (`docs/PORTING.md` & `docs/PORTING_PROGRESS.md`)
- `src/oracle_parity_test.zig` — Golden bit-for-bit Rust oracle regression suite
- `src/idiomatic_api_test.zig` — Idiomatic Zig 0.17, SIMD bitmask, O(1) LRU, and parallel compilation tests
- `tools/oracle.zig` — Zig oracle binary built into `zig-out/bin/xgrammar-oracle`
- `tools/oracle-rs/` — Reference Rust oracle binary for side-by-side comparison

## Build, Test & Oracle Parity

```sh
# Build library and zig-out/bin/xgrammar-oracle
zig build

# Run full test suite (unit + parity + idiomatic APIs, 0 leaks)
zig build test
zig test src/xgrammar.zig

# Side-by-side oracle check
tools/oracle-rs/target/release/oracle < case.json > expected.json
zig-out/bin/xgrammar-oracle < case.json > actual.json
```

## Benchmarks (Zig vs Rust)

Measured side-by-side on Apple M3 (`arm64`, Zig `0.17.1 -Doptimize=ReleaseFast` vs `xgrammar-rs 0.2.8 --release`) over a 32K vocab, nested JSON Schema, 4-rule EBNF, and 33-token decode trace with identical output checksums (`bitmask_checksum = 9170455314173489972`):

- **Per-token decode (`fill + apply + accept`)**: Zig **`2.30 µs/tok`** vs Rust `13.89 µs/tok` (**6.03x faster**), driven by **7.62x–7.91x faster** `@Vector(8, f32)` SIMD logit masking (`1.76 µs` b=1, `6.80 µs` b=4) and ~parity mask fill (`1.48 µs` vs `1.38 µs`).
- **Compile & init**: Cold EBNF compilation is **`35.00 µs`** in Zig vs `60.17 µs` in Rust (**1.72x faster**) after sharing ref-counted `TokenizerInfo` storage (`cloneShared()`); 32K `TokenizerInfo` init (`5.30 ms` vs `2.92 ms`) and JSON Schema compilation (`3.38 ms` 4t vs `2.71 ms`) remain faster in Rust.

See [docs/BENCHMARKS.md](docs/BENCHMARKS.md) for the full comparison tables, optimization history (Stage 0 → Stage 1 → Stage 2), tradeoff analysis, and reproduction commands.
