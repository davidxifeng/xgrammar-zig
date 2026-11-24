//! Decoded forms of `TagDispatch` and `TokenTagDispatch` grammar expressions.

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_mod = @import("Grammar.zig");
const Grammar = grammar_mod.Grammar;
const GrammarExpr = grammar_mod.GrammarExpr;

/// The number of trailing payload elements after the tag/rule pairs:
/// `loop_after_dispatch` and the excluded-strings expression id.
pub const EXTRA_PARAMETERS: usize = 2;

/// `(tag, rule_id)` pair.
pub const TagRulePair = struct {
    tag: []u8,
    rule_id: i32,
};

/// A decoded tag-dispatch expression: `(tag bytes, rule id)` pairs, a looping
/// flag, and a set of excluded byte strings.
pub const TagDispatch = struct {
    tag_rule_pairs: std.ArrayList(TagRulePair) = .empty,
    loop_after_dispatch: bool = false,
    excludes: std.ArrayList([]u8) = .empty,

    pub const empty: TagDispatch = .{};

    pub fn init() TagDispatch {
        return .empty;
    }

    pub fn deinit(self: *TagDispatch, allocator: Allocator) void {
        for (self.tag_rule_pairs.items) |pair| allocator.free(pair.tag);
        self.tag_rule_pairs.deinit(allocator);
        for (self.excludes.items) |exclude| allocator.free(exclude);
        self.excludes.deinit(allocator);
    }

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
    /// byte-string and excludes expression ids through `context.expr(expr_id)`.
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
        for (0..body_len / 2) |pair_index| {
            const pair = data[pair_index * 2 ..][0..2];
            const tag = try context.expr(pair[0]).byteString(allocator);
            errdefer allocator.free(tag);
            try tag_rule_pairs.append(allocator, .{ .tag = tag, .rule_id = pair[1] });
        }
        const loop_after_dispatch = data[data.len - 2] != 0;
        const exclude_expr: GrammarExpr = context.expr(data[data.len - 1]);
        std.debug.assert(exclude_expr.ty == .Choices);
        var excludes: std.ArrayList([]u8) = .empty;
        errdefer if (!finished) {
            for (excludes.items) |exclude| allocator.free(exclude);
            excludes.deinit(allocator);
        };
        for (exclude_expr.data) |child| {
            const bytes = try context.expr(child).byteString(allocator);
            errdefer allocator.free(bytes);
            try excludes.append(allocator, bytes);
        }
        finished = true;
        return .{
            .tag_rule_pairs = tag_rule_pairs,
            .loop_after_dispatch = loop_after_dispatch,
            .excludes = excludes,
        };
    }
};

/// Decodes the tag-dispatch expression with the given id.
pub fn tagDispatch(
    grammar: *const Grammar,
    allocator: Allocator,
    expr_id: i32,
) Allocator.Error!TagDispatch {
    const expr = grammar.expr(expr_id);
    std.debug.assert(expr.ty == .TagDispatch);
    return decodeTagDispatchData(grammar, allocator, expr.data);
}

/// Decodes a tag-dispatch payload against `grammar`.
pub fn decodeTagDispatchData(
    grammar: *const Grammar,
    allocator: Allocator,
    data: []const i32,
) Allocator.Error!TagDispatch {
    return TagDispatch.decode(allocator, data, grammar);
}

/// `(token_id, rule_id)` trigger pair.
pub const TriggerRulePair = struct {
    token_id: i32,
    rule_id: i32,
};

/// A decoded token-tag-dispatch expression: `(token id, rule id)` triggers, a looping
/// flag, and excluded token ids.
pub const TokenTagDispatch = struct {
    trigger_rule_pairs: std.ArrayList(TriggerRulePair) = .empty,
    loop_after_dispatch: bool = false,
    excludes: std.ArrayList(i32) = .empty,

    pub const empty: TokenTagDispatch = .{};

    pub fn init() TokenTagDispatch {
        return .empty;
    }

    pub fn deinit(self: *TokenTagDispatch, allocator: Allocator) void {
        self.trigger_rule_pairs.deinit(allocator);
        self.excludes.deinit(allocator);
    }

    pub fn eql(a: TokenTagDispatch, b: TokenTagDispatch) bool {
        if (a.loop_after_dispatch != b.loop_after_dispatch) return false;
        if (a.trigger_rule_pairs.items.len != b.trigger_rule_pairs.items.len) return false;
        for (a.trigger_rule_pairs.items, b.trigger_rule_pairs.items) |x, y| {
            if (x.token_id != y.token_id or x.rule_id != y.rule_id) return false;
        }
        return std.mem.eql(i32, a.excludes.items, b.excludes.items);
    }
};

/// Decodes the token-tag-dispatch expression with the given id.
pub fn tokenTagDispatch(
    grammar: *const Grammar,
    allocator: Allocator,
    expr_id: i32,
) Allocator.Error!TokenTagDispatch {
    const expr = grammar.expr(expr_id);
    std.debug.assert(expr.ty == .TokenTagDispatch);
    return decodeTokenTagDispatchData(allocator, expr.data);
}

/// Decodes a token-tag-dispatch payload (the expr data without its type tag).
pub fn decodeTokenTagDispatchData(
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

    std.debug.assert(pos == data.len);
    return .{
        .trigger_rule_pairs = trigger_rule_pairs,
        .loop_after_dispatch = loop_after_dispatch,
        .excludes = excludes,
    };
}

test "tag dispatch decode roundtrip via grammar" {
    const backing = std.testing.allocator;
    const grammar_builder_mod = @import("Builder.zig");
    var builder = try grammar_builder_mod.GrammarBuilder.init(backing);
    defer builder.deinit();
    _ = try builder.addRuleNamed("r1", try builder.addByteString("a"));
    _ = try builder.addRuleNamed("r2", try builder.addByteString("bc"));
    var td = TagDispatch.init();
    defer td.deinit(backing);
    try td.tag_rule_pairs.append(backing, .{ .tag = try backing.dupe(u8, "a"), .rule_id = 0 });
    try td.tag_rule_pairs.append(backing, .{ .tag = try backing.dupe(u8, "bc"), .rule_id = 1 });
    td.loop_after_dispatch = true;
    try td.excludes.append(backing, try backing.dupe(u8, "zz"));
    const td_id = try builder.addTagDispatch(&td);
    _ = try builder.addRuleNamed("root", td_id);
    var grammar = try builder.intoGrammarWithRootId(2);
    defer grammar.deinit();

    var decoded = try tagDispatch(&grammar, backing, grammar.rootRule().body_expr_id);
    defer decoded.deinit(backing);
    try std.testing.expectEqual(@as(usize, 2), decoded.tag_rule_pairs.items.len);
    try std.testing.expectEqualStrings("a", decoded.tag_rule_pairs.items[0].tag);
    try std.testing.expectEqual(@as(i32, 0), decoded.tag_rule_pairs.items[0].rule_id);
    try std.testing.expectEqualStrings("bc", decoded.tag_rule_pairs.items[1].tag);
    try std.testing.expectEqual(@as(i32, 1), decoded.tag_rule_pairs.items[1].rule_id);
    try std.testing.expect(decoded.loop_after_dispatch);
    try std.testing.expectEqual(@as(usize, 1), decoded.excludes.items.len);
    try std.testing.expectEqualStrings("zz", decoded.excludes.items[0]);

    var decoded2 = try decodeTagDispatchData(&grammar, backing, grammar.expr(grammar.rootRule().body_expr_id).data);
    defer decoded2.deinit(backing);
    try std.testing.expect(decoded.eql(decoded2));
}

test "token tag dispatch decode roundtrip via grammar" {
    const backing = std.testing.allocator;
    const grammar_builder_mod = @import("Builder.zig");
    var builder = try grammar_builder_mod.GrammarBuilder.init(backing);
    defer builder.deinit();
    _ = try builder.addRuleNamed("r1", try builder.addEmptyStr());
    _ = try builder.addRuleNamed("r2", try builder.addEmptyStr());
    var ttd = TokenTagDispatch.init();
    defer ttd.deinit(backing);
    try ttd.trigger_rule_pairs.append(backing, .{ .token_id = 10, .rule_id = 0 });
    try ttd.trigger_rule_pairs.append(backing, .{ .token_id = 20, .rule_id = 1 });
    ttd.loop_after_dispatch = false;
    try ttd.excludes.appendSlice(backing, &.{ 7, 8, 9 });
    const ttd_id = try builder.addTokenTagDispatch(&ttd);
    _ = try builder.addRuleNamed("root", ttd_id);
    var grammar = try builder.intoGrammarWithRootId(2);
    defer grammar.deinit();

    var decoded = try tokenTagDispatch(&grammar, backing, 2);
    defer decoded.deinit(backing);
    try std.testing.expect(decoded.eql(ttd));
    try std.testing.expectEqual(@as(usize, 2), decoded.trigger_rule_pairs.items.len);
    try std.testing.expectEqual(@as(i32, 20), decoded.trigger_rule_pairs.items[1].token_id);
    try std.testing.expect(!decoded.loop_after_dispatch);
    try std.testing.expectEqual(@as(usize, 3), decoded.excludes.items.len);
}
