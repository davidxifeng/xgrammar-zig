//! The `any_text` structural-tag format (`any_text_format.rs`).

const std = @import("std");

/// `{"type":"any_text","excludes":[..],"max_tokens":..,"max_chars":..}`; `detected_end_strs` is
/// filled by the analyzer.
pub const AnyTextFormat = struct {
    excludes: std.ArrayList([]const u8) = .empty,
    /// Token budget of the text.
    max_tokens: ?i32 = null,
    /// Character budget of the text.
    max_chars: ?i32 = null,
    detected_end_strs: std.ArrayList([]const u8) = .empty,
};
