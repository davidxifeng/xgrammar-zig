//! Recursive-descent parser for the Lark grammar syntax (`lark_parser.rs`).
//!
//! All AST nodes, strings, and JSON values live in the returned document's arena (nested
//! `%lark` documents allocate from the parent arena and are reclaimed with it — Rust
//! `Rc<LarkDocument>` collapsed into arena ownership).

const std = @import("std");
const Allocator = std.mem.Allocator;
const lark_definition = @import("lark_definition.zig");
const lark_document = @import("lark_document.zig");
const lark_error = @import("lark_error.zig");
const lark_import = @import("lark_import.zig");
const lark_lexer = @import("lark_lexer.zig");
const lark_location = @import("lark_location.zig");
const lark_node = @import("lark_node.zig");
const lark_node_kind = @import("lark_node_kind.zig");
const lark_token = @import("lark_token.zig");
const lark_token_type = @import("lark_token_type.zig");
const support = @import("../support/mod.zig");
const LarkDefinition = lark_definition.LarkDefinition;
const LarkDocument = lark_document.LarkDocument;
const LarkError = lark_error.LarkError;
const LarkErrorInfo = lark_error.LarkErrorInfo;
const LarkImport = lark_import.LarkImport;
const LarkLexer = lark_lexer.LarkLexer;
const LarkLocation = lark_location.LarkLocation;
const LarkNode = lark_node.LarkNode;
const LarkNodeKind = lark_node_kind.LarkNodeKind;
const LarkToken = lark_token.LarkToken;
const LarkTokenType = lark_token_type.LarkTokenType;
const parse_json = support.json_parse.parse_json;

/// Groups recurse `parse_choice -> parse_sequence -> parse_expr -> parse_atom` once per
/// level, so the nesting depth is bounded instead of overflowing the stack.
const MAX_GROUP_DEPTH: i32 = 200;

/// Parses Lark tokens into a `LarkDocument`.
///
/// `diag` (optional) receives the failure payload; its strings are allocated from `gpa`.
pub fn parse(gpa: Allocator, source: []const u8, diag: ?*?LarkErrorInfo) LarkError!LarkDocument {
    return parse_nested(gpa, source, diag, null);
}

/// `parse` for an inline `%lark` block: `parent_alloc` is the enclosing document's arena
/// allocator, so the nested document is reclaimed with its parent.
pub fn parse_nested(gpa: Allocator, source: []const u8, diag: ?*?LarkErrorInfo, parent_alloc: ?Allocator) LarkError!LarkDocument {
    const arena_backing = parent_alloc orelse gpa;
    var document = if (parent_alloc != null)
        try LarkDocument.create_nested(arena_backing)
    else
        try LarkDocument.create(gpa);
    errdefer if (parent_alloc == null) document.deinit();
    var lexer = LarkLexer{ .gpa = gpa, .diag = diag, .arena = document.allocator(), .source = source };
    const tokens = try lexer.tokenize();
    var parser = LarkParser{
        .gpa = gpa,
        .diag = diag,
        .arena = document.allocator(),
        .source = source,
        .tokens = tokens,
        .document = &document,
    };
    try parser.parse_document(false);
    return document;
}

pub const LarkParser = struct {
    gpa: Allocator,
    diag: ?*?LarkErrorInfo,
    /// The document being built (its arena allocates every node and string).
    arena: Allocator,
    source: []const u8,
    tokens: std.ArrayList(LarkToken),
    position: usize = 0,
    group_depth: i32 = 0,
    document: *LarkDocument,

    fn err(self: *const LarkParser, location: LarkLocation, message: []const u8) LarkError {
        if (self.diag) |d| {
            lark_error.set_info(d, try lark_error.at(self.gpa, self.source, location, message), self.gpa) catch return error.OutOfMemory;
        }
        return error.Lark;
    }

    fn err_fmt(self: *const LarkParser, location: LarkLocation, comptime fmt: []const u8, args: anytype) LarkError {
        const message = std.fmt.allocPrint(self.gpa, fmt, args) catch return error.OutOfMemory;
        defer self.gpa.free(message);
        return self.err(location, message);
    }

    fn peek_at(self: *const LarkParser, offset: usize) *const LarkToken {
        return &self.tokens.items[@min(self.position + offset, self.tokens.items.len - 1)];
    }

    fn peek(self: *const LarkParser) *const LarkToken {
        return self.peek_at(0);
    }

    fn peek_type(self: *const LarkParser) LarkTokenType {
        return self.peek().ty;
    }

    fn match_token(self: *LarkParser, ty: LarkTokenType) bool {
        if (self.peek_type() != ty) return false;
        self.position += 1;
        return true;
    }

    fn consume(self: *LarkParser, ty: LarkTokenType, message: []const u8) LarkError!LarkToken {
        if (self.peek_type() != ty) {
            return self.err(self.peek().location, message);
        }
        self.position += 1;
        return self.tokens.items[self.position - 1];
    }

    /// Fails with `message` at the next token if it has type `ty`.
    fn reject(self: *const LarkParser, ty: LarkTokenType, message: []const u8) LarkError!void {
        if (self.peek_type() == ty) {
            return self.err(self.peek().location, message);
        }
    }

    fn consume_newlines(self: *LarkParser) void {
        while (self.match_token(.Newline)) {}
    }

    fn parse_document(self: *LarkParser, stop_at_rbrace: bool) LarkError!void {
        const at_end = struct {
            fn check(ty: LarkTokenType, stop: bool) bool {
                return ty == .End or (stop and ty == .RBrace);
            }
        }.check;
        self.consume_newlines();
        while (!at_end(self.peek_type(), stop_at_rbrace)) {
            switch (self.peek_type()) {
                .Import => try self.parse_import(),
                .Ignore => {
                    self.position += 1;
                    const ignore = try self.parse_choice();
                    try self.document.ignores.append(self.arena, ignore);
                },
                .GrammarOptions => {
                    const token = try self.consume(.GrammarOptions, "expected %grammar_options");
                    const value = parse_json(self.arena, token.text) catch |parse_error| {
                        return self.err_fmt(token.location, "invalid %grammar_options value: {s}", .{@errorName(parse_error)});
                    };
                    try self.document.options.append(self.arena, .{ .value = value, .location = token.location });
                },
                .UnsupportedDirective => {
                    return self.err_fmt(self.peek().location, "directive {s} is not supported", .{self.peek().text});
                },
                else => {
                    const definition = try self.parse_definition();
                    try self.document.definitions.append(self.arena, definition);
                },
            }
            if (self.peek_type() != .Newline and !at_end(self.peek_type(), stop_at_rbrace)) {
                return self.err(self.peek().location, "expected end of grammar item");
            }
            self.consume_newlines();
        }
    }

    fn is_terminal_name(raw_name: []const u8) bool {
        var name = raw_name;
        if (name.len != 0 and (name[0] == '!' or name[0] == '?')) name = name[1..];
        if (name.len != 0 and name[0] == '_') name = name[1..];
        return name.len != 0 and name[0] >= 'A' and name[0] <= 'Z';
    }

    fn normalize_rule_name(name: []const u8) []const u8 {
        if (name.len != 0 and (name[0] == '!' or name[0] == '?')) return name[1..];
        return name;
    }

    fn validate_capture_name(self: *const LarkParser, capture_name: []const u8, location: LarkLocation) LarkError!void {
        if (capture_name.len == 0) {
            return self.err(location, "capture name must not be empty");
        }
        for (capture_name) |c| {
            if (!is_ascii_alphanumeric(c) and c != '_' and c != '-' and c != '.') {
                return self.err(location, "capture name must only contain letters, digits, '_', '-' and '.'");
            }
        }
    }

    fn parse_stop_like_value(self: *LarkParser, attribute_name: []const u8) LarkError!LarkNode {
        const token = self.peek().*;
        switch (token.ty) {
            .String => {
                self.position += 1;
                return self.parse_string_node(&token);
            },
            .Regex => {
                self.position += 1;
                return regex_node(token);
            },
            .Name => {
                self.position += 1;
                if (!is_terminal_name(token.text)) {
                    return self.err_fmt(token.location, "{s} terminal name must be uppercase", .{attribute_name});
                }
                return LarkNode.with_text(.Name, token.location, normalize_rule_name(token.text));
            },
            else => {
                return self.err_fmt(
                    token.location,
                    "expected string literal, regular expression, or uppercase terminal name after {s}=",
                    .{attribute_name},
                );
            },
        }
    }

    fn regex_node(token: LarkToken) LarkNode {
        var node = LarkNode.with_text(.Regex, token.location, token.text);
        node.flags = token.flags;
        return node;
    }

    fn parse_import(self: *LarkParser) LarkError!void {
        const location = (try self.consume(.Import, "expected %import")).location;
        var path: std.ArrayList(u8) = .empty;
        try path.appendSlice(self.arena, (try self.consume(.Name, "expected import path")).text);
        while (self.match_token(.Dot)) {
            try path.append(self.arena, '.');
            try path.appendSlice(self.arena, (try self.consume(.Name, "expected name after '.'")).text);
        }

        if (self.match_token(.LParen)) {
            while (true) {
                const name = try self.consume(.Name, "expected imported terminal name");
                try self.document.imports.append(self.arena, .{
                    .path = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ path.items, name.text }),
                    .local_name = name.text,
                    .location = location,
                });
                if (!self.match_token(.Comma)) break;
            }
            _ = try self.consume(.RParen, "expected ')' after import list");
            return;
        }

        var local_name: []const u8 = undefined;
        if (std.mem.lastIndexOfScalar(u8, path.items, '.')) |dot| {
            local_name = path.items[dot + 1 ..];
        } else {
            local_name = path.items;
        }
        if (self.match_token(.Arrow)) {
            local_name = (try self.consume(.Name, "expected import alias")).text;
        }
        try self.document.imports.append(self.arena, .{
            .path = try self.arena.dupe(u8, path.items),
            .local_name = local_name,
            .location = location,
        });
    }

    fn parse_definition(self: *LarkParser) LarkError!LarkDefinition {
        const name_token = try self.consume(.Name, "expected rule or terminal name");
        var definition = LarkDefinition.new(
            normalize_rule_name(name_token.text),
            is_terminal_name(name_token.text),
            LarkNode.new(.Sequence, name_token.location),
            name_token.location,
        );

        if (self.peek_type() == .LBracket) {
            if (definition.is_terminal) {
                return self.err(self.peek().location, "attributes are only supported on rules");
            }
            try self.parse_attributes(&definition);
        }
        try self.reject(.Dot, "rule and terminal priorities are not supported");
        try self.reject(.DoubleColon, "parametric grammar is not supported");
        try self.reject(.LBrace, "Lark templates are not supported");
        _ = try self.consume(.Colon, "expected ':' after rule name");
        definition.body = try self.parse_choice();
        return definition;
    }

    /// Parses a string-literal attribute value that must be a valid capture name.
    fn parse_capture_name_value(self: *LarkParser, attribute_name: []const u8) LarkError!LarkDefinition.CaptureName {
        const message = try std.fmt.allocPrint(self.gpa, "expected string literal after {s}=", .{attribute_name});
        defer self.gpa.free(message);
        const token = try self.consume(.String, message);
        const node = try self.parse_string_node(&token);
        if (node.flags.len != 0) {
            return self.err_fmt(node.location, "case-insensitive flags are not supported on {s}", .{attribute_name});
        }
        return .{ .name = node.text, .value_location = node.location };
    }

    /// Parses a `suffix=` or `stop=` value; `other` is the attribute it cannot be combined with.
    fn parse_marker_attribute(
        self: *LarkParser,
        key: *const LarkToken,
        current: ?LarkNode,
        other: ?LarkNode,
        other_name: []const u8,
    ) LarkError!LarkNode {
        const name = key.text;
        {
            const message = try std.fmt.allocPrint(self.gpa, "expected '=' after {s} attribute", .{name});
            defer self.gpa.free(message);
            _ = try self.consume(.Equals, message);
        }
        const marker = try self.parse_stop_like_value(name);
        if (marker.kind == .String and marker.text.len == 0) {
            return self.err_fmt(marker.location, "{s} must not be empty", .{name});
        }
        if (current != null) {
            return self.err_fmt(key.location, "{s} attribute is specified more than once", .{name});
        }
        if (other != null) {
            return self.err_fmt(key.location, "{s} cannot be combined with {s}", .{ name, other_name });
        }
        return marker;
    }

    fn parse_attributes(self: *LarkParser, definition: *LarkDefinition) LarkError!void {
        _ = try self.consume(.LBracket, "expected '['");
        var stop_capture_location: ?LarkLocation = null;
        while (self.peek_type() != .RBracket) {
            const key = try self.consume(.Name, "expected rule attribute");
            if (std.mem.eql(u8, key.text, "lazy")) {
                if (self.peek_type() != .Equals) definition.lazy = true else return self.attribute_not_supported(&key);
            } else
                if (std.mem.eql(u8, key.text, "max_tokens")) {
                    {
                        const message = try std.fmt.allocPrint(self.gpa, "expected '=' after max_tokens attribute", .{});
                        defer self.gpa.free(message);
                        _ = try self.consume(.Equals, message);
                    }
                    const value_location = self.peek().location;
                    const value = try self.parse_integer();
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
                    {
                        const message = try std.fmt.allocPrint(self.gpa, "expected '=' after max_chars attribute", .{});
                        defer self.gpa.free(message);
                        _ = try self.consume(.Equals, message);
                    }
                    const value = try self.parse_integer();
                    if (definition.max_chars != null) {
                        return self.duplicate(&key);
                    }
                    definition.max_chars = value;
                } else if (std.mem.eql(u8, key.text, "capture")) {
                    var capture: LarkDefinition.CaptureName = undefined;
                    if (self.match_token(.Equals)) {
                        capture = try self.parse_capture_name_value("capture");
                    } else {
                        capture = .{ .name = definition.name, .value_location = key.location };
                    }
                    try self.validate_capture_name(capture.name, capture.value_location);
                    if (definition.capture_name != null) {
                        return self.duplicate(&key);
                    }
                    definition.capture_name = capture;
                } else if (std.mem.eql(u8, key.text, "suffix")) {
                    const suffix = try self.parse_marker_attribute(&key, definition.suffix, definition.stop, "stop");
                    definition.suffix = suffix;
                } else if (std.mem.eql(u8, key.text, "stop")) {
                    const stop = try self.parse_marker_attribute(&key, definition.stop, definition.suffix, "suffix");
                    definition.stop = stop;
                } else if (std.mem.eql(u8, key.text, "stop_capture")) {
                    {
                        const message = try std.fmt.allocPrint(self.gpa, "expected '=' after stop_capture attribute", .{});
                        defer self.gpa.free(message);
                        _ = try self.consume(.Equals, message);
                    }
                    const captured = try self.parse_capture_name_value("stop_capture");
                    try self.validate_capture_name(captured.name, captured.value_location);
                    if (definition.stop_capture_name != null) {
                        return self.duplicate(&key);
                    }
                    definition.stop_capture_name = captured.name;
                    stop_capture_location = captured.value_location;
                } else if (std.mem.eql(u8, key.text, "temperature")) {
                    {
                        const message = try std.fmt.allocPrint(self.gpa, "expected '=' after temperature attribute", .{});
                        defer self.gpa.free(message);
                        _ = try self.consume(.Equals, message);
                    }
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
                    return self.attribute_not_supported(&key);
                }
            if (!self.match_token(.Comma)) break;
        }
        _ = try self.consume(.RBracket, "expected ']' after rule attributes");
        if (stop_capture_location != null and definition.suffix == null and definition.stop == null) {
            return self.err(stop_capture_location.?, "stop_capture requires stop or suffix");
        }
    }

    fn duplicate(self: *const LarkParser, key: *const LarkToken) LarkError {
        return self.err_fmt(key.location, "{s} attribute is specified more than once", .{key.text});
    }

    fn attribute_not_supported(self: *const LarkParser, key: *const LarkToken) LarkError {
        return self.err_fmt(key.location, "rule attribute '{s}' is not supported by XGrammar Lark", .{key.text});
    }

    fn parse_choice(self: *LarkParser) LarkError!LarkNode {
        const location = self.peek().location;
        var alternatives: std.ArrayList(LarkNode) = .empty;
        try alternatives.append(self.arena, try self.parse_sequence());
        while (try self.match_alternative_separator()) {
            try alternatives.append(self.arena, try self.parse_sequence());
        }
        if (alternatives.items.len == 1) {
            return alternatives.items[0];
        }
        return LarkNode.with_children(.Choice, location, alternatives.items, self.arena);
    }

    fn match_alternative_separator(self: *LarkParser) LarkError!bool {
        if (self.match_token(.Pipe)) return true;
        const saved_position = self.position;
        self.consume_newlines();
        if (self.match_token(.Pipe)) return true;
        switch (self.peek_type()) {
            .RParen, .RBracket, .RBrace => return false,
            else => {},
        }
        self.position = saved_position;
        return false;
    }

    fn parse_sequence(self: *LarkParser) LarkError!LarkNode {
        const location = self.peek().location;
        var elements: std.ArrayList(LarkNode) = .empty;
        while (true) {
            switch (self.peek_type()) {
                .Newline, .Pipe, .RParen, .RBracket, .RBrace, .End, .Arrow, .And, .If => break,
                else => try elements.append(self.arena, try self.parse_expr()),
            }
        }
        if (self.match_token(.Arrow)) {
            _ = try self.consume(.Name, "expected alias name after '->'");
        }
        try self.reject(.And, "terminal intersection '&' is not supported");
        try self.reject(.If, "parametric %if conditions are not supported");
        return LarkNode.with_children(.Sequence, location, elements.items, self.arena);
    }

    fn parse_integer(self: *LarkParser) LarkError!i32 {
        const token = try self.consume(.Number, "expected integer");
        const value = std.fmt.parseInt(i64, token.text, 10) catch {
            return self.err(token.location, "invalid repetition count");
        };
        if (value < 0 or value > std.math.maxInt(i32)) {
            return self.err(token.location, "invalid repetition count");
        }
        return @intCast(value);
    }

    fn parse_expr(self: *LarkParser) LarkError!LarkNode {
        const location = self.peek().location;
        const negated = self.match_token(.Tilde);
        var atom = try self.parse_atom();
        if (negated) {
            atom = try LarkNode.with_children(.Not, location, &.{atom}, self.arena);
        }

        var min_repeat: i32 = undefined;
        var max_repeat: i32 = undefined;
        if (self.match_token(.Question)) {
            min_repeat = 0;
            max_repeat = 1;
        } else if (self.match_token(.Star)) {
            min_repeat = 0;
            max_repeat = -1;
        } else if (self.match_token(.Plus)) {
            min_repeat = 1;
            max_repeat = -1;
        } else if (self.match_token(.Tilde)) {
            min_repeat = try self.parse_integer();
            if (self.match_token(.DotDot)) {
                max_repeat = try self.parse_integer();
            } else {
                max_repeat = min_repeat;
            }
        } else if (self.match_token(.LBrace)) {
            if (self.peek_type() == .Comma) {
                min_repeat = 0;
            } else {
                min_repeat = try self.parse_integer();
            }
            if (!self.match_token(.Comma)) {
                max_repeat = min_repeat;
            } else if (self.peek_type() == .RBrace) {
                max_repeat = -1;
            } else {
                max_repeat = try self.parse_integer();
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

    fn parse_group_body(self: *LarkParser, open: *const LarkToken) LarkError!LarkNode {
        if (self.group_depth >= MAX_GROUP_DEPTH) {
            return self.err_fmt(open.location, "groups are nested deeper than {d} levels", .{MAX_GROUP_DEPTH});
        }
        self.group_depth += 1;
        const result = self.parse_choice();
        self.group_depth -= 1;
        return result;
    }

    fn parse_atom(self: *LarkParser) LarkError!LarkNode {
        const token = self.peek().*;
        self.position += 1;
        const location = token.location;
        switch (token.ty) {
            .LParen => {
                const result = try self.parse_group_body(&token);
                _ = try self.consume(.RParen, "expected ')' after group");
                return result;
            },
            .LBracket => {
                const inner = try self.parse_group_body(&token);
                _ = try self.consume(.RBracket, "expected ']' after optional group");
                return LarkNode.repeat(location, inner, 0, 1, self.arena);
            },
            .String => {
                const result = try self.parse_string_node(&token);
                if (!self.match_token(.DotDot)) {
                    return result;
                }
                const end = try self.consume(.String, "expected string after '..'");
                const end_node = try self.parse_string_node(&end);
                if (result.flags.len != 0) {
                    return self.err(location, "flags are not allowed on character ranges");
                }
                if (end_node.flags.len != 0) {
                    return self.err(end.location, "flags are not allowed on character ranges");
                }
                var node = LarkNode.with_text(.Range, location, result.text);
                node.text2 = end_node.text;
                return node;
            },
            .Regex => return regex_node(token),
            .Name => {
                try self.reject(.DoubleColon, "parametric grammar is not supported");
                if (self.peek_type() == .LBrace and
                    self.peek_at(1).ty != .Comma and self.peek_at(1).ty != .Number)
                {
                    return self.err(self.peek().location, "Lark templates are not supported");
                }
                return LarkNode.with_text(.Name, location, normalize_rule_name(token.text));
            },
            .Json => return LarkNode.with_text(.Json, location, token.text),
            .RegexExt => return LarkNode.with_text(.RegexExt, location, token.text),
            .SpecialToken => return LarkNode.with_text(.SpecialToken, location, token.text),
            .GrammarRef => return LarkNode.with_text(.GrammarRef, location, token.text),
            .Lark => {
                _ = try self.consume(.LBrace, "expected '{' after %lark");
                // The nested document allocates from this document's arena (see module doc).
                const nested_ptr = try self.arena.create(LarkDocument);
                nested_ptr.* = try LarkDocument.create_nested(self.arena);
                const saved_doc = self.document;
                self.document = nested_ptr;
                defer self.document = saved_doc;
                try self.parse_document(true);
                _ = try self.consume(.RBrace, "expected '}' after nested Lark grammar");
                var node = LarkNode.new(.NestedLark, location);
                node.nested = nested_ptr;
                return node;
            },
            .UnsupportedDirective => {
                return self.err_fmt(location, "directive {s} is not supported", .{token.text});
            },
            else => return self.err(location, "expected grammar expression"),
        }
    }

    fn parse_string_node(self: *const LarkParser, token: *const LarkToken) LarkError!LarkNode {
        // A trailing `i` selects the case-insensitive variant (lex_string consumed it).
        var json_string = token.text;
        var flags: []const u8 = "";
        if (json_string.len != 0 and json_string[json_string.len - 1] == 'i') {
            json_string = json_string[0 .. json_string.len - 1];
            flags = "i";
        }
        const parsed = parse_json(self.arena, json_string) catch |parse_error| {
            return self.err_fmt(token.location, "invalid string literal: {s}", .{@errorName(parse_error)});
        };
        switch (parsed) {
            .string => |text| {
                var node = LarkNode.with_text(.String, token.location, text);
                node.flags = flags;
                return node;
            },
            else => return self.err(token.location, "invalid string literal: "),
        }
    }
};

fn is_ascii_alphabetic(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn is_ascii_digit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn is_ascii_alphanumeric(c: u8) bool {
    return is_ascii_alphabetic(c) or is_ascii_digit(c);
}
