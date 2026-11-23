//! Parses a JSON Schema (a `std.json.Value`) into the [`SchemaSpec`] IR
//! (`schema_parser.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const json_schema_converter_mod = @import("json_schema_converter.zig");
const schema_error = @import("schema_error.zig");
const SchemaError = schema_error.SchemaError;
const SchemaErrorInfo = schema_error.SchemaErrorInfo;
const schema_spec = @import("schema_spec.zig");
const ArraySpec = schema_spec.ArraySpec;
const AllOfSpec = schema_spec.AllOfSpec;
const AnyOfSpec = schema_spec.AnyOfSpec;
const ConstSpec = schema_spec.ConstSpec;
const EnumSpec = schema_spec.EnumSpec;
const IntegerSpec = schema_spec.IntegerSpec;
const NumberSpec = schema_spec.NumberSpec;
const ObjectSpec = schema_spec.ObjectSpec;
const PatternProperty = schema_spec.PatternProperty;
const Property = schema_spec.Property;
const RefSpec = schema_spec.RefSpec;
const SchemaSpec = schema_spec.SchemaSpec;
const SchemaSpecPtr = schema_spec.SchemaSpecPtr;
const SchemaSpecVariant = schema_spec.SchemaSpecVariant;
const StringSpec = schema_spec.StringSpec;
const TypeArraySpec = schema_spec.TypeArraySpec;

pub const Value = std.json.Value;
pub const ObjectMap = std.json.ObjectMap;

fn fail(e: SchemaError, diag: ?*SchemaErrorInfo, gpa: Allocator, message: []const u8) SchemaError {
    return schema_error.report(e, diag, gpa, message);
}

fn failFmt(e: SchemaError, diag: ?*SchemaErrorInfo, gpa: Allocator, comptime fmt: []const u8, args: anytype) SchemaError {
    return schema_error.reportFmt(e, diag, gpa, fmt, args);
}

/// Rust `n as i32` (saturating).
fn sat_i32(n: i64) i32 {
    return std.math.cast(i32, n) orelse if (n < 0) std.math.minInt(i32) else std.math.maxInt(i32);
}

/// Object keys ignored when computing a schema's de-duplication cache key.
const SKIPPED_CACHE_KEYS = [_][]const u8{
    "title",  "default", "description", "examples", "deprecated", "readOnly", "writeOnly", "$comment", "$schema",
};

const UNSUPPORTED_ONE_OF_MESSAGE = "oneOf with overlapping or non-provably-disjoint branches cannot be represented exactly; falling back to anyOf semantics";

fn contains_str(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

fn has_only_schema_keys(schema: ObjectMap, allowed: []const []const u8) bool {
    for (schema.keys()) |key| {
        if (!contains_str(allowed, key) and !contains_str(&SKIPPED_CACHE_KEYS, key)) return false;
    }
    return true;
}

fn normalize_type_set(arena: Allocator, value: Value) ?std.StringHashMap(void) {
    const SUPPORTED_TYPES = [_][]const u8{ "null", "boolean", "object", "array", "number", "string", "integer" };
    var result = std.StringHashMap(void).init(arena);
    switch (value) {
        .string => |ty| {
            if (!contains_str(&SUPPORTED_TYPES, ty)) return null;
            result.put(ty, {}) catch return null;
        },
        .array => |types| {
            if (types.items.len == 0) return null;
            for (types.items) |item| {
                if (item != .string) return null;
                const ty = item.string;
                if (!contains_str(&SUPPORTED_TYPES, ty)) return null;
                result.put(ty, {}) catch return null;
            }
        },
        else => return null,
    }
    return result;
}

fn is_numeric_value(value: Value) bool {
    return switch (value) {
        .integer, .float, .number_string => true,
        else => false,
    };
}

fn is_integer_value(value: Value) bool {
    return switch (value) {
        .integer => true,
        .float => |f| std.math.isFinite(f) and f == @trunc(f),
        else => false,
    };
}

/// JSON-number comparisons are deliberately conservative when either side was parsed as a
/// floating-point value. This matches upstream and avoids claiming `oneOf` disjointness
/// after a potentially lossy conversion.
fn json_values_may_overlap(lhs: Value, rhs: Value) bool {
    if (is_numeric_value(lhs) or is_numeric_value(rhs)) {
        if (!is_numeric_value(lhs) or !is_numeric_value(rhs)) {
            return false;
        }
        // Rust: equal only when both sides are exact integers (not parsed as f64).
        return lhs == .integer and rhs == .integer and lhs.integer == rhs.integer;
    }
    if (lhs == .null and rhs == .null) return true;
    if (lhs == .bool and rhs == .bool) return lhs.bool == rhs.bool;
    if (lhs == .string and rhs == .string) return std.mem.eql(u8, lhs.string, rhs.string);
    if (lhs == .array and rhs == .array) {
        if (lhs.array.items.len != rhs.array.items.len) return false;
        for (lhs.array.items, rhs.array.items) |l, r| {
            if (!json_values_may_overlap(l, r)) return false;
        }
        return true;
    }
    if (lhs == .object and rhs == .object) {
        if (lhs.object.count() != rhs.object.count()) return false;
        for (lhs.object.keys(), lhs.object.values()) |key, l| {
            const r = rhs.object.get(key) orelse return false;
            if (!json_values_may_overlap(l, r)) return false;
        }
        return true;
    }
    return false;
}

fn value_matches_type(value: Value, ty: []const u8) bool {
    if (std.mem.eql(u8, ty, "null")) return value == .null;
    if (std.mem.eql(u8, ty, "boolean")) return value == .bool;
    if (std.mem.eql(u8, ty, "string")) return value == .string;
    if (std.mem.eql(u8, ty, "integer")) return is_integer_value(value);
    if (std.mem.eql(u8, ty, "number")) return is_numeric_value(value);
    if (std.mem.eql(u8, ty, "array")) return value == .array;
    if (std.mem.eql(u8, ty, "object")) return value == .object;
    return false;
}

fn finite_values(arena: Allocator, schema: ObjectMap) ?std.ArrayList(Value) {
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
    TypeSet: std.StringHashMap(void),
    FiniteValues: std.ArrayList(Value),
};

fn classify_one_of_arm(arena: Allocator, option: Value) ?OneOfArmProof {
    if (option != .object) return null;
    const schema = option.object;
    for ([_][]const u8{ "$ref", "anyOf", "allOf", "oneOf" }) |key| {
        if (schema.get(key) != null) return null;
    }
    if (finite_values(arena, schema)) |values| {
        return .{ .FiniteValues = values };
    }
    if (!has_only_schema_keys(schema, &[_][]const u8{"type"})) {
        return null;
    }
    const type_set = normalize_type_set(arena, schema.get("type") orelse return null) orelse return null;
    if (type_set.contains("object")) {
        return null;
    }
    return .{ .TypeSet = type_set };
}

fn type_sets_overlap(lhs: *const std.StringHashMap(void), rhs: *const std.StringHashMap(void)) bool {
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

fn finite_values_overlap(lhs: []const Value, rhs: []const Value) bool {
    for (lhs) |lhs_value| {
        for (rhs) |rhs_value| {
            if (json_values_may_overlap(lhs_value, rhs_value)) return true;
        }
    }
    return false;
}

fn finite_values_overlap_type_set(values: []const Value, type_set: *const std.StringHashMap(void)) bool {
    for (values) |value| {
        if (is_numeric_value(value) and (type_set.contains("integer") or type_set.contains("number"))) {
            return true;
        }
        var it = type_set.keyIterator();
        while (it.next()) |ty| {
            if (value_matches_type(value, ty.*)) return true;
        }
    }
    return false;
}

fn one_of_arm_proofs_are_disjoint(lhs: *const OneOfArmProof, rhs: *const OneOfArmProof) bool {
    switch (lhs.*) {
        .TypeSet => |l| switch (rhs.*) {
            .TypeSet => |r| return !type_sets_overlap(&l, &r),
            .FiniteValues => |r| return !finite_values_overlap_type_set(r.items, &l),
        },
        .FiniteValues => |l| switch (rhs.*) {
            .TypeSet => |r| return !finite_values_overlap_type_set(l.items, &r),
            .FiniteValues => |r| return !finite_values_overlap(l.items, r.items),
        },
    }
}

fn discriminator_values(arena: Allocator, option: Value, discriminator_key: []const u8) ?std.ArrayList(Value) {
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
    return finite_values(arena, property_schema.object);
}

fn discriminator_candidates(arena: Allocator, option: Value) std.ArrayList([]const u8) {
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
            if (prop == .object and finite_values(arena, prop.object) != null) {
                out.append(arena, key) catch return out;
            }
        }
    }
    return out;
}

fn try_prove_discriminator_one_of(arena: Allocator, options: []const Value) bool {
    if (options.len == 0) return false;
    const first = options[0];
    var candidates = discriminator_candidates(arena, first);
    defer candidates.deinit(arena);
    for (candidates.items) |key| {
        var branch_values: ?std.ArrayList(std.ArrayList(Value)) = .empty;
        var failed = false;
        for (options) |option| {
            if (branch_values == null) break;
            if (discriminator_values(arena, option, key)) |values| {
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
                    if (finite_values_overlap(values.items[lhs].items, values.items[rhs].items)) {
                        all_disjoint = false;
                    }
                }
            }
            if (all_disjoint) return true;
        }
    }
    return false;
}

fn try_prove_type_or_finite_one_of(arena: Allocator, options: []const Value) bool {
    var proofs: std.ArrayList(OneOfArmProof) = .empty;
    defer proofs.deinit(arena);
    for (options) |option| {
        const proof = classify_one_of_arm(arena, option) orelse return false;
        proofs.append(arena, proof) catch return false;
    }
    for (0..proofs.items.len) |lhs| {
        for (lhs + 1..proofs.items.len) |rhs| {
            if (!one_of_arm_proofs_are_disjoint(&proofs.items[lhs], &proofs.items[rhs])) return false;
        }
    }
    return true;
}

fn try_prove_pairwise_disjoint_one_of(arena: Allocator, options: []const Value) bool {
    return options.len != 0 and
        (try_prove_discriminator_one_of(arena, options) or try_prove_type_or_finite_one_of(arena, options));
}

/// Deep-clones a JSON value into `allocator` (Rust `Value::clone`).
pub fn value_clone(allocator: Allocator, value: Value) Allocator.Error!Value {
    return switch (value) {
        .null, .bool, .integer, .float => value,
        .number_string => |s| Value{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| Value{ .string = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            var out = std.json.Array.init(allocator);
            try out.ensureTotalCapacity(arr.items.len);
            for (arr.items) |item| out.appendAssumeCapacity(try value_clone(allocator, item));
            break :blk Value{ .array = out };
        },
        .object => |map| blk: {
            var out = try ObjectMap.init(allocator, &.{}, &.{});
            try out.ensureTotalCapacity(allocator, map.count());
            for (map.keys(), map.values()) |k, v| {
                out.putAssumeCapacity(try allocator.dupe(u8, k), try value_clone(allocator, v));
            }
            break :blk Value{ .object = out };
        },
    };
}

/// Deep structural equality of two JSON values.
pub fn value_eql(lhs: Value, rhs: Value) bool {
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
                if (!value_eql(l, r)) break :blk false;
            }
            break :blk true;
        },
        .object => blk: {
            if (lhs.object.count() != rhs.object.count()) break :blk false;
            for (lhs.object.keys(), lhs.object.values()) |k, l| {
                const r = rhs.object.get(k) orelse break :blk false;
                if (!value_eql(l, r)) break :blk false;
            }
            break :blk true;
        },
    };
}

/// The keys of an object, sorted byte-lexicographically (serde_json's `Map` is a
/// `BTreeMap`; std.json's `ObjectMap` is insertion-ordered — see PORTING.md trap 1).
pub fn sorted_keys(arena: Allocator, map: ObjectMap) Allocator.Error![][]const u8 {
    const keys = try arena.alloc([]const u8, map.count());
    @memcpy(keys, map.keys());
    std.mem.sort([]const u8, keys, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return keys;
}

/// Serializes `value` as compact JSON, spelled as the reference implementation spells
/// schema literals: integral doubles below 2^53 without a fraction (`1.0` is `1`), other
/// doubles with 17 significant digits, and DEL escaped like the control characters.
/// Object keys keep insertion order (xgrammar-rs 0.2.8 enables serde_json
/// `preserve_order`; see deviation 7 — std.json's ObjectMap is already insertion-ordered).
pub fn serialize_json(arena: Allocator, value: Value) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    try serialize_json_into(arena, &out, value);
    return out.toOwnedSlice(arena);
}

fn trim_fraction(text: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, text, '.') != null) {
        return std.mem.trimEnd(u8, std.mem.trimEnd(u8, text, "0"), ".");
    }
    return text;
}

fn write_number(arena: Allocator, out: *std.ArrayList(u8), int: ?i64, double: ?f64, raw: ?[]const u8) Allocator.Error!void {
    if (int) |integer| {
        try out.print(arena, "{d}", .{integer});
        return;
    }
    if (double) |double_value| {
        if (@abs(double_value) < 9007199254740992.0 and double_value == @trunc(double_value)) {
            const text = try @import("range_regex.zig").format_fixed(arena, double_value, 0);
            defer arena.free(text);
            try out.appendSlice(arena, text);
            return;
        }
        // printf("%.17g"): scientific notation outside [1e-4, 1e17).
        var buf: [1100]u8 = undefined;
        const scientific = std.fmt.float.render(&buf, double_value, .{ .mode = .scientific, .precision = 16 }) catch unreachable;
        const e_index = std.mem.indexOfScalar(u8, scientific, 'e').?;
        const mantissa = scientific[0..e_index];
        const exponent = std.fmt.parseInt(i32, scientific[e_index + 1 ..], 10) catch unreachable;
        if (exponent >= -4 and exponent < 17) {
            const text = try @import("range_regex.zig").format_fixed(arena, double_value, @intCast(16 - exponent));
            defer arena.free(text);
            try out.appendSlice(arena, trim_fraction(text));
        } else {
            const sign: u8 = if (exponent < 0) '-' else '+';
            const trimmed = trim_fraction(mantissa);
            if (@abs(exponent) < 10) {
                try out.print(arena, "{s}e{c}{c}{d}", .{ trimmed, sign, '0', @abs(exponent) });
            } else {
                try out.print(arena, "{s}e{c}{d}", .{ trimmed, sign, @abs(exponent) });
            }
        }
        return;
    }
    // Rust `(None, None)`: a u64 outside i64's range. std.json parses those as f64, so this
    // is only reachable for a raw `number_string`.
    try out.appendSlice(arena, raw orelse "");
}

fn serialize_json_into(arena: Allocator, out: *std.ArrayList(u8), value: Value) Allocator.Error!void {
    switch (value) {
        .null => try out.appendSlice(arena, "null"),
        .bool => |flag| try out.appendSlice(arena, if (flag) "true" else "false"),
        .integer => |n| try out.print(arena, "{d}", .{n}),
        .float => |f| try write_number(arena, out, null, f, null),
        .number_string => |s| try write_number(arena, out, null, null, s),
        .string => |text| {
            try out.append(arena, '"');
            var view = std.unicode.Utf8View.initUnchecked(text).iterator();
            while (view.nextCodepoint()) |character| {
                const c: u21 = character;
                switch (c) {
                    '"' => try out.appendSlice(arena, "\\\""),
                    '\\' => try out.appendSlice(arena, "\\\\"),
                    0x8 => try out.appendSlice(arena, "\\b"),
                    0xc => try out.appendSlice(arena, "\\f"),
                    '\n' => try out.appendSlice(arena, "\\n"),
                    '\r' => try out.appendSlice(arena, "\\r"),
                    '\t' => try out.appendSlice(arena, "\\t"),
                    else => {
                        if (c < ' ' or c == 0x7f) {
                            try out.print(arena, "\\u{x:0>4}", .{c});
                        } else {
                            var utf8_buf: [4]u8 = undefined;
                            const len = std.unicode.utf8Encode(c, &utf8_buf) catch unreachable;
                            try out.appendSlice(arena, utf8_buf[0..len]);
                        }
                    },
                }
            }
            try out.append(arena, '"');
        },
        .array => |items| {
            try out.append(arena, '[');
            for (items.items, 0..) |item, index| {
                if (index != 0) try out.append(arena, ',');
                try serialize_json_into(arena, out, item);
            }
            try out.append(arena, ']');
        },
        .object => |members| {
            try out.append(arena, '{');
            for (members.keys(), members.values(), 0..) |key, member, index| {
                if (index != 0) try out.append(arena, ',');
                try serialize_json_into(arena, out, Value{ .string = key });
                try out.append(arena, ':');
                try serialize_json_into(arena, out, member);
            }
            try out.append(arena, '}');
        },
    }
}

/// Parses JSON schemas into [`SchemaSpec`] trees, resolving `$ref`s against the root.
/// All spec nodes live in the parser's arena; `deinit` releases them.
pub const SchemaParser = struct {
    gpa: Allocator,
    arena_state: ArenaAllocator,
    arena: Allocator,
    strict_mode: bool,
    root_schema: Value,
    ref_cache: std.StringHashMap(SchemaSpecPtr),
    schema_cache: std.StringHashMap(SchemaSpecPtr),

    /// Takes a deep clone of `root_schema` into the parser's arena (Rust moves the value).
    pub fn init(gpa: Allocator, root_schema: Value, strict_mode: bool) Allocator.Error!*SchemaParser {
        const self = try gpa.create(SchemaParser);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .arena_state = ArenaAllocator.init(gpa),
            .arena = undefined,
            .strict_mode = strict_mode,
            .root_schema = undefined,
            .ref_cache = undefined,
            .schema_cache = undefined,
        };
        self.arena = self.arena_state.allocator();
        errdefer self.arena_state.deinit();
        self.root_schema = try value_clone(self.arena, root_schema);
        self.ref_cache = std.StringHashMap(SchemaSpecPtr).init(self.arena);
        self.schema_cache = std.StringHashMap(SchemaSpecPtr).init(self.arena);
        return self;
    }

    pub fn deinit(self: *SchemaParser) void {
        self.arena_state.deinit();
        self.gpa.destroy(self);
    }

    /// Deterministic cache key for `value` (objects sorted, cosmetic keys dropped).
    fn compute_cache_key(arena: Allocator, value: Value) Allocator.Error![]u8 {
        switch (value) {
            .object => |map| {
                var filtered: std.ArrayList([]const u8) = .empty;
                defer filtered.deinit(arena);
                for (map.keys()) |k| {
                    if (!contains_str(&SKIPPED_CACHE_KEYS, k)) try filtered.append(arena, k);
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
                    try result.appendSlice(arena, try compute_cache_key(arena, map.get(k).?));
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
                    try result.appendSlice(arena, try compute_cache_key(arena, item));
                }
                try result.append(arena, ']');
                return result.toOwnedSlice(arena);
            },
            else => return serialize_json(arena, value),
        }
    }

    fn make(self: *SchemaParser, variant: SchemaSpecVariant, cache_key: []const u8) Allocator.Error!SchemaSpecPtr {
        return SchemaSpec.make(self.arena, variant, try self.arena.dupe(u8, cache_key));
    }

    pub fn parse(
        self: *SchemaParser,
        schema: Value,
        default_type: ?[]const u8,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!SchemaSpecPtr {
        const arena = self.arena;
        const cache_key = try compute_cache_key(arena, schema);
        if (self.schema_cache.get(cache_key)) |spec| {
            return spec;
        }

        if (schema == .bool) {
            if (!schema.bool) {
                return fail(error.UnsatisfiableSchema, diag, self.gpa, "Schema 'false' cannot accept any value");
            }
            const spec = try self.make(.{ .Any = {} }, cache_key);
            try self.schema_cache.put(try arena.dupe(u8, cache_key), spec);
            return spec;
        }

        if (schema != .object) {
            const printed = try serialize_json(arena, schema);
            defer arena.free(printed);
            return failFmt(error.InvalidSchema, diag, self.gpa, "Schema should be an object or bool, but got {s}", .{printed});
        }
        const obj = schema.object;

        var variant: SchemaSpecVariant = undefined;
        if (obj.get("$ref") != null) {
            variant = .{ .Ref = try self.parse_ref(obj, diag) };
        } else if (obj.get("const") != null) {
            variant = .{ .Const = try self.parse_const(obj) };
        } else if (obj.get("enum") != null) {
            variant = .{ .Enum = try self.parse_enum(obj, diag) };
        } else if (obj.get("anyOf") != null) {
            variant = .{ .AnyOf = try self.parse_any_of(obj, diag) };
        } else if (obj.get("oneOf") != null) {
            const one_of = obj.get("oneOf").?;
            if (one_of != .array) {
                return fail(error.InvalidSchema, diag, self.gpa, "oneOf must be an array");
            }
            if (!try_prove_pairwise_disjoint_one_of(arena, one_of.array.items)) {
                std.debug.print("{s}\n", .{UNSUPPORTED_ONE_OF_MESSAGE});
            }
            variant = .{ .AnyOf = try self.parse_any_of(obj, diag) };
        } else if (obj.get("allOf") != null) {
            variant = .{ .AllOf = try self.parse_all_of(obj, diag) };
        } else if (obj.get("type") != null or default_type != null) {
            const type_value = obj.get("type");
            if (type_value != null and type_value.? == .array) {
                variant = .{ .TypeArray = try self.parse_type_array(obj, diag) };
            } else {
                if (type_value != null and type_value.? != .string) {
                    return fail(error.InvalidSchema, diag, self.gpa, "Type should be a string");
                }
                const ty = if (type_value != null) type_value.?.string else default_type.?;
                if (std.mem.eql(u8, ty, "integer")) {
                    variant = .{ .Integer = try parse_integer(obj, diag, self.gpa) };
                } else if (std.mem.eql(u8, ty, "number")) {
                    variant = .{ .Number = try parse_number(obj, diag, self.gpa) };
                } else if (std.mem.eql(u8, ty, "string")) {
                    variant = .{ .String = try parse_string(obj, diag, self.gpa, arena) };
                } else if (std.mem.eql(u8, ty, "boolean")) {
                    variant = .{ .Boolean = {} };
                } else if (std.mem.eql(u8, ty, "null")) {
                    variant = .{ .Null = {} };
                } else if (std.mem.eql(u8, ty, "array")) {
                    variant = .{ .Array = try self.parse_array(obj, diag) };
                } else if (std.mem.eql(u8, ty, "object")) {
                    variant = .{ .Object = try self.parse_object(obj, diag) };
                } else {
                    return failFmt(error.InvalidSchema, diag, self.gpa, "Unsupported type \"{s}\"", .{ty});
                }
            }
        } else if (obj.get("properties") != null or obj.get("additionalProperties") != null or
            obj.get("unevaluatedProperties") != null)
        {
            variant = .{ .Object = try self.parse_object(obj, diag) };
        } else if (obj.get("items") != null or obj.get("prefixItems") != null or obj.get("unevaluatedItems") != null) {
            variant = .{ .Array = try self.parse_array(obj, diag) };
        } else {
            variant = .{ .Any = {} };
        }
        const result: SchemaSpecPtr = try self.make(variant, cache_key);

        try self.schema_cache.put(try arena.dupe(u8, cache_key), result);
        return result;
    }

    fn check_integer_bound(value: Value, diag: ?*SchemaErrorInfo, gpa: Allocator) SchemaError!i64 {
        if (value == .integer) {
            return value.integer;
        }
        if (value != .float) {
            return fail(error.InvalidSchema, diag, gpa, "Value must be a number");
        }
        const val = value.float;
        if (val != @trunc(val)) {
            return fail(error.InvalidSchema, diag, gpa, "Integer constraint must be a whole number");
        }
        // A bound outside int64 is parsed as a double; +-2^63 is where it rounds onto the edge
        // of the int64 range, so it must be rejected rather than saturated.
        const i64_min_f: f64 = @floatFromInt(std.math.minInt(i64));
        const i64_max_f: f64 = @floatFromInt(std.math.maxInt(i64));
        if (val == i64_min_f) {
            return fail(error.InvalidSchema, diag, gpa, "Integer exceeds minimum limit due to precision loss at 64-bit boundary");
        }
        if (val >= i64_max_f) {
            return fail(error.InvalidSchema, diag, gpa, if (val == i64_max_f)
                "Integer exceeds maximum limit due to precision loss at 64-bit boundary"
            else
                "Integer exceeds maximum limit");
        }
        if (val < i64_min_f) {
            return fail(error.InvalidSchema, diag, gpa, "Integer exceeds minimum limit");
        }
        return @intFromFloat(val);
    }

    fn parse_integer(schema: ObjectMap, diag: ?*SchemaErrorInfo, gpa: Allocator) SchemaError!IntegerSpec {
        const INTEGER_MULTIPLE_OF_MAX: f64 = 1024.0;
        const INTEGER_MULTIPLE_OF_RANGE_WIDTH_MAX: i128 = 10_000;

        var spec = IntegerSpec{};
        if (schema.get("multipleOf")) |value| {
            if (value != .float and value != .integer) {
                return fail(error.InvalidSchema, diag, gpa, "Value must be a number");
            }
            const multiple_of = number_as_f64(value);
            if (multiple_of <= 0.0) {
                return fail(error.InvalidSchema, diag, gpa, "multipleOf must be greater than 0");
            }
            if (multiple_of != @trunc(multiple_of)) {
                std.debug.print("multipleOf for type:integer must be an integer; ignoring multipleOf\n", .{});
            } else if (multiple_of > INTEGER_MULTIPLE_OF_MAX) {
                std.debug.print("multipleOf for type:integer must be > 0 and <= 1024; ignoring multipleOf\n", .{});
            } else {
                spec.multiple_of = @intFromFloat(multiple_of);
            }
        }
        if (schema.get("minimum")) |v| {
            spec.minimum = try check_integer_bound(v, diag, gpa);
        }
        if (schema.get("maximum")) |v| {
            spec.maximum = try check_integer_bound(v, diag, gpa);
        }
        if (schema.get("exclusiveMinimum")) |v| {
            const val = try check_integer_bound(v, diag, gpa);
            if (val == std.math.maxInt(i64)) {
                return fail(error.UnsatisfiableSchema, diag, gpa, "exclusiveMinimum would cause integer overflow");
            }
            spec.exclusive_minimum = val;
        }
        if (schema.get("exclusiveMaximum")) |v| {
            const val = try check_integer_bound(v, diag, gpa);
            if (val == std.math.minInt(i64)) {
                return fail(error.UnsatisfiableSchema, diag, gpa, "exclusiveMaximum would cause integer underflow");
            }
            spec.exclusive_maximum = val;
        }

        const effective = spec.effective_range();
        const effective_min = effective.start orelse std.math.minInt(i64);
        const effective_max = effective.end orelse std.math.maxInt(i64);
        if (effective_min > effective_max) {
            return fail(error.UnsatisfiableSchema, diag, gpa, "Invalid range: minimum greater than maximum");
        }
        if (spec.multiple_of) |multiple_of| {
            const has_lower_bound = effective.start != null;
            const has_upper_bound = effective.end != null;
            if (has_lower_bound or has_upper_bound) {
                const range_width: i128 = @as(i128, effective_max) - @as(i128, effective_min) + 1;
                if (!has_lower_bound or !has_upper_bound or range_width > INTEGER_MULTIPLE_OF_RANGE_WIDTH_MAX) {
                    std.debug.print("range + multipleOf combination not yet supported; ignoring multipleOf\n", .{});
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
                        return fail(error.UnsatisfiableSchema, diag, gpa, "range contains no multipleOf value");
                    }
                }
            }
        }
        return spec;
    }

    fn number_as_f64(value: Value) f64 {
        return switch (value) {
            .integer => |n| @floatFromInt(n),
            .float => |f| f,
            .number_string => |s| std.fmt.parseFloat(f64, s) catch 0.0,
            else => unreachable,
        };
    }

    fn parse_number(schema: ObjectMap, diag: ?*SchemaErrorInfo, gpa: Allocator) SchemaError!NumberSpec {
        var spec = NumberSpec{};
        if (schema.get("multipleOf")) |value| {
            if (value != .float and value != .integer) {
                return fail(error.InvalidSchema, diag, gpa, "Value must be a number");
            }
            const multiple_of = number_as_f64(value);
            if (multiple_of <= 0.0) {
                return fail(error.InvalidSchema, diag, gpa, "multipleOf must be greater than 0");
            }
            std.debug.print("multipleOf is not supported for type:number; ignoring multipleOf\n", .{});
        }

        const get_double = struct {
            fn call(v: Value, d: ?*SchemaErrorInfo, allocator: Allocator) SchemaError!f64 {
                if (v == .float or v == .integer) return number_as_f64(v);
                return fail(error.InvalidSchema, d, allocator, "Value must be a number");
            }
        }.call;
        if (schema.get("minimum")) |v| {
            spec.minimum = try get_double(v, diag, gpa);
        }
        if (schema.get("maximum")) |v| {
            spec.maximum = try get_double(v, diag, gpa);
        }
        if (schema.get("exclusiveMinimum")) |v| {
            spec.exclusive_minimum = try get_double(v, diag, gpa);
        }
        if (schema.get("exclusiveMaximum")) |v| {
            spec.exclusive_maximum = try get_double(v, diag, gpa);
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
            return fail(error.UnsatisfiableSchema, diag, gpa, "Invalid range: empty range");
        }
        return spec;
    }

    fn parse_string(schema: ObjectMap, diag: ?*SchemaErrorInfo, gpa: Allocator, arena: Allocator) SchemaError!StringSpec {
        var spec = StringSpec{};
        if (schema.get("format")) |v| {
            if (v == .string) spec.format = try arena.dupe(u8, v.string);
        }
        if (schema.get("pattern")) |v| {
            if (v == .string) spec.pattern = try arena.dupe(u8, v.string);
        }
        // Lengths become int32 repetition bounds. A minimum beyond int32 can never be
        // satisfied; a maximum beyond it is unbounded in practice. Neither may wrap around
        // when converted.
        if (schema.get("minLength")) |v| {
            if (v != .integer or v.integer > std.math.maxInt(i32)) {
                return failFmt(error.InvalidSchema, diag, gpa, "minLength must be an integer not exceeding {d}", .{std.math.maxInt(i32)});
            }
            spec.min_length = @intCast(v.integer);
        }
        if (schema.get("maxLength")) |v| {
            if (v != .integer) {
                return fail(error.InvalidSchema, diag, gpa, "maxLength must be an integer");
            }
            if (std.math.cast(i32, v.integer)) |n| {
                spec.max_length = n;
            }
        }
        if (spec.max_length != -1 and spec.min_length > spec.max_length) {
            return failFmt(error.UnsatisfiableSchema, diag, gpa, "minLength {d} is greater than maxLength {d}", .{ spec.min_length, spec.max_length });
        }
        // A pattern or built-in format takes the whole string branch of every converter, so
        // the length bounds would otherwise be dropped silently.
        if (spec.min_length != 0 or spec.max_length != -1) {
            const generative: ?[]const u8 = if (spec.pattern != null)
                "pattern"
            else blk: {
                if (spec.format) |format| {
                    if (json_schema_converter_mod.json_format_to_regex_pattern(arena, format) catch null != null) {
                        break :blk "format";
                    }
                }
                break :blk null;
            };
            if (generative) |g| {
                std.debug.print("{s} combined with minLength/maxLength is not supported; ignoring minLength/maxLength\n", .{g});
            }
        }
        return spec;
    }

    fn parse_array(self: *SchemaParser, schema: ObjectMap, diag: ?*SchemaErrorInfo) SchemaError!ArraySpec {
        var spec = ArraySpec{};

        if (schema.get("prefixItems")) |prefix| {
            if (prefix != .array) {
                return fail(error.InvalidSchema, diag, self.gpa, "prefixItems must be an array");
            }
            for (prefix.array.items) |item| {
                if (item == .bool and item.bool == false) {
                    return fail(error.UnsatisfiableSchema, diag, self.gpa, "prefixItems contains false");
                } else if (item != .object) {
                    return fail(error.InvalidSchema, diag, self.gpa, "prefixItems must be an array of objects or booleans");
                }
                const parsed = try self.parse(item, null, diag);
                try spec.prefix_items.append(self.arena, parsed);
            }
        }

        if (schema.get("items")) |items| {
            if (items != .bool and items != .object) {
                return fail(error.InvalidSchema, diag, self.gpa, "items must be a boolean or an object");
            }
            if (items == .bool and items.bool == false) {
                spec.allow_additional_items = false;
            } else {
                spec.allow_additional_items = true;
                spec.additional_items = try self.parse(items, null, diag);
            }
        } else if (schema.get("unevaluatedItems")) |uneval| {
            if (uneval != .bool and uneval != .object) {
                return fail(error.InvalidSchema, diag, self.gpa, "unevaluatedItems must be a boolean or an object");
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
                return fail(error.InvalidSchema, diag, self.gpa, "minItems must be an integer");
            }
            spec.min_items = @max(v.integer, 0);
        }
        if (schema.get("minContains")) |v| {
            if (v != .integer) {
                return fail(error.InvalidSchema, diag, self.gpa, "minContains must be an integer");
            }
            spec.min_items = @max(spec.min_items, v.integer);
        }
        if (schema.get("maxItems")) |v| {
            if (v != .integer or v.integer < 0) {
                return fail(error.InvalidSchema, diag, self.gpa, "maxItems must be a non-negative integer");
            }
            spec.max_items = v.integer;
        }
        // Item counts become int32 repetition bounds, see `parse_string` for the rationale.
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

    fn parse_object(self: *SchemaParser, schema: ObjectMap, diag: ?*SchemaErrorInfo) SchemaError!ObjectSpec {
        const arena = self.arena;
        var spec = try ObjectSpec.default(arena);
        errdefer spec.required.deinit();

        if (schema.get("properties")) |props| {
            if (props != .object) {
                return fail(error.InvalidSchema, diag, self.gpa, "properties must be an object");
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
                return fail(error.InvalidSchema, diag, self.gpa, "required must be an array");
            }
            for (req.array.items) |r| {
                if (r == .string) {
                    try spec.required.put(try arena.dupe(u8, r.string), {});
                }
            }
        }

        if (schema.get("patternProperties")) |pp| {
            if (pp != .object) {
                return fail(error.InvalidSchema, diag, self.gpa, "patternProperties must be an object");
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
                return fail(error.InvalidSchema, diag, self.gpa, "propertyNames must be an object");
            }
            if (pn.object.get("type")) |t| {
                if (t == .string and !std.mem.eql(u8, t.string, "string")) {
                    return fail(error.UnsatisfiableSchema, diag, self.gpa, "propertyNames must be an object that validates string");
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
                return fail(error.InvalidSchema, diag, self.gpa, "minProperties must be an integer");
            }
            spec.min_properties = sat_i32(v.integer);
            if (spec.min_properties < 0) {
                return fail(error.UnsatisfiableSchema, diag, self.gpa, "minProperties must be a non-negative integer");
            }
        }
        if (schema.get("maxProperties")) |v| {
            if (v != .integer) {
                return fail(error.InvalidSchema, diag, self.gpa, "maxProperties must be an integer");
            }
            spec.max_properties = sat_i32(v.integer);
            if (spec.max_properties < 0) {
                return fail(error.UnsatisfiableSchema, diag, self.gpa, "maxProperties must be a non-negative integer");
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

    fn parse_const(self: *SchemaParser, schema: ObjectMap) Allocator.Error!ConstSpec {
        return .{ .json_value = try serialize_json(self.arena, schema.get("const").?) };
    }

    fn parse_enum(self: *SchemaParser, schema: ObjectMap, diag: ?*SchemaErrorInfo) SchemaError!EnumSpec {
        var spec = EnumSpec{};
        errdefer spec.json_values.deinit(self.arena);
        const arr = schema.get("enum").?;
        if (arr != .array) {
            return fail(error.InvalidSchema, diag, self.gpa, "enum must be an array");
        }
        if (arr.array.items.len == 0) {
            return fail(error.InvalidSchema, diag, self.gpa, "enum array must not be empty");
        }
        for (arr.array.items) |item| {
            try spec.json_values.append(self.arena, try serialize_json(self.arena, item));
        }
        return spec;
    }

    fn parse_ref(self: *SchemaParser, schema: ObjectMap, diag: ?*SchemaErrorInfo) SchemaError!RefSpec {
        const ref = schema.get("$ref").?;
        if (ref != .string) {
            return fail(error.InvalidSchema, diag, self.gpa, "$ref must be a string");
        }
        return .{ .uri = try self.arena.dupe(u8, ref.string) };
    }

    pub fn resolve_ref(
        self: *SchemaParser,
        uri: []const u8,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!SchemaSpecPtr {
        if (self.ref_cache.get(uri)) |spec| {
            return spec;
        }

        if (std.mem.eql(u8, uri, "#")) {
            const placeholder = try self.make(.{ .Any = {} }, "");
            try self.ref_cache.put(try self.arena.dupe(u8, uri), placeholder);
            const resolved = try self.parse(self.root_schema, null, diag);
            try self.ref_cache.put(try self.arena.dupe(u8, uri), resolved);
            return resolved;
        }

        if (!std.mem.startsWith(u8, uri, "#/")) {
            std.debug.print("URI should either be '#' or start with '#/' but got {s}\n", .{uri});
            return self.make(.{ .Any = {} }, "");
        }

        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(self.arena);
        var it = std.mem.tokenizeScalar(u8, uri[2..], '/');
        while (it.next()) |p| {
            if (p.len != 0) try parts.append(self.arena, p);
        }
        var current = self.root_schema;
        for (parts.items) |p| {
            if (current != .object) {
                return failFmt(error.InvalidSchema, diag, self.gpa, "Cannot find field {s} in {s}", .{ p, uri });
            }
            const next = current.object.get(p) orelse {
                return failFmt(error.InvalidSchema, diag, self.gpa, "Cannot find field {s} in {s}", .{ p, uri });
            };
            current = next;
        }
        const resolved = try self.parse(current, null, diag);
        try self.ref_cache.put(try self.arena.dupe(u8, uri), resolved);
        return resolved;
    }

    fn parse_any_of(self: *SchemaParser, schema: ObjectMap, diag: ?*SchemaErrorInfo) SchemaError!AnyOfSpec {
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

    fn parse_all_of(self: *SchemaParser, schema: ObjectMap, diag: ?*SchemaErrorInfo) SchemaError!AllOfSpec {
        var spec = AllOfSpec{};
        errdefer spec.schemas.deinit(self.arena);
        const arr = schema.get("allOf").?;
        if (arr != .array) {
            return fail(error.InvalidSchema, diag, self.gpa, "allOf must be an array");
        }
        for (arr.array.items) |sub| {
            const parsed = try self.parse(sub, null, diag);
            try spec.schemas.append(self.arena, parsed);
        }
        return spec;
    }

    fn parse_type_array(self: *SchemaParser, schema: ObjectMap, diag: ?*SchemaErrorInfo) SchemaError!TypeArraySpec {
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
                return fail(error.InvalidSchema, diag, self.gpa, "type must be a string or an array of strings");
            }
            try schema_copy.put(arena, try arena.dupe(u8, "type"), ty);
            const parsed = try self.parse(Value{ .object = schema_copy }, null, diag);
            try spec.type_schemas.append(arena, parsed);
        }
        return spec;
    }
};
