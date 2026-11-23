//! The MiniMax-M3 XML tool-calling converter (`minimax_m3_xml_tool_calling_converter.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const json_schema_converter_mod = @import("json_schema_converter.zig");
const JsonSchemaConverter = json_schema_converter_mod.JsonSchemaConverter;
const BASIC_BOOLEAN = json_schema_converter_mod.BASIC_BOOLEAN;
const BASIC_INTEGER = json_schema_converter_mod.BASIC_INTEGER;
const BASIC_NULL = json_schema_converter_mod.BASIC_NULL;
const BASIC_NUMBER = json_schema_converter_mod.BASIC_NUMBER;
const BASIC_STRING = json_schema_converter_mod.BASIC_STRING;
const json_format_to_regex_pattern = json_schema_converter_mod.json_format_to_regex_pattern;
const parse_literal = json_schema_converter_mod.parse_literal;
const schema_converter_mod = @import("schema_converter.zig");
const schema_error_mod = @import("schema_error.zig");
const SchemaError = schema_error_mod.SchemaError;
const SchemaErrorInfo = schema_error_mod.SchemaErrorInfo;
const schema_parser_mod = @import("schema_parser.zig");
const Value = schema_parser_mod.Value;
const serialize_json = schema_parser_mod.serialize_json;
const schema_spec = @import("schema_spec.zig");
const ArraySpec = schema_spec.ArraySpec;
const ConstSpec = schema_spec.ConstSpec;
const EnumSpec = schema_spec.EnumSpec;
const IntegerSpec = schema_spec.IntegerSpec;
const NumberSpec = schema_spec.NumberSpec;
const ObjectSpec = schema_spec.ObjectSpec;
const SchemaSpecPtr = schema_spec.SchemaSpecPtr;
const StringSpec = schema_spec.StringSpec;

/// The namespace marker that prefixes every MiniMax-M3 element tag.
const NAMESPACE = "]<]minimax[>[";
/// The element name of array items.
const ARRAY_ITEM_NAME = "item";

/// Converts a JSON Schema into MiniMax-M3's recursive namespace-prefixed elements:
/// `]<]minimax[>[<name>value]<]minimax[>[</name>`, where objects are sequences of named
/// elements and arrays sequences of `item` elements. Element names must be known when the
/// grammar is built, so schemas requiring runtime names are rejected.
pub const MiniMaxM3XmlToolCallingConverter = struct {
    base_conv: *JsonSchemaConverter,

    /// Creates the converter.
    pub fn new(base_conv: *JsonSchemaConverter) MiniMaxM3XmlToolCallingConverter {
        return .{ .base_conv = base_conv };
    }

    pub fn base(self: *MiniMaxM3XmlToolCallingConverter) *JsonSchemaConverter {
        return self.base_conv;
    }

    /// One element named `name` around the value rule.
    fn format_element(
        self: *MiniMaxM3XmlToolCallingConverter,
        name: []const u8,
        value_rule_id: i32,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        try validate_element_name(self.base_conv.gpa, diag, name);
        const arena = self.base_conv.arena;
        const open_str = try std.fmt.allocPrint(arena, "{s}<{s}>", .{ NAMESPACE, name });
        const close_str = try std.fmt.allocPrint(arena, "{s}</{s}>", .{ NAMESPACE, name });
        const open = try self.base_conv.byte_string(open_str);
        const value = try self.base_conv.rule_ref(value_rule_id);
        const close = try self.base_conv.byte_string(close_str);
        return self.base_conv.sequence(&.{ open, value, close });
    }

    /// A literal value: strings are raw text, objects and arrays nested elements.
    fn generate_literal(
        self: *MiniMaxM3XmlToolCallingConverter,
        value: Value,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        const b = self.base_conv;
        const arena = b.arena;
        switch (value) {
            .string => |text| {
                if (std.mem.indexOf(u8, text, NAMESPACE) != null) {
                    return schema_error_mod.report(
                        error.InvalidSchema,
                        diag,
                        b.gpa,
                        "A minimax_m3_xml string literal cannot contain the namespace marker",
                    );
                }
                return b.byte_string(text);
            },
            .object => |members| {
                // `serde_json` in xgrammar-rs 0.2.8 enables `preserve_order`, matching
                // `std.json.ObjectMap`'s insertion order directly.
                var properties: std.ArrayList(i32) = .empty;
                try properties.ensureTotalCapacity(arena, members.count());
                for (members.keys(), members.values()) |key, member| {
                    const value_expr = try self.generate_literal(member, diag);
                    const hint = try std.fmt.allocPrint(arena, "literal_{s}", .{key});
                    const value_rule_id = try b.builder.add_rule_with_hint(hint, value_expr);
                    try properties.append(arena, try self.format_element(key, value_rule_id, diag));
                }
                return b.sequence(properties.items);
            },
            .array => |items| {
                var elements: std.ArrayList(i32) = .empty;
                try elements.ensureTotalCapacity(arena, items.items.len);
                for (items.items, 0..) |item, index| {
                    const value_expr = try self.generate_literal(item, diag);
                    const hint = try std.fmt.allocPrint(arena, "literal_item_{d}", .{index});
                    const value_rule_id = try b.builder.add_rule_with_hint(hint, value_expr);
                    try elements.append(arena, try self.format_element(ARRAY_ITEM_NAME, value_rule_id, diag));
                }
                return b.sequence(elements.items);
            },
            else => {
                const ser = try serialize_json(arena, value);
                return b.byte_string(ser);
            },
        }
    }

    // ----------------------------- SchemaConverter hooks -----------------------------

    pub fn add_basic_rules(self: *MiniMaxM3XmlToolCallingConverter, diag: ?*SchemaErrorInfo) SchemaError!void {
        const b = self.base_conv;
        for ([_][]const u8{ BASIC_INTEGER, BASIC_NUMBER, BASIC_STRING, BASIC_BOOLEAN, BASIC_NULL }) |name| {
            _ = try b.builder.add_empty_rule(name);
        }
        const default_int = IntegerSpec{};
        var body = try b.generate_integer(&default_int, BASIC_INTEGER, diag);
        try schema_converter_mod.set_basic_rule(self, BASIC_INTEGER, body, "{\"type\":\"integer\"}");

        const default_num = NumberSpec{};
        body = try b.generate_number(&default_num, BASIC_NUMBER, diag);
        try schema_converter_mod.set_basic_rule(self, BASIC_NUMBER, body, "{\"type\":\"number\"}");

        body = try b.tag_dispatch(false, &.{NAMESPACE});
        try schema_converter_mod.set_basic_rule(self, BASIC_STRING, body, "{\"type\":\"string\"}");

        body = try b.generate_boolean();
        try schema_converter_mod.set_basic_rule(self, BASIC_BOOLEAN, body, "{\"type\":\"boolean\"}");

        body = try b.generate_null();
        try schema_converter_mod.set_basic_rule(self, BASIC_NULL, body, "{\"type\":\"null\"}");
    }

    pub fn next_separator(self: *MiniMaxM3XmlToolCallingConverter, _: bool) Allocator.Error![]u8 {
        return self.base_conv.whitespace_pattern();
    }

    pub fn generate_string(
        self: *MiniMaxM3XmlToolCallingConverter,
        spec: *const StringSpec,
        _: []const u8,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        const b = self.base_conv;
        const has_known_format = if (spec.format) |fmt|
            (try json_format_to_regex_pattern(b.arena, fmt)) != null
        else
            false;
        if (spec.pattern != null or has_known_format or spec.min_length != 0 or spec.max_length != -1) {
            return schema_error_mod.report(
                error.InvalidSchema,
                diag,
                b.gpa,
                "String pattern, recognized format, and length constraints are not supported by minimax_m3_xml because they cannot be combined with the namespace-marker exclusion",
            );
        }
        return b.rule_ref_by_name(BASIC_STRING);
    }

    pub fn generate_array(
        self: *MiniMaxM3XmlToolCallingConverter,
        spec: *const ArraySpec,
        rule_name: []const u8,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        const b = self.base_conv;
        const arena = b.arena;
        var prefix_items: std.ArrayList(i32) = .empty;
        try prefix_items.ensureTotalCapacity(arena, spec.prefix_items.items.len);
        for (spec.prefix_items.items, 0..) |item, index| {
            const hint = try std.fmt.allocPrint(arena, "{s}_item_{d}", .{ rule_name, index });
            const item_rule_id = try schema_converter_mod.create_rule(self, item, hint, diag);
            try prefix_items.append(arena, try self.format_element(ARRAY_ITEM_NAME, item_rule_id, diag));
        }
        const additional_item: ?i32 = if (spec.allow_additional_items) blk: {
            const additional = spec.additional_items orelse {
                return schema_error_mod.report(
                    error.InvalidSchema,
                    diag,
                    b.gpa,
                    "minimax_m3_xml requires a fixed schema for array items",
                );
            };
            const hint = try std.fmt.allocPrint(arena, "{s}_additional", .{rule_name});
            const item_rule_id = try schema_converter_mod.create_rule(self, additional, hint, diag);
            break :blk try self.format_element(ARRAY_ITEM_NAME, item_rule_id, diag);
        } else null;

        const empty_expr = try b.empty();
        const whitespace = try b.whitespace_expression();
        // The parser bounds item counts to int32.
        const min_items: i32 = @intCast(spec.min_items);
        const max_items: i32 = @intCast(spec.max_items);
        if (prefix_items.items.len == 0) {
            const add = if (max_items != 0) additional_item else null;
            if (add == null) {
                return empty_expr;
            }
            const separated = try b.sequence(&.{ whitespace, add.? });
            const hint = try std.fmt.allocPrint(arena, "{s}_items", .{rule_name});
            const rest = try b.repeat(
                hint,
                separated,
                @max(min_items - 1, 0),
                if (max_items == -1) -1 else @max(max_items - 1, 0),
            );
            const nonempty = try b.sequence(&.{ whitespace, add.?, rest, whitespace });
            return if (min_items == 0)
                try b.choice(&.{ nonempty, empty_expr })
            else
                nonempty;
        }

        const first_item = prefix_items.items[0];
        const prefix_count: i32 = @intCast(prefix_items.items.len);
        var tail = empty_expr;
        if (additional_item) |add| {
            const separated = try b.sequence(&.{ whitespace, add });
            const hint = try std.fmt.allocPrint(arena, "{s}_additional_items", .{rule_name});
            tail = try b.repeat(
                hint,
                separated,
                @max(min_items - prefix_count, 0),
                if (max_items == -1) -1 else @max(max_items - prefix_count, 0),
            );
        }
        // A prefix item constrains its position without making it mandatory: the chain can stop
        // once minItems is satisfied.
        var index: i32 = prefix_count - 1;
        while (index > 0) {
            index -= 1;
            const emitted_count = index + 1;
            const can_stop = emitted_count >= min_items;
            const can_continue = max_items == -1 or emitted_count < max_items;
            var body = empty_expr;
            if (can_continue) {
                const continuation = try b.sequence(&.{ whitespace, prefix_items.items[@intCast(index + 1)], tail });
                body = if (can_stop)
                    try b.choice(&.{ continuation, empty_expr })
                else
                    continuation;
            }
            const tail_hint = try std.fmt.allocPrint(arena, "{s}_prefix_tail_{d}", .{ rule_name, index });
            const tail_rule_id = try b.builder.add_rule_with_hint(tail_hint, body);
            tail = try b.rule_ref(tail_rule_id);
        }
        if (max_items == 0) {
            return empty_expr;
        }
        const nonempty = try b.sequence(&.{ whitespace, first_item, tail, whitespace });
        return if (min_items == 0)
            try b.choice(&.{ nonempty, empty_expr })
        else
            nonempty;
    }

    pub fn generate_object(
        self: *MiniMaxM3XmlToolCallingConverter,
        spec: *const ObjectSpec,
        rule_name: []const u8,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        try validate_object(self.base_conv.gpa, self.base_conv.arena, diag, spec);
        const saved_any_whitespace = self.base_conv.any_whitespace;
        self.base_conv.any_whitespace = false;
        defer self.base_conv.any_whitespace = saved_any_whitespace;
        return schema_converter_mod.json_generate_object(self, spec, rule_name, false, diag);
    }

    pub fn generate_any(self: *MiniMaxM3XmlToolCallingConverter, _: []const u8, diag: ?*SchemaErrorInfo) SchemaError!i32 {
        return schema_error_mod.report(
            error.InvalidSchema,
            diag,
            self.base_conv.gpa,
            "minimax_m3_xml does not support unconstrained schemas",
        );
    }

    pub fn generate_const(
        self: *MiniMaxM3XmlToolCallingConverter,
        spec: *const ConstSpec,
        _: []const u8,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        return self.generate_literal(parse_literal(self.base_conv.arena, spec.json_value), diag);
    }

    pub fn generate_enum(
        self: *MiniMaxM3XmlToolCallingConverter,
        spec: *const EnumSpec,
        _: []const u8,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        const b = self.base_conv;
        var values: std.ArrayList(i32) = .empty;
        try values.ensureTotalCapacity(b.arena, spec.json_values.items.len);
        for (spec.json_values.items) |json_value| {
            try values.append(b.arena, try self.generate_literal(parse_literal(b.arena, json_value), diag));
        }
        return b.choice(values.items);
    }

    pub fn format_property(
        self: *MiniMaxM3XmlToolCallingConverter,
        key: []const u8,
        value_rule_id: i32,
        _: []const u8,
        _: usize,
        _: SchemaSpecPtr,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        return self.format_element(key, value_rule_id, diag);
    }
};

/// Rejects objects whose element names are not all known when the grammar is built.
fn validate_object(
    gpa: Allocator,
    arena: Allocator,
    diag: ?*SchemaErrorInfo,
    spec: *const ObjectSpec,
) SchemaError!void {
    if (spec.allow_additional_properties or
        spec.additional_properties_schema != null or
        spec.allow_unevaluated_properties or
        spec.unevaluated_properties_schema != null or
        spec.pattern_properties.items.len != 0 or
        spec.property_names != null)
    {
        return schema_error_mod.report(
            error.InvalidSchema,
            diag,
            gpa,
            "minimax_m3_xml requires fixed object property names; additionalProperties, unevaluatedProperties, patternProperties, and propertyNames are not supported",
        );
    }
    var property_names = std.StringHashMap(void).init(arena);
    try property_names.ensureTotalCapacity(@intCast(spec.properties.items.len));
    for (spec.properties.items) |property| {
        try validate_element_name(gpa, diag, property.name);
        try property_names.put(property.name, {});
    }
    var req_it = spec.required.keyIterator();
    while (req_it.next()) |required| {
        if (!property_names.contains(required.*)) {
            return schema_error_mod.reportFmt(
                error.InvalidSchema,
                diag,
                gpa,
                "minimax_m3_xml required property has no fixed schema: {s}",
                .{required.*},
            );
        }
    }
}

/// Rejects element names that cannot be parsed back from the tags.
fn validate_element_name(gpa: Allocator, diag: ?*SchemaErrorInfo, name: []const u8) SchemaError!void {
    if (name.len == 0 or name[0] == '/' or std.mem.indexOfScalar(u8, name, '>') != null) {
        return schema_error_mod.reportFmt(error.InvalidSchema, diag, gpa, "Invalid minimax_m3_xml element name: {s}", .{name});
    }
    var all_blank = true;
    for (name) |byte| {
        if (!(byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0c or byte == 0x0b)) {
            all_blank = false;
            break;
        }
    }
    if (all_blank) {
        return schema_error_mod.report(error.InvalidSchema, diag, gpa, "minimax_m3_xml element names cannot be blank");
    }
}
