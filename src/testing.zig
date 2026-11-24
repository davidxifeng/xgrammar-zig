//! Test and debug helpers re-exported for bindings and integration tests (`testing.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const fsm_mod = @import("fsm.zig");
const CompactFsmWithStartEnd = fsm_mod.CompactFsmWithStartEnd;
const grammar_mod = @import("grammar.zig");
const Grammar = grammar_mod.Grammar;
const support = @import("support.zig");
const escapeBytes = support.escapeBytes;
const tokenizer_mod = @import("tokenizer.zig");
const TokenizerInfo = tokenizer_mod.TokenizerInfo;

/// Formats token ids for debugging (`PrintTokenByIds`). Caller owns slice.
pub fn printTokenByIds(
    allocator: Allocator,
    token_ids: []const u32,
    tokenizer_info: *const TokenizerInfo,
    max_print_num: usize,
) Allocator.Error![]u8 {
    const vocab = tokenizer_info.decodedVocab();
    const print_num = @min(token_ids.len, max_print_num);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    w.writeByte('[') catch return error.OutOfMemory;
    for (token_ids[0..print_num], 0..) |token_id, i| {
        const escaped: []const u8 = if (token_id < vocab.len)
            try escapeBytes(allocator, vocab[token_id])
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

fn formatCompactFsmWithStartEnd(allocator: Allocator, fsm: *const CompactFsmWithStartEnd) Allocator.Error![]u8 {
    var reachable_set = try fsm.reachableStates(allocator);
    defer reachable_set.deinit();

    var reachable: std.ArrayList(i32) = .empty;
    defer reachable.deinit(allocator);
    var it = reachable_set.keyIterator();
    while (it.next()) |s| try reachable.append(allocator, s.*);
    std.mem.sortUnstable(i32, reachable.items, {}, std.sort.asc(i32));

    var expanded = try fsm.fsm.toFsm(allocator);
    defer expanded.deinit();
    const edges_str = try expanded.edgesToString(allocator, reachable.items);
    defer allocator.free(edges_str);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    w.print("CompactFSM(num_states={d}, start={d}, end=[", .{ fsm.numStates(), fsm.start }) catch return error.OutOfMemory;
    var first_end = true;
    for (fsm.ends) |end_state| {
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
pub fn printGrammarFsms(allocator: Allocator, grammar: *const Grammar) TestingError![]u8 {
    if (grammar.perRuleFsmsSlice().len != grammar.numRules()) {
        return error.NoPerRuleFsms;
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    for (0..grammar.numRules()) |rule_idx| {
        const rule_id: i32 = @intCast(rule_idx);
        const r = grammar.rule(rule_id);
        w.print("Rule {d}: {s}, FSM: ", .{ rule_id, r.name }) catch return error.OutOfMemory;
        if (grammar.perRuleFsm(rule_id)) |per_rule| {
            const s = try formatCompactFsmWithStartEnd(allocator, &per_rule.fsm);
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
pub fn isRuleFsmAcceptString(
    allocator: Allocator,
    grammar: *const Grammar,
    rule_id: i32,
    input: []const u8,
) TestingError!bool {
    if (rule_id < 0 or @as(usize, @intCast(rule_id)) >= grammar.perRuleFsmsSlice().len) {
        return error.RuleIdOutOfRange;
    }
    const per_rule = grammar.perRuleFsm(rule_id) orelse return error.RuleHasNoFsm;
    return per_rule.fsm.acceptString(allocator, input);
}

test "testing printTokenByIds" {
    const a = std.testing.allocator;
    var tok = try TokenizerInfo.init(a, &.{ "hi", "\n" }, .{});
    defer tok.deinit();
    const formatted = try printTokenByIds(a, &.{ 0, 1, 99 }, &tok, 2);
    defer a.free(formatted);
    try std.testing.expectEqualStrings("[#0 <hi>, #1 <\\n>, ...]", formatted);
}
