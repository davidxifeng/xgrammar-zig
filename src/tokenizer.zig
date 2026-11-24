//! Tokenizer metadata and vocabulary decoding for grammar-guided generation.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const token_decoder = @import("tokenizer/token_decoder.zig");
pub const hf_metadata = @import("tokenizer/hf_metadata.zig");
const tokenizer_info_mod = @import("tokenizer/TokenizerInfo.zig");

/// How a tokenizer's raw vocabulary strings are encoded (and thus how they decode to bytes).
pub const VocabType = enum(i64) {
    /// The vocabulary is in the raw format.
    ///
    /// Tokens are kept in their original form without processing (e.g. tiktoken tokenizers).
    raw = 0,
    /// The vocabulary used in byte-fallback BPE tokenizers.
    ///
    /// Tokens are encoded through byte-fallback conversion (e.g. `"\u001b"` -> `"<0x1B>"`,
    /// `" apple"` -> `"▁apple"`).
    byte_fallback = 1,
    /// The vocabulary used in byte-level BPE tokenizers (GPT-2 bytes-to-unicode mapping).
    byte_level = 2,

    pub fn fromInt(v: i64) error{UnknownVocabType}!VocabType {
        return std.enums.fromInt(VocabType, v) orelse error.UnknownVocabType;
    }
};

/// Errors from constructing `TokenizerInfo`.
pub const TokenizerError = error{
    VocabSizeTooSmall,
    InvalidMetadata,
    OutOfMemory,
};

/// Errors from deserializing `TokenizerInfo` or matching serialized metadata.
pub const DeserializeError = error{
    InvalidJson,
    Version,
    Format,
};

/// Deserialization fallibility including allocation.
pub const DeserializeErrorAll = DeserializeError || Allocator.Error;

pub const TokenizerInfo = tokenizer_info_mod.TokenizerInfo;
pub const SortedDecodedToken = tokenizer_info_mod.SortedDecodedToken;
pub const HfMetadata = hf_metadata.HfMetadata;
pub const DetectError = hf_metadata.DetectError;
pub const detectMetadataFromHf = hf_metadata.detectMetadataFromHf;
pub const metadataToJson = hf_metadata.metadataToJson;
pub const decodeToken = token_decoder.decodeToken;
pub const decodeTokenBytes = token_decoder.decodeTokenBytes;

test "VocabType.fromInt" {
    try std.testing.expectEqual(VocabType.raw, try VocabType.fromInt(0));
    try std.testing.expectEqual(VocabType.byte_fallback, try VocabType.fromInt(1));
    try std.testing.expectEqual(VocabType.byte_level, try VocabType.fromInt(2));
    try std.testing.expectError(error.UnknownVocabType, VocabType.fromInt(-1));
    try std.testing.expectError(error.UnknownVocabType, VocabType.fromInt(3));
}

test {
    _ = token_decoder;
    _ = hf_metadata;
    _ = tokenizer_info_mod;
    _ = TokenizerInfo;
    std.testing.refAllDecls(@This());
}
