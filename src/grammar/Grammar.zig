//! The `Grammar` value handle and BNF AST model (`Rule`, `GrammarExpr`, `GrammarExprType`,
//! `CharacterClassElement`, `SuffixStopInfo`, `DeserializeError`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const Diagnostic = @import("../Diagnostic.zig").Diagnostic;
const support = @import("../support.zig");
const Compact2dArray = support.Compact2dArray;
const Compact2dArrayError = support.Compact2dArrayError;
const fsm_mod = @import("../fsm.zig");
const CompactFsm = fsm_mod.CompactFsm;
const CompactFsmWithStartEndWithSize = fsm_mod.CompactFsmWithStartEndWithSize;

/// Error set for JSON deserialization (payloads go into `Diagnostic`).
pub const DeserializeError = error{
    InvalidJson,
    Version,
    Format,
};

/// Sentinel id meaning "no expression / no lookahead assertion".
pub const NO_EXPR: i32 = -1;

/// An inclusive `[lower, upper]` codepoint range within a character class.
pub const CharacterClassElement = struct {
    lower: i32,
    upper: i32,

    pub fn init(lower: i32, upper: i32) CharacterClassElement {
        return .{ .lower = lower, .upper = upper };
    }

    pub fn contains(self: CharacterClassElement, codepoint: i32) bool {
        return self.lower <= codepoint and codepoint <= self.upper;
    }

    pub fn eql(a: CharacterClassElement, b: CharacterClassElement) bool {
        return a.lower == b.lower and a.upper == b.upper;
    }
};

pub const UnknownGrammarExprType = error{UnknownGrammarExprType};

/// The discriminant for a grammar expression and the data layout of each kind.
pub const GrammarExprType = enum(i32) {
    /// A string of bytes (0–255). Data: `[byte0, byte1, ...]`.
    ByteString = 0,
    /// A range of codepoints. Data: `[is_negative, lower0, upper0, ...]`.
    CharacterClass = 1,
    /// A star quantifier of a character class. Same layout as `CharacterClass`.
    CharacterClassStar = 2,
    /// The empty string `""`. Data: `[]`.
    EmptyStr = 3,
    /// A reference to another rule. Data: `[rule_id]`.
    RuleRef = 4,
    /// A sequence of grammar expressions. Data: `[expr_id0, expr_id1, ...]`.
    Sequence = 5,
    /// A choice of grammar expressions. Data: `[expr_id0, expr_id1, ...]`.
    Choices = 6,
    /// Tag dispatch. Data: `[tag_expr0, rule_id0, ..., loop_after_dispatch, excluded_str_expr_id]`.
    TagDispatch = 7,
    /// Bounded or unbounded repetition. Data: `[rule_id, min_repeat_count, max_repeat_count]`.
    Repeat = 8,
    /// An explicit set of allowed tokens. Data: `[token_id_0, ...]`.
    Token = 9,
    /// An explicit set of excluded tokens. Data: `[token_id_0, ...]`.
    ExcludeToken = 10,
    /// Token-triggered tag dispatch.
    /// Data: `[trigger_cnt, (token_id, rule_id) * N, loop_after_dispatch, exclude_cnt, token_id * M]`.
    TokenTagDispatch = 11,
    /// A regex pattern stored as bytes. Data: `[json_string, byte0, byte1, ...]`.
    Regex = 12,
    /// Every contiguous subsequence of a list of byte-string chunks.
    /// Data: `[chunk0_len, byte0_0, ..., chunk1_len, byte1_0, ...]`.
    Substring = 13,

    pub inline fn asI32(self: GrammarExprType) i32 {
        return @backingInt(self);
    }

    pub fn fromInt(value: i32) UnknownGrammarExprType!GrammarExprType {
        return std.enums.fromInt(GrammarExprType, value) orelse error.UnknownGrammarExprType;
    }
};

/// A read-only view of a grammar expression: its `GrammarExprType` and its `i32` data
/// payload, borrowed from the grammar's flat CSR buffer.
pub const GrammarExpr = struct {
    ty: GrammarExprType,
    data: []const i32,

    pub inline fn len(self: GrammarExpr) usize {
        return self.data.len;
    }

    pub inline fn isEmpty(self: GrammarExpr) bool {
        return self.data.len == 0;
    }

    pub fn byteString(self: GrammarExpr, allocator: Allocator) Allocator.Error![]u8 {
        std.debug.assert(self.ty == .ByteString);
        const out = try allocator.alloc(u8, self.data.len);
        for (self.data, 0..) |b, i| out[i] = @intCast(b);
        return out;
    }

    pub fn ruleRefId(self: GrammarExpr) i32 {
        std.debug.assert(self.ty == .RuleRef);
        return self.data[0];
    }

    pub const CharacterClass = struct {
        is_negative: bool,
        ranges: []CharacterClassElement,
    };

    pub fn characterClass(self: GrammarExpr, allocator: Allocator) Allocator.Error!CharacterClass {
        std.debug.assert(self.ty == .CharacterClass or self.ty == .CharacterClassStar);
        const is_negative = self.data[0] != 0;
        const n = (self.data.len - 1) / 2;
        const ranges = try allocator.alloc(CharacterClassElement, n);
        for (0..n) |i| ranges[i] = CharacterClassElement.init(self.data[1 + 2 * i], self.data[2 + 2 * i]);
        return .{ .is_negative = is_negative, .ranges = ranges };
    }

    pub fn regexPattern(self: GrammarExpr, allocator: Allocator) Allocator.Error![]u8 {
        std.debug.assert(self.ty == .Regex);
        const out = try allocator.alloc(u8, self.data.len - 1);
        for (self.data[1..], 0..) |b, i| out[i] = @intCast(b);
        return out;
    }

    pub fn regexIsJsonString(self: GrammarExpr) bool {
        std.debug.assert(self.ty == .Regex);
        return self.data[0] != 0;
    }

    pub fn substringChunks(self: GrammarExpr, allocator: Allocator) Allocator.Error![][]const u8 {
        std.debug.assert(self.ty == .Substring);
        var chunks: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (chunks.items) |c| allocator.free(c);
            chunks.deinit(allocator);
        }
        var index: usize = 0;
        while (index < self.data.len) {
            const chunk_len: usize = @intCast(self.data[index]);
            index += 1;
            const chunk = try allocator.alloc(u8, chunk_len);
            errdefer allocator.free(chunk);
            for (self.data[index..][0..chunk_len], 0..) |b, i| chunk[i] = @intCast(b);
            try chunks.append(allocator, chunk);
            index += chunk_len;
        }
        return chunks.toOwnedSlice(allocator);
    }

    pub const RepeatSpec = struct {
        rule_id: i32,
        min_repeat: i32,
        max_repeat: i32,
    };

    pub fn repeat(self: GrammarExpr) RepeatSpec {
        std.debug.assert(self.ty == .Repeat);
        return .{ .rule_id = self.data[0], .min_repeat = self.data[1], .max_repeat = self.data[2] };
    }
};

/// A named production rule.
pub const Rule = struct {
    name: []const u8,
    body_expr_id: i32,
    lookahead_assertion_id: i32 = NO_EXPR,
    is_exact_lookahead: bool = false,
    max_tokens: i32 = -1,
    max_chars: i32 = -1,
    capture_name: []const u8 = "",
    is_lazy: bool = false,
    temperature: ?f32 = null,

    pub fn init(name: []const u8, body_expr_id: i32) Rule {
        return .{
            .name = name,
            .body_expr_id = body_expr_id,
        };
    }

    pub fn empty(name: []const u8) Rule {
        return init(name, NO_EXPR);
    }

    pub fn eql(a: Rule, b: Rule) bool {
        return std.mem.eql(u8, a.name, b.name) and a.body_expr_id == b.body_expr_id and
            a.lookahead_assertion_id == b.lookahead_assertion_id and
            a.is_exact_lookahead == b.is_exact_lookahead and a.max_tokens == b.max_tokens and
            a.max_chars == b.max_chars and
            std.mem.eql(u8, a.capture_name, b.capture_name) and a.is_lazy == b.is_lazy and
            temperatureEql(a.temperature, b.temperature);
    }

    fn temperatureEql(a: ?f32, b: ?f32) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return a.? == b.?;
    }
};

/// Sparse per-rule metadata used to materialize suffix and stop captures.
pub const SuffixStopInfo = struct {
    rule_id: i32 = -1,
    hidden_suffix_bytes: i32 = 0,
    hidden_stop_bytes: i32 = 0,
    body_rule_id: i32 = -1,
    marker_rule_id: i32 = -1,
    stop_capture_name: []const u8 = "",

    pub const zero: SuffixStopInfo = .{};

    pub fn default() SuffixStopInfo {
        return .{};
    }

    pub fn isEmpty(self: SuffixStopInfo) bool {
        return self.hidden_suffix_bytes == 0 and self.hidden_stop_bytes == 0 and
            self.body_rule_id == -1 and self.marker_rule_id == -1 and
            self.stop_capture_name.len == 0;
    }

    pub fn eql(a: SuffixStopInfo, b: SuffixStopInfo) bool {
        return a.rule_id == b.rule_id and a.hidden_suffix_bytes == b.hidden_suffix_bytes and
            a.hidden_stop_bytes == b.hidden_stop_bytes and a.body_rule_id == b.body_rule_id and
            a.marker_rule_id == b.marker_rule_id and
            std.mem.eql(u8, a.stop_capture_name, b.stop_capture_name);
    }
};

pub const SearchResult = struct {
    found: bool,
    index: usize,
};

/// Binary search over a `SuffixStopInfo` table sorted by ascending `rule_id`.
pub fn searchByRuleId(items: []const SuffixStopInfo, rule_id: i32) SearchResult {
    var low: usize = 0;
    var high: usize = items.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (items[mid].rule_id < rule_id) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return .{ .found = low < items.len and items[low].rule_id == rule_id, .index = low };
}

/// Per-rule original->normalized state id pair.
pub const FsmStatePair = struct {
    original: i32,
    normalized: i32,
};

/// Storage handles returned by `Grammar.storageMut`.
pub const StorageMut = struct {
    rules: *std.ArrayList(Rule),
    exprs: *Compact2dArray(i32),
    suffix_stop_infos: *std.ArrayList(SuffixStopInfo),
};

/// Deep-copies `rule`'s string fields into `allocator`.
pub fn dupeRule(allocator: Allocator, r: Rule) Allocator.Error!Rule {
    var out = r;
    out.name = try allocator.dupe(u8, r.name);
    out.capture_name = try allocator.dupe(u8, r.capture_name);
    return out;
}

/// Deep-copies `info`'s string field into `allocator`.
pub fn dupeSuffixStopInfo(allocator: Allocator, info: SuffixStopInfo) Allocator.Error!SuffixStopInfo {
    var out = info;
    out.stop_capture_name = try allocator.dupe(u8, info.stop_capture_name);
    return out;
}

/// Heap-allocated backing storage of a `Grammar` handle.
pub const GrammarImpl = struct {
    arena: ArenaAllocator,
    rules: std.ArrayList(Rule),
    suffix_stop_infos: std.ArrayList(SuffixStopInfo),
    exprs: Compact2dArray(i32),
    root_rule_id: i32,
    complete_fsm: CompactFsm,
    per_rule_fsms: std.ArrayList(?CompactFsmWithStartEndWithSize),
    per_rule_fsm_hashes: std.ArrayList(?u64),
    per_rule_fsm_new_state_ids: std.ArrayList([]const FsmStatePair),
    allow_empty_rule_ids: std.ArrayList(i32),
    optimized: bool,
};

/// Value handle to a BNF grammar AST stored in flat CSR form.
///
/// The grammar owns an internal `ArenaAllocator` for AST data plus refcounted FSM handles
/// backed by `arena.child_allocator`. Call `deinit()` when done.
pub const Grammar = struct {
    impl: *GrammarImpl,

    /// Transfers ownership of an already-populated `arena`, `rules`, `exprs`, and
    /// `suffix_stop_infos` into a new `Grammar` with zero AST copying.
    /// If allocation fails, `arena` and the passed collections remain untouched (caller keeps ownership).
    pub fn initFromArena(
        arena: ArenaAllocator,
        rules: std.ArrayList(Rule),
        exprs: Compact2dArray(i32),
        suffix_stop_infos: std.ArrayList(SuffixStopInfo),
        root_rule_id: i32,
    ) Allocator.Error!Grammar {
        const backing = arena.child_allocator;
        var complete_fsm = try CompactFsm.empty(backing);
        errdefer complete_fsm.deinit();
        const impl = try backing.create(GrammarImpl);
        impl.* = .{
            .arena = arena,
            .rules = rules,
            .suffix_stop_infos = suffix_stop_infos,
            .exprs = exprs,
            .root_rule_id = root_rule_id,
            .complete_fsm = complete_fsm,
            .per_rule_fsms = .empty,
            .per_rule_fsm_hashes = .empty,
            .per_rule_fsm_new_state_ids = .empty,
            .allow_empty_rule_ids = .empty,
            .optimized = false,
        };
        return .{ .impl = impl };
    }

    /// Releases everything the grammar owns.
    pub fn deinit(self: *Grammar) void {
        self.impl.complete_fsm.deinit();
        for (self.impl.per_rule_fsms.items) |*maybe| {
            if (maybe.*) |*view| view.deinit();
        }
        const backing = self.impl.arena.child_allocator;
        self.impl.arena.deinit();
        backing.destroy(self.impl);
        self.* = undefined;
    }

    /// Assembles a grammar by deep-copying `rules` and `exprs` into a fresh arena backed by `backing`.
    pub fn fromParts(
        backing: Allocator,
        rules: []const Rule,
        exprs: *const Compact2dArray(i32),
        root_rule_id: i32,
    ) (Compact2dArrayError || Allocator.Error)!Grammar {
        var arena = ArenaAllocator.init(backing);
        errdefer arena.deinit();
        const g = arena.allocator();

        var rules_list: std.ArrayList(Rule) = .empty;
        try rules_list.ensureTotalCapacity(g, rules.len);
        for (rules) |r| rules_list.appendAssumeCapacity(try dupeRule(g, r));

        const exprs_copy = try Compact2dArray(i32).initFromDataAndIndptr(
            g,
            exprs.dataSlice(),
            exprs.indptrSlice(),
        );
        return try initFromArena(arena, rules_list, exprs_copy, .empty, root_rule_id);
    }

    /// Deep-copies the AST into a fresh arena backed by `backing`, while sharing refcounted FSM storage.
    pub fn dupe(self: *const Grammar, backing: Allocator) (Compact2dArrayError || Allocator.Error)!Grammar {
        var out = try fromParts(backing, self.impl.rules.items, &self.impl.exprs, self.impl.root_rule_id);
        errdefer out.deinit();
        const g = out.impl.arena.allocator();

        out.impl.complete_fsm.deinit();
        out.impl.complete_fsm = self.impl.complete_fsm.retain();

        try out.impl.per_rule_fsms.ensureTotalCapacity(g, self.impl.per_rule_fsms.items.len);
        for (self.impl.per_rule_fsms.items) |maybe| {
            if (maybe) |view| {
                out.impl.per_rule_fsms.appendAssumeCapacity(try view.cloneWithShared(backing));
            } else {
                out.impl.per_rule_fsms.appendAssumeCapacity(null);
            }
        }

        try out.impl.suffix_stop_infos.ensureTotalCapacity(g, self.impl.suffix_stop_infos.items.len);
        for (self.impl.suffix_stop_infos.items) |info| {
            out.impl.suffix_stop_infos.appendAssumeCapacity(try dupeSuffixStopInfo(g, info));
        }
        try out.impl.per_rule_fsm_hashes.appendSlice(g, self.impl.per_rule_fsm_hashes.items);
        try out.impl.per_rule_fsm_new_state_ids.ensureTotalCapacity(g, self.impl.per_rule_fsm_new_state_ids.items.len);
        for (self.impl.per_rule_fsm_new_state_ids.items) |pairs| {
            out.impl.per_rule_fsm_new_state_ids.appendAssumeCapacity(try g.dupe(FsmStatePair, pairs));
        }
        try out.impl.allow_empty_rule_ids.appendSlice(g, self.impl.allow_empty_rule_ids.items);
        out.impl.optimized = self.impl.optimized;
        return out;
    }

    /// Structural equality across AST, metadata, and FSMs.
    pub fn eql(a: *const Grammar, b: *const Grammar) bool {
        const ia = a.impl;
        const ib = b.impl;
        if (ia.root_rule_id != ib.root_rule_id or ia.optimized != ib.optimized) return false;
        if (ia.rules.items.len != ib.rules.items.len) return false;
        for (ia.rules.items, ib.rules.items) |x, y| if (!x.eql(y)) return false;
        if (!ia.complete_fsm.eql(ib.complete_fsm)) return false;
        if (ia.per_rule_fsms.items.len != ib.per_rule_fsms.items.len) return false;
        for (ia.per_rule_fsms.items, ib.per_rule_fsms.items) |x, y| {
            if (x == null and y == null) continue;
            if (x == null or y == null) return false;
            const vx = x.?;
            const vy = y.?;
            if (!vx.compact().eql(vy.compact())) return false;
            if (vx.startState() != vy.startState() or vx.isDfa() != vy.isDfa()) return false;
            if (!std.mem.eql(i32, vx.ends(), vy.ends())) return false;
            if (vx.edge_num != vy.edge_num or vx.node_num != vy.node_num) return false;
        }
        if (ia.suffix_stop_infos.items.len != ib.suffix_stop_infos.items.len) return false;
        for (ia.suffix_stop_infos.items, ib.suffix_stop_infos.items) |x, y| if (!x.eql(y)) return false;
        if (!exprsEql(&ia.exprs, &ib.exprs)) return false;
        if (ia.per_rule_fsm_hashes.items.len != ib.per_rule_fsm_hashes.items.len) return false;
        for (ia.per_rule_fsm_hashes.items, ib.per_rule_fsm_hashes.items) |x, y| {
            if (x == null and y == null) continue;
            if (x == null or y == null or x.? != y.?) return false;
        }
        if (ia.per_rule_fsm_new_state_ids.items.len != ib.per_rule_fsm_new_state_ids.items.len) return false;
        for (ia.per_rule_fsm_new_state_ids.items, ib.per_rule_fsm_new_state_ids.items) |x, y| {
            if (x.len != y.len) return false;
            for (x, y) |p, q| if (p.original != q.original or p.normalized != q.normalized) return false;
        }
        if (!std.mem.eql(i32, ia.allow_empty_rule_ids.items, ib.allow_empty_rule_ids.items)) return false;
        return true;
    }

    fn exprsEql(a: *const Compact2dArray(i32), b: *const Compact2dArray(i32)) bool {
        if (a.len() != b.len()) return false;
        for (0..a.len()) |i| {
            if (!std.mem.eql(i32, a.row(i), b.row(i))) return false;
        }
        return true;
    }

    // --- Convenience accessors ---

    pub inline fn numRules(self: *const Grammar) usize {
        return self.impl.rules.items.len;
    }

    pub inline fn numExprs(self: *const Grammar) usize {
        return self.impl.exprs.len();
    }

    pub inline fn rulesSlice(self: *const Grammar) []const Rule {
        return self.impl.rules.items;
    }

    pub inline fn suffixStopInfosSlice(self: *const Grammar) []const SuffixStopInfo {
        return self.impl.suffix_stop_infos.items;
    }

    pub inline fn allowEmptyRuleIdsSlice(self: *const Grammar) []const i32 {
        return self.impl.allow_empty_rule_ids.items;
    }

    pub inline fn rootRuleId(self: *const Grammar) i32 {
        return self.impl.root_rule_id;
    }

    pub inline fn exprsPtr(self: *const Grammar) *const Compact2dArray(i32) {
        return &self.impl.exprs;
    }

    pub inline fn completeFsm(self: *const Grammar) CompactFsm {
        return self.impl.complete_fsm;
    }

    pub inline fn rule(self: *const Grammar, rule_id: i32) *const Rule {
        return &self.impl.rules.items[@intCast(rule_id)];
    }

    pub inline fn ruleMut(self: *Grammar, rule_id: i32) *Rule {
        return &self.impl.rules.items[@intCast(rule_id)];
    }

    pub inline fn rootRule(self: *const Grammar) *const Rule {
        return self.rule(self.impl.root_rule_id);
    }

    pub fn expr(self: *const Grammar, expr_id: i32) GrammarExpr {
        const row = self.impl.exprs.row(@intCast(expr_id));
        const ty = GrammarExprType.fromInt(row[0]) catch unreachable;
        return .{ .ty = ty, .data = row[1..] };
    }

    pub fn byteString(self: *const Grammar, allocator: Allocator, expr_id: i32) Allocator.Error![]u8 {
        return self.expr(expr_id).byteString(allocator);
    }

    pub fn setExprData(self: *Grammar, expr_id: i32, index: usize, value: i32) void {
        self.impl.exprs.rowMut(@intCast(expr_id))[1 + index] = value;
    }

    pub fn renameRule(self: *Grammar, rule_id: i32, new_name: []const u8) Allocator.Error!void {
        self.impl.rules.items[@intCast(rule_id)].name = try self.impl.arena.allocator().dupe(u8, new_name);
    }

    pub fn suffixStopInfo(self: *const Grammar, rule_id: i32) ?*const SuffixStopInfo {
        const res = searchByRuleId(self.impl.suffix_stop_infos.items, rule_id);
        return if (res.found) &self.impl.suffix_stop_infos.items[res.index] else null;
    }

    pub fn setSuffixStopInfos(self: *Grammar, infos: []const SuffixStopInfo) Allocator.Error!void {
        const g = self.impl.arena.allocator();
        self.impl.suffix_stop_infos.clearRetainingCapacity();
        try self.impl.suffix_stop_infos.ensureTotalCapacity(g, infos.len);
        for (infos) |info| self.impl.suffix_stop_infos.appendAssumeCapacity(try dupeSuffixStopInfo(g, info));
    }

    pub inline fn isOptimized(self: *const Grammar) bool {
        return self.impl.optimized;
    }

    pub inline fn setOptimized(self: *Grammar, optimized: bool) void {
        self.impl.optimized = optimized;
    }

    pub fn setAllowEmptyRuleIds(self: *Grammar, ids: []const i32) Allocator.Error!void {
        const g = self.impl.arena.allocator();
        self.impl.allow_empty_rule_ids.clearRetainingCapacity();
        try self.impl.allow_empty_rule_ids.appendSlice(g, ids);
    }

    pub fn perRuleFsmHash(self: *const Grammar, rule_id: i32) ?u64 {
        const idx: usize = @intCast(rule_id);
        if (idx >= self.impl.per_rule_fsm_hashes.items.len) return null;
        return self.impl.per_rule_fsm_hashes.items[idx];
    }

    pub fn fsmNewStateIds(self: *const Grammar, rule_id: i32) []const FsmStatePair {
        const idx: usize = @intCast(rule_id);
        if (idx >= self.impl.per_rule_fsm_new_state_ids.items.len) return &.{};
        return self.impl.per_rule_fsm_new_state_ids.items[idx];
    }

    pub fn setFsmHashData(
        self: *Grammar,
        hashes: []const ?u64,
        new_state_ids: []const []const FsmStatePair,
    ) Allocator.Error!void {
        const g = self.impl.arena.allocator();
        self.impl.per_rule_fsm_hashes.clearRetainingCapacity();
        try self.impl.per_rule_fsm_hashes.appendSlice(g, hashes);
        self.impl.per_rule_fsm_new_state_ids.clearRetainingCapacity();
        try self.impl.per_rule_fsm_new_state_ids.ensureTotalCapacity(g, new_state_ids.len);
        for (new_state_ids) |pairs| {
            self.impl.per_rule_fsm_new_state_ids.appendAssumeCapacity(try g.dupe(FsmStatePair, pairs));
        }
    }

    pub fn perRuleFsm(self: *const Grammar, rule_id: i32) ?*const CompactFsmWithStartEndWithSize {
        const idx: usize = @intCast(rule_id);
        if (idx >= self.impl.per_rule_fsms.items.len) return null;
        return if (self.impl.per_rule_fsms.items[idx]) |*view| view else null;
    }

    pub fn perRuleFsmsSlice(self: *const Grammar) []const ?CompactFsmWithStartEndWithSize {
        return self.impl.per_rule_fsms.items;
    }

    /// Installs the compiled FSMs, properly releasing every prior view in `per_rule_fsms`
    /// and the previous `complete_fsm` before replacing them.
    pub fn setFsms(
        self: *Grammar,
        complete_fsm: CompactFsm,
        per_rule_fsms: []const ?CompactFsmWithStartEndWithSize,
    ) Allocator.Error!void {
        const g = self.impl.arena.allocator();
        const backing = self.impl.arena.child_allocator;
        var next_views: std.ArrayList(?CompactFsmWithStartEndWithSize) = .empty;
        errdefer {
            for (next_views.items) |*maybe| {
                if (maybe.*) |*view| view.deinit();
            }
        }
        try next_views.ensureTotalCapacity(g, per_rule_fsms.len);
        for (per_rule_fsms) |maybe| {
            if (maybe) |view| {
                next_views.appendAssumeCapacity(try view.cloneWithShared(backing));
            } else {
                next_views.appendAssumeCapacity(null);
            }
        }
        for (self.impl.per_rule_fsms.items) |*maybe| {
            if (maybe.*) |*view| view.deinit();
        }
        self.impl.per_rule_fsms.deinit(g);
        self.impl.per_rule_fsms = next_views;
        self.impl.complete_fsm.deinit();
        self.impl.complete_fsm = complete_fsm.retain();
    }

    pub fn fsmStateOffsets(self: *const Grammar, allocator: Allocator) Allocator.Error!std.ArrayList(usize) {
        const Storage = struct { fsm: CompactFsm, offset: usize };
        var storage: std.ArrayList(Storage) = .empty;
        defer storage.deinit(allocator);
        try storage.append(allocator, .{ .fsm = self.impl.complete_fsm, .offset = 0 });
        var next_offset: usize = @intCast(self.impl.complete_fsm.numStates());
        var offsets: std.ArrayList(usize) = .empty;
        errdefer offsets.deinit(allocator);
        for (self.impl.per_rule_fsms.items) |maybe| {
            const view = maybe orelse {
                try offsets.append(allocator, 0);
                continue;
            };
            const fsm = view.compact();
            var offset: ?usize = null;
            for (storage.items) |entry| {
                if (fsm.sharesStorage(entry.fsm)) {
                    offset = entry.offset;
                    break;
                }
            }
            if (offset == null) {
                offset = next_offset;
                next_offset += @intCast(fsm.numStates());
                try storage.append(allocator, .{ .fsm = fsm, .offset = offset.? });
            }
            try offsets.append(allocator, offset.?);
        }
        return offsets;
    }

    pub fn storageMut(self: *Grammar) StorageMut {
        return .{
            .rules = &self.impl.rules,
            .exprs = &self.impl.exprs,
            .suffix_stop_infos = &self.impl.suffix_stop_infos,
        };
    }

    // --- Printing & JSON serialization ---

    pub fn toStringEbnf(self: *const Grammar, allocator: Allocator) Allocator.Error![]u8 {
        return @import("printer.zig").toStringEbnf(self, allocator);
    }

    /// Streams EBNF directly into `writer` with zero heap allocation.
    pub fn format(self: Grammar, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        return @import("printer.zig").writeEbnf(&self, writer);
    }

    pub fn serializeJson(self: *const Grammar, allocator: Allocator) Allocator.Error![]u8 {
        return @import("serialization.zig").serializeJson(self, allocator);
    }

    pub fn writeJson(self: *const Grammar, jw: *std.json.Stringify) std.json.Stringify.Error!void {
        return @import("serialization.zig").writeJson(self, jw);
    }

    pub fn writeJsonEmbedded(self: *const Grammar, jw: *std.json.Stringify) std.json.Stringify.Error!void {
        return @import("serialization.zig").writeJsonEmbedded(self, jw);
    }

    pub fn deserializeJson(
        backing: Allocator,
        json_str: []const u8,
        diag: ?*Diagnostic,
    ) (DeserializeError || Compact2dArrayError || Allocator.Error)!Grammar {
        return @import("serialization.zig").deserializeJson(backing, json_str, diag);
    }

    // --- High-level static constructors ---

    pub const EbnfOptions = struct {
        root_rule_name: []const u8 = "root",
        diag: ?*Diagnostic = null,
    };

    pub const LarkOptions = struct {
        tokenizer_info: ?*const @import("../tokenizer.zig").TokenizerInfo = null,
        named_grammars: []const @import("../converter.zig").NamedGrammar = &.{},
        diag: ?*Diagnostic = null,
    };

    pub fn fromEbnf(
        allocator: Allocator,
        ebnf_str: []const u8,
        options: EbnfOptions,
    ) !Grammar {
        return @import("../functor.zig").fromEbnf(allocator, ebnf_str, options.root_rule_name, options.diag);
    }

    pub fn builtinJson(allocator: Allocator) Allocator.Error!Grammar {
        return @import("../functor.zig").builtinJsonGrammar(allocator);
    }

    pub fn fromJsonSchema(
        allocator: Allocator,
        schema: []const u8,
        options: @import("../converter.zig").JsonSchemaOptions,
    ) !Grammar {
        return @import("../converter.zig").fromJsonSchema(allocator, schema, options);
    }

    pub fn fromRegex(
        allocator: Allocator,
        regex_str: []const u8,
        diag: ?*Diagnostic,
    ) !Grammar {
        return @import("../converter.zig").fromRegex(allocator, regex_str, diag);
    }

    pub fn fromLark(
        allocator: Allocator,
        lark_str: []const u8,
        options: LarkOptions,
    ) !Grammar {
        return @import("../converter.zig").fromLark(
            allocator,
            lark_str,
            options.tokenizer_info,
            options.named_grammars,
            options.diag,
        );
    }

    pub fn fromStructuralTag(
        allocator: Allocator,
        json: []const u8,
        diag: ?*Diagnostic,
    ) !Grammar {
        return @import("../converter.zig").fromStructuralTag(allocator, json, diag);
    }

    pub fn fromStructuralTagWithTokenizer(
        allocator: Allocator,
        json: []const u8,
        tokenizer_info: *const @import("../tokenizer.zig").TokenizerInfo,
        diag: ?*Diagnostic,
    ) !Grammar {
        return @import("../converter.zig").fromStructuralTagWithTokenizer(allocator, json, tokenizer_info, diag);
    }

    pub fn unionOf(allocator: Allocator, grammars: []const Grammar) Allocator.Error!Grammar {
        return @import("../functor.zig").unionOf(allocator, grammars);
    }

    pub fn concatOf(allocator: Allocator, grammars: []const Grammar) Allocator.Error!Grammar {
        return @import("../functor.zig").concatOf(allocator, grammars);
    }
};

test "expr type, rule, suffix stop info, and grammar accessors" {
    const backing = std.testing.allocator;

    const all_types = [_]GrammarExprType{
        .ByteString, .CharacterClass, .CharacterClassStar, .EmptyStr,
        .RuleRef,    .Sequence,       .Choices,            .TagDispatch,
        .Repeat,     .Token,          .ExcludeToken,       .TokenTagDispatch,
        .Regex,      .Substring,
    };
    for (all_types, 0..) |ty, i| {
        try std.testing.expectEqual(@as(i32, @intCast(i)), ty.asI32());
        try std.testing.expectEqual(ty, try GrammarExprType.fromInt(ty.asI32()));
    }
    try std.testing.expectError(error.UnknownGrammarExprType, GrammarExprType.fromInt(14));
    try std.testing.expectError(error.UnknownGrammarExprType, GrammarExprType.fromInt(-1));

    var exprs = try Compact2dArray(i32).init(backing);
    defer exprs.deinit(backing);
    _ = try exprs.pushRowNoncontiguous(backing, GrammarExprType.ByteString.asI32(), &.{ 97, 98 });
    _ = try exprs.pushRowNoncontiguous(backing, GrammarExprType.EmptyStr.asI32(), &.{});
    const rules = [_]Rule{ Rule.init("a", 0), Rule.init("b", 1) };

    var grammar = try Grammar.fromParts(backing, &rules, &exprs, 0);
    defer grammar.deinit();
    try std.testing.expectEqual(@as(usize, 2), grammar.numRules());
    try std.testing.expectEqual(@as(usize, 2), grammar.numExprs());
    try std.testing.expectEqualStrings("a", grammar.rootRule().name);
    const bs = try grammar.byteString(backing, 0);
    defer backing.free(bs);
    try std.testing.expectEqualStrings("ab", bs);

    var cloned = try grammar.dupe(backing);
    defer cloned.deinit();
    try std.testing.expect(grammar.eql(&cloned));
    cloned.setExprData(0, 1, 122);
    try std.testing.expect(!grammar.eql(&cloned));
}

test "setFsms repeated replacement frees old views with zero leaks" {
    const backing = std.testing.allocator;
    const Fsm = fsm_mod.Fsm;
    const CompactFsmWithStartEnd = fsm_mod.CompactFsmWithStartEnd;

    var fsm = try Fsm.init(backing, 3);
    defer fsm.deinit();
    try fsm.addEdge(0, 1, 'a', 'a');
    try fsm.addEdge(1, 2, 'b', 'b');
    var complete = try CompactFsm.fromFsm(backing, &fsm);
    defer complete.deinit();

    var exprs = try Compact2dArray(i32).init(backing);
    defer exprs.deinit(backing);
    _ = try exprs.pushRowNoncontiguous(backing, GrammarExprType.EmptyStr.asI32(), &.{});
    const rules = [_]Rule{Rule.init("r0", 0)};
    var grammar = try Grammar.fromParts(backing, &rules, &exprs, 0);
    defer grammar.deinit();

    var view0 = try CompactFsmWithStartEnd.init(backing, complete.retain(), 0, &.{2}, false);
    defer view0.deinit();
    var sized0 = CompactFsmWithStartEndWithSize.init(try view0.cloneWithShared(backing), 2, 3);
    defer sized0.deinit();

    try grammar.setFsms(complete, &.{sized0});
    // Replace a second time — must deinit old per_rule_fsms views cleanly.
    try grammar.setFsms(complete, &.{sized0});
    grammar.setOptimized(true);
    try std.testing.expect(grammar.perRuleFsm(0).?.sharesStorage(complete));
}
