//! Lowers the regular subset of grammars (e.g. from `RegexToEBNF`) into one automaton
//! without changing terminal semantics (`regular_grammar_fsm_builder.rs`).
//!
//! A shared callee entry/exit would let one call return to another call's continuation.
//! Each finite call is inlined instead, and only direct tail self-references connect to
//! that call's own entry. The entry is private even when the caller's start also has an
//! optional exit.

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_mod = @import("../grammar/mod.zig");
const Grammar = grammar_mod.Grammar;
const GrammarExpr = grammar_mod.GrammarExpr;
const GrammarExprType = grammar_mod.GrammarExprType;
const fsm_mod = @import("../fsm/mod.zig");
const Fsm = fsm_mod.Fsm;
const FsmWithStartEnd = fsm_mod.FsmWithStartEnd;
const grammar_fsm_builder_mod = @import("grammar_fsm_builder.zig");
const GrammarFsmBuilder = grammar_fsm_builder_mod.GrammarFsmBuilder;
const NO_EXPR = grammar_mod.NO_EXPR;

/// The deepest chain of inlined rule calls.
const MAX_RULE_CALL_DEPTH: usize = 256;

/// Flattens a regular grammar into one FSM of bounded size (the C++
/// `RegularGrammarFSMBuilder`). The caller owns the result. On error, `err_msg.*` receives
/// why the grammar is not a plain regular grammar or exceeds the state limit (allocated
/// from `allocator`; the caller frees it).
pub fn build(
    allocator: Allocator,
    grammar: *const Grammar,
    max_num_states: i32,
    err_msg: ?*?[]u8,
) (Allocator.Error || error{Flatten})!FsmWithStartEnd {
    if (max_num_states < 2) {
        set_msg_z(allocator, err_msg, "Regular grammar FSM state limit must be at least 2") catch return error.Flatten;
        return error.Flatten;
    }
    var builder = Builder{
        .allocator = allocator,
        .grammar = grammar,
        .max_num_states = max_num_states,
        .fsm = try Fsm.new(allocator, 2),
        .active = try allocator.alloc(bool, @intCast(grammar.num_rules())),
        .depth = 0,
    };
    defer builder.deinit_temps();
    @memset(builder.active, false);
    builder.build_rule(grammar.root_rule_id, 0, 1, err_msg) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Flatten => return error.Flatten,
    };
    var ends: std.ArrayList(i32) = .empty;
    errdefer ends.deinit(allocator);
    try ends.append(allocator, 1);
    var result = try FsmWithStartEnd.new(allocator, builder.fsm, 0, ends, false);
    builder.fsm = try Fsm.empty(allocator); // moved into the result
    defer result.deinit();
    var simplified = try result.simplify_epsilon(allocator);
    defer simplified.deinit();
    return simplified.merge_equivalent_states(allocator);
}

fn set_msg(allocator: Allocator, err_msg: ?*?[]u8, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    if (err_msg) |slot| slot.* = try std.fmt.allocPrint(allocator, fmt, args);
}

fn set_msg_z(allocator: Allocator, err_msg: ?*?[]u8, message: []const u8) Allocator.Error!void {
    if (err_msg) |slot| slot.* = try allocator.dupe(u8, message);
}

const Builder = struct {
    allocator: Allocator,
    grammar: *const Grammar,
    max_num_states: i32,
    fsm: Fsm,
    active: []bool,
    depth: usize,

    fn deinit_temps(self: *Builder) void {
        self.fsm.deinit();
        self.allocator.free(self.active);
    }

    fn state_limit_error(self: *Builder, err_msg: ?*?[]u8) error{ Flatten, OutOfMemory }!noreturn {
        set_msg(self.allocator, err_msg, "intermediate FSM exceeds {d} states", .{self.max_num_states}) catch return error.OutOfMemory;
        return error.Flatten;
    }

    fn add_state(self: *Builder, err_msg: ?*?[]u8) error{ Flatten, OutOfMemory }!i32 {
        if (self.fsm.num_states() >= self.max_num_states) {
            try self.state_limit_error(err_msg);
        }
        return self.fsm.add_state();
    }

    fn append(self: *Builder, leaf: *const FsmWithStartEnd, start: i32, end: i32, err_msg: ?*?[]u8) error{ Flatten, OutOfMemory }!void {
        if (leaf.get_fsm().num_states() > self.max_num_states - self.fsm.num_states()) {
            try self.state_limit_error(err_msg);
        }
        const offset = try self.fsm.add_fsm(leaf.get_fsm());
        try self.fsm.add_epsilon_edge(start, offset + leaf.get_start());
        for (leaf.get_ends()) |leaf_end| {
            try self.fsm.add_epsilon_edge(offset + leaf_end, end);
        }
    }

    fn build_rule(self: *Builder, rule_id: i32, start: i32, end: i32, err_msg: ?*?[]u8) error{ Flatten, OutOfMemory }!void {
        const grammar = self.grammar;
        const rule = grammar.rule(rule_id);
        if (self.active[@intCast(rule_id)]) {
            set_msg(self.allocator, err_msg, "Cannot flatten regular grammar: mutual or non-tail recursion involving rule {s}", .{rule.name}) catch return error.OutOfMemory;
            return error.Flatten;
        }
        if (self.depth >= MAX_RULE_CALL_DEPTH) {
            set_msg(self.allocator, err_msg, "Cannot flatten regular grammar: rule call depth exceeds {d}", .{MAX_RULE_CALL_DEPTH}) catch return error.OutOfMemory;
            return error.Flatten;
        }
        if (rule.lookahead_assertion_id >= 0 or rule.max_tokens >= 0 or rule.max_chars >= 0 or
            rule.capture_name.len != 0 or rule.is_lazy or rule.temperature != null or
            grammar.suffix_stop_info(rule_id) != null)
        {
            set_msg(self.allocator, err_msg, "Cannot flatten regular grammar: annotated rule {s} is not a plain regular rule", .{rule.name}) catch return error.OutOfMemory;
            return error.Flatten;
        }
        const entry = try self.add_state(err_msg);
        try self.fsm.add_epsilon_edge(start, entry);
        self.active[@intCast(rule_id)] = true;
        self.depth += 1;
        defer self.depth -= 1;
        defer self.active[@intCast(rule_id)] = false;
        return self.build_expression(grammar.expr(rule.body_expr_id), entry, end, rule_id, entry, true, err_msg);
    }

    fn build_expression(
        self: *Builder,
        expr: GrammarExpr,
        start: i32,
        end: i32,
        rule_id: i32,
        rule_start: i32,
        tail: bool,
        err_msg: ?*?[]u8,
    ) error{ Flatten, OutOfMemory }!void {
        const grammar = self.grammar;
        switch (expr.ty) {
            .EmptyStr => try self.fsm.add_epsilon_edge(start, end),
            .ByteString => {
                if (expr.data.len >= @as(usize, @intCast(self.max_num_states - self.fsm.num_states()))) {
                    set_msg_z(self.allocator, err_msg, "Cannot flatten regular grammar: byte string exceeds the intermediate FSM state limit") catch return error.OutOfMemory;
                    return error.Flatten;
                }
                var leaf = try GrammarFsmBuilder.byte_string(self.allocator, expr);
                defer leaf.deinit();
                try self.append(&leaf, start, end, err_msg);
            },
            .CharacterClass, .CharacterClassStar => {
                var leaf = try GrammarFsmBuilder.character_class(self.allocator, expr);
                defer leaf.deinit();
                try self.append(&leaf, start, end, err_msg);
            },
            .RuleRef => {
                if (expr.data[0] == rule_id) {
                    if (!tail) {
                        set_msg(self.allocator, err_msg, "Cannot flatten regular grammar: non-tail self-recursion in rule {s}", .{grammar.rule(rule_id).name}) catch return error.OutOfMemory;
                        return error.Flatten;
                    }
                    try self.fsm.add_epsilon_edge(start, rule_start);
                } else {
                    try self.build_rule(expr.data[0], start, end, err_msg);
                }
            },
            .Choices => {
                for (expr.data) |choice| {
                    try self.build_expression(grammar.expr(choice), start, end, rule_id, rule_start, tail, err_msg);
                }
            },
            .Sequence => {
                if (expr.data.len == 0) {
                    try self.fsm.add_epsilon_edge(start, end);
                }
                var current = start;
                for (expr.data, 0..) |element, index| {
                    const is_last = index + 1 == expr.data.len;
                    const next = if (is_last) end else try self.add_state(err_msg);
                    try self.build_expression(grammar.expr(element), current, next, rule_id, rule_start, tail and is_last, err_msg);
                    current = next;
                }
            },
            .Repeat => {
                const repeat = expr.repeat();
                const lower: i64 = repeat.min_repeat;
                const upper: i64 = repeat.max_repeat;
                const callee = repeat.rule_id;
                if (lower < 0 or (upper != -1 and upper < lower)) {
                    set_msg_z(self.allocator, err_msg, "Cannot flatten regular grammar: invalid repetition bounds") catch return error.OutOfMemory;
                    return error.Flatten;
                }
                // Even empty callees must not make an enormous explicit repetition consume
                // unbounded compilation time.
                const count: i64 = if (upper == -1) lower else upper;
                if (count > self.max_num_states) {
                    set_msg_z(self.allocator, err_msg, "Cannot flatten regular grammar: repetition exceeds the intermediate FSM state limit") catch return error.OutOfMemory;
                    return error.Flatten;
                }
                var current = start;
                var index: i64 = 0;
                while (index <= count) : (index += 1) {
                    if (index >= lower) {
                        try self.fsm.add_epsilon_edge(current, end);
                    }
                    if (index == count) break;
                    const next = try self.add_state(err_msg);
                    try self.build_rule(callee, current, next, err_msg);
                    current = next;
                }
                if (upper == -1) {
                    try self.build_rule(callee, current, current, err_msg);
                }
            },
            else => {
                set_msg(self.allocator, err_msg, "Cannot flatten regular grammar: unsupported terminal or expression in rule {s}", .{grammar.rule(rule_id).name}) catch return error.OutOfMemory;
                return error.Flatten;
            },
        }
    }
};
