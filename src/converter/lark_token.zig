//! A token produced by the Lark lexer (`lark_token.rs`).

const lark_location = @import("lark_location.zig");
const lark_token_type = @import("lark_token_type.zig");
const LarkLocation = lark_location.LarkLocation;
const LarkTokenType = lark_token_type.LarkTokenType;

/// A Lark token: its kind, source text (or re-serialized JSON value), and regex flags.
/// `text`/`flags` are allocated from the parsing document's arena.
pub const LarkToken = struct {
    /// The token kind.
    ty: LarkTokenType,
    /// The token text; the pattern for regexes and the serialized value for JSON directives.
    text: []const u8,
    /// The flags following a regular expression.
    flags: []const u8,
    /// Where the token starts.
    location: LarkLocation,
};
