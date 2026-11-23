//! The legacy structural-tag item (`structural_tag_item.rs`).

/// Legacy structural-tag item (`begin` / `schema` / `end`).
///
/// Prefer the JSON structural-tag document + the structural tag converter; this exists
/// for API parity with `xgrammar::StructuralTagItem`.
pub const StructuralTagItem = struct {
    /// Opening tag text.
    begin: []const u8,
    /// JSON schema (as a string) between the tags.
    schema: []const u8,
    /// Closing tag text.
    end: []const u8,
};
