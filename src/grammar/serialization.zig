//! Streaming JSON serialization and validated deserialization for `Grammar` (`v16` layout).
//!
//! Serialization streams directly into `std.json.Stringify` with no intermediate
//! `std.json.Value` DOM tree, preserving exact lexicographic key order and Latin-1
//! string encoding.

const std = @import("std");
const Allocator = std.mem.Allocator;

const config = @import("../config.zig");
const Diagnostic = @import("../Diagnostic.zig").Diagnostic;
const support = @import("../support.zig");
const Compact2dArray = support.Compact2dArray;
const Compact2dArrayError = support.Compact2dArrayError;
const fsm_mod = @import("../fsm.zig");
const CompactFsm = fsm_mod.CompactFsm;
const CompactFsmWithStartEnd = fsm_mod.CompactFsmWithStartEnd;
const CompactFsmWithStartEndWithSize = fsm_mod.CompactFsmWithStartEndWithSize;
const fsm_ser = fsm_mod.serialization;
const grammar_mod = @import("Grammar.zig");
const Grammar = grammar_mod.Grammar;
const GrammarExprType = grammar_mod.GrammarExprType;
const Rule = grammar_mod.Rule;
const SuffixStopInfo = grammar_mod.SuffixStopInfo;
const DeserializeError = grammar_mod.DeserializeError;
const dispatch = @import("dispatch.zig");

pub const SerializeError = Allocator.Error;
pub const DeserializeErrorAll = DeserializeError || Compact2dArrayError || Allocator.Error;

/// Serializes the grammar to its `"v16"` JSON string using streaming `std.json.Stringify`.
/// Caller owns the returned slice.
pub fn serializeJson(grammar: *const Grammar, allocator: Allocator) SerializeError![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    writeJson(grammar, &jw) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

/// Streams the full `"v16"` grammar JSON object (starting with `"__VERSION__"`).
pub fn writeJson(grammar: *const Grammar, jw: *std.json.Stringify) std.json.Stringify.Error!void {
    try jw.beginObject();
    try jw.objectField("__VERSION__");
    try jw.write(config.serialization_version);
    try writeEmbeddedFields(grammar, jw);
    try jw.endObject();
}

/// Streams a grammar embedded inside a compiled grammar (no `"__VERSION__"` field).
pub fn writeJsonEmbedded(grammar: *const Grammar, jw: *std.json.Stringify) std.json.Stringify.Error!void {
    try jw.beginObject();
    try writeEmbeddedFields(grammar, jw);
    try jw.endObject();
}

fn writeEmbeddedFields(grammar: *const Grammar, jw: *std.json.Stringify) std.json.Stringify.Error!void {
    // Keys strictly in lexicographic order to match serde_json BTreeMap.
    try jw.objectField("allow_empty_rule_ids");
    try jw.beginArray();
    for (grammar.allowEmptyRuleIdsSlice()) |id| try jw.write(id);
    try jw.endArray();

    try jw.objectField("complete_fsm");
    if (grammar.isOptimized()) {
        try fsm_ser.writeCompactFsm(grammar.completeFsm(), jw);
    } else {
        try jw.write(null);
    }

    const exprs = grammar.exprsPtr();
    try jw.objectField("grammar_expr_data");
    try jw.beginArray();
    for (0..grammar.numExprs()) |expr_id| {
        const row = exprs.row(expr_id);
        try jw.write(row[0]);
        try jw.write(@as(i32, @intCast(row.len - 1)));
        for (row[1..]) |v| try jw.write(v);
    }
    try jw.endArray();

    try jw.objectField("grammar_expr_indptr");
    try jw.beginArray();
    var offset: i32 = 0;
    for (0..grammar.numExprs()) |expr_id| {
        try jw.write(offset);
        offset += @intCast(exprs.row(expr_id).len + 1);
    }
    try jw.endArray();

    try jw.objectField("optimized");
    try jw.write(grammar.isOptimized());

    try jw.objectField("per_rule_fsms");
    try jw.beginArray();
    if (grammar.isOptimized()) {
        for (grammar.perRuleFsmsSlice()) |maybe| {
            if (maybe) |*view| {
                try fsm_ser.writeCompactFsmWithStartEndWithSize(view, jw);
            } else {
                try jw.write(null);
            }
        }
    }
    try jw.endArray();

    try jw.objectField("root_rule_id");
    try jw.write(grammar.rootRuleId());

    try jw.objectField("rules");
    try jw.beginArray();
    for (grammar.rulesSlice()) |r| {
        try jw.beginArray();
        try writeLatin1JsonString(jw, r.name);
        try jw.write(r.body_expr_id);
        try jw.write(r.lookahead_assertion_id);
        try jw.write(r.is_exact_lookahead);
        try jw.write(r.max_tokens);
        try jw.write(r.max_chars);
        try writeLatin1JsonString(jw, r.capture_name);
        try jw.write(r.is_lazy);
        if (r.temperature) |t| {
            try jw.write(@as(f64, @floatCast(t)));
        } else {
            try jw.write(null);
        }
        try jw.endArray();
    }
    try jw.endArray();

    try jw.objectField("suffix_stop_infos");
    try jw.beginArray();
    for (grammar.suffixStopInfosSlice()) |info| {
        try jw.beginArray();
        try jw.write(info.rule_id);
        try jw.write(info.hidden_suffix_bytes);
        try jw.write(info.hidden_stop_bytes);
        try jw.write(info.body_rule_id);
        try jw.write(info.marker_rule_id);
        try writeLatin1JsonString(jw, info.stop_capture_name);
        try jw.endArray();
    }
    try jw.endArray();
}

/// Streams raw bytes as a Latin-1 encoded JSON string without intermediate heap allocations.
fn writeLatin1JsonString(jw: *std.json.Stringify, bytes: []const u8) std.json.Stringify.Error!void {
    try jw.beginWriteRaw();
    try jw.writer.writeByte('"');
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] < 0x80) {
            const start = i;
            while (i < bytes.len and bytes[i] < 0x80) : (i += 1) {}
            try std.json.Stringify.encodeJsonStringChars(bytes[start..i], jw.options, jw.writer);
        } else if (jw.options.escape_unicode) {
            try jw.writer.writeAll("\\u00");
            try jw.writer.printInt(bytes[i], 16, .lower, .{ .width = 2, .fill = '0' });
            i += 1;
        } else {
            const start = i;
            while (i < bytes.len and bytes[i] >= 0x80) : (i += 1) {}
            try support.encoding.writeLatin1(jw.writer, bytes[start..i]);
        }
    }
    try jw.writer.writeByte('"');
    jw.endWriteRaw();
}

/// Deserializes a grammar from its `"v16"` JSON string.
/// Uses a temporary local `ArenaAllocator` for JSON DOM parsing so nothing leaks on `backing`.
pub fn deserializeJson(
    backing: Allocator,
    json_str: []const u8,
    diag: ?*Diagnostic,
) DeserializeErrorAll!Grammar {
    var temp_arena = std.heap.ArenaAllocator.init(backing);
    defer temp_arena.deinit();
    const value = support.parseJson(temp_arena.allocator(), json_str) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            if (diag) |d| try d.setCopy(backing, .deserialize_invalid_json, @errorName(e));
            return error.InvalidJson;
        },
    };
    return deserializeJsonValueImpl(backing, value, true, diag);
}

/// Deserializes a grammar from a parsed JSON value (`__VERSION__` required).
pub fn deserializeJsonValue(
    backing: Allocator,
    value: std.json.Value,
    diag: ?*Diagnostic,
) DeserializeErrorAll!Grammar {
    return deserializeJsonValueImpl(backing, value, true, diag);
}

/// Deserializes a grammar nested inside a compiled grammar (`__VERSION__` optional).
pub fn deserializeJsonValueEmbedded(
    backing: Allocator,
    value: std.json.Value,
    diag: ?*Diagnostic,
) DeserializeErrorAll!Grammar {
    return deserializeJsonValueImpl(backing, value, false, diag);
}

fn failFormat(
    backing: Allocator,
    diag: ?*Diagnostic,
    comptime fmt: []const u8,
    args: anytype,
) (DeserializeError || Allocator.Error) {
    if (diag) |d| {
        try d.setFmt(backing, .deserialize_format, fmt, args);
    }
    return error.Format;
}

fn getField(value: std.json.Value, name: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |object| object.get(name),
        else => null,
    };
}

fn arrayOf(value: *const std.json.Value) ?*const std.json.Array {
    return switch (value.*) {
        .array => |*arr| arr,
        else => null,
    };
}

fn fixedArray(
    comptime n: usize,
    value: *const std.json.Value,
    backing: Allocator,
    diag: ?*Diagnostic,
    what: []const u8,
) (DeserializeError || Allocator.Error)!*const std.json.Array {
    const arr = arrayOf(value) orelse return failFormat(backing, diag, "expected array", .{});
    if (arr.items.len != n) return failFormat(backing, diag, "{s} arity", .{what});
    return arr;
}

fn i32Of(value: std.json.Value, backing: Allocator, diag: ?*Diagnostic) (DeserializeError || Allocator.Error)!i32 {
    return switch (value) {
        .integer => |v| std.math.cast(i32, v) orelse failFormat(backing, diag, "expected integer", .{}),
        else => failFormat(backing, diag, "expected integer", .{}),
    };
}

fn boolOf(value: std.json.Value, backing: Allocator, diag: ?*Diagnostic) (DeserializeError || Allocator.Error)!bool {
    return switch (value) {
        .bool => |b| b,
        else => failFormat(backing, diag, "expected boolean", .{}),
    };
}

fn stringOf(
    value: std.json.Value,
    temp: Allocator,
    backing: Allocator,
    diag: ?*Diagnostic,
) (DeserializeError || Allocator.Error)![]const u8 {
    const latin1 = switch (value) {
        .string => |s| s,
        else => return failFormat(backing, diag, "expected string", .{}),
    };
    const bytes = support.latin1ToBytes(temp, latin1) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failFormat(backing, diag, "invalid latin-1 string", .{}),
    };
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        return failFormat(backing, diag, "invalid UTF-8 string", .{});
    }
    return bytes;
}

fn i32Array(
    value: *const std.json.Value,
    temp: Allocator,
    backing: Allocator,
    diag: ?*Diagnostic,
) (DeserializeError || Allocator.Error)!std.ArrayList(i32) {
    const arr = arrayOf(value) orelse return failFormat(backing, diag, "expected array", .{});
    var out: std.ArrayList(i32) = .empty;
    errdefer out.deinit(temp);
    try out.ensureTotalCapacity(temp, arr.items.len);
    for (arr.items) |item| out.appendAssumeCapacity(try i32Of(item, backing, diag));
    return out;
}

fn deserializeJsonValueImpl(
    backing: Allocator,
    value: std.json.Value,
    require_version: bool,
    diag: ?*Diagnostic,
) DeserializeErrorAll!Grammar {
    var temp_arena = std.heap.ArenaAllocator.init(backing);
    defer temp_arena.deinit();
    const temp = temp_arena.allocator();

    if (getField(value, "__VERSION__")) |version_field| switch (version_field) {
        .string => |s| {
            if (!std.mem.eql(u8, s, config.serialization_version)) {
                if (diag) |d| try d.setVersionMismatch(backing, config.serialization_version, s);
                return error.Version;
            }
        },
        else => return failFormat(backing, diag, "__VERSION__ must be a string", .{}),
    } else if (require_version) {
        return failFormat(backing, diag, "missing __VERSION__", .{});
    }

    const rules_field = getField(value, "rules") orelse
        return failFormat(backing, diag, "missing rules", .{});
    var rules: std.ArrayList(Rule) = .empty;
    {
        const arr = arrayOf(&rules_field) orelse
            return failFormat(backing, diag, "expected array", .{});
        try rules.ensureTotalCapacity(temp, arr.items.len);
        for (arr.items) |entry| {
            const fields = try fixedArray(9, &entry, backing, diag, "rule");
            const name0 = try stringOf(fields.items[0], temp, backing, diag);
            var r = Rule.init(name0, try i32Of(fields.items[1], backing, diag));
            r.lookahead_assertion_id = try i32Of(fields.items[2], backing, diag);
            r.is_exact_lookahead = try boolOf(fields.items[3], backing, diag);
            r.max_tokens = try i32Of(fields.items[4], backing, diag);
            r.max_chars = try i32Of(fields.items[5], backing, diag);
            r.capture_name = try stringOf(fields.items[6], temp, backing, diag);
            r.is_lazy = try boolOf(fields.items[7], backing, diag);
            r.temperature = switch (fields.items[8]) {
                .null => null,
                .integer => |v| @floatFromInt(v),
                .float => |v| @floatCast(v),
                else => return failFormat(backing, diag, "expected number", .{}),
            };
            rules.appendAssumeCapacity(r);
        }
    }

    const infos_field = getField(value, "suffix_stop_infos") orelse
        return failFormat(backing, diag, "missing suffix_stop_infos", .{});
    var suffix_stop_infos: std.ArrayList(SuffixStopInfo) = .empty;
    {
        const arr = arrayOf(&infos_field) orelse
            return failFormat(backing, diag, "expected array", .{});
        try suffix_stop_infos.ensureTotalCapacity(temp, arr.items.len);
        for (arr.items) |entry| {
            const fields = try fixedArray(6, &entry, backing, diag, "suffix_stop_info");
            var info = SuffixStopInfo.default();
            info.rule_id = try i32Of(fields.items[0], backing, diag);
            info.hidden_suffix_bytes = try i32Of(fields.items[1], backing, diag);
            info.hidden_stop_bytes = try i32Of(fields.items[2], backing, diag);
            info.body_rule_id = try i32Of(fields.items[3], backing, diag);
            info.marker_rule_id = try i32Of(fields.items[4], backing, diag);
            info.stop_capture_name = try stringOf(fields.items[5], temp, backing, diag);
            suffix_stop_infos.appendAssumeCapacity(info);
        }
    }
    if (suffix_stop_infos.items.len >= 2) {
        for (suffix_stop_infos.items[1..], 0..) |info, i| {
            if (!(suffix_stop_infos.items[i].rule_id < info.rule_id)) {
                return failFormat(backing, diag, "suffix_stop_infos must be sorted by rule id", .{});
            }
        }
    }

    const data_field = getField(value, "grammar_expr_data") orelse
        return failFormat(backing, diag, "missing grammar_expr_data", .{});
    const data = try i32Array(&data_field, temp, backing, diag);
    const indptr_field = getField(value, "grammar_expr_indptr") orelse
        return failFormat(backing, diag, "missing grammar_expr_indptr", .{});
    const indptr = try i32Array(&indptr_field, temp, backing, diag);

    var exprs = try Compact2dArray(i32).init(temp);
    for (indptr.items, 0..) |start_value, expr_id| {
        const start = std.math.cast(usize, start_value) orelse
            return failFormat(backing, diag, "grammar_expr_indptr[{d}] is out of range", .{expr_id});
        if (start + 2 > data.items.len) {
            return failFormat(backing, diag, "grammar_expr_indptr[{d}] is out of range", .{expr_id});
        }
        const ty = data.items[start];
        const len_value = data.items[start + 1];
        const len = std.math.cast(usize, len_value) orelse
            return failFormat(backing, diag, "The length of grammar expr {d} is out of range", .{expr_id});
        if (len > data.items.len - (start + 2)) {
            return failFormat(backing, diag, "The length of grammar expr {d} is out of range", .{expr_id});
        }
        const end = start + 2 + len;
        _ = GrammarExprType.fromInt(ty) catch
            return failFormat(backing, diag, "Unknown type of grammar expr {d}", .{expr_id});
        _ = try exprs.pushRowNoncontiguous(temp, ty, data.items[start + 2 .. end]);
    }

    const root_rule_id = try i32Of(
        getField(value, "root_rule_id") orelse return failFormat(backing, diag, "missing root_rule_id", .{}),
        backing,
        diag,
    );
    const allow_empty_field = getField(value, "allow_empty_rule_ids") orelse
        return failFormat(backing, diag, "missing allow_empty_rule_ids", .{});
    const allow_empty = try i32Array(&allow_empty_field, temp, backing, diag);
    const optimized = try boolOf(
        getField(value, "optimized") orelse return failFormat(backing, diag, "missing optimized", .{}),
        backing,
        diag,
    );

    const complete_fsm = getField(value, "complete_fsm") orelse
        return failFormat(backing, diag, "missing complete_fsm", .{});
    const complete_fsm_is_null = complete_fsm == .null;
    const per_rule_json_field = getField(value, "per_rule_fsms") orelse
        return failFormat(backing, diag, "missing per_rule_fsms", .{});
    const per_rule_json = arrayOf(&per_rule_json_field) orelse
        return failFormat(backing, diag, "expected array", .{});

    var grammar = try Grammar.fromParts(backing, rules.items, &exprs, root_rule_id);
    errdefer grammar.deinit();
    try grammar.setSuffixStopInfos(suffix_stop_infos.items);
    try grammar.setAllowEmptyRuleIds(allow_empty.items);

    if (!complete_fsm_is_null or per_rule_json.items.len != 0) {
        var complete = if (complete_fsm_is_null)
            try CompactFsm.empty(backing)
        else
            try fsm_ser.deserializeCompactFsmJsonValue(backing, complete_fsm, diag);
        defer complete.deinit();

        var per_rule: std.ArrayList(?CompactFsmWithStartEndWithSize) = .empty;
        defer {
            for (per_rule.items) |*maybe| {
                if (maybe.*) |*view| view.deinit();
            }
            per_rule.deinit(backing);
        }

        for (per_rule_json.items) |entry| {
            if (entry == .null) {
                try per_rule.append(backing, null);
                continue;
            }
            var view = try fsm_ser.deserializeCompactFsmWithStartEndWithSizeJsonValue(backing, entry, diag);
            var view_moved = false;
            defer if (!view_moved) view.deinit();

            if (!view.compact().eql(complete)) {
                try per_rule.append(backing, view);
                view_moved = true;
                continue;
            }
            var retained = complete.retain();
            var shared = CompactFsmWithStartEnd.init(
                backing,
                retained,
                view.startState(),
                view.ends(),
                view.isDfa(),
            ) catch |err| {
                retained.deinit();
                return err;
            };
            var shared_moved = false;
            errdefer if (!shared_moved) shared.deinit();

            var rebuilt = CompactFsmWithStartEndWithSize.init(shared, view.edgeNum(), view.nodeNum());
            shared_moved = true;
            var rebuilt_moved = false;
            errdefer if (!rebuilt_moved) rebuilt.deinit();

            try per_rule.append(backing, rebuilt);
            rebuilt_moved = true;
        }
        try grammar.setFsms(complete, per_rule.items);
    }
    grammar.setOptimized(optimized);
    try validate(&grammar, backing, diag, !complete_fsm_is_null);
    return grammar;
}

fn validate(
    grammar: *const Grammar,
    backing: Allocator,
    diag: ?*Diagnostic,
    has_complete_fsm: bool,
) (DeserializeError || Allocator.Error)!void {
    const num_rules: i32 = @intCast(grammar.numRules());
    const num_exprs: i32 = @intCast(grammar.numExprs());

    const ruleOk = struct {
        fn check(id: i32, count: i32) bool {
            return id >= 0 and id < count;
        }
    }.check;
    const exprOk = ruleOk;

    for (0..grammar.numExprs()) |expr_index| {
        const expr_id: i32 = @intCast(expr_index);
        const expr = grammar.expr(expr_id);
        const data = expr.data;
        const size = data.len;
        const ok = switch (expr.ty) {
            .ByteString, .EmptyStr, .Token, .ExcludeToken => true,
            .CharacterClass, .CharacterClassStar => size >= 1 and size % 2 == 1,
            .RuleRef => size == 1 and ruleOk(data[0], num_rules),
            .Sequence, .Choices => blk: {
                for (data) |id| if (!exprOk(id, num_exprs)) break :blk false;
                break :blk true;
            },
            .TagDispatch => blk: {
                const extra = dispatch.EXTRA_PARAMETERS;
                if (size < extra or (size - extra) % 2 != 0) break :blk false;
                for (0..(size - extra) / 2) |pair_index| {
                    const pair = data[0 .. size - extra][pair_index * 2 ..][0..2];
                    if (!(exprOk(pair[0], num_exprs) and ruleOk(pair[1], num_rules))) break :blk false;
                }
                if (!exprOk(data[size - 1], num_exprs)) break :blk false;
                break :blk grammar.expr(data[size - 1]).ty == .Choices;
            },
            .Repeat => size == 3 and ruleOk(data[0], num_rules),
            .TokenTagDispatch => blk: {
                if (size < 3) break :blk false;
                const trigger_cnt = std.math.cast(usize, data[0]) orelse break :blk false;
                if (trigger_cnt > (size - 3) / 2) break :blk false;
                if (1 + 2 * trigger_cnt + 2 > size) break :blk false;
                const exclude_value = data[1 + 2 * trigger_cnt + 1];
                const exclude_cnt = std.math.cast(usize, exclude_value) orelse break :blk false;
                for (0..trigger_cnt) |i| {
                    if (!ruleOk(data[2 + 2 * i], num_rules)) break :blk false;
                }
                break :blk 1 + 2 * trigger_cnt + 2 + exclude_cnt == size;
            },
            .Regex => size >= 1,
            .Substring => blk: {
                var index: usize = 0;
                var ok_sub = true;
                while (ok_sub and index < size) {
                    const chunk_len = data[index];
                    index += 1;
                    const len = std.math.cast(usize, chunk_len) orelse {
                        ok_sub = false;
                        continue;
                    };
                    if (len > size - index) {
                        ok_sub = false;
                        continue;
                    }
                    index += len;
                }
                break :blk ok_sub;
            },
        };
        if (!ok) return failFormat(backing, diag, "Grammar expr {d} is malformed", .{expr_id});
    }

    for (grammar.rulesSlice(), 0..) |r, rule_index| {
        if (!exprOk(r.body_expr_id, num_exprs) or
            (r.lookahead_assertion_id != -1 and !exprOk(r.lookahead_assertion_id, num_exprs)))
        {
            return failFormat(backing, diag, "Rule {d} refers to a grammar expr out of range", .{rule_index});
        }
    }
    if (!ruleOk(grammar.rootRuleId(), num_rules)) {
        return failFormat(backing, diag, "root_rule_id {d} is out of range", .{grammar.rootRuleId()});
    }
    for (grammar.suffixStopInfosSlice()) |info| {
        if (!ruleOk(info.rule_id, num_rules) or
            (info.body_rule_id != -1 and !ruleOk(info.body_rule_id, num_rules)) or
            (info.marker_rule_id != -1 and !ruleOk(info.marker_rule_id, num_rules)))
        {
            return failFormat(backing, diag, "suffix_stop_infos refers to a rule out of range", .{});
        }
    }
    for (grammar.allowEmptyRuleIdsSlice()) |id| {
        if (!ruleOk(id, num_rules)) {
            return failFormat(backing, diag, "allow_empty_rule_ids refers to a rule out of range", .{});
        }
    }

    const complete = grammar.completeFsm();
    const complete_aux = complete.edgeAuxData();
    const FsmRulesOk = struct {
        fn check(fsm: CompactFsm, num_rules_count: i32) bool {
            const aux = fsm.edgeAuxData();
            var state: i32 = 0;
            while (state < fsm.numStates()) : (state += 1) {
                for (fsm.stateEdges(state)) |edge| {
                    if (edge.isRuleRef() and !ruleOk(edge.max, num_rules_count)) return false;
                    if (edge.isRepeatRef()) {
                        const index = std.math.cast(usize, edge.max) orelse return false;
                        if (index >= aux.len or !ruleOk(aux[index], num_rules_count)) return false;
                    }
                }
            }
            return true;
        }
    }.check;
    if (has_complete_fsm and !FsmRulesOk(complete, num_rules)) {
        return failFormat(backing, diag, "complete_fsm refers to a rule out of range", .{});
    }
    const per_rule_fsms = grammar.perRuleFsmsSlice();
    if (grammar.isOptimized()) {
        if (!has_complete_fsm or per_rule_fsms.len != grammar.numRules()) {
            return failFormat(backing, diag, "An optimized grammar must have complete_fsm and one FSM per rule", .{});
        }
    }
    for (per_rule_fsms, 0..) |maybe, rule_index| {
        const view = maybe orelse {
            if (grammar.isOptimized()) {
                return failFormat(backing, diag, "Rule {d} has no FSM in an optimized grammar", .{rule_index});
            }
            continue;
        };
        const fsm = view.compact();
        if (!FsmRulesOk(fsm, num_rules)) {
            return failFormat(backing, diag, "The FSM of rule {d} refers to a rule out of range", .{rule_index});
        }
        var repeat_ok = true;
        var state: i32 = 0;
        while (repeat_ok and state < fsm.numStates()) : (state += 1) {
            for (fsm.stateEdges(state)) |edge| {
                if (!edge.isRepeatRef()) continue;
                const index = std.math.cast(usize, edge.max) orelse {
                    repeat_ok = false;
                    break;
                };
                if (index + 3 > complete_aux.len or !ruleOk(complete_aux[index], num_rules)) {
                    repeat_ok = false;
                    break;
                }
            }
        }
        if (!repeat_ok) {
            return failFormat(backing, diag, "The FSM of rule {d} has a repeat edge that is out of range of complete_fsm", .{rule_index});
        }
    }
}

test "serialize deserialize roundtrip on GPA with zero leaks" {
    const backing = std.testing.allocator;
    const Builder = @import("Builder.zig").GrammarBuilder;
    var builder = try Builder.init(backing);
    defer builder.deinit();
    const elem = grammar_mod.CharacterClassElement;
    _ = try builder.addCharacterClass(&.{ elem.init('a', 'z'), elem.init('0', '9') }, false); // 0
    _ = try builder.addCharacterClassStar(&.{elem.init('A', 'F')}, true); // 1
    _ = try builder.addByteString("hi\n\"x\""); // 2
    _ = try builder.addEmptyStr(); // 3
    _ = try builder.addRuleRef(0); // 4
    const seq = try builder.addSequence(&.{ 0, 2 }); // 5
    _ = try builder.addTokenSet(&.{ 1, 2, 3 }); // 6
    _ = try builder.addExcludeTokenSet(&.{9}); // 7
    _ = try builder.addRegex("[a-z]+", true); // 8
    _ = try builder.addSubstring(&.{ "ab", "", "c" }); // 9
    _ = try builder.addRepeat(0, 1, -1); // 10
    _ = try builder.addRuleNamed("td_rule", try builder.addByteString("ab")); // rule 1
    _ = try builder.addRuleNamed("ttd_rule", try builder.addByteString("cd")); // rule 2
    var td = dispatch.TagDispatch.init();
    defer td.deinit(backing);
    try td.tag_rule_pairs.append(backing, .{ .tag = try backing.dupe(u8, "x"), .rule_id = 1 });
    try td.tag_rule_pairs.append(backing, .{ .tag = try backing.dupe(u8, "yy"), .rule_id = 2 });
    td.loop_after_dispatch = true;
    try td.excludes.append(backing, try backing.dupe(u8, "zz"));
    const tag_dispatch_id = try builder.addTagDispatch(&td); // 11
    var ttd = dispatch.TokenTagDispatch.init();
    defer ttd.deinit(backing);
    try ttd.trigger_rule_pairs.append(backing, .{ .token_id = 10, .rule_id = 1 });
    try ttd.trigger_rule_pairs.append(backing, .{ .token_id = 20, .rule_id = 2 });
    ttd.loop_after_dispatch = false;
    try ttd.excludes.appendSlice(backing, &.{ 7, 8, 9 });
    const token_tag_id = try builder.addTokenTagDispatch(&ttd); // 12
    const choices = try builder.addChoices(&.{ seq, 3, tag_dispatch_id, token_tag_id }); // 13
    const root_id = try builder.addRuleNamed("root", choices); // rule 3

    builder.updateLookaheadAssertion(root_id, seq);
    builder.updateLookaheadExact(root_id, true);
    builder.updateMaxTokens(root_id, 4);
    builder.updateMaxChars(root_id, 12);
    try builder.updateCaptureName(root_id, "cap");
    builder.updateLazy(root_id, true);
    builder.updateRuleTemperature(root_id, 0.7);

    var info = SuffixStopInfo.default();
    info.rule_id = root_id;
    info.hidden_suffix_bytes = 2;
    info.hidden_stop_bytes = 3;
    info.stop_capture_name = "tail";
    try builder.updateSuffixStopInfo(root_id, info);

    var grammar = try builder.intoGrammarWithRootId(root_id);
    defer grammar.deinit();
    try grammar.setAllowEmptyRuleIds(&.{root_id});

    const json = try serializeJson(&grammar, backing);
    defer backing.free(json);
    var parsed = try deserializeJson(backing, json, null);
    defer parsed.deinit();
    try std.testing.expect(grammar.eql(&parsed));
    try std.testing.expectEqual(grammar.numRules(), parsed.numRules());
    try std.testing.expectEqual(grammar.numExprs(), parsed.numExprs());
    try std.testing.expectEqualStrings("tail", parsed.suffixStopInfo(root_id).?.stop_capture_name);
    try std.testing.expectEqual(@as(f32, 0.7), parsed.rule(root_id).temperature.?);
    try std.testing.expect(parsed.rule(root_id).is_lazy);
    try std.testing.expectEqual(@as(i32, seq), parsed.rule(root_id).lookahead_assertion_id);
    try std.testing.expectEqual(@as(usize, 1), parsed.allowEmptyRuleIdsSlice().len);

    var decoded_td = try dispatch.tagDispatch(&parsed, backing, tag_dispatch_id);
    defer decoded_td.deinit(backing);
    try std.testing.expect(decoded_td.eql(td));
    var decoded_ttd = try dispatch.tokenTagDispatch(&parsed, backing, token_tag_id);
    defer decoded_ttd.deinit(backing);
    try std.testing.expect(decoded_ttd.eql(ttd));

    const json2 = try serializeJson(&parsed, backing);
    defer backing.free(json2);
    try std.testing.expectEqualStrings(json, json2);
}

test "serialize key order matches serde BTreeMap and Latin-1 string encoding" {
    const backing = std.testing.allocator;
    const Builder = @import("Builder.zig").GrammarBuilder;
    var builder = try Builder.init(backing);
    defer builder.deinit();
    _ = try builder.addRuleNamed("r_中", try builder.addEmptyStr());
    var grammar = try builder.intoGrammarWithRootId(0);
    defer grammar.deinit();

    const json = try serializeJson(&grammar, backing);
    defer backing.free(json);

    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const parsed_val = try support.parseJson(arena.allocator(), json);
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
    const keys = parsed_val.object.keys();
    try std.testing.expectEqual(expected_keys.len, keys.len);
    for (expected_keys, keys) |want, got| try std.testing.expectEqualStrings(want, got);

    var roundtrip = try deserializeJson(backing, json, null);
    defer roundtrip.deinit();
    try std.testing.expectEqualStrings("r_中", roundtrip.rule(0).name);

    // Embedded serialization + special JSON chars & non-ASCII bytes in rule/capture names.
    var b2 = try Builder.init(backing);
    defer b2.deinit();
    const rid = try b2.addRuleNamed("q\"\\n\n\x01_你", try b2.addEmptyStr());
    try b2.updateCaptureName(rid, "c\"\t\\_\xc3\xa9");
    var g2 = try b2.intoGrammarWithRootId(0);
    defer g2.deinit();

    var aw: std.Io.Writer.Allocating = .init(backing);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer };
    try writeJsonEmbedded(&g2, &jw);
    const parsed_emb = try support.parseJson(arena.allocator(), aw.written());
    var restored_emb = try deserializeJsonValueEmbedded(backing, parsed_emb, null);
    defer restored_emb.deinit();
    try std.testing.expect(g2.eql(&restored_emb));
}

test "deserialize errors via Diagnostic: version, missing version, invalid JSON, format" {
    const backing = std.testing.allocator;
    var diag: Diagnostic = .{};
    defer diag.deinit(backing);

    // Version mismatch.
    {
        const bad = "{\"__VERSION__\":\"v15\",\"rules\":[],\"suffix_stop_infos\":[],\"grammar_expr_data\":[],\"grammar_expr_indptr\":[],\"root_rule_id\":-1,\"complete_fsm\":null,\"per_rule_fsms\":[],\"allow_empty_rule_ids\":[],\"optimized\":false}";
        try std.testing.expectError(error.Version, deserializeJson(backing, bad, &diag));
        try std.testing.expectEqual(Diagnostic.Kind.deserialize_version, diag.kind);
        const msg = try diag.formatAlloc(backing);
        defer backing.free(msg);
        try std.testing.expectEqualStrings("version mismatch: expected v16, got v15", msg);
    }
    // Missing version.
    {
        const bad = "{\"rules\":[],\"suffix_stop_infos\":[],\"grammar_expr_data\":[],\"grammar_expr_indptr\":[],\"root_rule_id\":-1,\"complete_fsm\":null,\"per_rule_fsms\":[],\"allow_empty_rule_ids\":[],\"optimized\":false}";
        try std.testing.expectError(error.Format, deserializeJson(backing, bad, &diag));
        try std.testing.expectEqual(Diagnostic.Kind.deserialize_format, diag.kind);
        const msg = try diag.formatAlloc(backing);
        defer backing.free(msg);
        try std.testing.expectEqualStrings("invalid format: missing __VERSION__", msg);
    }
    // Invalid JSON.
    {
        try std.testing.expectError(error.InvalidJson, deserializeJson(backing, "{not json", &diag));
        try std.testing.expectEqual(Diagnostic.Kind.deserialize_invalid_json, diag.kind);
        try std.testing.expect(diag.message.len > 0);
    }
    // Rule arity.
    {
        const bad = "{\"__VERSION__\":\"v16\",\"rules\":[[\"r\",0]],\"suffix_stop_infos\":[],\"grammar_expr_data\":[],\"grammar_expr_indptr\":[],\"root_rule_id\":-1,\"complete_fsm\":null,\"per_rule_fsms\":[],\"allow_empty_rule_ids\":[],\"optimized\":false}";
        try std.testing.expectError(error.Format, deserializeJson(backing, bad, &diag));
        const msg = try diag.formatAlloc(backing);
        defer backing.free(msg);
        try std.testing.expectEqualStrings("invalid format: rule arity", msg);
    }
    // Unsorted suffix_stop_infos.
    {
        const bad = "{\"__VERSION__\":\"v16\",\"rules\":[],\"suffix_stop_infos\":[[3,0,0,-1,-1,\"\"],[1,0,0,-1,-1,\"\"]],\"grammar_expr_data\":[],\"grammar_expr_indptr\":[],\"root_rule_id\":-1,\"complete_fsm\":null,\"per_rule_fsms\":[],\"allow_empty_rule_ids\":[],\"optimized\":false}";
        try std.testing.expectError(error.Format, deserializeJson(backing, bad, &diag));
        const msg = try diag.formatAlloc(backing);
        defer backing.free(msg);
        try std.testing.expectEqualStrings("invalid format: suffix_stop_infos must be sorted by rule id", msg);
    }
    // Embedded (no version) path works.
    {
        const embedded = "{\"rules\":[[\"r\",0,-1,false,-1,-1,\"\",false,null]],\"suffix_stop_infos\":[],\"grammar_expr_data\":[3,0],\"grammar_expr_indptr\":[0],\"root_rule_id\":0,\"complete_fsm\":null,\"per_rule_fsms\":[],\"allow_empty_rule_ids\":[],\"optimized\":false}";
        var arena = std.heap.ArenaAllocator.init(backing);
        defer arena.deinit();
        var parsed = try deserializeJsonValueEmbedded(backing, try support.parseJson(arena.allocator(), embedded), null);
        defer parsed.deinit();
        try std.testing.expectEqual(@as(usize, 1), parsed.numRules());
    }
}

test "optimized grammar roundtrip with complete, shared and distinct rule fsms" {
    const backing = std.testing.allocator;
    const Fsm = fsm_mod.Fsm;
    const Builder = @import("Builder.zig").GrammarBuilder;

    var builder = try Builder.init(backing);
    defer builder.deinit();
    _ = try builder.addRuleNamed("r0", try builder.addEmptyStr());
    _ = try builder.addRuleNamed("r1", try builder.addEmptyStr());
    var grammar = try builder.intoGrammarWithRootId(0);
    defer grammar.deinit();

    var fsm = try Fsm.init(backing, 2);
    defer fsm.deinit();
    try fsm.addEdge(0, 1, 'a', 'a');
    try fsm.addEpsilonEdge(0, 1);
    var complete = try CompactFsm.fromFsm(backing, &fsm);
    defer complete.deinit();

    var fsm2 = try Fsm.init(backing, 2);
    defer fsm2.deinit();
    try fsm2.addEdge(0, 1, 'b', 'b');
    var distinct = try CompactFsm.fromFsm(backing, &fsm2);
    defer distinct.deinit();

    const view0 = try CompactFsmWithStartEnd.init(backing, complete.retain(), 0, &.{1}, false);
    const view1 = try CompactFsmWithStartEnd.init(backing, distinct.retain(), 0, &.{1}, false);
    var sized0 = CompactFsmWithStartEndWithSize.init(view0, 1, 2);
    defer sized0.deinit();
    var sized1 = CompactFsmWithStartEndWithSize.init(view1, 1, 2);
    defer sized1.deinit();

    try grammar.setFsms(complete, &.{ sized0, sized1 });
    grammar.setOptimized(true);

    const json = try serializeJson(&grammar, backing);
    defer backing.free(json);

    var parsed = try deserializeJson(backing, json, null);
    defer parsed.deinit();
    try std.testing.expect(grammar.eql(&parsed));
    try std.testing.expect(parsed.isOptimized());
    try std.testing.expect(parsed.completeFsm().eql(complete));
    try std.testing.expect(parsed.perRuleFsm(0).?.sharesStorage(parsed.completeFsm()));
    try std.testing.expect(!parsed.perRuleFsm(1).?.sharesStorage(parsed.completeFsm()));
    try std.testing.expectEqual(@as(i32, 1), parsed.perRuleFsm(1).?.edgeNum());
    try std.testing.expectEqual(@as(i32, 2), parsed.perRuleFsm(1).?.nodeNum());

    const json2 = try serializeJson(&parsed, backing);
    defer backing.free(json2);
    try std.testing.expectEqualStrings(json, json2);
}
