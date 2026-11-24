//! Lowers Lark syntax and parsed `LarkDocument`s into a normalized BNF `Grammar`
//! (`lark_compiler.rs` + `lark_converter.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const Diagnostic = @import("../../Diagnostic.zig").Diagnostic;
const fsm_mod = @import("../../fsm.zig");
const functor = @import("../../functor.zig");
const grammar_mod = @import("../../grammar.zig");
const support = @import("../../support.zig");
const TokenizerInfo = @import("../../tokenizer.zig").TokenizerInfo;
const json_schema = @import("../json_schema/converter.zig");
const regex_mod = @import("../regex.zig");
const ast = @import("ast.zig");
const lexer_mod = @import("lexer.zig");
const parser_mod = @import("parser.zig");

const CharacterClassElement = grammar_mod.CharacterClassElement;
const Grammar = grammar_mod.Grammar;
const GrammarBuilder = grammar_mod.GrammarBuilder;
const SuffixStopInfo = grammar_mod.SuffixStopInfo;
const TagDispatch = grammar_mod.TagDispatch;
const TokenTagDispatch = grammar_mod.TokenTagDispatch;

const LarkDefinition = ast.LarkDefinition;
const LarkDocument = ast.LarkDocument;
const LarkError = ast.LarkError;
const LarkLocation = ast.LarkLocation;
const LarkNode = ast.LarkNode;
const LarkSpecialTokenSet = ast.LarkSpecialTokenSet;
const LarkTrigger = ast.LarkTrigger;
const NamedGrammar = ast.NamedGrammar;
const NamedGrammarRegistry = ast.NamedGrammarRegistry;

const log = std.log.scoped(.xgrammar);

pub const BodyMarker = struct {
    body: []u8,
    marker: []u8,
};

/// Constructs a normalized BNF `Grammar` from Lark syntax. The root rule must be named `start`.
///
/// `tokenizer_info` (optional) resolves named special tokens (`<|...|>`) and the `<[*]>` wildcard.
/// `named_grammars` are grammar objects or Lark sources that can be referenced with `@name`.
/// `diag` (optional) receives failure details allocated from `gpa`.
pub fn fromLark(
    gpa: Allocator,
    lark_str: []const u8,
    tokenizer_info: ?*const TokenizerInfo,
    named_grammars: []const NamedGrammar,
    diag: ?*Diagnostic,
) LarkError!Grammar {
    var registry = NamedGrammarRegistry.init(gpa);
    defer registry.deinit();
    for (named_grammars) |*named_grammar| {
        const name = named_grammar.name();
        if (name.len == 0) {
            return ast.failMessage(gpa, diag, "Named grammar names must not be empty");
        }
        for (name) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') {
                return ast.failMessageFmt(
                    gpa,
                    diag,
                    "Invalid named grammar name '{s}': names may contain only letters, digits, underscores, and hyphens",
                    .{name},
                );
            }
        }
        const entry = try registry.inputs.getOrPut(gpa, name);
        if (entry.found_existing) {
            return ast.failMessageFmt(gpa, diag, "Duplicate named grammar '{s}'", .{name});
        }
        entry.value_ptr.* = named_grammar;
    }
    var document = try parser_mod.parse(gpa, lark_str, diag);
    return LarkCompiler.compile(gpa, lark_str, &document, tokenizer_info, &registry, diag);
}

/// Compiles one Lark document (top-level source, inline `%lark` block, or named Lark source)
/// into a normalized `Grammar` rooted at its `start` rule.
pub const LarkCompiler = struct {
    gpa: Allocator,
    diag: ?*Diagnostic,
    /// Scratch arena for hash maps, regex rewrites, and intermediate buffers.
    arena: Allocator,
    source: []const u8,
    document: *LarkDocument,
    tokenizer_info: ?*const TokenizerInfo,
    named_grammars: *NamedGrammarRegistry,
    builder: GrammarBuilder,
    definition_by_name: std.StringHashMapUnmanaged(usize) = .empty,
    rule_ids: std.StringHashMapUnmanaged(i32) = .empty,
    named_grammar_roots: std.StringHashMapUnmanaged(i32) = .empty,
    skip_rule_id: ?i32 = null,
    allow_initial_skip: bool = false,
    dynamic_unused_rules: std.StringHashMapUnmanaged(void) = .empty,

    /// Compiles `document` (parsed from `source`) into a normalized `Grammar`. Consumes `document`.
    pub fn compile(
        gpa: Allocator,
        source: []const u8,
        document: *LarkDocument,
        tokenizer_info: ?*const TokenizerInfo,
        named_grammars: *NamedGrammarRegistry,
        diag: ?*Diagnostic,
    ) LarkError!Grammar {
        defer document.deinit();

        for (document.imports.items) |*import| {
            const pattern = commonRegex(import.path) orelse {
                return ast.failLocatedFmt(
                    gpa,
                    diag,
                    source,
                    import.location,
                    "unknown common import '{s}'",
                    .{import.path},
                );
            };
            const regex = LarkNode.withText(.Regex, import.location, pattern);
            try document.definitions.append(document.allocator(), LarkDefinition.init(
                import.local_name,
                true,
                regex,
                import.location,
            ));
        }

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();

        var compiler = LarkCompiler{
            .gpa = gpa,
            .diag = diag,
            .arena = arena.allocator(),
            .source = source,
            .document = document,
            .tokenizer_info = tokenizer_info,
            .named_grammars = named_grammars,
            .builder = try GrammarBuilder.init(gpa),
        };
        defer compiler.builder.deinit();

        return compiler.compileDocument();
    }

    fn fail(self: *const LarkCompiler, location: LarkLocation, message: []const u8) LarkError {
        return ast.failLocated(self.gpa, self.diag, self.source, location, message);
    }

    fn failFmt(self: *const LarkCompiler, location: LarkLocation, comptime fmt: []const u8, args: anytype) LarkError {
        return ast.failLocatedFmt(self.gpa, self.diag, self.source, location, fmt, args);
    }

    fn definitionIndex(self: *const LarkCompiler, name: []const u8) ?usize {
        return self.definition_by_name.get(name);
    }

    fn compileDocument(self: *LarkCompiler) LarkError!Grammar {
        try self.parseOptions();
        try self.indexDefinitions();
        try self.validateTerminalCycles();

        const document = self.document;
        for (document.definitions.items) |*definition| {
            const rule_id = try self.builder.addEmptyRule(definition.name);
            try self.rule_ids.put(self.arena, definition.name, rule_id);
        }
        for (document.definitions.items) |*definition| {
            if (!definition.is_terminal) continue;
            const body = try self.compileNode(&definition.body, definition.name, true, true);
            self.builder.updateRuleBody(self.rule_ids.get(definition.name).?, body);
        }

        try self.compileIgnore();

        const start = &document.definitions.items[self.definition_by_name.get("start").?];
        const dynamic_start_body: ?i32 = if (start.temperature != null)
            null
        else
            try self.compileDynamicStart(start);

        for (document.definitions.items) |*definition| {
            if (definition.is_terminal) continue;
            const rule_id = self.rule_ids.get(definition.name).?;
            if (self.dynamic_unused_rules.contains(definition.name)) {
                if (definition.max_tokens) |max_tokens| {
                    return self.fail(max_tokens.key_location, "max_tokens is not supported on rules consumed by dynamic dispatch");
                }
                if (definition.max_chars != null) {
                    log.warn("Ignoring max_chars on rule '{s}' because it is consumed by dynamic dispatch.", .{definition.name});
                }
                if (definition.capture_name) |capture| {
                    return self.fail(capture.value_location, "capture is not supported on rules consumed by dynamic dispatch");
                }
                const empty = try self.builder.addEmptyStr();
                self.builder.updateRuleBody(rule_id, empty);
                continue;
            }
            const body_expr_id: i32 = blk: {
                if (definition.temperature != null) {
                    const body = try self.compileTemperatureRule(definition);
                    if (definition.max_chars) |max_chars| {
                        self.builder.updateMaxChars(rule_id, max_chars);
                    }
                    break :blk body;
                }
                if (std.mem.eql(u8, definition.name, "start")) {
                    const body = if (dynamic_start_body) |dynamic_body| blk2: {
                        if (definition.max_tokens) |max_tokens| {
                            return self.fail(max_tokens.key_location, "max_tokens is not supported on a dynamic dispatch start rule");
                        }
                        if (definition.max_chars != null) {
                            log.warn("Ignoring max_chars on dynamic dispatch start rule '{s}'.", .{definition.name});
                        }
                        break :blk2 dynamic_body;
                    } else try self.compileRuleBody(definition);
                    if (self.skip_rule_id) |skip_rule_id| {
                        if (self.allow_initial_skip) {
                            const skip = try self.builder.addRuleRef(skip_rule_id);
                            break :blk try self.builder.addSequence(&.{ skip, body });
                        }
                    }
                    break :blk body;
                }
                break :blk try self.compileRuleBody(definition);
            };
            self.builder.updateRuleBody(rule_id, body_expr_id);
            if (definition.capture_name) |capture| {
                try self.builder.updateCaptureName(rule_id, capture.name);
            }
            self.builder.updateRuleTemperature(rule_id, definition.temperature);
        }

        var root_rule_id = self.rule_ids.get("start").?;
        if (start.temperature != null) {
            if (self.skip_rule_id) |skip_rule_id| {
                var elements: std.ArrayList(i32) = .empty;
                if (self.allow_initial_skip) {
                    try elements.append(self.arena, try self.builder.addRuleRef(skip_rule_id));
                }
                try elements.append(self.arena, try self.builder.addRuleRef(root_rule_id));
                try elements.append(self.arena, try self.builder.addRuleRef(skip_rule_id));
                const sequence = try self.builder.addSequence(elements.items);
                root_rule_id = try self.builder.addRuleWithHint("start_with_skip", sequence);
            }
        }

        var grammar = try self.builder.intoGrammarWithRootId(root_rule_id);
        defer grammar.deinit();

        var normalized = functor.normalize(self.gpa, &grammar) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.fail(LarkLocation.START, "failed to normalize Lark grammar"),
        };
        defer normalized.deinit();

        return functor.eliminateDeadCode(self.gpa, &normalized) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.fail(LarkLocation.START, "failed to eliminate dead code in Lark grammar"),
        };
    }

    fn compileTemperatureRule(self: *LarkCompiler, definition: *const LarkDefinition) LarkError!i32 {
        const body = unwrapSingle(&definition.body);
        if (body.kind == .Json or body.kind == .NestedLark or body.kind == .GrammarRef) {
            return self.compileNode(body, definition.name, false, false);
        }
        var nested_diag: Diagnostic = .{};
        defer nested_diag.deinit(self.gpa);
        const saved = self.diag;
        self.diag = if (saved != null) &nested_diag else null;
        defer self.diag = saved;

        return self.compileNode(&definition.body, definition.name, true, false) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Lark => {
                if (saved == null) return error.Lark;
                self.diag = saved;
                if (nested_diag.kind == .none) {
                    return self.fail(definition.location, "lark error; temperature is only supported on terminals and subgrammars");
                }
                return self.failFmt(
                    definition.location,
                    "{f}; temperature is only supported on terminals and subgrammars",
                    .{nested_diag},
                );
            },
        };
    }

    /// Compiles an ordinary rule body, applying its token and character budgets.
    fn compileRuleBody(self: *LarkCompiler, definition: *const LarkDefinition) LarkError!i32 {
        const rule_id = self.rule_ids.get(definition.name).?;
        if (definition.max_tokens) |max_tokens| {
            self.builder.updateMaxTokens(rule_id, max_tokens.value);
        }
        if (definition.max_chars) |max_chars| {
            self.builder.updateMaxChars(rule_id, max_chars);
        }
        if (definition.hasLazySemantics()) {
            return self.compileLazyRule(definition);
        }
        return self.compileNode(&definition.body, definition.name, false, true);
    }

    fn parseOptions(self: *LarkCompiler) LarkError!void {
        const document = self.document;
        for (document.options.items) |*option| {
            if (option.value != .object) {
                return self.fail(option.location, "%grammar_options value must be an object");
            }
            var object = option.value.object;
            var keys = try sortedObjectKeys(self.arena, &object);
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
                    return self.failFmt(option.location, "unknown %grammar_options option '{s}'", .{key});
                };
                const flag_value = flag orelse {
                    return self.failFmt(option.location, "{s} must be a boolean", .{key});
                };
                if (std.mem.eql(u8, key, "allow_initial_skip")) {
                    self.allow_initial_skip = self.allow_initial_skip or flag_value;
                } else if (flag_value) {
                    return self.failFmt(option.location, "%grammar_options option '{s}' is not supported", .{key});
                }
            }
        }
    }

    fn indexDefinitions(self: *LarkCompiler) LarkError!void {
        const document = self.document;
        for (document.definitions.items, 0..) |*definition, index| {
            const entry = try self.definition_by_name.getOrPut(self.arena, definition.name);
            if (entry.found_existing) {
                return self.failFmt(definition.location, "duplicate rule or terminal '{s}'", .{definition.name});
            }
            entry.value_ptr.* = index;
        }
        const start_index = self.definitionIndex("start") orelse {
            return self.fail(LarkLocation.START, "no start rule found");
        };
        const start = &document.definitions.items[start_index];
        if (start.is_terminal) {
            return self.fail(start.location, "start must be a rule");
        }
    }

    fn collectReferencedNames(node: *const LarkNode, names: *std.ArrayList([]const u8), allocator: Allocator) Allocator.Error!void {
        if (node.kind == .Name) {
            try names.append(allocator, node.text);
        }
        for (node.children.items) |*child| {
            try collectReferencedNames(child, names, allocator);
        }
    }

    fn validateTerminalCycles(self: *LarkCompiler) LarkError!void {
        var states: std.StringHashMapUnmanaged(i32) = .empty;
        defer states.deinit(self.arena);
        for (self.document.definitions.items) |*definition| {
            if (definition.is_terminal and !states.contains(definition.name)) {
                try self.visitTerminal(definition, &states);
            }
        }
    }

    /// Depth-first visit of terminal references; `states` maps a name to 1 (visiting) or 2 (done).
    fn visitTerminal(self: *const LarkCompiler, definition: *const LarkDefinition, states: *std.StringHashMapUnmanaged(i32)) LarkError!void {
        try states.put(self.arena, definition.name, 1);
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.arena);
        try collectReferencedNames(&definition.body, &names, self.arena);
        for (names.items) |name| {
            const index = self.definitionIndex(name) orelse {
                return self.failFmt(definition.location, "unknown name '{s}'", .{name});
            };
            const referenced = &self.document.definitions.items[index];
            if (!referenced.is_terminal) {
                return self.failFmt(
                    definition.location,
                    "terminal '{s}' cannot reference rule '{s}'",
                    .{ definition.name, name },
                );
            }
            if (states.get(name)) |state| {
                if (state == 1) {
                    return self.failFmt(definition.location, "circular reference in terminal '{s}'", .{name});
                }
            } else {
                try self.visitTerminal(referenced, states);
            }
        }
        try states.put(self.arena, definition.name, 2);
    }

    fn compileIgnore(self: *LarkCompiler) LarkError!void {
        const document = self.document;
        if (document.ignores.items.len == 0) {
            return;
        }
        var ignore_choices: std.ArrayList(i32) = .empty;
        for (document.ignores.items) |*ignore| {
            try ignore_choices.append(self.arena, try self.compileNode(ignore, "lark_ignore", true, true));
        }
        const ignore_body = if (ignore_choices.items.len == 1)
            ignore_choices.items[0]
        else
            try self.builder.addChoices(ignore_choices.items);
        const ignore_item_rule = try self.builder.addRuleWithHint("lark_ignore_item", ignore_body);
        const ignore_repeat = try self.builder.addRepeat(ignore_item_rule, 0, -1);
        self.skip_rule_id = try self.builder.addRuleWithHint("lark_ignore", ignore_repeat);
    }

    /// The characters of a case-insensitive (`"..."i`) literal, which must be ASCII.
    fn caseInsensitiveChars(self: *const LarkCompiler, node: *const LarkNode) LarkError!std.ArrayList(u21) {
        if (!std.mem.eql(u8, node.flags, "i")) {
            return self.failFmt(node.location, "unsupported string literal flags '{s}'", .{node.flags});
        }
        var characters: std.ArrayList(u21) = .empty;
        const text = cStr(node.text);
        var i: usize = 0;
        while (i < text.len) {
            const len = std.unicode.utf8ByteSequenceLength(text[i]) catch break;
            if (i + len > text.len) break;
            const cp = std.unicode.utf8Decode(text[i .. i + len]) catch break;
            try characters.append(self.arena, cp);
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

    fn compileStringLiteral(self: *LarkCompiler, node: *const LarkNode) LarkError!i32 {
        if (node.flags.len == 0) {
            if (node.text.len == 0) {
                return self.builder.addEmptyStr();
            }
            return self.builder.addByteString(node.text);
        }
        var elements: std.ArrayList(i32) = .empty;
        var characters = try self.caseInsensitiveChars(node);
        defer characters.deinit(self.arena);
        for (characters.items) |character| {
            if ((character >= 'a' and character <= 'z') or (character >= 'A' and character <= 'Z')) {
                const lower: i32 = @intCast(std.ascii.toLower(@intCast(character)));
                const upper: i32 = @intCast(std.ascii.toUpper(@intCast(character)));
                try elements.append(self.arena, try self.builder.addCharacterClass(&.{
                    CharacterClassElement.init(lower, lower),
                    CharacterClassElement.init(upper, upper),
                }, false));
            } else {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(character, &buf) catch unreachable;
                try elements.append(self.arena, try self.builder.addByteString(buf[0..len]));
            }
        }
        return switch (elements.items.len) {
            0 => self.builder.addEmptyStr(),
            1 => elements.items[0],
            else => self.builder.addSequence(elements.items),
        };
    }

    /// Validates regex flags, returning `(case_insensitive, dot_all)`.
    fn parseRegexFlags(self: *const LarkCompiler, node: *const LarkNode) LarkError!struct { case_insensitive: bool, dot_all: bool } {
        var case_insensitive = false;
        var dot_all = false;
        for (node.flags) |flag| {
            switch (flag) {
                'i' => case_insensitive = true,
                's' => dot_all = true,
                // XGrammar regular expressions use Unicode codepoint semantics by default.
                'u' => {},
                else => {
                    return self.failFmt(node.location, "regular-expression flag '{c}' is not supported", .{flag});
                },
            }
        }
        return .{ .case_insensitive = case_insensitive, .dot_all = dot_all };
    }

    fn stringLiteralToRegex(self: *const LarkCompiler, node: *const LarkNode) LarkError![]u8 {
        if (node.flags.len == 0) {
            return escapeRegexLiteral(self.arena, node.text);
        }
        var result: std.ArrayList(u8) = .empty;
        var characters = try self.caseInsensitiveChars(node);
        defer characters.deinit(self.arena);
        for (characters.items) |character| {
            if ((character >= 'a' and character <= 'z') or (character >= 'A' and character <= 'Z')) {
                try result.append(self.arena, '[');
                try result.append(self.arena, @intCast(std.ascii.toLower(@intCast(character))));
                try result.append(self.arena, @intCast(std.ascii.toUpper(@intCast(character))));
                try result.append(self.arena, ']');
            } else {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(character, &buf) catch unreachable;
                const escaped = try escapeRegexLiteral(self.arena, buf[0..len]);
                try result.appendSlice(self.arena, escaped);
            }
        }
        return result.toOwnedSlice(self.arena);
    }

    /// The single codepoints of a character range's endpoints.
    fn rangeEndpoints(self: *const LarkCompiler, node: *const LarkNode) LarkError!struct { begin: u21, end: u21 } {
        const begin = singleCodepoint(cStr(node.text));
        const end = singleCodepoint(cStr(node.text2));
        if (begin == null or end == null) {
            return self.fail(node.location, "character range endpoints must be one character");
        }
        if (begin.? > end.?) {
            return self.fail(node.location, "character range start must not exceed end");
        }
        return .{ .begin = begin.?, .end = end.? };
    }

    /// Lowers a terminal expression to a single regular expression (used by suffix and stop).
    fn terminalNodeToRegex(self: *const LarkCompiler, node: *const LarkNode, visiting: *std.StringHashMapUnmanaged(void)) LarkError![]u8 {
        switch (node.kind) {
            .Sequence => {
                var result: std.ArrayList(u8) = .empty;
                for (node.children.items) |*child| {
                    const pattern = try self.terminalNodeToRegex(child, visiting);
                    if (pattern.len != 0) {
                        try result.print(self.arena, "(?:{s})", .{pattern});
                    }
                }
                return result.toOwnedSlice(self.arena);
            },
            .Choice => {
                var joined: std.ArrayList(u8) = .empty;
                for (node.children.items, 0..) |*child, i| {
                    if (i != 0) try joined.append(self.arena, '|');
                    const alternative = try self.terminalNodeToRegex(child, visiting);
                    try joined.appendSlice(self.arena, alternative);
                }
                return std.fmt.allocPrint(self.arena, "(?:{s})", .{joined.items});
            },
            .Repeat => {
                const child = try self.terminalNodeToRegex(&node.children.items[0], visiting);
                if (child.len == 0) {
                    return self.arena.dupe(u8, "");
                }
                const min = node.min_repeat;
                const max = node.max_repeat;
                const quantifier: []const u8 = blk: {
                    if (min == 0 and max == -1) break :blk "*";
                    if (min == 1 and max == -1) break :blk "+";
                    if (min == 0 and max == 1) break :blk "?";
                    if (min == max) break :blk try std.fmt.allocPrint(self.arena, "{{{d}}}", .{min});
                    if (max == -1) break :blk try std.fmt.allocPrint(self.arena, "{{{d},}}", .{min});
                    break :blk try std.fmt.allocPrint(self.arena, "{{{d},{d}}}", .{ min, max });
                };
                return std.fmt.allocPrint(self.arena, "(?:{s}){s}", .{ child, quantifier });
            },
            .String => return self.stringLiteralToRegex(node),
            .Regex => {
                const flags = try self.parseRegexFlags(node);
                if (flags.case_insensitive) {
                    return self.fail(
                        node.location,
                        "regular-expression flag 'i' is not supported with suffix or stop attributes",
                    );
                }
                const pattern = try fsm_mod.rewriteRegexDots(self.arena, node.text, flags.dot_all);
                return std.fmt.allocPrint(self.arena, "(?:{s})", .{pattern});
            },
            .Range => {
                const endpoints = try self.rangeEndpoints(node);
                var result: std.ArrayList(u8) = .empty;
                try result.append(self.arena, '[');
                try appendClassCharacter(&result, self.arena, endpoints.begin);
                try result.append(self.arena, '-');
                try appendClassCharacter(&result, self.arena, endpoints.end);
                try result.append(self.arena, ']');
                return result.toOwnedSlice(self.arena);
            },
            .Name => {
                const index = self.definitionIndex(node.text) orelse {
                    return self.failFmt(node.location, "unknown name '{s}'", .{node.text});
                };
                const definition = &self.document.definitions.items[index];
                if (!definition.is_terminal) {
                    return self.failFmt(node.location, "terminal cannot reference rule '{s}'", .{node.text});
                }
                const entry = try visiting.getOrPut(self.arena, node.text);
                if (entry.found_existing) {
                    return self.failFmt(node.location, "recursive terminal '{s}' is not supported", .{node.text});
                }
                defer _ = visiting.remove(node.text);
                return self.terminalNodeToRegex(&definition.body, visiting);
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

    fn parseStructuredRegexChunks(self: *const LarkCompiler, node: *const LarkNode) LarkError!std.ArrayList([]const u8) {
        const value = support.parseJson(self.arena, node.text) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.failFmt(node.location, "failed to parse %regex: {s}", .{@errorName(e)}),
        };
        if (value != .object) {
            return self.fail(node.location, "%regex value must be an object");
        }
        var object = value.object;
        var keys = try sortedObjectKeys(self.arena, &object);
        defer keys.deinit(self.arena);
        var fields: std.ArrayList(struct { key: []const u8, value: std.json.Value }) = .empty;
        defer fields.deinit(self.arena);
        for (keys.items) |key| {
            if (!std.mem.eql(u8, key, "substring_chunks") and
                !std.mem.eql(u8, key, "substring_chars") and
                !std.mem.eql(u8, key, "substring_words"))
            {
                return self.failFmt(node.location, "unknown field '{s}' in %regex", .{key});
            }
            const field_value = object.get(key).?;
            if (field_value != .null) {
                try fields.append(self.arena, .{ .key = key, .value = field_value });
            }
        }
        if (fields.items.len != 1) {
            return self.fail(node.location, if (fields.items.len == 0)
                "no fields set on %regex"
            else
                "only one field can be set on %regex");
        }
        const field = fields.items[0];
        var chunks: std.ArrayList([]const u8) = .empty;
        if (std.mem.eql(u8, field.key, "substring_words")) {
            return self.fail(node.location, if (field.value == .string)
                "substring_words is not supported yet"
            else
                "substring_words must be a string");
        }
        if (std.mem.eql(u8, field.key, "substring_chars")) {
            if (field.value != .string) {
                return self.fail(node.location, "substring_chars must be a string");
            }
            var i: usize = 0;
            const text = field.value.string;
            while (i < text.len) {
                const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
                const step = if (i + len > text.len) 1 else len;
                try chunks.append(self.arena, text[i .. i + step]);
                i += step;
            }
            return chunks;
        }
        if (field.value != .array) {
            return self.fail(node.location, "substring_chunks must be an array of strings");
        }
        for (field.value.array.items) |chunk| {
            if (chunk != .string) {
                return self.fail(node.location, "substring_chunks must be an array of strings");
            }
            try chunks.append(self.arena, chunk.string);
        }
        return chunks;
    }

    fn compileStructuredRegex(self: *LarkCompiler, node: *const LarkNode, rule_hint: []const u8) LarkError!i32 {
        const chunks = try self.parseStructuredRegexChunks(node);
        // A substring expr can only be the body of a rule, so wrap it and return a reference.
        const substring_expr_id = try self.builder.addSubstring(chunks.items);
        const hint = try std.fmt.allocPrint(self.arena, "{s}_substring", .{rule_hint});
        const rule_id = try self.builder.addRuleWithHint(hint, substring_expr_id);
        return self.builder.addRuleRef(rule_id);
    }

    /// Makes the named grammar `name` available in the registry, compiling it if it is a
    /// Lark source.
    fn resolveNamedGrammar(self: *LarkCompiler, name: []const u8, location: LarkLocation) LarkError!void {
        const input = self.named_grammars.inputs.get(name) orelse {
            return self.failFmt(location, "unknown named grammar '@{s}'", .{name});
        };
        const named_source = switch (input.*) {
            .grammar => return,
            .lark => |l| l.source,
        };
        if (self.named_grammars.compiled.contains(name)) {
            return;
        }
        for (self.named_grammars.active.items, 0..) |active, cycle_start| {
            if (std.mem.eql(u8, active, name)) {
                var cycle: std.ArrayList(u8) = .empty;
                for (self.named_grammars.active.items[cycle_start..]) |item| {
                    try cycle.print(self.arena, "@{s} -> ", .{item});
                }
                try cycle.print(self.arena, "@{s}", .{name});
                return self.failFmt(location, "circular named grammar reference: {s}", .{cycle.items});
            }
        }

        {
            const active_name = try self.named_grammars.gpa.dupe(u8, name);
            errdefer self.named_grammars.gpa.free(active_name);
            try self.named_grammars.active.append(self.named_grammars.gpa, active_name);
        }
        defer {
            const popped = self.named_grammars.active.pop();
            self.named_grammars.gpa.free(popped.?);
        }

        var nested_diag: Diagnostic = .{};
        defer nested_diag.deinit(self.gpa);
        const nested_diag_ptr: ?*Diagnostic = if (self.diag != null) &nested_diag else null;

        var document = parser_mod.parseNested(self.gpa, named_source, nested_diag_ptr, null) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Lark => {
                if (self.diag == null) return error.Lark;
                if (nested_diag.kind == .none) {
                    return self.failFmt(location, "failed to compile named grammar '@{s}': lark error", .{name});
                }
                return self.failFmt(location, "failed to compile named grammar '@{s}': {f}", .{ name, nested_diag });
            },
        };
        var compiled = LarkCompiler.compile(
            self.gpa,
            named_source,
            &document,
            self.tokenizer_info,
            self.named_grammars,
            nested_diag_ptr,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Lark => {
                if (self.diag == null) return error.Lark;
                if (nested_diag.kind == .none) {
                    return self.failFmt(location, "failed to compile named grammar '@{s}': lark error", .{name});
                }
                return self.failFmt(location, "failed to compile named grammar '@{s}': {f}", .{ name, nested_diag });
            },
        };
        errdefer compiled.deinit();

        const key = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(key);
        try self.named_grammars.compiled.put(self.gpa, key, compiled);
    }

    fn compileNode(
        self: *LarkCompiler,
        node: *const LarkNode,
        rule_hint: []const u8,
        terminal_mode: bool,
        with_skip: bool,
    ) LarkError!i32 {
        // Whether to append the `%ignore` skip after a lexeme-like result.
        const skip_lexeme = !terminal_mode and with_skip;
        const result: i32 = blk: {
            switch (node.kind) {
                .Sequence, .Choice => {
                    if (node.children.items.len == 0) {
                        return self.builder.addEmptyStr();
                    }
                    var elements: std.ArrayList(i32) = .empty;
                    for (node.children.items) |*child| {
                        try elements.append(self.arena, try self.compileNode(child, rule_hint, terminal_mode, with_skip));
                    }
                    if (elements.items.len == 1) {
                        return elements.items[0];
                    }
                    if (node.kind == .Sequence) {
                        return self.builder.addSequence(elements.items);
                    }
                    return self.builder.addChoices(elements.items);
                },
                .Repeat => {
                    const repeat_hint = try std.fmt.allocPrint(self.arena, "{s}_repeat", .{rule_hint});
                    const child = try self.compileNode(&node.children.items[0], repeat_hint, terminal_mode, with_skip);
                    return self.builder.addRepeatFromExpr(repeat_hint, child, node.min_repeat, node.max_repeat);
                },
                .Name => {
                    const index = self.definitionIndex(node.text) orelse {
                        return self.failFmt(node.location, "unknown name '{s}'", .{node.text});
                    };
                    const definition = &self.document.definitions.items[index];
                    if (terminal_mode and !definition.is_terminal) {
                        return self.failFmt(node.location, "terminal cannot reference rule '{s}'", .{node.text});
                    }
                    // Lazy and temperature rules are compiled like terminals (lexemes), so they
                    // also take a trailing skip.
                    const is_lexeme = definition.is_terminal or definition.hasLazySemantics() or definition.temperature != null;
                    const reference = try self.builder.addRuleRef(self.rule_ids.get(node.text).?);
                    if (skip_lexeme and is_lexeme) {
                        return self.appendSkip(reference);
                    }
                    return reference;
                },
                .String => {
                    const literal = try self.compileStringLiteral(node);
                    if (skip_lexeme and node.text.len != 0) {
                        return self.appendSkip(literal);
                    }
                    return literal;
                },
                .Range => {
                    const endpoints = try self.rangeEndpoints(node);
                    break :blk try self.builder.addCharacterClass(&.{
                        CharacterClassElement.init(@intCast(endpoints.begin), @intCast(endpoints.end)),
                    }, false);
                },
                .Regex => {
                    const flags = try self.parseRegexFlags(node);
                    const pattern = try fsm_mod.rewriteRegexDots(self.arena, node.text, flags.dot_all);
                    if (flags.case_insensitive) {
                        // The FSM regex engine handles the (?i) prefix with ASCII case folding.
                        // Validate the pattern eagerly so that errors carry the source location.
                        const flagged_pattern = try std.fmt.allocPrint(self.arena, "(?i){s}", .{pattern});
                        try self.validateRegex(flagged_pattern, node.location);
                        const regex_expr = try self.builder.addRegex(flagged_pattern, false);
                        const hint = try std.fmt.allocPrint(self.arena, "{s}_regex", .{rule_hint});
                        const regex_rule_id = try self.builder.addRuleWithHint(hint, regex_expr);
                        break :blk try self.builder.addRuleRef(regex_rule_id);
                    }
                    var grammar = try self.fromRegexChecked(pattern, node.location);
                    defer grammar.deinit();
                    const root = try functor.addSubGrammar(&self.builder, &grammar);
                    break :blk try self.builder.addRuleRef(root);
                },
                .Json => {
                    if (terminal_mode) {
                        return self.fail(node.location, "%json cannot be used in terminals");
                    }
                    var schema_diag: Diagnostic = .{};
                    defer schema_diag.deinit(self.gpa);
                    var grammar = json_schema.fromJsonSchema(self.gpa, node.text, .{
                        .any_whitespace = true,
                        .strict_mode = true,
                        .diag = if (self.diag != null) &schema_diag else null,
                    }) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => {
                            if (self.diag == null) return error.Lark;
                            if (schema_diag.kind == .none) {
                                return self.failFmt(node.location, "failed to compile inline JSON schema: {s}", .{@errorName(err)});
                            }
                            return self.failFmt(node.location, "failed to compile inline JSON schema: {f}", .{schema_diag});
                        },
                    };
                    defer grammar.deinit();
                    const root = try functor.addSubGrammar(&self.builder, &grammar);
                    break :blk try self.builder.addRuleRef(root);
                },
                .NestedLark => {
                    if (terminal_mode) {
                        return self.fail(node.location, "nested %lark cannot be used in terminals");
                    }
                    const nested = node.nested orelse {
                        return self.fail(node.location, "unsupported grammar node");
                    };
                    var cloned = try LarkDocument.deepClone(self.gpa, nested);
                    var nested_diag: Diagnostic = .{};
                    defer nested_diag.deinit(self.gpa);
                    var grammar = LarkCompiler.compile(
                        self.gpa,
                        self.source,
                        &cloned,
                        self.tokenizer_info,
                        self.named_grammars,
                        if (self.diag != null) &nested_diag else null,
                    ) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.Lark => {
                            if (self.diag == null) return error.Lark;
                            if (nested_diag.kind == .none) {
                                return self.fail(node.location, "failed to compile nested Lark grammar: lark error");
                            }
                            return self.failFmt(node.location, "failed to compile nested Lark grammar: {f}", .{nested_diag});
                        },
                    };
                    defer grammar.deinit();
                    const root = try functor.addSubGrammar(&self.builder, &grammar);
                    break :blk try self.builder.addRuleRef(root);
                },
                .SpecialToken => {
                    if (terminal_mode) {
                        return self.fail(node.location, "special tokens cannot be used in terminals");
                    }
                    const token_set = try self.resolveSpecialToken(node.text, node.location);
                    if (token_set.excluded) {
                        break :blk try self.builder.addExcludeTokenSet(token_set.token_ids.items);
                    }
                    break :blk try self.builder.addTokenSet(token_set.token_ids.items);
                },
                .RegexExt => break :blk try self.compileStructuredRegex(node, rule_hint),
                .GrammarRef => {
                    if (terminal_mode) {
                        return self.fail(node.location, "named grammars cannot be used in terminals");
                    }
                    const name = node.text[1..];
                    const root: i32 = self.named_grammar_roots.get(name) orelse root_blk: {
                        try self.resolveNamedGrammar(name, node.location);
                        const grammar = self.named_grammars.get(name) orelse {
                            return self.failFmt(node.location, "unknown named grammar '@{s}'", .{name});
                        };
                        const sub_root = try functor.addSubGrammar(&self.builder, grammar);
                        try self.named_grammar_roots.put(self.arena, try self.arena.dupe(u8, name), sub_root);
                        break :root_blk sub_root;
                    };
                    break :blk try self.builder.addRuleRef(root);
                },
                .Not => {
                    return self.fail(node.location, "regular-expression complement '~' is not supported");
                },
            }
        };
        if (skip_lexeme) {
            return self.appendSkip(result);
        }
        return result;
    }

    /// Compiles the regex and maps a conversion failure to a located Lark error.
    fn fromRegexChecked(self: *LarkCompiler, pattern: []const u8, location: LarkLocation) LarkError!Grammar {
        var regex_diag: Diagnostic = .{};
        defer regex_diag.deinit(self.gpa);
        return regex_mod.fromRegex(
            self.gpa,
            pattern,
            if (self.diag != null) &regex_diag else null,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Regex => {
                if (self.diag == null) return error.Lark;
                if (regex_diag.kind == .none) {
                    return self.fail(location, "failed to compile regular expression");
                }
                return self.failFmt(location, "failed to compile regular expression: {f}", .{regex_diag});
            },
        };
    }

    /// Validates the pattern with `RegexFsmBuilder.matchesEmpty`, forwarding any error.
    fn validateRegex(self: *LarkCompiler, pattern: []const u8, location: LarkLocation) LarkError!void {
        var regex_diag: Diagnostic = .{};
        defer regex_diag.deinit(self.gpa);
        _ = fsm_mod.RegexFsmBuilder.matchesEmpty(
            self.gpa,
            pattern,
            if (self.diag != null) &regex_diag else null,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                if (self.diag == null) return error.Lark;
                if (regex_diag.kind == .none) {
                    return self.failFmt(location, "failed to compile regular expression: {s}", .{@errorName(err)});
                }
                return self.failFmt(location, "failed to compile regular expression: {f}", .{regex_diag});
            },
        };
    }

    fn appendSkip(self: *LarkCompiler, expression: i32) Allocator.Error!i32 {
        const skip_rule_id = self.skip_rule_id orelse return expression;
        const skip = try self.builder.addRuleRef(skip_rule_id);
        return self.builder.addSequence(&.{ expression, skip });
    }

    fn resolveSpecialToken(self: *const LarkCompiler, token: []const u8, location: LarkLocation) LarkError!LarkSpecialTokenSet {
        var result = LarkSpecialTokenSet{};
        const contents_in: ?[]const u8 = if (std.mem.startsWith(u8, token, "<[") and std.mem.endsWith(u8, token, "]>"))
            token[2 .. token.len - 2]
        else
            null;
        if (contents_in == null) {
            const tokenizer_info = self.tokenizer_info orelse {
                return self.failFmt(location, "named special token {s} requires tokenizer_info", .{token});
            };
            var token_ids: std.ArrayList(i32) = .empty;
            for (tokenizer_info.decodedVocab(), 0..) |decoded, token_id| {
                if (std.mem.eql(u8, decoded, token)) {
                    try token_ids.append(self.arena, @intCast(token_id));
                }
            }
            if (token_ids.items.len == 0) {
                return self.failFmt(location, "unknown special token {s}", .{token});
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
            try token_ids.ensureTotalCapacity(self.arena, tokenizer_info.vocabSize());
            for (0..tokenizer_info.vocabSize()) |id| {
                token_ids.appendAssumeCapacity(@intCast(id));
            }
            result.token_ids = token_ids;
            return result;
        }
        if (std.mem.indexOfScalar(u8, contents, '*') != null) {
            return self.fail(location, "wildcard cannot be mixed with token ranges");
        }
        var range_it = std.mem.splitScalar(u8, contents, ',');
        while (range_it.next()) |raw_range| {
            const range = trimCSpace(raw_range);
            if (range.len == 0) continue;
            if (std.mem.indexOfScalar(u8, range, '-')) |dash| {
                const last = range[dash + 1 ..];
                if (std.mem.indexOfScalar(u8, last, '-') != null) {
                    return self.failFmt(location, "invalid numeric special-token range '{s}'", .{range});
                }
                const first = parseTokenId(range[0..dash]);
                const last_id = parseTokenId(last);
                if (first == null or last_id == null) {
                    return self.failFmt(location, "invalid numeric special-token range '{s}'", .{range});
                }
                try self.appendTokenRange(&result, location, first.?, last_id.?);
            } else {
                const id = parseTokenId(range) orelse {
                    return self.failFmt(location, "invalid numeric special-token range '{s}'", .{range});
                };
                try self.appendTokenRange(&result, location, id, id);
            }
        }
        if (result.token_ids.items.len == 0) {
            return self.fail(location, "empty numeric special-token range");
        }
        std.mem.sort(i32, result.token_ids.items, {}, std.sort.asc(i32));
        dedupI32(&result.token_ids);
        return result;
    }

    fn appendTokenRange(self: *const LarkCompiler, result: *LarkSpecialTokenSet, location: LarkLocation, first: i64, last: i64) LarkError!void {
        if (first < 0 or last < first or last > std.math.maxInt(i32)) {
            return self.fail(location, "invalid numeric special-token range");
        }
        if (last - first > 1_000_000) {
            return self.fail(location, "special-token range is too large");
        }
        var id = first;
        while (id <= last) : (id += 1) {
            try result.token_ids.append(self.arena, @intCast(id));
        }
    }

    /// Whether `node` matches any text: an any-text regex, possibly behind terminal names.
    fn isAnyText(self: *const LarkCompiler, node: *const LarkNode, visiting: *std.StringHashMapUnmanaged(void)) bool {
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
                    return self.isAnyText(&node.children.items[0], visiting);
                }
                return false;
            },
            .Name => {
                const index = self.definitionIndex(node.text) orelse return false;
                const entry = visiting.getOrPut(self.arena, node.text) catch return false;
                if (entry.found_existing) return false;
                defer _ = visiting.remove(node.text);
                return self.isAnyText(&self.document.definitions.items[index].body, visiting);
            },
            else => return false,
        }
    }

    fn extractLazyTrigger(self: *const LarkCompiler, definition: *const LarkDefinition) LarkError!?LarkTrigger {
        const marker = definition.stop orelse definition.suffix;
        if (marker) |*m| {
            const is_fixed_string = m.kind == .String and m.flags.len == 0;
            var visiting: std.StringHashMapUnmanaged(void) = .empty;
            defer visiting.deinit(self.arena);
            if (!is_fixed_string or !self.isAnyText(&definition.body, &visiting)) {
                return null;
            }
            return .{ .string = m.text };
        }
        if (!definition.lazy) {
            return null;
        }
        if (extractLazyRegexTrigger(self.arena, unwrapSingle(&definition.body))) |trigger| {
            return trigger;
        }
        const body = &definition.body;
        var visiting: std.StringHashMapUnmanaged(void) = .empty;
        defer visiting.deinit(self.arena);
        if (body.kind != .Sequence or body.children.items.len != 2 or
            !self.isAnyText(&body.children.items[0], &visiting))
        {
            return null;
        }
        const trigger = &body.children.items[1];
        if (trigger.kind == .String and trigger.text.len != 0 and trigger.flags.len == 0) {
            return .{ .string = trigger.text };
        }
        if (trigger.kind == .SpecialToken) {
            const token_set = try self.resolveSpecialToken(trigger.text, trigger.location);
            if (token_set.excluded) {
                return self.fail(trigger.location, "lazy special-token trigger cannot be negated");
            }
            return .{ .token = token_set.token_ids.items };
        }
        return null;
    }

    fn compileLazyRule(self: *LarkCompiler, definition: *const LarkDefinition) LarkError!i32 {
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
        const body = unwrapSingle(&definition.body);
        if (marker == null and body.kind == .Regex and
            extractLazyRegexTrigger(self.arena, body) != null)
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
            var visiting: std.StringHashMapUnmanaged(void) = .empty;
            defer visiting.deinit(self.arena);
            const body_pattern = try self.terminalNodeToRegex(&definition.body, &visiting);
            const marker_pattern = try self.terminalNodeToRegex(marker.?, &visiting);
            const body_helper_expr = try self.builder.addRegex(body_pattern, false);
            const body_hint = try std.fmt.allocPrint(self.arena, "{s}_stop_body", .{definition.name});
            suffix_stop_info.body_rule_id = try self.builder.addRuleWithHint(body_hint, body_helper_expr);
            const marker_helper_expr = try self.builder.addRegex(marker_pattern, false);
            const marker_hint = try std.fmt.allocPrint(self.arena, "{s}_stop_marker", .{definition.name});
            suffix_stop_info.marker_rule_id = try self.builder.addRuleWithHint(marker_hint, marker_helper_expr);
            patterns = .{ .body = body_pattern, .marker = marker_pattern };
        }
        try self.builder.updateSuffixStopInfo(rule_id, suffix_stop_info);
        const trigger = try self.extractLazyTrigger(definition);
        if (trigger == null) {
            // General committed-shortest lazy rule: compiled like a terminal (no skip
            // insertion); the terminal-like requirement is validated after grammar
            // optimization. suffix="s" and stop="s" both desugar to the lazy rule over
            // (body "s"); their only difference is capture scope, represented by the
            // metadata set above.
            self.builder.updateLazy(rule_id, true);
            const m = marker orelse {
                return self.compileNode(&definition.body, definition.name, true, true);
            };
            var visiting: std.StringHashMapUnmanaged(void) = .empty;
            defer visiting.deinit(self.arena);
            const both: BodyMarker = patterns orelse .{
                .body = try self.terminalNodeToRegex(&definition.body, &visiting),
                .marker = try self.terminalNodeToRegex(m, &visiting),
            };
            const combined = try std.fmt.allocPrint(self.arena, "(?:{s})(?:{s})", .{ both.body, both.marker });
            return self.builder.addRegex(combined, false);
        }
        const empty_expr = try self.builder.addEmptyStr();
        const empty_rule = try self.builder.addRuleWithHint("lark_lazy_end", empty_expr);
        const result: i32 = switch (trigger.?) {
            .string => |tag| blk: {
                var td: TagDispatch = .{ .loop_after_dispatch = false };
                defer td.deinit(self.gpa);
                try td.tag_rule_pairs.append(self.gpa, .{
                    .tag = try self.gpa.dupe(u8, tag),
                    .rule_id = empty_rule,
                });
                break :blk try self.builder.addTagDispatch(&td);
            },
            .token => |token_ids| blk: {
                var ttd: TokenTagDispatch = .{ .loop_after_dispatch = false };
                defer ttd.deinit(self.gpa);
                try ttd.trigger_rule_pairs.ensureTotalCapacity(self.gpa, token_ids.len);
                for (token_ids) |token_id| {
                    ttd.trigger_rule_pairs.appendAssumeCapacity(.{ .token_id = token_id, .rule_id = empty_rule });
                }
                break :blk try self.builder.addTokenTagDispatch(&ttd);
            },
        };
        return self.appendSkip(result);
    }

    /// Lowers `start: (tool_a | tool_b)* tail` with lazy tool heads and an any-text tail
    /// into a looping tag dispatch, or returns null if `start` does not have that shape.
    fn compileDynamicStart(self: *LarkCompiler, start: *const LarkDefinition) LarkError!?i32 {
        const document = self.document;
        var unused_rules: std.StringHashMapUnmanaged(void) = .empty;
        const start_elements = try flattenSequence(self.arena, &start.body);
        if (start_elements.items.len != 2) {
            return null;
        }
        const loop_element = &start_elements.items[0];
        const tail_element = &start_elements.items[1];
        const loop_node = unwrapSingle(loop_element);
        if (loop_node.kind != .Repeat or loop_node.min_repeat != 0 or loop_node.max_repeat != -1) {
            return null;
        }
        const loop_body = unwrapSingle(&loop_node.children.items[0]);
        var tool_names: std.ArrayList([]const u8) = .empty;
        switch (loop_body.kind) {
            .Choice => {
                for (loop_body.children.items) |*alternative| {
                    const name = unwrapSingle(alternative);
                    if (name.kind != .Name) {
                        return null;
                    }
                    try tool_names.append(self.arena, name.text);
                }
            },
            .Name => try tool_names.append(self.arena, loop_body.text),
            else => return null,
        }

        const tail_name = unwrapSingle(tail_element);
        if (tail_name.kind != .Name) {
            return null;
        }
        {
            var visiting: std.StringHashMapUnmanaged(void) = .empty;
            defer visiting.deinit(self.arena);
            const tail_index = self.definitionIndex(tail_name.text) orelse return null;
            if (!self.isAnyText(&document.definitions.items[tail_index].body, &visiting)) {
                return null;
            }
        }
        try unused_rules.put(self.arena, tail_name.text, {});

        const Alternative = struct {
            trigger: LarkTrigger,
            remainder: LarkNode,
            marker_event_rule_id: i32,
        };
        var alternatives: std.ArrayList(Alternative) = .empty;
        for (tool_names.items) |tool_name| {
            const tool_index = self.definitionIndex(tool_name) orelse return null;
            const tool = &document.definitions.items[tool_index];
            if (tool.is_terminal) return null;
            try unused_rules.put(self.arena, tool_name, {});
            const tool_elements = try flattenSequence(self.arena, &tool.body);
            if (tool_elements.items.len == 0) {
                return null;
            }

            var trigger: ?LarkTrigger = null;
            var marker_event_rule_id: i32 = -1;
            var remainder_begin: usize = 0;
            const first = unwrapSingle(&tool_elements.items[0]);
            var head: ?*const LarkDefinition = null;
            if (first.kind == .Name) {
                if (self.definitionIndex(first.text)) |head_index| {
                    head = &document.definitions.items[head_index];
                }
            }
            if (head) |h| {
                trigger = try self.extractLazyTrigger(h);
                if (trigger != null) {
                    try unused_rules.put(self.arena, first.text, {});
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
                            const event_expr = try self.builder.addEmptyStr();
                            const marker_hint = try std.fmt.allocPrint(self.arena, "{s}_dynamic_marker", .{h.name});
                            marker_event_rule_id = try self.builder.addRuleWithHint(marker_hint, event_expr);
                            const marker_expr = try self.builder.addByteString(t.string);
                            const marker_text_hint = try std.fmt.allocPrint(self.arena, "{s}_dynamic_marker_text", .{h.name});
                            const marker_rule_id = try self.builder.addRuleWithHint(marker_text_hint, marker_expr);
                            var suffix_stop_info = SuffixStopInfo.default();
                            suffix_stop_info.body_rule_id = marker_event_rule_id;
                            suffix_stop_info.marker_rule_id = marker_rule_id;
                            suffix_stop_info.hidden_stop_bytes = if (h.stop != null) @intCast(t.string.len) else 0;
                            suffix_stop_info.hidden_suffix_bytes = if (h.stop != null) 0 else @intCast(t.string.len);
                            suffix_stop_info.stop_capture_name = h.stop_capture_name orelse "";
                            try self.builder.updateSuffixStopInfo(marker_event_rule_id, suffix_stop_info);
                        }
                    }
                }
            }
            if (trigger == null and tool_elements.items.len >= 2) {
                var visiting: std.StringHashMapUnmanaged(void) = .empty;
                defer visiting.deinit(self.arena);
                if (self.isAnyText(&tool_elements.items[0], &visiting)) {
                    const token_trigger = unwrapSingle(&tool_elements.items[1]);
                    if (token_trigger.kind == .SpecialToken) {
                        const token_set = try self.resolveSpecialToken(token_trigger.text, token_trigger.location);
                        if (token_set.excluded) {
                            return self.fail(token_trigger.location, "dynamic special-token trigger cannot be negated");
                        }
                        trigger = .{ .token = token_set.token_ids.items };
                        remainder_begin = 2;
                    }
                }
            }
            const final_trigger = trigger orelse return null;
            const remainder = try LarkNode.withChildren(
                .Sequence,
                tool.location,
                tool_elements.items[remainder_begin..],
                self.arena,
            );
            try alternatives.append(self.arena, .{
                .trigger = final_trigger,
                .remainder = remainder,
                .marker_event_rule_id = marker_event_rule_id,
            });
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
        var group_by_trigger: std.HashMapUnmanaged(LarkTrigger, usize, TriggerContext, 80) = .empty;
        for (alternatives.items, 0..) |alternative, index| {
            var keys: std.ArrayList(LarkTrigger) = .empty;
            switch (alternative.trigger) {
                .string => try keys.append(self.arena, alternative.trigger),
                .token => |token_ids| {
                    for (token_ids) |token_id| {
                        const single = try self.arena.alloc(i32, 1);
                        single[0] = token_id;
                        try keys.append(self.arena, .{ .token = single });
                    }
                },
            }
            for (keys.items) |key| {
                const entry = try group_by_trigger.getOrPut(self.arena, key);
                if (!entry.found_existing) {
                    const indices: std.ArrayList(usize) = .empty;
                    try groups.append(self.arena, .{ .trigger = key, .indices = indices });
                    entry.value_ptr.* = groups.items.len - 1;
                }
                try groups.items[entry.value_ptr.*].indices.append(self.arena, index);
            }
        }

        const body_hint: []const u8 = if (is_string_level) "lark_dynamic_body" else "lark_dynamic_token_body";
        var tag_rule_pairs: std.ArrayList(struct { tag: []const u8, rule_id: i32 }) = .empty;
        var trigger_rule_pairs: std.ArrayList(struct { trigger: i32, rule_id: i32 }) = .empty;
        for (groups.items) |*group| {
            var remainder_choices: std.ArrayList(i32) = .empty;
            for (group.indices.items) |index| {
                const alternative = &alternatives.items[index];
                var remainder_expr = try self.compileNode(&alternative.remainder, body_hint, false, true);
                if (alternative.marker_event_rule_id >= 0) {
                    const marker_event = try self.builder.addRuleRef(alternative.marker_event_rule_id);
                    remainder_expr = try self.builder.addSequence(&.{ marker_event, remainder_expr });
                }
                try remainder_choices.append(self.arena, remainder_expr);
            }
            const body = if (remainder_choices.items.len == 1)
                remainder_choices.items[0]
            else
                try self.builder.addChoices(remainder_choices.items);
            const body_rule = try self.builder.addRuleWithHint(body_hint, body);
            switch (group.trigger) {
                .string => |trigger_str| try tag_rule_pairs.append(self.arena, .{ .tag = trigger_str, .rule_id = body_rule }),
                .token => |token_ids| try trigger_rule_pairs.append(self.arena, .{ .trigger = token_ids[0], .rule_id = body_rule }),
            }
        }
        self.dynamic_unused_rules = unused_rules;
        if (is_string_level) {
            var td: TagDispatch = .{ .loop_after_dispatch = true };
            defer td.deinit(self.gpa);
            try td.tag_rule_pairs.ensureTotalCapacity(self.gpa, tag_rule_pairs.items.len);
            for (tag_rule_pairs.items) |pair| {
                td.tag_rule_pairs.appendAssumeCapacity(.{
                    .tag = try self.gpa.dupe(u8, pair.tag),
                    .rule_id = pair.rule_id,
                });
            }
            return try self.builder.addTagDispatch(&td);
        }
        var ttd: TokenTagDispatch = .{ .loop_after_dispatch = true };
        defer ttd.deinit(self.gpa);
        try ttd.trigger_rule_pairs.ensureTotalCapacity(self.gpa, trigger_rule_pairs.items.len);
        for (trigger_rule_pairs.items) |pair| {
            ttd.trigger_rule_pairs.appendAssumeCapacity(.{ .token_id = pair.trigger, .rule_id = pair.rule_id });
        }
        return try self.builder.addTokenTagDispatch(&ttd);
    }
};

const common_regex_map = std.StaticStringMap([]const u8).initComptime(.{
    .{ "common.DIGIT", "[0-9]" },
    .{ "common.HEXDIGIT", "[a-fA-F0-9]" },
    .{ "common.INT", "[0-9]+" },
    .{ "common.SIGNED_INT", "(\\+|-)?[0-9]+" },
    .{ "common.DECIMAL", "([0-9]+\\.[0-9]*)|(\\.[0-9]+)" },
    .{ "common._EXP", "[eE](\\+|-)?[0-9]+" },
    .{ "common.FLOAT", "([0-9]+\\.[0-9]*|\\.[0-9]+)([eE](\\+|-)?[0-9]+)?|[0-9]+[eE](\\+|-)?[0-9]+" },
    .{ "common.SIGNED_FLOAT", "(\\+|-)?(([0-9]+\\.[0-9]*|\\.[0-9]+)([eE](\\+|-)?[0-9]+)?|[0-9]+[eE](\\+|-)?[0-9]+)" },
    .{ "common.NUMBER", "([0-9]+)|([0-9]+\\.[0-9]*|\\.[0-9]+)([eE](\\+|-)?[0-9]+)?|[0-9]+[eE](\\+|-)?[0-9]+" },
    .{ "common.SIGNED_NUMBER", "(\\+|-)?(([0-9]+)|([0-9]+\\.[0-9]*|\\.[0-9]+)([eE](\\+|-)?[0-9]+)?|[0-9]+[eE](\\+|-)?[0-9]+)" },
    .{ "common.ESCAPED_STRING", "\\\"([^\\\"\\\\]|\\\\.)*\\\"" },
    .{ "common.LCASE_LETTER", "[a-z]" },
    .{ "common.UCASE_LETTER", "[A-Z]" },
    .{ "common.LETTER", "[A-Za-z]" },
    .{ "common.WORD", "[A-Za-z]+" },
    .{ "common.CNAME", "[_A-Za-z][_A-Za-z0-9]*" },
    .{ "common.WS_INLINE", "[ \\t]+" },
    .{ "common.WS", "[ \\t\\f\\r\\n]+" },
    .{ "common.CR", "\\r" },
    .{ "common.LF", "\\n" },
    .{ "common.NEWLINE", "(\\r?\\n)+" },
    .{ "common.SH_COMMENT", "#[^\\n]*" },
    .{ "common.CPP_COMMENT", "//[^\\n]*" },
    .{ "common.C_COMMENT", "\\/\\*[^*]*\\*+(?:[^/*][^*]*\\*+)*\\/" },
    .{ "common.SQL_COMMENT", "--[^\\n]*" },
});

/// The regular expressions of the supported `%import common.NAME` terminals.
fn commonRegex(path: []const u8) ?[]const u8 {
    return common_regex_map.get(path);
}

/// Trims C-locale whitespace from both ends.
fn trimCSpace(value: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = value.len;
    while (start < end and lexer_mod.isCSpace(value[start])) start += 1;
    while (end > start and lexer_mod.isCSpace(value[end - 1])) end -= 1;
    return value[start..end];
}

/// The prefix of `text` before its first NUL (what a C string view of it contains).
fn cStr(text: []const u8) []const u8 {
    return text[0 .. std.mem.indexOfScalar(u8, text, 0) orelse text.len];
}

/// The single codepoint of `text`, or null if it does not hold exactly one.
fn singleCodepoint(text: []const u8) ?u21 {
    if (text.len == 0) return null;
    const len = std.unicode.utf8ByteSequenceLength(text[0]) catch return null;
    if (len != text.len) return null;
    return std.unicode.utf8Decode(text) catch null;
}

/// Decodes a regex made only of literal characters and escapes into the bytes it matches,
/// or null if it uses any other regex construct.
fn parseFixedRegexLiteral(allocator: Allocator, pattern: []const u8) ?std.ArrayList(u8) {
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
                    while (i < bytes.len and support.hexCharToInt(bytes[i]) != null) {
                        if (digit_count == 6) break;
                        codepoint = codepoint * 16 + support.hexCharToInt(bytes[i]).?;
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
                        const value = support.hexCharToInt(bytes[i]) orelse return null;
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
fn escapeRegexLiteral(allocator: Allocator, value: []const u8) Allocator.Error![]u8 {
    var result: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < value.len) {
        const len = std.unicode.utf8ByteSequenceLength(value[i]) catch 1;
        if (i + len > value.len) {
            try result.append(allocator, value[i]);
            i += 1;
            continue;
        }
        const character = std.unicode.utf8Decode(value[i .. i + len]) catch {
            try result.append(allocator, value[i]);
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
                    try result.print(allocator, "\\x{X:0>2}", .{cp});
                } else {
                    if (cp <= 0x7F and std.mem.indexOfScalar(u8, "\\.^$|()[]{}*+?", @as(u8, @intCast(cp))) != null) {
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
fn unwrapSingle(node_in: *const LarkNode) *const LarkNode {
    var node = node_in;
    while (node.kind == .Sequence and node.children.items.len == 1) {
        node = &node.children.items[0];
    }
    return node;
}

/// The elements of a sequence, or the node itself.
fn flattenSequence(allocator: Allocator, node: *const LarkNode) Allocator.Error!std.ArrayList(LarkNode) {
    var out: std.ArrayList(LarkNode) = .empty;
    if (node.kind == .Sequence) {
        try out.appendSlice(allocator, node.children.items);
        return out;
    }
    try out.append(allocator, node.*);
    return out;
}

/// The trigger of a lazy head written as one regex `<any-text prefix><fixed literal>`.
fn extractLazyRegexTrigger(allocator: Allocator, node: *const LarkNode) ?LarkTrigger {
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
        const trigger = parseFixedRegexLiteral(allocator, rest) orelse continue;
        if (trigger.items.len == 0) continue;
        return .{ .string = trigger.items };
    }
    return null;
}

fn parseTokenId(value_in: []const u8) ?i64 {
    const value = trimCSpace(value_in);
    return std.fmt.parseInt(i64, value, 10) catch null;
}

fn dedupI32(list: *std.ArrayList(i32)) void {
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

fn sortedObjectKeys(allocator: Allocator, object: *std.json.ObjectMap) Allocator.Error!std.ArrayList([]const u8) {
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

fn appendClassCharacter(result: *std.ArrayList(u8), allocator: Allocator, character: u21) Allocator.Error!void {
    if (character <= 0x7F and std.mem.indexOfScalar(u8, "\\]-^", @as(u8, @intCast(character))) != null) {
        try result.append(allocator, '\\');
    }
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(character, &buf) catch unreachable;
    try result.appendSlice(allocator, buf[0..len]);
}

test "fromLark error forwarding from regex, json_schema, nested lark, and temperature leaks zero bytes" {
    const a = std.testing.allocator;

    // Null diagnostic paths leak zero bytes.
    try std.testing.expectError(error.Lark, fromLark(a, "start: /a[]b/", null, &.{}, null));
    try std.testing.expectError(error.Lark, fromLark(a, "start: /a[]b/i", null, &.{}, null));
    try std.testing.expectError(error.Lark, fromLark(a, "start: %json {not json}", null, &.{}, null));
    try std.testing.expectError(error.Lark, fromLark(a, "start: %lark { item: \"a\" }", null, &.{}, null));
    try std.testing.expectError(error.Lark, fromLark(a, "start[temperature=0.5]: \"a\" | rule\nrule: \"b\"", null, &.{}, null));

    // Reusable Diagnostic across all forwarded sub-diagnostics.
    var diag: Diagnostic = .{};
    defer diag.deinit(a);

    try std.testing.expectError(error.Lark, fromLark(a, "start: /a[]b/", null, &.{}, &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "failed to compile regular expression:") != null);

    try std.testing.expectError(error.Lark, fromLark(a, "start: /a[]b/i", null, &.{}, &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "failed to compile regular expression:") != null);

    try std.testing.expectError(error.Lark, fromLark(a, "start: %json {\"type\":\"integer\",\"minimum\":10,\"maximum\":5}", null, &.{}, &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "failed to compile inline JSON schema:") != null);

    try std.testing.expectError(error.Lark, fromLark(a, "start: %lark { item: \"a\" }", null, &.{}, &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "failed to compile nested Lark grammar:") != null);

    try std.testing.expectError(error.Lark, fromLark(a, "start[temperature=0.5]: \"a\" | rule\nrule: \"b\"", null, &.{}, &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "temperature is only supported on terminals and subgrammars") != null);
}
