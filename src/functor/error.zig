//! Errors raised by grammar passes that reject their input (`error.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The error set of the grammar passes (Rust `FunctorError` enum; the payload of each
/// variant travels through the optional `FunctorErrorInfo` diagnostic, see the
/// support/parser wave convention).
pub const FunctorError = Allocator.Error || error{
    /// A repetition range with a negative lower bound, or an upper bound below the lower one.
    InvalidRepetitionRange,
    /// A rule body could not be compiled into an automaton (e.g. an invalid regex).
    FsmBuild,
    /// A lazy rule whose body is not a choices of terminal-like sequences.
    LazyRuleBodyNotChoices,
    /// A lazy rule whose body contains an element that does not compile into the rule's own FSM.
    LazyRuleElementNotTerminal,
    /// A grammar fsm-storage member awaited from the grammar wave (PORTING deviation 4:
    /// `complete_fsm`/`per_rule_fsms`/`set_fsms` are not installed yet).
    NotImplementedInWaveGrammar,
};

/// The diagnostic payload of a `FunctorError` (Rust enum data; strings are borrowed
/// unless noted: `FsmBuild` messages are allocated — the caller frees them).
pub const FunctorErrorInfo = union(enum) {
    /// The minimum repetition count and the maximum repetition count, or `-1` for unbounded.
    InvalidRepetitionRange: struct { lower: i64, upper: i64 },
    /// The build-failure message (allocated from the pass allocator; caller owns).
    FsmBuild: []const u8,
    /// The name of the lazy rule.
    LazyRuleBodyNotChoices: []const u8,
    /// The name of the lazy rule.
    LazyRuleElementNotTerminal: []const u8,
};

/// Writes `info` into `diag` when present.
pub fn set_diag(diag: ?*FunctorErrorInfo, info: FunctorErrorInfo) void {
    if (diag) |d| d.* = info;
}

/// Reproduces the Rust `Display` text of a `FunctorError` variant verbatim
/// (allocated; caller owns; only the string-carrying variants need this).
pub fn format_message(allocator: Allocator, info: FunctorErrorInfo) Allocator.Error![]u8 {
    return switch (info) {
        .InvalidRepetitionRange => |r| std.fmt.allocPrint(allocator, "Invalid repetition range {{{d}, {d}}}", .{ r.lower, r.upper }),
        .FsmBuild => |msg| allocator.dupe(u8, msg),
        .LazyRuleBodyNotChoices => |rule_name| std.fmt.allocPrint(allocator, "lazy rule '{s}' must have a terminal-like body", .{rule_name}),
        .LazyRuleElementNotTerminal => |rule_name| std.fmt.allocPrint(
            allocator,
            "lazy rule '{s}' must have a terminal-like body (strings, character classes, and regexes that " ++
                "compile to a single FSM); rule references and repetition ranges are not supported",
            .{rule_name},
        ),
    };
}

test "format functor error messages" {
    const gpa = std.testing.allocator;
    const msg = try format_message(gpa, .{ .InvalidRepetitionRange = .{ .lower = 2, .upper = -1 } });
    defer gpa.free(msg);
    try std.testing.expectEqualStrings("Invalid repetition range {2, -1}", msg);
    const lazy = try format_message(gpa, .{ .LazyRuleBodyNotChoices = .{ .rule_name = "x" } });
    defer gpa.free(lazy);
    try std.testing.expectEqualStrings("lazy rule 'x' must have a terminal-like body", lazy);
    const elem = try format_message(gpa, .{ .LazyRuleElementNotTerminal = .{ .rule_name = "y" } });
    defer gpa.free(elem);
    try std.testing.expectEqualStrings(
        "lazy rule 'y' must have a terminal-like body (strings, character classes, and regexes that " ++
            "compile to a single FSM); rule references and repetition ranges are not supported",
        elem,
    );
}
