//! Intermediate representation for macro arguments (`macro_ir.rs`).
//!
//! String payloads are allocator-owned slices (duplicated by the EBNF parser; the consumer
//! frees them, e.g. via an arena).

const std = @import("std");

/// A parsed macro argument value: a string, integer, boolean, identifier, or tuple of
/// nested values.
pub const MacroValue = union(enum) {
    /// A string literal.
    Str: []const u8,
    /// An integer literal.
    Int: i64,
    /// A boolean literal.
    Bool: bool,
    /// A bare identifier (a rule reference).
    Identifier: []const u8,
    /// A parenthesized tuple of values.
    Tuple: std.ArrayList(MacroValue),

    /// Rust `PartialEq`.
    pub fn eql(a: MacroValue, b: MacroValue) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .Str => |s| std.mem.eql(u8, s, b.Str),
            .Int => |v| v == b.Int,
            .Bool => |v| v == b.Bool,
            .Identifier => |s| std.mem.eql(u8, s, b.Identifier),
            .Tuple => |t| {
                if (t.items.len != b.Tuple.items.len) return false;
                for (t.items, b.Tuple.items) |x, y| {
                    if (!x.eql(y)) return false;
                }
                return true;
            },
        };
    }

    /// Deep clone (tuple contents copied).
    pub fn clone(self: MacroValue, gpa: std.mem.Allocator) std.mem.Allocator.Error!MacroValue {
        return switch (self) {
            .Str => |s| .{ .Str = try gpa.dupe(u8, s) },
            .Int => |v| .{ .Int = v },
            .Bool => |v| .{ .Bool = v },
            .Identifier => |s| .{ .Identifier = try gpa.dupe(u8, s) },
            .Tuple => |t| .{ .Tuple = try t.clone(gpa) },
        };
    }

    /// Releases the payload (arena users need not call this).
    pub fn deinit(self: *MacroValue, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .Str, .Identifier => |s| gpa.free(s),
            .Tuple => |*t| t.deinit(gpa),
            else => {},
        }
    }
};

/// One named macro argument (Rust tuple `(String, MacroValue)`).
pub const NamedArgument = struct {
    name: []const u8,
    value: MacroValue,
};

/// The positional and named arguments of a macro call.
pub const MacroArguments = struct {
    /// Positional arguments, in order.
    positional: std.ArrayList(MacroValue) = .empty,
    /// Named arguments, in encounter order.
    named: std.ArrayList(NamedArgument) = .empty,

    /// Returns the value of the named argument `name`, if present.
    /// (Rust `MacroArguments::named`; renamed: the field owns the Rust name.)
    pub fn named_value(self: *const MacroArguments, name: []const u8) ?*const MacroValue {
        for (self.named.items) |*arg| {
            if (std.mem.eql(u8, arg.name, name)) return &arg.value;
        }
        return null;
    }

    /// Deep clone.
    pub fn clone(self: MacroArguments, gpa: std.mem.Allocator) std.mem.Allocator.Error!MacroArguments {
        var out = MacroArguments{
            .positional = try self.positional.clone(gpa),
            .named = .empty,
        };
        errdefer out.deinit(gpa);
        try out.named.ensureTotalCapacity(gpa, self.named.items.len);
        for (self.named.items) |arg| {
            out.named.appendAssumeCapacity(.{
                .name = try gpa.dupe(u8, arg.name),
                .value = try arg.value.clone(gpa),
            });
        }
        return out;
    }

    /// Releases both lists (arena users need not call this).
    pub fn deinit(self: *MacroArguments, gpa: std.mem.Allocator) void {
        self.positional.deinit(gpa);
        for (self.named.items) |*arg| {
            gpa.free(arg.name);
            arg.value.deinit(gpa);
        }
        self.named.deinit(gpa);
    }
};
