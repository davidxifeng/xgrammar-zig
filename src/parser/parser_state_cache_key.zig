//! The adaptive token-mask cache key of a parser state (`parser_state_cache_key.rs`).

/// Equality/hash over `rule_id`, `sequence_id`, `element_id`, and `sub_element_id` only: the
/// token mask of a state does not depend on its start position, repeat count, partial
/// codepoint, budgets, or temperature (mirrors C++ `StateHashForCache`/`StateEqualForCache`).
pub const ParserStateCacheKey = struct {
    /// The rule's id.
    rule_id: i32,
    /// The rule body expression id.
    sequence_id: i32,
    /// The FSM node.
    element_id: i32,
    /// The sub element id.
    sub_element_id: i32,
};
