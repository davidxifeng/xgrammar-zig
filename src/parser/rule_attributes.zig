//! The attribute block of a rule definition, e.g. `name[max_tokens=10, capture] ::= ...`
//! (`rule_attributes.rs`).

const grammar = @import("../grammar/mod.zig");

const SuffixStopInfo = grammar.SuffixStopInfo;

/// Rule attributes attached to a rule-definition identifier by the lexer.
pub const RuleAttributes = struct {
    /// The token budget, or `-1`.
    max_tokens: i32,
    /// The character budget, or `-1`.
    max_chars: i32,
    /// The capture name, or empty.
    capture_name: []const u8,
    /// The capture-hidden suffix/stop metadata (the `rule_id` field is unused).
    suffix_stop_info: SuffixStopInfo,
    /// Whether the rule is lazy (committed-shortest).
    is_lazy: bool,
    /// The sampling temperature.
    temperature: ?f32,
};

test RuleAttributes {
    _ = SuffixStopInfo;
}
