//! A concrete occurrence of a captured rule in an Earley parent chain
//! (`capture_occurrence.rs`).

/// A rule occurrence identified by its rule id and start position.
pub const CaptureOccurrence = struct {
    /// The id of the captured rule.
    rule_id: i32,
    /// The position where the rule occurrence started.
    start_pos: i32,
};
