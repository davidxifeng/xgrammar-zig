# xgrammar-zig

[English](README.md) | **中文** | [日本語](README.ja.md)

面向语法约束 LLM 解码（JSON Schema / EBNF / Regex / Lark / Structural Tag -> token bitmask 与 logit 掩码）的纯 **Zig 0.17.1**（零外部依赖）移植实现，基于 **xgrammar-rs 0.2.8**（XGrammar-2 架构），同时提供符合 Zig 0.17 习惯的现代 API，并与 Rust 参考 Oracle 保持逐比特一致。

## 特性

- **零依赖纯 Zig 0.17.1 实现**：分层模块架构（`support -> tokenizer -> grammar -> parser/fsm/functor -> converter -> compiler -> matcher`）。
- **与 Rust Oracle 逐比特一致**：通过 `tools/oracle.zig`（`zig-out/bin/xgrammar-oracle`）与 `tools/oracle-rs/target/release/oracle` 对拍验证，覆盖 `json_schema`、`ebnf`、`raw` / `byte_fallback` 词表、填充的 `vocab_size`、多字节 UTF-8、多字位掩码及局部 UTF-8 jump-forward 字符串。
- **Zig 0.17 惯用 API**（并完整保留 `snake_case` 1:1 对拍接口）：
  - `TokenizerInfo.init`、`GrammarCompiler.init`、`compileJsonSchema`、`GrammarMatcher.init` 均提供带默认值的 `InitOptions` / `JsonSchemaOptions`
  - 一等值类型 `TokenBitmask`：基于 `@Vector(8, f32)` SIMD 的 `applyToLogits` / `applyBatchToLogits`，以及基于 `@popCount` + `@ctz` 的 `countAllowed` / `singleAllowedToken`
  - `Grammar.format` 支持 `{f}` 格式化输出（`std.fmt.allocPrint(allocator, "{f}", .{grammar})`）
- **性能与并发**：
  - 分片线程安全 `RuleLevelCache` 与 `GrammarCompiler` 缓存均采用 O(1) 侵入式双链表 `LruCache`（`src/support/lru_cache.zig`）
  - 支持通过 `max_threads` 启用确定性多线程 `build_adaptive_token_mask_cache`（`std.Thread.spawn` + 每线程私有 scratch arena）

## 快速开始（Zig 0.17）

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

## 目录结构

- `src/` — 核心库模块树（契约与进度见 `docs/PORTING.md` 与 `docs/PORTING_PROGRESS.md`）
- `src/oracle_parity_test.zig` — 固化 Rust Oracle 黄金数据的比特级回归测试集
- `src/idiomatic_api_test.zig` — Zig 0.17 惯用 API、SIMD bitmask、O(1) LRU 与多线程编译测试
- `tools/oracle.zig` — 编译生成 `zig-out/bin/xgrammar-oracle` 的对拍工具
- `tools/oracle-rs/` — 用于端到端比对的参考 Rust Oracle 二进制源码

## 构建、测试与 Oracle 对拍

```sh
# 构建库与 zig-out/bin/xgrammar-oracle
zig build

# 运行完整测试套件（单元测试 + Oracle 回归 + 惯用 API 测试，零泄漏）
zig build test
zig test src/xgrammar.zig

# 端到端 Oracle 对比验证
tools/oracle-rs/target/release/oracle < case.json > expected.json
zig-out/bin/xgrammar-oracle < case.json > actual.json
```

## 性能基准测试（Zig vs Rust）

在 Apple M3（`arm64`，Zig `0.17.1 -Doptimize=ReleaseFast` vs `xgrammar-rs 0.2.8 --release`）上基于 32K 词表、嵌套 JSON Schema、4 规则 EBNF 与 33-token 解码轨迹进行了同负载并排测试（输出校验和一致：`bitmask_checksum = 9170455314173489972`）：

- **单步解码热路径（`fill + apply + accept`）**：Zig 为 **`2.30 µs/tok`**，Rust 为 `13.89 µs/tok`（**快 6.03x**）；掩码生成基本持平（`1.48 µs` vs `1.38 µs`），基于 `@Vector(8, f32)` SIMD 的 logits 掩码应用速度是 Rust 的 **7.62x–7.91x**（`b=1` `1.76 µs`，`b=4` `6.80 µs`）。
- **冷启动与编译路径**：引入 `TokenizerInfo` 引用计数共享（`cloneShared()`）并消除每次编译深拷贝 32K 词表后，Zig 单线程 EBNF 编译耗时从 `407.00 µs` 降至 **`35.00 µs`**（Rust `60.17 µs`，**反超 1.72x**）；32K 词表初始化（`5.30 ms` vs `2.92 ms`）与 JSON Schema 编译（4 线程 `3.38 ms` vs `2.71 ms`）目前仍由 Rust 领先。

完整对比表格、各优化阶段的历史数据、原因/权衡分析及复现命令详见 [docs/BENCHMARKS.md](docs/BENCHMARKS.md)。
