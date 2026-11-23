//! Recursion-depth guard.
//!
//! A process-global maximum depth (configurable, env-overridable) bounds recursion in
//! the parser and grammar functors; a per-thread counter tracks the live depth via an
//! RAII [`RecursionGuard`]. Recursion is always within a single thread, so the counter is
//! thread-local.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Default maximum recursion depth when unset and no env override is present.
pub const DEFAULT_MAX_RECURSION_DEPTH: i32 = 10_000;

/// Hard upper bound on any configured maximum.
pub const MAX_REASONABLE_RECURSION_DEPTH: i32 = 1_000_000;

const ENV_VAR: [*:0]const u8 = "XGRAMMAR_MAX_RECURSION_DEPTH";

/// Error set mirroring the Rust `RecursionError` variants.
pub const RecursionError = error{
    /// A requested maximum was non-positive or exceeded `MAX_REASONABLE_RECURSION_DEPTH`.
    InvalidMax,
    /// The live recursion depth exceeded the configured maximum.
    DepthExceeded,
};

/// Diagnostic payload for a `RecursionError` (Rust error-enum data; read after catching).
pub const RecursionErrorInfo = struct {
    current: i32 = 0,
    max: i32 = 0,
};

// 0 is a sentinel meaning "not yet initialized".
var max_recursion_depth = std.atomic.Value(i32).init(0);

threadlocal var current_depth: i32 = 0;

// Latest error diagnostics for the calling thread.
threadlocal var last_error_info: RecursionErrorInfo = .{};

/// Formats the message the Rust `RecursionError::DepthExceeded` Display would produce.
pub fn format_depth_exceeded(allocator: Allocator, current: i32, max: i32) Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "RecursionGuard: Maximum recursion depth exceeded. Current depth: {d}, Max allowed: {d}", .{ current, max });
}

/// Formats the message the Rust `RecursionError::InvalidMax` Display would produce.
pub fn format_invalid_max(allocator: Allocator, got: i32) Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "RecursionGuard: Maximum recursion depth must be positive and less than {d}, got: {d}", .{ MAX_REASONABLE_RECURSION_DEPTH, got });
}

/// The diagnostics of the most recent `RecursionError` on the calling thread.
pub fn last_error() RecursionErrorInfo {
    return last_error_info;
}

fn load_max_from_env() i32 {
    // macOS/libSystem always links libc here; std.c.getenv avoids the 0.17
    // process-environ rework which has no stable std-level global accessor.
    const raw = std.c.getenv(ENV_VAR) orelse return DEFAULT_MAX_RECURSION_DEPTH;
    const value = std.fmt.parseInt(i32, std.mem.span(raw), 10) catch return DEFAULT_MAX_RECURSION_DEPTH;
    if (value > 0 and value <= MAX_REASONABLE_RECURSION_DEPTH) return value;
    return DEFAULT_MAX_RECURSION_DEPTH;
}

/// Returns the configured maximum recursion depth, initializing it from the environment
/// (or the default) on first access.
pub fn get_max_recursion_depth() i32 {
    const current = max_recursion_depth.load(.monotonic);
    if (current != 0) return current;
    const initial = load_max_from_env();
    max_recursion_depth.store(initial, .monotonic);
    return initial;
}

/// Sets the maximum recursion depth.
pub fn set_max_recursion_depth(max_depth: i32) RecursionError!void {
    if (max_depth <= 0 or max_depth > MAX_REASONABLE_RECURSION_DEPTH) {
        last_error_info = .{ .current = max_depth };
        return error.InvalidMax;
    }
    max_recursion_depth.store(max_depth, .monotonic);
}

/// Resets the calling thread's live recursion depth to zero.
pub fn reset_recursion_depth() void {
    current_depth = 0;
}

/// Idiomatic Zig camelCase aliases.
pub const getMaxRecursionDepth = get_max_recursion_depth;
pub const setMaxRecursionDepth = set_max_recursion_depth;
pub const resetRecursionDepth = reset_recursion_depth;

/// RAII guard that increments the calling thread's recursion depth on creation and
/// decrements it on drop (`deinit`).
pub const RecursionGuard = struct {
    /// Enters one level of recursion.
    ///
    /// Returns `error.DepthExceeded` if entering would exceed the configured
    /// maximum; the depth counter is left unchanged in that case.
    pub fn enter() RecursionError!RecursionGuard {
        const max = get_max_recursion_depth();
        current_depth += 1;
        const current = current_depth;
        if (current > max) {
            current_depth -= 1;
            last_error_info = .{ .current = current, .max = max };
            return error.DepthExceeded;
        }
        return RecursionGuard{};
    }

    /// Drops the guard: decrements the calling thread's live depth.
    pub fn deinit(self: RecursionGuard) void {
        _ = self;
        current_depth -= 1;
    }
};

test "recursion guard enter and drop" {
    const old_max = get_max_recursion_depth();
    defer set_max_recursion_depth(old_max) catch unreachable;
    defer reset_recursion_depth();
    reset_recursion_depth();
    set_max_recursion_depth(2) catch unreachable;

    var g1 = try RecursionGuard.enter();
    var g2 = try RecursionGuard.enter();
    try std.testing.expectEqual(@as(i32, 2), current_depth);
    try std.testing.expectError(error.DepthExceeded, RecursionGuard.enter());
    try std.testing.expectEqual(@as(i32, 2), current_depth); // unchanged on failure
    g2.deinit();
    g1.deinit();
    try std.testing.expectEqual(@as(i32, 0), current_depth);
}

test "recursion depth limit" {
    const old_max = get_max_recursion_depth();
    defer set_max_recursion_depth(old_max) catch unreachable;
    defer reset_recursion_depth();
    reset_recursion_depth();
    set_max_recursion_depth(1) catch unreachable;

    var guard = try RecursionGuard.enter();
    defer guard.deinit();
    try std.testing.expectError(error.DepthExceeded, RecursionGuard.enter());
    try std.testing.expectEqual(@as(i32, 2), last_error().current);
    try std.testing.expectEqual(@as(i32, 1), last_error().max);
}

test "set_max_recursion_depth validation" {
    const old_max = get_max_recursion_depth();
    defer set_max_recursion_depth(old_max) catch unreachable;
    try std.testing.expectError(error.InvalidMax, set_max_recursion_depth(0));
    try std.testing.expectError(error.InvalidMax, set_max_recursion_depth(-5));
    try std.testing.expectError(error.InvalidMax, set_max_recursion_depth(MAX_REASONABLE_RECURSION_DEPTH + 1));
    try set_max_recursion_depth(500);
    try std.testing.expectEqual(@as(i32, 500), get_max_recursion_depth());
    try std.testing.expectEqual(MAX_REASONABLE_RECURSION_DEPTH + 1, last_error().current);
}

test "formatted error messages match Rust Display" {
    const alloc = std.testing.allocator;
    const depth_msg = try format_depth_exceeded(alloc, 12, 10);
    defer alloc.free(depth_msg);
    try std.testing.expectEqualStrings("RecursionGuard: Maximum recursion depth exceeded. Current depth: 12, Max allowed: 10", depth_msg);

    const invalid_msg = try format_invalid_max(alloc, 0);
    defer alloc.free(invalid_msg);
    try std.testing.expectEqualStrings("RecursionGuard: Maximum recursion depth must be positive and less than 1000000, got: 0", invalid_msg);
}
