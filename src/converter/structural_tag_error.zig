//! Error raised by the structural-tag converter (`structural_tag_error.rs`).
//!
//! Rust enum-with-data → error set + diagnostic union carrying the message.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The error set of the structural-tag parser/converter.
pub const StructuralTagError = error{
    InvalidJson,
    InvalidJsonSchema,
    InvalidStructuralTag,
    OutOfMemory,
};

/// The message payload of a [`StructuralTagError`] (allocated from the caller's allocator;
/// freed by the diagnostic owner).
pub const StructuralTagErrorInfo = struct {
    kind: StructuralTagError,
    message: []u8,

    pub fn deinit(self: *StructuralTagErrorInfo, allocator: Allocator) void {
        allocator.free(self.message);
    }

    /// The Rust `Display` text.
    pub fn format_message(self: *const StructuralTagErrorInfo, allocator: Allocator) Allocator.Error![]u8 {
        const prefix: []const u8 = switch (self.kind) {
            error.InvalidJson => "Invalid JSON error: ",
            error.InvalidJsonSchema => "Invalid JSON schema error: ",
            error.InvalidStructuralTag => "Invalid structural tag error: ",
            else => "",
        };
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, self.message });
    }
};

/// Stores `info` into a null-initialized diag slot, freeing any previous payload.
pub fn set_info(dest: *?StructuralTagErrorInfo, info: StructuralTagErrorInfo, allocator: Allocator) Allocator.Error!void {
    if (dest.*) |*old| old.deinit(allocator);
    dest.* = info;
}

/// Builds an `InvalidStructuralTag` info (Rust `StructuralTagError::invalid`).
pub fn invalid(allocator: Allocator, message: []const u8) Allocator.Error!StructuralTagErrorInfo {
    return .{ .kind = error.InvalidStructuralTag, .message = try allocator.dupe(u8, message) };
}
