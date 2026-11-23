# UPSTREAM.md — 上游差异账(移植基线 xgrammar-rs 0.2.8)

基线对应上游 mlc-ai/xgrammar **v0.2.8**(2026-09-24;XGrammar-2 架构)。
上游 **v0.2.9**(2026-11-09)已发布但 **Rust 版 0.2.9 未发**(crates.io 最新 0.2.8,
2026-10-10)。以下为 v0.2.9 相对基线的变更,12 项正确性修复已全部回补并通过回归验证(`src/upstream_v029_test.zig`):

## 正确性修复(已全部回补)
- [x] rule-level cache 哈希碰撞:不同字符区间/重复边界(#943) — `src/functor/grammar_fsm_hasher.zig`
- [x] JSON Schema cache key 碰撞(#985) — `src/compiler/grammar_compiler.zig`
- [x] 大 regex 重复 + 缓存编译(#963) — `src/fsm/regex_ir.zig` 释放临时 hint + 与 #943/#949 协同
- [x] counted repeat 降级时保留 forbidden bytes(#949) — `src/fsm/regex_ir.zig`、`src/fsm/regex_fsm_builder.zig`
- [x] ECMAScript `\s`/`\S` 空白类(#977) — `src/fsm/regex_escape.zig`（包含 NBSP/全角空格/BOM 等 Unicode 空白；相对 0.2.8 为有意修复）
- [x] stop token 完成语法时放行(#710) — `src/matcher/grammar_matcher.zig`（含位掩码放行与完成即终止）
- [x] token 在 literal 中开始、在 token 级 free-text 区域结束(#942) — `src/matcher/grammar_matcher.zig`
- [x] 跨数组索引的 JSON Schema $ref 解析(#929) — `src/converter/schema_parser.zig`（RFC 6901 数组下标与 `~1`/`~0` 反转义）
- [x] schema literals 保留最短 JSON 数字(#926) — `src/converter/schema_parser.zig`（Ryu 最短往返表示）
- [x] generic JSON 规则保留分隔符(#948) — `src/converter/schema_converter.zig`（`basic_array`/`basic_object` 遵循调用方 separators）
- [x] find_jump_forward_string 保持整 UTF-8 字符(#1012) — `src/matcher/grammar_matcher.zig`（截断不完整首尾 UTF-8；相对 0.2.8 oracle `[0xB8, 0xAD]` 有意返回 `""`）
- [x] bounded-string token-mask 填充按 body 与父级分类(#903,perf+correctness) — `src/compiler/token_mask_cache_builder.zig`

## 功能项(低优先,按需)
- [ ] Gemma 4 工具调用 `<|"|>` 分隔符(#923)
- [ ] opt-in JIT 语法编译(#1017)
- [ ] structural tag 支持 Lark 语法(#1015)
- [ ] jump-forward tokens 保持接受边界(#980)
- [x] 依赖更新(#950)——不适用(纯 Zig 零依赖)

来源:https://github.com/mlc-ai/xgrammar/releases/tag/v0.2.9
