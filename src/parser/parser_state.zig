//! The state of the Earley parser (`parser_state.rs`).
//!
//! A live state walks a rule's compiled FSM: `element_id` is the current FSM node,
//! `rule_start_pos` the input position the rule was predicted at. `eql`/hash cover all
//! fields (equality/hash for parsing), which is what the parser's queue de-duplication needs.
//! The derived `Ord` is lexicographic over the fields in declaration order; `less_than`
//! reproduces it and is only used to sort states for deterministic serialization.

const std = @import("std");

const parser_state_cache_key = @import("parser_state_cache_key.zig");

const ParserStateCacheKey = parser_state_cache_key.ParserStateCacheKey;

/// One Earley item: a position within a rule's FSM plus the input position it began at.
pub const ParserState = struct {
    /// The rule's id (`-1` for an IR-path lookahead state).
    rule_id: i32,
    /// The rule body (or lookahead sequence) expression id.
    sequence_id: i32,
    /// The current FSM node (or element index in an IR sequence).
    element_id: i32,
    /// The input position the rule started at, or [`ParserState.NO_PREV_INPUT_POS`] for the root.
    rule_start_pos: i32,
    /// The last token index this state's derivation may consume, from the token budget
    /// (`Rule::max_tokens`) of the rule it is inside; `-1` means unlimited.
    budget_deadline: i32,
    /// The id of the sub element in the current element of the sequence.
    sub_element_id: i32,
    /// The number of times the element is repeated (for repeat edges).
    repeat_count: i32,
    /// Partial codepoint accumulated during UTF-8 decoding for character classes.
    partial_codepoint: i32,
    /// The innermost active rule that specifies a sampling temperature, or `-1`.
    active_temperature_rule_id: i32,
    /// The absolute input codepoint position at which the active character budget expires;
    /// `-1` means unlimited.
    char_budget_deadline: i32,

    /// A `rule_start_pos` meaning the state is the root of the parsing stack.
    pub const NO_PREV_INPUT_POS: i32 = -1;

    /// Creates a state at `element_id` of `sequence_id` with no budgets, sub element, repeat
    /// count, partial codepoint, or temperature rule.
    pub fn new(
        rule_id: i32,
        sequence_id: i32,
        element_id: i32,
        rule_start_pos: i32,
    ) ParserState {
        return .{
            .rule_id = rule_id,
            .sequence_id = sequence_id,
            .element_id = element_id,
            .rule_start_pos = rule_start_pos,
            .budget_deadline = -1,
            .sub_element_id = 0,
            .repeat_count = 0,
            .partial_codepoint = 0,
            .active_temperature_rule_id = -1,
            .char_budget_deadline = -1,
        };
    }

    /// The same occurrence moved to `element_id`, with the sub element, repeat count, and
    /// partial codepoint reset (budgets and the temperature rule are inherited).
    pub fn at_element(self: ParserState, element_id: i32) ParserState {
        return self.at_element_with_repeat(element_id, 0);
    }

    /// Like [`ParserState.at_element`], keeping `repeat_count`.
    pub fn at_element_with_repeat(self: ParserState, element_id: i32, repeat_count: i32) ParserState {
        var out = self;
        out.element_id = element_id;
        out.sub_element_id = 0;
        out.repeat_count = repeat_count;
        out.partial_codepoint = 0;
        return out;
    }

    /// The struct-update `{ element_id, ..*self }`: only the FSM node changes.
    pub fn with_element(self: ParserState, element_id: i32) ParserState {
        var out = self;
        out.element_id = element_id;
        return out;
    }

    /// The adaptive token-mask cache key of this state.
    pub fn cache_key(self: ParserState) ParserStateCacheKey {
        return .{
            .rule_id = self.rule_id,
            .sequence_id = self.sequence_id,
            .element_id = self.element_id,
            .sub_element_id = self.sub_element_id,
        };
    }

    /// Serializes as the C++ `XGRAMMAR_MEMBER_ARRAY` order.
    pub inline fn serialize_member_array(self: ParserState) [10]i32 {
        return .{
            self.rule_id,
            self.sequence_id,
            self.element_id,
            self.rule_start_pos,
            self.budget_deadline,
            self.sub_element_id,
            self.repeat_count,
            self.partial_codepoint,
            self.active_temperature_rule_id,
            self.char_budget_deadline,
        };
    }

    /// Deserializes a member array produced by [`ParserState.serialize_member_array`].
    ///
    /// Returns `null` unless `values` contains exactly ten integers.
    pub fn from_member_array(values: []const i32) ?ParserState {
        if (values.len != 10) return null;
        return .{
            .rule_id = values[0],
            .sequence_id = values[1],
            .element_id = values[2],
            .rule_start_pos = values[3],
            .budget_deadline = values[4],
            .sub_element_id = values[5],
            .repeat_count = values[6],
            .partial_codepoint = values[7],
            .active_temperature_rule_id = values[8],
            .char_budget_deadline = values[9],
        };
    }

    /// Rust `PartialEq` (all fields).
    pub fn eql(a: ParserState, b: ParserState) bool {
        return std.meta.eql(a.serialize_member_array(), b.serialize_member_array());
    }

    /// The derived Rust `Ord`: lexicographic over the fields in declaration order.
    pub fn less_than(a: ParserState, b: ParserState) bool {
        return std.mem.order(i32, &a.serialize_member_array(), &b.serialize_member_array()) == .lt;
    }

    /// The Rust `Display` text (caller owns the allocation).
    pub fn display(self: ParserState, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.print("ParserState(rule_id={d}, sequence_id={d}, element_id={d}, rule_start_pos={d}, sub_element_id={d}", .{
            self.rule_id, self.sequence_id, self.element_id, self.rule_start_pos, self.sub_element_id,
        }) catch return error.OutOfMemory;
        if (self.repeat_count != 0) w.print(", repeat_count={d}", .{self.repeat_count}) catch return error.OutOfMemory;
        if (self.partial_codepoint != 0) w.print(", partial_codepoint={d}", .{self.partial_codepoint}) catch return error.OutOfMemory;
        if (self.budget_deadline != -1) w.print(", budget_deadline={d}", .{self.budget_deadline}) catch return error.OutOfMemory;
        if (self.active_temperature_rule_id != -1)
            w.print(", active_temperature_rule_id={d}", .{self.active_temperature_rule_id}) catch return error.OutOfMemory;
        if (self.char_budget_deadline != -1)
            w.print(", char_budget_deadline={d}", .{self.char_budget_deadline}) catch return error.OutOfMemory;
        w.writeAll(")") catch return error.OutOfMemory;
        return gpa.dupe(u8, out.written());
    }
};

test "member array roundtrip and equality" {
    const s = ParserState.new(3, 7, 2, ParserState.NO_PREV_INPUT_POS);
    const arr = s.serialize_member_array();
    try std.testing.expectEqual(@as(usize, 10), arr.len);
    const back = ParserState.from_member_array(&arr).?;
    try std.testing.expect(s.eql(back));
    const short: []const i32 = arr[0..5];
    try std.testing.expect(ParserState.from_member_array(short) == null);
    try std.testing.expect(!s.eql(back.at_element(4)));
    try std.testing.expect(s.less_than(back.at_element(4)));
    const text = try s.display(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        "ParserState(rule_id=3, sequence_id=7, element_id=2, rule_start_pos=-1, sub_element_id=0)",
        text,
    );
}
