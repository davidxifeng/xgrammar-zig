//! Parses a structural-tag JSON document into an arena-backed `Format` IR
//! (`structural_tag_parser.rs` + `structural_tag_error.rs`).
//!
//! Temporary JSON DOM storage lives in a local scratch arena that is freed before
//! `parseStructuralTag` returns; the resulting `Format` tree lives in `ParsedFormat`'s
//! arena (or a caller-supplied arena in `parseStructuralTagInto`). Diagnostics are
//! reported through `Diagnostic` (`structural_tag_invalid_json`,
//! `structural_tag_invalid_schema`, `structural_tag_invalid`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const Diagnostic = @import("../../Diagnostic.zig").Diagnostic;
const support = @import("../../support.zig");
const json_schema_parser = @import("../json_schema/parser.zig");
const JsonFormat = @import("../json_schema/spec.zig").JsonFormat;
const format = @import("format.zig");

const AnyTextFormat = format.AnyTextFormat;
const AnyTokensFormat = format.AnyTokensFormat;
const ConstStringFormat = format.ConstStringFormat;
const DispatchFormat = format.DispatchFormat;
const ExcludeTokenFormat = format.ExcludeTokenFormat;
const Format = format.Format;
const GrammarFormat = format.GrammarFormat;
const IntOrString = format.IntOrString;
const JsonSchemaFormat = format.JsonSchemaFormat;
const OrFormat = format.OrFormat;
const ParsedFormat = format.ParsedFormat;
const RegexFormat = format.RegexFormat;
const RepeatFormat = format.RepeatFormat;
const SequenceFormat = format.SequenceFormat;
const TagBegin = format.TagBegin;
const TagEnd = format.TagEnd;
const TagFormat = format.TagFormat;
const TagsWithSeparatorFormat = format.TagsWithSeparatorFormat;
const TokenDispatchFormat = format.TokenDispatchFormat;
const TokenFormat = format.TokenFormat;
const TokenTriggeredTagsFormat = format.TokenTriggeredTagsFormat;
const TriggeredTagsFormat = format.TriggeredTagsFormat;

/// Formats are walked by several recursive passes, so their nesting is capped explicitly
/// (far below the global recursion limit, which the native stack could not sustain).
pub const MAX_FORMAT_DEPTH: usize = 100;

/// Errors raised while parsing or converting a structural-tag specification.
pub const StructuralTagError = error{
    InvalidJson,
    InvalidJsonSchema,
    InvalidStructuralTag,
    OutOfMemory,
};

pub fn failStatic(
    err: StructuralTagError,
    diag: ?*Diagnostic,
    kind: Diagnostic.Kind,
    message: []const u8,
) StructuralTagError {
    if (diag) |d| d.setStatic(kind, message);
    return err;
}

pub fn failCopy(
    err: StructuralTagError,
    diag: ?*Diagnostic,
    gpa: Allocator,
    kind: Diagnostic.Kind,
    message: []const u8,
) StructuralTagError {
    if (diag) |d| d.setCopy(gpa, kind, message) catch return error.OutOfMemory;
    return err;
}

pub fn failFmt(
    err: StructuralTagError,
    diag: ?*Diagnostic,
    gpa: Allocator,
    kind: Diagnostic.Kind,
    comptime fmt: []const u8,
    args: anytype,
) StructuralTagError {
    if (diag) |d| d.setFmt(gpa, kind, fmt, args) catch return error.OutOfMemory;
    return err;
}

/// Compact JSON serialization with object keys sorted byte-lexicographically (`BTreeMap`
/// order), reusing `json_schema/parser.zig` string escaping and shortest number formatting.
pub fn serializeJsonSorted(allocator: Allocator, value: std.json.Value) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try writeJsonSorted(allocator, &out, value);
    return out.toOwnedSlice(allocator);
}

fn writeJsonSorted(allocator: Allocator, out: *std.ArrayList(u8), value: std.json.Value) Allocator.Error!void {
    switch (value) {
        .array => |arr| {
            try out.append(allocator, '[');
            for (arr.items, 0..) |item, i| {
                if (i != 0) try out.append(allocator, ',');
                try writeJsonSorted(allocator, out, item);
            }
            try out.append(allocator, ']');
        },
        .object => |obj| {
            const keys = try json_schema_parser.sortedKeys(allocator, obj);
            defer allocator.free(keys);
            try out.append(allocator, '{');
            for (keys, 0..) |key, i| {
                if (i != 0) try out.append(allocator, ',');
                const key_json = try json_schema_parser.serializeJson(allocator, .{ .string = key });
                defer allocator.free(key_json);
                try out.appendSlice(allocator, key_json);
                try out.append(allocator, ':');
                try writeJsonSorted(allocator, out, obj.get(key).?);
            }
            try out.append(allocator, '}');
        },
        else => {
            const scalar = try json_schema_parser.serializeJson(allocator, value);
            defer allocator.free(scalar);
            try out.appendSlice(allocator, scalar);
        },
    }
}

const Ctx = struct {
    gpa: Allocator,
    diag: ?*Diagnostic,
    /// Owns all parsed `Format` nodes, strings, slices, and list buffers.
    arena: Allocator,

    fn invalid(self: *const Ctx, message: []const u8) StructuralTagError {
        return failStatic(error.InvalidStructuralTag, self.diag, .structural_tag_invalid, message);
    }

    fn invalidFmt(self: *const Ctx, comptime fmt: []const u8, args: anytype) StructuralTagError {
        return failFmt(error.InvalidStructuralTag, self.diag, self.gpa, .structural_tag_invalid, fmt, args);
    }

    fn withoutDiag(self: *const Ctx) Ctx {
        return .{ .gpa = self.gpa, .diag = null, .arena = self.arena };
    }
};

/// Parses a structural-tag JSON string into an owning `ParsedFormat`.
///
/// On failure, `diag` (if non-null) receives `.structural_tag_invalid_json` or
/// `.structural_tag_invalid`.
pub fn parseStructuralTag(
    gpa: Allocator,
    json: []const u8,
    diag: ?*Diagnostic,
) StructuralTagError!ParsedFormat {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const root = try parseStructuralTagInto(arena_state.allocator(), gpa, json, diag);
    return .{
        .arena_state = arena_state,
        .root = root,
    };
}

/// Parses a structural-tag JSON string into `arena` (`Format` nodes/strings/lists) while
/// allocating temporary JSON DOM storage in a local scratch arena and diagnostic payloads
/// in `gpa`.
pub fn parseStructuralTagInto(
    arena: Allocator,
    gpa: Allocator,
    json: []const u8,
    diag: ?*Diagnostic,
) StructuralTagError!Format {
    var dom_arena = std.heap.ArenaAllocator.init(gpa);
    defer dom_arena.deinit();

    const value = support.parseJson(dom_arena.allocator(), json) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failFmt(
            error.InvalidJson,
            diag,
            gpa,
            .structural_tag_invalid_json,
            "Failed to parse JSON: {s}",
            .{@errorName(err)},
        ),
    };
    const ctx = Ctx{ .gpa = gpa, .diag = diag, .arena = arena };
    var depth: usize = 0;
    return parseStructuralTagValue(&ctx, &value, &depth);
}

fn parseStructuralTagValue(ctx: *const Ctx, value: *const std.json.Value, depth: *usize) StructuralTagError!Format {
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
    const format_val = obj.get("format") orelse {
        return ctx.invalid("Structural tag must have a format field");
    };
    return parseFormat(ctx, &format_val, depth);
}

fn parseFormat(ctx: *const Ctx, value: *const std.json.Value, depth: *usize) StructuralTagError!Format {
    depth.* += 1;
    defer depth.* -= 1;
    if (depth.* > MAX_FORMAT_DEPTH) {
        return ctx.invalidFmt("Formats are nested deeper than {d} levels", .{MAX_FORMAT_DEPTH});
    }
    return parseFormatObject(ctx, value, depth);
}

fn parseFormatObject(ctx: *const Ctx, value: *const std.json.Value, depth: *usize) StructuralTagError!Format {
    if (value.* != .object) {
        return ctx.invalid("Format must be an object");
    }
    const obj = &value.object;
    if (obj.get("type")) |ty_value| {
        const ty: []const u8 = switch (ty_value) {
            .string => |s| s,
            else => return ctx.invalid("Format's type must be a string"),
        };
        if (std.mem.eql(u8, ty, "const_string")) return .{ .const_string = try parseConstString(ctx, obj) };
        if (std.mem.eql(u8, ty, "json_schema")) return .{ .json_schema = try parseJsonSchema(ctx, obj, null) };
        if (std.mem.eql(u8, ty, "any_text")) return .{ .any_text = try parseAnyText(ctx, obj) };
        if (std.mem.eql(u8, ty, "sequence")) return .{ .sequence = try parseSequence(ctx, obj, depth) };
        if (std.mem.eql(u8, ty, "or")) return .{ .or_fmt = try parseOr(ctx, obj, depth) };
        if (std.mem.eql(u8, ty, "tag")) return .{ .tag = try parseTag(ctx, obj, depth) };
        if (std.mem.eql(u8, ty, "triggered_tags")) return .{ .triggered_tags = try parseTriggeredTags(ctx, obj, depth) };
        if (std.mem.eql(u8, ty, "tags_with_separator")) return .{ .tags_with_separator = try parseTagsWithSeparator(ctx, obj, depth) };
        if (std.mem.eql(u8, ty, "optional")) {
            return .{ .optional = .{ .content = try boxed(ctx, try parseContent(ctx, obj, "Optional", depth)) } };
        }
        if (std.mem.eql(u8, ty, "plus")) {
            return .{ .plus = .{ .content = try boxed(ctx, try parseContent(ctx, obj, "Plus", depth)) } };
        }
        if (std.mem.eql(u8, ty, "star")) {
            return .{ .star = .{ .content = try boxed(ctx, try parseContent(ctx, obj, "Star", depth)) } };
        }
        if (std.mem.eql(u8, ty, "repeat")) return .{ .repeat = try parseRepeat(ctx, obj, depth) };
        if (std.mem.eql(u8, ty, "qwen_xml_parameter")) {
            return .{ .json_schema = try parseJsonSchema(ctx, obj, "qwen_xml") };
        }
        if (std.mem.eql(u8, ty, "grammar")) return .{ .grammar = try parseGrammar(ctx, obj) };
        if (std.mem.eql(u8, ty, "regex")) return .{ .regex = try parseRegex(ctx, obj) };
        if (std.mem.eql(u8, ty, "token")) return .{ .token = try parseToken(ctx, obj) };
        if (std.mem.eql(u8, ty, "exclude_token")) return .{ .exclude_token = try parseExcludeToken(ctx, obj) };
        if (std.mem.eql(u8, ty, "any_tokens")) return .{ .any_tokens = try parseAnyTokens(ctx, obj) };
        if (std.mem.eql(u8, ty, "token_triggered_tags")) return .{ .token_triggered_tags = try parseTokenTriggeredTags(ctx, obj, depth) };
        if (std.mem.eql(u8, ty, "dispatch")) return .{ .dispatch = try parseDispatch(ctx, obj, depth) };
        if (std.mem.eql(u8, ty, "token_dispatch")) return .{ .token_dispatch = try parseTokenDispatch(ctx, obj, depth) };
        return ctx.invalidFmt("Format type not recognized: {s}", .{ty});
    }

    // No type: try each format in priority order (tag first) without touching caller `diag`
    // during speculative probes, while always propagating OutOfMemory.
    const probe_ctx = ctx.withoutDiag();
    if (parseTag(&probe_ctx, obj, depth)) |f| {
        return .{ .tag = f };
    } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
    if (parseConstString(&probe_ctx, obj)) |f| {
        return .{ .const_string = f };
    } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
    if (parseJsonSchema(&probe_ctx, obj, null)) |f| {
        return .{ .json_schema = f };
    } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
    if (parseAnyText(&probe_ctx, obj)) |f| {
        return .{ .any_text = f };
    } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
    if (parseSequence(&probe_ctx, obj, depth)) |f| {
        return .{ .sequence = f };
    } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
    if (parseOr(&probe_ctx, obj, depth)) |f| {
        return .{ .or_fmt = f };
    } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
    if (parseTriggeredTags(&probe_ctx, obj, depth)) |f| {
        return .{ .triggered_tags = f };
    } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
    if (parseTagsWithSeparator(&probe_ctx, obj, depth)) |f| {
        return .{ .tags_with_separator = f };
    } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
    if (parseContent(&probe_ctx, obj, "Optional", depth)) |content| {
        return .{ .optional = .{ .content = try boxed(ctx, content) } };
    } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
    if (parseRepeat(&probe_ctx, obj, depth)) |f| {
        return .{ .repeat = f };
    } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
    if (parseDispatch(&probe_ctx, obj, depth)) |f| {
        return .{ .dispatch = f };
    } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;
    if (parseTokenDispatch(&probe_ctx, obj, depth)) |f| {
        return .{ .token_dispatch = f };
    } else |err| if (err == error.OutOfMemory) return error.OutOfMemory;

    const printed = try serializeJsonSorted(ctx.gpa, value.*);
    defer ctx.gpa.free(printed);
    return ctx.invalidFmt("Invalid format: {s}", .{printed});
}

fn boxed(ctx: *const Ctx, fmt: Format) Allocator.Error!*Format {
    const out = try ctx.arena.create(Format);
    out.* = fmt;
    return out;
}

fn parseConstString(ctx: *const Ctx, obj: *const std.json.ObjectMap) StructuralTagError!ConstStringFormat {
    const value = obj.get("value") orelse return ctx.invalid("ConstString format must have a value field with a string");
    return switch (value) {
        .string => |s| .{ .value = try ctx.arena.dupe(u8, s) },
        else => ctx.invalid("ConstString format must have a value field with a string"),
    };
}

fn parseJsonSchema(
    ctx: *const Ctx,
    obj: *const std.json.ObjectMap,
    style_override: ?[]const u8,
) StructuralTagError!JsonSchemaFormat {
    const js = obj.get("json_schema") orelse {
        return ctx.invalid("JSON schema format must have a json_schema field with a object or boolean value");
    };
    switch (js) {
        .object, .bool => {},
        else => return ctx.invalid("JSON schema format must have a json_schema field with a object or boolean value"),
    }
    var style: []const u8 = "json";
    if (style_override) |s| {
        style = try ctx.arena.dupe(u8, s);
    } else if (obj.get("style")) |style_value| {
        const style_err = "style must be \"json\", \"qwen_xml\", \"minimax_xml\", \"minimax_m3_xml\", \"deepseek_xml\", \"glm_xml\", \"cohere_xml\", \"kimi_k3_xml\", or \"deepseek_v4_1_xml\"";
        switch (style_value) {
            .string => |s| {
                if (JsonFormat.fromName(s) == null) {
                    return ctx.invalid(style_err);
                }
                style = try ctx.arena.dupe(u8, s);
            },
            else => return ctx.invalid(style_err),
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
        max_whitespace_cnt = switch (mw_value) {
            .null => null,
            .integer => |i| blk: {
                if (i < std.math.minInt(i32) or i > std.math.maxInt(i32)) {
                    return ctx.invalid("max_whitespace_cnt must be an integer or null");
                }
                break :blk @intCast(i);
            },
            .float => |f| try parseI32FromFloat(ctx, f, "max_whitespace_cnt must be an integer or null"),
            .number_string => |s| blk: {
                const f = std.fmt.parseFloat(f64, s) catch {
                    return ctx.invalid("max_whitespace_cnt must be an integer or null");
                };
                break :blk try parseI32FromFloat(ctx, f, "max_whitespace_cnt must be an integer or null");
            },
            else => return ctx.invalid("max_whitespace_cnt must be an integer or null"),
        };
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
                    try excludes.append(ctx.arena, try ctx.arena.dupe(u8, s));
                },
                else => return ctx.invalid("JSONSchema format's excludes must be an array of non-empty strings"),
            }
        }
        std.mem.sort([]const u8, excludes.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);
        dedupStrList(&excludes);
    }
    return .{
        .json_schema = try serializeJsonSorted(ctx.arena, js),
        .style = style,
        .any_order = any_order,
        .max_whitespace_cnt = max_whitespace_cnt,
        .excludes = excludes.items,
    };
}

fn dedupStrList(list: *std.ArrayList([]const u8)) void {
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

fn parseI32FromFloat(ctx: *const Ctx, f: f64, msg: []const u8) StructuralTagError!i32 {
    const min_i32: f64 = @floatFromInt(std.math.minInt(i32));
    const max_i32: f64 = @floatFromInt(std.math.maxInt(i32));
    if (!std.math.isFinite(f) or f != @trunc(f) or f < min_i32 or f > max_i32) {
        return ctx.invalid(msg);
    }
    return @intFromFloat(f);
}

/// An optional non-negative int32 budget field; absent or null means no budget.
fn parseOptionalBudget(
    ctx: *const Ctx,
    obj: *const std.json.ObjectMap,
    field_name: []const u8,
    format_name: []const u8,
) StructuralTagError!?i32 {
    const value = obj.get(field_name) orelse return null;
    const max_i32: f64 = @floatFromInt(std.math.maxInt(i32));
    switch (value) {
        .null => return null,
        .integer => |i| {
            if (i < 0 or i > std.math.maxInt(i32)) {
                return ctx.invalidFmt("{s} in {s} must be a non-negative 32-bit integer or null", .{ field_name, format_name });
            }
            return @intCast(i);
        },
        .float => |f| {
            if (std.math.isFinite(f) and f >= 0.0 and f <= max_i32 and f == @trunc(f)) {
                return @intFromFloat(f);
            }
            return ctx.invalidFmt("{s} in {s} must be a non-negative 32-bit integer or null", .{ field_name, format_name });
        },
        else => return ctx.invalidFmt("{s} in {s} must be a non-negative 32-bit integer or null", .{ field_name, format_name }),
    }
}

fn parseAnyText(ctx: *const Ctx, obj: *const std.json.ObjectMap) StructuralTagError!AnyTextFormat {
    const max_tokens = try parseOptionalBudget(ctx, obj, "max_tokens", "any_text");
    const max_chars = try parseOptionalBudget(ctx, obj, "max_chars", "any_text");
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
            .string => |s| try out.append(ctx.arena, try ctx.arena.dupe(u8, s)),
            else => return ctx.invalid("AnyText format's excluded_strs array must contain strings"),
        }
    }
    return .{ .excludes = out, .max_tokens = max_tokens, .max_chars = max_chars };
}

fn parseGrammar(ctx: *const Ctx, obj: *const std.json.ObjectMap) StructuralTagError!GrammarFormat {
    const value = obj.get("grammar") orelse return ctx.invalid("Grammar format must have a grammar field with a non-empty string");
    return switch (value) {
        .string => |s| {
            if (s.len == 0) return ctx.invalid("Grammar format must have a grammar field with a non-empty string");
            return .{ .grammar = try ctx.arena.dupe(u8, s) };
        },
        else => ctx.invalid("Grammar format must have a grammar field with a non-empty string"),
    };
}

fn parseRegex(ctx: *const Ctx, obj: *const std.json.ObjectMap) StructuralTagError!RegexFormat {
    const value = obj.get("pattern") orelse return ctx.invalid("Regex format must have a pattern field with a non-empty string");
    return switch (value) {
        .string => |s| {
            if (s.len == 0) return ctx.invalid("Regex format must have a pattern field with a non-empty string");
            return .{ .pattern = try ctx.arena.dupe(u8, s) };
        },
        else => ctx.invalid("Regex format must have a pattern field with a non-empty string"),
    };
}

fn parseElements(ctx: *const Ctx, obj: *const std.json.ObjectMap, kind: []const u8, depth: *usize) StructuralTagError!std.ArrayList(Format) {
    const elements = obj.get("elements") orelse {
        return ctx.invalidFmt("{s} format must have an elements field with an array", .{kind});
    };
    if (elements != .array) {
        return ctx.invalidFmt("{s} format must have an elements field with an array", .{kind});
    }
    var out: std.ArrayList(Format) = .empty;
    for (elements.array.items) |*item| {
        try out.append(ctx.arena, try parseFormat(ctx, item, depth));
    }
    if (out.items.len == 0) {
        return ctx.invalidFmt("{s} format must have at least one element", .{kind});
    }
    return out;
}

fn parseSequence(ctx: *const Ctx, obj: *const std.json.ObjectMap, depth: *usize) StructuralTagError!SequenceFormat {
    return .{ .elements = try parseElements(ctx, obj, "Sequence", depth), .is_unlimited = false };
}

fn parseOr(ctx: *const Ctx, obj: *const std.json.ObjectMap, depth: *usize) StructuralTagError!OrFormat {
    return .{ .elements = try parseElements(ctx, obj, "Or", depth), .is_unlimited = false };
}

fn parseContent(ctx: *const Ctx, obj: *const std.json.ObjectMap, kind: []const u8, depth: *usize) StructuralTagError!Format {
    const content = obj.get("content") orelse {
        return ctx.invalidFmt("{s} format must have a content field", .{kind});
    };
    return parseFormat(ctx, &content, depth);
}

fn parseTagValue(ctx: *const Ctx, value: *const std.json.Value, depth: *usize) StructuralTagError!TagFormat {
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
    return parseTag(ctx, obj, depth);
}

fn parseTag(ctx: *const Ctx, obj: *const std.json.ObjectMap, depth: *usize) StructuralTagError!TagFormat {
    const begin_val = obj.get("begin") orelse {
        return ctx.invalid("Tag format's begin field must be a string");
    };
    const begin: TagBegin = switch (begin_val) {
        .string => |s| .{ .str = try ctx.arena.dupe(u8, s) },
        .object => |*o| .{ .token = try parseToken(ctx, o) },
        else => return ctx.invalid("Tag format's begin field must be a string"),
    };

    const content = obj.get("content") orelse {
        return ctx.invalid("Tag format must have a content field");
    };
    const content_format = try parseFormat(ctx, &content, depth);

    const end_val = obj.get("end") orelse {
        return ctx.invalid("Tag format must have an end field");
    };
    const end: TagEnd = switch (end_val) {
        .string => |s| blk: {
            var strings: std.ArrayList([]const u8) = .empty;
            try strings.append(ctx.arena, try ctx.arena.dupe(u8, s));
            break :blk .{ .strings = strings };
        },
        .array => |arr| blk: {
            if (arr.items.len == 0) {
                return ctx.invalid("Tag format's end array cannot be empty");
            }
            var strings: std.ArrayList([]const u8) = .empty;
            for (arr.items) |item| {
                switch (item) {
                    .string => |s| try strings.append(ctx.arena, try ctx.arena.dupe(u8, s)),
                    else => return ctx.invalid("Tag format's end array must contain only strings"),
                }
            }
            break :blk .{ .strings = strings };
        },
        .object => |o| .{ .token = try parseToken(ctx, &o) },
        else => return ctx.invalid("Tag format's end field must be a string or array of strings"),
    };

    return .{
        .begin = begin,
        .content = try boxed(ctx, content_format),
        .end = end,
    };
}

fn parseBoolField(ctx: *const Ctx, obj: *const std.json.ObjectMap, key: []const u8) StructuralTagError!bool {
    const value = obj.get(key) orelse return false;
    return switch (value) {
        .bool => |b| b,
        else => ctx.invalidFmt("{s} must be a boolean", .{key}),
    };
}

fn parseTags(
    ctx: *const Ctx,
    obj: *const std.json.ObjectMap,
    missing_msg: []const u8,
    empty_msg: []const u8,
    depth: *usize,
) StructuralTagError!std.ArrayList(TagFormat) {
    const tags = obj.get("tags") orelse return ctx.invalid(missing_msg);
    if (tags != .array) return ctx.invalid(missing_msg);
    var out: std.ArrayList(TagFormat) = .empty;
    for (tags.array.items) |*item| {
        try out.append(ctx.arena, try parseTagValue(ctx, item, depth));
    }
    if (out.items.len == 0) {
        return ctx.invalid(empty_msg);
    }
    return out;
}

fn parseTriggeredTags(ctx: *const Ctx, obj: *const std.json.ObjectMap, depth: *usize) StructuralTagError!TriggeredTagsFormat {
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
                try triggers.append(ctx.arena, try ctx.arena.dupe(u8, s));
            },
            else => return ctx.invalid("Triggered tags format's triggers must be non-empty strings"),
        }
    }
    if (triggers.items.len == 0) {
        return ctx.invalid("Triggered tags format's triggers must be non-empty");
    }
    const tags = try parseTags(
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
                    try excludes.append(ctx.arena, try ctx.arena.dupe(u8, s));
                },
                else => return ctx.invalid("Triggered tags format's excluded_strs must be non-empty strings"),
            }
        }
    }
    return .{
        .triggers = triggers,
        .tags = tags,
        .excludes = excludes,
        .at_least_one = try parseBoolField(ctx, obj, "at_least_one"),
        .stop_after_first = try parseBoolField(ctx, obj, "stop_after_first"),
    };
}

fn parseTagsWithSeparator(ctx: *const Ctx, obj: *const std.json.ObjectMap, depth: *usize) StructuralTagError!TagsWithSeparatorFormat {
    const tags = try parseTags(
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
        .separator = try ctx.arena.dupe(u8, separator),
        .at_least_one = try parseBoolField(ctx, obj, "at_least_one"),
        .stop_after_first = try parseBoolField(ctx, obj, "stop_after_first"),
    };
}

fn parseToken(ctx: *const Ctx, obj: *const std.json.ObjectMap) StructuralTagError!TokenFormat {
    const token = obj.get("token") orelse return ctx.invalid("TokenFormat must have a token field");
    switch (token) {
        .string => |s| {
            if (s.len == 0) {
                return ctx.invalid("Token string must be non-empty");
            }
            return TokenFormat.init(.{ .str = try ctx.arena.dupe(u8, s) });
        },
        .integer => |i| {
            if (i < 0) return ctx.invalid("Token ID must be non-negative");
            if (i > std.math.maxInt(i32)) return ctx.invalid("Token ID must be an integer");
            return TokenFormat.init(.{ .int = @intCast(i) });
        },
        .float => |f| return parseTokenFloat(ctx, f),
        .number_string => |s| {
            const f = std.fmt.parseFloat(f64, s) catch return ctx.invalid("TokenFormat's token must be an integer or string");
            return parseTokenFloat(ctx, f);
        },
        else => return ctx.invalid("TokenFormat's token must be an integer or string"),
    }
}

fn parseTokenFloat(ctx: *const Ctx, d: f64) StructuralTagError!TokenFormat {
    const min_i32: f64 = @floatFromInt(std.math.minInt(i32));
    const max_i32: f64 = @floatFromInt(std.math.maxInt(i32));
    if (!std.math.isFinite(d) or d != @trunc(d) or d < min_i32 or d > max_i32) {
        return ctx.invalid("Token ID must be an integer");
    }
    const id: i32 = @intFromFloat(d);
    if (id < 0) {
        return ctx.invalid("Token ID must be non-negative");
    }
    return TokenFormat.init(.{ .int = id });
}

fn parseNonNegI32FromFloat(ctx: *const Ctx, f: f64, field: []const u8) StructuralTagError!i32 {
    const min_i32: f64 = @floatFromInt(std.math.minInt(i32));
    const max_i32: f64 = @floatFromInt(std.math.maxInt(i32));
    if (!std.math.isFinite(f) or f != @trunc(f) or f < min_i32 or f > max_i32) {
        return ctx.invalidFmt("{s} elements must be integers, not floats", .{field});
    }
    const id: i32 = @intFromFloat(f);
    if (id < 0) {
        return ctx.invalidFmt("{s} elements must be non-negative integers or strings", .{field});
    }
    return id;
}

fn parseIntOrStringArray(ctx: *const Ctx, val: *const std.json.Value, field: []const u8) StructuralTagError!std.ArrayList(IntOrString) {
    if (val.* != .array) {
        return ctx.invalidFmt("{s} must be an array", .{field});
    }
    var out: std.ArrayList(IntOrString) = .empty;
    for (val.array.items) |*item| {
        switch (item.*) {
            .string => |s| {
                if (s.len == 0) {
                    return ctx.invalidFmt("{s} string elements must be non-empty", .{field});
                }
                try out.append(ctx.arena, .{ .str = try ctx.arena.dupe(u8, s) });
            },
            .integer => |i| {
                if (i < 0 or i > std.math.maxInt(i32)) {
                    return ctx.invalidFmt("{s} elements must be non-negative integers or strings", .{field});
                }
                try out.append(ctx.arena, .{ .int = @intCast(i) });
            },
            .float => |f| try out.append(ctx.arena, .{ .int = try parseNonNegI32FromFloat(ctx, f, field) }),
            .number_string => |s| {
                const f = std.fmt.parseFloat(f64, s) catch {
                    return ctx.invalidFmt("{s} elements must be integers or strings", .{field});
                };
                try out.append(ctx.arena, .{ .int = try parseNonNegI32FromFloat(ctx, f, field) });
            },
            else => return ctx.invalidFmt("{s} elements must be integers or strings", .{field}),
        }
    }
    return out;
}

fn parseExcludeToken(ctx: *const Ctx, obj: *const std.json.ObjectMap) StructuralTagError!ExcludeTokenFormat {
    var exclude_tokens: std.ArrayList(IntOrString) = .empty;
    if (obj.get("exclude_tokens")) |v| {
        exclude_tokens = try parseIntOrStringArray(ctx, &v, "exclude_tokens");
    }
    return .{ .exclude_tokens = exclude_tokens };
}

fn parseAnyTokens(ctx: *const Ctx, obj: *const std.json.ObjectMap) StructuralTagError!AnyTokensFormat {
    var exclude_tokens: std.ArrayList(IntOrString) = .empty;
    if (obj.get("exclude_tokens")) |v| {
        exclude_tokens = try parseIntOrStringArray(ctx, &v, "exclude_tokens");
    }
    return .{
        .exclude_tokens = exclude_tokens,
        .max_tokens = try parseOptionalBudget(ctx, obj, "max_tokens", "any_tokens"),
    };
}

fn parseTokenTriggeredTags(
    ctx: *const Ctx,
    obj: *const std.json.ObjectMap,
    depth: *usize,
) StructuralTagError!TokenTriggeredTagsFormat {
    const triggers_val = obj.get("trigger_tokens") orelse {
        return ctx.invalid("TokenTriggeredTagsFormat must have a trigger_tokens field");
    };
    const trigger_tokens = try parseIntOrStringArray(ctx, &triggers_val, "trigger_tokens");
    if (trigger_tokens.items.len == 0) {
        return ctx.invalid("trigger_tokens must be non-empty");
    }
    const tags = try parseTags(
        ctx,
        obj,
        "TokenTriggeredTagsFormat must have a tags field with an array",
        "TokenTriggeredTagsFormat tags must be non-empty",
        depth,
    );
    var exclude_tokens: std.ArrayList(IntOrString) = .empty;
    if (obj.get("exclude_tokens")) |v| {
        exclude_tokens = try parseIntOrStringArray(ctx, &v, "exclude_tokens");
    }
    return .{
        .trigger_tokens = trigger_tokens,
        .tags = tags,
        .exclude_tokens = exclude_tokens,
        .at_least_one = try parseBoolField(ctx, obj, "at_least_one"),
        .stop_after_first = try parseBoolField(ctx, obj, "stop_after_first"),
    };
}

fn parseDispatch(ctx: *const Ctx, obj: *const std.json.ObjectMap, depth: *usize) StructuralTagError!DispatchFormat {
    const rules_arr = obj.get("rules") orelse {
        return ctx.invalid("TagDispatch format must have a rules field with an array");
    };
    if (rules_arr != .array) {
        return ctx.invalid("TagDispatch format must have a rules field with an array");
    }
    if (rules_arr.array.items.len == 0) {
        return ctx.invalid("TagDispatch format rules must be non-empty");
    }
    var rules: std.ArrayList(DispatchFormat.Rule) = .empty;
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
        const content = try parseFormat(ctx, &pair[1], depth);
        try rules.append(ctx.arena, .{
            .trigger = try ctx.arena.dupe(u8, trigger),
            .content = try boxed(ctx, content),
        });
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
                    try excludes.append(ctx.arena, try ctx.arena.dupe(u8, s));
                },
                else => return ctx.invalid("excludes must contain non-empty strings"),
            }
        }
    }
    return .{
        .rules = rules,
        .loop_after_dispatch = try parseBoolField(ctx, obj, "loop"),
        .excludes = excludes,
    };
}

fn parseTokenDispatch(ctx: *const Ctx, obj: *const std.json.ObjectMap, depth: *usize) StructuralTagError!TokenDispatchFormat {
    const rules_arr = obj.get("rules") orelse {
        return ctx.invalid("TokenTagDispatch format must have a rules field with an array");
    };
    if (rules_arr != .array) {
        return ctx.invalid("TokenTagDispatch format must have a rules field with an array");
    }
    if (rules_arr.array.items.len == 0) {
        return ctx.invalid("TokenTagDispatch format rules must be non-empty");
    }
    var rules: std.ArrayList(TokenDispatchFormat.Rule) = .empty;
    for (rules_arr.array.items) |*item| {
        if (item.* != .array) {
            return ctx.invalid("TokenTagDispatch pair must be a 2-element array");
        }
        const pair = item.array.items;
        if (pair.len != 2) {
            return ctx.invalid("TokenTagDispatch pair must be a 2-element array");
        }
        const trigger: IntOrString = switch (pair[0]) {
            .string => |s| .{ .str = try ctx.arena.dupe(u8, s) },
            .integer => |i| blk: {
                if (i < 0 or i > std.math.maxInt(i32)) {
                    return ctx.invalid("Token ID must be an integer");
                }
                break :blk .{ .int = @intCast(i) };
            },
            .float => |f| blk: {
                const id = parseI32FromFloat(ctx, f, "Token ID must be an integer") catch {
                    return ctx.invalid("Token ID must be an integer");
                };
                if (id < 0) return ctx.invalid("Token ID must be an integer");
                break :blk .{ .int = id };
            },
            .number_string => |s| blk: {
                const f = std.fmt.parseFloat(f64, s) catch {
                    return ctx.invalid("TokenTagDispatch pair first element must be an integer or string");
                };
                const id = parseI32FromFloat(ctx, f, "Token ID must be an integer") catch {
                    return ctx.invalid("Token ID must be an integer");
                };
                if (id < 0) return ctx.invalid("Token ID must be an integer");
                break :blk .{ .int = id };
            },
            else => return ctx.invalid("TokenTagDispatch pair first element must be an integer or string"),
        };
        const content = try parseFormat(ctx, &pair[1], depth);
        try rules.append(ctx.arena, .{
            .trigger = trigger,
            .content = try boxed(ctx, content),
        });
    }
    var exclude_tokens: std.ArrayList(IntOrString) = .empty;
    if (obj.get("exclude_tokens")) |v| {
        exclude_tokens = try parseIntOrStringArray(ctx, &v, "exclude_tokens");
    }
    return .{
        .rules = rules,
        .loop_after_dispatch = try parseBoolField(ctx, obj, "loop"),
        .exclude_tokens = exclude_tokens,
    };
}

fn saturateF64ToI64(f: f64) i64 {
    // 2^63 is exactly representable in f64; any value >= 2^63 exceeds maxInt(i64).
    const i64_upper: f64 = 9223372036854775808.0;
    const i64_lower: f64 = -9223372036854775808.0;
    if (f >= i64_upper) return std.math.maxInt(i64);
    if (f <= i64_lower) return std.math.minInt(i64);
    return @intFromFloat(f);
}

fn parseRepeat(ctx: *const Ctx, obj: *const std.json.ObjectMap, depth: *usize) StructuralTagError!RepeatFormat {
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
    if (std.math.isNan(min_f)) {
        return ctx.invalid("Repeat format must have a min field (number)");
    }
    if (std.math.isNan(max_f)) {
        return ctx.invalid("Repeat format must have a max field (number)");
    }
    const min_i = saturateF64ToI64(min_f);
    var max_i = saturateF64ToI64(max_f);
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
        return ctx.invalidFmt("Repeat min is too large, must be <= {d}", .{std.math.maxInt(i32)});
    }
    const content = try parseContent(ctx, obj, "Repeat", depth);
    return .{
        .min = @intCast(min_i),
        .max = @intCast(max_i),
        .content = try boxed(ctx, content),
    };
}

test "parseStructuralTag arena lifetime, sorted schema keys, untyped fallback, and reusable Diagnostic" {
    const a = std.testing.allocator;

    // 1. Valid typed + untyped + json_schema key sorting + excludes dedup.
    const doc =
        \\{"type":"structural_tag","format":{"type":"sequence","elements":[{"begin":"<a>","content":{"type":"json_schema","json_schema":{"z":1,"a":2},"excludes":["x","a","x"]},"end":"</a>"},{"value":"ok"}]}}
    ;
    var parsed = try parseStructuralTag(a, doc, null);
    defer parsed.deinit();

    try std.testing.expect(parsed.root == .sequence);
    const elems = parsed.root.sequence.elements.items;
    try std.testing.expectEqual(@as(usize, 2), elems.len);
    try std.testing.expect(elems[0] == .tag);
    try std.testing.expect(elems[0].tag.content.* == .json_schema);
    const js = elems[0].tag.content.json_schema;
    try std.testing.expectEqualStrings("{\"a\":2,\"z\":1}", js.json_schema);
    try std.testing.expectEqual(@as(usize, 2), js.excludes.len);
    try std.testing.expectEqualStrings("a", js.excludes[0]);
    try std.testing.expectEqualStrings("x", js.excludes[1]);
    try std.testing.expect(elems[1] == .const_string);
    try std.testing.expectEqualStrings("ok", elems[1].const_string.value);

    // 2. Reusable Diagnostic across InvalidJson, InvalidStructuralTag, and valid parse (0 leaks).
    var diag: Diagnostic = .{};
    defer diag.deinit(a);

    try std.testing.expectError(error.InvalidJson, parseStructuralTag(a, "{not json", &diag));
    try std.testing.expectEqual(Diagnostic.Kind.structural_tag_invalid_json, diag.kind);
    const json_err = try diag.formatAlloc(a);
    defer a.free(json_err);
    try std.testing.expect(std.mem.startsWith(u8, json_err, "Invalid JSON error: Failed to parse JSON: "));

    try std.testing.expectError(error.InvalidStructuralTag, parseStructuralTag(a, "{\"format\":{\"type\":\"bogus\"}}", &diag));
    try std.testing.expectEqual(Diagnostic.Kind.structural_tag_invalid, diag.kind);
    const tag_err = try diag.formatAlloc(a);
    defer a.free(tag_err);
    try std.testing.expectEqualStrings("Invalid structural tag error: Format type not recognized: bogus", tag_err);

    // Untyped empty object fails cleanly without touching static/owned state incorrectly.
    try std.testing.expectError(error.InvalidStructuralTag, parseStructuralTag(a, "{\"format\":{}}", &diag));
    const empty_err = try diag.formatAlloc(a);
    defer a.free(empty_err);
    try std.testing.expectEqualStrings("Invalid structural tag error: Invalid format: {}", empty_err);

    // Extreme float token id must fail cleanly instead of panicking on @intFromFloat.
    try std.testing.expectError(
        error.InvalidStructuralTag,
        parseStructuralTag(a, "{\"format\":{\"type\":\"token\",\"token\":1e30}}", &diag),
    );
    try std.testing.expectError(
        error.InvalidStructuralTag,
        parseStructuralTag(a, "{\"format\":{\"type\":\"any_tokens\",\"exclude_tokens\":[1e30]}}", &diag),
    );
    try std.testing.expectError(
        error.InvalidStructuralTag,
        parseStructuralTag(a, "{\"format\":{\"type\":\"token_dispatch\",\"rules\":[[1e30,{\"type\":\"const_string\",\"value\":\"a\"}]]}}", &diag),
    );
    // Repeat with huge max saturates to unbounded (-1) cleanly.
    var parsed_rep = try parseStructuralTag(a, "{\"format\":{\"type\":\"repeat\",\"min\":1,\"max\":1e30,\"content\":{\"type\":\"const_string\",\"value\":\"a\"}}}", &diag);
    defer parsed_rep.deinit();
    try std.testing.expectEqual(@as(i32, -1), parsed_rep.root.repeat.max);

    // Owned diagnostic overwritten by static diagnostic frees prior buffer cleanly.
    try std.testing.expectError(
        error.InvalidStructuralTag,
        parseStructuralTag(a, "{\"format\":{\"type\":123}}", &diag),
    );
    try std.testing.expectEqualStrings("Format's type must be a string", diag.message);

    // Depth exceeding MAX_FORMAT_DEPTH fails cleanly without stack overflow.
    var deep_json: std.ArrayList(u8) = .empty;
    defer deep_json.deinit(a);
    try deep_json.appendSlice(a, "{\"format\":");
    for (0..MAX_FORMAT_DEPTH + 1) |_| try deep_json.appendSlice(a, "{\"type\":\"optional\",\"content\":");
    try deep_json.appendSlice(a, "{\"type\":\"const_string\",\"value\":\"x\"}");
    for (0..MAX_FORMAT_DEPTH + 1) |_| try deep_json.append(a, '}');
    try deep_json.append(a, '}');
    try std.testing.expectError(error.InvalidStructuralTag, parseStructuralTag(a, deep_json.items, &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "nested deeper than") != null);

    // 3. OOM failure path does not leak any arena or diagnostic memory.
    try std.testing.checkAllAllocationFailures(a, struct {
        fn run(alloc: Allocator, input: []const u8) !void {
            var d: Diagnostic = .{};
            defer d.deinit(alloc);
            var p = parseStructuralTag(alloc, input, &d) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return,
            };
            p.deinit();
        }
    }.run, .{doc});
}
