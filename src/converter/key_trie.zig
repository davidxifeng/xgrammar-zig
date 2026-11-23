//! A trie over property-name spellings, for key patterns that exclude the declared
//! names (`key_trie.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A trie node over key units (bytes). Deviation: the Rust struct is generic over an
/// `Ord` unit and stores children in a `BTreeMap`; every instantiation in the crate is
/// `KeyTrie<u8>`, so this port fixes the unit to a byte with a fixed 256-slot child table
/// (iteration ascending by byte, matching `BTreeMap` order). Child nodes are allocated
/// from `build`'s allocator and freed by [`deinit`].
pub const KeyTrie = struct {
    is_terminal: bool = false,
    children: [256]?*KeyTrie = @splat(null),

    /// Builds the trie of `keys`, each given as its sequence of units (bytes).
    pub fn build(allocator: Allocator, keys: []const []const u8) Allocator.Error!KeyTrie {
        var root = KeyTrie{};
        for (keys) |key| {
            var node = &root;
            for (key) |unit| {
                if (node.children[unit] == null) {
                    const child = try allocator.create(KeyTrie);
                    child.* = KeyTrie{};
                    node.children[unit] = child;
                }
                node = node.children[unit].?;
            }
            node.is_terminal = true;
        }
        return root;
    }

    /// Frees the child nodes (the root itself is caller-owned).
    pub fn deinit(self: *KeyTrie, allocator: Allocator) void {
        for (&self.children) |*slot| {
            if (slot.*) |child| {
                child.deinit(allocator);
                allocator.destroy(child);
                slot.* = null;
            }
        }
    }
};
