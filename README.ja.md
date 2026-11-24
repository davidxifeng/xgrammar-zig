# xgrammar-zig

[English](README.md) | [中文](README.zh-CN.md) | **日本語**

文法制約付き LLM デコーディング（JSON Schema / EBNF / Regex / Lark / Structural Tag -> token bitmask および logit マスク）向けの純粋 **Zig 0.17.1**（外部依存ゼロ）移植版です。**xgrammar-rs 0.2.8**（v0.2.9 修正を含む）をベースとし、Zig 0.17 イディオマティックな値ハンドル API・明示的アロケータ管理・Rust リファレンス Oracle とのビット単位完全一致を実現しています。

## 特徴

- **外部依存ゼロの純粋 Zig 0.17.1 構成**：標準的な `src/<module>.zig` + `src/<module>/` 階層（`support -> tokenizer -> fsm -> grammar -> parser -> functor -> converter -> compiler -> matcher`）。
- **Rust Oracle とのビット単位パリティ**：`tools/oracle.zig`（`zig-out/bin/xgrammar-oracle`）と `tools/oracle-rs/target/release/oracle` で比較検証済み。`json_schema`、`ebnf`、`raw` / `byte_fallback` 語彙、パディング済み `vocab_size`、マルチバイト UTF-8、マルチワード bitmask、コードポイント境界準拠の jump-forward 文字列に対応。
- **Zig 0.17 イディオマティック API**：
  - アトミック参照カウントハンドル（`TokenizerInfo`、`CompactFsm`、`CompiledGrammar`）、Arena バックド `Grammar` + ゼロコピー `GrammarBuilder`、統一 `Diagnostic`（`{f}` フォーマット）
  - 静的コンストラクタ（`Grammar.fromEbnf`、`Grammar.builtinJson`、`Grammar.fromJsonSchema`、`Grammar.fromRegex`、`Grammar.fromLark`、`Grammar.fromStructuralTag`、`Grammar.unionOf`、`Grammar.concatOf`）
  - 所有権を持つ `TokenBitmask` と非所有ビュー `TokenBitmaskView`：`@Vector(8, f32)` SIMD による `applyToLogits` / `applyBatchToLogits`、および `@popCount` + `@ctz` ビット検索
  - ウォームアップ後の `fillNextTokenBitmask` ヒープ確保ゼロ化、`max_threads` 並列 `BatchMatcher`、DOM レス・ストリーミング `v16` JSON シリアライズ
- **並行処理とキャッシュ**：
  - シャード単位ミューテックス保護付き `RuleLevelCache` と `GrammarCompiler` キャッシュ（O(1) `LruCache`：[`src/support/lru_cache.zig`](src/support/lru_cache.zig)）
  - `ThreadSafeAllocator` 上でワーカースレッドごとに値埋め込み `EarleyParser` を再利用する並列 `buildAdaptiveTokenMaskCache`（`page_allocator` 非使用）

## クイックスタート（Zig 0.17）

```zig
const std = @import("std");
const xgrammar = @import("xgrammar");

pub fn example(allocator: std.mem.Allocator) !void {
    const vocab = [_][]const u8{ "{\"ok\": ", "true", "false", "}", "</s>" };

    var tok = try xgrammar.TokenizerInfo.init(allocator, &vocab, .{
        .vocab_type = .raw,
        .stop_token_ids = &.{4},
    });
    defer tok.deinit();

    var compiler = try xgrammar.GrammarCompiler.init(allocator, &tok, .{
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

    var bitmask = try xgrammar.TokenBitmask.initSingle(allocator, tok.vocabSize());
    defer bitmask.deinit();

    _ = try matcher.fillNextTokenBitmask(&bitmask, 0, null);
    var logits = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0 };
    bitmask.applyToLogits(&logits);
    _ = try matcher.acceptToken(0, null); // `{"ok": `
}
```

## ディレクトリ構成

- `src/xgrammar.zig` — 公開 API ルート（内部サブシステムは `pub const internal` 経由で公開）
- `src/{support,tokenizer,fsm,grammar,parser,functor,converter,compiler,matcher}.zig` — 各サブシステム本体と集約サブモジュール（`src/` 配下計 `87` ファイル）
- `src/Diagnostic.zig` — ゼロ値初期化安全な統一診断キャリア（`{f}` 対応）
- `src/oracle_parity_test.zig`・`src/idiomatic_api_test.zig`・`src/upstream_v029_test.zig` — Oracle パリティ・API/リグレッション・v0.2.9 検証スイート
- `tools/oracle.zig` / `tools/bench.zig` — `zig-out/bin/xgrammar-oracle` および `zig-out/bin/xgrammar-bench`
- `tools/oracle-rs/` — 比較検証用の Rust 版リファレンス Oracle・ベンチマーク

## ビルド・テスト・Oracle パリティ検証

```sh
# ライブラリと xgrammar-oracle / xgrammar-bench をビルド
zig build

# 全テストスイートを実行（単体テスト + Oracle パリティ + イディオマティック API、リークゼロ）
zig build test
zig test src/xgrammar.zig

# Rust 版と Zig 版 Oracle の並列比較
tools/oracle-rs/target/release/oracle < case.json > expected.json
zig-out/bin/xgrammar-oracle < case.json > actual.json
```

## ベンチマーク（Zig vs Rust）

Apple M3（`arm64`、Zig `0.17.1 -Doptimize=ReleaseFast` vs `xgrammar-rs 0.2.8 --release`）にて 32K 語彙・ネスト JSON Schema・4 ルール EBNF・33 トークンデコードトレースで並列計測しました（整合性チェックサム一致：`bitmask_checksum = 9170455314173489972`）：

- **トークン単位のデコード（`fill + apply + accept`）**：Zig **`2.12 µs/tok`** vs Rust `13.55 µs/tok`（**6.39x 高速**）。ウォームアップ後ヒープ確保ゼロのマスク生成は **`1.39 µs/tok`**（Rust `1.42 µs/tok` を上回る）、`@Vector(8, f32)` SIMD ロジットマスク適用は **7.42x–8.02x 高速**（`b=1` `1.68 µs`、`b=4` `7.10 µs`）です。
- **初期化とコールドコンパイル**：256 バケット MSD 基数パーティションにより 32K `TokenizerInfo.init` を **`4.43 ms`** へ短縮（Stage 2 比 16.3% 改善）、`EarleyParser` 再利用により JSON Schema コンパイルを **`4.88 ms`（1t）/ `3.22 ms`（4t）** へ改善し、EBNF 単スレッドコンパイルは **`43.00 µs`**（最小 `35.00 µs`）vs Rust `58.42 µs`（**1.36x 高速**）を達成しました。

Stage 0 → Stage 3 の全計測表と再現手順は [docs/BENCHMARKS.md](docs/BENCHMARKS.md) を参照してください。
