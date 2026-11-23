//! Converts Lark syntax into the grammar IR (`lark_converter.rs`).
//! Rust `Grammar::from_lark` → free function (grammar-wave convention).

const std = @import("std");
const Allocator = std.mem.Allocator;
const grammar_mod = @import("../grammar/mod.zig");
const lark_compiler = @import("lark_compiler.zig");
const lark_error = @import("lark_error.zig");
const lark_parser = @import("lark_parser.zig");
const named_grammar_mod = @import("named_grammar.zig");
const named_grammar_registry = @import("named_grammar_registry.zig");
const tokenizer_mod = @import("../tokenizer/mod.zig");
const Grammar = grammar_mod.Grammar;
const LarkError = lark_error.LarkError;
const LarkErrorInfo = lark_error.LarkErrorInfo;
const NamedGrammar = named_grammar_mod.NamedGrammar;
const NamedGrammarRegistry = named_grammar_registry.NamedGrammarRegistry;
const TokenizerInfo = tokenizer_mod.tokenizer_info.TokenizerInfo;

/// Constructs a grammar from Lark syntax. The root rule must be named `start`.
///
/// `tokenizer_info` resolves named special tokens (`<|...|>`) and the `<[*]>` wildcard.
/// `named_grammars` are grammar objects or Lark sources that can be referenced with `@name`.
/// `diag` (optional) receives the failure payload (strings allocated from `gpa`).
pub fn from_lark(
    gpa: Allocator,
    lark: []const u8,
    tokenizer_info: ?*const TokenizerInfo,
    named_grammars: []const NamedGrammar,
    diag: ?*?LarkErrorInfo,
) LarkError!*Grammar {
    var registry = NamedGrammarRegistry.new(gpa) catch return error.OutOfMemory;
    defer registry.deinit();
    for (named_grammars) |*named_grammar| {
        const name = named_grammar.name();
        if (name.len == 0) {
            return named_grammar_fail(gpa, diag, "Named grammar names must not be empty");
        }
        for (name) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') {
                return named_grammar_fail_fmt(
                    gpa,
                    diag,
                    "Invalid named grammar name '{s}': names may contain only letters, digits, underscores, and hyphens",
                    .{name},
                );
            }
        }
        const entry = registry.inputs.getOrPut(name) catch return error.OutOfMemory;
        if (entry.found_existing) {
            return named_grammar_fail_fmt(gpa, diag, "Duplicate named grammar '{s}'", .{name});
        }
        entry.value_ptr.* = named_grammar;
    }
    var document_or_err = lark_parser.parse(gpa, lark, diag);
    if (document_or_err) |*document| {
        return lark_compiler.LarkCompiler.compile(gpa, lark, document, tokenizer_info, &registry, diag);
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return err,
    }
}

fn named_grammar_fail(gpa: Allocator, diag: ?*?LarkErrorInfo, message: []const u8) LarkError {
    if (diag) |d| {
        d.* = .{ .named_grammar = gpa.dupe(u8, message) catch return error.OutOfMemory };
    }
    return error.Lark;
}

fn named_grammar_fail_fmt(gpa: Allocator, diag: ?*?LarkErrorInfo, comptime fmt: []const u8, args: anytype) LarkError {
    const msg = std.fmt.allocPrint(gpa, fmt, args) catch return error.OutOfMemory;
    defer gpa.free(msg);
    return named_grammar_fail(gpa, diag, msg);
}
