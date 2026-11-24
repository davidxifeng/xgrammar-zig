//! Streaming JSON serialization and validated deserialization for FSM types (`v16` layout).
//!
//! Object keys are emitted in lexicographic order (`edge_aux_data` < `edge_num` < `edges`,
//! `data_` < `indptr_`) to match serde_json / C++ reflection layout.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Diagnostic = @import("../Diagnostic.zig").Diagnostic;
const support = @import("../support.zig");
const Compact2dArray = support.Compact2dArray;
const edge_mod = @import("edge.zig");
const FsmEdge = edge_mod.FsmEdge;
const compact_mod = @import("CompactFsm.zig");
const CompactFsm = compact_mod.CompactFsm;
const CompactFsmWithStartEnd = compact_mod.CompactFsmWithStartEnd;
const CompactFsmWithStartEndWithSize = compact_mod.CompactFsmWithStartEndWithSize;

pub const DeserializeError = error{
    InvalidJson,
    Version,
    Format,
};

fn failFormat(
    allocator: Allocator,
    diag: ?*Diagnostic,
    comptime fmt: []const u8,
    args: anytype,
) (DeserializeError || Allocator.Error) {
    if (diag) |d| {
        try d.setFmt(allocator, .deserialize_format, fmt, args);
    }
    return error.Format;
}

/// Streams a CSR edge table in the `{"data_":[...],"indptr_":[...]}` form.
pub fn writeCompact2dFsmEdges(
    edges: *const Compact2dArray(FsmEdge),
    jw: *std.json.Stringify,
) std.json.Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("data_");
    try jw.beginArray();
    for (edges.dataSlice()) |edge| {
        try edge.writeJson(jw);
    }
    try jw.endArray();
    try jw.objectField("indptr_");
    try jw.beginArray();
    for (edges.indptrSlice()) |v| {
        try jw.write(v);
    }
    try jw.endArray();
    try jw.endObject();
}

/// Deserializes a CSR edge table from `{"data_": ..., "indptr_": ...}`.
pub fn deserializeCompact2dFsmEdges(
    allocator: Allocator,
    value: std.json.Value,
    diag: ?*Diagnostic,
) (DeserializeError || Allocator.Error)!Compact2dArray(FsmEdge) {
    const obj = switch (value) {
        .object => |o| o,
        else => return failFormat(allocator, diag, "compact fsm edges must be an object", .{}),
    };
    const data_value = obj.get("data_") orelse
        return failFormat(allocator, diag, "missing compact fsm data_ array", .{});
    const data_arr = switch (data_value) {
        .array => |arr| arr,
        else => return failFormat(allocator, diag, "compact fsm data_ must be an array", .{}),
    };
    const data = try allocator.alloc(FsmEdge, data_arr.items.len);
    defer allocator.free(data);
    for (data_arr.items, 0..) |item, i| {
        data[i] = FsmEdge.deserializeJsonValue(item) catch
            return failFormat(allocator, diag, "invalid fsm edge in compact fsm", .{});
    }
    const indptr_val = obj.get("indptr_") orelse
        return failFormat(allocator, diag, "missing compact fsm indptr_ array", .{});
    const indptr = try deserializeI32Array(allocator, indptr_val, diag);
    defer allocator.free(indptr);
    return Compact2dArray(FsmEdge).initFromDataAndIndptr(allocator, data, indptr) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failFormat(allocator, diag, "invalid compact fsm indptr_ invariants", .{}),
    };
}

fn parseI32(value: std.json.Value, allocator: Allocator, diag: ?*Diagnostic) (DeserializeError || Allocator.Error)!i32 {
    return switch (value) {
        .integer => |v| std.math.cast(i32, v) orelse
            failFormat(allocator, diag, "expected a 32-bit integer", .{}),
        else => failFormat(allocator, diag, "expected a 32-bit integer", .{}),
    };
}

fn deserializeI32Array(
    allocator: Allocator,
    value: std.json.Value,
    diag: ?*Diagnostic,
) (DeserializeError || Allocator.Error)![]i32 {
    const arr = switch (value) {
        .array => |a| a,
        else => return failFormat(allocator, diag, "expected integer array", .{}),
    };
    const out = try allocator.alloc(i32, arr.items.len);
    errdefer allocator.free(out);
    for (arr.items, 0..) |item, i| {
        out[i] = try parseI32(item, allocator, diag);
    }
    return out;
}

/// Streams a `CompactFsm` with keys in lexicographic order: `edge_aux_data`, `edge_num`, `edges`.
pub fn writeCompactFsm(fsm: CompactFsm, jw: *std.json.Stringify) std.json.Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("edge_aux_data");
    try jw.beginArray();
    for (fsm.edgeAuxData()) |v| try jw.write(v);
    try jw.endArray();
    try jw.objectField("edge_num");
    try jw.write(@as(u64, @intCast(fsm.numEdges())));
    try jw.objectField("edges");
    try writeCompact2dFsmEdges(fsm.edgesTable(), jw);
    try jw.endObject();
}

/// Deserializes a `CompactFsm` from its JSON object representation and validates invariants.
pub fn deserializeCompactFsmJsonValue(
    allocator: Allocator,
    value: std.json.Value,
    diag: ?*Diagnostic,
) (DeserializeError || Allocator.Error)!CompactFsm {
    const obj = switch (value) {
        .object => |o| o,
        else => return failFormat(allocator, diag, "compact fsm must be an object", .{}),
    };
    const edges_val = obj.get("edges") orelse
        return failFormat(allocator, diag, "missing compact fsm edges", .{});
    const aux_val = obj.get("edge_aux_data") orelse
        return failFormat(allocator, diag, "missing compact fsm edge_aux_data", .{});
    const edge_num_value = obj.get("edge_num") orelse
        return failFormat(allocator, diag, "missing compact fsm edge_num", .{});
    const edge_num: u64 = switch (edge_num_value) {
        .integer => |v| if (v >= 0) @intCast(v) else return failFormat(allocator, diag, "edge_num must be non-negative", .{}),
        else => return failFormat(allocator, diag, "expected edge_num integer", .{}),
    };

    var edges = try deserializeCompact2dFsmEdges(allocator, edges_val, diag);
    var edges_moved = false;
    errdefer if (!edges_moved) edges.deinit(allocator);

    const edge_aux_data = try deserializeI32Array(allocator, aux_val, diag);
    var aux_moved = false;
    errdefer if (!aux_moved) allocator.free(edge_aux_data);

    var fsm = try CompactFsm.fromParts(allocator, edges, edge_aux_data);
    edges_moved = true;
    aux_moved = true;
    errdefer fsm.deinit();

    try validateCompactFsm(&fsm, allocator, diag);
    if (edge_num != fsm.numEdges()) {
        return failFormat(allocator, diag, "edge_num does not match the number of edges", .{});
    }
    return fsm;
}

fn validateCompactFsm(
    fsm: *const CompactFsm,
    allocator: Allocator,
    diag: ?*Diagnostic,
) (DeserializeError || Allocator.Error)!void {
    const aux = fsm.edgeAuxData();
    const aux_size: i64 = @intCast(aux.len);
    for (0..@intCast(fsm.numStates())) |state| {
        for (fsm.stateEdges(@intCast(state))) |edge| {
            if (edge.target < 0 or edge.target >= fsm.numStates()) {
                return failFormat(allocator, diag, "edge target out of range", .{});
            }
            if (!edge.isAuxEdge()) continue;
            const idx: i64 = edge.max;
            const in_range = (idx >= 0 and idx < aux_size) and
                (if (edge.isRepeatRef())
                    idx + 3 <= aux_size
                else blk: {
                    const count: i64 = aux[@intCast(idx)];
                    break :blk count >= 0 and idx + 1 + count <= aux_size;
                });
            if (!in_range) {
                return failFormat(allocator, diag, "edge aux index out of range", .{});
            }
        }
    }
}

/// Streams a `CompactFsmWithStartEnd` as `[compact_fsm, start, end_indices, is_dfa, edge_num]`.
pub fn writeCompactFsmWithStartEnd(
    fsm: *const CompactFsmWithStartEnd,
    jw: *std.json.Stringify,
) std.json.Stringify.Error!void {
    try jw.beginArray();
    try writeCompactFsm(fsm.fsm, jw);
    try jw.write(fsm.start);
    try jw.beginArray();
    for (fsm.ends) |v| try jw.write(v);
    try jw.endArray();
    try jw.write(fsm.is_dfa);
    try jw.write(@as(u64, @intCast(fsm.edge_num)));
    try jw.endArray();
}

/// Deserializes a `CompactFsmWithStartEnd` from `[compact_fsm, start, end_indices, is_dfa, edge_num]`.
pub fn deserializeCompactFsmWithStartEndJsonValue(
    allocator: Allocator,
    value: std.json.Value,
    diag: ?*Diagnostic,
) (DeserializeError || Allocator.Error)!CompactFsmWithStartEnd {
    const arr = switch (value) {
        .array => |a| a,
        else => return failFormat(allocator, diag, "compact fsm with start/end must be an array", .{}),
    };
    if (arr.items.len != 5) {
        return failFormat(allocator, diag, "compact fsm with start/end must have five elements", .{});
    }
    var fsm = try deserializeCompactFsmJsonValue(allocator, arr.items[0], diag);
    errdefer fsm.deinit();

    const start = try parseI32(arr.items[1], allocator, diag);
    const ends = try deserializeI32Array(allocator, arr.items[2], diag);
    defer allocator.free(ends);
    const is_dfa = switch (arr.items[3]) {
        .bool => |b| b,
        else => return failFormat(allocator, diag, "expected is_dfa boolean", .{}),
    };
    switch (arr.items[4]) {
        .integer => |v| if (v < 0) return failFormat(allocator, diag, "expected non-negative edge_num", .{}),
        else => return failFormat(allocator, diag, "expected edge_num integer", .{}),
    }

    if (start < 0 or start >= fsm.numStates()) {
        return failFormat(allocator, diag, "start state out of range", .{});
    }
    for (ends) |end| {
        if (end < 0 or end >= fsm.numStates()) {
            return failFormat(allocator, diag, "end state out of range", .{});
        }
    }
    return CompactFsmWithStartEnd.init(allocator, fsm, start, ends, is_dfa);
}

/// Streams a `CompactFsmWithStartEndWithSize` as `[compact_fsm_with_start_end, edge_num, node_num]`.
pub fn writeCompactFsmWithStartEndWithSize(
    fsm: *const CompactFsmWithStartEndWithSize,
    jw: *std.json.Stringify,
) std.json.Stringify.Error!void {
    try jw.beginArray();
    try writeCompactFsmWithStartEnd(&fsm.fsm, jw);
    try jw.write(fsm.edge_num);
    try jw.write(fsm.node_num);
    try jw.endArray();
}

/// Deserializes a `CompactFsmWithStartEndWithSize` from `[compact_fsm_with_start_end, edge_num, node_num]`.
pub fn deserializeCompactFsmWithStartEndWithSizeJsonValue(
    allocator: Allocator,
    value: std.json.Value,
    diag: ?*Diagnostic,
) (DeserializeError || Allocator.Error)!CompactFsmWithStartEndWithSize {
    const arr = switch (value) {
        .array => |a| a,
        else => return failFormat(allocator, diag, "compact fsm with size must be an array", .{}),
    };
    if (arr.items.len != 3) {
        return failFormat(allocator, diag, "compact fsm with size must have three elements", .{});
    }
    var fsm = try deserializeCompactFsmWithStartEndJsonValue(allocator, arr.items[0], diag);
    errdefer fsm.deinit();
    const edge_num = try parseI32(arr.items[1], allocator, diag);
    const node_num = try parseI32(arr.items[2], allocator, diag);
    return CompactFsmWithStartEndWithSize.init(fsm, edge_num, node_num);
}

test "compact fsm streaming serialization roundtrip and error leak safety" {
    const a = std.testing.allocator;
    const Fsm = @import("Fsm.zig").Fsm;

    var fsm = try Fsm.init(a, 2);
    defer fsm.deinit();
    try fsm.addEdge(0, 1, 'a', 'b');
    try fsm.addRepeatEdge(1, 1, 3, 1, 5);
    var compact = try CompactFsm.fromFsm(a, &fsm);
    defer compact.deinit();
    var wse = try CompactFsmWithStartEnd.init(a, compact.retain(), 0, &.{1}, false);
    defer wse.deinit();
    var with_size = CompactFsmWithStartEndWithSize.init(try wse.cloneWithShared(a), 4, 2);
    defer with_size.deinit();

    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    try writeCompactFsmWithStartEndWithSize(&with_size, &jw);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const parsed = try support.parseJson(arena.allocator(), aw.written());

    var diag: Diagnostic = .{};
    defer diag.deinit(a);
    var recovered = try deserializeCompactFsmWithStartEndWithSizeJsonValue(a, parsed, &diag);
    defer recovered.deinit();
    try std.testing.expect(try recovered.fsm.acceptString(a, "a"));
    try std.testing.expect(!try recovered.fsm.acceptString(a, "ab"));
    try std.testing.expectEqual(@as(i32, 4), recovered.edgeNum());
    try std.testing.expectEqual(@as(i32, 2), recovered.nodeNum());

    // Malformed shapes report Format and leak nothing.
    try std.testing.expectError(error.Format, deserializeCompactFsmJsonValue(a, .{ .integer = 1 }, &diag));
    const msg = try diag.formatAlloc(a);
    defer a.free(msg);
    try std.testing.expectEqualStrings("invalid format: compact fsm must be an object", msg);
}
