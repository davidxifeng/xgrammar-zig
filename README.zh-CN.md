# xgrammar-zig

[English](README.md) | **中文** | [日本語](README.ja.md)

面向语法约束 LLM 解码（JSON Schema / EBNF / Regex / Lark / Structural Tag -> token bitmask 与 logit 掩码）的纯 **Zig 0.17.1**（零外部依赖）移植实现，基于 **xgrammar-rs 0.2.8**（含 v0.2.9 关键正确性修复），以符合 Zig 0.17 习惯的值句柄、显式分配器与统一诊断体系为核心设计，并与 Rust 参考 Oracle 保持逐比特一致。

## 特性

- **零依赖纯 Zig 0.17.1 模块架构**：标准 `src/<module>.zig` + `src/<module>/` 结构（`support -> tokenizer -> fsm -> grammar -> parser -> functor -> converter -> compiler -> matcher`）。
- **与 Rust Oracle 逐比特一致**：通过 `tools/oracle.zig`（`zig-out/bin/xgrammar-oracle`）与 `tools/oracle-rs/target/release/oracle` 并排验证，覆盖 `json_schema`、`ebnf`、`raw` / `byte_fallback` 词表、填充 `vocab_size`、多字节 UTF-8、多字位掩码及整码点边界 jump-forward 字符串。
- **Zig 0.17 惯用公开 API**：
  - 原子引用计数句柄（`TokenizerInfo`、`CompactFsm`、`CompiledGrammar`）、基于 Arena 的 `Grammar` 值句柄与零拷贝 `GrammarBuilder`，以及统一 `Diagnostic`（支持 `{f}` 格式化）
  - `Grammar` 静态构造器（`fromEbnf`、`builtinJson`、`fromJsonSchema`、`fromRegex`、`fromLark`、`fromStructuralTag`、`unionOf`、`concatOf`）
  - 拥有所有权的 `TokenBitmask` 与借用视图 `TokenBitmaskView`：`@Vector(8, f32)` SIMD `applyToLogits` / `applyBatchToLogits` 及 `@popCount` + `@ctz` 位查询
  - 预热后 `fillNextTokenBitmask` 热路径零堆分配、支持 `max_threads` 的并行 `BatchMatcher`，以及零 DOM 流式 `v16` JSON 序列化与 `{f}` 格式化输出
- **并发与缓存**：
  - 分片加锁的 `RuleLevelCache` 与 `GrammarCompiler` 缓存基于 O(1) 侵入式 `LruCache`（[`src/support/lru_cache.zig`](src/support/lru_cache.zig)）
  - 多线程 `buildAdaptiveTokenMaskCache` 在每个工作线程内复用单个值嵌入的 `EarleyParser`，并由调用方分配器经 `ThreadSafeAllocator` 统一托管（无隐藏 `page_allocator`）

## 快速开始（Zig 0.17）

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

## 目录结构

- `src/xgrammar.zig` — 精简公开 API 根入口（内部子系统命名空间通过 `pub const internal` 暴露）
- `src/{support,tokenizer,fsm,grammar,parser,functor,converter,compiler,matcher}.zig` — 各子系统入口与内聚子模块（`src/` 共 `87` 个文件）
- `src/Diagnostic.zig` — 零值安全的统一诊断载体（支持 `{f}` 输出）
- `src/oracle_parity_test.zig`、`src/idiomatic_api_test.zig`、`src/upstream_v029_test.zig` — Oracle 回归、惯用 API 与缺陷修复验证、v0.2.9 专项测试
- `tools/oracle.zig`、`tools/bench.zig` — 生成 `zig-out/bin/xgrammar-oracle` 与 `zig-out/bin/xgrammar-bench`
- `tools/oracle-rs/` — 用于端到端比对的参考 Rust 二进制源码

## 构建、测试与 Oracle 对拍

```sh
# 构建库、xgrammar-oracle 与 xgrammar-bench
zig build

# 运行完整测试套件（单元测试 + Oracle 对拍 + API 回归 + v0.2.9 测试，零泄漏）
zig build test
zig test src/xgrammar.zig

# 端到端 Oracle 对比验证
tools/oracle-rs/target/release/oracle < case.json > expected.json
zig-out/bin/xgrammar-oracle < case.json > actual.json
```

## 性能基准测试（Zig vs Rust）

在 Apple M3（`arm64`，Zig `0.17.1 -Doptimize=ReleaseFast` vs `xgrammar-rs 0.2.8 --release`）上基于 32K 词表、嵌套 JSON Schema、4 规则 EBNF 与 33-token 解码轨迹进行了同负载并排测试（输出校验和一致：`bitmask_checksum = 9170455314173489972`）：

- **单步解码热路径（`fill + apply + accept`）**：Zig 为 **`2.12 µs/tok`**，Rust 为 `13.55 µs/tok`（**快 6.39x**）；预热后零堆分配的掩码生成达到 **`1.39 µs/tok`**（超越 Rust `1.42 µs/tok`），`@Vector(8, f32)` SIMD logits 掩码应用速度是 Rust 的 **7.42x–8.02x**（`b=1` `1.68 µs`，`b=4` `7.10 µs`）。
- **初始化与冷编译路径**：256 桶 MSD 基数分桶排序将 32K `TokenizerInfo.init` 降至 **`4.43 ms`**（较 Stage 2 提速 16.3%），状态复用缓存构建将 JSON Schema 冷编译降至 **`4.88 ms`（1 线程）/ `3.22 ms`（4 线程）**，单线程 EBNF 冷编译为 **`43.00 µs`**（最低 `35.00 µs`），快于 Rust `58.42 µs`（**1.36x**）。

完整 Stage 0 → Stage 3 对比数据与分析详见 [docs/BENCHMARKS.md](docs/BENCHMARKS.md)。
