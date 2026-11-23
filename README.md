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

Measured side-by-side between **`xgrammar-zig`** (`tools/bench.zig`) and **`xgrammar-rs 0.2.8`** (`tools/oracle-rs/src/bin/bench.rs`) on identical workloads.

- **Environment**: Apple M3 (8 cores, `arm64`), macOS 27.0.1, Zig `0.17.1` (`-Doptimize=ReleaseFast`), `rustc 1.99.1 (58cf8f9c3 2026-10-13)` (`--release`)
- **Workload**: 32,000-token `.Raw` vocabulary, nested JSON Schema (`user` / `tags` / `score`), 4-rule recursive arithmetic EBNF grammar, and a 33-token JSON decode trace
- **Sampling**: 1 warmup + 5 timed runs for init/compile benchmarks; 5 warmup + 50 timed 33-token passes for mask fill and E2E decode; 20 warmup + 200x25 calls for `b=1` logit masking; 10 warmup + 100x10 calls for `b=4` logit masking
- **Parity check**: Both binaries produced identical outputs: `vocab_size = 32000`, `accepted_count = 33`, `bitmask_checksum = 9170455314173489972`

| Benchmark | Rust median (µs) | Zig median (µs) | Ratio (Rust / Zig) | Rust mean (µs) | Zig mean (µs) |
|---|---:|---:|---:|---:|---:|
| `TokenizerInfo` init (32K vocab) | 2978.58 | 5197.00 | 0.57x | 3101.83 | 5195.60 |
| Compile JSON Schema (1 thread) | 3190.21 | 5369.00 | 0.59x | 3247.83 | 5346.40 |
| Compile JSON Schema (4 threads) | 2605.33 | 3414.00 | 0.76x | 2629.80 | 3408.00 |
| Compile EBNF (1 thread) | 55.88 | 407.00 | 0.14x | 60.11 | 409.00 |
| `fill_next_token_bitmask` (32K, /tok) | 1.35 | 1.42 | 0.94x | 1.37 | 1.45 |
| `apply_token_bitmask_inplace` (32K, `b=1`) | 13.25 | 1.72 | **7.70x** | 13.60 | 1.72 |
| `apply_token_bitmask_inplace_batch` (128K, `b=4`) | 52.73 | 6.50 | **8.11x** | 53.88 | 6.66 |
| E2E decode: fill + apply + accept (32K, /tok) | 13.52 | 2.03 | **6.66x** | 13.83 | 2.04 |

**Takeaways:**
- On the **per-token decoding hot path**, Zig matches Rust on bitmask generation (`1.42 µs` vs `1.35 µs`) and is **7.70x–8.11x faster** on `@Vector(8, f32)` SIMD logit masking, yielding **6.66x faster end-to-end decoding** (`2.03 µs/tok` vs `13.52 µs/tok`).
- On **one-time initialization and cold compilation**, Rust is currently faster (1.3x–1.7x on 32K vocab init / JSON Schema compilation, and 7.3x on tiny EBNF compilation). Replacing `std.sort.insertion` in `TokenizerInfo` with `std.mem.sortUnstable` reduced 32K vocab init from ~1.79 s to 5.20 ms.

### Reproduce Benchmarks

```sh
# Build and run Zig release benchmark
zig build -Doptimize=ReleaseFast
./zig-out/bin/xgrammar-bench

# Build and run Rust (xgrammar-rs 0.2.8) release benchmark
cargo build --manifest-path tools/oracle-rs/Cargo.toml --release --bin bench
tools/oracle-rs/target/release/bench
```
