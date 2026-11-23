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
   - fsm 波未落地:`Grammar` 的 `complete_fsm`/`per_rule_fsms` 字段与全部 fsm 依赖
     路径(`complete_fsm`/`fsm_state_offsets`/`per_rule_fsm`/`set_fsms`/
     `per_rule_fsms_slice`、序列化 fsm 分支、validate fsm 段)登记为
     `error.NotImplementedInWaveFsm` 未接边,Wave B 落地后接线。
   - 序列化键序:serde_json Map=BTreeMap → std.json ObjectMap 按字典序插入,
     `__VERSION__` 最先(陷阱 1);serialize_json_value* 增加
     `error.NotImplementedInWaveFsm`(仅 optimized 语法可达)。
   - `InvalidJson` 诊断载荷为错误名(support.parse_json 返回裸 error set,
     serde 的详细消息文本不再可得)。
   - 交叉引用临时方案:`src/grammar/support`(symlink→../support)与
     `src/grammar/config.zig`(symlink→../config.zig,grammar 波代建的真实移植)
     使 `zig test src/grammar/mod.zig` 独立可跑;集成接线时删 symlink、改回
     `../support/mod.zig`、`../config.zig`。src/config.zig 本体归 Wave E。
