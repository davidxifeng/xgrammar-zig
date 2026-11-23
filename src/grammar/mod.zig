//! The grammar data model: the BNF abstract syntax tree (AST), its builder, and EBNF
//! printing (`mod.rs`).

pub const character_class_element = @import("character_class_element.zig");
pub const error_mod = @import("error.zig"); // Rust `mod error` — `error` is a Zig keyword
pub const grammar = @import("grammar.zig");
pub const grammar_builder = @import("grammar_builder.zig");
pub const grammar_expr = @import("grammar_expr.zig");
pub const grammar_expr_type = @import("grammar_expr_type.zig");
pub const printer = @import("printer.zig");
pub const rule = @import("rule.zig");
pub const serialization = @import("serialization.zig");
pub const suffix_stop_info = @import("suffix_stop_info.zig");
pub const tag_dispatch = @import("tag_dispatch.zig");
pub const token_tag_dispatch = @import("token_tag_dispatch.zig");

// pub use character_class_element::CharacterClassElement;
pub const CharacterClassElement = character_class_element.CharacterClassElement;
// pub use error::DeserializeError;
pub const DeserializeError = error_mod.DeserializeError;
pub const DeserializeErrorInfo = error_mod.DeserializeErrorInfo;
// pub use grammar::Grammar;
pub const Grammar = grammar.Grammar;
// pub use grammar_builder::GrammarBuilder;
pub const GrammarBuilder = grammar_builder.GrammarBuilder;
// pub use grammar_expr::GrammarExpr;
pub const GrammarExpr = grammar_expr.GrammarExpr;
// pub use grammar_expr_type::{GrammarExprType, UnknownGrammarExprType};
pub const GrammarExprType = grammar_expr_type.GrammarExprType;
pub const UnknownGrammarExprType = grammar_expr_type.UnknownGrammarExprType;
// pub use rule::{NO_EXPR, Rule};
pub const NO_EXPR = rule.NO_EXPR;
pub const Rule = rule.Rule;
// pub use suffix_stop_info::SuffixStopInfo;
pub const SuffixStopInfo = suffix_stop_info.SuffixStopInfo;
// pub use tag_dispatch::TagDispatch;
pub const TagDispatch = tag_dispatch.TagDispatch;
// pub use token_tag_dispatch::TokenTagDispatch;
pub const TokenTagDispatch = token_tag_dispatch.TokenTagDispatch;

test {
    _ = character_class_element;
    _ = error_mod;
    _ = @import("serialization_spec_test.zig");
    _ = grammar;
    _ = grammar_builder;
    _ = grammar_expr;
    _ = grammar_expr_type;
    _ = printer;
    _ = rule;
    _ = serialization;
    _ = suffix_stop_info;
    _ = tag_dispatch;
    _ = token_tag_dispatch;
}

// Behavior tests over the re-exported surface (builder → printer → serialization).

const std = @import("std");

test "builder, printer ebnf with attributes, serialization roundtrip" {
    const backing = std.testing.allocator;
    var builder = try GrammarBuilder.new(backing);
    defer builder.deinit();

    // root ::= ( [a-z]{2,} ... with lookahead and attributes)
    const cc = try builder.add_character_class(&.{CharacterClassElement.new('a', 'z')}, false);
    const star = try builder.add_character_class_star(&.{CharacterClassElement.new('a', 'z')}, false);
    const str_rule = try builder.add_rule_named("word", cc);
    const rep = try builder.add_repeat(str_rule, 2, -1);
    const star_rule = try builder.add_rule_named("rest", star);
    const seq = try builder.add_sequence(&.{ rep, try builder.add_rule_ref(star_rule) });
    const alt = try builder.add_choices(&.{ seq, try builder.add_empty_str() });
    const root = try builder.add_rule_named("root", alt);
    try builder.update_lookahead_assertion_by_name("root", seq);
    builder.update_lookahead_exact(root, true);
    builder.update_max_tokens(root, 8);
    builder.update_max_chars(root, 64);
    try builder.update_capture_name(root, "out");
    builder.update_lazy(root, true);
    builder.update_rule_temperature(root, 0.7);

    var g_arena = std.heap.ArenaAllocator.init(backing);
    defer g_arena.deinit();
    const built = try builder.into_grammar(g_arena.allocator(), "root", null);
    defer built.deinit();

    const ebnf = try printer.to_string_ebnf(built, backing);
    defer backing.free(ebnf);
    try std.testing.expectEqualStrings(
        "word ::= [a-z]\n" ++
            "rest ::= [a-z]*\n" ++
            "root[max_tokens=8, max_chars=64, capture=\"out\", lazy, temperature=0.699999988] ::= ((word{2, -1} rest) | \"\") (=(word{2, -1} rest))\n",
        ebnf,
    );

    var ser_arena = std.heap.ArenaAllocator.init(backing);
    defer ser_arena.deinit();
    const sa = ser_arena.allocator();
    const json = try serialization.serialize_json(built, sa);
    var info: DeserializeErrorInfo = undefined;
    const parsed = try serialization.deserialize_json(backing, json, &info);
    defer parsed.deinit();
    try std.testing.expect(built.eql(parsed));
    try std.testing.expect(parsed.rule(root).lookahead_assertion_id == seq);
    try std.testing.expect(parsed.rule(root).is_exact_lookahead);
    try std.testing.expectEqual(@as(i32, 8), parsed.rule(root).max_tokens);
    try std.testing.expectEqualStrings("out", parsed.rule(root).capture_name);
    try std.testing.expect(parsed.rule(root).is_lazy);
    try std.testing.expectEqual(@as(?f32, 0.7), parsed.rule(root).temperature);
    const roundtrip_json = try serialization.serialize_json(parsed, sa);
    try std.testing.expectEqualStrings(json, roundtrip_json);
}

test "from_grammar cycle preserves the grammar" {
    const backing = std.testing.allocator;
    var builder = try GrammarBuilder.new(backing);
    defer builder.deinit();
    const bs = try builder.add_byte_string("ok");
    _ = try builder.add_rule_named("root", bs);
    var info = SuffixStopInfo.default();
    info.rule_id = 0;
    info.stop_capture_name = "s";
    try builder.update_suffix_stop_info(0, info);
    const built = try builder.into_grammar_with_root_id(backing, 0);
    defer built.deinit();

    var seeded = try GrammarBuilder.from_grammar(built, backing);
    defer seeded.deinit();
    const grammar2 = try seeded.into_grammar_with_root_id(backing, 0);
    defer grammar2.deinit();
    try std.testing.expect(built.eql(grammar2));
    try std.testing.expect(grammar2.eql(built));
}
