//! The edge of a finite-state machine.
//!
//! An edge's kind is encoded in its `min` field: `min >= 0` is a character range `[min,
//! max]`; a negative `min` is one of the special `edge_type` tags, where `max` carries a
//! type-specific payload (a rule id, or an index into the owning FSM's `edge_aux_data`).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Special edge-type tags stored in `FsmEdge.min` when it is negative.
pub const edge_type = struct {
    /// Character range `[min, max]` (`min >= 0`; not represented here).
    pub const CHAR_RANGE: i32 = 0;
    /// Epsilon transition; `max` is unused.
    pub const EPSILON: i32 = -1;
    /// Rule reference; `max` is the rule id.
    pub const RULE_REF: i32 = -2;
    /// Accepts the end-of-string token; `max` is unused.
    pub const EOS: i32 = -3;
    /// Repeated rule reference; `max` indexes `edge_aux_data` (`[rule_id, lower, upper]`).
    pub const REPEAT_REF: i32 = -4;
    /// Accepts a set of token ids; `max` indexes `edge_aux_data` (`[count, ids...]`).
    pub const TOKEN: i32 = -5;
    /// Accepts any token not in a set; `max` indexes `edge_aux_data` (`[count, ids...]`).
    pub const EXCLUDE_TOKEN: i32 = -6;
};

/// The largest character value an edge range may span.
pub const MAX_CHAR: i32 = 255;

pub const DeserializeError = error{
    /// The JSON value is not a 3-element integer array.
    InvalidShape,
    OutOfMemory,
};

/// An FSM transition. Ordering is lexicographic over `(min, max, target)`, matching the
/// C++ edge sort.
pub const FsmEdge = struct {
    /// Range lower bound, or a negative `edge_type` tag.
    min: i32,
    /// Range upper bound, or a type-specific payload.
    max: i32,
    /// Target state id.
    target: i32,

    /// Creates an edge.
    ///
    /// Asserts (debug builds) that character ranges satisfy `min <= max`.
    pub fn init(min: i32, max: i32, target: i32) FsmEdge {
        std.debug.assert(min < 0 or min <= max);
        return .{ .min = min, .max = max, .target = target };
    }

    /// Whether the edge is a character range `[min, max]`.
    pub inline fn isCharRange(self: FsmEdge) bool {
        return self.min >= 0;
    }

    /// Whether the edge is an epsilon transition.
    pub inline fn isEpsilon(self: FsmEdge) bool {
        return self.min == edge_type.EPSILON;
    }

    /// Whether the edge is a rule reference.
    pub inline fn isRuleRef(self: FsmEdge) bool {
        return self.min == edge_type.RULE_REF;
    }

    /// Whether the edge accepts the end-of-string token.
    pub inline fn isEos(self: FsmEdge) bool {
        return self.min == edge_type.EOS;
    }

    /// Whether the edge is a repeated rule reference.
    pub inline fn isRepeatRef(self: FsmEdge) bool {
        return self.min == edge_type.REPEAT_REF;
    }

    /// Whether the edge accepts a token set.
    pub inline fn isToken(self: FsmEdge) bool {
        return self.min == edge_type.TOKEN;
    }

    /// Whether the edge accepts any token outside a set.
    pub inline fn isExcludeToken(self: FsmEdge) bool {
        return self.min == edge_type.EXCLUDE_TOKEN;
    }

    /// The referenced rule id, or `-1` if this is not a rule reference.
    pub inline fn refRuleId(self: FsmEdge) i32 {
        return if (self.isRuleRef()) self.max else -1;
    }

    /// Whether the edge carries an index into `edge_aux_data`.
    pub inline fn isAuxEdge(self: FsmEdge) bool {
        return self.isRepeatRef() or self.isToken() or self.isExcludeToken();
    }

    /// The `edge_aux_data` index for an aux edge, or `-1` otherwise.
    pub inline fn auxIndex(self: FsmEdge) i32 {
        return if (self.isAuxEdge()) self.max else -1;
    }

    /// The `(min, max)` range key used to sort/compare edges by range only.
    pub inline fn rangeKey(self: FsmEdge) struct { i32, i32 } {
        return .{ self.min, self.max };
    }

    pub inline fn eql(a: FsmEdge, b: FsmEdge) bool {
        return a.min == b.min and a.max == b.max and a.target == b.target;
    }

    /// Streams as `[min, max, target]`.
    pub fn writeJson(self: FsmEdge, jw: *std.json.Stringify) std.json.Stringify.Error!void {
        try jw.beginArray();
        try jw.write(self.min);
        try jw.write(self.max);
        try jw.write(self.target);
        try jw.endArray();
    }

    /// Deserializes from `[min, max, target]`.
    pub fn deserializeJsonValue(value: std.json.Value) DeserializeError!FsmEdge {
        const arr = switch (value) {
            .array => |a| a,
            else => return error.InvalidShape,
        };
        if (arr.items.len != 3) return error.InvalidShape;
        const min = try parseI32(arr.items[0]);
        const max = try parseI32(arr.items[1]);
        const target = try parseI32(arr.items[2]);
        if (min >= 0 and min > max) return error.InvalidShape;
        return FsmEdge.init(min, max, target);
    }

    fn parseI32(v: std.json.Value) DeserializeError!i32 {
        return switch (v) {
            .integer => |i| std.math.cast(i32, i) orelse error.InvalidShape,
            else => error.InvalidShape,
        };
    }
};

/// Streams `edge` as `[min, max, target]`.
pub fn writeJson(edge: FsmEdge, jw: *std.json.Stringify) std.json.Stringify.Error!void {
    return edge.writeJson(jw);
}

/// Deserializes an `FsmEdge` from `[min, max, target]`.
pub fn deserializeJsonValue(value: std.json.Value) DeserializeError!FsmEdge {
    return FsmEdge.deserializeJsonValue(value);
}

fn lessThan(_: void, a: FsmEdge, b: FsmEdge) bool {
    if (a.min != b.min) return a.min < b.min;
    if (a.max != b.max) return a.max < b.max;
    return a.target < b.target;
}

/// Lexicographic edge order over `(min, max, target)`.
pub fn sortEdges(edges: []FsmEdge) void {
    std.mem.sortUnstable(FsmEdge, edges, {}, lessThan);
}

/// View into `edge_aux_data` for a repeat edge (`[rule_id, lower, upper]`).
pub const RepeatEdgeRef = struct {
    /// The backing `[rule_id, lower, upper]` slice.
    data: []const i32,

    /// The repeated rule id.
    pub fn ruleId(self: RepeatEdgeRef) i32 {
        return self.data[0];
    }

    /// The minimum repetition count.
    pub fn lower(self: RepeatEdgeRef) i32 {
        return self.data[1];
    }

    /// The maximum repetition count (`-1` is unbounded).
    pub fn upper(self: RepeatEdgeRef) i32 {
        return self.data[2];
    }
};

/// View into `edge_aux_data` for a token edge (`[count, ids...]`).
pub const TokenEdgeRef = struct {
    /// The backing `[count, ids...]` slice.
    data: []const i32,

    /// The accepted token ids.
    pub fn tokenIds(self: TokenEdgeRef) []const i32 {
        return self.data[1 .. 1 + @as(usize, @intCast(self.data[0]))];
    }

    /// Whether `token_id` is in the set.
    pub fn contains(self: TokenEdgeRef, token_id: i32) bool {
        for (self.tokenIds()) |id| {
            if (id == token_id) return true;
        }
        return false;
    }
};

/// View into `edge_aux_data` for an exclude-token edge (`[count, ids...]`).
pub const ExcludeTokenEdgeRef = struct {
    /// The backing `[count, ids...]` slice.
    data: []const i32,

    /// The excluded token ids.
    pub fn tokenIds(self: ExcludeTokenEdgeRef) []const i32 {
        return self.data[1 .. 1 + @as(usize, @intCast(self.data[0]))];
    }

    /// Whether `token_id` is in the excluded set.
    pub fn contains(self: ExcludeTokenEdgeRef, token_id: i32) bool {
        for (self.tokenIds()) |id| {
            if (id == token_id) return true;
        }
        return false;
    }

    /// Whether `token_id` is accepted (i.e. not excluded).
    pub fn accepts(self: ExcludeTokenEdgeRef, token_id: i32) bool {
        return !self.contains(token_id);
    }
};

test "fsm edge serialize roundtrip and helpers" {
    const a = std.testing.allocator;
    const edge = FsmEdge.init(3, 7, 2);

    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    try writeJson(edge, &jw);
    try std.testing.expectEqualStrings("[3,7,2]", aw.written());

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const parsed = try @import("../support.zig").parseJson(arena.allocator(), aw.written());
    const back = try deserializeJsonValue(parsed);
    try std.testing.expectEqual(edge, back);

    const aux = FsmEdge.init(edge_type.TOKEN, 4, 9);
    try std.testing.expect(aux.isToken());
    try std.testing.expect(aux.isAuxEdge());
    try std.testing.expectEqual(@as(i32, -1), aux.refRuleId());
    try std.testing.expectEqual(@as(i32, 4), aux.auxIndex());

    const rep_data = [_]i32{ 5, 2, 10 };
    const rep = RepeatEdgeRef{ .data = &rep_data };
    try std.testing.expectEqual(@as(i32, 5), rep.ruleId());
    try std.testing.expectEqual(@as(i32, 2), rep.lower());
    try std.testing.expectEqual(@as(i32, 10), rep.upper());

    const tok_data = [_]i32{ 2, 10, 20 };
    const tok = TokenEdgeRef{ .data = &tok_data };
    try std.testing.expect(tok.contains(10));
    try std.testing.expect(!tok.contains(30));

    const ex = ExcludeTokenEdgeRef{ .data = &tok_data };
    try std.testing.expect(ex.contains(20));
    try std.testing.expect(!ex.accepts(20));
    try std.testing.expect(ex.accepts(30));

    try std.testing.expectError(error.InvalidShape, deserializeJsonValue(.{ .integer = 1 }));
    try std.testing.expectError(error.InvalidShape, deserializeJsonValue(.{ .array = std.json.Array.init(a) }));
}
