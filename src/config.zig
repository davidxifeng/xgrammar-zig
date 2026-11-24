//! Global configuration for XGrammar.

/// The serialization format version stamped into every serialized object's `__VERSION__`.
pub const serialization_version: []const u8 = "v16";

/// Returns the serialization version for the grammar.
pub fn getSerializationVersion() []const u8 {
    return serialization_version;
}
