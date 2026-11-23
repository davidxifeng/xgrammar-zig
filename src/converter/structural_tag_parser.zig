//! Parses a structural-tag JSON document into the `Format` IR (`structural_tag_parser.rs`).
//!
//! The thread-local depth cell becomes an explicit depth pointer threaded through the
//! recursive passes. Strings are allocated from the caller's allocator (freed via
//! `Format.deinit`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const any_text_format = @import("any_text_format.zig");
const any_tokens_format = @import("any_tokens_format.zig");
const json_format_mod = @import("json_format.zig");
const json_schema_format = @import("json_schema_format.zig");
const lark_lexer = @import("lark_lexer.zig");
const structural_tag_error = @import("structural_tag_error.zig");
const structural_tag_format = @import("structural_tag_format.zig");
const support = @import("../support/mod.zig");
const AnyTextFormat = any_text_format.AnyTextFormat;
const AnyTokensFormat = any_tokens_format.AnyTokensFormat;
const Format = structural_tag_format.Format;
const IntOrString = structural_tag_format.IntOrString;
const JsonFormat = json_format_mod.JsonFormat;
const JsonSchemaFormat = json_schema_format.JsonSchemaFormat;
const StructuralTagError = structural_tag_error.StructuralTagError;
const StructuralTagErrorInfo = structural_tag_error.StructuralTagErrorInfo;
const parse_json = support.json_parse.parse_json;

/// Formats are walked by several recursive passes, so their nesting is capped explicitly
/// (far below the global recursion limit, which the native stack could not sustain).
const MAX_FORMAT_DEPTH: usize = 100;

const Ctx = struct {
    gpa: Allocator,
    diag: ?*?StructuralTagErrorInfo,
    /// JSON value tree + sorted re-serialization scratch.
    arena: Allocator,

    fn invalid(self: *const Ctx, message: []const u8) StructuralTagError {
        if (self.diag) |d| {
            structural_tag_error.set_info(d, try structural_tag_error.invalid(self.gpa, message), self.gpa) catch return error.OutOfMemory;
        }
        return error.InvalidStructuralTag;
    }

    fn invalid_fmt(self: *const Ctx, comptime fmt: []const u8, args: anytype) StructuralTagError {
        const message = std.fmt.allocPrint(self.gpa, fmt, args) catch return error.OutOfMemory;
        defer self.gpa.free(message);
        return self.invalid(message);
    }

    fn invalid_kind(self: *const Ctx, kind: StructuralTagError, message: []const u8) StructuralTagError {
        if (self.diag) |d| {
            structural_tag_error.set_info(d, .{ .kind = kind, .message = self.gpa.dupe(u8, message) catch return error.OutOfMemory }, self.gpa) catch return error.OutOfMemory;
        }
        return @errorCast(kind);
    }
};

/// Parses a structural-tag JSON string into its `Format`. On failure `diag` receives the
/// error kind and message (`format_message` reproduces the Rust `Display` text).
pub fn parse_structural_tag(gpa: Allocator, json: []const u8, diag: ?*?StructuralTagErrorInfo) StructuralTagError!Format {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ctx = Ctx{ .gpa = gpa, .diag = diag, .arena = arena.allocator() };
    const value = parse_json(ctx.arena, json) catch |e| {
        const message = try std.fmt.allocPrint(gpa, "Failed to parse JSON: {s}", .{@errorName(e)});
        defer gpa.free(message);
        return ctx.invalid_kind(error.InvalidJson, message);
    };
    var depth: usize = 0;
    const format = try parse_structural_tag_value(&ctx, &value, &depth);
    return format.clone(gpa) catch return error.OutOfMemory;
}

fn parse_structural_tag_value(ctx: *const Ctx, value: *const std.json.Value, depth: *usize) StructuralTagError!Format {
    if (value.* != .object) {
        return ctx.invalid("Structural tag must be an object");
    }
    const obj = &value.object;
    if (obj.get("type")) |ty| {
        const ty_str: ?[]const u8 = switch (ty) {
            .string => |s| s,
            else => null,
        };
        if (ty_str == null or !std.mem.eql(u8, ty_str.?, "structural_tag")) {
            return ctx.invalid("Structural tag's type must be a string \"structural_tag\"");
        }
    }
    const format = obj.get("format") orelse {
        return ctx.invalid("Structural tag must have a format field");
    };
    return parse_format(ctx, &format, depth);
}

fn parse_format(ctx: *const Ctx, value: *const std.json.Value, depth: *usize) StructuralTagError!Format {
    depth.* += 1;
    defer depth.* -= 1;
    if (depth.* > MAX_FORMAT_DEPTH) {
        return ctx.invalid_fmt("Formats are nested deeper than {d} levels", .{MAX_FORMAT_DEPTH});
    }
    return parse_format_object(ctx, value, depth);
}

fn parse_format_object(ctx: *const Ctx, value: *const std.json.Value, depth: *usize) StructuralTagError!Format {
    if (value.* != .object) {
        return ctx.invalid("Format must be an object");
    }
    const obj = &value.object;
    if (obj.get("type")) |ty_value| {
        const ty: []const u8 = switch (ty_value) {
            .string => |s| s,
            else => return ctx.invalid("Format's type must be a string"),
        };
        if (std.mem.eql(u8, ty, "const_string")) return .{ .const_string = try parse_const_string(ctx, obj) };
        if (std.mem.eql(u8, ty, "json_schema")) return .{ .json_schema = try parse_json_schema(ctx, obj, null) };
        if (std.mem.eql(u8, ty, "any_text")) return .{ .any_text = try parse_any_text(ctx, obj) };
        if (std.mem.eql(u8, ty, "sequence")) return .{ .sequence = try parse_sequence(ctx, obj, depth) };
        if (std.mem.eql(u8, ty, "or")) return .{ .or_fmt = try parse_or(ctx, obj, depth) };
        if (std.mem.eql(u8, ty, "tag")) return .{ .tag = try parse_tag(ctx, obj, depth) };
        if (std.mem.eql(u8, ty, "triggered_tags")) return .{ .triggered_tags = try parse_triggered_tags(ctx, obj, depth) };
        if (std.mem.eql(u8, ty, "tags_with_separator")) return .{ .tags_with_separator = try parse_tags_with_separator(ctx, obj, depth) };
        if (std.mem.eql(u8, ty, "optional")) {
            return .{ .optional = .{ .content = try boxed(ctx, try parse_content(ctx, obj, "Optional", depth)) } };
        }
        if (std.mem.eql(u8, ty, "plus")) {
            return .{ .plus = .{ .content = try boxed(ctx, try parse_content(ctx, obj, "Plus", depth)) } };
        }
        if (std.mem.eql(u8, ty, "star")) {
            return .{ .star = .{ .content = try boxed(ctx, try parse_content(ctx, obj, "Star", depth)) } };
        }
        if (std.mem.eql(u8, ty, "repeat")) return .{ .repeat = try parse_repeat(ctx, obj, depth) };
        if (std.mem.eql(u8, ty, "qwen_xml_parameter")) {
            return .{ .json_schema = try parse_json_schema(ctx, obj, "qwen_xml") };
        }
        if (std.mem.eql(u8, ty, "grammar")) return .{ .grammar = try parse_grammar(ctx, obj) };
        if (std.mem.eql(u8, ty, "regex")) return .{ .regex = try parse_regex(ctx, obj) };
        if (std.mem.eql(u8, ty, "token")) return .{ .token = try parse_token(ctx, obj) };
        if (std.mem.eql(u8, ty, "exclude_token")) return .{ .exclude_token = try parse_exclude_token(ctx, obj) };
        if (std.mem.eql(u8, ty, "any_tokens")) return .{ .any_tokens = try parse_any_tokens(ctx, obj) };
        if (std.mem.eql(u8, ty, "token_triggered_tags")) return .{ .token_triggered_tags = try parse_token_triggered_tags(ctx, obj, depth) };
        if (std.mem.eql(u8, ty, "dispatch")) return .{ .dispatch = try parse_dispatch(ctx, obj, depth) };
        if (std.mem.eql(u8, ty, "token_dispatch")) return .{ .token_dispatch = try parse_token_dispatch(ctx, obj, depth) };
        return ctx.invalid_fmt("Format type not recognized: {s}", .{ty});
    }

    // No type: try each format, tag first.
    if (parse_tag(ctx, obj, depth)) |f| {
        return .{ .tag = f };
    } else |_| {}
    if (parse_const_string(ctx, obj)) |f| {
        return .{ .const_string = f };
    } else |_| {}
    if (parse_json_schema(ctx, obj, null)) |f| {
        return .{ .json_schema = f };
    } else |_| {}
    if (parse_any_text(ctx, obj)) |f| {
        return .{ .any_text = f };
    } else |_| {}
    if (parse_sequence(ctx, obj, depth)) |f| {
        return .{ .sequence = f };
    } else |_| {}
    if (parse_or(ctx, obj, depth)) |f| {
        return .{ .or_fmt = f };
    } else |_| {}
    if (parse_triggered_tags(ctx, obj, depth)) |f| {
        return .{ .triggered_tags = f };
    } else |_| {}
    if (parse_tags_with_separator(ctx, obj, depth)) |f| {
        return .{ .tags_with_separator = f };
    } else |_| {}
    if (parse_content(ctx, obj, "Optional", depth)) |content| {
        return .{ .optional = .{ .content = try boxed(ctx, content) } };
    } else |_| {}
    if (parse_repeat(ctx, obj, depth)) |f| {
        return .{ .repeat = f };
    } else |_| {}
    if (parse_dispatch(ctx, obj, depth)) |f| {
        return .{ .dispatch = f };
    } else |_| {}
    if (parse_token_dispatch(ctx, obj, depth)) |f| {
        return .{ .token_dispatch = f };
    } else |_| {}
    return ctx.invalid_fmt("Invalid format: {s}", .{try serialize_value(ctx, value)});
}

fn boxed(ctx: *const Ctx, format: Format) StructuralTagError!*Format {
    const out = ctx.arena.create(Format) catch return error.OutOfMemory;
    out.* = format;
    return out;
}

/// Compact JSON serialization with sorted object keys (Rust `serde_json::Value::to_string`).
fn serialize_value(ctx: *const Ctx, value: *const std.json.Value) StructuralTagError![]u8 {
    return lark_lexer.serialize_json_value_sorted(ctx.arena, value.*) catch return error.OutOfMemory;
}

fn parse_const_string(ctx: *const Ctx, obj: *const std.json.ObjectMap) StructuralTagError!structural_tag_format.ConstStringFormat {
    const value = obj.get("value") orelse return ctx.invalid("ConstString format must have a value field with a string");
    switch (value) {
        .string => |s| return .{ .value = ctx.arena.dupe(u8, s) catch return error.OutOfMemory },
        else => return ctx.invalid("ConstString format must have a value field with a string"),
    }
}

fn parse_json_schema(ctx: *const Ctx, obj: *const std.json.ObjectMap, style_override: ?[]const u8) StructuralTagError!JsonSchemaFormat {
    const js = obj.get("json_schema") orelse {
        return ctx.invalid("JSON schema format must have a json_schema field with a object or boolean value");
    };
    switch (js) {
        .object, .bool => {},
        else => return ctx.invalid("JSON schema format must have a json_schema field with a object or boolean value"),
    }
    var style: []const u8 = "json";
    if (style_override) |s| {
        style = ctx.arena.dupe(u8, s) catch return error.OutOfMemory;
    } else if (obj.get("style")) |style_value| {
        switch (style_value) {
            .string => |s| {
                if (JsonFormat.from_name(s) == null) {
                    return ctx.invalid("style must be \"json\", \"qwen_xml\", \"minimax_xml\", \"minimax_m3_xml\", \"deepseek_xml\", \"glm_xml\", \"cohere_xml\", \"kimi_k3_xml\", or \"deepseek_v4_1_xml\"");
                }
                style = ctx.arena.dupe(u8, s) catch return error.OutOfMemory;
            },
            else => return ctx.invalid("style must be \"json\", \"qwen_xml\", \"minimax_xml\", \"minimax_m3_xml\", \"deepseek_xml\", \"glm_xml\", \"cohere_xml\", \"kimi_k3_xml\", or \"deepseek_v4_1_xml\""),
        }
    }
    var any_order = false;
    if (obj.get("any_order")) |any_order_value| {
        switch (any_order_value) {
            .bool => |b| any_order = b,
            else => return ctx.invalid("any_order must be a boolean"),
        }
    }
    var max_whitespace_cnt: ?i32 = null;
    if (obj.get("max_whitespace_cnt")) |mw_value| {
        switch (mw_value) {
            .null => {},
            .integer => |i| {
                if (i < std.math.minInt(i32) or i > std.math.maxInt(i32)) {
                    return ctx.invalid("max_whitespace_cnt must be an integer or null");
                }
                max_whitespace_cnt = @intCast(i);
            },
            .float => |f| {
                if (f != @trunc(f) or f < std.math.minInt(i32) or f > std.math.maxInt(i32)) {
                    return ctx.invalid("max_whitespace_cnt must be an integer or null");
                }
                max_whitespace_cnt = @intFromFloat(f);
            },
            else => return ctx.invalid("max_whitespace_cnt must be an integer or null"),
        }
    }
    var excludes: std.ArrayList([]const u8) = .empty;
    if (obj.get("excludes")) |excludes_value| {
        if (excludes_value != .array) {
            return ctx.invalid("JSONSchema format's excludes must be an array of non-empty strings");
        }
        for (excludes_value.array.items) |item| {
            switch (item) {
                .string => |s| {
                    if (s.len == 0) {
                        return ctx.invalid("JSONSchema format's excludes must be an array of non-empty strings");
                    }
                    excludes.append(ctx.arena, ctx.arena.dupe(u8, s) catch return error.OutOfMemory) catch return error.OutOfMemory;
                },
                else => return ctx.invalid("JSONSchema format's excludes must be an array of non-empty strings"),
            }
        }
        std.mem.sort([]const u8, excludes.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);
        dedup_str_list(&excludes);
    }
    return .{
        .json_schema = lark_lexer.serialize_json_value_sorted(ctx.arena, js) catch return error.OutOfMemory,
        .style = style,
        .any_order = any_order,
        .max_whitespace_cnt = max_whitespace_cnt,
        .excludes = excludes.items,
    };
}

fn dedup_str_list(list: *std.ArrayList([]const u8)) void {
    if (list.items.len <= 1) return;
    var write: usize = 1;
    for (list.items[1..]) |item| {
        if (!std.mem.eql(u8, item, list.items[write - 1])) {
            list.items[write] = item;
            write += 1;
        }
    }
    list.shrinkRetainingCapacity(write);
}

/// An optional non-negative int32 budget field; absent or null means no budget.
fn parse_optional_budget(ctx: *const Ctx, obj: *const std.json.ObjectMap, field_name: []const u8, format_name: []const u8) StructuralTagError!?i32 {
    const value = obj.get(field_name) orelse return null;
    switch (value) {
        .null => return null,
        .integer => |i| {
            if (i < 0 or i > std.math.maxInt(i32)) {
                return ctx.invalid_fmt("{s} in {s} must be a non-negative 32-bit integer or null", .{ field_name, format_name });
            }
            return @intCast(i);
        },
        .float => |f| {
            if (f >= 0.0 and f <= @as(f64, @floatFromInt(std.math.maxInt(i32))) and f == @trunc(f)) {
                return @intFromFloat(f);
            }
            return ctx.invalid_fmt("{s} in {s} must be a non-negative 32-bit integer or null", .{ field_name, format_name });
        },
        else => return ctx.invalid_fmt("{s} in {s} must be a non-negative 32-bit integer or null", .{ field_name, format_name }),
    }
}

fn parse_any_text(ctx: *const Ctx, obj: *const std.json.ObjectMap) StructuralTagError!AnyTextFormat {
    const max_tokens = try parse_optional_budget(ctx, obj, "max_tokens", "any_text");
    const max_chars = try parse_optional_budget(ctx, obj, "max_chars", "any_text");
    const excludes = obj.get("excludes") orelse {
        if (obj.get("type") == null) {
            return ctx.invalid("Any text format should not have any fields other than type");
        }
        return .{ .max_tokens = max_tokens, .max_chars = max_chars };
    };
    if (excludes != .array) {
        return ctx.invalid("AnyText format's excluded_strs field must be an array");
    }
    var out: std.ArrayList([]const u8) = .empty;
    for (excludes.array.items) |item| {
        switch (item) {
            .string => |s| out.append(ctx.arena, ctx.arena.dupe(u8, s) catch return error.OutOfMemory) catch return error.OutOfMemory,
            else => return ctx.invalid("AnyText format's excluded_strs array must contain strings"),
        }
    }
    return .{ .excludes = out, .max_tokens = max_tokens, .max_chars = max_chars };
}

fn parse_grammar(ctx: *const Ctx, obj: *const std.json.ObjectMap) StructuralTagError!structural_tag_format.GrammarFormat {
    const value = obj.get("grammar") orelse return ctx.invalid("Grammar format must have a grammar field with a non-empty string");
    switch (value) {
        .string => |s| {
            if (s.len == 0) return ctx.invalid("Grammar format must have a grammar field with a non-empty string");
            return .{ .grammar = ctx.arena.dupe(u8, s) catch return error.OutOfMemory };
        },
        else => return ctx.invalid("Grammar format must have a grammar field with a non-empty string"),
    }
}

fn parse_regex(ctx: *const Ctx, obj: *const std.json.ObjectMap) StructuralTagError!structural_tag_format.RegexFormat {
    const value = obj.get("pattern") orelse return ctx.invalid("Regex format must have a pattern field with a non-empty string");
    switch (value) {
        .string => |s| {
            if (s.len == 0) return ctx.invalid("Regex format must have a pattern field with a non-empty string");
            return .{ .pattern = ctx.arena.dupe(u8, s) catch return error.OutOfMemory };
        },
        else => return ctx.invalid("Regex format must have a pattern field with a non-empty string"),
    }
}

fn parse_elements(ctx: *const Ctx, obj: *const std.json.ObjectMap, kind: []const u8, depth: *usize) StructuralTagError!std.ArrayList(Format) {
    const elements = obj.get("elements") orelse {
        return ctx.invalid_fmt("{s} format must have an elements field with an array", .{kind});
    };
    if (elements != .array) {
        return ctx.invalid_fmt("{s} format must have an elements field with an array", .{kind});
    }
    var out: std.ArrayList(Format) = .empty;
    for (elements.array.items) |*item| {
        out.append(ctx.arena, try parse_format(ctx, item, depth)) catch return error.OutOfMemory;
    }
    if (out.items.len == 0) {
        return ctx.invalid_fmt("{s} format must have at least one element", .{kind});
    }
    // The list outlives the parse arena: move ownership to `gpa`.
    var owned: std.ArrayList(Format) = .empty;
    try owned.appendSlice(ctx.arena, out.items);
    return owned;
}

fn parse_sequence(ctx: *const Ctx, obj: *const std.json.ObjectMap, depth: *usize) StructuralTagError!structural_tag_format.SequenceFormat {
    return .{ .elements = try parse_elements(ctx, obj, "Sequence", depth), .is_unlimited = false };
}

fn parse_or(ctx: *const Ctx, obj: *const std.json.ObjectMap, depth: *usize) StructuralTagError!structural_tag_format.OrFormat {
    return .{ .elements = try parse_elements(ctx, obj, "Or", depth), .is_unlimited = false };
}

fn parse_content(ctx: *const Ctx, obj: *const std.json.ObjectMap, kind: []const u8, depth: *usize) StructuralTagError!Format {
    const content = obj.get("content") orelse {
        return ctx.invalid_fmt("{s} format must have a content field", .{kind});
    };
    return parse_format(ctx, &content, depth);
}

fn parse_tag_value(ctx: *const Ctx, value: *const std.json.Value, depth: *usize) StructuralTagError!structural_tag_format.TagFormat {
    if (value.* != .object) {
        return ctx.invalid("Tag format must be an object");
    }
    const obj = &value.object;
    if (obj.get("type")) |ty| {
        const ty_str: ?[]const u8 = switch (ty) {
            .string => |s| s,
            else => null,
        };
        if (ty_str == null or !std.mem.eql(u8, ty_str.?, "tag")) {
            return ctx.invalid("Tag format's type must be a string \"tag\"");
        }
    }
    return parse_tag(ctx, obj, depth);
}

fn parse_tag(ctx: *const Ctx, obj: *const std.json.ObjectMap, depth: *usize) StructuralTagError!structural_tag_format.TagFormat {
    const begin_val = obj.get("begin") orelse {
        return ctx.invalid("Tag format's begin field must be a string");
    };
    const begin: structural_tag_format.TagBegin = switch (begin_val) {
        .string => |s| .{ .str = ctx.arena.dupe(u8, s) catch return error.OutOfMemory },
        .object => |*o| blk: {
            // `obj.get` yields a copy; find the live pointer for token parsing.
            break :blk .{ .token = try parse_token(ctx, o) };
        },
        else => return ctx.invalid("Tag format's begin field must be a string"),
    };

    const content = obj.get("content") orelse {
        return ctx.invalid("Tag format must have a content field");
    };
    const content_format = try parse_format(ctx, &content, depth);

    const end_val = obj.get("end") orelse {
        return ctx.invalid("Tag format must have an end field");
    };
    const end: structural_tag_format.TagEnd = switch (end_val) {
        .string => |s| blk: {
            var strings: std.ArrayList([]const u8) = .empty;
            try strings.append(ctx.arena, ctx.arena.dupe(u8, s) catch return error.OutOfMemory);
            break :blk .{ .strings = strings };
        },
        .array => |arr| blk: {
            if (arr.items.len == 0) {
                return ctx.invalid("Tag format's end array cannot be empty");
            }
            var strings: std.ArrayList([]const u8) = .empty;
            for (arr.items) |item| {
                switch (item) {
                    .string => |s| strings.append(ctx.arena, ctx.arena.dupe(u8, s) catch return error.OutOfMemory) catch return error.OutOfMemory,
                    else => return ctx.invalid("Tag format's end array must contain only strings"),
                }
            }
            break :blk .{ .strings = strings };
        },
        .object => |o| .{ .token = try parse_token(ctx, &o) },
        else => return ctx.invalid("Tag format's end field must be a string or array of strings"),
    };

    return .{
        .begin = begin,
        .content = try boxed(ctx, content_format),
        .end = end,
    };
}

fn parse_bool_field(ctx: *const Ctx, obj: *const std.json.ObjectMap, key: []const u8) StructuralTagError!bool {
    const value = obj.get(key) orelse return false;
    return switch (value) {
        .bool => |b| b,
        else => ctx.invalid_fmt("{s} must be a boolean", .{key}),
    };
}

fn parse_tags(ctx: *const Ctx, obj: *const std.json.ObjectMap, missing_msg: []const u8, empty_msg: []const u8, depth: *usize) StructuralTagError!std.ArrayList(structural_tag_format.TagFormat) {
    const tags = obj.get("tags") orelse return ctx.invalid(missing_msg);
    if (tags != .array) return ctx.invalid(missing_msg);
    var out: std.ArrayList(structural_tag_format.TagFormat) = .empty;
    for (tags.array.items) |*item| {
        out.append(ctx.arena, try parse_tag_value(ctx, item, depth)) catch return error.OutOfMemory;
    }
    if (out.items.len == 0) {
        return ctx.invalid(empty_msg);
    }
    return out;
}

fn parse_triggered_tags(ctx: *const Ctx, obj: *const std.json.ObjectMap, depth: *usize) StructuralTagError!structural_tag_format.TriggeredTagsFormat {
    const triggers_arr = obj.get("triggers") orelse {
        return ctx.invalid("Triggered tags format must have a triggers field with an array");
    };
    if (triggers_arr != .array) {
        return ctx.invalid("Triggered tags format must have a triggers field with an array");
    }
    var triggers: std.ArrayList([]const u8) = .empty;
    for (triggers_arr.array.items) |item| {
        switch (item) {
            .string => |s| {
                if (s.len == 0) {
                    return ctx.invalid("Triggered tags format's triggers must be non-empty strings");
                }
                triggers.append(ctx.arena, ctx.arena.dupe(u8, s) catch return error.OutOfMemory) catch return error.OutOfMemory;
            },
            else => return ctx.invalid("Triggered tags format's triggers must be non-empty strings"),
        }
    }
    if (triggers.items.len == 0) {
        return ctx.invalid("Triggered tags format's triggers must be non-empty");
    }
    const tags = try parse_tags(
        ctx,
        obj,
        "Triggered tags format must have a tags field with an array",
        "Triggered tags format's tags must be non-empty",
        depth,
    );
    var excludes: std.ArrayList([]const u8) = .empty;
    if (obj.get("excludes")) |ex| {
        if (ex != .array) {
            return ctx.invalid("Triggered tags format should have a excludes field with an array");
        }
        for (ex.array.items) |item| {
            switch (item) {
                .string => |s| {
                    if (s.len == 0) {
                        return ctx.invalid("Triggered tags format's excluded_strs must be non-empty strings");
                    }
                    excludes.append(ctx.arena, ctx.arena.dupe(u8, s) catch return error.OutOfMemory) catch return error.OutOfMemory;
                },
                else => return ctx.invalid("Triggered tags format's excluded_strs must be non-empty strings"),
            }
        }
    }
    return .{
        .triggers = triggers,
        .tags = tags,
        .excludes = excludes,
        .at_least_one = try parse_bool_field(ctx, obj, "at_least_one"),
        .stop_after_first = try parse_bool_field(ctx, obj, "stop_after_first"),
    };
}

fn parse_tags_with_separator(ctx: *const Ctx, obj: *const std.json.ObjectMap, depth: *usize) StructuralTagError!structural_tag_format.TagsWithSeparatorFormat {
    const tags = try parse_tags(
        ctx,
        obj,
        "Tags with separator format must have a tags field with an array",
        "Tags with separator format's tags must be non-empty",
        depth,
    );
    const separator_value = obj.get("separator") orelse {
        return ctx.invalid("Tags with separator format's separator field must be a string");
    };
    const separator: []const u8 = switch (separator_value) {
        .string => |s| s,
        else => return ctx.invalid("Tags with separator format's separator field must be a string"),
    };
    return .{
        .tags = tags,
        .separator = ctx.arena.dupe(u8, separator) catch return error.OutOfMemory,
        .at_least_one = try parse_bool_field(ctx, obj, "at_least_one"),
        .stop_after_first = try parse_bool_field(ctx, obj, "stop_after_first"),
    };
}

fn parse_token(ctx: *const Ctx, obj: *const std.json.ObjectMap) StructuralTagError!structural_tag_format.TokenFormat {
    const token = obj.get("token") orelse return ctx.invalid("TokenFormat must have a token field");
    switch (token) {
        .string => |s| {
            if (s.len == 0) {
                return ctx.invalid("Token string must be non-empty");
            }
            return structural_tag_format.TokenFormat.new(ctx.arena, .{ .str = ctx.arena.dupe(u8, s) catch return error.OutOfMemory }) catch return error.OutOfMemory;
        },
        .integer => |i| {
            if (i < 0 or i > std.math.maxInt(i32)) {
                return parse_token_float(ctx, @floatFromInt(i));
            }
            if (i < 0) return ctx.invalid("Token ID must be non-negative");
            return structural_tag_format.TokenFormat.new(ctx.arena, .{ .int = @intCast(i) }) catch return error.OutOfMemory;
        },
        .float => |f| return parse_token_float(ctx, f),
        .number_string => |s| {
            const f = std.fmt.parseFloat(f64, s) catch return ctx.invalid("TokenFormat's token must be an integer or string");
            return parse_token_float(ctx, f);
        },
        else => return ctx.invalid("TokenFormat's token must be an integer or string"),
    }
}

fn parse_token_float(ctx: *const Ctx, d: f64) StructuralTagError!structural_tag_format.TokenFormat {
    if (d != @as(f64, @floatFromInt(@as(i32, @intFromFloat(d))))) {
        return ctx.invalid("Token ID must be an integer");
    }
    const id: i32 = @intFromFloat(d);
    if (id < 0) {
        return ctx.invalid("Token ID must be non-negative");
    }
    return structural_tag_format.TokenFormat.new(ctx.arena, .{ .int = id }) catch return error.OutOfMemory;
}

fn parse_int_or_string_array(ctx: *const Ctx, val: *const std.json.Value, field: []const u8) StructuralTagError!std.ArrayList(IntOrString) {
    if (val.* != .array) {
        return ctx.invalid_fmt("{s} must be an array", .{field});
    }
    var out: std.ArrayList(IntOrString) = .empty;
    for (val.array.items) |*item| {
        switch (item.*) {
            .string => |s| {
                if (s.len == 0) {
                    return ctx.invalid_fmt("{s} string elements must be non-empty", .{field});
                }
                out.append(ctx.arena, .{ .str = ctx.arena.dupe(u8, s) catch return error.OutOfMemory }) catch return error.OutOfMemory;
            },
            .integer => |i| {
                if (i < 0 or i > std.math.maxInt(i32)) {
                    return ctx.invalid_fmt("{s} elements must be non-negative integers or strings", .{field});
                }
                out.append(ctx.arena, .{ .int = @intCast(i) }) catch return error.OutOfMemory;
            },
            .float => |f| {
                if (f != @as(f64, @floatFromInt(@as(i32, @intFromFloat(f))))) {
                    return ctx.invalid_fmt("{s} elements must be integers, not floats", .{field});
                }
                const id: i32 = @intFromFloat(f);
                if (id < 0) {
                    return ctx.invalid_fmt("{s} elements must be non-negative integers or strings", .{field});
                }
                out.append(ctx.arena, .{ .int = id }) catch return error.OutOfMemory;
            },
            .number_string => |s| {
                const f = std.fmt.parseFloat(f64, s) catch {
                    return ctx.invalid_fmt("{s} elements must be integers or strings", .{field});
                };
                if (f != @as(f64, @floatFromInt(@as(i32, @intFromFloat(f))))) {
                    return ctx.invalid_fmt("{s} elements must be integers, not floats", .{field});
                }
                const id: i32 = @intFromFloat(f);
                if (id < 0) {
                    return ctx.invalid_fmt("{s} elements must be non-negative integers or strings", .{field});
                }
                out.append(ctx.arena, .{ .int = id }) catch return error.OutOfMemory;
            },
            else => return ctx.invalid_fmt("{s} elements must be integers or strings", .{field}),
        }
    }
    return out;
}

fn parse_exclude_token(ctx: *const Ctx, obj: *const std.json.ObjectMap) StructuralTagError!structural_tag_format.ExcludeTokenFormat {
    var exclude_tokens: std.ArrayList(IntOrString) = .empty;
    if (obj.get("exclude_tokens")) |v| {
        exclude_tokens = try parse_int_or_string_array(ctx, &v, "exclude_tokens");
    }
    return .{ .exclude_tokens = exclude_tokens };
}

fn parse_any_tokens(ctx: *const Ctx, obj: *const std.json.ObjectMap) StructuralTagError!AnyTokensFormat {
    var exclude_tokens: std.ArrayList(IntOrString) = .empty;
    if (obj.get("exclude_tokens")) |v| {
        exclude_tokens = try parse_int_or_string_array(ctx, &v, "exclude_tokens");
    }
    return .{
        .exclude_tokens = exclude_tokens,
        .max_tokens = try parse_optional_budget(ctx, obj, "max_tokens", "any_tokens"),
    };
}

fn parse_token_triggered_tags(ctx: *const Ctx, obj: *const std.json.ObjectMap, depth: *usize) StructuralTagError!structural_tag_format.TokenTriggeredTagsFormat {
    const triggers_val = obj.get("trigger_tokens") orelse {
        return ctx.invalid("TokenTriggeredTagsFormat must have a trigger_tokens field");
    };
    const trigger_tokens = try parse_int_or_string_array(ctx, &triggers_val, "trigger_tokens");
    if (trigger_tokens.items.len == 0) {
        return ctx.invalid("trigger_tokens must be non-empty");
    }
    const tags = try parse_tags(
        ctx,
        obj,
        "TokenTriggeredTagsFormat must have a tags field with an array",
        "TokenTriggeredTagsFormat tags must be non-empty",
        depth,
    );
    var exclude_tokens: std.ArrayList(IntOrString) = .empty;
    if (obj.get("exclude_tokens")) |v| {
        exclude_tokens = try parse_int_or_string_array(ctx, &v, "exclude_tokens");
    }
    return .{
        .trigger_tokens = trigger_tokens,
        .tags = tags,
        .exclude_tokens = exclude_tokens,
        .at_least_one = try parse_bool_field(ctx, obj, "at_least_one"),
        .stop_after_first = try parse_bool_field(ctx, obj, "stop_after_first"),
    };
}

fn parse_dispatch(ctx: *const Ctx, obj: *const std.json.ObjectMap, depth: *usize) StructuralTagError!structural_tag_format.DispatchFormat {
    const rules_arr = obj.get("rules") orelse {
        return ctx.invalid("TagDispatch format must have a rules field with an array");
    };
    if (rules_arr != .array) {
        return ctx.invalid("TagDispatch format must have a rules field with an array");
    }
    if (rules_arr.array.items.len == 0) {
        return ctx.invalid("TagDispatch format rules must be non-empty");
    }
    var rules: std.ArrayList(structural_tag_format.DispatchFormat.Rule) = .empty;
    for (rules_arr.array.items) |*item| {
        if (item.* != .array) {
            return ctx.invalid("TagDispatch pair must be a 2-element array");
        }
        const pair = item.array.items;
        if (pair.len != 2) {
            return ctx.invalid("TagDispatch pair must be a 2-element array");
        }
        const trigger: []const u8 = switch (pair[0]) {
            .string => |s| s,
            else => return ctx.invalid("TagDispatch pair first element must be a string"),
        };
        const content = try parse_format(ctx, &pair[1], depth);
        rules.append(ctx.arena, .{
            .trigger = ctx.arena.dupe(u8, trigger) catch return error.OutOfMemory,
            .content = try boxed(ctx, content),
        }) catch return error.OutOfMemory;
    }
    var excludes: std.ArrayList([]const u8) = .empty;
    if (obj.get("excludes")) |ex| {
        if (ex != .array) {
            return ctx.invalid("excludes must be an array");
        }
        for (ex.array.items) |item| {
            switch (item) {
                .string => |s| {
                    if (s.len == 0) return ctx.invalid("excludes must contain non-empty strings");
                    excludes.append(ctx.arena, ctx.arena.dupe(u8, s) catch return error.OutOfMemory) catch return error.OutOfMemory;
                },
                else => return ctx.invalid("excludes must contain non-empty strings"),
            }
        }
    }
    return .{
        .rules = rules,
        .loop_after_dispatch = try parse_bool_field(ctx, obj, "loop"),
        .excludes = excludes,
    };
}

fn parse_token_dispatch(ctx: *const Ctx, obj: *const std.json.ObjectMap, depth: *usize) StructuralTagError!structural_tag_format.TokenDispatchFormat {
    const rules_arr = obj.get("rules") orelse {
        return ctx.invalid("TokenTagDispatch format must have a rules field with an array");
    };
    if (rules_arr != .array) {
        return ctx.invalid("TokenTagDispatch format must have a rules field with an array");
    }
    if (rules_arr.array.items.len == 0) {
        return ctx.invalid("TokenTagDispatch format rules must be non-empty");
    }
    var rules: std.ArrayList(structural_tag_format.TokenDispatchFormat.Rule) = .empty;
    for (rules_arr.array.items) |*item| {
        if (item.* != .array) {
            return ctx.invalid("TokenTagDispatch pair must be a 2-element array");
        }
        const pair = item.array.items;
        if (pair.len != 2) {
            return ctx.invalid("TokenTagDispatch pair must be a 2-element array");
        }
        const trigger: IntOrString = switch (pair[0]) {
            .string => |s| .{ .str = ctx.arena.dupe(u8, s) catch return error.OutOfMemory },
            .integer => |i| blk: {
                if (i < 0 or i > std.math.maxInt(i32)) {
                    return ctx.invalid("Token ID must be an integer");
                }
                break :blk .{ .int = @intCast(i) };
            },
            .float => |f| blk: {
                if (f != @as(f64, @floatFromInt(@as(i32, @intFromFloat(f))))) {
                    return ctx.invalid("Token ID must be an integer");
                }
                break :blk .{ .int = @intFromFloat(f) };
            },
            else => return ctx.invalid("TokenTagDispatch pair first element must be an integer or string"),
        };
        const content = try parse_format(ctx, &pair[1], depth);
        rules.append(ctx.arena, .{
            .trigger = trigger,
            .content = try boxed(ctx, content),
        }) catch return error.OutOfMemory;
    }
    var exclude_tokens: std.ArrayList(IntOrString) = .empty;
    if (obj.get("exclude_tokens")) |v| {
        exclude_tokens = try parse_int_or_string_array(ctx, &v, "exclude_tokens");
    }
    return .{
        .rules = rules,
        .loop_after_dispatch = try parse_bool_field(ctx, obj, "loop"),
        .exclude_tokens = exclude_tokens,
    };
}

fn parse_repeat(ctx: *const Ctx, obj: *const std.json.ObjectMap, depth: *usize) StructuralTagError!structural_tag_format.RepeatFormat {
    const min_value = obj.get("min") orelse {
        return ctx.invalid("Repeat format must have a min field (number)");
    };
    const max_value = obj.get("max") orelse {
        return ctx.invalid("Repeat format must have a max field (number)");
    };
    const min_f: f64 = switch (min_value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch return ctx.invalid("Repeat format must have a min field (number)"),
        else => return ctx.invalid("Repeat format must have a min field (number)"),
    };
    const max_f: f64 = switch (max_value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch return ctx.invalid("Repeat format must have a max field (number)"),
        else => return ctx.invalid("Repeat format must have a max field (number)"),
    };
    // Rust `min as i64` saturates at the i64 bounds.
    const min_i: i64 = if (min_f >= 9.223372036854776e18)
        std.math.maxInt(i64)
    else if (min_f <= -9.223372036854776e18)
        std.math.minInt(i64)
    else
        @intFromFloat(min_f);
    var max_i: i64 = if (max_f >= 9.223372036854776e18)
        std.math.maxInt(i64)
    else if (max_f <= -9.223372036854776e18)
        std.math.minInt(i64)
    else
        @intFromFloat(max_f);
    if (max_i >= 0 and min_i > max_i) {
        return ctx.invalid("Repeat min must be <= max");
    }
    if (min_i < 0) {
        return ctx.invalid("Repeat min must be >= 0");
    }
    if (max_i < -1) {
        return ctx.invalid("Repeat max must be -1 (unbounded) or >= 0");
    }
    if (max_i > std.math.maxInt(i32)) {
        max_i = -1;
    }
    if (min_i > std.math.maxInt(i32)) {
        return ctx.invalid_fmt("Repeat min is too large, must be <= {d}", .{std.math.maxInt(i32)});
    }
    const content = try parse_content(ctx, obj, "Repeat", depth);
    return .{
        .min = @intCast(min_i),
        .max = @intCast(max_i),
        .content = try boxed(ctx, content),
    };
}
