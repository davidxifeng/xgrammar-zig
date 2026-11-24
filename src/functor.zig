//! Grammar transformation passes ("functors"): normalization, simplification,
//! analysis, repetition expansion, lazy flattening, optimization, combination,
//! FSM construction, and structural FSM hashing.

const std = @import("std");

pub const mutator = @import("functor/mutator.zig");
pub const normalizer = @import("functor/normalizer.zig");
pub const simplify_passes = @import("functor/simplify_passes.zig");
pub const analysis_passes = @import("functor/analysis_passes.zig");
pub const repetition_expander = @import("functor/repetition_expander.zig");
pub const lazy_flattener = @import("functor/lazy_flattener.zig");
pub const optimizer = @import("functor/optimizer.zig");
pub const combine = @import("functor/combine.zig");
pub const fsm_builder = @import("functor/fsm_builder.zig");
pub const fsm_hasher = @import("functor/fsm_hasher.zig");

pub const FunctorError = mutator.FunctorError;
pub const GrammarMutator = mutator;
pub const MutatorState = mutator.MutatorState;
pub const in_place = mutator.in_place;

pub const normalize = normalizer.normalize;
pub const fromEbnf = normalizer.fromEbnf;
pub const builtinJsonGrammar = normalizer.builtinJsonGrammar;
pub const normalizeStructure = normalizer.normalizeStructure;
pub const normalizeRepetition = normalizer.normalizeRepetition;

pub const fuseByteStrings = simplify_passes.fuseByteStrings;
pub const eliminateSingleElementExprs = simplify_passes.eliminateSingleElementExprs;
pub const inlineRules = simplify_passes.inlineRules;
pub const eliminateDeadCode = simplify_passes.eliminateDeadCode;
pub const renameRootRule = simplify_passes.renameRootRule;

pub const allowEmptyRuleIds = analysis_passes.allowEmptyRuleIds;
pub const ruleRefGraph = analysis_passes.ruleRefGraph;
pub const analyzeLookaheadAssertions = analysis_passes.analyzeLookaheadAssertions;
pub const analyzeLookaheadAssertionsInPlace = analysis_passes.analyzeLookaheadAssertionsInPlace;

pub const expandRepetitionRanges = repetition_expander.expandRepetitionRanges;
pub const flattenLazyBodies = lazy_flattener.flattenLazyBodies;
pub const optimizeGrammar = optimizer.optimizeGrammar;

pub const unionOf = combine.unionOf;
pub const concatOf = combine.concatOf;
pub const addSubGrammar = combine.addSubGrammar;

pub const ExpressionFsmBuilder = fsm_builder.ExpressionFsmBuilder;
pub const RegularGrammarFsmBuilder = fsm_builder.RegularGrammarFsmBuilder;
pub const GrammarFsmBuilder = fsm_builder.GrammarFsmBuilder;

pub const hashGrammarFsms = fsm_hasher.apply;
pub const hashSequence = fsm_hasher.hashSequence;

test {
    _ = mutator;
    _ = normalizer;
    _ = simplify_passes;
    _ = analysis_passes;
    _ = repetition_expander;
    _ = lazy_flattener;
    _ = optimizer;
    _ = combine;
    _ = fsm_builder;
    _ = fsm_hasher;
    std.testing.refAllDecls(@This());
}
