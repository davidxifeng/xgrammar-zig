//! The finite-state-machine engine: edges, NFAs/DFAs, compact CSR FSMs,
//! regex/trie/suffix-automaton builders, and streaming JSON serialization.

const std = @import("std");

pub const edge = @import("fsm/edge.zig");
pub const fsm_mod = @import("fsm/Fsm.zig");
pub const fsm_automata = @import("fsm/fsm_automata.zig");
pub const compact_fsm = @import("fsm/CompactFsm.zig");
pub const regex_ir = @import("fsm/regex_ir.zig");
pub const regex_builder = @import("fsm/regex_builder.zig");
pub const trie_and_suffix = @import("fsm/trie_and_suffix.zig");
pub const serialization = @import("fsm/serialization.zig");

pub const FsmEdge = edge.FsmEdge;
pub const edge_type = edge.edge_type;
pub const MAX_CHAR = edge.MAX_CHAR;
pub const RepeatEdgeRef = edge.RepeatEdgeRef;
pub const TokenEdgeRef = edge.TokenEdgeRef;
pub const ExcludeTokenEdgeRef = edge.ExcludeTokenEdgeRef;
pub const sortEdges = edge.sortEdges;

pub const Fsm = fsm_mod.Fsm;
pub const FsmSliceMeta = fsm_mod.FsmSliceMeta;
pub const EdgeKind = fsm_mod.EdgeKind;
pub const StateSet = fsm_mod.StateSet;
pub const NO_NEXT_STATE = fsm_mod.NO_NEXT_STATE;
pub const cloneSet = fsm_mod.cloneSet;
pub const stateSetFrom = fsm_mod.stateSetFrom;
pub const stateSetEql = fsm_mod.stateSetEql;

pub const FsmWithStartEnd = fsm_automata.FsmWithStartEnd;
pub const FsmWithStartEndWithSize = fsm_automata.FsmWithStartEndWithSize;
pub const AutomataError = fsm_automata.AutomataError;

pub const CompactFsm = compact_fsm.CompactFsm;
pub const CompactFsmShared = compact_fsm.CompactFsmShared;
pub const CompactFsmWithStartEnd = compact_fsm.CompactFsmWithStartEnd;
pub const CompactFsmWithStartEndWithSize = compact_fsm.CompactFsmWithStartEndWithSize;

pub const RegexIr = regex_ir.RegexIr;
pub const RegexNode = regex_ir.RegexNode;
pub const RegexStackEntry = regex_ir.RegexStackEntry;
pub const RegexEscape = regex_ir.RegexEscape;
pub const RegexError = regex_ir.RegexError;
pub const CodepointRange = regex_ir.CodepointRange;
pub const MAX_CODEPOINT = regex_ir.MAX_CODEPOINT;

pub const RegexFsmBuilder = regex_builder.RegexFsmBuilder;
pub const MAX_1_BYTE_UNICODE = regex_builder.MAX_1_BYTE_UNICODE;
pub const codepointToPackedUtf8 = regex_builder.codepointToPackedUtf8;
pub const addPackedUtf8RangeEdges = regex_builder.addPackedUtf8RangeEdges;
pub const rewriteRegexDots = regex_builder.rewriteRegexDots;

pub const TrieFsmBuilder = trie_and_suffix.TrieFsmBuilder;
pub const SuffixAutomata = trie_and_suffix.SuffixAutomata;

pub const writeCompact2dFsmEdges = serialization.writeCompact2dFsmEdges;
pub const writeCompactFsm = serialization.writeCompactFsm;
pub const writeCompactFsmWithStartEnd = serialization.writeCompactFsmWithStartEnd;
pub const writeCompactFsmWithStartEndWithSize = serialization.writeCompactFsmWithStartEndWithSize;
pub const deserializeCompact2dFsmEdges = serialization.deserializeCompact2dFsmEdges;
pub const deserializeCompactFsmJsonValue = serialization.deserializeCompactFsmJsonValue;
pub const deserializeCompactFsmWithStartEndJsonValue = serialization.deserializeCompactFsmWithStartEndJsonValue;
pub const deserializeCompactFsmWithStartEndWithSizeJsonValue = serialization.deserializeCompactFsmWithStartEndWithSizeJsonValue;

test {
    _ = edge;
    _ = fsm_mod;
    _ = fsm_automata;
    _ = compact_fsm;
    _ = regex_ir;
    _ = regex_builder;
    _ = trie_and_suffix;
    _ = serialization;
    _ = @import("fsm/spec_test_fsm.zig");
    _ = @import("fsm/spec_test_fsm_builder.zig");
    _ = @import("fsm/spec_test_regular_grammar_fsm.zig");
    std.testing.refAllDecls(@This());
}
