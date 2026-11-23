# UPSTREAM.md — 上游差异账(移植基线 xgrammar-rs 0.2.8)

基线对应上游 mlc-ai/xgrammar **v0.2.8**(2026-09-24;XGrammar-2 架构)。
上游 **v0.2.9**(2026-11-09)已发布但 **Rust 版 0.2.9 未发**(crates.io 最新 0.2.8,
2026-10-10)。以下为 v0.2.9 相对基线的变更,移植完成并过 oracle 后逐项评估回补:

## 正确性修复(优先回补;判定标准:oracle 对拍)
- [ ] rule-level cache 哈希碰撞:不同字符区间/重复边界(#943)
- [ ] JSON Schema cache key 碰撞(#985)
- [ ] 大 regex 重复 + 缓存编译(#963)
- [ ] counted repeat 降级时保留 forbidden bytes(#949)
- [ ] ECMAScript `\s`/`\S` 空白类(#977)
- [ ] stop token 完成语法时放行(#710)
- [ ] token 在 literal 中开始、在 token 级 free-text 区域结束(#942)
- [ ] 跨数组索引的 JSON Schema $ref 解析(#929)
- [ ] schema literals 保留最短 JSON 数字(#926)
- [ ] generic JSON 规则保留分隔符(#948)
- [ ] find_jump_forward_string 保持整 UTF-8 字符(#1012)
- [ ] bounded-string token-mask 填充按 body 与父级分类(#903,perf+correctness)

## 功能项(低优先,按需)
- [ ] Gemma 4 工具调用 `<|"|>` 分隔符(#923)
- [ ] opt-in JIT 语法编译(#1017)
- [ ] structural tag 支持 Lark 语法(#1015)
- [ ] jump-forward tokens 保持接受边界(#980)
- [ ] 依赖更新(#950)——不适用(纯 Zig 零依赖)

来源:https://github.com/mlc-ai/xgrammar/releases/tag/v0.2.9
