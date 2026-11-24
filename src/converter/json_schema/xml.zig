//! XML parameter-list tool-calling converters and shared XML helpers
//! (`xml_wrapper.rs` + `xml_converter.rs` + `xml_tool_calling_converter.rs`).
//!
//! Covers Qwen, MiniMax, DeepSeek (DSML & V4.1), GLM, and Kimi-K3 formats, plus shared
//! parameter-list primitives used by `CohereXmlToolCallingConverter`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Diagnostic = @import("../../Diagnostic.zig").Diagnostic;
const grammar_mod = @import("../../grammar.zig");
const CharacterClassElement = grammar_mod.CharacterClassElement;
const converter_mod = @import("converter.zig");
const JsonSchemaConverter = converter_mod.JsonSchemaConverter;
const BASIC_ANY = converter_mod.BASIC_ANY;
const BASIC_ARRAY = converter_mod.BASIC_ARRAY;
const BASIC_BOOLEAN = converter_mod.BASIC_BOOLEAN;
const BASIC_NULL = converter_mod.BASIC_NULL;
const BASIC_NUMBER = converter_mod.BASIC_NUMBER;
const BASIC_OBJECT = converter_mod.BASIC_OBJECT;
const BASIC_STRING = converter_mod.BASIC_STRING;
const generator = @import("generator.zig");
const parser_mod = @import("parser.zig");
const SchemaError = parser_mod.SchemaError;
const spec_mod = @import("spec.zig");
const ArraySpec = spec_mod.ArraySpec;
const ConstSpec = spec_mod.ConstSpec;
const EnumSpec = spec_mod.EnumSpec;
const JsonFormat = spec_mod.JsonFormat;
const ObjectSpec = spec_mod.ObjectSpec;
const Property = spec_mod.Property;
const SchemaSpec = spec_mod.SchemaSpec;
const SchemaSpecPtr = spec_mod.SchemaSpecPtr;
const StringSpec = spec_mod.StringSpec;

pub const XML_STRING = "xml_string";
pub const XML_ANY = "xml_any";
pub const XML_OBJECT = "xml_object";
pub const XML_VARIABLE_NAME = "xml_variable_name";

const OBJECT_CACHE_KEY = "{\"type\":\"object\"}";

// ---------------------------------------------------------------------------
// XmlWrapper
// ---------------------------------------------------------------------------

/// The literal pieces around one XML tool-call parameter: `key_prefix` NAME `key_suffix`
/// `value_prefix` VALUE `parameter_suffix`.
pub const XmlWrapper = struct {
    key_prefix: []const u8,
    key_suffix: []const u8,
    value_prefix: []const u8,
    parameter_suffix: []const u8,

    /// Kimi-K3 renders the value's type between the key and `<|sep|>`; see `KIMI_K3_TYPES`.
    pub const KIMI_K3_TYPE_PREFIX: []const u8 = "\" type=\"";
    /// The type attribute values of Kimi-K3 parameters.
    pub const KIMI_K3_TYPES: [7][]const u8 = .{ "string", "number", "integer", "boolean", "object", "array", "null" };
    /// The end of a Kimi-K3 parameter's opening tag.
    pub const KIMI_K3_TYPE_SUFFIX: []const u8 = "\"<|sep|>";

    /// Returns the wrapper of an XML parameter-list format, or `null` for other formats.
    pub fn forFormat(format: JsonFormat) ?XmlWrapper {
        return switch (format) {
            .qwen_xml => .{ .key_prefix = "<parameter=", .key_suffix = ">", .value_prefix = "", .parameter_suffix = "</parameter>" },
            .minimax_xml => .{ .key_prefix = "<parameter name=\"", .key_suffix = "\">", .value_prefix = "", .parameter_suffix = "</parameter>" },
            .deepseek_xml => .{ .key_prefix = "<｜DSML｜parameter name=\"", .key_suffix = "", .value_prefix = "", .parameter_suffix = "</｜DSML｜parameter>" },
            .deepseek_v4_1_xml => .{ .key_prefix = "<｜DSML｜ parameter name=\"", .key_suffix = "", .value_prefix = "", .parameter_suffix = "</｜DSML｜ parameter>" },
            .glm_xml => .{ .key_prefix = "<arg_key>", .key_suffix = "</arg_key>", .value_prefix = "<arg_value>", .parameter_suffix = "</arg_value>" },
            .cohere_xml => .{ .key_prefix = "<cofl:value", .key_suffix = ">", .value_prefix = "", .parameter_suffix = "</cofl:value>" },
            .kimi_k3_xml => .{ .key_prefix = "<|open|>argument key=\"", .key_suffix = "", .value_prefix = "", .parameter_suffix = "<|close|>argument<|sep|>" },
            else => null,
        };
    }
};

// ---------------------------------------------------------------------------
// XmlToolCallingConverter
// ---------------------------------------------------------------------------

fn isPadding(c: u8) bool {
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
    pub fn init(
        base_conv: *JsonSchemaConverter,
        format: JsonFormat,
        diag: ?*Diagnostic,
    ) SchemaError!XmlToolCallingConverter {
        const wrapper = XmlWrapper.forFormat(format) orelse {
            return parser_mod.failFmt(
                error.InvalidSchema,
                diag,
                base_conv.gpa,
                "Invalid JSON format for XML tool calling: {s}",
                .{@tagName(format)},
            );
        };
        for (base_conv.excludes) |excluded| {
            if (excluded.len != 0 and (isPadding(excluded[0]) or isPadding(excluded[excluded.len - 1]))) {
                return parser_mod.failStatic(
                    error.InvalidSchema,
                    diag,
                    "XML JSONSchemaFormat.excludes must not start or end with formatting whitespace",
                );
            }
        }
        return .{
            .base_conv = base_conv,
            .format = format,
            .nested_object_level = 0,
            .wrapper = wrapper,
            .deepseek_param_ref_rules = .empty,
        };
    }

    /// The cache context: the parameter list, a raw parameter value, or nested JSON.
    pub fn encodingContext(self: *const XmlToolCallingConverter) i32 {
        return @min(self.nested_object_level, 2);
    }

    fn typeOfJsonValue(arena: Allocator, json_value: []const u8) []const u8 {
        return switch (converter_mod.parseLiteral(arena, json_value)) {
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
    pub fn renderedJsonType(arena: Allocator, spec: ?SchemaSpecPtr) ?[]const u8 {
        const sc = spec orelse return null;
        return switch (sc.spec) {
            .String => "string",
            .Integer, .Number => "number",
            .Boolean => "boolean",
            .Null => "null",
            .Array => "array",
            .Object => "object",
            .Const => |c| typeOfJsonValue(arena, c.json_value),
            .Enum => |e| blk: {
                if (e.json_values.items.len == 0) break :blk null;
                const first = typeOfJsonValue(arena, e.json_values.items[0]);
                for (e.json_values.items[1..]) |val| {
                    if (!std.mem.eql(u8, typeOfJsonValue(arena, val), first)) break :blk null;
                }
                break :blk first;
            },
            else => null,
        };
    }

    /// The raw text of a JSON literal: a string's content, or the JSON text of other values.
    pub fn xmlValue(arena: Allocator, json_value: []const u8) Allocator.Error![]const u8 {
        return switch (converter_mod.parseLiteral(arena, json_value)) {
            .string => |text| text,
            else => arena.dupe(u8, json_value),
        };
    }

    /// Escapes an attribute value as Kimi-K3's renderer does (`&` and `"`); other formats keep it.
    pub fn escapeAttrValue(self: *const XmlToolCallingConverter, arena: Allocator, value: []const u8) Allocator.Error![]const u8 {
        if (self.format != .kimi_k3_xml) {
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

    // ----------------------------- hook overrides -----------------------------

    pub fn base(self: *XmlToolCallingConverter) *JsonSchemaConverter {
        return self.base_conv;
    }

    pub fn xml(self: *const XmlToolCallingConverter) *const XmlToolCallingConverter {
        return self;
    }

    pub fn xmlMut(self: *XmlToolCallingConverter) *XmlToolCallingConverter {
        return self;
    }

    pub fn addBasicRules(self: *XmlToolCallingConverter, diag: ?*Diagnostic) SchemaError!void {
        return xmlAddBasicRules(self, diag);
    }

    pub fn addCache(self: *XmlToolCallingConverter, key: []const u8, rule_id: i32) Allocator.Error!void {
        if (key.len != 0) {
            const context = self.encodingContext();
            try self.base_conv.rule_cache.put(self.base_conv.arena, .{
                .key = try self.base_conv.arena.dupe(u8, key),
                .context = context,
            }, rule_id);
        }
    }

    pub fn getCache(self: *XmlToolCallingConverter, key: []const u8) ?i32 {
        if (key.len == 0) return null;
        const parameter_list_any = (self.format == .qwen_xml or self.format == .deepseek_xml or self.format == .deepseek_v4_1_xml) and
            self.nested_object_level == 0 and
            std.mem.eql(u8, key, "{}");
        const cache_key: JsonSchemaConverter.CacheKey = if (parameter_list_any)
            .{ .key = OBJECT_CACHE_KEY, .context = 0 }
        else if (self.nested_object_level == 1 and std.mem.eql(u8, key, OBJECT_CACHE_KEY))
            .{ .key = key, .context = 2 }
        else
            .{ .key = key, .context = self.encodingContext() };
        return self.base_conv.rule_cache.get(cache_key);
    }

    pub fn refCacheKey(self: *XmlToolCallingConverter, uri: []const u8) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(self.base_conv.arena, "{d}:{s}", .{ self.encodingContext(), uri });
    }

    pub fn nextSeparator(self: *XmlToolCallingConverter, is_end: bool) Allocator.Error![]u8 {
        if (self.nested_object_level <= 1) {
            return self.base_conv.whitespacePattern();
        }
        return self.base_conv.indent_manager.nextSeparator(is_end);
    }

    pub fn keyPattern(self: *XmlToolCallingConverter) []const u8 {
        if (self.nested_object_level <= 1) {
            return XML_VARIABLE_NAME;
        }
        return BASIC_STRING;
    }

    pub fn basicAnyRuleName(self: *XmlToolCallingConverter) []const u8 {
        if (self.nested_object_level <= 1) {
            return XML_ANY;
        }
        return BASIC_ANY;
    }

    pub fn keyPatternExcluding(
        self: *XmlToolCallingConverter,
        properties: []const Property,
        rule_name: []const u8,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        if (self.nested_object_level <= 1) {
            return generator.keyPatternExpression(self);
        }
        return generator.jsonKeyPatternExcluding(self, properties, rule_name, diag);
    }

    pub fn generateString(
        self: *XmlToolCallingConverter,
        spec: *const StringSpec,
        rule_name: []const u8,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        if (self.nested_object_level > 1) {
            return generator.jsonGenerateString(self, spec, rule_name, diag);
        }
        if (spec.format) |fmt| {
            if (try parser_mod.jsonFormatToRegexPattern(self.base_conv.arena, fmt)) |regex| {
                return self.base_conv.regexExpression(regex, false, true, diag);
            }
        }
        if (spec.pattern) |pattern| {
            return self.base_conv.regexExpression(pattern, false, true, diag);
        }
        const bounded = spec.min_length != 0 or spec.max_length != -1;
        if (self.base_conv.excludes.len == 0 and (bounded or spec.format != null)) {
            return self.base_conv.rawCharacters(spec, rule_name);
        }
        if (bounded) {
            JsonSchemaConverter.warnDroppedLengthConstraints(spec, rule_name);
        }
        return self.base_conv.ruleRefByName(XML_STRING);
    }

    pub fn generateArray(
        self: *XmlToolCallingConverter,
        spec: *const ArraySpec,
        rule_name: []const u8,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        self.nested_object_level += 1;
        defer self.nested_object_level -= 1;
        return generator.jsonGenerateArray(self, spec, rule_name, diag);
    }

    pub fn generateObject(
        self: *XmlToolCallingConverter,
        spec: *const ObjectSpec,
        rule_name: []const u8,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        self.nested_object_level += 1;
        defer self.nested_object_level -= 1;
        const need_braces = self.nested_object_level > 1;
        return generator.jsonGenerateObject(self, spec, rule_name, need_braces, diag);
    }

    pub fn generateAny(self: *XmlToolCallingConverter, _: []const u8, _: ?*Diagnostic) SchemaError!i32 {
        return switch (self.nested_object_level) {
            0 => try self.base_conv.ruleRefByName(XML_OBJECT),
            1 => blk: {
                const names = [_][]const u8{ XML_STRING, BASIC_ARRAY, BASIC_OBJECT };
                var choices: [names.len]i32 = undefined;
                for (names, 0..) |name, i| {
                    choices[i] = try self.base_conv.ruleRefByName(name);
                }
                break :blk try self.base_conv.choice(&choices);
            },
            else => generator.jsonGenerateAny(self),
        };
    }

    pub fn generateConst(
        self: *XmlToolCallingConverter,
        spec: *const ConstSpec,
        rule_name: []const u8,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        const arena = self.base_conv.arena;
        if (self.nested_object_level == 0) {
            const parsed = converter_mod.parseLiteral(arena, spec.json_value);
            if (parsed == .object) {
                const members = parsed.object;
                var object = ObjectSpec{};
                object.allow_unevaluated_properties = false;
                for (members.keys(), members.values()) |key, value| {
                    const schema = try SchemaSpec.make(arena, .{
                        .Const = .{ .json_value = try parser_mod.serializeJson(arena, value) },
                    }, "");
                    try object.required.put(arena, key, {});
                    try object.properties.append(arena, .{ .name = key, .schema = schema });
                }
                const saved_any_order = self.base_conv.any_order;
                self.base_conv.any_order = false;
                defer self.base_conv.any_order = saved_any_order;
                return self.generateObject(&object, rule_name, diag);
            }
        }
        if (self.nested_object_level > 1) {
            return generator.jsonGenerateLiterals(self, &.{spec.json_value});
        }
        if (!self.base_conv.isAllowedJsonLiteral(spec.json_value, true)) {
            return self.base_conv.unsatisfiable();
        }
        const raw_val = try xmlValue(arena, spec.json_value);
        return self.base_conv.byteString(raw_val);
    }

    pub fn generateEnum(
        self: *XmlToolCallingConverter,
        spec: *const EnumSpec,
        rule_name: []const u8,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        if (self.nested_object_level > 1) {
            return generator.jsonGenerateLiterals(self, spec.json_values.items);
        }
        const arena = self.base_conv.arena;
        var values: std.ArrayList(i32) = .empty;
        try values.ensureTotalCapacity(arena, spec.json_values.items.len);
        for (spec.json_values.items) |json_value| {
            const literal = ConstSpec{ .json_value = json_value };
            try values.append(arena, try self.generateConst(&literal, rule_name, diag));
        }
        return self.base_conv.choice(values.items);
    }

    pub fn formatPropertyKey(
        self: *XmlToolCallingConverter,
        key: []const u8,
        schema: SchemaSpecPtr,
    ) Allocator.Error!i32 {
        return xmlFormatPropertyKey(self, key, schema);
    }

    pub fn formatProperty(
        self: *XmlToolCallingConverter,
        key: []const u8,
        value_rule_id: i32,
        _: []const u8,
        _: usize,
        schema: SchemaSpecPtr,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        return xmlFormatProperty(self, key, value_rule_id, schema, diag);
    }

    pub fn formatOtherProperty(
        self: *XmlToolCallingConverter,
        key_pattern_id: i32,
        value_rule_id: i32,
        _: []const u8,
        _: []const u8,
        schema: ?SchemaSpecPtr,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        return xmlFormatOtherProperty(self, key_pattern_id, value_rule_id, schema, diag);
    }
};

// ---------------------------------------------------------------------------
// Shared XML helpers
// ---------------------------------------------------------------------------

/// The JSON basic rules at level 2, then the XML rules: `xml_string`, `xml_any`,
/// `xml_object`, and `xml_variable_name`.
pub fn xmlAddBasicRules(self: anytype, diag: ?*Diagnostic) SchemaError!void {
    const b = self.base();
    const arena = b.arena;
    self.xmlMut().nested_object_level = 2;
    try generator.jsonAddBasicRules(self, &.{ XML_STRING, XML_ANY, XML_OBJECT, XML_VARIABLE_NAME }, diag);
    const any_spec = try SchemaSpec.make(arena, .{ .Any = {} }, "{}");

    self.xmlMut().nested_object_level = 1;
    var string_excludes: std.ArrayList([]const u8) = .empty;
    try string_excludes.appendSlice(arena, b.excludes);
    try string_excludes.append(arena, self.xml().wrapper.parameter_suffix);
    var body = try b.tagDispatch(false, string_excludes.items);
    try generator.setBasicRule(self, XML_STRING, body, "{\"type\":\"string\"}");
    body = try generator.generateAny(self, XML_ANY, diag);
    try generator.setBasicRule(self, XML_ANY, body, "{}");

    self.xmlMut().nested_object_level = 0;
    var object_spec = ObjectSpec{};
    object_spec.allow_additional_properties = true;
    object_spec.additional_properties_schema = any_spec;
    body = try generator.generateObject(self, &object_spec, XML_OBJECT, diag);
    try generator.setBasicRule(self, XML_OBJECT, body, "{\"type\":\"object\"}");

    body = if (b.excludes.len == 0) blk: {
        const id_first = try identifierClass(arena, false);
        const id_rest = try identifierClass(arena, true);
        const first = try b.builder.addCharacterClass(id_first, false);
        const rest = try b.builder.addCharacterClassStar(id_rest, false);
        break :blk try b.sequence(&.{ first, rest });
    } else try b.excludingString("[a-zA-Z_][a-zA-Z0-9_]*", XML_VARIABLE_NAME, false, &.{}, diag);
    try b.builder.updateRuleBodyByName(XML_VARIABLE_NAME, body);
}

/// The opening of a declared parameter (key prefix, escaped key, and key suffix).
pub fn xmlFormatPropertyKey(
    self: anytype,
    key: []const u8,
    schema: SchemaSpecPtr,
) Allocator.Error!i32 {
    const b = self.base();
    if (self.xml().nested_object_level > 1) {
        return b.jsonPropertyKey(key);
    }
    const pinned_type = if (self.xml().format == .kimi_k3_xml)
        XmlToolCallingConverter.renderedJsonType(b.arena, schema)
    else
        null;
    const escaped = try self.xml().escapeAttrValue(b.arena, key);
    if (!b.isAllowedString(escaped)) {
        return b.unsatisfiable();
    }
    const prefix_str = try std.fmt.allocPrint(b.arena, "{s}{s}", .{ self.xml().wrapper.key_prefix, escaped });
    const prefix = try b.byteString(prefix_str);
    const suffix = try xmlKeySuffix(self, pinned_type);
    return b.sequence(&.{ prefix, suffix });
}

/// The expression between a parameter's key and its value.
pub fn xmlKeySuffix(
    self: anytype,
    pinned_type: ?[]const u8,
) Allocator.Error!i32 {
    const key_suffix = self.xml().wrapper.key_suffix;
    const is_kimi = self.xml().format == .kimi_k3_xml;
    const b = self.base();
    if (!is_kimi) {
        return b.byteString(key_suffix);
    }
    const type_expr = if (pinned_type) |pt|
        try b.byteString(pt)
    else blk: {
        var choices: [XmlWrapper.KIMI_K3_TYPES.len]i32 = undefined;
        for (XmlWrapper.KIMI_K3_TYPES, 0..) |value, i| {
            choices[i] = try b.byteString(value);
        }
        break :blk try b.choice(&choices);
    };
    const prefix = try b.byteString(XmlWrapper.KIMI_K3_TYPE_PREFIX);
    const suffix = try b.byteString(XmlWrapper.KIMI_K3_TYPE_SUFFIX);
    return b.sequence(&.{ prefix, type_expr, suffix });
}

/// A declared parameter at the parameter-list level, or a JSON member below it.
pub fn xmlFormatProperty(
    self: anytype,
    key: []const u8,
    value_rule_id: i32,
    schema: SchemaSpecPtr,
    diag: ?*Diagnostic,
) SchemaError!i32 {
    const b = self.base();
    if (self.xml().nested_object_level > 1) {
        const key_id = try b.jsonPropertyKey(key);
        return b.jsonMember(key_id, value_rule_id);
    }
    if (self.xml().format.isDeepseek()) {
        if (!b.isAllowedString(key)) {
            return b.unsatisfiable();
        }
        const prefix_str = try std.fmt.allocPrint(b.arena, "{s}{s}", .{ self.xml().wrapper.key_prefix, key });
        const prefix = try b.byteString(prefix_str);
        const suffix = try formatDeepseekParamSuffix(self, schema, value_rule_id, "", diag);
        return b.sequence(&.{ prefix, suffix });
    }
    const key_id = try generator.formatPropertyKey(self, key, schema);
    return xmlParameterValue(self, &.{key_id}, value_rule_id);
}

/// A free-form parameter (`key_pattern` names it) at the parameter-list level, or a JSON
/// member below it.
pub fn xmlFormatOtherProperty(
    self: anytype,
    key_pattern: i32,
    value_rule_id: i32,
    schema: ?SchemaSpecPtr,
    diag: ?*Diagnostic,
) SchemaError!i32 {
    const b = self.base();
    if (self.xml().nested_object_level > 1) {
        return b.jsonMember(key_pattern, value_rule_id);
    }
    const key_prefix = self.xml().wrapper.key_prefix;
    const prefix = try b.byteString(key_prefix);
    if (self.xml().format.isDeepseek()) {
        const suffix = try formatDeepseekParamSuffix(self, schema, value_rule_id, "", diag);
        return b.sequence(&.{ prefix, key_pattern, suffix });
    }
    const pinned_type = if (self.xml().format == .kimi_k3_xml)
        XmlToolCallingConverter.renderedJsonType(b.arena, schema)
    else
        null;
    const suffix = try xmlKeySuffix(self, pinned_type);
    return xmlParameterValue(self, &.{ prefix, key_pattern, suffix }, value_rule_id);
}

/// Appends the value wrapper, the value, and the parameter end to a parameter's opening.
pub fn xmlParameterValue(
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
        try elements.append(arena, try b.whitespaceExpression());
        try elements.append(arena, try b.byteString(wrapper.value_prefix));
    }
    if (value_rule_id == try b.builder.getRuleId(XML_STRING)) {
        try elements.append(arena, try b.ruleRef(value_rule_id));
    } else {
        try elements.append(arena, try b.whitespaceExpression());
        try elements.append(arena, try b.ruleRef(value_rule_id));
        try elements.append(arena, try b.whitespaceExpression());
    }
    try elements.append(arena, try b.byteString(wrapper.parameter_suffix));
    return b.sequence(elements.items);
}

/// A DeepSeek parameter's `string` attribute, value, and closing tag.
pub fn formatDeepseekParamSuffix(
    self: anytype,
    schema: ?SchemaSpecPtr,
    value_rule_id: ?i32,
    rule_name_hint: []const u8,
    diag: ?*Diagnostic,
) SchemaError!i32 {
    const b = self.base();
    const arena = b.arena;
    const value_rule_name = if (value_rule_id) |rid|
        b.builder.getRule(rid).name
    else
        rule_name_hint;

    if (schema) |sc| {
        if (sc.spec == .Ref) {
            const reference = sc.spec.Ref;
            if (self.xml().deepseek_param_ref_rules.get(reference.uri)) |rule_id| {
                return b.ruleRef(rule_id);
            }
            const param_hint = try std.fmt.allocPrint(arena, "{s}_dsml_param", .{value_rule_name});
            const param_rule_id = try b.builder.addEmptyRuleWithHint(param_hint);
            try self.xmlMut().deepseek_param_ref_rules.put(arena, try arena.dupe(u8, reference.uri), param_rule_id);
            const resolved = try b.resolveRef(reference.uri, diag);
            const body = try formatDeepseekParamSuffix(self, resolved, value_rule_id, value_rule_name, diag);
            b.builder.updateRuleBody(param_rule_id, body);
            return b.ruleRef(param_rule_id);
        }
    }

    if (schema) |sc| {
        if (XmlToolCallingConverter.renderedJsonType(arena, sc)) |pinned_type| {
            const resolved_value_rule_id = if (value_rule_id) |rid|
                rid
            else
                try generator.createRule(self, sc, value_rule_name, diag);
            const value = try b.ruleRef(resolved_value_rule_id);
            return deepseekValue(self, value, std.mem.eql(u8, pinned_type, "string"));
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
        const xml_string = try b.ruleRefByName(XML_STRING);
        const raw = try deepseekValue(self, xml_string, true);
        const json_names = [_][]const u8{ BASIC_NUMBER, BASIC_BOOLEAN, BASIC_NULL, BASIC_ARRAY, BASIC_OBJECT };
        var json_choices: [json_names.len]i32 = undefined;
        for (json_names, 0..) |name, i| {
            json_choices[i] = try b.ruleRefByName(name);
        }
        const json_expr = try b.choice(&json_choices);
        const json = try deepseekValue(self, json_expr, false);
        return b.choice(&.{ raw, json });
    }
    var choices: std.ArrayList(i32) = .empty;
    try choices.ensureTotalCapacity(arena, options.items.len);
    for (options.items, 0..) |option, index| {
        const case_hint = try std.fmt.allocPrint(arena, "{s}_dsml_case_{d}", .{ value_rule_name, index });
        try choices.append(arena, try formatDeepseekParamSuffix(self, option, null, case_hint, diag));
    }
    return b.choice(choices.items);
}

/// A DeepSeek value with its `string` attribute; JSON values may be padded by whitespace.
pub fn deepseekValue(
    self: anytype,
    value: i32,
    is_string: bool,
) Allocator.Error!i32 {
    const parameter_suffix = self.xml().wrapper.parameter_suffix;
    const b = self.base();
    const arena = b.arena;
    const attribute: []const u8 = if (is_string) "\" string=\"true\">" else "\" string=\"false\">";
    var elements: std.ArrayList(i32) = .empty;
    try elements.append(arena, try b.byteString(attribute));
    if (!is_string) {
        try elements.append(arena, try b.whitespaceExpression());
    }
    try elements.append(arena, value);
    if (!is_string) {
        try elements.append(arena, try b.whitespaceExpression());
    }
    try elements.append(arena, try b.byteString(parameter_suffix));
    return b.sequence(elements.items);
}

/// `[a-zA-Z_]`, with `[0-9]` when `with_digits`.
fn identifierClass(arena: Allocator, with_digits: bool) Allocator.Error![]CharacterClassElement {
    var class: std.ArrayList(CharacterClassElement) = .empty;
    try class.append(arena, CharacterClassElement.init(0x61, 0x7a));
    try class.append(arena, CharacterClassElement.init(0x41, 0x5a));
    if (with_digits) {
        try class.append(arena, CharacterClassElement.init(0x30, 0x39));
    }
    try class.appendSlice(arena, try converter_mod.asciiClass(arena, "_"));
    return class.items;
}

test "XmlWrapper.forFormat covers XML styles and excludes plain json and minimax_m3" {
    try std.testing.expect(XmlWrapper.forFormat(.json) == null);
    try std.testing.expect(XmlWrapper.forFormat(.minimax_m3_xml) == null);
    try std.testing.expectEqualStrings("<parameter=", XmlWrapper.forFormat(.qwen_xml).?.key_prefix);
    try std.testing.expectEqualStrings("</arg_value>", XmlWrapper.forFormat(.glm_xml).?.parameter_suffix);
    try std.testing.expect(XmlWrapper.forFormat(.deepseek_v4_1_xml) != null);
    std.testing.refAllDecls(@This());
}
