//! Finite-state-machine builders for grammar expressions (`ExpressionFsmBuilder`),
//! regular grammars (`RegularGrammarFsmBuilder`), and full grammars (`GrammarFsmBuilder`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const Diagnostic = @import("../Diagnostic.zig").Diagnostic;
const fsm_mod = @import("../fsm.zig");
const CompactFsm = fsm_mod.CompactFsm;
const CompactFsmWithStartEnd = fsm_mod.CompactFsmWithStartEnd;
const CompactFsmWithStartEndWithSize = fsm_mod.CompactFsmWithStartEndWithSize;
const Fsm = fsm_mod.Fsm;
const FsmSliceMeta = fsm_mod.FsmSliceMeta;
const FsmWithStartEnd = fsm_mod.FsmWithStartEnd;
const RegexError = fsm_mod.RegexError;
const RegexFsmBuilder = fsm_mod.RegexFsmBuilder;
const SuffixAutomata = fsm_mod.SuffixAutomata;
const TrieFsmBuilder = fsm_mod.TrieFsmBuilder;
const addPackedUtf8RangeEdges = fsm_mod.addPackedUtf8RangeEdges;
const codepointToPackedUtf8 = fsm_mod.codepointToPackedUtf8;
const grammar_mod = @import("../grammar.zig");
const Grammar = grammar_mod.Grammar;
const GrammarBuilder = grammar_mod.GrammarBuilder;
const GrammarExpr = grammar_mod.GrammarExpr;
const TagDispatch = grammar_mod.TagDispatch;
const TokenTagDispatch = grammar_mod.TokenTagDispatch;
const dispatch = grammar_mod.dispatch;
const mutator = @import("mutator.zig");
const FunctorError = mutator.FunctorError;

const MAX_CODEPOINT: u32 = 0x10_FFFF;

const JSON_FORBIDDEN_CHARS: [256]bool = blk: {
    var table: [256]bool = @splat(false);
    for (0..0x20) |i| table[i] = true;
    table['"'] = true;
    table['\\'] = true;
    break :blk table;
};

// ---------------------------------------------------------------------------
// 1. ExpressionFsmBuilder
// ---------------------------------------------------------------------------

const BuilderExprContext = struct {
    builder: *GrammarBuilder,

    pub fn expr(self: BuilderExprContext, expr_id: i32) GrammarExpr {
        return self.builder.grammarExpr(expr_id);
    }
};

/// Builds expressions into `target_fsm`, reading them through `exprs`.
/// When `create_rules` is set, large bounded regex repetitions add helper rules via `exprs`.
pub const ExpressionFsmBuilder = struct {
    allocator: Allocator,
    target_fsm: Fsm,
    exprs: *GrammarBuilder,
    rule_name: ?[]const u8,
    create_rules: bool,

    /// Builds the automaton of `expr_id`, simplified and minimized unless it is a tag dispatch.
    pub fn buildExpressionFsm(
        allocator: Allocator,
        exprs: *GrammarBuilder,
        expr_id: i32,
        rule_name: ?[]const u8,
        create_rules: bool,
        diag: ?*Diagnostic,
    ) FunctorError!FsmWithStartEnd {
        const ty = exprs.grammarExpr(expr_id).ty;
        var result = try build(allocator, exprs, expr_id, rule_name, create_rules, diag);
        if (ty == .TagDispatch or ty == .TokenTagDispatch) return result;
        var simplified = blk: {
            defer result.deinit();
            break :blk try result.simplifyEpsilon(allocator);
        };
        defer simplified.deinit();
        return simplified.mergeEquivalentStates(allocator);
    }

    /// Builds the automaton of `expr_id` as constructed, without simplification.
    pub fn build(
        allocator: Allocator,
        exprs: *GrammarBuilder,
        expr_id: i32,
        rule_name: ?[]const u8,
        create_rules: bool,
        diag: ?*Diagnostic,
    ) FunctorError!FsmWithStartEnd {
        var builder = ExpressionFsmBuilder{
            .allocator = allocator,
            .target_fsm = try Fsm.init(allocator, 1),
            .exprs = exprs,
            .rule_name = rule_name,
            .create_rules = create_rules,
        };
        errdefer builder.target_fsm.deinit();

        var ends = try builder.buildExpression(expr_id, 0, diag);
        errdefer ends.deinit(allocator);
        const empty_fsm = try Fsm.empty(allocator);
        const result = FsmWithStartEnd.init(allocator, builder.target_fsm, 0, ends, false);
        builder.target_fsm = empty_fsm;
        return result;
    }

    fn buildExpression(
        self: *ExpressionFsmBuilder,
        expr_id: i32,
        start: i32,
        diag: ?*Diagnostic,
    ) FunctorError!std.ArrayList(i32) {
        const gpa = self.allocator;
        const e = self.exprs.grammarExpr(expr_id);
        const ty = e.ty;
        const data = try gpa.dupe(i32, e.data);
        defer gpa.free(data);
        var fsm = &self.target_fsm;
        var ends: std.ArrayList(i32) = .empty;
        errdefer ends.deinit(gpa);

        switch (ty) {
            .EmptyStr => try ends.append(gpa, start),
            .ByteString => try ends.append(gpa, try GrammarFsmBuilder.buildByteString(fsm, data, start)),
            .CharacterClass => {
                const end = try fsm.addState();
                try GrammarFsmBuilder.addCharacterClassTransitions(fsm, data, start, end);
                try ends.append(gpa, end);
            },
            .CharacterClassStar => {
                try GrammarFsmBuilder.addCharacterClassTransitions(fsm, data, start, start);
                try ends.append(gpa, start);
            },
            .RuleRef => {
                const end = try fsm.addState();
                try fsm.addRuleEdge(start, end, data[0]);
                try ends.append(gpa, end);
            },
            .Repeat => {
                const end = try fsm.addState();
                try fsm.addRepeatEdge(start, end, data[0], data[1], data[2]);
                try ends.append(gpa, end);
            },
            .Token => {
                const end = try fsm.addState();
                try fsm.addTokenEdge(start, end, data);
                try ends.append(gpa, end);
            },
            .ExcludeToken => {
                const end = try fsm.addState();
                try fsm.addExcludeTokenEdge(start, end, data);
                try ends.append(gpa, end);
            },
            .Sequence => {
                var result = try self.buildSequence(data, start, diag);
                defer result.deinit(gpa);
                try ends.appendSlice(gpa, result.items);
            },
            .Choices => {
                var result = try self.buildChoices(data, start, diag);
                defer result.deinit(gpa);
                try ends.appendSlice(gpa, result.items);
            },
            .Regex => {
                const built = self.exprs.grammarExpr(expr_id);
                const pattern = try built.regexPattern(gpa);
                defer gpa.free(pattern);
                const json_string = built.regexIsJsonString();
                var result = try self.buildRegex(pattern, json_string, start, diag);
                defer result.deinit(gpa);
                try ends.appendSlice(gpa, result.items);
            },
            .Substring => {
                const built = self.exprs.grammarExpr(expr_id);
                const chunks = try built.substringChunks(gpa);
                defer {
                    for (chunks) |c| gpa.free(c);
                    gpa.free(chunks);
                }
                var suffix_fsm = try SuffixAutomata.build(gpa, chunks);
                defer suffix_fsm.deinit();
                var mapped = try self.appendFsm(&suffix_fsm, start);
                defer mapped.deinit(gpa);
                try ends.appendSlice(gpa, mapped.items);
            },
            .TagDispatch => {
                var tag_dispatch = try TagDispatch.decode(
                    gpa,
                    data,
                    BuilderExprContext{ .builder = self.exprs },
                );
                defer tag_dispatch.deinit(gpa);
                var dispatch_fsm = (try GrammarFsmBuilder.tagDispatch(gpa, &tag_dispatch)) orelse {
                    if (diag) |d| d.setStatic(.message, "Failed to build tag dispatch FSM");
                    return error.FsmBuild;
                };
                defer dispatch_fsm.deinit();
                var mapped = try self.appendFsm(&dispatch_fsm, start);
                defer mapped.deinit(gpa);
                try ends.appendSlice(gpa, mapped.items);
            },
            .TokenTagDispatch => {
                var ttd = try dispatch.decodeTokenTagDispatchData(gpa, data);
                defer ttd.deinit(gpa);
                var ttd_ends = try GrammarFsmBuilder.buildTokenTagDispatch(fsm, &ttd, start);
                defer ttd_ends.deinit(gpa);
                try ends.appendSlice(gpa, ttd_ends.items);
            },
        }
        return ends;
    }

    fn buildSequence(
        self: *ExpressionFsmBuilder,
        elements: []const i32,
        start: i32,
        diag: ?*Diagnostic,
    ) FunctorError!std.ArrayList(i32) {
        const gpa = self.allocator;
        var end_states: std.ArrayList(i32) = .empty;
        errdefer end_states.deinit(gpa);
        if (elements.len == 0) {
            try end_states.append(gpa, start);
            return end_states;
        }
        var first_ends = try self.buildExpression(elements[0], start, diag);
        defer first_ends.deinit(gpa);
        try end_states.appendSlice(gpa, first_ends.items);
        for (elements[1..]) |element| {
            const element_start = try self.target_fsm.addState();
            var next_end_states = try self.buildExpression(element, element_start, diag);
            defer next_end_states.deinit(gpa);
            for (end_states.items) |previous_end| {
                try self.target_fsm.addEpsilonEdge(previous_end, element_start);
            }
            end_states.clearRetainingCapacity();
            try end_states.appendSlice(gpa, next_end_states.items);
        }
        return end_states;
    }

    fn buildChoices(
        self: *ExpressionFsmBuilder,
        choices: []const i32,
        start: i32,
        diag: ?*Diagnostic,
    ) FunctorError!std.ArrayList(i32) {
        const gpa = self.allocator;
        var nullable = false;
        var non_empty: std.ArrayList(i32) = .empty;
        defer non_empty.deinit(gpa);
        for (choices) |choice| {
            if (self.exprs.grammarExpr(choice).ty == .EmptyStr) {
                nullable = true;
            } else {
                try non_empty.append(gpa, choice);
            }
        }
        var end_states: std.ArrayList(i32) = .empty;
        errdefer end_states.deinit(gpa);
        if (non_empty.items.len == 0) {
            try end_states.append(gpa, start);
            return end_states;
        }
        if (non_empty.items.len == 1 and !nullable) {
            var single = try self.buildExpression(non_empty.items[0], start, diag);
            defer single.deinit(gpa);
            try end_states.appendSlice(gpa, single.items);
            return end_states;
        }
        for (non_empty.items) |choice| {
            const branch_start = try self.target_fsm.addState();
            var branch_end_states = try self.buildExpression(choice, branch_start, diag);
            defer branch_end_states.deinit(gpa);
            try self.target_fsm.addEpsilonEdge(start, branch_start);
            try end_states.appendSlice(gpa, branch_end_states.items);
        }
        if (nullable) {
            const nullable_branch = try self.target_fsm.addState();
            try self.target_fsm.addEpsilonEdge(start, nullable_branch);
            try end_states.append(gpa, nullable_branch);
        }
        return end_states;
    }

    fn buildRegex(
        self: *ExpressionFsmBuilder,
        pattern: []const u8,
        json_string: bool,
        start: i32,
        diag: ?*Diagnostic,
    ) FunctorError!std.ArrayList(i32) {
        const gpa = self.allocator;
        const rule_hint = self.rule_name orelse "";
        const builder: ?*GrammarBuilder = if (self.create_rules) self.exprs else null;
        var regex_diag: Diagnostic = .{};
        defer regex_diag.deinit(gpa);
        const regex_diag_ptr: ?*Diagnostic = if (diag != null) &regex_diag else null;
        const result = if (json_string)
            RegexFsmBuilder.buildWithForbiddenChars(
                gpa,
                pattern,
                GrammarFsmBuilder.jsonStringForbiddenChars(),
                builder,
                rule_hint,
                regex_diag_ptr,
            )
        else
            RegexFsmBuilder.build(gpa, pattern, builder, rule_hint, regex_diag_ptr);
        var fsm = result catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                if (diag) |d| {
                    const detail = if (regex_diag.kind != .none)
                        try regex_diag.formatAlloc(gpa)
                    else
                        null;
                    defer if (detail) |m| gpa.free(m);
                    const msg = detail orelse @errorName(err);
                    if (self.rule_name) |rule_name| {
                        try d.setFmt(
                            gpa,
                            .message,
                            "Failed to build the automaton for rule {s} with regex {s}: {s}",
                            .{ rule_name, pattern, msg },
                        );
                    } else {
                        try d.setFmt(
                            gpa,
                            .message,
                            "Failed to build the automaton for regex {s}: {s}",
                            .{ pattern, msg },
                        );
                    }
                }
                return error.FsmBuild;
            },
        };
        defer fsm.deinit();
        return self.appendFsm(&fsm, start);
    }

    fn appendFsm(self: *ExpressionFsmBuilder, fsm: *const FsmWithStartEnd, start: i32) FunctorError!std.ArrayList(i32) {
        const gpa = self.allocator;
        var ends: std.ArrayList(i32) = .empty;
        errdefer ends.deinit(gpa);
        const target = &self.target_fsm;
        const target_is_empty = target.numStates() == 1 and start == 0 and
            target.stateEdges(0).len == 0 and target.edgeAuxDataSlice().len == 0 and
            fsm.startState() == 0;
        if (target_is_empty) {
            try ends.appendSlice(gpa, fsm.endsSlice());
            const cloned = try fsm.getFsm().dupe(gpa);
            target.deinit();
            target.* = cloned;
            return ends;
        }
        const offset = try target.addFsm(fsm.getFsm());
        try target.addEpsilonEdge(start, offset + fsm.startState());
        for (fsm.endsSlice()) |end| {
            try ends.append(gpa, offset + end);
        }
        return ends;
    }
};

// ---------------------------------------------------------------------------
// 2. RegularGrammarFsmBuilder
// ---------------------------------------------------------------------------

/// Flattens a regular grammar (no non-tail recursion, no rule annotations) into one FSM
/// bounded by `max_num_states`.
pub const RegularGrammarFsmBuilder = struct {
    const MAX_RULE_CALL_DEPTH: usize = 256;

    pub fn build(
        allocator: Allocator,
        grammar: *const Grammar,
        max_num_states: i32,
        diag: ?*Diagnostic,
    ) (Allocator.Error || error{Flatten})!FsmWithStartEnd {
        if (max_num_states < 2) {
            if (diag) |d| d.setStatic(.message, "Regular grammar FSM state limit must be at least 2");
            return error.Flatten;
        }
        var builder = FlattenState{
            .allocator = allocator,
            .grammar = grammar,
            .max_num_states = max_num_states,
            .fsm = try Fsm.init(allocator, 2),
            .active = try allocator.alloc(bool, grammar.numRules()),
            .depth = 0,
        };
        defer builder.deinitTemps();
        @memset(builder.active, false);

        try builder.buildRule(grammar.rootRuleId(), 0, 1, diag);

        var ends: std.ArrayList(i32) = .empty;
        errdefer ends.deinit(allocator);
        try ends.append(allocator, 1);
        const empty_fsm = try Fsm.empty(allocator);
        var result = FsmWithStartEnd.init(allocator, builder.fsm, 0, ends, false);
        builder.fsm = empty_fsm;
        defer result.deinit();
        var simplified = try result.simplifyEpsilon(allocator);
        defer simplified.deinit();
        return simplified.mergeEquivalentStates(allocator);
    }

    const FlattenState = struct {
        allocator: Allocator,
        grammar: *const Grammar,
        max_num_states: i32,
        fsm: Fsm,
        active: []bool,
        depth: usize,

        fn deinitTemps(self: *FlattenState) void {
            self.fsm.deinit();
            self.allocator.free(self.active);
        }

        fn stateLimitError(self: *FlattenState, diag: ?*Diagnostic) error{ Flatten, OutOfMemory }!noreturn {
            if (diag) |d| try d.setFmt(self.allocator, .message, "intermediate FSM exceeds {d} states", .{self.max_num_states});
            return error.Flatten;
        }

        fn addState(self: *FlattenState, diag: ?*Diagnostic) error{ Flatten, OutOfMemory }!i32 {
            if (self.fsm.numStates() >= self.max_num_states) {
                try self.stateLimitError(diag);
            }
            return self.fsm.addState();
        }

        fn append(self: *FlattenState, leaf: *const FsmWithStartEnd, start: i32, end: i32, diag: ?*Diagnostic) error{ Flatten, OutOfMemory }!void {
            if (leaf.getFsm().numStates() > self.max_num_states - self.fsm.numStates()) {
                try self.stateLimitError(diag);
            }
            const offset = try self.fsm.addFsm(leaf.getFsm());
            try self.fsm.addEpsilonEdge(start, offset + leaf.startState());
            for (leaf.endsSlice()) |leaf_end| {
                try self.fsm.addEpsilonEdge(offset + leaf_end, end);
            }
        }

        fn buildRule(self: *FlattenState, rule_id: i32, start: i32, end: i32, diag: ?*Diagnostic) error{ Flatten, OutOfMemory }!void {
            const grammar = self.grammar;
            const r = grammar.rule(rule_id);
            if (self.active[@intCast(rule_id)]) {
                if (diag) |d| try d.setFmt(self.allocator, .message, "Cannot flatten regular grammar: mutual or non-tail recursion involving rule {s}", .{r.name});
                return error.Flatten;
            }
            if (self.depth >= MAX_RULE_CALL_DEPTH) {
                if (diag) |d| try d.setFmt(self.allocator, .message, "Cannot flatten regular grammar: rule call depth exceeds {d}", .{MAX_RULE_CALL_DEPTH});
                return error.Flatten;
            }
            if (r.lookahead_assertion_id >= 0 or r.max_tokens >= 0 or r.max_chars >= 0 or
                r.capture_name.len != 0 or r.is_lazy or r.temperature != null or
                grammar.suffixStopInfo(rule_id) != null)
            {
                if (diag) |d| try d.setFmt(self.allocator, .message, "Cannot flatten regular grammar: annotated rule {s} is not a plain regular rule", .{r.name});
                return error.Flatten;
            }
            const entry = try self.addState(diag);
            try self.fsm.addEpsilonEdge(start, entry);
            self.active[@intCast(rule_id)] = true;
            self.depth += 1;
            defer self.depth -= 1;
            defer self.active[@intCast(rule_id)] = false;
            return self.buildExpression(grammar.expr(r.body_expr_id), entry, end, rule_id, entry, true, diag);
        }

        fn buildExpression(
            self: *FlattenState,
            e: GrammarExpr,
            start: i32,
            end: i32,
            rule_id: i32,
            rule_start: i32,
            tail: bool,
            diag: ?*Diagnostic,
        ) error{ Flatten, OutOfMemory }!void {
            const grammar = self.grammar;
            switch (e.ty) {
                .EmptyStr => try self.fsm.addEpsilonEdge(start, end),
                .ByteString => {
                    if (e.data.len >= @as(usize, @intCast(self.max_num_states - self.fsm.numStates()))) {
                        if (diag) |d| d.setStatic(.message, "Cannot flatten regular grammar: byte string exceeds the intermediate FSM state limit");
                        return error.Flatten;
                    }
                    var leaf = try GrammarFsmBuilder.byteString(self.allocator, e);
                    defer leaf.deinit();
                    try self.append(&leaf, start, end, diag);
                },
                .CharacterClass, .CharacterClassStar => {
                    var leaf = try GrammarFsmBuilder.characterClass(self.allocator, e);
                    defer leaf.deinit();
                    try self.append(&leaf, start, end, diag);
                },
                .RuleRef => {
                    if (e.data[0] == rule_id) {
                        if (!tail) {
                            if (diag) |d| try d.setFmt(self.allocator, .message, "Cannot flatten regular grammar: non-tail self-recursion in rule {s}", .{grammar.rule(rule_id).name});
                            return error.Flatten;
                        }
                        try self.fsm.addEpsilonEdge(start, rule_start);
                    } else {
                        try self.buildRule(e.data[0], start, end, diag);
                    }
                },
                .Choices => {
                    for (e.data) |choice| {
                        try self.buildExpression(grammar.expr(choice), start, end, rule_id, rule_start, tail, diag);
                    }
                },
                .Sequence => {
                    if (e.data.len == 0) {
                        try self.fsm.addEpsilonEdge(start, end);
                    }
                    var current = start;
                    for (e.data, 0..) |element, index| {
                        const is_last = index + 1 == e.data.len;
                        const next = if (is_last) end else try self.addState(diag);
                        try self.buildExpression(grammar.expr(element), current, next, rule_id, rule_start, tail and is_last, diag);
                        current = next;
                    }
                },
                .Repeat => {
                    const rep = e.repeat();
                    const lower: i64 = rep.min_repeat;
                    const upper: i64 = rep.max_repeat;
                    const callee = rep.rule_id;
                    if (lower < 0 or (upper != -1 and upper < lower)) {
                        if (diag) |d| d.setStatic(.message, "Cannot flatten regular grammar: invalid repetition bounds");
                        return error.Flatten;
                    }
                    const count: i64 = if (upper == -1) lower else upper;
                    if (count > self.max_num_states) {
                        if (diag) |d| d.setStatic(.message, "Cannot flatten regular grammar: repetition exceeds the intermediate FSM state limit");
                        return error.Flatten;
                    }
                    var current = start;
                    var index: i64 = 0;
                    while (index <= count) : (index += 1) {
                        if (index >= lower) {
                            try self.fsm.addEpsilonEdge(current, end);
                        }
                        if (index == count) break;
                        const next = try self.addState(diag);
                        try self.buildRule(callee, current, next, diag);
                        current = next;
                    }
                    if (upper == -1) {
                        try self.buildRule(callee, current, current, diag);
                    }
                },
                else => {
                    if (diag) |d| try d.setFmt(self.allocator, .message, "Cannot flatten regular grammar: unsupported terminal or expression in rule {s}", .{grammar.rule(rule_id).name});
                    return error.Flatten;
                },
            }
        }
    };
};

// ---------------------------------------------------------------------------
// 3. GrammarFsmBuilder
// ---------------------------------------------------------------------------

/// Stateless builder of per-expression and full-grammar FSMs.
pub const GrammarFsmBuilder = struct {
    /// Compiles every rule body into an FSM, folding them into a shared `CompactFsm`
    /// installed on `grammar`.
    pub fn apply(allocator: Allocator, grammar: *Grammar, diag: ?*Diagnostic) FunctorError!void {
        const gpa = allocator;
        const num_original_rules = grammar.numRules();
        var complete_fsm = try Fsm.init(gpa, 0);
        defer complete_fsm.deinit();
        var per_rule_fsms: std.ArrayList(FsmSliceMeta) = .empty;
        defer {
            for (per_rule_fsms.items) |*item| item.deinit();
            per_rule_fsms.deinit(gpa);
        }

        {
            var builder = GrammarBuilder.editInPlace(grammar);
            defer builder.deinit();
            var rule_id: i32 = 0;
            while (rule_id < builder.numRules()) : (rule_id += 1) {
                const r = builder.getRule(rule_id);
                var rule_fsm = try ExpressionFsmBuilder.buildExpressionFsm(
                    gpa,
                    &builder,
                    r.body_expr_id,
                    r.name,
                    true,
                    diag,
                );
                defer rule_fsm.deinit();
                try per_rule_fsms.ensureUnusedCapacity(gpa, 1);
                per_rule_fsms.appendAssumeCapacity(try rule_fsm.addToCompleteFsm(&complete_fsm));
            }
            builder.editInPlaceCommit(grammar);
        }

        // Update allow-empty list for any helper rules created while compiling regex repeats.
        var allow_empty: std.ArrayList(i32) = .empty;
        defer allow_empty.deinit(gpa);
        try allow_empty.appendSlice(gpa, grammar.allowEmptyRuleIdsSlice());
        for (num_original_rules..grammar.numRules()) |rule_id| {
            const body = grammar.expr(grammar.rule(@intCast(rule_id)).body_expr_id);
            std.debug.assert(body.ty == .Regex);
            const pattern = try body.regexPattern(gpa);
            defer gpa.free(pattern);
            if (RegexFsmBuilder.matchesEmpty(gpa, pattern, null)) |matches| {
                if (matches) try allow_empty.append(gpa, @intCast(rule_id));
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {},
            }
        }
        try grammar.setAllowEmptyRuleIds(allow_empty.items);

        var compact_complete_fsm = try CompactFsm.fromFsm(gpa, &complete_fsm);
        defer compact_complete_fsm.deinit();

        var compact_per_rule_fsms: std.ArrayList(?CompactFsmWithStartEndWithSize) = .empty;
        defer {
            for (compact_per_rule_fsms.items) |*maybe| {
                if (maybe.*) |*view| view.deinit();
            }
            compact_per_rule_fsms.deinit(gpa);
        }
        try compact_per_rule_fsms.ensureTotalCapacity(gpa, per_rule_fsms.items.len);
        for (per_rule_fsms.items) |slice| {
            var retained = compact_complete_fsm.retain();
            const with_start_end = CompactFsmWithStartEnd.init(
                gpa,
                retained,
                slice.start,
                slice.ends.items,
                false,
            ) catch |err| {
                retained.deinit();
                return err;
            };
            compact_per_rule_fsms.appendAssumeCapacity(CompactFsmWithStartEndWithSize.init(
                with_start_end,
                slice.edge_num,
                slice.node_num,
            ));
        }

        try grammar.setFsms(compact_complete_fsm, compact_per_rule_fsms.items);
    }

    /// Builds the FSM for a `RuleRef` expression.
    pub fn ruleRef(allocator: Allocator, expr: GrammarExpr) Allocator.Error!FsmWithStartEnd {
        var fsm = try Fsm.init(allocator, 2);
        errdefer fsm.deinit();
        try fsm.addRuleEdge(0, 1, expr.data[0]);
        var ends: std.ArrayList(i32) = .empty;
        errdefer ends.deinit(allocator);
        try ends.append(allocator, 1);
        return FsmWithStartEnd.init(allocator, fsm, 0, ends, false);
    }

    /// Builds the FSM for a `ByteString` expression (one transition per byte).
    pub fn byteString(allocator: Allocator, expr: GrammarExpr) Allocator.Error!FsmWithStartEnd {
        std.debug.assert(expr.ty == .ByteString);
        var fsm = try Fsm.init(allocator, 1);
        errdefer fsm.deinit();
        const end = try buildByteString(&fsm, expr.data, 0);
        var ends: std.ArrayList(i32) = .empty;
        errdefer ends.deinit(allocator);
        try ends.append(allocator, end);
        return FsmWithStartEnd.init(allocator, fsm, 0, ends, false);
    }

    /// Builds the FSM for a `CharacterClass` / `CharacterClassStar` expression.
    pub fn characterClass(allocator: Allocator, expr: GrammarExpr) Allocator.Error!FsmWithStartEnd {
        var fsm = try Fsm.init(allocator, 1);
        errdefer fsm.deinit();
        const end: i32 = if (expr.ty == .CharacterClassStar) 0 else try fsm.addState();
        try addCharacterClassTransitions(&fsm, expr.data, 0, end);
        var ends: std.ArrayList(i32) = .empty;
        errdefer ends.deinit(allocator);
        try ends.append(allocator, end);
        return FsmWithStartEnd.init(allocator, fsm, 0, ends, false);
    }

    /// Builds the FSM for a `Token` expression.
    pub fn token(allocator: Allocator, expr: GrammarExpr) Allocator.Error!FsmWithStartEnd {
        std.debug.assert(expr.ty == .Token);
        var fsm = try Fsm.init(allocator, 2);
        errdefer fsm.deinit();
        try fsm.addTokenEdge(0, 1, expr.data);
        var ends: std.ArrayList(i32) = .empty;
        errdefer ends.deinit(allocator);
        try ends.append(allocator, 1);
        return FsmWithStartEnd.init(allocator, fsm, 0, ends, false);
    }

    /// Builds the FSM for an `ExcludeToken` expression.
    pub fn excludeToken(allocator: Allocator, expr: GrammarExpr) Allocator.Error!FsmWithStartEnd {
        std.debug.assert(expr.ty == .ExcludeToken);
        var fsm = try Fsm.init(allocator, 2);
        errdefer fsm.deinit();
        try fsm.addExcludeTokenEdge(0, 1, expr.data);
        var ends: std.ArrayList(i32) = .empty;
        errdefer ends.deinit(allocator);
        try ends.append(allocator, 1);
        return FsmWithStartEnd.init(allocator, fsm, 0, ends, false);
    }

    /// Builds the dispatch FSM for a token tag-dispatch.
    pub fn tokenTagDispatch(allocator: Allocator, ttd: *const TokenTagDispatch) Allocator.Error!FsmWithStartEnd {
        var fsm = try Fsm.init(allocator, 1);
        errdefer fsm.deinit();
        const ends = try buildTokenTagDispatch(&fsm, ttd, 0);
        return FsmWithStartEnd.init(allocator, fsm, 0, ends, false);
    }

    /// Builds the FSM for a `Sequence` expression of `grammar` without simplification.
    pub fn sequence(
        allocator: Allocator,
        expr: GrammarExpr,
        grammar: *const Grammar,
    ) FunctorError!FsmWithStartEnd {
        std.debug.assert(expr.ty == .Sequence);
        var builder = try GrammarBuilder.fromGrammar(grammar, allocator);
        defer builder.deinit();
        const sequence_id = try builder.addSequence(expr.data);
        return ExpressionFsmBuilder.build(allocator, &builder, sequence_id, null, false, null);
    }

    /// Builds the FSM for a `Choices` expression of `grammar`, simplified and minimized.
    pub fn choices(
        allocator: Allocator,
        expr: GrammarExpr,
        grammar: *const Grammar,
    ) FunctorError!FsmWithStartEnd {
        std.debug.assert(expr.ty == .Choices);
        var builder = try GrammarBuilder.fromGrammar(grammar, allocator);
        defer builder.deinit();
        const choices_id = try builder.addChoices(expr.data);
        return ExpressionFsmBuilder.buildExpressionFsm(allocator, &builder, choices_id, null, false, null);
    }

    /// Builds the dispatch FSM for a string tag-dispatch, or `null` if the trie cannot be built.
    pub fn tagDispatch(allocator: Allocator, td: *const TagDispatch) Allocator.Error!?FsmWithStartEnd {
        const gpa = allocator;
        const tag_names = try gpa.alloc([]const u8, td.tag_rule_pairs.items.len);
        defer gpa.free(tag_names);
        for (td.tag_rule_pairs.items, 0..) |pair, i| tag_names[i] = pair.tag;
        const excluded = try gpa.alloc([]const u8, td.excludes.items.len);
        defer gpa.free(excluded);
        for (td.excludes.items, 0..) |e, i| excluded[i] = e;
        var end_states: std.ArrayList(i32) = .empty;
        defer end_states.deinit(gpa);
        const trie = try TrieFsmBuilder.build(gpa, tag_names, excluded, &end_states, true, true);
        var trie_fsm = trie orelse return null;
        defer trie_fsm.deinit();
        const start = trie_fsm.startState();

        var ends: std.ArrayList(i32) = .empty;
        errdefer ends.deinit(gpa);
        for (0..@intCast(trie_fsm.numStates())) |state| {
            if (!trie_fsm.isEndState(@intCast(state))) try ends.append(gpa, @intCast(state));
        }
        for (td.tag_rule_pairs.items, 0..) |pair, i| {
            const next_state = if (td.loop_after_dispatch)
                start
            else blk: {
                const state = try trie_fsm.fsmMut().addState();
                try ends.append(gpa, state);
                break :blk state;
            };
            try trie_fsm.fsmMut().addRuleEdge(end_states.items[i], next_state, pair.rule_id);
        }
        const cloned = try trie_fsm.getFsm().dupe(gpa);
        return FsmWithStartEnd.init(gpa, cloned, start, ends, false);
    }

    /// Compiles a standalone regex into a simplified, minimized automaton.
    pub fn regex(
        allocator: Allocator,
        regex_pattern: []const u8,
        json_string: bool,
        diag: ?*Diagnostic,
    ) RegexError!FsmWithStartEnd {
        const gpa = allocator;
        var built = if (json_string)
            try RegexFsmBuilder.buildWithForbiddenChars(gpa, regex_pattern, jsonStringForbiddenChars(), null, "", diag)
        else
            try RegexFsmBuilder.build(gpa, regex_pattern, null, "", diag);
        defer built.deinit();
        var simplified = try built.simplifyEpsilon(gpa);
        defer simplified.deinit();
        return simplified.mergeEquivalentStates(gpa);
    }

    /// Flattens a regular grammar into one automaton of at most `max_num_states` states.
    pub fn fromRegularGrammar(
        allocator: Allocator,
        grammar: *const Grammar,
        max_num_states: i32,
        diag: ?*Diagnostic,
    ) (Allocator.Error || error{Flatten})!FsmWithStartEnd {
        return RegularGrammarFsmBuilder.build(allocator, grammar, max_num_states, diag);
    }

    /// The characters that must be escaped in a JSON string: control chars, `"` and `\`.
    pub fn jsonStringForbiddenChars() *const [256]bool {
        return &JSON_FORBIDDEN_CHARS;
    }

    /// Adds a chain of byte transitions from `start`, returning the end state.
    pub fn buildByteString(fsm: *Fsm, bytes: []const i32, start: i32) Allocator.Error!i32 {
        var current = start;
        for (bytes) |byte_in| {
            const next = try fsm.addState();
            const byte: i32 = @as(u8, @intCast(byte_in));
            try fsm.addEdge(current, next, byte, byte);
            current = next;
        }
        return current;
    }

    /// Adds the transitions of a (possibly negated) character class payload
    /// `[is_negative, lower0, upper0, ...]` from `start` to `end`.
    pub fn addCharacterClassTransitions(fsm: *Fsm, data: []const i32, start: i32, end: i32) Allocator.Error!void {
        var i: usize = 1;
        const positive = data[0] == 0;
        if (positive) {
            while (i + 1 < data.len) : (i += 2) {
                try addCodepointRange(fsm, start, end, @intCast(@max(data[i], 0)), @intCast(@max(data[i + 1], 0)));
            }
            return;
        }
        const pair_count = (data.len - 1) / 2;
        var stack_buf: [1024][2]u32 = undefined;
        const heap_buf: ?[][2]u32 = if (pair_count > stack_buf.len)
            try fsm.allocator.alloc([2]u32, pair_count)
        else
            null;
        defer if (heap_buf) |hb| fsm.allocator.free(hb);
        const excluded_slice = if (heap_buf) |hb| hb else stack_buf[0..pair_count];

        var count: usize = 0;
        while (i + 1 < data.len) : (i += 2) {
            excluded_slice[count] = .{ @intCast(@max(data[i], 0)), @intCast(@max(data[i + 1], 0)) };
            count += 1;
        }
        std.mem.sortUnstable([2]u32, excluded_slice, {}, struct {
            fn less(_: void, a: [2]u32, b: [2]u32) bool {
                return a[0] < b[0];
            }
        }.less);
        var next: u32 = 0;
        for (excluded_slice) |range| {
            const low = range[0];
            const high = range[1];
            if (low > next) {
                try addCodepointRange(fsm, start, end, next, @min(low - 1, MAX_CODEPOINT));
            }
            if (high >= MAX_CODEPOINT) return;
            next = @max(next, high + 1);
        }
        if (next <= MAX_CODEPOINT) {
            try addCodepointRange(fsm, start, end, next, MAX_CODEPOINT);
        }
    }

    /// Adds a token tag-dispatch from `start`, returning its end states.
    pub fn buildTokenTagDispatch(fsm: *Fsm, ttd: *const TokenTagDispatch, start: i32) Allocator.Error!std.ArrayList(i32) {
        const gpa = fsm.allocator;
        var end_states: std.ArrayList(i32) = .empty;
        errdefer end_states.deinit(gpa);
        var dispatch_states: std.ArrayList(i32) = .empty;
        defer dispatch_states.deinit(gpa);
        try dispatch_states.ensureTotalCapacity(gpa, ttd.trigger_rule_pairs.items.len);
        for (ttd.trigger_rule_pairs.items) |_| {
            dispatch_states.appendAssumeCapacity(try fsm.addState());
        }
        try end_states.append(gpa, start);
        const end_state = if (ttd.loop_after_dispatch)
            start
        else blk: {
            const state = try fsm.addState();
            try end_states.append(gpa, state);
            break :blk state;
        };
        var excluded_token_ids: std.ArrayList(i32) = .empty;
        defer excluded_token_ids.deinit(gpa);
        for (ttd.trigger_rule_pairs.items) |pair| {
            try excluded_token_ids.append(gpa, pair.token_id);
        }
        try excluded_token_ids.appendSlice(gpa, ttd.excludes.items);
        std.mem.sortUnstable(i32, excluded_token_ids.items, {}, std.sort.asc(i32));
        {
            var write: usize = 0;
            for (excluded_token_ids.items, 0..) |v, read| {
                if (read == 0 or excluded_token_ids.items[write - 1] != v) {
                    excluded_token_ids.items[write] = v;
                    write += 1;
                }
            }
            excluded_token_ids.shrinkRetainingCapacity(write);
        }
        for (ttd.trigger_rule_pairs.items, dispatch_states.items) |pair, dispatch_state| {
            try fsm.addTokenEdge(start, dispatch_state, &.{pair.token_id});
            try fsm.addRuleEdge(dispatch_state, end_state, pair.rule_id);
        }
        try fsm.addExcludeTokenEdge(start, start, excluded_token_ids.items);
        return end_states;
    }
};

fn addCodepointRange(fsm: *Fsm, from: i32, to: i32, low_in: u32, high: u32) Allocator.Error!void {
    var low = low_in;
    for ([_]u32{ 0x7F, 0x7FF, 0xFFFF, MAX_CODEPOINT }) |width_end| {
        if (low <= high and low <= width_end) {
            const end = @min(high, width_end);
            try addPackedUtf8RangeEdges(fsm, from, to, codepointToPackedUtf8(low), codepointToPackedUtf8(end));
            low = end + 1;
        }
    }
}

test "GrammarFsmBuilder builds expression, regular grammar, and regex FSMs with Diagnostic" {
    const gpa = std.testing.allocator;
    var builder = try GrammarBuilder.init(gpa);
    defer builder.deinit();
    const bs = try builder.addByteString("ab");
    const seq = try builder.addSequence(&.{bs});
    _ = try builder.addRuleNamed("root", try builder.addChoices(&.{seq}));
    var grammar = try builder.intoGrammar("root", null);
    defer grammar.deinit();

    try GrammarFsmBuilder.apply(gpa, &grammar, null);
    try std.testing.expect(grammar.perRuleFsm(0) != null);

    var reg_fsm = try GrammarFsmBuilder.fromRegularGrammar(gpa, &grammar, 100, null);
    defer reg_fsm.deinit();
    try std.testing.expect(try reg_fsm.acceptString("ab"));
    try std.testing.expect(!try reg_fsm.acceptString("a"));

    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);
    try std.testing.expectError(error.Flatten, GrammarFsmBuilder.fromRegularGrammar(gpa, &grammar, 1, &diag));
    const msg = try diag.formatAlloc(gpa);
    defer gpa.free(msg);
    try std.testing.expectEqualStrings("Regular grammar FSM state limit must be at least 2", msg);
}
