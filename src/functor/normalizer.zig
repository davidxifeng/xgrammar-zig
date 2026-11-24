//! Grammar normalization, structure normalization, repetition normalization, and
//! EBNF / built-in JSON constructors (`normalizer`).
//!
//! Structure normalization rewrites every rule body (after `eliminateSingleElementExprs`)
//! into the normal form `rule ::= ("" | (e1 e2 ...) | ...)`: a choices of sequences of leaf
//! elements, where only the first choice may be the empty string.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Diagnostic = @import("../Diagnostic.zig").Diagnostic;
const grammar_mod = @import("../grammar.zig");
const CharacterClassElement = grammar_mod.CharacterClassElement;
const Grammar = grammar_mod.Grammar;
const GrammarBuilder = grammar_mod.GrammarBuilder;
const GrammarExprType = grammar_mod.GrammarExprType;
const NO_EXPR = grammar_mod.NO_EXPR;
const dispatch = grammar_mod.dispatch;
const parser_mod = @import("../parser.zig");
const EbnfError = parser_mod.EbnfError;
const Compact2dArrayError = @import("../support.zig").Compact2dArrayError;
const mutator = @import("mutator.zig");
const FunctorError = mutator.FunctorError;
const simplify_passes = @import("simplify_passes.zig");

// ---------------------------------------------------------------------------
// 1. High-level normalization & grammar constructors
// ---------------------------------------------------------------------------

/// Normalizes a grammar: rename the root rule to `"root"`, then structure-normalize it.
pub fn normalize(allocator: Allocator, grammar: *const Grammar) FunctorError!Grammar {
    var renamed = try simplify_passes.renameRootRule(allocator, grammar);
    defer renamed.deinit();
    return normalizeStructure(allocator, &renamed);
}

/// Constructs a normalized BNF `Grammar` from an EBNF string.
///
/// On lexer/parser/normalization failure, populates `diag` (if non-null) using `gpa`.
pub fn fromEbnf(
    gpa: Allocator,
    ebnf_string: []const u8,
    root_rule_name: []const u8,
    diag: ?*Diagnostic,
) (Allocator.Error || Compact2dArrayError || EbnfError)!Grammar {
    var parsed = try parser_mod.ebnfToGrammarNoNormalization(gpa, ebnf_string, root_rule_name, diag);
    defer parsed.deinit();
    return normalize(gpa, &parsed) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EmptyIndptr, error.NonZeroStart, error.NotMonotonic, error.BadEnd => |e| return e,
        else => {
            if (diag) |d| d.setStatic(.message, "grammar normalization failed");
            return error.Normalization;
        },
    };
}

/// Returns the normalized built-in JSON grammar.
pub fn builtinJsonGrammar(allocator: Allocator) Allocator.Error!Grammar {
    return fromEbnf(allocator, BUILTIN_JSON_GRAMMAR, "root", null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable, // built-in JSON grammar is statically valid
    };
}

// ---------------------------------------------------------------------------
// 2. Structure normalizer
// ---------------------------------------------------------------------------

/// Normalizes the AST structure of `grammar`, returning a fresh `Grammar` by value.
pub fn normalizeStructure(allocator: Allocator, grammar: *const Grammar) FunctorError!Grammar {
    var base = try simplify_passes.eliminateSingleElementExprs(allocator, grammar);
    defer base.deinit();

    var normalizer = StructureNormalizer{
        .allocator = allocator,
        .base = &base,
        .builder = try GrammarBuilder.init(allocator),
        .cur_rule_name = "",
    };
    defer normalizer.builder.deinit();
    return normalizer.run();
}

const ExprView = struct { ty: GrammarExprType, data: []const i32 };

const StructureNormalizer = struct {
    allocator: Allocator,
    base: *const Grammar,
    builder: GrammarBuilder,
    cur_rule_name: []const u8,

    fn run(self: *StructureNormalizer) FunctorError!Grammar {
        for (self.base.rulesSlice()) |r| _ = try self.builder.addEmptyRule(r.name);
        for (0..self.base.numRules()) |i| {
            const r = self.base.rule(@intCast(i));
            self.cur_rule_name = r.name;
            const new_body = try self.visitRuleBody(r.body_expr_id);
            self.builder.updateRuleBody(@intCast(i), new_body);
            const new_lookahead = try self.visitLookahead(r.lookahead_assertion_id);
            self.builder.updateLookaheadAssertion(@intCast(i), new_lookahead);
            try self.builder.copyRuleAttributes(@intCast(i), self.base, @intCast(i), identityRuleId);
        }
        const root = self.base.rootRule().name;
        return self.builder.intoGrammar(root, null) catch |err| switch (err) {
            error.RootRuleNotFound => unreachable, // root rule preserved during normalization
            else => |e| return e,
        };
    }

    fn identityRuleId(id: i32) i32 {
        return id;
    }

    fn baseExpr(self: *const StructureNormalizer, expr_id: i32) ExprView {
        const e = self.base.expr(expr_id);
        return .{ .ty = e.ty, .data = e.data };
    }

    fn builtExpr(self: *const StructureNormalizer, expr_id: i32) ExprView {
        const e = self.builder.grammarExpr(expr_id);
        return .{ .ty = e.ty, .data = e.data };
    }

    fn rebuildTagDispatch(self: *StructureNormalizer, ty: GrammarExprType, data: []const i32) FunctorError!i32 {
        const alloc = self.builder.scratch_alloc;
        switch (ty) {
            .TagDispatch => {
                var td = try dispatch.decodeTagDispatchData(self.base, alloc, data);
                defer td.deinit(alloc);
                return self.builder.addTagDispatch(&td);
            },
            .TokenTagDispatch => {
                var ttd = try dispatch.decodeTokenTagDispatchData(alloc, data);
                defer ttd.deinit(alloc);
                return self.builder.addTokenTagDispatch(&ttd);
            },
            else => unreachable,
        }
    }

    fn visitLookahead(self: *StructureNormalizer, lookahead_id: i32) FunctorError!i32 {
        if (lookahead_id == NO_EXPR) return NO_EXPR;
        const decoded = self.baseExpr(lookahead_id);
        switch (decoded.ty) {
            .Sequence => {
                const ids = try self.visitSequenceData(decoded.data);
                defer self.builder.scratch_alloc.free(ids);
                return self.builder.addSequence(ids);
            },
            .Choices => std.debug.panic("Choices in lookahead assertion are not supported yet", .{}),
            .EmptyStr => std.debug.panic("Empty string should not be in lookahead assertion", .{}),
            .TagDispatch => std.debug.panic("TagDispatch should not be in lookahead assertion", .{}),
            .Regex => std.debug.panic("Regex should not be in lookahead assertion", .{}),
            .Substring => std.debug.panic("Substring should not be in lookahead assertion", .{}),
            else => {
                const element = try self.builder.addGrammarExpr(decoded.ty, decoded.data);
                return self.builder.addSequence(&.{element});
            },
        }
    }

    fn visitRuleBody(self: *StructureNormalizer, expr_id: i32) FunctorError!i32 {
        const decoded = self.baseExpr(expr_id);
        const ty = decoded.ty;
        const data = decoded.data;
        switch (ty) {
            .Sequence => {
                const ids = try self.visitSequenceData(data);
                defer self.builder.scratch_alloc.free(ids);
                const seq = try self.builder.addSequence(ids);
                return self.builder.addChoices(&.{seq});
            },
            .Choices => {
                const ids = try self.visitChoicesData(data);
                defer self.builder.scratch_alloc.free(ids);
                return self.builder.addChoices(ids);
            },
            .EmptyStr => {
                const empty = try self.builder.addEmptyStr();
                return self.builder.addChoices(&.{empty});
            },
            .ByteString, .CharacterClass, .CharacterClassStar, .RuleRef, .Repeat, .Token, .ExcludeToken => {
                const element = try self.builder.addGrammarExpr(ty, data);
                const seq = try self.builder.addSequence(&.{element});
                return self.builder.addChoices(&.{seq});
            },
            .TagDispatch => return self.rebuildTagDispatch(ty, data),
            .Regex, .Substring => return self.builder.addGrammarExpr(ty, data),
            .TokenTagDispatch => {
                const ttd = try self.rebuildTagDispatch(ty, data);
                const rule_id = try self.builder.addRuleWithHint(self.cur_rule_name, ttd);
                const rule_ref = try self.builder.addRuleRef(rule_id);
                const seq = try self.builder.addSequence(&.{rule_ref});
                return self.builder.addChoices(&.{seq});
            },
        }
    }

    fn visitChoicesData(self: *StructureNormalizer, data: []const i32) FunctorError![]i32 {
        const alloc = self.builder.scratch_alloc;
        var new_choice_ids: std.ArrayList(i32) = .empty;
        errdefer new_choice_ids.deinit(alloc);
        var found_empty = false;
        for (data) |choice| {
            const decoded = self.baseExpr(choice);
            switch (decoded.ty) {
                .Sequence => {
                    const sub = try self.visitSequenceData(decoded.data);
                    defer alloc.free(sub);
                    if (sub.len == 0) {
                        found_empty = true;
                    } else {
                        try new_choice_ids.append(alloc, try self.builder.addSequence(sub));
                    }
                },
                .Choices => {
                    const sub = try self.visitChoicesData(decoded.data);
                    defer alloc.free(sub);
                    const first_is_empty = self.builtExpr(sub[0]).ty == .EmptyStr;
                    if (first_is_empty) {
                        found_empty = true;
                        try new_choice_ids.appendSlice(alloc, sub[1..]);
                    } else {
                        try new_choice_ids.appendSlice(alloc, sub);
                    }
                },
                .EmptyStr => found_empty = true,
                .TagDispatch, .TokenTagDispatch => {
                    const element = try self.rebuildTagDispatch(decoded.ty, decoded.data);
                    const rule_id = try self.builder.addRuleWithHint(self.cur_rule_name, element);
                    const rule_ref = try self.builder.addRuleRef(rule_id);
                    try new_choice_ids.append(alloc, try self.builder.addSequence(&.{rule_ref}));
                },
                .Regex, .Substring => {
                    const element = try self.builder.addGrammarExpr(decoded.ty, decoded.data);
                    const rule_id = try self.builder.addRuleWithHint(self.cur_rule_name, element);
                    const rule_ref = try self.builder.addRuleRef(rule_id);
                    try new_choice_ids.append(alloc, try self.builder.addSequence(&.{rule_ref}));
                },
                else => {
                    const element = try self.builder.addGrammarExpr(decoded.ty, decoded.data);
                    try new_choice_ids.append(alloc, try self.builder.addSequence(&.{element}));
                },
            }
        }
        if (found_empty) {
            const empty = try self.builder.addEmptyStr();
            try new_choice_ids.insert(alloc, 0, empty);
        }
        std.debug.assert(new_choice_ids.items.len != 0);
        return new_choice_ids.toOwnedSlice(alloc);
    }

    fn visitSequenceData(self: *StructureNormalizer, data: []const i32) FunctorError![]i32 {
        const alloc = self.builder.scratch_alloc;
        var new_sequence_ids: std.ArrayList(i32) = .empty;
        errdefer new_sequence_ids.deinit(alloc);
        for (data) |element| {
            const decoded = self.baseExpr(element);
            switch (decoded.ty) {
                .Sequence => {
                    const sub = try self.visitSequenceData(decoded.data);
                    defer alloc.free(sub);
                    try new_sequence_ids.appendSlice(alloc, sub);
                },
                .Choices => {
                    const sub = try self.visitChoicesData(decoded.data);
                    defer alloc.free(sub);
                    if (sub.len == 1) {
                        const decoded_sub = self.builtExpr(sub[0]);
                        if (decoded_sub.ty != .EmptyStr) {
                            try new_sequence_ids.appendSlice(alloc, decoded_sub.data);
                        }
                    } else {
                        const choices = try self.builder.addChoices(sub);
                        const rule_id = try self.builder.addRuleWithHint(self.cur_rule_name, choices);
                        try new_sequence_ids.append(alloc, try self.builder.addRuleRef(rule_id));
                    }
                },
                .EmptyStr => {},
                .TagDispatch, .TokenTagDispatch => {
                    const element_id = try self.rebuildTagDispatch(decoded.ty, decoded.data);
                    const rule_id = try self.builder.addRuleWithHint(self.cur_rule_name, element_id);
                    try new_sequence_ids.append(alloc, try self.builder.addRuleRef(rule_id));
                },
                .Regex, .Substring => {
                    const element_id = try self.builder.addGrammarExpr(decoded.ty, decoded.data);
                    const rule_id = try self.builder.addRuleWithHint(self.cur_rule_name, element_id);
                    try new_sequence_ids.append(alloc, try self.builder.addRuleRef(rule_id));
                },
                else => try new_sequence_ids.append(alloc, try self.builder.addGrammarExpr(decoded.ty, decoded.data)),
            }
        }
        return new_sequence_ids.toOwnedSlice(alloc);
    }
};

// ---------------------------------------------------------------------------
// 3. Repetition normalizer
// ---------------------------------------------------------------------------

/// Marks every repeated rule exact-lookahead and lowers nullable repeats' minimum count
/// to 0 in place. Must run after `allowEmptyRuleIds` has populated the grammar.
pub fn normalizeRepetition(grammar: *Grammar) void {
    const allow_empty = grammar.allowEmptyRuleIdsSlice();
    for (0..grammar.numExprs()) |expr_id| {
        const e = grammar.expr(@intCast(expr_id));
        if (e.ty != .Repeat) continue;
        const repeat_rule_id = e.data[0];
        grammar.ruleMut(repeat_rule_id).is_exact_lookahead = true;
        if (std.sort.binarySearch(i32, allow_empty, repeat_rule_id, struct {
            fn cmp(ctx: i32, item: i32) std.math.Order {
                return std.math.order(item, ctx);
            }
        }.cmp) != null) {
            grammar.setExprData(@intCast(expr_id), 1, 0);
        }
    }
}

// ---------------------------------------------------------------------------
// Built-in JSON grammar
// ---------------------------------------------------------------------------

const BUILTIN_JSON_GRAMMAR =
    \\
    \\root ::= (
    \\    "{" [ \n\r\t]* members_and_embrace |
    \\    "[" [ \n\r\t]* elements_or_embrace
    \\)
    \\value_non_str ::= (
    \\    "{" [ \n\r\t]* members_and_embrace |
    \\    "[" [ \n\r\t]* elements_or_embrace |
    \\    "0" fraction exponent |
    \\    [1-9] [0-9]* fraction exponent |
    \\    "-" [0-9] fraction exponent |
    \\    "-" [1-9] [0-9]* fraction exponent |
    \\    "true" |
    \\    "false" |
    \\    "null"
    \\) (= [ \n\r\t]* member_suffix_suffix)
    \\members_and_embrace ::= ("\"" characters_and_colon [ \n\r\t]* members_suffix | "}") (= [ \n\r\t,}\]])
    \\members_suffix ::= (
    \\    value_non_str [ \n\r\t]* member_suffix_suffix |
    \\    "\"" characters_and_embrace |
    \\    "\"" characters_and_comma [ \n\r\t]* "\"" characters_and_colon [ \n\r\t]* members_suffix
    \\) (= [ \n\r\t,}\]])
    \\member_suffix_suffix ::= (
    \\    "}" |
    \\    "," [ \n\r\t]* "\"" characters_and_colon [ \n\r\t]* members_suffix
    \\) (= [ \n\r\t,}\]])
    \\elements_or_embrace ::= (
    \\    "{" [ \n\r\t]* members_and_embrace elements_rest [ \n\r\t]* "]" |
    \\    "[" [ \n\r\t]* elements_or_embrace elements_rest [ \n\r\t]* "]" |
    \\    "\"" characters_item elements_rest [ \n\r\t]* "]" |
    \\    "0" fraction exponent elements_rest [ \n\r\t]* "]" |
    \\    [1-9] [0-9]* fraction exponent elements_rest [ \n\r\t]* "]" |
    \\    "-" "0" fraction exponent elements_rest [ \n\r\t]* "]" |
    \\    "-" [1-9] [0-9]* fraction exponent elements_rest [ \n\r\t]* "]" |
    \\    "true" elements_rest [ \n\r\t]* "]" |
    \\    "false" elements_rest [ \n\r\t]* "]" |
    \\    "null" elements_rest [ \n\r\t]* "]" |
    \\    "]"
    \\)
    \\elements ::= (
    \\    "{" [ \n\r\t]* members_and_embrace elements_rest |
    \\    "[" [ \n\r\t]* elements_or_embrace elements_rest |
    \\    "\"" characters_item elements_rest |
    \\    "0" fraction exponent elements_rest |
    \\    [1-9] [0-9]* fraction exponent elements_rest |
    \\    "-" [0-9] fraction exponent elements_rest |
    \\    "-" [1-9] [0-9]* fraction exponent elements_rest |
    \\    "true" elements_rest |
    \\    "false" elements_rest |
    \\    "null" elements_rest
    \\)
    \\elements_rest ::= (
    \\    "" |
    \\    [ \n\r\t]* "," [ \n\r\t]* elements
    \\)
    \\characters_and_colon ::= (
    \\    "\"" [ \n\r\t]* ":" |
    \\    [^"\\\x00-\x1F] characters_and_colon |
    \\    "\\" escape characters_and_colon
    \\) (=[ \n\r\t]* [\"{[0-9tfn-])
    \\characters_and_comma ::= (
    \\    "\"" [ \n\r\t]* "," |
    \\    [^"\\\x00-\x1F] characters_and_comma |
    \\    "\\" escape characters_and_comma
    \\) (=[ \n\r\t]* "\"")
    \\characters_and_embrace ::= (
    \\    "\"" [ \n\r\t]* "}" |
    \\    [^"\\\x00-\x1F] characters_and_embrace |
    \\    "\\" escape characters_and_embrace
    \\) (=[ \n\r\t]* [},])
    \\characters_item ::= (
    \\    "\"" |
    \\    [^"\\\x00-\x1F] characters_item |
    \\    "\\" escape characters_item
    \\) (= [ \n\r\t]* [,\]])
    \\escape ::= ["\\/bfnrt] | "u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]
    \\fraction ::= "" | "." [0-9] [0-9]*
    \\exponent ::= "" |  "e" sign [0-9] [0-9]* | "E" sign [0-9] [0-9]*
    \\sign ::= "" | "+" | "-"
    \\
;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "builtinJsonGrammar normalizes cleanly" {
    const gpa = std.testing.allocator;
    var grammar = try builtinJsonGrammar(gpa);
    defer grammar.deinit();
    try std.testing.expect(!grammar.isOptimized());
    try std.testing.expectEqualStrings("root", grammar.rootRule().name);
    for (grammar.rulesSlice()) |r| {
        const body = grammar.expr(r.body_expr_id);
        try std.testing.expect(body.ty == .Choices or body.ty == .Regex or
            body.ty == .Substring or body.ty == .TagDispatch or body.ty == .TokenTagDispatch);
    }
}

test "fromEbnf renames root and normalizes structure" {
    const gpa = std.testing.allocator;
    var grammar = try fromEbnf(gpa, "main ::= (\"a\" | (\"b\" \"\")) \"c\"", "main", null);
    defer grammar.deinit();
    try std.testing.expectEqualStrings("root", grammar.rootRule().name);
    const ebnf = try grammar.toStringEbnf(gpa);
    defer gpa.free(ebnf);
    try std.testing.expectEqualStrings("root ::= ((root_1 \"c\"))\nroot_1 ::= ((\"a\") | (\"b\"))\n", ebnf);

    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);
    try std.testing.expectError(error.Parser, fromEbnf(gpa, "other ::= \"x\"", "main", &diag));
    try std.testing.expectEqual(Diagnostic.Kind.ebnf_parser, diag.kind);
}

test "normalizeStructure flattens nested choices and sequences" {
    const gpa = std.testing.allocator;
    var builder = try GrammarBuilder.init(gpa);
    defer builder.deinit();
    const a = try builder.addByteString("a");
    const b = try builder.addByteString("b");
    const inner_choices = try builder.addChoices(&.{ a, try builder.addSequence(&.{ b, try builder.addEmptyStr() }) });
    const seq = try builder.addSequence(&.{ inner_choices, try builder.addByteString("c") });
    const body = try builder.addChoices(&.{ seq, try builder.addEmptyStr() });
    _ = try builder.addRuleNamed("root", body);
    var grammar = try builder.intoGrammar("root", null);
    defer grammar.deinit();

    var normalized = try normalizeStructure(gpa, &grammar);
    defer normalized.deinit();
    const ebnf = try normalized.toStringEbnf(gpa);
    defer gpa.free(ebnf);
    try std.testing.expectEqualStrings("root ::= (\"\" | (root_1 \"c\"))\nroot_1 ::= ((\"a\") | (\"b\"))\n", ebnf);
}

test "normalizeRepetition lowers minimum of nullable repeats" {
    const gpa = std.testing.allocator;
    var builder = try GrammarBuilder.init(gpa);
    defer builder.deinit();
    const cc = try builder.addCharacterClass(&.{CharacterClassElement.init('a', 'b')}, false);
    const inner = try builder.addRuleNamed("inner", cc);
    const empty = try builder.addEmptyStr();
    const inner_choices = try builder.addChoices(&.{ empty, try builder.addRuleRef(inner) });
    try builder.updateRuleBodyByName("inner", inner_choices);
    const rep = try builder.addRepeat(inner, 1, -1);
    _ = try builder.addRuleNamed("root", rep);
    var grammar = try builder.intoGrammar("root", null);
    defer grammar.deinit();

    try grammar.setAllowEmptyRuleIds(&.{0});
    normalizeRepetition(&grammar);
    try std.testing.expect(grammar.rule(0).is_exact_lookahead);
    const rep_expr = grammar.expr(grammar.rule(1).body_expr_id);
    try std.testing.expectEqual(@as(i32, 0), rep_expr.data[1]);
}
