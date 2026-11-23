//! The parsed regex AST and its lowering into an NFA.
//!
//! Parsing builds a `RegexIr` on a stack of `RegexStackEntry`s; building lowers it into an
//! `FsmWithStartEnd` through the `concat`/`union`/`star`/`plus`/`optional` algebra.

const std = @import("std");
const Allocator = std.mem.Allocator;

const fsm_mod = @import("fsm.zig");
const Fsm = fsm_mod.Fsm;
const fsm_with_start_end = @import("fsm_with_start_end.zig");
const FsmWithStartEnd = fsm_with_start_end.FsmWithStartEnd;
const packed_utf8 = @import("packed_utf8.zig");
const MAX_1_BYTE_UNICODE = packed_utf8.MAX_1_BYTE_UNICODE;
const add_packed_utf8_range_edges = packed_utf8.add_packed_utf8_range_edges;
const codepoint_to_packed_utf8 = packed_utf8.codepoint_to_packed_utf8;
const regex_escape_mod = @import("regex_escape.zig");
const RegexEscape = regex_escape_mod.RegexEscape;
const MAX_CODEPOINT = regex_escape_mod.MAX_CODEPOINT;
const CodepointRange = regex_escape_mod.CodepointRange;
const regex_node_mod = @import("regex_node.zig");
const RegexNode = regex_node_mod.RegexNode;
const regex_stack_entry_mod = @import("regex_stack_entry.zig");
const RegexStackEntry = regex_stack_entry_mod.RegexStackEntry;
const grammar_builder_mod = @import("../grammar/mod.zig");
const GrammarBuilder = grammar_builder_mod.GrammarBuilder;
const support = @import("../support/mod.zig");
const encoding = support.encoding;

const REPEAT_NO_UPPER_BOUND: i32 = -1;
/// Bounded repetitions above this are compiled into a repeat FSM edge (when a grammar builder is
/// available) instead of being unrolled. Matches the grammar-level repetition expander.
const LARGE_REPEAT_THRESHOLD: i32 = 128;
/// The cap of the estimated state count of a bounded repetition that has to be unrolled.
const MAX_UNROLLED_REPEAT_STATES: i64 = 100_000;
/// `10^9` fits in an `i32`; longer counts could overflow.
const MAX_REPEAT_DIGITS: usize = 9;

/// Errors of the parse/build path (`Result<_, String>` in Rust; the exact message text is
/// reported through `err_msg` where the Rust tests compare it).
pub const RegexError = Allocator.Error || error{
    /// Malformed/unsupported regex; details in `err_msg` out-param.
    RegexParse,
    /// A repetition is too large to unroll.
    RepeatTooLarge,
    /// `{n,m}` count is malformed (message via `err_msg`/out-param).
    InvalidRepeat,
    RepeatCountInvalid,
    /// A `(` was left open (`split_branches` payload).
    UnclosedParen,
    /// Propagated from `RegexEscape.parse` (already reported via `err_msg`).
    InvalidEscape,
};

/// A parsed regex: the top-level sequence and the flags.
pub const RegexIr = struct {
    /// Backs every node of this AST (freed by `deinit`).
    allocator: Allocator,
    states: []RegexNode,
    case_insensitive: bool,

    /// Frees the storage owned by this AST.
    pub fn deinit(self: *RegexIr) void {
        for (self.states) |state| state.deinit(self.allocator);
        self.allocator.free(self.states);
    }

    /// Parses a regex. A leading `(?i)` enables ASCII case-insensitive matching.
    ///
    /// With a `builder`, a bounded repetition whose upper bound (or, if unbounded, lower bound)
    /// exceeds 128 becomes a new rule (with a regex body holding the repeated sub-pattern, named
    /// after `rule_hint`) referenced by a repeat edge, instead of being unrolled.
    ///
    /// On `error.RegexParse`, `err_msg.*` (if non-null pointer) receives the message
    /// `"Regex parsing error at position <1-based>: <description>"` — the position includes
    /// the `(?i)` prefix — allocated from `allocator`; free it after use.
    pub fn parse(
        allocator: Allocator,
        regex_with_flags: []const u8,
        builder: ?*GrammarBuilder,
        rule_hint: []const u8,
        err_msg: ?*?[]u8,
    ) RegexError!RegexIr {
        const prefix = [_]u8{ '(', '?', 'i', ')' };
        const has_flags = std.mem.startsWith(u8, regex_with_flags, &prefix);
        const regex = if (has_flags) regex_with_flags[prefix.len..] else regex_with_flags;
        const case_insensitive = has_flags;
        const flag_prefix_length = regex_with_flags.len - regex.len;
        const lossy = struct {
            fn f(a: Allocator, bytes: []const u8) Allocator.Error![]u8 {
                return a.dupe(u8, bytes);
            }
        }.f;

        var parse_ctx = ParseContext{
            .allocator = allocator,
            .regex = regex,
            .flag_prefix_length = flag_prefix_length,
            .err_msg = err_msg,
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
                        const msg = try lossy(allocator, regex);
                        defer allocator.free(msg);
                        std.debug.print("Anchor '{c}' in the middle of regex is ignored: {s}\n", .{ c, msg });
                    }
                },
                '[' => {
                    const class_end = skip_character_class(regex, i) orelse return parse_ctx.fail(i, "Unclosed '['");
                    const content_begin = if (i + 1 < regex.len and regex[i + 1] == '^') i + 2 else i + 1;
                    if (content_begin + 1 == class_end) {
                        return parse_ctx.fail(i, "Empty character class is not allowed in regex");
                    }
                    const leaf = try allocator.dupe(u8, regex[i..class_end]);
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
                        return parse_ctx.fail_fmt(i, "There is nothing to repeat before '{c}'", .{c});
                    if (top != .Node) {
                        try stack.append(allocator, top);
                        return parse_ctx.fail_fmt(i, "There is nothing to repeat before '{c}'", .{c});
                    }
                    const child = try allocator.create(RegexNode);
                    child.* = top.Node.node;
                    const node: RegexNode = switch (c) {
                        '+' => .{ .Plus = child },
                        '*' => .{ .Star = child },
                        else => .{ .Optional = child },
                    };
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
                                // Skip the whole lookahead group and treat it as the empty string.
                                const msg = try lossy(allocator, regex);
                                defer allocator.free(msg);
                                std.debug.print("Lookahead assertion is not supported and is ignored in regex: {s}\n", .{msg});
                                var depth: i32 = 1;
                                var j = i + 3;
                                while (j < size and depth > 0) {
                                    switch (regex[j]) {
                                        '\\' => j += 1,
                                        '[' => {
                                            j = skip_character_class(regex, j) orelse
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
                                try stack.append(allocator, .{ .Node = .{
                                    .node = .{ .Leaf = try allocator.dupe(u8, "") },
                                    .span_begin = i,
                                    .span_end = j,
                                } });
                                i = j - 1;
                            },
                            '<', 'P' => {
                                if (!(modifier == '<' or (i + 3 < regex.len and regex[i + 3] == '<'))) {
                                    return parse_ctx.fail_fmt(i, "Unsupported group modifier '(?{c}'", .{modifier});
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
                                // The group name is ignored; the content compiles as a plain group.
                                try stack.append(allocator, .{ .GroupOpen = i });
                                i = name_end;
                            },
                            else => {
                                return parse_ctx.fail_fmt(i, "Unsupported group modifier '(?{c}'", .{modifier});
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
                    var branches = split_branches(allocator, content, &group_open_at) catch |e| switch (e) {
                        error.UnclosedParen => return parse_ctx.fail(group_open_at, "The parenthesis is not closed"),
                        else => return e,
                    };
                    // The consumed stack entries (open marker and content) are freed below;
                    // their nodes moved into `branches`.
                    stack.items.len = open_idx + 1;
                    stack.shrinkRetainingCapacity(open_idx);
                    // An empty group or an empty alternative matches the empty string.
                    var node: RegexNode = undefined;
                    if (branches.items.len == 1) {
                        var only = branches.items[0];
                        const bracket = try allocator.alloc(RegexNode, only.items.len);
                        @memcpy(bracket, only.items);
                        only.deinit(allocator);
                        branches.deinit(allocator);
                        node = .{ .Bracket = bracket };
                    } else {
                        const union_nodes = try allocator.alloc(RegexNode, branches.items.len);
                        for (branches.items, 0..) |branch, bi| {
                            var branch_mut = branch;
                            const bracket = try allocator.alloc(RegexNode, branch_mut.items.len);
                            @memcpy(bracket, branch_mut.items);
                            branch_mut.deinit(allocator);
                            union_nodes[bi] = .{ .Bracket = bracket };
                        }
                        branches.deinit(allocator);
                        node = .{ .Union = union_nodes };
                    }
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
                    const repeat_begin = i;
                    var repeat_plain: ?[]u8 = null;
                    var repeat = check_repeat(allocator, regex, &i, &repeat_plain) catch |e| switch (e) {
                        error.InvalidRepeat, error.RepeatCountInvalid => {
                            if (err_msg) |m| {
                                m.* = std.fmt.allocPrint(
                                    allocator,
                                    "Regex parsing error at position {d}: {s}",
                                    .{ repeat_begin + flag_prefix_length + 1, repeat_plain.? },
                                ) catch |e2| return e2;
                            }
                            allocator.free(repeat_plain.?);
                            // `top` is a Node on this path; its node would leak on return.
                            if (top == .Node) top.Node.node.deinit(allocator);
                            return error.RegexParse;
                        },
                        else => return e,
                    };
                    if (i + 1 < regex.len and regex[i + 1] == '?') i += 1;
                    const is_large_repeat = if (repeat.upper == REPEAT_NO_UPPER_BOUND)
                        repeat.lower > LARGE_REPEAT_THRESHOLD
                    else
                        repeat.upper > LARGE_REPEAT_THRESHOLD;
                    const node: RegexNode = if (builder != null and is_large_repeat) blk: {
                        // The repeated sub-pattern becomes a rule with a regex body, repeated through
                        // a repeat edge that the Earley parser counts at runtime.
                        var inner_regex: std.ArrayList(u8) = .empty;
                        defer inner_regex.deinit(allocator);
                        if (case_insensitive) try inner_regex.appendSlice(allocator, "(?i)");
                        try inner_regex.appendSlice(allocator, regex[top.Node.span_begin..top.Node.span_end]);
                        if (top.Node.node.is_nullable()) {
                            // The count of a nullable element cannot be enforced (as in the
                            // repetition normalizer), so the lower bound is relaxed to 0.
                            repeat.lower = 0;
                        }
                        const hint: []const u8 = if (rule_hint.len == 0) "regex" else rule_hint;
                        const b = builder.?;
                        const body = try b.add_regex(inner_regex.items, false);
                        const rule_id = try b.add_rule_with_hint(std.fmt.allocPrint(allocator, "{s}_repeat", .{hint}) catch |e2| return e2, body);
                        b.update_lookahead_exact(rule_id, true);
                        if (repeat.upper != REPEAT_NO_UPPER_BOUND) {
                            break :blk .{ .RepeatSubrule = .{ .rule_id = rule_id, .lower = repeat.lower, .upper = repeat.upper } };
                        } else {
                            // {n,} == {n}{0,}: a repeat edge for the mandatory part, then a starred
                            // rule reference.
                            const rule_ref = try allocator.create(RegexNode);
                            rule_ref.* = .{ .RuleRef = rule_id };
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
                    } else .{ .Repeat = .{
                        .child = try allocator.create(RegexNode),
                        .lower = repeat.lower,
                        .upper = repeat.upper,
                    } };
                    if (node == .Repeat) node.Repeat.child.* = top.Node.node;
                    try stack.append(allocator, .{ .Node = .{
                        .node = node,
                        .span_begin = top.Node.span_begin,
                        .span_end = i + 1,
                    } });
                },
                '\\' => {
                    var escape_end = i;
                    var escape_err: ?[]const u8 = null;
                    _ = RegexEscape.parse(allocator, regex, &escape_end, false, &escape_err) catch |e| switch (e) {
                        error.InvalidEscape => {
                            const msg = try allocator.dupe(u8, escape_err.?);
                            if (err_msg) |m| {
                                m.* = std.fmt.allocPrint(
                                    allocator,
                                    "Regex parsing error at position {d}: {s}",
                                    .{ i + flag_prefix_length + 1, msg },
                                ) catch |e2| return e2;
                            }
                            allocator.free(msg);
                            return error.RegexParse;
                        },
                        else => return e,
                    };
                    const leaf = try allocator.dupe(u8, regex[i..escape_end]);
                    try stack.append(allocator, .{ .Node = .{
                        .node = .{ .Leaf = leaf },
                        .span_begin = i,
                        .span_end = escape_end,
                    } });
                    i = escape_end - 1;
                },
                else => {
                    const num_bytes: usize = if (encoding.parse_next_utf8(regex[i..])) |decoded|
                        decoded.consumed
                    else |_| 1;
                    const leaf = try allocator.dupe(u8, regex[i .. i + num_bytes]);
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
        var branches = split_branches(allocator, stack.items, &group_open_at) catch |e| switch (e) {
            error.UnclosedParen => {
                for (stack.items) |entry| {
                    if (entry == .Node) entry.Node.node.deinit(allocator);
                }
                stack.items.len = 0; // nodes freed; the errdefer deinits the stack itself
                return parse_ctx.fail(group_open_at, "The parenthesis is not closed");
            },
            else => return e,
        };
        var states: []RegexNode = undefined;
        if (branches.items.len == 1) {
            states = try allocator.alloc(RegexNode, branches.items[0].items.len);
            @memcpy(states, branches.items[0].items);
        } else {
            const union_nodes = try allocator.alloc(RegexNode, branches.items.len);
            for (branches.items, 0..) |branch, bi| {
                var branch_mut = branch;
                const bracket = try allocator.alloc(RegexNode, branch_mut.items.len);
                @memcpy(bracket, branch_mut.items);
                branch_mut.deinit(allocator);
                union_nodes[bi] = .{ .Bracket = bracket };
            }
            states = try allocator.alloc(RegexNode, 1);
            states[0] = .{ .Union = union_nodes };
        }
        branches.deinit(allocator);
        stack.deinit(allocator);
        return .{ .allocator = allocator, .states = states, .case_insensitive = case_insensitive };
    }

    /// Whether the regex matches the empty string.
    pub fn matches_empty(self: *const RegexIr) bool {
        return RegexNode.is_nullable_sequence(self.states);
    }

    /// Lowers the regex into an NFA. The caller owns the result.
    pub fn build(self: *const RegexIr, err_msg: ?*?[]u8) RegexError!FsmWithStartEnd {
        return self.build_sequence(self.states, err_msg);
    }

    fn build_sequence(self: *const RegexIr, nodes: []const RegexNode, err_msg: ?*?[]u8) RegexError!FsmWithStartEnd {
        if (nodes.len == 0) {
            return empty_string_fsm(self.allocator);
        }
        var fsms: std.ArrayList(FsmWithStartEnd) = .empty;
        defer {
            for (fsms.items) |*f| f.deinit();
            fsms.deinit(self.allocator);
        }
        for (nodes) |node| try fsms.append(self.allocator, try self.visit(node, err_msg));
        if (fsms.items.len == 1) {
            const only = fsms.items[0];
            fsms.items.len = 0;
            return only;
        } else {
            const result = try FsmWithStartEnd.concat(self.allocator, fsms.items);
            return result;
        }
    }

    fn visit(self: *const RegexIr, node: RegexNode, err_msg: ?*?[]u8) RegexError!FsmWithStartEnd {
        return switch (node) {
            .Leaf => |regex| self.build_leaf(regex, err_msg),
            .Star => |child| (try self.visit(child.*, err_msg)).star(self.allocator),
            .Plus => |child| (try self.visit(child.*, err_msg)).plus(self.allocator),
            .Optional => |child| (try self.visit(child.*, err_msg)).optional(self.allocator),
            .Union => |branches| blk: {
                var fsms: std.ArrayList(FsmWithStartEnd) = .empty;
                defer {
                    for (fsms.items) |*f| f.deinit();
                    fsms.deinit(self.allocator);
                }
                for (branches) |branch| try fsms.append(self.allocator, try self.visit(branch, err_msg));
                break :blk try FsmWithStartEnd.union_(self.allocator, fsms.items);
            },
            .Bracket => |children| self.build_sequence(children, err_msg),
            .Repeat => |r| self.build_repeat(r.child.*, r.lower, r.upper, err_msg),
            .RuleRef => |rule_id| blk: {
                var fsm = try Fsm.new(self.allocator, 2);
                errdefer fsm.deinit();
                try fsm.add_rule_edge(0, 1, rule_id);
                var ends: std.ArrayList(i32) = .empty;
                try ends.append(self.allocator, 1);
                break :blk try FsmWithStartEnd.new(self.allocator, fsm, 0, ends, false);
            },
            .RepeatSubrule => |r| blk: {
                // The state holding the repeat edge is padded with epsilon edges on both sides, so
                // compositions never add another outgoing edge to it (a repeat-edge state must have
                // no other outgoing edges).
                var fsm = try Fsm.new(self.allocator, 4);
                errdefer fsm.deinit();
                try fsm.add_epsilon_edge(0, 1);
                try fsm.add_repeat_edge(1, 2, r.rule_id, r.lower, r.upper);
                try fsm.add_epsilon_edge(2, 3);
                var ends: std.ArrayList(i32) = .empty;
                try ends.append(self.allocator, 3);
                break :blk try FsmWithStartEnd.new(self.allocator, fsm, 0, ends, false);
            },
        };
    }

    /// Unrolls `child{lower, upper}` (`upper == -1` is unbounded).
    fn build_repeat(self: *const RegexIr, child: RegexNode, lower: i32, upper: i32, err_msg: ?*?[]u8) RegexError!FsmWithStartEnd {
        const has_upper_bound = upper != REPEAT_NO_UPPER_BOUND;
        if (has_upper_bound and upper == 0) {
            // {0} / {0,0} matches exactly the empty string; the general path below starts from one
            // copy of the child, whose end states stay accepting.
            return empty_string_fsm(self.allocator);
        }
        var child_fsm = try self.visit(child, err_msg);
        defer child_fsm.deinit();
        var result = try child_fsm.clone(self.allocator);
        errdefer result.deinit();
        // Guard against state explosion. With a grammar builder, large repetitions become repeat
        // edges instead and never reach this point.
        const num_copies: i64 = if (has_upper_bound) upper else @max(lower, 1);
        if (@as(i64, result.num_states()) * num_copies > MAX_UNROLLED_REPEAT_STATES) {
            if (err_msg) |m| {
                m.* = if (has_upper_bound)
                    std.fmt.allocPrint(self.allocator, "The bounded repetition {{{d},{d}}} is too large to compile into a FSM", .{ lower, upper }) catch |e| return e
                else
                    std.fmt.allocPrint(self.allocator, "The bounded repetition {{{d},}} is too large to compile into a FSM", .{lower}) catch |e| return e;
            }
            return error.RepeatTooLarge;
        }

        // A single copy is accepting when the lower bound is at most 1.
        var new_ends: std.ArrayList(i32) = .empty;
        errdefer new_ends.deinit(self.allocator);
        if (lower <= 1) try new_ends.appendSlice(self.allocator, result.get_ends());

        if (has_upper_bound) {
            var copy_i: i32 = 2;
            while (copy_i <= upper) : (copy_i += 1) {
                var child_clone = try child_fsm.clone(self.allocator);
                defer child_clone.deinit();
                var inputs = [_]FsmWithStartEnd{ result, child_clone };
                result = try FsmWithStartEnd.concat(self.allocator, &inputs);
                inputs[0].deinit();
                if (copy_i >= lower) try new_ends.appendSlice(self.allocator, result.get_ends());
            }
        } else {
            var copy_i: i32 = 2;
            while (copy_i < lower) : (copy_i += 1) {
                var child_clone = try child_fsm.clone(self.allocator);
                defer child_clone.deinit();
                var inputs = [_]FsmWithStartEnd{ result, child_clone };
                result = try FsmWithStartEnd.concat(self.allocator, &inputs);
                inputs[0].deinit();
            }
            if (result.get_ends().len == 0) {
                if (err_msg) |m| m.* = try self.allocator.dupe(u8, "Internal error: no end state found in the lower bound FSM");
                return error.RepeatTooLarge;
            }
            const end_of_lower_bound = result.get_ends()[0];
            var child_clone = try child_fsm.clone(self.allocator);
            defer child_clone.deinit();
            var inputs = [_]FsmWithStartEnd{ result, child_clone };
            result = try FsmWithStartEnd.concat(self.allocator, &inputs);
            inputs[0].deinit();
            const ends_snapshot = try self.allocator.dupe(i32, result.get_ends());
            defer self.allocator.free(ends_snapshot);
            for (ends_snapshot) |end| try result.fsm_mut().add_epsilon_edge(end, end_of_lower_bound);
        }
        for (new_ends.items) |end| result.add_end_state(end);
        if (lower == 0) {
            // A fresh accepting start state makes zero repetitions match. Making the original start
            // accepting would also accept strings that merely loop back to it inside the first copy.
            const old_start = result.get_start();
            const new_start = try result.add_state();
            try result.fsm_mut().add_epsilon_edge(new_start, old_start);
            result.set_start_state(new_start);
            result.add_end_state(new_start);
        }
        return result;
    }

    /// Builds the FSM of one leaf: the empty string, a character class `[...]`, or a sequence of
    /// literal characters, `.` and escapes.
    fn build_leaf(self: *const RegexIr, regex: []const u8, err_msg: ?*?[]u8) RegexError!FsmWithStartEnd {
        var result = try FsmWithStartEnd.new(self.allocator, try Fsm.new(self.allocator, 1), 0, .empty, false);
        errdefer result.deinit();
        if (regex.len > 0 and regex[0] == '[') {
            const ranges = try self.parse_character_class(regex, err_msg);
            defer self.allocator.free(ranges);
            const end = try result.add_state();
            try add_codepoint_ranges(result.fsm_mut(), 0, end, ranges);
            result.add_end_state(end);
            return result;
        }
        var current: i32 = 0;
        var pos: usize = 0;
        while (pos < regex.len) {
            var ranges_buf: [2]CodepointRange = undefined;
            var ranges_owned: ?[]CodepointRange = null;
            defer if (ranges_owned) |r| self.allocator.free(r);
            var ranges: []const CodepointRange = ranges_buf[0..0];
            var codepoint: u32 = 0;
            if (regex[pos] == '.') {
                pos += 1;
                ranges_buf[0] = .{ .low = 0, .high = MAX_CODEPOINT };
                ranges = ranges_buf[0..1];
            } else if (regex[pos] == '\\') {
                var escape_err: ?[]const u8 = null;
                const escape = RegexEscape.parse(self.allocator, regex, &pos, false, &escape_err) catch |e| switch (e) {
                    error.InvalidEscape => {
                        if (err_msg) |m| m.* = try self.allocator.dupe(u8, escape_err.?);
                        return error.RegexParse;
                    },
                    else => |other| return other,
                };
                defer escape.deinit(self.allocator);
                switch (escape) {
                    .Single => |cp| {
                        codepoint = cp;
                        ranges = self.single_codepoint_ranges(&ranges_buf, codepoint);
                    },
                    .Class => |cls| {
                        const resolved = try resolve_ranges(self.allocator, cls.ranges, self.case_insensitive, cls.negated);
                        defer self.allocator.free(resolved);
                        if (resolved.len <= ranges_buf.len) {
                            @memcpy(ranges_buf[0..resolved.len], resolved);
                            ranges = ranges_buf[0..resolved.len];
                        } else {
                            ranges_owned = try self.allocator.dupe(CodepointRange, resolved);
                            ranges = ranges_owned.?;
                        }
                    },
                }
            } else if (encoding.parse_next_utf8(regex[pos..])) |decoded| {
                pos += decoded.consumed;
                ranges = self.single_codepoint_ranges(&ranges_buf, @intCast(decoded.codepoint));
            } else |_| {
                // Be permissive with non-UTF-8 patterns: match the raw byte.
                const byte: i32 = regex[pos];
                pos += 1;
                const next = try result.add_state();
                try result.fsm_mut().add_edge(current, next, byte, byte);
                current = next;
                continue;
            }
            const next = try result.add_state();
            try add_codepoint_ranges(result.fsm_mut(), current, next, ranges);
            current = next;
        }
        result.add_end_state(current);
        return result;
    }

    /// Writes the ranges accepting one codepoint (plus the ASCII case-folded counterpart when
    /// matching case-insensitively) into `buf`, returning the active slice.
    fn single_codepoint_ranges(self: *const RegexIr, buf: *[2]CodepointRange, codepoint: u32) []const CodepointRange {
        buf[0] = .{ .low = codepoint, .high = codepoint };
        if (self.case_insensitive) {
            buf[1] = fold_ascii_case_pair(codepoint);
            return if (buf[1].low <= buf[1].high) buf[0..2] else buf[0..1];
        }
        return buf[0..1];
    }

    /// Parses a character class leaf `[...]` into its accepted codepoint ranges. ASCII case
    /// folding (if enabled) is applied before negation. Allocated from `self.allocator`.
    fn parse_character_class(self: *const RegexIr, regex: []const u8, err_msg: ?*?[]u8) RegexError![]CodepointRange {
        const a = self.allocator;
        const content_end = regex.len - 1;
        const negated = regex.len > 1 and regex[1] == '^' and content_end > 1;
        var pos: usize = if (negated) 2 else 1;
        if (pos == content_end) {
            const msg = try std.fmt.allocPrint(a, "Empty character class {s} is not allowed in regex", .{regex});
            if (err_msg) |m| m.* = msg;
            return error.RegexParse;
        }

        var ranges: std.ArrayList(CodepointRange) = .empty;
        errdefer ranges.deinit(a);
        while (pos < content_end) {
            // One class unit: an escape sequence or a literal (possibly multi-byte) character.
            var unit: RegexEscape = undefined;
            if (regex[pos] == '\\') {
                var escape_err: ?[]const u8 = null;
                unit = RegexEscape.parse(a, regex, &pos, true, &escape_err) catch |e| switch (e) {
                    error.InvalidEscape => {
                        if (err_msg) |m| m.* = try a.dupe(u8, escape_err.?);
                        return error.RegexParse;
                    },
                    else => |other| return other,
                };
            } else {
                const decoded = encoding.parse_next_utf8(regex[pos..content_end]) catch {
                    const msg = try std.fmt.allocPrint(a, "Invalid UTF-8 in regex character class {s}", .{regex});
                    if (err_msg) |m| m.* = msg;
                    return error.RegexParse;
                };
                pos += decoded.consumed;
                unit = .{ .Single = @intCast(decoded.codepoint) };
            }
            defer unit.deinit(a);
            switch (unit) {
                .Class => |cls| {
                    // Class escapes like \d cannot be a range endpoint; a following '-' is literal.
                    const resolved = try resolve_ranges(a, cls.ranges, false, cls.negated);
                    defer a.free(resolved);
                    try ranges.appendSlice(a, resolved);
                },
                .Single => |low| {
                    if (pos < regex.len and regex[pos] == '-' and pos + 1 < content_end) {
                        pos += 1;
                        var high_unit: RegexEscape = undefined;
                        if (regex[pos] == '\\') {
                            var escape_err: ?[]const u8 = null;
                            high_unit = RegexEscape.parse(a, regex, &pos, true, &escape_err) catch |e| switch (e) {
                                error.InvalidEscape => {
                                    if (err_msg) |m| m.* = try a.dupe(u8, escape_err.?);
                                    return error.RegexParse;
                                },
                                else => |other| return other,
                            };
                        } else {
                            const decoded = encoding.parse_next_utf8(regex[pos..content_end]) catch {
                                const msg = try std.fmt.allocPrint(a, "Invalid UTF-8 in regex character class {s}", .{regex});
                                if (err_msg) |m| m.* = msg;
                                return error.RegexParse;
                            };
                            pos += decoded.consumed;
                            high_unit = .{ .Single = @intCast(decoded.codepoint) };
                        }
                        defer high_unit.deinit(a);
                        const high = switch (high_unit) {
                            .Single => |cp| cp,
                            else => {
                                const msg = try std.fmt.allocPrint(a, "Invalid character range endpoint in regex character class {s}", .{regex});
                                if (err_msg) |m| m.* = msg;
                                return error.RegexParse;
                            },
                        };
                        if (high < low) {
                            const msg = try std.fmt.allocPrint(a, "Invalid character range (lower bound exceeds upper bound) in regex character class {s}", .{regex});
                            if (err_msg) |m| m.* = msg;
                            return error.RegexParse;
                        }
                        try ranges.append(a, .{ .low = low, .high = high });
                    } else {
                        try ranges.append(a, .{ .low = low, .high = low });
                    }
                },
            }
        }
        return resolve_ranges(a, ranges.items, self.case_insensitive, negated);
    }
};

/// Parse-context helper formatting "Regex parsing error at position <1-based>: <message>".
const ParseContext = struct {
    allocator: Allocator,
    regex: []const u8,
    flag_prefix_length: usize,
    err_msg: ?*?[]u8,

    fn fail(self: *ParseContext, pos: usize, message: []const u8) RegexError {
        return self.fail_fmt(pos, "{s}", .{message});
    }

    fn fail_fmt(self: *ParseContext, pos: usize, comptime fmt: []const u8, args: anytype) RegexError {
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch return error.OutOfMemory;
        if (self.err_msg) |slot| {
            slot.* = std.fmt.allocPrint(
                self.allocator,
                "Regex parsing error at position {d}: {s}",
                .{ pos + self.flag_prefix_length + 1, message },
            ) catch return error.OutOfMemory;
        }
        return error.RegexParse;
    }
};

/// The FSM matching exactly the empty string.
fn empty_string_fsm(allocator: Allocator) Allocator.Error!FsmWithStartEnd {
    var ends: std.ArrayList(i32) = .empty;
    try ends.append(allocator, 0);
    return FsmWithStartEnd.new(allocator, try Fsm.new(allocator, 1), 0, ends, false);
}

/// Splits stack entries (left to right) at the alternations into branches. Errors with
/// `error.UnclosedParen` (the Rust `usize` payload becomes the caller-reported position).
fn split_branches(allocator: Allocator, entries: []const RegexStackEntry, open_at: *usize) (Allocator.Error || error{UnclosedParen})!std.ArrayList(std.ArrayList(RegexNode)) {
    // Pre-scan: if a `(` was left open, report its offset without moving any node out of the
    // caller's stack (the caller's errdefer keeps ownership; the Rust path drops everything).
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

/// The offset right after the character class starting at `regex[pos] == '['`, or null if it
/// is not closed.
fn skip_character_class(regex: []const u8, pos_in: usize) ?usize {
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

/// A `{n}` / `{n,}` / `{n,m}` repetition parsed at `regex[i.*] == '{'`, leaving `i` at the
/// closing `}`. An unbounded upper bound is `-1`. Message via `err_msg`.
fn check_repeat(allocator: Allocator, regex: []const u8, i: *usize, err_msg: ?*?[]u8) (Allocator.Error || error{ InvalidRepeat, RepeatCountInvalid })!struct { lower: i32, upper: i32 } {
    const Skip = struct {
        fn skip_spaces(r: []const u8, idx: *usize) void {
            while (idx.* < r.len and r[idx.*] == ' ') idx.* += 1;
        }
    };
    const Parse = struct {
        fn parse_count(r: []const u8, idx: *usize, slot: ?*?[]u8, a: Allocator) (Allocator.Error || error{RepeatCountInvalid})!?i32 {
            const digits_begin = idx.*;
            while (idx.* < r.len and std.ascii.isDigit(r[idx.*])) idx.* += 1;
            const digits = r[digits_begin..idx.*];
            if (digits.len > MAX_REPEAT_DIGITS) {
                if (slot) |s| {
                    s.* = try std.fmt.allocPrint(a, "Invalid repetition count: the count {s} is too large", .{digits});
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
    Skip.skip_spaces(regex, i);
    const lower = (try Parse.parse_count(regex, i, err_msg, allocator)) orelse {
        if (err_msg) |s| s.* = try allocator.dupe(u8, "Invalid repetition count: expected a number after '{'");
        return error.InvalidRepeat;
    };
    Skip.skip_spaces(regex, i);
    if (i.* >= regex.len or regex[i.*] == '}') {
        if (i.* < regex.len) return .{ .lower = lower, .upper = lower };
    }
    if (i.* >= regex.len or regex[i.*] != ',') {
        if (err_msg) |s| s.* = try allocator.dupe(u8, "Invalid repetition count: expected ',' or '}' after the lower bound");
        return error.InvalidRepeat;
    }
    i.* += 1;
    Skip.skip_spaces(regex, i);
    if (i.* < regex.len and regex[i.*] == '}') {
        return .{ .lower = lower, .upper = REPEAT_NO_UPPER_BOUND };
    }
    const upper = (try Parse.parse_count(regex, i, err_msg, allocator)) orelse {
        if (err_msg) |s| s.* = try allocator.dupe(u8, "Invalid repetition count: expected a number or '}' after ','");
        return error.InvalidRepeat;
    };
    if (upper < lower) {
        if (err_msg) |s| {
            s.* = try std.fmt.allocPrint(allocator, "Invalid repetition count: the lower bound {d} is larger than the upper bound {d}", .{ lower, upper });
        }
        return error.InvalidRepeat;
    }
    Skip.skip_spaces(regex, i);
    if (i.* >= regex.len or regex[i.*] != '}') {
        if (err_msg) |s| s.* = try allocator.dupe(u8, "Invalid repetition count: expected '}' after the upper bound");
        return error.InvalidRepeat;
    }
    return .{ .lower = lower, .upper = upper };
}

/// Applies ASCII case folding (if `fold_case`) and normalization, then complements the ranges
/// (if `negated`). Allocated from `allocator`.
fn resolve_ranges(allocator: Allocator, ranges: []const CodepointRange, fold_case: bool, negated: bool) Allocator.Error![]CodepointRange {
    if (!fold_case) return resolve_sorted(allocator, ranges, negated);
    // The Rust version scans only the original elements (the range end is captured once).
    var expanded: std.ArrayList(CodepointRange) = .empty;
    errdefer expanded.deinit(allocator);
    try expanded.appendSlice(allocator, ranges);
    for (ranges) |r| {
        if (fold_ascii_case_pair_of_range(r)) |p| try expanded.append(allocator, p);
    }
    return resolve_sorted(allocator, expanded.items, negated);
}

fn resolve_sorted(allocator: Allocator, ranges: []const CodepointRange, negated: bool) Allocator.Error![]CodepointRange {
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
    // The complement over the codepoint domain [0, MAX_CODEPOINT].
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

/// The ASCII case-folded counterpart of one codepoint, or a sentinel (low > high) if it has none.
fn fold_ascii_case_pair(codepoint: u32) CodepointRange {
    const CASE_OFFSET: u32 = 'a' - 'A';
    if (codepoint >= 'a' and codepoint <= 'z') {
        return .{ .low = codepoint - CASE_OFFSET, .high = codepoint - CASE_OFFSET };
    }
    if (codepoint >= 'A' and codepoint <= 'Z') {
        return .{ .low = codepoint + CASE_OFFSET, .high = codepoint + CASE_OFFSET };
    }
    return .{ .low = 1, .high = 0 };
}

/// The ASCII case-folded counterpart range of one range, or null if there is none.
fn fold_ascii_case_pair_of_range(r: CodepointRange) ?CodepointRange {
    const CASE_OFFSET: u32 = 'a' - 'A';
    const lower_low = @max(r.low, 'a');
    const lower_high = @min(r.high, 'z');
    if (lower_low <= lower_high) return .{ .low = lower_low - CASE_OFFSET, .high = lower_high - CASE_OFFSET };
    const upper_low = @max(r.low, 'A');
    const upper_high = @min(r.high, 'Z');
    if (upper_low <= upper_high) return .{ .low = upper_low + CASE_OFFSET, .high = upper_high + CASE_OFFSET };
    return null;
}

/// Adds edges from `from` to `to` accepting the UTF-8 encoding of every codepoint in `ranges`.
/// Multi-byte characters get intermediate states.
fn add_codepoint_ranges(fsm: *Fsm, from: i32, to: i32, ranges: []const CodepointRange) Allocator.Error!void {
    for (ranges) |r| {
        if (r.low <= MAX_1_BYTE_UNICODE) {
            try fsm.add_edge(from, to, @intCast(r.low), @intCast(@min(r.high, MAX_1_BYTE_UNICODE)));
        }
        if (r.high > MAX_1_BYTE_UNICODE) {
            const low = @max(r.low, MAX_1_BYTE_UNICODE + 1);
            try add_packed_utf8_range_edges(fsm, from, to, codepoint_to_packed_utf8(low), codepoint_to_packed_utf8(r.high));
        }
    }
}
