//! Test and debug helpers re-exported for bindings and integration tests (`testing.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const fsm_mod = @import("fsm/mod.zig");
const CompactFsmWithStartEnd = fsm_mod.CompactFsmWithStartEnd;
const grammar_mod = @import("grammar/mod.zig");
const Grammar = grammar_mod.Grammar;
const support = @import("support/mod.zig");
const escape_bytes = support.escape_bytes;
const tokenizer_mod = @import("tokenizer/mod.zig");
const TokenizerInfo = tokenizer_mod.TokenizerInfo;

/// Formats token ids for debugging — the C++ `PrintTokenByIds`. Caller owns slice.
pub fn print_token_by_ids(
    allocator: Allocator,
    token_ids: []const i32,
    tokenizer_info: *const TokenizerInfo,
    max_print_num: i32,
) Allocator.Error![]u8 {
    const vocab = tokenizer_info.decoded_vocab;
    const limit_i32 = @max(@min(@as(i32, @intCast(token_ids.len)), max_print_num), 0);
    const print_num: usize = @intCast(limit_i32);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    w.writeByte('[') catch return error.OutOfMemory;
    for (token_ids[0..print_num], 0..) |token_id, i| {
        const escaped: []const u8 = if (token_id >= 0 and @as(usize, @intCast(token_id)) < vocab.len)
            try escape_bytes(allocator, vocab[@intCast(token_id)])
        else
            try allocator.dupe(u8, "");
        defer allocator.free(escaped);
        w.print("#{d} <{s}>", .{ token_id, escaped }) catch return error.OutOfMemory;
        if (i + 1 < print_num) {
            w.writeAll(", ") catch return error.OutOfMemory;
        }
    }
    if (token_ids.len > print_num) {
        w.writeAll(", ...") catch return error.OutOfMemory;
    }
    w.writeByte(']') catch return error.OutOfMemory;
    return allocator.dupe(u8, out.written());
}

fn format_compact_fsm_with_start_end(allocator: Allocator, fsm: *const CompactFsmWithStartEnd) Allocator.Error![]u8 {
    var reachable_set = try fsm.reachable_states();
    defer reachable_set.deinit();

    var reachable: std.ArrayList(i32) = .empty;
    defer reachable.deinit(allocator);
    var it = reachable_set.keyIterator();
    while (it.next()) |s| try reachable.append(allocator, s.*);
    std.mem.sortUnstable(i32, reachable.items, {}, std.sort.asc(i32));

    var expanded = try fsm.get_fsm().to_fsm(allocator);
    defer expanded.deinit();
    const edges_str = try expanded.edges_to_string(reachable.items);
    defer allocator.free(edges_str);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    w.print("CompactFSM(num_states={d}, start={d}, end=[", .{ fsm.num_states(), fsm.get_start() }) catch return error.OutOfMemory;
    var first_end = true;
    for (fsm.get_ends()) |end_state| {
        if (!reachable_set.contains(end_state)) continue;
        if (!first_end) w.writeAll(", ") catch return error.OutOfMemory;
        first_end = false;
        w.print("{d}", .{end_state}) catch return error.OutOfMemory;
    }
    w.print("], edges={s})", .{edges_str}) catch return error.OutOfMemory;
    return allocator.dupe(u8, out.written());
}

pub const TestingError = Allocator.Error || error{
    NoPerRuleFsms,
    RuleIdOutOfRange,
    RuleHasNoFsm,
};

/// Prints each rule's compiled per-rule FSM using the C++ `ToString` edge format (caller owns slice).
pub fn print_grammar_fsms(allocator: Allocator, grammar: *const Grammar) TestingError![]u8 {
    if (grammar.per_rule_fsms_slice().len != @as(usize, @intCast(grammar.num_rules()))) {
        return error.NoPerRuleFsms;
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    var rule_id: i32 = 0;
    while (rule_id < grammar.num_rules()) : (rule_id += 1) {
        const rule = grammar.rule(rule_id);
        w.print("Rule {d}: {s}, FSM: ", .{ rule_id, rule.name }) catch return error.OutOfMemory;
        if (grammar.per_rule_fsm(rule_id)) |per_rule| {
            const s = try format_compact_fsm_with_start_end(allocator, per_rule.get_fsm());
            defer allocator.free(s);
            w.writeAll(s) catch return error.OutOfMemory;
        } else {
            w.writeAll("None") catch return error.OutOfMemory;
        }
        w.writeByte('\n') catch return error.OutOfMemory;
    }
    return allocator.dupe(u8, out.written());
}

/// Whether the per-rule FSM of `rule_id` accepts `input`.
pub fn is_rule_fsm_accept_string(grammar: *const Grammar, rule_id: i32, input: []const u8) TestingError!bool {
    if (rule_id < 0 or @as(usize, @intCast(rule_id)) >= grammar.per_rule_fsms_slice().len) {
        return error.RuleIdOutOfRange;
    }
    const per_rule = grammar.per_rule_fsm(rule_id) orelse return error.RuleHasNoFsm;
    return per_rule.get_fsm().accept_string(input);
}

test "testing print_token_by_ids" {
    const a = std.testing.allocator;
    var tok = try TokenizerInfo.new(a, &.{ "hi", "\n" }, .Raw, null, null, false, null);
    defer tok.deinit();
    const formatted = try print_token_by_ids(a, &.{ 0, 1, 99 }, &tok, 2);
    defer a.free(formatted);
    try std.testing.expectEqualStrings("[#0 <hi>, #1 <\\n>, ...]", formatted);
}
