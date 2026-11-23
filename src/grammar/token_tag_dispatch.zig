//! Decoded form of a `GrammarExprType.TokenTagDispatch` expression
//! (`token_tag_dispatch.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_mod = @import("grammar.zig");
const Grammar = grammar_mod.Grammar;
const grammar_expr_type = @import("grammar_expr_type.zig");
const GrammarExprType = grammar_expr_type.GrammarExprType;

/// `(token_id, rule_id)` trigger pair (Rust tuple `(i32, i32)`).
pub const TriggerRulePair = struct {
    token_id: i32,
    rule_id: i32,
};

/// A decoded token-tag-dispatch expression: `(token id, rule id)` triggers, a looping
/// flag, and excluded token ids.
pub const TokenTagDispatch = struct {
    /// `(token_id, rule_id)` pairs; each trigger token dispatches into its rule.
    trigger_rule_pairs: std.ArrayList(TriggerRulePair),
    /// Whether dispatching loops after a tag is handled.
    loop_after_dispatch: bool,
    /// Excluded token ids.
    excludes: std.ArrayList(i32),

    pub fn empty() TokenTagDispatch {
        return .{ .trigger_rule_pairs = .empty, .loop_after_dispatch = false, .excludes = .empty };
    }

    pub fn deinit(self: *TokenTagDispatch, allocator: Allocator) void {
        self.trigger_rule_pairs.deinit(allocator);
        self.excludes.deinit(allocator);
    }

    /// Rust `PartialEq`.
    pub fn eql(a: TokenTagDispatch, b: TokenTagDispatch) bool {
        if (a.loop_after_dispatch != b.loop_after_dispatch) return false;
        if (a.trigger_rule_pairs.items.len != b.trigger_rule_pairs.items.len) return false;
        for (a.trigger_rule_pairs.items, b.trigger_rule_pairs.items) |x, y| {
            if (x.token_id != y.token_id or x.rule_id != y.rule_id) return false;
        }
        if (a.excludes.items.len != b.excludes.items.len) return false;
        for (a.excludes.items, b.excludes.items) |x, y| if (x != y) return false;
        return true;
    }
};

/// Decodes the token-tag-dispatch expression with the given id (Rust
/// `Grammar::token_tag_dispatch`).
pub fn token_tag_dispatch(
    grammar: *const Grammar,
    allocator: Allocator,
    expr_id: i32,
) Allocator.Error!TokenTagDispatch {
    const expr = grammar.expr(expr_id);
    std.debug.assert(expr.ty == .TokenTagDispatch); // not a token tag dispatch
    return decode_token_tag_dispatch_data(allocator, expr.data);
}

/// Decodes a token-tag-dispatch payload (the expr data without its type tag).
pub fn decode_token_tag_dispatch_data(
    allocator: Allocator,
    data: []const i32,
) Allocator.Error!TokenTagDispatch {
    var pos: usize = 0;

    const trigger_count: usize = @intCast(data[pos]);
    pos += 1;
    var trigger_rule_pairs: std.ArrayList(TriggerRulePair) = .empty;
    errdefer trigger_rule_pairs.deinit(allocator);
    try trigger_rule_pairs.ensureTotalCapacity(allocator, trigger_count);
    for (0..trigger_count) |_| {
        trigger_rule_pairs.appendAssumeCapacity(.{ .token_id = data[pos], .rule_id = data[pos + 1] });
        pos += 2;
    }

    const loop_after_dispatch = data[pos] != 0;
    pos += 1;

    const exclude_count: usize = @intCast(data[pos]);
    pos += 1;
    var excludes: std.ArrayList(i32) = .empty;
    errdefer excludes.deinit(allocator);
    try excludes.ensureTotalCapacity(allocator, exclude_count);
    for (0..exclude_count) |_| {
        excludes.appendAssumeCapacity(data[pos]);
        pos += 1;
    }

    std.debug.assert(pos == data.len); // token-tag-dispatch payload length mismatch
    return .{
        .trigger_rule_pairs = trigger_rule_pairs,
        .loop_after_dispatch = loop_after_dispatch,
        .excludes = excludes,
    };
}

test "token tag dispatch decode roundtrip via grammar" {
    const backing = std.testing.allocator;
    const grammar_builder_mod = @import("grammar_builder.zig");
    var builder = try grammar_builder_mod.GrammarBuilder.new(backing);
    defer builder.deinit();
    _ = try builder.add_rule_named("r1", try builder.add_empty_str());
    _ = try builder.add_rule_named("r2", try builder.add_empty_str());
    var ttd = TokenTagDispatch.empty();
    defer ttd.deinit(backing);
    try ttd.trigger_rule_pairs.append(backing, .{ .token_id = 10, .rule_id = 0 });
    try ttd.trigger_rule_pairs.append(backing, .{ .token_id = 20, .rule_id = 1 });
    ttd.loop_after_dispatch = false;
    try ttd.excludes.appendSlice(backing, &.{ 7, 8, 9 });
    const ttd_id = try builder.add_token_tag_dispatch(&ttd);
    _ = try builder.add_rule_named("root", ttd_id);
    const grammar = try builder.into_grammar_with_root_id(backing, 2);
    defer grammar.deinit();

    var decoded = try token_tag_dispatch(grammar, backing, 2);
    defer decoded.deinit(backing);
    try std.testing.expect(decoded.eql(ttd));
    try std.testing.expectEqual(@as(usize, 2), decoded.trigger_rule_pairs.items.len);
    try std.testing.expectEqual(@as(i32, 20), decoded.trigger_rule_pairs.items[1].token_id);
    try std.testing.expect(!decoded.loop_after_dispatch);
    try std.testing.expectEqual(@as(usize, 3), decoded.excludes.items.len);
}
