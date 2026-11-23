//! A 1-based position in a Lark source (`lark_location.rs`).

/// A 1-based line and byte column in a Lark source.
pub const LarkLocation = struct {
    /// 1-based line number.
    line: i32,
    /// 1-based byte column.
    column: i32,

    /// The location of the first byte of a source.
    pub const START: LarkLocation = .{ .line = 1, .column = 1 };
};
