//! The XML tool-calling encoding shared by the XML parameter-list converters
//! (`xml_converter.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const json_format_mod = @import("json_format.zig");
const JsonFormat = json_format_mod.JsonFormat;
const json_schema_converter_mod = @import("json_schema_converter.zig");
const ascii_class = json_schema_converter_mod.ascii_class;
const BASIC_ARRAY = json_schema_converter_mod.BASIC_ARRAY;
const BASIC_BOOLEAN = json_schema_converter_mod.BASIC_BOOLEAN;
const BASIC_NULL = json_schema_converter_mod.BASIC_NULL;
const BASIC_NUMBER = json_schema_converter_mod.BASIC_NUMBER;
const BASIC_OBJECT = json_schema_converter_mod.BASIC_OBJECT;
const schema_converter_mod = @import("schema_converter.zig");
const schema_error_mod = @import("schema_error.zig");
const SchemaError = schema_error_mod.SchemaError;
const SchemaErrorInfo = schema_error_mod.SchemaErrorInfo;
const schema_spec = @import("schema_spec.zig");
const ConstSpec = schema_spec.ConstSpec;
const ObjectSpec = schema_spec.ObjectSpec;
const SchemaSpec = schema_spec.SchemaSpec;
const SchemaSpecPtr = schema_spec.SchemaSpecPtr;
const xml_tool_calling_converter_mod = @import("xml_tool_calling_converter.zig");
const XmlToolCallingConverter = xml_tool_calling_converter_mod.XmlToolCallingConverter;
const XML_ANY = xml_tool_calling_converter_mod.XML_ANY;
const XML_OBJECT = xml_tool_calling_converter_mod.XML_OBJECT;
const XML_STRING = xml_tool_calling_converter_mod.XML_STRING;
const XML_VARIABLE_NAME = xml_tool_calling_converter_mod.XML_VARIABLE_NAME;
const xml_wrapper_mod = @import("xml_wrapper.zig");
const XmlWrapper = xml_wrapper_mod.XmlWrapper;
const grammar_mod = @import("../grammar/mod.zig");
const CharacterClassElement = grammar_mod.CharacterClassElement;

/// The JSON basic rules at level 2, then the XML rules: `xml_string` (raw text up to the
/// parameter end), `xml_any`, `xml_object` (the parameter list), and `xml_variable_name`.
pub fn xml_add_basic_rules(self: anytype, diag: ?*SchemaErrorInfo) SchemaError!void {
    const b = self.base();
    const arena = b.arena;
    self.xml_mut().nested_object_level = 2;
    try schema_converter_mod.json_add_basic_rules(self, &.{ XML_STRING, XML_ANY, XML_OBJECT, XML_VARIABLE_NAME }, diag);
    const any_spec = try SchemaSpec.make(arena, .{ .Any = {} }, "{}");

    self.xml_mut().nested_object_level = 1;
    // The unrestricted raw body is one TagDispatch; the parameter suffix is matched by the
    // enclosing property rule, outside this body's exclusion scope.
    var string_excludes: std.ArrayList([]const u8) = .empty;
    try string_excludes.appendSlice(arena, b.excludes);
    try string_excludes.append(arena, self.xml().wrapper.parameter_suffix);
    var body = try b.tag_dispatch(false, string_excludes.items);
    try schema_converter_mod.set_basic_rule(self, XML_STRING, body, "{\"type\":\"string\"}");
    body = try schema_converter_mod.generate_any(self, XML_ANY, diag);
    try schema_converter_mod.set_basic_rule(self, XML_ANY, body, "{}");

    self.xml_mut().nested_object_level = 0;
    var object_spec = try ObjectSpec.default(arena);
    object_spec.allow_additional_properties = true;
    object_spec.additional_properties_schema = any_spec;
    body = try schema_converter_mod.generate_object(self, &object_spec, XML_OBJECT, diag);
    try schema_converter_mod.set_basic_rule(self, XML_OBJECT, body, "{\"type\":\"object\"}");

    body = if (b.excludes.len == 0) blk: {
        const id_first = try identifier_class(arena, false);
        const id_rest = try identifier_class(arena, true);
        const first = try b.builder.add_character_class(id_first, false);
        const rest = try b.builder.add_character_class_star(id_rest, false);
        break :blk try b.sequence(&.{ first, rest });
    } else try b.excluding_string("[a-zA-Z_][a-zA-Z0-9_]*", XML_VARIABLE_NAME, false, &.{}, diag);
    try b.builder.update_rule_body_by_name(XML_VARIABLE_NAME, body);
}

/// The opening of a declared parameter (key prefix, escaped key, and key suffix).
pub fn xml_format_property_key(
    self: anytype,
    key: []const u8,
    schema: SchemaSpecPtr,
) Allocator.Error!i32 {
    const b = self.base();
    if (self.xml().nested_object_level > 1) {
        return b.json_property_key(key);
    }
    // Only kimi_k3_xml encodes the value's type next to the key.
    const pinned_type = if (self.xml().format == .KimiK3Xml)
        XmlToolCallingConverter.rendered_json_type(b.arena, schema)
    else
        null;
    const escaped = try self.xml().escape_attr_value(b.arena, key);
    if (!b.is_allowed_string(escaped)) {
        return b.unsatisfiable();
    }
    const prefix_str = try std.fmt.allocPrint(b.arena, "{s}{s}", .{ self.xml().wrapper.key_prefix, escaped });
    const prefix = try b.byte_string(prefix_str);
    const suffix = try xml_key_suffix(self, pinned_type);
    return b.sequence(&.{ prefix, suffix });
}

/// The expression between a parameter's key and its value. For Kimi-K3 it carries the type
/// attribute: `pinned_type` for a declared property, every type for a free-form key.
pub fn xml_key_suffix(
    self: anytype,
    pinned_type: ?[]const u8,
) Allocator.Error!i32 {
    const key_suffix = self.xml().wrapper.key_suffix;
    const is_kimi = self.xml().format == .KimiK3Xml;
    const b = self.base();
    if (!is_kimi) {
        return b.byte_string(key_suffix);
    }
    const type_expr = if (pinned_type) |pt|
        try b.byte_string(pt)
    else blk: {
        var choices: [XmlWrapper.KIMI_K3_TYPES.len]i32 = undefined;
        for (XmlWrapper.KIMI_K3_TYPES, 0..) |value, i| {
            choices[i] = try b.byte_string(value);
        }
        break :blk try b.choice(&choices);
    };
    const prefix = try b.byte_string(XmlWrapper.KIMI_K3_TYPE_PREFIX);
    const suffix = try b.byte_string(XmlWrapper.KIMI_K3_TYPE_SUFFIX);
    return b.sequence(&.{ prefix, type_expr, suffix });
}

/// A declared parameter at the parameter-list level, or a JSON member below it.
pub fn xml_format_property(
    self: anytype,
    key: []const u8,
    value_rule_id: i32,
    schema: SchemaSpecPtr,
    diag: ?*SchemaErrorInfo,
) SchemaError!i32 {
    const b = self.base();
    if (self.xml().nested_object_level > 1) {
        const key_id = try b.json_property_key(key);
        return b.json_member(key_id, value_rule_id);
    }
    if (self.xml().format.is_deepseek()) {
        if (!b.is_allowed_string(key)) {
            return b.unsatisfiable();
        }
        const prefix_str = try std.fmt.allocPrint(b.arena, "{s}{s}", .{ self.xml().wrapper.key_prefix, key });
        const prefix = try b.byte_string(prefix_str);
        const suffix = try format_deepseek_param_suffix(self, schema, value_rule_id, "", diag);
        return b.sequence(&.{ prefix, suffix });
    }
    const key_id = try schema_converter_mod.format_property_key(self, key, schema);
    return xml_parameter_value(self, &.{key_id}, value_rule_id);
}

/// A free-form parameter (`key_pattern` names it) at the parameter-list level, or a JSON
/// member below it.
pub fn xml_format_other_property(
    self: anytype,
    key_pattern: i32,
    value_rule_id: i32,
    schema: ?SchemaSpecPtr,
    diag: ?*SchemaErrorInfo,
) SchemaError!i32 {
    const b = self.base();
    if (self.xml().nested_object_level > 1) {
        return b.json_member(key_pattern, value_rule_id);
    }
    const key_prefix = self.xml().wrapper.key_prefix;
    const prefix = try b.byte_string(key_prefix);
    if (self.xml().format.is_deepseek()) {
        const suffix = try format_deepseek_param_suffix(self, schema, value_rule_id, "", diag);
        return b.sequence(&.{ prefix, key_pattern, suffix });
    }
    const pinned_type = if (self.xml().format == .KimiK3Xml)
        XmlToolCallingConverter.rendered_json_type(b.arena, schema)
    else
        null;
    const suffix = try xml_key_suffix(self, pinned_type);
    return xml_parameter_value(self, &.{ prefix, key_pattern, suffix }, value_rule_id);
}

/// Appends the value wrapper, the value, and the parameter end to a parameter's opening.
pub fn xml_parameter_value(
    self: anytype,
    prefix_elements: []const i32,
    value_rule_id: i32,
) Allocator.Error!i32 {
    const wrapper = self.xml().wrapper;
    const b = self.base();
    const arena = b.arena;
    var elements: std.ArrayList(i32) = .empty;
    try elements.appendSlice(arena, prefix_elements);
    if (wrapper.value_prefix.len != 0) {
        try elements.append(arena, try b.whitespace_expression());
        try elements.append(arena, try b.byte_string(wrapper.value_prefix));
    }
    // xml_string already accepts whitespace; padding it would create one parser state for
    // every split of the leading and trailing whitespace.
    if (value_rule_id == try b.builder.get_rule_id(XML_STRING)) {
        try elements.append(arena, try b.rule_ref(value_rule_id));
    } else {
        try elements.append(arena, try b.whitespace_expression());
        try elements.append(arena, try b.rule_ref(value_rule_id));
        try elements.append(arena, try b.whitespace_expression());
    }
    try elements.append(arena, try b.byte_string(wrapper.parameter_suffix));
    return b.sequence(elements.items);
}

/// A DeepSeek parameter's `string` attribute, value, and closing tag: `string="true"` wraps
/// raw strings, `string="false"` JSON values. Unions and mixed enums produce one alternative
/// per option. Without `value_rule_id` the value rule is created when a typed leaf is reached.
pub fn format_deepseek_param_suffix(
    self: anytype,
    schema: ?SchemaSpecPtr,
    value_rule_id: ?i32,
    rule_name_hint: []const u8,
    diag: ?*SchemaErrorInfo,
) SchemaError!i32 {
    const b = self.base();
    const arena = b.arena;
    const value_rule_name = if (value_rule_id) |rid|
        b.builder.get_rule(rid).name
    else
        rule_name_hint;

    if (schema) |sc| {
        if (sc.spec == .Ref) {
            const reference = sc.spec.Ref;
            if (self.xml().deepseek_param_ref_rules.get(reference.uri)) |rule_id| {
                return b.rule_ref(rule_id);
            }
            // Register the rule before descending, so a recursive branch refers back to it and
            // shared acyclic subgraphs are built once.
            const param_hint = try std.fmt.allocPrint(arena, "{s}_dsml_param", .{value_rule_name});
            const param_rule_id = try b.builder.add_empty_rule_with_hint(param_hint);
            try self.xml_mut().deepseek_param_ref_rules.put(arena, try arena.dupe(u8, reference.uri), param_rule_id);
            const resolved = try b.resolve_ref(reference.uri, diag);
            const body = try format_deepseek_param_suffix(self, resolved, value_rule_id, value_rule_name, diag);
            b.builder.update_rule_body(param_rule_id, body);
            return b.rule_ref(param_rule_id);
        }
    }

    // A schema rendered with a single type keeps the value rule built by the caller.
    if (schema) |sc| {
        if (XmlToolCallingConverter.rendered_json_type(arena, sc)) |pinned_type| {
            const resolved_value_rule_id = if (value_rule_id) |rid|
                rid
            else
                try schema_converter_mod.create_rule(self, sc, value_rule_name, diag);
            const value = try b.rule_ref(resolved_value_rule_id);
            return deepseek_value(self, value, std.mem.eql(u8, pinned_type, "string"));
        }
    }

    var options: std.ArrayList(SchemaSpecPtr) = .empty;
    if (schema) |sc| {
        switch (sc.spec) {
            .AnyOf => |spec| try options.appendSlice(arena, spec.options.items),
            .TypeArray => |spec| try options.appendSlice(arena, spec.type_schemas.items),
            .AllOf => |spec| {
                if (spec.schemas.items.len == 1) {
                    try options.appendSlice(arena, spec.schemas.items);
                }
            },
            .Enum => |spec| {
                for (spec.json_values.items) |value| {
                    try options.append(arena, try SchemaSpec.make(arena, .{ .Const = .{ .json_value = value } }, ""));
                }
            },
            else => {},
        }
    }
    if (options.items.len == 0) {
        // No schema, {}, and allOf with several schemas all render any value.
        const xml_string = try b.rule_ref_by_name(XML_STRING);
        const raw = try deepseek_value(self, xml_string, true);
        const json_names = [_][]const u8{ BASIC_NUMBER, BASIC_BOOLEAN, BASIC_NULL, BASIC_ARRAY, BASIC_OBJECT };
        var json_choices: [json_names.len]i32 = undefined;
        for (json_names, 0..) |name, i| {
            json_choices[i] = try b.rule_ref_by_name(name);
        }
        const json_expr = try b.choice(&json_choices);
        const json = try deepseek_value(self, json_expr, false);
        return b.choice(&.{ raw, json });
    }
    var choices: std.ArrayList(i32) = .empty;
    try choices.ensureTotalCapacity(arena, options.items.len);
    for (options.items, 0..) |option, index| {
        // Only leaves need value rules; rebuilding a nested union's value subtree at each
        // level would create quadratically many rules.
        const case_hint = try std.fmt.allocPrint(arena, "{s}_dsml_case_{d}", .{ value_rule_name, index });
        try choices.append(arena, try format_deepseek_param_suffix(self, option, null, case_hint, diag));
    }
    return b.choice(choices.items);
}

/// A DeepSeek value with its `string` attribute; JSON values may be padded by whitespace.
pub fn deepseek_value(
    self: anytype,
    value: i32,
    is_string: bool,
) Allocator.Error!i32 {
    const parameter_suffix = self.xml().wrapper.parameter_suffix;
    const b = self.base();
    const arena = b.arena;
    const attribute: []const u8 = if (is_string) "\" string=\"true\">" else "\" string=\"false\">";
    var elements: std.ArrayList(i32) = .empty;
    try elements.append(arena, try b.byte_string(attribute));
    if (!is_string) {
        try elements.append(arena, try b.whitespace_expression());
    }
    try elements.append(arena, value);
    if (!is_string) {
        try elements.append(arena, try b.whitespace_expression());
    }
    try elements.append(arena, try b.byte_string(parameter_suffix));
    return b.sequence(elements.items);
}

/// `[a-zA-Z_]`, with `[0-9]` when `with_digits`.
fn identifier_class(arena: Allocator, with_digits: bool) Allocator.Error![]CharacterClassElement {
    var class: std.ArrayList(CharacterClassElement) = .empty;
    try class.append(arena, CharacterClassElement.new(0x61, 0x7a));
    try class.append(arena, CharacterClassElement.new(0x41, 0x5a));
    if (with_digits) {
        try class.append(arena, CharacterClassElement.new(0x30, 0x39));
    }
    try class.appendSlice(arena, try ascii_class(arena, "_"));
    return class.items;
}
