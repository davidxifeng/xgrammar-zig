//! Resolves, analyzes, and converts a structural-tag `Format` tree into a normalized
//! `Grammar` (`structural_tag_converter.rs`).
//!
//! Combines `StructuralTagTokenResolver`, `StructuralTagAnalyzer`, and
//! `StructuralTagConverter`. All AST mutations during resolution and analysis stay in
//! the parsed format's arena; `StructuralTagConverter` caches sub-formats by value via
//! `FormatHashContext` and transfers the resulting unnormalized grammar cleanly before
//! `functor.normalize` (freeing the intermediate grammar on every return or error path).

const std = @import("std");
const Allocator = std.mem.Allocator;

const Diagnostic = @import("../../Diagnostic.zig").Diagnostic;
const functor = @import("../../functor.zig");
const grammar_mod = @import("../../grammar.zig");
const TokenizerInfo = @import("../../tokenizer.zig").TokenizerInfo;
const json_schema = @import("../json_schema/converter.zig");
const JsonFormat = @import("../json_schema/spec.zig").JsonFormat;
const regex = @import("../regex.zig");
const format = @import("format.zig");
const parser = @import("parser.zig");

const CharacterClassElement = grammar_mod.CharacterClassElement;
const Grammar = grammar_mod.Grammar;
const GrammarBuilder = grammar_mod.GrammarBuilder;
const TagDispatch = grammar_mod.TagDispatch;
const TokenTagDispatch = grammar_mod.TokenTagDispatch;
const TriggerRulePair = grammar_mod.TriggerRulePair;

const Format = format.Format;
const FormatHashContext = format.FormatHashContext;
const IntOrString = format.IntOrString;
const TagEnd = format.TagEnd;
const TagFormat = format.TagFormat;
const TagsWithSeparatorFormat = format.TagsWithSeparatorFormat;
const TokenFormat = format.TokenFormat;
const TokenTriggeredTagsFormat = format.TokenTriggeredTagsFormat;
const TriggeredTagsFormat = format.TriggeredTagsFormat;

pub const StructuralTagError = parser.StructuralTagError;

/// `(tag, rule_id)` pair passed to `addTagDispatchRule`.
const TagRulePairInit = struct {
    tag: []const u8,
    rule_id: i32,
};

/// Constructs a normalized `Grammar` from a structural-tag JSON string.
///
/// String-keyed token references require a tokenizer; use
/// `fromStructuralTagWithTokenizer` for those (integer token ids work without one).
/// On failure, `diag` (if non-null) receives `.structural_tag_invalid_json`,
/// `.structural_tag_invalid_schema`, or `.structural_tag_invalid`.
pub fn fromStructuralTag(
    gpa: Allocator,
    json: []const u8,
    diag: ?*Diagnostic,
) StructuralTagError!Grammar {
    return buildStructuralTag(gpa, json, null, diag);
}

/// Constructs a normalized `Grammar` from a structural-tag JSON string, resolving string
/// token references against `tokenizer_info.decodedVocab()`.
pub fn fromStructuralTagWithTokenizer(
    gpa: Allocator,
    json: []const u8,
    tokenizer_info: *const TokenizerInfo,
    diag: ?*Diagnostic,
) StructuralTagError!Grammar {
    return buildStructuralTag(gpa, json, tokenizer_info.decodedVocab(), diag);
}

fn buildStructuralTag(
    gpa: Allocator,
    json: []const u8,
    vocab: ?[]const []const u8,
    diag: ?*Diagnostic,
) StructuralTagError!Grammar {
    var parsed = try parser.parseStructuralTag(gpa, json, diag);
    defer parsed.deinit();
    return convertFormatToGrammar(gpa, parsed.allocator(), &parsed.root, vocab, diag);
}

/// Resolves, analyzes, converts, and normalizes an already-parsed `Format` tree.
/// Mutations during token resolution and end-string analysis are allocated in `ast_arena`.
pub fn convertFormatToGrammar(
    gpa: Allocator,
    ast_arena: Allocator,
    root: *Format,
    vocab: ?[]const []const u8,
    diag: ?*Diagnostic,
) StructuralTagError!Grammar {
    try resolveFormat(ast_arena, gpa, diag, root, vocab);
    try analyze(ast_arena, gpa, diag, root, null);

    var conv = try StructuralTagConverter.init(gpa, diag);
    defer conv.deinit();

    var grammar = try conv.convert(root);
    defer grammar.deinit();

    return functor.normalize(gpa, &grammar) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return parser.failFmt(
            error.InvalidStructuralTag,
            diag,
            gpa,
            .structural_tag_invalid,
            "Failed to normalize structural tag grammar: {s}",
            .{@errorName(err)},
        ),
    };
}

// ============================ Token resolver ============================

fn lookupVocabToken(
    gpa: Allocator,
    diag: ?*Diagnostic,
    token_str: []const u8,
    vocab: ?[]const []const u8,
) StructuralTagError!i32 {
    const v = vocab orelse {
        return parser.failStatic(
            error.InvalidStructuralTag,
            diag,
            .structural_tag_invalid,
            "Token string resolution requires tokenizer_info",
        );
    };
    for (v, 0..) |candidate, i| {
        if (std.mem.eql(u8, candidate, token_str)) {
            return @intCast(i);
        }
    }
    return parser.failFmt(
        error.InvalidStructuralTag,
        diag,
        gpa,
        .structural_tag_invalid,
        "Token string \"{s}\" not found in vocabulary",
        .{token_str},
    );
}

fn resolveToken(
    gpa: Allocator,
    diag: ?*Diagnostic,
    tf: *TokenFormat,
    vocab: ?[]const []const u8,
) StructuralTagError!void {
    if (tf.resolved_token_id >= 0) return;
    const s = switch (tf.token) {
        .int => return,
        .str => |s| s,
    };
    tf.resolved_token_id = try lookupVocabToken(gpa, diag, s, vocab);
}

fn resolveVec(
    ast_arena: Allocator,
    gpa: Allocator,
    diag: ?*Diagnostic,
    input: []const IntOrString,
    vocab: ?[]const []const u8,
    out: *std.ArrayList(i32),
) StructuralTagError!void {
    for (input) |item| {
        switch (item) {
            .int => |i| try out.append(ast_arena, i),
            .str => |s| try out.append(ast_arena, try lookupVocabToken(gpa, diag, s, vocab)),
        }
    }
}

fn resolveTag(
    ast_arena: Allocator,
    gpa: Allocator,
    diag: ?*Diagnostic,
    tag: *TagFormat,
    vocab: ?[]const []const u8,
) StructuralTagError!void {
    switch (tag.begin) {
        .str => {},
        .token => |*tf| try resolveToken(gpa, diag, tf, vocab),
    }
    switch (tag.end) {
        .strings => {},
        .token => |*tf| try resolveToken(gpa, diag, tf, vocab),
    }
    try resolveFormat(ast_arena, gpa, diag, tag.content, vocab);
}

fn resolveFormat(
    ast_arena: Allocator,
    gpa: Allocator,
    diag: ?*Diagnostic,
    fmt: *Format,
    vocab: ?[]const []const u8,
) StructuralTagError!void {
    switch (fmt.*) {
        .token => |*f| return resolveToken(gpa, diag, f, vocab),
        .exclude_token => |*f| {
            f.resolved_token_ids.clearRetainingCapacity();
            try resolveVec(ast_arena, gpa, diag, f.exclude_tokens.items, vocab, &f.resolved_token_ids);
        },
        .any_tokens => |*f| {
            f.resolved_exclude_token_ids.clearRetainingCapacity();
            try resolveVec(ast_arena, gpa, diag, f.exclude_tokens.items, vocab, &f.resolved_exclude_token_ids);
        },
        .token_triggered_tags => |*f| {
            f.resolved_trigger_token_ids.clearRetainingCapacity();
            try resolveVec(ast_arena, gpa, diag, f.trigger_tokens.items, vocab, &f.resolved_trigger_token_ids);
            f.resolved_exclude_token_ids.clearRetainingCapacity();
            try resolveVec(ast_arena, gpa, diag, f.exclude_tokens.items, vocab, &f.resolved_exclude_token_ids);
            for (f.tags.items) |*tag| {
                try resolveTag(ast_arena, gpa, diag, tag, vocab);
            }
        },
        .token_dispatch => |*f| {
            var triggers: std.ArrayList(IntOrString) = .empty;
            defer triggers.deinit(gpa);
            try triggers.ensureTotalCapacity(gpa, f.rules.items.len);
            for (f.rules.items) |rule| {
                triggers.appendAssumeCapacity(rule.trigger);
            }
            f.resolved_trigger_token_ids.clearRetainingCapacity();
            try resolveVec(ast_arena, gpa, diag, triggers.items, vocab, &f.resolved_trigger_token_ids);
            f.resolved_exclude_token_ids.clearRetainingCapacity();
            try resolveVec(ast_arena, gpa, diag, f.exclude_tokens.items, vocab, &f.resolved_exclude_token_ids);
            for (f.rules.items) |*rule| {
                try resolveFormat(ast_arena, gpa, diag, rule.content, vocab);
            }
        },
        .dispatch => |*f| {
            for (f.rules.items) |*rule| {
                try resolveFormat(ast_arena, gpa, diag, rule.content, vocab);
            }
        },
        .tag => |*f| return resolveTag(ast_arena, gpa, diag, f, vocab),
        .sequence => |*f| {
            for (f.elements.items) |*e| {
                try resolveFormat(ast_arena, gpa, diag, e, vocab);
            }
        },
        .or_fmt => |*f| {
            for (f.elements.items) |*e| {
                try resolveFormat(ast_arena, gpa, diag, e, vocab);
            }
        },
        .triggered_tags => |*f| {
            for (f.tags.items) |*tag| {
                try resolveTag(ast_arena, gpa, diag, tag, vocab);
            }
        },
        .tags_with_separator => |*f| {
            for (f.tags.items) |*tag| {
                try resolveTag(ast_arena, gpa, diag, tag, vocab);
            }
        },
        .optional => |f| return resolveFormat(ast_arena, gpa, diag, f.content, vocab),
        .plus => |f| return resolveFormat(ast_arena, gpa, diag, f.content, vocab),
        .star => |f| return resolveFormat(ast_arena, gpa, diag, f.content, vocab),
        .repeat => |f| return resolveFormat(ast_arena, gpa, diag, f.content, vocab),
        else => {},
    }
}

// ============================ Analyzer ============================

fn endStringsOf(ast_arena: Allocator, nearest_tag_end: ?*const TagEnd) Allocator.Error!std.ArrayList([]const u8) {
    var out: std.ArrayList([]const u8) = .empty;
    if (nearest_tag_end) |end| {
        switch (end.*) {
            .strings => |v| {
                try out.ensureTotalCapacity(ast_arena, v.items.len);
                for (v.items) |s| {
                    out.appendAssumeCapacity(try ast_arena.dupe(u8, s));
                }
            },
            else => {},
        }
    }
    return out;
}

fn endTokenIdsOf(ast_arena: Allocator, nearest_tag_end: ?*const TagEnd) Allocator.Error!std.ArrayList(i32) {
    var out: std.ArrayList(i32) = .empty;
    if (nearest_tag_end) |end| {
        switch (end.*) {
            .token => |tf| try out.append(ast_arena, tf.resolved_token_id),
            else => {},
        }
    }
    return out;
}

fn isUnlimited(fmt: *const Format) bool {
    return switch (fmt.*) {
        .any_text, .triggered_tags, .token_triggered_tags, .dispatch, .token_dispatch, .any_tokens, .tags_with_separator, .star, .plus => true,
        .sequence => |f| f.is_unlimited,
        .or_fmt => |f| f.is_unlimited,
        .optional => |f| isUnlimited(f.content),
        .repeat => |f| f.max == -1 or (f.max != 0 and isUnlimited(f.content)),
        else => false,
    };
}

fn isExcluded(fmt: *const Format) bool {
    return switch (fmt.*) {
        .any_text => |f| f.excludes.items.len != 0,
        .triggered_tags => |f| f.excludes.items.len != 0,
        .token_triggered_tags => |f| f.exclude_tokens.items.len != 0,
        .dispatch => |f| f.excludes.items.len != 0,
        .token_dispatch => |f| f.exclude_tokens.items.len != 0,
        .any_tokens => |f| f.exclude_tokens.items.len != 0,
        else => false,
    };
}

fn analyzeTag(
    ast_arena: Allocator,
    gpa: Allocator,
    diag: ?*Diagnostic,
    tag: *TagFormat,
) StructuralTagError!void {
    const end = tag.end;
    try analyze(ast_arena, gpa, diag, tag.content, &end);
    if (isUnlimited(tag.content)) {
        switch (tag.end) {
            .strings => |ends| {
                var has_non_empty = false;
                for (ends.items) |s| {
                    if (s.len != 0) has_non_empty = true;
                }
                if (!has_non_empty and !isExcluded(tag.content)) {
                    return parser.failStatic(
                        error.InvalidStructuralTag,
                        diag,
                        .structural_tag_invalid,
                        "When the content is unlimited, at least one end string must be non-empty",
                    );
                }
            },
            else => {},
        }
    }
}

fn analyze(
    ast_arena: Allocator,
    gpa: Allocator,
    diag: ?*Diagnostic,
    fmt: *Format,
    nearest_tag_end: ?*const TagEnd,
) StructuralTagError!void {
    switch (fmt.*) {
        .any_text => |*f| {
            f.detected_end_strs = try endStringsOf(ast_arena, nearest_tag_end);
        },
        .exclude_token => |*f| {
            f.detected_end_token_ids = try endTokenIdsOf(ast_arena, nearest_tag_end);
        },
        .any_tokens => |*f| {
            f.detected_end_token_ids = try endTokenIdsOf(ast_arena, nearest_tag_end);
        },
        .sequence => |*f| {
            var any_unlimited = false;
            for (f.elements.items) |*e| {
                try analyze(ast_arena, gpa, diag, e, nearest_tag_end);
                any_unlimited = any_unlimited or (isUnlimited(e) and !isExcluded(e));
            }
            f.is_unlimited = any_unlimited;
        },
        .or_fmt => |*f| {
            var any_unlimited = false;
            for (f.elements.items) |*e| {
                try analyze(ast_arena, gpa, diag, e, nearest_tag_end);
                any_unlimited = any_unlimited or (isUnlimited(e) and !isExcluded(e));
            }
            f.is_unlimited = any_unlimited;
        },
        .tag => |*f| return analyzeTag(ast_arena, gpa, diag, f),
        .triggered_tags => |*f| {
            for (f.tags.items) |*tag| {
                try analyzeTag(ast_arena, gpa, diag, tag);
            }
            f.detected_end_strs = try endStringsOf(ast_arena, nearest_tag_end);
        },
        .tags_with_separator => |*f| {
            for (f.tags.items) |*tag| {
                try analyzeTag(ast_arena, gpa, diag, tag);
            }
        },
        .token_triggered_tags => |*f| {
            for (f.tags.items) |*tag| {
                try analyzeTag(ast_arena, gpa, diag, tag);
            }
            f.detected_end_token_ids = try endTokenIdsOf(ast_arena, nearest_tag_end);
        },
        .optional => |f| return analyze(ast_arena, gpa, diag, f.content, nearest_tag_end),
        .plus => |f| return analyze(ast_arena, gpa, diag, f.content, nearest_tag_end),
        .star => |f| return analyze(ast_arena, gpa, diag, f.content, nearest_tag_end),
        .repeat => |f| return analyze(ast_arena, gpa, diag, f.content, nearest_tag_end),
        .dispatch => |*f| {
            for (f.rules.items) |*rule| {
                try analyze(ast_arena, gpa, diag, rule.content, nearest_tag_end);
            }
        },
        .token_dispatch => |*f| {
            for (f.rules.items) |*rule| {
                try analyze(ast_arena, gpa, diag, rule.content, nearest_tag_end);
            }
        },
        else => {},
    }
}

// ============================ Grammar converter ============================

/// Converts a resolved and analyzed `Format` tree into an unnormalized `Grammar`.
///
/// Deduplicates identical sub-formats in `cache` keyed by value (`FormatHashContext`);
/// the caller's `Format` arena must remain alive until `convert` returns.
pub const StructuralTagConverter = struct {
    gpa: Allocator,
    diag: ?*Diagnostic = null,
    arena_state: std.heap.ArenaAllocator,
    builder: GrammarBuilder,
    cache: std.HashMapUnmanaged(Format, i32, FormatHashContext, 80),

    pub fn init(gpa: Allocator, diag: ?*Diagnostic) Allocator.Error!StructuralTagConverter {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        errdefer arena_state.deinit();
        const builder = try GrammarBuilder.init(gpa);
        return .{
            .gpa = gpa,
            .diag = diag,
            .arena_state = arena_state,
            .builder = builder,
            .cache = .empty,
        };
    }

    pub fn deinit(self: *StructuralTagConverter) void {
        self.cache.deinit(self.gpa);
        self.builder.deinit();
        self.arena_state.deinit();
        self.* = undefined;
    }

    inline fn scratch(self: *StructuralTagConverter) Allocator {
        return self.arena_state.allocator();
    }

    pub fn convert(self: *StructuralTagConverter, fmt: *const Format) StructuralTagError!Grammar {
        const root_ref_rule_id = try self.visit(fmt);
        const expr = try self.builder.addRuleRef(root_ref_rule_id);
        const seq = try self.builder.addSequence(&.{expr});
        const choices = try self.builder.addChoices(&.{seq});
        const root_rule_id = try self.builder.addRuleWithHint("root", choices);
        return self.builder.intoGrammarWithRootId(root_rule_id);
    }

    fn visit(self: *StructuralTagConverter, fmt: *const Format) StructuralTagError!i32 {
        if (self.cache.get(fmt.*)) |id| {
            return id;
        }
        const id = try self.visitSub(fmt);
        try self.cache.put(self.gpa, fmt.*, id);
        return id;
    }

    fn buildBeginExpr(self: *StructuralTagConverter, tag: *const TagFormat) Allocator.Error!i32 {
        return switch (tag.begin) {
            .str => |s| self.builder.addByteString(s),
            .token => |tf| self.builder.addTokenSet(&.{tf.resolved_token_id}),
        };
    }

    fn buildEndExpr(self: *StructuralTagConverter, tag: *const TagFormat) Allocator.Error!i32 {
        switch (tag.end) {
            .token => |tf| return self.builder.addTokenSet(&.{tf.resolved_token_id}),
            .strings => |ends| {
                if (ends.items.len == 1) {
                    if (ends.items[0].len == 0) {
                        return self.builder.addEmptyStr();
                    }
                    return self.builder.addByteString(ends.items[0]);
                }
                const aa = self.scratch();
                var end_seq_ids: std.ArrayList(i32) = .empty;
                defer end_seq_ids.deinit(aa);
                for (ends.items) |s| {
                    const e = if (s.len == 0) try self.builder.addEmptyStr() else try self.builder.addByteString(s);
                    try end_seq_ids.append(aa, try self.builder.addSequence(&.{e}));
                }
                const choice = try self.builder.addChoices(end_seq_ids.items);
                const rule = try self.builder.addRuleWithHint("tag_end", choice);
                return self.builder.addRuleRef(rule);
            },
        }
    }

    /// Sets a rule's body and its token/character budgets. A zero-token region is empty by
    /// definition; that is materialized in the grammar because `-1` is also the parser's
    /// pre-first-token sentinel.
    fn setRuleBodyAndBudgets(
        self: *StructuralTagConverter,
        rule_id: i32,
        body_in: i32,
        max_tokens: ?i32,
        max_chars: ?i32,
    ) Allocator.Error!void {
        var body = body_in;
        if (max_tokens != null and max_tokens.? == 0) {
            const empty = try self.builder.addEmptyStr();
            body = try self.builder.addChoices(&.{empty});
        }
        self.builder.updateRuleBody(rule_id, body);
        if (max_tokens) |mt| self.builder.updateMaxTokens(rule_id, mt);
        if (max_chars) |mc| self.builder.updateMaxChars(rule_id, mc);
    }

    fn addTagDispatchRule(
        self: *StructuralTagConverter,
        tag_rule_pairs: []const TagRulePairInit,
        loop_after_dispatch: bool,
        excludes: []const []const u8,
    ) Allocator.Error!i32 {
        var td: TagDispatch = .{ .loop_after_dispatch = loop_after_dispatch };
        defer td.deinit(self.gpa);
        try td.tag_rule_pairs.ensureTotalCapacity(self.gpa, tag_rule_pairs.len);
        for (tag_rule_pairs) |pair| {
            td.tag_rule_pairs.appendAssumeCapacity(.{
                .tag = try self.gpa.dupe(u8, pair.tag),
                .rule_id = pair.rule_id,
            });
        }
        try td.excludes.ensureTotalCapacity(self.gpa, excludes.len);
        for (excludes) |exclude| {
            td.excludes.appendAssumeCapacity(try self.gpa.dupe(u8, exclude));
        }
        return self.builder.addTagDispatch(&td);
    }

    fn addTokenTagDispatchRule(
        self: *StructuralTagConverter,
        trigger_rule_pairs: []const TriggerRulePair,
        loop_after_dispatch: bool,
        excludes: []const i32,
    ) Allocator.Error!i32 {
        var ttd: TokenTagDispatch = .{ .loop_after_dispatch = loop_after_dispatch };
        defer ttd.deinit(self.gpa);
        try ttd.trigger_rule_pairs.appendSlice(self.gpa, trigger_rule_pairs);
        try ttd.excludes.appendSlice(self.gpa, excludes);
        return self.builder.addTokenTagDispatch(&ttd);
    }

    fn failInvalid(self: *const StructuralTagConverter, message: []const u8) StructuralTagError {
        return parser.failStatic(error.InvalidStructuralTag, self.diag, .structural_tag_invalid, message);
    }

    fn failInvalidFmt(self: *const StructuralTagConverter, comptime fmt_str: []const u8, args: anytype) StructuralTagError {
        return parser.failFmt(error.InvalidStructuralTag, self.diag, self.gpa, .structural_tag_invalid, fmt_str, args);
    }

    fn visitSub(self: *StructuralTagConverter, fmt: *const Format) StructuralTagError!i32 {
        const aa = self.scratch();
        switch (fmt.*) {
            .const_string => |f| {
                const expr = if (f.value.len == 0) try self.builder.addEmptyStr() else try self.builder.addByteString(f.value);
                const seq = try self.builder.addSequence(&.{expr});
                const choices = try self.builder.addChoices(&.{seq});
                return self.builder.addRuleWithHint("const_string", choices);
            },
            .json_schema => |f| {
                const json_format = JsonFormat.fromName(f.style) orelse {
                    return self.failInvalidFmt("Unsupported parsing type: {s}", .{f.style});
                };
                var schema_diag: Diagnostic = .{};
                defer schema_diag.deinit(self.gpa);
                var sub = json_schema.jsonSchemaToGrammar(self.gpa, f.json_schema, .{
                    .any_whitespace = true,
                    .strict_mode = true,
                    .max_whitespace_cnt = f.max_whitespace_cnt,
                    .any_order = f.any_order,
                    .json_format = json_format,
                    .excludes = f.excludes,
                    .diag = if (self.diag != null) &schema_diag else null,
                }) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        if (self.diag) |d| {
                            d.setFmt(self.gpa, .structural_tag_invalid_schema, "{f}", .{schema_diag}) catch return error.OutOfMemory;
                        }
                        return error.InvalidJsonSchema;
                    },
                };
                defer sub.deinit();
                var normalized = functor.normalize(self.gpa, &sub) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return self.failInvalidFmt("Failed to normalize JSON schema grammar: {s}", .{@errorName(err)}),
                };
                defer normalized.deinit();
                return functor.addSubGrammar(&self.builder, &normalized);
            },
            .grammar => |f| {
                var ebnf_diag: Diagnostic = .{};
                defer ebnf_diag.deinit(self.gpa);
                var sub = functor.fromEbnf(
                    self.gpa,
                    f.grammar,
                    "root",
                    if (self.diag != null) &ebnf_diag else null,
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        if (self.diag) |d| {
                            d.setFmt(self.gpa, .structural_tag_invalid, "{f}", .{ebnf_diag}) catch return error.OutOfMemory;
                        }
                        return error.InvalidStructuralTag;
                    },
                };
                defer sub.deinit();
                return functor.addSubGrammar(&self.builder, &sub);
            },
            .regex => |f| {
                var regex_diag: Diagnostic = .{};
                defer regex_diag.deinit(self.gpa);
                var sub = regex.fromRegex(
                    self.gpa,
                    f.pattern,
                    if (self.diag != null) &regex_diag else null,
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Regex => {
                        if (self.diag) |d| {
                            d.setFmt(self.gpa, .structural_tag_invalid, "{f}", .{regex_diag}) catch return error.OutOfMemory;
                        }
                        return error.InvalidStructuralTag;
                    },
                };
                defer sub.deinit();
                return functor.addSubGrammar(&self.builder, &sub);
            },
            .any_text => |f| {
                var all_excludes: std.ArrayList([]const u8) = .empty;
                defer all_excludes.deinit(aa);
                try all_excludes.appendSlice(aa, f.excludes.items);
                for (f.detected_end_strs.items) |s| {
                    if (s.len != 0) try all_excludes.append(aa, s);
                }
                const body = if (all_excludes.items.len == 0) blk: {
                    const any = try self.builder.addCharacterClassStar(&.{CharacterClassElement.init(0, 0x10_FFFF)}, false);
                    const seq = try self.builder.addSequence(&.{any});
                    break :blk try self.builder.addChoices(&.{seq});
                } else try self.addTagDispatchRule(&.{}, false, all_excludes.items);
                const rule_id = try self.builder.addEmptyRuleWithHint("any_text");
                try self.setRuleBodyAndBudgets(rule_id, body, f.max_tokens, f.max_chars);
                return rule_id;
            },
            .sequence => |f| {
                var refs: std.ArrayList(i32) = .empty;
                defer refs.deinit(aa);
                for (f.elements.items) |*e| {
                    const id = try self.visit(e);
                    try refs.append(aa, try self.builder.addRuleRef(id));
                }
                const seq = try self.builder.addSequence(refs.items);
                const choices = try self.builder.addChoices(&.{seq});
                return self.builder.addRuleWithHint("sequence", choices);
            },
            .or_fmt => |f| {
                var seqs: std.ArrayList(i32) = .empty;
                defer seqs.deinit(aa);
                for (f.elements.items) |*e| {
                    const id = try self.visit(e);
                    const r = try self.builder.addRuleRef(id);
                    try seqs.append(aa, try self.builder.addSequence(&.{r}));
                }
                const choices = try self.builder.addChoices(seqs.items);
                return self.builder.addRuleWithHint("or", choices);
            },
            .tag => |f| {
                const content_id = try self.visit(f.content);
                const begin = try self.buildBeginExpr(&f);
                const content_ref = try self.builder.addRuleRef(content_id);
                const end = try self.buildEndExpr(&f);
                const seq = try self.builder.addSequence(&.{ begin, content_ref, end });
                const choices = try self.builder.addChoices(&.{seq});
                return self.builder.addRuleWithHint("tag", choices);
            },
            .triggered_tags => |f| return self.visitTriggeredTags(&f),
            .tags_with_separator => |f| return self.visitTagsWithSeparator(&f),
            .optional => |f| {
                const content_id = try self.visit(f.content);
                const content_ref = try self.builder.addRuleRef(content_id);
                const empty = try self.builder.addEmptyStr();
                const seq = try self.builder.addSequence(&.{content_ref});
                const choices = try self.builder.addChoices(&.{ empty, seq });
                return self.builder.addRuleWithHint("optional", choices);
            },
            .plus => |f| {
                const content_id = try self.visit(f.content);
                const content_ref = try self.builder.addRuleRef(content_id);
                const star_rule = try self.builder.addEmptyRuleWithHint("plus_star");
                const star_ref = try self.builder.addRuleRef(star_rule);
                const empty = try self.builder.addEmptyStr();
                const inner = try self.builder.addSequence(&.{ content_ref, star_ref });
                const star_body = try self.builder.addChoices(&.{ empty, inner });
                self.builder.updateRuleBody(star_rule, star_body);
                const plus = try self.builder.addSequence(&.{ content_ref, star_ref });
                return self.builder.addRuleWithHint("plus", plus);
            },
            .star => |f| {
                const content_id = try self.visit(f.content);
                const content_ref = try self.builder.addRuleRef(content_id);
                const star_rule = try self.builder.addEmptyRuleWithHint("star");
                const star_ref = try self.builder.addRuleRef(star_rule);
                const empty = try self.builder.addEmptyStr();
                const inner = try self.builder.addSequence(&.{ content_ref, star_ref });
                const star_body = try self.builder.addChoices(&.{ empty, inner });
                self.builder.updateRuleBody(star_rule, star_body);
                return self.builder.addRuleWithHint("star", star_ref);
            },
            .repeat => |f| {
                const content_id = try self.visit(f.content);
                const rep = try self.builder.addRepeat(content_id, f.min, f.max);
                return self.builder.addRuleWithHint("repeat", rep);
            },
            .token => |f| {
                const token_set = try self.builder.addTokenSet(&.{f.resolved_token_id});
                const seq = try self.builder.addSequence(&.{token_set});
                const choices = try self.builder.addChoices(&.{seq});
                return self.builder.addRuleWithHint("token", choices);
            },
            .exclude_token => |f| {
                var all: std.ArrayList(i32) = .empty;
                defer all.deinit(aa);
                try all.appendSlice(aa, f.resolved_token_ids.items);
                try all.appendSlice(aa, f.detected_end_token_ids.items);
                const expr = try self.builder.addExcludeTokenSet(all.items);
                const seq = try self.builder.addSequence(&.{expr});
                const choices = try self.builder.addChoices(&.{seq});
                return self.builder.addRuleWithHint("exclude_token", choices);
            },
            .any_tokens => |f| {
                var all: std.ArrayList(i32) = .empty;
                defer all.deinit(aa);
                try all.appendSlice(aa, f.resolved_exclude_token_ids.items);
                try all.appendSlice(aa, f.detected_end_token_ids.items);
                const expr = try self.builder.addExcludeTokenSet(all.items);
                const seq = try self.builder.addSequence(&.{expr});
                const choices = try self.builder.addChoices(&.{seq});
                const inner_rule = try self.builder.addRuleWithHint("any_tokens_inner", choices);
                const inner_ref = try self.builder.addRuleRef(inner_rule);
                const star_rule = try self.builder.addEmptyRuleWithHint("any_tokens");
                const star_ref = try self.builder.addRuleRef(star_rule);
                const empty = try self.builder.addEmptyStr();
                const seq2 = try self.builder.addSequence(&.{ inner_ref, star_ref });
                const star_body = try self.builder.addChoices(&.{ empty, seq2 });
                try self.setRuleBodyAndBudgets(star_rule, star_body, f.max_tokens, null);
                return star_rule;
            },
            .token_triggered_tags => |f| return self.visitTokenTriggeredTags(&f),
            .dispatch => |f| {
                var pairs: std.ArrayList(TagRulePairInit) = .empty;
                defer pairs.deinit(aa);
                for (f.rules.items) |*rule| {
                    const id = try self.visit(rule.content);
                    try pairs.append(aa, .{ .tag = rule.trigger, .rule_id = id });
                }
                const expr = try self.addTagDispatchRule(pairs.items, f.loop_after_dispatch, f.excludes.items);
                return self.builder.addRuleWithHint("tag_dispatch", expr);
            },
            .token_dispatch => |f| {
                var pairs: std.ArrayList(TriggerRulePair) = .empty;
                defer pairs.deinit(aa);
                for (f.rules.items, 0..) |*rule, i| {
                    const id = try self.visit(rule.content);
                    try pairs.append(aa, .{ .token_id = f.resolved_trigger_token_ids.items[i], .rule_id = id });
                }
                const expr = try self.addTokenTagDispatchRule(pairs.items, f.loop_after_dispatch, f.resolved_exclude_token_ids.items);
                return self.builder.addRuleWithHint("token_tag_dispatch", expr);
            },
        }
    }

    fn buildAllTagsChoices(
        self: *StructuralTagConverter,
        tags: []const TagFormat,
        content_rule_ids: []const i32,
    ) Allocator.Error!i32 {
        const aa = self.scratch();
        var choices: std.ArrayList(i32) = .empty;
        try choices.ensureTotalCapacity(aa, tags.len);
        for (tags, 0..) |*tag, it_tag| {
            const begin = try self.buildBeginExpr(tag);
            const r = try self.builder.addRuleRef(content_rule_ids[it_tag]);
            const end = try self.buildEndExpr(tag);
            choices.appendAssumeCapacity(try self.builder.addSequence(&.{ begin, r, end }));
        }
        return self.builder.addChoices(choices.items);
    }

    fn visitTriggeredTags(self: *StructuralTagConverter, f: *const TriggeredTagsFormat) StructuralTagError!i32 {
        const aa = self.scratch();
        var trigger_to_tag_ids: std.ArrayList(std.ArrayList(usize)) = .empty;
        try trigger_to_tag_ids.ensureTotalCapacity(aa, f.triggers.items.len);
        for (0..f.triggers.items.len) |_| {
            trigger_to_tag_ids.appendAssumeCapacity(.empty);
        }
        var tag_content_rule_ids: std.ArrayList(i32) = .empty;

        for (f.tags.items, 0..) |*tag, it_tag| {
            const tag_begin = switch (tag.begin) {
                .str => |s| s,
                else => return self.failInvalid("Tags in triggered_tags must have a string begin, not a token format"),
            };
            var matched: ?usize = null;
            for (f.triggers.items, 0..) |trigger, it_trigger| {
                if (std.mem.startsWith(u8, tag_begin, trigger)) {
                    if (matched != null) {
                        return self.failInvalid("One tag matches multiple triggers in a triggered tags format");
                    }
                    matched = it_trigger;
                }
            }
            const matched_trigger = matched orelse {
                return self.failInvalid("One tag does not match any trigger in a triggered tags format");
            };
            try trigger_to_tag_ids.items[matched_trigger].append(aa, it_tag);
            try tag_content_rule_ids.append(aa, try self.visit(tag.content));
        }

        // Special case: at_least_one && stop_after_first.
        if (f.at_least_one and f.stop_after_first) {
            const choice = try self.buildAllTagsChoices(f.tags.items, tag_content_rule_ids.items);
            return self.builder.addRuleWithHint("triggered_tags", choice);
        }

        // Normal case.
        var tag_rule_pairs: std.ArrayList(TagRulePairInit) = .empty;
        for (f.triggers.items, 0..) |trigger, it_trigger| {
            var choices: std.ArrayList(i32) = .empty;
            for (trigger_to_tag_ids.items[it_trigger].items) |tag_id| {
                const tag = &f.tags.items[tag_id];
                const tag_begin = switch (tag.begin) {
                    .str => |s| s,
                    else => unreachable, // validated above
                };
                const begin = try self.builder.addByteString(tag_begin[trigger.len..]);
                const r = try self.builder.addRuleRef(tag_content_rule_ids.items[tag_id]);
                const end = try self.buildEndExpr(tag);
                try choices.append(aa, try self.builder.addSequence(&.{ begin, r, end }));
            }
            const choice = try self.builder.addChoices(choices.items);
            const sub_rule = try self.builder.addRuleWithHint("triggered_tags_group", choice);
            try tag_rule_pairs.append(aa, .{ .tag = trigger, .rule_id = sub_rule });
        }

        var all_excludes: std.ArrayList([]const u8) = .empty;
        defer all_excludes.deinit(aa);
        try all_excludes.appendSlice(aa, f.excludes.items);
        for (f.detected_end_strs.items) |s| {
            if (s.len != 0) try all_excludes.append(aa, s);
        }
        var rule_expr_id = try self.addTagDispatchRule(tag_rule_pairs.items, !f.stop_after_first, all_excludes.items);

        if (f.at_least_one) {
            const first_choice = try self.buildAllTagsChoices(f.tags.items, tag_content_rule_ids.items);
            const first_rule = try self.builder.addRuleWithHint("triggered_tags_first", first_choice);
            const dispatch_rule = try self.builder.addRuleWithHint("triggered_tags_sub", rule_expr_id);
            const ref_first = try self.builder.addRuleRef(first_rule);
            const ref_dispatch = try self.builder.addRuleRef(dispatch_rule);
            const seq = try self.builder.addSequence(&.{ ref_first, ref_dispatch });
            rule_expr_id = try self.builder.addChoices(&.{seq});
        }

        return self.builder.addRuleWithHint("triggered_tags", rule_expr_id);
    }

    fn visitTagsWithSeparator(self: *StructuralTagConverter, f: *const TagsWithSeparatorFormat) StructuralTagError!i32 {
        const aa = self.scratch();
        var choice_ids: std.ArrayList(i32) = .empty;
        defer choice_ids.deinit(aa);
        for (f.tags.items) |*tag| {
            const tag_copy = Format{ .tag = tag.* };
            const tag_rule_id = try self.visit(&tag_copy);
            const tag_ref = try self.builder.addRuleRef(tag_rule_id);
            try choice_ids.append(aa, try self.builder.addSequence(&.{tag_ref}));
        }
        const choice = try self.builder.addChoices(choice_ids.items);
        const all_tags_rule = try self.builder.addRuleWithHint("tags_with_separator_tags", choice);
        const all_tags_ref = try self.builder.addRuleRef(all_tags_rule);

        if (f.stop_after_first) {
            const body = if (f.at_least_one) blk: {
                const seq = try self.builder.addSequence(&.{all_tags_ref});
                break :blk try self.builder.addChoices(&.{seq});
            } else blk: {
                const seq = try self.builder.addSequence(&.{all_tags_ref});
                const empty = try self.builder.addEmptyStr();
                break :blk try self.builder.addChoices(&.{ seq, empty });
            };
            return self.builder.addRuleWithHint("tags_with_separator", body);
        }

        const sub_rule = try self.builder.addEmptyRuleWithHint("tags_with_separator_sub");
        const end_str_seq = try self.builder.addEmptyStr();
        var sub_seq: std.ArrayList(i32) = .empty;
        if (f.separator.len != 0) {
            try sub_seq.append(aa, try self.builder.addByteString(f.separator));
        }
        try sub_seq.append(aa, all_tags_ref);
        const sub_self_ref = try self.builder.addRuleRef(sub_rule);
        try sub_seq.append(aa, sub_self_ref);
        const sub_seq_id = try self.builder.addSequence(sub_seq.items);
        const sub_body = try self.builder.addChoices(&.{ sub_seq_id, end_str_seq });
        self.builder.updateRuleBody(sub_rule, sub_body);

        const sub_ref = try self.builder.addRuleRef(sub_rule);
        const main_seq = try self.builder.addSequence(&.{ all_tags_ref, sub_ref });
        var choices: std.ArrayList(i32) = .empty;
        try choices.append(aa, main_seq);
        if (!f.at_least_one) {
            try choices.append(aa, end_str_seq);
        }
        const body = try self.builder.addChoices(choices.items);
        return self.builder.addRuleWithHint("tags_with_separator", body);
    }

    fn visitTokenTriggeredTags(self: *StructuralTagConverter, f: *const TokenTriggeredTagsFormat) StructuralTagError!i32 {
        const aa = self.scratch();
        var trigger_to_tag_ids: std.ArrayList(std.ArrayList(usize)) = .empty;
        try trigger_to_tag_ids.ensureTotalCapacity(aa, f.trigger_tokens.items.len);
        for (0..f.trigger_tokens.items.len) |_| {
            trigger_to_tag_ids.appendAssumeCapacity(.empty);
        }
        var tag_content_rule_ids: std.ArrayList(i32) = .empty;

        for (f.tags.items, 0..) |*tag, it_tag| {
            const begin_token_id = switch (tag.begin) {
                .token => |tf| tf.resolved_token_id,
                else => return self.failInvalid("Tags in token_triggered_tags must have a token format begin, not a string"),
            };
            var matched: ?usize = null;
            for (f.resolved_trigger_token_ids.items, 0..) |tid, it| {
                if (tid == begin_token_id) {
                    if (matched != null) {
                        return self.failInvalid("Tag matches multiple triggers");
                    }
                    matched = it;
                }
            }
            const matched_trigger = matched orelse {
                return self.failInvalid("Tag does not match any trigger");
            };
            try trigger_to_tag_ids.items[matched_trigger].append(aa, it_tag);
            try tag_content_rule_ids.append(aa, try self.visit(tag.content));
        }

        if (f.at_least_one and f.stop_after_first) {
            const choice = try self.buildAllTagsChoices(f.tags.items, tag_content_rule_ids.items);
            return self.builder.addRuleWithHint("token_triggered_tags", choice);
        }

        var trigger_rule_pairs: std.ArrayList(TriggerRulePair) = .empty;
        for (f.resolved_trigger_token_ids.items, 0..) |trigger_id, it| {
            var choices: std.ArrayList(i32) = .empty;
            for (trigger_to_tag_ids.items[it].items) |tag_id| {
                const tag = &f.tags.items[tag_id];
                const r = try self.builder.addRuleRef(tag_content_rule_ids.items[tag_id]);
                const end = try self.buildEndExpr(tag);
                try choices.append(aa, try self.builder.addSequence(&.{ r, end }));
            }
            const choice = try self.builder.addChoices(choices.items);
            const sub_rule = try self.builder.addRuleWithHint("token_triggered_tags_group", choice);
            try trigger_rule_pairs.append(aa, .{ .token_id = trigger_id, .rule_id = sub_rule });
        }

        var all_excludes: std.ArrayList(i32) = .empty;
        defer all_excludes.deinit(aa);
        try all_excludes.appendSlice(aa, f.resolved_exclude_token_ids.items);
        try all_excludes.appendSlice(aa, f.detected_end_token_ids.items);
        var rule_expr_id = try self.addTokenTagDispatchRule(trigger_rule_pairs.items, !f.stop_after_first, all_excludes.items);

        if (f.at_least_one) {
            const first_choice = try self.buildAllTagsChoices(f.tags.items, tag_content_rule_ids.items);
            const first_rule = try self.builder.addRuleWithHint("token_triggered_tags_first", first_choice);
            const dispatch_rule = try self.builder.addRuleWithHint("token_triggered_tags_sub", rule_expr_id);
            const ref_first = try self.builder.addRuleRef(first_rule);
            const ref_dispatch = try self.builder.addRuleRef(dispatch_rule);
            const seq = try self.builder.addSequence(&.{ ref_first, ref_dispatch });
            rule_expr_id = try self.builder.addChoices(&.{seq});
        }

        return self.builder.addRuleWithHint("token_triggered_tags", rule_expr_id);
    }
};

test "fromStructuralTag and fromStructuralTagWithTokenizer cover formats, caching, and zero-leak errors" {
    const a = std.testing.allocator;

    // 1. Triggered tags with json_schema + deduplicated repeated sub-formats.
    const stag =
        \\{"type":"structural_tag","format":{"type":"sequence","elements":[
        \\  {"type":"triggered_tags","triggers":["<call>"],"tags":[
        \\    {"begin":"<call>","content":{"type":"json_schema","json_schema":{"type":"object","properties":{"x":{"type":"integer"}},"required":["x"],"additionalProperties":false}},"end":"</call>"},
        \\    {"begin":"<call>2","content":{"type":"json_schema","json_schema":{"additionalProperties":false,"required":["x"],"properties":{"x":{"type":"integer"}},"type":"object"}},"end":"</call>"}
        \\  ]},
        \\  {"type":"tags_with_separator","tags":[{"begin":"[","content":{"type":"regex","pattern":"[a-z]+"},"end":"]"}],"separator":","}
        \\]}}
    ;
    var g = try fromStructuralTag(a, stag, null);
    defer g.deinit();
    const ebnf = try g.toStringEbnf(a);
    defer a.free(ebnf);
    try std.testing.expect(std.mem.indexOf(u8, ebnf, "TagDispatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, ebnf, "<call>") != null);

    // Verify StructuralTagConverter deduplicates identical json_schema sub-formats regardless of key order.
    {
        var parsed_dedup = try parser.parseStructuralTag(a, stag, null);
        defer parsed_dedup.deinit();
        try resolveFormat(parsed_dedup.allocator(), a, null, &parsed_dedup.root, null);
        try analyze(parsed_dedup.allocator(), a, null, &parsed_dedup.root, null);
        var conv = try StructuralTagConverter.init(a, null);
        defer conv.deinit();
        var raw_g = try conv.convert(&parsed_dedup.root);
        defer raw_g.deinit();
        // Top sequence(1) + triggered_tags(1) + deduplicated json_schema(1) + tags_with_separator(1) + tag(1) + regex(1) = 6 entries.
        try std.testing.expectEqual(@as(usize, 6), conv.cache.count());
    }

    // 2. Token-keyed formats via TokenizerInfo.decodedVocab().
    var tok = try TokenizerInfo.init(a, &.{ "<|start|>", "<|end|>", "<|stop|>", "hello", "</s>" }, .{
        .stop_token_ids = &.{4},
    });
    defer tok.deinit();
    const token_stag =
        \\{"format":{"type":"token_triggered_tags","trigger_tokens":["<|start|>"],"exclude_tokens":["<|stop|>"],"tags":[{"begin":{"token":"<|start|>"},"content":{"type":"any_tokens","max_tokens":4},"end":{"token":"<|end|>"}}]}}
    ;
    var tg = try fromStructuralTagWithTokenizer(a, token_stag, &tok, null);
    defer tg.deinit();
    const tg_ebnf = try tg.toStringEbnf(a);
    defer a.free(tg_ebnf);
    try std.testing.expect(std.mem.indexOf(u8, tg_ebnf, "TokenTagDispatch") != null);

    // 3. Diagnostic propagation across InvalidJson, InvalidJsonSchema, InvalidStructuralTag (regex/ebnf/vocab/unlimited).
    var diag: Diagnostic = .{};
    defer diag.deinit(a);

    try std.testing.expectError(error.InvalidJson, fromStructuralTag(a, "{bad", &diag));
    try std.testing.expectEqual(Diagnostic.Kind.structural_tag_invalid_json, diag.kind);

    try std.testing.expectError(
        error.InvalidJsonSchema,
        fromStructuralTag(a, "{\"format\":{\"type\":\"json_schema\",\"json_schema\":false}}", &diag),
    );
    try std.testing.expectEqual(Diagnostic.Kind.structural_tag_invalid_schema, diag.kind);
    const schema_msg = try diag.formatAlloc(a);
    defer a.free(schema_msg);
    try std.testing.expectEqualStrings("Invalid JSON schema error: Schema 'false' cannot accept any value", schema_msg);

    try std.testing.expectError(
        error.InvalidJsonSchema,
        fromStructuralTag(a, "{\"format\":{\"type\":\"json_schema\",\"json_schema\":{\"type\":\"string\",\"pattern\":\"a[]b\"}}}", &diag),
    );
    try std.testing.expectEqual(Diagnostic.Kind.structural_tag_invalid_schema, diag.kind);
    const schema_regex_msg = try diag.formatAlloc(a);
    defer a.free(schema_regex_msg);
    try std.testing.expect(std.mem.indexOf(u8, schema_regex_msg, "Empty character class") != null);

    try std.testing.expectError(
        error.InvalidStructuralTag,
        fromStructuralTag(a, "{\"format\":{\"type\":\"regex\",\"pattern\":\"a[]b\"}}", &diag),
    );
    try std.testing.expectEqual(Diagnostic.Kind.structural_tag_invalid, diag.kind);
    const regex_msg = try diag.formatAlloc(a);
    defer a.free(regex_msg);
    try std.testing.expectEqualStrings(
        "Invalid structural tag error: Regex parsing error at position 3: Empty character class is not allowed in regex.",
        regex_msg,
    );

    try std.testing.expectError(
        error.InvalidStructuralTag,
        fromStructuralTag(a, "{\"format\":{\"type\":\"grammar\",\"grammar\":\"bad ::= \"}}", &diag),
    );
    try std.testing.expectEqual(Diagnostic.Kind.structural_tag_invalid, diag.kind);
    const ebnf_msg = try diag.formatAlloc(a);
    defer a.free(ebnf_msg);
    try std.testing.expect(std.mem.startsWith(u8, ebnf_msg, "Invalid structural tag error: "));

    try std.testing.expectError(
        error.InvalidStructuralTag,
        fromStructuralTagWithTokenizer(a, "{\"format\":{\"type\":\"token\",\"token\":\"missing\"}}", &tok, &diag),
    );
    try std.testing.expectEqual(Diagnostic.Kind.structural_tag_invalid, diag.kind);

    try std.testing.expectError(
        error.InvalidStructuralTag,
        fromStructuralTag(a, "{\"format\":{\"type\":\"tag\",\"begin\":\"<a>\",\"content\":{\"type\":\"any_text\"},\"end\":\"\"}}", &diag),
    );
    try std.testing.expectEqual(Diagnostic.Kind.structural_tag_invalid, diag.kind);

    // 4. Null diagnostic across all error categories + all remaining format variants.
    try std.testing.expectError(error.InvalidJson, fromStructuralTag(a, "{bad", null));
    try std.testing.expectError(error.InvalidJsonSchema, fromStructuralTag(a, "{\"format\":{\"type\":\"json_schema\",\"json_schema\":false}}", null));
    try std.testing.expectError(error.InvalidStructuralTag, fromStructuralTag(a, "{\"format\":{\"type\":\"regex\",\"pattern\":\"a[]b\"}}", null));

    const rich_stag =
        \\{"format":{"type":"or","elements":[
        \\  {"type":"optional","content":{"type":"const_string","value":"pre"}},
        \\  {"type":"plus","content":{"type":"const_string","value":"x"}},
        \\  {"type":"star","content":{"type":"const_string","value":"y"}},
        \\  {"type":"repeat","min":1,"max":3,"content":{"type":"const_string","value":"z"}},
        \\  {"type":"qwen_xml_parameter","json_schema":{"type":"object","properties":{"a":{"type":"integer"}},"required":["a"]}},
        \\  {"type":"grammar","grammar":"root ::= \"ok\""},
        \\  {"type":"tag","begin":"<a1>","content":{"type":"any_text","max_tokens":0,"max_chars":10},"end":["</a1>","</a2>"]},
        \\  {"type":"triggered_tags","triggers":["<t>"],"tags":[{"begin":"<t>a","content":{"type":"const_string","value":"1"},"end":"</t>"}],"at_least_one":true,"stop_after_first":true},
        \\  {"type":"dispatch","rules":[["<d>",{"type":"const_string","value":"d"}]],"loop":true,"excludes":["</stop>"]}
        \\]}}
    ;
    var rich_g = try fromStructuralTag(a, rich_stag, null);
    defer rich_g.deinit();
    try std.testing.expect(rich_g.numRules() >= 1);

    const rich_tok_stag =
        \\{"format":{"type":"sequence","elements":[
        \\  {"type":"token","token":"hello"},
        \\  {"type":"exclude_token","exclude_tokens":["<|stop|>",0]},
        \\  {"type":"token_dispatch","rules":[["<|start|>",{"type":"const_string","value":"v"}]],"loop":false,"exclude_tokens":["<|stop|>"]},
        \\  {"type":"token_triggered_tags","trigger_tokens":["<|start|>"],"tags":[{"begin":{"token":"<|start|>"},"content":{"type":"const_string","value":"k"},"end":{"token":"<|end|>"}}],"at_least_one":true,"stop_after_first":false}
        \\]}}
    ;
    var rich_tg = try fromStructuralTagWithTokenizer(a, rich_tok_stag, &tok, null);
    defer rich_tg.deinit();
    try std.testing.expect(rich_tg.numRules() >= 1);

    // 5. Exhaustive OOM failure injection across parsing, resolving, analyzing, converting,
    // and normalizing (`functor.normalize` after `conv.convert()` succeeds) with 0 leaks.
    try std.testing.checkAllAllocationFailures(a, struct {
        fn run(alloc: Allocator, input: []const u8) !void {
            var d: Diagnostic = .{};
            defer d.deinit(alloc);
            var out = fromStructuralTag(alloc, input, &d) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return,
            };
            out.deinit();
        }
    }.run, .{stag});

    try std.testing.checkAllAllocationFailures(a, struct {
        fn run(alloc: Allocator, input: []const u8, t: *const TokenizerInfo) !void {
            var d: Diagnostic = .{};
            defer d.deinit(alloc);
            var out = fromStructuralTagWithTokenizer(alloc, input, t, &d) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return,
            };
            out.deinit();
        }
    }.run, .{ token_stag, &tok });

    // OOM injection along the schema error diagnostic forwarding path (0 leaks).
    try std.testing.checkAllAllocationFailures(a, struct {
        fn run(alloc: Allocator) !void {
            var d: Diagnostic = .{};
            defer d.deinit(alloc);
            var out = fromStructuralTag(
                alloc,
                "{\"format\":{\"type\":\"json_schema\",\"json_schema\":{\"type\":\"string\",\"pattern\":\"a[]b\"}}}",
                &d,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidJsonSchema => return,
                else => return error.TestUnexpectedResult,
            };
            out.deinit();
            return error.TestUnexpectedResult;
        }
    }.run, .{});
}
