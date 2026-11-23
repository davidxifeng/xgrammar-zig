//! Errors from building [`TokenizerInfo`](tokenizer_info.zig).

/// An error from constructing tokenizer info.
///
/// Payload data (mirroring the Rust enum variants) is carried in
/// [`TokenizerErrorInfo`]; fallible entry points accept `?*TokenizerErrorInfo`.
pub const TokenizerError = error{
    /// The padded vocabulary size is smaller than the number of real tokens.
    VocabSizeTooSmall,
    /// The metadata JSON is malformed.
    InvalidMetadata,
    OutOfMemory,
};

/// Diagnostics for [`TokenizerError`], mirroring the Rust enum payloads.
pub const TokenizerErrorInfo = union(enum) {
    /// "vocab_size ({vocab_size}) must be at least the number of tokens in the vocab ({num_tokens})."
    VocabSizeTooSmall: struct {
        vocab_size: i32,
        num_tokens: usize,
    },
    InvalidMetadata: []const u8,
};

pub fn set_diag(diag: ?*TokenizerErrorInfo, info: TokenizerErrorInfo) void {
    if (diag) |d| d.* = info;
}
