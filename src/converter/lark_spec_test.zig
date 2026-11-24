//! Port of `tests/cpp/test_lark_converter.rs`.

const std = @import("std");

const Diagnostic = @import("../Diagnostic.zig").Diagnostic;
const grammar_mod = @import("../grammar.zig");
const tokenizer_mod = @import("../tokenizer.zig");
const lark_ast = @import("lark/ast.zig");
const lark_compiler = @import("lark/compiler.zig");
const regex_mod = @import("regex.zig");

const Grammar = grammar_mod.Grammar;
const NamedGrammar = lark_ast.NamedGrammar;
const TokenizerInfo = tokenizer_mod.TokenizerInfo;

const allocator = std.testing.allocator;

fn lark(source: []const u8) ![]u8 {
    var diag: Diagnostic = .{};
    defer diag.deinit(allocator);
    var grammar = lark_compiler.fromLark(allocator, source, null, &.{}, &diag) catch |err| {
        if (diag.kind != .none) {
            const msg = try diag.formatAlloc(allocator);
            defer allocator.free(msg);
            std.debug.print("lark() unexpected error: {s}\n", .{msg});
        }
        return err;
    };
    defer grammar.deinit();
    return grammar.toStringEbnf(allocator);
}

fn larkSource(name: []const u8, source: []const u8) NamedGrammar {
    return .{ .lark = .{ .name = name, .source = source } };
}

fn larkGrammar(name: []const u8, grammar: *const Grammar) NamedGrammar {
    return .{ .grammar = .{ .name = name, .grammar = grammar } };
}

/// Same as `larkErrorMatches`, driven by an already-populated `Diagnostic`.
fn expectErrorMatches(diag: *const Diagnostic, pattern: []const u8) !void {
    const message = try diag.formatAlloc(allocator);
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

/// Runs `fromLark`, expecting failure; asserts the formatted `Diagnostic` against `pattern`.
fn larkErrorMatches(source: []const u8, pattern: []const u8) !void {
    var diag: Diagnostic = .{};
    defer diag.deinit(allocator);
    if (lark_compiler.fromLark(allocator, source, null, &.{}, &diag)) |g| {
        var grammar = g;
        grammar.deinit();
        std.debug.print("expected error for: {s}\n", .{source});
        return error.TestUnexpectedResult;
    } else |_| {}
    try expectErrorMatches(&diag, pattern);
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
    var word = try regex_mod.fromRegex(allocator, "[a-z]+", null);
    defer word.deinit();
    var number = try lark_compiler.fromLark(allocator, "start: /[0-9]+/", null, &.{}, null);
    defer number.deinit();
    const named = [_]NamedGrammar{
        larkGrammar("word", &word),
        larkGrammar("number", &number),
    };
    const source =
        \\
        \\        start: "<" @word ":" @number ">" %lark {
        \\          start: "/" @word
        \\        }
        \\
    ;
    var grammar = try lark_compiler.fromLark(allocator, source, null, &named, null);
    defer grammar.deinit();
    const printed = try grammar.toStringEbnf(allocator);
    defer allocator.free(printed);
    try std.testing.expect(std.mem.indexOf(u8, printed, "[a-z]") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "[0-9]") != null);
}

test "named grammar sources" {
    const named = [_]NamedGrammar{
        larkSource("pair", "start: @item \":\" @item"),
        larkSource("item", "start: /[a-z]+/"),
    };
    var grammar = try lark_compiler.fromLark(allocator, "start: @pair", null, &named, null);
    defer grammar.deinit();
    const printed = try grammar.toStringEbnf(allocator);
    defer allocator.free(printed);
    try std.testing.expect(std.mem.indexOf(u8, printed, "[a-z]") != null);
    try std.testing.expect(std.mem.indexOf(u8, printed, "\":\"") != null);
}

test "named grammar cycle" {
    const named = [_]NamedGrammar{
        larkSource("left", "start: @right"),
        larkSource("right", "start: @left"),
    };
    var diag: Diagnostic = .{};
    defer diag.deinit(allocator);
    if (lark_compiler.fromLark(allocator, "start: @left", null, &named, &diag)) |g| {
        var grammar = g;
        grammar.deinit();
        return error.TestUnexpectedResult;
    } else |_| {}
    try expectErrorMatches(&diag, "circular named grammar reference: @left -> @right -> @left");
}

test "grammar compiler caches lark sources" {
    const compiler_mod = @import("../compiler.zig");
    const GrammarCompiler = compiler_mod.GrammarCompiler;

    const vocab = [_][]const u8{ "a", "b", "c", "item" };
    var tokenizer_info = try TokenizerInfo.init(allocator, &vocab, .{
        .vocab_type = .raw,
        .vocab_size = 4,
    });
    defer tokenizer_info.deinit();

    var compiler_inst = try GrammarCompiler.init(allocator, &tokenizer_info, .{
        .max_threads = 1,
        .cache_enabled = true,
    });
    defer compiler_inst.deinit();

    var first = try compiler_inst.compileLark("start: \"a\"", .{});
    defer first.deinit();
    var repeated = try compiler_inst.compileLark("start: \"a\"", .{});
    defer repeated.deinit();
    try std.testing.expect(first.sharesStorage(&repeated));

    const named_grammars = [_]NamedGrammar{
        larkSource("left", "start: \"a\""),
        larkSource("right", "start: \"b\""),
    };
    var with_named_grammars = try compiler_inst.compileLark("start: @left @right", .{
        .named_grammars = &named_grammars,
    });
    defer with_named_grammars.deinit();
    const reversed = [_]NamedGrammar{ named_grammars[1], named_grammars[0] };
    var with_reordered_named_grammars = try compiler_inst.compileLark("start: @left @right", .{
        .named_grammars = &reversed,
    });
    defer with_reordered_named_grammars.deinit();
    try std.testing.expect(with_named_grammars.sharesStorage(&with_reordered_named_grammars));

    const diff_named = [_]NamedGrammar{
        larkSource("left", "start: \"a\""),
        larkSource("right", "start: \"c\""),
    };
    var with_different_named_grammar = try compiler_inst.compileLark("start: @left @right", .{
        .named_grammars = &diff_named,
    });
    defer with_different_named_grammar.deinit();
    try std.testing.expect(!with_named_grammars.sharesStorage(&with_different_named_grammar));

    var item1 = try lark_compiler.fromLark(allocator, "start: \"item\"", null, &.{}, null);
    defer item1.deinit();
    var item2 = try lark_compiler.fromLark(allocator, "start: \"item\"", null, &.{}, null);
    defer item2.deinit();
    var with_grammar_object = try compiler_inst.compileLark("start: @item", .{
        .named_grammars = &.{larkGrammar("item", &item1)},
    });
    defer with_grammar_object.deinit();
    var with_equivalent_grammar_object = try compiler_inst.compileLark("start: @item", .{
        .named_grammars = &.{larkGrammar("item", &item2)},
    });
    defer with_equivalent_grammar_object.deinit();
    try std.testing.expect(with_grammar_object.sharesStorage(&with_equivalent_grammar_object));

    var uncached_compiler = try GrammarCompiler.init(allocator, &tokenizer_info, .{
        .max_threads = 1,
        .cache_enabled = false,
    });
    defer uncached_compiler.deinit();
    var uncached_first = try uncached_compiler.compileLark("start: \"a\"", .{});
    defer uncached_first.deinit();
    var uncached_second = try uncached_compiler.compileLark("start: \"a\"", .{});
    defer uncached_second.deinit();
    try std.testing.expect(!uncached_first.sharesStorage(&uncached_second));
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
    var tokenizer_info = try TokenizerInfo.init(allocator, &vocab, .{
        .vocab_type = .raw,
        .vocab_size = 3,
    });
    defer tokenizer_info.deinit();
    var grammar = try lark_compiler.fromLark(allocator, "start: <[0,2]> | <|tool|>", &tokenizer_info, &.{}, null);
    defer grammar.deinit();
    const printed = try grammar.toStringEbnf(allocator);
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
    try larkErrorMatches("start: \"Żółw\"i", "case-insensitive string literals currently support ASCII characters only");
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
    try larkErrorMatches("item: \"a\"", "line 1, column 1.*no start rule");
    try larkErrorMatches("start: missing", "line 1, column 8.*unknown name");
    try larkErrorMatches("start: FOO\nFOO: BAR\nBAR: FOO", "circular reference in terminal");
    try larkErrorMatches("start[budget=10]: \"a\"", "attribute 'budget' is not supported");
    try larkErrorMatches("start[capture=\"a b\"]: \"a\"", "capture name must only contain letters, digits");
    try larkErrorMatches("start: A & B\nA: \"a\"\nB: \"b\"", "intersection '&' is not supported");
    try larkErrorMatches("start: /abc/m", "regular-expression flag 'm' is not supported");
    try larkErrorMatches("start: TOKEN\nTOKEN: %json {}", "%json cannot be used in terminals");
    try larkErrorMatches("start: TOKEN\nTOKEN: %lark { start: \"a\" }", "nested %lark cannot be used in terminals");
    try larkErrorMatches("start: <[1-2-3]>", "invalid numeric special-token range");
    try larkErrorMatches("start: @missing", "line 1, column 8.*unknown named grammar '@missing'");
}

test "duplicate named grammar" {
    const named = [_]NamedGrammar{
        larkSource("item", "start: \"a\""),
        larkSource("item", "start: \"b\""),
    };
    var diag: Diagnostic = .{};
    defer diag.deinit(allocator);
    if (lark_compiler.fromLark(allocator, "start: @item", null, &named, &diag)) |g| {
        var grammar = g;
        grammar.deinit();
        return error.TestUnexpectedResult;
    } else |_| {}
    try expectErrorMatches(&diag, "Duplicate named grammar 'item'");
}
