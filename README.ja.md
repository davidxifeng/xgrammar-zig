# xgrammar-zig

[English](README.md) | [中文](README.zh-CN.md) | **日本語**

文法制約付き LLM デコーディング（JSON Schema / EBNF / Regex / Lark / Structural Tag -> token bitmask および logit マスク）向けの純粋 **Zig 0.17.1**（外部依存ゼロ）移植版です。**xgrammar-rs 0.2.8**（XGrammar-2 アーキテクチャ）をベースとし、Zig 0.17 イディオマティックな API と Rust リファレンス Oracle とのビット単位完全一致を実現しています。

## 特徴

- **外部依存ゼロの純粋 Zig 0.17.1 実装**：階層モジュール構成（`support -> tokenizer -> grammar -> parser/fsm/functor -> converter -> compiler -> matcher`）。
- **Rust Oracle とのビット単位パリティ**：`tools/oracle.zig`（`zig-out/bin/xgrammar-oracle`）と `tools/oracle-rs/target/release/oracle` を比較検証済み。`json_schema`、`ebnf`、`raw` / `byte_fallback` 語彙、パディング済み `vocab_size`、マルチバイト UTF-8、マルチワード bitmask、部分 UTF-8 の jump-forward 文字列に対応。
- **Zig 0.17 イディオマティック API**（既存の 1:1 `snake_case` API もすべて維持）：
  - `TokenizerInfo.init`、`GrammarCompiler.init`、`compileJsonSchema`、`GrammarMatcher.init` におけるデフォルト値付き `InitOptions` / `JsonSchemaOptions`
  - ファーストクラス型 `TokenBitmask`：`@Vector(8, f32)` SIMD による `applyToLogits` / `applyBatchToLogits`、および `@popCount` + `@ctz` による `countAllowed` / `singleAllowedToken`
  - `Grammar.format` による `{f}` フォーマット出力（`std.fmt.allocPrint(allocator, "{f}", .{grammar})`）
- **パフォーマンスと並行処理**：
  - シャード化されたスレッドセーフな `RuleLevelCache` と `GrammarCompiler` キャッシュに O(1) イントルーシブ双方向連結リスト `LruCache`（`src/support/lru_cache.zig`）を採用
  - `max_threads` による決定論的なマルチスレッド `build_adaptive_token_mask_cache`（`std.Thread.spawn` + スレッドローカルなスクラッチ arena）

## クイックスタート（Zig 0.17）

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

## ディレクトリ構成

- `src/` — コアライブラリモジュール（規約と進捗は `docs/PORTING.md`・`docs/PORTING_PROGRESS.md` を参照）
- `src/oracle_parity_test.zig` — Rust Oracle のゴールデン出力を用いたビット単位リグレッションテスト
- `src/idiomatic_api_test.zig` — Zig 0.17 イディオマティック API・SIMD bitmask・O(1) LRU・並列コンパイルのテスト
- `tools/oracle.zig` — `zig-out/bin/xgrammar-oracle` としてビルドされる検証用 Oracle CLI
- `tools/oracle-rs/` — 比較検証用の Rust 版リファレンス Oracle

## ビルド・テスト・Oracle パリティ検証

```sh
# ライブラリと zig-out/bin/xgrammar-oracle をビルド
zig build

# 全テストスイートを実行（単体テスト + Oracle パリティ + イディオマティック API、リークゼロ）
zig build test
zig test src/xgrammar.zig

# Rust 版と Zig 版 Oracle の並列比較
tools/oracle-rs/target/release/oracle < case.json > expected.json
zig-out/bin/xgrammar-oracle < case.json > actual.json
```

## ベンチマーク（Zig vs Rust）

同一ワークロードを用いて、**`xgrammar-zig`**（`tools/bench.zig`）と **`xgrammar-rs 0.2.8`**（`tools/oracle-rs/src/bin/bench.rs`）のベンチマークを計測しました。

- **計測環境**: Apple M3（8 コア、`arm64`）、macOS 27.0.1、Zig `0.17.1`（`-Doptimize=ReleaseFast`）、`rustc 1.99.1 (58cf8f9c3 2026-10-13)`（`--release`）
- **ワークロード**: 32,000 トークン `.Raw` 語彙、ネストされた JSON Schema（`user` / `tags` / `score`）、4 ルール再帰算術 EBNF 文法、33 トークン JSON デコードトレース
- **サンプリング条件**: 初期化・コンパイル項目はウォームアップ 1 回 + 本計測 5 回、ビットマスク生成と E2E デコードはウォームアップ 5 回 + 33 トークンパス 50 回、`b=1` ロジットマスク適用はウォームアップ 20 回 + 200×25 回、`b=4` バッチ適用はウォームアップ 10 回 + 100×10 回
- **整合性検証**: 両実装で完全一致の結果を確認済み（`vocab_size = 32000`、`accepted_count = 33`、`bitmask_checksum = 9170455314173489972`）

| ベンチマーク項目 | Rust 中央値 (µs) | Zig 中央値 (µs) | 高速化倍率 (Rust / Zig) | Rust 平均値 (µs) | Zig 平均値 (µs) |
|---|---:|---:|---:|---:|---:|
| `TokenizerInfo` 初期化（32K 語彙） | 2978.58 | 5197.00 | 0.57x | 3101.83 | 5195.60 |
| JSON Schema コンパイル（1 スレッド） | 3190.21 | 5369.00 | 0.59x | 3247.83 | 5346.40 |
| JSON Schema コンパイル（4 スレッド） | 2605.33 | 3414.00 | 0.76x | 2629.80 | 3408.00 |
| EBNF コンパイル（1 スレッド） | 55.88 | 407.00 | 0.14x | 60.11 | 409.00 |
| `fill_next_token_bitmask`（32K、1 トークン） | 1.35 | 1.42 | 0.94x | 1.37 | 1.45 |
| `apply_token_bitmask_inplace`（32K、`b=1`） | 13.25 | 1.72 | **7.70x** | 13.60 | 1.72 |
| `apply_token_bitmask_inplace_batch`（128K、`b=4`） | 52.73 | 6.50 | **8.11x** | 53.88 | 6.66 |
| E2E デコード: fill + apply + accept（32K、1 トークン） | 13.52 | 2.03 | **6.66x** | 13.83 | 2.04 |

**結果の要約:**
- **トークンごとのデコードホットパス**では、Zig はビットマスク生成で Rust と同等（`1.42 µs` vs `1.35 µs`）、`@Vector(8, f32)` SIMD によるロジットマスク適用で **7.70x–8.11x 高速**、結果として **E2E デコード全体で 6.66x 高速**（`2.03 µs/tok` vs `13.52 µs/tok`）になりました。
- **初回初期化とコールドコンパイル**では、現時点で Rust の方が高速です（32K 語彙初期化・JSON Schema コンパイルで 1.3x–1.7x、小規模 EBNF コンパイルで 7.3x）。なお、`TokenizerInfo` 内の `std.sort.insertion` を `std.mem.sortUnstable` に置き換えたことで、Zig の 32K 語彙初期化は約 1.79 s から 5.20 ms まで高速化されました。

### ベンチマークの再実行手順

```sh
# Zig ReleaseFast ベンチマークのビルドと実行
zig build -Doptimize=ReleaseFast
./zig-out/bin/xgrammar-bench

# Rust (xgrammar-rs 0.2.8) Release ベンチマークのビルドと実行
cargo build --manifest-path tools/oracle-rs/Cargo.toml --release --bin bench
tools/oracle-rs/target/release/bench
```
