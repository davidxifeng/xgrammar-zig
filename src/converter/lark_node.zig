//! A parsed Lark expression (`lark_node.rs`).

const std = @import("std");
const lark_location = @import("lark_location.zig");
const lark_node_kind = @import("lark_node_kind.zig");
const lark_document = @import("lark_document.zig");
const LarkLocation = lark_location.LarkLocation;
const LarkNodeKind = lark_node_kind.LarkNodeKind;
const LarkDocument = lark_document.LarkDocument;

/// A Lark expression tree node. Which fields are meaningful depends on `LarkNodeKind`:
/// `text` holds the literal, pattern, name, JSON value, or token text; `text2` the end of a
/// character range; `flags` string or regex flags; `min_repeat`/`max_repeat` the repetition
/// bounds (`-1` is unbounded); `nested` an inline `%lark` document.
/// All payloads live in the owning document's arena; `nested` documents live in the same
/// arena as the tree that references them (Rust `Rc<LarkDocument>` sharing collapsed into
/// arena allocation, read-only after parse).
pub const LarkNode = struct {
    /// The node kind.
    kind: LarkNodeKind,
    /// Where the node starts.
    location: LarkLocation,
    /// The primary text payload.
    text: []const u8 = "",
    /// The end of a character range.
    text2: []const u8 = "",
    /// String or regex flags.
    flags: []const u8 = "",
    /// Minimum repetition count.
    min_repeat: i32 = 0,
    /// Maximum repetition count (`-1` is unbounded).
    max_repeat: i32 = 0,
    /// Child expressions.
    children: std.ArrayList(LarkNode) = .empty,
    /// The document of an inline `%lark { ... }` grammar.
    nested: ?*const LarkDocument = null,

    /// Creates a node of `kind` with empty payloads.
    pub fn new(kind: LarkNodeKind, location: LarkLocation) LarkNode {
        return .{ .kind = kind, .location = location };
    }

    /// Creates a node of `kind` whose primary payload is `text`.
    pub fn with_text(kind: LarkNodeKind, location: LarkLocation, text: []const u8) LarkNode {
        var node = LarkNode.new(kind, location);
        node.text = text;
        return node;
    }

    /// Creates a node of `kind` over `children` (consumed; must be arena-allocated).
    pub fn with_children(kind: LarkNodeKind, location: LarkLocation, children: []const LarkNode, allocator: std.mem.Allocator) std.mem.Allocator.Error!LarkNode {
        var node = LarkNode.new(kind, location);
        try node.children.appendSlice(allocator, children);
        return node;
    }

    /// Creates a repetition of `child` between `min_repeat` and `max_repeat` (`-1` unbounded).
    pub fn repeat(location: LarkLocation, child: LarkNode, min_repeat: i32, max_repeat: i32, allocator: std.mem.Allocator) std.mem.Allocator.Error!LarkNode {
        var node = try LarkNode.with_children(.Repeat, location, &.{child}, allocator);
        node.min_repeat = min_repeat;
        node.max_repeat = max_repeat;
        return node;
    }

    /// Deep copy into `allocator` (Rust `Clone`); used to hand an inline `%lark` document to
    /// a nested compilation (Rust `LarkDocument::clone`).
    pub fn clone(self: *const LarkNode, allocator: std.mem.Allocator) std.mem.Allocator.Error!LarkNode {
        var node = LarkNode.new(self.kind, self.location);
        node.text = try allocator.dupe(u8, self.text);
        node.text2 = try allocator.dupe(u8, self.text2);
        node.flags = try allocator.dupe(u8, self.flags);
        node.min_repeat = self.min_repeat;
        node.max_repeat = self.max_repeat;
        try node.children.ensureTotalCapacity(allocator, self.children.items.len);
        for (self.children.items) |*child| {
            node.children.appendAssumeCapacity(try child.clone(allocator));
        }
        if (self.nested) |nested| {
            const nested_ptr = try allocator.create(lark_document.LarkDocument);
            nested_ptr.* = try lark_document.LarkDocument.deep_clone(allocator, nested);
            node.nested = nested_ptr;
        }
        return node;
    }
};
