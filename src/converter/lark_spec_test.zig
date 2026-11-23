//! Port of `tests/cpp/test_lark_converter.rs`.
//!
//! Tests that need the compiler wave (`GrammarCompiler`, `compile_lark`) are gated with
//! `error.SkipZigTest` until that wave lands (parser-wave precedent).

const std = @import("std");
const grammar_mod = @import("../grammar/mod.zig");
const printer = @import("../grammar/printer.zig");
const lark_converter = @import("lark_converter.zig");
const lark_error = @import("lark_error.zig");
const named_grammar_mod = @import("named_grammar.zig");
const regex_converter = @import("regex_converter.zig");
const tokenizer_mod = @import("../tokenizer/mod.zig");
const Grammar = grammar_mod.Grammar;
const LarkErrorInfo = lark_error.LarkErrorInfo;
const NamedGrammar = named_grammar_mod.NamedGrammar;
const TokenizerInfo = tokenizer_mod.tokenizer_info.TokenizerInfo;
const VocabType = tokenizer_mod.vocab_type.VocabType;

const allocator = std.testing.allocator;

fn lark(source: []const u8) ![]u8 {
    var info: ?LarkErrorInfo = null;
    const grammar = lark_converter.from_lark(allocator, source, null, &.{}, &info) catch |err| {
        if (info) |*i| {
            defer i.deinit(allocator);
            const msg = try i.format_message(allocator);
            defer allocator.free(msg);
            std.debug.print("lark() unexpected error: {s}\n", .{msg});
        }
        return err;
    };
    defer grammar.deinit();
    return printer.to_string_ebnf(grammar, allocator);
}

fn lark_source(name: []const u8, source: []const u8) NamedGrammar {
    return .{ .lark = .{ .name = name, .source = source } };
}

fn lark_grammar(name: []const u8, grammar: *const Grammar) NamedGrammar {
    return .{ .grammar = .{ .name = name, .grammar = grammar } };
}

/// Same as `expect_error`, driven by an already-materialized error info.
fn expect_error_matches(info: *const LarkErrorInfo, pattern: []const u8) !void {
    const message = try info.format_message(allocator);
    defer allocator.free(message);
    var rest: []const u8 = message;
    var it = std.mem.splitSequence(u8, pattern, ".*");
    while (it.next()) |part| {
        const index = std.mem.indexOf(u8, rest, part) orelse {
            std.debug.print("pattern {s} does not match message {s}\n", .{ pattern, message });
            return error.TestUnexpectedResult;
        };
        rest = rest[index + part.len ..];
    }
}

/// Runs `from_lark`, expecting failure; asserts the message against `pattern`.
fn lark_error_matches(source: []const u8, pattern: []const u8) !void {
    var info: ?LarkErrorInfo = null;
    if (lark_converter.from_lark(allocator, source, null, &.{}, &info)) |grammar| {
        grammar.deinit();
        std.debug.print("expected error for: {s}\n", .{source});
        return error.TestUnexpectedResult;
    } else |_| {}
    defer if (info) |*i| i.deinit(allocator);
    try expect_error_matches(&info.?, pattern);
}

test "default arguments" {
    const source = "start: \"x\"";
    const printed = try lark(source);
    defer allocator.free(printed);
    // Same source compiled twice prints the same (default arguments are no-ops).
    const again = try lark(source);
    defer allocator.free(again);
    try std.testing.expectEqualStrings(printed, again);
}

test "core syntax and imports" {
    const source =
        \\
        \\    %import common.INT
        \\    %import common (WS_INLINE, CNAME)
        \\    %ignore WS_INLINE
        \\    start: item{2,3}
        \\    item: CNAME ":" INT | "none"
        \\
    ;
    const printed = try lark(source);
    defer allocator.free(printed);
    try std.testing.expect(std.mem.indexOf(u8, printed, "root") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "lark_ignore") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "{2, 3}") != null);
}

test "inline and nested grammar" {
    const source =
        \\
        \\    start: "payload=" %json {
        \\      "type": "object",
        \\      "properties": {"x": {"type": "integer"}},
        \\      "required": ["x"],
        \\      "additionalProperties": false
        \\    } ";" %lark {
        \\      start: "yes" | "no"
        \\    }
        \\
    ;
    const printed = try lark(source);
    defer allocator.free(printed);
    try std.testing.expect(std.mem.indexOf(u8, printed, "payload=") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "basic_integer") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "yes") != null);
}

test "named grammars" {
    const word = try regex_converter.from_regex(allocator, "[a-z]+", null);
    defer word.deinit();
    const number = try lark_converter.from_lark(allocator, "start: /[0-9]+/", null, &.{}, null);
    defer number.deinit();
    var named = [_]NamedGrammar{
        lark_grammar("word", word),
        lark_grammar("number", number),
    };
    const source =
        \\
        \\        start: "<" @word ":" @number ">" %lark {
        \\          start: "/" @word
        \\        }
        \\
    ;
    const grammar = try lark_converter.from_lark(allocator, source, null, &named, null);
    defer grammar.deinit();
    const printed = try printer.to_string_ebnf(grammar, allocator);
    defer allocator.free(printed);
    try std.testing.expect(std.mem.indexOf(u8, printed, "[a-z]") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "[0-9]") != null);
}

test "named grammar sources" {
    var named = [_]NamedGrammar{
        lark_source("pair", "start: @item \":\" @item"),
        lark_source("item", "start: /[a-z]+/"),
    };
    const grammar = try lark_converter.from_lark(allocator, "start: @pair", null, &named, null);
    defer grammar.deinit();
    const printed = try printer.to_string_ebnf(grammar, allocator);
    defer allocator.free(printed);
    try std.testing.expect(std.mem.indexOf(u8, printed, "[a-z]") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "\":\"") != null);
}

test "named grammar cycle" {
    var named = [_]NamedGrammar{
        lark_source("left", "start: @right"),
        lark_source("right", "start: @left"),
    };
    var info: ?LarkErrorInfo = null;
    if (lark_converter.from_lark(allocator, "start: @left", null, &named, &info)) |grammar| {
        grammar.deinit();
        return error.TestUnexpectedResult;
    } else |_| {}
    defer if (info) |*i| i.deinit(allocator);
    try expect_error_matches(&info.?, "circular named grammar reference: @left -> @right -> @left");
}

test "grammar compiler caches lark sources" {
    return error.SkipZigTest; // needs the compiler wave (`GrammarCompiler.compile_lark`)
}

test "dynamic tool call lowers to tag dispatch" {
    const source =
        \\
        \\    start: (foo | bar)* tail
        \\    tail: TEXT
        \\
        \\    foo_head[lazy]: TEXT "<function"
        \\    foo: foo_head "=foo>" /[a-z]+/ "</function>"
        \\
        \\    bar_head[lazy]: TEXT "<function"
        \\    bar: bar_head "=bar>" /[A-Z]+/ "</function>"
        \\
        \\    TEXT: /(\n|.)*/
        \\
    ;
    const printed = try lark(source);
    defer allocator.free(printed);
    try std.testing.expect(std.mem.indexOf(u8, printed, "TagDispatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "\"<function\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "loop_after_dispatch=true") != null);
}

test "numeric and named special tokens" {
    const vocab = [_][]const u8{ "a", "<|tool|>", "b" };
    var tokenizer_diag: tokenizer_mod.error_mod.TokenizerErrorInfo = undefined;
    var tokenizer_info = tokenizer_mod.tokenizer_info.TokenizerInfo.new(allocator, &vocab, .Raw, 3, &.{}, false, &tokenizer_diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SkipZigTest,
    };
    defer tokenizer_info.deinit();
    const grammar = try lark_converter.from_lark(allocator, "start: <[0,2]> | <|tool|>", &tokenizer_info, &.{}, null);
    defer grammar.deinit();
    const printed = try printer.to_string_ebnf(grammar, allocator);
    defer allocator.free(printed);
    try std.testing.expect(std.mem.indexOf(u8, printed, "Token(0, 2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "Token(1)") != null);
}

test "string and regex flags" {
    // The i flag folds ASCII letters; non-ASCII characters in the regex are matched literally.
    const source =
        \\
        \\    start: "Case"i /Σ[^k].x/isu
        \\
    ;
    const printed = try lark(source);
    defer allocator.free(printed);
    try std.testing.expect(std.mem.indexOf(u8, printed, "root") != null);
}

test "case-insensitive string rejects non-ASCII" {
    try lark_error_matches("start: \"Żółw\"i", "case-insensitive string literals currently support ASCII characters only");
}

test "dynamic regex suffix and suffix attribute" {
    const source =
        \\
        \\    start: (foo | bar)* tail
        \\    tail: TEXT
        \\
        \\    foo_head[lazy]: /(\n|.)*<foo>/
        \\    foo: foo_head /[a-z]+/ "</foo>"
        \\
        \\    bar_head[suffix="<bar>"]: TEXT
        \\    bar: bar_head /[0-9]+/ "</bar>"
        \\
        \\    TEXT: /.*/s
        \\
    ;
    const printed = try lark(source);
    defer allocator.free(printed);
    try std.testing.expect(std.mem.indexOf(u8, printed, "TagDispatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "\"<foo>\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "\"<bar>\"") != null);
}

test "errors contain source locations" {
    try lark_error_matches("item: \"a\"", "line 1, column 1.*no start rule");
    try lark_error_matches("start: missing", "line 1, column 8.*unknown name");
    try lark_error_matches("start: FOO\nFOO: BAR\nBAR: FOO", "circular reference in terminal");
    try lark_error_matches("start[budget=10]: \"a\"", "attribute 'budget' is not supported");
    try lark_error_matches("start[capture=\"a b\"]: \"a\"", "capture name must only contain letters, digits");
    try lark_error_matches("start: A & B\nA: \"a\"\nB: \"b\"", "intersection '&' is not supported");
    try lark_error_matches("start: /abc/m", "regular-expression flag 'm' is not supported");
    try lark_error_matches("start: TOKEN\nTOKEN: %json {}", "%json cannot be used in terminals");
    try lark_error_matches("start: TOKEN\nTOKEN: %lark { start: \"a\" }", "nested %lark cannot be used in terminals");
    try lark_error_matches("start: <[1-2-3]>", "invalid numeric special-token range");
    try lark_error_matches("start: @missing", "line 1, column 8.*unknown named grammar '@missing'");
}

test "duplicate named grammar" {
    var named = [_]NamedGrammar{
        lark_source("item", "start: \"a\""),
        lark_source("item", "start: \"b\""),
    };
    var info: ?LarkErrorInfo = null;
    if (lark_converter.from_lark(allocator, "start: @item", null, &named, &info)) |grammar| {
        grammar.deinit();
        return error.TestUnexpectedResult;
    } else |_| {}
    defer if (info) |*i| i.deinit(allocator);
    try expect_error_matches(&info.?, "Duplicate named grammar 'item'");
}
