//! JSON serialization for `Grammar` (`serialization.rs`).
//!
//! The on-disk format uses the `"v16"` layout: rules as
//! `[name, body_expr_id, lookahead_assertion_id, is_exact_lookahead, max_tokens, max_chars,
//! capture_name, is_lazy, temperature]`, sparse `suffix_stop_infos`, and the expression
//! store as a flat `grammar_expr_data` array of `[type, data_len, data...]` rows indexed by
//! `grammar_expr_indptr` offsets. Strings are Latin-1 encoded byte strings, as in the C++.

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_mod = @import("grammar.zig");
const Grammar = grammar_mod.Grammar;
const dupe_rule = grammar_mod.dupe_rule;
const dupe_suffix_stop_info = grammar_mod.dupe_suffix_stop_info;
const grammar_expr_type = @import("grammar_expr_type.zig");
const GrammarExprType = grammar_expr_type.GrammarExprType;
const rule_mod = @import("rule.zig");
const Rule = rule_mod.Rule;
const suffix_stop_info_mod = @import("suffix_stop_info.zig");
const SuffixStopInfo = suffix_stop_info_mod.SuffixStopInfo;
const tag_dispatch_mod = @import("tag_dispatch.zig");
const error_mod = @import("error.zig");
const DeserializeError = error_mod.DeserializeError;
const DeserializeErrorInfo = error_mod.DeserializeErrorInfo;
const support = @import("../support/mod.zig");
const Compact2dArray = support.Compact2dArray;
const config = @import("../config.zig");
const fsm_mod = @import("../fsm/mod.zig");
const CompactFsm = fsm_mod.CompactFsm;
const CompactFsmWithStartEnd = fsm_mod.CompactFsmWithStartEnd;
const CompactFsmWithStartEndWithSize = fsm_mod.CompactFsmWithStartEndWithSize;
const fsm_ser = fsm_mod.serialization;

/// Errors of the serialize path.
pub const SerializeError = Allocator.Error;

/// Errors of the deserialize path.
pub const DeserializeErrorAll = DeserializeError || support.Compact2dArrayError || Allocator.Error;

/// Serializes the grammar to its `"v16"` JSON form (FSMs are `null`/`[]` until optimized).
/// The returned slice is allocated from `allocator`.
pub fn serialize_json(grammar: *const Grammar, allocator: Allocator) SerializeError![]u8 {
    const value = try serialize_json_value(grammar, allocator);
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

/// Serializes the grammar to a JSON value.
pub fn serialize_json_value(grammar: *const Grammar, allocator: Allocator) SerializeError!Value {
    // serde_json's Map is a BTreeMap: keys serialize in lexicographic order, and
    // "__VERSION__" ('_' < lowercase letters) sorts before every body key
    // (契约对拍陷阱 1: std.json ObjectMap 是插入序,必须按字典序插入).
    var value = try serialize_json_value_embedded(grammar, allocator);
    var out = std.json.ObjectMap.empty;
    try out.put(allocator, "__VERSION__", .{ .string = config.SERIALIZATION_VERSION });
    var it = value.object.iterator();
    while (it.next()) |entry|
        try out.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
    return .{ .object = out };
}

/// Serializes the grammar nested inside a compiled grammar (no `__VERSION__` field).
pub fn serialize_json_value_embedded(grammar: *const Grammar, allocator: Allocator) SerializeError!Value {
    // Re-encode the expression store into the C++ flat layout: each row is
    // `[type, data_len, data...]`, indexed by cumulative offsets.
    var indptr = std.json.Array.init(allocator);
    var data = std.json.Array.init(allocator);
    for (0..@intCast(grammar.num_exprs())) |expr_id| {
        try indptr.append(.{ .integer = @intCast(data.items.len) });
        const row = grammar.exprs.row(expr_id);
        try data.append(.{ .integer = row[0] });
        try data.append(.{ .integer = @intCast(row.len - 1) });
        for (row[1..]) |v| try data.append(.{ .integer = v });
    }

    var rules = std.json.Array.init(allocator);
    for (grammar.rules.items) |rule| {
        var entry = std.json.Array.init(allocator);
        try entry.append(try byte_to_latin1_value(allocator, rule.name));
        try entry.append(.{ .integer = rule.body_expr_id });
        try entry.append(.{ .integer = rule.lookahead_assertion_id });
        try entry.append(.{ .bool = rule.is_exact_lookahead });
        try entry.append(.{ .integer = rule.max_tokens });
        try entry.append(.{ .integer = rule.max_chars });
        try entry.append(try byte_to_latin1_value(allocator, rule.capture_name));
        try entry.append(.{ .bool = rule.is_lazy });
        try entry.append(if (rule.temperature) |t| Value{ .float = @floatCast(t) } else .null);
        try rules.append(.{ .array = entry });
    }

    var suffix_stop_infos = std.json.Array.init(allocator);
    for (grammar.suffix_stop_infos.items) |info| {
        var entry = std.json.Array.init(allocator);
        try entry.append(.{ .integer = info.rule_id });
        try entry.append(.{ .integer = info.hidden_suffix_bytes });
        try entry.append(.{ .integer = info.hidden_stop_bytes });
        try entry.append(.{ .integer = info.body_rule_id });
        try entry.append(.{ .integer = info.marker_rule_id });
        try entry.append(try byte_to_latin1_value(allocator, info.stop_capture_name));
        try suffix_stop_infos.append(.{ .array = entry });
    }

    const with_fsm = grammar.is_optimized();
    var complete_fsm_value: Value = .null;
    var per_rule_fsms = std.json.Array.init(allocator);
    if (with_fsm) {
        complete_fsm_value = try fsm_ser.serialize_compact_fsm_json_value(grammar.complete_fsm, allocator);
        for (grammar.per_rule_fsms_slice()) |maybe| {
            if (maybe) |*view|
                try per_rule_fsms.append(try fsm_ser.serialize_compact_fsm_with_start_end_with_size_json_value(view, allocator))
            else
                try per_rule_fsms.append(.null);
        }
    }

    var object = std.json.ObjectMap.empty;
    // Keys inserted in lexicographic order to match serde_json's BTreeMap serialization
    // (契约对拍陷阱 1).
    try object.put(allocator, "allow_empty_rule_ids", try i32_slice_value(allocator, grammar.allow_empty_rule_ids.items));
    try object.put(allocator, "complete_fsm", complete_fsm_value);
    try object.put(allocator, "grammar_expr_data", .{ .array = data });
    try object.put(allocator, "grammar_expr_indptr", .{ .array = indptr });
    try object.put(allocator, "optimized", .{ .bool = grammar.is_optimized() });
    try object.put(allocator, "per_rule_fsms", .{ .array = per_rule_fsms });
    try object.put(allocator, "root_rule_id", .{ .integer = grammar.root_rule_id });
    try object.put(allocator, "rules", .{ .array = rules });
    try object.put(allocator, "suffix_stop_infos", .{ .array = suffix_stop_infos });
    return .{ .object = object };
}

fn byte_to_latin1_value(allocator: Allocator, bytes: []const u8) Allocator.Error!Value {
    const latin1 = try support.byte_to_latin1(allocator, bytes);
    return .{ .string = latin1 };
}

fn i32_slice_value(allocator: Allocator, values: []const i32) Allocator.Error!Value {
    var arr = std.json.Array.init(allocator);
    for (values) |v| try arr.append(.{ .integer = v });
    return .{ .array = arr };
}

/// Deserializes a grammar from its `"v16"` JSON form. Diagnostic payloads are allocated
/// from `backing` (caller owns them); the grammar owns its own arena.
pub fn deserialize_json(
    backing: Allocator,
    json_str: []const u8,
    diag: ?*DeserializeErrorInfo,
) DeserializeErrorAll!*Grammar {
    var temp_arena = std.heap.ArenaAllocator.init(backing);
    defer temp_arena.deinit();
    const value = support.parse_json(temp_arena.allocator(), json_str) catch |e| {
        // Rust embeds the serde error message; the support port exposes a bare error set,
        // so the diagnostic carries the error name.
        if (diag) |d| d.* = .{ .InvalidJson = @errorName(e) };
        return error.InvalidJson;
    };
    return deserialize_json_value_impl(backing, value, true, diag);
}

/// Deserializes a grammar from a JSON value.
pub fn deserialize_json_value(
    backing: Allocator,
    value: Value,
    diag: ?*DeserializeErrorInfo,
) DeserializeErrorAll!*Grammar {
    return deserialize_json_value_impl(backing, value, true, diag);
}

/// Deserializes a grammar nested inside a compiled grammar (no `__VERSION__` field).
pub fn deserialize_json_value_embedded(
    backing: Allocator,
    value: Value,
    diag: ?*DeserializeErrorInfo,
) DeserializeErrorAll!*Grammar {
    return deserialize_json_value_impl(backing, value, false, diag);
}

const Value = std.json.Value;

fn fail_format(
    backing: Allocator,
    diag: ?*DeserializeErrorInfo,
    comptime fmt: []const u8,
    args: anytype,
) DeserializeError {
    if (diag) |d| {
        const message = std.fmt.allocPrint(backing, fmt, args) catch "";
        d.* = .{ .Format = message };
    }
    return error.Format;
}

fn get_field(value: Value, name: []const u8) ?Value {
    return switch (value) {
        .object => |object| object.get(name),
        else => null,
    };
}

fn array_of(value: *const Value) ?*const std.json.Array {
    return switch (value.*) {
        .array => |*arr| arr,
        else => null,
    };
}

fn fixed_array(comptime n: usize, value: *const Value, backing: Allocator, diag: ?*DeserializeErrorInfo, what: []const u8) DeserializeError!?*const std.json.Array {
    const arr = array_of(value) orelse return fail_format(backing, diag, "invalid format: expected array", .{});
    if (arr.items.len != n) return fail_format(backing, diag, "invalid format: {s} arity", .{what});
    return arr;
}

fn i32_of(value: Value, backing: Allocator, diag: ?*DeserializeErrorInfo) DeserializeError!i32 {
    return switch (value) {
        .integer => |v| std.math.cast(i32, v) orelse fail_format(backing, diag, "invalid format: expected integer", .{}),
        else => fail_format(backing, diag, "invalid format: expected integer", .{}),
    };
}

fn bool_of(value: Value, backing: Allocator, diag: ?*DeserializeErrorInfo) DeserializeError!bool {
    return switch (value) {
        .bool => |b| b,
        else => fail_format(backing, diag, "invalid format: expected boolean", .{}),
    };
}

fn string_of(value: Value, temp: Allocator, backing: Allocator, diag: ?*DeserializeErrorInfo) (DeserializeError || Allocator.Error)![]const u8 {
    const latin1 = switch (value) {
        .string => |s| s,
        else => return fail_format(backing, diag, "invalid format: expected string", .{}),
    };
    const bytes = support.latin1_to_bytes(temp, latin1) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail_format(backing, diag, "invalid format: invalid latin-1 string", .{}),
    };
    if (!std.unicode.utf8ValidateSlice(bytes))
        return fail_format(backing, diag, "invalid format: invalid UTF-8 string", .{});
    return bytes;
}

fn i32_array(value: *const Value, temp: Allocator, backing: Allocator, diag: ?*DeserializeErrorInfo) (DeserializeError || Allocator.Error)!std.ArrayList(i32) {
    const arr = array_of(value) orelse return fail_format(backing, diag, "invalid format: expected array", .{});
    var out: std.ArrayList(i32) = .empty;
    errdefer out.deinit(temp);
    try out.ensureTotalCapacity(temp, arr.items.len);
    for (arr.items) |item| out.appendAssumeCapacity(try i32_of(item, backing, diag));
    return out;
}

fn deserialize_json_value_impl(
    backing: Allocator,
    value: Value,
    require_version: bool,
    diag: ?*DeserializeErrorInfo,
) DeserializeErrorAll!*Grammar {
    var temp_arena = std.heap.ArenaAllocator.init(backing);
    defer temp_arena.deinit();
    const temp = temp_arena.allocator();

    if (get_field(value, "__VERSION__")) |version_field| switch (version_field) {
        .string => |s| {
            if (!std.mem.eql(u8, s, config.SERIALIZATION_VERSION)) {
                if (diag) |d| d.* = .{ .Version = .{
                    .expected = config.SERIALIZATION_VERSION,
                    .got = try backing.dupe(u8, s),
                } };
                return error.Version;
            }
        },
        else => {
            if (diag) |d| d.* = .{ .Format = "invalid format: __VERSION__ must be a string" };
            return error.Format;
        },
    } else if (require_version) {
        return fail_format(backing, diag, "invalid format: missing __VERSION__", .{});
    }

    const rules_field = get_field(value, "rules") orelse
        return fail_format(backing, diag, "invalid format: missing rules", .{});
    var rules: std.ArrayList(Rule) = .empty;
    errdefer rules.deinit(temp);
    {
        const arr = array_of(&rules_field) orelse
            return fail_format(backing, diag, "invalid format: expected array", .{});
        try rules.ensureTotalCapacity(temp, arr.items.len);
        for (arr.items) |entry| {
            const fields = (try fixed_array(9, &entry, backing, diag, "rule")) orelse return error.Format;
            const name0 = try string_of(fields.items[0], temp, backing, diag);
            var rule = Rule.new(name0, try i32_of(fields.items[1], backing, diag));
            rule.lookahead_assertion_id = try i32_of(fields.items[2], backing, diag);
            rule.is_exact_lookahead = try bool_of(fields.items[3], backing, diag);
            rule.max_tokens = try i32_of(fields.items[4], backing, diag);
            rule.max_chars = try i32_of(fields.items[5], backing, diag);
            rule.capture_name = try string_of(fields.items[6], temp, backing, diag);
            rule.is_lazy = try bool_of(fields.items[7], backing, diag);
            rule.temperature = switch (fields.items[8]) {
                .null => null,
                .integer => |v| @floatFromInt(v),
                .float => |v| @floatCast(v),
                else => return fail_format(backing, diag, "invalid format: expected number", .{}),
            };
            rules.appendAssumeCapacity(rule);
        }
    }

    const infos_field = get_field(value, "suffix_stop_infos") orelse
        return fail_format(backing, diag, "invalid format: missing suffix_stop_infos", .{});
    var suffix_stop_infos: std.ArrayList(SuffixStopInfo) = .empty;
    errdefer suffix_stop_infos.deinit(temp);
    {
        const arr = array_of(&infos_field) orelse
            return fail_format(backing, diag, "invalid format: expected array", .{});
        try suffix_stop_infos.ensureTotalCapacity(temp, arr.items.len);
        for (arr.items) |entry| {
            const fields = (try fixed_array(6, &entry, backing, diag, "suffix_stop_info")) orelse return error.Format;
            var info = SuffixStopInfo.default();
            info.rule_id = try i32_of(fields.items[0], backing, diag);
            info.hidden_suffix_bytes = try i32_of(fields.items[1], backing, diag);
            info.hidden_stop_bytes = try i32_of(fields.items[2], backing, diag);
            info.body_rule_id = try i32_of(fields.items[3], backing, diag);
            info.marker_rule_id = try i32_of(fields.items[4], backing, diag);
            info.stop_capture_name = try string_of(fields.items[5], temp, backing, diag);
            suffix_stop_infos.appendAssumeCapacity(info);
        }
    }
    if (suffix_stop_infos.items.len >= 2) {
        for (suffix_stop_infos.items[1..], 0..) |info, i| {
            if (!(suffix_stop_infos.items[i].rule_id < info.rule_id))
                return fail_format(backing, diag, "invalid format: suffix_stop_infos must be sorted by rule id", .{});
        }
    }

    const data_field = get_field(value, "grammar_expr_data") orelse
        return fail_format(backing, diag, "invalid format: missing grammar_expr_data", .{});
    const data = try i32_array(&data_field, temp, backing, diag);
    const indptr_field = get_field(value, "grammar_expr_indptr") orelse
        return fail_format(backing, diag, "invalid format: missing grammar_expr_indptr", .{});
    const indptr = try i32_array(&indptr_field, temp, backing, diag);
    var exprs = try Compact2dArray(i32).init(temp);
    errdefer exprs.deinit();
    for (indptr.items, 0..) |start_value, expr_id| {
        const start = std.math.cast(usize, start_value) orelse
            return fail_format(backing, diag, "invalid format: grammar_expr_indptr[{d}] is out of range", .{expr_id});
        if (!(start + 2 <= data.items.len))
            return fail_format(backing, diag, "invalid format: grammar_expr_indptr[{d}] is out of range", .{expr_id});
        const ty = data.items[start];
        const len_value = data.items[start + 1];
        const len = std.math.cast(usize, len_value) orelse
            return fail_format(backing, diag, "invalid format: The length of grammar expr {d} is out of range", .{expr_id});
        const end = start + 2 + len;
        if (!(end <= data.items.len))
            return fail_format(backing, diag, "invalid format: The length of grammar expr {d} is out of range", .{expr_id});
        _ = grammar_expr_type.try_from(ty) catch
            return fail_format(backing, diag, "invalid format: Unknown type of grammar expr {d}", .{expr_id});
        // Drop the C++ `data_len` header element; keep `[type, data...]`.
        _ = try exprs.push_row_noncontiguous(ty, data.items[start + 2 .. end]);
    }

    const root_rule_id = try i32_of(get_field(value, "root_rule_id") orelse
        return fail_format(backing, diag, "invalid format: missing root_rule_id", .{}), backing, diag);
    const allow_empty_field = get_field(value, "allow_empty_rule_ids") orelse
        return fail_format(backing, diag, "invalid format: missing allow_empty_rule_ids", .{});
    const allow_empty = try i32_array(&allow_empty_field, temp, backing, diag);
    const optimized = try bool_of(get_field(value, "optimized") orelse
        return fail_format(backing, diag, "invalid format: missing optimized", .{}), backing, diag);

    const grammar = try Grammar.from_parts(backing, rules.items, &exprs, root_rule_id);
    errdefer grammar.deinit();
    try grammar.set_suffix_stop_infos(suffix_stop_infos.items);
    try grammar.set_allow_empty_rule_ids(allow_empty.items);

    const complete_fsm = get_field(value, "complete_fsm") orelse
        return fail_format(backing, diag, "invalid format: missing complete_fsm", .{});
    const complete_fsm_is_null = complete_fsm == .null;
    const per_rule_json_field = get_field(value, "per_rule_fsms") orelse
        return fail_format(backing, diag, "invalid format: missing per_rule_fsms", .{});
    const per_rule_json = array_of(&per_rule_json_field) orelse
        return fail_format(backing, diag, "invalid format: expected array", .{});
    if (!complete_fsm_is_null or per_rule_json.items.len != 0) {
        // Generated views share the complete FSM; independently serialized rule graphs stay
        // distinct (reference serialization.rs lines 219–232). FSM storage lives in the
        // grammar's arena so it dies with the grammar (refcounts stay correct).
        const galloc = grammar.arena.allocator();
        var complete = if (complete_fsm_is_null)
            try CompactFsm.empty(galloc)
        else
            try fsm_ser.deserialize_compact_fsm_json_value(galloc, complete_fsm);
        var per_rule: std.ArrayList(?CompactFsmWithStartEndWithSize) = .empty;
        var installed = false;
        // On any failure the still-unowned handles are released here (arena frees are
        // individually no-ops, so releasing only the caller-side refs is always safe).
        defer if (!installed) {
            complete.deinit();
            for (per_rule.items) |*maybe| {
                if (maybe.*) |*view| view.deinit();
            }
            per_rule.deinit(galloc);
        };
        for (per_rule_json.items) |entry| {
            if (entry == .null) {
                try per_rule.append(galloc, null);
                continue;
            }
            var view = try fsm_ser.deserialize_compact_fsm_with_start_end_with_size_json_value(galloc, entry);
            var moved = false;
            defer if (!moved) view.deinit();
            const view_fsm = view.get_fsm();
            if (!view_fsm.get_fsm().eql(complete)) {
                try per_rule.append(galloc, view);
                moved = true;
                continue;
            }
            // Rebuild the view over the complete FSM's storage (shared-handle clone).
            var ends: std.ArrayList(i32) = .empty;
            try ends.appendSlice(galloc, view_fsm.get_ends());
            const shared = try CompactFsmWithStartEnd.new(
                galloc,
                complete.clone(),
                view_fsm.get_start(),
                ends,
                view_fsm.get_is_dfa(),
            );
            const rebuilt = CompactFsmWithStartEndWithSize.new(shared, view.get_edge_num(), view.get_node_num());
            view.deinit();
            moved = true;
            try per_rule.append(galloc, rebuilt);
        }
        try grammar.set_fsms(complete, per_rule.items);
        installed = true;
        // The grammar retained its own references; drop the caller-side ones
        // (`per_rule.deinit` frees the buffer only, the loop releases the handles).
        complete.deinit();
        for (per_rule.items) |*maybe| {
            if (maybe.*) |*view| view.deinit();
        }
        per_rule.deinit(galloc);
    }
    grammar.set_optimized(optimized);
    try validate(grammar, backing, diag, !complete_fsm_is_null);
    return grammar;
}

/// Checks that every id stored in the grammar is in range. Used after deserialization,
/// where the fields are restored verbatim and none of the builder checks run.
fn validate(
    grammar: *const Grammar,
    backing: Allocator,
    diag: ?*DeserializeErrorInfo,
    has_complete_fsm: bool,
) DeserializeError!void {
    const num_rules = grammar.num_rules();
    const num_exprs = grammar.num_exprs();

    const rule_ok = struct {
        fn check(id: i32, count: i32) bool {
            return id >= 0 and id < count;
        }
    }.check;
    const expr_ok = rule_ok;

    for (0..@intCast(num_exprs)) |expr_index| {
        const expr_id: i32 = @intCast(expr_index);
        const expr = grammar.expr(expr_id);
        const data = expr.data;
        const size = data.len;
        const ok = switch (expr.ty) {
            .ByteString, .EmptyStr, .Token, .ExcludeToken => true,
            .CharacterClass, .CharacterClassStar => size % 2 == 1,
            .RuleRef => size == 1 and rule_ok(data[0], num_rules),
            .Sequence, .Choices => blk: {
                for (data) |id| if (!expr_ok(id, num_exprs)) break :blk false;
                break :blk true;
            },
            .TagDispatch => blk: {
                const extra = tag_dispatch_mod.EXTRA_PARAMETERS;
                if (!(size >= extra and (size - extra) % 2 == 0)) break :blk false;
                for (0..(size - extra) / 2) |pair_index| {
                    const pair = data[0..size - extra][pair_index * 2 ..][0..2];
                    if (!(expr_ok(pair[0], num_exprs) and rule_ok(pair[1], num_rules))) break :blk false;
                }
                if (!expr_ok(data[size - 1], num_exprs)) break :blk false;
                break :blk grammar.expr(data[size - 1]).ty == .Choices;
            },
            .Repeat => size == 3 and rule_ok(data[0], num_rules),
            .TokenTagDispatch => blk: {
                const trigger_cnt = std.math.cast(usize, data[0]) orelse break :blk false;
                if (!(1 + 2 * trigger_cnt + 2 <= size)) break :blk false;
                const exclude_value = data[1 + 2 * trigger_cnt + 1];
                const exclude_cnt = std.math.cast(usize, exclude_value) orelse break :blk false;
                for (0..trigger_cnt) |i| {
                    if (!rule_ok(data[2 + 2 * i], num_rules)) break :blk false;
                }
                break :blk 1 + 2 * trigger_cnt + 2 + exclude_cnt == size;
            },
            .Regex => size >= 1,
            .Substring => blk: {
                var index: usize = 0;
                var ok = true;
                while (ok and index < size) {
                    const chunk_len = data[index];
                    index += 1;
                    const len = std.math.cast(usize, chunk_len) orelse {
                        ok = false;
                        // Rust still advances by `chunk_len.max(0) as usize`.
                        continue;
                    };
                    ok = index + len <= size;
                    index += len;
                }
                break :blk ok;
            },
        };
        if (!ok) return fail_format(backing, diag, "invalid format: Grammar expr {d} is malformed", .{expr_id});
    }

    for (grammar.rules.items, 0..) |rule, rule_index| {
        if (!expr_ok(rule.body_expr_id, num_exprs) or
            (rule.lookahead_assertion_id != -1 and !expr_ok(rule.lookahead_assertion_id, num_exprs)))
        {
            return fail_format(backing, diag, "invalid format: Rule {d} refers to a grammar expr out of range", .{rule_index});
        }
    }
    if (!rule_ok(grammar.root_rule_id, num_rules))
        return fail_format(backing, diag, "invalid format: root_rule_id {d} is out of range", .{grammar.root_rule_id});
    for (grammar.suffix_stop_infos.items) |info| {
        if (!rule_ok(info.rule_id, num_rules) or
            (info.body_rule_id != -1 and !rule_ok(info.body_rule_id, num_rules)) or
            (info.marker_rule_id != -1 and !rule_ok(info.marker_rule_id, num_rules)))
        {
            return fail_format(backing, diag, "invalid format: suffix_stop_infos refers to a rule out of range", .{});
        }
    }
    for (grammar.allow_empty_rule_ids.items) |id| {
        if (!rule_ok(id, num_rules))
            return fail_format(backing, diag, "invalid format: allow_empty_rule_ids refers to a rule out of range", .{});
    }

    // The parser reads the repeat info of a per-rule FSM edge from complete_fsm, so the
    // aux indices of per-rule repeat edges must also be valid for complete_fsm
    // (reference serialization.rs lines 334–396).
    const complete_aux = grammar.complete_fsm.edge_aux_data();
    const FsmRulesOk = struct {
        fn check(fsm: CompactFsm, num_rules_count: i32) bool {
            const aux = fsm.edge_aux_data();
            var state: i32 = 0;
            while (state < fsm.num_states()) : (state += 1) {
                for (fsm.state_edges(state)) |edge| {
                    if (edge.is_rule_ref() and !rule_ok(edge.max, num_rules_count)) return false;
                    if (edge.is_repeat_ref()) {
                        const index = std.math.cast(usize, edge.max) orelse return false;
                        if (index >= aux.len or !rule_ok(aux[index], num_rules_count)) return false;
                    }
                }
            }
            return true;
        }
    }.check;
    if (has_complete_fsm and !FsmRulesOk(grammar.complete_fsm, num_rules))
        return fail_format(backing, diag, "invalid format: complete_fsm refers to a rule out of range", .{});
    const per_rule_fsms = grammar.per_rule_fsms_slice();
    if (grammar.is_optimized()) {
        if (!has_complete_fsm or per_rule_fsms.len != @as(usize, @intCast(num_rules)))
            return fail_format(backing, diag, "invalid format: An optimized grammar must have complete_fsm and one FSM per rule", .{});
    }
    for (per_rule_fsms, 0..) |maybe, rule_index| {
        const view = maybe orelse {
            if (grammar.is_optimized())
                return fail_format(backing, diag, "invalid format: Rule {d} has no FSM in an optimized grammar", .{rule_index});
            continue;
        };
        const fsm = view.get_fsm().get_fsm();
        if (!FsmRulesOk(fsm, num_rules))
            return fail_format(backing, diag, "invalid format: The FSM of rule {d} refers to a rule out of range", .{rule_index});
        var repeat_ok = true;
        var state: i32 = 0;
        while (repeat_ok and state < fsm.num_states()) : (state += 1) {
            for (fsm.state_edges(state)) |edge| {
                if (!edge.is_repeat_ref()) continue;
                const index = std.math.cast(usize, edge.max) orelse {
                    repeat_ok = false;
                    break;
                };
                if (!(index + 3 <= complete_aux.len and rule_ok(complete_aux[index], num_rules))) {
                    repeat_ok = false;
                    break;
                }
            }
        }
        if (!repeat_ok)
            return fail_format(backing, diag, "invalid format: The FSM of rule {d} has a repeat edge that is out of range of complete_fsm", .{rule_index});
    }
}

test "serialize deserialize roundtrip" {
    const backing = std.testing.allocator;
    const grammar_builder_mod = @import("grammar_builder.zig");
    var builder = try grammar_builder_mod.GrammarBuilder.new(backing);
    defer builder.deinit();
    const elem = @import("character_class_element.zig").CharacterClassElement;
    _ = try builder.add_character_class(&.{ elem.new('a', 'z'), elem.new('0', '9') }, false); // 0
    _ = try builder.add_character_class_star(&.{elem.new('A', 'F')}, true); // 1
    _ = try builder.add_byte_string("hi\n\"x\""); // 2
    _ = try builder.add_empty_str(); // 3
    _ = try builder.add_rule_ref(0); // 4
    const seq = try builder.add_sequence(&.{ 0, 2 }); // 5
    _ = try builder.add_token_set(&.{ 1, 2, 3 }); // 6
    _ = try builder.add_exclude_token_set(&.{9}); // 7
    _ = try builder.add_regex("[a-z]+", true); // 8
    _ = try builder.add_substring(&.{ "ab", "", "c" }); // 9
    _ = try builder.add_repeat(0, 1, -1); // 10
    // helper rules for dispatch exprs (bodies must be valid exprs; body-less rules are
    // rejected by `validate`, as in the reference)
    _ = try builder.add_rule_named("td_rule", try builder.add_byte_string("ab")); // rule 1
    _ = try builder.add_rule_named("ttd_rule", try builder.add_byte_string("cd")); // rule 2
    var td = tag_dispatch_mod.TagDispatch.empty();
    defer td.deinit(backing);
    try td.tag_rule_pairs.append(backing, .{ .tag = try backing.dupe(u8, "x"), .rule_id = 1 });
    try td.tag_rule_pairs.append(backing, .{ .tag = try backing.dupe(u8, "yy"), .rule_id = 2 });
    td.loop_after_dispatch = true;
    try td.excludes.append(backing, try backing.dupe(u8, "zz"));
    const tag_dispatch_id = try builder.add_tag_dispatch(&td); // 11
    var ttd = @import("token_tag_dispatch.zig").TokenTagDispatch.empty();
    defer ttd.deinit(backing);
    try ttd.trigger_rule_pairs.append(backing, .{ .token_id = 10, .rule_id = 1 });
    try ttd.trigger_rule_pairs.append(backing, .{ .token_id = 20, .rule_id = 2 });
    ttd.loop_after_dispatch = false;
    try ttd.excludes.appendSlice(backing, &.{ 7, 8, 9 });
    const token_tag_id = try builder.add_token_tag_dispatch(&ttd); // 12
    const choices = try builder.add_choices(&.{ seq, 3, tag_dispatch_id, token_tag_id }); // 13
    const root_id = try builder.add_rule_named("root", choices); // rule 3 (ids 0-2 above)

    var rule0 = Rule.new("root", choices);
    rule0.max_tokens = 4;
    rule0.max_chars = 12;
    rule0.capture_name = "cap";
    rule0.is_lazy = true;
    rule0.temperature = 0.7;
    rule0.lookahead_assertion_id = seq;
    rule0.is_exact_lookahead = true;
    builder.rules.items[@intCast(root_id)] = rule0;
    var info = SuffixStopInfo.default();
    info.rule_id = root_id;
    info.hidden_suffix_bytes = 2;
    info.hidden_stop_bytes = 3;
    info.stop_capture_name = "tail";
    try builder.update_suffix_stop_info(root_id, info);

    const grammar = try builder.into_grammar_with_root_id(backing, root_id);
    defer grammar.deinit();
    try grammar.set_allow_empty_rule_ids(&.{root_id});

    var ser_arena = std.heap.ArenaAllocator.init(backing);
    defer ser_arena.deinit();
    const json = try serialize_json(grammar, ser_arena.allocator());
    const parsed = try deserialize_json(backing, json, null);
    defer parsed.deinit();
    try std.testing.expect(grammar.eql(parsed));
    try std.testing.expectEqual(grammar.num_rules(), parsed.num_rules());
    try std.testing.expectEqual(grammar.num_exprs(), parsed.num_exprs());
    try std.testing.expectEqualStrings("tail", parsed.suffix_stop_info(root_id).?.stop_capture_name);
    try std.testing.expectEqual(@as(f32, 0.7), parsed.rules.items[@intCast(root_id)].temperature.?);
    try std.testing.expect(parsed.rules.items[@intCast(root_id)].is_lazy);
    try std.testing.expectEqual(@as(i32, seq), parsed.rules.items[@intCast(root_id)].lookahead_assertion_id);
    try std.testing.expectEqual(@as(usize, 1), parsed.allow_empty_rule_ids.items.len);
    var decoded_td = try tag_dispatch_mod.tag_dispatch(parsed, backing, tag_dispatch_id);
    defer decoded_td.deinit(backing);
    try std.testing.expect(decoded_td.eql(td));
    var decoded_ttd = try @import("token_tag_dispatch.zig").token_tag_dispatch(parsed, backing, token_tag_id);
    defer decoded_ttd.deinit(backing);
    try std.testing.expect(decoded_ttd.eql(ttd));

    // Roundtrip of the roundtrip is stable.
    const json2 = try serialize_json(parsed, ser_arena.allocator());
    try std.testing.expectEqualStrings(json, json2);
}

test "serialize key order matches serde BTreeMap" {
    const backing = std.testing.allocator;
    const grammar_builder_mod = @import("grammar_builder.zig");
    var builder = try grammar_builder_mod.GrammarBuilder.new(backing);
    defer builder.deinit();
    _ = try builder.add_rule_named("root", try builder.add_empty_str());
    const grammar = try builder.into_grammar_with_root_id(backing, 0);
    defer grammar.deinit();
    var ser_arena = std.heap.ArenaAllocator.init(backing);
    defer ser_arena.deinit();
    const value = try serialize_json_value(grammar, ser_arena.allocator());
    const expected_keys = [_][]const u8{
        "__VERSION__",
        "allow_empty_rule_ids",
        "complete_fsm",
        "grammar_expr_data",
        "grammar_expr_indptr",
        "optimized",
        "per_rule_fsms",
        "root_rule_id",
        "rules",
        "suffix_stop_infos",
    };
    const keys = value.object.keys();
    try std.testing.expectEqual(expected_keys.len, keys.len);
    for (expected_keys, keys) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "deserialize errors: version, missing version, arity, sorted infos, bad refs" {
    const backing = std.testing.allocator;
    const grammar_builder_mod = @import("grammar_builder.zig");
    var builder = try grammar_builder_mod.GrammarBuilder.new(backing);
    defer builder.deinit();
    _ = try builder.add_rule_named("root", try builder.add_empty_str());
    const grammar = try builder.into_grammar_with_root_id(backing, 0);
    defer grammar.deinit();

    // Version mismatch.
    {
        const bad = try std.fmt.allocPrint(backing, "{{\"__VERSION__\":\"v15\",\"rules\":[],\"suffix_stop_infos\":[],\"grammar_expr_data\":[],\"grammar_expr_indptr\":[],\"root_rule_id\":-1,\"complete_fsm\":null,\"per_rule_fsms\":[],\"allow_empty_rule_ids\":[],\"optimized\":false}}", .{});
        defer backing.free(bad);
        var info: DeserializeErrorInfo = undefined;
        try std.testing.expectError(error.Version, deserialize_json(backing, bad, &info));
        defer backing.free(info.Version.got);
        const message = try info.message(backing);
        defer backing.free(message);
        try std.testing.expectEqualStrings("version mismatch: expected v16, got v15", message);
    }
    // Missing version.
    {
        const bad = "{\"rules\":[],\"suffix_stop_infos\":[],\"grammar_expr_data\":[],\"grammar_expr_indptr\":[],\"root_rule_id\":-1,\"complete_fsm\":null,\"per_rule_fsms\":[],\"allow_empty_rule_ids\":[],\"optimized\":false}";
        var info: DeserializeErrorInfo = undefined;
        try std.testing.expectError(error.Format, deserialize_json(backing, bad, &info));
        defer backing.free(info.Format);
        try std.testing.expectEqualStrings("invalid format: missing __VERSION__", info.Format);
    }
    // Invalid JSON.
    {
        var info: DeserializeErrorInfo = undefined;
        try std.testing.expectError(error.InvalidJson, deserialize_json(backing, "{not json", &info));
        try std.testing.expect(info.InvalidJson.len > 0);
    }
    // Rule arity.
    {
        const bad = "{\"__VERSION__\":\"v16\",\"rules\":[[\"r\",0]],\"suffix_stop_infos\":[],\"grammar_expr_data\":[],\"grammar_expr_indptr\":[],\"root_rule_id\":-1,\"complete_fsm\":null,\"per_rule_fsms\":[],\"allow_empty_rule_ids\":[],\"optimized\":false}";
        var info: DeserializeErrorInfo = undefined;
        try std.testing.expectError(error.Format, deserialize_json(backing, bad, &info));
        defer backing.free(info.Format);
        try std.testing.expectEqualStrings("invalid format: rule arity", info.Format);
    }
    // Unsorted suffix_stop_infos.
    {
        const bad = "{\"__VERSION__\":\"v16\",\"rules\":[],\"suffix_stop_infos\":[[3,0,0,-1,-1,\"\"],[1,0,0,-1,-1,\"\"]],\"grammar_expr_data\":[],\"grammar_expr_indptr\":[],\"root_rule_id\":-1,\"complete_fsm\":null,\"per_rule_fsms\":[],\"allow_empty_rule_ids\":[],\"optimized\":false}";
        var info: DeserializeErrorInfo = undefined;
        try std.testing.expectError(error.Format, deserialize_json(backing, bad, &info));
        defer backing.free(info.Format);
        try std.testing.expectEqualStrings("invalid format: suffix_stop_infos must be sorted by rule id", info.Format);
    }
    // Rule refers to expr out of range.
    {
        const bad = "{\"__VERSION__\":\"v16\",\"rules\":[[\"r\",7,-1,false,-1,-1,\"\",false,null]],\"suffix_stop_infos\":[],\"grammar_expr_data\":[],\"grammar_expr_indptr\":[],\"root_rule_id\":0,\"complete_fsm\":null,\"per_rule_fsms\":[],\"allow_empty_rule_ids\":[],\"optimized\":false}";
        var info: DeserializeErrorInfo = undefined;
        try std.testing.expectError(error.Format, deserialize_json(backing, bad, &info));
        defer backing.free(info.Format);
        try std.testing.expectEqualStrings("invalid format: Rule 0 refers to a grammar expr out of range", info.Format);
    }
    // root_rule_id out of range.
    {
        const bad = "{\"__VERSION__\":\"v16\",\"rules\":[],\"suffix_stop_infos\":[],\"grammar_expr_data\":[],\"grammar_expr_indptr\":[],\"root_rule_id\":5,\"complete_fsm\":null,\"per_rule_fsms\":[],\"allow_empty_rule_ids\":[],\"optimized\":false}";
        var info: DeserializeErrorInfo = undefined;
        try std.testing.expectError(error.Format, deserialize_json(backing, bad, &info));
        defer backing.free(info.Format);
        try std.testing.expectEqualStrings("invalid format: root_rule_id 5 is out of range", info.Format);
    }
    // Malformed expr: RuleRef with out-of-range rule.
    {
        const bad = "{\"__VERSION__\":\"v16\",\"rules\":[[\"r\",0,-1,false,-1,-1,\"\",false,null]],\"suffix_stop_infos\":[],\"grammar_expr_data\":[4,1,1,99],\"grammar_expr_indptr\":[0],\"root_rule_id\":0,\"complete_fsm\":null,\"per_rule_fsms\":[],\"allow_empty_rule_ids\":[],\"optimized\":false}";
        var info: DeserializeErrorInfo = undefined;
        try std.testing.expectError(error.Format, deserialize_json(backing, bad, &info));
        defer backing.free(info.Format);
        try std.testing.expectEqualStrings("invalid format: Grammar expr 0 is malformed", info.Format);
    }
    // Unknown expr type tag.
    {
        const bad = "{\"__VERSION__\":\"v16\",\"rules\":[[\"r\",0,-1,false,-1,-1,\"\",false,null]],\"suffix_stop_infos\":[],\"grammar_expr_data\":[99,0],\"grammar_expr_indptr\":[0],\"root_rule_id\":0,\"complete_fsm\":null,\"per_rule_fsms\":[],\"allow_empty_rule_ids\":[],\"optimized\":false}";
        var info: DeserializeErrorInfo = undefined;
        try std.testing.expectError(error.Format, deserialize_json(backing, bad, &info));
        defer backing.free(info.Format);
        try std.testing.expectEqualStrings("invalid format: Unknown type of grammar expr 0", info.Format);
    }
    // Embedded (no version) path works.
    {
        const embedded = "{\"rules\":[[\"r\",0,-1,false,-1,-1,\"\",false,null]],\"suffix_stop_infos\":[],\"grammar_expr_data\":[3,0],\"grammar_expr_indptr\":[0],\"root_rule_id\":0,\"complete_fsm\":null,\"per_rule_fsms\":[],\"allow_empty_rule_ids\":[],\"optimized\":false}";
        var arena = std.heap.ArenaAllocator.init(backing);
        defer arena.deinit();
        const parsed = try deserialize_json_value_embedded(backing, try support.parse_json(arena.allocator(), embedded), null);
        defer parsed.deinit();
        try std.testing.expectEqual(@as(i32, 1), parsed.num_rules());
    }
}

test "optimized grammar roundtrip with complete, shared and distinct rule fsms" {
    const backing = std.testing.allocator;
    const Fsm = fsm_mod.Fsm;
    const grammar_builder_mod = @import("grammar_builder.zig");
    var builder = try grammar_builder_mod.GrammarBuilder.new(backing);
    defer builder.deinit();
    _ = try builder.add_rule_named("r0", try builder.add_empty_str());
    _ = try builder.add_rule_named("r1", try builder.add_empty_str());
    const grammar = try builder.into_grammar_with_root_id(backing, 0);
    defer grammar.deinit();

    // complete: 0 -a-> 1, 0 -e-> 1
    var fsm = try Fsm.new(backing, 2);
    defer fsm.deinit();
    try fsm.add_edge(0, 1, 'a', 'a');
    try fsm.add_epsilon_edge(0, 1);
    var complete = try CompactFsm.from_fsm(backing, &fsm);
    defer complete.deinit();
    // distinct for rule 1: 0 -b-> 1
    var fsm2 = try Fsm.new(backing, 2);
    defer fsm2.deinit();
    try fsm2.add_edge(0, 1, 'b', 'b');
    var distinct = try CompactFsm.from_fsm(backing, &fsm2);
    defer distinct.deinit();

    var ends0: std.ArrayList(i32) = .empty;
    try ends0.append(backing, 1);
    const view0 = try CompactFsmWithStartEnd.new(backing, complete.clone(), 0, ends0, false);
    var ends1: std.ArrayList(i32) = .empty;
    try ends1.append(backing, 1);
    const view1 = try CompactFsmWithStartEnd.new(backing, distinct.clone(), 0, ends1, false);
    var sized0 = CompactFsmWithStartEndWithSize.new(view0, 1, 2);
    defer sized0.deinit();
    var sized1 = CompactFsmWithStartEndWithSize.new(view1, 1, 2);
    defer sized1.deinit();

    try grammar.set_fsms(complete, &.{ sized0, sized1 });
    grammar.set_optimized(true);

    var ser_arena = std.heap.ArenaAllocator.init(backing);
    defer ser_arena.deinit();
    const sa = ser_arena.allocator();
    const json = try serialize_json(grammar, sa);

    const parsed = try deserialize_json(backing, json, null);
    defer parsed.deinit();
    try std.testing.expect(grammar.eql(parsed));
    try std.testing.expect(parsed.is_optimized());
    try std.testing.expect(parsed.complete_fsm.eql(complete));
    // Rule 0's view was rebuilt over the complete FSM's storage; rule 1's stayed distinct.
    try std.testing.expect(parsed.per_rule_fsm(0).?.get_fsm().get_fsm().shares_storage(parsed.complete_fsm));
    try std.testing.expect(!parsed.per_rule_fsm(1).?.get_fsm().get_fsm().shares_storage(parsed.complete_fsm));
    try std.testing.expectEqual(@as(i32, 1), parsed.per_rule_fsm(1).?.get_edge_num());
    try std.testing.expectEqual(@as(i32, 2), parsed.per_rule_fsm(1).?.get_node_num());
    const json2 = try serialize_json(parsed, sa);
    try std.testing.expectEqualStrings(json, json2);
}
