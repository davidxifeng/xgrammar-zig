//! Intermediate representation for a parsed structural tag (`structural_tag_format.rs`).
//!
//! The full tree (including the resolver/analyzer-filled `resolved_*`/`detected_*` fields)
//! participates in equality/hashing so the converter can de-duplicate identical sub-formats.
//! Strings live in the owning allocator; `deinit` frees the tree. `Box<Format>` → owned
//! `*Format`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const any_text_format = @import("any_text_format.zig");
const any_tokens_format = @import("any_tokens_format.zig");
const json_schema_format = @import("json_schema_format.zig");

const AnyTextFormat = any_text_format.AnyTextFormat;
const AnyTokensFormat = any_tokens_format.AnyTokensFormat;
const JsonSchemaFormat = json_schema_format.JsonSchemaFormat;

/// A token reference: a literal id or a vocabulary string (resolved to an id later).
pub const IntOrString = union(enum) {
    int: i32,
    str: []const u8,

    pub fn eql(a: IntOrString, b: IntOrString) bool {
        if (@as(std.meta.Tag(IntOrString), a) != @as(std.meta.Tag(IntOrString), b)) return false;
        return switch (a) {
            .int => |i| i == b.int,
            .str => |s| std.mem.eql(u8, s, b.str),
        };
    }

    pub fn hash(self: IntOrString, hasher: anytype) void {
        switch (self) {
            .int => |i| {
                hasher.update("i");
                var buf: [4]u8 = undefined;
                std.mem.writeInt(i32, &buf, i, .little);
                hasher.update(&buf);
            },
            .str => |s| {
                hasher.update("s");
                hasher.update(s);
            },
        }
    }
};

/// `{"type":"const_string","value":.}`
pub const ConstStringFormat = struct {
    value: []const u8,
};

/// `{"type":"grammar","grammar":<ebnf>}`
pub const GrammarFormat = struct {
    grammar: []const u8,
};

/// `{"type":"regex","pattern":<regex>}`
pub const RegexFormat = struct {
    pattern: []const u8,
};

pub const SequenceFormat = struct {
    elements: std.ArrayList(Format) = .empty,
    is_unlimited: bool = false,
};

pub const OrFormat = struct {
    elements: std.ArrayList(Format) = .empty,
    is_unlimited: bool = false,
};

/// A tag's begin marker: a literal string or a token.
pub const TagBegin = union(enum) {
    str: []const u8,
    token: TokenFormat,
};

/// A tag's end marker: a set of literal strings or a token.
pub const TagEnd = union(enum) {
    strings: std.ArrayList([]const u8),
    token: TokenFormat,
};

pub const TagFormat = struct {
    begin: TagBegin,
    content: *Format,
    end: TagEnd,
};

pub const TriggeredTagsFormat = struct {
    triggers: std.ArrayList([]const u8) = .empty,
    tags: std.ArrayList(TagFormat) = .empty,
    excludes: std.ArrayList([]const u8) = .empty,
    at_least_one: bool = false,
    stop_after_first: bool = false,
    detected_end_strs: std.ArrayList([]const u8) = .empty,
};

pub const TagsWithSeparatorFormat = struct {
    tags: std.ArrayList(TagFormat) = .empty,
    separator: []const u8 = "",
    at_least_one: bool = false,
    stop_after_first: bool = false,
};

pub const OptionalFormat = struct {
    content: *Format,
};

pub const PlusFormat = struct {
    content: *Format,
};

pub const StarFormat = struct {
    content: *Format,
};

/// `max == -1` is unbounded.
pub const RepeatFormat = struct {
    min: i32,
    max: i32,
    content: *Format,
};

pub const TokenFormat = struct {
    token: IntOrString,
    resolved_token_id: i32,

    pub fn new(allocator: Allocator, token: IntOrString) Allocator.Error!TokenFormat {
        // An integer token is its own resolved id; a string token resolves later.
        const resolved_token_id = switch (token) {
            .int => |i| i,
            .str => -1,
        };
        _ = allocator;
        return .{ .token = token, .resolved_token_id = resolved_token_id };
    }
};

pub const ExcludeTokenFormat = struct {
    exclude_tokens: std.ArrayList(IntOrString) = .empty,
    resolved_token_ids: std.ArrayList(i32) = .empty,
    detected_end_token_ids: std.ArrayList(i32) = .empty,
};

pub const TokenTriggeredTagsFormat = struct {
    trigger_tokens: std.ArrayList(IntOrString) = .empty,
    tags: std.ArrayList(TagFormat) = .empty,
    exclude_tokens: std.ArrayList(IntOrString) = .empty,
    at_least_one: bool = false,
    stop_after_first: bool = false,
    resolved_trigger_token_ids: std.ArrayList(i32) = .empty,
    resolved_exclude_token_ids: std.ArrayList(i32) = .empty,
    detected_end_token_ids: std.ArrayList(i32) = .empty,
};

pub const DispatchFormat = struct {
    rules: std.ArrayList(Rule) = .empty,
    loop_after_dispatch: bool = false,
    excludes: std.ArrayList([]const u8) = .empty,

    /// `(trigger, content)` (Rust tuple `(String, Box<Format>)`).
    pub const Rule = struct {
        trigger: []const u8,
        content: *Format,
    };
};

pub const TokenDispatchFormat = struct {
    rules: std.ArrayList(Rule) = .empty,
    loop_after_dispatch: bool = false,
    exclude_tokens: std.ArrayList(IntOrString) = .empty,
    resolved_trigger_token_ids: std.ArrayList(i32) = .empty,
    resolved_exclude_token_ids: std.ArrayList(i32) = .empty,

    /// `(trigger, content)` (Rust tuple `(IntOrString, Box<Format>)`).
    pub const Rule = struct {
        trigger: IntOrString,
        content: *Format,
    };
};

/// The tagged union of all structural-tag format kinds.
pub const Format = union(enum) {
    const_string: ConstStringFormat,
    json_schema: JsonSchemaFormat,
    any_text: AnyTextFormat,
    grammar: GrammarFormat,
    regex: RegexFormat,
    sequence: SequenceFormat,
    or_fmt: OrFormat, // Rust `Or` (`or` is a Zig keyword)
    tag: TagFormat,
    triggered_tags: TriggeredTagsFormat,
    tags_with_separator: TagsWithSeparatorFormat,
    optional: OptionalFormat,
    plus: PlusFormat,
    star: StarFormat,
    repeat: RepeatFormat,
    token: TokenFormat,
    exclude_token: ExcludeTokenFormat,
    any_tokens: AnyTokensFormat,
    token_triggered_tags: TokenTriggeredTagsFormat,
    dispatch: DispatchFormat,
    token_dispatch: TokenDispatchFormat,

    /// Frees the tree (strings and children). JSON-schema payloads are freed the same way.
    pub fn deinit(self: *Format, allocator: Allocator) void {
        switch (self.*) {
            .const_string => |f| allocator.free(f.value),
            .json_schema => |*f| deinit_json_schema(allocator, f),
            .any_text => |*f| {
                free_str_list(allocator, &f.excludes);
                f.excludes.deinit(allocator);
                free_str_list(allocator, &f.detected_end_strs);
                f.detected_end_strs.deinit(allocator);
            },
            .grammar => |f| allocator.free(f.grammar),
            .regex => |f| allocator.free(f.pattern),
            .sequence => |*f| {
                deinit_formats(allocator, &f.elements);
            },
            .or_fmt => |*f| {
                deinit_formats(allocator, &f.elements);
            },
            .tag => |*f| deinit_tag(allocator, f),
            .triggered_tags => |*f| {
                free_str_list(allocator, &f.triggers);
                f.triggers.deinit(allocator);
                deinit_tags(allocator, &f.tags);
                free_str_list(allocator, &f.excludes);
                f.excludes.deinit(allocator);
                free_str_list(allocator, &f.detected_end_strs);
                f.detected_end_strs.deinit(allocator);
            },
            .tags_with_separator => |*f| {
                deinit_tags(allocator, &f.tags);
                allocator.free(f.separator);
            },
            .optional => |f| {
                f.content.deinit(allocator);
                allocator.destroy(f.content);
            },
            .plus => |f| {
                f.content.deinit(allocator);
                allocator.destroy(f.content);
            },
            .star => |f| {
                f.content.deinit(allocator);
                allocator.destroy(f.content);
            },
            .repeat => |f| {
                f.content.deinit(allocator);
                allocator.destroy(f.content);
            },
            .token => |f| deinit_int_or_string(allocator, f.token),
            .exclude_token => |*f| {
                deinit_int_or_string_list(allocator, &f.exclude_tokens);
            },
            .any_tokens => |*f| {
                deinit_int_or_string_list(allocator, &f.exclude_tokens);
            },
            .token_triggered_tags => |*f| {
                deinit_int_or_string_list(allocator, &f.trigger_tokens);
                deinit_tags(allocator, &f.tags);
                deinit_int_or_string_list(allocator, &f.exclude_tokens);
            },
            .dispatch => |*f| {
                for (f.rules.items) |rule| {
                    allocator.free(rule.trigger);
                    rule.content.deinit(allocator);
                    allocator.destroy(rule.content);
                }
                f.rules.deinit(allocator);
                free_str_list(allocator, &f.excludes);
                f.excludes.deinit(allocator);
            },
            .token_dispatch => |*f| {
                for (f.rules.items) |rule| {
                    deinit_int_or_string(allocator, rule.trigger);
                    rule.content.deinit(allocator);
                    allocator.destroy(rule.content);
                }
                f.rules.deinit(allocator);
                deinit_int_or_string_list(allocator, &f.exclude_tokens);
            },
        }
    }

    /// Rust `PartialEq` (by content).
    pub fn eql(a: *const Format, b: *const Format) bool {
        if (@as(std.meta.Tag(Format), a.*) != @as(std.meta.Tag(Format), b.*)) return false;
        return switch (a.*) {
            .const_string => |f| std.mem.eql(u8, f.value, b.const_string.value),
            .json_schema => |*f| json_schema_eql(f, &b.json_schema),
            .any_text => |f| str_list_eql(f.excludes.items, b.any_text.excludes.items) and
                eq_opt_i32(f.max_tokens, b.any_text.max_tokens) and
                eq_opt_i32(f.max_chars, b.any_text.max_chars) and
                str_list_eql(f.detected_end_strs.items, b.any_text.detected_end_strs.items),
            .grammar => |f| std.mem.eql(u8, f.grammar, b.grammar.grammar),
            .regex => |f| std.mem.eql(u8, f.pattern, b.regex.pattern),
            .sequence => |f| formats_eql(&f.elements, &b.sequence.elements) and f.is_unlimited == b.sequence.is_unlimited,
            .or_fmt => |f| formats_eql(&f.elements, &b.or_fmt.elements) and f.is_unlimited == b.or_fmt.is_unlimited,
            .tag => |*f| tag_eql(f, &b.tag),
            .triggered_tags => |f| str_list_eql(f.triggers.items, b.triggered_tags.triggers.items) and
                tags_eql(&f.tags, &b.triggered_tags.tags) and
                str_list_eql(f.excludes.items, b.triggered_tags.excludes.items) and
                f.at_least_one == b.triggered_tags.at_least_one and
                f.stop_after_first == b.triggered_tags.stop_after_first and
                str_list_eql(f.detected_end_strs.items, b.triggered_tags.detected_end_strs.items),
            .tags_with_separator => |f| tags_eql(&f.tags, &b.tags_with_separator.tags) and
                std.mem.eql(u8, f.separator, b.tags_with_separator.separator) and
                f.at_least_one == b.tags_with_separator.at_least_one and
                f.stop_after_first == b.tags_with_separator.stop_after_first,
            .optional => |f| eql(f.content, b.optional.content),
            .plus => |f| eql(f.content, b.plus.content),
            .star => |f| eql(f.content, b.star.content),
            .repeat => |f| f.min == b.repeat.min and f.max == b.repeat.max and eql(f.content, b.repeat.content),
            .token => |f| f.resolved_token_id == b.token.resolved_token_id and int_or_string_eql(f.token, b.token.token),
            .exclude_token => |f| int_or_strings_eql(&f.exclude_tokens, &b.exclude_token.exclude_tokens) and
                i32_list_eql(f.resolved_token_ids.items, b.exclude_token.resolved_token_ids.items) and
                i32_list_eql(f.detected_end_token_ids.items, b.exclude_token.detected_end_token_ids.items),
            .any_tokens => |f| int_or_strings_eql(&f.exclude_tokens, &b.any_tokens.exclude_tokens) and
                eq_opt_i32(f.max_tokens, b.any_tokens.max_tokens) and
                i32_list_eql(f.resolved_exclude_token_ids.items, b.any_tokens.resolved_exclude_token_ids.items) and
                i32_list_eql(f.detected_end_token_ids.items, b.any_tokens.detected_end_token_ids.items),
            .token_triggered_tags => |f| int_or_strings_eql(&f.trigger_tokens, &b.token_triggered_tags.trigger_tokens) and
                tags_eql(&f.tags, &b.token_triggered_tags.tags) and
                int_or_strings_eql(&f.exclude_tokens, &b.token_triggered_tags.exclude_tokens) and
                f.at_least_one == b.token_triggered_tags.at_least_one and
                f.stop_after_first == b.token_triggered_tags.stop_after_first and
                i32_list_eql(f.resolved_trigger_token_ids.items, b.token_triggered_tags.resolved_trigger_token_ids.items) and
                i32_list_eql(f.resolved_exclude_token_ids.items, b.token_triggered_tags.resolved_exclude_token_ids.items) and
                i32_list_eql(f.detected_end_token_ids.items, b.token_triggered_tags.detected_end_token_ids.items),
            .dispatch => |f| rules_eql_str(&f.rules, &b.dispatch.rules) and
                f.loop_after_dispatch == b.dispatch.loop_after_dispatch and
                str_list_eql(f.excludes.items, b.dispatch.excludes.items),
            .token_dispatch => |f| rules_eql_int(&f.rules, &b.token_dispatch.rules) and
                f.loop_after_dispatch == b.token_dispatch.loop_after_dispatch and
                int_or_strings_eql(&f.exclude_tokens, &b.token_dispatch.exclude_tokens) and
                i32_list_eql(f.resolved_trigger_token_ids.items, b.token_dispatch.resolved_trigger_token_ids.items) and
                i32_list_eql(f.resolved_exclude_token_ids.items, b.token_dispatch.resolved_exclude_token_ids.items),
        };
    }

    /// Rust-derived `Hash`; mixes the tag so `(Int, ...)` can't collide with a string.
    pub fn hash(self: *const Format, hasher: anytype) void {
        std.hash.autoHash(hasher, @as(std.meta.Tag(Format), self.*));
        switch (self.*) {
            .const_string => |f| hasher.update(f.value),
            .json_schema => |*f| hash_json_schema(hasher, f),
            .any_text => |f| {
                hash_str_list(hasher, f.excludes.items);
                hash_opt_i32(hasher, f.max_tokens);
                hash_opt_i32(hasher, f.max_chars);
                hash_str_list(hasher, f.detected_end_strs.items);
            },
            .grammar => |f| hasher.update(f.grammar),
            .regex => |f| hasher.update(f.pattern),
            .sequence => |f| {
                hash_formats(hasher, &f.elements);
                std.hash.autoHash(hasher, f.is_unlimited);
            },
            .or_fmt => |f| {
                hash_formats(hasher, &f.elements);
                std.hash.autoHash(hasher, f.is_unlimited);
            },
            .tag => |*f| hash_tag(hasher, f),
            .triggered_tags => |f| {
                hash_str_list(hasher, f.triggers.items);
                hash_tags(hasher, &f.tags);
                hash_str_list(hasher, f.excludes.items);
                std.hash.autoHash(hasher, f.at_least_one);
                std.hash.autoHash(hasher, f.stop_after_first);
                hash_str_list(hasher, f.detected_end_strs.items);
            },
            .tags_with_separator => |f| {
                hash_tags(hasher, &f.tags);
                hasher.update(f.separator);
                std.hash.autoHash(hasher, f.at_least_one);
                std.hash.autoHash(hasher, f.stop_after_first);
            },
            .optional => |f| Format.hash(f.content, hasher),
            .plus => |f| Format.hash(f.content, hasher),
            .star => |f| Format.hash(f.content, hasher),
            .repeat => |f| {
                std.hash.autoHash(hasher, f.min);
                std.hash.autoHash(hasher, f.max);
                Format.hash(f.content, hasher);
            },
            .token => |f| {
                f.token.hash(hasher);
                std.hash.autoHash(hasher, f.resolved_token_id);
            },
            .exclude_token => |f| {
                hash_int_or_strings(hasher, &f.exclude_tokens);
                hash_i32_list(hasher, f.resolved_token_ids.items);
                hash_i32_list(hasher, f.detected_end_token_ids.items);
            },
            .any_tokens => |f| {
                hash_int_or_strings(hasher, &f.exclude_tokens);
                hash_opt_i32(hasher, f.max_tokens);
                hash_i32_list(hasher, f.resolved_exclude_token_ids.items);
                hash_i32_list(hasher, f.detected_end_token_ids.items);
            },
            .token_triggered_tags => |f| {
                hash_int_or_strings(hasher, &f.trigger_tokens);
                hash_tags(hasher, &f.tags);
                hash_int_or_strings(hasher, &f.exclude_tokens);
                std.hash.autoHash(hasher, f.at_least_one);
                std.hash.autoHash(hasher, f.stop_after_first);
                hash_i32_list(hasher, f.resolved_trigger_token_ids.items);
                hash_i32_list(hasher, f.resolved_exclude_token_ids.items);
                hash_i32_list(hasher, f.detected_end_token_ids.items);
            },
            .dispatch => |f| {
                for (f.rules.items) |rule| {
                    hasher.update(rule.trigger);
                    Format.hash(rule.content, hasher);
                }
                std.hash.autoHash(hasher, f.loop_after_dispatch);
                hash_str_list(hasher, f.excludes.items);
            },
            .token_dispatch => |f| {
                for (f.rules.items) |rule| {
                    rule.trigger.hash(hasher);
                    Format.hash(rule.content, hasher);
                }
                std.hash.autoHash(hasher, f.loop_after_dispatch);
                hash_int_or_strings(hasher, &f.exclude_tokens);
                hash_i32_list(hasher, f.resolved_trigger_token_ids.items);
                hash_i32_list(hasher, f.resolved_exclude_token_ids.items);
            },
        }
    }

    /// Deep copy into `allocator` (Rust `Clone`).
    pub fn clone(self: *const Format, allocator: Allocator) Allocator.Error!Format {
        return switch (self.*) {
            .const_string => |f| .{ .const_string = .{ .value = try allocator.dupe(u8, f.value) } },
            .json_schema => |f| .{ .json_schema = try clone_json_schema(allocator, &f) },
            .any_text => |f| blk: {
                var out = AnyTextFormat{};
                try clone_str_list(allocator, &out.excludes, f.excludes.items);
                out.max_tokens = f.max_tokens;
                out.max_chars = f.max_chars;
                try clone_str_list(allocator, &out.detected_end_strs, f.detected_end_strs.items);
                break :blk .{ .any_text = out };
            },
            .grammar => |f| .{ .grammar = .{ .grammar = try allocator.dupe(u8, f.grammar) } },
            .regex => |f| .{ .regex = .{ .pattern = try allocator.dupe(u8, f.pattern) } },
            .sequence => |f| blk: {
                var out = SequenceFormat{ .is_unlimited = f.is_unlimited };
                try clone_formats(allocator, &out.elements, &f.elements);
                break :blk .{ .sequence = out };
            },
            .or_fmt => |f| blk: {
                var out = OrFormat{ .is_unlimited = f.is_unlimited };
                try clone_formats(allocator, &out.elements, &f.elements);
                break :blk .{ .or_fmt = out };
            },
            .tag => |f| .{ .tag = try clone_tag(allocator, &f) },
            .triggered_tags => |f| blk: {
                var out = TriggeredTagsFormat{
                    .at_least_one = f.at_least_one,
                    .stop_after_first = f.stop_after_first,
                };
                try clone_str_list(allocator, &out.triggers, f.triggers.items);
                try clone_tags(allocator, &out.tags, &f.tags);
                try clone_str_list(allocator, &out.excludes, f.excludes.items);
                try clone_str_list(allocator, &out.detected_end_strs, f.detected_end_strs.items);
                break :blk .{ .triggered_tags = out };
            },
            .tags_with_separator => |f| blk: {
                var out = TagsWithSeparatorFormat{
                    .separator = try allocator.dupe(u8, f.separator),
                    .at_least_one = f.at_least_one,
                    .stop_after_first = f.stop_after_first,
                };
                try clone_tags(allocator, &out.tags, &f.tags);
                break :blk .{ .tags_with_separator = out };
            },
            .optional => |f| blk: {
                const content = try allocator.create(Format);
                content.* = try f.content.clone(allocator);
                break :blk .{ .optional = .{ .content = content } };
            },
            .plus => |f| blk: {
                const content = try allocator.create(Format);
                content.* = try f.content.clone(allocator);
                break :blk .{ .plus = .{ .content = content } };
            },
            .star => |f| blk: {
                const content = try allocator.create(Format);
                content.* = try f.content.clone(allocator);
                break :blk .{ .star = .{ .content = content } };
            },
            .repeat => |f| blk: {
                const content = try allocator.create(Format);
                content.* = try f.content.clone(allocator);
                break :blk .{ .repeat = .{ .min = f.min, .max = f.max, .content = content } };
            },
            .token => |f| .{ .token = .{
                .token = try clone_int_or_string(allocator, f.token),
                .resolved_token_id = f.resolved_token_id,
            } },
            .exclude_token => |f| blk: {
                var out = ExcludeTokenFormat{};
                try clone_int_or_strings(allocator, &out.exclude_tokens, &f.exclude_tokens);
                try out.resolved_token_ids.appendSlice(allocator, f.resolved_token_ids.items);
                try out.detected_end_token_ids.appendSlice(allocator, f.detected_end_token_ids.items);
                break :blk .{ .exclude_token = out };
            },
            .any_tokens => |f| blk: {
                var out = AnyTokensFormat{ .max_tokens = f.max_tokens };
                try clone_int_or_strings(allocator, &out.exclude_tokens, &f.exclude_tokens);
                try out.resolved_exclude_token_ids.appendSlice(allocator, f.resolved_exclude_token_ids.items);
                try out.detected_end_token_ids.appendSlice(allocator, f.detected_end_token_ids.items);
                break :blk .{ .any_tokens = out };
            },
            .token_triggered_tags => |f| blk: {
                var out = TokenTriggeredTagsFormat{
                    .at_least_one = f.at_least_one,
                    .stop_after_first = f.stop_after_first,
                };
                try clone_int_or_strings(allocator, &out.trigger_tokens, &f.trigger_tokens);
                try clone_tags(allocator, &out.tags, &f.tags);
                try clone_int_or_strings(allocator, &out.exclude_tokens, &f.exclude_tokens);
                try out.resolved_trigger_token_ids.appendSlice(allocator, f.resolved_trigger_token_ids.items);
                try out.resolved_exclude_token_ids.appendSlice(allocator, f.resolved_exclude_token_ids.items);
                try out.detected_end_token_ids.appendSlice(allocator, f.detected_end_token_ids.items);
                break :blk .{ .token_triggered_tags = out };
            },
            .dispatch => |f| blk: {
                var out = DispatchFormat{ .loop_after_dispatch = f.loop_after_dispatch };
                try out.rules.ensureTotalCapacity(allocator, f.rules.items.len);
                for (f.rules.items) |rule| {
                    const content = try allocator.create(Format);
                    content.* = try rule.content.clone(allocator);
                    out.rules.appendAssumeCapacity(.{
                        .trigger = try allocator.dupe(u8, rule.trigger),
                        .content = content,
                    });
                }
                try clone_str_list(allocator, &out.excludes, f.excludes.items);
                break :blk .{ .dispatch = out };
            },
            .token_dispatch => |f| blk: {
                var out = TokenDispatchFormat{ .loop_after_dispatch = f.loop_after_dispatch };
                try out.rules.ensureTotalCapacity(allocator, f.rules.items.len);
                for (f.rules.items) |rule| {
                    const content = try allocator.create(Format);
                    content.* = try rule.content.clone(allocator);
                    out.rules.appendAssumeCapacity(.{
                        .trigger = try clone_int_or_string(allocator, rule.trigger),
                        .content = content,
                    });
                }
                try clone_int_or_strings(allocator, &out.exclude_tokens, &f.exclude_tokens);
                try out.resolved_trigger_token_ids.appendSlice(allocator, f.resolved_trigger_token_ids.items);
                try out.resolved_exclude_token_ids.appendSlice(allocator, f.resolved_exclude_token_ids.items);
                break :blk .{ .token_dispatch = out };
            },
        };
    }
};

// ----------------------------- helpers -----------------------------

fn eq_opt_i32(a: ?i32, b: ?i32) bool {
    return a == b;
}

fn str_list_eql(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

fn i32_list_eql(a: []const i32, b: []const i32) bool {
    return std.mem.eql(i32, a, b);
}

fn int_or_string_eql(a: IntOrString, b: IntOrString) bool {
    return a.eql(b);
}

fn int_or_strings_eql(a: *const std.ArrayList(IntOrString), b: *const std.ArrayList(IntOrString)) bool {
    if (a.items.len != b.items.len) return false;
    for (a.items, b.items) |x, y| {
        if (!int_or_string_eql(x, y)) return false;
    }
    return true;
}

fn formats_eql(a: *const std.ArrayList(Format), b: *const std.ArrayList(Format)) bool {
    if (a.items.len != b.items.len) return false;
    for (a.items, b.items) |*x, *y| {
        if (!Format.eql(x, y)) return false;
    }
    return true;
}

fn json_schema_eql(a: *const JsonSchemaFormat, b: *const JsonSchemaFormat) bool {
    return std.mem.eql(u8, a.json_schema, b.json_schema) and
        std.mem.eql(u8, a.style, b.style) and
        a.any_order == b.any_order and
        a.max_whitespace_cnt == b.max_whitespace_cnt and
        str_list_eql(a.excludes, b.excludes);
}

fn tag_eql(a: *const TagFormat, b: *const TagFormat) bool {
    const begin_eql = switch (a.begin) {
        .str => |s| switch (b.begin) {
            .str => |t| std.mem.eql(u8, s, t),
            else => false,
        },
        .token => |t| switch (b.begin) {
            .token => |u| t.resolved_token_id == u.resolved_token_id and int_or_string_eql(t.token, u.token),
            else => false,
        },
    };
    if (!begin_eql) return false;
    const end_eql = switch (a.end) {
        .strings => |s| switch (b.end) {
            .strings => |t| str_list_eql(s.items, t.items),
            else => false,
        },
        .token => |t| switch (b.end) {
            .token => |u| t.resolved_token_id == u.resolved_token_id and int_or_string_eql(t.token, u.token),
            else => false,
        },
    };
    if (!end_eql) return false;
    return Format.eql(a.content, b.content);
}

fn tags_eql(a: *const std.ArrayList(TagFormat), b: *const std.ArrayList(TagFormat)) bool {
    if (a.items.len != b.items.len) return false;
    for (a.items, b.items) |*x, *y| {
        if (!tag_eql(x, y)) return false;
    }
    return true;
}

fn rules_eql_str(a: *const std.ArrayList(DispatchFormat.Rule), b: *const std.ArrayList(DispatchFormat.Rule)) bool {
    if (a.items.len != b.items.len) return false;
    for (a.items, b.items) |*x, *y| {
        if (!std.mem.eql(u8, x.trigger, y.trigger) or !Format.eql(x.content, y.content)) return false;
    }
    return true;
}

fn rules_eql_int(a: *const std.ArrayList(TokenDispatchFormat.Rule), b: *const std.ArrayList(TokenDispatchFormat.Rule)) bool {
    if (a.items.len != b.items.len) return false;
    for (a.items, b.items) |*x, *y| {
        if (!int_or_string_eql(x.trigger, y.trigger) or !Format.eql(x.content, y.content)) return false;
    }
    return true;
}

fn hash_str_list(hasher: anytype, items: []const []const u8) void {
    std.hash.autoHash(hasher, items.len);
    for (items) |s| hasher.update(s);
}

fn hash_i32_list(hasher: anytype, items: []const i32) void {
    std.hash.autoHash(hasher, items.len);
    for (items) |i| std.hash.autoHash(hasher, i);
}

fn hash_int_or_strings(hasher: anytype, items: *const std.ArrayList(IntOrString)) void {
    std.hash.autoHash(hasher, items.items.len);
    for (items.items) |item| item.hash(hasher);
}

fn hash_formats(hasher: anytype, items: *const std.ArrayList(Format)) void {
    std.hash.autoHash(hasher, items.items.len);
    for (items.items) |*item| item.hash(hasher);
}

fn hash_tags(hasher: anytype, items: *const std.ArrayList(TagFormat)) void {
    std.hash.autoHash(hasher, items.items.len);
    for (items.items) |*item| hash_tag(hasher, item);
}

fn hash_tag(hasher: anytype, tag: *const TagFormat) void {
    switch (tag.begin) {
        .str => |s| {
            std.hash.autoHash(hasher, @as(u8, 0));
            hasher.update(s);
        },
        .token => |t| {
            std.hash.autoHash(hasher, @as(u8, 1));
            t.token.hash(hasher);
            std.hash.autoHash(hasher, t.resolved_token_id);
        },
    }
    Format.hash(tag.content, hasher);
    switch (tag.end) {
        .strings => |s| {
            std.hash.autoHash(hasher, @as(u8, 0));
            hash_str_list(hasher, s.items);
        },
        .token => |t| {
            std.hash.autoHash(hasher, @as(u8, 1));
            t.token.hash(hasher);
            std.hash.autoHash(hasher, t.resolved_token_id);
        },
    }
}

fn hash_json_schema(hasher: anytype, f: *const JsonSchemaFormat) void {
    hasher.update(f.json_schema);
    hasher.update(f.style);
    std.hash.autoHash(hasher, f.any_order);
    hash_opt_i32(hasher, f.max_whitespace_cnt);
    hash_str_list(hasher, f.excludes);
}

fn hash_opt_i32(hasher: anytype, value: ?i32) void {
    std.hash.autoHash(hasher, value);
}

fn free_str_list(allocator: Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |s| allocator.free(s);
}

fn deinit_formats(allocator: Allocator, list: *std.ArrayList(Format)) void {
    for (list.items) |*item| item.deinit(allocator);
    list.deinit(allocator);
}

fn deinit_tags(allocator: Allocator, list: *std.ArrayList(TagFormat)) void {
    for (list.items) |*item| deinit_tag(allocator, item);
    list.deinit(allocator);
}

fn deinit_tag(allocator: Allocator, tag: *TagFormat) void {
    switch (tag.begin) {
        .str => |s| allocator.free(s),
        .token => |t| deinit_int_or_string(allocator, t.token),
    }
    switch (tag.end) {
        .strings => |*s| {
            free_str_list(allocator, s);
            s.deinit(allocator);
        },
        .token => |t| deinit_int_or_string(allocator, t.token),
    }
    tag.content.deinit(allocator);
    allocator.destroy(tag.content);
}

fn deinit_json_schema(allocator: Allocator, f: *JsonSchemaFormat) void {
    allocator.free(f.json_schema);
    allocator.free(f.style);
    for (f.excludes) |e| allocator.free(e);
    if (f.excludes.len != 0) allocator.free(f.excludes);
}

fn deinit_int_or_string(allocator: Allocator, value: IntOrString) void {
    switch (value) {
        .int => {},
        .str => |s| allocator.free(s),
    }
}

fn deinit_int_or_string_list(allocator: Allocator, list: *std.ArrayList(IntOrString)) void {
    for (list.items) |item| deinit_int_or_string(allocator, item);
    list.deinit(allocator);
}

fn clone_str_list(allocator: Allocator, out: *std.ArrayList([]const u8), items: []const []const u8) Allocator.Error!void {
    try out.ensureTotalCapacity(allocator, items.len);
    for (items) |s| out.appendAssumeCapacity(try allocator.dupe(u8, s));
}

fn clone_int_or_string(allocator: Allocator, value: IntOrString) Allocator.Error!IntOrString {
    return switch (value) {
        .int => |i| .{ .int = i },
        .str => |s| .{ .str = try allocator.dupe(u8, s) },
    };
}

fn clone_int_or_strings(allocator: Allocator, out: *std.ArrayList(IntOrString), items: *const std.ArrayList(IntOrString)) Allocator.Error!void {
    try out.ensureTotalCapacity(allocator, items.items.len);
    for (items.items) |item| out.appendAssumeCapacity(try clone_int_or_string(allocator, item));
}

fn clone_formats(allocator: Allocator, out: *std.ArrayList(Format), items: *const std.ArrayList(Format)) Allocator.Error!void {
    try out.ensureTotalCapacity(allocator, items.items.len);
    for (items.items) |*item| out.appendAssumeCapacity(try item.clone(allocator));
}

fn clone_tags(allocator: Allocator, out: *std.ArrayList(TagFormat), items: *const std.ArrayList(TagFormat)) Allocator.Error!void {
    try out.ensureTotalCapacity(allocator, items.items.len);
    for (items.items) |*item| out.appendAssumeCapacity(try clone_tag(allocator, item));
}

fn clone_tag(allocator: Allocator, tag: *const TagFormat) Allocator.Error!TagFormat {
    const begin: TagBegin = switch (tag.begin) {
        .str => |s| .{ .str = try allocator.dupe(u8, s) },
        .token => |t| .{ .token = .{
            .token = try clone_int_or_string(allocator, t.token),
            .resolved_token_id = t.resolved_token_id,
        } },
    };
    const end: TagEnd = switch (tag.end) {
        .strings => |s| blk: {
            var list: std.ArrayList([]const u8) = .empty;
            try clone_str_list(allocator, &list, s.items);
            break :blk .{ .strings = list };
        },
        .token => |t| .{ .token = .{
            .token = try clone_int_or_string(allocator, t.token),
            .resolved_token_id = t.resolved_token_id,
        } },
    };
    const content = try allocator.create(Format);
    content.* = try tag.content.clone(allocator);
    return .{ .begin = begin, .content = content, .end = end };
}

fn clone_json_schema(allocator: Allocator, f: *const JsonSchemaFormat) Allocator.Error!JsonSchemaFormat {
    var excludes: std.ArrayList([]const u8) = .empty;
    try clone_str_list(allocator, &excludes, f.excludes);
    return .{
        .json_schema = try allocator.dupe(u8, f.json_schema),
        .style = try allocator.dupe(u8, f.style),
        .any_order = f.any_order,
        .max_whitespace_cnt = f.max_whitespace_cnt,
        .excludes = try excludes.toOwnedSlice(allocator),
    };
}
