//! A grammar that a Lark source can reference as `@name` (`named_grammar.rs`).
//!
//! Rust `Box<Grammar>` → borrowed `*const Grammar`; strings are borrowed slices owned by
//! the caller (`from_lark`'s `named_grammars` argument outlives the call).

const grammar_mod = @import("../grammar/mod.zig");
const Grammar = grammar_mod.Grammar;

/// A grammar or Lark source that can be referenced by name from another Lark grammar.
pub const NamedGrammar = union(enum) {
    /// An existing grammar.
    grammar: struct {
        /// The reference name, without the leading `@`.
        name: []const u8,
        /// The referenced grammar.
        grammar: *const Grammar,
    },
    /// A Lark source with its own `start` rule.
    lark: struct {
        /// The reference name, without the leading `@`.
        name: []const u8,
        /// The Lark source.
        source: []const u8,
    },

    /// The reference name, without the leading `@`.
    pub fn name(self: *const NamedGrammar) []const u8 {
        return switch (self.*) {
            .grammar => |g| g.name,
            .lark => |l| l.name,
        };
    }
};
