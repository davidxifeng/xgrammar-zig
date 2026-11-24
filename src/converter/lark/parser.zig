//! Recursive-descent parser for the Lark grammar syntax (`lark_parser.rs`).
//!
//! All AST nodes, strings, and JSON values live in the returned document's arena (nested
//! `%lark` documents borrow the enclosing document's arena allocator and are reclaimed with it).

const std = @import("std");
const Allocator = std.mem.Allocator;

const Diagnostic = @import("../../Diagnostic.zig").Diagnostic;
const support = @import("../../support.zig");
const ast = @import("ast.zig");
const lexer_mod = @import("lexer.zig");

const LarkDefinition = ast.LarkDefinition;
const LarkDocument = ast.LarkDocument;
const LarkError = ast.LarkError;
const LarkLexer = lexer_mod.LarkLexer;
const LarkLocation = ast.LarkLocation;
const LarkNode = ast.LarkNode;
const LarkToken = ast.LarkToken;
const LarkTokenType = ast.LarkTokenType;

/// Groups recurse `parseChoice -> parseSequence -> parseExpr -> parseAtom` once per
/// level, so the nesting depth is bounded instead of overflowing the stack.
const MAX_GROUP_DEPTH: i32 = 200;

/// Parses Lark source into a `LarkDocument` owning its own arena.
///
/// `diag` (optional) receives `.lark_located` failure payloads allocated from `gpa`.
pub fn parse(gpa: Allocator, source: []const u8, diag: ?*Diagnostic) LarkError!LarkDocument {
    return parseNested(gpa, source, diag, null);
}

/// Parses Lark source into a `LarkDocument`. When `parent_alloc` is non-null, allocations
/// go directly into `parent_alloc` so the nested document is reclaimed with its parent.
pub fn parseNested(
    gpa: Allocator,
    source: []const u8,
    diag: ?*Diagnostic,
    parent_alloc: ?Allocator,
) LarkError!LarkDocument {
    var document = if (parent_alloc) |pa|
        LarkDocument.initNested(pa)
    else
        try LarkDocument.init(gpa);
    errdefer document.deinit();
    var lexer = LarkLexer{
        .gpa = gpa,
        .diag = diag,
        .arena = document.allocator(),
        .source = source,
    };
    const tokens = try lexer.tokenize();
    var parser = LarkParser{
        .gpa = gpa,
        .diag = diag,
        .arena = document.allocator(),
        .source = source,
        .tokens = tokens.items,
        .document = &document,
    };
    try parser.parseDocument(false);
    return document;
}

pub const LarkParser = struct {
    gpa: Allocator,
    diag: ?*Diagnostic,
    /// The document being built (its arena allocates every node and string).
    arena: Allocator,
    source: []const u8,
    tokens: []const LarkToken,
    position: usize = 0,
    group_depth: i32 = 0,
    document: *LarkDocument,

    fn err(self: *const LarkParser, location: LarkLocation, message: []const u8) LarkError {
        return ast.failLocated(self.gpa, self.diag, self.source, location, message);
    }

    fn errFmt(self: *const LarkParser, location: LarkLocation, comptime fmt: []const u8, args: anytype) LarkError {
        return ast.failLocatedFmt(self.gpa, self.diag, self.source, location, fmt, args);
    }

    fn peekAt(self: *const LarkParser, offset: usize) *const LarkToken {
        return &self.tokens[@min(self.position + offset, self.tokens.len - 1)];
    }

    fn peek(self: *const LarkParser) *const LarkToken {
        return self.peekAt(0);
    }

    fn peekType(self: *const LarkParser) LarkTokenType {
        return self.peek().ty;
    }

    fn matchToken(self: *LarkParser, ty: LarkTokenType) bool {
        if (self.peekType() != ty) return false;
        self.position += 1;
        return true;
    }

    fn consume(self: *LarkParser, ty: LarkTokenType, message: []const u8) LarkError!LarkToken {
        if (self.peekType() != ty) {
            return self.err(self.peek().location, message);
        }
        self.position += 1;
        return self.tokens[self.position - 1];
    }

    fn consumeFmt(self: *LarkParser, ty: LarkTokenType, comptime fmt: []const u8, args: anytype) LarkError!LarkToken {
        if (self.peekType() != ty) {
            return self.errFmt(self.peek().location, fmt, args);
        }
        self.position += 1;
        return self.tokens[self.position - 1];
    }

    /// Fails with `message` at the next token if it has type `ty`.
    fn reject(self: *const LarkParser, ty: LarkTokenType, message: []const u8) LarkError!void {
        if (self.peekType() == ty) {
            return self.err(self.peek().location, message);
        }
    }

    fn consumeNewlines(self: *LarkParser) void {
        while (self.matchToken(.Newline)) {}
    }

    fn parseDocument(self: *LarkParser, stop_at_rbrace: bool) LarkError!void {
        const atEnd = struct {
            fn check(ty: LarkTokenType, stop: bool) bool {
                return ty == .End or (stop and ty == .RBrace);
            }
        }.check;
        self.consumeNewlines();
        while (!atEnd(self.peekType(), stop_at_rbrace)) {
            switch (self.peekType()) {
                .Import => try self.parseImport(),
                .Ignore => {
                    self.position += 1;
                    const ignore = try self.parseChoice();
                    try self.document.ignores.append(self.arena, ignore);
                },
                .GrammarOptions => {
                    const token = try self.consume(.GrammarOptions, "expected %grammar_options");
                    const value = support.parseJson(self.arena, token.text) catch |parse_error| switch (parse_error) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return self.errFmt(
                            token.location,
                            "invalid %grammar_options value: {s}",
                            .{@errorName(parse_error)},
                        ),
                    };
                    try self.document.options.append(self.arena, .{ .value = value, .location = token.location });
                },
                .UnsupportedDirective => {
                    return self.errFmt(self.peek().location, "directive {s} is not supported", .{self.peek().text});
                },
                else => {
                    const definition = try self.parseDefinition();
                    try self.document.definitions.append(self.arena, definition);
                },
            }
            if (self.peekType() != .Newline and !atEnd(self.peekType(), stop_at_rbrace)) {
                return self.err(self.peek().location, "expected end of grammar item");
            }
            self.consumeNewlines();
        }
    }

    fn isTerminalName(raw_name: []const u8) bool {
        var name = raw_name;
        if (name.len != 0 and (name[0] == '!' or name[0] == '?')) name = name[1..];
        if (name.len != 0 and name[0] == '_') name = name[1..];
        return name.len != 0 and name[0] >= 'A' and name[0] <= 'Z';
    }

    fn normalizeRuleName(name: []const u8) []const u8 {
        if (name.len != 0 and (name[0] == '!' or name[0] == '?')) return name[1..];
        return name;
    }

    fn validateCaptureName(self: *const LarkParser, capture_name: []const u8, location: LarkLocation) LarkError!void {
        if (capture_name.len == 0) {
            return self.err(location, "capture name must not be empty");
        }
        for (capture_name) |c| {
            if (!isAsciiAlphanumeric(c) and c != '_' and c != '-' and c != '.') {
                return self.err(location, "capture name must only contain letters, digits, '_', '-' and '.'");
            }
        }
    }

    fn parseStopLikeValue(self: *LarkParser, attribute_name: []const u8) LarkError!LarkNode {
        const token = self.peek().*;
        switch (token.ty) {
            .String => {
                self.position += 1;
                return self.parseStringNode(&token);
            },
            .Regex => {
                self.position += 1;
                return regexNode(token);
            },
            .Name => {
                self.position += 1;
                if (!isTerminalName(token.text)) {
                    return self.errFmt(token.location, "{s} terminal name must be uppercase", .{attribute_name});
                }
                return LarkNode.withText(.Name, token.location, normalizeRuleName(token.text));
            },
            else => {
                return self.errFmt(
                    token.location,
                    "expected string literal, regular expression, or uppercase terminal name after {s}=",
                    .{attribute_name},
                );
            },
        }
    }

    fn regexNode(token: LarkToken) LarkNode {
        var node = LarkNode.withText(.Regex, token.location, token.text);
        node.flags = token.flags;
        return node;
    }

    fn parseImport(self: *LarkParser) LarkError!void {
        const location = (try self.consume(.Import, "expected %import")).location;
        var path: std.ArrayList(u8) = .empty;
        try path.appendSlice(self.arena, (try self.consume(.Name, "expected import path")).text);
        while (self.matchToken(.Dot)) {
            try path.append(self.arena, '.');
            try path.appendSlice(self.arena, (try self.consume(.Name, "expected name after '.'")).text);
        }

        if (self.matchToken(.LParen)) {
            while (true) {
                const name = try self.consume(.Name, "expected imported terminal name");
                try self.document.imports.append(self.arena, .{
                    .path = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ path.items, name.text }),
                    .local_name = name.text,
                    .location = location,
                });
                if (!self.matchToken(.Comma)) break;
            }
            _ = try self.consume(.RParen, "expected ')' after import list");
            return;
        }

        const local_name = if (std.mem.lastIndexOfScalar(u8, path.items, '.')) |dot|
            path.items[dot + 1 ..]
        else
            path.items;
        const aliased_name = if (self.matchToken(.Arrow))
            (try self.consume(.Name, "expected import alias")).text
        else
            local_name;
        try self.document.imports.append(self.arena, .{
            .path = try self.arena.dupe(u8, path.items),
            .local_name = aliased_name,
            .location = location,
        });
    }

    fn parseDefinition(self: *LarkParser) LarkError!LarkDefinition {
        const name_token = try self.consume(.Name, "expected rule or terminal name");
        var definition = LarkDefinition.init(
            normalizeRuleName(name_token.text),
            isTerminalName(name_token.text),
            LarkNode.init(.Sequence, name_token.location),
            name_token.location,
        );

        if (self.peekType() == .LBracket) {
            if (definition.is_terminal) {
                return self.err(self.peek().location, "attributes are only supported on rules");
            }
            try self.parseAttributes(&definition);
        }
        try self.reject(.Dot, "rule and terminal priorities are not supported");
        try self.reject(.DoubleColon, "parametric grammar is not supported");
        try self.reject(.LBrace, "Lark templates are not supported");
        _ = try self.consume(.Colon, "expected ':' after rule name");
        definition.body = try self.parseChoice();
        return definition;
    }

    /// Parses a string-literal attribute value that must be a valid capture name.
    fn parseCaptureNameValue(self: *LarkParser, attribute_name: []const u8) LarkError!LarkDefinition.CaptureName {
        const token = try self.consumeFmt(.String, "expected string literal after {s}=", .{attribute_name});
        const node = try self.parseStringNode(&token);
        if (node.flags.len != 0) {
            return self.errFmt(node.location, "case-insensitive flags are not supported on {s}", .{attribute_name});
        }
        return .{ .name = node.text, .value_location = node.location };
    }

    /// Parses a `suffix=` or `stop=` value; `other` is the attribute it cannot be combined with.
    fn parseMarkerAttribute(
        self: *LarkParser,
        key: *const LarkToken,
        current: ?LarkNode,
        other: ?LarkNode,
        other_name: []const u8,
    ) LarkError!LarkNode {
        const name = key.text;
        _ = try self.consumeFmt(.Equals, "expected '=' after {s} attribute", .{name});
        const marker = try self.parseStopLikeValue(name);
        if (marker.kind == .String and marker.text.len == 0) {
            return self.errFmt(marker.location, "{s} must not be empty", .{name});
        }
        if (current != null) {
            return self.errFmt(key.location, "{s} attribute is specified more than once", .{name});
        }
        if (other != null) {
            return self.errFmt(key.location, "{s} cannot be combined with {s}", .{ name, other_name });
        }
        return marker;
    }

    fn parseAttributes(self: *LarkParser, definition: *LarkDefinition) LarkError!void {
        _ = try self.consume(.LBracket, "expected '['");
        var stop_capture_location: ?LarkLocation = null;
        while (self.peekType() != .RBracket) {
            const key = try self.consume(.Name, "expected rule attribute");
            if (std.mem.eql(u8, key.text, "lazy")) {
                if (self.peekType() != .Equals) definition.lazy = true else return self.attributeNotSupported(&key);
            } else if (std.mem.eql(u8, key.text, "max_tokens")) {
                _ = try self.consume(.Equals, "expected '=' after max_tokens attribute");
                const value_location = self.peek().location;
                const value = try self.parseInteger();
                if (value <= 0) {
                    return self.err(value_location, "max_tokens must be positive");
                }
                if (value > 1_000_000) {
                    return self.err(value_location, "max_tokens is too large");
                }
                if (definition.max_tokens != null) {
                    return self.duplicate(&key);
                }
                definition.max_tokens = .{ .value = value, .key_location = key.location };
            } else if (std.mem.eql(u8, key.text, "max_chars")) {
                _ = try self.consume(.Equals, "expected '=' after max_chars attribute");
                const value = try self.parseInteger();
                if (definition.max_chars != null) {
                    return self.duplicate(&key);
                }
                definition.max_chars = value;
            } else if (std.mem.eql(u8, key.text, "capture")) {
                const capture: LarkDefinition.CaptureName = if (self.matchToken(.Equals))
                    try self.parseCaptureNameValue("capture")
                else
                    .{ .name = definition.name, .value_location = key.location };
                try self.validateCaptureName(capture.name, capture.value_location);
                if (definition.capture_name != null) {
                    return self.duplicate(&key);
                }
                definition.capture_name = capture;
            } else if (std.mem.eql(u8, key.text, "suffix")) {
                definition.suffix = try self.parseMarkerAttribute(&key, definition.suffix, definition.stop, "stop");
            } else if (std.mem.eql(u8, key.text, "stop")) {
                definition.stop = try self.parseMarkerAttribute(&key, definition.stop, definition.suffix, "suffix");
            } else if (std.mem.eql(u8, key.text, "stop_capture")) {
                _ = try self.consume(.Equals, "expected '=' after stop_capture attribute");
                const captured = try self.parseCaptureNameValue("stop_capture");
                try self.validateCaptureName(captured.name, captured.value_location);
                if (definition.stop_capture_name != null) {
                    return self.duplicate(&key);
                }
                definition.stop_capture_name = captured.name;
                stop_capture_location = captured.value_location;
            } else if (std.mem.eql(u8, key.text, "temperature")) {
                _ = try self.consume(.Equals, "expected '=' after temperature attribute");
                const value = try self.consume(.Number, "expected number after temperature=");
                if (definition.temperature != null) {
                    return self.duplicate(&key);
                }
                const temperature = std.fmt.parseFloat(f32, value.text) catch {
                    return self.err(value.location, "temperature must be a finite non-negative number");
                };
                if (std.math.isFinite(temperature) and temperature >= 0.0) {
                    definition.temperature = temperature;
                } else {
                    return self.err(value.location, "temperature must be a finite non-negative number");
                }
            } else {
                return self.attributeNotSupported(&key);
            }
            if (!self.matchToken(.Comma)) break;
        }
        _ = try self.consume(.RBracket, "expected ']' after rule attributes");
        if (stop_capture_location != null and definition.suffix == null and definition.stop == null) {
            return self.err(stop_capture_location.?, "stop_capture requires stop or suffix");
        }
    }

    fn duplicate(self: *const LarkParser, key: *const LarkToken) LarkError {
        return self.errFmt(key.location, "{s} attribute is specified more than once", .{key.text});
    }

    fn attributeNotSupported(self: *const LarkParser, key: *const LarkToken) LarkError {
        return self.errFmt(key.location, "rule attribute '{s}' is not supported by XGrammar Lark", .{key.text});
    }

    fn parseChoice(self: *LarkParser) LarkError!LarkNode {
        const location = self.peek().location;
        var alternatives: std.ArrayList(LarkNode) = .empty;
        try alternatives.append(self.arena, try self.parseSequence());
        while (self.matchAlternativeSeparator()) {
            try alternatives.append(self.arena, try self.parseSequence());
        }
        if (alternatives.items.len == 1) {
            return alternatives.items[0];
        }
        return LarkNode.withChildren(.Choice, location, alternatives.items, self.arena);
    }

    fn matchAlternativeSeparator(self: *LarkParser) bool {
        if (self.matchToken(.Pipe)) return true;
        const saved_position = self.position;
        self.consumeNewlines();
        if (self.matchToken(.Pipe)) return true;
        switch (self.peekType()) {
            .RParen, .RBracket, .RBrace => return false,
            else => {},
        }
        self.position = saved_position;
        return false;
    }

    fn parseSequence(self: *LarkParser) LarkError!LarkNode {
        const location = self.peek().location;
        var elements: std.ArrayList(LarkNode) = .empty;
        while (true) {
            switch (self.peekType()) {
                .Newline, .Pipe, .RParen, .RBracket, .RBrace, .End, .Arrow, .And, .If => break,
                else => try elements.append(self.arena, try self.parseExpr()),
            }
        }
        if (self.matchToken(.Arrow)) {
            _ = try self.consume(.Name, "expected alias name after '->'");
        }
        try self.reject(.And, "terminal intersection '&' is not supported");
        try self.reject(.If, "parametric %if conditions are not supported");
        return LarkNode.withChildren(.Sequence, location, elements.items, self.arena);
    }

    fn parseInteger(self: *LarkParser) LarkError!i32 {
        const token = try self.consume(.Number, "expected integer");
        const value = std.fmt.parseInt(i64, token.text, 10) catch {
            return self.err(token.location, "invalid repetition count");
        };
        if (value < 0 or value > std.math.maxInt(i32)) {
            return self.err(token.location, "invalid repetition count");
        }
        return @intCast(value);
    }

    fn parseExpr(self: *LarkParser) LarkError!LarkNode {
        const location = self.peek().location;
        const negated = self.matchToken(.Tilde);
        var atom = try self.parseAtom();
        if (negated) {
            atom = try LarkNode.withChildren(.Not, location, &.{atom}, self.arena);
        }

        var min_repeat: i32 = undefined;
        var max_repeat: i32 = undefined;
        if (self.matchToken(.Question)) {
            min_repeat = 0;
            max_repeat = 1;
        } else if (self.matchToken(.Star)) {
            min_repeat = 0;
            max_repeat = -1;
        } else if (self.matchToken(.Plus)) {
            min_repeat = 1;
            max_repeat = -1;
        } else if (self.matchToken(.Tilde)) {
            min_repeat = try self.parseInteger();
            if (self.matchToken(.DotDot)) {
                max_repeat = try self.parseInteger();
            } else {
                max_repeat = min_repeat;
            }
        } else if (self.matchToken(.LBrace)) {
            if (self.peekType() == .Comma) {
                min_repeat = 0;
            } else {
                min_repeat = try self.parseInteger();
            }
            if (!self.matchToken(.Comma)) {
                max_repeat = min_repeat;
            } else if (self.peekType() == .RBrace) {
                max_repeat = -1;
            } else {
                max_repeat = try self.parseInteger();
            }
            _ = try self.consume(.RBrace, "expected '}' after repetition range");
        } else {
            return atom;
        }

        if (max_repeat != -1 and max_repeat < min_repeat) {
            return self.err(location, "repetition end must be greater than or equal to start");
        }
        return LarkNode.repeat(location, atom, min_repeat, max_repeat, self.arena);
    }

    fn parseGroupBody(self: *LarkParser, open: *const LarkToken) LarkError!LarkNode {
        if (self.group_depth >= MAX_GROUP_DEPTH) {
            return self.errFmt(open.location, "groups are nested deeper than {d} levels", .{MAX_GROUP_DEPTH});
        }
        self.group_depth += 1;
        defer self.group_depth -= 1;
        return self.parseChoice();
    }

    fn parseAtom(self: *LarkParser) LarkError!LarkNode {
        const token = self.peek().*;
        self.position += 1;
        const location = token.location;
        switch (token.ty) {
            .LParen => {
                const result = try self.parseGroupBody(&token);
                _ = try self.consume(.RParen, "expected ')' after group");
                return result;
            },
            .LBracket => {
                const inner = try self.parseGroupBody(&token);
                _ = try self.consume(.RBracket, "expected ']' after optional group");
                return LarkNode.repeat(location, inner, 0, 1, self.arena);
            },
            .String => {
                const result = try self.parseStringNode(&token);
                if (!self.matchToken(.DotDot)) {
                    return result;
                }
                const end = try self.consume(.String, "expected string after '..'");
                const end_node = try self.parseStringNode(&end);
                if (result.flags.len != 0) {
                    return self.err(location, "flags are not allowed on character ranges");
                }
                if (end_node.flags.len != 0) {
                    return self.err(end.location, "flags are not allowed on character ranges");
                }
                var node = LarkNode.withText(.Range, location, result.text);
                node.text2 = end_node.text;
                return node;
            },
            .Regex => return regexNode(token),
            .Name => {
                try self.reject(.DoubleColon, "parametric grammar is not supported");
                if (self.peekType() == .LBrace and
                    self.peekAt(1).ty != .Comma and self.peekAt(1).ty != .Number)
                {
                    return self.err(self.peek().location, "Lark templates are not supported");
                }
                return LarkNode.withText(.Name, location, normalizeRuleName(token.text));
            },
            .Json => return LarkNode.withText(.Json, location, token.text),
            .RegexExt => return LarkNode.withText(.RegexExt, location, token.text),
            .SpecialToken => return LarkNode.withText(.SpecialToken, location, token.text),
            .GrammarRef => return LarkNode.withText(.GrammarRef, location, token.text),
            .Lark => {
                _ = try self.consume(.LBrace, "expected '{' after %lark");
                const nested_ptr = try self.arena.create(LarkDocument);
                nested_ptr.* = LarkDocument.initNested(self.arena);
                const saved_doc = self.document;
                self.document = nested_ptr;
                defer self.document = saved_doc;
                try self.parseDocument(true);
                _ = try self.consume(.RBrace, "expected '}' after nested Lark grammar");
                var node = LarkNode.init(.NestedLark, location);
                node.nested = nested_ptr;
                return node;
            },
            .UnsupportedDirective => {
                return self.errFmt(location, "directive {s} is not supported", .{token.text});
            },
            else => return self.err(location, "expected grammar expression"),
        }
    }

    fn parseStringNode(self: *const LarkParser, token: *const LarkToken) LarkError!LarkNode {
        var json_string = token.text;
        var flags: []const u8 = "";
        if (json_string.len != 0 and json_string[json_string.len - 1] == 'i') {
            json_string = json_string[0 .. json_string.len - 1];
            flags = "i";
        }
        const parsed = support.parseJson(self.arena, json_string) catch |parse_error| switch (parse_error) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return self.errFmt(token.location, "invalid string literal: {s}", .{@errorName(parse_error)}),
        };
        switch (parsed) {
            .string => |text| {
                var node = LarkNode.withText(.String, token.location, text);
                node.flags = flags;
                return node;
            },
            else => return self.err(token.location, "invalid string literal: "),
        }
    }
};

fn isAsciiAlphabetic(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isAsciiDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isAsciiAlphanumeric(c: u8) bool {
    return isAsciiAlphabetic(c) or isAsciiDigit(c);
}

test "LarkParser parses nested %lark cleanly and reports located errors with zero leaks" {
    const a = std.testing.allocator;
    var diag: Diagnostic = .{};
    defer diag.deinit(a);

    var doc = try parse(a, "start: %lark {\n  start: \"ok\"\n}\n", &diag);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 1), doc.definitions.items.len);
    const nested = doc.definitions.items[0].body.children.items[0].nested.?;
    try std.testing.expect(nested.arena == null);
    try std.testing.expectEqual(@as(usize, 1), nested.definitions.items.len);

    // Invalid rule attribute sets .lark_located diagnostic without leaks.
    try std.testing.expectError(error.Lark, parse(a, "start[unknown=1]: \"x\"", &diag));
    const msg = try diag.formatAlloc(a);
    defer a.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "rule attribute 'unknown' is not supported") != null);
}
