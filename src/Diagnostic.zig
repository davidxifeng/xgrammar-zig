//! Unified zero-value-safe diagnostic payload replacing per-module error info structs.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Zero-initialized diagnostic carrier (`var diag: Diagnostic = .{}; defer diag.deinit(allocator);`).
///
/// Safe to pass unpopulated, safe across repeated reuse (setters free prior owned slices),
/// and implements `{f}` formatting (`std.fmt.allocPrint(a, "{f}", .{diag})`).
pub const Diagnostic = struct {
    pub const Kind = enum {
        none,
        message,
        ebnf_lexer,
        ebnf_parser,
        lark_located,
        regex,
        structural_tag_invalid_json,
        structural_tag_invalid_schema,
        structural_tag_invalid,
        deserialize_invalid_json,
        deserialize_format,
        deserialize_version,
        tokenizer_vocab_too_small,
        functor_invalid_repetition_range,
        functor_lazy_rule_body_not_choices,
        functor_lazy_rule_element_not_terminal,
        compile_token_id_out_of_range,
        matcher_terminated,
        matcher_empty_override_stop_tokens,
        matcher_stop_token_out_of_range,
        matcher_invalid_default_temperature,
        matcher_rollback_too_far,
        recursion_depth_exceeded,
        recursion_invalid_max,
    };

    pub const Location = struct {
        line: usize = 0,
        column: usize = 0,
        position: usize = 0,
    };

    kind: Kind = .none,
    message: []const u8 = "",
    source_line: []const u8 = "",
    expected: []const u8 = "",
    got: []const u8 = "",
    location: ?Location = null,
    primary_num: i64 = 0,
    secondary_num: i64 = 0,

    owned_alloc: ?Allocator = null,
    message_owned: bool = false,
    source_line_owned: bool = false,
    got_owned: bool = false,

    pub const empty: Diagnostic = .{};

    pub fn deinit(self: *Diagnostic, fallback_allocator: Allocator) void {
        self.clear(fallback_allocator);
    }

    pub fn clear(self: *Diagnostic, fallback_allocator: Allocator) void {
        const a = self.owned_alloc orelse fallback_allocator;
        if (self.message_owned) a.free(self.message);
        if (self.source_line_owned) a.free(self.source_line);
        if (self.got_owned) a.free(self.got);
        self.* = .{};
    }

    fn clearUsingStored(self: *Diagnostic) void {
        if (self.owned_alloc) |a| {
            if (self.message_owned) a.free(self.message);
            if (self.source_line_owned) a.free(self.source_line);
            if (self.got_owned) a.free(self.got);
        }
        self.* = .{};
    }

    pub fn setStatic(self: *Diagnostic, kind: Kind, msg: []const u8) void {
        self.clearUsingStored();
        self.kind = kind;
        self.message = msg;
    }

    pub fn setOwned(self: *Diagnostic, allocator: Allocator, kind: Kind, msg_owned: []const u8) void {
        self.clear(allocator);
        self.kind = kind;
        self.message = msg_owned;
        self.owned_alloc = allocator;
        self.message_owned = true;
    }

    pub fn setCopy(self: *Diagnostic, allocator: Allocator, kind: Kind, msg: []const u8) Allocator.Error!void {
        const duped = try allocator.dupe(u8, msg);
        self.clear(allocator);
        self.kind = kind;
        self.message = duped;
        self.owned_alloc = allocator;
        self.message_owned = true;
    }

    pub fn setFmt(
        self: *Diagnostic,
        allocator: Allocator,
        kind: Kind,
        comptime fmt: []const u8,
        args: anytype,
    ) Allocator.Error!void {
        const msg = try std.fmt.allocPrint(allocator, fmt, args);
        self.clear(allocator);
        self.kind = kind;
        self.message = msg;
        self.owned_alloc = allocator;
        self.message_owned = true;
    }

    pub fn setLocatedFmt(
        self: *Diagnostic,
        allocator: Allocator,
        kind: Kind,
        line: usize,
        column: usize,
        source_line_slice: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) Allocator.Error!void {
        const msg = try std.fmt.allocPrint(allocator, fmt, args);
        errdefer allocator.free(msg);
        const line_copy: []const u8 = if (source_line_slice.len > 0)
            try allocator.dupe(u8, source_line_slice)
        else
            "";
        self.clear(allocator);
        self.kind = kind;
        self.message = msg;
        self.source_line = line_copy;
        self.location = .{ .line = line, .column = column };
        self.owned_alloc = allocator;
        self.message_owned = true;
        self.source_line_owned = line_copy.len > 0;
    }

    pub fn setAtOffsetFmt(
        self: *Diagnostic,
        allocator: Allocator,
        kind: Kind,
        position: usize,
        comptime fmt: []const u8,
        args: anytype,
    ) Allocator.Error!void {
        const msg = try std.fmt.allocPrint(allocator, fmt, args);
        self.clear(allocator);
        self.kind = kind;
        self.message = msg;
        self.location = .{ .position = position };
        self.owned_alloc = allocator;
        self.message_owned = true;
    }

    pub fn setVersionMismatch(
        self: *Diagnostic,
        allocator: Allocator,
        expected: []const u8,
        got: []const u8,
    ) Allocator.Error!void {
        const got_copy = try allocator.dupe(u8, got);
        self.clear(allocator);
        self.kind = .deserialize_version;
        self.expected = expected;
        self.got = got_copy;
        self.owned_alloc = allocator;
        self.got_owned = true;
    }

    pub fn setNumbers(
        self: *Diagnostic,
        kind: Kind,
        primary: i64,
        secondary: i64,
    ) void {
        self.clearUsingStored();
        self.kind = kind;
        self.primary_num = primary;
        self.secondary_num = secondary;
    }

    pub fn setNamedAndKind(
        self: *Diagnostic,
        allocator: Allocator,
        kind: Kind,
        name: []const u8,
    ) Allocator.Error!void {
        try self.setCopy(allocator, kind, name);
    }

    pub fn format(self: Diagnostic, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.kind) {
            .none => {},
            .message => try writer.writeAll(self.message),
            .ebnf_lexer => {
                const loc = self.location orelse Location{};
                try writer.print("EBNF lexer error at line {d}, column {d}: {s}", .{
                    loc.line, loc.column, self.message,
                });
            },
            .ebnf_parser => {
                const loc = self.location orelse Location{};
                try writer.print("EBNF parser error at line {d}, column {d}: {s}", .{
                    loc.line, loc.column, self.message,
                });
            },
            .lark_located => {
                const loc = self.location orelse Location{};
                try writer.print("Lark error at line {d}, column {d}: {s}", .{
                    loc.line, loc.column, self.message,
                });
                if (self.source_line.len > 0) {
                    try writer.print("\n{s}\n", .{self.source_line});
                    const pad = if (loc.column > 0) loc.column - 1 else 0;
                    for (0..pad) |_| try writer.writeByte(' ');
                    try writer.writeByte('^');
                }
            },
            .regex => {
                const loc = self.location orelse Location{};
                try writer.print("Regex parsing error at position {d}: {s}", .{
                    loc.position, self.message,
                });
            },
            .structural_tag_invalid_json => try writer.print("Invalid JSON error: {s}", .{self.message}),
            .structural_tag_invalid_schema => try writer.print("Invalid JSON schema error: {s}", .{self.message}),
            .structural_tag_invalid => try writer.print("Invalid structural tag error: {s}", .{self.message}),
            .deserialize_invalid_json => try writer.print("invalid JSON: {s}", .{self.message}),
            .deserialize_format => try writer.print("invalid format: {s}", .{self.message}),
            .deserialize_version => try writer.print("version mismatch: expected {s}, got {s}", .{
                self.expected, self.got,
            }),
            .tokenizer_vocab_too_small => try writer.print(
                "vocab_size ({d}) must be at least the number of tokens in the vocab ({d}).",
                .{ self.primary_num, self.secondary_num },
            ),
            .functor_invalid_repetition_range => try writer.print(
                "Invalid repetition range {{{d}, {d}}}",
                .{ self.primary_num, self.secondary_num },
            ),
            .functor_lazy_rule_body_not_choices => try writer.print(
                "lazy rule '{s}' must have a terminal-like body",
                .{self.message},
            ),
            .functor_lazy_rule_element_not_terminal => try writer.print(
                "lazy rule '{s}' must have a terminal-like body (strings, character classes, and regexes that " ++
                    "compile to a single FSM); rule references and repetition ranges are not supported",
                .{self.message},
            ),
            .compile_token_id_out_of_range => try writer.print(
                "Token id {d} in the grammar is out of the vocabulary range [0, {d})",
                .{ self.primary_num, self.secondary_num },
            ),
            .matcher_terminated => try writer.print(
                "GrammarMatcher has terminated after accepting the stop token, but is trying to {s}",
                .{self.message},
            ),
            .matcher_empty_override_stop_tokens => try writer.writeAll(
                "The override_stop_tokens should not be empty",
            ),
            .matcher_stop_token_out_of_range => try writer.print(
                "The override stop token id {d} is out of the vocabulary range [0, {d})",
                .{ self.primary_num, self.secondary_num },
            ),
            .matcher_invalid_default_temperature => try writer.writeAll(
                "The default_temperature must be a finite non-negative number",
            ),
            .matcher_rollback_too_far => try writer.print(
                "Intended to rollback {d} tokens, but only the last {d} steps of history are saved",
                .{ self.primary_num, self.secondary_num },
            ),
            .recursion_depth_exceeded => try writer.print(
                "RecursionGuard: Maximum recursion depth exceeded. Current depth: {d}, Max allowed: {d}",
                .{ self.primary_num, self.secondary_num },
            ),
            .recursion_invalid_max => try writer.print(
                "RecursionGuard: Maximum recursion depth must be positive and less than {d}, got: {d}",
                .{ self.primary_num, self.secondary_num },
            ),
        }
    }

    pub fn formatAlloc(self: Diagnostic, allocator: Allocator) Allocator.Error![]u8 {
        return std.fmt.allocPrint(allocator, "{f}", .{self});
    }
};

/// Captures `source[line_start..line_end]` for `line` (1-based).
pub fn extractSourceLine(source: []const u8, target_line: usize) []const u8 {
    var line_start: usize = 0;
    var current_line: usize = 1;
    while (current_line < target_line and line_start < source.len) {
        if (std.mem.indexOfScalarPos(u8, source, line_start, '\n')) |offset| {
            line_start = offset + 1;
            current_line += 1;
        } else {
            line_start = source.len;
            break;
        }
    }
    const line_end = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len;
    return source[line_start..line_end];
}

test "Diagnostic zero init, reuse, format, and leak-free deinit" {
    const a = std.testing.allocator;
    var diag: Diagnostic = .{};
    defer diag.deinit(a);

    try diag.setFmt(a, .message, "bad value {d}", .{42});
    const m1 = try diag.formatAlloc(a);
    defer a.free(m1);
    try std.testing.expectEqualStrings("bad value 42", m1);

    // Overwrite with located lark diagnostic — prior owned buffer must be freed cleanly.
    try diag.setLocatedFmt(a, .lark_located, 2, 5, "foo: bar?", "unexpected '{s}'", .{"?"});
    const m2 = try diag.formatAlloc(a);
    defer a.free(m2);
    try std.testing.expectEqualStrings("Lark error at line 2, column 5: unexpected '?'\nfoo: bar?\n    ^", m2);

    // Overwrite with static diagnostic — prior owned slices still freed via stored allocator.
    diag.setStatic(.matcher_empty_override_stop_tokens, "");
    const m3 = try diag.formatAlloc(a);
    defer a.free(m3);
    try std.testing.expectEqualStrings("The override_stop_tokens should not be empty", m3);

    // Version mismatch and token id out of range.
    try diag.setVersionMismatch(a, "v16", "v15");
    const m4 = try diag.formatAlloc(a);
    defer a.free(m4);
    try std.testing.expectEqualStrings("version mismatch: expected v16, got v15", m4);

    diag.setNumbers(.compile_token_id_out_of_range, 42, 10);
    const m5 = try diag.formatAlloc(a);
    defer a.free(m5);
    try std.testing.expectEqualStrings("Token id 42 in the grammar is out of the vocabulary range [0, 10)", m5);
}
