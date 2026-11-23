//! The type of the vocabulary. Used in [`TokenizerInfo`](tokenizer_info.zig).
//!
//! XGrammar supports three types of vocabularies: [`Raw`](VocabType.Raw),
//! [`ByteFallback`](VocabType.ByteFallback), and [`ByteLevel`](VocabType.ByteLevel).

/// How a tokenizer's raw vocabulary strings are encoded (and thus how they decode to bytes).
pub const VocabType = enum(i64) {
    /// The vocabulary is in the raw format.
    ///
    /// The tokens in the vocabulary are kept in their original form without any processing. This
    /// kind of tokenizer includes the tiktoken tokenizer, e.g. `microsoft/Phi-3-small-8k-instruct`,
    /// `Qwen/Qwen-7B-Chat`, etc.
    Raw = 0,
    /// The vocabulary used in the byte fallback BPE tokenizer.
    ///
    /// The tokens are encoded through the byte-fallback conversion. E.g. `"\u001b"` → `"<0x1B>"`,
    /// `" apple"` → `"▁apple"`. This kind of tokenizer includes `meta-llama/Llama-2-7b-chat`,
    /// `microsoft/Phi-3.5-mini-instruct`, etc.
    ByteFallback = 1,
    /// The vocabulary used in the byte level BPE tokenizer.
    ///
    /// The tokens are encoded through the byte-to-unicode conversion, as in the GPT-2
    /// tokenization scheme. This kind of tokenizer includes `meta-llama/Meta-Llama-3-8B-Instruct`,
    /// `meta-llama/Meta-Llama-3.1-8B-Instruct`, etc.
    ByteLevel = 2,
};

/// Backwards-compatible spelling used by xgrammar-rs 0.2.
pub const RAW: VocabType = .Raw;
/// Backwards-compatible spelling used by xgrammar-rs 0.2.
pub const BYTE_FALLBACK: VocabType = .ByteFallback;
/// Backwards-compatible spelling used by xgrammar-rs 0.2.
pub const BYTE_LEVEL: VocabType = .ByteLevel;

/// Error converting an integer to a [`VocabType`]. The offending value is carried here
/// (Zig error sets cannot hold payloads).
pub const UnknownVocabType = struct { value: i64 };

pub const TryFromError = error{UnknownVocabType};

pub fn try_from(value: i64) TryFromError!VocabType {
    return switch (value) {
        0 => .Raw,
        1 => .ByteFallback,
        2 => .ByteLevel,
        else => error.UnknownVocabType,
    };
}
