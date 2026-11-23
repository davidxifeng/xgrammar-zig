//! Global configuration for XGrammar.
//! 直译参照:src/config.rs(12 行)。

/// The serialization format version stamped into every serialized object's `__VERSION__`.
pub const SERIALIZATION_VERSION: []const u8 = "v16";

/// Returns the serialization version for the grammar.
///
/// This is used to check the compatibility of the serialized grammar.
pub fn get_serialization_version() []const u8 {
    return SERIALIZATION_VERSION;
}
