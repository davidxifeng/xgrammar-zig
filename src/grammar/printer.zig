//! Streaming EBNF printing for `Grammar` (zero heap allocation in `writeEbnf`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_mod = @import("Grammar.zig");
const Grammar = grammar_mod.Grammar;
const NO_EXPR = grammar_mod.NO_EXPR;
const dispatch = @import("dispatch.zig");
const support = @import("../support.zig");
const encoding = support.encoding;
const CodepointEscape = encoding.CodepointEscape;

/// Custom escapes used inside character classes: `-` and `]` are backslash-escaped.
const CHAR_CLASS_ESCAPES = [_]CodepointEscape{
    .{ .codepoint = 0x2D, .escape = "\\-" },
    .{ .codepoint = 0x5D, .escape = "\\]" },
};

/// Streams the grammar in normalized EBNF form (one rule per line) directly to `writer`
/// with zero heap allocations.
pub fn writeEbnf(grammar: *const Grammar, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    for (0..grammar.numRules()) |rule_id| {
        try writeRule(grammar, writer, @intCast(rule_id));
        try writer.writeByte('\n');
    }
}

/// Renders the grammar back to its normalized EBNF text (`allocator`-owned slice).
pub fn toStringEbnf(grammar: *const Grammar, allocator: Allocator) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    writeEbnf(grammar, &aw.writer) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeAttrSep(writer: *std.Io.Writer, first: *bool) std.Io.Writer.Error!void {
    if (first.*) {
        first.* = false;
    } else {
        try writer.writeAll(", ");
    }
}

fn writeRule(
    grammar: *const Grammar,
    writer: *std.Io.Writer,
    rule_id: i32,
) std.Io.Writer.Error!void {
    const r = grammar.rule(rule_id);
    const suffix_stop_info = grammar.suffixStopInfo(rule_id);

    try writer.writeAll(r.name);
    const has_attrs = suffix_stop_info != null or
        r.max_tokens >= 0 or
        r.max_chars >= 0 or
        r.capture_name.len != 0 or
        r.is_lazy or
        r.temperature != null;
    if (has_attrs) {
        try writer.writeByte('[');
        var first = true;
        if (r.max_tokens >= 0) {
            try writeAttrSep(writer, &first);
            try writer.print("max_tokens={d}", .{r.max_tokens});
        }
        if (r.max_chars >= 0) {
            try writeAttrSep(writer, &first);
            try writer.print("max_chars={d}", .{r.max_chars});
        }
        if (r.capture_name.len != 0) {
            try writeAttrSep(writer, &first);
            try writer.print("capture=\"{s}\"", .{r.capture_name});
        }
        if (suffix_stop_info) |info| {
            if (info.hidden_suffix_bytes > 0) {
                try writeAttrSep(writer, &first);
                try writer.print("capture_hidden_suffix_bytes={d}", .{info.hidden_suffix_bytes});
            }
            if (info.hidden_stop_bytes > 0) {
                try writeAttrSep(writer, &first);
                try writer.print("capture_hidden_stop_bytes={d}", .{info.hidden_stop_bytes});
            }
            if (info.body_rule_id >= 0) {
                try writeAttrSep(writer, &first);
                try writer.print("capture_hidden_body_rule_id={d}", .{info.body_rule_id});
                try writeAttrSep(writer, &first);
                try writer.print("capture_hidden_marker_rule_id={d}", .{info.marker_rule_id});
            }
            if (info.stop_capture_name.len != 0) {
                try writeAttrSep(writer, &first);
                try writer.print("stop_capture=\"{s}\"", .{info.stop_capture_name});
            }
        }
        if (r.is_lazy) {
            try writeAttrSep(writer, &first);
            try writer.writeAll("lazy");
        }
        if (r.temperature) |temperature| {
            try writeAttrSep(writer, &first);
            try writer.writeAll("temperature=");
            try writeFloatMaxDigits(writer, temperature);
        }
        try writer.writeByte(']');
    }

    try writer.writeAll(" ::= ");
    try writeExpr(grammar, writer, r.body_expr_id);
    if (r.lookahead_assertion_id != NO_EXPR) {
        try writer.writeAll(" (=");
        try writeExpr(grammar, writer, r.lookahead_assertion_id);
        try writer.writeByte(')');
    }
}

fn writeEscapedI32Bytes(writer: *std.Io.Writer, data: []const i32) std.Io.Writer.Error!void {
    var i: usize = 0;
    while (i < data.len) {
        var buf: [4]u8 = undefined;
        const avail = @min(4, data.len - i);
        for (0..avail) |k| {
            const v = data[i + k];
            buf[k] = if (v >= 0 and v <= 255) @intCast(v) else 0xFF;
        }
        if (encoding.parseNextUtf8(buf[0..avail])) |decoded| {
            try encoding.writeEscapedCodepoint(writer, decoded.codepoint, &.{});
            i += decoded.consumed;
        } else |_| {
            try encoding.writeEscapedCodepoint(writer, data[i], &.{});
            i += 1;
        }
    }
}

fn writeQuotedI32Bytes(writer: *std.Io.Writer, data: []const i32) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    try writeEscapedI32Bytes(writer, data);
    try writer.writeByte('"');
}

fn writeExpr(
    grammar: *const Grammar,
    writer: *std.Io.Writer,
    expr_id: i32,
) std.Io.Writer.Error!void {
    const expr = grammar.expr(expr_id);
    switch (expr.ty) {
        .ByteString => try writeQuotedI32Bytes(writer, expr.data),
        .CharacterClass => try writeCharacterClass(writer, expr.data, false),
        .CharacterClassStar => try writeCharacterClass(writer, expr.data, true),
        .EmptyStr => try writer.writeAll("\"\""),
        .RuleRef => try writer.writeAll(grammar.rule(expr.ruleRefId()).name),
        .Sequence => try writeJoined(grammar, writer, expr.data, " "),
        .Choices => try writeJoined(grammar, writer, expr.data, " | "),
        .TagDispatch => try writeTagDispatch(grammar, writer, expr.data),
        .Repeat => {
            const rep = expr.repeat();
            try writer.print("{s}{{{d}, {d}}}", .{ grammar.rule(rep.rule_id).name, rep.min_repeat, rep.max_repeat });
        },
        .Token => try writeTokenList(writer, "Token", expr.data),
        .ExcludeToken => try writeTokenList(writer, "ExcludeToken", expr.data),
        .TokenTagDispatch => try writeTokenTagDispatch(grammar, writer, expr.data),
        .Regex => {
            try writer.writeAll("Regex(");
            try writeQuotedI32Bytes(writer, expr.data[1..]);
            if (expr.regexIsJsonString()) try writer.writeAll(", json_string=true");
            try writer.writeByte(')');
        },
        .Substring => {
            try writer.writeAll("Substring(");
            var index: usize = 0;
            var first = true;
            while (index < expr.data.len) {
                const chunk_len: usize = @intCast(expr.data[index]);
                index += 1;
                if (!first) try writer.writeAll(", ");
                first = false;
                try writeQuotedI32Bytes(writer, expr.data[index..][0..chunk_len]);
                index += chunk_len;
            }
            try writer.writeByte(')');
        },
    }
}

fn writeJoined(
    grammar: *const Grammar,
    writer: *std.Io.Writer,
    element_ids: []const i32,
    separator: []const u8,
) std.Io.Writer.Error!void {
    try writer.writeByte('(');
    for (element_ids, 0..) |id, i| {
        if (i > 0) try writer.writeAll(separator);
        try writeExpr(grammar, writer, id);
    }
    try writer.writeByte(')');
}

fn writeCharacterClass(
    writer: *std.Io.Writer,
    data: []const i32,
    star: bool,
) std.Io.Writer.Error!void {
    const is_negative = data[0] != 0;
    const n = (data.len - 1) / 2;
    try writer.writeByte('[');
    if (is_negative) try writer.writeByte('^');
    for (0..n) |i| {
        const lower = data[1 + 2 * i];
        const upper = data[2 + 2 * i];
        try encoding.writeEscapedCodepoint(writer, lower, &CHAR_CLASS_ESCAPES);
        if (lower != upper) {
            try writer.writeByte('-');
            try encoding.writeEscapedCodepoint(writer, upper, &CHAR_CLASS_ESCAPES);
        }
    }
    try writer.writeByte(']');
    if (star) try writer.writeByte('*');
}

fn writeTokenList(
    writer: *std.Io.Writer,
    label: []const u8,
    token_ids: []const i32,
) std.Io.Writer.Error!void {
    try writer.print("{s}(", .{label});
    for (token_ids, 0..) |id, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("{d}", .{id});
    }
    try writer.writeByte(')');
}

fn writeTagDispatch(
    grammar: *const Grammar,
    writer: *std.Io.Writer,
    data: []const i32,
) std.Io.Writer.Error!void {
    const body_len = data.len - dispatch.EXTRA_PARAMETERS;
    try writer.writeAll("TagDispatch(\n");
    for (0..body_len / 2) |pair_index| {
        const pair = data[pair_index * 2 ..][0..2];
        const tag_expr = grammar.expr(pair[0]);
        std.debug.assert(tag_expr.ty == .ByteString);
        try writer.writeAll("  (");
        try writeQuotedI32Bytes(writer, tag_expr.data);
        try writer.print(", {s}),\n", .{grammar.rule(pair[1]).name});
    }
    const loop_after_dispatch = data[data.len - 2] != 0;
    try writer.print("  loop_after_dispatch={s},\n", .{boolStr(loop_after_dispatch)});
    const exclude_expr = grammar.expr(data[data.len - 1]);
    std.debug.assert(exclude_expr.ty == .Choices);
    try writer.writeAll("  excludes=(");
    for (exclude_expr.data, 0..) |child, i| {
        if (i > 0) try writer.writeAll(", ");
        const exc_expr = grammar.expr(child);
        std.debug.assert(exc_expr.ty == .ByteString);
        try writeQuotedI32Bytes(writer, exc_expr.data);
    }
    try writer.writeAll(")\n)");
}

fn writeTokenTagDispatch(
    grammar: *const Grammar,
    writer: *std.Io.Writer,
    data: []const i32,
) std.Io.Writer.Error!void {
    var pos: usize = 0;
    const trigger_count: usize = @intCast(data[pos]);
    pos += 1;
    try writer.writeAll("TokenTagDispatch(\n");
    for (0..trigger_count) |_| {
        const token_id = data[pos];
        const rule_id = data[pos + 1];
        pos += 2;
        try writer.print("  ({d}, {s}),\n", .{ token_id, grammar.rule(rule_id).name });
    }
    const loop_after_dispatch = data[pos] != 0;
    pos += 1;
    try writer.print("  loop_after_dispatch={s},\n", .{boolStr(loop_after_dispatch)});
    const exclude_count: usize = @intCast(data[pos]);
    pos += 1;
    try writer.writeAll("  excludes=(");
    for (0..exclude_count) |i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("{d}", .{data[pos]});
        pos += 1;
    }
    try writer.writeAll(")\n)");
}

fn boolStr(b: bool) []const u8 {
    return if (b) "true" else "false";
}

/// Streams `value_f32` like C++ `ostream << std::setprecision(max_digits10)` (i.e. `%.9g`)
/// without heap allocation.
pub fn writeFloatMaxDigits(writer: *std.Io.Writer, value_f32: f32) std.Io.Writer.Error!void {
    const PRECISION: usize = 9;
    const value: f64 = @floatCast(value_f32);
    if (value == 0.0 or !std.math.isFinite(value)) {
        if (std.math.isNan(value)) return writer.writeAll("NaN");
        if (std.math.isInf(value)) return writer.writeAll(if (value < 0) "-inf" else "inf");
        if (std.math.signbit(value)) return writer.writeAll("-0");
        return writer.writeAll("0");
    }
    var sci_buf: [std.fmt.float.bufferSize(.decimal, f64) + 32]u8 = undefined;
    const scientific = std.fmt.float.render(&sci_buf, value, .{ .mode = .scientific, .precision = PRECISION - 1 }) catch unreachable;
    const e_pos = std.mem.indexOfScalar(u8, scientific, 'e') orelse unreachable;
    const exponent = std.fmt.parseInt(i32, scientific[e_pos + 1 ..], 10) catch unreachable;
    var mant_buf: [64]u8 = undefined;
    const mantissa = stripDigits(&mant_buf, scientific[0..e_pos]);
    if (exponent >= -4 and exponent < @as(i32, @intCast(PRECISION))) {
        const decimals: usize = @intCast(@max(0, @as(i32, @intCast(PRECISION)) - 1 - exponent));
        var fix_buf: [std.fmt.float.bufferSize(.decimal, f64) + 32]u8 = undefined;
        const fixed = std.fmt.float.render(&fix_buf, value, .{ .mode = .decimal, .precision = decimals }) catch unreachable;
        var strip_buf: [256]u8 = undefined;
        return writer.writeAll(stripDigits(&strip_buf, fixed));
    } else {
        const sign: u8 = if (exponent < 0) '-' else '+';
        return writer.print("{s}e{c}{d:0>2}", .{ mantissa, sign, @abs(exponent) });
    }
}

/// Allocates and formats `value_f32` via `writeFloatMaxDigits`.
pub fn formatFloatMaxDigits(allocator: Allocator, value_f32: f32) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    writeFloatMaxDigits(&aw.writer, value_f32) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn stripDigits(buf: []u8, digits: []const u8) []const u8 {
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

test "formatFloatMaxDigits" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { value: f32, want: []const u8 }{
        .{ .value = 0.7, .want = "0.699999988" },
        .{ .value = 1.0, .want = "1" },
        .{ .value = 0.5, .want = "0.5" },
        .{ .value = 0.123456789, .want = "0.123456791" },
        .{ .value = 123456792.0, .want = "123456792" },
        .{ .value = 1e-5, .want = "9.99999975e-06" },
        .{ .value = -2.5, .want = "-2.5" },
        .{ .value = 1000000.0, .want = "1000000" },
    };
    for (cases) |c| {
        const got = try formatFloatMaxDigits(gpa, c.value);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}

test "streaming writeEbnf and Grammar.format with zero temp heap allocations" {
    const backing = std.testing.allocator;
    const Builder = @import("Builder.zig").GrammarBuilder;
    var builder = try Builder.init(backing);
    defer builder.deinit();

    const cc_id = try builder.addCharacterClass(&.{grammar_mod.CharacterClassElement.init('a', 'z')}, false);
    const bs_id = try builder.addByteString("b\n中");
    const seq_id = try builder.addSequence(&.{ bs_id, cc_id });
    const empty_id = try builder.addEmptyStr();
    const rx_id = try builder.addRegex("[0-9]+", true);
    const sub_id = try builder.addSubstring(&.{ "ab", "", "c" });
    const tok_id = try builder.addTokenSet(&.{ 1, 2 });
    const exc_id = try builder.addExcludeTokenSet(&.{9});
    const choices_id = try builder.addChoices(&.{ seq_id, empty_id, rx_id, sub_id, tok_id, exc_id });
    _ = try builder.addRuleNamed("root", choices_id);
    var grammar = try builder.intoGrammarWithRootId(0);
    defer grammar.deinit();

    // Format directly into a fixed stack buffer — zero heap allocations!
    var stack_buf: [1024]u8 = undefined;
    var fixed_writer = std.Io.Writer.fixed(&stack_buf);
    try fixed_writer.print("{f}", .{grammar});

    const owned = try toStringEbnf(&grammar, backing);
    defer backing.free(owned);
    try std.testing.expectEqualStrings(owned, fixed_writer.buffered());
    try std.testing.expectEqualStrings(
        "root ::= ((\"b\\n\\u4e2d\" [a-z]) | \"\" | Regex(\"[0-9]+\", json_string=true) | Substring(\"ab\", \"\", \"c\") | Token(1, 2) | ExcludeToken(9))\n",
        owned,
    );

    // Zero-alloc streaming also works for TagDispatch and TokenTagDispatch.
    var b2 = try Builder.init(backing);
    defer b2.deinit();
    _ = try b2.addRuleNamed("r1", try b2.addByteString("a"));
    var td = dispatch.TagDispatch.init();
    defer td.deinit(backing);
    try td.tag_rule_pairs.append(backing, .{ .tag = try backing.dupe(u8, "x"), .rule_id = 0 });
    td.loop_after_dispatch = true;
    try td.excludes.append(backing, try backing.dupe(u8, "z"));
    const td_id = try b2.addTagDispatch(&td);
    var ttd = dispatch.TokenTagDispatch.init();
    defer ttd.deinit(backing);
    try ttd.trigger_rule_pairs.append(backing, .{ .token_id = 5, .rule_id = 0 });
    try ttd.excludes.append(backing, 8);
    const ttd_id = try b2.addTokenTagDispatch(&ttd);
    _ = try b2.addRuleNamed("root", try b2.addChoices(&.{ td_id, ttd_id }));
    var g2 = try b2.intoGrammar("root", null);
    defer g2.deinit();

    var buf2: [1024]u8 = undefined;
    var fw2 = std.Io.Writer.fixed(&buf2);
    try fw2.print("{f}", .{g2});
    try std.testing.expect(std.mem.indexOf(u8, fw2.buffered(), "TagDispatch(") != null);
    try std.testing.expect(std.mem.indexOf(u8, fw2.buffered(), "TokenTagDispatch(") != null);
}
