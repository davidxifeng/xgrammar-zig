//! EBNF printing for `Grammar` (`printer.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_mod = @import("grammar.zig");
const Grammar = grammar_mod.Grammar;
const grammar_expr_mod = @import("grammar_expr.zig");
const GrammarExpr = grammar_expr_mod.GrammarExpr;
const grammar_expr_type = @import("grammar_expr_type.zig");
const GrammarExprType = grammar_expr_type.GrammarExprType;
const rule_mod = @import("rule.zig");
const NO_EXPR = rule_mod.NO_EXPR;
const support = @import("../support/mod.zig");
const CodepointEscape = support.encoding.CodepointEscape;

/// Custom escapes used inside character classes: `-` and `]` are backslash-escaped.
const CHAR_CLASS_ESCAPES = [_]CodepointEscape{
    .{ .codepoint = 0x2D, .escape = "\\-" },
    .{ .codepoint = 0x5D, .escape = "\\]" },
};

/// Renders the grammar back to its normalized EBNF text (one rule per line)
/// (Rust `Grammar::to_string_ebnf` / `Display`).
pub fn to_string_ebnf(grammar: *const Grammar, allocator: Allocator) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (0..@intCast(grammar.num_rules())) |rule_id| {
        try print_rule(&out, allocator, grammar, @intCast(rule_id));
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

fn push_fmt(
    out: *std.ArrayList(u8),
    allocator: Allocator,
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error!void {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    try out.appendSlice(allocator, s);
}

fn print_rule(
    out: *std.ArrayList(u8),
    allocator: Allocator,
    grammar: *const Grammar,
    rule_id: i32,
) Allocator.Error!void {
    const rule = grammar.rule(rule_id);
    const suffix_stop_info = grammar.suffix_stop_info(rule_id);
    // Print the attributes as one comma-separated bracket group, re-parseable by the lexer.
    var attributes: std.ArrayList(u8) = .empty;
    defer attributes.deinit(allocator);
    if (rule.max_tokens >= 0) {
        try push_attribute(&attributes, allocator, "max_tokens={d}", .{rule.max_tokens});
    }
    if (rule.max_chars >= 0) {
        try push_attribute(&attributes, allocator, "max_chars={d}", .{rule.max_chars});
    }
    if (rule.capture_name.len != 0) {
        try push_attribute(&attributes, allocator, "capture=\"{s}\"", .{rule.capture_name});
    }
    if (suffix_stop_info) |info| {
        if (info.hidden_suffix_bytes > 0) {
            try push_attribute(&attributes, allocator, "capture_hidden_suffix_bytes={d}", .{info.hidden_suffix_bytes});
        }
        if (info.hidden_stop_bytes > 0) {
            try push_attribute(&attributes, allocator, "capture_hidden_stop_bytes={d}", .{info.hidden_stop_bytes});
        }
        if (info.body_rule_id >= 0) {
            try push_attribute(&attributes, allocator, "capture_hidden_body_rule_id={d}", .{info.body_rule_id});
            try push_attribute(&attributes, allocator, "capture_hidden_marker_rule_id={d}", .{info.marker_rule_id});
        }
        if (info.stop_capture_name.len != 0) {
            try push_attribute(&attributes, allocator, "stop_capture=\"{s}\"", .{info.stop_capture_name});
        }
    }
    if (rule.is_lazy) {
        try push_attribute(&attributes, allocator, "lazy", .{});
    }
    if (rule.temperature) |temperature| {
        const formatted = try format_float_max_digits(allocator, temperature);
        defer allocator.free(formatted);
        try push_attribute(&attributes, allocator, "temperature={s}", .{formatted});
    }
    try out.appendSlice(allocator, rule.name);
    if (suffix_stop_info != null or attributes.items.len != 0) {
        try push_fmt(out, allocator, "[{s}]", .{attributes.items});
    }
    const body = try print_expr(allocator, grammar, rule.body_expr_id);
    defer allocator.free(body);
    try push_fmt(out, allocator, " ::= {s}", .{body});
    if (rule.lookahead_assertion_id != NO_EXPR) {
        const lookahead = try print_expr(allocator, grammar, rule.lookahead_assertion_id);
        defer allocator.free(lookahead);
        try push_fmt(out, allocator, " (={s})", .{lookahead});
    }
}

fn push_attribute(
    attributes: *std.ArrayList(u8),
    allocator: Allocator,
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error!void {
    if (attributes.items.len != 0) try attributes.appendSlice(allocator, ", ");
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    try attributes.appendSlice(allocator, s);
}

fn print_expr(
    allocator: Allocator,
    grammar: *const Grammar,
    expr_id: i32,
) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const expr = grammar.expr(expr_id);
    switch (expr.ty) {
        .ByteString => {
            const bytes = try expr.byte_string(allocator);
            defer allocator.free(bytes);
            const escaped = try support.escape_bytes(allocator, bytes);
            defer allocator.free(escaped);
            try push_fmt(&out, allocator, "\"{s}\"", .{escaped});
        },
        .CharacterClass => try print_character_class(&out, allocator, grammar, expr_id, false),
        .CharacterClassStar => try print_character_class(&out, allocator, grammar, expr_id, true),
        .EmptyStr => try out.appendSlice(allocator, "\"\""),
        .RuleRef => try out.appendSlice(allocator, grammar.rule(expr.rule_ref_id()).name),
        .Sequence => try print_joined(&out, allocator, grammar, expr.data, " "),
        .Choices => try print_joined(&out, allocator, grammar, expr.data, " | "),
        .TagDispatch => try print_tag_dispatch(&out, allocator, grammar, expr_id),
        .Repeat => {
            const rep = expr.repeat();
            try push_fmt(&out, allocator, "{s}{{{d}, {d}}}", .{ grammar.rule(rep.rule_id).name, rep.min_repeat, rep.max_repeat });
        },
        .Token => try print_token_list(&out, allocator, "Token", expr.data),
        .ExcludeToken => try print_token_list(&out, allocator, "ExcludeToken", expr.data),
        .TokenTagDispatch => try print_token_tag_dispatch(&out, allocator, grammar, expr_id),
        .Regex => {
            const pattern = try expr.regex_pattern(allocator);
            defer allocator.free(pattern);
            const json_string: []const u8 = if (expr.regex_is_json_string()) ", json_string=true" else "";
            const quoted = try print_quoted(allocator, pattern);
            defer allocator.free(quoted);
            try push_fmt(&out, allocator, "Regex({s}{s})", .{ quoted, json_string });
        },
        .Substring => {
            const chunks = try expr.substring_chunks(allocator);
            defer {
                for (chunks) |chunk| allocator.free(chunk);
                allocator.free(chunks);
            }
            try out.appendSlice(allocator, "Substring(");
            for (chunks, 0..) |chunk, i| {
                if (i > 0) try out.appendSlice(allocator, ", ");
                const quoted = try print_quoted(allocator, chunk);
                defer allocator.free(quoted);
                try out.appendSlice(allocator, quoted);
            }
            try out.appendSlice(allocator, ")");
        },
    }
    return out.toOwnedSlice(allocator);
}

fn print_joined(
    out: *std.ArrayList(u8),
    allocator: Allocator,
    grammar: *const Grammar,
    element_ids: []const i32,
    separator: []const u8,
) Allocator.Error!void {
    try out.append(allocator, '(');
    for (element_ids, 0..) |id, i| {
        if (i > 0) try out.appendSlice(allocator, separator);
        const piece = try print_expr(allocator, grammar, id);
        defer allocator.free(piece);
        try out.appendSlice(allocator, piece);
    }
    try out.append(allocator, ')');
}

fn print_character_class(
    out: *std.ArrayList(u8),
    allocator: Allocator,
    grammar: *const Grammar,
    expr_id: i32,
    star: bool,
) Allocator.Error!void {
    const class = try grammar.expr(expr_id).character_class(allocator);
    defer allocator.free(class.ranges);
    try out.append(allocator, '[');
    if (class.is_negative) try out.append(allocator, '^');
    for (class.ranges) |range| {
        const lower = try support.escape_codepoint(allocator, range.lower, &CHAR_CLASS_ESCAPES);
        defer allocator.free(lower);
        try out.appendSlice(allocator, lower);
        if (range.lower != range.upper) {
            try out.append(allocator, '-');
            const upper = try support.escape_codepoint(allocator, range.upper, &CHAR_CLASS_ESCAPES);
            defer allocator.free(upper);
            try out.appendSlice(allocator, upper);
        }
    }
    try out.append(allocator, ']');
    if (star) try out.append(allocator, '*');
}

fn print_token_list(
    out: *std.ArrayList(u8),
    allocator: Allocator,
    label: []const u8,
    token_ids: []const i32,
) Allocator.Error!void {
    try push_fmt(out, allocator, "{s}(", .{label});
    for (token_ids, 0..) |id, i| {
        if (i > 0) try out.appendSlice(allocator, ", ");
        try push_fmt(out, allocator, "{d}", .{id});
    }
    try out.append(allocator, ')');
}

fn print_quoted(allocator: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    const escaped = try support.escape_bytes(allocator, bytes);
    defer allocator.free(escaped);
    return std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
}

fn print_tag_dispatch(
    out: *std.ArrayList(u8),
    allocator: Allocator,
    grammar: *const Grammar,
    expr_id: i32,
) Allocator.Error!void {
    var td = try @import("tag_dispatch.zig").tag_dispatch(grammar, allocator, expr_id);
    defer td.deinit(allocator);
    try out.appendSlice(allocator, "TagDispatch(\n");
    for (td.tag_rule_pairs.items) |pair| {
        const quoted = try print_quoted(allocator, pair.tag);
        defer allocator.free(quoted);
        try push_fmt(out, allocator, "  ({s}, {s}),\n", .{ quoted, grammar.rule(pair.rule_id).name });
    }
    try push_fmt(out, allocator, "  loop_after_dispatch={s},\n", .{bool_str(td.loop_after_dispatch)});
    try out.appendSlice(allocator, "  excludes=(");
    for (td.excludes.items, 0..) |exclude, i| {
        if (i > 0) try out.appendSlice(allocator, ", ");
        const quoted = try print_quoted(allocator, exclude);
        defer allocator.free(quoted);
        try out.appendSlice(allocator, quoted);
    }
    try out.appendSlice(allocator, ")\n)");
}

fn print_token_tag_dispatch(
    out: *std.ArrayList(u8),
    allocator: Allocator,
    grammar: *const Grammar,
    expr_id: i32,
) Allocator.Error!void {
    var ttd = try @import("token_tag_dispatch.zig").token_tag_dispatch(grammar, allocator, expr_id);
    defer ttd.deinit(allocator);
    try out.appendSlice(allocator, "TokenTagDispatch(\n");
    for (ttd.trigger_rule_pairs.items) |pair| {
        try push_fmt(out, allocator, "  ({d}, {s}),\n", .{ pair.token_id, grammar.rule(pair.rule_id).name });
    }
    try push_fmt(out, allocator, "  loop_after_dispatch={s},\n", .{bool_str(ttd.loop_after_dispatch)});
    try out.appendSlice(allocator, "  excludes=(");
    for (ttd.excludes.items, 0..) |id, i| {
        if (i > 0) try out.appendSlice(allocator, ", ");
        try push_fmt(out, allocator, "{d}", .{id});
    }
    try out.appendSlice(allocator, ")\n)");
}

fn bool_str(b: bool) []const u8 {
    return if (b) "true" else "false";
}

/// Formats `value` like C++ `ostream << std::setprecision(max_digits10)` (i.e. `%.9g`)
/// (`printer.rs::format_float_max_digits`).
pub fn format_float_max_digits(allocator: Allocator, value_f32: f32) Allocator.Error![]u8 {
    // std::numeric_limits<float>::max_digits10
    const PRECISION: usize = 9;
    const value: f64 = @floatCast(value_f32);
    if (value == 0.0 or !std.math.isFinite(value)) {
        // Rust `format!("{value}")` spellings.
        if (std.math.isNan(value)) return allocator.dupe(u8, "NaN");
        if (std.math.isInf(value)) return allocator.dupe(u8, if (value < 0) "-inf" else "inf");
        if (std.math.signbit(value)) return allocator.dupe(u8, "-0");
        return allocator.dupe(u8, "0");
    }
    var sci_buf: [std.fmt.float.bufferSize(.decimal, f64) + 32]u8 = undefined;
    const scientific = std.fmt.float.render(&sci_buf, value, .{ .mode = .scientific, .precision = PRECISION - 1 }) catch unreachable;
    const e_pos = std.mem.indexOfScalar(u8, scientific, 'e') orelse unreachable; // scientific notation has an exponent
    const exponent = std.fmt.parseInt(i32, scientific[e_pos + 1 ..], 10) catch unreachable;
    var mant_buf: [64]u8 = undefined;
    const mantissa = strip_digits(&mant_buf, scientific[0..e_pos]);
    if (exponent >= -4 and exponent < @as(i32, @intCast(PRECISION))) {
        const decimals: usize = @intCast(@max(0, @as(i32, @intCast(PRECISION)) - 1 - exponent));
        var fix_buf: [std.fmt.float.bufferSize(.decimal, f64) + 32]u8 = undefined;
        const fixed = std.fmt.float.render(&fix_buf, value, .{ .mode = .decimal, .precision = decimals }) catch unreachable;
        var strip_buf: [256]u8 = undefined;
        return allocator.dupe(u8, strip_digits(&strip_buf, fixed));
    } else {
        const sign: u8 = if (exponent < 0) '-' else '+';
        return std.fmt.allocPrint(allocator, "{s}e{c}{d:0>2}", .{ mantissa, sign, @abs(exponent) });
    }
}

/// Rust `strip`: trims trailing zeros and then a trailing decimal point.
fn strip_digits(buf: []u8, digits: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, digits, '.') == null) {
        @memcpy(buf[0..digits.len], digits);
        return buf[0..digits.len];
    }
    var end = digits.len;
    while (end > 0 and digits[end - 1] == '0') end -= 1;
    if (end > 0 and digits[end - 1] == '.') end -= 1;
    @memcpy(buf[0..end], digits[0..end]);
    return buf[0..end];
}

test "format float max digits" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { value: f32, want: []const u8 }{
        .{ .value = 0.7, .want = "0.699999988" }, // 0.7f32 widened to f64
        .{ .value = 1.0, .want = "1" },
        .{ .value = 0.5, .want = "0.5" },
        .{ .value = 0.123456789, .want = "0.123456791" }, // f32 rounding, then %.9g
        .{ .value = 123456792.0, .want = "123456792" }, // exponent 8 → decimal branch
        .{ .value = 1e-5, .want = "9.99999975e-06" }, // exponent -5 → scientific branch
        .{ .value = -2.5, .want = "-2.5" },
        .{ .value = 1000000.0, .want = "1000000" },
    };
    for (cases) |c| {
        const got = try format_float_max_digits(gpa, c.value);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}

test "to_string_ebnf basic grammar" {
    const backing = std.testing.allocator;
    const grammar_builder_mod = @import("grammar_builder.zig");
    var builder = try grammar_builder_mod.GrammarBuilder.new(backing);
    defer builder.deinit();
    const char_class_id = try builder.add_character_class(&.{@import("character_class_element.zig").CharacterClassElement.new('a', 'z')}, false);
    const bs_id = try builder.add_byte_string("b");
    const seq_id = try builder.add_sequence(&.{ bs_id, char_class_id });
    const empty_id = try builder.add_empty_str();
    const choices_id = try builder.add_choices(&.{ seq_id, empty_id });
    _ = try builder.add_rule_named("root", choices_id);
    const grammar = try builder.into_grammar_with_root_id(backing, 0);
    defer grammar.deinit();

    const ebnf = try to_string_ebnf(grammar, backing);
    defer backing.free(ebnf);
    try std.testing.expectEqualStrings("root ::= ((\"b\" [a-z]) | \"\")\n", ebnf);
}
