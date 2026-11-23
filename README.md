# xgrammar-zig

xgrammar-rs **0.2.8**(XGrammar-2 架构)的纯 Zig 直译移植。零外部依赖,
Zig 0.17.1。目标:为 kajikiri 的 OpenAI 兼容服务端提供语法约束采样
(JSON Schema / EBNF → token bitmask)。

## 状态

移植中,按依赖分五波(support → grammar/tokenizer → parser/fsm/functor →
converter → compiler → matcher)。进度见 `docs/PORTING_PROGRESS.md`。

## 布局

- `src/` — 模块树 1:1 镜像参照(契约见 `docs/PORTING.md`)
- `tools/oracle-rs/` — Rust 对拍 dumper(外部 oracle,先于一切 Zig 代码建立):
  输入 grammar+vocab+token 序列 JSON,输出每步 bitmask(u32 字)/accept/reject/
  completed/jump_forward;Zig 侧验收 = 同输入逐字一致
- `docs/UPSTREAM.md` — 上游 v0.2.9 差异 backlog(基线 0.2.8 之后)

## 验证

```sh
zig build test                 # 包级(集成者)
zig test src/<module>/mod.zig  # 波次内单模块(移植 agent)
tools/oracle-rs/target/release/oracle <case.json > expected.json
```
