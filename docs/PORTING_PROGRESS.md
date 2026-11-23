# PORTING_PROGRESS.md — 文件级移植账(集成者维护;agent 交付报告驱动,勿直接改)

状态:☐ 未开始 / 🔄 进行中 / ✅ 完成+模块测试绿 / 🔗 已接线(根模块引入+包级测试绿)

## Wave A(support / grammar / tokenizer)
| Rust 文件 | Zig 文件 | 状态 |
|---|---|---|
| support/* (10 文件,1434 行) | src/support/* | ✅(36 测试绿,集成者复核) |
| grammar/* (13 文件,2160 行) | src/grammar/* | ✅(59 测试绿,集成者复核;fsm 相关入口挂 `error.NotImplementedInWaveFsm`,Wave E 前由 WaveGrammar 补齐) |
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
| parser/* (earley_parser 1212、ebnf_parser 824、ebnf_lexer 681 等) | src/parser/* (17 文件 + parser_spec_test.zig) | 🔗 已接线(75/75 绿,集成者复核;fsm 边登记 NotImplementedInWaveFsm) |
| fsm/* (fsm_with_start_end 998、regex_ir 745、fsm 495、fsm_edge 239、compact_fsm 194、compact_fsm_with_start_end 130、trie_fsm_builder 180、serialization 164、packed_utf8 155、regex_escape 136、regex_node 71、regex_stack_entry 21、regex_fsm_builder 81、suffix_automata 84、rewrite_regex_dots 40、fsm_with_start_end_with_size 57、compact_fsm_with_start_end_with_size 49、mod 39) | src/fsm/* (17 源文件 + 3 spec 测试文件) | ✅(zig test src/fsm/mod.zig 102 项:91 过 + 11 跳过(跳过项为 functor/matcher 未接边的 spec 用例,已译好 gating);集成时删 src/fsm/{support,grammar,config.zig} symlink 并把模块内 import 改回 ../ 前缀) |
| functor/* (lazy_body_flattener 511、grammar_fsm_hasher 468 等) | src/functor/* | ☐ |

## Wave C(converter)
| Rust 文件 | Zig 文件 | 状态 |
|---|---|---|
| converter/* (json_schema_converter 1114、schema_converter 1094、schema_parser 1014、lark_compiler 1358、structural_tag_*、xml_* 等) | src/converter/* | ☐ |

## Wave D(compiler)
| Rust 文件 | Zig 文件 | 状态 |
|---|---|---|
| compiler/* (token_mask_cache_builder 859、grammar_compiler 415、adaptive_token_mask 347、rule_level_cache 164、compiled_grammar 188、tag_dispatch_optimization) | src/compiler/* | ☐ |

## Wave E(matcher + API + parity)
| Rust 文件 | Zig 文件 | 状态 |
|---|---|---|
| matcher/* (grammar_matcher 1911、token_bitmask 214、batch_grammar_matcher 144 等) | src/matcher/* | ☐ |
| testing.rs / config.rs / lib.rs re-export 面 | src/testing.zig / src/config.zig / src/xgrammar.zig | ☐ |
| oracle 全量对拍(JSON schema × byte_level 词表 × 中文) | tools/ | ☐ |
