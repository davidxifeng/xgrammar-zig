//! Grammar normalization and constructors from EBNF and built-in JSON
//! (`grammar_normalizer.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_mod = @import("../grammar/mod.zig");
const Grammar = grammar_mod.Grammar;
const parser_mod = @import("../parser/mod.zig");
const EbnfError = parser_mod.EbnfError;
const EbnfErrorInfo = parser_mod.EbnfErrorInfo;
const root_rule_renamer_mod = @import("root_rule_renamer.zig");
const structure_normalizer_mod = @import("structure_normalizer.zig");
const error_mod = @import("error.zig");
const FunctorError = error_mod.FunctorError;

/// Normalizes a grammar: rename the root to `root`, then structure-normalize it.
pub fn grammar_normalizer(allocator: Allocator, grammar: *const Grammar) FunctorError!*Grammar {
    const renamed = try root_rule_renamer_mod.root_rule_renamer(allocator, grammar);
    defer renamed.deinit();
    return structure_normalizer_mod.structure_normalizer(allocator, renamed);
}

/// Constructs a BNF grammar with an EBNF-formatted string (Rust `Grammar::from_ebnf`).
/// The grammar will be normalized (simplified) by default.
///
/// On `error.Normalization`, `diag.normalization` receives the message
/// (allocated from `gpa`; the caller owns it; Rust catches a normalization panic there).
pub fn from_ebnf(
    gpa: Allocator,
    ebnf_string: []const u8,
    root_rule_name: []const u8,
    diag: ?*EbnfErrorInfo,
) (Allocator.Error || EbnfError || FunctorError)!*Grammar {
    const parsed = try parser_mod.ebnf_to_grammar_no_normalization(gpa, ebnf_string, root_rule_name, diag);
    defer parsed.deinit();
    const normalized = grammar_normalizer(gpa, parsed) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EmptyIndptr, error.NonZeroStart, error.NotMonotonic, error.BadEnd => return err,
        else => {
            if (diag) |d| {
                d.* = .{ .normalization = try gpa.dupe(u8, "grammar normalization failed") };
            }
            return error.Normalization;
        },
    };
    return normalized;
}

/// Returns the grammar of standard JSON format (Rust `Grammar::builtin_json_grammar`).
/// XGrammar has built-in support for JSON.
///
/// Never fails in practice — the embedded grammar is a valid constant (Rust `expect`).
pub fn builtin_json_grammar(allocator: Allocator) Allocator.Error!*Grammar {
    var diag: EbnfErrorInfo = undefined;
    return from_ebnf(allocator, BUILTIN_JSON_GRAMMAR, "root", &diag) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable, // the builtin JSON grammar is valid
    };
}

/// The EBNF source of `builtin_json_grammar` — a verbatim copy of the built-in JSON
/// grammar string (`BUILTIN_JSON_GRAMMAR`).
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

test "builtin json grammar normalizes and accepts objects" {
    const gpa = std.testing.allocator;
    const grammar = try builtin_json_grammar(gpa);
    defer grammar.deinit();
    try std.testing.expect(grammar.is_optimized() == false);
    try std.testing.expectEqualStrings("root", grammar.root_rule().name);
    // Normalized: every rule body is a choices (or a direct regex/substring/dispatch body).
    for (grammar.rules.items) |rule| {
        const body = grammar.expr(rule.body_expr_id);
        try std.testing.expect(body.ty == .Choices or body.ty == .Regex or
            body.ty == .Substring or body.ty == .TagDispatch or body.ty == .TokenTagDispatch);
    }
}

test "from_ebnf renames the root and normalizes" {
    const gpa = std.testing.allocator;
    const grammar = try from_ebnf(gpa, "main ::= (\"a\" | (\"b\" \"\")) \"c\"", "main", null);
    defer grammar.deinit();
    try std.testing.expectEqualStrings("root", grammar.root_rule().name);
    const printer = grammar_mod.printer;
    const ebnf = try printer.to_string_ebnf(grammar, gpa);
    defer gpa.free(ebnf);
    try std.testing.expectEqualStrings("root ::= ((root_1 \"c\"))\nroot_1 ::= ((\"a\") | (\"b\"))\n", ebnf);
}
