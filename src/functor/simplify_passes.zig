//! Structural simplification passes:
//! - `fuseByteStrings` (in-place adjacent byte-string fusing)
//! - `eliminateSingleElementExprs` (single-element sequence/choice and single-char class folding)
//! - `inlineRules` (in-place simple leading-rule inlining)
//! - `eliminateDeadCode` (reachability pruning + rule id compaction)
//! - `renameRootRule` (ensures the root rule is named `"root"`)

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_mod = @import("../grammar.zig");
const CharacterClassElement = grammar_mod.CharacterClassElement;
const Grammar = grammar_mod.Grammar;
const GrammarBuilder = grammar_mod.GrammarBuilder;
const GrammarExprType = grammar_mod.GrammarExprType;
const NO_EXPR = grammar_mod.NO_EXPR;
const dispatch = grammar_mod.dispatch;
const support = @import("../support.zig");
const Compact2dArrayError = support.Compact2dArrayError;
const mutator = @import("mutator.zig");
const FunctorError = mutator.FunctorError;
const MutatorState = mutator.MutatorState;

// ---------------------------------------------------------------------------
// 1. ByteStringFuser
// ---------------------------------------------------------------------------

const ByteStringFuser = struct {
    pub fn visitSequence(
        self: ByteStringFuser,
        builder: *GrammarBuilder,
        memo: []i32,
        expr_id: i32,
    ) (Allocator.Error || Compact2dArrayError)!i32 {
        _ = self;
        _ = memo;
        const alloc = builder.scratch_alloc;
        // Read-only probe so unchanged sequences allocate nothing.
        var previous_is_byte_string = false;
        var needs_rewrite = false;
        for (builder.grammarExpr(expr_id).data) |element_id| {
            const element = builder.grammarExpr(element_id);
            const is_byte_string = element.ty == .ByteString;
            const fusable = is_byte_string and (previous_is_byte_string or element.isEmpty());
            previous_is_byte_string = is_byte_string;
            if (fusable) needs_rewrite = true;
        }
        if (!needs_rewrite) return expr_id;

        // Copy element ids before appending new expressions to the arena.
        const element_ids = try alloc.dupe(i32, builder.grammarExpr(expr_id).data);
        defer alloc.free(element_ids);

        var new_element_ids: std.ArrayList(i32) = .empty;
        defer new_element_ids.deinit(alloc);

        var index: usize = 0;
        while (index < element_ids.len) {
            if (builder.grammarExpr(element_ids[index]).ty != .ByteString) {
                try new_element_ids.append(alloc, element_ids[index]);
                index += 1;
                continue;
            }
            var fused_bytes: std.ArrayList(i32) = .empty;
            defer fused_bytes.deinit(alloc);
            var run_end = index;
            while (run_end < element_ids.len) {
                const element = builder.grammarExpr(element_ids[run_end]);
                if (element.ty != .ByteString) break;
                try fused_bytes.appendSlice(alloc, element.data);
                run_end += 1;
            }
            // Empty byte strings are epsilon and can be omitted from a sequence.
            if (fused_bytes.items.len != 0) {
                try new_element_ids.append(alloc, if (run_end - index == 1)
                    element_ids[index]
                else
                    try builder.addByteStringBytes(fused_bytes.items));
            }
            index = run_end;
        }
        return builder.addSequence(new_element_ids.items);
    }
};

/// Fuses adjacent byte strings (and drops empty byte strings) within sequences in place.
pub fn fuseByteStrings(grammar: *Grammar) (Allocator.Error || Compact2dArrayError)!void {
    try mutator.in_place.apply(ByteStringFuser{}, grammar);
}

// ---------------------------------------------------------------------------
// 2. SingleElementExprEliminator
// ---------------------------------------------------------------------------

/// Collapses one-element sequences/choices to their sole child and converts
/// single-codepoint positive character classes `[c]` to byte strings.
pub const SingleElementExprEliminator = struct {
    pub fn visitSequence(self: SingleElementExprEliminator, state: *MutatorState, data: []const i32) FunctorError!i32 {
        const alloc = state.gpa();
        var ids: std.ArrayList(i32) = .empty;
        defer ids.deinit(alloc);
        try ids.ensureTotalCapacity(alloc, data.len);
        for (data) |child| ids.appendAssumeCapacity(try mutator.visitExprId(self, state, child));
        if (ids.items.len == 1) return ids.items[0];
        return state.builder.addSequence(ids.items);
    }

    pub fn visitChoices(self: SingleElementExprEliminator, state: *MutatorState, data: []const i32) FunctorError!i32 {
        const alloc = state.gpa();
        var ids: std.ArrayList(i32) = .empty;
        defer ids.deinit(alloc);
        try ids.ensureTotalCapacity(alloc, data.len);
        for (data) |child| ids.appendAssumeCapacity(try mutator.visitExprId(self, state, child));
        if (ids.items.len == 1) return ids.items[0];
        return state.builder.addChoices(ids.items);
    }

    /// `[c]` (a single, non-negated codepoint) becomes the byte string of that codepoint.
    pub fn visitCharacterClass(
        self: SingleElementExprEliminator,
        state: *MutatorState,
        ty: GrammarExprType,
        data: []const i32,
    ) FunctorError!i32 {
        _ = self;
        if (data.len == 3 and data[0] == 0 and data[1] == data[2]) {
            const alloc = state.gpa();
            const bytes = try support.charToUtf8Bytes(alloc, @intCast(data[1]));
            defer alloc.free(bytes);
            var byte_ids: [4]i32 = undefined;
            for (bytes, 0..) |b, i| byte_ids[i] = b;
            return state.builder.addByteStringBytes(byte_ids[0..bytes.len]);
        }
        return state.builder.addGrammarExpr(ty, data);
    }
};

/// Eliminates single-element sequences/choices and single-char classes, returning a fresh `Grammar`.
pub fn eliminateSingleElementExprs(allocator: Allocator, grammar: *const Grammar) FunctorError!Grammar {
    return mutator.apply(SingleElementExprEliminator{}, allocator, grammar);
}

// ---------------------------------------------------------------------------
// 3. RuleInliner
// ---------------------------------------------------------------------------

/// Inlines leading references to simple non-annotated rules in place.
pub fn inlineRules(grammar: *Grammar) (Allocator.Error || Compact2dArrayError)!void {
    const alloc = grammar.impl.arena.child_allocator;
    var inliner = RuleInliner{
        .original_body_expr_ids = .empty,
        .can_rule_be_inlined = .empty,
    };
    defer {
        inliner.original_body_expr_ids.deinit(alloc);
        inliner.can_rule_be_inlined.deinit(alloc);
    }
    const rules = grammar.rulesSlice();
    try inliner.original_body_expr_ids.ensureTotalCapacity(alloc, rules.len);
    try inliner.can_rule_be_inlined.ensureTotalCapacity(alloc, rules.len);
    for (rules, 0..) |r, rule_id| {
        inliner.original_body_expr_ids.appendAssumeCapacity(r.body_expr_id);
        inliner.can_rule_be_inlined.appendAssumeCapacity(canRuleBeInlined(grammar, @intCast(rule_id)));
    }
    try mutator.in_place.apply(&inliner, grammar);
}

const RuleInliner = struct {
    original_body_expr_ids: std.ArrayList(i32),
    can_rule_be_inlined: std.ArrayList(bool),

    fn leadingInlinableRule(self: *const RuleInliner, builder: *const GrammarBuilder, choice_id: i32) ?i32 {
        const choice = builder.grammarExpr(choice_id);
        if (choice.ty != .Sequence or choice.isEmpty()) return null;
        const first_element = builder.grammarExpr(choice.data[0]);
        if (first_element.ty != .RuleRef) return null;
        const rule_id = first_element.ruleRefId();
        if (!self.can_rule_be_inlined.items[@intCast(rule_id)]) return null;
        return rule_id;
    }

    pub fn visitChoices(
        self: *RuleInliner,
        builder: *GrammarBuilder,
        memo: []i32,
        expr_id: i32,
    ) (Allocator.Error || Compact2dArrayError)!i32 {
        const alloc = builder.scratch_alloc;
        const size = builder.grammarExpr(expr_id).len();
        var new_choice_ids: ?std.ArrayList(i32) = null;
        errdefer if (new_choice_ids) |*ids| ids.deinit(alloc);

        for (0..size) |index| {
            const choice_id = builder.grammarExpr(expr_id).data[index];
            const inline_rule_id = self.leadingInlinableRule(builder, choice_id) orelse {
                const new_choice_id = try mutator.in_place.visitExpr(self, builder, memo, choice_id);
                if (new_choice_ids == null and new_choice_id != choice_id) {
                    var ids: std.ArrayList(i32) = .empty;
                    try ids.appendSlice(alloc, builder.grammarExpr(expr_id).data[0..index]);
                    new_choice_ids = ids;
                }
                if (new_choice_ids) |*ids| try ids.append(alloc, new_choice_id);
                continue;
            };
            if (new_choice_ids == null) {
                var ids: std.ArrayList(i32) = .empty;
                try ids.appendSlice(alloc, builder.grammarExpr(expr_id).data[0..index]);
                new_choice_ids = ids;
            }
            const ids = &new_choice_ids.?;
            const rest_source = builder.grammarExpr(choice_id).data[1..];
            var rest_element_ids: std.ArrayList(i32) = .empty;
            defer rest_element_ids.deinit(alloc);
            try rest_element_ids.ensureTotalCapacity(alloc, rest_source.len);
            for (rest_source) |element_id| {
                rest_element_ids.appendAssumeCapacity(try mutator.in_place.visitExpr(self, builder, memo, element_id));
            }
            const ref_body_id = self.original_body_expr_ids.items[@intCast(inline_rule_id)];
            const ref_choice_ids = try alloc.dupe(i32, builder.grammarExpr(ref_body_id).data);
            defer alloc.free(ref_choice_ids);
            for (ref_choice_ids) |ref_choice_id| {
                var new_sequence: std.ArrayList(i32) = .empty;
                defer new_sequence.deinit(alloc);
                const seq_len = builder.grammarExpr(ref_choice_id).len();
                try new_sequence.ensureTotalCapacity(alloc, seq_len + rest_element_ids.items.len);
                for (0..seq_len) |elem_idx| {
                    const element_id = builder.grammarExpr(ref_choice_id).data[elem_idx];
                    new_sequence.appendAssumeCapacity(try mutator.in_place.visitExpr(self, builder, memo, element_id));
                }
                try new_sequence.appendSlice(alloc, rest_element_ids.items);
                try ids.append(alloc, try builder.addSequence(new_sequence.items));
            }
        }
        if (new_choice_ids) |*ids| {
            defer ids.deinit(alloc);
            return builder.addChoices(ids.items);
        }
        return expr_id;
    }
};

fn canRuleBeInlined(grammar: *const Grammar, rule_id: i32) bool {
    const r = grammar.rule(rule_id);
    if (r.max_tokens >= 0 or r.max_chars >= 0 or r.capture_name.len != 0 or
        grammar.suffixStopInfo(rule_id) != null or r.is_lazy or r.temperature != null)
    {
        return false;
    }
    const body = grammar.expr(r.body_expr_id);
    if (body.ty != .Choices or body.isEmpty()) return false;
    for (body.data) |choice_id| {
        const choice = grammar.expr(choice_id);
        if (choice.ty != .Sequence) return false;
        for (choice.data) |element_id| {
            if (grammar.expr(element_id).ty == .RuleRef) return false;
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// 4. DeadCodeEliminator
// ---------------------------------------------------------------------------

/// Drops rules unreachable from the root and compacts expressions/rule ids.
pub fn eliminateDeadCode(allocator: Allocator, grammar: *const Grammar) FunctorError!Grammar {
    const used = try usedRules(allocator, grammar);
    defer allocator.free(used);

    var pass = DeadCodeEliminator{ .rule_id_map = .empty };
    defer pass.rule_id_map.deinit(allocator);
    try pass.rule_id_map.ensureTotalCapacity(allocator, @intCast(used.len));

    var state = MutatorState{
        .base = grammar,
        .builder = try GrammarBuilder.init(allocator),
        .cur_rule_name = "",
    };
    defer state.builder.deinit();

    for (used) |old_id| {
        const new_id = try state.builder.addEmptyRule(grammar.rule(old_id).name);
        pass.rule_id_map.putAssumeCapacity(old_id, new_id);
    }

    const remapper = RuleIdRemapper{ .map = &pass.rule_id_map };
    for (used) |old_id| {
        const r = grammar.rule(old_id);
        state.cur_rule_name = r.name;
        const new_body = try mutator.visitExprId(&pass, &state, r.body_expr_id);
        const new_id = pass.rule_id_map.get(old_id).?;
        state.builder.updateRuleBody(new_id, new_body);
        const new_lookahead = try mutator.visitLookahead(&pass, &state, r.lookahead_assertion_id);
        state.builder.updateLookaheadAssertion(new_id, new_lookahead);
        try state.builder.copyRuleAttributes(new_id, grammar, old_id, remapper);
    }

    const new_root = pass.rule_id_map.get(grammar.rootRuleId()).?;
    return state.builder.intoGrammarWithRootId(new_root);
}

const RuleIdRemapper = struct {
    map: *const std.AutoHashMapUnmanaged(i32, i32),

    pub fn call(self: RuleIdRemapper, id: i32) i32 {
        return self.map.get(id).?;
    }
};

const DeadCodeEliminator = struct {
    rule_id_map: std.AutoHashMapUnmanaged(i32, i32),

    pub fn visitRuleRef(
        self: *const DeadCodeEliminator,
        state: *MutatorState,
        ty: GrammarExprType,
        data: []const i32,
    ) FunctorError!i32 {
        _ = ty;
        return state.builder.addRuleRef(self.rule_id_map.get(data[0]).?);
    }

    pub fn visitRepeat(
        self: *const DeadCodeEliminator,
        state: *MutatorState,
        ty: GrammarExprType,
        data: []const i32,
    ) FunctorError!i32 {
        _ = ty;
        return state.builder.addRepeat(self.rule_id_map.get(data[0]).?, data[1], data[2]);
    }

    pub fn visitTagDispatch(
        self: *const DeadCodeEliminator,
        state: *MutatorState,
        ty: GrammarExprType,
        data: []const i32,
    ) FunctorError!i32 {
        _ = ty;
        const alloc = state.gpa();
        var td = try dispatch.decodeTagDispatchData(state.base, alloc, data);
        defer td.deinit(alloc);
        for (td.tag_rule_pairs.items) |*pair| {
            pair.rule_id = self.rule_id_map.get(pair.rule_id).?;
        }
        return state.builder.addTagDispatch(&td);
    }

    pub fn visitTokenTagDispatch(
        self: *const DeadCodeEliminator,
        state: *MutatorState,
        ty: GrammarExprType,
        data: []const i32,
    ) FunctorError!i32 {
        _ = ty;
        const alloc = state.gpa();
        var ttd = try dispatch.decodeTokenTagDispatchData(alloc, data);
        defer ttd.deinit(alloc);
        for (ttd.trigger_rule_pairs.items) |*pair| {
            pair.rule_id = self.rule_id_map.get(pair.rule_id).?;
        }
        return state.builder.addTokenTagDispatch(&ttd);
    }
};

fn usedRules(allocator: Allocator, grammar: *const Grammar) Allocator.Error![]i32 {
    var visited: std.AutoHashMapUnmanaged(i32, void) = .empty;
    defer visited.deinit(allocator);
    var queue: std.Deque(i32) = .empty;
    defer queue.deinit(allocator);

    try queue.pushBack(allocator, grammar.rootRuleId());
    while (queue.popFront()) |rule_id| {
        const gop = try visited.getOrPut(allocator, rule_id);
        if (gop.found_existing) continue;
        const r = grammar.rule(rule_id);
        try collectRuleRefs(allocator, grammar, r.body_expr_id, &queue);
        if (r.lookahead_assertion_id != NO_EXPR) {
            try collectRuleRefs(allocator, grammar, r.lookahead_assertion_id, &queue);
        }
        if (grammar.suffixStopInfo(rule_id)) |info| {
            if (info.body_rule_id != -1) {
                try queue.pushBack(allocator, info.body_rule_id);
                try queue.pushBack(allocator, info.marker_rule_id);
            }
        }
    }
    const result = try allocator.alloc(i32, visited.count());
    var wi: usize = 0;
    var kit = visited.keyIterator();
    while (kit.next()) |k| {
        result[wi] = k.*;
        wi += 1;
    }
    std.mem.sortUnstable(i32, result, {}, std.sort.asc(i32));
    return result;
}

fn collectRuleRefs(
    allocator: Allocator,
    grammar: *const Grammar,
    expr_id: i32,
    queue: *std.Deque(i32),
) Allocator.Error!void {
    const e = grammar.expr(expr_id);
    switch (e.ty) {
        .RuleRef, .Repeat => try queue.pushBack(allocator, e.data[0]),
        .Sequence, .Choices => {
            for (e.data) |child| try collectRuleRefs(allocator, grammar, child, queue);
        },
        .TagDispatch => {
            var td = try dispatch.tagDispatch(grammar, allocator, expr_id);
            defer td.deinit(allocator);
            for (td.tag_rule_pairs.items) |pair| try queue.pushBack(allocator, pair.rule_id);
        },
        .TokenTagDispatch => {
            var ttd = try dispatch.tokenTagDispatch(grammar, allocator, expr_id);
            defer ttd.deinit(allocator);
            for (ttd.trigger_rule_pairs.items) |pair| try queue.pushBack(allocator, pair.rule_id);
        },
        else => {},
    }
}

// ---------------------------------------------------------------------------
// 5. RootRuleRenamer
// ---------------------------------------------------------------------------

/// Ensures the root rule is named `"root"`. If another rule already has that name, it is
/// renamed to the first free `root_N`. The input is untouched; returns a fresh `Grammar`.
pub fn renameRootRule(allocator: Allocator, grammar: *const Grammar) (Allocator.Error || Compact2dArrayError)!Grammar {
    if (std.mem.eql(u8, grammar.rootRule().name, "root")) {
        return grammar.dupe(allocator);
    }

    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(allocator);
    const rules = grammar.rulesSlice();
    try names.ensureTotalCapacity(allocator, @intCast(rules.len));
    var collision: ?i32 = null;
    for (rules, 0..) |r, i| {
        names.putAssumeCapacity(r.name, {});
        if (collision == null and std.mem.eql(u8, r.name, "root")) {
            collision = @intCast(i);
        }
    }

    var renamed = try grammar.dupe(allocator);
    errdefer renamed.deinit();
    try renamed.renameRule(renamed.rootRuleId(), "root");

    if (collision) |collision_id| {
        var i: usize = 0;
        while (i <= rules.len) : (i += 1) {
            var buf: [32]u8 = undefined;
            const candidate = std.fmt.bufPrint(&buf, "root_{d}", .{i}) catch unreachable;
            if (!names.contains(candidate)) {
                try renamed.renameRule(collision_id, candidate);
                break;
            }
        }
    }
    return renamed;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "fuseByteStrings merges adjacent strings and drops empties" {
    const gpa = std.testing.allocator;
    var builder = try GrammarBuilder.init(gpa);
    defer builder.deinit();
    const a = try builder.addByteString("a");
    const empty = try builder.addByteString("");
    const bc = try builder.addByteString("bc");
    const cc = try builder.addCharacterClass(&.{CharacterClassElement.init('x', 'y')}, false);
    const seq = try builder.addSequence(&.{ a, empty, bc, cc, try builder.addByteString("") });
    _ = try builder.addRuleNamed("root", seq);
    var grammar = try builder.intoGrammar("root", null);
    defer grammar.deinit();

    try fuseByteStrings(&grammar);

    const body = grammar.expr(grammar.rule(0).body_expr_id);
    try std.testing.expectEqual(@as(usize, 2), body.data.len);
    const fused = try grammar.expr(body.data[0]).byteString(gpa);
    defer gpa.free(fused);
    try std.testing.expectEqualStrings("abc", fused);
    try std.testing.expect(grammar.expr(body.data[1]).ty == .CharacterClass);
}

test "eliminateSingleElementExprs folds single-char class and singletons" {
    const gpa = std.testing.allocator;
    var builder = try GrammarBuilder.init(gpa);
    defer builder.deinit();
    const cc = try builder.addCharacterClass(&.{CharacterClassElement.init('a', 'a')}, false);
    const seq = try builder.addSequence(&.{cc});
    const choices = try builder.addChoices(&.{seq});
    _ = try builder.addRuleNamed("root", choices);
    var grammar = try builder.intoGrammar("root", null);
    defer grammar.deinit();

    var simplified = try eliminateSingleElementExprs(gpa, &grammar);
    defer simplified.deinit();
    const body = simplified.expr(simplified.rootRule().body_expr_id);
    try std.testing.expectEqual(GrammarExprType.ByteString, body.ty);
    const bs = try body.byteString(gpa);
    defer gpa.free(bs);
    try std.testing.expectEqualStrings("a", bs);
}

test "inlineRules splices referenced choices in front" {
    const gpa = std.testing.allocator;
    var builder = try GrammarBuilder.init(gpa);
    defer builder.deinit();
    const pfx = try builder.addRuleNamed(
        "pfx",
        try builder.addChoices(&.{
            try builder.addSequence(&.{try builder.addByteString("a")}),
            try builder.addSequence(&.{try builder.addByteString("b")}),
        }),
    );
    const seq1 = try builder.addSequence(&.{ try builder.addRuleRef(pfx), try builder.addByteString("x") });
    const root_body = try builder.addChoices(&.{ seq1, try builder.addByteString("c") });
    _ = try builder.addRuleNamed("root", root_body);
    var grammar = try builder.intoGrammar("root", null);
    defer grammar.deinit();

    try inlineRules(&grammar);

    const ebnf = try grammar.toStringEbnf(gpa);
    defer gpa.free(ebnf);
    try std.testing.expectEqualStrings(
        "pfx ::= ((\"a\") | (\"b\"))\nroot ::= ((\"a\" \"x\") | (\"b\" \"x\") | \"c\")\n",
        ebnf,
    );
}

test "eliminateDeadCode keeps reachable rules and remaps refs" {
    const gpa = std.testing.allocator;
    var builder = try GrammarBuilder.init(gpa);
    defer builder.deinit();
    _ = try builder.addRuleNamed("unused", try builder.addByteString("z"));
    const keep = try builder.addRuleNamed("keep", try builder.addByteString("a"));
    const root = try builder.addRuleNamed("root", try builder.addRuleRef(keep));
    builder.updateMaxTokens(root, 5);
    var grammar = try builder.intoGrammar("root", null);
    defer grammar.deinit();

    var reduced = try eliminateDeadCode(gpa, &grammar);
    defer reduced.deinit();
    try std.testing.expectEqual(@as(usize, 2), reduced.numRules());
    try std.testing.expectEqualStrings("keep", reduced.rule(0).name);
    try std.testing.expectEqualStrings("root", reduced.rule(1).name);
    try std.testing.expectEqual(@as(i32, 1), reduced.rootRuleId());
    try std.testing.expectEqual(@as(i32, 5), reduced.rule(1).max_tokens);
    const body = reduced.expr(reduced.rule(1).body_expr_id);
    try std.testing.expectEqual(@as(i32, 0), body.data[0]);
}

test "renameRootRule without and with collision" {
    const gpa = std.testing.allocator;
    {
        var builder = try GrammarBuilder.init(gpa);
        defer builder.deinit();
        const bs = try builder.addByteString("a");
        _ = try builder.addRuleNamed("main", bs);
        var grammar = try builder.intoGrammar("main", null);
        defer grammar.deinit();
        var renamed = try renameRootRule(gpa, &grammar);
        defer renamed.deinit();
        try std.testing.expectEqualStrings("root", renamed.rootRule().name);
        try std.testing.expectEqualStrings("main", grammar.rootRule().name);
    }
    {
        var builder = try GrammarBuilder.init(gpa);
        defer builder.deinit();
        const bs = try builder.addByteString("a");
        _ = try builder.addRuleNamed("root", bs);
        const bs2 = try builder.addByteString("b");
        _ = try builder.addRuleNamed("other", bs2);
        var grammar = try builder.intoGrammar("other", null);
        defer grammar.deinit();
        var renamed = try renameRootRule(gpa, &grammar);
        defer renamed.deinit();
        try std.testing.expectEqualStrings("root", renamed.rootRule().name);
        try std.testing.expectEqualStrings("root_0", renamed.rule(0).name);
        try std.testing.expectEqualStrings("root", renamed.rule(1).name);
        try std.testing.expectEqual(@as(i32, 1), renamed.rootRuleId());
    }
}
