//! Converts a JSON Schema into a BNF `Grammar` or EBNF string
//! (`json_schema_converter.rs`).
//!
//! `JsonSchemaConverter` owns the conversion state and grammar-building primitives.
//! The generation algorithm lives in `generator.zig`, whose hooks the XML tool-calling
//! converters (`xml.zig`, `xml_cohere.zig`, `xml_minimax.zig`) override.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Diagnostic = @import("../../Diagnostic.zig").Diagnostic;
const fsm_mod = @import("../../fsm.zig");
const FsmWithStartEnd = fsm_mod.FsmWithStartEnd;
const TrieFsmBuilder = fsm_mod.TrieFsmBuilder;
const functor_mod = @import("../../functor.zig");
const grammar_mod = @import("../../grammar.zig");
const CharacterClassElement = grammar_mod.CharacterClassElement;
const Grammar = grammar_mod.Grammar;
const GrammarBuilder = grammar_mod.GrammarBuilder;
const TagDispatch = grammar_mod.TagDispatch;
const support = @import("../../support.zig");
const range_regex = @import("../range_regex.zig");
const regex_mod = @import("../regex.zig");
const Utf8RangeCollapser = @import("../utf8_range_collapser.zig").Utf8RangeCollapser;
const generator = @import("generator.zig");
const parser_mod = @import("parser.zig");
const SchemaParser = parser_mod.SchemaParser;
const Value = parser_mod.Value;
const spec_mod = @import("spec.zig");
const IndentManager = spec_mod.IndentManager;
const KeyTrie = spec_mod.KeyTrie;
const NumberSpec = spec_mod.NumberSpec;
const IntegerSpec = spec_mod.IntegerSpec;
const SchemaSpecPtr = spec_mod.SchemaSpecPtr;
const StringSpec = spec_mod.StringSpec;
const xml_mod = @import("xml.zig");
const XmlToolCallingConverter = xml_mod.XmlToolCallingConverter;
const xml_cohere = @import("xml_cohere.zig");
const CohereXmlToolCallingConverter = xml_cohere.CohereXmlToolCallingConverter;
const xml_minimax = @import("xml_minimax.zig");
const MiniMaxM3XmlToolCallingConverter = xml_minimax.MiniMaxM3XmlToolCallingConverter;

pub const JsonFormat = spec_mod.JsonFormat;
pub const SchemaError = parser_mod.SchemaError;
pub const jsonFormatToRegexPattern = parser_mod.jsonFormatToRegexPattern;

const log = std.log.scoped(.xgrammar);

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
    CharacterClassElement.init(' ', ' '),
    CharacterClassElement.init('\n', '\n'),
    CharacterClassElement.init('\r', '\r'),
    CharacterClassElement.init('\t', '\t'),
};

/// Characters that may follow the end of a JSON string or key.
const CLOSING_CONTEXT = [_]CharacterClassElement{
    CharacterClassElement.init(',', ','),
    CharacterClassElement.init('}', '}'),
    CharacterClassElement.init(']', ']'),
    CharacterClassElement.init(':', ':'),
};

/// Characters that cannot appear unescaped in a JSON string.
const JSON_STRING_SPECIAL_CHARACTERS = [_]CharacterClassElement{
    CharacterClassElement.init(0, 0x1f),
    CharacterClassElement.init('"', '"'),
    CharacterClassElement.init('\\', '\\'),
    CharacterClassElement.init('\r', '\r'),
    CharacterClassElement.init('\n', '\n'),
};

const ANY_CODEPOINT = [_]CharacterClassElement{
    CharacterClassElement.init(0, 0x10FFFF),
};

/// The two separators used in the schema: comma and colon.
pub const Separators = struct {
    item: []const u8,
    colon: []const u8,
};

/// Configuration options for JSON Schema conversion.
pub const JsonSchemaOptions = struct {
    any_whitespace: bool = true,
    indent: ?i32 = null,
    separators: ?Separators = null,
    strict_mode: bool = true,
    max_whitespace_cnt: ?i32 = null,
    any_order: bool = false,
    json_format: JsonFormat = .json,
    excludes: []const []const u8 = &.{},
    print_converted_ebnf: bool = false,
    diag: ?*Diagnostic = null,
};

/// Converts a JSON Schema string to its normalized EBNF grammar text.
pub fn jsonSchemaToEbnf(
    gpa: Allocator,
    schema: []const u8,
    options: JsonSchemaOptions,
) (Allocator.Error || SchemaError)![]u8 {
    var grammar = try jsonSchemaToGrammar(gpa, schema, options);
    defer grammar.deinit();
    var normalized = try normalizeGrammarMapped(gpa, &grammar, options.diag);
    defer normalized.deinit();
    return grammar_mod.toStringEbnf(&normalized, gpa);
}

/// Converts a JSON Schema string to an unnormalized `Grammar` AST.
pub fn jsonSchemaToGrammar(
    gpa: Allocator,
    schema: []const u8,
    options: JsonSchemaOptions,
) (Allocator.Error || SchemaError)!Grammar {
    var arena_state = ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = support.parseJson(arena, schema) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return parser_mod.failFmt(
            error.InvalidSchema,
            options.diag,
            gpa,
            "Failed to parse JSON: {s}",
            .{@errorName(e)},
        ),
    };
    if (options.max_whitespace_cnt != null and options.max_whitespace_cnt.? <= 0) {
        return parser_mod.failStatic(error.InvalidSchema, options.diag, "max_whitespace_cnt must be positive.");
    }
    const parser = try SchemaParser.init(gpa, root, options.strict_mode);
    const spec = parser.parse(root, null, options.diag) catch |err| {
        parser.deinit();
        return err;
    };
    if (options.excludes.len != 0 and (options.json_format == .minimax_m3_xml or options.json_format == .cohere_xml)) {
        parser.deinit();
        const name: []const u8 = if (options.json_format == .cohere_xml) "cohere_xml" else "minimax_m3_xml";
        return parser_mod.failFmt(
            error.InvalidSchema,
            options.diag,
            gpa,
            "JSONSchemaFormat.excludes is not supported for {s}",
            .{name},
        );
    }
    const base_conv = JsonSchemaConverter.init(
        gpa,
        parser,
        options.indent,
        options.separators,
        options.any_whitespace,
        options.max_whitespace_cnt,
        options.any_order,
        options.excludes,
    ) catch |err| {
        parser.deinit();
        return err;
    };
    defer base_conv.deinit();
    switch (options.json_format) {
        .json => return generator.intoGrammar(base_conv, spec, options.diag),
        .minimax_m3_xml => {
            var conv = MiniMaxM3XmlToolCallingConverter.init(base_conv);
            return generator.intoGrammar(&conv, spec, options.diag);
        },
        .cohere_xml => {
            var conv = try CohereXmlToolCallingConverter.init(base_conv, options.diag);
            return generator.intoGrammar(&conv, spec, options.diag);
        },
        else => {
            var conv = try XmlToolCallingConverter.init(base_conv, options.json_format, options.diag);
            return generator.intoGrammar(&conv, spec, options.diag);
        },
    }
}

/// Constructs a normalized BNF `Grammar` from a JSON Schema string.
pub fn fromJsonSchema(
    gpa: Allocator,
    schema: []const u8,
    options: JsonSchemaOptions,
) (Allocator.Error || SchemaError)!Grammar {
    var grammar = try jsonSchemaToGrammar(gpa, schema, options);
    defer grammar.deinit();
    var normalized = try normalizeGrammarMapped(gpa, &grammar, options.diag);
    errdefer normalized.deinit();
    if (options.print_converted_ebnf) {
        const text = try grammar_mod.toStringEbnf(&normalized, gpa);
        defer gpa.free(text);
        log.info("Converted EBNF: {s}", .{text});
    }
    return normalized;
}

/// The conversion state shared by every JSON-schema converter: the grammar builder,
/// formatting options, the rule caches, and the `$ref` resolver.
pub const JsonSchemaConverter = struct {
    gpa: Allocator,
    arena_state: ArenaAllocator,
    arena: Allocator,
    builder: GrammarBuilder,
    indent_manager: IndentManager,
    colon_expr_id: i32,
    any_whitespace: bool,
    max_whitespace_cnt: ?i32,
    any_order: bool,
    excludes: []const []const u8,
    rule_cache: std.HashMapUnmanaged(CacheKey, i32, CacheKeyContext, 80),
    uri_to_rule_id: std.StringHashMapUnmanaged(i32),
    parser: *SchemaParser,
    empty_expr_id: ?i32 = null,
    unsatisfiable_expr_id: ?i32 = null,
    whitespace_expr_id: ?i32 = null,
    byte_string_expr_ids: std.StringHashMapUnmanaged(i32),
    rule_ref_expr_ids: std.AutoHashMapUnmanaged(i32, i32),

    pub const CacheKey = struct {
        key: []const u8,
        context: i32,
    };

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

    pub fn base(self: *JsonSchemaConverter) *JsonSchemaConverter {
        return self;
    }

    /// Creates the converter state. Takes ownership of `parser` (released by `deinit`).
    pub fn init(
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
            .rule_cache = .empty,
            .uri_to_rule_id = .empty,
            .parser = parser,
            .byte_string_expr_ids = .empty,
            .rule_ref_expr_ids = .empty,
        };
        self.arena = self.arena_state.allocator();
        errdefer self.arena_state.deinit();
        const arena = self.arena;
        self.builder = try GrammarBuilder.init(gpa);
        errdefer self.builder.deinit();
        self.indent_manager = try IndentManager.init(arena, indent, item_separator, any_whitespace, max_whitespace_cnt);
        errdefer self.indent_manager.deinit();
        const excludes_copy = try arena.alloc([]const u8, excludes.len);
        for (excludes, 0..) |e, i| excludes_copy[i] = try arena.dupe(u8, e);
        self.excludes = excludes_copy;

        const colon = if (any_whitespace) blk: {
            const whitespace = try self.whitespacePattern();
            break :blk try std.fmt.allocPrint(arena, "{s} \"{s}\" {s}", .{ whitespace, colon_separator, whitespace });
        } else try std.fmt.allocPrint(arena, "\"{s}\"", .{colon_separator});
        self.colon_expr_id = try self.formattingExpression(colon, null);
        return self;
    }

    pub fn deinit(self: *JsonSchemaConverter) void {
        self.builder.deinit();
        self.indent_manager.deinit();
        self.parser.deinit();
        self.arena_state.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// Resolves a `$ref` URI to its parsed schema.
    pub fn resolveRef(
        self: *JsonSchemaConverter,
        uri: []const u8,
        diag: ?*Diagnostic,
    ) SchemaError!SchemaSpecPtr {
        return self.parser.resolveRef(uri, diag);
    }

    /// Fills the bodies of the helper rules `basic_escape` and `basic_string_sub`.
    pub fn addHelperRules(self: *JsonSchemaConverter, diag: ?*Diagnostic) SchemaError!void {
        if (self.max_whitespace_cnt != null) {
            const empty_expr = try self.empty();
            _ = try self.builder.addRuleWithHint(BASIC_STRING_SUB, empty_expr);
        }
        const escaped_chars = try asciiClass(self.arena, "\"\\/bfnrt");
        const escaped_character = try self.builder.addCharacterClass(escaped_chars, false);
        const hexadecimal_character = try self.builder.addCharacterClass(&.{
            CharacterClassElement.init(0x41, 0x46),
            CharacterClassElement.init(0x61, 0x66),
            CharacterClassElement.init(0x30, 0x39),
        }, false);
        const u = try self.byteString("u");
        const unicode_escape = try self.sequence(&.{
            u,
            hexadecimal_character,
            hexadecimal_character,
            hexadecimal_character,
            hexadecimal_character,
        });
        const escape_body = try self.choice(&.{ escaped_character, unicode_escape });
        try self.builder.updateRuleBodyByName(BASIC_ESCAPE, escape_body);

        const normal_character = try self.builder.addCharacterClass(&JSON_STRING_SPECIAL_CHARACTERS, true);
        const string_sub_ref = try self.ruleRefByName(BASIC_STRING_SUB);
        const quote = try self.byteString("\"");
        const with_normal = try self.sequence(&.{ normal_character, string_sub_ref });
        const backslash = try self.byteString("\\");
        const escape_ref = try self.ruleRefByName(BASIC_ESCAPE);
        const with_escape = try self.sequence(&.{ backslash, escape_ref, string_sub_ref });
        const string_sub_body = try self.choice(&.{ quote, with_normal, with_escape });
        try self.builder.updateRuleBodyByName(BASIC_STRING_SUB, string_sub_body);
        if (self.excludes.len != 0) {
            const body = try self.excludingString(JSON_STRING_BODY_REGEX, BASIC_STRING_SUB, true, &.{}, diag);
            try self.builder.updateRuleBodyByName(BASIC_STRING_SUB, body);
        }
        const lookahead = try self.closingLookahead();
        try self.builder.updateLookaheadAssertionByName(BASIC_STRING_SUB, lookahead);
    }

    /// The lookahead `[ \n\r\t]* [,}\]:]` that ends a JSON string or key.
    pub fn closingLookahead(self: *JsonSchemaConverter) Allocator.Error!i32 {
        const whitespace = try self.whitespaceExpression();
        const closing_context = try self.builder.addCharacterClass(&CLOSING_CONTEXT, false);
        return try self.sequence(&.{ whitespace, closing_context });
    }

    /// The empty-string expression (shared).
    pub fn empty(self: *JsonSchemaConverter) Allocator.Error!i32 {
        if (self.empty_expr_id) |id| return id;
        const id = try self.builder.addEmptyStr();
        self.empty_expr_id = id;
        return id;
    }

    /// An expression matching nothing, for alternatives ruled out by exclusions (shared).
    pub fn unsatisfiable(self: *JsonSchemaConverter) Allocator.Error!i32 {
        if (self.unsatisfiable_expr_id) |id| return id;
        const id = try self.builder.addCharacterClass(&ANY_CODEPOINT, true);
        self.unsatisfiable_expr_id = id;
        return id;
    }

    /// A byte-string expression (shared per value; empty string maps to `empty()`).
    pub fn byteString(self: *JsonSchemaConverter, value: []const u8) Allocator.Error!i32 {
        if (self.byte_string_expr_ids.get(value)) |id| return id;
        const id = if (value.len == 0)
            try self.empty()
        else
            try self.builder.addByteString(value);
        const key = try self.arena.dupe(u8, value);
        try self.byte_string_expr_ids.put(self.arena, key, id);
        return id;
    }

    /// A tag-dispatch expression without tags: any text containing none of `excludes`.
    pub fn tagDispatch(self: *JsonSchemaConverter, loop_after_dispatch: bool, excludes: []const []const u8) Allocator.Error!i32 {
        var td: TagDispatch = .{
            .loop_after_dispatch = loop_after_dispatch,
        };
        defer td.deinit(self.gpa);
        try td.excludes.ensureTotalCapacity(self.gpa, excludes.len);
        for (excludes) |exclude| {
            td.excludes.appendAssumeCapacity(try self.gpa.dupe(u8, exclude));
        }
        return try self.builder.addTagDispatch(&td);
    }

    /// A reference to the rule `rule_id` (shared per rule).
    pub fn ruleRef(self: *JsonSchemaConverter, rule_id: i32) Allocator.Error!i32 {
        if (self.rule_ref_expr_ids.get(rule_id)) |id| return id;
        const id = try self.builder.addRuleRef(rule_id);
        try self.rule_ref_expr_ids.put(self.arena, rule_id, id);
        return id;
    }

    /// A reference to one of the converter's own rules, by name.
    pub fn ruleRefByName(self: *JsonSchemaConverter, rule_name: []const u8) Allocator.Error!i32 {
        const rule_id = try self.builder.getRuleId(rule_name);
        std.debug.assert(rule_id >= 0);
        return try self.ruleRef(rule_id);
    }

    /// A sequence; a single element is returned as is.
    pub fn sequence(self: *JsonSchemaConverter, elements: []const i32) Allocator.Error!i32 {
        if (elements.len == 0) return try self.empty();
        if (elements.len == 1) return elements[0];
        return try self.builder.addSequence(elements);
    }

    /// An alternation; a single choice is returned as is.
    pub fn choice(self: *JsonSchemaConverter, choices: []const i32) Allocator.Error!i32 {
        if (choices.len == 0) return try self.empty();
        if (choices.len == 1) return choices[0];
        return try self.builder.addChoices(choices);
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
            const expr = self.builder.grammarExpr(expr_id);
            if (expr.ty == .CharacterClass) {
                return try self.builder.addGrammarExpr(.CharacterClassStar, expr.data);
            }
        }
        return try self.builder.addRepeatFromExpr(rule_name_hint, expr_id, min_count, max_count);
    }

    /// Copies `grammar` into the builder and returns a reference to its root rule.
    pub fn addSubGrammar(self: *JsonSchemaConverter, grammar: *const Grammar) Allocator.Error!i32 {
        const rule_id = try functor_mod.addSubGrammar(&self.builder, grammar);
        return try self.ruleRef(rule_id);
    }

    /// The EBNF spelling of one whitespace run.
    pub fn whitespacePattern(self: *JsonSchemaConverter) Allocator.Error![]u8 {
        return IndentManager.whitespacePattern(self.arena, self.max_whitespace_cnt);
    }

    /// One whitespace run. Unbounded runs share one expression; bounded runs stay distinct.
    pub fn whitespaceExpression(self: *JsonSchemaConverter) Allocator.Error!i32 {
        const max_whitespace_cnt = self.max_whitespace_cnt orelse {
            if (self.whitespace_expr_id) |id| return id;
            const id = try self.builder.addCharacterClassStar(&WHITESPACE_CHARACTERS, false);
            self.whitespace_expr_id = id;
            return id;
        };
        const whitespace = try self.builder.addCharacterClass(&WHITESPACE_CHARACTERS, false);
        return try self.repeat("whitespace", whitespace, 0, max_whitespace_cnt);
    }

    /// Converts a separator fragment from `IndentManager` into a grammar expression.
    pub fn formattingExpression(
        self: *JsonSchemaConverter,
        expression: []const u8,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        const arena = self.arena;
        const whitespace = try self.whitespacePattern();
        if (std.mem.eql(u8, expression, whitespace)) {
            return try self.whitespaceExpression();
        }
        const prefix = try std.fmt.allocPrint(arena, "{s} ", .{whitespace});
        const suffix = try std.fmt.allocPrint(arena, " {s}", .{whitespace});
        if (expression.len >= prefix.len + suffix.len and
            std.mem.startsWith(u8, expression, prefix) and
            std.mem.endsWith(u8, expression, suffix))
        {
            const leading = try self.whitespaceExpression();
            const inner = try self.formattingExpression(expression[prefix.len .. expression.len - suffix.len], diag);
            const trailing = try self.whitespaceExpression();
            return try self.sequence(&.{ leading, inner, trailing });
        }
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, expression, .{}) catch
            return parser_mod.failFmt(error.InvalidSchema, diag, self.gpa, "Unsupported indentation expression: {s}", .{expression});
        if (parsed != .string) {
            return parser_mod.failFmt(error.InvalidSchema, diag, self.gpa, "Unsupported indentation expression: {s}", .{expression});
        }
        return try self.byteString(parsed.string);
    }

    /// The grammar expression matching `regex`. Prefers a `Regex` node compiled into one
    /// automaton, falling back to CFG expansion when forced, unsupported by the automaton
    /// engine, or empty under JSON string exclusions.
    pub fn regexExpression(
        self: *JsonSchemaConverter,
        regex: []const u8,
        json_string: bool,
        force_cfg_expansion: bool,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        const gpa = self.gpa;
        const can_use_fsm =
            !force_cfg_expansion and (!json_string or allPrintableAscii(regex));
        if (can_use_fsm and regexLanguageIsNonempty(gpa, regex, json_string)) {
            return try self.builder.addRegex(regex, json_string);
        }

        var regex_diag: Diagnostic = .{};
        defer regex_diag.deinit(gpa);
        const ebnf = regex_mod.regexToEbnf(gpa, regex, true, if (diag != null) &regex_diag else null) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Regex => {
                if (diag) |d| {
                    try d.setFmt(gpa, .message, "{f}", .{regex_diag});
                }
                return error.InvalidSchema;
            },
        };
        defer gpa.free(ebnf);

        var ebnf_diag: Diagnostic = .{};
        defer ebnf_diag.deinit(gpa);
        var grammar = functor_mod.fromEbnf(gpa, ebnf, "root", if (diag != null) &ebnf_diag else null) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                if (diag) |d| {
                    try d.setFmt(gpa, .message, "{f}", .{ebnf_diag});
                }
                return error.InvalidSchema;
            },
        };
        defer grammar.deinit();
        return try self.addSubGrammar(&grammar);
    }

    /// Logs that a string's length constraints are dropped because exclusions are set.
    pub fn warnDroppedLengthConstraints(spec: *const StringSpec, rule_name: []const u8) void {
        log.warn(
            "Ignoring the length constraints of string {s} (minLength={d}, maxLength={d}): they are not applied together with JSONSchemaFormat.excludes",
            .{ rule_name, spec.min_length, spec.max_length },
        );
    }

    pub fn isAllowedString(self: *const JsonSchemaConverter, text: []const u8) bool {
        for (self.excludes) |excluded| {
            if (std.mem.indexOf(u8, text, excluded) != null) return false;
        }
        return true;
    }

    pub fn isAllowedJsonLiteral(self: *const JsonSchemaConverter, json_value: []const u8, raw_string: bool) bool {
        return self.excludes.len == 0 or self.isAllowedLiteral(parseLiteral(self.arena, json_value), raw_string);
    }

    fn isAllowedLiteral(self: *const JsonSchemaConverter, value: Value, raw_string: bool) bool {
        switch (value) {
            .string => |text| {
                if (raw_string) return self.isAllowedString(text);
                const content = jsonStringContent(self.arena, text) catch return false;
                return self.isAllowedString(content);
            },
            .array => |items| {
                for (items.items) |item| {
                    if (!self.isAllowedLiteral(item, false)) return false;
                }
                return true;
            },
            .object => |members| {
                for (members.keys(), members.values()) |key, item| {
                    const content = jsonStringContent(self.arena, key) catch return false;
                    if (!self.isAllowedString(content)) return false;
                    if (!self.isAllowedLiteral(item, false)) return false;
                }
                return true;
            },
            else => return true,
        }
    }

    pub fn jsonPropertyKey(self: *JsonSchemaConverter, key: []const u8) Allocator.Error!i32 {
        const content = try jsonStringContent(self.arena, key);
        if (!self.isAllowedString(content)) {
            return try self.unsatisfiable();
        }
        const encoded = try parser_mod.serializeJson(self.arena, Value{ .string = key });
        return try self.byteString(encoded);
    }

    pub fn jsonMember(self: *JsonSchemaConverter, key: i32, value_rule_id: i32) Allocator.Error!i32 {
        const colon = self.colon_expr_id;
        const value = try self.ruleRef(value_rule_id);
        return try self.sequence(&.{ key, colon, value });
    }

    pub fn propertyWithNumberConstraints(
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
        const hint = try std.fmt.allocPrint(self.arena, "{s}_properties", .{rule_name});
        return try self.repeat(hint, pattern, lower, upper);
    }

    /// A JSON key (from its opening quote) that is none of `names`.
    pub fn keyExcludingNames(
        self: *JsonSchemaConverter,
        names: []const []const u8,
        rule_name: []const u8,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        const arena = self.arena;
        const quote = try self.byteString("\"");
        if (self.excludes.len != 0) {
            const keys = try arena.alloc([]const u8, names.len);
            for (names, 0..) |name, i| keys[i] = try jsonStringContent(arena, name);
            const hint = try std.fmt.allocPrint(arena, "{s}_addl_key", .{rule_name});
            const body = try self.excludingString(JSON_STRING_BODY_REGEX, hint, true, keys, diag);
            return try self.sequence(&.{ quote, body });
        }
        var trie = try KeyTrie.build(self.gpa, names);
        defer trie.deinit(self.gpa);
        const hint = try std.fmt.allocPrint(arena, "{s}_addl_key", .{rule_name});
        const key_rule_id = try self.builder.addEmptyRuleWithHint(hint);
        const trie_body = try self.keyTrieBody(&trie, trie.rootIndex());
        const body = try self.sequence(&.{ quote, trie_body });
        self.builder.updateRuleBody(key_rule_id, body);
        const lookahead = try self.closingLookahead();
        self.builder.updateLookaheadAssertion(key_rule_id, lookahead);
        return try self.ruleRef(key_rule_id);
    }

    fn keyTrieBody(self: *JsonSchemaConverter, trie: *const KeyTrie, node_idx: u32) Allocator.Error!i32 {
        const node = trie.node(node_idx);
        var choices: std.ArrayList(i32) = .empty;
        const arena = self.arena;
        if (!node.is_terminal) {
            try choices.append(arena, try self.byteString("\""));
        }
        var excluded: std.ArrayList(CharacterClassElement) = .empty;
        for (JSON_STRING_SPECIAL_CHARACTERS) |e| try excluded.append(arena, e);
        for (node.edges.items) |edge| {
            try excluded.append(arena, CharacterClassElement.init(@intCast(edge.byte), @intCast(edge.byte)));
        }
        const other_character = try self.builder.addCharacterClass(excluded.items, true);
        const string_sub = try self.ruleRefByName(BASIC_STRING_SUB);
        try choices.append(arena, try self.sequence(&.{ other_character, string_sub }));
        const backslash = try self.byteString("\\");
        const escape = try self.ruleRefByName(BASIC_ESCAPE);
        try choices.append(arena, try self.sequence(&.{ backslash, escape, string_sub }));
        for (node.edges.items) |edge| {
            const byte_bytes = [_]u8{edge.byte};
            const character = try self.byteString(&byte_bytes);
            const rest = try self.keyTrieBody(trie, edge.child);
            try choices.append(arena, try self.sequence(&.{ character, rest }));
        }
        return try self.choice(choices.items);
    }

    fn failExcludesFsm(diag: ?*Diagnostic) SchemaError {
        return parser_mod.failStatic(
            error.InvalidSchema,
            diag,
            "Cannot apply JSONSchemaFormat.excludes: automaton operation failed",
        );
    }

    /// Rules matching `regex` minus every string containing an exclusion, and minus
    /// `excluded_keys` as whole strings.
    pub fn excludingString(
        self: *JsonSchemaConverter,
        regex: []const u8,
        rule_name: []const u8,
        close_json_string: bool,
        excluded_keys: []const []const u8,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        const gpa = self.gpa;
        const arena = self.arena;
        var parsed = functor_mod.GrammarFsmBuilder.regex(gpa, regex, false, null) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return failExcludesFsm(diag),
        };
        defer parsed.deinit();

        var td: TagDispatch = .{};
        defer td.deinit(gpa);
        try td.excludes.ensureTotalCapacity(gpa, self.excludes.len);
        for (self.excludes) |excluded| {
            td.excludes.appendAssumeCapacity(try gpa.dupe(u8, excluded));
        }
        var exclusion = (try functor_mod.GrammarFsmBuilder.tagDispatch(gpa, &td)) orelse {
            return parser_mod.failStatic(error.InvalidSchema, diag, "Invalid JSONSchemaFormat.excludes");
        };
        defer exclusion.deinit();

        var fsm = FsmWithStartEnd.intersect(gpa, &parsed, &exclusion) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return failExcludesFsm(diag),
        };
        var fsm_owned = true;
        errdefer if (fsm_owned) fsm.deinit();

        if (excluded_keys.len != 0) {
            var other_keys = (try TrieFsmBuilder.build(gpa, excluded_keys, &.{}, null, true, false)) orelse {
                return parser_mod.failStatic(
                    error.InvalidSchema,
                    diag,
                    "Cannot apply JSONSchemaFormat.excludes: cannot build the key trie",
                );
            };
            defer other_keys.deinit();
            var not_keys = other_keys.not(gpa) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return failExcludesFsm(diag),
            };
            defer not_keys.deinit();
            const intersected = FsmWithStartEnd.intersect(gpa, &fsm, &not_keys) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return failExcludesFsm(diag),
            };
            fsm.deinit();
            fsm = intersected;
        }

        const start_state = fsm.startState();
        var collapser = try Utf8RangeCollapser.init(gpa, &fsm);
        defer collapser.deinit();
        if (!collapser.isProductive(start_state)) {
            fsm.deinit();
            fsm_owned = false;
            return try self.unsatisfiable();
        }

        const num_states: usize = @intCast(fsm.numStates());
        const rules = try gpa.alloc(i32, num_states);
        defer gpa.free(rules);
        @memset(rules, -1);
        var pending: std.ArrayList(i32) = .empty;
        defer pending.deinit(gpa);
        try pending.append(gpa, start_state);

        var shared_key_continuations: std.StringHashMapUnmanaged(i32) = .empty;
        rules[@intCast(start_state)] = try self.builder.addEmptyRuleWithHint(
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
            var ranges = try collapser.stateRanges(state);
            defer ranges.deinit(gpa);
            for (ranges.items) |r| {
                if (transitions.items.len > 0 and transitions.items[transitions.items.len - 1].target == r[0]) {
                    try transitions.items[transitions.items.len - 1].codepoints.append(gpa, CharacterClassElement.init(r[1], r[2]));
                } else {
                    var codepoints: std.ArrayList(CharacterClassElement) = .empty;
                    errdefer codepoints.deinit(gpa);
                    try codepoints.append(gpa, CharacterClassElement.init(r[1], r[2]));
                    try transitions.append(gpa, .{ .target = r[0], .codepoints = codepoints });
                }
            }
            var choices: std.ArrayList(i32) = .empty;
            defer choices.deinit(gpa);
            if (fsm.isEndState(state)) {
                try choices.append(gpa, if (close_json_string)
                    try self.byteString("\"")
                else
                    try self.empty());
            }
            for (transitions.items) |*transition| {
                const target = transition.target;
                if (rules[@intCast(target)] == -1) {
                    rules[@intCast(target)] = try self.builder.addEmptyRuleWithHint(
                        try std.fmt.allocPrint(arena, "{s}_exclude", .{rule_name}),
                    );
                    try pending.append(gpa, target);
                }
                const codepoints = transition.codepoints.items;
                const single_ascii = codepoints.len == 1 and
                    codepoints[0].lower == codepoints[0].upper and codepoints[0].upper <= 0x7f;
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
                        const class = try self.builder.addCharacterClass(codepoints, false);
                        const next = try self.ruleRef(rules[@intCast(target)]);
                        const body = try self.sequence(&.{ class, next });
                        const cont_hint = try std.fmt.allocPrint(arena, "{s}_exclude_continuation", .{rule_name});
                        const rule_id = try self.builder.addRuleWithHint(cont_hint, body);
                        const stored = try arena.dupe(u8, key.items);
                        try shared_key_continuations.put(arena, stored, rule_id);
                        break :blk rule_id;
                    };
                    try choices.append(gpa, try self.ruleRef(continuation));
                } else {
                    const class = try self.builder.addCharacterClass(codepoints, false);
                    const next = try self.ruleRef(rules[@intCast(target)]);
                    try choices.append(gpa, try self.sequence(&.{ class, next }));
                }
            }
            if (choices.items.len == 0) {
                try choices.append(gpa, try self.unsatisfiable());
            }
            const body = try self.choice(choices.items);
            self.builder.updateRuleBody(rules[@intCast(state)], body);
        }
        fsm.deinit();
        fsm_owned = false;
        return try self.ruleRef(rules[@intCast(start_state)]);
    }

    const Transition = struct {
        target: i32,
        codepoints: std.ArrayList(CharacterClassElement),
    };

    pub fn generateInteger(
        self: *JsonSchemaConverter,
        spec: *const IntegerSpec,
        rule_name: []const u8,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        const arena = self.arena;
        const effective = spec.effectiveRange();
        if (spec.multiple_of) |multiple_of| {
            if (effective.start != null and effective.end != null) {
                var multiples: std.ArrayList(i32) = .empty;
                var value = effective.start.?;
                while (value <= effective.end.?) : (value += 1) {
                    if (@rem(value, multiple_of) == 0) {
                        const text = try std.fmt.allocPrint(arena, "{d}", .{value});
                        try multiples.append(arena, try self.byteString(text));
                    }
                }
                return try self.choice(multiples.items);
            }
            return try self.integerMultipleOf(multiple_of, rule_name);
        }
        if (effective.start != null or effective.end != null) {
            const regex = try range_regex.generateRangeRegex(arena, effective.start, effective.end);
            return self.regexExpression(regex, false, true, diag);
        }
        const empty_expr = try self.empty();
        const minus = try self.byteString("-");
        const optional_minus = try self.choice(&.{ empty_expr, minus });
        const zero = try self.byteString("0");
        const leading_digit = try self.builder.addCharacterClass(&.{CharacterClassElement.init(0x31, 0x39)}, false);
        const digits = try self.builder.addCharacterClassStar(&.{CharacterClassElement.init(0x30, 0x39)}, false);
        const nonzero = try self.sequence(&.{ optional_minus, leading_digit, digits });
        return try self.choice(&.{ zero, nonzero });
    }

    fn integerMultipleOf(self: *JsonSchemaConverter, multiple_of: i64, rule_name: []const u8) Allocator.Error!i32 {
        const arena = self.arena;
        var states: std.ArrayList(i32) = .empty;
        for (0..@intCast(multiple_of)) |state| {
            const hint = try std.fmt.allocPrint(arena, "{s}_multiple_of_{d}_mod_{d}", .{ rule_name, multiple_of, state });
            try states.append(arena, try self.builder.addEmptyRuleWithHint(hint));
        }
        for (0..@intCast(multiple_of)) |state| {
            var transitions: std.ArrayList(i32) = .empty;
            if (state == 0) {
                try transitions.append(arena, try self.empty());
            }
            for (0..10) |digit| {
                const next_state = states.items[@intCast(@rem(@as(i64, @intCast(state)) * 10 + @as(i64, @intCast(digit)), multiple_of))];
                const digit_text = try std.fmt.allocPrint(arena, "{d}", .{digit});
                const digit_expr = try self.byteString(digit_text);
                const next_ref = try self.ruleRef(next_state);
                try transitions.append(arena, try self.sequence(&.{ digit_expr, next_ref }));
            }
            const body = try self.choice(transitions.items);
            self.builder.updateRuleBody(states.items[state], body);
        }
        var non_zero_starts: std.ArrayList(i32) = .empty;
        for (1..10) |digit| {
            const next_state = states.items[@intCast(@rem(@as(i64, @intCast(digit)), multiple_of))];
            const digit_text = try std.fmt.allocPrint(arena, "{d}", .{digit});
            const digit_expr = try self.byteString(digit_text);
            const next_ref = try self.ruleRef(next_state);
            try non_zero_starts.append(arena, try self.sequence(&.{ digit_expr, next_ref }));
        }
        const zero = try self.byteString("0");
        const empty_expr = try self.empty();
        const minus = try self.byteString("-");
        const optional_minus = try self.choice(&.{ empty_expr, minus });
        const non_zero = try self.choice(non_zero_starts.items);
        const signed = try self.sequence(&.{ optional_minus, non_zero });
        return try self.choice(&.{ zero, signed });
    }

    pub fn generateNumber(
        self: *JsonSchemaConverter,
        spec: *const NumberSpec,
        rule_name: []const u8,
        diag: ?*Diagnostic,
    ) SchemaError!i32 {
        const arena = self.arena;
        var start = spec.minimum;
        var end = spec.maximum;
        var exclusive_start = false;
        var exclusive_end = false;
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
            const regex = try range_regex.generateFloatRangeRegexWithOptions(arena, start, end, .{
                .exclusive_start = exclusive_start,
                .exclusive_end = exclusive_end,
            });
            return self.regexExpression(regex, false, true, diag);
        }
        const empty_expr = try self.empty();
        const minus = try self.byteString("-");
        const optional_minus = try self.choice(&.{ empty_expr, minus });
        const zero = try self.byteString("0");
        const leading_digit = try self.builder.addCharacterClass(&.{CharacterClassElement.init(0x31, 0x39)}, false);
        const digits = try self.builder.addCharacterClassStar(&.{CharacterClassElement.init(0x30, 0x39)}, false);
        const nonzero = try self.sequence(&.{ leading_digit, digits });
        const integer_part = try self.choice(&.{ zero, nonzero });
        const digit = try self.builder.addCharacterClass(&.{CharacterClassElement.init(0x30, 0x39)}, false);
        const digits_hint = try std.fmt.allocPrint(arena, "{s}_digits", .{rule_name});
        const one_or_more_digits = try self.repeat(digits_hint, digit, 1, -1);
        const dot = try self.byteString(".");
        const fraction_digits = try self.sequence(&.{ dot, one_or_more_digits });
        const fraction = try self.choice(&.{ empty_expr, fraction_digits });
        const exponent_mark = try self.builder.addCharacterClass(try asciiClass(arena, "eE"), false);
        const sign = try self.builder.addCharacterClass(try asciiClass(arena, "+-"), false);
        const optional_sign = try self.choice(&.{ empty_expr, sign });
        const exponent_digits = try self.sequence(&.{ exponent_mark, optional_sign, one_or_more_digits });
        const exponent = try self.choice(&.{ empty_expr, exponent_digits });
        return try self.sequence(&.{ optional_minus, integer_part, fraction, exponent });
    }

    pub fn generateBoolean(self: *JsonSchemaConverter) Allocator.Error!i32 {
        const true_literal = try self.byteString("true");
        const false_literal = try self.byteString("false");
        return try self.choice(&.{ true_literal, false_literal });
    }

    pub fn generateNull(self: *JsonSchemaConverter) Allocator.Error!i32 {
        return try self.byteString("null");
    }

    pub fn rawCharacters(self: *JsonSchemaConverter, spec: *const StringSpec, rule_name: []const u8) Allocator.Error!i32 {
        const character = try self.builder.addCharacterClass(&ANY_CODEPOINT, false);
        const hint = try std.fmt.allocPrint(self.arena, "{s}_characters", .{rule_name});
        return try self.repeat(hint, character, spec.min_length, spec.max_length);
    }
};

fn normalizeGrammarMapped(
    gpa: Allocator,
    grammar: *const Grammar,
    diag: ?*Diagnostic,
) (Allocator.Error || SchemaError)!Grammar {
    return functor_mod.normalize(gpa, grammar) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return parser_mod.failStatic(
            error.InvalidSchema,
            diag,
            "Failed to normalize converted JSON schema grammar",
        ),
    };
}

fn allPrintableAscii(regex: []const u8) bool {
    for (regex) |byte| {
        if (byte < 0x20 or byte > 0x7e) return false;
    }
    return true;
}

/// Parses a JSON literal serialized from a schema (`const`/`enum` values).
pub fn parseLiteral(arena: Allocator, json_value: []const u8) Value {
    return std.json.parseFromSliceLeaky(Value, arena, json_value, .{}) catch unreachable;
}

/// The escaped content of `text` as a JSON string literal, without the surrounding quotes.
pub fn jsonStringContent(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    const encoded = try parser_mod.serializeJson(arena, Value{ .string = text });
    return encoded[1 .. encoded.len - 1];
}

/// Single-character ranges for each byte of `characters`.
pub fn asciiClass(arena: Allocator, characters: []const u8) Allocator.Error![]CharacterClassElement {
    const out = try arena.alloc(CharacterClassElement, characters.len);
    for (characters, 0..) |byte, i| {
        out[i] = CharacterClassElement.init(byte, byte);
    }
    return out;
}

fn regexLanguageIsNonempty(gpa: Allocator, regex: []const u8, json_string: bool) bool {
    var fsm = functor_mod.GrammarFsmBuilder.regex(gpa, regex, json_string, null) catch return false;
    defer fsm.deinit();
    var states = fsm.reachableStates() catch return false;
    defer states.deinit();
    var it = states.keyIterator();
    while (it.next()) |state| {
        if (fsm.isEndState(state.*)) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "jsonSchemaToEbnf and fromJsonSchema across all 9 JsonFormats with zero leaks" {
    const gpa = std.testing.allocator;
    const schema =
        \\{"type":"object","properties":{"name":{"type":"string"},"count":{"type":"integer"},"tags":{"type":"array","items":{"type":"string"}}},"required":["name","count"],"additionalProperties":false}
    ;
    const formats = std.enums.values(JsonFormat);
    for (formats) |fmt| {
        const ebnf = try jsonSchemaToEbnf(gpa, schema, .{
            .any_whitespace = true,
            .strict_mode = true,
            .json_format = fmt,
        });
        defer gpa.free(ebnf);
        try std.testing.expect(ebnf.len > 0);
        switch (fmt) {
            .qwen_xml => try std.testing.expect(std.mem.indexOf(u8, ebnf, "<parameter=name") != null),
            .minimax_xml => try std.testing.expect(std.mem.indexOf(u8, ebnf, "<parameter name=\\\"name") != null),
            .deepseek_xml, .deepseek_v4_1_xml => try std.testing.expect(std.mem.indexOf(u8, ebnf, "DSML") != null),
            .glm_xml => try std.testing.expect(std.mem.indexOf(u8, ebnf, "<arg_key>") != null),
            .cohere_xml => try std.testing.expect(std.mem.indexOf(u8, ebnf, "<cofl:value") != null),
            .kimi_k3_xml => try std.testing.expect(std.mem.indexOf(u8, ebnf, "<|open|>argument") != null),
            .minimax_m3_xml => try std.testing.expect(std.mem.indexOf(u8, ebnf, "]<]minimax[>[<name>") != null),
            .json => try std.testing.expect(std.mem.indexOf(u8, ebnf, "root ::=") != null),
        }

        var g = try fromJsonSchema(gpa, schema, .{
            .json_format = fmt,
            .any_order = (fmt == .json),
        });
        defer g.deinit();
        try std.testing.expect(g.numRules() >= 1);
    }

    // Unnormalized grammar entry point.
    var raw_g = try jsonSchemaToGrammar(gpa, schema, .{ .any_whitespace = false });
    defer raw_g.deinit();
    try std.testing.expect(raw_g.numRules() >= 1);
}

test "jsonSchemaToEbnf handles excludes, KeyTrie additional keys, and shortest JSON literals with zero leaks" {
    const gpa = std.testing.allocator;

    const schema_excl =
        \\{"type":"object","properties":{"id":{"type":"integer"},"name":{"type":"string"}},"required":["id"]}
    ;
    const ebnf_excl = try jsonSchemaToEbnf(gpa, schema_excl, .{
        .strict_mode = false,
        .excludes = &.{"</tool_call>"},
    });
    defer gpa.free(ebnf_excl);
    try std.testing.expect(std.mem.indexOf(u8, ebnf_excl, "_exclude") != null);

    // Non-excluded object uses compact KeyTrie in ascending byte order.
    const ebnf_trie = try jsonSchemaToEbnf(gpa, schema_excl, .{
        .any_whitespace = false,
        .separators = .{ .item = ",", .colon = ":" },
        .strict_mode = false,
    });
    defer gpa.free(ebnf_trie);
    try std.testing.expect(std.mem.indexOf(u8, ebnf_trie, "(\"i\" root_addl_key_2) | (\"n\" root_addl_key_6)") != null);

    // Shortest JSON floats (#926).
    const schema_float =
        \\{"type":"object","properties":{"a":{"const":0.1},"b":{"enum":[0.25,0.5]}},"required":["a","b"]}
    ;
    const ebnf_float = try jsonSchemaToEbnf(gpa, schema_float, .{ .any_whitespace = false });
    defer gpa.free(ebnf_float);
    try std.testing.expect(std.mem.indexOf(u8, ebnf_float, "0.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, ebnf_float, "0.100000") == null);
    try std.testing.expect(std.mem.indexOf(u8, ebnf_float, "0.25") != null);
}

test "invalid JSON Schema inputs with diag == null and reusable diag under std.testing.allocator (0 leaks)" {
    const gpa = std.testing.allocator;

    // 1. Null diagnostic across multiple error paths.
    try std.testing.expectError(error.InvalidSchema, fromJsonSchema(gpa, "{not json", .{}));
    try std.testing.expectError(error.UnsatisfiableSchema, fromJsonSchema(gpa, "false", .{}));
    try std.testing.expectError(error.InvalidSchema, fromJsonSchema(gpa, "{}", .{ .max_whitespace_cnt = 0 }));
    try std.testing.expectError(error.InvalidSchema, fromJsonSchema(gpa, "{\"type\":\"string\",\"pattern\":\"a[]b\"}", .{}));
    try std.testing.expectError(error.InvalidSchema, fromJsonSchema(gpa, "{}", .{
        .json_format = .cohere_xml,
        .excludes = &.{"x"},
    }));
    try std.testing.expectError(error.UnsatisfiableSchema, fromJsonSchema(gpa, "{\"type\":\"integer\",\"minimum\":10,\"maximum\":5}", .{}));

    // 2. Reusable Diagnostic across every error kind (prior buffers freed cleanly).
    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);

    try std.testing.expectError(error.InvalidSchema, fromJsonSchema(gpa, "{not json", .{ .diag = &diag }));
    try std.testing.expect(std.mem.startsWith(u8, diag.message, "Failed to parse JSON: "));

    try std.testing.expectError(error.UnsatisfiableSchema, fromJsonSchema(gpa, "false", .{ .diag = &diag }));
    try std.testing.expectEqualStrings("Schema 'false' cannot accept any value", diag.message);

    try std.testing.expectError(error.InvalidSchema, fromJsonSchema(gpa, "{}", .{ .max_whitespace_cnt = -1, .diag = &diag }));
    try std.testing.expectEqualStrings("max_whitespace_cnt must be positive.", diag.message);

    try std.testing.expectError(error.InvalidSchema, fromJsonSchema(gpa, "{\"type\":\"string\",\"pattern\":\"a[]b\"}", .{ .diag = &diag }));
    try std.testing.expectEqualStrings("Regex parsing error at position 3: Empty character class is not allowed in regex.", diag.message);

    try std.testing.expectError(error.InvalidSchema, fromJsonSchema(gpa, "{}", .{
        .json_format = .minimax_m3_xml,
        .excludes = &.{"x"},
        .diag = &diag,
    }));
    try std.testing.expectEqualStrings("JSONSchemaFormat.excludes is not supported for minimax_m3_xml", diag.message);

    try std.testing.expectError(error.InvalidSchema, jsonSchemaToEbnf(gpa, "{\"type\":\"object\"}", .{
        .json_format = .minimax_m3_xml,
        .strict_mode = false,
        .diag = &diag,
    }));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "minimax_m3_xml requires fixed object property names") != null);
}
