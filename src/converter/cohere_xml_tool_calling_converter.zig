//! The Cohere XML tool-calling converter (`cohere_xml_tool_calling_converter.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const json_format_mod = @import("json_format.zig");
const json_schema_converter_mod = @import("json_schema_converter.zig");
const JsonSchemaConverter = json_schema_converter_mod.JsonSchemaConverter;
const BASIC_BOOLEAN = json_schema_converter_mod.BASIC_BOOLEAN;
const BASIC_NULL = json_schema_converter_mod.BASIC_NULL;
const BASIC_NUMBER = json_schema_converter_mod.BASIC_NUMBER;
const BASIC_STRING = json_schema_converter_mod.BASIC_STRING;
const json_format_to_regex_pattern = json_schema_converter_mod.json_format_to_regex_pattern;
const parse_literal = json_schema_converter_mod.parse_literal;
const schema_converter_mod = @import("schema_converter.zig");
const schema_error_mod = @import("schema_error.zig");
const SchemaError = schema_error_mod.SchemaError;
const SchemaErrorInfo = schema_error_mod.SchemaErrorInfo;
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
const xml_tool_calling_converter_mod = @import("xml_tool_calling_converter.zig");
const XmlToolCallingConverter = xml_tool_calling_converter_mod.XmlToolCallingConverter;
const XML_OBJECT = xml_tool_calling_converter_mod.XML_OBJECT;
const XML_STRING = xml_tool_calling_converter_mod.XML_STRING;
const grammar_mod = @import("../grammar/mod.zig");
const CharacterClassElement = grammar_mod.CharacterClassElement;

const COHERE_KEY = "cohere_key";
const COHERE_ANY_SCALAR = "cohere_any_scalar";
const COHERE_ANY_LIST = "cohere_any_list";

const KeyEntity = struct {
    ch: u21,
    entity: []const u8,
};

/// The XML-sensitive key characters and the entities that spell them.
const KEY_ENTITIES = [_]KeyEntity{
    .{ .ch = '&', .entity = "&amp;" },
    .{ .ch = '<', .entity = "&lt;" },
    .{ .ch = '>', .entity = "&gt;" },
    .{ .ch = '"', .entity = "&quot;" },
};

/// Codepoint trie matching Rust `KeyTrie<char>`, maintaining children in ascending codepoint order.
const CharKeyTrie = struct {
    const Child = struct {
        ch: u21,
        node: *CharKeyTrie,
    };

    is_terminal: bool = false,
    children: std.ArrayList(Child) = .empty,

    fn build(arena: Allocator, properties: []const Property) Allocator.Error!CharKeyTrie {
        var root = CharKeyTrie{};
        for (properties) |prop| {
            if (prop.name.len == 0) continue;
            var node = &root;
            const view = std.unicode.Utf8View.initUnchecked(prop.name);
            var it = view.iterator();
            while (it.nextCodepoint()) |cp| {
                node = try node.getOrInsertChild(arena, cp);
            }
            node.is_terminal = true;
        }
        return root;
    }

    fn getOrInsertChild(self: *CharKeyTrie, arena: Allocator, cp: u21) Allocator.Error!*CharKeyTrie {
        var idx: usize = 0;
        while (idx < self.children.items.len and self.children.items[idx].ch < cp) : (idx += 1) {}
        if (idx < self.children.items.len and self.children.items[idx].ch == cp) {
            return self.children.items[idx].node;
        }
        const child = try arena.create(CharKeyTrie);
        child.* = .{};
        try self.children.insert(arena, idx, .{ .ch = cp, .node = child });
        return child;
    }

    fn containsKey(self: *const CharKeyTrie, cp: u21) bool {
        for (self.children.items) |child| {
            if (child.ch == cp) return true;
        }
        return false;
    }
};

/// Converts a JSON Schema into recursive Cohere value tags,
/// `<cofl:value name="key" type="raw|json|dict|list">value</cofl:value>`: object members are
/// named value tags and array items unnamed ones.
pub const CohereXmlToolCallingConverter = struct {
    xml_state: XmlToolCallingConverter,
    /// The number of Cohere objects being generated.
    object_depth: usize,
    /// The number of Cohere arrays being generated.
    array_level: usize,
    /// Parameter suffix rules keyed by `$ref` URI; see `format_param_suffix`.
    param_ref_rules: std.StringHashMapUnmanaged(i32),

    /// Creates the converter.
    pub fn new(base_conv: *JsonSchemaConverter, diag: ?*SchemaErrorInfo) SchemaError!CohereXmlToolCallingConverter {
        return .{
            .xml_state = try XmlToolCallingConverter.new(base_conv, .CohereXml, diag),
            .object_depth = 0,
            .array_level = 0,
            .param_ref_rules = .{},
        };
    }

    fn at_root(self: *const CohereXmlToolCallingConverter) bool {
        return self.xml_state.nested_object_level == 0 and self.object_depth == 0 and self.array_level == 0;
    }

    /// Whether values are Cohere tags here (dict and list contents stay tagged at any depth).
    fn in_value_context(self: *const CohereXmlToolCallingConverter) bool {
        return self.xml_state.nested_object_level <= 1 or self.object_depth > 0 or self.array_level > 0;
    }

    /// `<cofl:value` plus the optional ` name="..."` attribute of one parameter.
    fn param_prefix(
        self: *CohereXmlToolCallingConverter,
        name: ?[]const u8,
        key_pattern_id: ?i32,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        const key_prefix = self.xml_state.wrapper.key_prefix;
        const b = self.xml_state.base_conv;
        const arena = b.arena;
        var elements: std.ArrayList(i32) = .empty;
        try elements.append(arena, try b.byte_string(key_prefix));
        if (name) |n| {
            const ser = try serialize_key(b.gpa, arena, n, diag);
            const attribute = try std.fmt.allocPrint(arena, " name=\"{s}\"", .{ser});
            try elements.append(arena, try b.byte_string(attribute));
        } else if (key_pattern_id) |kp| {
            try elements.append(arena, try b.byte_string(" name=\""));
            try elements.append(arena, kp);
            try elements.append(arena, try b.byte_string("\""));
        }
        return b.sequence(elements.items);
    }

    /// The type attribute, value, and closing tag of one parameter.
    fn suffix_with_type(
        self: *CohereXmlToolCallingConverter,
        type_expr: i32,
        value_rule_id: i32,
    ) Allocator.Error!i32 {
        const wrapper = self.xml_state.wrapper;
        const b = self.xml_state.base_conv;
        const arena = b.arena;
        var elements: std.ArrayList(i32) = .empty;
        try elements.append(arena, try b.byte_string(" type=\""));
        try elements.append(arena, type_expr);
        const end_attr = try std.fmt.allocPrint(arena, "\"{s}", .{wrapper.key_suffix});
        try elements.append(arena, try b.byte_string(end_attr));
        if (wrapper.value_prefix.len != 0) {
            try elements.append(arena, try b.byte_string(wrapper.value_prefix));
        }
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

    /// The suffix of an unconstrained parameter. Each type wrapper references its matching
    /// component of the Any union, instead of a type/body cross product.
    fn any_suffix(self: *CohereXmlToolCallingConverter) Allocator.Error!i32 {
        const b = self.xml_state.base_conv;
        const pairs = [_]struct { type_name: []const u8, rule_name: []const u8 }{
            .{ .type_name = "raw", .rule_name = XML_STRING },
            .{ .type_name = "json", .rule_name = COHERE_ANY_SCALAR },
            .{ .type_name = "dict", .rule_name = XML_OBJECT },
            .{ .type_name = "list", .rule_name = COHERE_ANY_LIST },
        };
        var choices: [pairs.len]i32 = undefined;
        for (pairs, 0..) |pair, i| {
            const type_expr = try b.byte_string(pair.type_name);
            const rule_id = try b.builder.get_rule_id(pair.rule_name);
            choices[i] = try self.suffix_with_type(type_expr, rule_id);
        }
        return b.choice(&choices);
    }

    /// A whole parameter correlated with `schema`.
    fn format_param(
        self: *CohereXmlToolCallingConverter,
        name: ?[]const u8,
        key_pattern_id: ?i32,
        schema: SchemaSpecPtr,
        value_rule_id: i32,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        const prefix = try self.param_prefix(name, key_pattern_id, diag);
        const suffix = try self.format_param_suffix(schema, value_rule_id, diag);
        return self.xml_state.base_conv.sequence(&.{ prefix, suffix });
    }

    /// The type attribute, value, and closing tag of one parameter, correlated with `schema`.
    /// The suffix does not depend on the name, so `$ref` schemas get one memoized rule per URI,
    /// registered before the reference is resolved so that recursive references point back at it.
    fn format_param_suffix(
        self: *CohereXmlToolCallingConverter,
        schema: SchemaSpecPtr,
        value_rule_id: i32,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        const b = self.xml_state.base_conv;
        const arena = b.arena;
        const value_rule_name = b.builder.get_rule(value_rule_id).name;
        switch (schema.spec) {
            .Ref => |reference| {
                if (self.param_ref_rules.get(reference.uri)) |rule_id| {
                    return b.rule_ref(rule_id);
                }
                const param_hint = try std.fmt.allocPrint(arena, "{s}_cohere_param", .{value_rule_name});
                const param_rule_id = try b.builder.add_empty_rule_with_hint(param_hint);
                try self.param_ref_rules.put(arena, try arena.dupe(u8, reference.uri), param_rule_id);
                const resolved = try b.resolve_ref(reference.uri, diag);
                const body = try self.format_param_suffix(resolved, value_rule_id, diag);
                b.builder.update_rule_body(param_rule_id, body);
                return b.rule_ref(param_rule_id);
            },
            // Multi-branch allOf falls back to Any in the base converter; keep it canonical.
            .Any => return self.any_suffix(),
            .AllOf => |spec| {
                if (spec.schemas.items.len != 1) return self.any_suffix();
            },
            else => {},
        }
        const options = try composite_options(arena, schema);
        if (options == null) {
            const type_name: []const u8 = switch (schema.spec) {
                .String => "raw",
                .Object => "dict",
                .Array => "list",
                .Const => |spec| type_for_literal(arena, spec.json_value),
                .Enum => |spec| common_type(arena, spec.json_values.items) orelse "json",
                else => "json",
            };
            const type_expr = try b.byte_string(type_name);
            return self.suffix_with_type(type_expr, value_rule_id);
        }
        var choices: std.ArrayList(i32) = .empty;
        try choices.ensureTotalCapacity(arena, options.?.len);
        for (options.?, 0..) |option, index| {
            const hint = try std.fmt.allocPrint(arena, "{s}_cohere_case_{d}", .{ value_rule_name, index });
            const option_rule_id = try schema_converter_mod.create_rule(self, option, hint, diag);
            try choices.append(arena, try self.format_param_suffix(option, option_rule_id, diag));
        }
        return b.choice(choices.items);
    }

    /// A key that is none of the trie's keys, from the given trie node.
    fn key_excluding_body(
        self: *CohereXmlToolCallingConverter,
        node: *const CharKeyTrie,
        depth: usize,
    ) Allocator.Error!i32 {
        const b = self.xml_state.base_conv;
        const arena = b.arena;
        var choices: std.ArrayList(i32) = .empty;
        if (depth > 0 and !node.is_terminal) {
            try choices.append(arena, try b.empty());
        }
        const empty_expr = try b.empty();
        const key_expr = try b.rule_ref_by_name(COHERE_KEY);
        const optional_key_suffix = try b.choice(&.{ empty_expr, key_expr });
        const ranges = try ordinary_key_ranges_excluding(arena, node.children.items);
        const ordinary = try b.builder.add_character_class(ranges, false);
        try choices.append(arena, try b.sequence(&.{ ordinary, optional_key_suffix }));
        for (KEY_ENTITIES) |ke| {
            if (!node.containsKey(ke.ch)) {
                const entity = try b.byte_string(ke.entity);
                try choices.append(arena, try b.sequence(&.{ entity, optional_key_suffix }));
            }
        }
        for (node.children.items) |child| {
            const spelled_str = try serialize_key_char(arena, child.ch);
            const spelled = try b.byte_string(spelled_str);
            const rest = try self.key_excluding_body(child.node, depth + 1);
            try choices.append(arena, try b.sequence(&.{ spelled, rest }));
        }
        return b.choice(choices.items);
    }

    const ArrayItemPatterns = struct {
        item_patterns: []const i32,
        additional_item_pattern: ?i32,
    };

    /// The unnamed item parameters of a Cohere list: the prefix items and the additional item.
    fn array_item_patterns(
        self: *CohereXmlToolCallingConverter,
        spec: *const ArraySpec,
        rule_name: []const u8,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!ArrayItemPatterns {
        const arena = self.xml_state.base_conv.arena;
        var item_patterns: std.ArrayList(i32) = .empty;
        try item_patterns.ensureTotalCapacity(arena, spec.prefix_items.items.len);
        for (spec.prefix_items.items, 0..) |item, index| {
            const hint = try std.fmt.allocPrint(arena, "{s}_item_{d}", .{ rule_name, index });
            const item_rule_id = try schema_converter_mod.create_rule(self, item, hint, diag);
            try item_patterns.append(arena, try self.format_param(null, null, item, item_rule_id, diag));
        }
        const additional_item_pattern: ?i32 = if (spec.additional_items != null and spec.allow_additional_items) blk: {
            const additional = spec.additional_items.?;
            const hint = try std.fmt.allocPrint(arena, "{s}_additional", .{rule_name});
            const additional_rule_id = try schema_converter_mod.create_rule(self, additional, hint, diag);
            break :blk try self.format_param(null, null, additional, additional_rule_id, diag);
        } else null;
        return .{
            .item_patterns = item_patterns.items,
            .additional_item_pattern = additional_item_pattern,
        };
    }

    // ----------------------------- SchemaConverter / XmlConverter hooks -----------------------------

    pub fn base(self: *CohereXmlToolCallingConverter) *JsonSchemaConverter {
        return self.xml_state.base_conv;
    }

    pub fn xml(self: *const CohereXmlToolCallingConverter) *const XmlToolCallingConverter {
        return &self.xml_state;
    }

    pub fn xml_mut(self: *CohereXmlToolCallingConverter) *XmlToolCallingConverter {
        return &self.xml_state;
    }

    pub fn add_basic_rules(self: *CohereXmlToolCallingConverter, diag: ?*SchemaErrorInfo) SchemaError!void {
        const b = self.xml_state.base_conv;
        // The dynamic key and recursive Any rules need stable targets before xml_object is built.
        for ([_][]const u8{ COHERE_KEY, COHERE_ANY_SCALAR, COHERE_ANY_LIST }) |name| {
            _ = try b.builder.add_empty_rule(name);
        }
        try xml_converter_mod.xml_add_basic_rules(self, diag);
        const key = try b.regex_expression("([^\\x00\"&<>]|&amp;|&lt;|&gt;|&quot;)+", false, false, diag);
        try b.builder.update_rule_body_by_name(COHERE_KEY, key);
        const scalar_names = [_][]const u8{ BASIC_NUMBER, BASIC_BOOLEAN, BASIC_NULL };
        var scalars: [scalar_names.len]i32 = undefined;
        for (scalar_names, 0..) |name, i| {
            scalars[i] = try b.rule_ref_by_name(name);
        }
        const scalar = try b.choice(&scalars);
        try b.builder.update_rule_body_by_name(COHERE_ANY_SCALAR, scalar);
        // xml_object already provides the named Any members; lists need unnamed Any items.
        const unnamed_any_value = try self.param_prefix(null, null, diag);
        const any_suf = try self.any_suffix();
        const item = try b.sequence(&.{ unnamed_any_value, any_suf });
        const list = try b.repeat("cohere_any_list_items", item, 0, -1);
        try b.builder.update_rule_body_by_name(COHERE_ANY_LIST, list);
    }

    pub fn add_cache(self: *CohereXmlToolCallingConverter, key: []const u8, rule_id: i32) Allocator.Error!void {
        if (key.len != 0) {
            const context: i32 = @intFromBool(self.xml_state.nested_object_level > 1 and !self.in_value_context());
            try self.xml_state.base_conv.rule_cache.put(.{
                .key = try self.xml_state.base_conv.arena.dupe(u8, key),
                .context = context,
            }, rule_id);
        }
    }

    pub fn get_cache(self: *CohereXmlToolCallingConverter, key: []const u8) ?i32 {
        if (key.len == 0) return null;
        // `true` and {} are equivalent: an unrestricted dictionary at the tool-arguments root.
        if (self.at_root() and (std.mem.eql(u8, key, "{}") or std.mem.eql(u8, key, "true"))) {
            return self.xml_state.base_conv.builder.get_rule_id(XML_OBJECT) catch null;
        }
        const context: i32 = @intFromBool(self.xml_state.nested_object_level > 1 and !self.in_value_context());
        return self.xml_state.base_conv.rule_cache.get(.{ .key = key, .context = context });
    }

    pub fn ref_cache_key(self: *CohereXmlToolCallingConverter, uri: []const u8) Allocator.Error![]const u8 {
        // Recursive dict/list contents remain tagged values regardless of depth.
        const context: i32 = if (self.at_root())
            0
        else if (self.in_value_context())
            1
        else
            2;
        return std.fmt.allocPrint(self.xml_state.base_conv.arena, "{d}:{s}", .{ context, uri });
    }

    pub fn next_separator(self: *CohereXmlToolCallingConverter, is_end: bool) Allocator.Error![]u8 {
        if (self.in_value_context()) {
            return self.xml_state.base_conv.whitespace_pattern();
        }
        return self.xml_state.base_conv.indent_manager.next_separator(is_end);
    }

    pub fn key_pattern(self: *CohereXmlToolCallingConverter) []const u8 {
        if (self.in_value_context()) {
            return COHERE_KEY;
        }
        return BASIC_STRING;
    }

    pub fn basic_any_rule_name(self: *CohereXmlToolCallingConverter) []const u8 {
        return self.xml_state.basic_any_rule_name();
    }

    pub fn key_pattern_excluding(
        self: *CohereXmlToolCallingConverter,
        properties: []const Property,
        rule_name: []const u8,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        if (!self.in_value_context()) {
            return schema_converter_mod.json_key_pattern_excluding(self, properties, rule_name, diag);
        }
        if (properties.len == 0) {
            return schema_converter_mod.key_pattern_expression(self);
        }
        const b = self.xml_state.base_conv;
        for (properties) |property| {
            try check_key(b.gpa, diag, property.name);
        }
        const trie = try CharKeyTrie.build(b.arena, properties);
        const hint = try std.fmt.allocPrint(b.arena, "{s}_cohere_addl_key", .{rule_name});
        const key_rule_id = try b.builder.add_empty_rule_with_hint(hint);
        const body = try self.key_excluding_body(&trie, 0);
        b.builder.update_rule_body(key_rule_id, body);
        return b.rule_ref(key_rule_id);
    }

    pub fn generate_string(
        self: *CohereXmlToolCallingConverter,
        spec: *const StringSpec,
        rule_name: []const u8,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        if (!self.in_value_context()) {
            return schema_converter_mod.json_generate_string(self, spec, rule_name, diag);
        }
        const b = self.xml_state.base_conv;
        const bounded = spec.min_length != 0 or spec.max_length != -1;
        if (spec.pattern == null and spec.format == null and !bounded) {
            return b.rule_ref_by_name(XML_STRING);
        }
        if (spec.format) |fmt| {
            if (try json_format_to_regex_pattern(b.arena, fmt)) |regex| {
                return b.regex_expression(regex, false, true, diag);
            }
        }
        if (spec.pattern) |pattern| {
            return b.regex_expression(pattern, false, true, diag);
        }
        if (bounded) {
            return b.raw_characters(spec, rule_name);
        }
        return schema_converter_mod.json_generate_string(self, spec, rule_name, diag);
    }

    pub fn generate_array(
        self: *CohereXmlToolCallingConverter,
        spec: *const ArraySpec,
        rule_name: []const u8,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        if (!self.in_value_context()) {
            self.xml_state.nested_object_level += 1;
            defer self.xml_state.nested_object_level -= 1;
            return schema_converter_mod.json_generate_array(self, spec, rule_name, diag);
        }
        const patterns = blk: {
            self.array_level += 1;
            defer self.array_level -= 1;
            break :blk try self.array_item_patterns(spec, rule_name, diag);
        };
        const item_patterns = patterns.item_patterns;
        const additional_item_pattern = patterns.additional_item_pattern;

        const b = self.xml_state.base_conv;
        const arena = b.arena;
        if (item_patterns.len == 0) {
            const additional = if (spec.max_items != 0) additional_item_pattern else null;
            if (additional == null) {
                return b.empty();
            }
            const hint = try std.fmt.allocPrint(arena, "{s}_items", .{rule_name});
            return b.repeat(hint, additional.?, @intCast(spec.min_items), max_count_of(spec.max_items, 0));
        }
        const prefix = try b.sequence(item_patterns);
        const additional = additional_item_pattern orelse return prefix;
        const item_count: i64 = @intCast(item_patterns.len);
        const minimum_additional: i32 = @intCast(@max(spec.min_items - item_count, 0));
        const rest_hint = try std.fmt.allocPrint(arena, "{s}_additional_items", .{rule_name});
        const rest = try b.repeat(rest_hint, additional, minimum_additional, max_count_of(spec.max_items, item_count));
        return b.sequence(&.{ prefix, rest });
    }

    pub fn generate_object(
        self: *CohereXmlToolCallingConverter,
        spec: *const ObjectSpec,
        rule_name: []const u8,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        self.xml_state.nested_object_level += 1;
        defer self.xml_state.nested_object_level -= 1;
        if (self.in_value_context()) {
            self.object_depth += 1;
            defer self.object_depth -= 1;
            return schema_converter_mod.json_generate_object(self, spec, rule_name, false, diag);
        } else {
            const need_braces = self.xml_state.nested_object_level > 1;
            return schema_converter_mod.json_generate_object(self, spec, rule_name, need_braces, diag);
        }
    }

    pub fn generate_any(self: *CohereXmlToolCallingConverter, _: []const u8, _: ?*SchemaErrorInfo) SchemaError!i32 {
        if (!self.in_value_context()) {
            return schema_converter_mod.json_generate_any(self);
        }
        const at_root_now = self.at_root();
        const b = self.xml_state.base_conv;
        if (at_root_now) {
            return b.rule_ref_by_name(XML_OBJECT);
        }
        const names = [_][]const u8{ XML_STRING, COHERE_ANY_SCALAR, XML_OBJECT, COHERE_ANY_LIST };
        var choices: [names.len]i32 = undefined;
        for (names, 0..) |name, i| {
            choices[i] = try b.rule_ref_by_name(name);
        }
        return b.choice(&choices);
    }

    pub fn generate_const(
        self: *CohereXmlToolCallingConverter,
        spec: *const ConstSpec,
        _: []const u8,
        _: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        if (!self.in_value_context()) {
            return schema_converter_mod.json_generate_literals(self, &.{spec.json_value});
        }
        const b = self.xml_state.base_conv;
        const value = try XmlToolCallingConverter.xml_value(b.arena, spec.json_value);
        return b.byte_string(value);
    }

    pub fn generate_enum(
        self: *CohereXmlToolCallingConverter,
        spec: *const EnumSpec,
        _: []const u8,
        _: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        if (!self.in_value_context()) {
            return schema_converter_mod.json_generate_literals(self, spec.json_values.items);
        }
        const b = self.xml_state.base_conv;
        var values: std.ArrayList(i32) = .empty;
        try values.ensureTotalCapacity(b.arena, spec.json_values.items.len);
        for (spec.json_values.items) |json_value| {
            const raw_val = try XmlToolCallingConverter.xml_value(b.arena, json_value);
            try values.append(b.arena, try b.byte_string(raw_val));
        }
        return b.choice(values.items);
    }

    pub fn format_property_key(
        self: *CohereXmlToolCallingConverter,
        key: []const u8,
        schema: SchemaSpecPtr,
    ) Allocator.Error!i32 {
        return xml_converter_mod.xml_format_property_key(self, key, schema);
    }

    pub fn format_property(
        self: *CohereXmlToolCallingConverter,
        key: []const u8,
        value_rule_id: i32,
        _: []const u8,
        _: usize,
        schema: SchemaSpecPtr,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        if (self.object_depth > 0) {
            return self.format_param(key, null, schema, value_rule_id, diag);
        }
        return xml_converter_mod.xml_format_property(self, key, value_rule_id, schema, diag);
    }

    pub fn format_other_property(
        self: *CohereXmlToolCallingConverter,
        key_pattern_id: i32,
        value_rule_id: i32,
        rule_name: []const u8,
        rule_name_suffix: []const u8,
        schema: ?SchemaSpecPtr,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        if (schema) |sc| {
            return self.format_param(null, key_pattern_id, sc, value_rule_id, diag);
        }
        if (self.in_value_context()) {
            const arena = self.xml_state.base_conv.arena;
            const any = try SchemaSpec.make(arena, .{ .Any = {} }, "");
            const hint = try std.fmt.allocPrint(arena, "{s}_{s}_cohere_any", .{ rule_name, rule_name_suffix });
            const any_rule_id = try schema_converter_mod.create_rule(self, any, hint, diag);
            return self.format_param(null, key_pattern_id, any, any_rule_id, diag);
        }
        return xml_converter_mod.xml_format_other_property(self, key_pattern_id, value_rule_id, schema, diag);
    }
};

fn max_count_of(max_items: i64, offset: i64) i32 {
    if (max_items == -1) return -1;
    return @intCast(max_items - offset);
}

/// The alternatives of a schema whose options render with different Cohere types: unions,
/// single-schema allOf, and enums mixing raw and JSON literals.
fn composite_options(arena: Allocator, schema: SchemaSpecPtr) Allocator.Error!?[]const SchemaSpecPtr {
    switch (schema.spec) {
        .AnyOf => |spec| return spec.options.items,
        .AllOf => |spec| {
            if (spec.schemas.items.len == 1) return spec.schemas.items;
            return null;
        },
        .TypeArray => |spec| return spec.type_schemas.items,
        .Enum => |spec| {
            if (spec.json_values.items.len != 0 and common_type(arena, spec.json_values.items) == null) {
                var out: std.ArrayList(SchemaSpecPtr) = .empty;
                try out.ensureTotalCapacity(arena, spec.json_values.items.len);
                for (spec.json_values.items) |value| {
                    try out.append(arena, try SchemaSpec.make(arena, .{
                        .Const = .{ .json_value = value },
                    }, ""));
                }
                return out.items;
            }
            return null;
        },
        else => return null,
    }
}

/// The Cohere type of a literal: strings are raw text, everything else is JSON.
fn type_for_literal(arena: Allocator, json_value: []const u8) []const u8 {
    return if (parse_literal(arena, json_value) == .string) "raw" else "json";
}

/// The Cohere type shared by all literals, if they agree.
fn common_type(arena: Allocator, json_values: []const []const u8) ?[]const u8 {
    if (json_values.len == 0) return null;
    const first = type_for_literal(arena, json_values[0]);
    for (json_values[1..]) |value| {
        if (!std.mem.eql(u8, type_for_literal(arena, value), first)) return null;
    }
    return first;
}

/// Rejects property names that cannot be spelled as a Cohere name attribute.
fn check_key(gpa: Allocator, diag: ?*SchemaErrorInfo, key: []const u8) SchemaError!void {
    if (std.mem.indexOfScalar(u8, key, 0) != null) {
        return schema_error_mod.report(error.InvalidSchema, diag, gpa, "Cohere property names cannot contain NUL");
    }
}

/// A property name as a Cohere name attribute, with XML-sensitive characters as entities.
fn serialize_key(gpa: Allocator, arena: Allocator, key: []const u8, diag: ?*SchemaErrorInfo) SchemaError![]const u8 {
    try check_key(gpa, diag, key);
    var out: std.ArrayList(u8) = .empty;
    const view = std.unicode.Utf8View.initUnchecked(key);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        try out.appendSlice(arena, try serialize_key_char(arena, cp));
    }
    return out.toOwnedSlice(arena);
}

fn serialize_key_char(arena: Allocator, cp: u21) Allocator.Error![]const u8 {
    for (KEY_ENTITIES) |ke| {
        if (ke.ch == cp) return ke.entity;
    }
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buf) catch unreachable;
    return arena.dupe(u8, buf[0..len]);
}

/// The ordinary key characters that are neither NUL, XML-sensitive (spelled as entities), nor
/// one of `children` (handled by a trie branch), as positive codepoint ranges.
fn ordinary_key_ranges_excluding(arena: Allocator, children: []const CharKeyTrie.Child) Allocator.Error![]CharacterClassElement {
    var excluded: std.ArrayList(i32) = .empty;
    for (KEY_ENTITIES) |ke| try excluded.append(arena, @intCast(ke.ch));
    try excluded.append(arena, 0);
    for (children) |child| try excluded.append(arena, @intCast(child.ch));
    std.mem.sort(i32, excluded.items, {}, std.sort.asc(i32));

    var ranges: std.ArrayList(CharacterClassElement) = .empty;
    var range_start: i32 = 0;
    for (excluded.items) |codepoint| {
        if (range_start < codepoint) {
            try ranges.append(arena, CharacterClassElement.new(range_start, codepoint - 1));
        }
        if (codepoint >= range_start) {
            range_start = codepoint + 1;
        }
    }
    if (range_start <= 0x10_FFFF) {
        try ranges.append(arena, CharacterClassElement.new(range_start, 0x10_FFFF));
    }
    return ranges.toOwnedSlice(arena);
}
