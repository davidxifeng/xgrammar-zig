//! Fuses consecutive byte strings within a sequence, in place (`byte_string_fuser.rs`).
//!
//! Only sequences that contain an empty byte string or two adjacent byte strings are
//! rebuilt, with each run merged into a single byte string; the rest keep their original
//! ids. Fusing keeps the matcher's hot path comparing whole literals instead of one byte
//! at a time.

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_mod = @import("../grammar/mod.zig");
const Grammar = grammar_mod.Grammar;
const GrammarExprType = grammar_mod.GrammarExprType;
const in_place = @import("in_place_grammar_rewriter.zig");

const ByteStringFuser = struct {
    pub fn visit_sequence(
        self: ByteStringFuser,
        builder: *grammar_mod.GrammarBuilder,
        memo: []i32,
        expr_id: i32,
    ) (Allocator.Error || @import("../support/mod.zig").Compact2dArrayError)!i32 {
        _ = self;
        _ = memo;
        const gpa = builder.allocator;
        // Read-only probe, so the common unchanged case allocates nothing.
        var previous_is_byte_string = false;
        var needs_rewrite = false;
        for (builder.grammar_expr(expr_id).data) |element_id| {
            const element = builder.grammar_expr(element_id);
            const is_byte_string = element.ty == .ByteString;
            const fusable = is_byte_string and (previous_is_byte_string or element.is_empty());
            previous_is_byte_string = is_byte_string;
            if (fusable) needs_rewrite = true;
        }
        if (!needs_rewrite) return expr_id;
        // Copy the element ids first: fusing appends to the arena.
        const source_data = builder.grammar_expr(expr_id).data;
        const element_ids = try gpa.dupe(i32, source_data);
        defer gpa.free(element_ids);
        var new_element_ids: std.ArrayList(i32) = .empty;
        defer new_element_ids.deinit(gpa);
        var index: usize = 0;
        while (index < element_ids.len) {
            if (builder.grammar_expr(element_ids[index]).ty != .ByteString) {
                try new_element_ids.append(gpa, element_ids[index]);
                index += 1;
                continue;
            }
            var fused_bytes: std.ArrayList(i32) = .empty;
            defer fused_bytes.deinit(gpa);
            var run_end = index;
            while (run_end < element_ids.len) {
                const element = builder.grammar_expr(element_ids[run_end]);
                if (element.ty != .ByteString) break;
                try fused_bytes.appendSlice(gpa, element.data);
                run_end += 1;
            }
            // Empty byte strings are epsilon and can be omitted from a sequence.
            if (fused_bytes.items.len != 0) {
                try new_element_ids.append(gpa, if (run_end - index == 1)
                    element_ids[index]
                else
                    try builder.add_byte_string_bytes(fused_bytes.items));
            }
            index = run_end;
        }
        return builder.add_sequence(new_element_ids.items);
    }
};

/// Fuses adjacent byte strings in `grammar` in place (the `GrammarFunctor.byte_string_fuser` pass).
pub fn byte_string_fuser(grammar: *Grammar) (Allocator.Error || @import("../support/mod.zig").Compact2dArrayError)!void {
    try in_place.apply(ByteStringFuser{}, grammar);
}

test "byte string fuser merges adjacent strings and drops empties" {
    const gpa = std.testing.allocator;
    const GrammarBuilder = grammar_mod.grammar_builder.GrammarBuilder;
    var builder = try GrammarBuilder.new(gpa);
    defer builder.deinit();
    const a = try builder.add_byte_string("a");
    const empty = try builder.add_byte_string("");
    const bc = try builder.add_byte_string("bc");
    const cc = try builder.add_character_class(&.{grammar_mod.CharacterClassElement.new('x', 'y')}, false);
    const seq = try builder.add_sequence(&.{ a, empty, bc, cc, try builder.add_byte_string("") });
    _ = try builder.add_rule_named("root", seq);
    const grammar = try builder.into_grammar(gpa, "root", null);
    defer grammar.deinit();

    try byte_string_fuser(grammar);

    const body = grammar.expr(grammar.rule(0).body_expr_id);
    try std.testing.expectEqual(@as(usize, 2), body.data.len);
    const fused = try grammar.expr(body.data[0]).byte_string(gpa);
    defer gpa.free(fused);
    try std.testing.expectEqualStrings("abc", fused);
    try std.testing.expect(grammar.expr(body.data[1]).ty == .CharacterClass);
}
