//! A parsed Lark grammar (`lark_document.rs`).

const std = @import("std");
const lark_definition = @import("lark_definition.zig");
const lark_import = @import("lark_import.zig");
const lark_location = @import("lark_location.zig");
const lark_node = @import("lark_node.zig");
const LarkDefinition = lark_definition.LarkDefinition;
const LarkImport = lark_import.LarkImport;
const LarkLocation = lark_location.LarkLocation;
const LarkNode = lark_node.LarkNode;

/// The items of a Lark grammar (or an inline `%lark { ... }` block). Everything is allocated
/// from the document's own arena; `deinit` frees the whole document (Rust relies on drop).
pub const LarkDocument = struct {
    arena: *std.heap.ArenaAllocator,
    /// Rule and terminal definitions, in source order.
    definitions: std.ArrayList(LarkDefinition) = .empty,
    /// `%ignore` expressions.
    ignores: std.ArrayList(LarkNode) = .empty,
    /// `%import` directives.
    imports: std.ArrayList(LarkImport) = .empty,
    /// `%grammar_options` values with their locations.
    options: std.ArrayList(Option) = .empty,

    /// One `%grammar_options` entry (Rust tuple `(Value, LarkLocation)`).
    pub const Option = struct {
        value: std.json.Value,
        location: LarkLocation,
    };

    /// An empty document owning a fresh arena under `backing`.
    pub fn create(backing: std.mem.Allocator) std.mem.Allocator!LarkDocument {
        const arena = try backing.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(backing);
        return .{ .arena = arena };
    }

    /// The document's allocation context (also the JSON value tree's owner).
    pub fn allocator(self: *const LarkDocument) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Frees the document and every node, string, and JSON value in it.
    pub fn deinit(self: *LarkDocument) void {
        const backing = self.arena.child_allocator;
        self.arena.deinit();
        backing.destroy(self.arena);
    }

    /// Deep copy under `backing` with a fresh arena (Rust `LarkDocument::clone`).
    pub fn deep_clone(backing: std.mem.Allocator, other: *const LarkDocument) std.mem.Allocator!LarkDocument {
        var document = try LarkDocument.create(backing);
        errdefer document.deinit();
        const a = document.allocator();
        try document.definitions.ensureTotalCapacity(a, other.definitions.items.len);
        for (other.definitions.items) |*definition| {
            document.definitions.appendAssumeCapacity(try definition.clone(a));
        }
        try document.ignores.ensureTotalCapacity(a, other.ignores.items.len);
        for (other.ignores.items) |*ignore| {
            document.ignores.appendAssumeCapacity(try ignore.clone(a));
        }
        try document.imports.ensureTotalCapacity(a, other.imports.items.len);
        for (other.imports.items) |item| {
            document.imports.appendAssumeCapacity(.{
                .path = try a.dupe(u8, item.path),
                .local_name = try a.dupe(u8, item.local_name),
                .location = item.location,
            });
        }
        try document.options.ensureTotalCapacity(a, other.options.items.len);
        for (other.options.items) |option| {
            document.options.appendAssumeCapacity(.{
                .value = try clone_json_value(a, option.value),
                .location = option.location,
            });
        }
        return document;
    }
};

/// Deep copy of a `std.json.Value` tree into `allocator` (the parse tree normally lives in
/// the source document's arena).
pub fn clone_json_value(allocator: std.mem.Allocator, value: std.json.Value) std.mem.Allocator!std.json.Value {
    return switch (value) {
        .null, .bool, .integer, .float, .number_string => value,
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |array| blk: {
            var out = try allocator.alloc(std.json.Value, array.items.len);
            for (array.items, 0..) |item, i| out[i] = try clone_json_value(allocator, item);
            break :blk .{ .array = .{ .items = out } };
        },
        .object => |object| blk: {
            var out = std.json.ObjectMap.init(allocator);
            var it = object.iterator();
            while (it.next()) |entry| {
                try out.put(try allocator.dupe(u8, entry.key_ptr.*), try clone_json_value(allocator, entry.value_ptr.*));
            }
            break :blk .{ .object = out };
        },
    };
}
