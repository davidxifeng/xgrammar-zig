//! The `Grammar` type: the BNF abstract syntax tree (AST) in flat CSR form
//! (`grammar.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const rule_mod = @import("rule.zig");
const Rule = rule_mod.Rule;
const NO_EXPR = rule_mod.NO_EXPR;
const suffix_stop_info_mod = @import("suffix_stop_info.zig");
const SuffixStopInfo = suffix_stop_info_mod.SuffixStopInfo;
const grammar_expr_mod = @import("grammar_expr.zig");
const GrammarExpr = grammar_expr_mod.GrammarExpr;
const grammar_expr_type = @import("grammar_expr_type.zig");
const GrammarExprType = grammar_expr_type.GrammarExprType;
const support = @import("../support/mod.zig");
const Compact2dArray = support.Compact2dArray;
const Compact2dArrayError = support.Compact2dArrayError;

/// Per-rule original→normalized state id pair (Rust tuple `(i32, i32)`).
pub const FsmStatePair = struct {
    original: i32,
    normalized: i32,
};

/// Storage handles returned by `storage_mut` (Rust tuple of three `&mut`s).
pub const StorageMut = struct {
    rules: *std.ArrayList(Rule),
    exprs: *Compact2dArray(i32),
    suffix_stop_infos: *std.ArrayList(SuffixStopInfo),
};

/// Deep-copies `rule`'s string fields into `gpa`.
pub fn dupe_rule(gpa: Allocator, rule: Rule) Allocator.Error!Rule {
    var out = rule;
    out.name = try gpa.dupe(u8, rule.name);
    out.capture_name = try gpa.dupe(u8, rule.capture_name);
    return out;
}

/// Deep-copies `info`'s string field into `gpa`.
pub fn dupe_suffix_stop_info(gpa: Allocator, info: SuffixStopInfo) Allocator.Error!SuffixStopInfo {
    var out = info;
    out.stop_capture_name = try gpa.dupe(u8, info.stop_capture_name);
    return out;
}

/// Stores the abstract syntax tree (AST) of a Backus–Naur Form (BNF) grammar.
///
/// The BNF definition is standard BNF; characters are represented using regex-style
/// character classes (e.g. `[a-z]`, `[^a-z]`). Rules and `GrammarExpr`s are stored in
/// CSR-matrix style: each expression occupies one row of `exprs`, laid out as
/// `[type_tag, data...]`.
///
/// The grammar owns an arena: every node, container, and string lives in it, and
/// `deinit` releases everything at once.
pub const Grammar = struct {
    arena: *ArenaAllocator,
    rules: std.ArrayList(Rule),
    /// Suffix/stop metadata, sorted by rule id and omitted for ordinary rules.
    suffix_stop_infos: std.ArrayList(SuffixStopInfo),
    exprs: Compact2dArray(i32),
    root_rule_id: i32,
    // fsm wave installs `complete_fsm: CompactFsm` and
    // `per_rule_fsms: ArrayList(?(fsm wave's CompactFsmWithStartEndWithSize))` here
    // (reference grammar.rs lines 44–51); until then the fsm accessors/setters below
    // are the registered unlinked edges.
    /// Per-rule FSM structural hashes (set by the FSM hasher; compile-time only).
    per_rule_fsm_hashes: std.ArrayList(?u64),
    /// Per-rule original→normalized state id pairs (set by the FSM hasher; compile-time only).
    per_rule_fsm_new_state_ids: std.ArrayList([]const FsmStatePair),
    /// Ids of rules that can match the empty string (set by the allow-empty analyzer).
    allow_empty_rule_ids: std.ArrayList(i32),
    /// Whether the grammar optimizer has run (FSMs built).
    optimized: bool,


    fn create(backing: Allocator) Allocator.Error!*Grammar {
        const arena = try backing.create(ArenaAllocator);
        errdefer backing.destroy(arena);
        arena.* = ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const g = try arena.allocator().create(Grammar);
        var exprs = try Compact2dArray(i32).init(arena.allocator());
        errdefer exprs.deinit();
        g.* = .{
            .arena = arena,
            .rules = .empty,
            .suffix_stop_infos = .empty,
            .exprs = exprs,
            .root_rule_id = NO_EXPR,
            .per_rule_fsm_hashes = .empty,
            .per_rule_fsm_new_state_ids = .empty,
            .allow_empty_rule_ids = .empty,
            .optimized = false,
        };
        return g;
    }

    /// Releases everything the grammar owns, including itself.
    pub fn deinit(self: *Grammar) void {
        const arena = self.arena;
        const backing = arena.child_allocator;
        arena.deinit();
        backing.destroy(arena);
    }

    /// Assembles a grammar from its parts (used by `GrammarBuilder`).
    /// Rust moves the inputs; this port copies them into the new grammar's arena.
    pub fn from_parts(
        backing: Allocator,
        rules: []const Rule,
        exprs: *const Compact2dArray(i32),
        root_rule_id: i32,
    ) (Compact2dArrayError || Allocator.Error)!*Grammar {
        const self = try create(backing);
        errdefer self.deinit();
        const g = self.arena.allocator();
        try self.rules.ensureTotalCapacity(g, rules.len);
        for (rules) |r| try self.rules.append(g, try dupe_rule(g, r));
        self.exprs.deinit();
        self.exprs = try Compact2dArray(i32).init_from_data_and_indptr(
            g,
            exprs.data_slice(),
            exprs.indptr_slice(),
        );
        self.root_rule_id = root_rule_id;
        return self;
    }

    /// Rust `Clone`: rebuilds the grammar in a fresh arena owned by the clone.
    pub fn clone(self: *const Grammar, backing: Allocator) (Compact2dArrayError || Allocator.Error)!*Grammar {
        const out = try from_parts(backing, self.rules.items, &self.exprs, self.root_rule_id);
        errdefer out.deinit();
        const g = out.arena.allocator();
        try out.suffix_stop_infos.ensureTotalCapacity(g, self.suffix_stop_infos.items.len);
        for (self.suffix_stop_infos.items) |info|
            try out.suffix_stop_infos.append(g, try dupe_suffix_stop_info(g, info));
        try out.per_rule_fsm_hashes.appendSlice(g, self.per_rule_fsm_hashes.items);
        try out.per_rule_fsm_new_state_ids.ensureTotalCapacity(g, self.per_rule_fsm_new_state_ids.items.len);
        for (self.per_rule_fsm_new_state_ids.items) |pairs|
            try out.per_rule_fsm_new_state_ids.append(g, try g.dupe(FsmStatePair, pairs));
        try out.allow_empty_rule_ids.appendSlice(g, self.allow_empty_rule_ids.items);
        out.optimized = self.optimized;
        return out;
    }

    /// Rust `PartialEq` for the data the grammar owns (fsm members are unlinked this wave).
    pub fn eql(a: *const Grammar, b: *const Grammar) bool {
        if (a.root_rule_id != b.root_rule_id or a.optimized != b.optimized) return false;
        if (a.rules.items.len != b.rules.items.len) return false;
        for (a.rules.items, b.rules.items) |x, y| if (!x.eql(y)) return false;
        if (a.suffix_stop_infos.items.len != b.suffix_stop_infos.items.len) return false;
        for (a.suffix_stop_infos.items, b.suffix_stop_infos.items) |x, y| if (!x.eql(y)) return false;
        if (!exprs_eql(&a.exprs, &b.exprs)) return false;
        if (a.per_rule_fsm_hashes.items.len != b.per_rule_fsm_hashes.items.len) return false;
        for (a.per_rule_fsm_hashes.items, b.per_rule_fsm_hashes.items) |x, y| {
            const both_null = x == null and y == null;
            if (!both_null and (x == null or y == null or x.? != y.?)) return false;
        }
        if (a.per_rule_fsm_new_state_ids.items.len != b.per_rule_fsm_new_state_ids.items.len) return false;
        for (a.per_rule_fsm_new_state_ids.items, b.per_rule_fsm_new_state_ids.items) |x, y| {
            if (x.len != y.len) return false;
            for (x, y) |p, q| if (p.original != q.original or p.normalized != q.normalized) return false;
        }
        if (a.allow_empty_rule_ids.items.len != b.allow_empty_rule_ids.items.len) return false;
        for (a.allow_empty_rule_ids.items, b.allow_empty_rule_ids.items) |x, y| if (x != y) return false;
        return true;
    }

    fn exprs_eql(a: *const Compact2dArray(i32), b: *const Compact2dArray(i32)) bool {
        if (a.len() != b.len()) return false;
        for (0..a.len()) |i| {
            const ra = a.row(i);
            const rb = b.row(i);
            if (ra.len != rb.len) return false;
            for (ra, rb) |x, y| if (x != y) return false;
        }
        return true;
    }

    /// The structural hash of the per-rule FSM for `rule_id`, if computed.
    pub fn per_rule_fsm_hash(self: *const Grammar, rule_id: i32) ?u64 {
        const idx: usize = @intCast(rule_id);
        if (idx >= self.per_rule_fsm_hashes.items.len) return null;
        return self.per_rule_fsm_hashes.items[idx];
    }

    /// Original→normalized state id mapping for `rule_id`'s FSM, if computed
    /// (Rust `per_rule_fsm_new_state_ids`; renamed: the field owns the Rust name).
    pub fn fsm_new_state_ids(self: *const Grammar, rule_id: i32) []const FsmStatePair {
        const idx: usize = @intCast(rule_id);
        if (idx >= self.per_rule_fsm_new_state_ids.items.len) return &.{};
        return self.per_rule_fsm_new_state_ids.items[idx];
    }

    /// Installs per-rule FSM hashes and state-id mappings (used by the FSM hasher).
    /// Rust moves the inputs; this port copies them into the grammar's arena.
    pub fn set_fsm_hash_data(
        self: *Grammar,
        hashes: []const ?u64,
        new_state_ids: []const []const FsmStatePair,
    ) Allocator.Error!void {
        const g = self.arena.allocator();
        self.per_rule_fsm_hashes.clearRetainingCapacity();
        try self.per_rule_fsm_hashes.appendSlice(g, hashes);
        self.per_rule_fsm_new_state_ids.clearRetainingCapacity();
        try self.per_rule_fsm_new_state_ids.ensureTotalCapacity(g, new_state_ids.len);
        for (new_state_ids) |pairs|
            try self.per_rule_fsm_new_state_ids.append(g, try g.dupe(FsmStatePair, pairs));
    }

    /// The ids of rules that can match the empty string (Rust accessor
    /// `allow_empty_rule_ids()` dropped: the field owns the name; use
    /// `.allow_empty_rule_ids.items`).

    /// Whether the grammar optimizer has run.
    pub fn is_optimized(self: *const Grammar) bool {
        return self.optimized;
    }

    /// Sets the empty-rule ids (used by the allow-empty analyzer).
    pub fn set_allow_empty_rule_ids(self: *Grammar, ids: []const i32) Allocator.Error!void {
        const g = self.arena.allocator();
        self.allow_empty_rule_ids.clearRetainingCapacity();
        try self.allow_empty_rule_ids.appendSlice(g, ids);
    }

    /// Marks the grammar as optimized.
    pub fn set_optimized(self: *Grammar, optimized: bool) void {
        self.optimized = optimized;
    }

    /// A mutable reference to a rule (used by in-place passes like the repetition normalizer).
    pub fn rule_mut(self: *Grammar, rule_id: i32) *Rule {
        return &self.rules.items[@intCast(rule_id)];
    }

    /// Overwrites the `index`-th data element of an expression in place.
    pub fn set_expr_data(self: *Grammar, expr_id: i32, index: usize, value: i32) void {
        self.exprs.row_mut(@intCast(expr_id))[1 + index] = value;
    }

    // Rust accessors `rules()`, `exprs()`, `suffix_stop_infos()`, `root_rule_id()` are
    // dropped: Zig fields are public and own the Rust names — read them directly
    // (`.rules.items`, `.exprs`, `.suffix_stop_infos.items`, `.root_rule_id`).

    /// The rules, expression store, and suffix/stop table, for editing the grammar in place
    /// through `GrammarBuilder.edit_in_place`.
    pub fn storage_mut(self: *Grammar) StorageMut {
        return .{
            .rules = &self.rules,
            .exprs = &self.exprs,
            .suffix_stop_infos = &self.suffix_stop_infos,
        };
    }

    /// Number of rules.
    pub fn num_rules(self: *const Grammar) i32 {
        return @intCast(self.rules.items.len);
    }

    /// The rule with the given id.
    pub fn rule(self: *const Grammar, rule_id: i32) *const Rule {
        return &self.rules.items[@intCast(rule_id)];
    }

    /// Renames a rule in place (used by the root-rule renamer pass).
    /// The name is copied into the grammar's arena.
    pub fn rename_rule(self: *Grammar, rule_id: i32, new_name: []const u8) Allocator.Error!void {
        self.rules.items[@intCast(rule_id)].name = try self.arena.allocator().dupe(u8, new_name);
    }

    /// All suffix/stop metadata entries, sorted by rule id (Rust accessor
    /// `suffix_stop_infos()` dropped: the field owns the name).

    /// The suffix/stop metadata of `rule_id`, if any.
    pub fn suffix_stop_info(self: *const Grammar, rule_id: i32) ?*const SuffixStopInfo {
        const res = suffix_stop_info_mod.search_by_rule_id(self.suffix_stop_infos.items, rule_id);
        return if (res.found) &self.suffix_stop_infos.items[res.index] else null;
    }

    /// Replaces the suffix/stop metadata table (entries must be sorted by rule id).
    /// Rust moves the input; this port copies it into the grammar's arena.
    pub fn set_suffix_stop_infos(self: *Grammar, infos: []const SuffixStopInfo) Allocator.Error!void {
        const g = self.arena.allocator();
        self.suffix_stop_infos.clearRetainingCapacity();
        try self.suffix_stop_infos.ensureTotalCapacity(g, infos.len);
        for (infos) |info| try self.suffix_stop_infos.append(g, try dupe_suffix_stop_info(g, info));
    }

    // Rust accessor `root_rule_id()` dropped: the field owns the name.
    /// The root rule.
    pub fn root_rule(self: *const Grammar) *const Rule {
        return self.rule(self.root_rule_id);
    }

    /// Number of grammar expressions.
    pub fn num_exprs(self: *const Grammar) i32 {
        return @intCast(self.exprs.len());
    }

    /// The expression with the given id, as a borrowed view.
    pub fn expr(self: *const Grammar, expr_id: i32) GrammarExpr {
        const row = self.exprs.row(@intCast(expr_id));
        const ty = grammar_expr_type.try_from(row[0]) catch
            unreachable; // grammar stores valid expr type tags
        return .{ .ty = ty, .data = row[1..] };
    }

    /// The byte string of a `GrammarExprType.ByteString` expression (allocated; caller owns).
    pub fn byte_string(self: *const Grammar, allocator: Allocator, expr_id: i32) Allocator.Error![]u8 {
        return self.expr(expr_id).byte_string(allocator);
    }
};

test "grammar from parts, clone and accessors" {
    const backing = std.testing.allocator;
    var builder_arena = ArenaAllocator.init(backing);
    defer builder_arena.deinit();
    const bg = builder_arena.allocator();

    var exprs = try Compact2dArray(i32).init(bg);
    defer exprs.deinit();
    _ = try exprs.push_row_noncontiguous(GrammarExprType.ByteString.as_i32(), &.{ 97, 98 });
    _ = try exprs.push_row_noncontiguous(GrammarExprType.EmptyStr.as_i32(), &.{});
    var rules = [_]Rule{ Rule.new("a", 0), Rule.new("b", 1) };

    const grammar = try Grammar.from_parts(backing, &rules, &exprs, 0);
    defer grammar.deinit();
    try std.testing.expectEqual(@as(i32, 2), grammar.num_rules());
    try std.testing.expectEqual(@as(i32, 2), grammar.num_exprs());
    try std.testing.expectEqualStrings("a", grammar.root_rule().name);
    try std.testing.expect(grammar.rule(1).body_expr_id == 1);
    try std.testing.expect(!grammar.is_optimized());
    try std.testing.expectEqual(@as(usize, 0), grammar.allow_empty_rule_ids.items.len);
    try std.testing.expect(grammar.suffix_stop_info(0) == null);
    {
        const bs = try grammar.byte_string(std.testing.allocator, 0);
        defer std.testing.allocator.free(bs);
        try std.testing.expectEqualStrings("ab", bs);
    }
    const e = grammar.expr(0);
    try std.testing.expectEqual(GrammarExprType.ByteString, e.ty);
    try std.testing.expectEqual(@as(usize, 2), e.len());

    grammar.set_optimized(true);
    try std.testing.expect(grammar.is_optimized());
    grammar.set_optimized(false);

    try grammar.rename_rule(1, "renamed");
    try std.testing.expectEqualStrings("renamed", grammar.rule(1).name);
    grammar.rule_mut(1).body_expr_id = 0;
    try std.testing.expectEqual(@as(i32, 0), grammar.rule(1).body_expr_id);
    grammar.set_expr_data(0, 1, 122);
    try std.testing.expectEqual(@as(i32, 122), grammar.expr(0).data[1]);

    const cloned = try grammar.clone(backing);
    defer cloned.deinit();
    try std.testing.expect(grammar.eql(cloned));
    cloned.set_expr_data(0, 1, 65);
    try std.testing.expect(!grammar.eql(cloned));

    const infos = [_]SuffixStopInfo{blk: {
        var info = SuffixStopInfo.default();
        info.rule_id = 1;
        info.hidden_stop_bytes = 4;
        info.stop_capture_name = "tail";
        break :blk info;
    }};
    try grammar.set_suffix_stop_infos(&infos);
    try std.testing.expect(grammar.suffix_stop_info(0) == null);
    try std.testing.expectEqual(@as(i32, 4), grammar.suffix_stop_info(1).?.hidden_stop_bytes);
    try std.testing.expectEqualStrings("tail", grammar.suffix_stop_info(1).?.stop_capture_name);
    try std.testing.expectEqual(@as(usize, 1), grammar.suffix_stop_infos.items.len);
    const cloned2 = try grammar.clone(backing);
    defer cloned2.deinit();
    try std.testing.expect(grammar.eql(cloned2));

    try grammar.set_allow_empty_rule_ids(&.{ 0, 1 });
    try std.testing.expectEqual(@as(usize, 2), grammar.allow_empty_rule_ids.items.len);

    const hashes = [_]?u64{ null, 42 };
    const pairs = [_]FsmStatePair{.{ .original = 3, .normalized = 1 }};
    const pair_lists = [_][]const FsmStatePair{ &pairs, &.{} };
    try grammar.set_fsm_hash_data(&hashes, &pair_lists);
    try std.testing.expectEqual(@as(u64, 42), grammar.per_rule_fsm_hash(1).?);
    try std.testing.expect(grammar.per_rule_fsm_hash(0) == null);
    try std.testing.expect(grammar.per_rule_fsm_hash(7) == null);
    try std.testing.expectEqual(@as(i32, 3), grammar.fsm_new_state_ids(0)[0].original);
    try std.testing.expectEqual(@as(usize, 0), grammar.fsm_new_state_ids(1).len);
    try std.testing.expectEqual(@as(usize, 0), grammar.fsm_new_state_ids(9).len);
}
