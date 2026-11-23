//! Builds the automaton of one grammar expression into a target FSM (the C++
//! `GrammarFSMBuilderImpl` instance) (`expression_fsm_builder.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_mod = @import("../grammar/mod.zig");
const Grammar = grammar_mod.Grammar;
const GrammarBuilder = grammar_mod.GrammarBuilder;
const GrammarExpr = grammar_mod.GrammarExpr;
const GrammarExprType = grammar_mod.GrammarExprType;
const fsm_mod = @import("../fsm/mod.zig");
const Fsm = fsm_mod.Fsm;
const FsmWithStartEnd = fsm_mod.FsmWithStartEnd;
const RegexFsmBuilder = fsm_mod.RegexFsmBuilder;
const SuffixAutomata = fsm_mod.SuffixAutomata;
const grammar_fsm_builder_mod = @import("grammar_fsm_builder.zig");
const GrammarFsmBuilder = grammar_fsm_builder_mod.GrammarFsmBuilder;
const error_mod = @import("error.zig");
const FunctorError = error_mod.FunctorError;
const FunctorErrorInfo = error_mod.FunctorErrorInfo;

/// Adapts a `GrammarBuilder` to the `expr(id)` resolver shape `TagDispatch.decode` expects
/// (Rust passes `|id| exprs.grammar_expr(id)`).
const BuilderExprContext = struct {
    builder: *GrammarBuilder,

    pub fn expr(self: BuilderExprContext, expr_id: i32) GrammarExpr {
        return self.builder.grammar_expr(expr_id);
    }
};

/// Builds expressions into `target_fsm`, reading them through `exprs`. When `create_rules`
/// is set, large bounded regex repetitions become repeat edges to new rules added through
/// `exprs`.
pub const ExpressionFsmBuilder = struct {
    allocator: Allocator,
    target_fsm: Fsm,
    exprs: *GrammarBuilder,
    rule_name: ?[]const u8,
    create_rules: bool,

    /// Builds the automaton of the expression `expr_id` (simplified and minimized unless it
    /// is a tag dispatch, whose shape the parser relies on).
    ///
    /// The caller owns the result (`deinit`). `diag` optionally receives the `FsmBuild`
    /// failure message.
    pub fn build_expression_fsm(
        allocator: Allocator,
        exprs: *GrammarBuilder,
        expr_id: i32,
        rule_name: ?[]const u8,
        create_rules: bool,
        diag: ?*FunctorErrorInfo,
    ) FunctorError!FsmWithStartEnd {
        const ty = exprs.grammar_expr(expr_id).ty;
        var result = try build(allocator, exprs, expr_id, rule_name, create_rules, diag);
        errdefer result.deinit();
        if (ty == .TagDispatch or ty == .TokenTagDispatch) return result;
        var simplified = try result.simplify_epsilon(allocator);
        result.deinit();
        const minimized = try simplified.merge_equivalent_states(allocator);
        simplified.deinit();
        return minimized;
    }

    /// Builds the automaton of the expression `expr_id` as constructed, without simplifying it.
    pub fn build(
        allocator: Allocator,
        exprs: *GrammarBuilder,
        expr_id: i32,
        rule_name: ?[]const u8,
        create_rules: bool,
        diag: ?*FunctorErrorInfo,
    ) FunctorError!FsmWithStartEnd {
        var builder = ExpressionFsmBuilder{
            .allocator = allocator,
            .target_fsm = try Fsm.new(allocator, 1),
            .exprs = exprs,
            .rule_name = rule_name,
            .create_rules = create_rules,
        };
        errdefer builder.target_fsm.deinit();
        var ends = try builder.build_expression(expr_id, 0, diag);
        defer ends.deinit(allocator);
        var ends_list: std.ArrayList(i32) = .empty;
        errdefer ends_list.deinit(allocator);
        try ends_list.appendSlice(allocator, ends.items);
        const result = try FsmWithStartEnd.new(allocator, builder.target_fsm, 0, ends_list, false);
        builder.target_fsm = try Fsm.empty(allocator); // moved into the result
        return result;
    }

    /// Builds the expression from `start`, returning its end states (an owned list).
    fn build_expression(
        self: *ExpressionFsmBuilder,
        expr_id: i32,
        start: i32,
        diag: ?*FunctorErrorInfo,
    ) FunctorError!std.ArrayList(i32) {
        const gpa = self.allocator;
        const expr = self.exprs.grammar_expr(expr_id);
        const ty = expr.ty;
        const data = try gpa.dupe(i32, expr.data);
        defer gpa.free(data);
        var fsm = &self.target_fsm;
        var ends: std.ArrayList(i32) = .empty;
        errdefer ends.deinit(gpa);
        switch (ty) {
            .EmptyStr => try ends.append(gpa, start),
            .ByteString => try ends.append(gpa, try GrammarFsmBuilder.build_byte_string(fsm, data, start)),
            .CharacterClass => {
                const end = try fsm.add_state();
                GrammarFsmBuilder.add_character_class_transitions(fsm, data, start, end);
                try ends.append(gpa, end);
            },
            .CharacterClassStar => {
                GrammarFsmBuilder.add_character_class_transitions(fsm, data, start, start);
                try ends.append(gpa, start);
            },
            .RuleRef => {
                const end = try fsm.add_state();
                try fsm.add_rule_edge(start, end, data[0]);
                try ends.append(gpa, end);
            },
            .Repeat => {
                const end = try fsm.add_state();
                try fsm.add_repeat_edge(start, end, data[0], data[1], data[2]);
                try ends.append(gpa, end);
            },
            .Token => {
                const end = try fsm.add_state();
                try fsm.add_token_edge(start, end, data);
                try ends.append(gpa, end);
            },
            .ExcludeToken => {
                const end = try fsm.add_state();
                try fsm.add_exclude_token_edge(start, end, data);
                try ends.append(gpa, end);
            },
            .Sequence => {
                var result = try self.build_sequence(data, start, diag);
                defer result.deinit(gpa);
                try ends.appendSlice(gpa, result.items);
            },
            .Choices => {
                var result = try self.build_choices(data, start, diag);
                defer result.deinit(gpa);
                try ends.appendSlice(gpa, result.items);
            },
            .Regex => {
                var built = self.exprs.grammar_expr(expr_id);
                const pattern = try built.regex_pattern(gpa);
                defer gpa.free(pattern);
                const json_string = built.regex_is_json_string();
                var result = try self.build_regex(pattern, json_string, start, diag);
                defer result.deinit(gpa);
                try ends.appendSlice(gpa, result.items);
            },
            .Substring => {
                var built = self.exprs.grammar_expr(expr_id);
                const chunks = try built.substring_chunks(gpa);
                defer {
                    for (chunks) |c| gpa.free(c);
                    gpa.free(chunks);
                }
                var suffix_fsm = try SuffixAutomata.build(gpa, chunks);
                defer suffix_fsm.deinit();
                var mapped = try self.append_fsm(suffix_fsm, start);
                defer mapped.deinit(gpa);
                try ends.appendSlice(gpa, mapped.items);
            },
            .TagDispatch => {
                var tag_dispatch = try grammar_mod.tag_dispatch.TagDispatch.decode(
                    gpa,
                    data,
                    BuilderExprContext{ .builder = self.exprs },
                );
                defer tag_dispatch.deinit(gpa);
                var dispatch_fsm = (try GrammarFsmBuilder.tag_dispatch(gpa, &tag_dispatch)) orelse {
                    const message = try gpa.dupe(u8, "Failed to build tag dispatch FSM");
                    error_mod.set_diag(diag, .{ .FsmBuild = message });
                    return error.FsmBuild;
                };
                defer dispatch_fsm.deinit();
                var mapped = try self.append_fsm(dispatch_fsm, start);
                defer mapped.deinit(gpa);
                try ends.appendSlice(gpa, mapped.items);
            },
            .TokenTagDispatch => {
                var ttd = try grammar_mod.token_tag_dispatch.decode_token_tag_dispatch_data(gpa, data);
                defer ttd.deinit(gpa);
                var ttd_ends = try GrammarFsmBuilder.build_token_tag_dispatch(fsm, &ttd, start);
                defer ttd_ends.deinit(gpa);
                try ends.appendSlice(gpa, ttd_ends.items);
            },
        }
        return ends;
    }

    fn build_sequence(
        self: *ExpressionFsmBuilder,
        elements: []const i32,
        start: i32,
        diag: ?*FunctorErrorInfo,
    ) FunctorError!std.ArrayList(i32) {
        const gpa = self.allocator;
        var end_states: std.ArrayList(i32) = .empty;
        errdefer end_states.deinit(gpa);
        if (elements.len == 0) {
            try end_states.append(gpa, start);
            return end_states;
        }
        var first_ends = try self.build_expression(elements[0], start, diag);
        defer first_ends.deinit(gpa);
        try end_states.appendSlice(gpa, first_ends.items);
        for (elements[1..]) |element| {
            const element_start = try self.target_fsm.add_state();
            var next_end_states = try self.build_expression(element, element_start, diag);
            defer next_end_states.deinit(gpa);
            for (end_states.items) |previous_end| {
                try self.target_fsm.add_epsilon_edge(previous_end, element_start);
            }
            end_states.clearRetainingCapacity();
            try end_states.appendSlice(gpa, next_end_states.items);
        }
        return end_states;
    }

    fn build_choices(
        self: *ExpressionFsmBuilder,
        choices: []const i32,
        start: i32,
        diag: ?*FunctorErrorInfo,
    ) FunctorError!std.ArrayList(i32) {
        const gpa = self.allocator;
        var nullable = false;
        for (choices) |choice| {
            if (self.exprs.grammar_expr(choice).ty == .EmptyStr) nullable = true;
        }
        var non_empty: std.ArrayList(i32) = .empty;
        defer non_empty.deinit(gpa);
        for (choices) |choice| {
            if (self.exprs.grammar_expr(choice).ty != .EmptyStr) try non_empty.append(gpa, choice);
        }
        var end_states: std.ArrayList(i32) = .empty;
        errdefer end_states.deinit(gpa);
        if (non_empty.items.len == 0) {
            try end_states.append(gpa, start);
            return end_states;
        }
        if (non_empty.items.len == 1 and !nullable) {
            var single = try self.build_expression(non_empty.items[0], start, diag);
            defer single.deinit(gpa);
            try end_states.appendSlice(gpa, single.items);
            return end_states;
        }
        for (non_empty.items) |choice| {
            const branch_start = try self.target_fsm.add_state();
            var branch_end_states = try self.build_expression(choice, branch_start, diag);
            defer branch_end_states.deinit(gpa);
            try self.target_fsm.add_epsilon_edge(start, branch_start);
            try end_states.appendSlice(gpa, branch_end_states.items);
        }
        if (nullable) {
            const nullable_branch = try self.target_fsm.add_state();
            try self.target_fsm.add_epsilon_edge(start, nullable_branch);
            try end_states.append(gpa, nullable_branch);
        }
        return end_states;
    }

    fn build_regex(
        self: *ExpressionFsmBuilder,
        pattern: []const u8,
        json_string: bool,
        start: i32,
        diag: ?*FunctorErrorInfo,
    ) FunctorError!std.ArrayList(i32) {
        const gpa = self.allocator;
        const rule_hint = self.rule_name orelse "";
        const builder: ?*GrammarBuilder = if (self.create_rules) self.exprs else null;
        var err_msg: ?[]u8 = null;
        defer if (err_msg) |m| gpa.free(m);
        const result = if (json_string)
            RegexFsmBuilder.build_with_forbidden_chars(gpa, pattern, GrammarFsmBuilder.json_string_forbidden_chars(), builder, rule_hint, &err_msg)
        else
            RegexFsmBuilder.build(gpa, pattern, builder, rule_hint, &err_msg);
        var fsm = result catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                const regex = pattern;
                if (self.rule_name) |rule_name| {
                    error_mod.set_diag(diag, .{ .FsmBuild = try std.fmt.allocPrint(
                        gpa,
                        "Failed to build the automaton for rule {s} with regex {s}: {s}",
                        .{ rule_name, regex, err_msg orelse @errorName(err) },
                    ) });
                } else {
                    error_mod.set_diag(diag, .{ .FsmBuild = try std.fmt.allocPrint(
                        gpa,
                        "Failed to build the automaton for regex {s}: {s}",
                        .{ regex, err_msg orelse @errorName(err) },
                    ) });
                }
                return error.FsmBuild;
            },
        };
        defer fsm.deinit();
        return self.append_fsm(fsm, start);
    }

    /// Appends `fsm` after `start`, returning the mapped end states. An untouched one-state
    /// target is replaced by `fsm` directly.
    fn append_fsm(self: *ExpressionFsmBuilder, fsm: FsmWithStartEnd, start: i32) FunctorError!std.ArrayList(i32) {
        const gpa = self.allocator;
        var ends: std.ArrayList(i32) = .empty;
        errdefer ends.deinit(gpa);
        const target = &self.target_fsm;
        const target_is_empty = target.num_states() == 1 and start == 0 and
            target.state_edges(0).len == 0 and target.edge_aux_data_slice().len == 0 and
            fsm.get_start() == 0;
        if (target_is_empty) {
            try ends.appendSlice(gpa, fsm.get_ends());
            const cloned = try fsm.get_fsm().clone(gpa);
            target.deinit();
            target.* = cloned;
            return ends;
        }
        const offset = try target.add_fsm(fsm.get_fsm());
        try target.add_epsilon_edge(start, offset + fsm.get_start());
        for (fsm.get_ends()) |end| {
            try ends.append(gpa, offset + end);
        }
        return ends;
    }
};
