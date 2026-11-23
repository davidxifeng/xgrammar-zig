//! Builds an NFA from a (byte-oriented) regex.
//!
//! The regex is parsed into an AST (`RegexIr`) and then lowered into an `FsmWithStartEnd`.
//! This is the FSM-level regex used to compile grammars, distinct from the regex→EBNF
//! converter.

const std = @import("std");
const Allocator = std.mem.Allocator;

const fsm_mod = @import("fsm.zig");
const Fsm = fsm_mod.Fsm;
const fsm_with_start_end = @import("fsm_with_start_end.zig");
const FsmWithStartEnd = fsm_with_start_end.FsmWithStartEnd;
const regex_ir = @import("regex_ir.zig");
const RegexIr = regex_ir.RegexIr;
const regex_ir_errors = regex_ir.RegexError;
const grammar_mod = @import("../grammar/mod.zig");
const GrammarBuilder = grammar_mod.GrammarBuilder;

/// Converts regexes into FSMs.
pub const RegexFsmBuilder = struct {
    /// Builds an FSM accepting the language of `regex`. A leading `(?i)` makes the match ASCII
    /// case-insensitive.
    ///
    /// With a `builder`, bounded repetitions whose upper bound exceeds the unroll threshold
    /// (128) are compiled into a repeat-ref edge referencing a new rule (with a regex body holding
    /// the repeated sub-pattern, named after `rule_hint`) added through `builder`, instead of
    /// being unrolled.
    ///
    /// On error, `err_msg.*` receives the message (allocated from `allocator`; free after use).
    pub fn build(
        allocator: Allocator,
        regex: []const u8,
        builder: ?*GrammarBuilder,
        rule_hint: []const u8,
        err_msg: ?*?[]u8,
    ) regex_ir_errors!FsmWithStartEnd {
        var ir = try RegexIr.parse(allocator, regex, builder, rule_hint, err_msg);
        defer ir.deinit();
        return ir.build(err_msg);
    }

    /// Builds the FSM of `regex` (see `build`), then removes the forbidden bytes from
    /// every character edge. The result accepts the strings of the regex language that contain
    /// no forbidden byte; the language may be empty.
    pub fn build_with_forbidden_chars(
        allocator: Allocator,
        regex: []const u8,
        forbidden_chars: *const [256]bool,
        builder: ?*GrammarBuilder,
        rule_hint: []const u8,
        err_msg: ?*?[]u8,
    ) regex_ir_errors!FsmWithStartEnd {
        const fsm_wse = try build(allocator, regex, builder, rule_hint, err_msg);
        errdefer fsm_wse.deinit();
        var any = false;
        for (forbidden_chars) |f| {
            if (f) any = true;
        }
        if (!any) return fsm_wse;

        var new_fsm = try Fsm.new(allocator, @intCast(fsm_wse.num_states()));
        errdefer new_fsm.deinit();
        for (0..@intCast(fsm_wse.num_states())) |state| {
            for (fsm_wse.get_fsm().state_edges(@intCast(state))) |edge| {
                if (!edge.is_char_range()) {
                    try new_fsm.add_edge(@intCast(state), edge.target, edge.min, edge.max);
                    continue;
                }
                // Split the character range into the maximal sub-ranges of allowed characters.
                var range_start: ?i32 = null;
                var c = edge.min;
                while (c <= edge.max + 1) : (c += 1) {
                    if (c <= edge.max and !forbidden_chars[@intCast(c)]) {
                        if (range_start == null) range_start = c;
                    } else if (range_start) |start| {
                        try new_fsm.add_edge(@intCast(state), edge.target, start, c - 1);
                        range_start = null;
                    }
                }
            }
        }
        var aux: std.ArrayList(i32) = .empty;
        try aux.appendSlice(allocator, fsm_wse.get_fsm().edge_aux_data_slice());
        new_fsm.set_edge_aux_data(aux);
        var ends: std.ArrayList(i32) = .empty;
        try ends.appendSlice(allocator, fsm_wse.get_ends());
        const result = try FsmWithStartEnd.new(allocator, new_fsm, fsm_wse.get_start(), ends, false);
        fsm_wse.deinit();
        return result;
    }

    /// Whether `regex` matches the empty string. Only parses the regex; no FSM is built, so this
    /// is cheap even for huge bounded repetitions.
    pub fn matches_empty(allocator: Allocator, regex: []const u8, err_msg: ?*?[]u8) regex_ir_errors!bool {
        var ir = try RegexIr.parse(allocator, regex, null, "", err_msg);
        defer ir.deinit();
        return ir.matches_empty();
    }
};
