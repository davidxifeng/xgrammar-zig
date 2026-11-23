# PORTING_PROGRESS.md — 文件级移植账(集成者维护;agent 交付报告驱动,勿直接改)

状态:☐ 未开始 / 🔄 进行中 / ✅ 完成+模块测试绿 / 🔗 已接线(根模块引入+包级测试绿)

## Wave A(support / grammar / tokenizer)
| Rust 文件 | Zig 文件 | 状态 |
|---|---|---|
| support/* (10 文件,1434 行) | src/support/* | ✅(36 测试绿,集成者复核) |
| grammar/* (13 文件,2160 行) | src/grammar/* | 🔗 已接线+fsm 挂点补齐(NotImplementedInWaveFsm 0 残留;test_serialization.rs 8 测试已移植;set_fsms retain 偏离已登记) |
| config.rs (12) | src/config.zig | ✅(集成者建,WaveGrammar 同译校对) |
| tokenizer/vocab_type.rs (56) | src/tokenizer/vocab_type.zig | ✅ |
| tokenizer/error.rs (17) | src/tokenizer/error.zig | ✅ |
| tokenizer/token_decoder.rs (99) | src/tokenizer/token_decoder.zig | ✅ |
| tokenizer/tokenizer_info.rs (534) | src/tokenizer/tokenizer_info.zig | ✅ |
| tokenizer/hf_metadata.rs (101) | src/tokenizer/hf_metadata.zig | ✅(tokenizers crate 路径按契约跳过) |
| tokenizer/mod.rs (16) | src/tokenizer/mod.zig | 🔗 已接线(shim 已删,重接真实模块,集成者复核) |

## Wave B(parser / fsm / functor)
| Rust 文件 | Zig 文件 | 状态 |
|---|---|---|
| parser/* (earley_parser 1212、ebnf_parser 824、ebnf_lexer 681 等) | src/parser/* (17 文件 + parser_spec_test.zig) | 🔗 已接线(集成者复核);fsm 分支按参照实现完成,NotImplementedInWaveFsm 全消除,残余 FsmNotInstalled 门控(grammar 挂点安装后自动解除) |
| fsm/* (fsm_with_start_end 998、regex_ir 745、fsm 495、fsm_edge 239、compact_fsm 194、compact_fsm_with_start_end 130、trie_fsm_builder 180、serialization 164、packed_utf8 155、regex_escape 136、regex_node 71、regex_stack_entry 21、regex_fsm_builder 81、suffix_automata 84、rewrite_regex_dots 40、fsm_with_start_end_with_size 57、compact_fsm_with_start_end_with_size 49、mod 39) | src/fsm/* (17 源文件 + 3 spec 测试文件) | ✅(zig test src/fsm/mod.zig 102 项:91 过 + 11 跳过(跳过项为 functor/matcher 未接边的 spec 用例,已译好 gating);symlink 已删、import 已改 ../ 前缀,已接线入根模块(集成者复核 121 过+11 门控) |
| functor/* (22 文件,约 3000 行,含 grammar_optimizer/byte_string_fuser/single_element_expr_eliminator 三个清单外依赖件) | src/functor/* | 🔗 已接线(集成者复核 155 过+12 门控;GrammarFsmBuilder/hash 已按 grammar 真实 fsm API 接线,0 挂账) |

## Wave C(converter)
| Rust 文件 | Zig 文件 | 状态 |
|---|---|---|
| converter/* (json_schema_converter 1114、schema_converter 1094、schema_parser 1014、lark_compiler 1358、structural_tag_*、xml_* 等 19 文件) | src/converter/* (20 源文件 + spec_test/lark_spec_test) | 🔗 已接线(XML/Lark/StructuralTag 全补齐;NotImplementedInWaveLark 0 残留;196 过 + 3 门控,0 泄漏) |

## Wave D(compiler)
| Rust 文件 | Zig 文件 | 状态 |
|---|---|---|
| compiler/* (token_mask_cache_builder 859、grammar_compiler 415、adaptive_token_mask 347、rule_level_cache 164、compiled_grammar 188、tag_dispatch_optimization) | src/compiler/* (8 文件) | 🔗 已接线(203 过 + 1 待 matcher 门控,0 失败,0 泄漏;lark cache 与 earley fsm gate 已解锁) |

## Wave E(matcher + API + parity)
| Rust 文件 | Zig 文件 | 状态 |
|---|---|---|
| matcher/* (grammar_matcher 1911、token_bitmask 214、batch_grammar_matcher 144 等) | src/matcher/* (7 文件) | 🔗 已接线(218 过, 0 跳过, 0 泄漏) |
| testing.rs / config.rs / lib.rs re-export 面 | src/testing.zig / src/config.zig / src/xgrammar.zig / src/tests.zig / src/oracle_parity_test.zig | 🔗 已接线 |
| oracle 全量对拍(JSON schema × byte_fallback/raw 词表 × 中文 × 多字位掩码) | tools/oracle.zig + build.zig (`xgrammar-oracle`) | 🔗 已接线(与 `tools/oracle-rs` 100% 比特级一致) |
