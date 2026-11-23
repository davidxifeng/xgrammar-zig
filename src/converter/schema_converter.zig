//! The JSON-schema generation algorithm, expressed over overridable hooks
//! (`schema_converter.rs`).
//!
//! Zig has no traits: the Rust `SchemaConverter` trait is ported as free functions over
//! `self: anytype` (a pointer to the converter struct), following the functor-wave
//! convention. The converter must expose `pub fn base(self: *T) *JsonSchemaConverter`;
//! hook overrides must be `pub` and match the names/parameter order below exactly
//! (`@hasDecl` returns false for non-pub declarations). Defaults are the `json_*`
//! functions in this file.

const std = @import("std");
const Allocator = std.mem.Allocator;

const schema_converter_mod = @import("schema_converter.zig");
const indent_manager_mod = @import("indent_manager.zig");
const IndentManager = indent_manager_mod.IndentManager;
const json_schema_converter_mod = @import("json_schema_converter.zig");
const JsonSchemaConverter = json_schema_converter_mod.JsonSchemaConverter;
const BASIC_ANY = json_schema_converter_mod.BASIC_ANY;
const BASIC_ARRAY = json_schema_converter_mod.BASIC_ARRAY;
const BASIC_BOOLEAN = json_schema_converter_mod.BASIC_BOOLEAN;
const BASIC_ESCAPE = json_schema_converter_mod.BASIC_ESCAPE;
const BASIC_INTEGER = json_schema_converter_mod.BASIC_INTEGER;
const BASIC_NULL = json_schema_converter_mod.BASIC_NULL;
const BASIC_NUMBER = json_schema_converter_mod.BASIC_NUMBER;
const BASIC_OBJECT = json_schema_converter_mod.BASIC_OBJECT;
const BASIC_STRING = json_schema_converter_mod.BASIC_STRING;
const BASIC_STRING_SUB = json_schema_converter_mod.BASIC_STRING_SUB;
const JSON_CACHE_CONTEXT = json_schema_converter_mod.JSON_CACHE_CONTEXT;
const schema_error_mod = @import("schema_error.zig");
const SchemaError = schema_error_mod.SchemaError;
const SchemaErrorInfo = schema_error_mod.SchemaErrorInfo;
const schema_spec = @import("schema_spec.zig");
const ArraySpec = schema_spec.ArraySpec;
const ConstSpec = schema_spec.ConstSpec;
const EnumSpec = schema_spec.EnumSpec;
const IntegerSpec = schema_spec.IntegerSpec;
const NumberSpec = schema_spec.NumberSpec;
const ObjectSpec = schema_spec.ObjectSpec;
const Property = schema_spec.Property;
const RefSpec = schema_spec.RefSpec;
const SchemaSpec = schema_spec.SchemaSpec;
const SchemaSpecPtr = schema_spec.SchemaSpecPtr;
const SchemaSpecVariant = schema_spec.SchemaSpecVariant;
const StringSpec = schema_spec.StringSpec;
const TypeArraySpec = schema_spec.TypeArraySpec;
const grammar_mod = @import("../grammar/mod.zig");
const Grammar = grammar_mod.Grammar;

fn fail(e: SchemaError, diag: ?*SchemaErrorInfo, gpa: Allocator, message: []const u8) SchemaError {
    return schema_error_mod.report(e, diag, gpa, message);
}

fn failFmt(e: SchemaError, diag: ?*SchemaErrorInfo, gpa: Allocator, comptime fmt: []const u8, args: anytype) SchemaError {
    return schema_error_mod.reportFmt(e, diag, gpa, fmt, args);
}

fn diag_gpa(self: anytype) Allocator {
    return self.base().gpa;
}

// ----------------------------- hook dispatch -----------------------------

/// The shared algorithm entry: converts the parsed schema into the grammar. Consumes the
/// converter's builder (Rust moves `self`).
pub fn into_grammar(
    self: anytype,
    gpa: Allocator,
    spec: *const SchemaSpec,
    diag: ?*SchemaErrorInfo,
) SchemaError!*Grammar {
    try add_basic_rules(self, diag);
    const b = self.base();
    // Register the root rule so that `$ref: "#"` resolves to it.
    const root_rule_id = try b.builder.add_empty_rule_with_hint("root");
    const root_rule_name = b.builder.get_rule(root_rule_id).name;
    const root_key = try ref_cache_key(self, "#");
    try b.uri_to_rule_id.put(root_key, root_rule_id);
    const body = if (get_cache(self, spec.cache_key)) |cached|
        try b.rule_ref(cached)
    else blk: {
        try add_cache(self, spec.cache_key, root_rule_id);
        break :blk try generate_from_spec(self, spec, root_rule_name, diag);
    };
    b.builder.update_rule_body(root_rule_id, body);
    var moved = b.builder;
    b.builder_taken = true;
    defer moved.deinit();
    return moved.into_grammar_with_root_id(gpa, root_rule_id) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        // The builder's fresh expr rows are always valid (Rust cannot fail there).
        else => unreachable,
    };
}

/// The rule for `spec`: a cached rule, or a new rule named after `rule_name_hint`.
pub fn create_rule(
    self: anytype,
    spec: *const SchemaSpec,
    rule_name_hint: []const u8,
    diag: ?*SchemaErrorInfo,
) SchemaError!i32 {
    if (get_cache(self, spec.cache_key)) |cached| {
        return cached;
    }
    const b = self.base();
    const rule_id = try b.builder.add_empty_rule_with_hint(rule_name_hint);
    const rule_name = b.builder.get_rule(rule_id).name;
    const body = try generate_from_spec(self, spec, rule_name, diag);
    b.builder.update_rule_body(rule_id, body);
    return rule_id;
}

/// Dispatches to the generator of the spec's kind.
pub fn generate_from_spec(
    self: anytype,
    spec: *const SchemaSpec,
    rule_name: []const u8,
    diag: ?*SchemaErrorInfo,
) SchemaError!i32 {
    const b = self.base();
    switch (spec.spec) {
        .Integer => |*s| return b.generate_integer(s, rule_name, diag),
        .Number => |*s| return b.generate_number(s, rule_name, diag),
        .String => |*s| return generate_string(self, s, rule_name, diag),
        .Boolean => return try b.generate_boolean(),
        .Null => return try b.generate_null(),
        .Array => |*s| return generate_array(self, s, rule_name, diag),
        .Object => |*s| return generate_object(self, s, rule_name, diag),
        .Any => return generate_any(self, rule_name, diag),
        .Const => |*s| return generate_const(self, s, rule_name, diag),
        .Enum => |*s| return generate_enum(self, s, rule_name, diag),
        .Ref => |*s| return generate_ref(self, s, diag),
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
                const rule_id = try create_rule(self, option, hint, diag);
                try choices.append(b.arena, try b.rule_ref(rule_id));
            }
            return try b.choice(choices.items);
        },
        .AllOf => |s| {
            if (s.schemas.items.len == 1) {
                const hint = try std.fmt.allocPrint(b.arena, "{s}_case_0", .{rule_name});
                return generate_from_spec(self, s.schemas.items[0], hint, diag);
            }
            std.debug.print("Support for allOf with multiple options is still ongoing\n", .{});
            return generate_any(self, rule_name, diag);
        },
    }
}

/// `$ref`: one rule per reference key, allocated before resolving so that recursive
/// references point back at it.
pub fn generate_ref(
    self: anytype,
    spec: *const RefSpec,
    diag: ?*SchemaErrorInfo,
) SchemaError!i32 {
    const b = self.base();
    const cache_key = try ref_cache_key(self, spec.uri);
    if (b.uri_to_rule_id.get(cache_key)) |rule_id| {
        return try b.rule_ref(rule_id);
    }
    // Name the rule after the URI path so that the same $ref always gets the same name.
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
    const rule_id = try b.builder.add_empty_rule_with_hint(rule_name_hint);
    const rule_name = b.builder.get_rule(rule_id).name;
    try b.uri_to_rule_id.put(cache_key, rule_id);
    const resolved = try b.resolve_ref(spec.uri, diag);
    const body = try generate_from_spec(self, resolved, rule_name, diag);
    b.builder.update_rule_body(rule_id, body);
    try add_cache(self, resolved.cache_key, rule_id);
    return try b.rule_ref(rule_id);
}

/// A reference to the free-form key rule.
pub fn key_pattern_expression(self: anytype) Allocator.Error!i32 {
    const pattern = key_pattern(self);
    return self.base().rule_ref_by_name(pattern);
}

/// The next separator between object members, as an expression.
pub fn next_separator_expression(self: anytype, is_end: bool, diag: ?*SchemaErrorInfo) SchemaError!i32 {
    const separator = try next_separator(self, is_end);
    return self.base().formatting_expression(separator, diag);
}

/// The JSON basic rules (`basic_escape` … `basic_object`), plus empty rules for
/// `additional_rule_names` allocated right after them.
pub fn json_add_basic_rules(
    self: anytype,
    additional_rule_names: []const []const u8,
    diag: ?*SchemaErrorInfo,
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
        _ = try b.builder.add_empty_rule(name);
    }
    for (additional_rule_names) |name| {
        _ = try b.builder.add_empty_rule(name);
    }
    try b.add_helper_rules(diag);

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
    var body = try generate_any(self, BASIC_ANY, diag);
    try set_basic_rule(self, BASIC_ANY, body, "{}");
    const default_integer = IntegerSpec{};
    body = try b.generate_integer(&default_integer, BASIC_INTEGER, diag);
    try set_basic_rule(self, BASIC_INTEGER, body, "{\"type\":\"integer\"}");
    const default_number = NumberSpec{};
    body = try b.generate_number(&default_number, BASIC_NUMBER, diag);
    try set_basic_rule(self, BASIC_NUMBER, body, "{\"type\":\"number\"}");
    {
        const quote = try b.byte_string("\"");
        const string_sub = try b.rule_ref_by_name(BASIC_STRING_SUB);
        body = try b.sequence(&.{ quote, string_sub });
        try set_basic_rule(self, BASIC_STRING, body, "{\"type\":\"string\"}");
    }
    body = try b.generate_boolean();
    try set_basic_rule(self, BASIC_BOOLEAN, body, "{\"type\":\"boolean\"}");
    body = try b.generate_null();
    try set_basic_rule(self, BASIC_NULL, body, "{\"type\":\"null\"}");
    {
        var array_spec = ArraySpec{};
        array_spec.allow_additional_items = true;
        array_spec.additional_items = any_spec;
        body = try generate_array(self, &array_spec, BASIC_ARRAY, diag);
        try set_basic_rule(self, BASIC_ARRAY, body, "{\"type\":\"array\"}");
    }
    {
        var object_spec = try ObjectSpec.default(b.arena);
        object_spec.allow_additional_properties = true;
        object_spec.additional_properties_schema = any_spec;
        body = try generate_object(self, &object_spec, BASIC_OBJECT, diag);
        try set_basic_rule(self, BASIC_OBJECT, body, "{\"type\":\"object\"}");
    }
}

/// Sets the body of the basic rule `name` and caches it under `cache_key`.
pub fn set_basic_rule(self: anytype, name: []const u8, body: i32, cache_key: []const u8) Allocator.Error!void {
    const b = self.base();
    try b.builder.update_rule_body_by_name(name, body);
    const rule_id = try b.builder.get_rule_id(name);
    try add_cache(self, cache_key, rule_id);
}

/// The JSON `string`: a format or pattern regex, a length bound, or any string.
pub fn json_generate_string(
    self: anytype,
    spec: *const StringSpec,
    rule_name: []const u8,
    diag: ?*SchemaErrorInfo,
) SchemaError!i32 {
    const b = self.base();
    const quote = try b.byte_string("\"");
    if (spec.format) |format| {
        if (try json_schema_converter_mod.json_format_to_regex_pattern(b.arena, format)) |regex| {
            // The format regexes use constructs that the automaton engine does not fully
            // support yet (e.g. quoted email local parts), so they keep the CFG expansion.
            const body = try b.regex_expression(regex, false, true, diag);
            return try b.sequence(&.{ quote, body, quote });
        }
    }
    if (spec.pattern) |pattern| {
        const body = try b.regex_expression(pattern, true, false, diag);
        return try b.sequence(&.{ quote, body, quote });
    }
    // Length bounds are dropped together with exclusions: intersecting the unrolled bound
    // with the exclusion automaton would emit one rule per position and automaton state.
    if (spec.min_length != 0 or spec.max_length != -1) {
        if (b.excludes.len == 0) {
            const characters = try json_schema_converter_mod.ascii_class(b.arena, "\"\\\r\n");
            const character = try b.builder.add_character_class(characters, true);
            const hint = try std.fmt.allocPrint(b.arena, "{s}_characters", .{rule_name});
            const body = try b.repeat(hint, character, spec.min_length, spec.max_length);
            return try b.sequence(&.{ quote, body, quote });
        }
        json_schema_converter_mod.JsonSchemaConverter.warn_dropped_length_constraints(spec, rule_name);
    }
    const string_sub = try b.rule_ref_by_name(BASIC_STRING_SUB);
    return try b.sequence(&.{ quote, string_sub });
}

fn max_items_of(spec: *const ArraySpec, offset: i64) i32 {
    if (spec.max_items == -1) {
        return -1;
    }
    return @truncate(spec.max_items - offset);
}

/// The JSON `array`. `prefixItems` entries are positional: the array may end after any
/// prefix position (subject to `minItems`), and additional items only follow the full
/// prefix.
pub fn json_generate_array(
    self: anytype,
    spec: *const ArraySpec,
    rule_name: []const u8,
    diag: ?*SchemaErrorInfo,
) SchemaError!i32 {
    const b = self.base();
    const arena = b.arena;
    try b.indent_manager.start_indent();
    const start_sep_expr = try b.formatting_expression(try b.indent_manager.start_separator(), diag);
    const middle_sep_expr = try b.formatting_expression(try b.indent_manager.middle_separator(), diag);
    const end_sep_expr = try b.formatting_expression(try b.indent_manager.end_separator(), diag);
    const empty_sep_expr = try b.formatting_expression(try b.indent_manager.empty_separator(), diag);

    var item_rule_ids: std.ArrayList(i32) = .empty;
    for (spec.prefix_items.items, 0..) |item, index| {
        const hint = try std.fmt.allocPrint(arena, "{s}_item_{d}", .{ rule_name, index });
        const rule_id = try create_rule(self, item, hint, diag);
        try item_rule_ids.append(arena, rule_id);
    }
    var additional_rule_id: ?i32 = null;
    if (spec.additional_items != null and spec.allow_additional_items) {
        const hint = try std.fmt.allocPrint(arena, "{s}_additional", .{rule_name});
        additional_rule_id = try create_rule(self, spec.additional_items.?, hint, diag);
    }
    b.indent_manager.end_indent();

    const left_bracket = try b.byte_string("[");
    const right_bracket = try b.byte_string("]");
    const empty_array = try b.sequence(&.{ left_bracket, empty_sep_expr, right_bracket });

    if (item_rule_ids.items.len == 0) {
        const add = if (spec.max_items != 0) additional_rule_id else null;
        if (add == null) {
            return empty_array;
        }
        const additional = try b.rule_ref(add.?);
        const separated = try b.sequence(&.{ middle_sep_expr, additional });
        const hint = try std.fmt.allocPrint(arena, "{s}_items", .{rule_name});
        const tail = try b.repeat(hint, separated, @as(i32, @intCast(@max(spec.min_items - 1, 0))), max_items_of(spec, 1));
        const nonempty = try b.sequence(&.{ left_bracket, start_sep_expr, additional, tail, end_sep_expr, right_bracket });
        if (spec.min_items == 0) {
            return try b.choice(&.{ nonempty, empty_array });
        }
        return nonempty;
    }

    const item_count = item_rule_ids.items.len;
    const mandatory_count = @min(@as(usize, @intCast(@max(spec.min_items, 0))), item_count);
    // The mandatory head: the first min(minItems, n) items, separated.
    var content: std.ArrayList(i32) = .empty;
    for (item_rule_ids.items[0..mandatory_count], 0..) |item_rule_id, index| {
        if (index != 0) {
            try content.append(arena, middle_sep_expr);
        }
        try content.append(arena, try b.rule_ref(item_rule_id));
    }
    // The rest is a right-recursive chain `suffix_k ::= "" | sep item_k suffix_{k+1}`
    // ending with the additional-items tail, so each position is encoded once.
    var suffix = try b.empty();
    if (additional_rule_id) |add_id| {
        const additional = try b.rule_ref(add_id);
        const separated = try b.sequence(&.{ middle_sep_expr, additional });
        const minimum_additional: i32 = @intCast(@max(spec.min_items - @as(i64, @intCast(item_count)), 0));
        const hint = try std.fmt.allocPrint(arena, "{s}_additional_items", .{rule_name});
        suffix = try b.repeat(hint, separated, minimum_additional, max_items_of(spec, @intCast(item_count)));
    }
    {
        var k: usize = item_count;
        const lower = @max(mandatory_count, 1);
        while (k > lower) {
            k -= 1;
            const item = try b.rule_ref(item_rule_ids.items[k]);
            const with_item = try b.sequence(&.{ middle_sep_expr, item, suffix });
            const empty = try b.empty();
            const body = try b.choice(&.{ empty, with_item });
            const hint = try std.fmt.allocPrint(arena, "{s}_suffix_{d}", .{ rule_name, k });
            const suffix_rule_id = try b.builder.add_rule_with_hint(hint, body);
            suffix = try b.rule_ref(suffix_rule_id);
        }
    }
    if (mandatory_count == 0) {
        const item = try b.rule_ref(item_rule_ids.items[0]);
        const with_first = try b.sequence(&.{ item, suffix });
        const empty = try b.empty();
        const body = try b.choice(&.{ empty, with_first });
        const hint = try std.fmt.allocPrint(arena, "{s}_suffix_0", .{rule_name});
        const suffix_rule_id = try b.builder.add_rule_with_hint(hint, body);
        suffix = try b.rule_ref(suffix_rule_id);
    }
    try content.append(arena, suffix);
    const items = try b.sequence(content.items);
    return try b.sequence(&.{ left_bracket, start_sep_expr, items, end_sep_expr, right_bracket });
}

/// The JSON `object`; `need_braces` is false for formats that encode the members only.
pub fn json_generate_object(
    self: anytype,
    spec: *const ObjectSpec,
    rule_name: []const u8,
    need_braces: bool,
    diag: ?*SchemaErrorInfo,
) SchemaError!i32 {
    const b = self.base();
    const arena = b.arena;
    const additional = try object_additional_property(arena, spec);
    try b.indent_manager.start_indent();
    var has_content = false;
    var could_be_empty: bool = undefined;
    var content = try b.empty();

    if (spec.properties.items.len != 0 and
        (spec.pattern_properties.items.len != 0 or spec.property_names != null))
    {
        // Named properties plus patternProperties/propertyNames, which become the
        // additional-property pattern.
        var effective_additional = additional.schema;
        var effective_suffix: []const u8 = additional.suffix;
        var additional_override: ?i32 = null;
        if (spec.pattern_properties.items.len != 0) {
            var patterns: std.ArrayList(i32) = .empty;
                    for (spec.pattern_properties.items, 0..) |pattern_property, index| {
                const pattern_suffix = try std.fmt.allocPrint(arena, "pp_{d}", .{index});
                const key_hint = try std.fmt.allocPrint(arena, "{s}_{s}_key", .{ rule_name, pattern_suffix });
                const key_rule_id = try create_pattern_key_rule(self, pattern_property.pattern, key_hint, diag);
                const value_hint = try std.fmt.allocPrint(arena, "{s}_{s}", .{ rule_name, pattern_suffix });
                const value_rule_id = try create_rule(self, pattern_property.schema, value_hint, diag);
                const key = try b.rule_ref(key_rule_id);
                try patterns.append(arena, try format_other_property(
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
                const value_rule_id = try create_rule(self, effective_additional.?, value_hint, diag);
                const key = try key_pattern_expression(self);
                try patterns.append(arena, try format_other_property(
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
            // propertyNames constrains the keys of additional properties; it only applies
            // when additional properties are allowed.
            const name_hint = try std.fmt.allocPrint(arena, "{s}_name", .{rule_name});
            const key_rule_id = try create_rule(self, spec.property_names.?, name_hint, diag);
            const value_hint = try std.fmt.allocPrint(arena, "{s}_{s}", .{ rule_name, effective_suffix });
            const value_rule_id = try create_rule(self, effective_additional.?, value_hint, diag);
            const key = try b.rule_ref(key_rule_id);
            additional_override = try format_other_property(
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
        content = try partial_rule_for_properties(
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
        // patternProperties or propertyNames without named properties.
        if (spec.max_properties != 0) {
            const beginning_separator = try next_separator_expression(self, false, diag);
            var property_choices: std.ArrayList(i32) = .empty;
                    if (spec.pattern_properties.items.len == 0) {
                const property_names = spec.property_names.?;
                const name_hint = try std.fmt.allocPrint(arena, "{s}_name", .{rule_name});
                const key_rule_id = try create_rule(self, property_names, name_hint, diag);
                // propertyNames constrains only the key; a typed additionalProperties
                // schema still applies to the value.
                const value_rule_id = if (additional.schema) |add| blk: {
                    const hint = try std.fmt.allocPrint(arena, "{s}_{s}", .{ rule_name, additional.suffix });
                    break :blk try create_rule(self, add, hint, diag);
                } else b.builder.get_rule_id(basic_any_rule_name(self)) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                };
                const key = try b.rule_ref(key_rule_id);
                const property = try format_other_property(self, key, value_rule_id, rule_name, "pn", additional.schema, diag);
                try property_choices.append(arena, try b.sequence(&.{ beginning_separator, property }));
            } else {
                for (spec.pattern_properties.items, 0..) |pattern_property, index| {
                    const pattern_suffix = try std.fmt.allocPrint(arena, "prop_{d}", .{index});
                    const key_hint = try std.fmt.allocPrint(arena, "{s}_{s}_key", .{ rule_name, pattern_suffix });
                    const key_rule_id = try create_pattern_key_rule(self, pattern_property.pattern, key_hint, diag);
                    const value_hint = try std.fmt.allocPrint(arena, "{s}_{s}", .{ rule_name, pattern_suffix });
                    const value_rule_id = try create_rule(self, pattern_property.schema, value_hint, diag);
                    const key = try b.rule_ref(key_rule_id);
                    const property = try format_other_property(
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
            const property_rule_id = try b.builder.add_rule_with_hint(prop_hint, choices);
            const separator = try next_separator_expression(self, false, diag);
            const property = try b.rule_ref(property_rule_id);
            const subsequent_property = try b.sequence(&.{ separator, property });
            const rest = try b.property_with_number_constraints(
                subsequent_property,
                spec.min_properties,
                spec.max_properties,
                1,
                rule_name,
            );
            const end_separator = try next_separator_expression(self, true, diag);
            content = try b.sequence(&.{ property, rest, end_separator });
            has_content = true;
            could_be_empty = spec.min_properties == 0;
        } else {
            could_be_empty = true;
        }
    } else if (spec.properties.items.len != 0) {
        content = try partial_rule_for_properties(
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
        // No declared properties, additional properties allowed.
        if (spec.max_properties != 0) {
            const value_hint = try std.fmt.allocPrint(arena, "{s}_{s}", .{ rule_name, additional.suffix });
            const value_rule_id = try create_rule(self, add, value_hint, diag);
            const key = try key_pattern_expression(self);
            const property = try format_other_property(self, key, value_rule_id, rule_name, additional.suffix, add, diag);
            const first_separator = try next_separator_expression(self, false, diag);
            const separator = try next_separator_expression(self, false, diag);
            const subsequent_property = try b.sequence(&.{ separator, property });
            const rest = try b.property_with_number_constraints(
                subsequent_property,
                spec.min_properties,
                spec.max_properties,
                1,
                rule_name,
            );
            const end_separator = try next_separator_expression(self, true, diag);
            content = try b.sequence(&.{ first_separator, property, rest, end_separator });
            has_content = true;
        }
        could_be_empty = spec.min_properties == 0;
    } else {
        // No properties of any kind: the object is unconditionally empty.
        could_be_empty = true;
    }

    b.indent_manager.end_indent();
    const left_brace = try b.byte_string("{");
    const right_brace = try b.byte_string("}");
    const result = if (need_braces)
        try b.sequence(&.{ left_brace, content, right_brace })
    else
        content;
    if (!could_be_empty) {
        return result;
    }
    const empty_content = if (b.any_whitespace)
        try b.whitespace_expression()
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

/// The rule of a string key matching `pattern`. Built through [`generate_string`] so that
/// formats with unquoted keys produce their own key body.
pub fn create_pattern_key_rule(
    self: anytype,
    pattern: []const u8,
    rule_name_hint: []const u8,
    diag: ?*SchemaErrorInfo,
) SchemaError!i32 {
    const b = self.base();
    const key_spec = StringSpec{ .pattern = pattern };
    const spec = try SchemaSpec.make(b.arena, .{ .String = key_spec }, "");
    return create_rule(self, spec, rule_name_hint, diag);
}

/// The object members for the declared properties (in declaration order, or any order),
/// followed by the additional properties (`additional_override`, or
/// `key: additional`).
pub fn partial_rule_for_properties(
    self: anytype,
    spec: *const ObjectSpec,
    additional: ?SchemaSpecPtr,
    rule_name: []const u8,
    additional_suffix: []const u8,
    additional_override_in: ?i32,
    diag: ?*SchemaErrorInfo,
) SchemaError!i32 {
    const b = self.base();
    const arena = b.arena;
    const properties = spec.properties.items;
    const min_properties = spec.min_properties;
    const max_properties = spec.max_properties;
    if (max_properties == 0) {
        return try b.empty();
    }
    const first_separator = try next_separator_expression(self, false, diag);
    const middle_separator = try next_separator_expression(self, false, diag);
    const last_separator = try next_separator_expression(self, true, diag);
    var property_patterns: std.ArrayList(i32) = .empty;
    for (properties, 0..) |property, index| {
        const hint = try std.fmt.allocPrint(arena, "{s}_prop_{d}", .{ rule_name, index });
        const value_rule_id = try create_rule(self, property.schema, hint, diag);
        try property_patterns.append(arena, try format_property(
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
    // The Rust `additional_pattern` closure: builds (and remembers) the additional
    // member pattern the first time it is needed.
    // Rust's `additional_pattern` closure is only invoked when `additional != null`.

    if (b.any_order) {
        // One alternation over every key, repeated between max(minProperties, #required)
        // and maxProperties times: only the entry count is bounded, not which keys appear.
        var items = property_patterns;
        if (additional != null) {
            if (pattern == null) {
                pattern = try json_additional_pattern(self, properties, additional.?, rule_name, additional_suffix, diag);
            }
            try items.append(arena, pattern.?);
        }
        const choices = try b.choice(items.items);
        const item_hint = try std.fmt.allocPrint(arena, "{s}_item", .{rule_name});
        const item_rule_id = try b.builder.add_rule_with_hint(item_hint, choices);
        const item = try b.rule_ref(item_rule_id);
        const separated = try b.sequence(&.{ middle_separator, item });
        const minimum_count = @max(min_properties, @as(i32, @intCast(spec.required.count())));
        const rest = try b.property_with_number_constraints(separated, minimum_count, max_properties, 1, rule_name);
        return try b.sequence(&.{ first_separator, item, rest, last_separator });
    }

    const property_count = properties.len;
    const last = property_count - 1;
    const required = spec.required;
    const allow_additional = additional != null;
    var choices: std.ArrayList(i32) = .empty;

    if (min_properties == 0 and max_properties == -1) {
        // No property count constraints: tails[i] follows property i.
        var tails = try arena.alloc(i32, property_count);
        for (tails) |*t| t.* = try b.empty();
        if (allow_additional) {
            if (pattern == null) {
                pattern = try json_additional_pattern(self, properties, additional.?, rule_name, additional_suffix, diag);
            }
            const separated = try b.sequence(&.{ middle_separator, pattern.? });
            const hint = try std.fmt.allocPrint(arena, "{s}_additional_properties", .{rule_name});
            const repeated = try b.repeat(hint, separated, 0, -1);
            const part_hint = try std.fmt.allocPrint(arena, "{s}_part_{d}", .{ rule_name, last });
            const tail_rule_id = try b.builder.add_rule_with_hint(part_hint, repeated);
            tails[last] = try b.rule_ref(tail_rule_id);
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
                const tail_rule_id = try b.builder.add_rule_with_hint(part_hint, body);
                tails[index] = try b.rule_ref(tail_rule_id);
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
                pattern = try json_additional_pattern(self, properties, additional.?, rule_name, additional_suffix, diag);
            }
            try choices.append(arena, try b.sequence(&.{ pattern.?, tails[last] }));
        }
    } else {
        // matched_min/matched_max bound how many properties can have been emitted when
        // property i is the last one so far; tails[i][m - matched_min[i]] continues from
        // there.
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
                        pattern = try json_additional_pattern(self, properties, additional.?, rule_name, additional_suffix, diag);
                    }
                    const separated = try b.sequence(&.{ middle_separator, pattern.? });
                    const body = try b.property_with_number_constraints(separated, min_properties, max_properties, matched, rule_name);
                    const part_hint = try std.fmt.allocPrint(arena, "{s}_part_{d}_{d}", .{ rule_name, last, matched });
                    const tail_rule_id = try b.builder.add_rule_with_hint(part_hint, body);
                    try tails[last].append(arena, try b.rule_ref(tail_rule_id));
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
                    const tail_rule_id = try b.builder.add_rule_with_hint(part_hint, body);
                    try current.append(arena, try b.rule_ref(tail_rule_id));
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
                pattern = try json_additional_pattern(self, properties, additional.?, rule_name, additional_suffix, diag);
            }
            const separated = try b.sequence(&.{ middle_separator, pattern.? });
            const rest = try b.property_with_number_constraints(separated, min_properties, max_properties, 1, rule_name);
            try choices.append(arena, try b.sequence(&.{ pattern.?, rest }));
        }
    }
    const members = try b.choice(choices.items);
    return try b.sequence(&.{ first_separator, members, last_separator });
}

/// The JSON key pattern excluding the declared property names.
pub fn json_key_pattern_excluding(
    self: anytype,
    properties: []const Property,
    rule_name: []const u8,
    diag: ?*SchemaErrorInfo,
) SchemaError!i32 {
    if (properties.len == 0) {
        return key_pattern_expression(self);
    }
    const b = self.base();
    const names = try b.arena.alloc([]const u8, properties.len);
    for (properties, 0..) |property, i| names[i] = property.name;
    return b.key_excluding_names(names, rule_name, diag);
}

/// The member pattern `key: value` of an object's additional properties, whose keys
/// exclude the declared `properties`.
pub fn json_additional_pattern(
    self: anytype,
    properties: []const Property,
    additional: SchemaSpecPtr,
    rule_name: []const u8,
    suffix: []const u8,
    diag: ?*SchemaErrorInfo,
) SchemaError!i32 {
    const b = self.base();
    const value_hint = try std.fmt.allocPrint(b.arena, "{s}_{s}", .{ rule_name, suffix });
    const value_rule_id = try create_rule(self, additional, value_hint, diag);
    const key = try key_pattern_excluding(self, properties, rule_name, diag);
    return format_other_property(self, key, value_rule_id, rule_name, suffix, additional, diag);
}

/// Any JSON value.
pub fn json_generate_any(self: anytype) SchemaError!i32 {
    const b = self.base();
    const choices = [_][]const u8{
        BASIC_NUMBER, BASIC_STRING, BASIC_BOOLEAN, BASIC_NULL, BASIC_ARRAY, BASIC_OBJECT,
    };
    var ids: [choices.len]i32 = undefined;
    for (&ids, choices) |*id, name| id.* = try b.rule_ref_by_name(name);
    return try b.choice(&ids);
}

/// The JSON literals that contain no exclusion, as alternatives.
pub fn json_generate_literals(self: anytype, json_values: []const []const u8) SchemaError!i32 {
    const b = self.base();
    var values: std.ArrayList(i32) = .empty;
    defer values.deinit(b.arena);
    for (json_values) |value| {
        if (b.is_allowed_json_literal(value, false)) {
            values.append(b.arena, try b.byte_string(value)) catch return error.OutOfMemory;
        }
    }
    if (values.items.len == 0) {
        return try b.unsatisfiable();
    }
    return try b.choice(values.items);
}

// ----------------------------- hook wrappers -----------------------------
// Each resolves an override with `@hasDecl`, else runs the JSON default.

pub fn add_basic_rules(self: anytype, diag: ?*SchemaErrorInfo) SchemaError!void {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "add_basic_rules")) return T.add_basic_rules(self, diag);
    return json_add_basic_rules(self, &.{}, diag);
}

pub fn add_cache(self: anytype, key: []const u8, rule_id: i32) Allocator.Error!void {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "add_cache")) return T.add_cache(self, key, rule_id);
    const b = self.base();
    if (key.len != 0) {
        try b.rule_cache.put(.{ .key = try b.arena.dupe(u8, key), .context = JSON_CACHE_CONTEXT }, rule_id);
    }
}

pub fn get_cache(self: anytype, key: []const u8) ?i32 {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "get_cache")) return T.get_cache(self, key);
    if (key.len == 0) return null;
    return self.base().rule_cache.get(.{ .key = key, .context = JSON_CACHE_CONTEXT });
}

pub fn ref_cache_key(self: anytype, uri: []const u8) Allocator.Error![]const u8 {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "ref_cache_key")) return T.ref_cache_key(self, uri);
    return self.base().arena.dupe(u8, uri);
}

pub fn next_separator(self: anytype, is_end: bool) Allocator.Error![]u8 {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "next_separator")) return T.next_separator(self, is_end);
    return self.base().indent_manager.next_separator(is_end);
}

pub fn key_pattern(self: anytype) []const u8 {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "key_pattern")) return T.key_pattern(self);
    return BASIC_STRING;
}

pub fn basic_any_rule_name(self: anytype) []const u8 {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "basic_any_rule_name")) return T.basic_any_rule_name(self);
    return BASIC_ANY;
}

pub fn key_pattern_excluding(
    self: anytype,
    properties: []const Property,
    rule_name: []const u8,
    diag: ?*SchemaErrorInfo,
) SchemaError!i32 {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "key_pattern_excluding")) return T.key_pattern_excluding(self, properties, rule_name, diag);
    return json_key_pattern_excluding(self, properties, rule_name, diag);
}

pub fn generate_string(
    self: anytype,
    spec: *const StringSpec,
    rule_name: []const u8,
    diag: ?*SchemaErrorInfo,
) SchemaError!i32 {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "generate_string")) return T.generate_string(self, spec, rule_name, diag);
    return json_generate_string(self, spec, rule_name, diag);
}

pub fn generate_array(
    self: anytype,
    spec: *const ArraySpec,
    rule_name: []const u8,
    diag: ?*SchemaErrorInfo,
) SchemaError!i32 {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "generate_array")) return T.generate_array(self, spec, rule_name, diag);
    return json_generate_array(self, spec, rule_name, diag);
}

pub fn generate_object(
    self: anytype,
    spec: *const ObjectSpec,
    rule_name: []const u8,
    diag: ?*SchemaErrorInfo,
) SchemaError!i32 {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "generate_object")) return T.generate_object(self, spec, rule_name, diag);
    return json_generate_object(self, spec, rule_name, true, diag);
}

pub fn generate_any(self: anytype, rule_name: []const u8, diag: ?*SchemaErrorInfo) SchemaError!i32 {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "generate_any")) return T.generate_any(self, rule_name, diag);
    return json_generate_any(self);
}

pub fn generate_const(
    self: anytype,
    spec: *const ConstSpec,
    rule_name: []const u8,
    diag: ?*SchemaErrorInfo,
) SchemaError!i32 {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "generate_const")) return T.generate_const(self, spec, rule_name, diag);
    return json_generate_literals(self, &.{spec.json_value});
}

pub fn generate_enum(
    self: anytype,
    spec: *const EnumSpec,
    rule_name: []const u8,
    diag: ?*SchemaErrorInfo,
) SchemaError!i32 {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "generate_enum")) return T.generate_enum(self, spec, rule_name, diag);
    return json_generate_literals(self, spec.json_values.items);
}

pub fn format_property_key(self: anytype, key: []const u8, schema: SchemaSpecPtr) Allocator.Error!i32 {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "format_property_key")) return T.format_property_key(self, key, schema);
    return try self.base().json_property_key(key);
}

pub fn format_property(
    self: anytype,
    key: []const u8,
    value_rule_id: i32,
    rule_name: []const u8,
    index: usize,
    schema: SchemaSpecPtr,
    diag: ?*SchemaErrorInfo,
) SchemaError!i32 {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "format_property")) return T.format_property(self, key, value_rule_id, rule_name, index, schema, diag);
    const key_id = try format_property_key(self, key, schema);
    return try self.base().json_member(key_id, value_rule_id);
}

pub fn format_other_property(
    self: anytype,
    key_pattern_id: i32,
    value_rule_id: i32,
    rule_name: []const u8,
    rule_name_suffix: []const u8,
    schema: ?SchemaSpecPtr,
    diag: ?*SchemaErrorInfo,
) SchemaError!i32 {
    const T = @typeInfo(@TypeOf(self)).pointer.child;
    if (comptime @hasDecl(T, "format_other_property")) return T.format_other_property(self, key_pattern_id, value_rule_id, rule_name, rule_name_suffix, schema, diag);
    return self.base().json_member(key_pattern_id, value_rule_id);
}

/// The schema of the additional members of `spec` and its rule-name suffix: additional
/// properties, then unevaluated properties, then any value when either is merely allowed.
pub const AdditionalProperty = struct {
    suffix: []const u8,
    schema: ?SchemaSpecPtr,
};

pub fn object_additional_property(arena: Allocator, spec: *const ObjectSpec) Allocator.Error!AdditionalProperty {
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
    _ = json_schema_converter_mod;
    _ = indent_manager_mod;
    _ = schema_error_mod;
    _ = grammar_mod;
}
