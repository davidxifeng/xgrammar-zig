//! A node of the parsed regex AST.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A node of the regex AST. Owned slices/pointers are allocated from the owning `RegexIr`'s
/// allocator and freed by its `deinit`.
pub const RegexNode = union(enum) {
    /// One atom: the empty string (`""`), a character class (`"[...]"`), or one literal
    /// character or escape sequence (the raw regex bytes).
    Leaf: []const u8,
    /// `child*`.
    Star: *RegexNode,
    /// `child+`.
    Plus: *RegexNode,
    /// `child?`.
    Optional: *RegexNode,
    /// An alternation of branches.
    Union: []RegexNode,
    /// A concatenation (a group, or a branch of an alternation).
    Bracket: []RegexNode,
    /// A `{lower, upper}` repetition, unrolled into the FSM (`upper == -1` is unbounded).
    Repeat: struct {
        /// The repeated node.
        child: *RegexNode,
        /// The minimum repetition count.
        lower: i32,
        /// The maximum repetition count, or `-1` for no upper bound.
        upper: i32,
    },
    /// A reference to a grammar rule, compiled into a rule-ref FSM edge.
    RuleRef: i32,
    /// A bounded repetition of a grammar rule, compiled into a repeat-ref FSM edge. The rule
    /// holds the repeated sub-pattern; the Earley parser counts the repetitions at runtime, so
    /// the FSM is not unrolled.
    RepeatSubrule: struct {
        /// The repeated rule.
        rule_id: i32,
        /// The minimum repetition count.
        lower: i32,
        /// The maximum repetition count.
        upper: i32,
    },

    /// Frees the storage owned by this node (allocated from `allocator`).
    pub fn deinit(self: RegexNode, allocator: Allocator) void {
        switch (self) {
            .Leaf => |bytes| allocator.free(bytes),
            .Star, .Plus, .Optional => |child| {
                child.deinit(allocator);
                allocator.destroy(child);
            },
            .Union, .Bracket => |children| {
                for (children) |child| child.deinit(allocator);
                allocator.free(children);
            },
            .Repeat => |r| {
                r.child.deinit(allocator);
                allocator.destroy(r.child);
            },
            .RuleRef => {},
            .RepeatSubrule => {},
        }
    }

    /// Whether the node can match the empty string. Purely syntactic; no FSM is built.
    pub fn is_nullable(self: RegexNode) bool {
        return switch (self) {
            .Leaf => |regex| regex.len == 0,
            .Star, .Optional => true,
            .Plus => |child| child.is_nullable(),
            .Union => |branches| blk: {
                for (branches) |branch| {
                    if (branch.is_nullable()) break :blk true;
                }
                break :blk false;
            },
            .Bracket => |children| is_nullable_sequence(children),
            .Repeat => |r| r.lower == 0 or r.child.is_nullable(),
            .RuleRef => false,
            .RepeatSubrule => |r| r.lower == 0,
        };
    }

    /// Whether a sequence of nodes can match the empty string.
    pub fn is_nullable_sequence(nodes: []const RegexNode) bool {
        for (nodes) |node| {
            if (!node.is_nullable()) return false;
        }
        return true;
    }
};
