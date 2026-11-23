//! Converts a JSON Schema into a grammar AST, built directly through [`GrammarBuilder`]
//! (`json_schema_converter.rs`).
//!
//! [`JsonSchemaConverter`] owns the conversion state and the grammar-building primitives.
//! The generation algorithm lives in [`schema_converter`] (the Rust `SchemaConverter`
//! trait, ported as anytype-dispatched free functions), whose hooks the XML tool-calling
//! converters override.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const indent_manager_mod = @import("indent_manager.zig");
const IndentManager = indent_manager_mod.IndentManager;
const json_format_mod = @import("json_format.zig");
const JsonFormat = json_format_mod.JsonFormat;
const key_trie_mod = @import("key_trie.zig");
const KeyTrie = key_trie_mod.KeyTrie;
const range_regex_mod = @import("range_regex.zig");
const regex_converter_mod = @import("regex_converter.zig");
const regex_error_mod = @import("regex_error.zig");
const RegexErrorInfo = regex_error_mod.RegexErrorInfo;
const schema_converter_mod = @import("schema_converter.zig");
const schema_error_mod = @import("schema_error.zig");
pub const SchemaError = schema_error_mod.SchemaError;
pub const SchemaErrorInfo = schema_error_mod.SchemaErrorInfo;
const schema_parser_mod = @import("schema_parser.zig");
const SchemaParser = schema_parser_mod.SchemaParser;
const schema_spec = @import("schema_spec.zig");
const IntegerSpec = schema_spec.IntegerSpec;
const NumberSpec = schema_spec.NumberSpec;
const SchemaSpecPtr = schema_spec.SchemaSpecPtr;
const StringSpec = schema_spec.StringSpec;
const utf8_range_collapser_mod = @import("utf8_range_collapser.zig");
const Utf8RangeCollapser = utf8_range_collapser_mod.Utf8RangeCollapser;
const xml_tool_calling_converter_mod = @import("xml_tool_calling_converter.zig");
const XmlToolCallingConverter = xml_tool_calling_converter_mod.XmlToolCallingConverter;
const cohere_xml_tool_calling_converter_mod = @import("cohere_xml_tool_calling_converter.zig");
const CohereXmlToolCallingConverter = cohere_xml_tool_calling_converter_mod.CohereXmlToolCallingConverter;
const minimax_m3_xml_tool_calling_converter_mod = @import("minimax_m3_xml_tool_calling_converter.zig");
const MiniMaxM3XmlToolCallingConverter = minimax_m3_xml_tool_calling_converter_mod.MiniMaxM3XmlToolCallingConverter;
const fsm_mod = @import("../fsm/mod.zig");
const FsmWithStartEnd = fsm_mod.FsmWithStartEnd;
const TrieFsmBuilder = fsm_mod.TrieFsmBuilder;
const functor_mod = @import("../functor/mod.zig");
const grammar_mod = @import("../grammar/mod.zig");
const CharacterClassElement = grammar_mod.CharacterClassElement;
const Grammar = grammar_mod.Grammar;
const GrammarBuilder = grammar_mod.GrammarBuilder;
const GrammarExprType = grammar_mod.GrammarExprType;
const TagDispatch = grammar_mod.TagDispatch;
const support = @import("../support/mod.zig");
const parser_mod = @import("../parser/mod.zig");

const Value = schema_parser_mod.Value;

fn fail(e: SchemaError, diag: ?*SchemaErrorInfo, gpa: Allocator, message: []const u8) SchemaError {
    return schema_error_mod.report(e, diag, gpa, message);
}

fn failFmt(e: SchemaError, diag: ?*SchemaErrorInfo, gpa: Allocator, comptime fmt: []const u8, args: anytype) SchemaError {
    return schema_error_mod.reportFmt(e, diag, gpa, fmt, args);
}

pub const BASIC_ANY = "basic_any";
pub const BASIC_INTEGER = "basic_integer";
pub const BASIC_NUMBER = "basic_number";
pub const BASIC_STRING = "basic_string";
pub const BASIC_BOOLEAN = "basic_boolean";
pub const BASIC_NULL = "basic_null";
pub const BASIC_ARRAY = "basic_array";
pub const BASIC_OBJECT = "basic_object";
pub const BASIC_ESCAPE = "basic_escape";
pub const BASIC_STRING_SUB = "basic_string_sub";

/// The content of a JSON string, escapes included.
pub const JSON_STRING_BODY_REGEX = "([^\"\\\\\\x00-\\x1f]|\\\\([\"\\\\/bfnrt]|u[0-9a-fA-F]{4}))*";

/// The cache context of the plain JSON encoding.
pub const JSON_CACHE_CONTEXT: i32 = 1;

const WHITESPACE_CHARACTERS = [_]CharacterClassElement{
    CharacterClassElement.new(' ', ' '),
    CharacterClassElement.new('\n', '\n'),
    CharacterClassElement.new('\r', '\r'),
    CharacterClassElement.new('\t', '\t'),
};

/// Characters that may follow the end of a JSON string or key.
const CLOSING_CONTEXT = [_]CharacterClassElement{
    CharacterClassElement.new(',', ','),
    CharacterClassElement.new('}', '}'),
    CharacterClassElement.new(']', ']'),
    CharacterClassElement.new(':', ':'),
};

/// Characters that cannot appear unescaped in a JSON string.
const JSON_STRING_SPECIAL_CHARACTERS = [_]CharacterClassElement{
    CharacterClassElement.new(0, 0x1f),
    CharacterClassElement.new('"', '"'),
    CharacterClassElement.new('\\', '\\'),
    CharacterClassElement.new('\r', '\r'),
    CharacterClassElement.new('\n', '\n'),
};

const ANY_CODEPOINT = [_]CharacterClassElement{
    CharacterClassElement.new(0, 0x10FFFF),
};

/// The two separators used in the schema: comma and colon (Rust `Option<(&str, &str)>`).
pub const Separators = struct {
    item: []const u8,
    colon: []const u8,
};

/// Converts a JSON Schema string to its EBNF grammar text (the normalized grammar,
/// printed).
///
/// `any_whitespace` allows flexible whitespace; `indent`/`separators` control formatting;
/// `strict_mode` forbids unspecified additional items/properties; `max_whitespace_cnt`
/// bounds whitespace runs; `json_format` selects the encoding of the root object;
/// `any_order` lets object properties appear in any order.
pub fn json_schema_to_ebnf(
    gpa: Allocator,
    schema: []const u8,
    any_whitespace: bool,
    indent: ?i32,
    separators: ?Separators,
    strict_mode: bool,
    max_whitespace_cnt: ?i32,
    json_format: JsonFormat,
    any_order: bool,
    excludes: []const []const u8,
    diag: ?*SchemaErrorInfo,
) (Allocator.Error || SchemaError)![]u8 {
    const grammar = try json_schema_to_grammar(
        gpa,
        schema,
        any_whitespace,
        indent,
        separators,
        strict_mode,
        max_whitespace_cnt,
        any_order,
        json_format,
        excludes,
        diag,
    );
    defer grammar.deinit();
    const normalized = grammar_normalizer_mapped(gpa, grammar) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSchema => |msg| return msg,
    };
    defer normalized.deinit();
    return grammar_mod.printer.to_string_ebnf(normalized, gpa);
}

/// Converts a JSON Schema string to an unnormalized grammar AST. `excludes` lists
/// substrings that may not appear in unconstrained string values and property names.
pub fn json_schema_to_grammar(
    gpa: Allocator,
    schema: []const u8,
    any_whitespace: bool,
    indent: ?i32,
    separators: ?Separators,
    strict_mode: bool,
    max_whitespace_cnt: ?i32,
    any_order: bool,
    json_format: JsonFormat,
    excludes: []const []const u8,
    diag: ?*SchemaErrorInfo,
) (Allocator.Error || SchemaError)!*Grammar {
    var arena_state = ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = support.parse_json(arena, schema) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        // The Rust message carries the serde parse error; the Zig parse surface exposes
        // the error name only (PORTING.md deviation, support wave).
        else => return failFmt(error.InvalidSchema, diag, gpa, "Failed to parse JSON: {s}", .{@errorName(e)}),
    };
    if (max_whitespace_cnt != null and max_whitespace_cnt.? <= 0) {
        return fail(error.InvalidSchema, diag, gpa, "max_whitespace_cnt must be positive.");
    }
    const parser = try SchemaParser.init(gpa, root, strict_mode);
    const spec = parser.parse(root, null, diag) catch |err| {
        parser.deinit();
        return err;
    };
    if (excludes.len != 0 and (json_format == .MiniMaxM3Xml or json_format == .CohereXml)) {
        parser.deinit();
        const name: []const u8 = if (json_format == .CohereXml) "cohere_xml" else "minimax_m3_xml";
        return failFmt(error.InvalidSchema, diag, gpa, "JSONSchemaFormat.excludes is not supported for {s}", .{name});
    }
    const base = JsonSchemaConverter.new(
        gpa,
        parser,
        indent,
        separators,
        any_whitespace,
        max_whitespace_cnt,
        any_order,
        excludes,
    ) catch |err| {
        parser.deinit();
        return err;
    };
    defer base.deinit();
    switch (json_format) {
        .Json => return schema_converter_mod.into_grammar(base, gpa, spec, diag),
        .MiniMaxM3Xml => {
            var conv = MiniMaxM3XmlToolCallingConverter.new(base);
            return schema_converter_mod.into_grammar(&conv, gpa, spec, diag);
        },
        .CohereXml => {
            var conv = try CohereXmlToolCallingConverter.new(base, diag);
            return schema_converter_mod.into_grammar(&conv, gpa, spec, diag);
        },
        else => {
            var conv = try XmlToolCallingConverter.new(base, json_format, diag);
            return schema_converter_mod.into_grammar(&conv, gpa, spec, diag);
        },
    }
}

/// Constructs a BNF grammar from a JSON schema string (`Grammar::from_json_schema`).
pub fn from_json_schema(
    gpa: Allocator,
    schema: []const u8,
    any_whitespace: bool,
    indent: ?i32,
    separators: ?Separators,
    strict_mode: bool,
    max_whitespace_cnt: ?i32,
    diag: ?*SchemaErrorInfo,
) (Allocator.Error || SchemaError)!*Grammar {
    return from_json_schema_with_any_order(
        gpa,
        schema,
        any_whitespace,
        indent,
        separators,
        strict_mode,
        max_whitespace_cnt,
        false,
        diag,
    );
}

/// Constructs a BNF grammar from a JSON schema string, optionally allowing object
/// properties in any order (`Grammar::from_json_schema_with_any_order`).
pub fn from_json_schema_with_any_order(
    gpa: Allocator,
    schema: []const u8,
    any_whitespace: bool,
    indent: ?i32,
    separators: ?Separators,
    strict_mode: bool,
    max_whitespace_cnt: ?i32,
    any_order: bool,
    diag: ?*SchemaErrorInfo,
) (Allocator.Error || SchemaError)!*Grammar {
    return from_json_schema_with_options(
        gpa,
        schema,
        any_whitespace,
        indent,
        separators,
        strict_mode,
        max_whitespace_cnt,
        false,
        any_order,
        diag,
    );
}

/// Constructs a BNF grammar from a JSON schema string with full formatting options
/// (`Grammar::from_json_schema_with_options`).
pub fn from_json_schema_with_options(
    gpa: Allocator,
    schema: []const u8,
    any_whitespace: bool,
    indent: ?i32,
    separators: ?Separators,
    strict_mode: bool,
    max_whitespace_cnt: ?i32,
    print_converted_ebnf: bool,
    any_order: bool,
    diag: ?*SchemaErrorInfo,
) (Allocator.Error || SchemaError)!*Grammar {
    const grammar = try json_schema_to_grammar(
        gpa,
        schema,
        any_whitespace,
        indent,
        separators,
        strict_mode,
        max_whitespace_cnt,
        any_order,
        .Json,
        &.{},
        diag,
    );
    defer grammar.deinit();
    const normalized = grammar_normalizer_mapped(gpa, grammar) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidSchema => |msg| return msg,
    };
    errdefer normalized.deinit();
    if (print_converted_ebnf) {
        const text = try grammar_mod.printer.to_string_ebnf(normalized, gpa);
        defer gpa.free(text);
        std.debug.print("Converted EBNF: {s}\n", .{text});
    }
    return normalized;
}

/// The conversion state shared by every JSON-schema converter: the grammar builder,
/// formatting options, the rule caches, and the `$ref` resolver.
pub const JsonSchemaConverter = struct {
    /// Diagnostics and long-lived storage (Rust: owned values).
    gpa: Allocator,
    arena_state: ArenaAllocator,
    arena: Allocator,
    builder: GrammarBuilder,
    /// Set when the builder was moved out by `into_grammar` (Rust `mem::take`).
    builder_taken: bool = false,
    indent_manager: IndentManager,
    colon_expr_id: i32,
    any_whitespace: bool,
    max_whitespace_cnt: ?i32,
    /// Object properties may appear in any order (applies to nested objects too).
    any_order: bool,
    /// Substrings forbidden in unconstrained strings and property names.
    excludes: []const []const u8,
    /// Generated rules keyed by schema cache key and encoding context.
    rule_cache: std.HashMap(CacheKey, i32, CacheKeyContext, 80),
    /// `$ref` rules keyed by the converter's reference cache key, for recursive references.
    uri_to_rule_id: std.StringHashMap(i32),
    parser: *SchemaParser,
    empty_expr_id: ?i32 = null,
    unsatisfiable_expr_id: ?i32 = null,
    whitespace_expr_id: ?i32 = null,
    byte_string_expr_ids: std.StringHashMap(i32),
    rule_ref_expr_ids: std.AutoHashMap(i32, i32),

    pub const CacheKey = struct {
        key: []const u8,
        context: i32,
    };

    /// Auto-hash rejects slices; a content-hash context gives (key, context) semantics.
    pub const CacheKeyContext = struct {
        pub fn hash(_: CacheKeyContext, k: CacheKey) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(k.key);
            h.update(std.mem.asBytes(&k.context));
            return h.final();
        }
        pub fn eql(_: CacheKeyContext, a: CacheKey, b: CacheKey) bool {
            return a.context == b.context and std.mem.eql(u8, a.key, b.key);
        }
    };

    /// Rust `SchemaConverter::base`/`base_mut`.
    pub fn base(self: *JsonSchemaConverter) *JsonSchemaConverter {
        return self;
    }

    /// Creates the converter state. Takes ownership of `parser` (its `deinit` is called
    /// from [`deinit`]).
    pub fn new(
        gpa: Allocator,
        parser: *SchemaParser,
        indent: ?i32,
        separators: ?Separators,
        any_whitespace: bool,
        max_whitespace_cnt: ?i32,
        any_order: bool,
        excludes: []const []const u8,
    ) SchemaError!*JsonSchemaConverter {
        const item_separator: []const u8 = if (separators) |s|
            s.item
        else if (any_whitespace or indent != null)
            ","
        else
            ", ";
        const colon_separator: []const u8 = if (separators) |s|
            s.colon
        else if (any_whitespace)
            ":"
        else
            ": ";
        const self = try gpa.create(JsonSchemaConverter);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .arena_state = ArenaAllocator.init(gpa),
            .arena = undefined,
            .builder = undefined,
            .indent_manager = undefined,
            .colon_expr_id = -1,
            .any_whitespace = any_whitespace,
            .max_whitespace_cnt = max_whitespace_cnt,
            .any_order = any_order,
            .excludes = &.{},
            .rule_cache = undefined,
            .uri_to_rule_id = undefined,
            .parser = parser,
            .byte_string_expr_ids = undefined,
            .rule_ref_expr_ids = undefined,
        };
        self.arena = self.arena_state.allocator();
        errdefer self.arena_state.deinit();
        const arena = self.arena;
        self.builder = GrammarBuilder.new(gpa) catch return error.OutOfMemory;
        errdefer self.builder.deinit();
        self.indent_manager = IndentManager.init(arena, indent, item_separator, any_whitespace, max_whitespace_cnt) catch return error.OutOfMemory;
        self.rule_cache = std.HashMap(CacheKey, i32, CacheKeyContext, 80).init(arena);
        self.uri_to_rule_id = std.StringHashMap(i32).init(arena);
        self.byte_string_expr_ids = std.StringHashMap(i32).init(arena);
        self.rule_ref_expr_ids = std.AutoHashMap(i32, i32).init(arena);
        const excludes_copy = arena.alloc([]const u8, excludes.len) catch return error.OutOfMemory;
        for (excludes, 0..) |e, i| excludes_copy[i] = arena.dupe(u8, e) catch return error.OutOfMemory;
        self.excludes = excludes_copy;

        var colon: []u8 = undefined;
        if (any_whitespace) {
            const whitespace = try self.whitespace_pattern();
            colon = std.fmt.allocPrint(arena, "{s} \"{s}\" {s}", .{ whitespace, colon_separator, whitespace }) catch return error.OutOfMemory;
        } else {
            colon = std.fmt.allocPrint(arena, "\"{s}\"", .{colon_separator}) catch return error.OutOfMemory;
        }
        const colon_diag: ?*SchemaErrorInfo = null;
        self.colon_expr_id = self.formatting_expression(colon, colon_diag) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return e,
        };
        return self;
    }

    pub fn deinit(self: *JsonSchemaConverter) void {
        if (!self.builder_taken) {
            self.builder.deinit();
        }
        self.indent_manager.deinit();
        self.parser.deinit();
        self.arena_state.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// Resolves a `$ref` URI to its parsed schema.
    pub fn resolve_ref(
        self: *JsonSchemaConverter,
        uri: []const u8,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!SchemaSpecPtr {
        return self.parser.resolve_ref(uri, diag);
    }

    /// Fills the bodies of the helper rules `basic_escape` and `basic_string_sub`.
    pub fn add_helper_rules(self: *JsonSchemaConverter, diag: ?*SchemaErrorInfo) SchemaError!void {
        if (self.max_whitespace_cnt != null) {
            // Keep the historical helper-rule numbering after grammar optimization.
            const empty_expr = try self.empty();
            _ = try self.builder.add_rule_with_hint(BASIC_STRING_SUB, empty_expr);
        }
        const escaped_chars = try ascii_class(self.arena, "\"\\/bfnrt");
        const escaped_character = try self.builder.add_character_class(escaped_chars, false);
        const hexadecimal_character = try self.builder.add_character_class(&.{
            CharacterClassElement.new(0x41, 0x46),
            CharacterClassElement.new(0x61, 0x66),
            CharacterClassElement.new(0x30, 0x39),
        }, false);
        const u = try self.byte_string("u");
        const unicode_escape = try self.sequence(&.{
            u,
            hexadecimal_character,
            hexadecimal_character,
            hexadecimal_character,
            hexadecimal_character,
        });
        const escape_body = try self.choice(&.{ escaped_character, unicode_escape });
        try self.builder.update_rule_body_by_name(BASIC_ESCAPE, escape_body);

        const normal_character = try self.builder.add_character_class(&JSON_STRING_SPECIAL_CHARACTERS, true);
        const string_sub_ref = try self.rule_ref_by_name(BASIC_STRING_SUB);
        const quote = try self.byte_string("\"");
        const with_normal = try self.sequence(&.{ normal_character, string_sub_ref });
        const backslash = try self.byte_string("\\");
        const escape_ref = try self.rule_ref_by_name(BASIC_ESCAPE);
        const with_escape = try self.sequence(&.{ backslash, escape_ref, string_sub_ref });
        const string_sub_body = try self.choice(&.{ quote, with_normal, with_escape });
        try self.builder.update_rule_body_by_name(BASIC_STRING_SUB, string_sub_body);
        if (self.excludes.len != 0) {
            const body = try self.excluding_string(JSON_STRING_BODY_REGEX, BASIC_STRING_SUB, true, &.{}, diag);
            try self.builder.update_rule_body_by_name(BASIC_STRING_SUB, body);
        }
        const lookahead = try self.closing_lookahead();
        try self.builder.update_lookahead_assertion_by_name(BASIC_STRING_SUB, lookahead);
    }

    /// The lookahead `[ \n\r\t]* [,}\]:]` that ends a JSON string or key.
    pub fn closing_lookahead(self: *JsonSchemaConverter) Allocator.Error!i32 {
        const whitespace = try self.whitespace_expression();
        const closing_context = try self.builder.add_character_class(&CLOSING_CONTEXT, false);
        return try self.sequence(&.{ whitespace, closing_context });
    }

    /// The empty-string expression (shared).
    pub fn empty(self: *JsonSchemaConverter) Allocator.Error!i32 {
        if (self.empty_expr_id) |id| return id;
        const id = try self.builder.add_empty_str();
        self.empty_expr_id = id;
        return id;
    }

    /// An expression matching nothing, for alternatives ruled out by the exclusions
    /// (shared).
    pub fn unsatisfiable(self: *JsonSchemaConverter) Allocator.Error!i32 {
        if (self.unsatisfiable_expr_id) |id| return id;
        const id = try self.builder.add_character_class(&ANY_CODEPOINT, true);
        self.unsatisfiable_expr_id = id;
        return id;
    }

    /// A byte-string expression (shared per value; the empty string maps to [`empty`]).
    pub fn byte_string(self: *JsonSchemaConverter, value: []const u8) Allocator.Error!i32 {
        if (self.byte_string_expr_ids.get(value)) |id| return id;
        const id = if (value.len == 0)
            try self.empty()
        else
            try self.builder.add_byte_string(value);
        const key = self.arena.dupe(u8, value) catch return error.OutOfMemory;
        self.byte_string_expr_ids.put(key, id) catch return error.OutOfMemory;
        return id;
    }

    /// A tag-dispatch expression without tags: any text that contains none of `excludes`.
    pub fn tag_dispatch(self: *JsonSchemaConverter, loop_after_dispatch: bool, excludes: []const []const u8) Allocator.Error!i32 {
        const arena = self.arena;
        const td = TagDispatch{
            .tag_rule_pairs = .empty,
            .loop_after_dispatch = loop_after_dispatch,
            .excludes = .empty,
        };
        var td_copy = td;
        for (excludes) |exclude| {
            const duped = arena.dupe(u8, exclude) catch return error.OutOfMemory;
            td_copy.excludes.append(arena, duped) catch return error.OutOfMemory;
        }
        return try self.builder.add_tag_dispatch(&td_copy);
    }

    /// A reference to the rule `rule_id` (shared per rule).
    pub fn rule_ref(self: *JsonSchemaConverter, rule_id: i32) Allocator.Error!i32 {
        if (self.rule_ref_expr_ids.get(rule_id)) |id| return id;
        const id = try self.builder.add_rule_ref(rule_id);
        self.rule_ref_expr_ids.put(rule_id, id) catch return error.OutOfMemory;
        return id;
    }

    /// A reference to one of the converter's own rules, by name.
    pub fn rule_ref_by_name(self: *JsonSchemaConverter, rule_name: []const u8) Allocator.Error!i32 {
        const rule_id = try self.builder.get_rule_id(rule_name);
        std.debug.assert(rule_id >= 0);
        return try self.rule_ref(rule_id);
    }

    /// A sequence; a single element is returned as is and no element is the empty string.
    pub fn sequence(self: *JsonSchemaConverter, elements: []const i32) Allocator.Error!i32 {
        if (elements.len == 0) return try self.empty();
        if (elements.len == 1) return elements[0];
        return try self.builder.add_sequence(elements);
    }

    /// An alternation; a single choice is returned as is and no choice is the empty
    /// string.
    pub fn choice(self: *JsonSchemaConverter, choices: []const i32) Allocator.Error!i32 {
        if (choices.len == 0) return try self.empty();
        if (choices.len == 1) return choices[0];
        return try self.builder.add_choices(choices);
    }

    /// `expr_id` repeated `[min_count, max_count]` times (`-1` is unbounded).
    pub fn repeat(self: *JsonSchemaConverter, rule_name_hint: []const u8, expr_id: i32, min_count: i32, max_count: i32) Allocator.Error!i32 {
        if (min_count == 0 and max_count == 0) return try self.empty();
        if (min_count == 1 and max_count == 1) return expr_id;
        if (min_count == 0 and max_count == 1) {
            const empty_expr = try self.empty();
            return try self.choice(&.{ empty_expr, expr_id });
        }
        if (min_count == 0 and max_count == -1) {
            const expr = self.builder.grammar_expr(expr_id);
            if (expr.ty == .CharacterClass) {
                return try self.builder.add_grammar_expr(.CharacterClassStar, expr.data);
            }
        }
        return try self.builder.add_repeat_from_expr(rule_name_hint, expr_id, min_count, max_count);
    }

    /// Copies `grammar` into the builder and returns a reference to its root rule.
    pub fn add_sub_grammar(self: *JsonSchemaConverter, grammar: *const Grammar) Allocator.Error!i32 {
        const rule_id = try functor_mod.add_sub_grammar(&self.builder, grammar);
        return try self.rule_ref(rule_id);
    }

    /// The EBNF spelling of one whitespace run.
    pub fn whitespace_pattern(self: *JsonSchemaConverter) Allocator.Error![]u8 {
        return IndentManager.whitespace_pattern(self.arena, self.max_whitespace_cnt);
    }

    /// One whitespace run. Unbounded runs share one expression; bounded runs stay
    /// distinct rules.
    pub fn whitespace_expression(self: *JsonSchemaConverter) Allocator.Error!i32 {
        const max_whitespace_cnt = self.max_whitespace_cnt orelse {
            if (self.whitespace_expr_id) |id| return id;
            const id = try self.builder.add_character_class_star(&WHITESPACE_CHARACTERS, false);
            self.whitespace_expr_id = id;
            return id;
        };
        const whitespace = try self.builder.add_character_class(&WHITESPACE_CHARACTERS, false);
        return try self.repeat("whitespace", whitespace, 0, max_whitespace_cnt);
    }

    /// Converts a separator fragment from [`IndentManager`] (a whitespace run, a JSON
    /// string literal, or a literal padded by whitespace runs) into an expression.
    pub fn formatting_expression(
        self: *JsonSchemaConverter,
        expression: []const u8,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        const arena = self.arena;
        const whitespace = try self.whitespace_pattern();
        if (std.mem.eql(u8, expression, whitespace)) {
            return try self.whitespace_expression();
        }
        const prefix = try std.fmt.allocPrint(arena, "{s} ", .{whitespace});
        const suffix = try std.fmt.allocPrint(arena, " {s}", .{whitespace});
        if (expression.len >= prefix.len + suffix.len and
            std.mem.startsWith(u8, expression, prefix) and
            std.mem.endsWith(u8, expression, suffix))
        {
            const leading = try self.whitespace_expression();
            const inner = try self.formatting_expression(expression[prefix.len .. expression.len - suffix.len], diag);
            const trailing = try self.whitespace_expression();
            return try self.sequence(&.{ leading, inner, trailing });
        }
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, expression, .{}) catch
            return failFmt(error.InvalidSchema, diag, self.gpa, "Unsupported indentation expression: {s}", .{expression});
        if (parsed != .string) {
            return failFmt(error.InvalidSchema, diag, self.gpa, "Unsupported indentation expression: {s}", .{expression});
        }
        return try self.byte_string(parsed.string);
    }

    /// The grammar expression matching `regex`. Prefers a `Regex` node compiled into one
    /// automaton; `json_string` excludes the characters that must be escaped in a JSON
    /// string from every character match. Falls back to the CFG expansion when forced,
    /// when the automaton engine cannot build the pattern, or when the exclusion leaves
    /// the language empty.
    pub fn regex_expression(
        self: *JsonSchemaConverter,
        regex: []const u8,
        json_string: bool,
        force_cfg_expansion: bool,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        const gpa = self.gpa;
        const can_use_fsm =
            !force_cfg_expansion and (!json_string or all_printable_ascii(regex));
        if (can_use_fsm and regex_language_is_nonempty(gpa, regex, json_string)) {
            return try self.builder.add_regex(regex, json_string);
        }
        var regex_diag: RegexErrorInfo = undefined;
        const ebnf = regex_converter_mod.regex_to_ebnf(gpa, regex, true, &regex_diag) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Regex => {
                defer gpa.free(regex_diag.message);
                const msg = regex_error_mod.format_message(&regex_diag, gpa) catch return error.OutOfMemory;
                defer gpa.free(msg);
                return fail(error.InvalidSchema, diag, gpa, msg);
            },
        };
        defer gpa.free(ebnf);
        var ebnf_diag: parser_mod.EbnfErrorInfo = undefined;
        const grammar = functor_mod.grammar_normalizer_mod.from_ebnf(gpa, ebnf, "root", &ebnf_diag) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                const msg = parser_mod.ebnf_error.message_of(ebnf_diag, gpa) catch return error.OutOfMemory;
                defer gpa.free(msg);
                return fail(error.InvalidSchema, diag, gpa, msg);
            },
        };
        defer grammar.deinit();
        return try self.add_sub_grammar(grammar);
    }

    /// Logs that a string's length constraints are dropped because exclusions are set.
    pub fn warn_dropped_length_constraints(spec: *const StringSpec, rule_name: []const u8) void {
        std.debug.print(
            "Ignoring the length constraints of string {s} (minLength={d}, maxLength={d}): they are not applied together with JSONSchemaFormat.excludes\n",
            .{ rule_name, spec.min_length, spec.max_length },
        );
    }

    /// Whether `text` contains none of the exclusions.
    pub fn is_allowed_string(self: *const JsonSchemaConverter, text: []const u8) bool {
        for (self.excludes) |excluded| {
            if (std.mem.indexOf(u8, text, excluded) != null) return false;
        }
        return true;
    }

    /// Whether the serialized JSON literal contains none of the exclusions. Strings are
    /// checked as their escaped JSON content, or as the raw text when `raw_string` is
    /// set; arrays and objects are checked element-wise and key-wise.
    pub fn is_allowed_json_literal(self: *const JsonSchemaConverter, json_value: []const u8, raw_string: bool) bool {
        return self.excludes.len == 0 or self.is_allowed_literal(parse_literal(self.arena, json_value), raw_string);
    }

    fn is_allowed_literal(self: *const JsonSchemaConverter, value: Value, raw_string: bool) bool {
        switch (value) {
            .string => |text| {
                if (raw_string) return self.is_allowed_string(text);
                const content = json_string_content(self.arena, text) catch return false;
                return self.is_allowed_string(content);
            },
            .array => |items| {
                for (items.items) |item| {
                    if (!self.is_allowed_literal(item, false)) return false;
                }
                return true;
            },
            .object => |members| {
                for (members.keys(), members.values()) |key, item| {
                    const content = json_string_content(self.arena, key) catch return false;
                    if (!self.is_allowed_string(content)) return false;
                    if (!self.is_allowed_literal(item, false)) return false;
                }
                return true;
            },
            else => return true,
        }
    }

    /// The fixed spelling of a JSON object key, or an unsatisfiable expression when the
    /// key contains an exclusion.
    pub fn json_property_key(self: *JsonSchemaConverter, key: []const u8) Allocator.Error!i32 {
        const content = json_string_content(self.arena, key) catch return error.OutOfMemory;
        if (!self.is_allowed_string(content)) {
            return try self.unsatisfiable();
        }
        const encoded = schema_parser_mod.serialize_json(self.arena, Value{ .string = key }) catch return error.OutOfMemory;
        return try self.byte_string(encoded);
    }

    /// A JSON object member: `key`, the colon separator, and the value rule.
    pub fn json_member(self: *JsonSchemaConverter, key: i32, value_rule_id: i32) Allocator.Error!i32 {
        const colon = self.colon_expr_id;
        const value = try self.rule_ref(value_rule_id);
        return try self.sequence(&.{ key, colon, value });
    }

    /// `pattern` repeated so that the total count stays within
    /// `[min_properties, max_properties]` after `already_repeated_times` occurrences.
    pub fn property_with_number_constraints(
        self: *JsonSchemaConverter,
        pattern: i32,
        min_properties: i32,
        max_properties: i32,
        already_repeated_times: i32,
        rule_name: []const u8,
    ) Allocator.Error!i32 {
        if (max_properties != -1 and max_properties == already_repeated_times) {
            return try self.empty();
        }
        const lower = @max(min_properties - already_repeated_times, 0);
        const upper = if (max_properties == -1) -1 else @max(max_properties - already_repeated_times, -1);
        const hint = std.fmt.allocPrint(self.arena, "{s}_properties", .{rule_name}) catch return error.OutOfMemory;
        return try self.repeat(hint, pattern, lower, upper);
    }

    /// A JSON key (from its opening quote) that is none of `names`. Only the literal
    /// unescaped spelling of each name is excluded.
    pub fn key_excluding_names(
        self: *JsonSchemaConverter,
        names: []const []const u8,
        rule_name: []const u8,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        const arena = self.arena;
        const quote = try self.byte_string("\"");
        if (self.excludes.len != 0) {
            const keys = try arena.alloc([]const u8, names.len);
            for (names, 0..) |name, i| keys[i] = try json_string_content(arena, name);
            const hint = try std.fmt.allocPrint(arena, "{s}_addl_key", .{rule_name});
            const body = try self.excluding_string(JSON_STRING_BODY_REGEX, hint, true, keys, diag);
            return try self.sequence(&.{ quote, body });
        }
        const trie = try KeyTrie.build(arena, names);
        const hint = try std.fmt.allocPrint(arena, "{s}_addl_key", .{rule_name});
        const key_rule_id = try self.builder.add_empty_rule_with_hint(hint);
        const trie_body = try self.key_trie_body(&trie);
        const body = try self.sequence(&.{ quote, trie_body });
        self.builder.update_rule_body(key_rule_id, body);
        const lookahead = try self.closing_lookahead();
        self.builder.update_lookahead_assertion(key_rule_id, lookahead);
        return try self.rule_ref(key_rule_id);
    }

    fn key_trie_body(self: *JsonSchemaConverter, node: *const KeyTrie) Allocator.Error!i32 {
        var choices: std.ArrayList(i32) = .empty;
        const arena = self.arena;
        if (!node.is_terminal) {
            try choices.append(arena, try self.byte_string("\""));
        }
        var excluded: std.ArrayList(CharacterClassElement) = .empty;
        for (JSON_STRING_SPECIAL_CHARACTERS) |e| try excluded.append(arena, e);
        for (0..256) |byte| {
            if (node.children[byte] != null) {
                try excluded.append(arena, CharacterClassElement.new(@intCast(byte), @intCast(byte)));
            }
        }
        const other_character = try self.builder.add_character_class(excluded.items, true);
        const string_sub = try self.rule_ref_by_name(BASIC_STRING_SUB);
        try choices.append(arena, try self.sequence(&.{ other_character, string_sub }));
        const backslash = try self.byte_string("\\");
        const escape = try self.rule_ref_by_name(BASIC_ESCAPE);
        try choices.append(arena, try self.sequence(&.{ backslash, escape, string_sub }));
        for (0..256) |byte| {
            if (node.children[byte]) |child| {
                const byte_bytes = [_]u8{@intCast(byte)};
                const character = try self.byte_string(&byte_bytes);
                const rest = try self.key_trie_body(child);
                try choices.append(arena, try self.sequence(&.{ character, rest }));
            }
        }
        return try self.choice(choices.items);
    }

    /// Rules matching `regex` (one of the converter's own ASCII string bodies) minus every
    /// string containing an exclusion, and minus `excluded_keys` as whole strings. With
    /// `close_json_string` the closing quote follows the filtered body, so it is never
    /// part of an exclusion.
    pub fn excluding_string(
        self: *JsonSchemaConverter,
        regex: []const u8,
        rule_name: []const u8,
        close_json_string: bool,
        excluded_keys: []const []const u8,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        const gpa = self.gpa;
        const arena = self.arena;
        // The Rust messages wrap the underlying fsm error's Display text; the fsm wave
        // port drops message text, so the inner text is generic here.
        const fsm_error = failFmt(error.InvalidSchema, diag, gpa, "Cannot apply JSONSchemaFormat.excludes: automaton operation failed", .{});
        var parsed = functor_mod.GrammarFsmBuilder.regex(gpa, regex, false, null) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return fsm_error,
        };
        defer parsed.deinit();
        const td = TagDispatch{
            .tag_rule_pairs = .empty,
            .loop_after_dispatch = false,
            .excludes = .empty,
        };
        var td_copy = td;
        for (self.excludes) |excluded| {
            td_copy.excludes.append(arena, try arena.dupe(u8, excluded)) catch return error.OutOfMemory;
        }
        var exclusion = functor_mod.GrammarFsmBuilder.tag_dispatch(gpa, &td_copy) catch return error.OutOfMemory;
        if (exclusion == null) {
            return fail(error.InvalidSchema, diag, gpa, "Invalid JSONSchemaFormat.excludes");
        }
        defer exclusion.?.deinit();
        var fsm = FsmWithStartEnd.intersect(gpa, &parsed, &exclusion.?) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return fsm_error,
        };
        var fsm_owned = true;
        errdefer if (fsm_owned) fsm.deinit();
        if (excluded_keys.len != 0) {
            const keys = try gpa.alloc([]const u8, excluded_keys.len);
            defer gpa.free(keys);
            for (excluded_keys, 0..) |k, i| keys[i] = k;
            var end_states: std.ArrayList(i32) = .empty;
            defer end_states.deinit(gpa);
            var other_keys_opt = TrieFsmBuilder.build(gpa, keys, &.{}, null, true, false) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (other_keys_opt == null) {
                const msg = try std.fmt.allocPrint(gpa, "Cannot apply JSONSchemaFormat.excludes: cannot build the key trie", .{});
                defer gpa.free(msg);
                return fail(error.InvalidSchema, diag, gpa, msg);
            }
            defer other_keys_opt.?.deinit();
            var not_keys = other_keys_opt.?.not(gpa) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return fsm_error,
            };
            defer not_keys.deinit();
            const intersected = FsmWithStartEnd.intersect(gpa, &fsm, &not_keys) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return fsm_error,
            };
            fsm.deinit();
            fsm = intersected;
        }
        // Do not emit paths that can never complete after exclusions: a matcher could
        // accept a forbidden alternative's prefix and reach an all-rejected mask later.
        var collapser = Utf8RangeCollapser.init(gpa, &fsm) catch return error.OutOfMemory;
        defer collapser.deinit();
        if (!collapser.is_productive(fsm.get_start())) {
            fsm.deinit();
            fsm_owned = false;
            return try self.unsatisfiable();
        }

        const num_states: usize = @intCast(fsm.num_states());
        var rules = try gpa.alloc(i32, num_states);
        defer gpa.free(rules);
        @memset(rules, -1);
        var pending: std.ArrayList(i32) = .empty;
        defer pending.deinit(gpa);
        try pending.append(gpa, fsm.get_start());
        // Share complete fallback branches across key prefixes to reuse their token
        // masks. The key is the target state followed by every codepoint interval.
        var shared_key_continuations = std.StringHashMap(i32).init(arena);
        rules[@intCast(fsm.get_start())] = try self.builder.add_empty_rule_with_hint(
            try std.fmt.allocPrint(arena, "{s}_exclude", .{rule_name}),
        );
        var index: usize = 0;
        while (index < pending.items.len) : (index += 1) {
            const state = pending.items[index];
            var transitions: std.ArrayList(Transition) = .empty;
            defer {
                for (transitions.items) |*t| t.codepoints.deinit(gpa);
                transitions.deinit(gpa);
            }
            var ranges = collapser.state_ranges(state) catch return error.OutOfMemory;
            defer ranges.deinit(gpa);
            for (ranges.items) |r| {
                // group by target (sorted ranges already cluster targets)
                if (transitions.items.len > 0 and transitions.items[transitions.items.len - 1].target == r[0]) {
                    try transitions.items[transitions.items.len - 1].codepoints.append(gpa, CharacterClassElement.new(r[1], r[2]));
                } else {
                    var codepoints: std.ArrayList(CharacterClassElement) = .empty;
                    try codepoints.append(gpa, CharacterClassElement.new(r[1], r[2]));
                    try transitions.append(gpa, .{ .target = r[0], .codepoints = codepoints });
                }
            }
            var choices: std.ArrayList(i32) = .empty;
            defer choices.deinit(gpa);
            // Keep the closing quote on the accepting body states: a nullable body rule
            // would finish at every character. The quote is JSON syntax, not filtered
            // string content.
            if (fsm.is_end_state(state)) {
                try choices.append(gpa, if (close_json_string)
                    try self.byte_string("\"")
                else
                    try self.empty());
            }
            for (transitions.items) |*transition| {
                const target = transition.target;
                if (rules[@intCast(target)] == -1) {
                    rules[@intCast(target)] = try self.builder.add_empty_rule_with_hint(
                        try std.fmt.allocPrint(arena, "{s}_exclude", .{rule_name}),
                    );
                    try pending.append(gpa, target);
                }
                const codepoints = transition.codepoints.items;
                const single_ascii = codepoints.len == 1 and
                    codepoints[0].lower == codepoints[0].upper and codepoints[0].upper <= 0x7f;
                // Keep self-loops local for the compiler's speculative string-mask fast
                // path.
                if (excluded_keys.len != 0 and !single_ascii and target != state) {
                    var key: std.ArrayList(u8) = .empty;
                    defer key.deinit(gpa);
                    var target_bytes: [4]u8 = undefined;
                    std.mem.writeInt(i32, &target_bytes, target, .little);
                    try key.appendSlice(gpa, &target_bytes);
                    for (codepoints) |range| {
                        var lo_bytes: [4]u8 = undefined;
                        var hi_bytes: [4]u8 = undefined;
                        std.mem.writeInt(i32, &lo_bytes, range.lower, .little);
                        std.mem.writeInt(i32, &hi_bytes, range.upper, .little);
                        try key.appendSlice(gpa, &lo_bytes);
                        try key.appendSlice(gpa, &hi_bytes);
                    }
                    const continuation: i32 = blk: {
                        if (shared_key_continuations.get(key.items)) |existing| {
                            break :blk existing;
                        }
                        const class = try self.builder.add_character_class(codepoints, false);
                        const next = try self.rule_ref(rules[@intCast(target)]);
                        const body = try self.sequence(&.{ class, next });
                        const cont_hint = try std.fmt.allocPrint(arena, "{s}_exclude_continuation", .{rule_name});
                        const rule_id = try self.builder.add_rule_with_hint(cont_hint, body);
                        const stored = try gpa.dupe(u8, key.items);
                        try shared_key_continuations.put(stored, rule_id);
                        break :blk rule_id;
                    };
                    try choices.append(gpa, try self.rule_ref(continuation));
                } else {
                    const class = try self.builder.add_character_class(codepoints, false);
                    const next = try self.rule_ref(rules[@intCast(target)]);
                    try choices.append(gpa, try self.sequence(&.{ class, next }));
                }
            }
            if (choices.items.len == 0) {
                try choices.append(gpa, try self.unsatisfiable());
            }
            const body = try self.choice(choices.items);
            self.builder.update_rule_body(rules[@intCast(state)], body);
        }
        fsm.deinit();
        return try self.rule_ref(rules[@intCast(fsm.get_start())]);
    }

    const Transition = struct {
        target: i32,
        codepoints: std.ArrayList(CharacterClassElement),
    };

    /// `integer`: a range, a `multipleOf` constraint, or any JSON integer.
    pub fn generate_integer(
        self: *JsonSchemaConverter,
        spec: *const IntegerSpec,
        rule_name: []const u8,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        const arena = self.arena;
        const effective = spec.effective_range();
        if (spec.multiple_of) |multiple_of| {
            // The parser keeps multipleOf only for fully bounded ranges (enumerated here)
            // and fully unbounded ones (a modulo automaton).
            if (effective.start != null and effective.end != null) {
                var multiples: std.ArrayList(i32) = .empty;
                var value = effective.start.?;
                while (value <= effective.end.?) : (value += 1) {
                    if (@rem(value, multiple_of) == 0) {
                        const text = try std.fmt.allocPrint(arena, "{d}", .{value});
                        try multiples.append(arena, try self.byte_string(text));
                    }
                }
                return try self.choice(multiples.items);
            }
            return try self.integer_multiple_of(multiple_of, rule_name);
        }
        if (effective.start != null or effective.end != null) {
            const regex = try range_regex_mod.generate_range_regex(arena, effective.start, effective.end);
            return self.regex_expression(regex, false, true, diag);
        }
        const empty_expr = try self.empty();
        const minus = try self.byte_string("-");
        const optional_minus = try self.choice(&.{ empty_expr, minus });
        const zero = try self.byte_string("0");
        const leading_digit = try self.builder.add_character_class(&.{CharacterClassElement.new(0x31, 0x39)}, false);
        const digits = try self.builder.add_character_class_star(&.{CharacterClassElement.new(0x30, 0x39)}, false);
        const nonzero = try self.sequence(&.{ optional_minus, leading_digit, digits });
        return try self.choice(&.{ zero, nonzero });
    }

    /// The decimal integers divisible by `multiple_of`, as an automaton over the
    /// remainder.
    fn integer_multiple_of(self: *JsonSchemaConverter, multiple_of: i64, rule_name: []const u8) Allocator.Error!i32 {
        const arena = self.arena;
        var states: std.ArrayList(i32) = .empty;
        for (0..@intCast(multiple_of)) |state| {
            const hint = std.fmt.allocPrint(arena, "{s}_multiple_of_{d}_mod_{d}", .{ rule_name, multiple_of, state }) catch return error.OutOfMemory;
            states.append(arena, try self.builder.add_empty_rule_with_hint(hint)) catch return error.OutOfMemory;
        }
        for (0..@intCast(multiple_of)) |state| {
            var transitions: std.ArrayList(i32) = .empty;
            if (state == 0) {
                transitions.append(arena, try self.empty()) catch return error.OutOfMemory;
            }
            for (0..10) |digit| {
                const next_state = states.items[@intCast(@rem(@as(i64, @intCast(state)) * 10 + @as(i64, @intCast(digit)), multiple_of))];
                const digit_text = std.fmt.allocPrint(arena, "{d}", .{digit}) catch return error.OutOfMemory;
                const digit_expr = try self.byte_string(digit_text);
                const next_ref = try self.rule_ref(next_state);
                transitions.append(arena, try self.sequence(&.{ digit_expr, next_ref })) catch return error.OutOfMemory;
            }
            const body = try self.choice(transitions.items);
            self.builder.update_rule_body(states.items[state], body);
        }
        var non_zero_starts: std.ArrayList(i32) = .empty;
        for (1..10) |digit| {
            const next_state = states.items[@intCast(@rem(@as(i64, @intCast(digit)), multiple_of))];
            const digit_text = std.fmt.allocPrint(arena, "{d}", .{digit}) catch return error.OutOfMemory;
            const digit_expr = try self.byte_string(digit_text);
            const next_ref = try self.rule_ref(next_state);
            non_zero_starts.append(arena, try self.sequence(&.{ digit_expr, next_ref })) catch return error.OutOfMemory;
        }
        const zero = try self.byte_string("0");
        const empty_expr = try self.empty();
        const minus = try self.byte_string("-");
        const optional_minus = try self.choice(&.{ empty_expr, minus });
        const non_zero = try self.choice(non_zero_starts.items);
        const signed = try self.sequence(&.{ optional_minus, non_zero });
        return try self.choice(&.{ zero, signed });
    }

    /// `number`: a range or any JSON number.
    pub fn generate_number(
        self: *JsonSchemaConverter,
        spec: *const NumberSpec,
        rule_name: []const u8,
        diag: ?*SchemaErrorInfo,
    ) SchemaError!i32 {
        const arena = self.arena;
        var start = spec.minimum;
        var end = spec.maximum;
        var exclusive_start = false;
        var exclusive_end = false;
        // The larger lower bound wins; on a tie the exclusive one is stricter.
        if (spec.exclusive_minimum) |exclusive| {
            if (start == null or exclusive >= start.?) {
                start = exclusive;
                exclusive_start = true;
            }
        }
        if (spec.exclusive_maximum) |exclusive| {
            if (end == null or exclusive <= end.?) {
                end = exclusive;
                exclusive_end = true;
            }
        }
        if (start != null or end != null) {
            const regex = try range_regex_mod.generate_float_range_regex_with_options(arena, start, end, exclusive_start, exclusive_end);
            return self.regex_expression(regex, false, true, diag);
        }
        const empty_expr = try self.empty();
        const minus = try self.byte_string("-");
        const optional_minus = try self.choice(&.{ empty_expr, minus });
        const zero = try self.byte_string("0");
        const leading_digit = try self.builder.add_character_class(&.{CharacterClassElement.new(0x31, 0x39)}, false);
        const digits = try self.builder.add_character_class_star(&.{CharacterClassElement.new(0x30, 0x39)}, false);
        const nonzero = try self.sequence(&.{ leading_digit, digits });
        const integer_part = try self.choice(&.{ zero, nonzero });
        const digit = try self.builder.add_character_class(&.{CharacterClassElement.new(0x30, 0x39)}, false);
        const digits_hint = try std.fmt.allocPrint(arena, "{s}_digits", .{rule_name});
        const one_or_more_digits = try self.repeat(digits_hint, digit, 1, -1);
        const dot = try self.byte_string(".");
        const fraction_digits = try self.sequence(&.{ dot, one_or_more_digits });
        const fraction = try self.choice(&.{ empty_expr, fraction_digits });
        const exponent_mark = try self.builder.add_character_class(try ascii_class(arena, "eE"), false);
        const sign = try self.builder.add_character_class(try ascii_class(arena, "+-"), false);
        const optional_sign = try self.choice(&.{ empty_expr, sign });
        const exponent_digits = try self.sequence(&.{ exponent_mark, optional_sign, one_or_more_digits });
        const exponent = try self.choice(&.{ empty_expr, exponent_digits });
        // "-"? ("0" | ...) admits -0; ("0" | "-"? ...) would not.
        return try self.sequence(&.{ optional_minus, integer_part, fraction, exponent });
    }

    /// `boolean`.
    pub fn generate_boolean(self: *JsonSchemaConverter) Allocator.Error!i32 {
        const true_literal = try self.byte_string("true");
        const false_literal = try self.byte_string("false");
        return try self.choice(&.{ true_literal, false_literal });
    }

    /// `null`.
    pub fn generate_null(self: *JsonSchemaConverter) Allocator.Error!i32 {
        return try self.byte_string("null");
    }

    /// Any codepoint repeated `[min_length, max_length]` times, the body of a raw string
    /// with a length bound.
    pub fn raw_characters(self: *JsonSchemaConverter, spec: *const StringSpec, rule_name: []const u8) Allocator.Error!i32 {
        const character = try self.builder.add_character_class(&ANY_CODEPOINT, false);
        const hint = std.fmt.allocPrint(self.arena, "{s}_characters", .{rule_name}) catch return error.OutOfMemory;
        return try self.repeat(hint, character, spec.min_length, spec.max_length);
    }
};

/// Maps `grammar_normalizer`'s FunctorError surface onto `SchemaError`: OOM passes
/// through; the remaining normalization failures cannot occur for converter-generated
/// grammars (Rust propagates its own error enum) and surface as `InvalidSchema`.
fn grammar_normalizer_mapped(gpa: Allocator, grammar: *Grammar) (Allocator.Error || error{InvalidSchema})!*Grammar {
    return functor_mod.grammar_normalizer(gpa, grammar) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => return error.InvalidSchema,
    };
}

fn all_printable_ascii(regex: []const u8) bool {
    for (regex) |byte| {
        if (byte < 0x20 or byte > 0x7e) return false;
    }
    return true;
}

/// The JSON-schema `format` → regex table. A recognized format is compiled to its regex,
/// which takes precedence over `minLength`/`maxLength`.
pub fn json_format_to_regex_pattern(arena: Allocator, format: []const u8) Allocator.Error!?[]u8 {
    const atext = "[\\w!#$%&'*+/=?^`{|}~-]";
    const dot_string = try std.fmt.allocPrint(arena, "({s}+(\\.{s}+)*)", .{ atext, atext });
    const quoted_string = "\\\\\"(\\\\[\\x20-\\x7E]|[\\x20\\x21\\x23-\\x5B\\x5D-\\x7E])*\\\\\"";
    const domain = "([A-Za-z0-9]([\\-A-Za-z0-9]*[A-Za-z0-9])?)((\\.[A-Za-z0-9][\\-A-Za-z0-9]*[A-Za-z0-9])*)";

    if (std.mem.eql(u8, format, "email")) {
        return try std.fmt.allocPrint(arena, "^({s}|{s})@{s}$", .{ dot_string, quoted_string, domain });
    } else if (std.mem.eql(u8, format, "date")) {
        return try arena.dupe(u8, "^(\\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[1-2]\\d|3[01]))$");
    } else if (std.mem.eql(u8, format, "time")) {
        return try arena.dupe(u8, "^([01]\\d|2[0-3]):[0-5]\\d:([0-5]\\d|60)(\\.\\d+)?(Z|[+-]([01]\\d|2[0-3]):[0-5]\\d)$");
    } else if (std.mem.eql(u8, format, "date-time")) {
        return try arena.dupe(u8, "^(\\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[1-2]\\d|3[01]))T([01]\\d|2[0-3]):[0-5]\\d:([0-5]\\d|60)(\\.\\d+)?(Z|[+-]([01]\\d|2[0-3]):[0-5]\\d)$");
    } else if (std.mem.eql(u8, format, "duration")) {
        return try arena.dupe(u8, "^P((\\d+D|\\d+M(\\d+D)?|\\d+Y(\\d+M(\\d+D)?)?)(T(\\d+S|\\d+M(\\d+S)?|\\d+H(\\d+M(\\d+S)?)?))?|T(\\d+S|\\d+M(\\d+S)?|\\d+H(\\d+M(\\d+S)?)?)|\\d+W)$");
    } else if (std.mem.eql(u8, format, "ipv4")) {
        const decbyte = "(25[0-5]|2[0-4]\\d|[0-1]?\\d?\\d)";
        return try std.fmt.allocPrint(arena, "^({s}\\.){{3}}{s}$", .{ decbyte, decbyte });
    } else if (std.mem.eql(u8, format, "ipv6")) {
        return try arena.dupe(u8, "(([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9]))");
    } else if (std.mem.eql(u8, format, "hostname")) {
        return try arena.dupe(u8, "^([a-z0-9]([a-z0-9-]*[a-z0-9])?)(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$");
    } else if (std.mem.eql(u8, format, "uuid")) {
        return try arena.dupe(u8, "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$");
    } else if (std.mem.eql(u8, format, "uri")) {
        const schema_pat = "[a-zA-Z][a-zA-Z+\\.-]*";
        const pchar = "([\\w\\.~!$&'()*+,;=:@-]|%[0-9A-Fa-f][0-9A-Fa-f])";
        const query_fragment_char = "([\\w\\.~!$&'()*+,;=:@/\\?-]|%[0-9A-Fa-f][0-9A-Fa-f])*";
        const query = try std.fmt.allocPrint(arena, "(\\?{s})?", .{query_fragment_char});
        const fragment = try std.fmt.allocPrint(arena, "(#{s})?", .{query_fragment_char});
        const path_abempty = try std.fmt.allocPrint(arena, "({s}*)*", .{pchar});
        const path_absolute_rootless_empty = try std.fmt.allocPrint(arena, "/?({s}+({s}*)*)?", .{ pchar, path_abempty });
        const userinfo = "([\\w\\.~!$&'()*+,;=:-]|%[0-9A-Fa-f][0-9A-Fa-f])*";
        const host = "([\\w\\.~!$&'()*+,;=-]|%[0-9A-Fa-f][0-9A-Fa-f])*";
        const authority = try std.fmt.allocPrint(arena, "({s}@)?{s}(:\\d*)?", .{ userinfo, host });
        const hier_part = try std.fmt.allocPrint(arena, "(//{s}{s}|{s})", .{ authority, path_abempty, path_absolute_rootless_empty });
        return try std.fmt.allocPrint(arena, "^{s}:{s}{s}{s}$", .{ schema_pat, hier_part, query, fragment });
    } else if (std.mem.eql(u8, format, "uri-reference")) {
        const pchar = "([\\w\\.~!$&'()*+,;=:@-]|%[0-9A-Fa-f][0-9A-Fa-f])";
        const query_fragment_char = "([\\w\\.~!$&'()*+,;=:@/\\?-]|%[0-9A-Fa-f][0-9A-Fa-f])*";
        const query = try std.fmt.allocPrint(arena, "(\\?{s})?", .{query_fragment_char});
        const fragment = try std.fmt.allocPrint(arena, "(#{s})?", .{query_fragment_char});
        const path_abempty = try std.fmt.allocPrint(arena, "({s}*)*", .{pchar});
        const path_absolute = try std.fmt.allocPrint(arena, "/({s}+({s}*)*)?", .{ pchar, path_abempty });
        const segment_nz_nc = "([\\w\\.~!$&'()*+,;=@-]|%[0-9A-Fa-f][0-9A-Fa-f])+";
        const path_noscheme = try std.fmt.allocPrint(arena, "{s}({s}*)*", .{ segment_nz_nc, pchar });
        const userinfo = "([\\w\\.~!$&'()*+,;=:-]|%[0-9A-Fa-f][0-9A-Fa-f])*";
        const host = "([\\w\\.~!$&'()*+,;=-]|%[0-9A-Fa-f][0-9A-Fa-f])*";
        const authority = try std.fmt.allocPrint(arena, "({s}@)?{s}(:\\d*)?", .{ userinfo, host });
        const relative_part = try std.fmt.allocPrint(arena, "(//{s}{s}|{s}|{s})?", .{ authority, path_abempty, path_absolute, path_noscheme });
        return try std.fmt.allocPrint(arena, "^{s}{s}{s}$", .{ relative_part, query, fragment });
    } else if (std.mem.eql(u8, format, "uri-template")) {
        const literals = "([\\x21\\x23-\\x24\\x26\\x28-\\x3B\\x3D\\x3F-\\x5B\\x5D\\x5F\\x61-\\x7A\\x7E]|%[0-9A-Fa-f][0-9A-Fa-f])";
        const op = "[+#\\./;\\?&=,!@|]";
        const varchar = "(\\w|%[0-9A-Fa-f][0-9A-Fa-f])";
        const varname = try std.fmt.allocPrint(arena, "{s}(\\.?{s})*", .{ varchar, varchar });
        const varspec = try std.fmt.allocPrint(arena, "{s}(:[1-9]\\d?\\d?\\d?|\\*)?", .{varname});
        const variable_list = try std.fmt.allocPrint(arena, "{s}({s})*", .{ varspec, varspec });
        const expression = try std.fmt.allocPrint(arena, "\\{{({s})?{s}\\}}", .{ op, variable_list });
        return try std.fmt.allocPrint(arena, "^({s}|{s})*$", .{ literals, expression });
    } else if (std.mem.eql(u8, format, "json-pointer")) {
        return try arena.dupe(u8, "^(/([\\x00-\\x2E]|[\\x30-\\x7D]|[\\x7F-\\U0010FFFF]|~[01])*)*$");
    } else if (std.mem.eql(u8, format, "relative-json-pointer")) {
        return try arena.dupe(u8, "^(0|[1-9][0-9]*)(#|(/([\\x00-\\x2E]|[\\x30-\\x7D]|[\\x7F-\\U0010FFFF]|~[01])*)*)$");
    }
    return null;
}

/// Parses a JSON literal serialized from a schema (`const`/`enum` values).
pub fn parse_literal(arena: Allocator, json_value: []const u8) Value {
    // Rust `.expect`: schema literals are serialized by the converter itself.
    return std.json.parseFromSliceLeaky(Value, arena, json_value, .{}) catch unreachable;
}

/// The escaped content of `text` as a JSON string literal, without the surrounding
/// quotes.
pub fn json_string_content(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    const encoded = try schema_parser_mod.serialize_json(arena, Value{ .string = text });
    return encoded[1 .. encoded.len - 1];
}

/// Single-character ranges for each byte of `characters`.
pub fn ascii_class(arena: Allocator, characters: []const u8) Allocator.Error![]CharacterClassElement {
    const out = try arena.alloc(CharacterClassElement, characters.len);
    for (characters, 0..) |byte, i| {
        out[i] = CharacterClassElement.new(byte, byte);
    }
    return out;
}

/// Whether the automaton of `regex` (excluding the JSON-string forbidden characters with
/// `json_string`) accepts any string.
fn regex_language_is_nonempty(gpa: Allocator, regex: []const u8, json_string: bool) bool {
    var fsm = functor_mod.GrammarFsmBuilder.regex(gpa, regex, json_string, null) catch return false;
    defer fsm.deinit();
    var states = fsm.reachable_states() catch return false;
    defer states.deinit();
    var it = states.keyIterator();
    while (it.next()) |state| {
        if (fsm.is_end_state(state.*)) return true;
    }
    return false;
}

test {
    _ = schema_converter_mod;
    _ = json_format_mod;
    _ = key_trie_mod;
    _ = range_regex_mod;
    _ = utf8_range_collapser_mod;
    _ = schema_parser_mod;
    _ = schema_error_mod;
    _ = regex_error_mod;
    _ = indent_manager_mod;
    _ = grammar_mod;
    _ = functor_mod;
    _ = fsm_mod;
    _ = support;
}
