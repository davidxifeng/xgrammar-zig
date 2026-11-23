//! Lowers a parsed Lark document into the grammar IR (`lark_compiler.rs`).
//!
//! The compiler owns a temporary arena for maps and scratch strings; the returned grammar is
//! heap-allocated (caller `deinit`). `compile` consumes the passed `LarkDocument` (Rust move).

const std = @import("std");
const Allocator = std.mem.Allocator;
const fsm_mod = @import("../fsm/mod.zig");
const functor = @import("../functor/mod.zig");
const grammar_mod = @import("../grammar/mod.zig");
const lark_definition = @import("lark_definition.zig");
const lark_document = @import("lark_document.zig");
const lark_error = @import("lark_error.zig");
const lark_lexer_mod = @import("lark_lexer.zig");
const lark_location = @import("lark_location.zig");
const lark_node = @import("lark_node.zig");
const lark_node_kind = @import("lark_node_kind.zig");
const lark_parser = @import("lark_parser.zig");
const lark_special_token_set = @import("lark_special_token_set.zig");
const lark_trigger = @import("lark_trigger.zig");
const named_grammar_mod = @import("named_grammar.zig");
const named_grammar_registry = @import("named_grammar_registry.zig");
const json_schema_converter = @import("json_schema_converter.zig");
const schema_error = @import("schema_error.zig");
const regex_converter = @import("regex_converter.zig");
const regex_error_mod = @import("regex_error.zig");
const support = @import("../support/mod.zig");
const tokenizer_mod = @import("../tokenizer/mod.zig");
const CharacterClassElement = grammar_mod.CharacterClassElement;
const Grammar = grammar_mod.Grammar;
const GrammarBuilder = grammar_mod.GrammarBuilder;
const SuffixStopInfo = grammar_mod.SuffixStopInfo;
const TagDispatch = grammar_mod.TagDispatch;
const TokenTagDispatch = grammar_mod.TokenTagDispatch;
const LarkDefinition = lark_definition.LarkDefinition;
const LarkDocument = lark_document.LarkDocument;
const LarkError = lark_error.LarkError;
const LarkErrorInfo = lark_error.LarkErrorInfo;
const LarkLocation = lark_location.LarkLocation;
const LarkNode = lark_node.LarkNode;
const LarkNodeKind = lark_node_kind.LarkNodeKind;
const LarkSpecialTokenSet = lark_special_token_set.LarkSpecialTokenSet;
const LarkTrigger = lark_trigger.LarkTrigger;
const NamedGrammar = named_grammar_mod.NamedGrammar;
const NamedGrammarRegistry = named_grammar_registry.NamedGrammarRegistry;
const TokenizerInfo = tokenizer_mod.tokenizer_info.TokenizerInfo;

/// Compiles one Lark document (the top-level source, an inline `%lark` block, or a named
/// Lark source) into a normalized `Grammar` rooted at its `start` rule.
pub const BodyMarker = struct { body: []u8, marker: []u8 };

pub const LarkCompiler = struct {
    gpa: Allocator,
    diag: ?*?LarkErrorInfo,
    /// Scratch arena: hash maps, regex rewrites, intermediate grammars. Freed when the
    /// compilation ends; only the result grammar (from `gpa`) and diag strings survive.
    arena: Allocator,
    source: []const u8,
    document: *LarkDocument,
    tokenizer_info: ?*const TokenizerInfo,
    named_grammars: *NamedGrammarRegistry,
    builder: GrammarBuilder,
    definition_by_name: std.StringHashMap(usize),
    rule_ids: std.StringHashMap(i32),
    named_grammar_roots: std.StringHashMap(i32),
    skip_rule_id: ?i32 = null,
    allow_initial_skip: bool = false,
    dynamic_unused_rules: std.StringHashMap(void),

    /// Compiles `document` (parsed from `source`) into a grammar. Consumes `document`.
    pub fn compile(
        gpa: Allocator,
        source: []const u8,
        document: *LarkDocument,
        tokenizer_info: ?*const TokenizerInfo,
        named_grammars: *NamedGrammarRegistry,
        diag: ?*?LarkErrorInfo,
    ) LarkError!*Grammar {
        for (document.imports.items) |*import| {
            const pattern = common_regex(import.path) orelse {
                const msg = std.fmt.allocPrint(
                    gpa,
                    "unknown common import '{s}'",
                    .{import.path},
                ) catch {
                    document.deinit();
                    return error.OutOfMemory;
                };
                defer gpa.free(msg);
                const err_ret = fail_at(gpa, diag, source, import.location, msg);
                document.deinit();
                return err_ret;
            };
            const regex = LarkNode.with_text(.Regex, import.location, pattern);
            document.definitions.append(document.allocator(), LarkDefinition.new(
                import.local_name,
                true,
                regex,
                import.location,
            )) catch return error.OutOfMemory;
        }
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var builder = GrammarBuilder.new(gpa) catch return error.OutOfMemory;
        var compiler = LarkCompiler{
            .gpa = gpa,
            .diag = diag,
            .arena = arena.allocator(),
            .source = source,
            .document = document,
            .tokenizer_info = tokenizer_info,
            .named_grammars = named_grammars,
            .builder = builder,
            .definition_by_name = std.StringHashMap(usize).init(arena.allocator()),
            .rule_ids = std.StringHashMap(i32).init(arena.allocator()),
            .named_grammar_roots = std.StringHashMap(i32).init(arena.allocator()),
            .dynamic_unused_rules = std.StringHashMap(void).init(arena.allocator()),
        };
        const grammar = compiler.compile_document() catch |err| {
            builder.deinit();
            document.deinit();
            return err;
        };
        builder.deinit();
        document.deinit();
        return grammar;
    }

    fn fail(self: *const LarkCompiler, location: LarkLocation, message: []const u8) LarkError {
        return fail_at(self.gpa, self.diag, self.source, location, message);
    }

    fn fail_fmt(self: *const LarkCompiler, location: LarkLocation, comptime fmt: []const u8, args: anytype) LarkError {
        const message = std.fmt.allocPrint(self.gpa, fmt, args) catch return error.OutOfMemory;
        defer self.gpa.free(message);
        return fail_at(self.gpa, self.diag, self.source, location, message);
    }

    fn fail_at(gpa: Allocator, diag: ?*?LarkErrorInfo, source: []const u8, location: LarkLocation, message: []const u8) LarkError {
        if (diag) |d| {
            d.* = lark_error.at(gpa, source, location, message) catch return error.OutOfMemory;
        }
        return error.Lark;
    }

    fn definition_index(self: *const LarkCompiler, name: []const u8) ?usize {
        return self.definition_by_name.get(name);
    }

    fn compile_document(self: *LarkCompiler) LarkError!*Grammar {
        try self.parse_options();
        try self.index_definitions();
        try self.validate_terminal_cycles();

        const document = self.document;
        for (document.definitions.items) |*definition| {
            const rule_id = self.builder.add_empty_rule(definition.name) catch return error.OutOfMemory;
            self.rule_ids.put(definition.name, rule_id) catch return error.OutOfMemory;
        }
        for (document.definitions.items) |*definition| {
            if (!definition.is_terminal) continue;
            const body = try self.compile_node(&definition.body, definition.name, true, true);
            self.builder.update_rule_body(self.rule_ids.get(definition.name).?, body);
        }

        try self.compile_ignore();

        const start = &document.definitions.items[self.definition_by_name.get("start").?];
        const dynamic_start_body: ?i32 = if (start.temperature != null)
            null
        else
            try self.compile_dynamic_start(start);

        for (document.definitions.items) |*definition| {
            if (definition.is_terminal) continue;
            const rule_id = self.rule_ids.get(definition.name).?;
            if (self.dynamic_unused_rules.contains(definition.name)) {
                if (definition.max_tokens) |max_tokens| {
                    return self.fail(max_tokens.key_location, "max_tokens is not supported on rules consumed by dynamic dispatch");
                }
                if (definition.max_chars != null) {
                    std.debug.print("Ignoring max_chars on rule '{s}' because it is consumed by dynamic dispatch.\n", .{definition.name});
                }
                if (definition.capture_name) |capture| {
                    return self.fail(capture.value_location, "capture is not supported on rules consumed by dynamic dispatch");
                }
                const empty = self.builder.add_empty_str() catch return error.OutOfMemory;
                self.builder.update_rule_body(rule_id, empty);
                continue;
            }
            const body_expr_id: i32 = blk: {
                if (definition.temperature != null) {
                    const body = try self.compile_temperature_rule(definition);
                    if (definition.max_chars) |max_chars| {
                        self.builder.update_max_chars(rule_id, max_chars);
                    }
                    break :blk body;
                }
                if (std.mem.eql(u8, definition.name, "start")) {
                    const body = if (dynamic_start_body) |dynamic_body| blk2: {
                        if (definition.max_tokens) |max_tokens| {
                            return self.fail(max_tokens.key_location, "max_tokens is not supported on a dynamic dispatch start rule");
                        }
                        if (definition.max_chars != null) {
                            std.debug.print("Ignoring max_chars on dynamic dispatch start rule '{s}'.\n", .{definition.name});
                        }
                        break :blk2 dynamic_body;
                    } else try self.compile_rule_body(definition);
                    if (self.skip_rule_id) |skip_rule_id| {
                        if (self.allow_initial_skip) {
                            const skip = self.builder.add_rule_ref(skip_rule_id) catch return error.OutOfMemory;
                            break :blk self.builder.add_sequence(&.{ skip, body }) catch return error.OutOfMemory;
                        }
                    }
                    break :blk body;
                }
                break :blk try self.compile_rule_body(definition);
            };
            self.builder.update_rule_body(rule_id, body_expr_id);
            if (definition.capture_name) |capture| {
                self.builder.update_capture_name(rule_id, capture.name) catch return error.OutOfMemory;
            }
            self.builder.update_rule_temperature(rule_id, definition.temperature);
        }

        var root_rule_id = self.rule_ids.get("start").?;
        if (start.temperature != null) {
            if (self.skip_rule_id) |skip_rule_id| {
                var elements: std.ArrayList(i32) = .empty;
                if (self.allow_initial_skip) {
                    elements.append(self.arena, self.builder.add_rule_ref(skip_rule_id) catch return error.OutOfMemory) catch return error.OutOfMemory;
                }
                elements.append(self.arena, self.builder.add_rule_ref(root_rule_id) catch return error.OutOfMemory) catch return error.OutOfMemory;
                elements.append(self.arena, self.builder.add_rule_ref(skip_rule_id) catch return error.OutOfMemory) catch return error.OutOfMemory;
                const sequence = self.builder.add_sequence(elements.items) catch return error.OutOfMemory;
                root_rule_id = self.builder.add_rule_with_hint("start_with_skip", sequence) catch return error.OutOfMemory;
            }
        }
        const grammar = self.builder.into_grammar_with_root_id(self.gpa, root_rule_id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Lark,
        };
        const normalized = functor.grammar_normalizer(self.gpa, grammar) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Lark,
        };
        grammar.deinit();
        const eliminated = functor.dead_code_eliminator(self.gpa, normalized) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Lark,
        };
        normalized.deinit();
        return eliminated;
    }

    fn compile_temperature_rule(self: *LarkCompiler, definition: *const LarkDefinition) LarkError!i32 {
        const body = unwrap_single(&definition.body);
        if (body.kind == .Json or body.kind == .NestedLark or body.kind == .GrammarRef) {
            return self.compile_node(body, definition.name, false, false);
        }
        var nested_diag: ?LarkErrorInfo = null;
        const saved = self.diag;
        self.diag = &nested_diag;
        const result = self.compile_node(&definition.body, definition.name, true, false) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Lark => {
                self.diag = saved;
                const message: []const u8 = if (nested_diag) |*nd| nd.format_message(self.gpa) catch return error.OutOfMemory else "lark error";
                defer self.gpa.free(message);
                return self.fail_fmt(
                    definition.location,
                    "{s}; temperature is only supported on terminals and subgrammars",
                    .{message},
                );
            },
        };
        return result;
    }

    /// Compiles an ordinary rule body, applying its token and character budgets.
    fn compile_rule_body(self: *LarkCompiler, definition: *const LarkDefinition) LarkError!i32 {
        const rule_id = self.rule_ids.get(definition.name).?;
        if (definition.max_tokens) |max_tokens| {
            self.builder.update_max_tokens(rule_id, max_tokens.value);
        }
        if (definition.max_chars) |max_chars| {
            self.builder.update_max_chars(rule_id, max_chars);
        }
        if (definition.has_lazy_semantics()) {
            return self.compile_lazy_rule(definition);
        }
        return self.compile_node(&definition.body, definition.name, false, true);
    }

    fn parse_options(self: *LarkCompiler) LarkError!void {
        const document = self.document;
        for (document.options.items) |*option| {
            if (option.value != .object) {
                return self.fail(option.location, "%grammar_options value must be an object");
            }
            var object = option.value.object;
            var keys = sorted_object_keys(self.arena, &object) catch return error.OutOfMemory;
            defer keys.deinit(self.arena);
            for (keys.items) |key| {
                const option_value = object.get(key).?;
                const flag: ?bool = blk: {
                    if (std.mem.eql(u8, key, "allow_initial_skip") or
                        std.mem.eql(u8, key, "no_forcing") or
                        std.mem.eql(u8, key, "allow_invalid_utf8"))
                    {
                        break :blk switch (option_value) {
                            .bool => |b| b,
                            else => null,
                        };
                    }
                    return self.fail_fmt(option.location, "unknown %grammar_options option '{s}'", .{key});
                };
                const flag_value = flag orelse {
                    return self.fail_fmt(option.location, "{s} must be a boolean", .{key});
                };
                if (std.mem.eql(u8, key, "allow_initial_skip")) {
                    self.allow_initial_skip = self.allow_initial_skip or flag_value;
                } else if (flag_value) {
                    return self.fail_fmt(option.location, "%grammar_options option '{s}' is not supported", .{key});
                }
            }
        }
    }

    fn index_definitions(self: *LarkCompiler) LarkError!void {
        const document = self.document;
        for (document.definitions.items, 0..) |*definition, index| {
            const entry = self.definition_by_name.getOrPut(definition.name) catch return error.OutOfMemory;
            if (entry.found_existing) {
                return self.fail_fmt(definition.location, "duplicate rule or terminal '{s}'", .{definition.name});
            }
            entry.value_ptr.* = index;
        }
        const start_index = self.definition_index("start") orelse {
            return self.fail(LarkLocation.START, "no start rule found");
        };
        const start = &document.definitions.items[start_index];
        if (start.is_terminal) {
            return self.fail(start.location, "start must be a rule");
        }
    }

    fn collect_referenced_names(node: *const LarkNode, names: *std.ArrayList([]const u8), allocator: Allocator) Allocator.Error!void {
        if (node.kind == .Name) {
            try names.append(allocator, node.text);
        }
        for (node.children.items) |*child| {
            try collect_referenced_names(child, names, allocator);
        }
    }

    fn validate_terminal_cycles(self: *LarkCompiler) LarkError!void {
        var states = std.StringHashMap(i32).init(self.arena);
        defer states.deinit();
        for (self.document.definitions.items) |*definition| {
            if (definition.is_terminal and !states.contains(definition.name)) {
                try self.visit_terminal(definition, &states);
            }
        }
    }

    /// Depth-first visit of terminal references; `states` maps a name to 1 (visiting) or 2 (done).
    fn visit_terminal(self: *const LarkCompiler, definition: *const LarkDefinition, states: *std.StringHashMap(i32)) LarkError!void {
        states.put(definition.name, 1) catch return error.OutOfMemory;
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.arena);
        collect_referenced_names(&definition.body, &names, self.arena) catch return error.OutOfMemory;
        for (names.items) |name| {
            const index = self.definition_index(name) orelse {
                return self.fail_fmt(definition.location, "unknown name '{s}'", .{name});
            };
            const referenced = &self.document.definitions.items[index];
            if (!referenced.is_terminal) {
                return self.fail_fmt(
                    definition.location,
                    "terminal '{s}' cannot reference rule '{s}'",
                    .{ definition.name, name },
                );
            }
            if (states.get(name)) |state| {
                if (state == 1) {
                    return self.fail_fmt(definition.location, "circular reference in terminal '{s}'", .{name});
                }
            } else {
                try self.visit_terminal(referenced, states);
            }
        }
        states.put(definition.name, 2) catch return error.OutOfMemory;
    }

    fn compile_ignore(self: *LarkCompiler) LarkError!void {
        const document = self.document;
        if (document.ignores.items.len == 0) {
            return;
        }
        var ignore_choices: std.ArrayList(i32) = .empty;
        for (document.ignores.items) |*ignore| {
            ignore_choices.append(self.arena, try self.compile_node(ignore, "lark_ignore", true, true)) catch return error.OutOfMemory;
        }
        const ignore_body = if (ignore_choices.items.len == 1)
            ignore_choices.items[0]
        else
            self.builder.add_choices(ignore_choices.items) catch return error.OutOfMemory;
        const ignore_item_rule = self.builder.add_rule_with_hint("lark_ignore_item", ignore_body) catch return error.OutOfMemory;
        const ignore_repeat = self.builder.add_repeat(ignore_item_rule, 0, -1) catch return error.OutOfMemory;
        self.skip_rule_id = self.builder.add_rule_with_hint("lark_ignore", ignore_repeat) catch return error.OutOfMemory;
    }

    /// The characters of a case-insensitive (`"..."i`) literal, which must be ASCII.
    fn case_insensitive_chars(self: *const LarkCompiler, node: *const LarkNode) LarkError!std.ArrayList(u21) {
        if (!std.mem.eql(u8, node.flags, "i")) {
            return self.fail_fmt(node.location, "unsupported string literal flags '{s}'", .{node.flags});
        }
        var characters: std.ArrayList(u21) = .empty;
        const text = c_str(node.text);
        var i: usize = 0;
        while (i < text.len) {
            const len = std.unicode.utf8ByteSequenceLength(text[i]) catch break;
            if (i + len > text.len) break;
            const cp = std.unicode.utf8Decode(text[i .. i + len]) catch break;
            characters.append(self.arena, cp) catch return error.OutOfMemory;
            i += len;
        }
        if (node.text.len != 0 and characters.items.len == 0) {
            return self.fail(node.location, "case-insensitive string is not valid UTF-8");
        }
        for (characters.items) |character| {
            if (character > 0x7F) {
                return self.fail(node.location, "case-insensitive string literals currently support ASCII characters only");
            }
        }
        return characters;
    }

    fn compile_string_literal(self: *LarkCompiler, node: *const LarkNode) LarkError!i32 {
        if (node.flags.len == 0) {
            if (node.text.len == 0) {
                return self.builder.add_empty_str() catch return error.OutOfMemory;
            }
            return self.builder.add_byte_string(node.text) catch return error.OutOfMemory;
        }
        var elements: std.ArrayList(i32) = .empty;
        var characters = try self.case_insensitive_chars(node);
        defer characters.deinit(self.arena);
        for (characters.items) |character| {
            if ((character >= 'a' and character <= 'z') or (character >= 'A' and character <= 'Z')) {
                const lower: i32 = @intCast(std.ascii.toLower(@intCast(character)));
                const upper: i32 = @intCast(std.ascii.toUpper(@intCast(character)));
                elements.append(self.arena, self.builder.add_character_class(&.{
                    CharacterClassElement.new(lower, lower),
                    CharacterClassElement.new(upper, upper),
                }, false) catch return error.OutOfMemory) catch return error.OutOfMemory;
            } else {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(character, &buf) catch unreachable;
                elements.append(self.arena, self.builder.add_byte_string(buf[0..len]) catch return error.OutOfMemory) catch return error.OutOfMemory;
            }
        }
        return switch (elements.items.len) {
            0 => self.builder.add_empty_str() catch return error.OutOfMemory,
            1 => elements.items[0],
            else => self.builder.add_sequence(elements.items) catch return error.OutOfMemory,
        };
    }

    /// Validates regex flags, returning `(case_insensitive, dot_all)`.
    fn parse_regex_flags(self: *const LarkCompiler, node: *const LarkNode) LarkError!struct { case_insensitive: bool, dot_all: bool } {
        var case_insensitive = false;
        var dot_all = false;
        var i: usize = 0;
        while (i < node.flags.len) : (i += 1) {
            const flag = node.flags[i];
            switch (flag) {
                'i' => case_insensitive = true,
                's' => dot_all = true,
                // XGrammar regular expressions use Unicode codepoint semantics by default.
                'u' => {},
                else => {
                    return self.fail_fmt(node.location, "regular-expression flag '{c}' is not supported", .{flag});
                },
            }
        }
        return .{ .case_insensitive = case_insensitive, .dot_all = dot_all };
    }

    fn string_literal_to_regex(self: *const LarkCompiler, node: *const LarkNode) LarkError![]u8 {
        if (node.flags.len == 0) {
            return escape_regex_literal(self.arena, node.text) catch return error.OutOfMemory;
        }
        var result: std.ArrayList(u8) = .empty;
        var characters = try self.case_insensitive_chars(node);
        defer characters.deinit(self.arena);
        for (characters.items) |character| {
            if ((character >= 'a' and character <= 'z') or (character >= 'A' and character <= 'Z')) {
                result.append(self.arena, '[') catch return error.OutOfMemory;
                result.append(self.arena, @intCast(std.ascii.toLower(@intCast(character)))) catch return error.OutOfMemory;
                result.append(self.arena, @intCast(std.ascii.toUpper(@intCast(character)))) catch return error.OutOfMemory;
                result.append(self.arena, ']') catch return error.OutOfMemory;
            } else {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(character, &buf) catch unreachable;
                const escaped = escape_regex_literal(self.arena, buf[0..len]) catch return error.OutOfMemory;
                result.appendSlice(self.arena, escaped) catch return error.OutOfMemory;
            }
        }
        return result.toOwnedSlice(self.arena);
    }

    /// The single codepoints of a character range's endpoints.
    fn range_endpoints(self: *const LarkCompiler, node: *const LarkNode) LarkError!struct { begin: u21, end: u21 } {
        const begin = single_codepoint(c_str(node.text));
        const end = single_codepoint(c_str(node.text2));
        if (begin == null or end == null) {
            return self.fail(node.location, "character range endpoints must be one character");
        }
        if (begin.? > end.?) {
            return self.fail(node.location, "character range start must not exceed end");
        }
        return .{ .begin = begin.?, .end = end.? };
    }

    /// Lowers a terminal expression to a single regular expression (used by suffix and stop).
    fn terminal_node_to_regex(self: *const LarkCompiler, node: *const LarkNode, visiting: *std.StringHashMap(void)) LarkError![]u8 {
        switch (node.kind) {
            .Sequence => {
                var result: std.ArrayList(u8) = .empty;
                for (node.children.items) |*child| {
                    const pattern = try self.terminal_node_to_regex(child, visiting);
                    if (pattern.len != 0) {
                        result.appendSlice(self.arena, std.fmt.allocPrint(self.arena, "(?:{s})", .{pattern}) catch return error.OutOfMemory) catch return error.OutOfMemory;
                    }
                }
                return result.toOwnedSlice(self.arena);
            },
            .Choice => {
                var alternatives: std.ArrayList([]u8) = .empty;
                for (node.children.items) |*child| {
                    alternatives.append(self.arena, try self.terminal_node_to_regex(child, visiting)) catch return error.OutOfMemory;
                }
                var joined: std.ArrayList(u8) = .empty;
                for (alternatives.items, 0..) |alternative, i| {
                    if (i != 0) joined.append(self.arena, '|') catch return error.OutOfMemory;
                    joined.appendSlice(self.arena, alternative) catch return error.OutOfMemory;
                }
                return std.fmt.allocPrint(self.arena, "(?:{s})", .{joined.items}) catch return error.OutOfMemory;
            },
            .Repeat => {
                const child = try self.terminal_node_to_regex(&node.children.items[0], visiting);
                if (child.len == 0) {
                    return self.arena.dupe(u8, "");
                }
                var arena_result: std.ArrayList(u8) = .empty;
                const min = node.min_repeat;
                const max = node.max_repeat;
                const quantifier: []const u8 = blk: {
                    if (min == 0 and max == -1) break :blk "*";
                    if (min == 1 and max == -1) break :blk "+";
                    if (min == 0 and max == 1) break :blk "?";
                    if (min == max) break :blk std.fmt.allocPrint(self.arena, "{{{d}}}", .{min}) catch return error.OutOfMemory;
                    if (max == -1) break :blk std.fmt.allocPrint(self.arena, "{{{d},}}", .{min}) catch return error.OutOfMemory;
                    break :blk std.fmt.allocPrint(self.arena, "{{{d},{d}}}", .{ min, max }) catch return error.OutOfMemory;
                };
                arena_result.appendSlice(self.arena, std.fmt.allocPrint(self.arena, "(?:{s}){s}", .{ child, quantifier }) catch return error.OutOfMemory) catch return error.OutOfMemory;
                return arena_result.toOwnedSlice(self.arena);
            },
            .String => return self.string_literal_to_regex(node),
            .Regex => {
                const flags = try self.parse_regex_flags(node);
                if (flags.case_insensitive) {
                    return self.fail(
                        node.location,
                        "regular-expression flag 'i' is not supported with suffix or stop attributes",
                    );
                }
                const pattern = fsm_mod.rewrite_regex_dots(self.arena, node.text, flags.dot_all) catch return error.OutOfMemory;
                return std.fmt.allocPrint(self.arena, "(?:{s})", .{pattern}) catch return error.OutOfMemory;
            },
            .Range => {
                const endpoints = try self.range_endpoints(node);
                var result: std.ArrayList(u8) = .empty;
                result.append(self.arena, '[') catch return error.OutOfMemory;
                append_class_character(&result, self.arena, endpoints.begin) catch return error.OutOfMemory;
                result.append(self.arena, '-') catch return error.OutOfMemory;
                append_class_character(&result, self.arena, endpoints.end) catch return error.OutOfMemory;
                result.append(self.arena, ']') catch return error.OutOfMemory;
                return result.toOwnedSlice(self.arena);
            },
            .Name => {
                const index = self.definition_index(node.text) orelse {
                    return self.fail_fmt(node.location, "unknown name '{s}'", .{node.text});
                };
                const definition = &self.document.definitions.items[index];
                if (!definition.is_terminal) {
                    return self.fail_fmt(node.location, "terminal cannot reference rule '{s}'", .{node.text});
                }
                const entry = visiting.getOrPut(node.text) catch return error.OutOfMemory;
                if (entry.found_existing) {
                    return self.fail_fmt(node.location, "recursive terminal '{s}' is not supported", .{node.text});
                }
                const result = self.terminal_node_to_regex(&definition.body, visiting);
                _ = visiting.remove(node.text);
                return result;
            },
            else => {
                const message: []const u8 = switch (node.kind) {
                    .SpecialToken => "special tokens cannot be used in terminals",
                    .Json => "%json cannot be used in terminals",
                    .NestedLark => "nested %lark cannot be used in terminals",
                    .RegexExt => "structured %regex cannot be used with suffix or stop",
                    .GrammarRef => "named grammars cannot be used in terminals",
                    .Not => "regular-expression complement '~' is not supported",
                    else => unreachable,
                };
                return self.fail(node.location, message);
            },
        }
    }

    fn parse_structured_regex_chunks(self: *const LarkCompiler, node: *const LarkNode) LarkError!std.ArrayList([]const u8) {
        const parse_error = struct {
            fn f(compiler: *const LarkCompiler, n: *const LarkNode, message: []const u8) LarkError {
                return compiler.fail(n.location, message);
            }
        }.f;
        const value = support.json_parse.parse_json(self.arena, node.text) catch |e| {
            const message = try std.fmt.allocPrint(self.gpa, "failed to parse %regex: {s}", .{@errorName(e)});
            defer self.gpa.free(message);
            return parse_error(self, node, message);
        };
        if (value != .object) {
            return parse_error(self, node, "%regex value must be an object");
        }
        var object = value.object;
        var keys = sorted_object_keys(self.arena, &object) catch return error.OutOfMemory;
        defer keys.deinit(self.arena);
        var fields: std.ArrayList(struct { key: []const u8, value: std.json.Value }) = .empty;
        defer fields.deinit(self.arena);
        for (keys.items) |key| {
            if (!std.mem.eql(u8, key, "substring_chunks") and
                !std.mem.eql(u8, key, "substring_chars") and
                !std.mem.eql(u8, key, "substring_words"))
            {
                const message = try std.fmt.allocPrint(self.gpa, "unknown field '{s}' in %regex", .{key});
                defer self.gpa.free(message);
                return parse_error(self, node, message);
            }
            const field_value = object.get(key).?;
            if (field_value != .null) {
                fields.append(self.arena, .{ .key = key, .value = field_value }) catch return error.OutOfMemory;
            }
        }
        if (fields.items.len != 1) {
            return parse_error(self, node, if (fields.items.len == 0)
                "no fields set on %regex"
            else
                "only one field can be set on %regex");
        }
        const field = fields.items[0];
        var chunks: std.ArrayList([]const u8) = .empty;
        if (std.mem.eql(u8, field.key, "substring_words")) {
            return parse_error(self, node, if (field.value == .string)
                "substring_words is not supported yet"
            else
                "substring_words must be a string");
        }
        if (std.mem.eql(u8, field.key, "substring_chars")) {
            if (field.value != .string) {
                return parse_error(self, node, "substring_chars must be a string");
            }
            var i: usize = 0;
            const text = field.value.string;
            while (i < text.len) {
                const len = std.unicode.utf8ByteSequenceLength(text[i]) catch text.len;
                if (i + len > text.len) len2: {
                    chunks.append(self.arena, text[i .. i + 1]) catch return error.OutOfMemory;
                    i += 1;
                    break :len2;
                }
                chunks.append(self.arena, text[i .. i + len]) catch return error.OutOfMemory;
                i += len;
            }
            return chunks;
        }
        if (field.value != .array) {
            return parse_error(self, node, "substring_chunks must be an array of strings");
        }
        for (field.value.array.items) |chunk| {
            if (chunk != .string) {
                return parse_error(self, node, "substring_chunks must be an array of strings");
            }
            chunks.append(self.arena, chunk.string) catch return error.OutOfMemory;
        }
        return chunks;
    }

    fn compile_structured_regex(self: *LarkCompiler, node: *const LarkNode, rule_hint: []const u8) LarkError!i32 {
        const chunks = try self.parse_structured_regex_chunks(node);
        // A substring expr can only be the body of a rule, so wrap it and return a reference.
        const substring_expr_id = self.builder.add_substring(chunks.items) catch return error.OutOfMemory;
        const hint = std.fmt.allocPrint(self.arena, "{s}_substring", .{rule_hint}) catch return error.OutOfMemory;
        const rule_id = self.builder.add_rule_with_hint(hint, substring_expr_id) catch return error.OutOfMemory;
        return self.builder.add_rule_ref(rule_id) catch return error.OutOfMemory;
    }

    /// Makes the named grammar `name` available in the registry, compiling it if it is a
    /// Lark source.
    fn resolve_named_grammar(self: *LarkCompiler, name: []const u8, location: LarkLocation) LarkError!void {
        const input = self.named_grammars.inputs.get(name) orelse {
            return self.fail_fmt(location, "unknown named grammar '@{s}'", .{name});
        };
        const named_source = switch (input.*) {
            .grammar => return,
            .lark => |l| l.source,
        };
        if (self.named_grammars.compiled.contains(name)) {
            return;
        }
        var cycle_start_opt: ?usize = null;
        for (self.named_grammars.active.items, 0..) |active, index| {
            if (std.mem.eql(u8, active, name)) {
                cycle_start_opt = index;
                break;
            }
        }
        if (cycle_start_opt != null) {
            const cycle_start = cycle_start_opt.?;
            var cycle: std.ArrayList(u8) = .empty;
            for (self.named_grammars.active.items[cycle_start..]) |active| {
                cycle.appendSlice(self.arena, std.fmt.allocPrint(self.arena, "@{s} -> ", .{active}) catch return error.OutOfMemory) catch return error.OutOfMemory;
            }
            cycle.appendSlice(self.arena, std.fmt.allocPrint(self.arena, "@{s}", .{name}) catch return error.OutOfMemory) catch return error.OutOfMemory;
            return self.fail_fmt(location, "circular named grammar reference: {s}", .{cycle.items});
        }

        const active_name = self.gpa.dupe(u8, name) catch return error.OutOfMemory;
        self.named_grammars.active.append(self.named_grammars.gpa, active_name) catch return error.OutOfMemory;
        var nested_diag: ?LarkErrorInfo = null;
        var compiled: ?*Grammar = null;
        {
            const saved = self.diag;
            self.diag = &nested_diag;
            defer self.diag = saved;
            var document_or_err = lark_parser.parse_nested(self.gpa, named_source, &nested_diag, null);
            if (document_or_err) |*document| {
                if (LarkCompiler.compile(self.gpa, named_source, document, self.tokenizer_info, self.named_grammars, &nested_diag)) |grammar| {
                    compiled = grammar;
                } else |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {},
                }
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            }
        }
        const popped = self.named_grammars.active.pop();
        self.named_grammars.gpa.free(popped.?);
        if (compiled == null) {
            defer if (nested_diag) |*nd| nd.deinit(self.gpa);
            const message = try (if (nested_diag) |*nd| nd.format_message(self.gpa) else self.gpa.dupe(u8, "lark error"));
            defer self.gpa.free(message);
            return self.fail_fmt(location, "failed to compile named grammar '@{s}': {s}", .{ name, message });
        }
        self.named_grammars.compiled.put(self.gpa.dupe(u8, name) catch return error.OutOfMemory, compiled.?) catch return error.OutOfMemory;
    }

    fn compile_node(self: *LarkCompiler, node: *const LarkNode, rule_hint: []const u8, terminal_mode: bool, with_skip: bool) LarkError!i32 {
        // Whether to append the `%ignore` skip after a lexeme-like result.
        const skip_lexeme = !terminal_mode and with_skip;
        const result: i32 = blk: {
            switch (node.kind) {
            .Sequence, .Choice => {
                if (node.children.items.len == 0) {
                    return self.builder.add_empty_str() catch return error.OutOfMemory;
                }
                var elements: std.ArrayList(i32) = .empty;
                for (node.children.items) |*child| {
                    elements.append(self.arena, try self.compile_node(child, rule_hint, terminal_mode, with_skip)) catch return error.OutOfMemory;
                }
                if (elements.items.len == 1) {
                    return elements.items[0];
                }
                if (node.kind == .Sequence) {
                    break :blk self.builder.add_sequence(elements.items) catch return error.OutOfMemory;
                }
                break :blk self.builder.add_choices(elements.items) catch return error.OutOfMemory;
            },
            .Repeat => {
                const repeat_hint = std.fmt.allocPrint(self.arena, "{s}_repeat", .{rule_hint}) catch return error.OutOfMemory;
                const child = try self.compile_node(&node.children.items[0], repeat_hint, terminal_mode, with_skip);
                break :blk self.builder.add_repeat_from_expr(repeat_hint, child, node.min_repeat, node.max_repeat) catch return error.OutOfMemory;
            },
            .Name => {
                const index = self.definition_index(node.text) orelse {
                    return self.fail_fmt(node.location, "unknown name '{s}'", .{node.text});
                };
                const definition = &self.document.definitions.items[index];
                if (terminal_mode and !definition.is_terminal) {
                    return self.fail_fmt(node.location, "terminal cannot reference rule '{s}'", .{node.text});
                }
                // Lazy and temperature rules are compiled like terminals (lexemes), so they
                // also take a trailing skip.
                const is_lexeme = definition.is_terminal or definition.has_lazy_semantics() or definition.temperature != null;
                const reference = self.builder.add_rule_ref(self.rule_ids.get(node.text).?) catch return error.OutOfMemory;
                if (skip_lexeme and is_lexeme) {
                    break :blk self.append_skip(reference);
                }
                break :blk reference;
            },
            .String => {
                const literal = try self.compile_string_literal(node);
                if (skip_lexeme and node.text.len != 0) {
                    break :blk self.append_skip(literal);
                }
                break :blk literal;
            },
            .Range => {
                const endpoints = try self.range_endpoints(node);
                break :blk self.builder.add_character_class(&.{
                    CharacterClassElement.new(@intCast(endpoints.begin), @intCast(endpoints.end)),
                }, false) catch return error.OutOfMemory;
            },
            .Regex => {
                const flags = try self.parse_regex_flags(node);
                const pattern = fsm_mod.rewrite_regex_dots(self.arena, node.text, flags.dot_all) catch return error.OutOfMemory;
                if (flags.case_insensitive) {
                    // The FSM regex engine handles the (?i) prefix with ASCII case folding.
                    // Validate the pattern eagerly so that errors carry the source location.
                    const flagged_pattern = std.fmt.allocPrint(self.arena, "(?i){s}", .{pattern}) catch return error.OutOfMemory;
                    try self.validate_regex(flagged_pattern, node.location);
                    const regex_expr = self.builder.add_regex(flagged_pattern, false) catch return error.OutOfMemory;
                    const hint = std.fmt.allocPrint(self.arena, "{s}_regex", .{rule_hint}) catch return error.OutOfMemory;
                    const regex_rule_id = self.builder.add_rule_with_hint(hint, regex_expr) catch return error.OutOfMemory;
                    break :blk self.builder.add_rule_ref(regex_rule_id) catch return error.OutOfMemory;
                }
                const grammar = try self.from_regex_checked(pattern, node.location);
                defer grammar.deinit();
                const root = functor.grammar_union_concat_mod.add_sub_grammar(&self.builder, grammar) catch return error.OutOfMemory;
                break :blk self.builder.add_rule_ref(root) catch return error.OutOfMemory;
            },
            .Json => {
                if (terminal_mode) {
                    return self.fail(node.location, "%json cannot be used in terminals");
                }
                var schema_diag_storage: schema_error.SchemaErrorInfo = undefined;
                const schema_diag: ?*schema_error.SchemaErrorInfo = &schema_diag_storage;
                const grammar = json_schema_converter.from_json_schema(
                    self.gpa,
                    node.text,
                    true,
                    null,
                    null,
                    true,
                    null,
                &schema_diag_storage,
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        defer if (schema_diag != null) self.gpa.free(schema_diag_storage.message);
                        const message = if (schema_diag != null) try self.gpa.dupe(u8, schema_diag.?.message) else try self.gpa.dupe(u8, @errorName(err));
                        defer self.gpa.free(message);
                        return self.fail_fmt(node.location, "failed to compile inline JSON schema: {s}", .{message});
                    },
                };
                defer grammar.deinit();
                const root = functor.grammar_union_concat_mod.add_sub_grammar(&self.builder, grammar) catch return error.OutOfMemory;
                break :blk self.builder.add_rule_ref(root) catch return error.OutOfMemory;
            },
            .NestedLark => {
                if (terminal_mode) {
                    return self.fail(node.location, "nested %lark cannot be used in terminals");
                }
                const nested = node.nested orelse {
                    return self.fail(node.location, "unsupported grammar node");
                };
                var cloned = LarkDocument.deep_clone(self.gpa, nested) catch return error.OutOfMemory;
                var nested_diag: ?LarkErrorInfo = null;
                const grammar = LarkCompiler.compile(self.gpa, self.source, &cloned, self.tokenizer_info, self.named_grammars, &nested_diag) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Lark => {
                        defer if (nested_diag) |*nd| nd.deinit(self.gpa);
                        const message = try (if (nested_diag) |*nd| nd.format_message(self.gpa) else self.gpa.dupe(u8, "lark error"));
                        defer self.gpa.free(message);
                        return self.fail_fmt(node.location, "failed to compile nested Lark grammar: {s}", .{message});
                    },
                };
                defer grammar.deinit();
                const root = functor.grammar_union_concat_mod.add_sub_grammar(&self.builder, grammar) catch return error.OutOfMemory;
                break :blk self.builder.add_rule_ref(root) catch return error.OutOfMemory;
            },
            .SpecialToken => {
                if (terminal_mode) {
                    return self.fail(node.location, "special tokens cannot be used in terminals");
                }
                const token_set = try self.resolve_special_token(node.text, node.location);
                if (token_set.excluded) {
                    break :blk self.builder.add_exclude_token_set(token_set.token_ids.items) catch return error.OutOfMemory;
                }
                break :blk self.builder.add_token_set(token_set.token_ids.items) catch return error.OutOfMemory;
            },
            .RegexExt => break :blk try self.compile_structured_regex(node, rule_hint),
            .GrammarRef => {
                if (terminal_mode) {
                    return self.fail(node.location, "named grammars cannot be used in terminals");
                }
                const name = node.text[1..];
                const root: i32 = self.named_grammar_roots.get(name) orelse root_blk: {
                    try self.resolve_named_grammar(name, node.location);
                    const grammar = self.named_grammars.get(name) orelse {
                        return self.fail_fmt(node.location, "unknown named grammar '@{s}'", .{name});
                    };
                    const sub_root = functor.grammar_union_concat_mod.add_sub_grammar(&self.builder, grammar) catch return error.OutOfMemory;
                    self.named_grammar_roots.put(self.arena.dupe(u8, name) catch return error.OutOfMemory, sub_root) catch return error.OutOfMemory;
                    break :root_blk sub_root;
                };
                break :blk self.builder.add_rule_ref(root) catch return error.OutOfMemory;
            },
            .Not => {
                return self.fail(node.location, "regular-expression complement '~' is not supported");
            },
            }
        };
        if (skip_lexeme) {
            return self.append_skip(result);
        }
        return result;
    }

    /// Compiles the regex and maps a conversion failure to a located Lark error.
    fn from_regex_checked(self: *LarkCompiler, pattern: []u8, location: LarkLocation) LarkError!*Grammar {
        var regex_diag: regex_error_mod.RegexErrorInfo = undefined;
        const grammar = regex_converter.from_regex(self.gpa, pattern, &regex_diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Regex => {
                defer self.gpa.free(regex_diag.message);
                const message = regex_error_mod.format_message(&regex_diag, self.gpa) catch return error.OutOfMemory;
                defer self.gpa.free(message);
                return self.fail_fmt(location, "failed to compile regular expression: {s}", .{message});
            },
        };
        return grammar;
    }

    /// Validates the pattern with `RegexFsmBuilder::matches_empty`, mapping the message.
    fn validate_regex(self: *LarkCompiler, pattern: []const u8, location: LarkLocation) LarkError!void {
        var msg: ?[]u8 = null;
        const arena = self.arena;
        _ = fsm_mod.regex_fsm_builder.RegexFsmBuilder.matches_empty(arena, pattern, &msg) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                const message: []const u8 = msg orelse @errorName(err);
                return self.fail_fmt(location, "failed to compile regular expression: {s}", .{message});
            },
        };
    }

    fn append_skip(self: *LarkCompiler, expression: i32) i32 {
        const skip_rule_id = self.skip_rule_id orelse return expression;
        const skip = self.builder.add_rule_ref(skip_rule_id) catch return expression;
        return self.builder.add_sequence(&.{ expression, skip }) catch expression;
    }

    fn resolve_special_token(self: *const LarkCompiler, token: []const u8, location: LarkLocation) LarkError!LarkSpecialTokenSet {
        var result = LarkSpecialTokenSet{};
        const contents_in: ?[]const u8 = blk: {
            if (std.mem.startsWith(u8, token, "<[") and std.mem.endsWith(u8, token, "]>")) {
                break :blk token[2 .. token.len - 2];
            }
            break :blk null;
        };
        if (contents_in == null) {
            const tokenizer_info = self.tokenizer_info orelse {
                return self.fail_fmt(location, "named special token {s} requires tokenizer_info", .{token});
            };
            var token_ids: std.ArrayList(i32) = .empty;
            for (tokenizer_info.decoded_vocab, 0..) |decoded, token_id| {
                if (std.mem.eql(u8, decoded, token)) {
                    token_ids.append(self.arena, @intCast(token_id)) catch return error.OutOfMemory;
                }
            }
            if (token_ids.items.len == 0) {
                return self.fail_fmt(location, "unknown special token {s}", .{token});
            }
            result.token_ids = token_ids;
            return result;
        }
        var contents = contents_in.?;
        if (std.mem.startsWith(u8, contents, "^")) {
            result.excluded = true;
            contents = contents[1..];
        }
        if (std.mem.eql(u8, contents, "*")) {
            if (result.excluded) {
                return self.fail(location, "negated wildcard special token is not supported");
            }
            const tokenizer_info = self.tokenizer_info orelse {
                return self.fail(location, "wildcard special token requires tokenizer_info");
            };
            var token_ids: std.ArrayList(i32) = .empty;
            var id: i32 = 0;
            while (id < tokenizer_info.vocab_size) : (id += 1) {
                token_ids.append(self.arena, id) catch return error.OutOfMemory;
            }
            result.token_ids = token_ids;
            return result;
        }
        if (std.mem.indexOfScalar(u8, contents, '*') != null) {
            return self.fail(location, "wildcard cannot be mixed with token ranges");
        }
        var range_it = std.mem.splitScalar(u8, contents, ',');
        while (range_it.next()) |raw_range| {
            const range = trim_c_space(raw_range);
            if (range.len == 0) continue;
            if (std.mem.indexOfScalar(u8, range, '-')) |dash| {
                const last = range[dash + 1 ..];
                if (std.mem.indexOfScalar(u8, last, '-') != null) {
                    return self.fail_fmt(location, "invalid numeric special-token range '{s}'", .{range});
                }
                const first = parse_token_id(range[0..dash]);
                const last_id = parse_token_id(last);
                if (first == null or last_id == null) {
                    return self.fail_fmt(location, "invalid numeric special-token range '{s}'", .{range});
                }
                try self.append_token_range(&result, location, first.?, last_id.?);
            } else {
                const id = parse_token_id(range) orelse {
                    return self.fail_fmt(location, "invalid numeric special-token range '{s}'", .{range});
                };
                try self.append_token_range(&result, location, id, id);
            }
        }
        if (result.token_ids.items.len == 0) {
            return self.fail(location, "empty numeric special-token range");
        }
        std.mem.sort(i32, result.token_ids.items, {}, std.sort.asc(i32));
        dedup_i32(&result.token_ids);
        return result;
    }

    fn append_token_range(self: *const LarkCompiler, result: *LarkSpecialTokenSet, location: LarkLocation, first: i64, last: i64) LarkError!void {
        if (first < 0 or last < first or last > std.math.maxInt(i32)) {
            return self.fail(location, "invalid numeric special-token range");
        }
        if (last - first > 1_000_000) {
            return self.fail(location, "special-token range is too large");
        }
        var id = first;
        while (id <= last) : (id += 1) {
            result.token_ids.append(self.arena, @intCast(id)) catch return error.OutOfMemory;
        }
    }

    /// Whether `node` matches any text: an any-text regex, possibly behind terminal names.
    fn is_any_text(self: *const LarkCompiler, node: *const LarkNode, visiting: *std.StringHashMap(void)) bool {
        switch (node.kind) {
            .Regex => {
                var pattern: std.ArrayList(u8) = .empty;
                for (node.text) |c| {
                    if (c != ' ' and c != '\t' and c != '\r') {
                        pattern.append(self.arena, c) catch return false;
                    }
                }
                for (node.flags) |flag| {
                    if (flag != 'i' and flag != 's' and flag != 'u') return false;
                }
                if (std.mem.indexOfScalar(u8, node.flags, 's') != null) {
                    return std.mem.eql(u8, pattern.items, ".*");
                }
                const any_text_patterns = [_][]const u8{
                    "(.|\\n)*",
                    "(\\n|.)*",
                    "(?s:.*)",
                    "(?:.|\\n)*",
                    "(?:\\n|.)*",
                    "[\\s\\S]*",
                };
                for (any_text_patterns) |candidate| {
                    if (std.mem.eql(u8, pattern.items, candidate)) return true;
                }
                return false;
            },
            .Sequence => {
                if (node.children.items.len == 1) {
                    return self.is_any_text(&node.children.items[0], visiting);
                }
                return false;
            },
            .Name => {
                const index = self.definition_index(node.text) orelse return false;
                const entry = visiting.getOrPut(node.text) catch return false;
                if (entry.found_existing) return false;
                const result = self.is_any_text(&self.document.definitions.items[index].body, visiting);
                _ = visiting.remove(node.text);
                return result;
            },
            else => return false,
        }
    }

    fn extract_lazy_trigger(self: *const LarkCompiler, definition: *const LarkDefinition) LarkError!?LarkTrigger {
        const marker = definition.stop orelse definition.suffix;
        if (marker) |*m| {
            const is_fixed_string = m.kind == .String and m.flags.len == 0;
            var visiting = std.StringHashMap(void).init(self.arena);
            defer visiting.deinit();
            if (!is_fixed_string or !self.is_any_text(&definition.body, &visiting)) {
                return null;
            }
            return .{ .string = m.text };
        }
        if (!definition.lazy) {
            return null;
        }
        const regex_trigger = extract_lazy_regex_trigger(self.arena, unwrap_single(&definition.body));
        if (regex_trigger) |trigger| {
            return trigger;
        }
        const body = &definition.body;
        var visiting = std.StringHashMap(void).init(self.arena);
        defer visiting.deinit();
        if (body.kind != .Sequence or body.children.items.len != 2 or
            !self.is_any_text(&body.children.items[0], &visiting))
        {
            return null;
        }
        const trigger = &body.children.items[1];
        if (trigger.kind == .String and trigger.text.len != 0 and trigger.flags.len == 0) {
            return .{ .string = trigger.text };
        }
        if (trigger.kind == .SpecialToken) {
            const token_set = try self.resolve_special_token(trigger.text, trigger.location);
            if (token_set.excluded) {
                return self.fail(trigger.location, "lazy special-token trigger cannot be negated");
            }
            return .{ .token = token_set.token_ids.items };
        }
        return null;
    }

    fn compile_lazy_rule(self: *LarkCompiler, definition: *const LarkDefinition) LarkError!i32 {
        const rule_id = self.rule_ids.get(definition.name).?;
        const marker: ?*const LarkNode = if (definition.suffix) |*s| s else if (definition.stop) |*s| s else null;
        var fixed_marker_length: ?usize = null;
        if (marker != null and marker.?.kind == .String) {
            fixed_marker_length = marker.?.text.len;
        }
        const hidden_bytes: i32 = if (fixed_marker_length) |length| @intCast(length) else 1;
        var suffix_stop_info = SuffixStopInfo.default();
        if (definition.suffix != null) {
            suffix_stop_info.hidden_suffix_bytes = hidden_bytes;
        } else if (definition.stop != null) {
            suffix_stop_info.hidden_stop_bytes = hidden_bytes;
        }
        if (definition.stop_capture_name) |stop_capture_name| {
            suffix_stop_info.stop_capture_name = stop_capture_name;
        }
        const body = unwrap_single(&definition.body);
        if (marker == null and body.kind == .Regex and
            extract_lazy_regex_trigger(self.arena, body) != null)
        {
            return self.fail(
                definition.location,
                "lazy regex suffix is only supported on a head used by dynamic dispatch",
            );
        }
        var patterns: ?BodyMarker = null;
        const needs_helpers = fixed_marker_length == null or
            definition.max_tokens != null or definition.max_chars != null;
        if (marker != null and needs_helpers) {
            var visiting = std.StringHashMap(void).init(self.arena);
            defer visiting.deinit();
            const body_pattern = try self.terminal_node_to_regex(&definition.body, &visiting);
            const marker_pattern = try self.terminal_node_to_regex(marker.?, &visiting);
            const body_helper_expr = self.builder.add_regex(body_pattern, false) catch return error.OutOfMemory;
            const body_hint = std.fmt.allocPrint(self.arena, "{s}_stop_body", .{definition.name}) catch return error.OutOfMemory;
            suffix_stop_info.body_rule_id = self.builder.add_rule_with_hint(body_hint, body_helper_expr) catch return error.OutOfMemory;
            const marker_helper_expr = self.builder.add_regex(marker_pattern, false) catch return error.OutOfMemory;
            const marker_hint = std.fmt.allocPrint(self.arena, "{s}_stop_marker", .{definition.name}) catch return error.OutOfMemory;
            suffix_stop_info.marker_rule_id = self.builder.add_rule_with_hint(marker_hint, marker_helper_expr) catch return error.OutOfMemory;
            patterns = .{ .body = body_pattern, .marker = marker_pattern };
        }
        self.builder.update_suffix_stop_info(rule_id, suffix_stop_info) catch return error.OutOfMemory;
        const trigger = try self.extract_lazy_trigger(definition);
        if (trigger == null) {
            // General committed-shortest lazy rule: compiled like a terminal (no skip
            // insertion); the terminal-like requirement is validated after grammar
            // optimization. suffix="s" and stop="s" both desugar to the lazy rule over
            // (body "s"); their only difference is capture scope, represented by the
            // metadata set above.
            self.builder.update_lazy(rule_id, true);
            const m = marker orelse {
                return self.compile_node(&definition.body, definition.name, true, true);
            };
            var visiting = std.StringHashMap(void).init(self.arena);
            defer visiting.deinit();
            const both: BodyMarker = patterns orelse .{
                .body = try self.terminal_node_to_regex(&definition.body, &visiting),
                .marker = try self.terminal_node_to_regex(m, &visiting),
            };
            const combined = std.fmt.allocPrint(self.arena, "(?:{s})(?:{s})", .{ both.body, both.marker }) catch return error.OutOfMemory;
            return self.builder.add_regex(combined, false) catch return error.OutOfMemory;
        }
        const empty_expr = self.builder.add_empty_str() catch return error.OutOfMemory;
        const empty_rule = self.builder.add_rule_with_hint("lark_lazy_end", empty_expr) catch return error.OutOfMemory;
        const result: i32 = trig_blk: {
            switch (trigger.?) {
            .string => |tag| {
                var td = TagDispatch.empty();
                defer td.deinit(self.arena);
                td.tag_rule_pairs.append(self.arena, .{ .tag = @constCast(tag), .rule_id = empty_rule }) catch return error.OutOfMemory;
                td.loop_after_dispatch = false;
                break :trig_blk self.builder.add_tag_dispatch(&td) catch return error.OutOfMemory;
            },
            .token => |token_ids| {
                var ttd = TokenTagDispatch.empty();
                defer ttd.deinit(self.arena);
                for (token_ids) |token_id| {
                    ttd.trigger_rule_pairs.append(self.arena, .{ .token_id = token_id, .rule_id = empty_rule }) catch return error.OutOfMemory;
                }
                ttd.loop_after_dispatch = false;
                break :trig_blk self.builder.add_token_tag_dispatch(&ttd) catch return error.OutOfMemory;
            },
            }
        };
        return self.append_skip(result);
    }

    /// Lowers `start: (tool_a | tool_b)* tail` with lazy tool heads and an any-text tail
    /// into a looping tag dispatch, or returns null if `start` does not have that shape.
    fn compile_dynamic_start(self: *LarkCompiler, start: *const LarkDefinition) LarkError!?i32 {
        const document = self.document;
        var unused_rules = std.StringHashMap(void).init(self.arena);
        const start_elements = flatten_sequence(self.arena, &start.body) catch return error.OutOfMemory;
        if (start_elements.items.len != 2) {
            return null;
        }
        const loop_element = &start_elements.items[0];
        const tail_element = &start_elements.items[1];
        const loop_node = unwrap_single(loop_element);
        if (loop_node.kind != .Repeat or loop_node.min_repeat != 0 or loop_node.max_repeat != -1) {
            return null;
        }
        const loop_body = unwrap_single(&loop_node.children.items[0]);
        var tool_names: std.ArrayList([]const u8) = .empty;
        switch (loop_body.kind) {
            .Choice => {
                for (loop_body.children.items) |*alternative| {
                    const name = unwrap_single(alternative);
                    if (name.kind != .Name) {
                        return null;
                    }
                    tool_names.append(self.arena, name.text) catch return error.OutOfMemory;
                }
            },
            .Name => tool_names.append(self.arena, loop_body.text) catch return error.OutOfMemory,
            else => return null,
        }

        const tail_name = unwrap_single(tail_element);
        if (tail_name.kind != .Name) {
            return null;
        }
        {
            var visiting = std.StringHashMap(void).init(self.arena);
            defer visiting.deinit();
            const tail_index = self.definition_index(tail_name.text) orelse return null;
            if (!self.is_any_text(&document.definitions.items[tail_index].body, &visiting)) {
                return null;
            }
        }
        unused_rules.put(tail_name.text, {}) catch return error.OutOfMemory;

        const Alternative = struct {
            trigger: LarkTrigger,
            remainder: LarkNode,
            marker_event_rule_id: i32,
        };
        var alternatives: std.ArrayList(Alternative) = .empty;
        for (tool_names.items) |tool_name| {
            const tool_index = self.definition_index(tool_name) orelse return null;
            const tool = &document.definitions.items[tool_index];
            if (tool.is_terminal) return null;
            unused_rules.put(tool_name, {}) catch return error.OutOfMemory;
            const tool_elements = flatten_sequence(self.arena, &tool.body) catch return error.OutOfMemory;
            if (tool_elements.items.len == 0) {
                return null;
            }

            var trigger: ?LarkTrigger = null;
            var marker_event_rule_id: i32 = -1;
            var remainder_begin: usize = 0;
            const first = unwrap_single(&tool_elements.items[0]);
            var head: ?*const LarkDefinition = null;
            if (first.kind == .Name) {
                if (self.definition_index(first.text)) |head_index| {
                    head = &document.definitions.items[head_index];
                }
            }
            if (head) |h| {
                trigger = try self.extract_lazy_trigger(h);
                if (trigger != null) {
                    unused_rules.put(first.text, {}) catch return error.OutOfMemory;
                    remainder_begin = 1;
                }
                // A stop marker or stop capture implies a fixed-string trigger.
                const has_stop = h.stop != null or h.stop_capture_name != null;
                if (has_stop) {
                    if (trigger) |t| {
                        if (t == .string) {
                            // The dispatch FSM consumes the trigger before entering the
                            // remainder. Insert a zero-width rule there so capture
                            // materialization can recover that preceding marker without
                            // giving up the deterministic dispatch path.
                            const event_expr = self.builder.add_empty_str() catch return error.OutOfMemory;
                            const marker_hint = std.fmt.allocPrint(self.arena, "{s}_dynamic_marker", .{h.name}) catch return error.OutOfMemory;
                            marker_event_rule_id = self.builder.add_rule_with_hint(marker_hint, event_expr) catch return error.OutOfMemory;
                            var marker_bytes: std.ArrayList(i32) = .empty;
                            for (t.string) |byte| {
                                marker_bytes.append(self.arena, byte) catch return error.OutOfMemory;
                            }
                            const marker_expr = self.builder.add_byte_string_bytes(marker_bytes.items) catch return error.OutOfMemory;
                            const marker_text_hint = std.fmt.allocPrint(self.arena, "{s}_dynamic_marker_text", .{h.name}) catch return error.OutOfMemory;
                            const marker_rule_id = self.builder.add_rule_with_hint(marker_text_hint, marker_expr) catch return error.OutOfMemory;
                            var suffix_stop_info = SuffixStopInfo.default();
                            suffix_stop_info.body_rule_id = marker_event_rule_id;
                            suffix_stop_info.marker_rule_id = marker_rule_id;
                            suffix_stop_info.hidden_stop_bytes = if (h.stop != null) @intCast(t.string.len) else 0;
                            suffix_stop_info.hidden_suffix_bytes = if (h.stop != null) 0 else @intCast(t.string.len);
                            suffix_stop_info.stop_capture_name = h.stop_capture_name orelse "";
                            self.builder.update_suffix_stop_info(marker_event_rule_id, suffix_stop_info) catch return error.OutOfMemory;
                        }
                    }
                }
            }
            if (trigger == null and tool_elements.items.len >= 2) {
                var visiting = std.StringHashMap(void).init(self.arena);
                defer visiting.deinit();
                if (self.is_any_text(&tool_elements.items[0], &visiting)) {
                    const token_trigger = unwrap_single(&tool_elements.items[1]);
                    if (token_trigger.kind == .SpecialToken) {
                        const token_set = try self.resolve_special_token(token_trigger.text, token_trigger.location);
                        if (token_set.excluded) {
                            return self.fail(token_trigger.location, "dynamic special-token trigger cannot be negated");
                        }
                        trigger = .{ .token = token_set.token_ids.items };
                        remainder_begin = 2;
                    }
                }
            }
            const final_trigger = trigger orelse return null;
            const remainder = LarkNode.with_children(
                .Sequence,
                tool.location,
                tool_elements.items[remainder_begin..],
                self.arena,
            ) catch return error.OutOfMemory;
            alternatives.append(self.arena, .{
                .trigger = final_trigger,
                .remainder = remainder,
                .marker_event_rule_id = marker_event_rule_id,
            }) catch return error.OutOfMemory;
        }

        if (alternatives.items.len == 0) {
            return null;
        }
        const is_string_level = alternatives.items[0].trigger == .string;
        for (alternatives.items) |alternative| {
            if ((alternative.trigger == .string) != is_string_level) {
                return self.fail(start.location, "a dynamic Lark start rule cannot mix string and token triggers");
            }
        }

        // Group alternatives by trigger string or trigger token, in order of first appearance.
        const TriggerContext = struct {
            pub fn hash(_: @This(), key: LarkTrigger) u64 {
                var hasher = std.hash.Wyhash.init(0);
                key.hash(&hasher);
                return hasher.final();
            }

            pub fn eql(_: @This(), a: LarkTrigger, b: LarkTrigger) bool {
                return a.eql(b);
            }
        };
        var groups: std.ArrayList(struct { trigger: LarkTrigger, indices: std.ArrayList(usize) }) = .empty;
        var group_by_trigger = std.HashMap(LarkTrigger, usize, TriggerContext, 80).init(self.arena);
        for (alternatives.items, 0..) |alternative, index| {
            var keys: std.ArrayList(LarkTrigger) = .empty;
            switch (alternative.trigger) {
                .string => keys.append(self.arena, alternative.trigger) catch return error.OutOfMemory,
                .token => |token_ids| {
                    for (token_ids) |token_id| {
                        const single = self.arena.alloc(i32, 1) catch return error.OutOfMemory;
                        single[0] = token_id;
                        keys.append(self.arena, .{ .token = single }) catch return error.OutOfMemory;
                    }
                },
            }
            for (keys.items) |key| {
                const entry = group_by_trigger.getOrPut(key) catch return error.OutOfMemory;
                if (!entry.found_existing) {
                    const indices: std.ArrayList(usize) = .empty;
                    groups.append(self.arena, .{ .trigger = key, .indices = indices }) catch return error.OutOfMemory;
                    entry.value_ptr.* = groups.items.len - 1;
                }
                groups.items[entry.value_ptr.*].indices.append(self.arena, index) catch return error.OutOfMemory;
            }
        }

        const body_hint: []const u8 = if (is_string_level) "lark_dynamic_body" else "lark_dynamic_token_body";
        var tag_rule_pairs: std.ArrayList(struct { tag: []const u8, rule_id: i32 }) = .empty;
        var trigger_rule_pairs: std.ArrayList(struct { trigger: i32, rule_id: i32 }) = .empty;
        for (groups.items) |*group| {
            var remainder_choices: std.ArrayList(i32) = .empty;
            for (group.indices.items) |index| {
                const alternative = &alternatives.items[index];
                var remainder_expr = try self.compile_node(&alternative.remainder, body_hint, false, true);
                if (alternative.marker_event_rule_id >= 0) {
                    const marker_event = self.builder.add_rule_ref(alternative.marker_event_rule_id) catch return error.OutOfMemory;
                    remainder_expr = self.builder.add_sequence(&.{ marker_event, remainder_expr }) catch return error.OutOfMemory;
                }
                remainder_choices.append(self.arena, remainder_expr) catch return error.OutOfMemory;
            }
            const body = if (remainder_choices.items.len == 1)
                remainder_choices.items[0]
            else
                self.builder.add_choices(remainder_choices.items) catch return error.OutOfMemory;
            const body_rule = self.builder.add_rule_with_hint(body_hint, body) catch return error.OutOfMemory;
            switch (group.trigger) {
                .string => |trigger_str| tag_rule_pairs.append(self.arena, .{ .tag = trigger_str, .rule_id = body_rule }) catch return error.OutOfMemory,
                .token => |token_ids| trigger_rule_pairs.append(self.arena, .{ .trigger = token_ids[0], .rule_id = body_rule }) catch return error.OutOfMemory,
            }
        }
        self.dynamic_unused_rules = unused_rules;
        if (is_string_level) {
            var td = TagDispatch.empty();
            defer td.deinit(self.arena);
            for (tag_rule_pairs.items) |pair| {
                td.tag_rule_pairs.append(self.arena, .{ .tag = @constCast(pair.tag), .rule_id = pair.rule_id }) catch return error.OutOfMemory;
            }
            td.loop_after_dispatch = true;
            return self.builder.add_tag_dispatch(&td) catch return error.OutOfMemory;
        }
        var ttd = TokenTagDispatch.empty();
        defer ttd.deinit(self.arena);
        for (trigger_rule_pairs.items) |pair| {
            ttd.trigger_rule_pairs.append(self.arena, .{ .token_id = pair.trigger, .rule_id = pair.rule_id }) catch return error.OutOfMemory;
        }
        ttd.loop_after_dispatch = true;
        return self.builder.add_token_tag_dispatch(&ttd) catch return error.OutOfMemory;
    }
};

/// The regular expressions of the supported `%import common.NAME` terminals.
fn common_regex(path: []const u8) ?[]const u8 {
    const table = [_]struct { path: []const u8, pattern: []const u8 }{
        .{ .path = "common.DIGIT", .pattern = "[0-9]" },
        .{ .path = "common.HEXDIGIT", .pattern = "[a-fA-F0-9]" },
        .{ .path = "common.INT", .pattern = "[0-9]+" },
        .{ .path = "common.SIGNED_INT", .pattern = "(\\+|-)?[0-9]+" },
        .{ .path = "common.DECIMAL", .pattern = "([0-9]+\\.[0-9]*)|(\\.[0-9]+)" },
        .{ .path = "common._EXP", .pattern = "[eE](\\+|-)?[0-9]+" },
        .{ .path = "common.FLOAT", .pattern = "([0-9]+\\.[0-9]*|\\.[0-9]+)([eE](\\+|-)?[0-9]+)?|[0-9]+[eE](\\+|-)?[0-9]+" },
        .{ .path = "common.SIGNED_FLOAT", .pattern = "(\\+|-)?(([0-9]+\\.[0-9]*|\\.[0-9]+)([eE](\\+|-)?[0-9]+)?|[0-9]+[eE](\\+|-)?[0-9]+)" },
        .{ .path = "common.NUMBER", .pattern = "([0-9]+)|([0-9]+\\.[0-9]*|\\.[0-9]+)([eE](\\+|-)?[0-9]+)?|[0-9]+[eE](\\+|-)?[0-9]+" },
        .{ .path = "common.SIGNED_NUMBER", .pattern = "(\\+|-)?(([0-9]+)|([0-9]+\\.[0-9]*|\\.[0-9]+)([eE](\\+|-)?[0-9]+)?|[0-9]+[eE](\\+|-)?[0-9]+)" },
        .{ .path = "common.ESCAPED_STRING", .pattern = "\\\"([^\\\"\\\\]|\\\\.)*\\\"" },
        .{ .path = "common.LCASE_LETTER", .pattern = "[a-z]" },
        .{ .path = "common.UCASE_LETTER", .pattern = "[A-Z]" },
        .{ .path = "common.LETTER", .pattern = "[A-Za-z]" },
        .{ .path = "common.WORD", .pattern = "[A-Za-z]+" },
        .{ .path = "common.CNAME", .pattern = "[_A-Za-z][_A-Za-z0-9]*" },
        .{ .path = "common.WS_INLINE", .pattern = "[ \\t]+" },
        .{ .path = "common.WS", .pattern = "[ \\t\\f\\r\\n]+" },
        .{ .path = "common.CR", .pattern = "\\r" },
        .{ .path = "common.LF", .pattern = "\\n" },
        .{ .path = "common.NEWLINE", .pattern = "(\\r?\\n)+" },
        .{ .path = "common.SH_COMMENT", .pattern = "#[^\\n]*" },
        .{ .path = "common.CPP_COMMENT", .pattern = "//[^\\n]*" },
        .{ .path = "common.C_COMMENT", .pattern = "\\/\\*[^*]*\\*+(?:[^/*][^*]*\\*+)*\\/" },
        .{ .path = "common.SQL_COMMENT", .pattern = "--[^\\n]*" },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, entry.path, path)) return entry.pattern;
    }
    return null;
}

/// Trims C-locale whitespace from both ends.
fn trim_c_space(value: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = value.len;
    while (start < end and lark_lexer_mod.is_c_space(value[start])) start += 1;
    while (end > start and lark_lexer_mod.is_c_space(value[end - 1])) end -= 1;
    return value[start..end];
}

/// The prefix of `text` before its first NUL (what a C string view of it contains).
fn c_str(text: []const u8) []const u8 {
    return text[0 .. std.mem.indexOfScalar(u8, text, 0) orelse text.len];
}

/// The single codepoint of `text`, or null if it does not hold exactly one.
fn single_codepoint(text: []const u8) ?u21 {
    const len = std.unicode.utf8ByteSequenceLength(text[0]) catch return null;
    if (len != text.len) return null;
    return std.unicode.utf8Decode(text) catch null;
}

/// Decodes a regex made only of literal characters and escapes into the bytes it matches,
/// or null if it uses any other regex construct.
fn parse_fixed_regex_literal(allocator: Allocator, pattern: []const u8) ?std.ArrayList(u8) {
    const bytes = pattern;
    var result: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < bytes.len) {
        const c = bytes[i];
        i += 1;
        if (c != '\\') {
            if (std.mem.indexOfScalar(u8, ".^$*+?()[]{}|", c) != null) return null;
            result.append(allocator, c) catch return null;
            continue;
        }
        if (i >= bytes.len) return null;
        const escaped = bytes[i];
        i += 1;
        switch (escaped) {
            'n' => result.append(allocator, '\n') catch return null,
            'r' => result.append(allocator, '\r') catch return null,
            't' => result.append(allocator, '\t') catch return null,
            'f' => result.append(allocator, 0x0C) catch return null,
            'v' => result.append(allocator, 0x0B) catch return null,
            '0' => result.append(allocator, 0) catch return null,
            '^', '$', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '\\', '/', '-' => result.append(allocator, escaped) catch return null,
            'x', 'u' => {
                var codepoint: u32 = 0;
                if (escaped == 'u' and i < bytes.len and bytes[i] == '{') {
                    i += 1;
                    var digit_count: usize = 0;
                    while (i < bytes.len and support.encoding.hex_char_to_int(bytes[i]) != null) {
                        if (digit_count == 6) break;
                        codepoint = codepoint * 16 + support.encoding.hex_char_to_int(bytes[i]).?;
                        i += 1;
                        digit_count += 1;
                    }
                    if (digit_count == 0 or i >= bytes.len or bytes[i] != '}') return null;
                    i += 1;
                } else {
                    const digit_count: usize = if (escaped == 'x') 2 else 4;
                    var remaining_digits: usize = 0;
                    while (remaining_digits < digit_count) : (remaining_digits += 1) {
                        if (i >= bytes.len) return null;
                        const value = support.encoding.hex_char_to_int(bytes[i]) orelse return null;
                        codepoint = codepoint * 16 + value;
                        i += 1;
                    }
                }
                var buf: [4]u8 = undefined;
                const cp: u21 = std.math.cast(u21, codepoint) orelse return null;
                const len = std.unicode.utf8Encode(cp, &buf) catch return null;
                result.appendSlice(allocator, buf[0..len]) catch return null;
            },
            else => return null,
        }
    }
    return result;
}

/// Escapes a literal string so that a regex matches exactly it.
fn escape_regex_literal(allocator: Allocator, value: []const u8) Allocator.Error![]u8 {
    var result: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < value.len) {
        const len = std.unicode.utf8ByteSequenceLength(value[i]) catch 1;
        if (i + len > value.len) {
            result.append(allocator, value[i]) catch return error.OutOfMemory;
            i += 1;
            continue;
        }
        const character = std.unicode.utf8Decode(value[i .. i + len]) catch {
            result.append(allocator, value[i]) catch return error.OutOfMemory;
            i += 1;
            continue;
        };
        i += len;
        switch (character) {
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            else => {
                const cp: u32 = character;
                if (cp <= 0x1F or cp == 0x7F) {
                    try result.appendSlice(allocator, std.fmt.allocPrint(allocator, "\\x{X:0>2}", .{cp}) catch return error.OutOfMemory);
                } else {
                    if (std.mem.indexOfScalar(u8, "\\.^$|()[]{}*+?", @as(u8, @intCast(character))) != null) {
                        try result.append(allocator, '\\');
                    }
                    var buf: [4]u8 = undefined;
                    const elen = std.unicode.utf8Encode(character, &buf) catch unreachable;
                    try result.appendSlice(allocator, buf[0..elen]);
                }
            },
        }
    }
    return result.toOwnedSlice(allocator);
}

/// Unwraps single-element sequences.
fn unwrap_single(node_in: *const LarkNode) *const LarkNode {
    var node = node_in;
    while (node.kind == .Sequence and node.children.items.len == 1) {
        node = &node.children.items[0];
    }
    return node;
}

/// The elements of a sequence, or the node itself (Rust clones; here the elements are
/// copied by value into an arena list — nodes are small and reference arena strings).
fn flatten_sequence(allocator: Allocator, node: *const LarkNode) Allocator.Error!std.ArrayList(LarkNode) {
    var out: std.ArrayList(LarkNode) = .empty;
    if (node.kind == .Sequence) {
        try out.appendSlice(allocator, node.children.items);
        return out;
    }
    try out.append(allocator, node.*);
    return out;
}

/// The trigger of a lazy head written as one regex `<any-text prefix><fixed literal>`.
fn extract_lazy_regex_trigger(allocator: Allocator, node: *const LarkNode) ?LarkTrigger {
    if (node.kind != .Regex) return null;
    for (node.flags) |flag| {
        if (flag == 'i') return null;
        if (flag != 's' and flag != 'u') return null;
    }
    const prefixes: []const []const u8 = if (std.mem.indexOfScalar(u8, node.flags, 's') != null)
        &.{".*"}
    else
        &.{ "(.|\\n)*", "(\\n|.)*", "(?:.|\\n)*", "(?:\\n|.)*", "[\\s\\S]*", "(?s:.*)" };
    for (prefixes) |prefix| {
        if (!std.mem.startsWith(u8, node.text, prefix)) continue;
        const rest = node.text[prefix.len..];
        if (rest.len == 0) continue;
        const trigger = parse_fixed_regex_literal(allocator, rest) orelse continue;
        if (trigger.items.len == 0) continue;
        return .{ .string = trigger.items };
    }
    return null;
}

fn parse_token_id(value_in: []const u8) ?i64 {
    const value = trim_c_space(value_in);
    return std.fmt.parseInt(i64, value, 10) catch null;
}

fn dedup_i32(list: *std.ArrayList(i32)) void {
    if (list.items.len <= 1) return;
    var write: usize = 1;
    for (list.items[1..]) |item| {
        if (item != list.items[write - 1]) {
            list.items[write] = item;
            write += 1;
        }
    }
    list.shrinkRetainingCapacity(write);
}

fn sorted_object_keys(allocator: Allocator, object: *std.json.ObjectMap) Allocator.Error!std.ArrayList([]const u8) {
    var keys: std.ArrayList([]const u8) = .empty;
    var it = object.iterator();
    while (it.next()) |entry| try keys.append(allocator, entry.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return keys;
}

fn append_class_character(result: *std.ArrayList(u8), allocator: Allocator, character: u21) Allocator.Error!void {
    const c: u8 = @intCast(character);
    if (std.mem.indexOfScalar(u8, "\\]-^", c) != null) {
        try result.append(allocator, '\\');
    }
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(character, &buf) catch unreachable;
    try result.appendSlice(allocator, buf[0..len]);
}
