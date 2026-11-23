# Benchmarks: `xgrammar-zig` vs `xgrammar-rs 0.2.8`

Side-by-side performance benchmarks comparing **`xgrammar-zig`** (`tools/bench.zig`) against the reference **`xgrammar-rs 0.2.8`** (`tools/oracle-rs/src/bin/bench.rs`) on identical constrained-decoding workloads.

## Test Environment & Methodology

- **Hardware & OS**: Apple M3 (8 cores, `arm64`), macOS 27.0.1
- **Toolchains**:
  - **Zig**: `0.17.1` built with `zig build -Doptimize=ReleaseFast`
  - **Rust**: `rustc 1.99.1 (58cf8f9c3 2026-10-13)` built with `cargo build --release` (`xgrammar-rs 0.2.8`)
- **Workload**:
  - 32,000-token `.Raw` vocabulary (`stop_ids = [24]`)
  - Nested JSON Schema (`user` / `tags` / `score`, `additionalProperties: false`)
  - 4-rule recursive arithmetic EBNF grammar (`root`, `expr`, `term`, `factor`)
  - 33-token JSON decode trace for mask generation and end-to-end decoding
- **Sampling**:
  - Init / compile: 1 warmup + 5 timed iterations
  - `fill_next_token_bitmask` and E2E decode: 5 warmup + 50 timed 33-token passes
  - `apply_token_bitmask_inplace` (`b=1`): 20 warmup + 200 batches × 25 calls
  - `apply_token_bitmask_inplace_batch` (`b=4`, `4 × 32K = 128K` logits): 10 warmup + 100 batches × 10 calls
- **Parity Verification**: Across all runs, both binaries produced identical results:
  - `vocab_size = 32000`, `accepted_count = 33`, `bitmask_checksum = 9170455314173489972`

---

## Latest Results (Stage 2)

| Benchmark | Rust median (µs) | Zig median (µs) | Ratio (Rust / Zig) | Rust mean (µs) | Zig mean (µs) | Rust min (µs) | Zig min (µs) |
|---|---:|---:|---:|---:|---:|---:|---:|
| `TokenizerInfo` init (32K vocab) | 2920.79 | 5295.00 | 0.55x | 2908.63 | 5375.40 | 2719.04 | 5030.00 |
| Compile JSON Schema (1 thread) | 3257.38 | 5540.00 | 0.59x | 3388.00 | 5508.40 | 3187.58 | 5234.00 |
| Compile JSON Schema (4 threads) | 2707.33 | 3380.00 | 0.80x | 2698.16 | 3371.00 | 2623.54 | 3164.00 |
| Compile EBNF (1 thread) | 60.17 | **35.00** | **1.72x** | 61.18 | 37.20 | 58.08 | 34.00 |
| `fill_next_token_bitmask` (32K, /tok) | 1.38 | 1.48 | 0.93x | 1.38 | 1.54 | 1.37 | 1.45 |
| `apply_token_bitmask_inplace` (32K, `b=1`) | 13.41 | **1.76** | **7.62x** | 13.89 | 1.78 | 13.05 | 1.60 |
| `apply_token_bitmask_inplace_batch` (128K, `b=4`) | 53.76 | **6.80** | **7.91x** | 55.57 | 7.32 | 52.24 | 6.50 |
| E2E decode: fill + apply + accept (32K, /tok) | 13.89 | **2.30** | **6.03x** | 14.27 | 2.32 | 13.54 | 2.27 |

---

## Optimization History & Preserved Results

All Zig median latencies below are in **µs** alongside the Stage-2 Rust baseline for reference:

| Benchmark | Stage 0 (Initial Port) | Stage 1 (`c19ff48`, Sort Fix) | Stage 2 (Current, Shared + Slab) | Rust median (Stage 2) |
|---|---:|---:|---:|---:|
| `TokenizerInfo` init (32K vocab) | 1,789,684.00 | 5,197.00 | 5,295.00 | 2,920.79 |
| Compile JSON Schema (1 thread) | — | 5,369.00 | 5,540.00 | 3,257.38 |
| Compile JSON Schema (4 threads) | 3,409.00 | 3,414.00 | 3,380.00 | 2,707.33 |
| Compile EBNF (1 thread) | 363.00 | 407.00 | **35.00** | 60.17 |
| `fill_next_token_bitmask` (32K, /tok) | 1.45 | 1.42 | 1.48 | 1.38 |
| `apply_token_bitmask_inplace` (32K, `b=1`) | 1.68 | 1.72 | 1.76 | 13.41 |
| `apply_token_bitmask_inplace_batch` (128K, `b=4`) | 7.10 | 6.50 | 6.80 | 53.76 |
| E2E decode: fill + apply + accept (32K, /tok) | 2.42 | 2.03 | 2.30 | 13.89 |

### Where Each Improvement Came From

1. **Stage 1 (`c19ff48`) — Replacing $O(N^2)$ vocab sort (~344× init speedup)**
   - **Cause**: [`src/tokenizer/tokenizer_info.zig`](../src/tokenizer/tokenizer_info.zig) originally used `std.sort.insertion` across 32,000 tokens, causing $O(N^2)$ scaling (`1.79 s`).
   - **Fix**: Switched to $O(N \log N)$ `std.mem.sortUnstable` with explicit `lhs.id < rhs.id` tie-breaking to match Rust's stable `sort_by` determinism.
   - **Impact**: Cut `TokenizerInfo` 32K initialization from `1,789,684 µs` to `~5,200 µs`.

2. **Stage 2 — Ref-counted `TokenizerInfo` + capacity pre-allocation (~11.6× EBNF compile speedup)**
   - **Cause**: [`GrammarCompiler.new`](../src/compiler/grammar_compiler.zig), [`CompiledGrammar.build`](../src/compiler/compiled_grammar.zig), and `CompiledGrammar.deserialize_json_value` previously called `tokenizer.clone(allocator)`, deep-copying the entire 32K vocabulary arena and derived arrays (`~370 µs` overhead) on every cold grammar compilation — dwarfing the actual compilation of small EBNF grammars (`407 µs` total vs Rust `55–60 µs`).
   - **Fix**:
     - Added atomic ref-counted `TokenizerStorage` inside [`TokenizerInfo`](../src/tokenizer/tokenizer_info.zig) with `cloneShared()` (zero-copy handle copy) and `sharesStorage()`, while retaining `deepClone(allocator)` / `clone(allocator)` when an independent allocator lifetime is required.
     - Updated `GrammarCompiler` and `CompiledGrammar` to use `cloneShared()`, matching `xgrammar-rs`'s `Arc<TokenizerInfo>` ownership model and saving per-cached-grammar memory too.
     - Pre-allocated `decoded_vocab` and `sorted_decoded_vocab` capacities in `new_from_bytes`, packed `.Raw` token bytes into a single contiguous slab (zero per-token arena calls), and moved `build_trie_ranges`'s temporary stack to the caller's scratch allocator so it does not linger in the arena.
   - **Impact**: Cold 1-thread EBNF compilation dropped from `407.00 µs` to **`35.00 µs`** (**11.6× faster** than Stage 1, flipping from `0.14×` behind Rust to **`1.72×` faster than Rust**).

---

## Performance Analysis & Tradeoffs

### Why Zig Leads on Decoding & Logit Masking (6×–8×)
- [`src/matcher/token_bitmask.zig`](../src/matcher/token_bitmask.zig) inspects each 32-bit bitmask word:
  - `w == -1` (all 32 tokens allowed) skips reading/writing `logits` completely.
  - `w == 0` (all 32 tokens masked) lowers to `@memset(..., -inf)` (wide NEON stores). During structured JSON decoding, most 32-token blocks are all-zero.
  - Mixed words process 8 floats at a time with `@Vector(8, f32)` and branchless `@select`.
- `xgrammar-rs 0.2.8` (`token_bitmask.rs`) checks tokens in a scalar loop with division/modulo per token and allocates a temporary `Vec<usize>` of row indices per batch call.

### Why Remaining Compile/Init Gaps Exist
- **JSON Schema compilation** (`3.38 ms` 4t / `5.54 ms` 1t vs Rust `2.71 ms` / `3.26 ms`): dominated by schema-to-EBNF expansion, grammar optimizer passes, Earley precomputation across ~20+ states, and Zig worker threads cloning `AdaptiveTokenMask` under an output mutex from thread-local `ArenaAllocator`s (whereas Rayon moves owned `Vec`s directly).
- **`TokenizerInfo` init** (`5.30 ms` vs Rust `2.92 ms`): pre-allocation and `.Raw` slab packing eliminated per-token arena overhead; remaining difference is sorting algorithm constants (`std.mem.sortUnstable` pdqsort with `(token, id)` comparator vs Rust's driftsort/timsort on partially patterned tokens) and `build_trie_ranges` substring scans.

### Ref-Counted `TokenizerInfo` Tradeoffs
- **Allocator lifetime contract**: Sharing storage avoids deep-copying 32K tokens, which means the allocator that originally constructed `TokenizerInfo` must outlive all `GrammarCompiler` / `CompiledGrammar` / `cloneShared()` handles derived from it. Pass `deepClone(allocator)` whenever objects must outlive a temporary allocator.
- **Manual refcount pairing**: Unlike Rust's `Arc`, Zig structs have no `Drop` hook, so every `cloneShared()` must be paired with `deinit()`. Keeping slice/scalar views directly on the `TokenizerInfo` value preserved zero API breakage and zero hot-path pointer chasing.

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
