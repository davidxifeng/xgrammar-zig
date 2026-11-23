//! A `%import` of a common Lark terminal (`lark_import.rs`).

const lark_location = @import("lark_location.zig");
const LarkLocation = lark_location.LarkLocation;

/// One imported terminal: its dotted path and the local name it is bound to.
pub const LarkImport = struct {
    /// The dotted import path, e.g. `common.INT`.
    path: []const u8,
    /// The local terminal name.
    local_name: []const u8,
    /// Where the `%import` directive starts.
    location: LarkLocation,
};
