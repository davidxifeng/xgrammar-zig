//! Named grammars shared by a Lark conversion and the named Lark sources it compiles
//! (`named_grammar_registry.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const named_grammar = @import("named_grammar.zig");
const grammar_mod = @import("../grammar/mod.zig");
const NamedGrammar = named_grammar.NamedGrammar;
const Grammar = grammar_mod.Grammar;

/// The named grammar inputs, the Lark sources compiled so far, and the chain of Lark sources
/// being compiled (for cycle detection). `inputs` borrows its keys/values from the caller's
/// `NamedGrammar` list; `compiled` owns its keys and the compiled grammars (Rust `HashMap`
/// values → heap grammars with their own arenas).
pub const NamedGrammarRegistry = struct {
    gpa: Allocator,
    /// The named grammars by name.
    inputs: std.StringHashMap(*const NamedGrammar),
    /// Compiled named Lark sources by name.
    compiled: std.StringHashMap(*Grammar),
    /// The named Lark sources currently being compiled, outermost first.
    active: std.ArrayList([]u8),

    pub fn new(gpa: Allocator) Allocator.Error!NamedGrammarRegistry {
        return .{
            .gpa = gpa,
            .inputs = std.StringHashMap(*const NamedGrammar).init(gpa),
            .compiled = std.StringHashMap(*Grammar).init(gpa),
            .active = .empty,
        };
    }

    pub fn deinit(self: *NamedGrammarRegistry) void {
        self.inputs.deinit();
        var it = self.compiled.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.gpa.free(entry.key_ptr.*);
        }
        self.compiled.deinit();
        for (self.active.items) |item| self.gpa.free(item);
        self.active.deinit(self.gpa);
    }

    /// The grammar named `name`: the input grammar, or the compiled Lark source.
    pub fn get(self: *const NamedGrammarRegistry, name: []const u8) ?*const Grammar {
        const input = self.inputs.get(name) orelse return null;
        return switch (input.*) {
            .grammar => |g| g.grammar,
            .lark => self.compiled.get(name),
        };
    }
};
