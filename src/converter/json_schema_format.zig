//! The `json_schema` structural-tag format (`json_schema_format.rs`).

const std = @import("std");

/// `{"type":"json_schema","json_schema":..,"style":..}` (the schema is stored serialized).
pub const JsonSchemaFormat = struct {
    json_schema: []const u8,
    /// One of the [`json_format.JsonFormat`] names.
    style: []const u8,
    any_order: bool = false,
    /// Per-tag cap on consecutive whitespace characters.
    max_whitespace_cnt: ?i32 = null,
    /// Substrings forbidden within string values and property names (sorted, deduplicated).
    excludes: []const []const u8 = &.{},
};
