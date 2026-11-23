//! Normalizes grammar structure (`structure_normalizer.rs`).
//!
//! After the `SingleElementExprEliminator` pre-pass, every rule body is rewritten into the
//! normal form `rule ::= ("" | (e1 e2 …) | …)`: a choices of sequences of leaf elements,
//! where only the first choice may be the empty string. Nested choices in a sequence are
//! hoisted into fresh rules.

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_mod = @import("grammar/mod.zig");
const Grammar = grammar_mod.Grammar;
const GrammarBuilder = grammar_mod.GrammarBuilder;
const GrammarExprType = grammar_mod.GrammarExprType;
const NO_EXPR = grammar_mod.NO_EXPR;
const tag_dispatch_mod = grammar_mod.tag_dispatch;
const token_tag_dispatch_mod = grammar_mod.token_tag_dispatch;
const single_element = @import("single_element_expr_eliminator.zig");
const error_mod = @import("error.zig");
const FunctorError = error_mod.FunctorError;

/// Normalizes the structure of `grammar` (the `GrammarFunctor.structure_normalizer` pass).
pub fn structure_normalizer(allocator: Allocator, grammar: *const Grammar) FunctorError!*Grammar {
    var normalizer = StructureNormalizer{
        .allocator = allocator,
        .builder = undefined,
        .cur_rule_name = "",
    };
    errdefer normalizer.deinit_temps();
    normalizer.base = try single_element.apply(allocator, grammar);
    normalizer.builder = try GrammarBuilder.new(allocator);
    const result = try normalizer.run();
    normalizer.deinit_temps();
    return result;
}

const ExprView = struct { ty: GrammarExprType, data: []const i32 };

const StructureNormalizer = struct {
    allocator: Allocator,
    /// The pre-passed grammar (owned; freed by `deinit_temps`).
    base: ?*Grammar = null,
    builder: GrammarBuilder = undefined,
    cur_rule_name: []const u8 = "",

    fn deinit_temps(self: *StructureNormalizer) void {
        if (self.base) |b| b.deinit();
        self.builder.deinit();
    }

    fn run(self: *StructureNormalizer) FunctorError!*Grammar {
        const base = self.base.?;
        const gpa = self.allocator;
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(gpa);
        try names.ensureTotalCapacity(gpa, base.rules.items.len);
        for (base.rules.items) |r| names.appendAssumeCapacity(r.name);
        for (names.items) |name| _ = try self.builder.add_empty_rule(name);
        for (0..@intCast(base.num_rules())) |i| {
            const rule = base.rule(@intCast(i));
            self.cur_rule_name = rule.name;
            const new_body = try self.visit_rule_body(rule.body_expr_id);
            self.builder.update_rule_body(@intCast(i), new_body);
            const new_lookahead = try self.visit_lookahead(rule.lookahead_assertion_id);
            self.builder.update_lookahead_assertion(@intCast(i), new_lookahead);
            try self.builder.copy_rule_attributes(@intCast(i), base, @intCast(i), identity_rule_id);
        }
        const root = base.root_rule().name;
        const result = self.builder.into_grammar(gpa, root, null) catch |err| switch (err) {
            error.RootRuleNotFound => unreachable, // root rule preserved during normalization
            else => |e| return e,
        };
        return result;
    }

    fn identity_rule_id(id: i32) i32 {
        return id;
    }

    fn base_expr(self: *StructureNormalizer, expr_id: i32) ExprView {
        return .{ .ty = self.base.?.expr(expr_id).ty, .data = self.base.?.expr(expr_id).data };
    }

    fn built_expr(self: *StructureNormalizer, expr_id: i32) ExprView {
        const expr = self.builder.grammar_expr(expr_id);
        return .{ .ty = expr.ty, .data = expr.data };
    }

    /// Re-encodes a tag-dispatch (or token-tag-dispatch) payload into the result builder.
    fn rebuild_tag_dispatch(self: *StructureNormalizer, ty: GrammarExprType, data: []const i32) FunctorError!i32 {
        const gpa = self.builder.allocator;
        switch (ty) {
            .TagDispatch => {
                const tag_dispatch = try tag_dispatch_mod.decode_tag_dispatch_data(self.base.?, gpa, data);
                defer tag_dispatch.deinit(gpa);
                return self.builder.add_tag_dispatch(&tag_dispatch);
            },
            .TokenTagDispatch => {
                const ttd = try token_tag_dispatch_mod.decode_token_tag_dispatch_data(gpa, data);
                defer ttd.deinit(gpa);
                return self.builder.add_token_tag_dispatch(&ttd);
            },
            else => unreachable, // rebuild_tag_dispatch called with non-tag-dispatch type
        }
    }

    fn visit_lookahead(self: *StructureNormalizer, lookahead_id: i32) FunctorError!i32 {
        if (lookahead_id == NO_EXPR) return NO_EXPR;
        const decoded = self.base_expr(lookahead_id);
        const ty = decoded.ty;
        const data = decoded.data;
        switch (ty) {
            .Sequence => {
                const ids = try self.visit_sequence_(data);
                defer self.builder.allocator.free(ids);
                return self.builder.add_sequence(ids);
            },
            .Choices => std.debug.panic("Choices in lookahead assertion are not supported yet", .{}),
            .EmptyStr => std.debug.panic("Empty string should not be in lookahead assertion", .{}),
            .TagDispatch => std.debug.panic("TagDispatch should not be in lookahead assertion", .{}),
            .Regex => std.debug.panic("Regex should not be in lookahead assertion", .{}),
            .Substring => std.debug.panic("Substring should not be in lookahead assertion", .{}),
            else => {
                const element = try self.builder.add_grammar_expr(ty, data);
                return self.builder.add_sequence(&.{element});
            },
        }
    }

    fn visit_rule_body(self: *StructureNormalizer, expr_id: i32) FunctorError!i32 {
        const decoded = self.base_expr(expr_id);
        const ty = decoded.ty;
        const data = decoded.data;
        switch (ty) {
            .Sequence => {
                const ids = try self.visit_sequence_(data);
                defer self.builder.allocator.free(ids);
                const seq = try self.builder.add_sequence(ids);
                return self.builder.add_choices(&.{seq});
            },
            .Choices => {
                const ids = try self.visit_choices_(data);
                defer self.builder.allocator.free(ids);
                return self.builder.add_choices(ids);
            },
            .EmptyStr => {
                const empty = try self.builder.add_empty_str();
                return self.builder.add_choices(&.{empty});
            },
            .ByteString, .CharacterClass, .CharacterClassStar, .RuleRef, .Repeat, .Token, .ExcludeToken => {
                const element = try self.builder.add_grammar_expr(ty, data);
                const seq = try self.builder.add_sequence(&.{element});
                return self.builder.add_choices(&.{seq});
            },
            // A tag dispatch is kept as the rule body directly (printed without the
            // `(( … ))` choices/sequence wrapping).
            .TagDispatch => return self.rebuild_tag_dispatch(ty, data),
            // A regex or substring is kept as the direct body of the rule, like a tag dispatch.
            .Regex, .Substring => return self.builder.add_grammar_expr(ty, data),
            // A token-tag dispatch is hoisted into its own rule, matching the C++
            // `StructureNormalizer::VisitRuleBody` asymmetry.
            .TokenTagDispatch => {
                const ttd = try self.rebuild_tag_dispatch(ty, data);
                const rule_id = try self.builder.add_rule_with_hint(self.cur_rule_name, ttd);
                const rule_ref = try self.builder.add_rule_ref(rule_id);
                const seq = try self.builder.add_sequence(&.{rule_ref});
                return self.builder.add_choices(&.{seq});
            },
        }
    }

    /// Returns the new choice ids for a choices expression (flattening nested choices and
    /// folding empty strings to a single leading empty choice). Allocated from the builder
    /// allocator; the caller frees it.
    fn visit_choices_(self: *StructureNormalizer, data: []const i32) FunctorError![]i32 {
        const gpa = self.builder.allocator;
        var new_choice_ids: std.ArrayList(i32) = .empty;
        errdefer new_choice_ids.deinit(gpa);
        var found_empty = false;
        for (data) |choice| {
            const decoded = self.base_expr(choice);
            const ty = decoded.ty;
            const cdata = decoded.data;
            switch (ty) {
                .Sequence => {
                    const sub = try self.visit_sequence_(cdata);
                    defer gpa.free(sub);
                    if (sub.len == 0) {
                        found_empty = true;
                    } else {
                        const seq = try self.builder.add_sequence(sub);
                        try new_choice_ids.append(gpa, seq);
                    }
                },
                .Choices => {
                    const sub = try self.visit_choices_(cdata);
                    defer gpa.free(sub);
                    const first_is_empty = self.built_expr(sub[0]).ty == .EmptyStr;
                    if (first_is_empty) {
                        found_empty = true;
                        try new_choice_ids.appendSlice(gpa, sub[1..]);
                    } else {
                        try new_choice_ids.appendSlice(gpa, sub);
                    }
                },
                .EmptyStr => found_empty = true,
                .TagDispatch, .TokenTagDispatch => {
                    const element = try self.rebuild_tag_dispatch(ty, cdata);
                    const rule_id = try self.builder.add_rule_with_hint(self.cur_rule_name, element);
                    const rule_ref = try self.builder.add_rule_ref(rule_id);
                    const seq = try self.builder.add_sequence(&.{rule_ref});
                    try new_choice_ids.append(gpa, seq);
                },
                .Regex, .Substring => {
                    const element = try self.builder.add_grammar_expr(ty, cdata);
                    const rule_id = try self.builder.add_rule_with_hint(self.cur_rule_name, element);
                    const rule_ref = try self.builder.add_rule_ref(rule_id);
                    const seq = try self.builder.add_sequence(&.{rule_ref});
                    try new_choice_ids.append(gpa, seq);
                },
                else => {
                    const element = try self.builder.add_grammar_expr(ty, cdata);
                    const seq = try self.builder.add_sequence(&.{element});
                    try new_choice_ids.append(gpa, seq);
                },
            }
        }
        if (found_empty) {
            const empty = try self.builder.add_empty_str();
            try new_choice_ids.insert(gpa, 0, empty);
        }
        std.debug.assert(new_choice_ids.items.len != 0); // choices must be non-empty
        return new_choice_ids.toOwnedSlice(gpa);
    }

    /// Returns the new element ids for a sequence expression (flattening nested sequences,
    /// dropping empty strings, and hoisting nested choices into fresh rules). Allocated
    /// from the builder allocator; the caller frees it.
    fn visit_sequence_(self: *StructureNormalizer, data: []const i32) FunctorError![]i32 {
        const gpa = self.builder.allocator;
        var new_sequence_ids: std.ArrayList(i32) = .empty;
        errdefer new_sequence_ids.deinit(gpa);
        for (data) |element| {
            const decoded = self.base_expr(element);
            const ty = decoded.ty;
            const edata = decoded.data;
            switch (ty) {
                .Sequence => {
                    const sub = try self.visit_sequence_(edata);
                    defer gpa.free(sub);
                    try new_sequence_ids.appendSlice(gpa, sub);
                },
                .Choices => {
                    const sub = try self.visit_choices_(edata);
                    defer gpa.free(sub);
                    if (sub.len == 1) {
                        const decoded_sub = self.built_expr(sub[0]);
                        if (decoded_sub.ty != .EmptyStr) {
                            try new_sequence_ids.appendSlice(gpa, decoded_sub.data);
                        }
                    } else {
                        const choices = try self.builder.add_choices(sub);
                        const rule_id = try self.builder.add_rule_with_hint(self.cur_rule_name, choices);
                        try new_sequence_ids.append(gpa, try self.builder.add_rule_ref(rule_id));
                    }
                },
                .EmptyStr => {},
                .TagDispatch, .TokenTagDispatch => {
                    const element_id = try self.rebuild_tag_dispatch(ty, edata);
                    const rule_id = try self.builder.add_rule_with_hint(self.cur_rule_name, element_id);
                    try new_sequence_ids.append(gpa, try self.builder.add_rule_ref(rule_id));
                },
                .Regex, .Substring => {
                    const element_id = try self.builder.add_grammar_expr(ty, edata);
                    const rule_id = try self.builder.add_rule_with_hint(self.cur_rule_name, element_id);
                    try new_sequence_ids.append(gpa, try self.builder.add_rule_ref(rule_id));
                },
                else => try new_sequence_ids.append(gpa, try self.builder.add_grammar_expr(ty, edata)),
            }
        }
        return new_sequence_ids.toOwnedSlice(gpa);
    }
};

test "structure normalizer flattens nested choices and sequences" {
    const gpa = std.testing.allocator;
    const mod = @import("grammar/mod.zig");
    const GrammarBuilder = mod.GrammarBuilder;
    var builder = try GrammarBuilder.new(gpa);
    defer builder.deinit();
    // root ::= ((("a" | ("b" "")) "c")) | ""
    const a = try builder.add_byte_string("a");
    const b = try builder.add_byte_string("b");
    const inner_choices = try builder.add_choices(&.{ a, try builder.add_sequence(&.{b, try builder.add_empty_str()}) });
    const seq = try builder.add_sequence(&.{ inner_choices, try builder.add_byte_string("c") });
    const body = try builder.add_choices(&.{ seq, try builder.add_empty_str() });
    _ = try builder.add_rule_named("root", body);
    const grammar = try builder.into_grammar(gpa, "root", null);
    defer grammar.deinit();

    const normalized = try structure_normalizer(gpa, grammar);
    defer normalized.deinit();
    const printer = mod.printer;
    const ebnf = try printer.to_string_ebnf(normalized, gpa);
    defer gpa.free(ebnf);
    try std.testing.expectEqualStrings("root ::= (\"\" | (\"a\" \"c\") | (\"b\" \"c\"))\n", ebnf);
}
