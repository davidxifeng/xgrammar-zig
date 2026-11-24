//! The JSON-schema EBNF/AST generation algorithm, expressed over overridable hooks
//! (`schema_converter.rs`).
//!
//! Hook dispatch uses comptime `@hasDecl` over `self: anytype` (a pointer to a converter
//! struct that exposes `pub fn base(self: *T) *JsonSchemaConverter`). Override methods
//! must be `pub` and use the `camelCase` hook names below.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Diagnostic = @import("../../Diagnostic.zig").Diagnostic;
const grammar_mod = @import("../../grammar.zig");
const Grammar = grammar_mod.Grammar;
const converter_mod = @import("converter.zig");
const JsonSchemaConverter = converter_mod.JsonSchemaConverter;
const BASIC_ANY = converter_mod.BASIC_ANY;
const BASIC_ARRAY = converter_mod.BASIC_ARRAY;
const BASIC_BOOLEAN = converter_mod.BASIC_BOOLEAN;
const BASIC_ESCAPE = converter_mod.BASIC_ESCAPE;
const BASIC_INTEGER = converter_mod.BASIC_INTEGER;
const BASIC_NULL = converter_mod.BASIC_NULL;
const BASIC_NUMBER = converter_mod.BASIC_NUMBER;
const BASIC_OBJECT = converter_mod.BASIC_OBJECT;
const BASIC_STRING = converter_mod.BASIC_STRING;
const BASIC_STRING_SUB = converter_mod.BASIC_STRING_SUB;
const JSON_CACHE_CONTEXT = converter_mod.JSON_CACHE_CONTEXT;
const parser_mod = @import("parser.zig");
const SchemaError = parser_mod.SchemaError;
const spec_mod = @import("spec.zig");
const ArraySpec = spec_mod.ArraySpec;
const ConstSpec = spec_mod.ConstSpec;
const EnumSpec = spec_mod.EnumSpec;
const IndentManager = spec_mod.IndentManager;
const IntegerSpec = spec_mod.IntegerSpec;
const NumberSpec = spec_mod.NumberSpec;
const ObjectSpec = spec_mod.ObjectSpec;
const Property = spec_mod.Property;
const RefSpec = spec_mod.RefSpec;
const SchemaSpec = spec_mod.SchemaSpec;
const SchemaSpecPtr = spec_mod.SchemaSpecPtr;
const StringSpec = spec_mod.StringSpec;

const log = std.log.scoped(.xgrammar);

// ----------------------------- hook dispatch -----------------------------

/// Converts the parsed `spec` into a `Grammar` by value using `self`'s builder.
pub fn intoGrammar(
    self: anytype,
    spec: *const SchemaSpec,
    diag: ?*Diagnostic,
) SchemaError!Grammar {
    try addBasicRules(self, diag);
    const b = self.base();
    // Register the root rule so that `$ref: "#"` resolves to it.
    const root_rule_id = try b.builder.addEmptyRuleWithHint("root");
    const root_rule_name = b.builder.getRule(root_rule_id).name;
    const root_key = try refCacheKey(self, "#");
    try b.uri_to_rule_id.put(b.arena, root_key, root_rule_id);
    const body = if (getCache(self, spec.cache_key)) |cached|
        try b.ruleRef(cached)
    else blk: {
        try addCache(self, spec.cache_key, root_rule_id);
        break :blk try generateFromSpec(self, spec, root_rule_name, diag);
    };
    b.builder.updateRuleBody(root_rule_id, body);
    return b.builder.intoGrammarWithRootId(root_rule_id);
}

/// Returns the rule id for `spec`: a cached rule, or a new rule named after `rule_name_hint`.
pub fn createRule(
    self: anytype,
    spec: *const SchemaSpec,
    rule_name_hint: []const u8,
    diag: ?*Diagnostic,
) SchemaError!i32 {
    if (getCache(self, spec.cache_key)) |cached| {
        return cached;
    }
    const b = self.base();
    const rule_id = try b.builder.addEmptyRuleWithHint(rule_name_hint);
    const rule_name = b.builder.getRule(rule_id).name;
    const body = try generateFromSpec(self, spec, rule_name, diag);
    b.builder.updateRuleBody(rule_id, body);
    return rule_id;
}

/// Dispatches to the generator of `spec`'s kind.
pub fn generateFromSpec(
    self: anytype,
    spec: *const SchemaSpec,
    rule_name: []const u8,
    diag: ?*Diagnostic,
) SchemaError!i32 {
    const b = self.base();
    switch (spec.spec) {
        .Integer => |*s| return b.generateInteger(s, rule_name, diag),
        .Number => |*s| return b.generateNumber(s, rule_name, diag),
        .String => |*s| return generateString(self, s, rule_name, diag),
        .Boolean => return try b.generateBoolean(),
        .Null => return try b.generateNull(),
        .Array => |*s| return generateArray(self, s, rule_name, diag),
        .Object => |*s| return generateObject(self, s, rule_name, diag),
        .Any => return generateAny(self, rule_name, diag),
        .Const => |*s| return generateConst(self, s, rule_name, diag),
        .Enum => |*s| return generateEnum(self, s, rule_name, diag),
        .Ref => |*s| return generateRef(self, s, diag),
        .AnyOf, .TypeArray => {
            const options: []const SchemaSpecPtr = switch (spec.spec) {
                .AnyOf => |s| s.options.items,
                .TypeArray => |s| s.type_schemas.items,
                else => unreachable,
            };
            const case: []const u8 = if (spec.spec == .AnyOf) "case" else "type";
            var choices: std.ArrayList(i32) = .empty;
            for (options, 0..) |option, index| {
                const hint = try std.fmt.allocPrint(b.arena, "{s}_{s}_{d}", .{ rule_name, case, index });
                const rule_id = try createRule(self, option, hint, diag);
                try choices.append(b.arena, try b.ruleRef(rule_id));
            }
            return try b.choice(choices.items);
        },
        .AllOf => |s| {
            if (s.schemas.items.len == 1) {
                const hint = try std.fmt.allocPrint(b.arena, "{s}_case_0", .{rule_name});
                return generateFromSpec(self, s.schemas.items[0], hint, diag);
            }
            log.warn("Support for allOf with multiple options is still ongoing", .{});
            return generateAny(self, rule_name, diag);
        },
    }
}

/// `$ref`: one rule per reference key, allocated before resolving so that recursive
/// references point back at it.
pub fn generateRef(
    self: anytype,
    spec: *const RefSpec,
    diag: ?*Diagnostic,
) SchemaError!i32 {
    const b = self.base();
    const cache_key = try refCacheKey(self, spec.uri);
    if (b.uri_to_rule_id.get(cache_key)) |rule_id| {
        return try b.ruleRef(rule_id);
    }
    var rule_name_hint: []const u8 = "ref";
    if (std.mem.startsWith(u8, spec.uri, "#/")) {
        const path = spec.uri[2..];
        var prefix: std.ArrayList(u8) = .empty;
        var first = true;
        var it = std.mem.tokenizeScalar(u8, path, '/');
        while (it.next()) |part| {
            if (part.len == 0) continue;
            if (!first) try prefix.append(b.arena, '_');
            first = false;
            for (part) |c| {
                if (std.ascii.isAlphabetic(c) or c == '_' or c == '-' or c == '.') {
                    try prefix.append(b.arena, c);
                }
            }
        }
        if (prefix.items.len != 0) {
            rule_name_hint = try b.arena.dupe(u8, prefix.items);
        }
    }
    const rule_id = try b.builder.addEmptyRuleWithHint(rule_name_hint);
    const rule_name = b.builder.getRule(rule_id).name;
    try b.uri_to_rule_id.put(b.arena, cache_key, rule_id);
    const resolved = try b.resolveRef(spec.uri, diag);
    const body = try generateFromSpec(self, resolved, rule_name, diag);
    b.builder.updateRuleBody(rule_id, body);
    try addCache(self, resolved.cache_key, rule_id);
    return try b.ruleRef(rule_id);
}

/// A reference to the free-form key rule.
pub fn keyPatternExpression(self: anytype) Allocator.Error!i32 {
    const pattern = keyPattern(self);
    return self.base().ruleRefByName(pattern);
}

/// The next separator between object members, as an expression.
pub fn nextSeparatorExpression(self: anytype, is_end: bool, diag: ?*Diagnostic) SchemaError!i32 {
    const separator = try nextSeparator(self, is_end);
    defer self.base().arena.free(separator);
    return self.base().formattingExpression(separator, diag);
}

/// The JSON basic rules (`basic_escape` .. `basic_object`), plus empty rules for
/// `additional_rule_names` allocated right after them.
pub fn jsonAddBasicRules(
    self: anytype,
    additional_rule_names: []const []const u8,
    diag: ?*Diagnostic,
) SchemaError!void {
    const b = self.base();
    for ([_][]const u8{
        BASIC_ESCAPE,
        BASIC_STRING_SUB,
        BASIC_ANY,
        BASIC_INTEGER,
        BASIC_NUMBER,
        BASIC_STRING,
        BASIC_BOOLEAN,
        BASIC_NULL,
        BASIC_ARRAY,
        BASIC_OBJECT,
    }) |name| {
        _ = try b.builder.addEmptyRule(name);
    }
    for (additional_rule_names) |name| {
        _ = try b.builder.addEmptyRule(name);
    }
    try b.addHelperRules(diag);

    // The basic rules are compact regardless of the requested indentation.
    const any_whitespace = b.any_whitespace;
    var compact = try IndentManager.init(
        b.arena,
        null,
        b.indent_manager.separator,
        any_whitespace,
        if (any_whitespace) b.max_whitespace_cnt else null,
    );
    const saved_indent_manager = b.indent_manager;
    b.indent_manager = compact;
    defer {
        b.indent_manager = saved_indent_manager;
        compact.deinit();
    }

    const any_spec = try SchemaSpec.make(b.arena, .{ .Any = {} }, "{}");
    var body = try generateAny(self, BASIC_ANY, diag);
    try setBasicRule(self, BASIC_ANY, body, "{}");
    const default_integer = IntegerSpec{};
    body = try b.generateInteger(&default_integer, BASIC_INTEGER, diag);
    try setBasicRule(self, BASIC_INTEGER, body, "{\"type\":\"integer\"}");
    const default_number = NumberSpec{};
    body = try b.generateNumber(&default_number, BASIC_NUMBER, diag);
    try setBasicRule(self, BASIC_NUMBER, body, "{\"type\":\"number\"}");
    {
        const quote = try b.byteString("\"");
        const string_sub = try b.ruleRefByName(BASIC_STRING_SUB);
        body = try b.sequence(&.{ quote, string_sub });
        try setBasicRule(self, BASIC_STRING, body, "{\"type\":\"string\"}");
    }
    body = try b.generateBoolean();
    try setBasicRule(self, BASIC_BOOLEAN, body, "{\"type\":\"boolean\"}");
    body = try b.generateNull();
    try setBasicRule(self, BASIC_NULL, body, "{\"type\":\"null\"}");
    {
        var array_spec = ArraySpec{};
        array_spec.allow_additional_items = true;
        array_spec.additional_items = any_spec;
        body = try generateArray(self, &array_spec, BASIC_ARRAY, diag);
        try setBasicRule(self, BASIC_ARRAY, body, "{\"type\":\"array\"}");
    }
    {
        var object_spec = ObjectSpec{};
        object_spec.allow_additional_properties = true;
        object_spec.additional_properties_schema = any_spec;
        body = try generateObject(self, &object_spec, BASIC_OBJECT, diag);
        try setBasicRule(self, BASIC_OBJECT, body, "{\"type\":\"object\"}");
    }
}

/// Sets the body of the basic rule `name` and caches it under `cache_key`.
pub fn setBasicRule(self: anytype, name: []const u8, body: i32, cache_key: []const u8) Allocator.Error!void {
    const b = self.base();
    try b.builder.updateRuleBodyByName(name, body);
    const rule_id = try b.builder.getRuleId(name);
    try addCache(self, cache_key, rule_id);
}

/// The JSON `string`: a format or pattern regex, a length bound, or any string.
pub fn jsonGenerateString(
    self: anytype,
    spec: *const StringSpec,
    rule_name: []const u8,
    diag: ?*Diagnostic,
) SchemaError!i32 {
    const b = self.base();
    const quote = try b.byteString("\"");
    if (spec.format) |format| {
        if (try parser_mod.jsonFormatToRegexPattern(b.arena, format)) |regex| {
            const body = try b.regexExpression(regex, false, true, diag);
            return try b.sequence(&.{ quote, body, quote });
        }
    }
    if (spec.pattern) |pattern| {
        const body = try b.regexExpression(pattern, true, false, diag);
        return try b.sequence(&.{ quote, body, quote });
    }
    if (spec.min_length != 0 or spec.max_length != -1) {
        if (b.excludes.len == 0) {
            const characters = try converter_mod.asciiClass(b.arena, "\"\\\r\n");
            const character = try b.builder.addCharacterClass(characters, true);
            const hint = try std.fmt.allocPrint(b.arena, "{s}_characters", .{rule_name});
            const body = try b.repeat(hint, character, spec.min_length, spec.max_length);
            return try b.sequence(&.{ quote, body, quote });
        }
        JsonSchemaConverter.warnDroppedLengthConstraints(spec, rule_name);
    }
    const string_sub = try b.ruleRefByName(BASIC_STRING_SUB);
    return try b.sequence(&.{ quote, string_sub });
}

fn maxItemsOf(spec: *const ArraySpec, offset: i64) i32 {
    if (spec.max_items == -1) {
        return -1;
    }
    return @truncate(spec.max_items - offset);
}

/// The JSON `array`. `prefixItems` entries are positional: the array may end after any
/// prefix position (subject to `minItems`), and additional items only follow the full
/// prefix.
pub fn jsonGenerateArray(
    self: anytype,
    spec: *const ArraySpec,
    rule_name: []const u8,
    diag: ?*Diagnostic,
) SchemaError!i32 {
    const b = self.base();
    const arena = b.arena;
    try b.indent_manager.startIndent();
    const start_sep_expr = try b.formattingExpression(try b.indent_manager.startSeparator(), diag);
    const middle_sep_expr = try b.formattingExpression(try b.indent_manager.middleSeparator(), diag);
    const end_sep_expr = try b.formattingExpression(try b.indent_manager.endSeparator(), diag);
    const empty_sep_expr = try b.formattingExpression(try b.indent_manager.emptySeparator(), diag);

    var item_rule_ids: std.ArrayList(i32) = .empty;
    for (spec.prefix_items.items, 0..) |item, index| {
        const hint = try std.fmt.allocPrint(arena, "{s}_item_{d}", .{ rule_name, index });
        const rule_id = try createRule(self, item, hint, diag);
        try item_rule_ids.append(arena, rule_id);
    }
    var additional_rule_id: ?i32 = null;
    if (spec.additional_items != null and spec.allow_additional_items) {
        const hint = try std.fmt.allocPrint(arena, "{s}_additional", .{rule_name});
        additional_rule_id = try createRule(self, spec.additional_items.?, hint, diag);
    }
    b.indent_manager.endIndent();

    const left_bracket = try b.byteString("[");
    const right_bracket = try b.byteString("]");
    const empty_array = try b.sequence(&.{ left_bracket, empty_sep_expr, right_bracket });

    if (item_rule_ids.items.len == 0) {
        const add = if (spec.max_items != 0) additional_rule_id else null;
        if (add == null) {
            return empty_array;
        }
        const additional = try b.ruleRef(add.?);
        const separated = try b.sequence(&.{ middle_sep_expr, additional });
        const hint = try std.fmt.allocPrint(arena, "{s}_items", .{rule_name});
        const tail = try b.repeat(hint, separated, @as(i32, @intCast(@max(spec.min_items - 1, 0))), maxItemsOf(spec, 1));
        const nonempty = try b.sequence(&.{ left_bracket, start_sep_expr, additional, tail, end_sep_expr, right_bracket });
        if (spec.min_items == 0) {
            return try b.choice(&.{ nonempty, empty_array });
        }
        return nonempty;
    }

    const item_count = item_rule_ids.items.len;
    const mandatory_count = @min(@as(usize, @intCast(@max(spec.min_items, 0))), item_count);
    var content: std.ArrayList(i32) = .empty;
    for (item_rule_ids.items[0..mandatory_count], 0..) |item_rule_id, index| {
        if (index != 0) {
            try content.append(arena, middle_sep_expr);
        }
        try content.append(arena, try b.ruleRef(item_rule_id));
    }
    var suffix = try b.empty();
    if (additional_rule_id) |add_id| {
        const additional = try b.ruleRef(add_id);
        const separated = try b.sequence(&.{ middle_sep_expr, additional });
        const minimum_additional: i32 = @intCast(@max(spec.min_items - @as(i64, @intCast(item_count)), 0));
        const hint = try std.fmt.allocPrint(arena, "{s}_additional_items", .{rule_name});
        suffix = try b.repeat(hint, separated, minimum_additional, maxItemsOf(spec, @intCast(item_count)));
    }
    {
        var k: usize = item_count;
        const lower = @max(mandatory_count, 1);
        while (k > lower) {
            k -= 1;
            const item = try b.ruleRef(item_rule_ids.items[k]);
            const with_item = try b.sequence(&.{ middle_sep_expr, item, suffix });
            const empty = try b.empty();
            const body = try b.choice(&.{ empty, with_item });
            const hint = try std.fmt.allocPrint(arena, "{s}_suffix_{d}", .{ rule_name, k });
            const suffix_rule_id = try b.builder.addRuleWithHint(hint, body);
            suffix = try b.ruleRef(suffix_rule_id);
        }
    }
    if (mandatory_count == 0) {
        const item = try b.ruleRef(item_rule_ids.items[0]);
        const with_first = try b.sequence(&.{ item, suffix });
        const empty = try b.empty();
        const body = try b.choice(&.{ empty, with_first });
        const hint = try std.fmt.allocPrint(arena, "{s}_suffix_0", .{rule_name});
        const suffix_rule_id = try b.builder.addRuleWithHint(hint, body);
        suffix = try b.ruleRef(suffix_rule_id);
    }
    try content.append(arena, suffix);
    const items = try b.sequence(content.items);
    return try b.sequence(&.{ left_bracket, start_sep_expr, items, end_sep_expr, right_bracket });
}

/// The JSON `object`; `need_braces` is false for formats that encode the members only.
pub fn jsonGenerateObject(
    self: anytype,
    spec: *const ObjectSpec,
    rule_name: []const u8,
    need_braces: bool,
    diag: ?*Diagnostic,
) SchemaError!i32 {
    const b = self.base();
    const arena = b.arena;
    const additional = try objectAdditionalProperty(arena, spec);
    try b.indent_manager.startIndent();
    var has_content = false;
    var could_be_empty: bool = undefined;
    var content = try b.empty();

    if (spec.properties.items.len != 0 and
        (spec.pattern_properties.items.len != 0 or spec.property_names != null))
    {
        var effective_additional = additional.schema;
        var effective_suffix: []const u8 = additional.suffix;
        var additional_override: ?i32 = null;
        if (spec.pattern_properties.items.len != 0) {
            var patterns: std.ArrayList(i32) = .empty;
            for (spec.pattern_properties.items, 0..) |pattern_property, index| {
                const pattern_suffix = try std.fmt.allocPrint(arena, "pp_{d}", .{index});
                const key_hint = try std.fmt.allocPrint(arena, "{s}_{s}_key", .{ rule_name, pattern_suffix });
                const key_rule_id = try createPatternKeyRule(self, pattern_property.pattern, key_hint, diag);
                const value_hint = try std.fmt.allocPrint(arena, "{s}_{s}", .{ rule_name, pattern_suffix });
                const value_rule_id = try createRule(self, pattern_property.schema, value_hint, diag);
                const key = try b.ruleRef(key_rule_id);
                try patterns.append(arena, try formatOtherProperty(
                    self,
                    key,
                    value_rule_id,
                    rule_name,
                    pattern_suffix,
                    pattern_property.schema,
                    diag,
                ));
            }
            if (effective_additional != null) {
                const value_hint = try std.fmt.allocPrint(arena, "{s}_{s}", .{ rule_name, effective_suffix });
                const value_rule_id = try createRule(self, effective_additional.?, value_hint, diag);
                const key = try keyPatternExpression(self);
                try patterns.append(arena, try formatOtherProperty(
                    self,
                    key,
                    value_rule_id,
                    rule_name,
                    effective_suffix,
                    effective_additional,
                    diag,
                ));
            }
            additional_override = try b.choice(patterns.items);
            if (effective_additional == null) {
                effective_additional = try SchemaSpec.make(arena, .{ .Any = {} }, "");
            }
            effective_suffix = "pp";
        } else if (spec.property_names != null and effective_additional != null) {
            const name_hint = try std.fmt.allocPrint(arena, "{s}_name", .{rule_name});
            const key_rule_id = try createRule(self, spec.property_names.?, name_hint, diag);
            const value_hint = try std.fmt.allocPrint(arena, "{s}_{s}", .{ rule_name, effective_suffix });
            const value_rule_id = try createRule(self, effective_additional.?, value_hint, diag);
            const key = try b.ruleRef(key_rule_id);
            additional_override = try formatOtherProperty(
                self,
                key,
                value_rule_id,
                rule_name,
                "pn",
                effective_additional,
                diag,
            );
            effective_suffix = "pn";
        }
        content = try partialRuleForProperties(
            self,
            spec,
            effective_additional,
            rule_name,
            effective_suffix,
            additional_override,
            diag,
        );
        has_content = spec.max_properties != 0;
        could_be_empty = spec.required.count() == 0 and spec.min_properties == 0;
    } else if (spec.pattern_properties.items.len != 0 or spec.property_names != null) {
        if (spec.max_properties != 0) {
            const beginning_separator = try nextSeparatorExpression(self, false, diag);
            var property_choices: std.ArrayList(i32) = .empty;
            if (spec.pattern_properties.items.len == 0) {
                const property_names = spec.property_names.?;
                const name_hint = try std.fmt.allocPrint(arena, "{s}_name", .{rule_name});
                const key_rule_id = try createRule(self, property_names, name_hint, diag);
                const value_rule_id = if (additional.schema) |add| blk: {
                    const hint = try std.fmt.allocPrint(arena, "{s}_{s}", .{ rule_name, additional.suffix });
                    break :blk try createRule(self, add, hint, diag);
                } else try b.builder.getRuleId(basicAnyRuleName(self));
                const key = try b.ruleRef(key_rule_id);
                const property = try formatOtherProperty(self, key, value_rule_id, rule_name, "pn", additional.schema, diag);
                try property_choices.append(arena, try b.sequence(&.{ beginning_separator, property }));
            } else {
                for (spec.pattern_properties.items, 0..) |pattern_property, index| {
                    const pattern_suffix = try std.fmt.allocPrint(arena, "prop_{d}", .{index});
                    const key_hint = try std.fmt.allocPrint(arena, "{s}_{s}_key", .{ rule_name, pattern_suffix });
                    const key_rule_id = try createPatternKeyRule(self, pattern_property.pattern, key_hint, diag);
                    const value_hint = try std.fmt.allocPrint(arena, "{s}_{s}", .{ rule_name, pattern_suffix });
                    const value_rule_id = try createRule(self, pattern_property.schema, value_hint, diag);
                    const key = try b.ruleRef(key_rule_id);
                    const property = try formatOtherProperty(
                        self,
                        key,
                        value_rule_id,
                        rule_name,
                        pattern_suffix,
                        pattern_property.schema,
                        diag,
                    );
                    try property_choices.append(arena, try b.sequence(&.{ beginning_separator, property }));
                }
            }
            const choices = try b.choice(property_choices.items);
            const prop_hint = try std.fmt.allocPrint(arena, "{s}_prop", .{rule_name});
            const property_rule_id = try b.builder.addRuleWithHint(prop_hint, choices);
            const separator = try nextSeparatorExpression(self, false, diag);
            const property = try b.ruleRef(property_rule_id);
            const subsequent_property = try b.sequence(&.{ separator, property });
            const rest = try b.propertyWithNumberConstraints(
                subsequent_property,
                spec.min_properties,
                spec.max_properties,
                1,
                rule_name,
            );
            const end_separator = try nextSeparatorExpression(self, true, diag);
            content = try b.sequence(&.{ property, rest, end_separator });
            has_content = true;
            could_be_empty = spec.min_properties == 0;
        } else {
            could_be_empty = true;
        }
    } else if (spec.properties.items.len != 0) {
        content = try partialRuleForProperties(
            self,
            spec,
            additional.schema,
            rule_name,
            additional.suffix,
            null,
            diag,
        );
        has_content = spec.max_properties != 0;
        could_be_empty = spec.required.count() == 0 and spec.min_properties == 0;
    } else if (additional.schema) |add| {
        if (spec.max_properties != 0) {
            const value_hint = try std.fmt.allocPrint(arena, "{s}_{s}", .{ rule_name, additional.suffix });
            const value_rule_id = try createRule(self, add, value_hint, diag);
            const key = try keyPatternExpression(self);
            const property = try formatOtherProperty(self, key, value_rule_id, rule_name, additional.suffix, add, diag);
            const first_separator = try nextSeparatorExpression(self, false, diag);
            const separator = try nextSeparatorExpression(self, false, diag);
            const subsequent_property = try b.sequence(&.{ separator, property });
            const rest = try b.propertyWithNumberConstraints(
                subsequent_property,
                spec.min_properties,
                spec.max_properties,
                1,
                rule_name,
            );
            const end_separator = try nextSeparatorExpression(self, true, diag);
            content = try b.sequence(&.{ first_separator, property, rest, end_separator });
            has_content = true;
        }
        could_be_empty = spec.min_properties == 0;
    } else {
        could_be_empty = true;
    }

    b.indent_manager.endIndent();
    const left_brace = try b.byteString("{");
    const right_brace = try b.byteString("}");
    const result = if (need_braces)
        try b.sequence(&.{ left_brace, content, right_brace })
    else
        content;
    if (!could_be_empty) {
        return result;
    }
    const empty_content = if (b.any_whitespace)
        try b.whitespaceExpression()
    else
        try b.empty();
    const empty_result = if (need_braces)
        try b.sequence(&.{ left_brace, empty_content, right_brace })
    else
        empty_content;
    if (has_content) {
        return try b.choice(&.{ result, empty_result });
    }
    return empty_result;
}

/// The rule of a string key matching `pattern`.
pub fn createPatternKeyRule(
    self: anytype,
    pattern: []const u8,
    rule_name_hint: []const u8,
    diag: ?*Diagnostic,
) SchemaError!i32 {
    const b = self.base();
    const key_spec = StringSpec{ .pattern = pattern };
    const spec = try SchemaSpec.make(b.arena, .{ .String = key_spec }, "");
    return createRule(self, spec, rule_name_hint, diag);
}

/// The object members for the declared properties (in declaration order, or any order),
/// followed by the additional properties (`additional_override_in`, or `key: additional`).
pub fn partialRuleForProperties(
    self: anytype,
    spec: *const ObjectSpec,
    additional: ?SchemaSpecPtr,
    rule_name: []const u8,
    additional_suffix: []const u8,
    additional_override_in: ?i32,
    diag: ?*Diagnostic,
) SchemaError!i32 {
    const b = self.base();
    const arena = b.arena;
    const properties = spec.properties.items;
    const min_properties = spec.min_properties;
    const max_properties = spec.max_properties;
    if (max_properties == 0) {
        return try b.empty();
    }
    const first_separator = try nextSeparatorExpression(self, false, diag);
    const middle_separator = try nextSeparatorExpression(self, false, diag);
    const last_separator = try nextSeparatorExpression(self, true, diag);
    var property_patterns: std.ArrayList(i32) = .empty;
    for (properties, 0..) |property, index| {
        const hint = try std.fmt.allocPrint(arena, "{s}_prop_{d}", .{ rule_name, index });
        const value_rule_id = try createRule(self, property.schema, hint, diag);
        try property_patterns.append(arena, try formatProperty(
            self,
            property.name,
            value_rule_id,
            rule_name,
            index,
            property.schema,
            diag,
        ));
    }
    var pattern = additional_override_in;

    if (b.any_order) {
        var items = property_patterns;
        if (additional != null) {
            if (pattern == null) {
                pattern = try jsonAdditionalPattern(self, properties, additional.?, rule_name, additional_suffix, diag);
            }
            try items.append(arena, pattern.?);
        }
        const choices = try b.choice(items.items);
        const item_hint = try std.fmt.allocPrint(arena, "{s}_item", .{rule_name});
        const item_rule_id = try b.builder.addRuleWithHint(item_hint, choices);
        const item = try b.ruleRef(item_rule_id);
        const separated = try b.sequence(&.{ middle_separator, item });
        const minimum_count = @max(min_properties, @as(i32, @intCast(spec.required.count())));
        const rest = try b.propertyWithNumberConstraints(separated, minimum_count, max_properties, 1, rule_name);
        return try b.sequence(&.{ first_separator, item, rest, last_separator });
    }

    const property_count = properties.len;
    const last = property_count - 1;
    const required = spec.required;
    const allow_additional = additional != null;
    var choices: std.ArrayList(i32) = .empty;

    if (min_properties == 0 and max_properties == -1) {
        var tails = try arena.alloc(i32, property_count);
        for (tails) |*t| t.* = try b.empty();
        if (allow_additional) {
            if (pattern == null) {
                pattern = try jsonAdditionalPattern(self, properties, additional.?, rule_name, additional_suffix, diag);
            }
            const separated = try b.sequence(&.{ middle_separator, pattern.? });
            const hint = try std.fmt.allocPrint(arena, "{s}_additional_properties", .{rule_name});
            const repeated = try b.repeat(hint, separated, 0, -1);
            const part_hint = try std.fmt.allocPrint(arena, "{s}_part_{d}", .{ rule_name, last });
            const tail_rule_id = try b.builder.addRuleWithHint(part_hint, repeated);
            tails[last] = try b.ruleRef(tail_rule_id);
        }
        {
            var index: usize = last;
            while (index > 0) {
                index -= 1;
                const with_property = try b.sequence(&.{ middle_separator, property_patterns.items[index + 1], tails[index + 1] });
                const body = if (required.contains(properties[index + 1].name))
                    with_property
                else
                    try b.choice(&.{ tails[index + 1], with_property });
                const part_hint = try std.fmt.allocPrint(arena, "{s}_part_{d}", .{ rule_name, index });
                const tail_rule_id = try b.builder.addRuleWithHint(part_hint, body);
                tails[index] = try b.ruleRef(tail_rule_id);
            }
        }
        for (0..property_count) |index| {
            try choices.append(arena, try b.sequence(&.{ property_patterns.items[index], tails[index] }));
            if (required.contains(properties[index].name)) {
                break;
            }
        }
        if (allow_additional and required.count() == 0) {
            if (pattern == null) {
                pattern = try jsonAdditionalPattern(self, properties, additional.?, rule_name, additional_suffix, diag);
            }
            try choices.append(arena, try b.sequence(&.{ pattern.?, tails[last] }));
        }
    } else {
        const matched_min = try arena.alloc(i32, property_count);
        @memset(matched_min, 1);
        var found_required = required.contains(properties[0].name);
        for (1..property_count) |index| {
            matched_min[index] = if (!found_required)
                1
            else
                matched_min[index - 1] + @intFromBool(required.contains(properties[index].name));
            found_required = found_required or required.contains(properties[index].name);
        }
        const matched_max = try arena.alloc(i32, property_count);
        for (matched_max, 0..) |*m, i| m.* = @intCast(i + 1);
        matched_min[last] = if (allow_additional)
            @max(matched_min[last], 1)
        else
            @max(matched_min[last], min_properties);
        if (max_properties != -1) {
            matched_max[last] = @min(matched_max[last], max_properties);
        }
        {
            var index: usize = last;
            while (index > 0) {
                index -= 1;
                matched_min[index] = @max(matched_min[index], matched_min[index + 1] - 1);
                if (max_properties != -1) {
                    const next_max = matched_max[index + 1] - @intFromBool(required.contains(properties[index + 1].name));
                    matched_max[index] = @min(matched_max[index], next_max);
                }
            }
        }
        const tails = try arena.alloc(std.ArrayList(i32), property_count);
        for (tails) |*t| t.* = .empty;
        {
            var matched = matched_min[last];
            while (matched <= matched_max[last]) : (matched += 1) {
                if (allow_additional) {
                    if (pattern == null) {
                        pattern = try jsonAdditionalPattern(self, properties, additional.?, rule_name, additional_suffix, diag);
                    }
                    const separated = try b.sequence(&.{ middle_separator, pattern.? });
                    const body = try b.propertyWithNumberConstraints(separated, min_properties, max_properties, matched, rule_name);
                    const part_hint = try std.fmt.allocPrint(arena, "{s}_part_{d}_{d}", .{ rule_name, last, matched });
                    const tail_rule_id = try b.builder.addRuleWithHint(part_hint, body);
                    try tails[last].append(arena, try b.ruleRef(tail_rule_id));
                } else {
                    try tails[last].append(arena, try b.empty());
                }
            }
        }
        {
            var index: usize = last;
            while (index > 0) {
                index -= 1;
                const next = &tails[index + 1];
                const next_min = matched_min[index + 1];
                var current: std.ArrayList(i32) = .empty;
                var matched = matched_min[index];
                while (matched <= matched_max[index]) : (matched += 1) {
                    const body = if (matched == matched_max[index + 1])
                        next.items[@intCast(matched - next_min)]
                    else blk: {
                        const with_property = try b.sequence(&.{
                            middle_separator,
                            property_patterns.items[index + 1],
                            next.items[@intCast(matched + 1 - next_min)],
                        });
                        if (required.contains(properties[index + 1].name) or matched == next_min - 1) {
                            break :blk with_property;
                        }
                        break :blk try b.choice(&.{ next.items[@intCast(matched - next_min)], with_property });
                    };
                    const part_hint = try std.fmt.allocPrint(arena, "{s}_part_{d}_{d}", .{ rule_name, index, matched });
                    const tail_rule_id = try b.builder.addRuleWithHint(part_hint, body);
                    try current.append(arena, try b.ruleRef(tail_rule_id));
                }
                tails[index] = current;
            }
        }
        for (0..property_count) |index| {
            if (max_properties != -1 and matched_max[index] < matched_min[index]) {
                continue;
            }
            if (matched_min[index] > 1) {
                break;
            }
            try choices.append(arena, try b.sequence(&.{
                property_patterns.items[index],
                tails[index].items[@intCast(1 - matched_min[index])],
            }));
            if (required.contains(properties[index].name)) {
                break;
            }
        }
        if (allow_additional and required.count() == 0) {
            if (pattern == null) {
                pattern = try jsonAdditionalPattern(self, properties, additional.?, rule_name, additional_suffix, diag);
            }
            const separated = try b.sequence(&.{ middle_separator, pattern.? });
            const rest = try b.propertyWithNumberConstraints(separated, min_properties, max_properties, 1, rule_name);
            try choices.append(arena, try b.sequence(&.{ pattern.?, rest }));
        }
    }
    const members = try b.choice(choices.items);
    return try b.sequence(&.{ first_separator, members, last_separator });
}

/// The JSON key pattern excluding the declared property names.
pub fn jsonKeyPatternExcluding(
    self: anytype,
    properties: []const Property,
    rule_name: []const u8,
    diag: ?*Diagnostic,
) SchemaError!i32 {
    if (properties.len == 0) {
        return keyPatternExpression(self);
    }
    const b = self.base();
    const names = try b.arena.alloc([]const u8, properties.len);
    for (properties, 0..) |property, i| names[i] = property.name;
    return b.keyExcludingNames(names, rule_name, diag);
}

/// The member pattern `key: value` of an object's additional properties, whose keys
/// exclude the declared `properties`.
pub fn jsonAdditionalPattern(
    self: anytype,
    properties: []const Property,
    additional: SchemaSpecPtr,
    rule_name: []const u8,
    suffix: []const u8,
    diag: ?*Diagnostic,
) SchemaError!i32 {
    const b = self.base();
    const value_hint = try std.fmt.allocPrint(b.arena, "{s}_{s}", .{ rule_name, suffix });
    const value_rule_id = try createRule(self, additional, value_hint, diag);
    const key = try keyPatternExcluding(self, properties, rule_name, diag);
    return formatOtherProperty(self, key, value_rule_id, rule_name, suffix, additional, diag);
}

/// Any JSON value.
pub fn jsonGenerateAny(self: anytype) SchemaError!i32 {
    const b = self.base();
    const choices = [_][]const u8{
        BASIC_NUMBER, BASIC_STRING, BASIC_BOOLEAN, BASIC_NULL, BASIC_ARRAY, BASIC_OBJECT,
    };
    var ids: [choices.len]i32 = undefined;
    for (&ids, choices) |*id, name| id.* = try b.ruleRefByName(name);
    return try b.choice(&ids);
}

/// The JSON literals that contain no exclusion, as alternatives.
pub fn jsonGenerateLiterals(self: anytype, json_values: []const []const u8) SchemaError!i32 {
    const b = self.base();
    var values: std.ArrayList(i32) = .empty;
    defer values.deinit(b.arena);
    for (json_values) |value| {
        if (b.isAllowedJsonLiteral(value, false)) {
            values.append(b.arena, try b.byteString(value)) catch return error.OutOfMemory;
        }
    }
    if (values.items.len == 0) {
        return try b.unsatisfiable();
    }
    return try b.choice(values.items);
}

// ----------------------------- hook wrappers -----------------------------

pub fn addBasicRules(self: anytype, diag: ?*Diagnostic) SchemaError!void {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "addBasicRules")) return T.addBasicRules(self, diag);
    return jsonAddBasicRules(self, &.{}, diag);
}

pub fn addCache(self: anytype, key: []const u8, rule_id: i32) Allocator.Error!void {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "addCache")) return T.addCache(self, key, rule_id);
    const b = self.base();
    if (key.len != 0) {
        try b.rule_cache.put(b.arena, .{ .key = try b.arena.dupe(u8, key), .context = JSON_CACHE_CONTEXT }, rule_id);
    }
}

pub fn getCache(self: anytype, key: []const u8) ?i32 {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "getCache")) return T.getCache(self, key);
    if (key.len == 0) return null;
    return self.base().rule_cache.get(.{ .key = key, .context = JSON_CACHE_CONTEXT });
}

pub fn refCacheKey(self: anytype, uri: []const u8) Allocator.Error![]const u8 {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "refCacheKey")) return T.refCacheKey(self, uri);
    return self.base().arena.dupe(u8, uri);
}

pub fn nextSeparator(self: anytype, is_end: bool) Allocator.Error![]u8 {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "nextSeparator")) return T.nextSeparator(self, is_end);
    return self.base().indent_manager.nextSeparator(is_end);
}

pub fn keyPattern(self: anytype) []const u8 {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "keyPattern")) return T.keyPattern(self);
    return BASIC_STRING;
}

pub fn basicAnyRuleName(self: anytype) []const u8 {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "basicAnyRuleName")) return T.basicAnyRuleName(self);
    return BASIC_ANY;
}

pub fn keyPatternExcluding(
    self: anytype,
    properties: []const Property,
    rule_name: []const u8,
    diag: ?*Diagnostic,
) SchemaError!i32 {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "keyPatternExcluding")) return T.keyPatternExcluding(self, properties, rule_name, diag);
    return jsonKeyPatternExcluding(self, properties, rule_name, diag);
}

pub fn generateString(
    self: anytype,
    spec: *const StringSpec,
    rule_name: []const u8,
    diag: ?*Diagnostic,
) SchemaError!i32 {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "generateString")) return T.generateString(self, spec, rule_name, diag);
    return jsonGenerateString(self, spec, rule_name, diag);
}

pub fn generateArray(
    self: anytype,
    spec: *const ArraySpec,
    rule_name: []const u8,
    diag: ?*Diagnostic,
) SchemaError!i32 {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "generateArray")) return T.generateArray(self, spec, rule_name, diag);
    return jsonGenerateArray(self, spec, rule_name, diag);
}

pub fn generateObject(
    self: anytype,
    spec: *const ObjectSpec,
    rule_name: []const u8,
    diag: ?*Diagnostic,
) SchemaError!i32 {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "generateObject")) return T.generateObject(self, spec, rule_name, diag);
    return jsonGenerateObject(self, spec, rule_name, true, diag);
}

pub fn generateAny(self: anytype, rule_name: []const u8, diag: ?*Diagnostic) SchemaError!i32 {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "generateAny")) return T.generateAny(self, rule_name, diag);
    return jsonGenerateAny(self);
}

pub fn generateConst(
    self: anytype,
    spec: *const ConstSpec,
    rule_name: []const u8,
    diag: ?*Diagnostic,
) SchemaError!i32 {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "generateConst")) return T.generateConst(self, spec, rule_name, diag);
    return jsonGenerateLiterals(self, &.{spec.json_value});
}

pub fn generateEnum(
    self: anytype,
    spec: *const EnumSpec,
    rule_name: []const u8,
    diag: ?*Diagnostic,
) SchemaError!i32 {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "generateEnum")) return T.generateEnum(self, spec, rule_name, diag);
    return jsonGenerateLiterals(self, spec.json_values.items);
}

pub fn formatPropertyKey(self: anytype, key: []const u8, schema: SchemaSpecPtr) Allocator.Error!i32 {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "formatPropertyKey")) return T.formatPropertyKey(self, key, schema);
    return try self.base().jsonPropertyKey(key);
}

pub fn formatProperty(
    self: anytype,
    key: []const u8,
    value_rule_id: i32,
    rule_name: []const u8,
    index: usize,
    schema: SchemaSpecPtr,
    diag: ?*Diagnostic,
) SchemaError!i32 {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "formatProperty")) return T.formatProperty(self, key, value_rule_id, rule_name, index, schema, diag);
    const key_id = try formatPropertyKey(self, key, schema);
    return try self.base().jsonMember(key_id, value_rule_id);
}

pub fn formatOtherProperty(
    self: anytype,
    key_pattern_id: i32,
    value_rule_id: i32,
    rule_name: []const u8,
    rule_name_suffix: []const u8,
    schema: ?SchemaSpecPtr,
    diag: ?*Diagnostic,
) SchemaError!i32 {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "formatOtherProperty")) return T.formatOtherProperty(self, key_pattern_id, value_rule_id, rule_name, rule_name_suffix, schema, diag);
    return self.base().jsonMember(key_pattern_id, value_rule_id);
}

/// The schema of the additional members of `spec` and its rule-name suffix.
pub const AdditionalProperty = struct {
    suffix: []const u8,
    schema: ?SchemaSpecPtr,
};

pub fn objectAdditionalProperty(arena: Allocator, spec: *const ObjectSpec) Allocator.Error!AdditionalProperty {
    if (spec.allow_additional_properties and spec.additional_properties_schema != null) {
        return .{ .suffix = "addl", .schema = spec.additional_properties_schema };
    } else if (spec.allow_unevaluated_properties and spec.unevaluated_properties_schema != null) {
        return .{ .suffix = "uneval", .schema = spec.unevaluated_properties_schema };
    } else if (spec.allow_additional_properties or spec.allow_unevaluated_properties) {
        return .{ .suffix = "addl", .schema = try SchemaSpec.make(arena, .{ .Any = {} }, "") };
    }
    return .{ .suffix = "", .schema = null };
}

test {
    std.testing.refAllDecls(@This());
}
