//! Grammar transformation passes — the "functors": normalization, structure
//! normalization, inlining, dead-code elimination, optimization, etc. (`mod.rs`).
//!
//! `GrammarMutator` is the visitor/mutator framework; concrete passes implement it.
//! Module namespaces are exposed as `<name>_mod` so the Rust `pub use` names (which
//! collide with the file names) stay available at their Rust call-site paths.

const std = @import("std");

pub const allow_empty_rule_analyzer_mod = @import("allow_empty_rule_analyzer.zig");
pub const byte_string_fuser_mod = @import("byte_string_fuser.zig");
pub const dead_code_eliminator_mod = @import("dead_code_eliminator.zig");
pub const error_mod = @import("error.zig"); // Rust `mod error` — `error` is a Zig keyword
pub const expression_fsm_builder_mod = @import("expression_fsm_builder.zig");
pub const grammar_fsm_builder_mod = @import("grammar_fsm_builder.zig");
pub const grammar_fsm_hasher_mod = @import("grammar_fsm_hasher.zig");
pub const grammar_normalizer_mod = @import("grammar_normalizer.zig");
pub const grammar_optimizer_mod = @import("grammar_optimizer.zig");
pub const grammar_union_concat_mod = @import("grammar_union_concat.zig");
pub const in_place_grammar_rewriter_mod = @import("in_place_grammar_rewriter.zig");
pub const lazy_body_flattener_mod = @import("lazy_body_flattener.zig");
pub const lookahead_assertion_analyzer_mod = @import("lookahead_assertion_analyzer.zig");
pub const mutator_mod = @import("mutator.zig");
pub const regular_grammar_fsm_builder_mod = @import("regular_grammar_fsm_builder.zig");
pub const repetition_normalizer_mod = @import("repetition_normalizer.zig");
pub const repetition_range_expander_mod = @import("repetition_range_expander.zig");
pub const root_rule_renamer_mod = @import("root_rule_renamer.zig");
pub const rule_inliner_mod = @import("rule_inliner.zig");
pub const single_element_expr_eliminator_mod = @import("single_element_expr_eliminator.zig");
pub const structure_normalizer_mod = @import("structure_normalizer.zig");

// pub use allow_empty_rule_analyzer::allow_empty_rule_ids;
pub const allow_empty_rule_ids = allow_empty_rule_analyzer_mod.allow_empty_rule_ids;
// pub use byte_string_fuser::byte_string_fuser;
pub const byte_string_fuser = byte_string_fuser_mod.byte_string_fuser;
// pub use dead_code_eliminator::dead_code_eliminator;
pub const dead_code_eliminator = dead_code_eliminator_mod.dead_code_eliminator;
// pub use error::FunctorError;
pub const FunctorError = error_mod.FunctorError;
pub const FunctorErrorInfo = error_mod.FunctorErrorInfo;
// pub use grammar_fsm_builder::GrammarFsmBuilder;
pub const GrammarFsmBuilder = grammar_fsm_builder_mod.GrammarFsmBuilder;
// pub use grammar_fsm_hasher::{apply as grammar_fsm_hasher, hash_sequence as grammar_fsm_hash_sequence};
pub const grammar_fsm_hasher = grammar_fsm_hasher_mod.apply;
pub const grammar_fsm_hash_sequence = grammar_fsm_hasher_mod.hash_sequence;
// pub use grammar_normalizer::grammar_normalizer;
pub const grammar_normalizer = grammar_normalizer_mod.grammar_normalizer;
// pub use grammar_optimizer::grammar_optimizer;
pub const grammar_optimizer = grammar_optimizer_mod.grammar_optimizer;
// pub(crate) use grammar_union_concat::add_sub_grammar;
pub const add_sub_grammar = grammar_union_concat_mod.add_sub_grammar;
// Rust `Grammar::union` / `Grammar::concat` impl blocks (`union` is a Zig keyword).
pub const grammar_union = grammar_union_concat_mod.union_;
pub const grammar_concat = grammar_union_concat_mod.concat;
// pub use lookahead_assertion_analyzer::lookahead_assertion_analyzer;
pub const lookahead_assertion_analyzer = lookahead_assertion_analyzer_mod.lookahead_assertion_analyzer;
// pub use mutator::{GrammarMutator, MutatorState};
pub const GrammarMutator = mutator_mod;
pub const MutatorState = mutator_mod.MutatorState;
// pub use repetition_normalizer::repetition_normalizer;
pub const repetition_normalizer = repetition_normalizer_mod.repetition_normalizer;
// pub use repetition_range_expander::repetition_range_expander;
pub const repetition_range_expander = repetition_range_expander_mod.repetition_range_expander;
// pub use root_rule_renamer::root_rule_renamer;
pub const root_rule_renamer = root_rule_renamer_mod.root_rule_renamer;
// pub use rule_inliner::rule_inliner;
pub const rule_inliner = rule_inliner_mod.rule_inliner;
// pub use structure_normalizer::structure_normalizer;
pub const structure_normalizer = structure_normalizer_mod.structure_normalizer;

test {
    _ = allow_empty_rule_analyzer_mod;
    _ = byte_string_fuser_mod;
    _ = dead_code_eliminator_mod;
    _ = error_mod;
    _ = expression_fsm_builder_mod;
    _ = grammar_fsm_builder_mod;
    _ = grammar_fsm_hasher_mod;
    _ = grammar_normalizer_mod;
    _ = grammar_optimizer_mod;
    _ = grammar_union_concat_mod;
    _ = in_place_grammar_rewriter_mod;
    _ = lazy_body_flattener_mod;
    _ = lookahead_assertion_analyzer_mod;
    _ = mutator_mod;
    _ = regular_grammar_fsm_builder_mod;
    _ = repetition_normalizer_mod;
    _ = repetition_range_expander_mod;
    _ = root_rule_renamer_mod;
    _ = rule_inliner_mod;
    _ = single_element_expr_eliminator_mod;
    _ = structure_normalizer_mod;
}
