//! The finite-state-machine engine: edges, NFAs/DFAs, and the regex/trie/suffix-automaton
//! builders that back grammar compilation.
//!
//! One dedicated type per file; re-exported here (mirrors fsm/mod.rs).

const std = @import("std");

pub const compact_fsm = @import("compact_fsm.zig");
pub const compact_fsm_with_start_end = @import("compact_fsm_with_start_end.zig");
pub const compact_fsm_with_start_end_with_size = @import("compact_fsm_with_start_end_with_size.zig");
pub const fsm = @import("fsm.zig");
pub const fsm_edge = @import("fsm_edge.zig");
pub const fsm_with_start_end = @import("fsm_with_start_end.zig");
pub const fsm_with_start_end_with_size = @import("fsm_with_start_end_with_size.zig");
pub const packed_utf8 = @import("packed_utf8.zig");
pub const regex_escape = @import("regex_escape.zig");
pub const regex_fsm_builder = @import("regex_fsm_builder.zig");
pub const regex_ir = @import("regex_ir.zig");
pub const regex_node = @import("regex_node.zig");
pub const regex_stack_entry = @import("regex_stack_entry.zig");
pub const rewrite_regex_dots_mod = @import("rewrite_regex_dots.zig");
pub const serialization = @import("serialization.zig");
pub const suffix_automata = @import("suffix_automata.zig");
pub const trie_fsm_builder = @import("trie_fsm_builder.zig");

pub const CompactFsm = compact_fsm.CompactFsm;
pub const CompactFsmWithStartEnd = compact_fsm_with_start_end.CompactFsmWithStartEnd;
pub const CompactFsmWithStartEndWithSize = compact_fsm_with_start_end_with_size.CompactFsmWithStartEndWithSize;
pub const EdgeKind = fsm.EdgeKind;
pub const Fsm = fsm.Fsm;
pub const NO_NEXT_STATE = fsm.NO_NEXT_STATE;
pub const ExcludeTokenEdgeRef = fsm_edge.ExcludeTokenEdgeRef;
pub const FsmEdge = fsm_edge.FsmEdge;
pub const MAX_CHAR = fsm_edge.MAX_CHAR;
pub const RepeatEdgeRef = fsm_edge.RepeatEdgeRef;
pub const TokenEdgeRef = fsm_edge.TokenEdgeRef;
pub const edge_type = fsm_edge.edge_type;
pub const FsmWithStartEnd = fsm_with_start_end.FsmWithStartEnd;
pub const FsmWithStartEndWithSize = fsm_with_start_end_with_size.FsmWithStartEndWithSize;
pub const add_packed_utf8_range_edges = packed_utf8.add_packed_utf8_range_edges;
pub const codepoint_to_packed_utf8 = packed_utf8.codepoint_to_packed_utf8;
pub const RegexFsmBuilder = regex_fsm_builder.RegexFsmBuilder;
pub const RegexIr = regex_ir.RegexIr;
pub const RegexNode = regex_node.RegexNode;
pub const rewrite_regex_dots = rewrite_regex_dots_mod.rewrite_regex_dots;
pub const deserialize_compact_2d_fsm_edges = serialization.deserialize_compact_2d_fsm_edges;
pub const serialize_compact_2d_fsm_edges = serialization.serialize_compact_2d_fsm_edges;
pub const SuffixAutomata = suffix_automata.SuffixAutomata;
pub const TrieFsmBuilder = trie_fsm_builder.TrieFsmBuilder;

/// An inclusive range of Unicode codepoints (`type CodepointRange = (u32, u32)`).
pub const CodepointRange = regex_escape.CodepointRange;

test {
    _ = compact_fsm;
    _ = compact_fsm_with_start_end;
    _ = compact_fsm_with_start_end_with_size;
    _ = fsm;
    _ = fsm_edge;
    _ = fsm_with_start_end;
    _ = fsm_with_start_end_with_size;
    _ = packed_utf8;
    _ = regex_escape;
    _ = regex_fsm_builder;
    _ = regex_ir;
    _ = regex_node;
    _ = regex_stack_entry;
    _ = rewrite_regex_dots_mod;
    _ = serialization;
    _ = suffix_automata;
    _ = trie_fsm_builder;
    std.testing.refAllDecls(@This());
    _ = @import("spec_test_fsm.zig");
    _ = @import("spec_test_fsm_builder.zig");
    _ = @import("spec_test_regular_grammar_fsm.zig");
}
