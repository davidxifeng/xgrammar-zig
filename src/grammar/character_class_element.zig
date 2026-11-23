//! One inclusive range of a character class (`character_class_element.rs`).
//! `GrammarBuilder::CharacterClassElement`.

/// An inclusive `[lower, upper]` codepoint range within a character class.
pub const CharacterClassElement = struct {
    /// Inclusive lower bound (codepoint).
    lower: i32,
    /// Inclusive upper bound (codepoint).
    upper: i32,

    /// Creates a range from `lower` to `upper`, inclusive.
    pub fn new(lower: i32, upper: i32) CharacterClassElement {
        return .{ .lower = lower, .upper = upper };
    }

    /// Whether `codepoint` falls within this range.
    pub fn contains(self: CharacterClassElement, codepoint: i32) bool {
        return self.lower <= codepoint and codepoint <= self.upper;
    }

    /// Rust `PartialEq`.
    pub fn eql(a: CharacterClassElement, b: CharacterClassElement) bool {
        return a.lower == b.lower and a.upper == b.upper;
    }
};

const std = @import("std");

test "character class element contains" {
    const e = CharacterClassElement.new(0x61, 0x7A);
    try std.testing.expect(e.contains(0x61));
    try std.testing.expect(e.contains(0x7A));
    try std.testing.expect(e.contains(0x6D));
    try std.testing.expect(!e.contains(0x60));
    try std.testing.expect(!e.contains(0x7B));
    try std.testing.expect(CharacterClassElement.new(1, 1).eql(CharacterClassElement.new(1, 1)));
    try std.testing.expect(!CharacterClassElement.new(1, 1).eql(CharacterClassElement.new(1, 2)));
}
