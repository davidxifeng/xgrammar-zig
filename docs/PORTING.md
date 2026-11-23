# PORTING.md — xgrammar-rs 0.2.8 → Zig 直译规范(所有参与者必读)

参照源(只读):`/Users/david/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/xgrammar-rs-0.2.8/`
本文是唯一契约:名字、结构、语义都以参照为准,deviation 必须在本文登记。

## 基线与验证

- 基线:xgrammar-rs 0.2.8(crates.io,对应上游 mlc-ai/xgrammar v0.2.8,即
  XGrammar-2 架构)。上游 v0.2.9 的修复清单见 `docs/UPSTREAM.md`,移植完成后增量补。
- **外部 oracle**:`tools/oracle-rs/`(已可运行)。输入 JSON(grammar+vocab+序列),
  输出每步 token bitmask(u32 字)与 accept/reject/completed/terminated/jump_forward。
  Zig 侧最终验收 = 同输入下逐字(bit-for-bit)一致。
- 每个 agent 移植自己波次的 `tests/cpp/test_*.rs` 用例为 Zig 测试
  (`tests/<name>.zig`,经 `src/tests.zig` 引入),行为断言优先,不确定行为用 oracle 验证后再写成断言。

## 结构规则

- 模块树 1:1 镜像 Rust:`src/support/`、`src/grammar/`、`src/parser/`、
  `src/converter/`、`src/fsm/`、`src/functor/`、`src/compiler/`、`src/matcher/`、
  `src/tokenizer/`;文件同名 `xxx.rs → xxx.zig`。模块 `mod.rs → mod` 区(`mod.zig` 聚合 + re-export)。
- 类型名/函数名/字段名保持 Rust 原名(Rust 类型已是 PascalCase、函数 snake_case,与 Zig 风格兼容)。
  不改名、不"Zig 化"命名;`pub use` re-export 保持调用点路径与 Rust 一致。
- 根模块 `src/xgrammar.zig` 镜像 `lib.rs` 的 re-export 面。

## 语义映射(硬规则)

| Rust | Zig |
|---|---|
| `Result<T, E>` | `E!T`(error union;错误枚举 1:1:`pub const Error = error{...}`,错误携带的数据放诊断结构可选回传) |
| `Option<T>` | `?T` |
| enum with data | tagged union,同名 |
| `Vec<T>` | `std.ArrayList(T)`(或 slice,见所有权) |
| `String/&str` | `[]const u8`(必须 UTF-8;拼接用 `std.ArrayList(u8)` + `std.fmt`) |
| `char`(unicode scalar) | `u21` |
| `HashMap`(ahash,顺序无关用途) | `std.AutoHashMap` / `std.StringHashMap` |
| `BTreeMap` / 顺序敏感遍历 | `std.ArrayHashMap`(插入序)+ 迭代前显式排序;**凡遍历序可能影响输出的容器必须确定性** |
| `Rc/Arc` 共享 | 借用指针(`*const T`);所有权见下 |
| `Drop` | 显式 `deinit(self)` |
| `Clone` | 显式 `clone(self, allocator)` 深拷贝 |
| `rayon par_iter` | 串行 for,行尾注释 `// rayon: serial in port` |
| panic!(逻辑不变量) | `unreachable` / `assert`;API 边界改 error |

## 所有权与内存(最重要)

- 每个顶层对象(`Grammar` / `CompiledGrammar` / `TokenizerInfo` / `GrammarMatcher` /
  `GrammarCompiler` / `EarleyParser`)**持有一个自己的 arena**:
  `arena: std.heap.ArenaAllocator`。内部所有节点、容器、字符串从 `self.arena.allocator()` 分配。
- `deinit(self)` 释放整个 arena。**绝不跨对象 free**;跨对象只传指针(借用)。
- 需要 `Clone` 的对象按 Rust 语义在目标对象自己的 arena 里重建。
- 函数签名:凡分配者带 `allocator: std.mem.Allocator` 首参;结构方法用对象内 allocator。

## 对拍口径陷阱(已知两处,后续登记在此)

1. **serde_json 的 Map 默认是 BTreeMap(键按字典序)**——参照 crates 主依赖未开
   `preserve_order`。Zig `std.json` 的 ObjectMap 是插入序。converter 波次处理 JSON
   Schema object 的 properties 等映射时,**必须按键字典序排序后再处理**,否则生成
   的 grammar 顺序发散,bitmask 对不上。
2. **bitmask 位语义**:bit=1 允许、bit=0 屏蔽;`vocab_size` 补齐到 u32 字
   (`get_bitmask_size = ceil(vocab/32)`);tokenizer vocab 小于 model vocab 时尾部
   字置全 1(放行)——uzu 采样 kernel 已验证此约定。

### 波次登记的 deviation

3. **support 波次(WaveSupport)**:
   - `UnionFindSet.union` → `union_`(`union` 是 Zig 关键字,无法保留原名);
     `find`/`union_` 对未添加元素:Rust panic → Zig `std.debug.panic`,语义一致。
   - Rust 元组返回值改具名 struct:`handle_utf8_first_byte`/`parse_next_utf8`/
     `parse_next_escaped`/`parse_next_utf8_or_escaped` 返回
     `encoding.Decoded{codepoint, consumed}`。
   - Rust 错误枚举带数据 → error set + 线程内诊断:`RecursionError` 变
     `error{InvalidMax, DepthExceeded}`,数据( current/max )经
     `recursion_guard.last_error()` 回读;Display 文本可由
     `format_depth_exceeded`/`format_invalid_max` 逐字复现。
   - `json_parse.parse_json` 返回 `ParseError!std.json.Value`
     (`error{DepthExceeded, InvalidJson, OutOfMemory}`),Rust 的 `Result<_,String>`
     消息文本不再作为返回值;深度扫描逻辑与 serde 尾部检查语义逐行对应。
   - `dynamic_bitset.serialize/deserialize_json_value_cpp` 与
     `compact_2d_array.serialize/deserialize_json_value` 用 `std.json.Value`;
     形状错误统一 `error.InvalidJson`。
   - `Compact2dArray.iter`(impl Iterator)→ `iter(context, comptime visit)` 访问者形式;
     `data()`/`indptr()` 访问器改名 `data_slice()`/`indptr_slice()`(避开字段名冲突)。
   - `Compact2dArray::from_row_sizes`/`reset_with_row_sizes` 的 `T: Default` 约束
     改为显式 `default: T` 参数。
   - 环境变量读取用 `std.c.getenv`(macOS 恒链 libSystem;0.17 的 process.Environ
     无稳定 std 级全局访问器)。
   - `escape_bytes` 的 `parse_utf8(..., true)` 按参照不可能是错误,展开处 `catch unreachable`。

6. **functor 波次(WaveFunctor)**:
   - Rust trait(`GrammarMutator`/`InPlaceGrammarRewriter`)无 Zig 对应:`apply`/`visit_*`
     默认实现改为 mutator/in_place_grammar_rewriter 模块内自由函数,各 pass 以
     `anytype` + comptime `@hasDecl` 鸭子分派选择覆盖(传值或指针均可,`PassT` 解包)。
     **pass 的 `visit_*` 覆盖方法必须 `pub`**(0.17 的 `@hasDecl` 对非 pub 声明返回 false)。
   - `FunctorError` 枚举带数据 → error set
     `{InvalidRepetitionRange, FsmBuild, LazyRuleBodyNotChoices, LazyRuleElementNotTerminal}`
     (+ OOM 与 `Compact2dArrayError` 透传)+ 诊断 `FunctorErrorInfo`(union(enum)),
     经可选出参 `diag: ?*FunctorErrorInfo` 回传;`format_message` 逐字复现 Rust Display。
     `GrammarFsmBuilder.regex`/`from_regular_grammar` 的 `Result<_, String>` 走 fsm 波
     `err_msg: ?*?[]?u8` 出参约定(错误集 `RegexError` / `error{Flatten}`)。
   - `Grammar::union` → `grammar_union_concat.union_`(`union` 是 Zig 关键字);
     `Grammar::union/concat/from_ebnf/builtin_json_grammar` 等 impl 块按 grammar 波约定
     落为对应文件内自由函数(首参 allocator)。
   - `copy_rule_attributes` 的规则 id 闭包:Zig 无闭包,重映射场景
     (dead_code_eliminator)展开为本地 `copy_attributes_remapped`;
     `add_sub_grammar` 用模块级 `remap_ids` 片段传递(仅调用期间有效)。
   - `OnceLock` 静态(json_string_forbidden_chars)→ 函数局部 `static` 变量惰性初始化。
   - 结构化哈希的 `BTreeMap`/`BTreeSet`:`hash_and_target` 候选排序去重后遍历,
     状态映射按 BFS 发现序赋新 id、输出按旧 id 排序(逐点对应 Rust 语义);
     边表统一 `fsm_edge.sortEdges` 排序,遍历序确定。
   - repetition_range_expander 的 `HashMap<Vec<i64>, i32>` 缓存键 → i64 小端字节串
     `StringHashMap`(键由缓存自持 allocator 分配/释放,勿与 builder arena 混用)。
   - mod.rs → mod.zig:模块命名空间以 `<name>_mod` 暴露,Rust `pub use` 名
     (与文件名冲突的函数)保留原名为包级 re-export;`GrammarFsmBuilder` 各入口
     (from_regular_grammar/tag_dispatch/token_tag_dispatch/byte_string/rule_ref/
     character_class/choices/json_string_forbidden_chars/regex/sequence)签名与参照
     同名同形(仅按约定加 allocator 首参与诊断/err_msg 出参)。
   - 清单外的依赖文件一并直译:`byte_string_fuser.rs`、`grammar_optimizer.rs`、
     `single_element_expr_eliminator.rs`(Rust `pub(crate)`,structure_normalizer/
     grammar_optimizer 的依赖)。
   - fsm 波 regex_fsm_builder.zig 的 `const fsm_wse` + `errdefer …deinit()` 编译错误
     (`*const T` 不能 deinit)已顺手修为 `var`(一行,已在上游交付物上)。

## 工程纪律

- 纯 Zig 0.17.1,零外部依赖;std API 拿不准就查
  `/opt/homebrew/Cellar/zig/0.17.1/lib/zig/std/` 源码,不凭记忆。
- 每个 agent 提交前:自己模块必须 `zig test src/<module>/mod.zig` 全绿
  (并行波次期间包根 `zig build test` 由集成者统一跑,agent 不改 `src/xgrammar.zig`
  与 `src/tests.zig`,根接线由集成者在评审后完成)。
- 包根:`~/work/apps/xgrammar-zig`。**不要执行 git 命令**,提交由集成者负责。
- 不写 TODO/占位;翻译到哪行,`docs/PORTING_PROGRESS.md` 登记到哪行
  (文件级:Rust 文件 → Zig 文件 → 状态)。
- **跨波次依赖**(如 grammar→parser):模块内功能必须完整;确需引用尚不存在的
  波次模块时,该入口函数暂时 `return error.NotImplementedInWaveX;` 并在交付报告
  显式登记(函数+参照行号),由集成者在依赖波次落地后补齐——不允许静默空实现。
- Zig 注释只写翻译时发现的语义备注(如"rayon 串行化""serde 键排序"),
  不复述代码。

4. **grammar 波次(WaveGrammar)**:
   - Rust `impl Grammar` 块分布在不同文件(tag_dispatch/token_tag_dispatch/printer/
     serialization.rs):Zig 无扩展方法 → 同名模块内自由函数,首参 `*const Grammar`,
     名字保持原名(如 `printer.to_string_ebnf(grammar, allocator)`)。
   - Rust 访问器与字段同名的(`Grammar::rules/exprs/suffix_stop_infos/root_rule_id/
     allow_empty_rule_ids`)删除,Zig 字段公开,直接字段访问;`per_rule_fsm_new_state_ids()`
     访问器改名 `fsm_new_state_ids()`(字段保留 Rust 名)。
   - `DeserializeError` → error set + `DeserializeErrorInfo`(union(enum),变体名同 Rust
     variant;诊断经可选出参 `diag: ?*DeserializeErrorInfo` 回传,字符串由调用方
     allocator 分配;形状与 tokenizer support_shim 一致,便于合并)。
   - 顶层对象 arena 化:Rust 的 move(`from_parts`/`set_suffix_stop_infos`/
     `set_fsm_hash_data`/`from_grammar`)一律改为深拷贝进目标对象 arena;
     `into_grammar` 的 `Result<_, String>`(缺失 root 名)经可选出参
     `missing_name: ?*?[]const u8` 回传;`builder.add_*` 系列把 OOM 上浮为
     `error.OutOfMemory`(Rust 为 panic)。
   - `GrammarBuilder::edit_in_place` 闭包 → 两段式 `edit_in_place(grammar)` /
     `edit_in_place_commit(builder, grammar)`(借用 grammar 存储,追加直接落
     grammar arena)。
   - fsm 挂点已接线(fsm 波落地后):`complete_fsm`/`per_rule_fsms` 字段就位,
     `fsm_state_offsets`/`per_rule_fsm`/`set_fsms`/`per_rule_fsms_slice` 完整,
     序列化 fsm 分支与 validate fsm 段齐备,`NotImplementedInWaveFsm` 已全部消除。
     所有权:FSM 存储是 refcount(CompactFsmShared);`set_fsms` 对传入句柄
     **retain**(非 Rust move——调用方保留自己的引用并自行 deinit),视图 clone 的
     ends 缓冲一律用该视图自身 shared.allocator 分配/释放,避免跨分配器释放;
     反序列化的 FSM 存储放在 grammar 自身 arena(随 grammar 释放,refcount 仍正确)。
   - 序列化键序:serde_json Map=BTreeMap → std.json ObjectMap 按字典序插入,
     `__VERSION__` 最先(陷阱 1);serialize_json_value* 增加
     `error.NotImplementedInWaveFsm`(仅 optimized 语法可达)。
   - `InvalidJson` 诊断载荷为错误名(support.parse_json 返回裸 error set,
     serde 的详细消息文本不再可得)。
   - 交叉引用临时方案:`src/grammar/support`(symlink→../support)与
     `src/grammar/config.zig`(symlink→../config.zig,grammar 波代建的真实移植)
     使 `zig test src/grammar/mod.zig` 独立可跑;集成接线时删 symlink、改回
     `../support/mod.zig`、`../config.zig`。src/config.zig 本体归 Wave E。

5. **parser 波次(WaveParser)**:
   - 错误携带数据:`ParserError`/`LexerError` 保留为诊断 struct(Rust thiserror struct);
     失败经 error set `error.Lexer`/`error.Parser` + 可选出参 `?*LexerError`/`?*ParserError`
     回传,Display 文本经 `format_message` 逐字复现。`EbnfError` 变 error set
     `{Lexer, Parser, Normalization}` + `EbnfErrorInfo`(union(enum)) 诊断出参;
     `message_of` 复现 Rust `EbnfError::message`。
   - `MacroArguments` 字段 `named` 与方法 `named` 重名:方法改名 `named_value`
     (字段保留 Rust 名);`EarleyParser::is_completed()` 同因改 `is_root_completed`。
   - 字符串所有权:token 的 lexeme/Str 值、RuleAttributes.capture_name、
     stop_capture_name 由调用方 allocator 分配,`token.free_tokens` 统一释放;
     ebnf_to_grammar_no_normalization 内部用临时 arena 承载 token/macro 值。
   - `ebnf_to_grammar_no_normalization` 签名
     `(gpa, ebnf_string, root_rule_name, diag) !(Allocator.Error || EbnfError)!*Grammar`;
     into_grammar 缺 root 的错误消息逐字复现 `root rule "..." was never added`。
   - `tokenize` 输入按 UTF-8 有效前提直拷(Rust `String::from_utf8_lossy` 在 `&str` 下不可达);
     f64 温度前缀解析用 `std.fmt.parseFloat` 最长前缀(std::stod 语义)。
   - `EarleyParser`:Rust `Arc<Grammar>` 改借用 `*const Grammar`;parser 堆分配自持
     (`new` 返回 `!*EarleyParser`,`deinit` 释放)。`VecDeque` 用 `std.Deque`;
     `enqueue` 在 Rust 无失败路径,`advance_byte_string` 处 OOM panic(`enqueue_no_fail`)。
     `Clone` 未移植(matcher 波落地后如需再补)。
   - **fsm 接线(WaveFsm/WaveGrammar 落地后由 WaveParser 完成)**:earley_parser 全部
     FSM 分支已按参照实现——`fsm_state_flags`/`initialize_fsm_state_flags`(状态标志
     缓存)、`complete` 的 FSM-parent 分支、`completion_consumed_marker`、
     `root_initial_state`、`enqueue_rule_start`、`expand_next_rule_ref_element_on_fsm`、
     `enqueue_scan_target`、`advance_fsm`、`scan_atomic_token`;`fsm_state_offsets`
     按 `Grammar::fsm_state_offsets`(grammar.rs L72)在 `init_fsm_state_offsets`
     本地重算(complete_fsm 为 0 号存储,共享存储复用同一段)。
     数据入口为 `Grammar.complete_fsm` / `Grammar.per_rule_fsms` 字段(WaveGrammar
     挂点);字段安装前 comptime 门控 `grammar_fsm_installed` 把 FSM 路径拦为
     `error.FsmNotInstalled`(临时门控,字段安装后自动消失;已置 SkipZigTest 的
     端到端 Earley 测试随之解锁,注明在 parser_spec_test.zig)。缺 per-rule FSM
     项按未安装处理(非 panic)。原 `error.NotImplementedInWaveFsm` 入口已全部消除。
     `ebnf_parser.parse_regex_macro` 的 `flags` 分支已接 `fsm::rewrite_regex_dots`:
     dot 语义按 dot_all 改写,case_insensitive 前缀 `(?i)`;'u' 为 no-op;未知 flag
     报参照同文错误。flags 参数出现即触发 dot 改写(与参照一致)。
   - 诊断消息从 `ebnf_to_grammar_no_normalization` 的临时 arena 提升(hoist)到
     调用方 allocator,避免悬挂;错误消息归调用方 free。
   - GrammarBuilder 在 grammar 波更新后 `update_rule_body_by_name`/
     `update_lookahead_assertion_by_name`/`into_grammar` 错误集变化,parser 已适配
     (`try` + `@errorCast` 收窄)。
   - 开发期 symlink:src/parser/{support,grammar,config.zig} → ../;独立测试
     `zig test src/parser/mod.zig` 75/75 绿(含 spec 测试 15 个 test 函数);
     集成时删 symlink 并把 parser 内 `@import("support/mod.zig")` /
     `@import("grammar/mod.zig")` 改回 `../support/mod.zig` / `../grammar/mod.zig`。

5. **fsm 波次(WaveFsm)**:
   - 开发期 symlink:src/fsm/{support,grammar,config.zig} → ../(同 parser 波约定);模块内
     import 为 `support/mod.zig` / `grammar/mod.zig` / `grammar/error.zig`;集成时删 symlink
     并改回 `../` 前缀。独立测试 `zig test src/fsm/mod.zig` 102 项全绿(91 过 + 11 跳过)。
   - `Result<_, String>`:regex parse/build 路径保留逐字错误消息——
     `RegexIr.parse` / `RegexIr.build` / `RegexFsmBuilder.build(_with_forbidden_chars)` /
     `matches_empty` 增加 `err_msg: ?*?[]u8` 出参(调用方 allocator 分配);错误集
     `RegexError = OOM || {RegexParse, RepeatTooLarge, InvalidRepeat, RepeatCountInvalid,
     UnclosedParen, InvalidEscape}`。`not`/`intersect(_with_limit)`/`to_dfa(_with_limit)`/
     `minimize_dfa` 消息文本丢弃:`error.NotLeaf` / `error.StateLimitExceeded`。
   - 所有权:Fsm/FsmWithStartEnd 等无 arena,方法显式 `allocator` 首参(或持 `self.allocator`),
     所有增长型方法返回 `Allocator.Error!`(Rust OOM panic);`deinit` 释放自身。
   - `CompactFsm` 的 `Arc` 对 → 引用计数共享块 `CompactFsmShared{allocator, refs, edges,
     edge_aux_data}`;`clone(self)` 只增引用计数(无 allocator 参数,偏离 Clone 约定);
     `shares_storage` = 指针等同;`eql` 逐字段比较。`from_parts`/`edges_table`(原 pub(crate))
     改为 pub。
   - 访问器与字段/方法重名:取值器加 `get_` 前缀(`get_start`/`get_ends`/`get_fsm`/
     `get_is_dfa`/`get_edge_num`/`get_node_num`);`Fsm.edges()`→`edges_slice()`,
     `edge_aux_data()`→`edge_aux_data_slice()`;`FsmWithStartEnd.union` → `union_`。
   - `BTreeSet`/`BTreeMap` 遍历序:to_dfa 的 interval_ends 用排序去重线性表;
     minimize_dfa 的 possible 用排序组表;suffix_automata 展开 chunk 转移前按字典序排序
     (陷阱 1 同源)。
   - serialization:std.json ObjectMap 按字典序插入(CompactFsm 键序 edge_aux_data <
     edge_num < edges);形状错误统一 `DeserializeError.Format`;FsmEdge.deserialize 的
     消息文本丢弃;JSON Value 无递归释放,序列化往返测试用 arena。
   - merge_equivalent_states 的 EndpointEdge CSR 行显式零默认(init_from_row_sizes 需 default)。
   - spec 测试:test_fsm.rs 全量译入 spec_test_fsm.zig;test_fsm_builder.rs 译入
     spec_test_fsm_builder.zig(其中 GrammarFsmBuilder 相关 7 组用例与
     test_regular_grammar_fsm.rs 全部 4 组用例依赖 functor/matcher 波,译好并 gating 为
     `error.SkipZigTest`,functor 落地后去掉 gating)。
