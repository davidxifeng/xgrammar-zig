//! One entry of the regex parsing stack.

const regex_node = @import("regex_node.zig");
const RegexNode = regex_node.RegexNode;

/// An entry of the regex parsing stack: a parsed atom with its source span, or a marker.
pub const RegexStackEntry = union(enum) {
    /// A parsed node spanning `regex[span_begin..span_end]`.
    Node: struct {
        /// The parsed node (owned by the `RegexIr` arena/allocator).
        node: RegexNode,
        /// The byte offset where the atom starts.
        span_begin: usize,
        /// The byte offset right after the atom.
        span_end: usize,
    },
    /// An opening `(` at the given byte offset.
    GroupOpen: usize,
    /// An alternation `|`.
    Alternation,
};
