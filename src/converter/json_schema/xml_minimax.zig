//! The MiniMax-M3 XML tool-calling converter (`minimax_m3_xml_tool_calling_converter.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const Diagnostic = @import("../../Diagnostic.zig").Diagnostic;
const converter_mod = @import("converter.zig");
const JsonSchemaConverter = converter_mod.JsonSchemaConverter;
const BASIC_BOOLEAN = converter_mod.BASIC_BOOLEAN;
const BASIC_INTEGER = converter_mod.BASIC_INTEGER;
const BASIC_NULL = converter_mod.BASIC_NULL;
const BASIC_NUMBER = converter_mod.BASIC_NUMBER;
const BASIC_STRING = converter_mod.BASIC_STRING;
const generator = @import("generator.zig");
const parser_mod = @import("parser.zig");
const SchemaError = parser_mod.SchemaError;
const Value = parser_mod.Value;
const spec_mod = @import("spec.zig");
const ArraySpec = spec_mod.ArraySpec;
const ConstSpec = spec_mod.ConstSpec;
const EnumSpec = spec_mod.EnumSpec;
const IntegerSpec = spec_mod.IntegerSpec;
const NumberSpec = spec_mod.NumberSpec;
const ObjectSpec = spec_mod.ObjectSpec;
const SchemaSpecPtr = spec_mod.SchemaSpecPtr;
const StringSpec = spec_mod.StringSpec;

/// The namespace marker that prefixes every MiniMax-M3 element tag.
const NAMESPACE = "]<]minimax[>[";
/// The element name of array items.
const ARRAY_ITEM_NAME = "item";

/// Converts a JSON Schema into MiniMax-M3's recursive namespace-prefixed elements:
/// `]<]minimax[>[<name>value]<]minimax[>[</name>`.
pub const MiniMaxM3XmlToolCallingConverter = struct {
    base_conv: *JsonSchemaConverter,

    pub fn init(base_conv: *JsonSchemaConverter) MiniMaxM3XmlToolCallingConverter {
        return .{ .base_conv = base_conv };
    }

    pub fn base(self: *MiniMaxM3XmlToolCallingConverter) *JsonSchemaConverter {
        return self.base_conv;
    }

    fn formatElement(
        self: *MiniMaxM3XmlToolCallingConverter,
        name: []const u8,
        value_rule_id: i32,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        try validateElementName(self.base_conv.gpa, diag, name);
        const arena = self.base_conv.arena;
        const open_str = try std.fmt.allocPrint(arena, "{s}<{s}>", .{ NAMESPACE, name });
        const close_str = try std.fmt.allocPrint(arena, "{s}</{s}>", .{ NAMESPACE, name });
        const open = try self.base_conv.byteString(open_str);
        const value = try self.base_conv.ruleRef(value_rule_id);
        const close = try self.base_conv.byteString(close_str);
        return self.base_conv.sequence(&.{ open, value, close });
    }

    fn generateLiteral(
        self: *MiniMaxM3XmlToolCallingConverter,
        value: Value,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        const b = self.base_conv;
        const arena = b.arena;
        switch (value) {
            .string => |text| {
                if (std.mem.indexOf(u8, text, NAMESPACE) != null) {
                    return parser_mod.failStatic(
                        error.InvalidSchema,
                        diag,
                        "A minimax_m3_xml string literal cannot contain the namespace marker",
                    );
                }
                return b.byteString(text);
            },
            .object => |members| {
                var properties: std.ArrayList(i32) = .empty;
                try properties.ensureTotalCapacity(arena, members.count());
                for (members.keys(), members.values()) |key, member| {
                    const value_expr = try self.generateLiteral(member, diag);
                    const hint = try std.fmt.allocPrint(arena, "literal_{s}", .{key});
                    const value_rule_id = try b.builder.addRuleWithHint(hint, value_expr);
                    try properties.append(arena, try self.formatElement(key, value_rule_id, diag));
                }
                return b.sequence(properties.items);
            },
            .array => |items| {
                var elements: std.ArrayList(i32) = .empty;
                try elements.ensureTotalCapacity(arena, items.items.len);
                for (items.items, 0..) |item, index| {
                    const value_expr = try self.generateLiteral(item, diag);
                    const hint = try std.fmt.allocPrint(arena, "literal_item_{d}", .{index});
                    const value_rule_id = try b.builder.addRuleWithHint(hint, value_expr);
                    try elements.append(arena, try self.formatElement(ARRAY_ITEM_NAME, value_rule_id, diag));
                }
                return b.sequence(elements.items);
            },
            else => {
                const ser = try parser_mod.serializeJson(arena, value);
                return b.byteString(ser);
            },
        }
    }

    // ----------------------------- hook overrides -----------------------------

    pub fn addBasicRules(self: *MiniMaxM3XmlToolCallingConverter, diag: ?*Diagnostic) SchemaError!void {
        const b = self.base_conv;
        for ([_][]const u8{ BASIC_INTEGER, BASIC_NUMBER, BASIC_STRING, BASIC_BOOLEAN, BASIC_NULL }) |name| {
            _ = try b.builder.addEmptyRule(name);
        }
        const default_int = IntegerSpec{};
        var body = try b.generateInteger(&default_int, BASIC_INTEGER, diag);
        try generator.setBasicRule(self, BASIC_INTEGER, body, "{\"type\":\"integer\"}");

        const default_num = NumberSpec{};
        body = try b.generateNumber(&default_num, BASIC_NUMBER, diag);
        try generator.setBasicRule(self, BASIC_NUMBER, body, "{\"type\":\"number\"}");

        body = try b.tagDispatch(false, &.{NAMESPACE});
        try generator.setBasicRule(self, BASIC_STRING, body, "{\"type\":\"string\"}");

        body = try b.generateBoolean();
        try generator.setBasicRule(self, BASIC_BOOLEAN, body, "{\"type\":\"boolean\"}");

        body = try b.generateNull();
        try generator.setBasicRule(self, BASIC_NULL, body, "{\"type\":\"null\"}");
    }

    pub fn nextSeparator(self: *MiniMaxM3XmlToolCallingConverter, _: bool) Allocator.Error![]u8 {
        return self.base_conv.whitespacePattern();
    }

    pub fn generateString(
        self: *MiniMaxM3XmlToolCallingConverter,
        spec: *const StringSpec,
        _: []const u8,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        const b = self.base_conv;
        const has_known_format = if (spec.format) |fmt|
            (try parser_mod.jsonFormatToRegexPattern(b.arena, fmt)) != null
        else
            false;
        if (spec.pattern != null or has_known_format or spec.min_length != 0 or spec.max_length != -1) {
            return parser_mod.failStatic(
                error.InvalidSchema,
                diag,
                "String pattern, recognized format, and length constraints are not supported by minimax_m3_xml because they cannot be combined with the namespace-marker exclusion",
            );
        }
        return b.ruleRefByName(BASIC_STRING);
    }

    pub fn generateArray(
        self: *MiniMaxM3XmlToolCallingConverter,
        spec: *const ArraySpec,
        rule_name: []const u8,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        const b = self.base_conv;
        const arena = b.arena;
        var prefix_items: std.ArrayList(i32) = .empty;
        try prefix_items.ensureTotalCapacity(arena, spec.prefix_items.items.len);
        for (spec.prefix_items.items, 0..) |item, index| {
            const hint = try std.fmt.allocPrint(arena, "{s}_item_{d}", .{ rule_name, index });
            const item_rule_id = try generator.createRule(self, item, hint, diag);
            try prefix_items.append(arena, try self.formatElement(ARRAY_ITEM_NAME, item_rule_id, diag));
        }
        const additional_item: ?i32 = if (spec.allow_additional_items) blk: {
            const additional = spec.additional_items orelse {
                return parser_mod.failStatic(
                    error.InvalidSchema,
                    diag,
                    "minimax_m3_xml requires a fixed schema for array items",
                );
            };
            const hint = try std.fmt.allocPrint(arena, "{s}_additional", .{rule_name});
            const item_rule_id = try generator.createRule(self, additional, hint, diag);
            break :blk try self.formatElement(ARRAY_ITEM_NAME, item_rule_id, diag);
        } else null;

        const empty_expr = try b.empty();
        const whitespace = try b.whitespaceExpression();
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
            const tail_rule_id = try b.builder.addRuleWithHint(tail_hint, body);
            tail = try b.ruleRef(tail_rule_id);
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

    pub fn generateObject(
        self: *MiniMaxM3XmlToolCallingConverter,
        spec: *const ObjectSpec,
        rule_name: []const u8,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        try validateObject(self.base_conv.gpa, self.base_conv.arena, diag, spec);
        const saved_any_whitespace = self.base_conv.any_whitespace;
        self.base_conv.any_whitespace = false;
        defer self.base_conv.any_whitespace = saved_any_whitespace;
        return generator.jsonGenerateObject(self, spec, rule_name, false, diag);
    }

    pub fn generateAny(_: *MiniMaxM3XmlToolCallingConverter, _: []const u8, diag: ?*Diagnostic) SchemaError!i32 {
        return parser_mod.failStatic(
            error.InvalidSchema,
            diag,
            "minimax_m3_xml does not support unconstrained schemas",
        );
    }

    pub fn generateConst(
        self: *MiniMaxM3XmlToolCallingConverter,
        spec: *const ConstSpec,
        _: []const u8,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        return self.generateLiteral(converter_mod.parseLiteral(self.base_conv.arena, spec.json_value), diag);
    }

    pub fn generateEnum(
        self: *MiniMaxM3XmlToolCallingConverter,
        spec: *const EnumSpec,
        _: []const u8,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        const b = self.base_conv;
        var values: std.ArrayList(i32) = .empty;
        try values.ensureTotalCapacity(b.arena, spec.json_values.items.len);
        for (spec.json_values.items) |json_value| {
            try values.append(b.arena, try self.generateLiteral(converter_mod.parseLiteral(b.arena, json_value), diag));
        }
        return b.choice(values.items);
    }

    pub fn formatProperty(
        self: *MiniMaxM3XmlToolCallingConverter,
        key: []const u8,
        value_rule_id: i32,
        _: []const u8,
        _: usize,
        _: SchemaSpecPtr,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        return self.formatElement(key, value_rule_id, diag);
    }
};

fn validateObject(
    gpa: Allocator,
    arena: Allocator,
    diag: ?*Diagnostic,
    spec: *const ObjectSpec,
) SchemaError!void {
    if (spec.allow_additional_properties or
        spec.additional_properties_schema != null or
        spec.allow_unevaluated_properties or
        spec.unevaluated_properties_schema != null or
        spec.pattern_properties.items.len != 0 or
        spec.property_names != null)
    {
        return parser_mod.failStatic(
            error.InvalidSchema,
            diag,
            "minimax_m3_xml requires fixed object property names; additionalProperties, unevaluatedProperties, patternProperties, and propertyNames are not supported",
        );
    }
    var property_names: std.StringHashMapUnmanaged(void) = .empty;
    try property_names.ensureTotalCapacity(arena, @intCast(spec.properties.items.len));
    for (spec.properties.items) |property| {
        try validateElementName(gpa, diag, property.name);
        try property_names.put(arena, property.name, {});
    }
    var req_it = spec.required.keyIterator();
    while (req_it.next()) |required| {
        if (!property_names.contains(required.*)) {
            return parser_mod.failFmt(
                error.InvalidSchema,
                diag,
                gpa,
                "minimax_m3_xml required property has no fixed schema: {s}",
                .{required.*},
            );
        }
    }
}

fn validateElementName(gpa: Allocator, diag: ?*Diagnostic, name: []const u8) SchemaError!void {
    if (name.len == 0 or name[0] == '/' or std.mem.indexOfScalar(u8, name, '>') != null) {
        return parser_mod.failFmt(error.InvalidSchema, diag, gpa, "Invalid minimax_m3_xml element name: {s}", .{name});
    }
    var all_blank = true;
    for (name) |byte| {
        if (!(byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0c or byte == 0x0b)) {
            all_blank = false;
            break;
        }
    }
    if (all_blank) {
        return parser_mod.failStatic(error.InvalidSchema, diag, "minimax_m3_xml element names cannot be blank");
    }
}

test "MiniMaxM3XmlToolCallingConverter element name validation" {
    const a = std.testing.allocator;
    var diag: Diagnostic = .{};
    defer diag.deinit(a);

    try validateElementName(a, &diag, "valid_name");
    try std.testing.expectError(error.InvalidSchema, validateElementName(a, &diag, "/bad"));
    try std.testing.expectError(error.InvalidSchema, validateElementName(a, &diag, "   "));
    try std.testing.expectEqualStrings("minimax_m3_xml element names cannot be blank", diag.message);

    std.testing.refAllDecls(@This());
}
