//! JSON serialization for FSM types — uses the `"v13"` reflection layout.
//!
//! Deserialization restores the fields verbatim, so it also checks the invariants the
//! constructors normally guarantee (the C++ `Validate` hooks): the CSR offsets cover the edge
//! data, every edge target and auxiliary-data reference is in range, `edge_num` matches, and the
//! start and end states are in range.

const std = @import("std");
const Allocator = std.mem.Allocator;

const fsm_edge_mod = @import("fsm_edge.zig");
const FsmEdge = fsm_edge_mod.FsmEdge;
const compact_fsm_mod = @import("compact_fsm.zig");
const CompactFsm = compact_fsm_mod.CompactFsm;
const compact_fsm_with_start_end_mod = @import("compact_fsm_with_start_end.zig");
const CompactFsmWithStartEnd = compact_fsm_with_start_end_mod.CompactFsmWithStartEnd;
const compact_fsm_with_start_end_with_size_mod = @import("compact_fsm_with_start_end_with_size.zig");
const CompactFsmWithStartEndWithSize = compact_fsm_with_start_end_with_size_mod.CompactFsmWithStartEndWithSize;
const support = @import("support/mod.zig");
const Compact2dArray = support.Compact2dArray;
const grammar_error = @import("grammar/error.zig");
const DeserializeError = grammar_error.DeserializeError;

pub const Value = std.json.Value;

fn format_error() DeserializeError {
    return error.Format;
}

/// Serializes a CSR edge table in the Compact2DArray FSMEdge form.
pub fn serialize_compact_2d_fsm_edges(allocator: Allocator, edges: *const Compact2dArray(FsmEdge)) Allocator.Error!Value {
    var data = std.json.Array.init(allocator);
    for (edges.data_slice()) |edge| {
        try data.append(try edge.serialize_json_value(allocator));
    }
    var indptr = std.json.Array.init(allocator);
    for (edges.indptr_slice()) |v| {
        try indptr.append(.{ .integer = v });
    }
    // serde_json's Map is a BTreeMap: keys serialize in lexicographic order
    // (契约对拍陷阱 1: std.json ObjectMap 是插入序,必须按字典序插入).
    var object = std.json.ObjectMap.empty;
    try object.put(allocator, "data_", .{ .array = data });
    try object.put(allocator, "indptr_", .{ .array = indptr });
    return .{ .object = object };
}

/// Deserializes a CSR edge table from the Compact2DArray FSMEdge form.
pub fn deserialize_compact_2d_fsm_edges(allocator: Allocator, value: Value) (DeserializeError || Allocator.Error)!Compact2dArray(FsmEdge) {
    const obj = switch (value) {
        .object => |o| o,
        else => return format_error(), // compact fsm edges must be an object
    };
    const data_value = obj.get("data_") orelse return format_error(); // missing compact fsm data_ array
    const data_arr = switch (data_value) {
        .array => |arr| arr,
        else => return format_error(),
    };
    var data = try allocator.alloc(FsmEdge, data_arr.items.len);
    defer allocator.free(data);
    for (data_arr.items, 0..) |item, i| {
        data[i] = FsmEdge.deserialize_json_value(item) catch return format_error();
    }
    const indptr = try deserialize_i32_array(allocator, obj.get("indptr_") orelse return format_error()); // missing compact fsm indptr_
    defer allocator.free(indptr);
    return Compact2dArray(FsmEdge).init_from_data_and_indptr(allocator, data, indptr) catch return format_error();
}

fn i32_of(value: Value) DeserializeError!i32 {
    return switch (value) {
        .integer => |v| if (v >= std.math.minInt(i32) and v <= std.math.maxInt(i32))
            @intCast(v)
        else
            format_error(),
        else => format_error(), // expected a 32-bit integer
    };
}

fn deserialize_i32_array(allocator: Allocator, value: Value) (DeserializeError || Allocator.Error)![]i32 {
    const arr = switch (value) {
        .array => |a| a,
        else => return format_error(), // expected array
    };
    const out = try allocator.alloc(i32, arr.items.len);
    for (arr.items, 0..) |item, i| out[i] = try i32_of(item);
    return out;
}

/// An i32 JSON array value.
fn i32_array_value(allocator: Allocator, items: []const i32) Allocator.Error!Value {
    var arr = std.json.Array.init(allocator);
    for (items) |item| try arr.append(.{ .integer = item });
    return .{ .array = arr };
}

/// Serializes this compact FSM to the C++ JSON object form.
pub fn serialize_compact_fsm_json_value(self: CompactFsm, allocator: Allocator) Allocator.Error!Value {
    // Keys sorted lexicographically: "edge_aux_data" < "edge_num" < "edges" (陷阱 1).
    var object = std.json.ObjectMap.empty;
    try object.put(allocator, "edge_aux_data", try i32_array_value(allocator, self.edge_aux_data()));
    try object.put(allocator, "edge_num", .{ .integer = @intCast(self.num_edges()) });
    try object.put(allocator, "edges", try serialize_compact_2d_fsm_edges(allocator, self.edges_table()));
    return .{ .object = object };
}

/// Deserializes a compact FSM from the C++ JSON object form.
pub fn deserialize_compact_fsm_json_value(allocator: Allocator, value: Value) (DeserializeError || Allocator.Error)!CompactFsm {
    const obj = switch (value) {
        .object => |o| o,
        else => return format_error(), // compact fsm must be an object
    };
    const edges = try deserialize_compact_2d_fsm_edges(allocator, obj.get("edges") orelse return format_error());
    const edge_aux_data = try deserialize_i32_array(allocator, obj.get("edge_aux_data") orelse return format_error());
    const edge_num_value = obj.get("edge_num") orelse return format_error();
    const edge_num: u64 = switch (edge_num_value) {
        .integer => |v| if (v >= 0) @intCast(v) else return format_error(),
        else => return format_error(), // expected edge_num integer
    };
    const fsm = CompactFsm.from_parts(allocator, edges, edge_aux_data) catch return error.OutOfMemory;
    try validate_compact_fsm(&fsm);
    if (edge_num != fsm.num_edges()) {
        return format_error(); // edge_num does not match the number of edges
    }
    return fsm;
}

/// Checks that every edge target and every auxiliary data reference is in range.
fn validate_compact_fsm(fsm: *const CompactFsm) DeserializeError!void {
    const aux = fsm.edge_aux_data();
    const aux_size: i64 = @intCast(aux.len);
    for (0..@intCast(fsm.num_states())) |state| {
        for (fsm.state_edges(@intCast(state))) |edge| {
            if (edge.target < 0 or edge.target >= fsm.num_states()) {
                return format_error(); // edge target out of range
            }
            if (!edge.is_aux_edge()) continue;
            // A repeat edge owns 3 aux elements; a token edge owns a count followed by count ids.
            const idx: i64 = edge.max;
            const in_range = (idx >= 0 and idx < aux_size) and
                (if (edge.is_repeat_ref())
                    idx + 3 <= aux_size
                else blk: {
                    if (idx < 0 or idx >= aux_size) break :blk false;
                    const count: i64 = aux[@intCast(idx)];
                    break :blk count >= 0 and idx + 1 + count <= aux_size;
                });
            if (!in_range) return format_error(); // edge aux index out of range
        }
    }
}

/// Serializes as `[compact_fsm, start, end_indices, is_dfa, edge_num]`.
pub fn serialize_compact_fsm_with_start_end_json_value(self: *const CompactFsmWithStartEnd, allocator: Allocator) Allocator.Error!Value {
    var arr = std.json.Array.init(allocator);
    try arr.append(try serialize_compact_fsm_json_value(self.get_fsm(), allocator));
    try arr.append(.{ .integer = self.get_start() });
    try arr.append(try i32_array_value(allocator, self.get_ends()));
    try arr.append(.{ .bool = self.get_is_dfa() });
    try arr.append(.{ .integer = @intCast(self.get_edge_num()) });
    return .{ .array = arr };
}

/// Deserializes from `[compact_fsm, start, end_indices, is_dfa, edge_num]`.
pub fn deserialize_compact_fsm_with_start_end_json_value(allocator: Allocator, value: Value) (DeserializeError || Allocator.Error)!CompactFsmWithStartEnd {
    const arr = switch (value) {
        .array => |a| a,
        else => return format_error(), // compact fsm with start/end must be an array
    };
    if (arr.items.len != 5) {
        return format_error(); // must have five elements
    }
    const fsm = try deserialize_compact_fsm_json_value(allocator, arr.items[0]);
    const start = try i32_of(arr.items[1]);
    const ends = try deserialize_i32_array(allocator, arr.items[2]);
    const is_dfa = switch (arr.items[3]) {
        .bool => |b| b,
        else => return format_error(), // expected is_dfa boolean
    };
    _ = try i32_of(arr.items[4]); // edge_num (informational)
    const in_range = start >= 0 and start < fsm.num_states();
    for (ends) |end| {
        if (!(end >= 0 and end < fsm.num_states())) return format_error();
    }
    if (!in_range) {
        return format_error(); // The start or end state is out of range
    }
    var ends_list: std.ArrayList(i32) = .empty;
    try ends_list.appendSlice(allocator, ends);
    return CompactFsmWithStartEnd.new(allocator, fsm, start, ends_list, is_dfa);
}

/// Serializes as `[compact_fsm_with_start_end, edge_num, node_num]`.
pub fn serialize_compact_fsm_with_start_end_with_size_json_value(self: *const CompactFsmWithStartEndWithSize, allocator: Allocator) Allocator.Error!Value {
    var arr = std.json.Array.init(allocator);
    try arr.append(try serialize_compact_fsm_with_start_end_json_value(self.get_fsm(), allocator));
    try arr.append(.{ .integer = self.get_edge_num() });
    try arr.append(.{ .integer = self.get_node_num() });
    return .{ .array = arr };
}

/// Deserializes from `[compact_fsm_with_start_end, edge_num, node_num]`.
pub fn deserialize_compact_fsm_with_start_end_with_size_json_value(allocator: Allocator, value: Value) (DeserializeError || Allocator.Error)!CompactFsmWithStartEndWithSize {
    const arr = switch (value) {
        .array => |a| a,
        else => return format_error(), // must be an array
    };
    if (arr.items.len != 3) {
        return format_error(); // must have three elements
    }
    const fsm = try deserialize_compact_fsm_with_start_end_json_value(allocator, arr.items[0]);
    const edge_num = try i32_of(arr.items[1]);
    const node_num = try i32_of(arr.items[2]);
    return CompactFsmWithStartEndWithSize.new(fsm, edge_num, node_num);
}

test "compact fsm serialization roundtrip" {
    // std.json Value trees have no recursive free (调用方 arena,见 PORTING.md).
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fsm = try @import("fsm.zig").Fsm.new(a, 2);
    defer fsm.deinit();
    try fsm.add_edge(0, 1, 'a', 'b');
    try fsm.add_repeat_edge(1, 1, 3, 1, 5);
    var compact = try CompactFsm.from_fsm(a, &fsm);
    defer compact.deinit();
    var wse = try CompactFsmWithStartEnd.new(a, compact.clone(), 0, blk: {
        var ends: std.ArrayList(i32) = .empty;
        try ends.append(a, 1);
        break :blk ends;
    }, false);
    defer wse.deinit();
    const with_size = CompactFsmWithStartEndWithSize.new(wse.clone(a), 4, 2);
    defer @constCast(&with_size).deinit();

    const value = try serialize_compact_fsm_with_start_end_with_size_json_value(&with_size, a);

    var recovered = try deserialize_compact_fsm_with_start_end_with_size_json_value(a, value);
    defer recovered.deinit();
    try std.testing.expect(try recovered.get_fsm().accept_string("ab"));
    try std.testing.expectEqual(@as(i32, 4), recovered.get_edge_num());
    try std.testing.expectEqual(@as(i32, 2), recovered.get_node_num());

    // Malformed shapes report Format.
    try std.testing.expectError(error.Format, deserialize_compact_fsm_json_value(a, .{ .integer = 1 }));
}
