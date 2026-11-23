//! An error from `Grammar.deserialize_json` (and other deserializers)
//! (`error.rs`). SerializationError family.

const std = @import("std");

/// Error set 1:1 with the Rust `DeserializeError` enum variants; payloads live in
/// `DeserializeErrorInfo` (contract: 错误数据放诊断结构可选回传).
pub const DeserializeError = error{
    /// The input was not valid JSON.
    InvalidJson,
    /// The serialized `__VERSION__` did not match the current one.
    Version,
    /// The JSON was structurally valid but missing/ill-typed for the target type.
    Format,
};

pub const VersionInfo = struct {
    /// The version this build expects.
    expected: []const u8,
    /// The version found in the input.
    got: []const u8,
};

/// Diagnostics for `DeserializeError`, mirroring the Rust enum payloads
/// (shape shared with the tokenizer wave's `support_shim.zig`).
pub const DeserializeErrorInfo = union(enum) {
    InvalidJson: []const u8,
    Version: VersionInfo,
    Format: []const u8,

    /// Renders the Rust `thiserror` message (allocated; caller owns the slice).
    pub fn message(self: DeserializeErrorInfo, gpa: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return switch (self) {
            .InvalidJson => |m| std.fmt.allocPrint(gpa, "invalid JSON: {s}", .{m}),
            .Version => |v| std.fmt.allocPrint(gpa, "version mismatch: expected {s}, got {s}", .{ v.expected, v.got }),
            .Format => |m| std.fmt.allocPrint(gpa, "invalid format: {s}", .{m}),
        };
    }
};

test "deserialize error messages" {
    const gpa = std.testing.allocator;
    const m1 = try (@as(DeserializeErrorInfo, .{ .InvalidJson = "eof" })).message(gpa);
    defer gpa.free(m1);
    try std.testing.expectEqualStrings("invalid JSON: eof", m1);
    const m2 = try (@as(DeserializeErrorInfo, .{ .Version = .{ .expected = "v16", .got = "v15" } })).message(gpa);
    defer gpa.free(m2);
    try std.testing.expectEqualStrings("version mismatch: expected v16, got v15", m2);
    const m3 = try (@as(DeserializeErrorInfo, .{ .Format = "bad" })).message(gpa);
    defer gpa.free(m3);
    try std.testing.expectEqualStrings("invalid format: bad", m3);
}
