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

Apple M3（`arm64`、Zig `0.17.1 -Doptimize=ReleaseFast` vs `xgrammar-rs 0.2.8 --release`）にて 32K 語彙・ネスト JSON Schema・4 ルール EBNF・33 トークンデコードトレースで並列計測しました（整合性チェックサム完全一致：`bitmask_checksum = 9170455314173489972`）：

- **トークン単位のデコード（`fill + apply + accept`）**：Zig **`2.30 µs/tok`** vs Rust `13.89 µs/tok`（**6.03x 高速**）。マスク生成は同等（`1.48 µs` vs `1.38 µs`）、`@Vector(8, f32)` SIMD ロジットマスク適用が **7.62x–7.91x 高速**（`b=1` `1.76 µs`、`b=4` `6.80 µs`）です。
- **初期化とコールドコンパイル**：参照カウント共有 `TokenizerInfo`（`cloneShared()`）の導入で毎コンパイルの 32K 語彙ディープコピーを撤廃した結果、EBNF 単スレッドコンパイルは `407.00 µs` から **`35.00 µs`** へ短縮し Rust（`60.17 µs`）より **1.72x 高速**になりました。32K 語彙初期化（`5.30 ms` vs `2.92 ms`）および JSON Schema コンパイル（4 スレッド `3.38 ms` vs `2.71 ms`）では現時点で Rust が高速です。

全計測表、最適化段階ごとの履歴、設計トレードオフ、再実行手順は [docs/BENCHMARKS.md](docs/BENCHMARKS.md) を参照してください。
