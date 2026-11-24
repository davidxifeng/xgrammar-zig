//! Recursion-depth guard.

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const Diagnostic = @import("../Diagnostic.zig").Diagnostic;

/// Default maximum recursion depth when unset and no env override is present.
pub const default_max_recursion_depth: u32 = 10_000;

/// Hard upper bound on any configured maximum.
pub const max_reasonable_recursion_depth: u32 = 1_000_000;

const env_var: [*:0]const u8 = "XGRAMMAR_MAX_RECURSION_DEPTH";

pub const RecursionError = error{
    InvalidMax,
    DepthExceeded,
};

var max_recursion_depth = std.atomic.Value(u32).init(0);
threadlocal var current_depth: u32 = 0;

fn loadMaxFromEnv() u32 {
    if (!builtin.link_libc) return default_max_recursion_depth;
    const raw = std.c.getenv(env_var) orelse return default_max_recursion_depth;
    const value = std.fmt.parseInt(u32, std.mem.span(raw), 10) catch return default_max_recursion_depth;
    if (value > 0 and value <= max_reasonable_recursion_depth) return value;
    return default_max_recursion_depth;
}

/// Returns the configured maximum recursion depth, initializing from `XGRAMMAR_MAX_RECURSION_DEPTH`
/// (or default) on first access.
pub fn getMaxRecursionDepth() u32 {
    const current = max_recursion_depth.load(.acquire);
    if (current != 0) return current;
    const initial = loadMaxFromEnv();
    return max_recursion_depth.cmpxchgStrong(0, initial, .acq_rel, .acquire) orelse initial;
}

/// Sets the maximum recursion depth.
pub fn setMaxRecursionDepth(max_depth: u32) RecursionError!void {
    if (max_depth == 0 or max_depth > max_reasonable_recursion_depth) {
        return error.InvalidMax;
    }
    max_recursion_depth.store(max_depth, .release);
}

/// Resets the calling thread's live recursion depth to zero.
pub fn resetRecursionDepth() void {
    current_depth = 0;
}

pub fn formatDepthExceeded(allocator: Allocator, current: u32, max: u32) Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "RecursionGuard: Maximum recursion depth exceeded. Current depth: {d}, Max allowed: {d}",
        .{ current, max },
    );
}

pub fn formatInvalidMax(allocator: Allocator, got: u32) Allocator.Error![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "RecursionGuard: Maximum recursion depth must be positive and less than {d}, got: {d}",
        .{ max_reasonable_recursion_depth, got },
    );
}

/// RAII guard that increments the calling thread's recursion depth on `enter` and
/// decrements it on `deinit`.
pub const RecursionGuard = struct {
    pub fn enter() RecursionError!RecursionGuard {
        return enterDiag(null);
    }

    pub fn enterDiag(diag: ?*Diagnostic) RecursionError!RecursionGuard {
        const max = getMaxRecursionDepth();
        current_depth += 1;
        const current = current_depth;
        if (current > max) {
            current_depth -= 1;
            if (diag) |d| d.setNumbers(.recursion_depth_exceeded, current, max);
            return error.DepthExceeded;
        }
        return RecursionGuard{};
    }

    pub fn deinit(self: RecursionGuard) void {
        _ = self;
        current_depth -= 1;
    }
};

test "recursion guard enter and deinit" {
    const old_max = getMaxRecursionDepth();
    defer setMaxRecursionDepth(old_max) catch unreachable;
    defer resetRecursionDepth();
    resetRecursionDepth();
    setMaxRecursionDepth(2) catch unreachable;

    var g1 = try RecursionGuard.enter();
    var g2 = try RecursionGuard.enter();
    try std.testing.expectEqual(@as(u32, 2), current_depth);
    try std.testing.expectError(error.DepthExceeded, RecursionGuard.enter());
    try std.testing.expectEqual(@as(u32, 2), current_depth);
    g2.deinit();
    g1.deinit();
    try std.testing.expectEqual(@as(u32, 0), current_depth);
}

test "setMaxRecursionDepth validation" {
    const old_max = getMaxRecursionDepth();
    defer setMaxRecursionDepth(old_max) catch unreachable;
    try std.testing.expectError(error.InvalidMax, setMaxRecursionDepth(0));
    try std.testing.expectError(error.InvalidMax, setMaxRecursionDepth(max_reasonable_recursion_depth + 1));
    try setMaxRecursionDepth(500);
    try std.testing.expectEqual(@as(u32, 500), getMaxRecursionDepth());
}

test "formatted error messages" {
    const alloc = std.testing.allocator;
    const depth_msg = try formatDepthExceeded(alloc, 12, 10);
    defer alloc.free(depth_msg);
    try std.testing.expectEqualStrings("RecursionGuard: Maximum recursion depth exceeded. Current depth: 12, Max allowed: 10", depth_msg);

    const invalid_msg = try formatInvalidMax(alloc, 0);
    defer alloc.free(invalid_msg);
    try std.testing.expectEqualStrings("RecursionGuard: Maximum recursion depth must be positive and less than 1000000, got: 0", invalid_msg);
}
