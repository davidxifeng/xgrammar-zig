//! Builder for the BNF AST (`GrammarBuilder`), with zero-copy finalization and
//! scratch-isolated in-place editing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Diagnostic = @import("../Diagnostic.zig").Diagnostic;
const grammar_mod = @import("Grammar.zig");
const Grammar = grammar_mod.Grammar;
const CharacterClassElement = grammar_mod.CharacterClassElement;
const GrammarExpr = grammar_mod.GrammarExpr;
const GrammarExprType = grammar_mod.GrammarExprType;
const Rule = grammar_mod.Rule;
const NO_EXPR = grammar_mod.NO_EXPR;
const SuffixStopInfo = grammar_mod.SuffixStopInfo;
const dupeRule = grammar_mod.dupeRule;
const dupeSuffixStopInfo = grammar_mod.dupeSuffixStopInfo;
const searchByRuleId = grammar_mod.searchByRuleId;
const dispatch = @import("dispatch.zig");
const TagDispatch = dispatch.TagDispatch;
const TokenTagDispatch = dispatch.TokenTagDispatch;
const support = @import("../support.zig");
const Compact2dArray = support.Compact2dArray;
const Compact2dArrayError = support.Compact2dArrayError;

/// Builds a `Grammar` incrementally: add expressions (each returns its id), wire them
/// into rules, then finalize with a root rule.
///
/// In standalone mode (`init`/`fromGrammar`), the builder owns an `ArenaAllocator` for AST
/// data and transfers it directly into the `Grammar` on `intoGrammar` / `intoGrammarWithRootId`
/// with zero copying. Scratch structures (`rule_name_to_id`, `next_cnt_per_hint`, and
/// temporary conversion buffers) always use `scratch_alloc` and are freed in `deinit()`,
/// so `editInPlace` never pollutes `grammar.impl.arena`.
pub const GrammarBuilder = struct {
    scratch_alloc: Allocator,
    arena: ?ArenaAllocator,
    borrowed_arena: ?*ArenaAllocator,
    rules: std.ArrayList(Rule),
    suffix_stop_infos: std.ArrayList(SuffixStopInfo),
    exprs: Compact2dArray(i32),
    rule_name_to_id: ?std.StringHashMapUnmanaged(i32),
    next_cnt_per_hint: std.StringHashMapUnmanaged(i32),

    /// Creates an empty standalone builder backed by `backing`.
    pub fn init(backing: Allocator) Allocator.Error!GrammarBuilder {
        var arena = ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const exprs = try Compact2dArray(i32).init(arena.allocator());
        return .{
            .scratch_alloc = backing,
            .arena = arena,
            .borrowed_arena = null,
            .rules = .empty,
            .suffix_stop_infos = .empty,
            .exprs = exprs,
            .rule_name_to_id = null,
            .next_cnt_per_hint = .empty,
        };
    }

    /// Releases scratch maps and (if still owned) the standalone AST arena.
    pub fn deinit(self: *GrammarBuilder) void {
        if (self.rule_name_to_id) |*map| {
            var it = map.keyIterator();
            while (it.next()) |k| self.scratch_alloc.free(k.*);
            map.deinit(self.scratch_alloc);
        }
        {
            var it = self.next_cnt_per_hint.keyIterator();
            while (it.next()) |k| self.scratch_alloc.free(k.*);
            self.next_cnt_per_hint.deinit(self.scratch_alloc);
        }
        if (self.arena) |*arena| {
            arena.deinit();
        }
        self.* = undefined;
    }

    inline fn astAllocator(self: *GrammarBuilder) Allocator {
        if (self.arena) |*a| return a.allocator();
        return self.borrowed_arena.?.allocator();
    }

    /// Seeds a builder from an existing grammar by deep-copying its AST into a fresh arena.
    pub fn fromGrammar(grammar: *const Grammar, backing: Allocator) (Compact2dArrayError || Allocator.Error)!GrammarBuilder {
        var self = try init(backing);
        errdefer self.deinit();
        const a = self.astAllocator();
        try self.rules.ensureTotalCapacity(a, grammar.impl.rules.items.len);
        for (grammar.impl.rules.items) |r| {
            self.rules.appendAssumeCapacity(try dupeRule(a, r));
        }
        try self.suffix_stop_infos.ensureTotalCapacity(a, grammar.impl.suffix_stop_infos.items.len);
        for (grammar.impl.suffix_stop_infos.items) |info| {
            self.suffix_stop_infos.appendAssumeCapacity(try dupeSuffixStopInfo(a, info));
        }
        self.exprs = try Compact2dArray(i32).initFromDataAndIndptr(
            a,
            grammar.impl.exprs.dataSlice(),
            grammar.impl.exprs.indptrSlice(),
        );
        return self;
    }

    /// Binds a builder to `grammar` without copying it. Edits accumulate in `grammar`'s
    /// arena while scratch maps stay in `grammar`'s backing allocator (`deinit()` frees them).
    pub fn editInPlace(grammar: *Grammar) GrammarBuilder {
        const storage = grammar.storageMut();
        return .{
            .scratch_alloc = grammar.impl.arena.child_allocator,
            .arena = null,
            .borrowed_arena = &grammar.impl.arena,
            .rules = storage.rules.*,
            .suffix_stop_infos = storage.suffix_stop_infos.*,
            .exprs = storage.exprs.*,
            .rule_name_to_id = null,
            .next_cnt_per_hint = .empty,
        };
    }

    /// Writes the edited rule/expression storage back into `grammar`.
    pub fn editInPlaceCommit(self: *GrammarBuilder, grammar: *Grammar) void {
        std.debug.assert(self.arena == null);
        const storage = grammar.storageMut();
        storage.rules.* = self.rules;
        storage.exprs.* = self.exprs;
        storage.suffix_stop_infos.* = self.suffix_stop_infos;
    }

    /// Zero-copy finalizes the grammar, setting the root to the rule named `root_rule_name`.
    /// On `error.RootRuleNotFound`, populates `diag` (with `.message`) if non-null.
    pub fn intoGrammar(
        self: *GrammarBuilder,
        root_rule_name: []const u8,
        diag: ?*Diagnostic,
    ) (Allocator.Error || error{RootRuleNotFound})!Grammar {
        const map = try self.ruleNameToIdMap();
        const root_rule_id = map.get(root_rule_name) orelse {
            if (diag) |d| try d.setFmt(self.scratch_alloc, .message, "Root rule '{s}' not found", .{root_rule_name});
            return error.RootRuleNotFound;
        };
        return self.intoGrammarWithRootId(root_rule_id);
    }

    /// Zero-copy finalizes the grammar with an explicit root rule id, transferring the
    /// builder's `ArenaAllocator` and AST buffers directly into the new `Grammar`.
    /// The builder remains valid for `deinit()` only.
    pub fn intoGrammarWithRootId(self: *GrammarBuilder, root_rule_id: i32) Allocator.Error!Grammar {
        std.debug.assert(self.arena != null);
        const grammar = try Grammar.initFromArena(
            self.arena.?,
            self.rules,
            self.exprs,
            self.suffix_stop_infos,
            root_rule_id,
        );
        self.arena = null;
        self.rules = .empty;
        self.suffix_stop_infos = .empty;
        self.exprs = .{};
        return grammar;
    }

    fn ruleNameToIdMap(self: *GrammarBuilder) Allocator.Error!*std.StringHashMapUnmanaged(i32) {
        if (self.rule_name_to_id == null) {
            var map: std.StringHashMapUnmanaged(i32) = .empty;
            errdefer {
                var it = map.keyIterator();
                while (it.next()) |k| self.scratch_alloc.free(k.*);
                map.deinit(self.scratch_alloc);
            }
            try map.ensureTotalCapacity(self.scratch_alloc, @intCast(self.rules.items.len));
            for (self.rules.items, 0..) |r, id| {
                const k = try self.scratch_alloc.dupe(u8, r.name);
                errdefer self.scratch_alloc.free(k);
                map.putAssumeCapacity(k, @intCast(id));
            }
            self.rule_name_to_id = map;
        }
        return &self.rule_name_to_id.?;
    }

    // ----------------------------- expressions -----------------------------

    pub fn addGrammarExpr(
        self: *GrammarBuilder,
        ty: GrammarExprType,
        data: []const i32,
    ) Allocator.Error!i32 {
        const a = self.astAllocator();
        return @intCast(try self.exprs.pushRowNoncontiguous(a, ty.asI32(), data));
    }

    pub fn addByteStringBytes(self: *GrammarBuilder, bytes: []const i32) Allocator.Error!i32 {
        return self.addGrammarExpr(.ByteString, bytes);
    }

    pub fn addByteString(self: *GrammarBuilder, s: []const u8) Allocator.Error!i32 {
        var bytes: std.ArrayList(i32) = .empty;
        defer bytes.deinit(self.scratch_alloc);
        try bytes.ensureTotalCapacity(self.scratch_alloc, s.len);
        for (s) |b| bytes.appendAssumeCapacity(b);
        return self.addByteStringBytes(bytes.items);
    }

    fn buildCharClassData(
        self: *GrammarBuilder,
        elements: []const CharacterClassElement,
        is_negative: bool,
    ) Allocator.Error!std.ArrayList(i32) {
        var data: std.ArrayList(i32) = .empty;
        errdefer data.deinit(self.scratch_alloc);
        try data.ensureTotalCapacity(self.scratch_alloc, 1 + elements.len * 2);
        data.appendAssumeCapacity(@intFromBool(is_negative));
        for (elements) |e| {
            data.appendAssumeCapacity(e.lower);
            data.appendAssumeCapacity(e.upper);
        }
        return data;
    }

    pub fn addCharacterClass(
        self: *GrammarBuilder,
        elements: []const CharacterClassElement,
        is_negative: bool,
    ) Allocator.Error!i32 {
        var data = try self.buildCharClassData(elements, is_negative);
        defer data.deinit(self.scratch_alloc);
        return self.addGrammarExpr(.CharacterClass, data.items);
    }

    pub fn addCharacterClassStar(
        self: *GrammarBuilder,
        elements: []const CharacterClassElement,
        is_negative: bool,
    ) Allocator.Error!i32 {
        var data = try self.buildCharClassData(elements, is_negative);
        defer data.deinit(self.scratch_alloc);
        return self.addGrammarExpr(.CharacterClassStar, data.items);
    }

    pub fn addEmptyStr(self: *GrammarBuilder) Allocator.Error!i32 {
        return self.addGrammarExpr(.EmptyStr, &.{});
    }

    pub fn addTokenSet(self: *GrammarBuilder, token_ids: []const i32) Allocator.Error!i32 {
        return self.addGrammarExpr(.Token, token_ids);
    }

    pub fn addExcludeTokenSet(self: *GrammarBuilder, token_ids: []const i32) Allocator.Error!i32 {
        return self.addGrammarExpr(.ExcludeToken, token_ids);
    }

    pub fn addRuleRef(self: *GrammarBuilder, rule_id: i32) Allocator.Error!i32 {
        return self.addGrammarExpr(.RuleRef, &.{rule_id});
    }

    pub fn addSequence(self: *GrammarBuilder, elements: []const i32) Allocator.Error!i32 {
        return self.addGrammarExpr(.Sequence, elements);
    }

    pub fn addChoices(self: *GrammarBuilder, choices: []const i32) Allocator.Error!i32 {
        return self.addGrammarExpr(.Choices, choices);
    }

    pub fn addRepeat(
        self: *GrammarBuilder,
        ref_rule_id: i32,
        min_repeat: i32,
        max_repeat: i32,
    ) Allocator.Error!i32 {
        return self.addGrammarExpr(.Repeat, &.{ ref_rule_id, min_repeat, max_repeat });
    }

    pub fn addRepeatFromExpr(
        self: *GrammarBuilder,
        cur_rule_name: []const u8,
        grammar_expr_id: i32,
        min_repeat: i32,
        max_repeat: i32,
    ) Allocator.Error!i32 {
        const expr = self.grammarExpr(grammar_expr_id);
        const ref_rule_id = if (expr.ty == .RuleRef)
            expr.ruleRefId()
        else blk: {
            const name = try self.getNewRuleName(cur_rule_name);
            break :blk try self.addRuleNamed(name, grammar_expr_id);
        };
        return self.addRepeat(ref_rule_id, min_repeat, max_repeat);
    }

    pub fn addRegex(
        self: *GrammarBuilder,
        pattern: []const u8,
        json_string: bool,
    ) Allocator.Error!i32 {
        var data: std.ArrayList(i32) = .empty;
        defer data.deinit(self.scratch_alloc);
        try data.ensureTotalCapacity(self.scratch_alloc, pattern.len + 1);
        data.appendAssumeCapacity(@intFromBool(json_string));
        for (pattern) |b| data.appendAssumeCapacity(b);
        return self.addGrammarExpr(.Regex, data.items);
    }

    pub fn addSubstring(self: *GrammarBuilder, chunks: []const []const u8) Allocator.Error!i32 {
        var data: std.ArrayList(i32) = .empty;
        defer data.deinit(self.scratch_alloc);
        for (chunks) |chunk| {
            try data.append(self.scratch_alloc, @intCast(chunk.len));
            for (chunk) |b| try data.append(self.scratch_alloc, b);
        }
        return self.addGrammarExpr(.Substring, data.items);
    }

    pub fn addTagDispatch(self: *GrammarBuilder, tag_dispatch: *const TagDispatch) Allocator.Error!i32 {
        var data: std.ArrayList(i32) = .empty;
        defer data.deinit(self.scratch_alloc);
        try data.ensureTotalCapacity(self.scratch_alloc, tag_dispatch.tag_rule_pairs.items.len * 2 + 2);
        for (tag_dispatch.tag_rule_pairs.items) |pair| {
            const id = try self.addByteString(pair.tag);
            data.appendAssumeCapacity(id);
            data.appendAssumeCapacity(pair.rule_id);
        }
        data.appendAssumeCapacity(@intFromBool(tag_dispatch.loop_after_dispatch));
        var exclude_ids: std.ArrayList(i32) = .empty;
        defer exclude_ids.deinit(self.scratch_alloc);
        try exclude_ids.ensureTotalCapacity(self.scratch_alloc, tag_dispatch.excludes.items.len);
        for (tag_dispatch.excludes.items) |exclude| {
            exclude_ids.appendAssumeCapacity(try self.addByteString(exclude));
        }
        const exclude_choices = try self.addChoices(exclude_ids.items);
        data.appendAssumeCapacity(exclude_choices);
        return self.addGrammarExpr(.TagDispatch, data.items);
    }

    pub fn addTokenTagDispatch(
        self: *GrammarBuilder,
        ttd: *const TokenTagDispatch,
    ) Allocator.Error!i32 {
        var data: std.ArrayList(i32) = .empty;
        defer data.deinit(self.scratch_alloc);
        try data.ensureTotalCapacity(
            self.scratch_alloc,
            ttd.trigger_rule_pairs.items.len * 2 + ttd.excludes.items.len + 3,
        );
        data.appendAssumeCapacity(@intCast(ttd.trigger_rule_pairs.items.len));
        for (ttd.trigger_rule_pairs.items) |pair| {
            data.appendAssumeCapacity(pair.token_id);
            data.appendAssumeCapacity(pair.rule_id);
        }
        data.appendAssumeCapacity(@intFromBool(ttd.loop_after_dispatch));
        data.appendAssumeCapacity(@intCast(ttd.excludes.items.len));
        for (ttd.excludes.items) |token_id| data.appendAssumeCapacity(token_id);
        return self.addGrammarExpr(.TokenTagDispatch, data.items);
    }

    pub fn numGrammarExprs(self: *const GrammarBuilder) i32 {
        return @intCast(self.exprs.len());
    }

    pub fn grammarExpr(self: *const GrammarBuilder, expr_id: i32) GrammarExpr {
        const row = self.exprs.row(@intCast(expr_id));
        const ty = GrammarExprType.fromInt(row[0]) catch unreachable;
        return .{ .ty = ty, .data = row[1..] };
    }

    // -------------------------------- rules --------------------------------

    pub fn addRule(self: *GrammarBuilder, r: Rule) Allocator.Error!i32 {
        const id: i32 = @intCast(self.rules.items.len);
        const map = try self.ruleNameToIdMap();
        std.debug.assert(!map.contains(r.name));
        const key = try self.scratch_alloc.dupe(u8, r.name);
        var key_in_map = false;
        errdefer if (!key_in_map) self.scratch_alloc.free(key);
        try map.put(self.scratch_alloc, key, id);
        key_in_map = true;
        errdefer {
            if (map.fetchRemove(key)) |kv| self.scratch_alloc.free(kv.key);
        }
        const ast_alloc = self.astAllocator();
        try self.rules.append(ast_alloc, try dupeRule(ast_alloc, r));
        return id;
    }

    pub fn addRuleNamed(self: *GrammarBuilder, name: []const u8, body_expr_id: i32) Allocator.Error!i32 {
        return self.addRule(Rule.init(name, body_expr_id));
    }

    pub fn addRuleWithHint(self: *GrammarBuilder, name_hint: []const u8, body_expr_id: i32) Allocator.Error!i32 {
        const name = try self.getNewRuleName(name_hint);
        return self.addRule(Rule.init(name, body_expr_id));
    }

    pub fn addEmptyRule(self: *GrammarBuilder, name: []const u8) Allocator.Error!i32 {
        return self.addRule(Rule.empty(name));
    }

    pub fn addEmptyRuleWithHint(self: *GrammarBuilder, name_hint: []const u8) Allocator.Error!i32 {
        const name = try self.getNewRuleName(name_hint);
        return self.addRule(Rule.empty(name));
    }

    pub fn updateRuleBody(self: *GrammarBuilder, rule_id: i32, body_expr_id: i32) void {
        self.rules.items[@intCast(rule_id)].body_expr_id = body_expr_id;
    }

    pub fn updateRuleBodyByName(self: *GrammarBuilder, name: []const u8, body_expr_id: i32) Allocator.Error!void {
        const id = try self.getRuleId(name);
        std.debug.assert(id != NO_EXPR);
        self.updateRuleBody(id, body_expr_id);
    }

    pub fn updateLookaheadAssertionByName(self: *GrammarBuilder, name: []const u8, lookahead_assertion_id: i32) Allocator.Error!void {
        const id = try self.getRuleId(name);
        std.debug.assert(id != NO_EXPR);
        self.updateLookaheadAssertion(id, lookahead_assertion_id);
    }

    pub fn updateLookaheadAssertion(self: *GrammarBuilder, rule_id: i32, lookahead_assertion_id: i32) void {
        self.rules.items[@intCast(rule_id)].lookahead_assertion_id = lookahead_assertion_id;
    }

    pub fn updateLookaheadExact(self: *GrammarBuilder, rule_id: i32, is_exact: bool) void {
        self.rules.items[@intCast(rule_id)].is_exact_lookahead = is_exact;
    }

    pub fn updateMaxTokens(self: *GrammarBuilder, rule_id: i32, max_tokens: i32) void {
        self.rules.items[@intCast(rule_id)].max_tokens = max_tokens;
    }

    pub fn updateMaxChars(self: *GrammarBuilder, rule_id: i32, max_chars: i32) void {
        self.rules.items[@intCast(rule_id)].max_chars = max_chars;
    }

    pub fn updateCaptureName(self: *GrammarBuilder, rule_id: i32, capture_name: []const u8) Allocator.Error!void {
        self.rules.items[@intCast(rule_id)].capture_name = try self.astAllocator().dupe(u8, capture_name);
    }

    pub fn updateLazy(self: *GrammarBuilder, rule_id: i32, is_lazy: bool) void {
        self.rules.items[@intCast(rule_id)].is_lazy = is_lazy;
    }

    pub fn updateRuleTemperature(self: *GrammarBuilder, rule_id: i32, temperature: ?f32) void {
        self.rules.items[@intCast(rule_id)].temperature = temperature;
    }

    pub fn copyRuleAttributes(
        self: *GrammarBuilder,
        rule_id: i32,
        source: *const Grammar,
        source_rule_id: i32,
        map_rule_id: anytype,
    ) Allocator.Error!void {
        const r = source.rule(source_rule_id);
        self.updateMaxTokens(rule_id, r.max_tokens);
        self.updateMaxChars(rule_id, r.max_chars);
        try self.updateCaptureName(rule_id, r.capture_name);
        if (source.suffixStopInfo(source_rule_id)) |info_src| {
            var info = info_src.*;
            if (info.body_rule_id >= 0) {
                const MapT = @TypeOf(map_rule_id);
                const apply_map = struct {
                    inline fn call(m: MapT, id: i32) i32 {
                        return if (@typeInfo(MapT) == .@"struct" and @hasDecl(MapT, "call")) m.call(id) else m(id);
                    }
                }.call;
                info.body_rule_id = apply_map(map_rule_id, info.body_rule_id);
                info.marker_rule_id = apply_map(map_rule_id, info.marker_rule_id);
            }
            try self.updateSuffixStopInfo(rule_id, info);
        }
        self.updateLazy(rule_id, r.is_lazy);
        self.updateRuleTemperature(rule_id, r.temperature);
    }

    pub fn updateSuffixStopInfo(
        self: *GrammarBuilder,
        rule_id: i32,
        info_in: SuffixStopInfo,
    ) Allocator.Error!void {
        var info = info_in;
        const rule_count = self.numRules();
        std.debug.assert(rule_id >= 0 and rule_id < rule_count);
        std.debug.assert(info.hidden_suffix_bytes >= 0 and info.hidden_stop_bytes >= 0);
        std.debug.assert((info.body_rule_id == -1 and info.marker_rule_id == -1) or
            (info.body_rule_id >= 0 and info.body_rule_id < rule_count and
                info.marker_rule_id >= 0 and info.marker_rule_id < rule_count));
        const position = searchByRuleId(self.suffix_stop_infos.items, rule_id);
        if (info.isEmpty()) {
            if (position.found) {
                _ = self.suffix_stop_infos.orderedRemove(position.index);
            }
            return;
        }
        info.rule_id = rule_id;
        const ast_alloc = self.astAllocator();
        const stored = try dupeSuffixStopInfo(ast_alloc, info);
        if (position.found) {
            self.suffix_stop_infos.items[position.index] = stored;
        } else {
            try self.suffix_stop_infos.insert(ast_alloc, position.index, stored);
        }
    }

    pub fn numRules(self: *const GrammarBuilder) i32 {
        return @intCast(self.rules.items.len);
    }

    pub fn getRule(self: *const GrammarBuilder, rule_id: i32) *const Rule {
        return &self.rules.items[@intCast(rule_id)];
    }

    pub fn getRuleId(self: *GrammarBuilder, name: []const u8) Allocator.Error!i32 {
        const map = try self.ruleNameToIdMap();
        return map.get(name) orelse NO_EXPR;
    }

    pub fn getNewRuleName(
        self: *GrammarBuilder,
        name_hint: []const u8,
    ) Allocator.Error![]const u8 {
        const map = try self.ruleNameToIdMap();
        const ast_alloc = self.astAllocator();
        if (!map.contains(name_hint)) return ast_alloc.dupe(u8, name_hint);

        var cnt = self.next_cnt_per_hint.get(name_hint) orelse 0;
        if (cnt < 1) cnt = 1;
        var candidate_buf: std.ArrayList(u8) = .empty;
        defer candidate_buf.deinit(self.scratch_alloc);
        while (true) {
            candidate_buf.clearRetainingCapacity();
            try candidate_buf.print(self.scratch_alloc, "{s}_{d}", .{ name_hint, cnt });
            if (!map.contains(candidate_buf.items)) break;
            cnt += 1;
        }
        const gop = try self.next_cnt_per_hint.getOrPut(self.scratch_alloc, name_hint);
        if (!gop.found_existing) {
            errdefer _ = self.next_cnt_per_hint.remove(name_hint);
            gop.key_ptr.* = try self.scratch_alloc.dupe(u8, name_hint);
        }
        gop.value_ptr.* = cnt;
        return ast_alloc.dupe(u8, candidate_buf.items);
    }
};

test "builder constructs rules, zero-copy intoGrammar, and Diagnostic" {
    const backing = std.testing.allocator;
    var builder = try GrammarBuilder.init(backing);
    defer builder.deinit();

    const bs = try builder.addByteString("hello");
    try std.testing.expectEqual(@as(i32, 0), bs);
    const empty = try builder.addEmptyStr();
    const choices = try builder.addChoices(&.{ bs, empty });
    const seq = try builder.addSequence(&.{ choices, empty });
    try std.testing.expectEqual(@as(i32, 4), builder.numGrammarExprs());

    const root = try builder.addRuleNamed("root", seq);
    const other = try builder.addRuleWithHint("root", empty);
    const another = try builder.addRuleWithHint("root", empty);
    try std.testing.expectEqual(@as(i32, 0), root);
    try std.testing.expectEqualStrings("root_1", builder.getRule(other).name);
    try std.testing.expectEqualStrings("root_2", builder.getRule(another).name);
    try std.testing.expectEqual(@as(i32, 3), builder.numRules());
    try std.testing.expectEqual(@as(i32, 0), try builder.getRuleId("root"));
    try std.testing.expectEqual(NO_EXPR, try builder.getRuleId("missing"));

    const fresh_name = try builder.getNewRuleName("fresh");
    try std.testing.expectEqualStrings("fresh", fresh_name);

    builder.updateRuleBody(other, bs);
    try std.testing.expectEqual(bs, builder.getRule(other).body_expr_id);
    try builder.updateRuleBodyByName("root_2", choices);
    try std.testing.expectEqual(choices, builder.getRule(another).body_expr_id);

    // Zero-copy transfer check: the arena buffer pointers stay identical.
    const original_root_name_ptr = builder.rules.items[0].name.ptr;
    var grammar = try builder.intoGrammar("root", null);
    defer grammar.deinit();
    try std.testing.expectEqual(original_root_name_ptr, grammar.rule(0).name.ptr);
    try std.testing.expectEqualStrings("root", grammar.rootRule().name);
    try std.testing.expectEqual(@as(usize, 3), grammar.numRules());
    try std.testing.expectEqual(@as(usize, 4), grammar.numExprs());

    // Missing root name reports through Diagnostic.
    var builder2 = try GrammarBuilder.init(backing);
    defer builder2.deinit();
    var diag: Diagnostic = .{};
    defer diag.deinit(backing);
    try std.testing.expectError(error.RootRuleNotFound, builder2.intoGrammar("nope", &diag));
    const msg = try diag.formatAlloc(backing);
    defer backing.free(msg);
    try std.testing.expectEqualStrings("Root rule 'nope' not found", msg);
}

test "addRepeatFromExpr, expr adders, suffixStopInfo, fromGrammar, and editInPlace" {
    const backing = std.testing.allocator;
    var builder = try GrammarBuilder.init(backing);
    defer builder.deinit();
    _ = try builder.addRuleNamed("root", NO_EXPR);
    const bs = try builder.addByteString("x");
    const repeat_id = try builder.addRepeatFromExpr("wrap", bs, 1, -1);
    const rep = builder.grammarExpr(repeat_id);
    try std.testing.expectEqual(GrammarExprType.Repeat, rep.ty);
    try std.testing.expectEqual(@as(i32, 1), rep.repeat().rule_id);
    try std.testing.expectEqualStrings("wrap", builder.getRule(1).name);

    const ref = try builder.addRuleRef(0);
    const repeat2 = try builder.addRepeatFromExpr("wrap", ref, 0, 2);
    try std.testing.expectEqual(@as(i32, 0), builder.grammarExpr(repeat2).repeat().rule_id);

    var info = SuffixStopInfo.default();
    info.hidden_suffix_bytes = 2;
    try builder.updateSuffixStopInfo(1, info);
    try std.testing.expectEqual(@as(usize, 1), builder.suffix_stop_infos.items.len);

    var grammar = try builder.intoGrammarWithRootId(0);
    defer grammar.deinit();

    var seeded = try GrammarBuilder.fromGrammar(&grammar, backing);
    defer seeded.deinit();
    var grammar2 = try seeded.intoGrammarWithRootId(0);
    defer grammar2.deinit();
    try std.testing.expect(grammar.eql(&grammar2));

    // editInPlace uses scratch_alloc for name map and frees it in deinit().
    var editor = GrammarBuilder.editInPlace(&grammar);
    defer editor.deinit();
    const extra2 = try editor.addByteString("e");
    const appended_id = try editor.addRuleNamed("appended", extra2);
    try std.testing.expectEqual(@as(i32, 2), appended_id);
    try std.testing.expectEqual(@as(i32, 2), try editor.getRuleId("appended"));
    editor.updateMaxTokens(appended_id, 7);
    editor.updateMaxChars(appended_id, 21);
    try editor.updateCaptureName(appended_id, "cap");
    editor.updateLazy(appended_id, true);
    editor.updateRuleTemperature(appended_id, 0.5);
    var info_dst = SuffixStopInfo.default();
    info_dst.rule_id = appended_id;
    info_dst.body_rule_id = appended_id;
    info_dst.marker_rule_id = appended_id;
    info_dst.stop_capture_name = "stop_c";
    try editor.updateSuffixStopInfo(appended_id, info_dst);
    editor.editInPlaceCommit(&grammar);
    try std.testing.expectEqual(@as(usize, 3), grammar.numRules());

    // copyRuleAttributes copies scalar attributes and remaps suffix/stop helper ids.
    var target_builder = try GrammarBuilder.init(backing);
    defer target_builder.deinit();
    _ = try target_builder.addEmptyRule("t0");
    _ = try target_builder.addEmptyRule("t1");
    _ = try target_builder.addEmptyRule("t2");
    _ = try target_builder.addEmptyRule("t3");
    try target_builder.copyRuleAttributes(1, &grammar, appended_id, struct {
        fn map(id: i32) i32 {
            return id + 1;
        }
    }.map);
    const copied = target_builder.getRule(1);
    try std.testing.expectEqual(@as(i32, 7), copied.max_tokens);
    try std.testing.expectEqual(@as(i32, 21), copied.max_chars);
    try std.testing.expectEqualStrings("cap", copied.capture_name);
    try std.testing.expect(copied.is_lazy);
    try std.testing.expectEqual(@as(?f32, 0.5), copied.temperature);
    const copied_info = target_builder.suffix_stop_infos.items[0];
    try std.testing.expectEqual(@as(i32, 3), copied_info.body_rule_id);
    try std.testing.expectEqual(@as(i32, 3), copied_info.marker_rule_id);
    try std.testing.expectEqualStrings("stop_c", copied_info.stop_capture_name);
}
