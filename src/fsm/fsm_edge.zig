//! The edge of a finite-state machine.
//!
//! An edge's kind is encoded in its `min` field: `min >= 0` is a character range `[min,
//! max]`; a negative `min` is one of the special `edge_type` tags, where `max` carries a
//! type-specific payload (a rule id, or an index into the owning FSM's `edge_aux_data`).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Value = std.json.Value;

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
    /// Panics (debug builds) if this is a character range with `min > max`.
    pub fn new(min: i32, max: i32, target: i32) FsmEdge {
        std.debug.assert(min < 0 or min <= max); // invalid FsmEdge: min > max
        return .{ .min = min, .max = max, .target = target };
    }

    /// Whether the edge is a character range `[min, max]`.
    pub fn is_char_range(self: FsmEdge) bool {
        return self.min >= 0;
    }

    /// Whether the edge is an epsilon transition.
    pub fn is_epsilon(self: FsmEdge) bool {
        return self.min == edge_type.EPSILON;
    }

    /// Whether the edge is a rule reference.
    pub fn is_rule_ref(self: FsmEdge) bool {
        return self.min == edge_type.RULE_REF;
    }

    /// Whether the edge accepts the end-of-string token.
    pub fn is_eos(self: FsmEdge) bool {
        return self.min == edge_type.EOS;
    }

    /// Whether the edge is a repeated rule reference.
    pub fn is_repeat_ref(self: FsmEdge) bool {
        return self.min == edge_type.REPEAT_REF;
    }

    /// Whether the edge accepts a token set.
    pub fn is_token(self: FsmEdge) bool {
        return self.min == edge_type.TOKEN;
    }

    /// Whether the edge accepts any token outside a set.
    pub fn is_exclude_token(self: FsmEdge) bool {
        return self.min == edge_type.EXCLUDE_TOKEN;
    }

    /// The referenced rule id, or `-1` if this is not a rule reference.
    pub fn ref_rule_id(self: FsmEdge) i32 {
        return if (self.is_rule_ref()) self.max else -1;
    }

    /// Whether the edge carries an index into `edge_aux_data`.
    pub fn is_aux_edge(self: FsmEdge) bool {
        return self.is_repeat_ref() or self.is_token() or self.is_exclude_token();
    }

    /// The `edge_aux_data` index for an aux edge, or `-1` otherwise.
    pub fn aux_index(self: FsmEdge) i32 {
        return if (self.is_aux_edge()) self.max else -1;
    }

    /// The `(min, max)` range key used to sort/compare edges by range only.
    pub fn range_key(self: FsmEdge) struct { i32, i32 } {
        return .{ self.min, self.max };
    }

    /// Serializes as `[min, max, target]` (C++ `XGRAMMAR_MEMBER_ARRAY`).
    pub fn serialize_json_value(self: FsmEdge, allocator: Allocator) Allocator.Error!Value {
        var arr = std.json.Array.init(allocator);
        try arr.append(.{ .integer = self.min });
        try arr.append(.{ .integer = self.max });
        try arr.append(.{ .integer = self.target });
        return .{ .array = arr };
    }

    /// Deserializes from `[min, max, target]`. The fields are restored verbatim; the owning
    /// FSM's deserializer checks them against the FSM.
    ///
    /// The Rust error string is dropped (shape-only diagnostics); see PORTING.md deviation.
    pub fn deserialize_json_value(value: Value) DeserializeError!FsmEdge {
        const arr = switch (value) {
            .array => |a| a,
            else => return error.InvalidShape, // fsm edge expects a JSON array
        };
        if (arr.items.len != 3) return error.InvalidShape; // fsm edge must have three elements
        const field = struct {
            fn f(v: Value) DeserializeError!i32 {
                return switch (v) {
                    .integer => |i| if (i >= std.math.minInt(i32) and i <= std.math.maxInt(i32))
                        @intCast(i)
                    else
                        error.InvalidShape,
                    else => error.InvalidShape, // fsm edge fields must be 32-bit integers
                };
            }
        }.f;
        return FsmEdge.new(
            try field(arr.items[0]),
            try field(arr.items[1]),
            try field(arr.items[2]),
        );
    }
};

fn lessThan(_: void, a: FsmEdge, b: FsmEdge) bool {
    if (a.min != b.min) return a.min < b.min;
    if (a.max != b.max) return a.max < b.max;
    return a.target < b.target;
}

/// Lexicographic edge order over `(min, max, target)` (the derived Rust `Ord`).
pub fn sortEdges(edges: []FsmEdge) void {
    std.mem.sortUnstable(FsmEdge, edges, {}, lessThan);
}

/// View into `edge_aux_data` for a repeat edge (`[rule_id, lower, upper]`).
pub const RepeatEdgeRef = struct {
    /// The backing `[rule_id, lower, upper]` slice.
    data: []const i32,

    /// The repeated rule id.
    pub fn rule_id(self: RepeatEdgeRef) i32 {
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
    pub fn token_ids(self: TokenEdgeRef) []const i32 {
        return self.data[1 .. 1 + @as(usize, @intCast(self.data[0]))];
    }
    /// Whether `token_id` is in the set.
    pub fn contains(self: TokenEdgeRef, token_id: i32) bool {
        for (self.token_ids()) |id| {
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
    pub fn token_ids(self: ExcludeTokenEdgeRef) []const i32 {
        return self.data[1 .. 1 + @as(usize, @intCast(self.data[0]))];
    }
    /// Whether `token_id` is in the excluded set.
    pub fn contains(self: ExcludeTokenEdgeRef, token_id: i32) bool {
        for (self.token_ids()) |id| {
            if (id == token_id) return true;
        }
        return false;
    }
    /// Whether `token_id` is accepted (i.e. not excluded).
    pub fn accepts(self: ExcludeTokenEdgeRef, token_id: i32) bool {
        return !self.contains(token_id);
    }
};

test "fsm edge serialize roundtrip" {
    const a = std.testing.allocator;
    const edge = FsmEdge.new(3, 7, 2);
    const v = try edge.serialize_json_value(a);
    defer v.array.deinit();
    const back = try FsmEdge.deserialize_json_value(v);
    try std.testing.expectEqual(edge, back);

    const aux = FsmEdge.new(edge_type.TOKEN, 4, 9);
    try std.testing.expect(aux.is_token());
    try std.testing.expectEqual(@as(i32, -1), aux.ref_rule_id());
    try std.testing.expectEqual(@as(i32, 4), aux.aux_index());
    try std.testing.expectError(error.InvalidShape, FsmEdge.deserialize_json_value(.{ .integer = 1 }));
    try std.testing.expectError(error.InvalidShape, FsmEdge.deserialize_json_value(.{ .array = std.json.Array.init(a) }));
}
