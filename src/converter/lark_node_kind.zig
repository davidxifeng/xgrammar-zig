//! Kinds of Lark expression nodes (`lark_node_kind.rs`).

/// The kind of a `LarkNode`.
pub const LarkNodeKind = enum {
    Sequence,
    Choice,
    Repeat,
    String,
    Regex,
    Range,
    Name,
    Json,
    RegexExt,
    NestedLark,
    SpecialToken,
    GrammarRef,
    Not,
};
