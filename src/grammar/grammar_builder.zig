//! Builder for the BNF AST (`grammar_builder.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const grammar_mod = @import("grammar.zig");
const Grammar = grammar_mod.Grammar;
const dupe_rule = grammar_mod.dupe_rule;
const dupe_suffix_stop_info = grammar_mod.dupe_suffix_stop_info;
const grammar_expr_mod = @import("grammar_expr.zig");
const GrammarExpr = grammar_expr_mod.GrammarExpr;
const grammar_expr_type = @import("grammar_expr_type.zig");
const GrammarExprType = grammar_expr_type.GrammarExprType;
const rule_mod = @import("rule.zig");
const Rule = rule_mod.Rule;
const NO_EXPR = rule_mod.NO_EXPR;
const suffix_stop_info_mod = @import("suffix_stop_info.zig");
const SuffixStopInfo = suffix_stop_info_mod.SuffixStopInfo;
const tag_dispatch_mod = @import("tag_dispatch.zig");
const TagDispatch = tag_dispatch_mod.TagDispatch;
const token_tag_dispatch_mod = @import("token_tag_dispatch.zig");
const TokenTagDispatch = token_tag_dispatch_mod.TokenTagDispatch;
const support = @import("../support/mod.zig");
const Compact2dArray = support.Compact2dArray;
const Compact2dArrayError = support.Compact2dArrayError;

/// Heap arena plus its allocator, shared by the builder constructors.
const ArenaCommon = struct {
    arena: *ArenaAllocator,
    allocator: Allocator,
};

/// Builds a `Grammar` incrementally: add expressions (each returns its id), wire them
/// into rules, then finalize with a root rule.
///
/// The builder owns an arena in standalone mode (`new`/`from_grammar`); in
/// `edit_in_place` mode it borrows the target grammar's storage and allocates from its
/// arena instead. `Rule` names passed in are copied into the active arena.
pub const GrammarBuilder = struct {
    /// The allocator every builder-owned allocation goes through.
    allocator: Allocator,
    /// Non-null in standalone mode; null while editing a grammar in place.
    arena: ?*ArenaAllocator,
    backing: Allocator,
    rules: std.ArrayList(Rule),
    suffix_stop_infos: std.ArrayList(SuffixStopInfo),
    // Each row is `[type_tag, data...]`.
    exprs: Compact2dArray(i32),
    // Built from `rules` on the first name-based operation, so id-only rewriting of an
    // existing grammar pays no name hashing cost (the C++ `EnsureRuleNameMap`).
    rule_name_to_id: ?std.StringHashMap(i32),
    next_cnt_per_hint: std.StringHashMap(i32),

    fn init_common(backing: Allocator) Allocator.Error!ArenaCommon {
        const arena = try backing.create(ArenaAllocator);
        errdefer backing.destroy(arena);
        arena.* = ArenaAllocator.init(backing);
        errdefer arena.deinit();
        return .{ .arena = arena, .allocator = arena.allocator() };
    }

    /// Creates an empty builder.
    pub fn new(backing: Allocator) Allocator.Error!GrammarBuilder {
        const common = try init_common(backing);
        const exprs = try Compact2dArray(i32).init(common.allocator);
        return .{
            .allocator = common.allocator,
            .arena = common.arena,
            .backing = backing,
            .rules = .empty,
            .suffix_stop_infos = .empty,
            .exprs = exprs,
            .rule_name_to_id = null,
            .next_cnt_per_hint = std.StringHashMap(i32).init(common.allocator),
        };
    }

    /// Releases standalone-mode storage; a no-op while editing a grammar in place.
    pub fn deinit(self: *GrammarBuilder) void {
        if (self.arena) |arena| {
            const backing = arena.child_allocator;
            arena.deinit();
            backing.destroy(arena);
        }
    }

    /// Seeds a builder from an existing grammar (for functor passes and union/concat).
    /// Rust moves clones of the grammar's vectors; this port deep-copies into the
    /// builder's own arena.
    pub fn from_grammar(grammar: *const Grammar, backing: Allocator) (Compact2dArrayError || Allocator.Error)!GrammarBuilder {
        var self = try new(backing);
        errdefer self.deinit();
        try self.rules.ensureTotalCapacity(self.allocator, grammar.rules.items.len);
        for (grammar.rules.items) |r|
            try self.rules.append(self.allocator, try dupe_rule(self.allocator, r));
        try self.suffix_stop_infos.ensureTotalCapacity(self.allocator, grammar.suffix_stop_infos.items.len);
        for (grammar.suffix_stop_infos.items) |info|
            try self.suffix_stop_infos.append(self.allocator, try dupe_suffix_stop_info(self.allocator, info));
        self.exprs.deinit();
        self.exprs = try Compact2dArray(i32).init_from_data_and_indptr(
            self.allocator,
            grammar.exprs.data_slice(),
            grammar.exprs.indptr_slice(),
        );
        return self;
    }

    /// Binds a builder to `grammar` without copying it (the C++
    /// `GrammarBuilder::FromMutableGrammar`): between `edit_in_place` and
    /// `edit_in_place_commit`, appended exprs and rule updates land directly in
    /// `grammar`'s storage, whose root rule and analysis results are left untouched.
    pub fn edit_in_place(grammar: *Grammar) Allocator.Error!GrammarBuilder {
        const storage = grammar.storage_mut();
        return .{
            .allocator = grammar.arena.allocator(),
            .arena = null,
            .backing = undefined,
            .rules = storage.rules.*,
            .suffix_stop_infos = storage.suffix_stop_infos.*,
            .exprs = storage.exprs.*,
            .rule_name_to_id = null,
            .next_cnt_per_hint = std.StringHashMap(i32).init(grammar.arena.allocator()),
        };
    }

    /// Writes the edited rule/expression storage back into `grammar`
    /// (Rust does this when its `edit` closure returns).
    pub fn edit_in_place_commit(self: *GrammarBuilder, grammar: *Grammar) void {
        const storage = grammar.storage_mut();
        storage.rules.* = self.rules;
        storage.exprs.* = self.exprs;
        storage.suffix_stop_infos.* = self.suffix_stop_infos;
    }

    /// Finalizes the grammar, setting the root to the rule named `root_rule_name`.
    /// Rust's `String` error payload (the missing name) is returned through the optional
    /// `missing_name` out parameter (allocated from `backing`; caller owns it).
    pub fn into_grammar(
        self: *GrammarBuilder,
        backing: Allocator,
        root_rule_name: []const u8,
        missing_name: ?*?[]const u8,
    ) (Compact2dArrayError || Allocator.Error || error{RootRuleNotFound})!*Grammar {
        const map = try self.rule_name_to_id_map();
        const root_rule_id = map.get(root_rule_name) orelse {
            if (missing_name) |out| out.* = try backing.dupe(u8, root_rule_name);
            return error.RootRuleNotFound;
        };
        return self.into_grammar_with_root_id(backing, root_rule_id);
    }

    fn rule_name_to_id_map(self: *GrammarBuilder) Allocator.Error!*std.StringHashMap(i32) {
        if (self.rule_name_to_id == null) {
            var map = std.StringHashMap(i32).init(self.allocator);
            errdefer map.deinit();
            try map.ensureTotalCapacity(@intCast(self.rules.items.len));
            for (self.rules.items, 0..) |rule, id|
                try map.put(try self.allocator.dupe(u8, rule.name), @intCast(id));
            self.rule_name_to_id = map;
        }
        return &self.rule_name_to_id.?;
    }

    /// Finalizes the grammar with an explicit root rule id. The builder stays usable for
    /// `deinit` only (Rust consumes `self`).
    pub fn into_grammar_with_root_id(
        self: *GrammarBuilder,
        backing: Allocator,
        root_rule_id: i32,
    ) (Compact2dArrayError || Allocator.Error)!*Grammar {
        const grammar = try Grammar.from_parts(backing, self.rules.items, &self.exprs, root_rule_id);
        errdefer grammar.deinit();
        try grammar.set_suffix_stop_infos(self.suffix_stop_infos.items);
        return grammar;
    }

    // ----------------------------- expressions -----------------------------

    /// Low-level: appends an expression of `ty` with `data`, returning its id.
    pub fn add_grammar_expr(
        self: *GrammarBuilder,
        ty: GrammarExprType,
        data: []const i32,
    ) Allocator.Error!i32 {
        return @intCast(try self.exprs.push_row_noncontiguous(ty.as_i32(), data));
    }

    /// Adds a byte-string expression from raw byte values (`0..=255`).
    pub fn add_byte_string_bytes(
        self: *GrammarBuilder,
        bytes: []const i32,
    ) Allocator.Error!i32 {
        return self.add_grammar_expr(.ByteString, bytes);
    }

    /// Adds a byte-string expression from a string's UTF-8 bytes.
    pub fn add_byte_string(
        self: *GrammarBuilder,
        s: []const u8,
    ) Allocator.Error!i32 {
        var bytes: std.ArrayList(i32) = .empty;
        defer bytes.deinit(self.allocator);
        try bytes.ensureTotalCapacity(self.allocator, s.len);
        for (s) |b| bytes.appendAssumeCapacity(b);
        return self.add_byte_string_bytes(bytes.items);
    }

    fn char_class_data(
        self: *GrammarBuilder,
        elements: []const @import("character_class_element.zig").CharacterClassElement,
        is_negative: bool,
    ) Allocator.Error!std.ArrayList(i32) {
        var data: std.ArrayList(i32) = .empty;
        errdefer data.deinit(self.allocator);
        try data.ensureTotalCapacity(self.allocator, 1 + elements.len * 2);
        data.appendAssumeCapacity(@intFromBool(is_negative));
        for (elements) |e| {
            data.appendAssumeCapacity(e.lower);
            data.appendAssumeCapacity(e.upper);
        }
        return data;
    }

    /// Adds a character-class expression.
    pub fn add_character_class(
        self: *GrammarBuilder,
        elements: []const @import("character_class_element.zig").CharacterClassElement,
        is_negative: bool,
    ) Allocator.Error!i32 {
        var data = try self.char_class_data(elements, is_negative);
        defer data.deinit(self.allocator);
        return self.add_grammar_expr(.CharacterClass, data.items);
    }

    /// Adds a starred character-class expression (`[...]*`).
    pub fn add_character_class_star(
        self: *GrammarBuilder,
        elements: []const @import("character_class_element.zig").CharacterClassElement,
        is_negative: bool,
    ) Allocator.Error!i32 {
        var data = try self.char_class_data(elements, is_negative);
        defer data.deinit(self.allocator);
        return self.add_grammar_expr(.CharacterClassStar, data.items);
    }

    /// Adds the empty-string expression.
    pub fn add_empty_str(self: *GrammarBuilder) Allocator.Error!i32 {
        return self.add_grammar_expr(.EmptyStr, &.{});
    }

    /// Adds an allowed-token-set expression.
    pub fn add_token_set(self: *GrammarBuilder, token_ids: []const i32) Allocator.Error!i32 {
        return self.add_grammar_expr(.Token, token_ids);
    }

    /// Adds an excluded-token-set expression.
    pub fn add_exclude_token_set(self: *GrammarBuilder, token_ids: []const i32) Allocator.Error!i32 {
        return self.add_grammar_expr(.ExcludeToken, token_ids);
    }

    /// Adds a reference to another rule.
    pub fn add_rule_ref(self: *GrammarBuilder, rule_id: i32) Allocator.Error!i32 {
        return self.add_grammar_expr(.RuleRef, &.{rule_id});
    }

    /// Adds a sequence of expressions.
    pub fn add_sequence(self: *GrammarBuilder, elements: []const i32) Allocator.Error!i32 {
        return self.add_grammar_expr(.Sequence, elements);
    }

    /// Adds an alternation of expressions.
    pub fn add_choices(self: *GrammarBuilder, choices: []const i32) Allocator.Error!i32 {
        return self.add_grammar_expr(.Choices, choices);
    }

    /// Adds a repetition of a rule: `[ref_rule_id, min, max]` (`max == -1` is unbounded).
    pub fn add_repeat(
        self: *GrammarBuilder,
        ref_rule_id: i32,
        min_repeat: i32,
        max_repeat: i32,
    ) Allocator.Error!i32 {
        return self.add_grammar_expr(.Repeat, &.{ ref_rule_id, min_repeat, max_repeat });
    }

    /// Adds a repetition of an arbitrary expression, wrapping it in a fresh rule (named
    /// from `cur_rule_name`) unless it is already a rule reference.
    pub fn add_repeat_from_expr(
        self: *GrammarBuilder,
        cur_rule_name: []const u8,
        grammar_expr_id: i32,
        min_repeat: i32,
        max_repeat: i32,
    ) Allocator.Error!i32 {
        const expr = self.grammar_expr(grammar_expr_id);
        const ref_rule_id = if (expr.ty == .RuleRef)
            expr.rule_ref_id()
        else blk: {
            const name = try self.get_new_rule_name(cur_rule_name);
            break :blk try self.add_rule_named(name, grammar_expr_id);
        };
        return self.add_repeat(ref_rule_id, min_repeat, max_repeat);
    }

    /// Adds a regex expression. The pattern is stored as-is and compiled into an automaton
    /// by the grammar FSM builder. If `json_string` is true, the characters that must be
    /// escaped in a JSON string are excluded from every character match of the compiled
    /// automaton.
    pub fn add_regex(
        self: *GrammarBuilder,
        pattern: []const u8,
        json_string: bool,
    ) Allocator.Error!i32 {
        var data: std.ArrayList(i32) = .empty;
        defer data.deinit(self.allocator);
        try data.ensureTotalCapacity(self.allocator, pattern.len + 1);
        data.appendAssumeCapacity(@intFromBool(json_string));
        for (pattern) |b| data.appendAssumeCapacity(b);
        return self.add_grammar_expr(.Regex, data.items);
    }

    /// Adds a substring expression, which matches every contiguous subsequence of the
    /// chunk list (including the empty one). Chunks may be empty or repeated.
    pub fn add_substring(self: *GrammarBuilder, chunks: []const []const u8) Allocator.Error!i32 {
        var data: std.ArrayList(i32) = .empty;
        defer data.deinit(self.allocator);
        for (chunks) |chunk| {
            try data.append(self.allocator, @intCast(chunk.len));
            for (chunk) |b| try data.append(self.allocator, b);
        }
        return self.add_grammar_expr(.Substring, data.items);
    }

    /// Adds a tag-dispatch expression from its decoded form.
    pub fn add_tag_dispatch(self: *GrammarBuilder, tag_dispatch: *const TagDispatch) Allocator.Error!i32 {
        var data: std.ArrayList(i32) = .empty;
        defer data.deinit(self.allocator);
        try data.ensureTotalCapacity(self.allocator, tag_dispatch.tag_rule_pairs.items.len * 2 + 2);
        for (tag_dispatch.tag_rule_pairs.items) |pair| {
            var bytes: std.ArrayList(i32) = .empty;
            defer bytes.deinit(self.allocator);
            try bytes.ensureTotalCapacity(self.allocator, pair.tag.len);
            for (pair.tag) |b| bytes.appendAssumeCapacity(b);
            const id = try self.add_byte_string_bytes(bytes.items);
            data.appendAssumeCapacity(id);
            data.appendAssumeCapacity(pair.rule_id);
        }
        data.appendAssumeCapacity(@intFromBool(tag_dispatch.loop_after_dispatch));
        var exclude_ids: std.ArrayList(i32) = .empty;
        defer exclude_ids.deinit(self.allocator);
        try exclude_ids.ensureTotalCapacity(self.allocator, tag_dispatch.excludes.items.len);
        for (tag_dispatch.excludes.items) |exclude| {
            var bytes: std.ArrayList(i32) = .empty;
            defer bytes.deinit(self.allocator);
            try bytes.ensureTotalCapacity(self.allocator, exclude.len);
            for (exclude) |b| bytes.appendAssumeCapacity(b);
            exclude_ids.appendAssumeCapacity(try self.add_byte_string_bytes(bytes.items));
        }
        const exclude_choices = try self.add_choices(exclude_ids.items);
        data.appendAssumeCapacity(exclude_choices);
        return self.add_grammar_expr(.TagDispatch, data.items);
    }

    /// Adds a token-tag-dispatch expression from its decoded form.
    pub fn add_token_tag_dispatch(
        self: *GrammarBuilder,
        ttd: *const TokenTagDispatch,
    ) Allocator.Error!i32 {
        var data: std.ArrayList(i32) = .empty;
        defer data.deinit(self.allocator);
        try data.ensureTotalCapacity(
            self.allocator,
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
        return self.add_grammar_expr(.TokenTagDispatch, data.items);
    }

    /// Number of grammar expressions added so far.
    pub fn num_grammar_exprs(self: *const GrammarBuilder) i32 {
        return @intCast(self.exprs.len());
    }

    /// A view of the expression with the given id.
    pub fn grammar_expr(self: *const GrammarBuilder, expr_id: i32) GrammarExpr {
        const row = self.exprs.row(@intCast(expr_id));
        const ty = grammar_expr_type.try_from(row[0]) catch
            unreachable; // builder stores valid expr type tags
        return .{ .ty = ty, .data = row[1..] };
    }

    // -------------------------------- rules --------------------------------

    /// Adds a rule, returning its id. The rule's strings are copied into the builder's
    /// arena. Panics (assert) if a rule with the same name already exists.
    pub fn add_rule(self: *GrammarBuilder, rule: Rule) Allocator.Error!i32 {
        const id: i32 = @intCast(self.rules.items.len);
        const map = try self.rule_name_to_id_map();
        std.debug.assert(!map.contains(rule.name)); // duplicate rule name
        try map.put(try self.allocator.dupe(u8, rule.name), id);
        try self.rules.append(self.allocator, try dupe_rule(self.allocator, rule));
        return id;
    }

    /// Adds a rule with the given name and body.
    pub fn add_rule_named(
        self: *GrammarBuilder,
        name: []const u8,
        body_expr_id: i32,
    ) Allocator.Error!i32 {
        return self.add_rule(Rule.new(name, body_expr_id));
    }

    /// Adds a rule whose name is derived from `name_hint` (deduplicated with `_N` suffixes).
    pub fn add_rule_with_hint(
        self: *GrammarBuilder,
        name_hint: []const u8,
        body_expr_id: i32,
    ) Allocator.Error!i32 {
        const name = try self.get_new_rule_name(name_hint);
        return self.add_rule(Rule.new(name, body_expr_id));
    }

    /// Adds a body-less rule (set the body later with `update_rule_body`).
    pub fn add_empty_rule(self: *GrammarBuilder, name: []const u8) Allocator.Error!i32 {
        return self.add_rule(Rule.empty(name));
    }

    /// Adds a body-less rule with a hinted, deduplicated name.
    pub fn add_empty_rule_with_hint(self: *GrammarBuilder, name_hint: []const u8) Allocator.Error!i32 {
        const name = try self.get_new_rule_name(name_hint);
        return self.add_rule(Rule.empty(name));
    }

    /// Sets the body expression of an existing rule.
    pub fn update_rule_body(self: *GrammarBuilder, rule_id: i32, body_expr_id: i32) void {
        self.rules.items[@intCast(rule_id)].body_expr_id = body_expr_id;
    }

    /// Sets the body expression of the rule with the given name.
    pub fn update_rule_body_by_name(
        self: *GrammarBuilder,
        name: []const u8,
        body_expr_id: i32,
    ) Allocator.Error!void {
        const id = try self.get_rule_id(name);
        std.debug.assert(id != NO_EXPR); // rule not found
        self.update_rule_body(id, body_expr_id);
    }

    /// Attaches a lookahead assertion to the rule with the given name.
    pub fn update_lookahead_assertion_by_name(
        self: *GrammarBuilder,
        name: []const u8,
        lookahead_assertion_id: i32,
    ) Allocator.Error!void {
        const id = try self.get_rule_id(name);
        std.debug.assert(id != NO_EXPR); // rule not found
        self.update_lookahead_assertion(id, lookahead_assertion_id);
    }

    /// Attaches a lookahead assertion (a sequence expr id, or `NO_EXPR` for none).
    pub fn update_lookahead_assertion(
        self: *GrammarBuilder,
        rule_id: i32,
        lookahead_assertion_id: i32,
    ) void {
        self.rules.items[@intCast(rule_id)].lookahead_assertion_id = lookahead_assertion_id;
    }

    /// Marks a rule's lookahead assertion as exact (or not).
    pub fn update_lookahead_exact(self: *GrammarBuilder, rule_id: i32, is_exact: bool) void {
        self.rules.items[@intCast(rule_id)].is_exact_lookahead = is_exact;
    }

    /// Sets the token budget of a rule (`-1` means none).
    pub fn update_max_tokens(self: *GrammarBuilder, rule_id: i32, max_tokens: i32) void {
        self.rules.items[@intCast(rule_id)].max_tokens = max_tokens;
    }

    /// Sets the character budget of a rule (`-1` means none).
    pub fn update_max_chars(self: *GrammarBuilder, rule_id: i32, max_chars: i32) void {
        self.rules.items[@intCast(rule_id)].max_chars = max_chars;
    }

    /// Sets the capture group name of a rule (empty means no capture).
    pub fn update_capture_name(
        self: *GrammarBuilder,
        rule_id: i32,
        capture_name: []const u8,
    ) Allocator.Error!void {
        self.rules.items[@intCast(rule_id)].capture_name = try self.allocator.dupe(u8, capture_name);
    }

    /// Sets whether a rule is lazy (committed-shortest).
    pub fn update_lazy(self: *GrammarBuilder, rule_id: i32, is_lazy: bool) void {
        self.rules.items[@intCast(rule_id)].is_lazy = is_lazy;
    }

    /// Sets the sampling temperature associated with a rule.
    pub fn update_rule_temperature(
        self: *GrammarBuilder,
        rule_id: i32,
        temperature: ?f32,
    ) void {
        self.rules.items[@intCast(rule_id)].temperature = temperature;
    }

    /// Copies the budgets, capture name, laziness, temperature, and suffix/stop metadata of
    /// `source`'s rule `source_rule_id` onto `rule_id`, mapping suffix/stop helper rule ids
    /// through `map_rule_id` (Rust `impl Fn(i32) -> i32`: pass a function item/pointer or
    /// a struct with a matching `call`).
    pub fn copy_rule_attributes(
        self: *GrammarBuilder,
        rule_id: i32,
        source: *const Grammar,
        source_rule_id: i32,
        map_rule_id: anytype,
    ) Allocator.Error!void {
        const rule = source.rule(source_rule_id);
        self.update_max_tokens(rule_id, rule.max_tokens);
        self.update_max_chars(rule_id, rule.max_chars);
        try self.update_capture_name(rule_id, rule.capture_name);
        if (source.suffix_stop_info(source_rule_id)) |info_src| {
            var info = try dupe_suffix_stop_info(self.allocator, info_src.*);
            if (info.body_rule_id >= 0) {
                info.body_rule_id = map_rule_id(info.body_rule_id);
                info.marker_rule_id = map_rule_id(info.marker_rule_id);
            }
            try self.update_suffix_stop_info(rule_id, info);
        }
        self.update_lazy(rule_id, rule.is_lazy);
        self.update_rule_temperature(rule_id, rule.temperature);
    }

    /// Sets or clears (when `info` is empty) the sparse suffix/stop metadata of a rule.
    pub fn update_suffix_stop_info(
        self: *GrammarBuilder,
        rule_id: i32,
        info_in: SuffixStopInfo,
    ) Allocator.Error!void {
        var info = info_in;
        const rule_count = self.num_rules();
        std.debug.assert(rule_id >= 0 and rule_id < rule_count); // Rule id is out of range.
        std.debug.assert(info.hidden_suffix_bytes >= 0 and info.hidden_stop_bytes >= 0); // The number of hidden suffix/stop bytes must be non-negative.
        std.debug.assert((info.body_rule_id == -1 and info.marker_rule_id == -1) or
            (info.body_rule_id >= 0 and info.body_rule_id < rule_count and
                info.marker_rule_id >= 0 and info.marker_rule_id < rule_count)); // Capture-hidden helper rule ids must both be -1 or valid rule ids.
        const position = suffix_stop_info_mod.search_by_rule_id(self.suffix_stop_infos.items, rule_id);
        if (info.is_empty()) {
            if (position.found) {
                // Rust `Vec::remove` drops the entry (and its String) here.
                self.allocator.free(self.suffix_stop_infos.items[position.index].stop_capture_name);
                _ = self.suffix_stop_infos.orderedRemove(position.index);
            }
            return;
        }
        info.rule_id = rule_id;
        const stored = try dupe_suffix_stop_info(self.allocator, info);
        errdefer self.allocator.free(stored.stop_capture_name);
        if (position.found) {
            const old = self.suffix_stop_infos.items[position.index];
            self.allocator.free(old.stop_capture_name);
            self.suffix_stop_infos.items[position.index] = stored;
        } else {
            try self.suffix_stop_infos.insert(self.allocator, position.index, stored);
        }
    }

    /// Number of rules added so far.
    pub fn num_rules(self: *const GrammarBuilder) i32 {
        return @intCast(self.rules.items.len);
    }

    /// The rule with the given id.
    pub fn get_rule(self: *const GrammarBuilder, rule_id: i32) *const Rule {
        return &self.rules.items[@intCast(rule_id)];
    }

    /// The id of the rule with the given name, or `NO_EXPR` (`-1`) if absent
    /// (Rust builds the name map lazily through `OnceCell`; Zig needs `*self`).
    pub fn get_rule_id(self: *GrammarBuilder, name: []const u8) Allocator.Error!i32 {
        const map = try self.rule_name_to_id_map();
        return map.get(name) orelse NO_EXPR;
    }

    /// Returns a fresh rule name based on `name_hint`, appending `_1`, `_2`, … to avoid
    /// collisions (matching the C++ scheme exactly). The returned slice lives in the
    /// builder's arena.
    pub fn get_new_rule_name(
        self: *GrammarBuilder,
        name_hint: []const u8,
    ) Allocator.Error![]const u8 {
        const map = try self.rule_name_to_id_map();
        if (!map.contains(name_hint)) return name_hint;
        var cnt = (self.next_cnt_per_hint.get(name_hint) orelse 0);
        if (cnt < 1) cnt = 1;
        var candidate: []u8 = undefined;
        while (true) {
            candidate = try std.fmt.allocPrint(self.allocator, "{s}_{d}", .{ name_hint, cnt });
            if (!map.contains(candidate)) break;
            cnt += 1;
        }
        try self.next_cnt_per_hint.put(try self.allocator.dupe(u8, name_hint), cnt);
        return candidate;
    }
};

test "builder constructs rules, exprs and dedupes hint names" {
    const backing = std.testing.allocator;
    var builder = try GrammarBuilder.new(backing);
    defer builder.deinit();

    const bs = try builder.add_byte_string("hello");
    try std.testing.expectEqual(@as(i32, 0), bs);
    const empty = try builder.add_empty_str();
    const choices = try builder.add_choices(&.{ bs, empty });
    const seq = try builder.add_sequence(&.{ choices, empty });
    try std.testing.expectEqual(@as(i32, 4), builder.num_grammar_exprs());

    const root = try builder.add_rule_named("root", seq);
    const other = try builder.add_rule_with_hint("root", empty); // root_1
    const another = try builder.add_rule_with_hint("root", empty); // root_2
    try std.testing.expectEqual(@as(i32, 0), root);
    try std.testing.expectEqualStrings("root_1", builder.get_rule(other).name);
    try std.testing.expectEqualStrings("root_2", builder.get_rule(another).name);
    try std.testing.expectEqual(@as(i32, 3), builder.num_rules());
    try std.testing.expectEqual(@as(i32, 0), try builder.get_rule_id("root"));
    try std.testing.expectEqual(NO_EXPR, try builder.get_rule_id("missing"));

    // get_new_rule_name with a fresh hint returns the hint verbatim.
    try std.testing.expectEqualStrings("fresh", try builder.get_new_rule_name("fresh"));

    builder.update_rule_body(other, bs);
    try std.testing.expectEqual(bs, builder.get_rule(other).body_expr_id);
    try builder.update_rule_body_by_name("root_2", choices);
    try std.testing.expectEqual(choices, builder.get_rule(another).body_expr_id);

    const grammar = try builder.into_grammar(backing, "root", null);
    defer grammar.deinit();
    try std.testing.expectEqualStrings("root", grammar.root_rule().name);
    try std.testing.expectEqual(@as(i32, 3), grammar.num_rules());
    try std.testing.expectEqual(@as(i32, 4), grammar.num_exprs());

    // Missing root name reports through the out parameter.
    var builder2 = try GrammarBuilder.new(backing);
    defer builder2.deinit();
    var missing: ?[]const u8 = null;
    const failed = builder2.into_grammar(backing, "nope", &missing);
    try std.testing.expectError(error.RootRuleNotFound, failed);
    try std.testing.expectEqualStrings("nope", missing.?);
    backing.free(missing.?);
}

test "add repeat from expr wraps non-rule-ref exprs" {
    const backing = std.testing.allocator;
    var builder = try GrammarBuilder.new(backing);
    defer builder.deinit();
    _ = try builder.add_rule_named("root", NO_EXPR);
    const bs = try builder.add_byte_string("x");
    const repeat_id = try builder.add_repeat_from_expr("wrap", bs, 1, -1);
    const rep = builder.grammar_expr(repeat_id);
    try std.testing.expectEqual(GrammarExprType.Repeat, rep.ty);
    const spec = rep.repeat();
    try std.testing.expectEqual(@as(i32, 1), spec.rule_id); // fresh "wrap" rule
    try std.testing.expectEqual(@as(i32, 1), spec.min_repeat);
    try std.testing.expectEqual(@as(i32, -1), spec.max_repeat);
    try std.testing.expectEqualStrings("wrap", builder.get_rule(1).name);
    try std.testing.expectEqual(bs, builder.get_rule(1).body_expr_id);
    // Wrapping a rule ref does not create a new rule.
    const ref = try builder.add_rule_ref(0);
    const repeat2 = try builder.add_repeat_from_expr("wrap", ref, 0, 2);
    try std.testing.expectEqual(@as(i32, 0), builder.grammar_expr(repeat2).repeat().rule_id);
}

test "grammar expr adders decode correctly" {
    const backing = std.testing.allocator;
    var builder = try GrammarBuilder.new(backing);
    defer builder.deinit();
    const cc = try builder.add_character_class(&.{ @import("character_class_element.zig").CharacterClassElement.new('a', 'z'), @import("character_class_element.zig").CharacterClassElement.new('0', '9') }, true);
    const cc_view = builder.grammar_expr(cc);
    try std.testing.expectEqual(GrammarExprType.CharacterClass, cc_view.ty);
    const cls = try cc_view.character_class(backing);
    defer backing.free(cls.ranges);
    try std.testing.expect(cls.is_negative);
    try std.testing.expectEqual(@as(usize, 2), cls.ranges.len);

    const star = try builder.add_character_class_star(&.{@import("character_class_element.zig").CharacterClassElement.new('a', 'z')}, false);
    try std.testing.expectEqual(GrammarExprType.CharacterClassStar, builder.grammar_expr(star).ty);

    const token_set = try builder.add_token_set(&.{ 1, 2, 3 });
    try std.testing.expectEqual(GrammarExprType.Token, builder.grammar_expr(token_set).ty);
    const exclude_set = try builder.add_exclude_token_set(&.{5});
    try std.testing.expectEqual(GrammarExprType.ExcludeToken, builder.grammar_expr(exclude_set).ty);

    const regex = try builder.add_regex("[a-z]+", true);
    const regex_view = builder.grammar_expr(regex);
    try std.testing.expectEqual(GrammarExprType.Regex, regex_view.ty);
    try std.testing.expect(regex_view.regex_is_json_string());
    const pattern = try regex_view.regex_pattern(backing);
    defer backing.free(pattern);
    try std.testing.expectEqualStrings("[a-z]+", pattern);

    const substring = try builder.add_substring(&.{ "ab", "", "c" });
    const sub_view = builder.grammar_expr(substring);
    try std.testing.expectEqual(GrammarExprType.Substring, sub_view.ty);
    const chunks = try sub_view.substring_chunks(backing);
    defer {
        for (chunks) |chunk| backing.free(chunk);
        backing.free(chunks);
    }
    try std.testing.expectEqual(@as(usize, 3), chunks.len);
    try std.testing.expectEqualStrings("ab", chunks[0]);
    try std.testing.expectEqualStrings("", chunks[1]);
    try std.testing.expectEqualStrings("c", chunks[2]);
}

test "suffix stop info update, replace and remove" {
    const backing = std.testing.allocator;
    var builder = try GrammarBuilder.new(backing);
    defer builder.deinit();
    _ = try builder.add_empty_rule("a");
    _ = try builder.add_empty_rule("b");

    var info = SuffixStopInfo.default();
    info.hidden_suffix_bytes = 2;
    try builder.update_suffix_stop_info(1, info);
    try std.testing.expectEqual(@as(usize, 1), builder.suffix_stop_infos.items.len);
    try std.testing.expectEqual(@as(i32, 0), try builder.get_rule_id("a")); // sanity
    try std.testing.expectEqual(@as(i32, 1), builder.suffix_stop_infos.items[0].rule_id);

    // Replace in place (rule_id stays sorted position).
    info.hidden_suffix_bytes = 5;
    info.stop_capture_name = "cap";
    try builder.update_suffix_stop_info(1, info);
    try std.testing.expectEqual(@as(usize, 1), builder.suffix_stop_infos.items.len);
    try std.testing.expectEqualStrings("cap", builder.suffix_stop_infos.items[0].stop_capture_name);

    // Insert before existing (lower rule id keeps sorted order).
    var info0 = SuffixStopInfo.default();
    info0.hidden_stop_bytes = 1;
    try builder.update_suffix_stop_info(0, info0);
    try std.testing.expectEqual(@as(usize, 2), builder.suffix_stop_infos.items.len);
    try std.testing.expectEqual(@as(i32, 0), builder.suffix_stop_infos.items[0].rule_id);
    try std.testing.expectEqual(@as(i32, 1), builder.suffix_stop_infos.items[1].rule_id);

    // Empty info removes the entry.
    var empty = SuffixStopInfo.default();
    empty.rule_id = 1;
    try builder.update_suffix_stop_info(1, empty);
    try std.testing.expectEqual(@as(usize, 1), builder.suffix_stop_infos.items.len);
    try std.testing.expectEqual(@as(i32, 0), builder.suffix_stop_infos.items[0].rule_id);
}

test "from_grammar and edit_in_place" {
    const backing = std.testing.allocator;
    var builder = try GrammarBuilder.new(backing);
    defer builder.deinit();
    const bs = try builder.add_byte_string("q");
    _ = try builder.add_rule_named("root", bs);
    var info = SuffixStopInfo.default();
    info.rule_id = 0;
    info.stop_capture_name = "s";
    try builder.update_suffix_stop_info(0, info);
    var grammar = try builder.into_grammar_with_root_id(backing, 0);
    defer grammar.deinit();

    // from_grammar deep-copies.
    var seeded = try GrammarBuilder.from_grammar(grammar, backing);
    defer seeded.deinit();
    try std.testing.expectEqual(@as(i32, 1), seeded.num_rules());
    try std.testing.expectEqual(@as(i32, 1), seeded.num_grammar_exprs());
    try std.testing.expectEqual(@as(usize, 1), seeded.suffix_stop_infos.items.len);
    const extra = try seeded.add_byte_string("w");
    _ = try seeded.add_rule_named("extra", extra);
    const grammar2 = try seeded.into_grammar_with_root_id(backing, 1);
    defer grammar2.deinit();
    try std.testing.expectEqual(@as(i32, 2), grammar2.num_rules());
    try std.testing.expectEqual(@as(i32, 2), grammar2.num_exprs());

    // edit_in_place appends into the original grammar.
    var editor = try GrammarBuilder.edit_in_place(grammar);
    const extra2 = try editor.add_byte_string("e");
    _ = try editor.add_rule_named("appended", extra2);
    try std.testing.expectEqual(@as(i32, 2), editor.num_rules());

    // copy_rule_attributes maps helper ids and copies scalar attributes; the helper-rule
    // suffix/stop info of grammar rule 1 is set first through the editor.
    var info_dst = SuffixStopInfo.default();
    info_dst.rule_id = 1;
    info_dst.body_rule_id = 1;
    info_dst.marker_rule_id = 1;
    info_dst.stop_capture_name = "cap";
    try editor.update_suffix_stop_info(1, info_dst);
    editor.edit_in_place_commit(grammar);
    editor.deinit();
    try std.testing.expectEqual(@as(i32, 2), grammar.num_rules());
    try std.testing.expectEqualStrings("appended", grammar.rules.items[1].name);
    try std.testing.expectEqual(@as(i32, 2), grammar.num_exprs());

    var target_builder = try GrammarBuilder.new(backing);
    defer target_builder.deinit();
    _ = try target_builder.add_empty_rule("t0");
    _ = try target_builder.add_empty_rule("t1");
    _ = try target_builder.add_empty_rule("t2");
    try target_builder.copy_rule_attributes(1, grammar, 1, struct {
        fn map(id: i32) i32 {
            return id + 1;
        }
    }.map);
    const copied = target_builder.get_rule(1);
    try std.testing.expectEqual(@as(i32, -1), copied.max_tokens);
    const copied_info = target_builder.suffix_stop_infos.items[0];
    try std.testing.expectEqual(@as(i32, 2), copied_info.body_rule_id);
    try std.testing.expectEqualStrings("cap", copied_info.stop_capture_name);
}
