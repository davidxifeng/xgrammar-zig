//! Resolves, analyzes, and converts a structural-tag `Format` tree into a `Grammar`
//! (`structural_tag_converter.rs`) — a port of `StructuralTagTokenResolver`,
//! `StructuralTagAnalyzer`, and `StructuralTagConverter`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const functor = @import("../functor/mod.zig");
const grammar_mod = @import("../grammar/mod.zig");
const json_format_mod = @import("json_format.zig");
const json_schema_converter = @import("json_schema_converter.zig");
const structural_tag_error = @import("structural_tag_error.zig");
const structural_tag_format = @import("structural_tag_format.zig");
const structural_tag_parser = @import("structural_tag_parser.zig");
const tokenizer_mod = @import("../tokenizer/mod.zig");
const Grammar = grammar_mod.Grammar;
const GrammarBuilder = grammar_mod.GrammarBuilder;
const TagDispatch = grammar_mod.TagDispatch;
const TokenTagDispatch = grammar_mod.TokenTagDispatch;
const TriggerRulePair = grammar_mod.token_tag_dispatch.TriggerRulePair;
const CharacterClassElement = grammar_mod.CharacterClassElement;
const Format = structural_tag_format.Format;
const IntOrString = structural_tag_format.IntOrString;
const TagBegin = structural_tag_format.TagBegin;
const TagEnd = structural_tag_format.TagEnd;
const TagFormat = structural_tag_format.TagFormat;
const TagsWithSeparatorFormat = structural_tag_format.TagsWithSeparatorFormat;
const TokenFormat = structural_tag_format.TokenFormat;
const TokenTriggeredTagsFormat = structural_tag_format.TokenTriggeredTagsFormat;
const TriggeredTagsFormat = structural_tag_format.TriggeredTagsFormat;
const StructuralTagError = structural_tag_error.StructuralTagError;
const StructuralTagErrorInfo = structural_tag_error.StructuralTagErrorInfo;
const TokenizerInfo = tokenizer_mod.tokenizer_info.TokenizerInfo;

/// `(tag, rule_id)` pair passed to `add_tag_dispatch_rule` (Rust builds a `TagDispatch`).
const TagRulePairInit = struct { tag: []const u8, rule_id: i32 };

/// Constructs a grammar from a structural tag string (Rust `Grammar::from_structural_tag`).
///
/// String-keyed token references require a tokenizer; use
/// `from_structural_tag_with_tokenizer` for those (integer token ids work without one).
/// `diag` receives the failure payload on error.
pub fn from_structural_tag(gpa: Allocator, json: []const u8, diag: ?*?StructuralTagErrorInfo) StructuralTagError!*Grammar {
    return build_structural_tag(gpa, json, null, diag);
}

/// Constructs a grammar from a structural tag string (Rust
/// `Grammar::from_structural_tag_with_tokenizer`).
///
/// `tokenizer_info` is used for resolving string token references.
pub fn from_structural_tag_with_tokenizer(gpa: Allocator, json: []const u8, tokenizer_info: *const TokenizerInfo, diag: ?*?StructuralTagErrorInfo) StructuralTagError!*Grammar {
    return build_structural_tag(gpa, json, tokenizer_info.decoded_vocab, diag);
}

fn build_structural_tag(
    gpa: Allocator,
    json: []const u8,
    vocab: ?[]const []const u8,
    diag: ?*?StructuralTagErrorInfo,
) StructuralTagError!*Grammar {
    var format = try structural_tag_parser.parse_structural_tag(gpa, json, diag);
    defer format.deinit(gpa);
    try resolve_format(gpa, diag, &format, vocab);
    try analyze(gpa, diag, &format, null);
    var converter = StructuralTagConverter.new(gpa) catch return error.OutOfMemory;
    converter.diag = diag;
    defer converter.deinit();
    const grammar = try converter.convert(&format);
    const normalized = functor.grammar_normalizer(gpa, grammar) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidStructuralTag,
    };
    grammar.deinit();
    return normalized;
}

// ============================ Token resolver ============================

fn resolve_token(gpa: Allocator, diag: ?*?StructuralTagErrorInfo, tf: *TokenFormat, vocab: ?[]const []const u8) StructuralTagError!void {
    if (tf.resolved_token_id >= 0) return;
    const s = switch (tf.token) {
        .int => return,
        .str => |s| s,
    };
    const v = vocab orelse {
        return fail_invalid_info(gpa, diag, "Token string resolution requires tokenizer_info");
    };
    for (v, 0..) |candidate, i| {
        if (std.mem.eql(u8, candidate, s)) {
            tf.resolved_token_id = @intCast(i);
            return;
        }
    }
    return fail_invalid_fmt(gpa, diag, "Token string \"{s}\" not found in vocabulary", .{s});
}

fn resolve_vec(gpa: Allocator, diag: ?*?StructuralTagErrorInfo, input: []const IntOrString, vocab: ?[]const []const u8, out: *std.ArrayList(i32)) StructuralTagError!void {
    for (input) |item| {
        switch (item) {
            .int => |i| out.append(gpa, i) catch return error.OutOfMemory,
            .str => |s| {
                const v = vocab orelse {
                    return fail_invalid_info(gpa, diag, "Token string resolution requires tokenizer_info");
                };
                var found = false;
                for (v, 0..) |candidate, i| {
                    if (std.mem.eql(u8, candidate, s)) {
                        out.append(gpa, @intCast(i)) catch return error.OutOfMemory;
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    return fail_invalid_fmt(gpa, diag, "Token string \"{s}\" not found in vocabulary", .{s});
                }
            },
        }
    }
}

fn resolve_tag(gpa: Allocator, diag: ?*?StructuralTagErrorInfo, tag: *TagFormat, vocab: ?[]const []const u8) StructuralTagError!void {
    switch (tag.begin) {
        .str => {},
        .token => |*tf| try resolve_token(gpa, diag, tf, vocab),
    }
    switch (tag.end) {
        .strings => {},
        .token => |*tf| try resolve_token(gpa, diag, tf, vocab),
    }
    try resolve_format(gpa, diag, tag.content, vocab);
}

fn resolve_format(gpa: Allocator, diag: ?*?StructuralTagErrorInfo, format: *Format, vocab: ?[]const []const u8) StructuralTagError!void {
    switch (format.*) {
        .token => |*f| return resolve_token(gpa, diag, f, vocab),
        .exclude_token => |*f| {
            f.resolved_token_ids.clearRetainingCapacity();
            try resolve_vec(gpa, diag, f.exclude_tokens.items, vocab, &f.resolved_token_ids);
        },
        .any_tokens => |*f| {
            f.resolved_exclude_token_ids.clearRetainingCapacity();
            try resolve_vec(gpa, diag, f.exclude_tokens.items, vocab, &f.resolved_exclude_token_ids);
        },
        .token_triggered_tags => |*f| {
            f.resolved_trigger_token_ids.clearRetainingCapacity();
            try resolve_vec(gpa, diag, f.trigger_tokens.items, vocab, &f.resolved_trigger_token_ids);
            f.resolved_exclude_token_ids.clearRetainingCapacity();
            try resolve_vec(gpa, diag, f.exclude_tokens.items, vocab, &f.resolved_exclude_token_ids);
            for (f.tags.items) |*tag| {
                try resolve_tag(gpa, diag, tag, vocab);
            }
        },
        .token_dispatch => |*f| {
            var triggers: std.ArrayList(IntOrString) = .empty;
            defer triggers.deinit(gpa);
            for (f.rules.items) |rule| {
                triggers.append(gpa, rule.trigger) catch return error.OutOfMemory;
            }
            f.resolved_trigger_token_ids.clearRetainingCapacity();
            try resolve_vec(gpa, diag, triggers.items, vocab, &f.resolved_trigger_token_ids);
            f.resolved_exclude_token_ids.clearRetainingCapacity();
            try resolve_vec(gpa, diag, f.exclude_tokens.items, vocab, &f.resolved_exclude_token_ids);
            for (f.rules.items) |*rule| {
                try resolve_format(gpa, diag, rule.content, vocab);
            }
        },
        .dispatch => |*f| {
            for (f.rules.items) |*rule| {
                try resolve_format(gpa, diag, rule.content, vocab);
            }
        },
        .tag => |*f| return resolve_tag(gpa, diag, f, vocab),
        .sequence => |*f| {
            for (f.elements.items) |*e| {
                try resolve_format(gpa, diag, e, vocab);
            }
        },
        .or_fmt => |*f| {
            for (f.elements.items) |*e| {
                try resolve_format(gpa, diag, e, vocab);
            }
        },
        .triggered_tags => |*f| {
            for (f.tags.items) |*tag| {
                try resolve_tag(gpa, diag, tag, vocab);
            }
        },
        .tags_with_separator => |*f| {
            for (f.tags.items) |*tag| {
                try resolve_tag(gpa, diag, tag, vocab);
            }
        },
        .optional => |f| return resolve_format(gpa, diag, f.content, vocab),
        .plus => |f| return resolve_format(gpa, diag, f.content, vocab),
        .star => |f| return resolve_format(gpa, diag, f.content, vocab),
        .repeat => |f| return resolve_format(gpa, diag, f.content, vocab),
        else => {},
    }
}

// ============================ Analyzer ============================

fn end_strings_of(gpa: Allocator, nearest_tag_end: ?*const TagEnd) StructuralTagError!std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| gpa.free(s);
        out.deinit(gpa);
    }
    if (nearest_tag_end) |end| {
        switch (end.*) {
            .strings => |v| {
                for (v.items) |s| {
                    const duped = gpa.dupe(u8, s) catch return error.OutOfMemory;
                    out.append(gpa, duped) catch |err| {
                        gpa.free(duped);
                        return err;
                    };
                }
            },
            else => {},
        }
    }
    return out;
}

fn end_token_ids_of(gpa: Allocator, nearest_tag_end: ?*const TagEnd) StructuralTagError!std.ArrayList(i32) {
    var out: std.ArrayList(i32) = .empty;
    if (nearest_tag_end) |end| {
        switch (end.*) {
            .token => |tf| out.append(gpa, tf.resolved_token_id) catch return error.OutOfMemory,
            else => {},
        }
    }
    return out;
}

fn is_unlimited(format: *const Format) bool {
    return switch (format.*) {
        .any_text, .triggered_tags, .token_triggered_tags, .dispatch, .token_dispatch, .any_tokens, .tags_with_separator, .star, .plus => true,
        .sequence => |f| f.is_unlimited,
        .or_fmt => |f| f.is_unlimited,
        .optional => |f| is_unlimited(f.content),
        .repeat => |f| f.max == -1 or (f.max != 0 and is_unlimited(f.content)),
        else => false,
    };
}

fn is_excluded(format: *const Format) bool {
    return switch (format.*) {
        .any_text => |f| f.excludes.items.len != 0,
        .triggered_tags => |f| f.excludes.items.len != 0,
        .token_triggered_tags => |f| f.exclude_tokens.items.len != 0,
        .dispatch => |f| f.excludes.items.len != 0,
        .token_dispatch => |f| f.exclude_tokens.items.len != 0,
        .any_tokens => |f| f.exclude_tokens.items.len != 0,
        else => false,
    };
}

fn analyze_tag(gpa: Allocator, diag: ?*?StructuralTagErrorInfo, tag: *TagFormat) StructuralTagError!void {
    const end = tag.end;
    try analyze(gpa, diag, tag.content, &end);
    if (is_unlimited(tag.content)) {
        switch (tag.end) {
            .strings => |ends| {
                var has_non_empty = false;
                for (ends.items) |s| {
                    if (s.len != 0) has_non_empty = true;
                }
                if (!has_non_empty and !is_excluded(tag.content)) {
                    return fail_invalid_info(gpa, diag, "When the content is unlimited, at least one end string must be non-empty");
                }
            },
            else => {},
        }
    }
}

fn analyze(gpa: Allocator, diag: ?*?StructuralTagErrorInfo, format: *Format, nearest_tag_end: ?*const TagEnd) StructuralTagError!void {
    switch (format.*) {
        .any_text => |*f| {
            var detected = try end_strings_of(gpa, nearest_tag_end);
            std.mem.swap(std.ArrayList([]const u8), &detected, &f.detected_end_strs);
            for (detected.items) |s| gpa.free(s);
            detected.deinit(gpa);
        },
        .exclude_token => |*f| {
            var detected = try end_token_ids_of(gpa, nearest_tag_end);
            std.mem.swap(std.ArrayList(i32), &detected, &f.detected_end_token_ids);
            detected.deinit(gpa);
        },
        .any_tokens => |*f| {
            var detected = try end_token_ids_of(gpa, nearest_tag_end);
            std.mem.swap(std.ArrayList(i32), &detected, &f.detected_end_token_ids);
            detected.deinit(gpa);
        },
        .sequence => |*f| {
            var any_unlimited = false;
            for (f.elements.items) |*e| {
                try analyze(gpa, diag, e, nearest_tag_end);
                any_unlimited = any_unlimited or (is_unlimited(e) and !is_excluded(e));
            }
            f.is_unlimited = any_unlimited;
        },
        .or_fmt => |*f| {
            var any_unlimited = false;
            for (f.elements.items) |*e| {
                try analyze(gpa, diag, e, nearest_tag_end);
                any_unlimited = any_unlimited or (is_unlimited(e) and !is_excluded(e));
            }
            f.is_unlimited = any_unlimited;
        },
        .tag => |*f| return analyze_tag(gpa, diag, f),
        .triggered_tags => |*f| {
            for (f.tags.items) |*tag| {
                try analyze_tag(gpa, diag, tag);
            }
            var detected = try end_strings_of(gpa, nearest_tag_end);
            std.mem.swap(std.ArrayList([]const u8), &detected, &f.detected_end_strs);
            for (detected.items) |s| gpa.free(s);
            detected.deinit(gpa);
        },
        .tags_with_separator => |*f| {
            for (f.tags.items) |*tag| {
                try analyze_tag(gpa, diag, tag);
            }
        },
        .token_triggered_tags => |*f| {
            for (f.tags.items) |*tag| {
                try analyze_tag(gpa, diag, tag);
            }
            var detected = try end_token_ids_of(gpa, nearest_tag_end);
            std.mem.swap(std.ArrayList(i32), &detected, &f.detected_end_token_ids);
            detected.deinit(gpa);
        },
        .optional => |f| return analyze(gpa, diag, f.content, nearest_tag_end),
        .plus => |f| return analyze(gpa, diag, f.content, nearest_tag_end),
        .star => |f| return analyze(gpa, diag, f.content, nearest_tag_end),
        .repeat => |f| return analyze(gpa, diag, f.content, nearest_tag_end),
        .dispatch => |*f| {
            for (f.rules.items) |*rule| {
                try analyze(gpa, diag, rule.content, nearest_tag_end);
            }
        },
        .token_dispatch => |*f| {
            for (f.rules.items) |*rule| {
                try analyze(gpa, diag, rule.content, nearest_tag_end);
            }
        },
        else => {},
    }
}

// ============================ Grammar converter ============================

const FormatHashCtx = struct {
    pub fn hash(_: FormatHashCtx, key: *Format) u64 {
        var hasher = std.hash.Wyhash.init(0);
        key.hash(&hasher);
        return hasher.final();
    }

    pub fn eql(_: FormatHashCtx, a: *Format, b: *Format) bool {
        return Format.eql(a, b);
    }
};

/// The converter (Rust `struct StructuralTagConverter`). Cache keys are deep copies in the
/// converter's own arena (Rust clones the format into the map and drops it at the end).
pub const StructuralTagConverter = struct {
    gpa: Allocator,
    diag: ?*?StructuralTagErrorInfo = null,
    arena_state: *std.heap.ArenaAllocator,
    arena: Allocator,
    builder: GrammarBuilder,
    cache: std.HashMap(*Format, i32, FormatHashCtx, 80),

    pub fn new(gpa: Allocator) Allocator.Error!StructuralTagConverter {
        const arena_state = try gpa.create(std.heap.ArenaAllocator);
        arena_state.* = std.heap.ArenaAllocator.init(gpa);
        return .{
            .gpa = gpa,
            .arena_state = arena_state,
            .arena = arena_state.allocator(),
            .builder = try GrammarBuilder.new(gpa),
            .cache = std.HashMap(*Format, i32, FormatHashCtx, 80).init(gpa),
        };
    }

    pub fn deinit(self: *StructuralTagConverter) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            entry.key_ptr.*.deinit(self.arena);
        }
        self.cache.deinit();
        self.builder.deinit();
        const gpa = self.gpa;
        self.arena_state.deinit();
        gpa.destroy(self.arena_state);
    }

    pub fn convert(self: *StructuralTagConverter, format: *const Format) StructuralTagError!*Grammar {
        const root_ref_rule_id = try self.visit(format);
        const expr = self.builder.add_rule_ref(root_ref_rule_id) catch return error.OutOfMemory;
        const seq = self.builder.add_sequence(&.{expr}) catch return error.OutOfMemory;
        const choices = self.builder.add_choices(&.{seq}) catch return error.OutOfMemory;
        const root_rule_id = self.builder.add_rule_with_hint("root", choices) catch return error.OutOfMemory;
        return self.builder.into_grammar_with_root_id(self.gpa, root_rule_id) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };
    }

    fn visit(self: *StructuralTagConverter, format: *const Format) StructuralTagError!i32 {
        if (self.cache.get(@constCast(format))) |id| {
            return id;
        }
        const id = try self.visit_sub(format);
        const key = self.arena.create(Format) catch return error.OutOfMemory;
        key.* = format.clone(self.arena) catch return error.OutOfMemory;
        self.cache.put(key, id) catch return error.OutOfMemory;
        return id;
    }

    fn build_begin_expr(self: *StructuralTagConverter, tag: *const TagFormat) Allocator.Error!i32 {
        return switch (tag.begin) {
            .str => |s| self.builder.add_byte_string(s),
            .token => |tf| self.builder.add_token_set(&.{tf.resolved_token_id}),
        };
    }

    fn build_end_expr(self: *StructuralTagConverter, tag: *const TagFormat) Allocator.Error!i32 {
        switch (tag.end) {
            .token => |tf| return self.builder.add_token_set(&.{tf.resolved_token_id}),
            .strings => |ends| {
                if (ends.items.len == 1) {
                    if (ends.items[0].len == 0) {
                        return self.builder.add_empty_str();
                    }
                    return self.builder.add_byte_string(ends.items[0]);
                }
                var end_seq_ids: std.ArrayList(i32) = .empty;
                defer end_seq_ids.deinit(self.arena);
                for (ends.items) |s| {
                    const e = if (s.len == 0) try self.builder.add_empty_str() else try self.builder.add_byte_string(s);
                    try end_seq_ids.append(self.arena, try self.builder.add_sequence(&.{e}));
                }
                const choice = try self.builder.add_choices(end_seq_ids.items);
                const rule = try self.builder.add_rule_with_hint("tag_end", choice);
                return self.builder.add_rule_ref(rule);
            },
        }
    }

    /// Sets a rule's body and its token/character budgets. A zero-token region is empty by
    /// definition; that is materialized in the grammar because a budget of `-1` is also the
    /// parser's pre-first-token deadline sentinel.
    fn set_rule_body_and_budgets(self: *StructuralTagConverter, rule_id: i32, body_in: i32, max_tokens: ?i32, max_chars: ?i32) Allocator.Error!void {
        var body = body_in;
        if (max_tokens != null and max_tokens.? == 0) {
            const empty = try self.builder.add_empty_str();
            body = try self.builder.add_choices(&.{empty});
        }
        self.builder.update_rule_body(rule_id, body);
        if (max_tokens) |mt| self.builder.update_max_tokens(rule_id, mt);
        if (max_chars) |mc| self.builder.update_max_chars(rule_id, mc);
    }

    fn add_tag_dispatch_rule(self: *StructuralTagConverter, tag_rule_pairs: []const TagRulePairInit, loop_after_dispatch: bool, excludes: []const []const u8) Allocator.Error!i32 {
        var td = TagDispatch.empty();
        defer td.deinit(self.arena);
        for (tag_rule_pairs) |pair| {
            try td.tag_rule_pairs.append(self.arena, .{ .tag = try self.arena.dupe(u8, pair.tag), .rule_id = pair.rule_id });
        }
        td.loop_after_dispatch = loop_after_dispatch;
        for (excludes) |exclude| {
            try td.excludes.append(self.arena, try self.arena.dupe(u8, exclude));
        }
        return self.builder.add_tag_dispatch(&td);
    }

    fn add_token_tag_dispatch_rule(self: *StructuralTagConverter, trigger_rule_pairs: []const TriggerRulePair, loop_after_dispatch: bool, excludes: []const i32) Allocator.Error!i32 {
        var ttd = TokenTagDispatch.empty();
        defer ttd.deinit(self.arena);
        try ttd.trigger_rule_pairs.appendSlice(self.arena, trigger_rule_pairs);
        ttd.loop_after_dispatch = loop_after_dispatch;
        try ttd.excludes.appendSlice(self.arena, excludes);
        return self.builder.add_token_tag_dispatch(&ttd);
    }

    fn fail_invalid(self: *const StructuralTagConverter, message: []const u8) StructuralTagError {
        return fail_invalid_info(self.gpa, self.diag, message);
    }

    fn visit_sub(self: *StructuralTagConverter, format: *const Format) StructuralTagError!i32 {
        switch (format.*) {
            .const_string => |f| {
                const expr = if (f.value.len == 0) try self.builder.add_empty_str() else try self.builder.add_byte_string(f.value);
                const seq = try self.builder.add_sequence(&.{expr});
                const choices = try self.builder.add_choices(&.{seq});
                return self.builder.add_rule_with_hint("const_string", choices);
            },
            .json_schema => |f| {
                const json_format = json_format_mod.JsonFormat.from_name(f.style) orelse {
                    return self.fail_invalid_fmt("Unsupported parsing type: {s}", .{f.style});
                };
                var schema_diag: json_schema_converter.SchemaErrorInfo = undefined;
                const sub = json_schema_converter.json_schema_to_grammar(
                    self.gpa,
                    f.json_schema,
                    true,
                    null,
                    null,
                    true,
                    f.max_whitespace_cnt,
                    f.any_order,
                    json_format,
                    f.excludes,
                    &schema_diag,
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        defer self.gpa.free(schema_diag.message);
                        if (self.diag) |d| {
                            structural_tag_error.set_info(d, .{ .kind = error.InvalidJsonSchema, .message = self.gpa.dupe(u8, schema_diag.message) catch return error.OutOfMemory }, self.gpa) catch return error.OutOfMemory;
                        }
                        return error.InvalidJsonSchema;
                    },
                };
                defer sub.deinit();
                const normalized = functor.grammar_normalizer(self.gpa, sub) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidStructuralTag,
                };
                defer normalized.deinit();
                return functor.grammar_union_concat_mod.add_sub_grammar(&self.builder, normalized);
            },
            .grammar => |f| {
                var ebnf_diag: @import("../parser/mod.zig").EbnfErrorInfo = undefined;
                const sub = functor.grammar_normalizer_mod.from_ebnf(self.gpa, f.grammar, "root", &ebnf_diag) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        const message = @import("../parser/mod.zig").ebnf_error.message_of(ebnf_diag, self.gpa) catch return error.OutOfMemory;
                        defer self.gpa.free(message);
                        return self.fail_invalid(message);
                    },
                };
                defer sub.deinit();
                return functor.grammar_union_concat_mod.add_sub_grammar(&self.builder, sub);
            },
            .regex => |f| {
                var regex_diag: @import("regex_error.zig").RegexErrorInfo = undefined;
                const sub = @import("regex_converter.zig").from_regex(self.gpa, f.pattern, &regex_diag) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Regex => {
                        defer self.gpa.free(regex_diag.message);
                        const message = @import("regex_error.zig").format_message(&regex_diag, self.gpa) catch return error.OutOfMemory;
                        defer self.gpa.free(message);
                        return self.fail_invalid(message);
                    },
                };
                defer sub.deinit();
                return functor.grammar_union_concat_mod.add_sub_grammar(&self.builder, sub);
            },
            .any_text => |f| {
                var all_excludes: std.ArrayList([]const u8) = .empty;
                defer all_excludes.deinit(self.arena);
                try all_excludes.appendSlice(self.arena, f.excludes.items);
                for (f.detected_end_strs.items) |s| {
                    if (s.len != 0) try all_excludes.append(self.arena, s);
                }
                const body = if (all_excludes.items.len == 0) blk: {
                    const any = try self.builder.add_character_class_star(&.{CharacterClassElement.new(0, 0x10_FFFF)}, false);
                    const seq = try self.builder.add_sequence(&.{any});
                    break :blk try self.builder.add_choices(&.{seq});
                } else try self.add_tag_dispatch_rule(&.{}, false, all_excludes.items);
                const rule_id = try self.builder.add_empty_rule_with_hint("any_text");
                try self.set_rule_body_and_budgets(rule_id, body, f.max_tokens, f.max_chars);
                return rule_id;
            },
            .sequence => |f| {
                var refs: std.ArrayList(i32) = .empty;
                defer refs.deinit(self.arena);
                for (f.elements.items) |*e| {
                    const id = try self.visit(e);
                    try refs.append(self.arena, try self.builder.add_rule_ref(id));
                }
                const seq = try self.builder.add_sequence(refs.items);
                const choices = try self.builder.add_choices(&.{seq});
                return self.builder.add_rule_with_hint("sequence", choices);
            },
            .or_fmt => |f| {
                var seqs: std.ArrayList(i32) = .empty;
                defer seqs.deinit(self.arena);
                for (f.elements.items) |*e| {
                    const id = try self.visit(e);
                    const r = try self.builder.add_rule_ref(id);
                    try seqs.append(self.arena, try self.builder.add_sequence(&.{r}));
                }
                const choices = try self.builder.add_choices(seqs.items);
                return self.builder.add_rule_with_hint("or", choices);
            },
            .tag => |f| {
                const content_id = try self.visit(f.content);
                const begin = try self.build_begin_expr(&f);
                const content_ref = try self.builder.add_rule_ref(content_id);
                const end = try self.build_end_expr(&f);
                const seq = try self.builder.add_sequence(&.{ begin, content_ref, end });
                const choices = try self.builder.add_choices(&.{seq});
                return self.builder.add_rule_with_hint("tag", choices);
            },
            .triggered_tags => |f| return self.visit_triggered_tags(&f),
            .tags_with_separator => |f| return self.visit_tags_with_separator(&f),
            .optional => |f| {
                const content_id = try self.visit(f.content);
                const content_ref = try self.builder.add_rule_ref(content_id);
                const empty = try self.builder.add_empty_str();
                const seq = try self.builder.add_sequence(&.{content_ref});
                const choices = try self.builder.add_choices(&.{ empty, seq });
                return self.builder.add_rule_with_hint("optional", choices);
            },
            .plus => |f| {
                const content_id = try self.visit(f.content);
                const content_ref = try self.builder.add_rule_ref(content_id);
                const star_rule = try self.builder.add_empty_rule_with_hint("plus_star");
                const star_ref = try self.builder.add_rule_ref(star_rule);
                const empty = try self.builder.add_empty_str();
                const inner = try self.builder.add_sequence(&.{ content_ref, star_ref });
                const star_body = try self.builder.add_choices(&.{ empty, inner });
                self.builder.update_rule_body(star_rule, star_body);
                const plus = try self.builder.add_sequence(&.{ content_ref, star_ref });
                return self.builder.add_rule_with_hint("plus", plus);
            },
            .star => |f| {
                const content_id = try self.visit(f.content);
                const content_ref = try self.builder.add_rule_ref(content_id);
                const star_rule = try self.builder.add_empty_rule_with_hint("star");
                const star_ref = try self.builder.add_rule_ref(star_rule);
                const empty = try self.builder.add_empty_str();
                const inner = try self.builder.add_sequence(&.{ content_ref, star_ref });
                const star_body = try self.builder.add_choices(&.{ empty, inner });
                self.builder.update_rule_body(star_rule, star_body);
                return self.builder.add_rule_with_hint("star", star_ref);
            },
            .repeat => |f| {
                const content_id = try self.visit(f.content);
                const repeat = try self.builder.add_repeat(content_id, f.min, f.max);
                return self.builder.add_rule_with_hint("repeat", repeat);
            },
            .token => |f| {
                const token_set = try self.builder.add_token_set(&.{f.resolved_token_id});
                const seq = try self.builder.add_sequence(&.{token_set});
                const choices = try self.builder.add_choices(&.{seq});
                return self.builder.add_rule_with_hint("token", choices);
            },
            .exclude_token => |f| {
                var all: std.ArrayList(i32) = .empty;
                defer all.deinit(self.arena);
                try all.appendSlice(self.arena, f.resolved_token_ids.items);
                try all.appendSlice(self.arena, f.detected_end_token_ids.items);
                const expr = try self.builder.add_exclude_token_set(all.items);
                const seq = try self.builder.add_sequence(&.{expr});
                const choices = try self.builder.add_choices(&.{seq});
                return self.builder.add_rule_with_hint("exclude_token", choices);
            },
            .any_tokens => |f| {
                var all: std.ArrayList(i32) = .empty;
                defer all.deinit(self.arena);
                try all.appendSlice(self.arena, f.resolved_exclude_token_ids.items);
                try all.appendSlice(self.arena, f.detected_end_token_ids.items);
                const expr = try self.builder.add_exclude_token_set(all.items);
                const seq = try self.builder.add_sequence(&.{expr});
                const choices = try self.builder.add_choices(&.{seq});
                const inner_rule = try self.builder.add_rule_with_hint("any_tokens_inner", choices);
                const inner_ref = try self.builder.add_rule_ref(inner_rule);
                const star_rule = try self.builder.add_empty_rule_with_hint("any_tokens");
                const star_ref = try self.builder.add_rule_ref(star_rule);
                const empty = try self.builder.add_empty_str();
                const seq2 = try self.builder.add_sequence(&.{ inner_ref, star_ref });
                const star_body = try self.builder.add_choices(&.{ empty, seq2 });
                try self.set_rule_body_and_budgets(star_rule, star_body, f.max_tokens, null);
                return star_rule;
            },
            .token_triggered_tags => |f| return self.visit_token_triggered_tags(&f),
            .dispatch => |f| {
                var pairs: std.ArrayList(TagRulePairInit) = .empty;
                defer pairs.deinit(self.arena);
                for (f.rules.items) |*rule| {
                    const id = try self.visit(rule.content);
                    try pairs.append(self.arena, .{ .tag = rule.trigger, .rule_id = id });
                }
                const expr = try self.add_tag_dispatch_rule(pairs.items, f.loop_after_dispatch, f.excludes.items);
                return self.builder.add_rule_with_hint("tag_dispatch", expr);
            },
            .token_dispatch => |f| {
                var pairs: std.ArrayList(TriggerRulePair) = .empty;
                defer pairs.deinit(self.arena);
                for (f.rules.items, 0..) |*rule, i| {
                    const id = try self.visit(rule.content);
                    try pairs.append(self.arena, .{ .token_id = f.resolved_trigger_token_ids.items[i], .rule_id = id });
                }
                const expr = try self.add_token_tag_dispatch_rule(pairs.items, f.loop_after_dispatch, f.resolved_exclude_token_ids.items);
                return self.builder.add_rule_with_hint("token_tag_dispatch", expr);
            },
        }
    }

    fn visit_triggered_tags(self: *StructuralTagConverter, f: *const TriggeredTagsFormat) StructuralTagError!i32 {
        var trigger_to_tag_ids: std.ArrayList(std.ArrayList(usize)) = .empty;
        for (0..f.triggers.items.len) |_| {
            trigger_to_tag_ids.append(self.arena, .empty) catch return error.OutOfMemory;
        }
        var tag_content_rule_ids: std.ArrayList(i32) = .empty;

        for (f.tags.items, 0..) |*tag, it_tag| {
            const tag_begin = switch (tag.begin) {
                .str => |s| s,
                else => return self.fail_invalid("Tags in triggered_tags must have a string begin, not a token format"),
            };
            var matched: ?usize = null;
            for (f.triggers.items, 0..) |trigger, it_trigger| {
                if (std.mem.startsWith(u8, tag_begin, trigger)) {
                    if (matched != null) {
                        return self.fail_invalid("One tag matches multiple triggers in a triggered tags format");
                    }
                    matched = it_trigger;
                }
            }
            const matched_trigger = matched orelse {
                return self.fail_invalid("One tag does not match any trigger in a triggered tags format");
            };
            trigger_to_tag_ids.items[matched_trigger].append(self.arena, it_tag) catch return error.OutOfMemory;
            tag_content_rule_ids.append(self.arena, try self.visit(tag.content)) catch return error.OutOfMemory;
        }

        // Special case: at_least_one && stop_after_first.
        if (f.at_least_one and f.stop_after_first) {
            var choices: std.ArrayList(i32) = .empty;
            for (f.tags.items, 0..) |*tag, it_tag| {
                const begin = try self.build_begin_expr(tag);
                const r = try self.builder.add_rule_ref(tag_content_rule_ids.items[it_tag]);
                const end = try self.build_end_expr(tag);
                choices.append(self.arena, try self.builder.add_sequence(&.{ begin, r, end })) catch return error.OutOfMemory;
            }
            const choice = try self.builder.add_choices(choices.items);
            return self.builder.add_rule_with_hint("triggered_tags", choice);
        }

        // Normal case.
        var tag_rule_pairs: std.ArrayList(TagRulePairInit) = .empty;
        for (f.triggers.items, 0..) |trigger, it_trigger| {
            var choices: std.ArrayList(i32) = .empty;
            for (trigger_to_tag_ids.items[it_trigger].items) |tag_id| {
                const tag = &f.tags.items[tag_id];
                const tag_begin = switch (tag.begin) {
                    .str => |s| s,
                    else => unreachable, // checked above
                };
                const begin = try self.builder.add_byte_string(tag_begin[trigger.len..]);
                const r = try self.builder.add_rule_ref(tag_content_rule_ids.items[tag_id]);
                const end = try self.build_end_expr(tag);
                choices.append(self.arena, try self.builder.add_sequence(&.{ begin, r, end })) catch return error.OutOfMemory;
            }
            const choice = try self.builder.add_choices(choices.items);
            const sub_rule = try self.builder.add_rule_with_hint("triggered_tags_group", choice);
            tag_rule_pairs.append(self.arena, .{ .tag = trigger, .rule_id = sub_rule }) catch return error.OutOfMemory;
        }

        var all_excludes: std.ArrayList([]const u8) = .empty;
        defer all_excludes.deinit(self.arena);
        try all_excludes.appendSlice(self.arena, f.excludes.items);
        for (f.detected_end_strs.items) |s| {
            if (s.len != 0) try all_excludes.append(self.arena, s);
        }
        var rule_expr_id = try self.add_tag_dispatch_rule(tag_rule_pairs.items, !f.stop_after_first, all_excludes.items);

        if (f.at_least_one) {
            var first_choices: std.ArrayList(i32) = .empty;
            for (f.tags.items, 0..) |*tag, it_tag| {
                const begin = try self.build_begin_expr(tag);
                const r = try self.builder.add_rule_ref(tag_content_rule_ids.items[it_tag]);
                const end = try self.build_end_expr(tag);
                first_choices.append(self.arena, try self.builder.add_sequence(&.{ begin, r, end })) catch return error.OutOfMemory;
            }
            const first_choice = try self.builder.add_choices(first_choices.items);
            const first_rule = try self.builder.add_rule_with_hint("triggered_tags_first", first_choice);
            const dispatch_rule = try self.builder.add_rule_with_hint("triggered_tags_sub", rule_expr_id);
            const ref_first = try self.builder.add_rule_ref(first_rule);
            const ref_dispatch = try self.builder.add_rule_ref(dispatch_rule);
            const seq = try self.builder.add_sequence(&.{ ref_first, ref_dispatch });
            rule_expr_id = try self.builder.add_choices(&.{seq});
        }

        return self.builder.add_rule_with_hint("triggered_tags", rule_expr_id);
    }

    fn visit_tags_with_separator(self: *StructuralTagConverter, f: *const TagsWithSeparatorFormat) StructuralTagError!i32 {
        var choice_ids: std.ArrayList(i32) = .empty;
        defer choice_ids.deinit(self.arena);
        for (f.tags.items) |*tag| {
            var tag_copy = Format{ .tag = tag.* };
            const tag_rule_id = try self.visit(&tag_copy);
            const tag_ref = try self.builder.add_rule_ref(tag_rule_id);
            choice_ids.append(self.arena, try self.builder.add_sequence(&.{tag_ref})) catch return error.OutOfMemory;
        }
        const choice = try self.builder.add_choices(choice_ids.items);
        const all_tags_rule = try self.builder.add_rule_with_hint("tags_with_separator_tags", choice);
        const all_tags_ref = try self.builder.add_rule_ref(all_tags_rule);

        if (f.stop_after_first) {
            const body = if (f.at_least_one) blk: {
                const seq = try self.builder.add_sequence(&.{all_tags_ref});
                break :blk try self.builder.add_choices(&.{seq});
            } else blk: {
                const seq = try self.builder.add_sequence(&.{all_tags_ref});
                const empty = try self.builder.add_empty_str();
                break :blk try self.builder.add_choices(&.{ seq, empty });
            };
            return self.builder.add_rule_with_hint("tags_with_separator", body);
        }

        const sub_rule = try self.builder.add_empty_rule_with_hint("tags_with_separator_sub");
        const end_str_seq = try self.builder.add_empty_str();
        var sub_seq: std.ArrayList(i32) = .empty;
        if (f.separator.len != 0) {
            sub_seq.append(self.arena, try self.builder.add_byte_string(f.separator)) catch return error.OutOfMemory;
        }
        sub_seq.append(self.arena, all_tags_ref) catch return error.OutOfMemory;
        const sub_self_ref = try self.builder.add_rule_ref(sub_rule);
        sub_seq.append(self.arena, sub_self_ref) catch return error.OutOfMemory;
        const sub_seq_id = try self.builder.add_sequence(sub_seq.items);
        const sub_body = try self.builder.add_choices(&.{ sub_seq_id, end_str_seq });
        self.builder.update_rule_body(sub_rule, sub_body);

        const sub_ref = try self.builder.add_rule_ref(sub_rule);
        const main_seq = try self.builder.add_sequence(&.{ all_tags_ref, sub_ref });
        var choices: std.ArrayList(i32) = .empty;
        try choices.append(self.arena, main_seq);
        if (!f.at_least_one) {
            try choices.append(self.arena, end_str_seq);
        }
        const body = try self.builder.add_choices(choices.items);
        return self.builder.add_rule_with_hint("tags_with_separator", body);
    }

    fn visit_token_triggered_tags(self: *StructuralTagConverter, f: *const TokenTriggeredTagsFormat) StructuralTagError!i32 {
        var trigger_to_tag_ids: std.ArrayList(std.ArrayList(usize)) = .empty;
        for (0..f.trigger_tokens.items.len) |_| {
            trigger_to_tag_ids.append(self.arena, .empty) catch return error.OutOfMemory;
        }
        var tag_content_rule_ids: std.ArrayList(i32) = .empty;

        for (f.tags.items, 0..) |*tag, it_tag| {
            const begin_token_id = switch (tag.begin) {
                .token => |tf| tf.resolved_token_id,
                else => return self.fail_invalid("Tags in token_triggered_tags must have a token format begin, not a string"),
            };
            var matched: ?usize = null;
            for (f.resolved_trigger_token_ids.items, 0..) |tid, it| {
                if (tid == begin_token_id) {
                    if (matched != null) {
                        return self.fail_invalid("Tag matches multiple triggers");
                    }
                    matched = it;
                }
            }
            const matched_trigger = matched orelse {
                return self.fail_invalid("Tag does not match any trigger");
            };
            trigger_to_tag_ids.items[matched_trigger].append(self.arena, it_tag) catch return error.OutOfMemory;
            tag_content_rule_ids.append(self.arena, try self.visit(tag.content)) catch return error.OutOfMemory;
        }

        if (f.at_least_one and f.stop_after_first) {
            var choices: std.ArrayList(i32) = .empty;
            for (f.tags.items, 0..) |*tag, it_tag| {
                const begin = try self.build_begin_expr(tag);
                const r = try self.builder.add_rule_ref(tag_content_rule_ids.items[it_tag]);
                const end = try self.build_end_expr(tag);
                choices.append(self.arena, try self.builder.add_sequence(&.{ begin, r, end })) catch return error.OutOfMemory;
            }
            const choice = try self.builder.add_choices(choices.items);
            return self.builder.add_rule_with_hint("token_triggered_tags", choice);
        }

        var trigger_rule_pairs: std.ArrayList(TriggerRulePair) = .empty;
        for (f.resolved_trigger_token_ids.items, 0..) |trigger_id, it| {
            var choices: std.ArrayList(i32) = .empty;
            for (trigger_to_tag_ids.items[it].items) |tag_id| {
                const tag = &f.tags.items[tag_id];
                const r = try self.builder.add_rule_ref(tag_content_rule_ids.items[tag_id]);
                const end = try self.build_end_expr(tag);
                choices.append(self.arena, try self.builder.add_sequence(&.{ r, end })) catch return error.OutOfMemory;
            }
            const choice = try self.builder.add_choices(choices.items);
            const sub_rule = try self.builder.add_rule_with_hint("token_triggered_tags_group", choice);
            trigger_rule_pairs.append(self.arena, .{ .token_id = trigger_id, .rule_id = sub_rule }) catch return error.OutOfMemory;
        }

        var all_excludes: std.ArrayList(i32) = .empty;
        defer all_excludes.deinit(self.arena);
        try all_excludes.appendSlice(self.arena, f.resolved_exclude_token_ids.items);
        try all_excludes.appendSlice(self.arena, f.detected_end_token_ids.items);
        var rule_expr_id = try self.add_token_tag_dispatch_rule(trigger_rule_pairs.items, !f.stop_after_first, all_excludes.items);

        if (f.at_least_one) {
            var first_choices: std.ArrayList(i32) = .empty;
            for (f.tags.items, 0..) |*tag, it_tag| {
                const begin = try self.build_begin_expr(tag);
                const r = try self.builder.add_rule_ref(tag_content_rule_ids.items[it_tag]);
                const end = try self.build_end_expr(tag);
                first_choices.append(self.arena, try self.builder.add_sequence(&.{ begin, r, end })) catch return error.OutOfMemory;
            }
            const first_choice = try self.builder.add_choices(first_choices.items);
            const first_rule = try self.builder.add_rule_with_hint("token_triggered_tags_first", first_choice);
            const dispatch_rule = try self.builder.add_rule_with_hint("token_triggered_tags_sub", rule_expr_id);
            const ref_first = try self.builder.add_rule_ref(first_rule);
            const ref_dispatch = try self.builder.add_rule_ref(dispatch_rule);
            const seq = try self.builder.add_sequence(&.{ ref_first, ref_dispatch });
            rule_expr_id = try self.builder.add_choices(&.{seq});
        }

        return self.builder.add_rule_with_hint("token_triggered_tags", rule_expr_id);
    }

    fn fail_invalid_fmt(self: *const StructuralTagConverter, comptime fmt: []const u8, args: anytype) StructuralTagError {
        const message = std.fmt.allocPrint(self.gpa, fmt, args) catch return error.OutOfMemory;
        defer self.gpa.free(message);
        return fail_invalid_info(self.gpa, self.diag, message);
    }
};

fn fail_invalid_info(gpa: Allocator, diag: ?*?StructuralTagErrorInfo, message: []const u8) StructuralTagError {
    if (diag) |d| {
        d.* = .{ .kind = error.InvalidStructuralTag, .message = gpa.dupe(u8, message) catch return error.OutOfMemory };
    }
    return error.InvalidStructuralTag;
}

fn fail_invalid_fmt(gpa: Allocator, diag: ?*?StructuralTagErrorInfo, comptime fmt: []const u8, args: anytype) StructuralTagError {
    const message = std.fmt.allocPrint(gpa, fmt, args) catch return error.OutOfMemory;
    defer gpa.free(message);
    return fail_invalid_info(gpa, diag, message);
}
