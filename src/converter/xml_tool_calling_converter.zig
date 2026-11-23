//! The XML tool-calling converter (Qwen, MiniMax, DeepSeek, GLM, Kimi-K3 parameter
//! lists) (`xml_tool_calling_converter.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const json_format_mod = @import("json_format.zig");
const JsonFormat = json_format_mod.JsonFormat;
const json_schema_converter_mod = @import("json_schema_converter.zig");
const JsonSchemaConverter = json_schema_converter_mod.JsonSchemaConverter;
const BASIC_ANY = json_schema_converter_mod.BASIC_ANY;
const BASIC_ARRAY = json_schema_converter_mod.BASIC_ARRAY;
const BASIC_OBJECT = json_schema_converter_mod.BASIC_OBJECT;
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
const ObjectSpec = schema_spec.ObjectSpec;
const Property = schema_spec.Property;
const SchemaSpec = schema_spec.SchemaSpec;
const SchemaSpecPtr = schema_spec.SchemaSpecPtr;
const StringSpec = schema_spec.StringSpec;
const xml_converter_mod = @import("xml_converter.zig");
const xml_wrapper_mod = @import("xml_wrapper.zig");
const XmlWrapper = xml_wrapper_mod.XmlWrapper;

pub const XML_STRING = "xml_string";
pub const XML_ANY = "xml_any";
pub const XML_OBJECT = "xml_object";
pub const XML_VARIABLE_NAME = "xml_variable_name";

const OBJECT_CACHE_KEY = "{\"type\":\"object\"}";

fn is_padding(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

/// Converts a JSON Schema into an XML tool call: the root object is a list of
/// `<key>value</key>`-style parameters whose values are raw strings or JSON.
pub const XmlToolCallingConverter = struct {
    base_conv: *JsonSchemaConverter,
    format: JsonFormat,
    /// 0 at the parameter list, 1 inside a parameter value, 2 and deeper inside JSON values.
    nested_object_level: i32,
    wrapper: XmlWrapper,
    /// DeepSeek parameter suffix rules keyed by `$ref` URI; they do not depend on the key.
    deepseek_param_ref_rules: std.StringHashMapUnmanaged(i32),

    /// Creates the converter for one of the XML parameter-list formats.
    /// Does not take ownership of `base_conv`; caller retains `base_conv.deinit()`.
    pub fn new(
        base_conv: *JsonSchemaConverter,
        format: JsonFormat,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!XmlToolCallingConverter {
        const wrapper = XmlWrapper.for_format(format) orelse {
            return schema_error_mod.reportFmt(
                error.InvalidSchema,
                diag,
                base_conv.gpa,
                "Invalid JSON format for XML tool calling: {s}",
                .{@tagName(format)},
            );
        };
        for (base_conv.excludes) |excluded| {
            if (excluded.len != 0 and (is_padding(excluded[0]) or is_padding(excluded[excluded.len - 1]))) {
                return schema_error_mod.report(
                    error.InvalidSchema,
                    diag,
                    base_conv.gpa,
                    "XML JSONSchemaFormat.excludes must not start or end with formatting whitespace",
                );
            }
        }
        return .{
            .base_conv = base_conv,
            .format = format,
            .nested_object_level = 0,
            .wrapper = wrapper,
            .deepseek_param_ref_rules = .{},
        };
    }

    /// The cache context: the parameter list, a raw parameter value, or nested JSON.
    pub fn encoding_context(self: *const XmlToolCallingConverter) i32 {
        return @min(self.nested_object_level, 2);
    }

    fn type_of_json_value(arena: Allocator, json_value: []const u8) []const u8 {
        return switch (parse_literal(arena, json_value)) {
            .string => "string",
            .bool => "boolean",
            .integer, .float, .number_string => "number",
            .null => "null",
            .object => "object",
            .array => "array",
        };
    }

    /// The single JSON type a value of `spec` is rendered with, when it is known without
    /// resolving references or combinators. Integers and numbers are both `"number"`.
    pub fn rendered_json_type(arena: Allocator, spec: ?SchemaSpecPtr) ?[]const u8 {
        const sc = spec orelse return null;
        return switch (sc.spec) {
            .String => "string",
            .Integer, .Number => "number",
            .Boolean => "boolean",
            .Null => "null",
            .Array => "array",
            .Object => "object",
            .Const => |c| type_of_json_value(arena, c.json_value),
            // Only a single type when every alternative renders with it.
            .Enum => |e| blk: {
                if (e.json_values.items.len == 0) break :blk null;
                const first = type_of_json_value(arena, e.json_values.items[0]);
                for (e.json_values.items[1..]) |val| {
                    if (!std.mem.eql(u8, type_of_json_value(arena, val), first)) break :blk null;
                }
                break :blk first;
            },
            else => null,
        };
    }

    /// The raw text of a JSON literal: a string's content, or the JSON text of other values.
    pub fn xml_value(arena: Allocator, json_value: []const u8) Allocator.Error![]const u8 {
        return switch (parse_literal(arena, json_value)) {
            .string => |text| text,
            else => arena.dupe(u8, json_value),
        };
    }

    /// Escapes an attribute value as Kimi-K3's renderer does (`&` and `"`); other formats keep it.
    pub fn escape_attr_value(self: *const XmlToolCallingConverter, arena: Allocator, value: []const u8) Allocator.Error![]const u8 {
        if (self.format != .KimiK3Xml) {
            return arena.dupe(u8, value);
        }
        var out: std.ArrayList(u8) = .empty;
        for (value) |ch| {
            switch (ch) {
                '&' => try out.appendSlice(arena, "&amp;"),
                '"' => try out.appendSlice(arena, "&quot;"),
                else => try out.append(arena, ch),
            }
        }
        return out.toOwnedSlice(arena);
    }

    // ----------------------------- SchemaConverter / XmlConverter hooks -----------------------------

    pub fn base(self: *XmlToolCallingConverter) *JsonSchemaConverter {
        return self.base_conv;
    }

    pub fn xml(self: *const XmlToolCallingConverter) *const XmlToolCallingConverter {
        return self;
    }

    pub fn xml_mut(self: *XmlToolCallingConverter) *XmlToolCallingConverter {
        return self;
    }

    pub fn add_basic_rules(self: *XmlToolCallingConverter, diag: ?*SchemaErrorInfo) SchemaError!void {
        return xml_converter_mod.xml_add_basic_rules(self, diag);
    }

    pub fn add_cache(self: *XmlToolCallingConverter, key: []const u8, rule_id: i32) Allocator.Error!void {
        if (key.len != 0) {
            const context = self.encoding_context();
            try self.base_conv.rule_cache.put(.{
                .key = try self.base_conv.arena.dupe(u8, key),
                .context = context,
            }, rule_id);
        }
    }

    pub fn get_cache(self: *XmlToolCallingConverter, key: []const u8) ?i32 {
        if (key.len == 0) return null;
        const parameter_list_any = (self.format == .QwenXml or self.format == .DeepSeekXml or self.format == .DeepSeekV41Xml) and
            self.nested_object_level == 0 and
            std.mem.eql(u8, key, "{}");
        const cache_key: JsonSchemaConverter.CacheKey = if (parameter_list_any)
            // Unconstrained tool arguments are a parameter list, not one parameter's raw value.
            .{ .key = OBJECT_CACHE_KEY, .context = 0 }
        else if (self.nested_object_level == 1 and std.mem.eql(u8, key, OBJECT_CACHE_KEY))
            // An object parameter value is a JSON object with braces, not a parameter list.
            .{ .key = key, .context = 2 }
        else
            .{ .key = key, .context = self.encoding_context() };
        return self.base_conv.rule_cache.get(cache_key);
    }

    pub fn ref_cache_key(self: *XmlToolCallingConverter, uri: []const u8) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(self.base_conv.arena, "{d}:{s}", .{ self.encoding_context(), uri });
    }

    pub fn next_separator(self: *XmlToolCallingConverter, is_end: bool) Allocator.Error![]u8 {
        if (self.nested_object_level <= 1) {
            return self.base_conv.whitespace_pattern();
        }
        return self.base_conv.indent_manager.next_separator(is_end);
    }

    pub fn key_pattern(self: *XmlToolCallingConverter) []const u8 {
        if (self.nested_object_level <= 1) {
            return XML_VARIABLE_NAME;
        }
        return BASIC_STRING;
    }

    pub fn basic_any_rule_name(self: *XmlToolCallingConverter) []const u8 {
        if (self.nested_object_level <= 1) {
            return XML_ANY;
        }
        return BASIC_ANY;
    }

    pub fn key_pattern_excluding(
        self: *XmlToolCallingConverter,
        properties: []const Property,
        rule_name: []const u8,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        if (self.nested_object_level <= 1) {
            return schema_converter_mod.key_pattern_expression(self);
        }
        return schema_converter_mod.json_key_pattern_excluding(self, properties, rule_name, diag);
    }

    pub fn generate_string(
        self: *XmlToolCallingConverter,
        spec: *const StringSpec,
        rule_name: []const u8,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        if (self.nested_object_level > 1) {
            return schema_converter_mod.json_generate_string(self, spec, rule_name, diag);
        }
        if (spec.format) |fmt| {
            if (try json_format_to_regex_pattern(self.base_conv.arena, fmt)) |regex| {
                return self.base_conv.regex_expression(regex, false, true, diag);
            }
        }
        if (spec.pattern) |pattern| {
            return self.base_conv.regex_expression(pattern, false, true, diag);
        }
        const bounded = spec.min_length != 0 or spec.max_length != -1;
        // Without exclusions, a length bound or an unrecognized format keeps the plain repetition.
        if (self.base_conv.excludes.len == 0 and (bounded or spec.format != null)) {
            return self.base_conv.raw_characters(spec, rule_name);
        }
        // With exclusions the raw string keeps only the exclusions.
        if (bounded) {
            JsonSchemaConverter.warn_dropped_length_constraints(spec, rule_name);
        }
        return self.base_conv.rule_ref_by_name(XML_STRING);
    }

    pub fn generate_array(
        self: *XmlToolCallingConverter,
        spec: *const ArraySpec,
        rule_name: []const u8,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        self.nested_object_level += 1;
        defer self.nested_object_level -= 1;
        return schema_converter_mod.json_generate_array(self, spec, rule_name, diag);
    }

    pub fn generate_object(
        self: *XmlToolCallingConverter,
        spec: *const ObjectSpec,
        rule_name: []const u8,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        self.nested_object_level += 1;
        defer self.nested_object_level -= 1;
        const need_braces = self.nested_object_level > 1;
        return schema_converter_mod.json_generate_object(self, spec, rule_name, need_braces, diag);
    }

    pub fn generate_any(self: *XmlToolCallingConverter, _: []const u8, _: ?*SchemaErrorInfo) SchemaError!i32 {
        return switch (self.nested_object_level) {
            0 => try self.base_conv.rule_ref_by_name(XML_OBJECT),
            1 => blk: {
                const names = [_][]const u8{ XML_STRING, BASIC_ARRAY, BASIC_OBJECT };
                var choices: [names.len]i32 = undefined;
                for (names, 0..) |name, i| {
                    choices[i] = try self.base_conv.rule_ref_by_name(name);
                }
                break :blk try self.base_conv.choice(&choices);
            },
            else => schema_converter_mod.json_generate_any(self),
        };
    }

    pub fn generate_const(
        self: *XmlToolCallingConverter,
        spec: *const ConstSpec,
        rule_name: []const u8,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        const arena = self.base_conv.arena;
        if (self.nested_object_level == 0) {
            const parsed = parse_literal(arena, spec.json_value);
            if (parsed == .object) {
                const members = parsed.object;
                // A root object is a parameter list, including when all its values are fixed.
                var object = try ObjectSpec.default(arena);
                object.allow_unevaluated_properties = false;
                for (members.keys(), members.values()) |key, value| {
                    const schema = try SchemaSpec.make(arena, .{
                        .Const = .{ .json_value = try serialize_json(arena, value) },
                    }, "");
                    try object.required.put(key, {});
                    try object.properties.append(arena, .{ .name = key, .schema = schema });
                }
                // A fixed order even with any_order: the any-order rule admits repeated keys.
                const saved_any_order = self.base_conv.any_order;
                self.base_conv.any_order = false;
                defer self.base_conv.any_order = saved_any_order;
                return self.generate_object(&object, rule_name, diag);
            }
        }
        if (self.nested_object_level > 1) {
            return schema_converter_mod.json_generate_literals(self, &.{spec.json_value});
        }
        if (!self.base_conv.is_allowed_json_literal(spec.json_value, true)) {
            return self.base_conv.unsatisfiable();
        }
        const raw_val = try xml_value(arena, spec.json_value);
        return self.base_conv.byte_string(raw_val);
    }

    pub fn generate_enum(
        self: *XmlToolCallingConverter,
        spec: *const EnumSpec,
        rule_name: []const u8,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        if (self.nested_object_level > 1) {
            return schema_converter_mod.json_generate_literals(self, spec.json_values.items);
        }
        const arena = self.base_conv.arena;
        var values: std.ArrayList(i32) = .empty;
        try values.ensureTotalCapacity(arena, spec.json_values.items.len);
        for (spec.json_values.items) |json_value| {
            const literal = ConstSpec{ .json_value = json_value };
            try values.append(arena, try self.generate_const(&literal, rule_name, diag));
        }
        return self.base_conv.choice(values.items);
    }

    pub fn format_property_key(
        self: *XmlToolCallingConverter,
        key: []const u8,
        schema: SchemaSpecPtr,
    ) Allocator.Error!i32 {
        return xml_converter_mod.xml_format_property_key(self, key, schema);
    }

    pub fn format_property(
        self: *XmlToolCallingConverter,
        key: []const u8,
        value_rule_id: i32,
        _: []const u8,
        _: usize,
        schema: SchemaSpecPtr,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        return xml_converter_mod.xml_format_property(self, key, value_rule_id, schema, diag);
    }

    pub fn format_other_property(
        self: *XmlToolCallingConverter,
        key_pattern_id: i32,
        value_rule_id: i32,
        _: []const u8,
        _: []const u8,
        schema: ?SchemaSpecPtr,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        return xml_converter_mod.xml_format_other_property(self, key_pattern_id, value_rule_id, schema, diag);
    }
};
