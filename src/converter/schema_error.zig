//! Error raised by the JSON-schema converter (`schema_error.rs`).

const std = @import("std");

/// The category of a [`SchemaError`].
pub const SchemaErrorKind = enum {
    /// The schema is structurally invalid (wrong types, bad keywords).
    InvalidSchema,
    /// The schema is well-formed but cannot match any value.
    UnsatisfiableSchema,
};

/// Rust's thiserror struct carries data; Zig surfaces failure as an error set plus a
/// diagnostic out-param (`?*SchemaErrorInfo`), whose `message` is allocated from the
/// converter's caller `gpa` and freed by the caller.
pub const SchemaError = error{
    InvalidSchema,
    UnsatisfiableSchema,
    OutOfMemory,
};

/// The data payload of a [`SchemaError`].
pub const SchemaErrorInfo = struct {
    kind: SchemaErrorKind,
    /// Human-readable description (allocated from `gpa`; the caller frees).
    message: []u8,
};

/// Builds the diagnostic for `e` and returns `e`. Static messages are duped so the
/// caller can free uniformly.
pub fn report(
    e: SchemaError,
    diag: ?*SchemaErrorInfo,
    gpa: std.mem.Allocator,
    message: []const u8,
) SchemaError {
    if (diag) |d| {
        d.* = .{ .kind = switch (e) {
            error.InvalidSchema => .InvalidSchema,
            else => .UnsatisfiableSchema,
        }, .message = gpa.dupe(u8, message) catch &.{} };
    }
    return e;
}

/// [`report`] with a formatted message.
pub fn reportFmt(
    e: SchemaError,
    diag: ?*SchemaErrorInfo,
    gpa: std.mem.Allocator,
    comptime fmt: []const u8,
    args: anytype,
) SchemaError {
    if (diag) |d| {
        const kind: SchemaErrorKind = switch (e) {
            error.InvalidSchema => .InvalidSchema,
            else => .UnsatisfiableSchema,
        };
        const msg = std.fmt.allocPrint(gpa, fmt, args) catch return e;
        d.* = .{ .kind = kind, .message = msg };
    }
    return e;
}
