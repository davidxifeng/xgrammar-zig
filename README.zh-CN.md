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
