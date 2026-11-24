//! Parsed regex AST (`RegexNode`, `RegexStackEntry`, `RegexEscape`, `RegexIr`)
//! and lowering into an NFA (`FsmWithStartEnd`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const Diagnostic = @import("../Diagnostic.zig").Diagnostic;
const support = @import("../support.zig");
const encoding = support.encoding;
const fsm_mod = @import("Fsm.zig");
const Fsm = fsm_mod.Fsm;
const automata = @import("fsm_automata.zig");
const FsmWithStartEnd = automata.FsmWithStartEnd;
const GrammarBuilder = @import("../grammar.zig").GrammarBuilder;

const log = std.log.scoped(.xgrammar);

/// The largest Unicode codepoint.
pub const MAX_CODEPOINT: u32 = 0x10_FFFF;

/// An inclusive range of Unicode codepoints.
pub const CodepointRange = struct { low: u32, high: u32 };

pub const EscapeParseError = Allocator.Error || error{
    /// Unsupported or malformed escape (message via `diag`).
    InvalidEscape,
};

/// A parsed regex escape: a single codepoint, or a (possibly negated) set of codepoint ranges
/// for class escapes like `\d`, `\D`, `\w`, `\W`, `\s`, `\S`.
pub const RegexEscape = union(enum) {
    /// A single codepoint.
    Single: u32,
    /// A class escape.
    Class: struct {
        ranges: []CodepointRange,
        negated: bool,
    },

    pub fn deinit(self: RegexEscape, allocator: Allocator) void {
        switch (self) {
            .Class => |c| allocator.free(c.ranges),
            .Single => {},
        }
    }

    /// Parses the escape sequence starting at `regex[pos.*] == '\\'`, advancing `pos` past it.
    /// Inside a character class (`in_class`), `\b` is the backspace character instead of a word
    /// boundary assertion.
    pub fn parse(
        allocator: Allocator,
        regex: []const u8,
        pos: *usize,
        in_class: bool,
        diag: ?*Diagnostic,
    ) EscapeParseError!RegexEscape {
        std.debug.assert(regex[pos.*] == '\\');
        const escaped = if (pos.* + 1 < regex.len)
            regex[pos.* + 1]
        else
            return invalidEscapeCopy(allocator, diag, "Regex ends with a trailing backslash");
        pos.* += 2;
        switch (escaped) {
            'n' => return .{ .Single = 0x0A },
            't' => return .{ .Single = 0x09 },
            'r' => return .{ .Single = 0x0D },
            'f' => return .{ .Single = 0x0C },
            'v' => return .{ .Single = 0x0B },
            'a' => return .{ .Single = 0x07 },
            'e' => return .{ .Single = 0x1B },
            '0' => return .{ .Single = 0 },
            'b' => {
                if (in_class) return .{ .Single = 0x08 };
                return invalidEscapeCopy(allocator, diag, "Word boundary assertion \\b is not supported in regex");
            },
            'B' => return invalidEscapeCopy(allocator, diag, "Word boundary assertion \\B is not supported in regex"),
            'p', 'P' => return invalidEscapeCopy(allocator, diag, "Unicode property escape \\p / \\P is not supported in regex"),
            'k' => return invalidEscapeCopy(allocator, diag, "Backreference \\k is not supported in regex"),
            '1'...'9' => {
                if (diag) |d| try d.setFmt(allocator, .message, "Backreference \\{c} is not supported in regex", .{escaped});
                return error.InvalidEscape;
            },
            'd', 'D' => return classEscape(allocator, &.{.{ '0', '9' }}, escaped == 'D'),
            'w', 'W' => return classEscape(
                allocator,
                &.{ .{ '0', '9' }, .{ 'A', 'Z' }, .{ '_', '_' }, .{ 'a', 'z' } },
                escaped == 'W',
            ),
            's', 'S' => return classEscape(allocator, &.{
                .{ 0x09, 0x0D },
                .{ 0x20, 0x20 },
                .{ 0xA0, 0xA0 },
                .{ 0x1680, 0x1680 },
                .{ 0x2000, 0x200A },
                .{ 0x2028, 0x2029 },
                .{ 0x202F, 0x202F },
                .{ 0x205F, 0x205F },
                .{ 0x3000, 0x3000 },
                .{ 0xFEFF, 0xFEFF },
            }, escaped == 'S'),
            'x' => {
                const codepoint = if (pos.* + 2 <= regex.len)
                    hexValue(regex[pos.* .. pos.* + 2]) orelse
                        return invalidEscapeCopy(allocator, diag, "\\x must be followed by two hexadecimal digits in regex")
                else
                    return invalidEscapeCopy(allocator, diag, "\\x must be followed by two hexadecimal digits in regex");
                pos.* += 2;
                return .{ .Single = codepoint };
            },
            'u' => {
                if (pos.* < regex.len and regex[pos.*] == '{') {
                    const digits_begin = pos.* + 1;
                    var close: ?usize = null;
                    for (regex[digits_begin..], digits_begin..) |c, i| {
                        if (c == '}') {
                            close = i;
                            break;
                        }
                    }
                    const close_idx = close orelse
                        return invalidEscapeCopy(allocator, diag, "\\u{...} must contain one to six hexadecimal digits in regex");
                    if (!(close_idx > digits_begin and close_idx <= pos.* + 7)) {
                        return invalidEscapeCopy(allocator, diag, "\\u{...} must contain one to six hexadecimal digits in regex");
                    }
                    const codepoint = hexValue(regex[digits_begin..close_idx]) orelse
                        return invalidEscapeCopy(allocator, diag, "\\u{...} must contain one to six hexadecimal digits in regex");
                    if (codepoint > MAX_CODEPOINT) {
                        return invalidEscapeCopy(allocator, diag, "\\u{...} escape is beyond the Unicode range in regex");
                    }
                    pos.* = close_idx + 1;
                    return .{ .Single = codepoint };
                }
                const codepoint = if (pos.* + 4 <= regex.len)
                    hexValue(regex[pos.* .. pos.* + 4]) orelse
                        return invalidEscapeCopy(allocator, diag, "\\u must be followed by four hexadecimal digits in regex")
                else
                    return invalidEscapeCopy(allocator, diag, "\\u must be followed by four hexadecimal digits in regex");
                pos.* += 4;
                return .{ .Single = codepoint };
            },
            'c' => {
                if (pos.* < regex.len and std.ascii.isAlphabetic(regex[pos.*])) {
                    const letter = regex[pos.*];
                    pos.* += 1;
                    return .{ .Single = letter & 0x1F };
                }
                return invalidEscapeCopy(allocator, diag, "\\c must be followed by a letter in regex");
            },
            0x80...0xFF => {
                // A multi-byte UTF-8 character after the backslash matches literally.
                const decoded = encoding.parseNextUtf8(regex[pos.* - 1 ..]) catch
                    return invalidEscapeCopy(allocator, diag, "Invalid UTF-8 in regex escape sequence");
                pos.* += decoded.consumed - 1;
                return .{ .Single = @intCast(decoded.codepoint) };
            },
            else => {
                return .{ .Single = escaped };
            },
        }
    }
};

fn invalidEscapeCopy(allocator: Allocator, diag: ?*Diagnostic, message: []const u8) EscapeParseError {
    if (diag) |d| try d.setCopy(allocator, .message, message);
    return error.InvalidEscape;
}

fn classEscape(allocator: Allocator, bounds: []const [2]u32, negated: bool) EscapeParseError!RegexEscape {
    const ranges = try allocator.alloc(CodepointRange, bounds.len);
    for (bounds, 0..) |b, i| ranges[i] = .{ .low = b[0], .high = b[1] };
    return .{ .Class = .{ .ranges = ranges, .negated = negated } };
}

fn hexValue(digits: []const u8) ?u32 {
    var value: u32 = 0;
    for (digits) |digit| {
        const hex = encoding.hexCharToInt(digit) orelse return null;
        value = value * 16 + hex;
    }
    return value;
}

/// A node of the regex AST. Owned slices/pointers are allocated from the owning `RegexIr`'s
/// allocator and freed by its `deinit`.
pub const RegexNode = union(enum) {
    /// One atom: the empty string (`""`), a character class (`"[...]"`), or one literal
    /// character or escape sequence (the raw regex bytes).
    Leaf: []const u8,
    /// `child*`.
    Star: *RegexNode,
    /// `child+`.
    Plus: *RegexNode,
    /// `child?`.
    Optional: *RegexNode,
    /// An alternation of branches.
    Union: []RegexNode,
    /// A concatenation (a group, or a branch of an alternation).
    Bracket: []RegexNode,
    /// A `{lower, upper}` repetition, unrolled into the FSM (`upper == -1` is unbounded).
    Repeat: struct {
        child: *RegexNode,
        lower: i32,
        upper: i32,
    },
    /// A reference to a grammar rule, compiled into a rule-ref FSM edge.
    RuleRef: i32,
    /// A bounded repetition of a grammar rule, compiled into a repeat-ref FSM edge.
    RepeatSubrule: struct {
        rule_id: i32,
        lower: i32,
        upper: i32,
    },

    pub fn deinit(self: RegexNode, allocator: Allocator) void {
        switch (self) {
            .Leaf => |bytes| allocator.free(bytes),
            .Star, .Plus, .Optional => |child| {
                child.deinit(allocator);
                allocator.destroy(child);
            },
            .Union, .Bracket => |children| {
                for (children) |child| child.deinit(allocator);
                allocator.free(children);
            },
            .Repeat => |r| {
                r.child.deinit(allocator);
                allocator.destroy(r.child);
            },
            .RuleRef, .RepeatSubrule => {},
        }
    }

    /// Whether the node can match the empty string. Purely syntactic; no FSM is built.
    pub fn isNullable(self: RegexNode) bool {
        return switch (self) {
            .Leaf => |regex| regex.len == 0,
            .Star, .Optional => true,
            .Plus => |child| child.isNullable(),
            .Union => |branches| blk: {
                for (branches) |branch| {
                    if (branch.isNullable()) break :blk true;
                }
                break :blk false;
            },
            .Bracket => |children| isNullableSequence(children),
            .Repeat => |r| r.lower == 0 or r.child.isNullable(),
            .RuleRef => false,
            .RepeatSubrule => |r| r.lower == 0,
        };
    }

    /// Whether a sequence of nodes can match the empty string.
    pub fn isNullableSequence(nodes: []const RegexNode) bool {
        for (nodes) |node| {
            if (!node.isNullable()) return false;
        }
        return true;
    }
};

/// An entry of the regex parsing stack: a parsed atom with its source span, or a marker.
pub const RegexStackEntry = union(enum) {
    Node: struct {
        node: RegexNode,
        span_begin: usize,
        span_end: usize,
    },
    GroupOpen: usize,
    Alternation,
};

const REPEAT_NO_UPPER_BOUND: i32 = -1;
/// Bounded repetitions above this are compiled into a repeat FSM edge (when a grammar builder is
/// available) instead of being unrolled.
const LARGE_REPEAT_THRESHOLD: i32 = 128;
/// The cap of the estimated state count of a bounded repetition that has to be unrolled.
const MAX_UNROLLED_REPEAT_STATES: i64 = 100_000;
/// `10^9` fits in an `i32`; longer counts could overflow.
const MAX_REPEAT_DIGITS: usize = 9;

/// Errors of the regex parse/build path.
pub const RegexError = Allocator.Error || error{
    /// Malformed/unsupported regex; details in `diag`.
    RegexParse,
    /// A repetition is too large to unroll.
    RepeatTooLarge,
    /// `{n,m}` count is malformed.
    InvalidRepeat,
    RepeatCountInvalid,
    /// A `(` was left open.
    UnclosedParen,
    /// Propagated from `RegexEscape.parse`.
    InvalidEscape,
};

/// A parsed regex: the top-level sequence and the flags.
pub const RegexIr = struct {
    allocator: Allocator,
    states: []RegexNode,
    case_insensitive: bool,

    pub fn deinit(self: *RegexIr) void {
        for (self.states) |state| state.deinit(self.allocator);
        self.allocator.free(self.states);
    }

    /// Parses a regex. A leading `(?i)` enables ASCII case-insensitive matching.
    ///
    /// On `error.RegexParse`, `diag` (if non-null) receives
    /// `"Regex parsing error at position <1-based>: <description>"` via `Diagnostic.Kind.message`.
    pub fn parse(
        allocator: Allocator,
        regex_with_flags: []const u8,
        builder: ?*GrammarBuilder,
        rule_hint: []const u8,
        diag: ?*Diagnostic,
    ) RegexError!RegexIr {
        return parseWithOptions(allocator, regex_with_flags, builder, rule_hint, false, diag);
    }

    pub fn parseWithOptions(
        allocator: Allocator,
        regex_with_flags: []const u8,
        builder: ?*GrammarBuilder,
        rule_hint: []const u8,
        is_json_string: bool,
        diag: ?*Diagnostic,
    ) RegexError!RegexIr {
        const prefix = [_]u8{ '(', '?', 'i', ')' };
        const has_flags = std.mem.startsWith(u8, regex_with_flags, &prefix);
        const regex = if (has_flags) regex_with_flags[prefix.len..] else regex_with_flags;
        const case_insensitive = has_flags;
        const flag_prefix_length = regex_with_flags.len - regex.len;

        var parse_ctx = ParseContext{
            .allocator = allocator,
            .flag_prefix_length = flag_prefix_length,
            .diag = diag,
        };
        const size = regex.len;
        var stack: std.ArrayList(RegexStackEntry) = .empty;
        errdefer {
            for (stack.items) |entry| {
                if (entry == .Node) entry.Node.node.deinit(allocator);
            }
            stack.deinit(allocator);
        }
        var i: usize = 0;
        while (i < size) : (i += 1) {
            const c = regex[i];
            switch (c) {
                '^', '$' => {
                    if (!((c == '^' and i == 0) or (c == '$' and i == size - 1))) {
                        log.warn("Anchor '{c}' in the middle of regex is ignored: {s}", .{ c, regex });
                    }
                },
                '[' => {
                    const class_end = skipCharacterClass(regex, i) orelse return parse_ctx.fail(i, "Unclosed '['");
                    const content_begin = if (i + 1 < regex.len and regex[i + 1] == '^') i + 2 else i + 1;
                    if (content_begin + 1 == class_end) {
                        return parse_ctx.fail(i, "Empty character class is not allowed in regex");
                    }
                    const leaf = try allocator.dupe(u8, regex[i..class_end]);
                    errdefer allocator.free(leaf);
                    try stack.append(allocator, .{ .Node = .{
                        .node = .{ .Leaf = leaf },
                        .span_begin = i,
                        .span_end = class_end,
                    } });
                    i = class_end - 1;
                },
                ']' => return parse_ctx.fail(i, "Unmatched ']'"),
                '+', '*', '?' => {
                    const top = stack.pop() orelse
                        return parse_ctx.failFmt(i, "There is nothing to repeat before '{c}'", .{c});
                    if (top != .Node) {
                        try stack.append(allocator, top);
                        return parse_ctx.failFmt(i, "There is nothing to repeat before '{c}'", .{c});
                    }
                    var child_moved = false;
                    errdefer if (!child_moved) top.Node.node.deinit(allocator);
                    const child = try allocator.create(RegexNode);
                    child.* = top.Node.node;
                    child_moved = true;
                    const node: RegexNode = switch (c) {
                        '+' => .{ .Plus = child },
                        '*' => .{ .Star = child },
                        else => .{ .Optional = child },
                    };
                    errdefer node.deinit(allocator);
                    // Greedy and non-greedy quantifiers accept the same language.
                    if (i + 1 < regex.len and regex[i + 1] == '?') i += 1;
                    try stack.append(allocator, .{ .Node = .{
                        .node = node,
                        .span_begin = top.Node.span_begin,
                        .span_end = i + 1,
                    } });
                },
                '(' => {
                    if (i + 1 < regex.len and regex[i + 1] == '?') {
                        const modifier = if (i + 2 < regex.len)
                            regex[i + 2]
                        else
                            return parse_ctx.fail(i, "Group modifier is not finished");
                        switch (modifier) {
                            ':' => {
                                try stack.append(allocator, .{ .GroupOpen = i });
                                i += 2;
                            },
                            '=', '!' => {
                                log.warn("Lookahead assertion is not supported and is ignored in regex: {s}", .{regex});
                                var depth: i32 = 1;
                                var j = i + 3;
                                while (j < size and depth > 0) {
                                    switch (regex[j]) {
                                        '\\' => j += 1,
                                        '[' => {
                                            j = skipCharacterClass(regex, j) orelse
                                                return parse_ctx.fail(j, "Unclosed '['");
                                            continue;
                                        },
                                        '(' => depth += 1,
                                        ')' => depth -= 1,
                                        else => {},
                                    }
                                    j += 1;
                                }
                                if (depth != 0) return parse_ctx.fail(i, "The parenthesis is not closed");
                                const empty_leaf = try allocator.dupe(u8, "");
                                errdefer allocator.free(empty_leaf);
                                try stack.append(allocator, .{ .Node = .{
                                    .node = .{ .Leaf = empty_leaf },
                                    .span_begin = i,
                                    .span_end = j,
                                } });
                                i = j - 1;
                            },
                            '<', 'P' => {
                                if (!(modifier == '<' or (i + 3 < regex.len and regex[i + 3] == '<'))) {
                                    return parse_ctx.failFmt(i, "Unsupported group modifier '(?{c}'", .{modifier});
                                }
                                const name_begin = if (modifier == '<') i + 3 else i + 4;
                                if (name_begin < regex.len and (regex[name_begin] == '=' or regex[name_begin] == '!')) {
                                    return parse_ctx.fail(i, "Lookbehind assertion is not supported in regex");
                                }
                                var name_end = name_begin;
                                while (name_end < regex.len and
                                    (std.ascii.isAlphanumeric(regex[name_end]) or regex[name_end] == '_')) name_end += 1;
                                if (name_end == name_begin or name_end >= regex.len or regex[name_end] != '>') {
                                    return parse_ctx.fail(i, "Invalid named capturing group");
                                }
                                try stack.append(allocator, .{ .GroupOpen = i });
                                i = name_end;
                            },
                            else => {
                                return parse_ctx.failFmt(i, "Unsupported group modifier '(?{c}'", .{modifier});
                            },
                        }
                    } else {
                        try stack.append(allocator, .{ .GroupOpen = i });
                    }
                },
                '|' => try stack.append(allocator, .Alternation),
                ')' => {
                    var open: ?usize = null;
                    var group_begin: usize = 0;
                    var idx = stack.items.len;
                    while (idx > 0) {
                        idx -= 1;
                        if (stack.items[idx] == .GroupOpen) {
                            open = idx;
                            group_begin = stack.items[idx].GroupOpen;
                            break;
                        }
                    }
                    const open_idx = open orelse return parse_ctx.fail(i, "Unmatched ')'");
                    const content = stack.items[open_idx + 1 ..];
                    var group_open_at: usize = 0;
                    var branches = splitBranches(allocator, content, &group_open_at) catch |e| switch (e) {
                        error.UnclosedParen => return parse_ctx.fail(group_open_at, "The parenthesis is not closed"),
                        else => return e,
                    };
                    stack.items.len = open_idx + 1;
                    stack.shrinkRetainingCapacity(open_idx);
                    var node: RegexNode = undefined;
                    if (branches.items.len == 1) {
                        var only = branches.items[0];
                        const bracket = try allocator.alloc(RegexNode, only.items.len);
                        @memcpy(bracket, only.items);
                        only.deinit(allocator);
                        branches.deinit(allocator);
                        node = .{ .Bracket = bracket };
                    } else {
                        const union_nodes = allocator.alloc(RegexNode, branches.items.len) catch |err| {
                            for (branches.items) |*b| {
                                for (b.items) |n| n.deinit(allocator);
                                b.deinit(allocator);
                            }
                            branches.deinit(allocator);
                            return err;
                        };
                        var bi: usize = 0;
                        errdefer {
                            for (union_nodes[0..bi]) |n| n.deinit(allocator);
                            allocator.free(union_nodes);
                            for (branches.items[bi..]) |*b| {
                                for (b.items) |n| n.deinit(allocator);
                                b.deinit(allocator);
                            }
                            branches.deinit(allocator);
                        }
                        while (bi < branches.items.len) : (bi += 1) {
                            var branch_mut = branches.items[bi];
                            const bracket = try allocator.alloc(RegexNode, branch_mut.items.len);
                            @memcpy(bracket, branch_mut.items);
                            branch_mut.deinit(allocator);
                            union_nodes[bi] = .{ .Bracket = bracket };
                        }
                        branches.deinit(allocator);
                        node = .{ .Union = union_nodes };
                    }
                    errdefer node.deinit(allocator);
                    try stack.append(allocator, .{ .Node = .{
                        .node = node,
                        .span_begin = group_begin,
                        .span_end = i + 1,
                    } });
                },
                '{' => {
                    const top = stack.pop() orelse
                        return parse_ctx.fail(i, "There is nothing to repeat before the repetition");
                    if (top != .Node) {
                        try stack.append(allocator, top);
                        return parse_ctx.fail(i, "There is nothing to repeat before the repetition");
                    }
                    var top_consumed = false;
                    errdefer if (!top_consumed) top.Node.node.deinit(allocator);

                    const repeat_begin = i;
                    var repeat_diag: Diagnostic = .{};
                    defer repeat_diag.deinit(allocator);
                    const repeat_diag_ptr: ?*Diagnostic = if (diag != null) &repeat_diag else null;
                    var repeat = checkRepeat(allocator, regex, &i, repeat_diag_ptr) catch |e| switch (e) {
                        error.InvalidRepeat, error.RepeatCountInvalid => {
                            return parse_ctx.failFmt(repeat_begin, "{s}", .{repeat_diag.message});
                        },
                        else => return e,
                    };
                    if (i + 1 < regex.len and regex[i + 1] == '?') i += 1;
                    const is_large_repeat = if (repeat.upper == REPEAT_NO_UPPER_BOUND)
                        repeat.lower > LARGE_REPEAT_THRESHOLD
                    else
                        repeat.upper > LARGE_REPEAT_THRESHOLD;
                    const node: RegexNode = if (builder != null and is_large_repeat) blk: {
                        var inner_regex: std.ArrayList(u8) = .empty;
                        defer inner_regex.deinit(allocator);
                        if (case_insensitive) try inner_regex.appendSlice(allocator, "(?i)");
                        try inner_regex.appendSlice(allocator, regex[top.Node.span_begin..top.Node.span_end]);
                        if (top.Node.node.isNullable()) {
                            repeat.lower = 0;
                        }
                        const hint: []const u8 = if (rule_hint.len == 0) "regex" else rule_hint;
                        const b = builder.?;
                        const body = try b.addRegex(inner_regex.items, is_json_string);
                        const repeat_hint = try std.fmt.allocPrint(allocator, "{s}_repeat", .{hint});
                        defer allocator.free(repeat_hint);
                        const rule_id = try b.addRuleWithHint(repeat_hint, body);
                        b.updateLookaheadExact(rule_id, true);
                        top.Node.node.deinit(allocator);
                        top_consumed = true;
                        if (repeat.upper != REPEAT_NO_UPPER_BOUND) {
                            break :blk .{ .RepeatSubrule = .{ .rule_id = rule_id, .lower = repeat.lower, .upper = repeat.upper } };
                        } else {
                            const rule_ref = try allocator.create(RegexNode);
                            rule_ref.* = .{ .RuleRef = rule_id };
                            errdefer {
                                rule_ref.deinit(allocator);
                                allocator.destroy(rule_ref);
                            }
                            const star_node = RegexNode{ .Star = rule_ref };
                            if (repeat.lower > 0) {
                                const parts = try allocator.alloc(RegexNode, 2);
                                parts[0] = .{ .RepeatSubrule = .{ .rule_id = rule_id, .lower = repeat.lower, .upper = repeat.lower } };
                                parts[1] = star_node;
                                break :blk .{ .Bracket = parts };
                            } else {
                                break :blk star_node;
                            }
                        }
                    } else blk: {
                        const child = try allocator.create(RegexNode);
                        child.* = top.Node.node;
                        top_consumed = true;
                        break :blk .{ .Repeat = .{
                            .child = child,
                            .lower = repeat.lower,
                            .upper = repeat.upper,
                        } };
                    };
                    errdefer node.deinit(allocator);
                    try stack.append(allocator, .{ .Node = .{
                        .node = node,
                        .span_begin = top.Node.span_begin,
                        .span_end = i + 1,
                    } });
                },
                '\\' => {
                    var escape_end = i;
                    var escape_diag: Diagnostic = .{};
                    defer escape_diag.deinit(allocator);
                    const escape_diag_ptr: ?*Diagnostic = if (diag != null) &escape_diag else null;
                    _ = RegexEscape.parse(allocator, regex, &escape_end, false, escape_diag_ptr) catch |e| switch (e) {
                        error.InvalidEscape => {
                            return parse_ctx.failFmt(i, "{s}", .{escape_diag.message});
                        },
                        else => return e,
                    };
                    const leaf = try allocator.dupe(u8, regex[i..escape_end]);
                    errdefer allocator.free(leaf);
                    try stack.append(allocator, .{ .Node = .{
                        .node = .{ .Leaf = leaf },
                        .span_begin = i,
                        .span_end = escape_end,
                    } });
                    i = escape_end - 1;
                },
                else => {
                    const num_bytes: usize = if (encoding.parseNextUtf8(regex[i..])) |decoded|
                        decoded.consumed
                    else |_|
                        1;
                    const leaf = try allocator.dupe(u8, regex[i .. i + num_bytes]);
                    errdefer allocator.free(leaf);
                    try stack.append(allocator, .{ .Node = .{
                        .node = .{ .Leaf = leaf },
                        .span_begin = i,
                        .span_end = i + num_bytes,
                    } });
                    i += num_bytes - 1;
                },
            }
        }

        var group_open_at: usize = 0;
        var branches = splitBranches(allocator, stack.items, &group_open_at) catch |e| switch (e) {
            error.UnclosedParen => {
                for (stack.items) |entry| {
                    if (entry == .Node) entry.Node.node.deinit(allocator);
                }
                stack.items.len = 0;
                return parse_ctx.fail(group_open_at, "The parenthesis is not closed");
            },
            else => return e,
        };
        var states: []RegexNode = undefined;
        if (branches.items.len == 1) {
            states = allocator.alloc(RegexNode, branches.items[0].items.len) catch |err| {
                for (branches.items[0].items) |n| n.deinit(allocator);
                branches.items[0].deinit(allocator);
                branches.deinit(allocator);
                return err;
            };
            @memcpy(states, branches.items[0].items);
            branches.items[0].deinit(allocator);
        } else {
            const union_nodes = allocator.alloc(RegexNode, branches.items.len) catch |err| {
                for (branches.items) |*b| {
                    for (b.items) |n| n.deinit(allocator);
                    b.deinit(allocator);
                }
                branches.deinit(allocator);
                return err;
            };
            var bi: usize = 0;
            errdefer {
                for (union_nodes[0..bi]) |n| n.deinit(allocator);
                allocator.free(union_nodes);
                for (branches.items[bi..]) |*b| {
                    for (b.items) |n| n.deinit(allocator);
                    b.deinit(allocator);
                }
                branches.deinit(allocator);
            }
            while (bi < branches.items.len) : (bi += 1) {
                var branch_mut = branches.items[bi];
                const bracket = try allocator.alloc(RegexNode, branch_mut.items.len);
                @memcpy(bracket, branch_mut.items);
                branch_mut.deinit(allocator);
                union_nodes[bi] = .{ .Bracket = bracket };
            }
            states = allocator.alloc(RegexNode, 1) catch |err| {
                for (union_nodes) |n| n.deinit(allocator);
                allocator.free(union_nodes);
                branches.deinit(allocator);
                return err;
            };
            states[0] = .{ .Union = union_nodes };
        }
        branches.deinit(allocator);
        stack.deinit(allocator);
        return .{ .allocator = allocator, .states = states, .case_insensitive = case_insensitive };
    }

    /// Whether the regex matches the empty string.
    pub fn matchesEmpty(self: *const RegexIr) bool {
        return RegexNode.isNullableSequence(self.states);
    }

    /// Lowers the regex into an NFA. The caller owns the result.
    pub fn build(self: *const RegexIr, diag: ?*Diagnostic) RegexError!FsmWithStartEnd {
        return self.buildSequence(self.states, diag);
    }

    fn buildSequence(self: *const RegexIr, nodes: []const RegexNode, diag: ?*Diagnostic) RegexError!FsmWithStartEnd {
        if (nodes.len == 0) {
            return emptyStringFsm(self.allocator);
        }
        var fsms: std.ArrayList(FsmWithStartEnd) = .empty;
        defer {
            for (fsms.items) |*f| f.deinit();
            fsms.deinit(self.allocator);
        }
        for (nodes) |node| try fsms.append(self.allocator, try self.visit(node, diag));
        if (fsms.items.len == 1) {
            const only = fsms.items[0];
            fsms.items.len = 0;
            return only;
        } else {
            return FsmWithStartEnd.concat(self.allocator, fsms.items);
        }
    }

    fn visit(self: *const RegexIr, node: RegexNode, diag: ?*Diagnostic) RegexError!FsmWithStartEnd {
        return switch (node) {
            .Leaf => |regex| self.buildLeaf(regex, diag),
            .Star => |child| blk: {
                var sub = try self.visit(child.*, diag);
                defer sub.deinit();
                break :blk try sub.star(self.allocator);
            },
            .Plus => |child| blk: {
                var sub = try self.visit(child.*, diag);
                defer sub.deinit();
                break :blk try sub.plus(self.allocator);
            },
            .Optional => |child| blk: {
                var sub = try self.visit(child.*, diag);
                defer sub.deinit();
                break :blk try sub.optional(self.allocator);
            },
            .Union => |branches| blk: {
                var fsms: std.ArrayList(FsmWithStartEnd) = .empty;
                defer {
                    for (fsms.items) |*f| f.deinit();
                    fsms.deinit(self.allocator);
                }
                for (branches) |branch| try fsms.append(self.allocator, try self.visit(branch, diag));
                break :blk try FsmWithStartEnd.unionOf(self.allocator, fsms.items);
            },
            .Bracket => |children| self.buildSequence(children, diag),
            .Repeat => |r| self.buildRepeat(r.child.*, r.lower, r.upper, diag),
            .RuleRef => |rule_id| blk: {
                var fsm = try Fsm.init(self.allocator, 2);
                errdefer fsm.deinit();
                try fsm.addRuleEdge(0, 1, rule_id);
                var ends: std.ArrayList(i32) = .empty;
                errdefer ends.deinit(self.allocator);
                try ends.append(self.allocator, 1);
                break :blk FsmWithStartEnd.init(self.allocator, fsm, 0, ends, false);
            },
            .RepeatSubrule => |r| blk: {
                var fsm = try Fsm.init(self.allocator, 4);
                errdefer fsm.deinit();
                try fsm.addEpsilonEdge(0, 1);
                try fsm.addRepeatEdge(1, 2, r.rule_id, r.lower, r.upper);
                try fsm.addEpsilonEdge(2, 3);
                var ends: std.ArrayList(i32) = .empty;
                errdefer ends.deinit(self.allocator);
                try ends.append(self.allocator, 3);
                break :blk FsmWithStartEnd.init(self.allocator, fsm, 0, ends, false);
            },
        };
    }

    /// Unrolls `child{lower, upper}` (`upper == -1` is unbounded).
    fn buildRepeat(
        self: *const RegexIr,
        child: RegexNode,
        lower: i32,
        upper: i32,
        diag: ?*Diagnostic,
    ) RegexError!FsmWithStartEnd {
        const has_upper_bound = upper != REPEAT_NO_UPPER_BOUND;
        if (has_upper_bound and upper == 0) {
            return emptyStringFsm(self.allocator);
        }
        var child_fsm = try self.visit(child, diag);
        defer child_fsm.deinit();
        var result = try child_fsm.dupe(self.allocator);
        errdefer result.deinit();

        const num_copies: i64 = if (has_upper_bound) upper else @max(lower, 1);
        if (@as(i64, result.numStates()) * num_copies > MAX_UNROLLED_REPEAT_STATES) {
            if (diag) |d| {
                if (has_upper_bound) {
                    try d.setFmt(self.allocator, .message, "The bounded repetition {{{d},{d}}} is too large to compile into a FSM", .{ lower, upper });
                } else {
                    try d.setFmt(self.allocator, .message, "The bounded repetition {{{d},}} is too large to compile into a FSM", .{lower});
                }
            }
            return error.RepeatTooLarge;
        }

        var new_ends: std.ArrayList(i32) = .empty;
        defer new_ends.deinit(self.allocator);
        if (lower <= 1) try new_ends.appendSlice(self.allocator, result.endsSlice());

        if (has_upper_bound) {
            var copy_i: i32 = 2;
            while (copy_i <= upper) : (copy_i += 1) {
                var child_clone = try child_fsm.dupe(self.allocator);
                defer child_clone.deinit();
                var inputs = [_]FsmWithStartEnd{ result, child_clone };
                result = try FsmWithStartEnd.concat(self.allocator, &inputs);
                inputs[0].deinit();
                if (copy_i >= lower) try new_ends.appendSlice(self.allocator, result.endsSlice());
            }
        } else {
            var copy_i: i32 = 2;
            while (copy_i < lower) : (copy_i += 1) {
                var child_clone = try child_fsm.dupe(self.allocator);
                defer child_clone.deinit();
                var inputs = [_]FsmWithStartEnd{ result, child_clone };
                result = try FsmWithStartEnd.concat(self.allocator, &inputs);
                inputs[0].deinit();
            }
            if (result.endsSlice().len == 0) {
                if (diag) |d| try d.setCopy(self.allocator, .message, "Internal error: no end state found in the lower bound FSM");
                return error.RepeatTooLarge;
            }
            const end_of_lower_bound = result.endsSlice()[0];
            var child_clone = try child_fsm.dupe(self.allocator);
            defer child_clone.deinit();
            var inputs = [_]FsmWithStartEnd{ result, child_clone };
            result = try FsmWithStartEnd.concat(self.allocator, &inputs);
            inputs[0].deinit();
            const ends_snapshot = try self.allocator.dupe(i32, result.endsSlice());
            defer self.allocator.free(ends_snapshot);
            for (ends_snapshot) |end| try result.fsmMut().addEpsilonEdge(end, end_of_lower_bound);
        }
        for (new_ends.items) |end| try result.addEndState(end);
        if (lower == 0) {
            const old_start = result.startState();
            const new_start = try result.addState();
            try result.fsmMut().addEpsilonEdge(new_start, old_start);
            result.setStartState(new_start);
            try result.addEndState(new_start);
        }
        return result;
    }

    /// Builds the FSM of one leaf: the empty string, a character class `[...]`, or a sequence of
    /// literal characters, `.` and escapes.
    fn buildLeaf(self: *const RegexIr, regex: []const u8, diag: ?*Diagnostic) RegexError!FsmWithStartEnd {
        var result = FsmWithStartEnd.init(self.allocator, try Fsm.init(self.allocator, 1), 0, .empty, false);
        errdefer result.deinit();
        if (regex.len > 0 and regex[0] == '[') {
            const ranges = try self.parseCharacterClass(regex, diag);
            defer self.allocator.free(ranges);
            const end = try result.addState();
            try addCodepointRanges(result.fsmMut(), 0, end, ranges);
            try result.addEndState(end);
            return result;
        }
        var current: i32 = 0;
        var pos: usize = 0;
        while (pos < regex.len) {
            var ranges_buf: [2]CodepointRange = undefined;
            var ranges_owned: ?[]CodepointRange = null;
            defer if (ranges_owned) |r| self.allocator.free(r);
            var ranges: []const CodepointRange = ranges_buf[0..0];
            if (regex[pos] == '.') {
                pos += 1;
                ranges_buf[0] = .{ .low = 0, .high = MAX_CODEPOINT };
                ranges = ranges_buf[0..1];
            } else if (regex[pos] == '\\') {
                const escape = RegexEscape.parse(self.allocator, regex, &pos, false, diag) catch |e| switch (e) {
                    error.InvalidEscape => return error.RegexParse,
                    else => |other| return other,
                };
                defer escape.deinit(self.allocator);
                switch (escape) {
                    .Single => |cp| {
                        ranges = self.singleCodepointRanges(&ranges_buf, cp);
                    },
                    .Class => |cls| {
                        const resolved = try resolveRanges(self.allocator, cls.ranges, self.case_insensitive, cls.negated);
                        if (resolved.len <= ranges_buf.len) {
                            @memcpy(ranges_buf[0..resolved.len], resolved);
                            self.allocator.free(resolved);
                            ranges = ranges_buf[0..resolved.len];
                        } else {
                            ranges_owned = resolved;
                            ranges = resolved;
                        }
                    },
                }
            } else if (encoding.parseNextUtf8(regex[pos..])) |decoded| {
                pos += decoded.consumed;
                ranges = self.singleCodepointRanges(&ranges_buf, @intCast(decoded.codepoint));
            } else |_| {
                const byte: i32 = regex[pos];
                pos += 1;
                const next = try result.addState();
                try result.fsmMut().addEdge(current, next, byte, byte);
                current = next;
                continue;
            }
            const next = try result.addState();
            try addCodepointRanges(result.fsmMut(), current, next, ranges);
            current = next;
        }
        try result.addEndState(current);
        return result;
    }

    fn singleCodepointRanges(self: *const RegexIr, buf: *[2]CodepointRange, codepoint: u32) []const CodepointRange {
        buf[0] = .{ .low = codepoint, .high = codepoint };
        if (self.case_insensitive) {
            buf[1] = foldAsciiCasePair(codepoint);
            return if (buf[1].low <= buf[1].high) buf[0..2] else buf[0..1];
        }
        return buf[0..1];
    }

    fn parseCharacterClass(self: *const RegexIr, regex: []const u8, diag: ?*Diagnostic) RegexError![]CodepointRange {
        const a = self.allocator;
        const content_end = regex.len - 1;
        const negated = regex.len > 1 and regex[1] == '^' and content_end > 1;
        var pos: usize = if (negated) 2 else 1;
        if (pos == content_end) {
            if (diag) |d| try d.setFmt(a, .message, "Empty character class {s} is not allowed in regex", .{regex});
            return error.RegexParse;
        }

        var ranges: std.ArrayList(CodepointRange) = .empty;
        defer ranges.deinit(a);
        while (pos < content_end) {
            var unit: RegexEscape = undefined;
            if (regex[pos] == '\\') {
                unit = RegexEscape.parse(a, regex, &pos, true, diag) catch |e| switch (e) {
                    error.InvalidEscape => return error.RegexParse,
                    else => |other| return other,
                };
            } else {
                const decoded = encoding.parseNextUtf8(regex[pos..content_end]) catch {
                    if (diag) |d| try d.setFmt(a, .message, "Invalid UTF-8 in regex character class {s}", .{regex});
                    return error.RegexParse;
                };
                pos += decoded.consumed;
                unit = .{ .Single = @intCast(decoded.codepoint) };
            }
            defer unit.deinit(a);
            switch (unit) {
                .Class => |cls| {
                    const resolved = try resolveRanges(a, cls.ranges, false, cls.negated);
                    defer a.free(resolved);
                    try ranges.appendSlice(a, resolved);
                },
                .Single => |low| {
                    if (pos < regex.len and regex[pos] == '-' and pos + 1 < content_end) {
                        pos += 1;
                        var high_unit: RegexEscape = undefined;
                        if (regex[pos] == '\\') {
                            high_unit = RegexEscape.parse(a, regex, &pos, true, diag) catch |e| switch (e) {
                                error.InvalidEscape => return error.RegexParse,
                                else => |other| return other,
                            };
                        } else {
                            const decoded = encoding.parseNextUtf8(regex[pos..content_end]) catch {
                                if (diag) |d| try d.setFmt(a, .message, "Invalid UTF-8 in regex character class {s}", .{regex});
                                return error.RegexParse;
                            };
                            pos += decoded.consumed;
                            high_unit = .{ .Single = @intCast(decoded.codepoint) };
                        }
                        defer high_unit.deinit(a);
                        const high = switch (high_unit) {
                            .Single => |cp| cp,
                            else => {
                                if (diag) |d| try d.setFmt(a, .message, "Invalid character range endpoint in regex character class {s}", .{regex});
                                return error.RegexParse;
                            },
                        };
                        if (high < low) {
                            if (diag) |d| try d.setFmt(a, .message, "Invalid character range (lower bound exceeds upper bound) in regex character class {s}", .{regex});
                            return error.RegexParse;
                        }
                        try ranges.append(a, .{ .low = low, .high = high });
                    } else {
                        try ranges.append(a, .{ .low = low, .high = low });
                    }
                },
            }
        }
        return resolveRanges(a, ranges.items, self.case_insensitive, negated);
    }
};

const ParseContext = struct {
    allocator: Allocator,
    flag_prefix_length: usize,
    diag: ?*Diagnostic,

    fn fail(self: *ParseContext, pos: usize, message: []const u8) RegexError {
        return self.failFmt(pos, "{s}", .{message});
    }

    fn failFmt(self: *ParseContext, pos: usize, comptime fmt: []const u8, args: anytype) RegexError {
        if (self.diag) |d| {
            const message = try std.fmt.allocPrint(self.allocator, fmt, args);
            defer self.allocator.free(message);
            try d.setFmt(
                self.allocator,
                .message,
                "Regex parsing error at position {d}: {s}",
                .{ pos + self.flag_prefix_length + 1, message },
            );
        }
        return error.RegexParse;
    }
};

fn emptyStringFsm(allocator: Allocator) Allocator.Error!FsmWithStartEnd {
    var ends: std.ArrayList(i32) = .empty;
    errdefer ends.deinit(allocator);
    try ends.append(allocator, 0);
    return FsmWithStartEnd.init(allocator, try Fsm.init(allocator, 1), 0, ends, false);
}

fn splitBranches(
    allocator: Allocator,
    entries: []const RegexStackEntry,
    open_at: *usize,
) (Allocator.Error || error{UnclosedParen})!std.ArrayList(std.ArrayList(RegexNode)) {
    for (entries) |entry| {
        if (entry == .GroupOpen) {
            open_at.* = entry.GroupOpen;
            return error.UnclosedParen;
        }
    }
    var branches: std.ArrayList(std.ArrayList(RegexNode)) = .empty;
    errdefer {
        for (branches.items) |*b| {
            for (b.items) |node| node.deinit(allocator);
            b.deinit(allocator);
        }
        branches.deinit(allocator);
    }
    var current: std.ArrayList(RegexNode) = .empty;
    errdefer {
        for (current.items) |node| node.deinit(allocator);
        current.deinit(allocator);
    }
    for (entries) |entry| {
        switch (entry) {
            .Node => |n| try current.append(allocator, n.node),
            .Alternation => {
                try branches.append(allocator, current);
                current = .empty;
            },
            .GroupOpen => return error.UnclosedParen,
        }
    }
    try branches.append(allocator, current);
    return branches;
}

fn skipCharacterClass(regex: []const u8, pos_in: usize) ?usize {
    var pos = pos_in + 1;
    if (pos < regex.len and regex[pos] == '^') pos += 1;
    while (pos < regex.len) : (pos += 1) {
        switch (regex[pos]) {
            '\\' => pos += 1,
            ']' => return pos + 1,
            else => {},
        }
    }
    return null;
}

fn checkRepeat(
    allocator: Allocator,
    regex: []const u8,
    i: *usize,
    diag: ?*Diagnostic,
) (Allocator.Error || error{ InvalidRepeat, RepeatCountInvalid })!struct { lower: i32, upper: i32 } {
    const Skip = struct {
        fn skipSpaces(r: []const u8, idx: *usize) void {
            while (idx.* < r.len and r[idx.*] == ' ') idx.* += 1;
        }
    };
    const Parse = struct {
        fn parseCount(r: []const u8, idx: *usize, d_opt: ?*Diagnostic, a: Allocator) (Allocator.Error || error{RepeatCountInvalid})!?i32 {
            const digits_begin = idx.*;
            while (idx.* < r.len and std.ascii.isDigit(r[idx.*])) idx.* += 1;
            const digits = r[digits_begin..idx.*];
            if (digits.len > MAX_REPEAT_DIGITS) {
                if (d_opt) |d| {
                    try d.setFmt(a, .message, "Invalid repetition count: the count {s} is too large", .{digits});
                }
                return error.RepeatCountInvalid;
            }
            if (digits.len == 0) return null;
            var value: i32 = 0;
            for (digits) |digit| value = value * 10 + @as(i32, digit - '0');
            return value;
        }
    };

    i.* += 1;
    Skip.skipSpaces(regex, i);
    const lower = (try Parse.parseCount(regex, i, diag, allocator)) orelse {
        if (diag) |d| try d.setCopy(allocator, .message, "Invalid repetition count: expected a number after '{'");
        return error.InvalidRepeat;
    };
    Skip.skipSpaces(regex, i);
    if (i.* < regex.len and regex[i.*] == '}') {
        return .{ .lower = lower, .upper = lower };
    }
    if (i.* >= regex.len or regex[i.*] != ',') {
        if (diag) |d| try d.setCopy(allocator, .message, "Invalid repetition count: expected ',' or '}' after the lower bound");
        return error.InvalidRepeat;
    }
    i.* += 1;
    Skip.skipSpaces(regex, i);
    if (i.* < regex.len and regex[i.*] == '}') {
        return .{ .lower = lower, .upper = REPEAT_NO_UPPER_BOUND };
    }
    const upper = (try Parse.parseCount(regex, i, diag, allocator)) orelse {
        if (diag) |d| try d.setCopy(allocator, .message, "Invalid repetition count: expected a number or '}' after ','");
        return error.InvalidRepeat;
    };
    if (upper < lower) {
        if (diag) |d| try d.setFmt(allocator, .message, "Invalid repetition count: the lower bound {d} is larger than the upper bound {d}", .{ lower, upper });
        return error.InvalidRepeat;
    }
    Skip.skipSpaces(regex, i);
    if (i.* >= regex.len or regex[i.*] != '}') {
        if (diag) |d| try d.setCopy(allocator, .message, "Invalid repetition count: expected '}' after the upper bound");
        return error.InvalidRepeat;
    }
    return .{ .lower = lower, .upper = upper };
}

fn resolveRanges(allocator: Allocator, ranges: []const CodepointRange, fold_case: bool, negated: bool) Allocator.Error![]CodepointRange {
    if (!fold_case) return resolveSorted(allocator, ranges, negated);
    var expanded: std.ArrayList(CodepointRange) = .empty;
    defer expanded.deinit(allocator);
    try expanded.appendSlice(allocator, ranges);
    for (ranges) |r| {
        if (foldAsciiCasePairOfRange(r)) |p| try expanded.append(allocator, p);
    }
    return resolveSorted(allocator, expanded.items, negated);
}

fn resolveSorted(allocator: Allocator, ranges: []const CodepointRange, negated: bool) Allocator.Error![]CodepointRange {
    const sorted = try allocator.dupe(CodepointRange, ranges);
    defer allocator.free(sorted);
    std.mem.sortUnstable(CodepointRange, sorted, {}, struct {
        fn less(_: void, x: CodepointRange, y: CodepointRange) bool {
            if (x.low != y.low) return x.low < y.low;
            return x.high < y.high;
        }
    }.less);
    var normalized: std.ArrayList(CodepointRange) = .empty;
    defer normalized.deinit(allocator);
    for (sorted) |r| {
        if (normalized.items.len > 0 and r.low <= normalized.items[normalized.items.len - 1].high + 1) {
            const last = &normalized.items[normalized.items.len - 1];
            last.high = @max(last.high, r.high);
        } else {
            try normalized.append(allocator, r);
        }
    }
    if (!negated) return normalized.toOwnedSlice(allocator);
    var complement: std.ArrayList(CodepointRange) = .empty;
    errdefer complement.deinit(allocator);
    var next: u32 = 0;
    for (normalized.items) |r| {
        if (r.low > next) try complement.append(allocator, .{ .low = next, .high = r.low - 1 });
        if (r.high >= MAX_CODEPOINT) return complement.toOwnedSlice(allocator);
        next = @max(next, r.high + 1);
    }
    try complement.append(allocator, .{ .low = next, .high = MAX_CODEPOINT });
    return complement.toOwnedSlice(allocator);
}

fn foldAsciiCasePair(codepoint: u32) CodepointRange {
    const CASE_OFFSET: u32 = 'a' - 'A';
    if (codepoint >= 'a' and codepoint <= 'z') {
        return .{ .low = codepoint - CASE_OFFSET, .high = codepoint - CASE_OFFSET };
    }
    if (codepoint >= 'A' and codepoint <= 'Z') {
        return .{ .low = codepoint + CASE_OFFSET, .high = codepoint + CASE_OFFSET };
    }
    return .{ .low = 1, .high = 0 };
}

fn foldAsciiCasePairOfRange(r: CodepointRange) ?CodepointRange {
    const CASE_OFFSET: u32 = 'a' - 'A';
    const lower_low = @max(r.low, 'a');
    const lower_high = @min(r.high, 'z');
    if (lower_low <= lower_high) return .{ .low = lower_low - CASE_OFFSET, .high = lower_high - CASE_OFFSET };
    const upper_low = @max(r.low, 'A');
    const upper_high = @min(r.high, 'Z');
    if (upper_low <= upper_high) return .{ .low = upper_low + CASE_OFFSET, .high = upper_high + CASE_OFFSET };
    return null;
}

fn addCodepointRanges(fsm: *Fsm, from: i32, to: i32, ranges: []const CodepointRange) Allocator.Error!void {
    const rb = @import("regex_builder.zig");
    for (ranges) |r| {
        if (r.low <= rb.MAX_1_BYTE_UNICODE) {
            try fsm.addEdge(from, to, @intCast(r.low), @intCast(@min(r.high, rb.MAX_1_BYTE_UNICODE)));
        }
        if (r.high > rb.MAX_1_BYTE_UNICODE) {
            const low = @max(r.low, rb.MAX_1_BYTE_UNICODE + 1);
            try rb.addPackedUtf8RangeEdges(fsm, from, to, rb.codepointToPackedUtf8(low), rb.codepointToPackedUtf8(r.high));
        }
    }
}

test "RegexIr parse, case-insensitive, backreference diagnostic, and leak-free error" {
    const a = std.testing.allocator;
    var diag: Diagnostic = .{};
    defer diag.deinit(a);

    // Backreference error should not leak formatted message.
    try std.testing.expectError(error.RegexParse, RegexIr.parse(a, "(a)\\1", null, "", &diag));
    const m1 = try diag.formatAlloc(a);
    defer a.free(m1);
    try std.testing.expectEqualStrings("Regex parsing error at position 4: Backreference \\1 is not supported in regex", m1);

    // Case-insensitive character class must not leak expanded list.
    var ir = try RegexIr.parse(a, "(?i)[a-dx]+", null, "", &diag);
    defer ir.deinit();
    var fsm = try ir.build(&diag);
    defer fsm.deinit();
    try std.testing.expect(try fsm.acceptString("AbCxD"));
    try std.testing.expect(!try fsm.acceptString("E"));
}
