//! The Cohere XML tool-calling converter (`cohere_xml_tool_calling_converter.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const Diagnostic = @import("../../Diagnostic.zig").Diagnostic;
const grammar_mod = @import("../../grammar.zig");
const CharacterClassElement = grammar_mod.CharacterClassElement;
const converter_mod = @import("converter.zig");
const JsonSchemaConverter = converter_mod.JsonSchemaConverter;
const BASIC_BOOLEAN = converter_mod.BASIC_BOOLEAN;
const BASIC_NULL = converter_mod.BASIC_NULL;
const BASIC_NUMBER = converter_mod.BASIC_NUMBER;
const BASIC_STRING = converter_mod.BASIC_STRING;
const generator = @import("generator.zig");
const parser_mod = @import("parser.zig");
const SchemaError = parser_mod.SchemaError;
const spec_mod = @import("spec.zig");
const ArraySpec = spec_mod.ArraySpec;
const ConstSpec = spec_mod.ConstSpec;
const EnumSpec = spec_mod.EnumSpec;
const ObjectSpec = spec_mod.ObjectSpec;
const Property = spec_mod.Property;
const SchemaSpec = spec_mod.SchemaSpec;
const SchemaSpecPtr = spec_mod.SchemaSpecPtr;
const StringSpec = spec_mod.StringSpec;
const xml_mod = @import("xml.zig");
const XmlToolCallingConverter = xml_mod.XmlToolCallingConverter;
const XML_OBJECT = xml_mod.XML_OBJECT;
const XML_STRING = xml_mod.XML_STRING;

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
/// `<cofl:value name="key" type="raw|json|dict|list">value</cofl:value>`.
pub const CohereXmlToolCallingConverter = struct {
    xml_state: XmlToolCallingConverter,
    object_depth: usize,
    array_level: usize,
    param_ref_rules: std.StringHashMapUnmanaged(i32),

    pub fn init(base_conv: *JsonSchemaConverter, diag: ?*Diagnostic) SchemaError!CohereXmlToolCallingConverter {
        return .{
            .xml_state = try XmlToolCallingConverter.init(base_conv, .cohere_xml, diag),
            .object_depth = 0,
            .array_level = 0,
            .param_ref_rules = .empty,
        };
    }

    fn atRoot(self: *const CohereXmlToolCallingConverter) bool {
        return self.xml_state.nested_object_level == 0 and self.object_depth == 0 and self.array_level == 0;
    }

    fn inValueContext(self: *const CohereXmlToolCallingConverter) bool {
        return self.xml_state.nested_object_level <= 1 or self.object_depth > 0 or self.array_level > 0;
    }

    fn paramPrefix(
        self: *CohereXmlToolCallingConverter,
        name: ?[]const u8,
        key_pattern_id: ?i32,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        const key_prefix = self.xml_state.wrapper.key_prefix;
        const b = self.xml_state.base_conv;
        const arena = b.arena;
        var elements: std.ArrayList(i32) = .empty;
        try elements.append(arena, try b.byteString(key_prefix));
        if (name) |n| {
            const ser = try serializeKey(arena, n, diag);
            const attribute = try std.fmt.allocPrint(arena, " name=\"{s}\"", .{ser});
            try elements.append(arena, try b.byteString(attribute));
        } else if (key_pattern_id) |kp| {
            try elements.append(arena, try b.byteString(" name=\""));
            try elements.append(arena, kp);
            try elements.append(arena, try b.byteString("\""));
        }
        return b.sequence(elements.items);
    }

    fn suffixWithType(
        self: *CohereXmlToolCallingConverter,
        type_expr: i32,
        value_rule_id: i32,
    ) Allocator.Error!i32 {
        const wrapper = self.xml_state.wrapper;
        const b = self.xml_state.base_conv;
        const arena = b.arena;
        var elements: std.ArrayList(i32) = .empty;
        try elements.append(arena, try b.byteString(" type=\""));
        try elements.append(arena, type_expr);
        const end_attr = try std.fmt.allocPrint(arena, "\"{s}", .{wrapper.key_suffix});
        try elements.append(arena, try b.byteString(end_attr));
        if (wrapper.value_prefix.len != 0) {
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

    fn anySuffix(self: *CohereXmlToolCallingConverter) Allocator.Error!i32 {
        const b = self.xml_state.base_conv;
        const pairs = [_]struct { type_name: []const u8, rule_name: []const u8 }{
            .{ .type_name = "raw", .rule_name = XML_STRING },
            .{ .type_name = "json", .rule_name = COHERE_ANY_SCALAR },
            .{ .type_name = "dict", .rule_name = XML_OBJECT },
            .{ .type_name = "list", .rule_name = COHERE_ANY_LIST },
        };
        var choices: [pairs.len]i32 = undefined;
        for (pairs, 0..) |pair, i| {
            const type_expr = try b.byteString(pair.type_name);
            const rule_id = try b.builder.getRuleId(pair.rule_name);
            choices[i] = try self.suffixWithType(type_expr, rule_id);
        }
        return b.choice(&choices);
    }

    fn formatParam(
        self: *CohereXmlToolCallingConverter,
        name: ?[]const u8,
        key_pattern_id: ?i32,
        schema: SchemaSpecPtr,
        value_rule_id: i32,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        const prefix = try self.paramPrefix(name, key_pattern_id, diag);
        const suffix = try self.formatParamSuffix(schema, value_rule_id, diag);
        return self.xml_state.base_conv.sequence(&.{ prefix, suffix });
    }

    fn formatParamSuffix(
        self: *CohereXmlToolCallingConverter,
        schema: SchemaSpecPtr,
        value_rule_id: i32,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        const b = self.xml_state.base_conv;
        const arena = b.arena;
        const value_rule_name = b.builder.getRule(value_rule_id).name;
        switch (schema.spec) {
            .Ref => |reference| {
                if (self.param_ref_rules.get(reference.uri)) |rule_id| {
                    return b.ruleRef(rule_id);
                }
                const param_hint = try std.fmt.allocPrint(arena, "{s}_cohere_param", .{value_rule_name});
                const param_rule_id = try b.builder.addEmptyRuleWithHint(param_hint);
                try self.param_ref_rules.put(arena, try arena.dupe(u8, reference.uri), param_rule_id);
                const resolved = try b.resolveRef(reference.uri, diag);
                const body = try self.formatParamSuffix(resolved, value_rule_id, diag);
                b.builder.updateRuleBody(param_rule_id, body);
                return b.ruleRef(param_rule_id);
            },
            .Any => return self.anySuffix(),
            .AllOf => |spec| {
                if (spec.schemas.items.len != 1) return self.anySuffix();
            },
            else => {},
        }
        const options = try compositeOptions(arena, schema);
        if (options == null) {
            const type_name: []const u8 = switch (schema.spec) {
                .String => "raw",
                .Object => "dict",
                .Array => "list",
                .Const => |spec| typeForLiteral(arena, spec.json_value),
                .Enum => |spec| commonType(arena, spec.json_values.items) orelse "json",
                else => "json",
            };
            const type_expr = try b.byteString(type_name);
            return self.suffixWithType(type_expr, value_rule_id);
        }
        var choices: std.ArrayList(i32) = .empty;
        try choices.ensureTotalCapacity(arena, options.?.len);
        for (options.?, 0..) |option, index| {
            const hint = try std.fmt.allocPrint(arena, "{s}_cohere_case_{d}", .{ value_rule_name, index });
            const option_rule_id = try generator.createRule(self, option, hint, diag);
            try choices.append(arena, try self.formatParamSuffix(option, option_rule_id, diag));
        }
        return b.choice(choices.items);
    }

    fn keyExcludingBody(
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
        const key_expr = try b.ruleRefByName(COHERE_KEY);
        const optional_key_suffix = try b.choice(&.{ empty_expr, key_expr });
        const ranges = try ordinaryKeyRangesExcluding(arena, node.children.items);
        const ordinary = try b.builder.addCharacterClass(ranges, false);
        try choices.append(arena, try b.sequence(&.{ ordinary, optional_key_suffix }));
        for (KEY_ENTITIES) |ke| {
            if (!node.containsKey(ke.ch)) {
                const entity = try b.byteString(ke.entity);
                try choices.append(arena, try b.sequence(&.{ entity, optional_key_suffix }));
            }
        }
        for (node.children.items) |child| {
            const spelled_str = try serializeKeyChar(arena, child.ch);
            const spelled = try b.byteString(spelled_str);
            const rest = try self.keyExcludingBody(child.node, depth + 1);
            try choices.append(arena, try b.sequence(&.{ spelled, rest }));
        }
        return b.choice(choices.items);
    }

    const ArrayItemPatterns = struct {
        item_patterns: []const i32,
        additional_item_pattern: ?i32,
    };

    fn arrayItemPatterns(
        self: *CohereXmlToolCallingConverter,
        spec: *const ArraySpec,
        rule_name: []const u8,
        diag: ?*Diagnostic,
    ) SchemaError!ArrayItemPatterns {
        const arena = self.xml_state.base_conv.arena;
        var item_patterns: std.ArrayList(i32) = .empty;
        try item_patterns.ensureTotalCapacity(arena, spec.prefix_items.items.len);
        for (spec.prefix_items.items, 0..) |item, index| {
            const hint = try std.fmt.allocPrint(arena, "{s}_item_{d}", .{ rule_name, index });
            const item_rule_id = try generator.createRule(self, item, hint, diag);
            try item_patterns.append(arena, try self.formatParam(null, null, item, item_rule_id, diag));
        }
        const additional_item_pattern: ?i32 = if (spec.additional_items != null and spec.allow_additional_items) blk: {
            const additional = spec.additional_items.?;
            const hint = try std.fmt.allocPrint(arena, "{s}_additional", .{rule_name});
            const additional_rule_id = try generator.createRule(self, additional, hint, diag);
            break :blk try self.formatParam(null, null, additional, additional_rule_id, diag);
        } else null;
        return .{
            .item_patterns = item_patterns.items,
            .additional_item_pattern = additional_item_pattern,
        };
    }

    // ----------------------------- hook overrides -----------------------------

    pub fn base(self: *CohereXmlToolCallingConverter) *JsonSchemaConverter {
        return self.xml_state.base_conv;
    }

    pub fn xml(self: *const CohereXmlToolCallingConverter) *const XmlToolCallingConverter {
        return &self.xml_state;
    }

    pub fn xmlMut(self: *CohereXmlToolCallingConverter) *XmlToolCallingConverter {
        return &self.xml_state;
    }

    pub fn addBasicRules(self: *CohereXmlToolCallingConverter, diag: ?*Diagnostic) SchemaError!void {
        const b = self.xml_state.base_conv;
        for ([_][]const u8{ COHERE_KEY, COHERE_ANY_SCALAR, COHERE_ANY_LIST }) |name| {
            _ = try b.builder.addEmptyRule(name);
        }
        try xml_mod.xmlAddBasicRules(self, diag);
        const key = try b.regexExpression("([^\\x00\"&<>]|&amp;|&lt;|&gt;|&quot;)+", false, false, diag);
        try b.builder.updateRuleBodyByName(COHERE_KEY, key);
        const scalar_names = [_][]const u8{ BASIC_NUMBER, BASIC_BOOLEAN, BASIC_NULL };
        var scalars: [scalar_names.len]i32 = undefined;
        for (scalar_names, 0..) |name, i| {
            scalars[i] = try b.ruleRefByName(name);
        }
        const scalar = try b.choice(&scalars);
        try b.builder.updateRuleBodyByName(COHERE_ANY_SCALAR, scalar);
        const unnamed_any_value = try self.paramPrefix(null, null, diag);
        const any_suf = try self.anySuffix();
        const item = try b.sequence(&.{ unnamed_any_value, any_suf });
        const list = try b.repeat("cohere_any_list_items", item, 0, -1);
        try b.builder.updateRuleBodyByName(COHERE_ANY_LIST, list);
    }

    pub fn addCache(self: *CohereXmlToolCallingConverter, key: []const u8, rule_id: i32) Allocator.Error!void {
        if (key.len != 0) {
            const context: i32 = @intFromBool(self.xml_state.nested_object_level > 1 and !self.inValueContext());
            try self.xml_state.base_conv.rule_cache.put(self.xml_state.base_conv.arena, .{
                .key = try self.xml_state.base_conv.arena.dupe(u8, key),
                .context = context,
            }, rule_id);
        }
    }

    pub fn getCache(self: *CohereXmlToolCallingConverter, key: []const u8) ?i32 {
        if (key.len == 0) return null;
        if (self.atRoot() and (std.mem.eql(u8, key, "{}") or std.mem.eql(u8, key, "true"))) {
            return self.xml_state.base_conv.builder.getRuleId(XML_OBJECT) catch null;
        }
        const context: i32 = @intFromBool(self.xml_state.nested_object_level > 1 and !self.inValueContext());
        return self.xml_state.base_conv.rule_cache.get(.{ .key = key, .context = context });
    }

    pub fn refCacheKey(self: *CohereXmlToolCallingConverter, uri: []const u8) Allocator.Error![]const u8 {
        const context: i32 = if (self.atRoot())
            0
        else if (self.inValueContext())
            1
        else
            2;
        return std.fmt.allocPrint(self.xml_state.base_conv.arena, "{d}:{s}", .{ context, uri });
    }

    pub fn nextSeparator(self: *CohereXmlToolCallingConverter, is_end: bool) Allocator.Error![]u8 {
        if (self.inValueContext()) {
            return self.xml_state.base_conv.whitespacePattern();
        }
        return self.xml_state.base_conv.indent_manager.nextSeparator(is_end);
    }

    pub fn keyPattern(self: *CohereXmlToolCallingConverter) []const u8 {
        if (self.inValueContext()) {
            return COHERE_KEY;
        }
        return BASIC_STRING;
    }

    pub fn basicAnyRuleName(self: *CohereXmlToolCallingConverter) []const u8 {
        return self.xml_state.basicAnyRuleName();
    }

    pub fn keyPatternExcluding(
        self: *CohereXmlToolCallingConverter,
        properties: []const Property,
        rule_name: []const u8,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        if (!self.inValueContext()) {
            return generator.jsonKeyPatternExcluding(self, properties, rule_name, diag);
        }
        if (properties.len == 0) {
            return generator.keyPatternExpression(self);
        }
        const b = self.xml_state.base_conv;
        for (properties) |property| {
            try checkKey(diag, property.name);
        }
        const trie = try CharKeyTrie.build(b.arena, properties);
        const hint = try std.fmt.allocPrint(b.arena, "{s}_cohere_addl_key", .{rule_name});
        const key_rule_id = try b.builder.addEmptyRuleWithHint(hint);
        const body = try self.keyExcludingBody(&trie, 0);
        b.builder.updateRuleBody(key_rule_id, body);
        return b.ruleRef(key_rule_id);
    }

    pub fn generateString(
        self: *CohereXmlToolCallingConverter,
        spec: *const StringSpec,
        rule_name: []const u8,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        if (!self.inValueContext()) {
            return generator.jsonGenerateString(self, spec, rule_name, diag);
        }
        const b = self.xml_state.base_conv;
        const bounded = spec.min_length != 0 or spec.max_length != -1;
        if (spec.pattern == null and spec.format == null and !bounded) {
            return b.ruleRefByName(XML_STRING);
        }
        if (spec.format) |fmt| {
            if (try parser_mod.jsonFormatToRegexPattern(b.arena, fmt)) |regex| {
                return b.regexExpression(regex, false, true, diag);
            }
        }
        if (spec.pattern) |pattern| {
            return b.regexExpression(pattern, false, true, diag);
        }
        if (bounded) {
            return b.rawCharacters(spec, rule_name);
        }
        return generator.jsonGenerateString(self, spec, rule_name, diag);
    }

    pub fn generateArray(
        self: *CohereXmlToolCallingConverter,
        spec: *const ArraySpec,
        rule_name: []const u8,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        if (!self.inValueContext()) {
            self.xml_state.nested_object_level += 1;
            defer self.xml_state.nested_object_level -= 1;
            return generator.jsonGenerateArray(self, spec, rule_name, diag);
        }
        const patterns = blk: {
            self.array_level += 1;
            defer self.array_level -= 1;
            break :blk try self.arrayItemPatterns(spec, rule_name, diag);
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
            return b.repeat(hint, additional.?, @intCast(spec.min_items), maxCountOf(spec.max_items, 0));
        }
        const prefix = try b.sequence(item_patterns);
        const additional = additional_item_pattern orelse return prefix;
        const item_count: i64 = @intCast(item_patterns.len);
        const minimum_additional: i32 = @intCast(@max(spec.min_items - item_count, 0));
        const rest_hint = try std.fmt.allocPrint(arena, "{s}_additional_items", .{rule_name});
        const rest = try b.repeat(rest_hint, additional, minimum_additional, maxCountOf(spec.max_items, item_count));
        return b.sequence(&.{ prefix, rest });
    }

    pub fn generateObject(
        self: *CohereXmlToolCallingConverter,
        spec: *const ObjectSpec,
        rule_name: []const u8,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        self.xml_state.nested_object_level += 1;
        defer self.xml_state.nested_object_level -= 1;
        if (self.inValueContext()) {
            self.object_depth += 1;
            defer self.object_depth -= 1;
            return generator.jsonGenerateObject(self, spec, rule_name, false, diag);
        } else {
            const need_braces = self.xml_state.nested_object_level > 1;
            return generator.jsonGenerateObject(self, spec, rule_name, need_braces, diag);
        }
    }

    pub fn generateAny(self: *CohereXmlToolCallingConverter, _: []const u8, _: ?*Diagnostic) SchemaError!i32 {
        if (!self.inValueContext()) {
            return generator.jsonGenerateAny(self);
        }
        const at_root_now = self.atRoot();
        const b = self.xml_state.base_conv;
        if (at_root_now) {
            return b.ruleRefByName(XML_OBJECT);
        }
        const names = [_][]const u8{ XML_STRING, COHERE_ANY_SCALAR, XML_OBJECT, COHERE_ANY_LIST };
        var choices: [names.len]i32 = undefined;
        for (names, 0..) |name, i| {
            choices[i] = try b.ruleRefByName(name);
        }
        return b.choice(&choices);
    }

    pub fn generateConst(
        self: *CohereXmlToolCallingConverter,
        spec: *const ConstSpec,
        _: []const u8,
        _: ?*Diagnostic,
    ) SchemaError!i32 {
        if (!self.inValueContext()) {
            return generator.jsonGenerateLiterals(self, &.{spec.json_value});
        }
        const b = self.xml_state.base_conv;
        const value = try XmlToolCallingConverter.xmlValue(b.arena, spec.json_value);
        return b.byteString(value);
    }

    pub fn generateEnum(
        self: *CohereXmlToolCallingConverter,
        spec: *const EnumSpec,
        _: []const u8,
        _: ?*Diagnostic,
    ) SchemaError!i32 {
        if (!self.inValueContext()) {
            return generator.jsonGenerateLiterals(self, spec.json_values.items);
        }
        const b = self.xml_state.base_conv;
        var values: std.ArrayList(i32) = .empty;
        try values.ensureTotalCapacity(b.arena, spec.json_values.items.len);
        for (spec.json_values.items) |json_value| {
            const raw_val = try XmlToolCallingConverter.xmlValue(b.arena, json_value);
            try values.append(b.arena, try b.byteString(raw_val));
        }
        return b.choice(values.items);
    }

    pub fn formatPropertyKey(
        self: *CohereXmlToolCallingConverter,
        key: []const u8,
        schema: SchemaSpecPtr,
    ) Allocator.Error!i32 {
        return xml_mod.xmlFormatPropertyKey(self, key, schema);
    }

    pub fn formatProperty(
        self: *CohereXmlToolCallingConverter,
        key: []const u8,
        value_rule_id: i32,
        _: []const u8,
        _: usize,
        schema: SchemaSpecPtr,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        if (self.object_depth > 0) {
            return self.formatParam(key, null, schema, value_rule_id, diag);
        }
        return xml_mod.xmlFormatProperty(self, key, value_rule_id, schema, diag);
    }

    pub fn formatOtherProperty(
        self: *CohereXmlToolCallingConverter,
        key_pattern_id: i32,
        value_rule_id: i32,
        rule_name: []const u8,
        rule_name_suffix: []const u8,
        schema: ?SchemaSpecPtr,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        if (schema) |sc| {
            return self.formatParam(null, key_pattern_id, sc, value_rule_id, diag);
        }
        if (self.inValueContext()) {
            const arena = self.xml_state.base_conv.arena;
            const any = try SchemaSpec.make(arena, .{ .Any = {} }, "");
            const hint = try std.fmt.allocPrint(arena, "{s}_{s}_cohere_any", .{ rule_name, rule_name_suffix });
            const any_rule_id = try generator.createRule(self, any, hint, diag);
            return self.formatParam(null, key_pattern_id, any, any_rule_id, diag);
        }
        return xml_mod.xmlFormatOtherProperty(self, key_pattern_id, value_rule_id, schema, diag);
    }
};

fn maxCountOf(max_items: i64, offset: i64) i32 {
    if (max_items == -1) return -1;
    return @intCast(max_items - offset);
}

fn compositeOptions(arena: Allocator, schema: SchemaSpecPtr) Allocator.Error!?[]const SchemaSpecPtr {
    switch (schema.spec) {
        .AnyOf => |spec| return spec.options.items,
        .AllOf => |spec| {
            if (spec.schemas.items.len == 1) return spec.schemas.items;
            return null;
        },
        .TypeArray => |spec| return spec.type_schemas.items,
        .Enum => |spec| {
            if (spec.json_values.items.len != 0 and commonType(arena, spec.json_values.items) == null) {
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

fn typeForLiteral(arena: Allocator, json_value: []const u8) []const u8 {
    return if (converter_mod.parseLiteral(arena, json_value) == .string) "raw" else "json";
}

fn commonType(arena: Allocator, json_values: []const []const u8) ?[]const u8 {
    if (json_values.len == 0) return null;
    const first = typeForLiteral(arena, json_values[0]);
    for (json_values[1..]) |value| {
        if (!std.mem.eql(u8, typeForLiteral(arena, value), first)) return null;
    }
    return first;
}

fn checkKey(diag: ?*Diagnostic, key: []const u8) SchemaError!void {
    if (std.mem.indexOfScalar(u8, key, 0) != null) {
        return parser_mod.failStatic(error.InvalidSchema, diag, "Cohere property names cannot contain NUL");
    }
}

fn serializeKey(arena: Allocator, key: []const u8, diag: ?*Diagnostic) SchemaError![]const u8 {
    try checkKey(diag, key);
    var out: std.ArrayList(u8) = .empty;
    const view = std.unicode.Utf8View.initUnchecked(key);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        try out.appendSlice(arena, try serializeKeyChar(arena, cp));
    }
    return out.toOwnedSlice(arena);
}

fn serializeKeyChar(arena: Allocator, cp: u21) Allocator.Error![]const u8 {
    for (KEY_ENTITIES) |ke| {
        if (ke.ch == cp) return ke.entity;
    }
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buf) catch unreachable;
    return arena.dupe(u8, buf[0..len]);
}

fn ordinaryKeyRangesExcluding(arena: Allocator, children: []const CharKeyTrie.Child) Allocator.Error![]CharacterClassElement {
    var excluded: std.ArrayList(i32) = .empty;
    for (KEY_ENTITIES) |ke| try excluded.append(arena, @intCast(ke.ch));
    try excluded.append(arena, 0);
    for (children) |child| try excluded.append(arena, @intCast(child.ch));
    std.mem.sort(i32, excluded.items, {}, std.sort.asc(i32));

    var ranges: std.ArrayList(CharacterClassElement) = .empty;
    var range_start: i32 = 0;
    for (excluded.items) |codepoint| {
        if (range_start < codepoint) {
            try ranges.append(arena, CharacterClassElement.init(range_start, codepoint - 1));
        }
        if (codepoint >= range_start) {
            range_start = codepoint + 1;
        }
    }
    if (range_start <= 0x10_FFFF) {
        try ranges.append(arena, CharacterClassElement.init(range_start, 0x10_FFFF));
    }
    return ranges.toOwnedSlice(arena);
}

test "CohereXmlToolCallingConverter key validation and CharKeyTrie" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var diag: Diagnostic = .{};
    defer diag.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidSchema, checkKey(&diag, "bad\x00key"));
    try std.testing.expectEqualStrings("Cohere property names cannot contain NUL", diag.message);

    const ser = try serializeKey(aa, "a&b\"<c>", null);
    try std.testing.expectEqualStrings("a&amp;b&quot;&lt;c&gt;", ser);

    std.testing.refAllDecls(@This());
}
