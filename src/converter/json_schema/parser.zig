//! Parses a JSON Schema (`std.json.Value`) into the `SchemaSpec` IR
//! (`schema_parser.rs` + `schema_error.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Diagnostic = @import("../../Diagnostic.zig").Diagnostic;
const range_regex = @import("../range_regex.zig");
const spec_mod = @import("spec.zig");

const AllOfSpec = spec_mod.AllOfSpec;
const AnyOfSpec = spec_mod.AnyOfSpec;
const ArraySpec = spec_mod.ArraySpec;
const ConstSpec = spec_mod.ConstSpec;
const EnumSpec = spec_mod.EnumSpec;
const IntegerSpec = spec_mod.IntegerSpec;
const NumberSpec = spec_mod.NumberSpec;
const ObjectSpec = spec_mod.ObjectSpec;
const RefSpec = spec_mod.RefSpec;
const SchemaSpec = spec_mod.SchemaSpec;
const SchemaSpecPtr = spec_mod.SchemaSpecPtr;
const SchemaSpecVariant = spec_mod.SchemaSpecVariant;
const StringSpec = spec_mod.StringSpec;
const TypeArraySpec = spec_mod.TypeArraySpec;

const log = std.log.scoped(.xgrammar);

pub const Value = std.json.Value;
pub const ObjectMap = std.json.ObjectMap;

/// Errors raised while parsing or converting a JSON Schema.
pub const SchemaError = error{
    InvalidSchema,
    UnsatisfiableSchema,
    OutOfMemory,
};

pub fn failStatic(e: SchemaError, diag: ?*Diagnostic, message: []const u8) SchemaError {
    if (diag) |d| d.setStatic(.message, message);
    return e;
}

pub fn failCopy(e: SchemaError, diag: ?*Diagnostic, gpa: Allocator, message: []const u8) SchemaError {
    if (diag) |d| try d.setCopy(gpa, .message, message);
    return e;
}

pub fn failFmt(
    e: SchemaError,
    diag: ?*Diagnostic,
    gpa: Allocator,
    comptime fmt: []const u8,
    args: anytype,
) SchemaError {
    if (diag) |d| try d.setFmt(gpa, .message, fmt, args);
    return e;
}

/// Saturating `i64 -> i32` cast.
fn satI32(n: i64) i32 {
    return std.math.cast(i32, n) orelse if (n < 0) std.math.minInt(i32) else std.math.maxInt(i32);
}

/// Object keys ignored when computing a schema's de-duplication cache key.
const skipped_cache_keys = std.StaticStringMap(void).initComptime(.{
    .{"title"},
    .{"default"},
    .{"description"},
    .{"examples"},
    .{"deprecated"},
    .{"readOnly"},
    .{"writeOnly"},
    .{"$comment"},
    .{"$schema"},
});

const UNSUPPORTED_ONE_OF_MESSAGE = "oneOf with overlapping or non-provably-disjoint branches cannot be represented exactly; falling back to anyOf semantics";

fn containsStr(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

fn hasOnlySchemaKeys(schema: ObjectMap, allowed: []const []const u8) bool {
    for (schema.keys()) |key| {
        if (!containsStr(allowed, key) and !skipped_cache_keys.has(key)) return false;
    }
    return true;
}

const supported_types = std.StaticStringMap(void).initComptime(.{
    .{"null"},
    .{"boolean"},
    .{"object"},
    .{"array"},
    .{"number"},
    .{"string"},
    .{"integer"},
});

fn normalizeTypeSet(arena: Allocator, value: Value) ?std.StringHashMapUnmanaged(void) {
    var result: std.StringHashMapUnmanaged(void) = .empty;
    switch (value) {
        .string => |ty| {
            if (!supported_types.has(ty)) return null;
            result.put(arena, ty, {}) catch return null;
        },
        .array => |types| {
            if (types.items.len == 0) return null;
            for (types.items) |item| {
                if (item != .string) return null;
                const ty = item.string;
                if (!supported_types.has(ty)) return null;
                result.put(arena, ty, {}) catch return null;
            }
        },
        else => return null,
    }
    return result;
}

fn isNumericValue(value: Value) bool {
    return switch (value) {
        .integer, .float, .number_string => true,
        else => false,
    };
}

fn isIntegerValue(value: Value) bool {
    return switch (value) {
        .integer => true,
        .float => |f| std.math.isFinite(f) and f == @trunc(f),
        else => false,
    };
}

/// JSON-number comparisons are deliberately conservative when either side was parsed as a
/// floating-point value. This matches upstream and avoids claiming `oneOf` disjointness
/// after a potentially lossy conversion.
fn jsonValuesMayOverlap(lhs: Value, rhs: Value) bool {
    if (isNumericValue(lhs) or isNumericValue(rhs)) {
        if (!isNumericValue(lhs) or !isNumericValue(rhs)) {
            return false;
        }
        return lhs == .integer and rhs == .integer and lhs.integer == rhs.integer;
    }
    if (lhs == .null and rhs == .null) return true;
    if (lhs == .bool and rhs == .bool) return lhs.bool == rhs.bool;
    if (lhs == .string and rhs == .string) return std.mem.eql(u8, lhs.string, rhs.string);
    if (lhs == .array and rhs == .array) {
        if (lhs.array.items.len != rhs.array.items.len) return false;
        for (lhs.array.items, rhs.array.items) |l, r| {
            if (!jsonValuesMayOverlap(l, r)) return false;
        }
        return true;
    }
    if (lhs == .object and rhs == .object) {
        if (lhs.object.count() != rhs.object.count()) return false;
        for (lhs.object.keys(), lhs.object.values()) |key, l| {
            const r = rhs.object.get(key) orelse return false;
            if (!jsonValuesMayOverlap(l, r)) return false;
        }
        return true;
    }
    return false;
}

fn valueMatchesType(value: Value, ty: []const u8) bool {
    if (std.mem.eql(u8, ty, "null")) return value == .null;
    if (std.mem.eql(u8, ty, "boolean")) return value == .bool;
    if (std.mem.eql(u8, ty, "string")) return value == .string;
    if (std.mem.eql(u8, ty, "integer")) return isIntegerValue(value);
    if (std.mem.eql(u8, ty, "number")) return isNumericValue(value);
    if (std.mem.eql(u8, ty, "array")) return value == .array;
    if (std.mem.eql(u8, ty, "object")) return value == .object;
    return false;
}

fn finiteValues(arena: Allocator, schema: ObjectMap) ?std.ArrayList(Value) {
    if (schema.get("const")) |value| {
        var out: std.ArrayList(Value) = .empty;
        out.append(arena, value) catch return null;
        return out;
    }
    const values = schema.get("enum") orelse return null;
    if (values != .array) return null;
    if (values.array.items.len == 0) return null;
    var out: std.ArrayList(Value) = .empty;
    for (values.array.items) |item| {
        out.append(arena, item) catch return null;
    }
    return out;
}

const OneOfArmProof = union(enum) {
    TypeSet: std.StringHashMapUnmanaged(void),
    FiniteValues: std.ArrayList(Value),
};

fn classifyOneOfArm(arena: Allocator, option: Value) ?OneOfArmProof {
    if (option != .object) return null;
    const schema = option.object;
    for ([_][]const u8{ "$ref", "anyOf", "allOf", "oneOf" }) |key| {
        if (schema.get(key) != null) return null;
    }
    if (finiteValues(arena, schema)) |values| {
        return .{ .FiniteValues = values };
    }
    if (!hasOnlySchemaKeys(schema, &[_][]const u8{"type"})) {
        return null;
    }
    const type_set = normalizeTypeSet(arena, schema.get("type") orelse return null) orelse return null;
    if (type_set.contains("object")) {
        return null;
    }
    return .{ .TypeSet = type_set };
}

fn typeSetsOverlap(lhs: *const std.StringHashMapUnmanaged(void), rhs: *const std.StringHashMapUnmanaged(void)) bool {
    var it = lhs.keyIterator();
    while (it.next()) |lhs_type| {
        if (rhs.contains(lhs_type.*)) return true;
        if ((std.mem.eql(u8, lhs_type.*, "integer") or std.mem.eql(u8, lhs_type.*, "number")) and
            (rhs.contains("integer") or rhs.contains("number")))
        {
            return true;
        }
    }
    return false;
}

fn finiteValuesOverlap(lhs: []const Value, rhs: []const Value) bool {
    for (lhs) |lhs_value| {
        for (rhs) |rhs_value| {
            if (jsonValuesMayOverlap(lhs_value, rhs_value)) return true;
        }
    }
    return false;
}

fn finiteValuesOverlapTypeSet(values: []const Value, type_set: *const std.StringHashMapUnmanaged(void)) bool {
    for (values) |value| {
        if (isNumericValue(value) and (type_set.contains("integer") or type_set.contains("number"))) {
            return true;
        }
        var it = type_set.keyIterator();
        while (it.next()) |ty| {
            if (valueMatchesType(value, ty.*)) return true;
        }
    }
    return false;
}

fn oneOfArmProofsAreDisjoint(lhs: *const OneOfArmProof, rhs: *const OneOfArmProof) bool {
    switch (lhs.*) {
        .TypeSet => |l| switch (rhs.*) {
            .TypeSet => |r| return !typeSetsOverlap(&l, &r),
            .FiniteValues => |r| return !finiteValuesOverlapTypeSet(r.items, &l),
        },
        .FiniteValues => |l| switch (rhs.*) {
            .TypeSet => |r| return !finiteValuesOverlapTypeSet(l.items, &r),
            .FiniteValues => |r| return !finiteValuesOverlap(l.items, r.items),
        },
    }
}

fn discriminatorValues(arena: Allocator, option: Value, discriminator_key: []const u8) ?std.ArrayList(Value) {
    if (option != .object) return null;
    const schema = option.object;
    for ([_][]const u8{ "$ref", "anyOf", "allOf", "oneOf" }) |key| {
        if (schema.get(key) != null) return null;
    }
    const type_value = schema.get("type") orelse return null;
    if (type_value != .string or !std.mem.eql(u8, type_value.string, "object")) return null;
    const required = schema.get("required") orelse return null;
    if (required != .array) return null;
    var requires_key = false;
    for (required.array.items) |value| {
        if (value == .string and std.mem.eql(u8, value.string, discriminator_key)) requires_key = true;
    }
    if (!requires_key) return null;
    const properties = schema.get("properties") orelse return null;
    if (properties != .object) return null;
    const property_schema = properties.object.get(discriminator_key) orelse return null;
    if (property_schema != .object) return null;
    return finiteValues(arena, property_schema.object);
}

fn discriminatorCandidates(arena: Allocator, option: Value) std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    if (option != .object) return out;
    const schema = option.object;
    const required_value = schema.get("required") orelse return out;
    if (required_value != .array) return out;
    const properties_value = schema.get("properties") orelse return out;
    if (properties_value != .object) return out;
    for (required_value.array.items) |value| {
        if (value != .string) continue;
        const key = value.string;
        if (properties_value.object.get(key)) |prop| {
            if (prop == .object and finiteValues(arena, prop.object) != null) {
                out.append(arena, key) catch return out;
            }
        }
    }
    return out;
}

fn tryProveDiscriminatorOneOf(arena: Allocator, options: []const Value) bool {
    if (options.len == 0) return false;
    const first = options[0];
    var candidates = discriminatorCandidates(arena, first);
    defer candidates.deinit(arena);
    for (candidates.items) |key| {
        var branch_values: ?std.ArrayList(std.ArrayList(Value)) = .empty;
        var failed = false;
        for (options) |option| {
            if (branch_values == null) break;
            if (discriminatorValues(arena, option, key)) |values| {
                branch_values.?.append(arena, values) catch {
                    failed = true;
                    break;
                };
            } else {
                branch_values = null;
            }
        }
        if (failed) return false;
        if (branch_values) |values| {
            var all_disjoint = true;
            for (0..values.items.len) |lhs| {
                for (lhs + 1..values.items.len) |rhs| {
                    if (finiteValuesOverlap(values.items[lhs].items, values.items[rhs].items)) {
                        all_disjoint = false;
                    }
                }
            }
            if (all_disjoint) return true;
        }
    }
    return false;
}

fn tryProveTypeOrFiniteOneOf(arena: Allocator, options: []const Value) bool {
    var proofs: std.ArrayList(OneOfArmProof) = .empty;
    defer proofs.deinit(arena);
    for (options) |option| {
        const proof = classifyOneOfArm(arena, option) orelse return false;
        proofs.append(arena, proof) catch return false;
    }
    for (0..proofs.items.len) |lhs| {
        for (lhs + 1..proofs.items.len) |rhs| {
            if (!oneOfArmProofsAreDisjoint(&proofs.items[lhs], &proofs.items[rhs])) return false;
        }
    }
    return true;
}

fn tryProvePairwiseDisjointOneOf(arena: Allocator, options: []const Value) bool {
    return options.len != 0 and
        (tryProveDiscriminatorOneOf(arena, options) or tryProveTypeOrFiniteOneOf(arena, options));
}

/// Deep-clones a JSON value into `allocator`.
pub fn valueClone(allocator: Allocator, value: Value) Allocator.Error!Value {
    return switch (value) {
        .null, .bool, .integer, .float => value,
        .number_string => |s| Value{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| Value{ .string = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            var out = std.json.Array.init(allocator);
            try out.ensureTotalCapacity(arr.items.len);
            for (arr.items) |item| out.appendAssumeCapacity(try valueClone(allocator, item));
            break :blk Value{ .array = out };
        },
        .object => |map| blk: {
            var out = try ObjectMap.init(allocator, &.{}, &.{});
            try out.ensureTotalCapacity(allocator, map.count());
            for (map.keys(), map.values()) |k, v| {
                out.putAssumeCapacity(try allocator.dupe(u8, k), try valueClone(allocator, v));
            }
            break :blk Value{ .object = out };
        },
    };
}

/// Deep structural equality of two JSON values.
pub fn valueEql(lhs: Value, rhs: Value) bool {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
    return switch (lhs) {
        .null => true,
        .bool => lhs.bool == rhs.bool,
        .integer => lhs.integer == rhs.integer,
        .float => lhs.float == rhs.float,
        .number_string => std.mem.eql(u8, lhs.number_string, rhs.number_string),
        .string => std.mem.eql(u8, lhs.string, rhs.string),
        .array => blk: {
            if (lhs.array.items.len != rhs.array.items.len) break :blk false;
            for (lhs.array.items, rhs.array.items) |l, r| {
                if (!valueEql(l, r)) break :blk false;
            }
            break :blk true;
        },
        .object => blk: {
            if (lhs.object.count() != rhs.object.count()) break :blk false;
            for (lhs.object.keys(), lhs.object.values()) |k, l| {
                const r = rhs.object.get(k) orelse break :blk false;
                if (!valueEql(l, r)) break :blk false;
            }
            break :blk true;
        },
    };
}

/// Returns the keys of `map` sorted byte-lexicographically (`serde_json` `BTreeMap` order).
pub fn sortedKeys(allocator: Allocator, map: ObjectMap) Allocator.Error![][]const u8 {
    const keys = try allocator.alloc([]const u8, map.count());
    @memcpy(keys, map.keys());
    std.mem.sort([]const u8, keys, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return keys;
}

/// Serializes `value` as compact JSON matching the reference implementation's schema literal
/// spelling: integral doubles below 2^53 without a fraction (`1.0` -> `1`), shortest exact
/// decimal/scientific representation for other doubles, DEL (`0x7F`) escaped as `\u007f`,
/// and object keys in `ObjectMap` insertion order (`serde_json` `preserve_order`).
pub fn serializeJson(allocator: Allocator, value: Value) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try serializeJsonInto(allocator, &out, value);
    return out.toOwnedSlice(allocator);
}

fn writeNumber(allocator: Allocator, out: *std.ArrayList(u8), int: ?i64, double: ?f64, raw: ?[]const u8) Allocator.Error!void {
    if (int) |integer| {
        try out.print(allocator, "{d}", .{integer});
        return;
    }
    if (double) |double_value| {
        if (@abs(double_value) < 9007199254740992.0 and double_value == @trunc(double_value)) {
            const text = try range_regex.formatFixed(allocator, double_value, 0);
            defer allocator.free(text);
            try out.appendSlice(allocator, text);
            return;
        }
        const abs_val = @abs(double_value);
        if (abs_val == 0.0) {
            try out.appendSlice(allocator, if (std.math.signbit(double_value)) "-0" else "0");
            return;
        }
        if (abs_val >= 1e-4 and abs_val < 1e16) {
            var dec_buf: [std.fmt.float.bufferSize(.decimal, f64)]u8 = undefined;
            const dec = std.fmt.float.render(&dec_buf, double_value, .{ .mode = .decimal }) catch unreachable;
            try out.appendSlice(allocator, dec);
        } else {
            var sci_buf: [std.fmt.float.bufferSize(.scientific, f64)]u8 = undefined;
            const sci = std.fmt.float.render(&sci_buf, double_value, .{ .mode = .scientific }) catch unreachable;
            try out.appendSlice(allocator, sci);
        }
        return;
    }
    try out.appendSlice(allocator, raw orelse "");
}

fn serializeJsonInto(allocator: Allocator, out: *std.ArrayList(u8), value: Value) Allocator.Error!void {
    switch (value) {
        .null => try out.appendSlice(allocator, "null"),
        .bool => |flag| try out.appendSlice(allocator, if (flag) "true" else "false"),
        .integer => |n| try out.print(allocator, "{d}", .{n}),
        .float => |f| try writeNumber(allocator, out, null, f, null),
        .number_string => |s| try writeNumber(allocator, out, null, null, s),
        .string => |text| {
            try out.append(allocator, '"');
            var view = std.unicode.Utf8View.initUnchecked(text).iterator();
            while (view.nextCodepoint()) |character| {
                const c: u21 = character;
                switch (c) {
                    '"' => try out.appendSlice(allocator, "\\\""),
                    '\\' => try out.appendSlice(allocator, "\\\\"),
                    0x8 => try out.appendSlice(allocator, "\\b"),
                    0xc => try out.appendSlice(allocator, "\\f"),
                    '\n' => try out.appendSlice(allocator, "\\n"),
                    '\r' => try out.appendSlice(allocator, "\\r"),
                    '\t' => try out.appendSlice(allocator, "\\t"),
                    else => {
                        if (c < ' ' or c == 0x7f) {
                            try out.print(allocator, "\\u{x:0>4}", .{c});
                        } else {
                            var utf8_buf: [4]u8 = undefined;
                            const len = std.unicode.utf8Encode(c, &utf8_buf) catch unreachable;
                            try out.appendSlice(allocator, utf8_buf[0..len]);
                        }
                    },
                }
            }
            try out.append(allocator, '"');
        },
        .array => |items| {
            try out.append(allocator, '[');
            for (items.items, 0..) |item, index| {
                if (index != 0) try out.append(allocator, ',');
                try serializeJsonInto(allocator, out, item);
            }
            try out.append(allocator, ']');
        },
        .object => |members| {
            try out.append(allocator, '{');
            for (members.keys(), members.values(), 0..) |key, member, index| {
                if (index != 0) try out.append(allocator, ',');
                try serializeJsonInto(allocator, out, Value{ .string = key });
                try out.append(allocator, ':');
                try serializeJsonInto(allocator, out, member);
            }
            try out.append(allocator, '}');
        },
    }
}

/// The JSON-schema `format` -> regex table. Recognized formats take precedence over
/// `minLength`/`maxLength`.
pub fn jsonFormatToRegexPattern(arena: Allocator, format: []const u8) Allocator.Error!?[]u8 {
    const FormatKind = enum {
        email,
        date,
        time,
        date_time,
        duration,
        ipv4,
        ipv6,
        hostname,
        uuid,
        uri,
        uri_reference,
        uri_template,
        json_pointer,
        relative_json_pointer,
    };
    const format_map = std.StaticStringMap(FormatKind).initComptime(.{
        .{ "email", .email },
        .{ "date", .date },
        .{ "time", .time },
        .{ "date-time", .date_time },
        .{ "duration", .duration },
        .{ "ipv4", .ipv4 },
        .{ "ipv6", .ipv6 },
        .{ "hostname", .hostname },
        .{ "uuid", .uuid },
        .{ "uri", .uri },
        .{ "uri-reference", .uri_reference },
        .{ "uri-template", .uri_template },
        .{ "json-pointer", .json_pointer },
        .{ "relative-json-pointer", .relative_json_pointer },
    });
    const kind = format_map.get(format) orelse return null;
    switch (kind) {
        .email => {
            const atext = "[\\w!#$%&'*+/=?^`{|}~-]";
            const dot_string = try std.fmt.allocPrint(arena, "({s}+(\\.{s}+)*)", .{ atext, atext });
            const quoted_string = "\\\\\"(\\\\[\\x20-\\x7E]|[\\x20\\x21\\x23-\\x5B\\x5D-\\x7E])*\\\\\"";
            const domain = "([A-Za-z0-9]([\\-A-Za-z0-9]*[A-Za-z0-9])?)((\\.[A-Za-z0-9][\\-A-Za-z0-9]*[A-Za-z0-9])*)";
            return try std.fmt.allocPrint(arena, "^({s}|{s})@{s}$", .{ dot_string, quoted_string, domain });
        },
        .date => return try arena.dupe(u8, "^(\\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[1-2]\\d|3[01]))$"),
        .time => return try arena.dupe(u8, "^([01]\\d|2[0-3]):[0-5]\\d:([0-5]\\d|60)(\\.\\d+)?(Z|[+-]([01]\\d|2[0-3]):[0-5]\\d)$"),
        .date_time => return try arena.dupe(u8, "^(\\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[1-2]\\d|3[01]))T([01]\\d|2[0-3]):[0-5]\\d:([0-5]\\d|60)(\\.\\d+)?(Z|[+-]([01]\\d|2[0-3]):[0-5]\\d)$"),
        .duration => return try arena.dupe(u8, "^P((\\d+D|\\d+M(\\d+D)?|\\d+Y(\\d+M(\\d+D)?)?)(T(\\d+S|\\d+M(\\d+S)?|\\d+H(\\d+M(\\d+S)?)?))?|T(\\d+S|\\d+M(\\d+S)?|\\d+H(\\d+M(\\d+S)?)?)|\\d+W)$"),
        .ipv4 => {
            const decbyte = "(25[0-5]|2[0-4]\\d|[0-1]?\\d?\\d)";
            return try std.fmt.allocPrint(arena, "^({s}\\.){{3}}{s}$", .{ decbyte, decbyte });
        },
        .ipv6 => return try arena.dupe(u8, "(([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9]))"),
        .hostname => return try arena.dupe(u8, "^([a-z0-9]([a-z0-9-]*[a-z0-9])?)(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$"),
        .uuid => return try arena.dupe(u8, "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"),
        .uri => {
            const schema_pat = "[a-zA-Z][a-zA-Z+\\.-]*";
            const pchar = "([\\w\\.~!$&'()*+,;=:@-]|%[0-9A-Fa-f][0-9A-Fa-f])";
            const query_fragment_char = "([\\w\\.~!$&'()*+,;=:@/\\?-]|%[0-9A-Fa-f][0-9A-Fa-f])*";
            const query = try std.fmt.allocPrint(arena, "(\\?{s})?", .{query_fragment_char});
            const fragment = try std.fmt.allocPrint(arena, "(#{s})?", .{query_fragment_char});
            const path_abempty = try std.fmt.allocPrint(arena, "({s}*)*", .{pchar});
            const path_absolute_rootless_empty = try std.fmt.allocPrint(arena, "/?({s}+({s}*)*)?", .{ pchar, path_abempty });
            const userinfo = "([\\w\\.~!$&'()*+,;=:-]|%[0-9A-Fa-f][0-9A-Fa-f])*";
            const host = "([\\w\\.~!$&'()*+,;=-]|%[0-9A-Fa-f][0-9A-Fa-f])*";
            const authority = try std.fmt.allocPrint(arena, "({s}@)?{s}(:\\d*)?", .{ userinfo, host });
            const hier_part = try std.fmt.allocPrint(arena, "(//{s}{s}|{s})", .{ authority, path_abempty, path_absolute_rootless_empty });
            return try std.fmt.allocPrint(arena, "^{s}:{s}{s}{s}$", .{ schema_pat, hier_part, query, fragment });
        },
        .uri_reference => {
            const pchar = "([\\w\\.~!$&'()*+,;=:@-]|%[0-9A-Fa-f][0-9A-Fa-f])";
            const query_fragment_char = "([\\w\\.~!$&'()*+,;=:@/\\?-]|%[0-9A-Fa-f][0-9A-Fa-f])*";
            const query = try std.fmt.allocPrint(arena, "(\\?{s})?", .{query_fragment_char});
            const fragment = try std.fmt.allocPrint(arena, "(#{s})?", .{query_fragment_char});
            const path_abempty = try std.fmt.allocPrint(arena, "({s}*)*", .{pchar});
            const path_absolute = try std.fmt.allocPrint(arena, "/({s}+({s}*)*)?", .{ pchar, path_abempty });
            const segment_nz_nc = "([\\w\\.~!$&'()*+,;=@-]|%[0-9A-Fa-f][0-9A-Fa-f])+";
            const path_noscheme = try std.fmt.allocPrint(arena, "{s}({s}*)*", .{ segment_nz_nc, pchar });
            const userinfo = "([\\w\\.~!$&'()*+,;=:-]|%[0-9A-Fa-f][0-9A-Fa-f])*";
            const host = "([\\w\\.~!$&'()*+,;=-]|%[0-9A-Fa-f][0-9A-Fa-f])*";
            const authority = try std.fmt.allocPrint(arena, "({s}@)?{s}(:\\d*)?", .{ userinfo, host });
            const relative_part = try std.fmt.allocPrint(arena, "(//{s}{s}|{s}|{s})?", .{ authority, path_abempty, path_absolute, path_noscheme });
            return try std.fmt.allocPrint(arena, "^{s}{s}{s}$", .{ relative_part, query, fragment });
        },
        .uri_template => {
            const literals = "([\\x21\\x23-\\x24\\x26\\x28-\\x3B\\x3D\\x3F-\\x5B\\x5D\\x5F\\x61-\\x7A\\x7E]|%[0-9A-Fa-f][0-9A-Fa-f])";
            const op = "[+#\\./;\\?&=,!@|]";
            const varchar = "(\\w|%[0-9A-Fa-f][0-9A-Fa-f])";
            const varname = try std.fmt.allocPrint(arena, "{s}(\\.?{s})*", .{ varchar, varchar });
            const varspec = try std.fmt.allocPrint(arena, "{s}(:[1-9]\\d?\\d?\\d?|\\*)?", .{varname});
            const variable_list = try std.fmt.allocPrint(arena, "{s}({s})*", .{ varspec, varspec });
            const expression = try std.fmt.allocPrint(arena, "\\{{({s})?{s}\\}}", .{ op, variable_list });
            return try std.fmt.allocPrint(arena, "^({s}|{s})*$", .{ literals, expression });
        },
        .json_pointer => return try arena.dupe(u8, "^(/([\\x00-\\x2E]|[\\x30-\\x7D]|[\\x7F-\\U0010FFFF]|~[01])*)*$"),
        .relative_json_pointer => return try arena.dupe(u8, "^(0|[1-9][0-9]*)(#|(/([\\x00-\\x2E]|[\\x30-\\x7D]|[\\x7F-\\U0010FFFF]|~[01])*)*)$"),
    }
}

/// Parses JSON schemas into `SchemaSpec` trees, resolving `$ref`s against the root.
/// All spec nodes live in the parser's arena; `deinit` releases them.
pub const SchemaParser = struct {
    gpa: Allocator,
    arena_state: ArenaAllocator,
    arena: Allocator,
    strict_mode: bool,
    root_schema: Value,
    ref_cache: std.StringHashMapUnmanaged(SchemaSpecPtr),
    schema_cache: std.StringHashMapUnmanaged(SchemaSpecPtr),

    /// Takes a deep clone of `root_schema` into the parser's arena.
    pub fn init(gpa: Allocator, root_schema: Value, strict_mode: bool) Allocator.Error!*SchemaParser {
        const self = try gpa.create(SchemaParser);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .arena_state = ArenaAllocator.init(gpa),
            .arena = undefined,
            .strict_mode = strict_mode,
            .root_schema = undefined,
            .ref_cache = .empty,
            .schema_cache = .empty,
        };
        self.arena = self.arena_state.allocator();
        errdefer self.arena_state.deinit();
        self.root_schema = try valueClone(self.arena, root_schema);
        return self;
    }

    pub fn deinit(self: *SchemaParser) void {
        self.arena_state.deinit();
        self.gpa.destroy(self);
    }

    /// Deterministic cache key for `value` (object keys sorted lexicographically, cosmetic keys dropped).
    fn computeCacheKey(arena: Allocator, value: Value) Allocator.Error![]u8 {
        switch (value) {
            .object => |map| {
                var filtered: std.ArrayList([]const u8) = .empty;
                defer filtered.deinit(arena);
                for (map.keys()) |k| {
                    if (!skipped_cache_keys.has(k)) try filtered.append(arena, k);
                }
                std.mem.sort([]const u8, filtered.items, {}, struct {
                    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                        return std.mem.order(u8, a, b) == .lt;
                    }
                }.lessThan);
                var result: std.ArrayList(u8) = .empty;
                errdefer result.deinit(arena);
                try result.append(arena, '{');
                for (filtered.items, 0..) |k, i| {
                    if (i != 0) try result.append(arena, ',');
                    try result.append(arena, '"');
                    try result.appendSlice(arena, k);
                    try result.appendSlice(arena, "\":");
                    try result.appendSlice(arena, try computeCacheKey(arena, map.get(k).?));
                }
                try result.append(arena, '}');
                return result.toOwnedSlice(arena);
            },
            .array => |arr| {
                var result: std.ArrayList(u8) = .empty;
                errdefer result.deinit(arena);
                try result.append(arena, '[');
                for (arr.items, 0..) |item, i| {
                    if (i != 0) try result.append(arena, ',');
                    try result.appendSlice(arena, try computeCacheKey(arena, item));
                }
                try result.append(arena, ']');
                return result.toOwnedSlice(arena);
            },
            else => return serializeJson(arena, value),
        }
    }

    fn make(self: *SchemaParser, variant: SchemaSpecVariant, cache_key: []const u8) Allocator.Error!SchemaSpecPtr {
        return SchemaSpec.make(self.arena, variant, try self.arena.dupe(u8, cache_key));
    }

    pub fn parse(
        self: *SchemaParser,
        schema: Value,
        default_type: ?[]const u8,
        diag: ?*Diagnostic,
    ) SchemaError!SchemaSpecPtr {
        const arena = self.arena;
        const cache_key = try computeCacheKey(arena, schema);
        if (self.schema_cache.get(cache_key)) |spec| {
            return spec;
        }

        if (schema == .bool) {
            if (!schema.bool) {
                return failStatic(error.UnsatisfiableSchema, diag, "Schema 'false' cannot accept any value");
            }
            const spec = try self.make(.{ .Any = {} }, cache_key);
            try self.schema_cache.put(arena, try arena.dupe(u8, cache_key), spec);
            return spec;
        }

        if (schema != .object) {
            const printed = try serializeJson(arena, schema);
            defer arena.free(printed);
            return failFmt(error.InvalidSchema, diag, self.gpa, "Schema should be an object or bool, but got {s}", .{printed});
        }
        const obj = schema.object;

        var variant: SchemaSpecVariant = undefined;
        if (obj.get("$ref") != null) {
            variant = .{ .Ref = try self.parseRef(obj, diag) };
        } else if (obj.get("const") != null) {
            variant = .{ .Const = try self.parseConst(obj) };
        } else if (obj.get("enum") != null) {
            variant = .{ .Enum = try self.parseEnum(obj, diag) };
        } else if (obj.get("anyOf") != null) {
            variant = .{ .AnyOf = try self.parseAnyOf(obj, diag) };
        } else if (obj.get("oneOf") != null) {
            const one_of = obj.get("oneOf").?;
            if (one_of != .array) {
                return failStatic(error.InvalidSchema, diag, "oneOf must be an array");
            }
            if (!tryProvePairwiseDisjointOneOf(arena, one_of.array.items)) {
                log.warn("{s}", .{UNSUPPORTED_ONE_OF_MESSAGE});
            }
            variant = .{ .AnyOf = try self.parseAnyOf(obj, diag) };
        } else if (obj.get("allOf") != null) {
            variant = .{ .AllOf = try self.parseAllOf(obj, diag) };
        } else if (obj.get("type") != null or default_type != null) {
            const type_value = obj.get("type");
            if (type_value != null and type_value.? == .array) {
                variant = .{ .TypeArray = try self.parseTypeArray(obj, diag) };
            } else {
                if (type_value != null and type_value.? != .string) {
                    return failStatic(error.InvalidSchema, diag, "Type should be a string");
                }
                const ty = if (type_value != null) type_value.?.string else default_type.?;
                if (std.mem.eql(u8, ty, "integer")) {
                    variant = .{ .Integer = try parseInteger(obj, diag) };
                } else if (std.mem.eql(u8, ty, "number")) {
                    variant = .{ .Number = try parseNumber(obj, diag) };
                } else if (std.mem.eql(u8, ty, "string")) {
                    variant = .{ .String = try parseString(obj, diag, self.gpa, arena) };
                } else if (std.mem.eql(u8, ty, "boolean")) {
                    variant = .{ .Boolean = {} };
                } else if (std.mem.eql(u8, ty, "null")) {
                    variant = .{ .Null = {} };
                } else if (std.mem.eql(u8, ty, "array")) {
                    variant = .{ .Array = try self.parseArray(obj, diag) };
                } else if (std.mem.eql(u8, ty, "object")) {
                    variant = .{ .Object = try self.parseObject(obj, diag) };
                } else {
                    return failFmt(error.InvalidSchema, diag, self.gpa, "Unsupported type \"{s}\"", .{ty});
                }
            }
        } else if (obj.get("properties") != null or obj.get("additionalProperties") != null or
            obj.get("unevaluatedProperties") != null)
        {
            variant = .{ .Object = try self.parseObject(obj, diag) };
        } else if (obj.get("items") != null or obj.get("prefixItems") != null or obj.get("unevaluatedItems") != null) {
            variant = .{ .Array = try self.parseArray(obj, diag) };
        } else {
            variant = .{ .Any = {} };
        }
        const result: SchemaSpecPtr = try self.make(variant, cache_key);

        try self.schema_cache.put(arena, try arena.dupe(u8, cache_key), result);
        return result;
    }

    fn checkIntegerBound(value: Value, diag: ?*Diagnostic) SchemaError!i64 {
        if (value == .integer) {
            return value.integer;
        }
        if (value != .float) {
            return failStatic(error.InvalidSchema, diag, "Value must be a number");
        }
        const val = value.float;
        if (val != @trunc(val)) {
            return failStatic(error.InvalidSchema, diag, "Integer constraint must be a whole number");
        }
        // A bound outside int64 is parsed as a double; +-2^63 is where it rounds onto the edge
        // of the int64 range, so it must be rejected rather than saturated.
        const i64_min_f: f64 = @floatFromInt(std.math.minInt(i64));
        const i64_max_f: f64 = @floatFromInt(std.math.maxInt(i64));
        if (val == i64_min_f) {
            return failStatic(error.InvalidSchema, diag, "Integer exceeds minimum limit due to precision loss at 64-bit boundary");
        }
        if (val >= i64_max_f) {
            return failStatic(error.InvalidSchema, diag, if (val == i64_max_f)
                "Integer exceeds maximum limit due to precision loss at 64-bit boundary"
            else
                "Integer exceeds maximum limit");
        }
        if (val < i64_min_f) {
            return failStatic(error.InvalidSchema, diag, "Integer exceeds minimum limit");
        }
        return @intFromFloat(val);
    }

    fn parseInteger(schema: ObjectMap, diag: ?*Diagnostic) SchemaError!IntegerSpec {
        const INTEGER_MULTIPLE_OF_MAX: f64 = 1024.0;
        const INTEGER_MULTIPLE_OF_RANGE_WIDTH_MAX: i128 = 10_000;

        var spec = IntegerSpec{};
        if (schema.get("multipleOf")) |value| {
            if (value != .float and value != .integer) {
                return failStatic(error.InvalidSchema, diag, "Value must be a number");
            }
            const multiple_of = numberAsF64(value);
            if (multiple_of <= 0.0) {
                return failStatic(error.InvalidSchema, diag, "multipleOf must be greater than 0");
            }
            if (multiple_of != @trunc(multiple_of)) {
                log.warn("multipleOf for type:integer must be an integer; ignoring multipleOf", .{});
            } else if (multiple_of > INTEGER_MULTIPLE_OF_MAX) {
                log.warn("multipleOf for type:integer must be > 0 and <= 1024; ignoring multipleOf", .{});
            } else {
                spec.multiple_of = @intFromFloat(multiple_of);
            }
        }
        if (schema.get("minimum")) |v| {
            spec.minimum = try checkIntegerBound(v, diag);
        }
        if (schema.get("maximum")) |v| {
            spec.maximum = try checkIntegerBound(v, diag);
        }
        if (schema.get("exclusiveMinimum")) |v| {
            const val = try checkIntegerBound(v, diag);
            if (val == std.math.maxInt(i64)) {
                return failStatic(error.UnsatisfiableSchema, diag, "exclusiveMinimum would cause integer overflow");
            }
            spec.exclusive_minimum = val;
        }
        if (schema.get("exclusiveMaximum")) |v| {
            const val = try checkIntegerBound(v, diag);
            if (val == std.math.minInt(i64)) {
                return failStatic(error.UnsatisfiableSchema, diag, "exclusiveMaximum would cause integer underflow");
            }
            spec.exclusive_maximum = val;
        }

        const effective = spec.effectiveRange();
        const effective_min = effective.start orelse std.math.minInt(i64);
        const effective_max = effective.end orelse std.math.maxInt(i64);
        if (effective_min > effective_max) {
            return failStatic(error.UnsatisfiableSchema, diag, "Invalid range: minimum greater than maximum");
        }
        if (spec.multiple_of) |multiple_of| {
            const has_lower_bound = effective.start != null;
            const has_upper_bound = effective.end != null;
            if (has_lower_bound or has_upper_bound) {
                const range_width: i128 = @as(i128, effective_max) - @as(i128, effective_min) + 1;
                if (!has_lower_bound or !has_upper_bound or range_width > INTEGER_MULTIPLE_OF_RANGE_WIDTH_MAX) {
                    log.warn("range + multipleOf combination not yet supported; ignoring multipleOf", .{});
                    spec.multiple_of = null;
                } else {
                    var has_multiple = false;
                    var probe = effective_min;
                    while (probe <= effective_max) : (probe += 1) {
                        if (@rem(probe, multiple_of) == 0) {
                            has_multiple = true;
                            break;
                        }
                    }
                    if (!has_multiple) {
                        return failStatic(error.UnsatisfiableSchema, diag, "range contains no multipleOf value");
                    }
                }
            }
        }
        return spec;
    }

    fn numberAsF64(value: Value) f64 {
        return switch (value) {
            .integer => |n| @floatFromInt(n),
            .float => |f| f,
            .number_string => |s| std.fmt.parseFloat(f64, s) catch 0.0,
            else => unreachable,
        };
    }

    fn parseNumber(schema: ObjectMap, diag: ?*Diagnostic) SchemaError!NumberSpec {
        var spec = NumberSpec{};
        if (schema.get("multipleOf")) |value| {
            if (value != .float and value != .integer) {
                return failStatic(error.InvalidSchema, diag, "Value must be a number");
            }
            const multiple_of = numberAsF64(value);
            if (multiple_of <= 0.0) {
                return failStatic(error.InvalidSchema, diag, "multipleOf must be greater than 0");
            }
            log.warn("multipleOf is not supported for type:number; ignoring multipleOf", .{});
        }

        const getDouble = struct {
            fn call(v: Value, d: ?*Diagnostic) SchemaError!f64 {
                if (v == .float or v == .integer) return numberAsF64(v);
                return failStatic(error.InvalidSchema, d, "Value must be a number");
            }
        }.call;

        if (schema.get("minimum")) |v| {
            spec.minimum = try getDouble(v, diag);
        }
        if (schema.get("maximum")) |v| {
            spec.maximum = try getDouble(v, diag);
        }
        if (schema.get("exclusiveMinimum")) |v| {
            spec.exclusive_minimum = try getDouble(v, diag);
        }
        if (schema.get("exclusiveMaximum")) |v| {
            spec.exclusive_maximum = try getDouble(v, diag);
        }

        const min = spec.minimum;
        const max = spec.maximum;
        const ex_min = spec.exclusive_minimum;
        const ex_max = spec.exclusive_maximum;
        const empty_range =
            (if (min != null and max != null) min.? > max.? else false) or
            (if (min != null and ex_max != null) min.? >= ex_max.? else false) or
            (if (ex_min != null and max != null) ex_min.? >= max.? else false) or
            (if (ex_min != null and ex_max != null) ex_min.? >= ex_max.? else false);
        if (empty_range) {
            return failStatic(error.UnsatisfiableSchema, diag, "Invalid range: empty range");
        }
        return spec;
    }

    fn parseString(schema: ObjectMap, diag: ?*Diagnostic, gpa: Allocator, arena: Allocator) SchemaError!StringSpec {
        var spec = StringSpec{};
        if (schema.get("format")) |v| {
            if (v == .string) spec.format = try arena.dupe(u8, v.string);
        }
        if (schema.get("pattern")) |v| {
            if (v == .string) spec.pattern = try arena.dupe(u8, v.string);
        }
        if (schema.get("minLength")) |v| {
            if (v != .integer or v.integer > std.math.maxInt(i32)) {
                return failFmt(error.InvalidSchema, diag, gpa, "minLength must be an integer not exceeding {d}", .{std.math.maxInt(i32)});
            }
            spec.min_length = @intCast(v.integer);
        }
        if (schema.get("maxLength")) |v| {
            if (v != .integer) {
                return failStatic(error.InvalidSchema, diag, "maxLength must be an integer");
            }
            if (std.math.cast(i32, v.integer)) |n| {
                spec.max_length = n;
            }
        }
        if (spec.max_length != -1 and spec.min_length > spec.max_length) {
            return failFmt(error.UnsatisfiableSchema, diag, gpa, "minLength {d} is greater than maxLength {d}", .{ spec.min_length, spec.max_length });
        }
        if (spec.min_length != 0 or spec.max_length != -1) {
            const generative: ?[]const u8 = if (spec.pattern != null)
                "pattern"
            else blk: {
                if (spec.format) |format| {
                    if (jsonFormatToRegexPattern(arena, format) catch null != null) {
                        break :blk "format";
                    }
                }
                break :blk null;
            };
            if (generative) |g| {
                log.warn("{s} combined with minLength/maxLength is not supported; ignoring minLength/maxLength", .{g});
            }
        }
        return spec;
    }

    fn parseArray(self: *SchemaParser, schema: ObjectMap, diag: ?*Diagnostic) SchemaError!ArraySpec {
        var spec = ArraySpec{};

        if (schema.get("prefixItems")) |prefix| {
            if (prefix != .array) {
                return failStatic(error.InvalidSchema, diag, "prefixItems must be an array");
            }
            for (prefix.array.items) |item| {
                if (item == .bool and item.bool == false) {
                    return failStatic(error.UnsatisfiableSchema, diag, "prefixItems contains false");
                } else if (item != .object) {
                    return failStatic(error.InvalidSchema, diag, "prefixItems must be an array of objects or booleans");
                }
                const parsed = try self.parse(item, null, diag);
                try spec.prefix_items.append(self.arena, parsed);
            }
        }

        if (schema.get("items")) |items| {
            if (items != .bool and items != .object) {
                return failStatic(error.InvalidSchema, diag, "items must be a boolean or an object");
            }
            if (items == .bool and items.bool == false) {
                spec.allow_additional_items = false;
            } else {
                spec.allow_additional_items = true;
                spec.additional_items = try self.parse(items, null, diag);
            }
        } else if (schema.get("unevaluatedItems")) |uneval| {
            if (uneval != .bool and uneval != .object) {
                return failStatic(error.InvalidSchema, diag, "unevaluatedItems must be a boolean or an object");
            }
            if (uneval == .bool and uneval.bool == false) {
                spec.allow_additional_items = false;
            } else {
                spec.allow_additional_items = true;
                spec.additional_items = try self.parse(uneval, null, diag);
            }
        } else if (!self.strict_mode) {
            spec.allow_additional_items = true;
            spec.additional_items = try self.make(.{ .Any = {} }, "");
        } else {
            spec.allow_additional_items = false;
        }

        if (schema.get("minItems")) |v| {
            if (v != .integer) {
                return failStatic(error.InvalidSchema, diag, "minItems must be an integer");
            }
            spec.min_items = @max(v.integer, 0);
        }
        if (schema.get("minContains")) |v| {
            if (v != .integer) {
                return failStatic(error.InvalidSchema, diag, "minContains must be an integer");
            }
            spec.min_items = @max(spec.min_items, v.integer);
        }
        if (schema.get("maxItems")) |v| {
            if (v != .integer or v.integer < 0) {
                return failStatic(error.InvalidSchema, diag, "maxItems must be a non-negative integer");
            }
            spec.max_items = v.integer;
        }
        if (spec.min_items > std.math.maxInt(i32)) {
            return failFmt(error.InvalidSchema, diag, self.gpa, "minItems and minContains must not exceed {d}", .{std.math.maxInt(i32)});
        }
        if (spec.max_items > std.math.maxInt(i32)) {
            spec.max_items = -1;
        }

        if (spec.max_items != -1 and spec.min_items > spec.max_items) {
            return failFmt(error.UnsatisfiableSchema, diag, self.gpa, "minItems is greater than maxItems: {d} > {d}", .{ spec.min_items, spec.max_items });
        }
        const prefix_size: i64 = @intCast(spec.prefix_items.items.len);
        if (spec.max_items != -1 and spec.max_items < prefix_size) {
            return failFmt(error.UnsatisfiableSchema, diag, self.gpa, "maxItems is less than the number of prefixItems: {d} < {d}", .{ spec.max_items, prefix_size });
        }
        if (!spec.allow_additional_items) {
            if (prefix_size < spec.min_items) {
                return failFmt(error.UnsatisfiableSchema, diag, self.gpa, "minItems is greater than the number of prefixItems, but additional items are not allowed: {d} > {d}", .{ spec.min_items, prefix_size });
            }
            if (spec.max_items != -1 and prefix_size > spec.max_items) {
                return failFmt(error.UnsatisfiableSchema, diag, self.gpa, "maxItems is less than the number of prefixItems, but additional items are not allowed: {d} < {d}", .{ spec.max_items, prefix_size });
            }
        }
        return spec;
    }

    fn parseObject(self: *SchemaParser, schema: ObjectMap, diag: ?*Diagnostic) SchemaError!ObjectSpec {
        const arena = self.arena;
        var spec = ObjectSpec{};

        if (schema.get("properties")) |props| {
            if (props != .object) {
                return failStatic(error.InvalidSchema, diag, "properties must be an object");
            }
            for (props.object.keys(), props.object.values()) |key, value| {
                const parsed = try self.parse(value, null, diag);
                try spec.properties.append(arena, .{
                    .name = try arena.dupe(u8, key),
                    .schema = parsed,
                });
            }
        }

        if (schema.get("required")) |req| {
            if (req != .array) {
                return failStatic(error.InvalidSchema, diag, "required must be an array");
            }
            for (req.array.items) |r| {
                if (r == .string) {
                    try spec.required.put(arena, try arena.dupe(u8, r.string), {});
                }
            }
        }

        if (schema.get("patternProperties")) |pp| {
            if (pp != .object) {
                return failStatic(error.InvalidSchema, diag, "patternProperties must be an object");
            }
            for (pp.object.keys(), pp.object.values()) |key, value| {
                const parsed = try self.parse(value, null, diag);
                try spec.pattern_properties.append(arena, .{
                    .pattern = try arena.dupe(u8, key),
                    .schema = parsed,
                });
            }
        }

        if (schema.get("propertyNames")) |pn| {
            if (pn != .object) {
                return failStatic(error.InvalidSchema, diag, "propertyNames must be an object");
            }
            if (pn.object.get("type")) |t| {
                if (t == .string and !std.mem.eql(u8, t.string, "string")) {
                    return failStatic(error.UnsatisfiableSchema, diag, "propertyNames must be an object that validates string");
                }
            }
            spec.property_names = try self.parse(pn, "string", diag);
        }

        spec.allow_additional_properties = !self.strict_mode;
        if (schema.get("additionalProperties")) |add| {
            if (add == .bool) {
                spec.allow_additional_properties = add.bool;
            } else {
                spec.allow_additional_properties = true;
                spec.additional_properties_schema = try self.parse(add, null, diag);
            }
        }

        spec.allow_unevaluated_properties = true;
        if (schema.get("additionalProperties") != null) {
            spec.allow_unevaluated_properties = spec.allow_additional_properties;
        } else if (schema.get("unevaluatedProperties")) |uneval| {
            if (uneval == .bool) {
                spec.allow_unevaluated_properties = uneval.bool;
            } else {
                spec.allow_unevaluated_properties = true;
                spec.unevaluated_properties_schema = try self.parse(uneval, null, diag);
            }
        } else if (self.strict_mode) {
            spec.allow_unevaluated_properties = false;
        }

        if (schema.get("minProperties")) |v| {
            if (v != .integer) {
                return failStatic(error.InvalidSchema, diag, "minProperties must be an integer");
            }
            spec.min_properties = satI32(v.integer);
            if (spec.min_properties < 0) {
                return failStatic(error.UnsatisfiableSchema, diag, "minProperties must be a non-negative integer");
            }
        }
        if (schema.get("maxProperties")) |v| {
            if (v != .integer) {
                return failStatic(error.InvalidSchema, diag, "maxProperties must be an integer");
            }
            spec.max_properties = satI32(v.integer);
            if (spec.max_properties < 0) {
                return failStatic(error.UnsatisfiableSchema, diag, "maxProperties must be a non-negative integer");
            }
        }

        if (spec.max_properties != -1 and spec.min_properties > spec.max_properties) {
            return failFmt(error.UnsatisfiableSchema, diag, self.gpa, "minProperties is greater than maxProperties: {d} > {d}", .{ spec.min_properties, spec.max_properties });
        }
        if (spec.max_properties != -1 and @as(i32, @intCast(spec.required.count())) > spec.max_properties) {
            return failFmt(error.UnsatisfiableSchema, diag, self.gpa, "maxProperties is less than the number of required properties: {d} < {d}", .{ spec.max_properties, spec.required.count() });
        }
        if (spec.pattern_properties.items.len == 0 and spec.property_names == null and
            !spec.allow_additional_properties and !spec.allow_unevaluated_properties and
            spec.min_properties > @as(i32, @intCast(spec.properties.items.len)))
        {
            return failFmt(error.UnsatisfiableSchema, diag, self.gpa, "minProperties is greater than the number of properties, but additional properties aren't allowed: {d} > {d}", .{ spec.min_properties, spec.properties.items.len });
        }
        return spec;
    }

    fn parseConst(self: *SchemaParser, schema: ObjectMap) Allocator.Error!ConstSpec {
        return .{ .json_value = try serializeJson(self.arena, schema.get("const").?) };
    }

    fn parseEnum(self: *SchemaParser, schema: ObjectMap, diag: ?*Diagnostic) SchemaError!EnumSpec {
        var spec = EnumSpec{};
        errdefer spec.json_values.deinit(self.arena);
        const arr = schema.get("enum").?;
        if (arr != .array) {
            return failStatic(error.InvalidSchema, diag, "enum must be an array");
        }
        if (arr.array.items.len == 0) {
            return failStatic(error.InvalidSchema, diag, "enum array must not be empty");
        }
        for (arr.array.items) |item| {
            try spec.json_values.append(self.arena, try serializeJson(self.arena, item));
        }
        return spec;
    }

    fn parseRef(self: *SchemaParser, schema: ObjectMap, diag: ?*Diagnostic) SchemaError!RefSpec {
        const ref = schema.get("$ref").?;
        if (ref != .string) {
            return failStatic(error.InvalidSchema, diag, "$ref must be a string");
        }
        return .{ .uri = try self.arena.dupe(u8, ref.string) };
    }

    pub fn resolveRef(
        self: *SchemaParser,
        uri: []const u8,
        diag: ?*Diagnostic,
    ) SchemaError!SchemaSpecPtr {
        if (self.ref_cache.get(uri)) |spec| {
            return spec;
        }

        if (std.mem.eql(u8, uri, "#")) {
            const placeholder = try self.make(.{ .Any = {} }, "");
            try self.ref_cache.put(self.arena, try self.arena.dupe(u8, uri), placeholder);
            const resolved = try self.parse(self.root_schema, null, diag);
            try self.ref_cache.put(self.arena, try self.arena.dupe(u8, uri), resolved);
            return resolved;
        }

        if (!std.mem.startsWith(u8, uri, "#/")) {
            log.warn("URI should either be '#' or start with '#/' but got {s}", .{uri});
            return self.make(.{ .Any = {} }, "");
        }

        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(self.arena);
        var rest = uri[2..];
        while (true) {
            const slash = std.mem.indexOfScalar(u8, rest, '/');
            const seg = if (slash) |idx| rest[0..idx] else rest;
            if (seg.len != 0 or parts.items.len > 0 or slash != null) {
                var decoded: std.ArrayList(u8) = .empty;
                var si: usize = 0;
                while (si < seg.len) {
                    if (seg[si] == '~' and si + 1 < seg.len) {
                        if (seg[si + 1] == '1') {
                            try decoded.append(self.arena, '/');
                            si += 2;
                            continue;
                        } else if (seg[si + 1] == '0') {
                            try decoded.append(self.arena, '~');
                            si += 2;
                            continue;
                        }
                    }
                    try decoded.append(self.arena, seg[si]);
                    si += 1;
                }
                try parts.append(self.arena, try decoded.toOwnedSlice(self.arena));
            }
            if (slash) |idx| {
                rest = rest[idx + 1 ..];
            } else break;
        }
        var current = self.root_schema;
        for (parts.items) |p| {
            switch (current) {
                .object => |obj| {
                    current = obj.get(p) orelse {
                        return failFmt(error.InvalidSchema, diag, self.gpa, "Cannot find field {s} in {s}", .{ p, uri });
                    };
                },
                .array => |arr| {
                    const valid_idx = p.len > 0 and (p.len == 1 or p[0] != '0');
                    const parsed_idx = if (valid_idx) std.fmt.parseInt(usize, p, 10) catch null else null;
                    if (parsed_idx == null or parsed_idx.? >= arr.items.len) {
                        return failFmt(error.InvalidSchema, diag, self.gpa, "Cannot find index {s} in {s}", .{ p, uri });
                    }
                    current = arr.items[parsed_idx.?];
                },
                else => {
                    return failFmt(error.InvalidSchema, diag, self.gpa, "Cannot find field {s} in {s}", .{ p, uri });
                },
            }
        }
        const resolved = try self.parse(current, null, diag);
        try self.ref_cache.put(self.arena, try self.arena.dupe(u8, uri), resolved);
        return resolved;
    }

    fn parseAnyOf(self: *SchemaParser, schema: ObjectMap, diag: ?*Diagnostic) SchemaError!AnyOfSpec {
        const has_any_of = schema.get("anyOf") != null;
        const key: []const u8 = if (has_any_of) "anyOf" else "oneOf";
        const arr = schema.get(key).?;
        if (arr != .array) {
            return failFmt(error.InvalidSchema, diag, self.gpa, "{s} must be an array", .{key});
        }
        var spec = AnyOfSpec{};
        errdefer spec.options.deinit(self.arena);
        for (arr.array.items) |option| {
            const parsed = try self.parse(option, null, diag);
            try spec.options.append(self.arena, parsed);
        }
        return spec;
    }

    fn parseAllOf(self: *SchemaParser, schema: ObjectMap, diag: ?*Diagnostic) SchemaError!AllOfSpec {
        var spec = AllOfSpec{};
        errdefer spec.schemas.deinit(self.arena);
        const arr = schema.get("allOf").?;
        if (arr != .array) {
            return failStatic(error.InvalidSchema, diag, "allOf must be an array");
        }
        for (arr.array.items) |sub| {
            const parsed = try self.parse(sub, null, diag);
            try spec.schemas.append(self.arena, parsed);
        }
        return spec;
    }

    fn parseTypeArray(self: *SchemaParser, schema: ObjectMap, diag: ?*Diagnostic) SchemaError!TypeArraySpec {
        const arena = self.arena;
        var spec = TypeArraySpec{};
        errdefer spec.type_schemas.deinit(arena);
        const type_array = schema.get("type").?.array;
        var schema_copy = try ObjectMap.init(arena, &.{}, &.{});
        for (schema.keys(), schema.values()) |k, v| {
            try schema_copy.put(arena, k, v);
        }
        if (type_array.items.len == 0) {
            _ = schema_copy.orderedRemove("type");
            const any = try self.parse(Value{ .object = schema_copy }, null, diag);
            try spec.type_schemas.append(arena, any);
            return spec;
        }
        for (type_array.items) |ty| {
            if (ty != .string) {
                return failStatic(error.InvalidSchema, diag, "type must be a string or an array of strings");
            }
            try schema_copy.put(arena, try arena.dupe(u8, "type"), ty);
            const parsed = try self.parse(Value{ .object = schema_copy }, null, diag);
            try spec.type_schemas.append(arena, parsed);
        }
        return spec;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "SchemaParser sortedKeys, serializeJson, and Diagnostic errors with zero leaks" {
    const a = std.testing.allocator;
    var scratch = ArenaAllocator.init(a);
    defer scratch.deinit();
    const sa = scratch.allocator();

    // Test sortedKeys and serializeJson parity.
    var map = try ObjectMap.init(sa, &.{}, &.{});
    try map.put(sa, "z", .{ .float = 1.0 });
    try map.put(sa, "a", .{ .float = 0.1 });
    try map.put(sa, "m", .{ .string = "hi\x7f" });
    const keys = try sortedKeys(a, map);
    defer a.free(keys);
    try std.testing.expectEqualStrings("a", keys[0]);
    try std.testing.expectEqualStrings("m", keys[1]);
    try std.testing.expectEqualStrings("z", keys[2]);

    const serialized = try serializeJson(a, .{ .object = map });
    defer a.free(serialized);
    try std.testing.expectEqualStrings("{\"z\":1,\"a\":0.1,\"m\":\"hi\\u007f\"}", serialized);

    // Test SchemaParser parse & $ref resolution & Diagnostic error handling.
    const parsed_val = try std.json.parseFromSliceLeaky(Value, sa,
        \\{"$defs":{"pair":[{"type":"integer"},{"type":"string"}]},"type":"object","properties":{"n":{"$ref":"#/$defs/pair/0"}},"required":["n"]}
    , .{});

    var parser = try SchemaParser.init(a, parsed_val, true);
    defer parser.deinit();

    var diag: Diagnostic = .{};
    defer diag.deinit(a);

    const spec = try parser.parse(parsed_val, null, &diag);
    try std.testing.expect(spec.spec == .Object);
    const resolved = try parser.resolveRef("#/$defs/pair/0", &diag);
    try std.testing.expect(resolved.spec == .Integer);

    // Unsatisfiable and invalid schema errors under both diag == null and reusable diag.
    const bad_false = Value{ .bool = false };
    try std.testing.expectError(error.UnsatisfiableSchema, parser.parse(bad_false, null, null));
    try std.testing.expectError(error.UnsatisfiableSchema, parser.parse(bad_false, null, &diag));
    try std.testing.expectEqualStrings("Schema 'false' cannot accept any value", diag.message);

    try std.testing.expectError(error.InvalidSchema, parser.resolveRef("#/missing", &diag));
    const msg = try diag.formatAlloc(a);
    defer a.free(msg);
    try std.testing.expectEqualStrings("Cannot find field missing in #/missing", msg);
}
