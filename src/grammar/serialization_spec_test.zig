//! Port of `tests/cpp/test_serialization.rs` (JSON serialization spec cases), via the
//! grammar/fsm/support modules. Golden strings follow the library's serde_json Map =
//! BTreeMap key order (lexicographic); the Rust file's goldens were produced under the
//! dev-dependency `preserve_order` feature and are reordered accordingly here.

const std = @import("std");
const Allocator = std.mem.Allocator;

const support = @import("../support/mod.zig");
const fsm_mod = @import("../fsm/mod.zig");
const Compact2dArray = support.Compact2dArray;
const CompactFsm = fsm_mod.CompactFsm;
const DynamicBitset = support.DynamicBitset;
const byte_to_latin1 = support.byte_to_latin1;
const latin1_to_bytes = support.latin1_to_bytes;
const Value = std.json.Value;

/// Compact JSON dump matching picojson's escaping (non-ASCII → `\u00xx`), with object
/// keys sorted (serde_json Map = BTreeMap).
fn dump(gpa: Allocator, value: Value) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try dump_value(&out, gpa, value);
    return out.toOwnedSlice(gpa);
}

fn push_fmt(out: *std.ArrayList(u8), gpa: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    const s = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(s);
    try out.appendSlice(gpa, s);
}

fn dump_value(out: *std.ArrayList(u8), gpa: Allocator, value: Value) Allocator.Error!void {
    switch (value) {
        .null => try out.appendSlice(gpa, "null"),
        .bool => |b| try out.appendSlice(gpa, if (b) "true" else "false"),
        .integer => |n| try push_fmt(out, gpa, "{d}", .{n}),
        .float => |f| {
            var buf: [std.fmt.float.bufferSize(.decimal, f64) + 32]u8 = undefined;
            const s = std.fmt.float.render(&buf, f, .{ .mode = .decimal }) catch unreachable;
            try out.appendSlice(gpa, s);
        },
        .number_string => |s| try out.appendSlice(gpa, s),
        .string => |s| try dump_string(out, gpa, s),
        .array => |items| {
            try out.append(gpa, '[');
            for (items.items, 0..) |item, i| {
                if (i > 0) try out.append(gpa, ',');
                try dump_value(out, gpa, item);
            }
            try out.append(gpa, ']');
        },
        .object => |map| {
            // BTreeMap iteration: keys in lexicographic order.
            const keys = try gpa.dupe([]const u8, map.keys());
            defer gpa.free(keys);
            std.mem.sort([]const u8, keys, {}, struct {
                fn lt(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lt);
            try out.append(gpa, '{');
            for (keys, 0..) |key, i| {
                if (i > 0) try out.append(gpa, ',');
                try dump_string(out, gpa, key);
                try out.append(gpa, ':');
                try dump_value(out, gpa, map.get(key).?);
            }
            try out.append(gpa, '}');
        },
    }
}

fn dump_string(out: *std.ArrayList(u8), gpa: Allocator, s: []const u8) Allocator.Error!void {
    try out.append(gpa, '"');
    var i: usize = 0;
    while (i < s.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            try push_fmt(out, gpa, "\\u{x:0>4}", .{s[i]});
            i += 1;
            continue;
        };
        if (i + cp_len > s.len) {
            try push_fmt(out, gpa, "\\u{x:0>4}", .{s[i]});
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(s[i .. i + cp_len]) catch {
            try push_fmt(out, gpa, "\\u{x:0>4}", .{s[i]});
            i += 1;
            continue;
        };
        switch (cp) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            0x08 => try out.appendSlice(gpa, "\\b"),
            0x0C => try out.appendSlice(gpa, "\\f"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            else => if (cp < 0x20 or cp > 0x7E) {
                try push_fmt(out, gpa, "\\u{x:0>4}", .{cp});
            } else {
                try out.append(gpa, @intCast(cp));
            },
        }
        i += cp_len;
    }
    try out.append(gpa, '"');
}

fn serialize_bytes_string(gpa: Allocator, bytes: []const u8) Allocator.Error!Value {
    return .{ .string = try byte_to_latin1(gpa, bytes) };
}

fn deserialize_bytes_string(gpa: Allocator, value: Value) ![]u8 {
    const s = switch (value) {
        .string => |str| str,
        else => return error.TestUnexpectedResult,
    };
    return latin1_to_bytes(gpa, s) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.TestUnexpectedResult,
    };
}

fn serialize_i32_set(gpa: Allocator, set: []const i32) Allocator.Error!Value {
    const values = try gpa.dupe(i32, set);
    defer gpa.free(values);
    std.mem.sort(i32, values, {}, std.sort.asc(i32));
    var arr = std.json.Array.init(gpa);
    for (values) |v| try arr.append(.{ .integer = v });
    return .{ .array = arr };
}

fn expect_dump(gpa: Allocator, value: Value, want: []const u8) !void {
    const d = try dump(gpa, value);
    defer gpa.free(d);
    try std.testing.expectEqualStrings(want, d);
}

test "stl and builtin types" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    { // bool
        const json_value = Value{ .bool = true };
        try std.testing.expect(json_value == .bool);
        try expect_dump(a, json_value, "true");
        const deserialized = json_value.bool;
        try std.testing.expect(deserialized);
        try expect_dump(a, .{ .bool = deserialized }, "true");
    }
    { // i32
        const json_value = Value{ .integer = 42 };
        try std.testing.expect(json_value == .integer);
        try expect_dump(a, json_value, "42");
        try std.testing.expectEqual(@as(i32, 42), @as(i32, @intCast(json_value.integer)));
        try expect_dump(a, .{ .integer = 42 }, "42");
    }
    { // f64
        const json_value = Value{ .float = 3.14 };
        try std.testing.expect(json_value == .float);
        const d = try dump(a, json_value);
        try std.testing.expectEqual(@as(f64, 3.14), try std.fmt.parseFloat(f64, d));
        try std.testing.expectEqual(@as(f64, 3.14), json_value.float);
        try expect_dump(a, .{ .float = 3.14 }, "3.14");
    }
    { // bytes string
        const json_value = try serialize_bytes_string(a, "hello");
        try std.testing.expect(json_value == .string);
        try std.testing.expectEqualStrings("hello", json_value.string);
        try expect_dump(a, json_value, "\"hello\"");
        const deserialized = try deserialize_bytes_string(a, json_value);
        try std.testing.expectEqualStrings("hello", deserialized);
        try expect_dump(a, try serialize_bytes_string(a, deserialized), "\"hello\"");
    }
    { // i32 vector
        const json_value = try serialize_i32_set(a, &.{ 1, 2, 3 });
        try std.testing.expect(json_value == .array);
        try expect_dump(a, json_value, "[1,2,3]");
        var deserialized: std.ArrayList(i32) = .empty;
        for (json_value.array.items) |item| try deserialized.append(a, @intCast(item.integer));
        try std.testing.expectEqualSlices(i32, &.{ 1, 2, 3 }, deserialized.items);
        try expect_dump(a, try serialize_i32_set(a, deserialized.items), "[1,2,3]");
    }
    { // tuple
        const json_value = Value{ .array = blk: {
            var arr = std.json.Array.init(a);
            try arr.append(.{ .integer = 42 });
            try arr.append(try serialize_bytes_string(a, "hello"));
            break :blk arr;
        } };
        try expect_dump(a, json_value, "[42,\"hello\"]");
        const arr = json_value.array.items;
        try std.testing.expectEqual(@as(i64, 42), arr[0].integer);
        try std.testing.expectEqualStrings("hello", arr[1].string);
    }
    { // Some(i32)
        const json_value = Value{ .integer = 42 };
        try std.testing.expectEqual(@as(i64, 42), json_value.integer);
        try expect_dump(a, json_value, "42");
    }
    { // None
        const json_value = Value.null;
        try std.testing.expect(json_value == .null);
        try expect_dump(a, json_value, "null");
        var deserialized: ?i32 = 999;
        if (json_value == .null) deserialized = null;
        try std.testing.expectEqual(@as(?i32, null), deserialized);
        try expect_dump(a, Value.null, "null");
    }
}

test "string latin1 roundtrips" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    {
        const json_value = try serialize_bytes_string(a, "hello\nworld");
        try expect_dump(a, json_value, "\"hello\\nworld\"");
        const deserialized = try deserialize_bytes_string(a, json_value);
        try std.testing.expectEqualStrings("hello\nworld", deserialized);
    }
    {
        const json_value = try serialize_bytes_string(a, &.{ 0xC3, 0x28 });
        try expect_dump(a, json_value, "\"\\u00c3(\"");
        const deserialized = try deserialize_bytes_string(a, json_value);
        try std.testing.expectEqualSlices(u8, &.{ 0xC3, 0x28 }, deserialized);
    }
    {
        const json_value = try serialize_bytes_string(a, "我");
        try expect_dump(a, json_value, "\"\\u00e6\\u0088\\u0091\"");
        const deserialized = try deserialize_bytes_string(a, json_value);
        try std.testing.expectEqualStrings("我", deserialized);
    }
}

test "fsm edge json" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const FsmEdge = fsm_mod.FsmEdge;
    const edge_type = fsm_mod.edge_type;

    {
        const edge = FsmEdge.new(1, 2, 3);
        const json_value = try edge.serialize_json_value(a);
        try std.testing.expect(json_value == .array);
        try expect_dump(a, json_value, "[1,2,3]");
        const deserialized = try FsmEdge.deserialize_json_value(json_value);
        try std.testing.expect(std.meta.eql(deserialized, edge));
        try expect_dump(a, try deserialized.serialize_json_value(a), "[1,2,3]");
    }
    {
        const epsilon_edge = FsmEdge.new(edge_type.EPSILON, 0, 5);
        const json_value = try epsilon_edge.serialize_json_value(a);
        try expect_dump(a, json_value, "[-1,0,5]");
        const deserialized = try FsmEdge.deserialize_json_value(json_value);
        try std.testing.expect(std.meta.eql(deserialized, epsilon_edge));
        try std.testing.expect(deserialized.is_epsilon());
        try expect_dump(a, try deserialized.serialize_json_value(a), "[-1,0,5]");
    }
    {
        const rule_edge = FsmEdge.new(edge_type.RULE_REF, 10, 7);
        const json_value = try rule_edge.serialize_json_value(a);
        try expect_dump(a, json_value, "[-2,10,7]");
        const deserialized = try FsmEdge.deserialize_json_value(json_value);
        try std.testing.expect(std.meta.eql(deserialized, rule_edge));
        try std.testing.expect(deserialized.is_rule_ref());
        try std.testing.expectEqual(@as(i32, 10), deserialized.ref_rule_id());
        try expect_dump(a, try deserialized.serialize_json_value(a), "[-2,10,7]");
    }
}

test "compact 2d array json" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    {
        const array = try Compact2dArray(i32).init(a);
        const json_value = try support.compact_2d_array.serialize_json_value(&array, a);
        try std.testing.expect(json_value == .object);
        try expect_dump(a, json_value, "{\"data_\":[],\"indptr_\":[0]}");
        const deserialized = try support.compact_2d_array.deserialize_json_value(a, json_value);
        var deserialized_mut = deserialized;
        defer deserialized_mut.deinit();
        try std.testing.expectEqual(@as(usize, 0), deserialized.len());
        try expect_dump(a, try support.compact_2d_array.serialize_json_value(&deserialized, a), "{\"data_\":[],\"indptr_\":[0]}");
    }
    {
        var array = try Compact2dArray(i32).init(a);
        defer array.deinit();
        _ = try array.push_row(&.{ 0, 1, 2, 3 });
        _ = try array.push_row(&.{ 4, 5, 6, 7 });
        _ = try array.push_row(&.{ 8, 9 });

        const json_value = try support.compact_2d_array.serialize_json_value(&array, a);
        try std.testing.expect(json_value == .object);
        try expect_dump(a, json_value, "{\"data_\":[0,1,2,3,4,5,6,7,8,9],\"indptr_\":[0,4,8,10]}");
        const obj = json_value.object;
        try std.testing.expect(obj.contains("data_"));
        try std.testing.expect(obj.contains("indptr_"));
        try std.testing.expectEqual(@as(usize, 10), obj.get("data_").?.array.items.len);
        try std.testing.expectEqual(@as(usize, 4), obj.get("indptr_").?.array.items.len);

        const deserialized = try support.compact_2d_array.deserialize_json_value(a, json_value);
        var deserialized_mut = deserialized;
        defer deserialized_mut.deinit();
        try std.testing.expectEqualSlices(i32, array.data_slice(), deserialized.data_slice());
        try std.testing.expectEqualSlices(i32, array.indptr_slice(), deserialized.indptr_slice());
        try expect_dump(a, try support.compact_2d_array.serialize_json_value(&deserialized, a), "{\"data_\":[0,1,2,3,4,5,6,7,8,9],\"indptr_\":[0,4,8,10]}");
    }
    {
        const FsmEdge = fsm_mod.FsmEdge;
        const edge_type = fsm_mod.edge_type;
        var array = try Compact2dArray(FsmEdge).init(a);
        defer array.deinit();
        _ = try array.push_row(&.{ FsmEdge.new(1, 2, 3), FsmEdge.new(4, 5, 6) });
        _ = try array.push_row(&.{FsmEdge.new(edge_type.EPSILON, 0, 7)});

        const json_value = try fsm_mod.serialize_compact_2d_fsm_edges(a, &array);
        try std.testing.expect(json_value == .object);
        try expect_dump(a, json_value, "{\"data_\":[[1,2,3],[4,5,6],[-1,0,7]],\"indptr_\":[0,2,3]}");
        const deserialized = try fsm_mod.deserialize_compact_2d_fsm_edges(a, json_value);
        var deserialized_mut = deserialized;
        defer deserialized_mut.deinit();
        try std.testing.expectEqual(array.len(), deserialized.len());
        for (0..array.len()) |i| {
            const ra = array.row(i);
            const rb = deserialized.row(i);
            try std.testing.expectEqual(ra.len, rb.len);
            for (ra, rb) |x, y| try std.testing.expect(std.meta.eql(x, y));
        }
        try expect_dump(a, try fsm_mod.serialize_compact_2d_fsm_edges(a, &deserialized), "{\"data_\":[[1,2,3],[4,5,6],[-1,0,7]],\"indptr_\":[0,2,3]}");
    }
}

test "dynamic bitset cpp json" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    {
        var bitset = try DynamicBitset.init(gpa, 0);
        defer bitset.deinit();
        const json_value = try bitset.serialize_json_value_cpp(a);
        try std.testing.expect(json_value == .array);
        try expect_dump(a, json_value, "[0,0]");
        var deserialized = try DynamicBitset.deserialize_json_value_cpp(gpa, json_value);
        defer deserialized.deinit();
        try std.testing.expectEqual(bitset.len(), deserialized.len());
        try expect_dump(a, try deserialized.serialize_json_value_cpp(a), "[0,0]");
    }
    {
        var bitset = try DynamicBitset.init(gpa, 64);
        defer bitset.deinit();
        bitset.set(0, true);
        bitset.set(10, true);
        bitset.set(63, true);

        const json_value = try bitset.serialize_json_value_cpp(a);
        try std.testing.expect(json_value == .array);
        try expect_dump(a, json_value, "[64,2,1025,2147483648]");
        const arr = json_value.array.items;
        try std.testing.expectEqual(@as(usize, 4), arr.len);
        try std.testing.expectEqual(@as(i64, 64), arr[0].integer);
        try std.testing.expectEqual(@as(i64, 2), arr[1].integer);

        var deserialized = try DynamicBitset.deserialize_json_value_cpp(gpa, json_value);
        defer deserialized.deinit();
        try std.testing.expectEqual(bitset.len(), deserialized.len());
        try std.testing.expect(deserialized.get(0));
        try std.testing.expect(deserialized.get(10));
        try std.testing.expect(deserialized.get(63));
        try std.testing.expect(!deserialized.get(1));
        try std.testing.expect(!deserialized.get(62));
        try expect_dump(a, try deserialized.serialize_json_value_cpp(a), "[64,2,1025,2147483648]");
    }
    {
        var bitset = try DynamicBitset.init(gpa, 10);
        defer bitset.deinit();
        bitset.set(0, true);
        bitset.set(5, true);
        bitset.set(9, true);

        const json_value = try bitset.serialize_json_value_cpp(a);
        try std.testing.expect(json_value == .array);
        try expect_dump(a, json_value, "[10,1,545]");
        var deserialized = try DynamicBitset.deserialize_json_value_cpp(gpa, json_value);
        defer deserialized.deinit();
        try std.testing.expectEqual(bitset.len(), deserialized.len());
        try expect_dump(a, try deserialized.serialize_json_value_cpp(a), "[10,1,545]");
    }
}

test "compact fsm json" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const Fsm = fsm_mod.Fsm;

    {
        var fsm = try Fsm.new(a, 3);
        defer fsm.deinit();
        try fsm.add_edge(0, 1, 'a', 'a');
        try fsm.add_edge(1, 2, 'b', 'b');
        try fsm.add_epsilon_edge(0, 2);
        var compact_fsm = try CompactFsm.from_fsm(a, &fsm);
        defer compact_fsm.deinit();

        const json_value = try fsm_mod.serialization.serialize_compact_fsm_json_value(compact_fsm, a);
        try std.testing.expect(json_value == .object);
        try expect_dump(a, json_value, "{\"edge_aux_data\":[],\"edge_num\":3,\"edges\":{\"data_\":[[-1,0,2],[97,97,1],[98,98,2]],\"indptr_\":[0,2,3,3]}}");
        var deserialized = try fsm_mod.serialization.deserialize_compact_fsm_json_value(a, json_value);
        defer deserialized.deinit();
        try std.testing.expectEqual(compact_fsm.num_states(), deserialized.num_states());
        try expect_dump(a, try fsm_mod.serialization.serialize_compact_fsm_json_value(deserialized, a), "{\"edge_aux_data\":[],\"edge_num\":3,\"edges\":{\"data_\":[[-1,0,2],[97,97,1],[98,98,2]],\"indptr_\":[0,2,3,3]}}");
    }
    {
        var fsm = try Fsm.new(a, 3);
        defer fsm.deinit();
        try fsm.add_edge(0, 1, 'a', 'z');
        try fsm.add_rule_edge(1, 2, 5);
        try fsm.add_eos_edge(2, 0);
        var compact_fsm = try CompactFsm.from_fsm(a, &fsm);
        defer compact_fsm.deinit();

        const json_value = try fsm_mod.serialization.serialize_compact_fsm_json_value(compact_fsm, a);
        try expect_dump(a, json_value, "{\"edge_aux_data\":[],\"edge_num\":3,\"edges\":{\"data_\":[[97,122,1],[-2,5,2],[-3,0,0]],\"indptr_\":[0,1,2,3]}}");
        var deserialized = try fsm_mod.serialization.deserialize_compact_fsm_json_value(a, json_value);
        defer deserialized.deinit();
        try std.testing.expectEqual(compact_fsm.num_states(), deserialized.num_states());
        try expect_dump(a, try fsm_mod.serialization.serialize_compact_fsm_json_value(deserialized, a), "{\"edge_aux_data\":[],\"edge_num\":3,\"edges\":{\"data_\":[[97,122,1],[-2,5,2],[-3,0,0]],\"indptr_\":[0,1,2,3]}}");
    }
}

test "compact fsm with start end json" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const Fsm = fsm_mod.Fsm;
    const CompactFsmWithStartEnd = fsm_mod.CompactFsmWithStartEnd;

    {
        var fsm = try Fsm.new(a, 3);
        defer fsm.deinit();
        try fsm.add_edge(0, 1, 'a', 'a');
        try fsm.add_edge(1, 2, 'b', 'b');
        try fsm.add_epsilon_edge(0, 2);
        var compact_fsm = try CompactFsm.from_fsm(a, &fsm);
        defer compact_fsm.deinit();
        var ends: std.ArrayList(i32) = .empty;
        try ends.append(a, 2);
        var compact_fsm_with_start_end = try CompactFsmWithStartEnd.new(a, compact_fsm.clone(), 0, ends, false);
        defer compact_fsm_with_start_end.deinit();

        const json_value = try fsm_mod.serialization.serialize_compact_fsm_with_start_end_json_value(&compact_fsm_with_start_end, a);
        try std.testing.expect(json_value == .array);
        try expect_dump(a, json_value, "[{\"edge_aux_data\":[],\"edge_num\":3,\"edges\":{\"data_\":[[-1,0,2],[97,97,1],[98,98,2]],\"indptr_\":[0,2,3,3]}},0,[2],false,3]");
        var deserialized = try fsm_mod.serialization.deserialize_compact_fsm_with_start_end_json_value(a, json_value);
        defer deserialized.deinit();
        try std.testing.expectEqual(@as(i32, 0), deserialized.get_start());
        try std.testing.expectEqualSlices(i32, &.{2}, deserialized.get_ends());
        try expect_dump(a, try fsm_mod.serialization.serialize_compact_fsm_with_start_end_json_value(&deserialized, a), "[{\"edge_aux_data\":[],\"edge_num\":3,\"edges\":{\"data_\":[[-1,0,2],[97,97,1],[98,98,2]],\"indptr_\":[0,2,3,3]}},0,[2],false,3]");
    }
    {
        var fsm = try Fsm.new(a, 3);
        defer fsm.deinit();
        try fsm.add_edge(0, 1, 'a', 'z');
        try fsm.add_rule_edge(1, 2, 5);
        try fsm.add_eos_edge(2, 0);
        var compact_fsm = try CompactFsm.from_fsm(a, &fsm);
        defer compact_fsm.deinit();
        var ends: std.ArrayList(i32) = .empty;
        try ends.append(a, 2);
        var compact_fsm_with_start_end = try CompactFsmWithStartEnd.new(a, compact_fsm.clone(), 0, ends, false);
        defer compact_fsm_with_start_end.deinit();

        const json_value = try fsm_mod.serialization.serialize_compact_fsm_with_start_end_json_value(&compact_fsm_with_start_end, a);
        try expect_dump(a, json_value, "[{\"edge_aux_data\":[],\"edge_num\":3,\"edges\":{\"data_\":[[97,122,1],[-2,5,2],[-3,0,0]],\"indptr_\":[0,1,2,3]}},0,[2],false,3]");
        var deserialized = try fsm_mod.serialization.deserialize_compact_fsm_with_start_end_json_value(a, json_value);
        defer deserialized.deinit();
        try std.testing.expectEqual(@as(i32, 0), deserialized.get_start());
        try std.testing.expectEqualSlices(i32, &.{2}, deserialized.get_ends());
        try expect_dump(a, try fsm_mod.serialization.serialize_compact_fsm_with_start_end_json_value(&deserialized, a), "[{\"edge_aux_data\":[],\"edge_num\":3,\"edges\":{\"data_\":[[97,122,1],[-2,5,2],[-3,0,0]],\"indptr_\":[0,1,2,3]}},0,[2],false,3]");
    }
}

test "complex structures" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const FsmEdge = fsm_mod.FsmEdge;
    const edge_type = fsm_mod.edge_type;

    {
        const edges = [_]FsmEdge{
            FsmEdge.new(1, 2, 3),
            FsmEdge.new(edge_type.EPSILON, 0, 4),
            FsmEdge.new(edge_type.RULE_REF, 5, 6),
        };
        const json_value = Value{ .array = blk: {
            var arr = std.json.Array.init(a);
            for (edges) |edge| try arr.append(try edge.serialize_json_value(a));
            break :blk arr;
        } };
        try std.testing.expect(json_value == .array);
        try expect_dump(a, json_value, "[[1,2,3],[-1,0,4],[-2,5,6]]");
        var deserialized: std.ArrayList(FsmEdge) = .empty;
        for (json_value.array.items) |item| try deserialized.append(a, try FsmEdge.deserialize_json_value(item));
        try std.testing.expectEqual(edges.len, deserialized.items.len);
        for (edges, deserialized.items) |x, y| try std.testing.expect(std.meta.eql(x, y));
        const roundtrip = Value{ .array = blk: {
            var arr = std.json.Array.init(a);
            for (deserialized.items) |edge| try arr.append(try edge.serialize_json_value(a));
            break :blk arr;
        } };
        try expect_dump(a, roundtrip, "[[1,2,3],[-1,0,4],[-2,5,6]]");
    }
    {
        // Sorted-key object with vector values (C++ unordered_map order is unspecified;
        // the Rust fixture inserts keys in sorted order already).
        var obj = std.json.ObjectMap.empty;
        var v1 = std.json.Array.init(a);
        try v1.append(.{ .integer = 1 });
        try v1.append(.{ .integer = 2 });
        try v1.append(.{ .integer = 3 });
        var v2 = std.json.Array.init(a);
        try v2.append(.{ .integer = 4 });
        try v2.append(.{ .integer = 5 });
        try v2.append(.{ .integer = 6 });
        try obj.put(a, "key1", .{ .array = v1 });
        try obj.put(a, "key2", .{ .array = v2 });
        const json_value = Value{ .object = obj };
        try std.testing.expect(json_value == .object);
        const m = json_value.object;
        try std.testing.expectEqual(@as(usize, 2), m.count());
        try std.testing.expect(m.contains("key1"));
        try std.testing.expect(m.contains("key2"));

        var deserialized: std.StringHashMap(std.ArrayList(i32)) = .init(a);
        var it = m.iterator();
        while (it.next()) |entry| {
            var list: std.ArrayList(i32) = .empty;
            for (entry.value_ptr.*.array.items) |n| try list.append(a, @intCast(n.integer));
            try deserialized.put(try a.dupe(u8, entry.key_ptr.*), list);
        }
        try std.testing.expectEqual(@as(usize, 3), deserialized.get("key1").?.items.len);
        try std.testing.expectEqual(@as(i32, 6), deserialized.get("key2").?.items[2]);

        var obj2 = std.json.ObjectMap.empty;
        try obj2.put(a, "key1", .{ .array = v1 });
        try obj2.put(a, "key2", .{ .array = v2 });
        try expect_dump(a, Value{ .object = obj2 }, "{\"key1\":[1,2,3],\"key2\":[4,5,6]}");
    }
}
