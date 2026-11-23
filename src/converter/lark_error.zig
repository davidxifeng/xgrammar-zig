//! Error raised by the Lark converter (`lark_error.rs`).
//!
//! Rust enum-with-data → error set + diagnostic union (parser-wave convention): the failure
//! surfaces as `error.Lark`, the payload in a caller-provided `?*LarkErrorInfo` whose message
//! `format_message` reproduces the Rust `Display` text verbatim.

const std = @import("std");
const Allocator = std.mem.Allocator;
const lark_location = @import("lark_location.zig");
const LarkLocation = lark_location.LarkLocation;

/// The error set of every Lark entry point.
pub const LarkError = error{ Lark, OutOfMemory };

/// A Lark conversion failure (Rust `enum LarkError`). Strings are allocated from the caller's
/// allocator; the diagnostic owner frees them (see `deinit`).
pub const LarkErrorInfo = union(enum) {
    /// An error at a location in a Lark source, rendered with the offending line and a caret.
    located: struct {
        /// 1-based line number.
        line: i32,
        /// 1-based byte column.
        column: i32,
        /// Human-readable description.
        message: []u8,
        /// The source line containing the error.
        source_line: []u8,
    },
    /// An invalid named-grammar argument.
    named_grammar: []u8,

    pub fn deinit(self: *LarkErrorInfo, allocator: Allocator) void {
        switch (self.*) {
            .located => |*l| {
                allocator.free(l.message);
                allocator.free(l.source_line);
            },
            .named_grammar => |m| allocator.free(m),
        }
    }

    /// The Rust `Display` text (used by tests that assert error-message substrings).
    pub fn format_message(self: *const LarkErrorInfo, allocator: Allocator) Allocator.Error![]u8 {
        return switch (self.*) {
            .located => |l| blk: {
                const excerpt = render_excerpt(allocator, l.source_line, l.column) catch break :blk error.OutOfMemory;
                defer allocator.free(excerpt);
                break :blk std.fmt.allocPrint(allocator, "Lark error at line {d}, column {d}: {s}{s}", .{ l.line, l.column, l.message, excerpt });
            },
            .named_grammar => |m| allocator.dupe(u8, m),
        };
    }
};

/// Rust `render_excerpt`: `"\n{source_line}\n{spaces}^"`.
fn render_excerpt(allocator: Allocator, source_line: []const u8, column: i32) Allocator.Error![]u8 {
    if (source_line.len == 0) return allocator.dupe(u8, "");
    const pad: usize = @intCast(@max(column - 1, 0));
    const spaces = try allocator.alloc(u8, pad);
    defer allocator.free(spaces);
    @memset(spaces, ' ');
    return std.fmt.allocPrint(allocator, "\n{s}\n{s}^", .{ source_line, spaces });
}

/// Builds a located diagnostic, capturing the source line the location points into
/// (Rust `LarkError::at`).
pub fn at(allocator: Allocator, source: []const u8, location: LarkLocation, message: []const u8) Allocator.Error!LarkErrorInfo {
    const bytes = source;
    var line_start: usize = 0;
    var current_line: i32 = 1;
    while (current_line < location.line and line_start < bytes.len) {
        if (std.mem.indexOfScalarPos(u8, bytes, line_start, '\n')) |offset| {
            line_start += offset + 1;
            current_line += 1;
        } else {
            line_start = bytes.len;
            break;
        }
    }
    const line_end = std.mem.indexOfScalarPos(u8, bytes, line_start, '\n') orelse bytes.len;
    return .{ .located = .{
        .line = location.line,
        .column = location.column,
        .message = try allocator.dupe(u8, message),
        .source_line = try allocator.dupe(u8, bytes[line_start..line_end]),
    } };
}
