//! Errors from `GrammarCompiler` (`error.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const converter = @import("../converter/mod.zig");
const functor = @import("../functor/mod.zig");
const parser = @import("../parser/mod.zig");
const support = @import("../support/mod.zig");

/// An error from converting or compiling a grammar (Rust `CompileError`).
pub const CompileError = Allocator.Error ||
    support.Compact2dArrayError ||
    parser.EbnfError ||
    converter.SchemaError ||
    converter.RegexError ||
    converter.StructuralTagError ||
    converter.LarkError ||
    functor.FunctorError ||
    error{TokenIdOutOfRange};

/// Diagnostic payload for [`CompileError`]. Callers passing `diag` own any allocated strings
/// and must release them with `deinit`.
pub const CompileErrorInfo = union(enum) {
    Ebnf: parser.EbnfErrorInfo,
    Schema: converter.SchemaErrorInfo,
    Regex: converter.RegexErrorInfo,
    StructuralTag: converter.StructuralTagErrorInfo,
    Functor: functor.FunctorErrorInfo,
    Lark: converter.LarkErrorInfo,
    TokenIdOutOfRange: struct {
        token_id: i32,
        vocab_size: i32,
    },

    pub fn deinit(self: *CompileErrorInfo, allocator: Allocator) void {
        switch (self.*) {
            .Ebnf => |e| switch (e) {
                .lexer => |l| if (l.message.len > 0) allocator.free(l.message),
                .parser => |p| if (p.message.len > 0) allocator.free(p.message),
                .normalization => |m| allocator.free(m),
            },
            .Schema => |s| allocator.free(s.message),
            .Regex => |r| allocator.free(r.message),
            .StructuralTag => |*st| st.deinit(allocator),
            .Functor => |*f| f.deinit(allocator),
            .Lark => |*l| l.deinit(allocator),
            .TokenIdOutOfRange => {},
        }
    }

    /// Reproduces Rust `CompileError`'s `Display` output (caller owns the allocation).
    pub fn format_message(self: *const CompileErrorInfo, allocator: Allocator) Allocator.Error![]u8 {
        return switch (self.*) {
            .Ebnf => |e| switch (e) {
                .lexer => |l| l.format_message(allocator),
                .parser => |p| p.format_message(allocator),
                .normalization => |m| allocator.dupe(u8, m),
            },
            .Schema => |s| allocator.dupe(u8, s.message),
            .Regex => |r| converter.regex_error.format_message(&r, allocator),
            .StructuralTag => |*st| st.format_message(allocator),
            .Functor => |f| functor.error_mod.format_message(allocator, f),
            .Lark => |*l| l.format_message(allocator),
            .TokenIdOutOfRange => |t| std.fmt.allocPrint(
                allocator,
                "Token id {d} in the grammar is out of the vocabulary range [0, {d})",
                .{ t.token_id, t.vocab_size },
            ),
        };
    }
};

test "compile error token id out of range format" {
    const a = std.testing.allocator;
    var info: CompileErrorInfo = .{ .TokenIdOutOfRange = .{ .token_id = 42, .vocab_size = 10 } };
    defer info.deinit(a);
    const msg = try info.format_message(a);
    defer a.free(msg);
    try std.testing.expectEqualStrings(
        "Token id 42 in the grammar is out of the vocabulary range [0, 10)",
        msg,
    );
}
