//! Errors from `GrammarMatcher` operations (`error.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// An error from matcher construction or a matcher operation (Rust `MatcherError`).
pub const MatcherError = Allocator.Error || error{
    /// The matcher already accepted the stop token.
    Terminated,
    /// `override_stop_tokens` was empty.
    EmptyOverrideStopTokens,
    /// An override stop token id is outside the vocabulary.
    StopTokenOutOfRange,
    /// The default temperature is negative or not finite.
    InvalidDefaultTemperature,
    /// More tokens were rolled back than recorded.
    RollbackTooFar,
    /// A bitmask, temperature, or draft-tree argument has an invalid shape, dtype, or index.
    InvalidArgument,
};

/// Diagnostic payload carrying details of a [`MatcherError`]. Strings in `.InvalidArgument`
/// are allocated with the caller's allocator when `diag != null` and released via `deinit`.
pub const MatcherErrorInfo = union(enum) {
    Terminated: []const u8,
    EmptyOverrideStopTokens,
    StopTokenOutOfRange: struct { token_id: i32, vocab_size: i32 },
    InvalidDefaultTemperature,
    RollbackTooFar: struct { requested: i32, available: usize },
    InvalidArgument: []const u8,

    pub fn deinit(self: *MatcherErrorInfo, allocator: Allocator) void {
        switch (self.*) {
            .InvalidArgument => |msg| if (msg.len > 0) allocator.free(msg),
            else => {},
        }
    }

    pub fn format_message(self: *const MatcherErrorInfo, allocator: Allocator) Allocator.Error![]u8 {
        return switch (self.*) {
            .Terminated => |action| std.fmt.allocPrint(
                allocator,
                "GrammarMatcher has terminated after accepting the stop token, but is trying to {s}",
                .{action},
            ),
            .EmptyOverrideStopTokens => allocator.dupe(u8, "The override_stop_tokens should not be empty"),
            .StopTokenOutOfRange => |s| std.fmt.allocPrint(
                allocator,
                "The override stop token id {d} is out of the vocabulary range [0, {d})",
                .{ s.token_id, s.vocab_size },
            ),
            .InvalidDefaultTemperature => allocator.dupe(
                u8,
                "The default_temperature must be a finite non-negative number",
            ),
            .RollbackTooFar => |r| std.fmt.allocPrint(
                allocator,
                "Intended to rollback {d} tokens, but only the last {d} steps of history are saved",
                .{ r.requested, r.available },
            ),
            .InvalidArgument => |msg| allocator.dupe(u8, msg),
        };
    }
};

pub fn set_invalid_arg(
    diag: ?*MatcherErrorInfo,
    allocator: Allocator,
    msg: []const u8,
) MatcherError {
    if (diag) |d| {
        d.* = .{ .InvalidArgument = allocator.dupe(u8, msg) catch "" };
    }
    return error.InvalidArgument;
}

pub fn set_invalid_arg_fmt(
    diag: ?*MatcherErrorInfo,
    allocator: Allocator,
    comptime fmt: []const u8,
    args: anytype,
) MatcherError {
    if (diag) |d| {
        d.* = .{ .InvalidArgument = std.fmt.allocPrint(allocator, fmt, args) catch "" };
    }
    return error.InvalidArgument;
}
