//! The `any_tokens` structural-tag format (`any_tokens_format.rs`).

const std = @import("std");
const structural_tag_format = @import("structural_tag_format.zig");
const IntOrString = structural_tag_format.IntOrString;

/// `{"type":"any_tokens","exclude_tokens":[..],"max_tokens":..}`.
pub const AnyTokensFormat = struct {
    exclude_tokens: std.ArrayList(IntOrString) = .empty,
    /// Token budget of the token run.
    max_tokens: ?i32 = null,
    resolved_exclude_token_ids: std.ArrayList(i32) = .empty,
    detected_end_token_ids: std.ArrayList(i32) = .empty,
};
