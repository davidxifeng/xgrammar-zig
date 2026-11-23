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

在相同工作负载下对 **`xgrammar-zig`**（`tools/bench.zig`）与 **`xgrammar-rs 0.2.8`**（`tools/oracle-rs/src/bin/bench.rs`）进行了并排基准测试。

- **测试环境**：Apple M3（8 核，`arm64`），macOS 27.0.1，Zig `0.17.1`（`-Doptimize=ReleaseFast`），`rustc 1.99.1 (58cf8f9c3 2026-10-13)`（`--release`）
- **测试负载**：32,000 token `.Raw` 词表、嵌套 JSON Schema（`user` / `tags` / `score`）、4 规则递归算术 EBNF 文法，以及 33 token 的 JSON 解码轨迹
- **采样方式**：初始化/编译类测试为 1 次预热 + 5 次正式测量；掩码生成与端到端解码为 5 次预热 + 50 轮 33-token 轨迹；`b=1` logits 掩码应用为 20 次预热 + 200×25 次调用；`b=4` 批处理掩码应用为 10 次预热 + 100×10 次调用
- **一致性校验**：两侧输出的验证结果完全一致：`vocab_size = 32000`、`accepted_count = 33`、`bitmask_checksum = 9170455314173489972`

| 基准项 | Rust 中位数 (µs) | Zig 中位数 (µs) | 加速比 (Rust / Zig) | Rust 均值 (µs) | Zig 均值 (µs) |
|---|---:|---:|---:|---:|---:|
| `TokenizerInfo` 初始化（32K 词表） | 2978.58 | 5197.00 | 0.57x | 3101.83 | 5195.60 |
| 编译 JSON Schema（单线程） | 3190.21 | 5369.00 | 0.59x | 3247.83 | 5346.40 |
| 编译 JSON Schema（4 线程） | 2605.33 | 3414.00 | 0.76x | 2629.80 | 3408.00 |
| 编译 EBNF（单线程） | 55.88 | 407.00 | 0.14x | 60.11 | 409.00 |
| `fill_next_token_bitmask`（32K，单 token） | 1.35 | 1.42 | 0.94x | 1.37 | 1.45 |
| `apply_token_bitmask_inplace`（32K，`b=1`） | 13.25 | 1.72 | **7.70x** | 13.60 | 1.72 |
| `apply_token_bitmask_inplace_batch`（128K，`b=4`） | 52.73 | 6.50 | **8.11x** | 53.88 | 6.66 |
| 端到端解码：fill + apply + accept（32K，单 token） | 13.52 | 2.03 | **6.66x** | 13.83 | 2.04 |

**结论分析：**
- 在**单步解码热路径**上，Zig 的掩码生成速度与 Rust 持平（`1.42 µs` vs `1.35 µs`），基于 `@Vector(8, f32)` SIMD 的 logits 掩码应用速度是 Rust 的 **7.70x–8.11x**，使端到端单 token 解码速度达到 Rust 的 **6.66x**（`2.03 µs/tok` vs `13.52 µs/tok`）。
- 在**一次性初始化与冷编译路径**上，目前 Rust 更快（32K 词表初始化与 JSON Schema 编译快 1.3x–1.7x，小型 EBNF 编译快 7.3x）。在本次基准测试中，将 `TokenizerInfo` 中的 `std.sort.insertion` 替换为 `std.mem.sortUnstable` 后，32K 词表初始化耗时已从约 1.79 s 降至 5.20 ms。

### 复现基准测试

```sh
# 编译并运行 Zig ReleaseFast 基准测试
zig build -Doptimize=ReleaseFast
./zig-out/bin/xgrammar-bench

# 编译并运行 Rust (xgrammar-rs 0.2.8) Release 基准测试
cargo build --manifest-path tools/oracle-rs/Cargo.toml --release --bin bench
tools/oracle-rs/target/release/bench
```
