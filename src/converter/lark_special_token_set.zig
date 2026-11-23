//! The token ids selected by a Lark special-token reference (`lark_special_token_set.rs`).

const std = @import("std");

/// The token ids of a `<...>` special token, and whether they are excluded (`<[^...]>`).
pub const LarkSpecialTokenSet = struct {
    /// Whether the token ids are excluded rather than allowed.
    excluded: bool = false,
    /// The selected token ids.
    token_ids: std.ArrayList(i32) = .empty,
};
