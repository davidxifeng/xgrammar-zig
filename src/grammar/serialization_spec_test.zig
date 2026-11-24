//! Port of `tests/cpp/test_serialization.rs` (JSON serialization spec cases), via the
//! grammar/fsm/support modules.

const std = @import("std");
const Allocator = std.mem.Allocator;

const support = @import("../support.zig");
const fsm_mod = @import("../fsm.zig");
const Compact2dArray = support.Compact2dArray;
const CompactFsm = fsm_mod.CompactFsm;
const DynamicBitset = support.DynamicBitset;
const byteToLatin1 = support.byteToLatin1;
const latin1ToBytes = support.latin1ToBytes;
const Value = std.json.Value;

fn dump(gpa: Allocator, value: Value) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try dumpValue(&out, gpa, value);
    return out.toOwnedSlice(gpa);
}

fn pushFmt(out: *std.ArrayList(u8), gpa: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    const s = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(s);
    try out.appendSlice(gpa, s);
}

fn dumpValue(out: *std.ArrayList(u8), gpa: Allocator, value: Value) Allocator.Error!void {
    switch (value) {
        .null => try out.appendSlice(gpa, "null"),
        .bool => |b| try out.appendSlice(gpa, if (b) "true" else "false"),
        .integer => |n| try pushFmt(out, gpa, "{d}", .{n}),
        .float => |f| {
            var buf: [std.fmt.float.bufferSize(.decimal, f64) + 32]u8 = undefined;
            const s = std.fmt.float.render(&buf, f, .{ .mode = .decimal }) catch unreachable;
            try out.appendSlice(gpa, s);
        },
        .number_string => |s| try out.appendSlice(gpa, s),
        .string => |s| try dumpString(out, gpa, s),
        .array => |items| {
            try out.append(gpa, '[');
            for (items.items, 0..) |item, i| {
                if (i > 0) try out.append(gpa, ',');
                try dumpValue(out, gpa, item);
            }
            try out.append(gpa, ']');
        },
        .object => |map| {
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
                try dumpString(out, gpa, key);
                try out.append(gpa, ':');
                try dumpValue(out, gpa, map.get(key).?);
            }
            try out.append(gpa, '}');
        },
    }
}

fn dumpString(out: *std.ArrayList(u8), gpa: Allocator, s: []const u8) Allocator.Error!void {
    try out.append(gpa, '"');
    var i: usize = 0;
    while (i < s.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            try pushFmt(out, gpa, "\\u{x:0>4}", .{s[i]});
            i += 1;
            continue;
        };
        if (i + cp_len > s.len) {
            try pushFmt(out, gpa, "\\u{x:0>4}", .{s[i]});
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(s[i .. i + cp_len]) catch {
            try pushFmt(out, gpa, "\\u{x:0>4}", .{s[i]});
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
                try pushFmt(out, gpa, "\\u{x:0>4}", .{cp});
            } else {
                try out.append(gpa, @intCast(cp));
            },
        }
        i += cp_len;
    }
    try out.append(gpa, '"');
}

fn serializeBytesString(gpa: Allocator, bytes: []const u8) Allocator.Error!Value {
    return .{ .string = try byteToLatin1(gpa, bytes) };
}

fn deserializeBytesString(gpa: Allocator, value: Value) ![]u8 {
    const s = switch (value) {
        .string => |str| str,
        else => return error.TestUnexpectedResult,
    };
    return latin1ToBytes(gpa, s) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.TestUnexpectedResult,
    };
}

fn serializeI32Set(gpa: Allocator, set: []const i32) Allocator.Error!Value {
    const values = try gpa.dupe(i32, set);
    defer gpa.free(values);
    std.mem.sort(i32, values, {}, std.sort.asc(i32));
    var arr = std.json.Array.init(gpa);
    for (values) |v| try arr.append(.{ .integer = v });
    return .{ .array = arr };
}

fn expectDump(gpa: Allocator, value: Value, want: []const u8) !void {
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
        try expectDump(a, json_value, "true");
        const deserialized = json_value.bool;
        try std.testing.expect(deserialized);
        try expectDump(a, .{ .bool = deserialized }, "true");
    }
    { // i32
        const json_value = Value{ .integer = 42 };
        try std.testing.expect(json_value == .integer);
        try expectDump(a, json_value, "42");
        try std.testing.expectEqual(@as(i32, 42), @as(i32, @intCast(json_value.integer)));
        try expectDump(a, .{ .integer = 42 }, "42");
    }
    { // f64
        const json_value = Value{ .float = 3.14 };
        try std.testing.expect(json_value == .float);
        const d = try dump(a, json_value);
        try std.testing.expectEqual(@as(f64, 3.14), try std.fmt.parseFloat(f64, d));
        try std.testing.expectEqual(@as(f64, 3.14), json_value.float);
        try expectDump(a, .{ .float = 3.14 }, "3.14");
    }
    { // bytes string
        const json_value = try serializeBytesString(a, "hello");
        try std.testing.expect(json_value == .string);
        try std.testing.expectEqualStrings("hello", json_value.string);
        try expectDump(a, json_value, "\"hello\"");
        const deserialized = try deserializeBytesString(a, json_value);
        try std.testing.expectEqualStrings("hello", deserialized);
        try expectDump(a, try serializeBytesString(a, deserialized), "\"hello\"");
    }
    { // i32 vector
        const json_value = try serializeI32Set(a, &.{ 1, 2, 3 });
        try std.testing.expect(json_value == .array);
        try expectDump(a, json_value, "[1,2,3]");
        var deserialized: std.ArrayList(i32) = .empty;
        for (json_value.array.items) |item| try deserialized.append(a, @intCast(item.integer));
        try std.testing.expectEqualSlices(i32, &.{ 1, 2, 3 }, deserialized.items);
        try expectDump(a, try serializeI32Set(a, deserialized.items), "[1,2,3]");
    }
    { // tuple
        const json_value = Value{ .array = blk: {
            var arr = std.json.Array.init(a);
            try arr.append(.{ .integer = 42 });
            try arr.append(try serializeBytesString(a, "hello"));
            break :blk arr;
        } };
        try expectDump(a, json_value, "[42,\"hello\"]");
        const arr = json_value.array.items;
        try std.testing.expectEqual(@as(i64, 42), arr[0].integer);
        try std.testing.expectEqualStrings("hello", arr[1].string);
    }
    { // Some(i32)
        const json_value = Value{ .integer = 42 };
        try std.testing.expectEqual(@as(i64, 42), json_value.integer);
        try expectDump(a, json_value, "42");
    }
    { // None
        const json_value = Value.null;
        try std.testing.expect(json_value == .null);
        try expectDump(a, json_value, "null");
        var deserialized: ?i32 = 999;
        if (json_value == .null) deserialized = null;
        try std.testing.expectEqual(@as(?i32, null), deserialized);
        try expectDump(a, Value.null, "null");
    }
}

test "string latin1 roundtrips" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    {
        const json_value = try serializeBytesString(a, "hello\nworld");
        try expectDump(a, json_value, "\"hello\\nworld\"");
        const deserialized = try deserializeBytesString(a, json_value);
        try std.testing.expectEqualStrings("hello\nworld", deserialized);
    }
    {
        const json_value = try serializeBytesString(a, &.{ 0xC3, 0x28 });
        try expectDump(a, json_value, "\"\\u00c3(\"");
        const deserialized = try deserializeBytesString(a, json_value);
        try std.testing.expectEqualSlices(u8, &.{ 0xC3, 0x28 }, deserialized);
    }
    {
        const json_value = try serializeBytesString(a, "我");
        try expectDump(a, json_value, "\"\\u00e6\\u0088\\u0091\"");
        const deserialized = try deserializeBytesString(a, json_value);
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
        const edge = FsmEdge.init(1, 2, 3);
        var aw: std.Io.Writer.Allocating = .init(a);
        var jw: std.json.Stringify = .{ .writer = &aw.writer };
        try edge.writeJson(&jw);
        try std.testing.expectEqualStrings("[1,2,3]", aw.written());
        const json_value = try support.parseJson(a, aw.written());
        const deserialized = try FsmEdge.deserializeJsonValue(json_value);
        try std.testing.expect(std.meta.eql(deserialized, edge));
    }
    {
        const epsilon_edge = FsmEdge.init(edge_type.EPSILON, 0, 5);
        var aw: std.Io.Writer.Allocating = .init(a);
        var jw: std.json.Stringify = .{ .writer = &aw.writer };
        try epsilon_edge.writeJson(&jw);
        try std.testing.expectEqualStrings("[-1,0,5]", aw.written());
        const json_value = try support.parseJson(a, aw.written());
        const deserialized = try FsmEdge.deserializeJsonValue(json_value);
        try std.testing.expect(std.meta.eql(deserialized, epsilon_edge));
        try std.testing.expect(deserialized.isEpsilon());
    }
    {
        const rule_edge = FsmEdge.init(edge_type.RULE_REF, 10, 7);
        var aw: std.Io.Writer.Allocating = .init(a);
        var jw: std.json.Stringify = .{ .writer = &aw.writer };
        try rule_edge.writeJson(&jw);
        try std.testing.expectEqualStrings("[-2,10,7]", aw.written());
        const json_value = try support.parseJson(a, aw.written());
        const deserialized = try FsmEdge.deserializeJsonValue(json_value);
        try std.testing.expect(std.meta.eql(deserialized, rule_edge));
        try std.testing.expect(deserialized.isRuleRef());
        try std.testing.expectEqual(@as(i32, 10), deserialized.refRuleId());
    }
}

test "compact 2d array json" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    {
        var array = try Compact2dArray(i32).init(gpa);
        defer array.deinit(gpa);
        var aw: std.Io.Writer.Allocating = .init(a);
        var jw: std.json.Stringify = .{ .writer = &aw.writer };
        try support.compact_2d_array.writeJson(&array, &jw);
        try std.testing.expectEqualStrings("{\"data_\":[],\"indptr_\":[0]}", aw.written());
        const json_value = try support.parseJson(a, aw.written());
        var deserialized = try support.compact_2d_array.deserializeJsonValue(gpa, json_value);
        defer deserialized.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), deserialized.len());
    }
    {
        var array = try Compact2dArray(i32).init(gpa);
        defer array.deinit(gpa);
        _ = try array.pushRow(gpa, &.{ 0, 1, 2, 3 });
        _ = try array.pushRow(gpa, &.{ 4, 5, 6, 7 });
        _ = try array.pushRow(gpa, &.{ 8, 9 });

        var aw: std.Io.Writer.Allocating = .init(a);
        var jw: std.json.Stringify = .{ .writer = &aw.writer };
        try support.compact_2d_array.writeJson(&array, &jw);
        try std.testing.expectEqualStrings("{\"data_\":[0,1,2,3,4,5,6,7,8,9],\"indptr_\":[0,4,8,10]}", aw.written());
        const json_value = try support.parseJson(a, aw.written());
        const obj = json_value.object;
        try std.testing.expect(obj.contains("data_"));
        try std.testing.expect(obj.contains("indptr_"));
        try std.testing.expectEqual(@as(usize, 10), obj.get("data_").?.array.items.len);
        try std.testing.expectEqual(@as(usize, 4), obj.get("indptr_").?.array.items.len);

        var deserialized = try support.compact_2d_array.deserializeJsonValue(gpa, json_value);
        defer deserialized.deinit(gpa);
        try std.testing.expectEqualSlices(i32, array.dataSlice(), deserialized.dataSlice());
        try std.testing.expectEqualSlices(i32, array.indptrSlice(), deserialized.indptrSlice());
    }
    {
        const FsmEdge = fsm_mod.FsmEdge;
        const edge_type = fsm_mod.edge_type;
        var array = try Compact2dArray(FsmEdge).init(gpa);
        defer array.deinit(gpa);
        _ = try array.pushRow(gpa, &.{ FsmEdge.init(1, 2, 3), FsmEdge.init(4, 5, 6) });
        _ = try array.pushRow(gpa, &.{FsmEdge.init(edge_type.EPSILON, 0, 7)});

        var aw: std.Io.Writer.Allocating = .init(a);
        var jw: std.json.Stringify = .{ .writer = &aw.writer };
        try fsm_mod.writeCompact2dFsmEdges(&array, &jw);
        try std.testing.expectEqualStrings("{\"data_\":[[1,2,3],[4,5,6],[-1,0,7]],\"indptr_\":[0,2,3]}", aw.written());
        const json_value = try support.parseJson(a, aw.written());
        var deserialized = try fsm_mod.deserializeCompact2dFsmEdges(gpa, json_value, null);
        defer deserialized.deinit(gpa);
        try std.testing.expectEqual(array.len(), deserialized.len());
        for (0..array.len()) |i| {
            const ra = array.row(i);
            const rb = deserialized.row(i);
            try std.testing.expectEqual(ra.len, rb.len);
            for (ra, rb) |x, y| try std.testing.expect(std.meta.eql(x, y));
        }
    }
}

test "dynamic bitset cpp json" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    {
        var bitset = try DynamicBitset.init(gpa, 0);
        defer bitset.deinit(gpa);
        var aw: std.Io.Writer.Allocating = .init(a);
        var jw: std.json.Stringify = .{ .writer = &aw.writer };
        try bitset.writeJsonCpp(&jw);
        try std.testing.expectEqualStrings("[0,0]", aw.written());
        const json_value = try support.parseJson(a, aw.written());
        var deserialized = try DynamicBitset.deserializeJsonValueCpp(gpa, json_value);
        defer deserialized.deinit(gpa);
        try std.testing.expectEqual(bitset.len(), deserialized.len());
    }
    {
        var bitset = try DynamicBitset.init(gpa, 64);
        defer bitset.deinit(gpa);
        bitset.set(0, true);
        bitset.set(10, true);
        bitset.set(63, true);

        var aw: std.Io.Writer.Allocating = .init(a);
        var jw: std.json.Stringify = .{ .writer = &aw.writer };
        try bitset.writeJsonCpp(&jw);
        try std.testing.expectEqualStrings("[64,2,1025,2147483648]", aw.written());
        const json_value = try support.parseJson(a, aw.written());
        const arr = json_value.array.items;
        try std.testing.expectEqual(@as(usize, 4), arr.len);
        try std.testing.expectEqual(@as(i64, 64), arr[0].integer);
        try std.testing.expectEqual(@as(i64, 2), arr[1].integer);

        var deserialized = try DynamicBitset.deserializeJsonValueCpp(gpa, json_value);
        defer deserialized.deinit(gpa);
        try std.testing.expectEqual(bitset.len(), deserialized.len());
        try std.testing.expect(deserialized.get(0));
        try std.testing.expect(deserialized.get(10));
        try std.testing.expect(deserialized.get(63));
        try std.testing.expect(!deserialized.get(1));
        try std.testing.expect(!deserialized.get(62));
    }
    {
        var bitset = try DynamicBitset.init(gpa, 10);
        defer bitset.deinit(gpa);
        bitset.set(0, true);
        bitset.set(5, true);
        bitset.set(9, true);

        var aw: std.Io.Writer.Allocating = .init(a);
        var jw: std.json.Stringify = .{ .writer = &aw.writer };
        try bitset.writeJsonCpp(&jw);
        try std.testing.expectEqualStrings("[10,1,545]", aw.written());
        const json_value = try support.parseJson(a, aw.written());
        var deserialized = try DynamicBitset.deserializeJsonValueCpp(gpa, json_value);
        defer deserialized.deinit(gpa);
        try std.testing.expectEqual(bitset.len(), deserialized.len());
    }
}

test "compact fsm json" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const Fsm = fsm_mod.Fsm;

    {
        var fsm = try Fsm.init(gpa, 3);
        defer fsm.deinit();
        try fsm.addEdge(0, 1, 'a', 'a');
        try fsm.addEdge(1, 2, 'b', 'b');
        try fsm.addEpsilonEdge(0, 2);
        var compact_fsm = try CompactFsm.fromFsm(gpa, &fsm);
        defer compact_fsm.deinit();

        var aw: std.Io.Writer.Allocating = .init(a);
        var jw: std.json.Stringify = .{ .writer = &aw.writer };
        try fsm_mod.writeCompactFsm(compact_fsm, &jw);
        try std.testing.expectEqualStrings(
            "{\"edge_aux_data\":[],\"edge_num\":3,\"edges\":{\"data_\":[[-1,0,2],[97,97,1],[98,98,2]],\"indptr_\":[0,2,3,3]}}",
            aw.written(),
        );
        const json_value = try support.parseJson(a, aw.written());
        var deserialized = try fsm_mod.deserializeCompactFsmJsonValue(gpa, json_value, null);
        defer deserialized.deinit();
        try std.testing.expectEqual(compact_fsm.numStates(), deserialized.numStates());

        var aw2: std.Io.Writer.Allocating = .init(a);
        var jw2: std.json.Stringify = .{ .writer = &aw2.writer };
        try fsm_mod.writeCompactFsm(deserialized, &jw2);
        try std.testing.expectEqualStrings(aw.written(), aw2.written());
    }
    {
        var fsm = try Fsm.init(gpa, 3);
        defer fsm.deinit();
        try fsm.addEdge(0, 1, 'a', 'z');
        try fsm.addRuleEdge(1, 2, 5);
        try fsm.addEosEdge(2, 0);
        var compact_fsm = try CompactFsm.fromFsm(gpa, &fsm);
        defer compact_fsm.deinit();

        var aw: std.Io.Writer.Allocating = .init(a);
        var jw: std.json.Stringify = .{ .writer = &aw.writer };
        try fsm_mod.writeCompactFsm(compact_fsm, &jw);
        try std.testing.expectEqualStrings(
            "{\"edge_aux_data\":[],\"edge_num\":3,\"edges\":{\"data_\":[[97,122,1],[-2,5,2],[-3,0,0]],\"indptr_\":[0,1,2,3]}}",
            aw.written(),
        );
        const json_value = try support.parseJson(a, aw.written());
        var deserialized = try fsm_mod.deserializeCompactFsmJsonValue(gpa, json_value, null);
        defer deserialized.deinit();
        try std.testing.expectEqual(compact_fsm.numStates(), deserialized.numStates());
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
        var fsm = try Fsm.init(gpa, 3);
        defer fsm.deinit();
        try fsm.addEdge(0, 1, 'a', 'a');
        try fsm.addEdge(1, 2, 'b', 'b');
        try fsm.addEpsilonEdge(0, 2);
        var compact_fsm = try CompactFsm.fromFsm(gpa, &fsm);
        defer compact_fsm.deinit();
        var compact_fsm_with_start_end = try CompactFsmWithStartEnd.init(gpa, compact_fsm.retain(), 0, &.{2}, false);
        defer compact_fsm_with_start_end.deinit();

        var aw: std.Io.Writer.Allocating = .init(a);
        var jw: std.json.Stringify = .{ .writer = &aw.writer };
        try fsm_mod.writeCompactFsmWithStartEnd(&compact_fsm_with_start_end, &jw);
        try std.testing.expectEqualStrings(
            "[{\"edge_aux_data\":[],\"edge_num\":3,\"edges\":{\"data_\":[[-1,0,2],[97,97,1],[98,98,2]],\"indptr_\":[0,2,3,3]}},0,[2],false,3]",
            aw.written(),
        );
        const json_value = try support.parseJson(a, aw.written());
        var deserialized = try fsm_mod.deserializeCompactFsmWithStartEndJsonValue(gpa, json_value, null);
        defer deserialized.deinit();
        try std.testing.expectEqual(@as(i32, 0), deserialized.start);
        try std.testing.expectEqualSlices(i32, &.{2}, deserialized.ends);
    }
    {
        var fsm = try Fsm.init(gpa, 3);
        defer fsm.deinit();
        try fsm.addEdge(0, 1, 'a', 'z');
        try fsm.addRuleEdge(1, 2, 5);
        try fsm.addEosEdge(2, 0);
        var compact_fsm = try CompactFsm.fromFsm(gpa, &fsm);
        defer compact_fsm.deinit();
        var compact_fsm_with_start_end = try CompactFsmWithStartEnd.init(gpa, compact_fsm.retain(), 0, &.{2}, false);
        defer compact_fsm_with_start_end.deinit();

        var aw: std.Io.Writer.Allocating = .init(a);
        var jw: std.json.Stringify = .{ .writer = &aw.writer };
        try fsm_mod.writeCompactFsmWithStartEnd(&compact_fsm_with_start_end, &jw);
        try std.testing.expectEqualStrings(
            "[{\"edge_aux_data\":[],\"edge_num\":3,\"edges\":{\"data_\":[[97,122,1],[-2,5,2],[-3,0,0]],\"indptr_\":[0,1,2,3]}},0,[2],false,3]",
            aw.written(),
        );
        const json_value = try support.parseJson(a, aw.written());
        var deserialized = try fsm_mod.deserializeCompactFsmWithStartEndJsonValue(gpa, json_value, null);
        defer deserialized.deinit();
        try std.testing.expectEqual(@as(i32, 0), deserialized.start);
        try std.testing.expectEqualSlices(i32, &.{2}, deserialized.ends);
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
            FsmEdge.init(1, 2, 3),
            FsmEdge.init(edge_type.EPSILON, 0, 4),
            FsmEdge.init(edge_type.RULE_REF, 5, 6),
        };
        var aw: std.Io.Writer.Allocating = .init(a);
        var jw: std.json.Stringify = .{ .writer = &aw.writer };
        try jw.beginArray();
        for (edges) |edge| try edge.writeJson(&jw);
        try jw.endArray();
        try std.testing.expectEqualStrings("[[1,2,3],[-1,0,4],[-2,5,6]]", aw.written());
        const json_value = try support.parseJson(a, aw.written());
        var deserialized: std.ArrayList(FsmEdge) = .empty;
        for (json_value.array.items) |item| try deserialized.append(a, try FsmEdge.deserializeJsonValue(item));
        try std.testing.expectEqual(edges.len, deserialized.items.len);
        for (edges, deserialized.items) |x, y| try std.testing.expect(std.meta.eql(x, y));
    }
    {
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

        try expectDump(a, json_value, "{\"key1\":[1,2,3],\"key2\":[4,5,6]}");
    }
}
