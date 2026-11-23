//! Decoded form of a `GrammarExprType.TagDispatch` expression (`tag_dispatch.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_mod = @import("grammar.zig");
const Grammar = grammar_mod.Grammar;
const grammar_expr_mod = @import("grammar_expr.zig");
const support = @import("../support/mod.zig");
const GrammarExpr = grammar_expr_mod.GrammarExpr;
const grammar_expr_type = @import("grammar_expr_type.zig");
const GrammarExprType = grammar_expr_type.GrammarExprType;

/// The number of trailing payload elements after the tag/rule pairs:
/// `loop_after_dispatch` and the excluded-strings expression id.
pub const EXTRA_PARAMETERS: usize = 2;

/// `(tag, rule_id)` pair (Rust tuple `(Vec<u8>, i32)`).
pub const TagRulePair = struct {
    tag: []u8,
    rule_id: i32,
};

/// A decoded tag-dispatch expression: a list of `(tag bytes, rule id)` pairs, a looping
/// flag, and a set of excluded byte strings.
pub const TagDispatch = struct {
    /// `(tag, rule_id)` pairs; each tag triggers a dispatch into its rule.
    tag_rule_pairs: std.ArrayList(TagRulePair),
    /// Whether dispatching loops after a tag is handled.
    loop_after_dispatch: bool,
    /// Byte strings excluded from free-text matching.
    excludes: std.ArrayList([]u8),

    pub fn empty() TagDispatch {
        return .{ .tag_rule_pairs = .empty, .loop_after_dispatch = false, .excludes = .empty };
    }

    pub fn deinit(self: *TagDispatch, allocator: Allocator) void {
        for (self.tag_rule_pairs.items) |pair| allocator.free(pair.tag);
        self.tag_rule_pairs.deinit(allocator);
        for (self.excludes.items) |exclude| allocator.free(exclude);
        self.excludes.deinit(allocator);
    }

    /// Rust `PartialEq` (byte content equality).
    pub fn eql(a: TagDispatch, b: TagDispatch) bool {
        if (a.loop_after_dispatch != b.loop_after_dispatch) return false;
        if (a.tag_rule_pairs.items.len != b.tag_rule_pairs.items.len) return false;
        for (a.tag_rule_pairs.items, b.tag_rule_pairs.items) |x, y| {
            if (!std.mem.eql(u8, x.tag, y.tag) or x.rule_id != y.rule_id) return false;
        }
        if (a.excludes.items.len != b.excludes.items.len) return false;
        for (a.excludes.items, b.excludes.items) |x, y| {
            if (!std.mem.eql(u8, x, y)) return false;
        }
        return true;
    }

    /// Decodes a tag-dispatch payload (the expr data without its type tag), resolving the
    /// byte-string and excludes expression ids through `context.expr(expr_id)`
    /// (Rust passes `impl Fn(i32) -> GrammarExpr`; `Grammar.expr` fits directly).
    pub fn decode(
        allocator: Allocator,
        data: []const i32,
        context: anytype,
    ) Allocator.Error!TagDispatch {
        std.debug.assert(data.len >= EXTRA_PARAMETERS);
        const body_len = data.len - EXTRA_PARAMETERS;
        var tag_rule_pairs: std.ArrayList(TagRulePair) = .empty;
        var finished = false;
        errdefer if (!finished) {
            for (tag_rule_pairs.items) |pair| allocator.free(pair.tag);
            tag_rule_pairs.deinit(allocator);
        };
        // Rust `chunks_exact(2)`: a trailing odd element would be ignored there too.
        for (0..body_len / 2) |pair_index| {
            const pair = data[pair_index * 2 ..][0..2];
            const tag = try context.expr(pair[0]).byte_string(allocator);
            try tag_rule_pairs.append(allocator, .{ .tag = tag, .rule_id = pair[1] });
        }
        const loop_after_dispatch = data[data.len - 2] != 0;
        const exclude_expr: GrammarExpr = context.expr(data[data.len - 1]);
        std.debug.assert(exclude_expr.ty == .Choices); // tag-dispatch excludes must be a choices expr
        var excludes: std.ArrayList([]u8) = .empty;
        errdefer if (!finished) {
            for (excludes.items) |exclude| allocator.free(exclude);
            excludes.deinit(allocator);
        };
        for (exclude_expr.data) |child| {
            const bytes = try context.expr(child).byte_string(allocator);
            try excludes.append(allocator, bytes);
        }
        finished = true;
        return .{ .tag_rule_pairs = tag_rule_pairs, .loop_after_dispatch = loop_after_dispatch, .excludes = excludes };
    }
};

/// Decodes the tag-dispatch expression with the given id (Rust `Grammar::tag_dispatch`).
pub fn tag_dispatch(
    grammar: *const Grammar,
    allocator: Allocator,
    expr_id: i32,
) Allocator.Error!TagDispatch {
    const expr = grammar.expr(expr_id);
    std.debug.assert(expr.ty == .TagDispatch); // not a tag dispatch
    return decode_tag_dispatch_data(grammar, allocator, expr.data);
}

/// Decodes a tag-dispatch payload (the expr data without its type tag), resolving the
/// byte-string and excludes expression ids against this grammar
/// (Rust `Grammar::decode_tag_dispatch_data`).
pub fn decode_tag_dispatch_data(
    grammar: *const Grammar,
    allocator: Allocator,
    data: []const i32,
) Allocator.Error!TagDispatch {
    return TagDispatch.decode(allocator, data, grammar);
}

test "tag dispatch decode roundtrip via grammar" {
    const backing = std.testing.allocator;
    const grammar = try build_tag_dispatch_grammar(backing);
    defer grammar.deinit();

    var td = try tag_dispatch(grammar, backing, grammar.root_rule().body_expr_id);
    defer td.deinit(backing);
    try std.testing.expectEqual(@as(usize, 2), td.tag_rule_pairs.items.len);
    try std.testing.expectEqualStrings("a", td.tag_rule_pairs.items[0].tag);
    try std.testing.expectEqual(@as(i32, 0), td.tag_rule_pairs.items[0].rule_id);
    try std.testing.expectEqualStrings("bc", td.tag_rule_pairs.items[1].tag);
    try std.testing.expectEqual(@as(i32, 1), td.tag_rule_pairs.items[1].rule_id);
    try std.testing.expect(td.loop_after_dispatch);
    try std.testing.expectEqual(@as(usize, 1), td.excludes.items.len);
    try std.testing.expectEqualStrings("zz", td.excludes.items[0]);

    var td2 = try decode_tag_dispatch_data(grammar, backing, grammar.expr(grammar.root_rule().body_expr_id).data);
    defer td2.deinit(backing);
    try std.testing.expect(td.eql(td2));
}

/// Test helper shared with printer tests: builds
/// `root ::= TagDispatch(("a" -> r1, "bc" -> r2), loop, excludes=("zz"))`.
pub fn build_tag_dispatch_grammar(backing: Allocator) (support.Compact2dArrayError || Allocator.Error)!*Grammar {
    const grammar_builder_mod = @import("grammar_builder.zig");
    var builder = try grammar_builder_mod.GrammarBuilder.new(backing);
    defer builder.deinit();
    _ = try builder.add_rule_named("r1", try builder.add_byte_string("a"));
    _ = try builder.add_rule_named("r2", try builder.add_byte_string("bc"));
    var td = TagDispatch.empty();
    defer td.deinit(backing);
    try td.tag_rule_pairs.append(backing, .{ .tag = try backing.dupe(u8, "a"), .rule_id = 0 });
    try td.tag_rule_pairs.append(backing, .{ .tag = try backing.dupe(u8, "bc"), .rule_id = 1 });
    td.loop_after_dispatch = true;
    try td.excludes.append(backing, try backing.dupe(u8, "zz"));
    const td_id = try builder.add_tag_dispatch(&td);
    _ = try builder.add_rule_named("root", td_id);
    return builder.into_grammar_with_root_id(backing, 2);
}
