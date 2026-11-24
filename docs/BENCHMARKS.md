# Benchmarks: `xgrammar-zig` vs `xgrammar-rs 0.2.8`

Side-by-side performance benchmarks comparing **`xgrammar-zig`** (`tools/bench.zig`) against the reference **`xgrammar-rs 0.2.8`** (`tools/oracle-rs/src/bin/bench.rs`) on identical constrained-decoding workloads.

## Test Environment & Methodology

- **Hardware & OS**: Apple M3 (8 cores, `arm64`), macOS 27.0.1
- **Toolchains**:
  - **Zig**: `0.17.1` built with `zig build -Doptimize=ReleaseFast`
  - **Rust**: `rustc 1.99.1 (58cf8f9c3 2026-10-13)` built with `cargo build --release` (`xgrammar-rs 0.2.8`)
- **Workload**:
  - 32,000-token `.raw` vocabulary (`stop_token_ids = &.{24}`)
  - Nested JSON Schema (`user` / `tags` / `score`, `additionalProperties: false`)
  - 4-rule recursive arithmetic EBNF grammar (`root`, `expr`, `term`, `factor`)
  - 33-token JSON decode trace for mask generation and end-to-end decoding
- **Sampling**:
  - Init / compile: 1 warmup + 5 timed iterations
  - `fillNextTokenBitmask` and E2E decode: 5 warmup + 50 timed 33-token passes
  - `applyToLogits` (`b=1`): 20 warmup + 200 batches × 25 calls
  - `applyBatchToLogits` (`b=4`, `4 × 32K = 128K` logits): 10 warmup + 100 batches × 10 calls
- **Parity Verification**: Across all runs, both binaries produced identical results:
  - `vocab_size = 32000`, `accepted_count = 33`, `bitmask_checksum = 9170455314173489972`

---

## Latest Results (Stage 3 — Idiomatic Zig 0.17 Refactor)

| Benchmark | Rust median (µs) | Zig median (µs) | Ratio (Rust / Zig) | Rust mean (µs) | Zig mean (µs) | Rust min (µs) | Zig min (µs) |
|---|---:|---:|---:|---:|---:|---:|---:|
| `TokenizerInfo` init (32K vocab) | 3077.71 | **4432.00** | 0.69x | 2984.98 | 4470.80 | 2776.00 | 3757.00 |
| Compile JSON Schema (1 thread) | 3493.17 | **4882.00** | 0.72x | 3417.67 | 4916.20 | 3164.58 | 4579.00 |
| Compile JSON Schema (4 threads) | 2953.50 | **3218.00** | 0.92x | 2899.46 | 3208.20 | 2666.75 | 3079.00 |
| Compile EBNF (1 thread) | 58.42 | **43.00** | **1.36x** | 59.22 | 62.00 | 56.08 | 35.00 |
| `fillNextTokenBitmask` (32K, /tok) | 1.42 | **1.39** | **1.02x** | 1.59 | 1.41 | 1.37 | 1.36 |
| `applyToLogits` (32K, `b=1`) | 13.47 | **1.68** | **8.02x** | 13.86 | 1.91 | 12.94 | 1.56 |
| `applyBatchToLogits` (128K, `b=4`) | 52.68 | **7.10** | **7.42x** | 53.70 | 7.51 | 51.66 | 6.50 |
| E2E decode: fill + apply + accept (32K, /tok) | 13.55 | **2.12** | **6.39x** | 13.84 | 2.37 | 13.37 | 1.91 |

---

## Optimization History & Preserved Results

All Zig median latencies below are in **µs** alongside the Stage-3 Rust baseline for reference:

| Benchmark | Stage 0 (Initial Port) | Stage 1 (`c19ff48`, Sort Fix) | Stage 2 (Shared + Slab) | Stage 3 (Current, Zero-Alloc + Radix) | Rust median (Stage 3) |
|---|---:|---:|---:|---:|---:|
| `TokenizerInfo` init (32K vocab) | 1,789,684.00 | 5,197.00 | 5,295.00 | **4,432.00** | 3,077.71 |
| Compile JSON Schema (1 thread) | — | 5,369.00 | 5,540.00 | **4,882.00** | 3,493.17 |
| Compile JSON Schema (4 threads) | 3,409.00 | 3,414.00 | 3,380.00 | **3,218.00** | 2,953.50 |
| Compile EBNF (1 thread) | 363.00 | 407.00 | 35.00 | **43.00** | 58.42 |
| `fillNextTokenBitmask` (32K, /tok) | 1.45 | 1.42 | 1.48 | **1.39** | 1.42 |
| `applyToLogits` (32K, `b=1`) | 1.68 | 1.72 | 1.76 | **1.68** | 13.47 |
| `applyBatchToLogits` (128K, `b=4`) | 7.10 | 6.50 | 6.80 | **7.10** | 52.68 |
| E2E decode: fill + apply + accept (32K, /tok) | 2.42 | 2.03 | 2.30 | **2.12** | 13.55 |

### Where Each Improvement Came From

1. **Stage 1 (`c19ff48`) — Replacing $O(N^2)$ vocab sort (~344× init speedup)**
   - Switched from $O(N^2)$ insertion sort across 32,000 tokens to $O(N \log N)$ pdqsort (`std.mem.sortUnstable`), cutting `TokenizerInfo` 32K initialization from `1,789,684 µs` to `~5,200 µs`.

2. **Stage 2 — Ref-counted `TokenizerInfo` + `.raw` slab packing (~11.6× EBNF compile speedup)**
   - Added atomic ref-counted `TokenizerStorage` (`retain()` / `sharesStorage()`) and single-slab packing for `.raw` vocab bytes, dropping cold 1-thread EBNF compilation from `407.00 µs` to `~35–43 µs`.

3. **Stage 3 (Current Refactor) — 256-Bucket Radix Sort, Parser Reuse & Zero-Alloc Decode Hot Path**
   - **256-bucket MSD radix partition + fast stop-token detection** ([`src/tokenizer/TokenizerInfo.zig`](../src/tokenizer/TokenizerInfo.zig)): Partitions `sorted_decoded_vocab` by first byte before sorting within each bucket (plus `'<'` prefix guard and bitset lookup for stop tokens), cutting 32K `TokenizerInfo.init` median from `5,295 µs` to **`4,432 µs`** (-16.3%).
   - **Value-embedded `EarleyParser` & `resetForState` cache-builder reuse** ([`src/compiler/token_mask_cache_builder.zig`](../src/compiler/token_mask_cache_builder.zig), [`src/functor/optimizer.zig`](../src/functor/optimizer.zig)): Reuses one `GrammarMatcherForTokenMaskCache` and `EarleyParser` per worker across all states via `resetWithInitialState` and adds zero-copy fast pass-throughs for non-`Repeat` and non-`lazy` grammars, reducing JSON Schema compilation latency to **`4,882 µs` (1t)** (-11.9%) / **`3,218 µs` (4t)** (-4.8%).
   - **Zero-allocation warmed-up bitmask generation** ([`src/matcher/GrammarMatcher.zig`](../src/matcher/GrammarMatcher.zig), [`src/parser/EarleyParser.zig`](../src/parser/EarleyParser.zig)): Moved per-step scratch buffers (`tmp_latest_states`, `tmp_states_with_masks`, `tmp_intset_scratch`) onto `GrammarMatcher` and eliminated temporary heap allocations in `advanceFsm`/`scanAtomicToken`/`advanceAtomicToken`, dropping `fillNextTokenBitmask` to **`1.39 µs/tok`** (ahead of Rust `1.42 µs/tok`) and E2E decode to **`2.12 µs/tok`** (**6.39x faster than Rust**).

---

## Performance Analysis & Tradeoffs

### Why Zig Leads on Decoding & Logit Masking (6.4×–8.0×)
- [`src/matcher/TokenBitmask.zig`](../src/matcher/TokenBitmask.zig) splits owned `TokenBitmask` and non-owning `TokenBitmaskView` and inspects each 32-bit bitmask word:
  - `w == -1` (all 32 tokens allowed) skips touching `logits`.
  - `w == 0` (all 32 tokens masked) lowers to `@memset(..., -inf)` (wide NEON stores).
  - Mixed words process 8 floats at a time with `@Vector(8, f32)` and branchless `@select`.
- `xgrammar-rs 0.2.8` checks tokens in a scalar loop with division/modulo per token and allocates a temporary `Vec<usize>` of row indices per batch call.

### Why Remaining Compile/Init Gaps Exist
- **JSON Schema compilation** (`3.22 ms` 4t / `4.88 ms` 1t vs Rust `2.95 ms` / `3.49 ms`): schema-to-EBNF expansion + Earley precomputation across ~20+ states, with worker threads synchronizing allocations via `ThreadSafeAllocator` over caller allocators rather than thread-local allocator heaps.
- **`TokenizerInfo` init** (`4.43 ms` vs Rust `3.08 ms`): remaining gap is single-byte radix bucket sort constants and `buildTrieRanges` byte-substring scans.

---

## Reproduce Benchmarks

```sh
# Build and run Zig release benchmark
zig build -Doptimize=ReleaseFast
./zig-out/bin/xgrammar-bench

# Build and run Rust (xgrammar-rs 0.2.8) release benchmark
cargo build --manifest-path tools/oracle-rs/Cargo.toml --release --bin bench
tools/oracle-rs/target/release/bench
```
