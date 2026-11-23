//! Eliminates single-element sequences/choices and single-char classes
//! (`single_element_expr_eliminator.rs`). Not on the mod.rs re-export face
//! (Rust `pub(crate)`); ported as a dependency of `structure_normalizer`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_mod = @import("grammar/mod.zig");
const Grammar = grammar_mod.Grammar;
const GrammarExprType = grammar_mod.GrammarExprType;
const mutator = @import("mutator.zig");
const MutatorState = mutator.MutatorState;
const support = @import("support/mod.zig");
const error_mod = @import("error.zig");
const FunctorError = error_mod.FunctorError;

/// A pass that collapses one-element sequences and choices to their single child, and
/// rewrites a single-codepoint positive character class as a byte string.
pub const SingleElementExprEliminator = struct {
    /// Rebuilds a sequence; a one-element sequence collapses to its single child.
    pub fn visit_sequence(self: SingleElementExprEliminator, state: *MutatorState, data: []const i32) FunctorError!i32 {
        _ = self;
        const gpa = state.gpa();
        var ids: std.ArrayList(i32) = .empty;
        defer ids.deinit(gpa);
        try ids.ensureTotalCapacity(gpa, data.len);
        for (data) |child| ids.appendAssumeCapacity(try mutator.visit_expr_id(self, state, child));
        if (ids.items.len == 1) return ids.items[0];
        return state.builder.add_sequence(ids.items);
    }

    /// Rebuilds an alternation; a one-element alternation collapses to its single child.
    pub fn visit_choices(self: SingleElementExprEliminator, state: *MutatorState, data: []const i32) FunctorError!i32 {
        _ = self;
        const gpa = state.gpa();
        var ids: std.ArrayList(i32) = .empty;
        defer ids.deinit(gpa);
        try ids.ensureTotalCapacity(gpa, data.len);
        for (data) |child| ids.appendAssumeCapacity(try mutator.visit_expr_id(self, state, child));
        if (ids.items.len == 1) return ids.items[0];
        return state.builder.add_choices(ids.items);
    }

    /// `[c]` (a single, non-negated codepoint) becomes the byte string of that codepoint.
    pub fn visit_character_class(
        self: SingleElementExprEliminator,
        state: *MutatorState,
        ty: GrammarExprType,
        data: []const i32,
    ) FunctorError!i32 {
        _ = self;
        if (data.len == 3 and data[0] == 0 and data[1] == data[2]) {
            const gpa = state.gpa();
            const bytes = try support.encoding.char_to_utf8_bytes(gpa, @intCast(data[1]));
            defer gpa.free(bytes);
            var byte_ids: std.ArrayList(i32) = .empty;
            defer byte_ids.deinit(gpa);
            try byte_ids.ensureTotalCapacity(gpa, bytes.len);
            for (bytes) |b| byte_ids.appendAssumeCapacity(b);
            return state.builder.add_byte_string_bytes(byte_ids.items);
        }
        return state.builder.add_grammar_expr(ty, data);
    }
};

/// Applies the pass, returning a fresh grammar.
pub fn apply(allocator: Allocator, grammar: *const Grammar) FunctorError!*Grammar {
    return mutator.apply(SingleElementExprEliminator{}, allocator, grammar);
}
