//! The marker that ends a lazy Lark rule (`lark_trigger.rs`).

const std = @import("std");

/// A lazy-rule trigger: a fixed string or a set of token ids.
pub const LarkTrigger = union(enum) {
    /// A fixed byte string.
    string: []const u8,
    /// A set of token ids.
    token: []const i32,

    pub fn eql(a: LarkTrigger, b: LarkTrigger) bool {
        if (@as(std.meta.Tag(LarkTrigger), a) != @as(std.meta.Tag(LarkTrigger), b)) return false;
        return switch (a) {
            .string => |s| std.mem.eql(u8, s, b.string),
            .token => |t| std.mem.eql(i32, t, b.token),
        };
    }

    /// Hashes the payload only (used as a map key; callers mix in nothing else).
    pub fn hash(self: LarkTrigger, hasher: anytype) void {
        switch (self) {
            .string => |s| {
                hasher.update("s");
                hasher.update(s);
            },
            .token => |t| {
                hasher.update("t");
                for (t) |id| {
                    var buf: [4]u8 = undefined;
                    std.mem.writeInt(i32, &buf, id, .little);
                    hasher.update(&buf);
                }
            },
        }
    }
};
