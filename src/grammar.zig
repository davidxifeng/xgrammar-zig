//! The grammar data model: BNF abstract syntax tree (AST), builder, dispatch decoders,
//! streaming EBNF printer, and streaming JSON serialization.

const std = @import("std");
const Diagnostic = @import("Diagnostic.zig").Diagnostic;

pub const grammar_mod = @import("grammar/Grammar.zig");
pub const builder_mod = @import("grammar/Builder.zig");
pub const dispatch = @import("grammar/dispatch.zig");
pub const printer = @import("grammar/printer.zig");
pub const serialization = @import("grammar/serialization.zig");

pub const Grammar = grammar_mod.Grammar;
pub const GrammarImpl = grammar_mod.GrammarImpl;
pub const FsmStatePair = grammar_mod.FsmStatePair;
pub const StorageMut = grammar_mod.StorageMut;
pub const Rule = grammar_mod.Rule;
pub const NO_EXPR = grammar_mod.NO_EXPR;
pub const GrammarExpr = grammar_mod.GrammarExpr;
pub const GrammarExprType = grammar_mod.GrammarExprType;
pub const UnknownGrammarExprType = grammar_mod.UnknownGrammarExprType;
pub const CharacterClassElement = grammar_mod.CharacterClassElement;
pub const SuffixStopInfo = grammar_mod.SuffixStopInfo;
pub const DeserializeError = grammar_mod.DeserializeError;
pub const dupeRule = grammar_mod.dupeRule;
pub const dupeSuffixStopInfo = grammar_mod.dupeSuffixStopInfo;
pub const searchByRuleId = grammar_mod.searchByRuleId;

pub const GrammarBuilder = builder_mod.GrammarBuilder;

pub const TagDispatch = dispatch.TagDispatch;
pub const TagRulePair = dispatch.TagRulePair;
pub const TokenTagDispatch = dispatch.TokenTagDispatch;
pub const TriggerRulePair = dispatch.TriggerRulePair;
pub const tagDispatch = dispatch.tagDispatch;
pub const decodeTagDispatchData = dispatch.decodeTagDispatchData;
pub const tokenTagDispatch = dispatch.tokenTagDispatch;
pub const decodeTokenTagDispatchData = dispatch.decodeTokenTagDispatchData;

pub const writeEbnf = printer.writeEbnf;
pub const toStringEbnf = printer.toStringEbnf;
pub const serializeJson = serialization.serializeJson;
pub const writeJson = serialization.writeJson;
pub const writeJsonEmbedded = serialization.writeJsonEmbedded;
pub const deserializeJson = serialization.deserializeJson;
pub const deserializeJsonValue = serialization.deserializeJsonValue;
pub const deserializeJsonValueEmbedded = serialization.deserializeJsonValueEmbedded;

test {
    _ = grammar_mod;
    _ = builder_mod;
    _ = dispatch;
    _ = printer;
    _ = serialization;
    _ = @import("grammar/serialization_spec_test.zig");
    std.testing.refAllDecls(@This());
}

test "builder, printer ebnf with attributes, serialization roundtrip" {
    const backing = std.testing.allocator;
    var builder = try GrammarBuilder.init(backing);
    defer builder.deinit();

    const cc = try builder.addCharacterClass(&.{CharacterClassElement.init('a', 'z')}, false);
    const star = try builder.addCharacterClassStar(&.{CharacterClassElement.init('a', 'z')}, false);
    const str_rule = try builder.addRuleNamed("word", cc);
    const rep = try builder.addRepeat(str_rule, 2, -1);
    const star_rule = try builder.addRuleNamed("rest", star);
    const seq = try builder.addSequence(&.{ rep, try builder.addRuleRef(star_rule) });
    const alt = try builder.addChoices(&.{ seq, try builder.addEmptyStr() });
    const root = try builder.addRuleNamed("root", alt);
    try builder.updateLookaheadAssertionByName("root", seq);
    builder.updateLookaheadExact(root, true);
    builder.updateMaxTokens(root, 8);
    builder.updateMaxChars(root, 64);
    try builder.updateCaptureName(root, "out");
    builder.updateLazy(root, true);
    builder.updateRuleTemperature(root, 0.7);

    var built = try builder.intoGrammar("root", null);
    defer built.deinit();

    const ebnf = try built.toStringEbnf(backing);
    defer backing.free(ebnf);
    try std.testing.expectEqualStrings(
        "word ::= [a-z]\n" ++
            "rest ::= [a-z]*\n" ++
            "root[max_tokens=8, max_chars=64, capture=\"out\", lazy, temperature=0.699999988] ::= ((word{2, -1} rest) | \"\") (=(word{2, -1} rest))\n",
        ebnf,
    );

    const formatted = try std.fmt.allocPrint(backing, "{f}", .{built});
    defer backing.free(formatted);
    try std.testing.expectEqualStrings(ebnf, formatted);

    const json = try built.serializeJson(backing);
    defer backing.free(json);
    var diag: Diagnostic = .{};
    defer diag.deinit(backing);
    var parsed = try Grammar.deserializeJson(backing, json, &diag);
    defer parsed.deinit();
    try std.testing.expect(built.eql(&parsed));
    try std.testing.expectEqual(seq, parsed.rule(root).lookahead_assertion_id);
    try std.testing.expect(parsed.rule(root).is_exact_lookahead);
    try std.testing.expectEqual(@as(i32, 8), parsed.rule(root).max_tokens);
    try std.testing.expectEqualStrings("out", parsed.rule(root).capture_name);
    try std.testing.expect(parsed.rule(root).is_lazy);
    try std.testing.expectEqual(@as(?f32, 0.7), parsed.rule(root).temperature);
    const roundtrip_json = try parsed.serializeJson(backing);
    defer backing.free(roundtrip_json);
    try std.testing.expectEqualStrings(json, roundtrip_json);
}

test "fromGrammar cycle preserves the grammar" {
    const backing = std.testing.allocator;
    var builder = try GrammarBuilder.init(backing);
    defer builder.deinit();
    const bs = try builder.addByteString("ok");
    _ = try builder.addRuleNamed("root", bs);
    var info = SuffixStopInfo.default();
    info.rule_id = 0;
    info.stop_capture_name = "s";
    try builder.updateSuffixStopInfo(0, info);
    var built = try builder.intoGrammarWithRootId(0);
    defer built.deinit();

    var seeded = try GrammarBuilder.fromGrammar(&built, backing);
    defer seeded.deinit();
    var grammar2 = try seeded.intoGrammarWithRootId(0);
    defer grammar2.deinit();
    try std.testing.expect(built.eql(&grammar2));
    try std.testing.expect(grammar2.eql(&built));
}
