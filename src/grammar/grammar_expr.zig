//! A borrowed view over one grammar expression (`grammar_expr.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_expr_type = @import("grammar_expr_type.zig");
const GrammarExprType = grammar_expr_type.GrammarExprType;
const character_class_element = @import("character_class_element.zig");
const CharacterClassElement = character_class_element.CharacterClassElement;

/// A read-only view of a grammar expression: its `GrammarExprType` and its `i32` data
/// payload, borrowed from the grammar's flat buffer.
pub const GrammarExpr = struct {
    /// The expression kind.
    ty: GrammarExprType,
    /// The raw `i32` payload, laid out per the variant's documented format.
    data: []const i32,

    /// Number of payload elements.
    pub fn len(self: GrammarExpr) usize {
        return self.data.len;
    }

    /// Whether the payload is empty.
    pub fn is_empty(self: GrammarExpr) bool {
        return self.data.len == 0;
    }

    /// Decodes a `GrammarExprType.ByteString` payload into its bytes (allocated; caller owns).
    pub fn byte_string(self: GrammarExpr, gpa: Allocator) Allocator.Error![]u8 {
        std.debug.assert(self.ty == .ByteString);
        const out = try gpa.alloc(u8, self.data.len);
        for (self.data, 0..) |b, i| out[i] = @intCast(b);
        return out;
    }

    /// Decodes a `RuleRef` / `CharacterClassStar`-of-rule payload's referenced rule id.
    pub fn rule_ref_id(self: GrammarExpr) i32 {
        std.debug.assert(self.ty == .RuleRef);
        return self.data[0];
    }

    /// Decoded `(is_negative, ranges)` of a character class / character-class-star payload
    /// (Rust returns the tuple `(bool, Vec<CharacterClassElement>)`).
    pub const CharacterClass = struct {
        is_negative: bool,
        ranges: []CharacterClassElement,
    };

    /// Decodes a character class / character-class-star payload (allocated; caller owns).
    pub fn character_class(self: GrammarExpr, gpa: Allocator) Allocator.Error!CharacterClass {
        std.debug.assert(self.ty == .CharacterClass or self.ty == .CharacterClassStar);
        const is_negative = self.data[0] != 0;
        const n = (self.data.len - 1) / 2;
        const ranges = try gpa.alloc(CharacterClassElement, n);
        for (0..n) |i| ranges[i] = CharacterClassElement.new(self.data[1 + 2 * i], self.data[2 + 2 * i]);
        return .{ .is_negative = is_negative, .ranges = ranges };
    }

    /// Decodes a `GrammarExprType.Regex` payload's pattern bytes (allocated; caller owns).
    pub fn regex_pattern(self: GrammarExpr, gpa: Allocator) Allocator.Error![]u8 {
        std.debug.assert(self.ty == .Regex);
        const out = try gpa.alloc(u8, self.data.len - 1);
        for (self.data[1..], 0..) |b, i| out[i] = @intCast(b);
        return out;
    }

    /// Whether a `GrammarExprType.Regex` payload matches the body of a JSON string literal.
    pub fn regex_is_json_string(self: GrammarExpr) bool {
        std.debug.assert(self.ty == .Regex);
        return self.data[0] != 0;
    }

    /// Decodes a `GrammarExprType.Substring` payload into its byte-string chunks
    /// (allocated; caller owns the outer slice and the chunks).
    pub fn substring_chunks(self: GrammarExpr, gpa: Allocator) Allocator.Error![][]const u8 {
        std.debug.assert(self.ty == .Substring);
        var chunks: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (chunks.items) |c| gpa.free(c);
            chunks.deinit(gpa);
        }
        var index: usize = 0;
        while (index < self.data.len) {
            const chunk_len: usize = @intCast(self.data[index]);
            index += 1;
            const chunk = try gpa.alloc(u8, chunk_len);
            for (self.data[index..][0..chunk_len], 0..) |b, i| chunk[i] = @intCast(b);
            try chunks.append(gpa, chunk);
            index += chunk_len;
        }
        return chunks.toOwnedSlice(gpa);
    }

    /// Decoded `(rule_id, min_repeat, max_repeat)` of a `Repeat` payload
    /// (Rust returns the tuple `(i32, i32, i32)`).
    pub const RepeatSpec = struct {
        rule_id: i32,
        min_repeat: i32,
        max_repeat: i32,
    };

    /// Decodes a `GrammarExprType.Repeat` payload.
    pub fn repeat(self: GrammarExpr) RepeatSpec {
        std.debug.assert(self.ty == .Repeat);
        return .{ .rule_id = self.data[0], .min_repeat = self.data[1], .max_repeat = self.data[2] };
    }
};

test "grammar expr decoders" {
    const gpa = std.testing.allocator;
    {
        const e = GrammarExpr{ .ty = .ByteString, .data = &.{ 97, 98, 99 } };
        const bytes = try e.byte_string(gpa);
        defer gpa.free(bytes);
        try std.testing.expectEqualStrings("abc", bytes);
        try std.testing.expectEqual(@as(usize, 3), e.len());
        try std.testing.expect(!e.is_empty());
    }
    {
        const e = GrammarExpr{ .ty = .CharacterClass, .data = &.{ 1, 97, 122, 65, 90 } };
        const cc = try e.character_class(gpa);
        defer gpa.free(cc.ranges);
        try std.testing.expect(cc.is_negative);
        try std.testing.expectEqual(@as(usize, 2), cc.ranges.len);
        try std.testing.expect(cc.ranges[0].contains(97));
        try std.testing.expect(cc.ranges[1].contains(90));
    }
    {
        const e = GrammarExpr{ .ty = .CharacterClassStar, .data = &.{0} };
        const cc = try e.character_class(gpa);
        defer gpa.free(cc.ranges);
        try std.testing.expect(!cc.is_negative);
        try std.testing.expectEqual(@as(usize, 0), cc.ranges.len);
    }
    {
        const e = GrammarExpr{ .ty = .RuleRef, .data = &.{5} };
        try std.testing.expectEqual(@as(i32, 5), e.rule_ref_id());
    }
    {
        const e = GrammarExpr{ .ty = .Regex, .data = &.{ 1, 92, 100 } };
        const pat = try e.regex_pattern(gpa);
        defer gpa.free(pat);
        try std.testing.expectEqualStrings("\\d", pat);
        try std.testing.expect(e.regex_is_json_string());
        try std.testing.expect(!(@as(GrammarExpr, .{ .ty = .Regex, .data = &.{ 0, 120 } })).regex_is_json_string());
    }
    {
        const e = GrammarExpr{ .ty = .Substring, .data = &.{ 2, 97, 98, 3, 99, 100, 101 } };
        const chunks = try e.substring_chunks(gpa);
        defer {
            for (chunks) |c| gpa.free(c);
            gpa.free(chunks);
        }
        try std.testing.expectEqual(@as(usize, 2), chunks.len);
        try std.testing.expectEqualStrings("ab", chunks[0]);
        try std.testing.expectEqualStrings("cde", chunks[1]);
    }
    {
        const e = GrammarExpr{ .ty = .Repeat, .data = &.{ 3, 1, -1 } };
        const r = e.repeat();
        try std.testing.expectEqual(@as(i32, 3), r.rule_id);
        try std.testing.expectEqual(@as(i32, 1), r.min_repeat);
        try std.testing.expectEqual(@as(i32, -1), r.max_repeat);
    }
    {
        const e = GrammarExpr{ .ty = .EmptyStr, .data = &.{} };
        try std.testing.expect(e.is_empty());
    }
}
