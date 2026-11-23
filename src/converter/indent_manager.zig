//! Manages indentation and separators while emitting JSON-shaped grammars
//! (`indent_manager.rs`).
//!
//! Depending on the whitespace mode it emits either flexible whitespace char-classes
//! (`any_whitespace`), fixed separators, or newline-plus-indent strings. The fragments are
//! EBNF snippets that the converter turns into grammar expressions.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Produces the separator/whitespace fragments for array and object generation. All
/// fragments are allocated from `self.allocator` and live as long as it (the owning
/// converter's arena).
pub const IndentManager = struct {
    allocator: Allocator,
    any_whitespace: bool,
    enable_newline: bool,
    indent: i32,
    separator: []const u8,
    total_indent: i32 = 0,
    is_first: std.ArrayList(bool) = .empty,
    max_whitespace_cnt: ?i32,

    /// Creates an indent manager. `indent` enables newline+indent output; `separator` is
    /// the item separator (e.g. `,` or `, `). `max_whitespace_cnt` must be positive when
    /// set.
    pub fn init(
        allocator: Allocator,
        indent: ?i32,
        separator: []const u8,
        any_whitespace: bool,
        max_whitespace_cnt: ?i32,
    ) Allocator.Error!IndentManager {
        var self = IndentManager{
            .allocator = allocator,
            .any_whitespace = any_whitespace,
            .enable_newline = indent != null,
            .indent = indent orelse 0,
            .separator = try allocator.dupe(u8, separator),
            .max_whitespace_cnt = max_whitespace_cnt,
        };
        try self.is_first.append(allocator, true);
        return self;
    }

    pub fn deinit(self: *IndentManager) void {
        self.allocator.free(self.separator);
        self.is_first.deinit(self.allocator);
    }

    /// The JSON whitespace character class, optionally bounded to `max_whitespace_cnt`.
    pub fn whitespace_pattern(allocator: Allocator, max_whitespace_cnt: ?i32) Allocator.Error![]u8 {
        if (max_whitespace_cnt) |n| {
            return std.fmt.allocPrint(allocator, "[ \\n\\r\\t]{{0,{d}}}", .{n});
        }
        return allocator.dupe(u8, "[ \\n\\r\\t]*");
    }

    pub fn start_indent(self: *IndentManager) Allocator.Error!void {
        self.total_indent += self.indent;
        try self.is_first.append(self.allocator, true);
    }

    pub fn end_indent(self: *IndentManager) void {
        self.total_indent -= self.indent;
        _ = self.is_first.pop();
    }

    pub fn start_separator(self: *IndentManager) Allocator.Error![]u8 {
        if (self.any_whitespace) {
            return whitespace_pattern(self.allocator, self.max_whitespace_cnt);
        }
        if (!self.enable_newline) {
            return self.allocator.dupe(u8, "\"\"");
        }
        return std.fmt.allocPrint(self.allocator, "\"\\n{s}\"", .{spaces(self.allocator, @max(self.total_indent, 0)) catch |e| return e});
    }

    pub fn middle_separator(self: *IndentManager) Allocator.Error![]u8 {
        if (self.any_whitespace) {
            const ws = try whitespace_pattern(self.allocator, self.max_whitespace_cnt);
            defer self.allocator.free(ws);
            return std.fmt.allocPrint(self.allocator, "{s} \"{s}\" {s}", .{ ws, self.separator, ws });
        }
        if (!self.enable_newline) {
            return std.fmt.allocPrint(self.allocator, "\"{s}\"", .{self.separator});
        }
        return std.fmt.allocPrint(self.allocator, "\"{s}\\n{s}\"", .{ self.separator, spaces(self.allocator, @max(self.total_indent, 0)) catch |e| return e });
    }

    pub fn end_separator(self: *IndentManager) Allocator.Error![]u8 {
        if (self.any_whitespace) {
            return whitespace_pattern(self.allocator, self.max_whitespace_cnt);
        }
        if (!self.enable_newline) {
            return self.allocator.dupe(u8, "\"\"");
        }
        return std.fmt.allocPrint(self.allocator, "\"\\n{s}\"", .{spaces(self.allocator, @max(self.total_indent - self.indent, 0)) catch |e| return e});
    }

    pub fn empty_separator(self: *IndentManager) Allocator.Error![]u8 {
        if (self.any_whitespace) {
            return whitespace_pattern(self.allocator, self.max_whitespace_cnt);
        }
        return self.allocator.dupe(u8, "\"\"");
    }

    pub fn next_separator(self: *IndentManager, is_end: bool) Allocator.Error![]u8 {
        const is_first = &self.is_first.items[self.is_first.items.len - 1];
        if (self.any_whitespace) {
            const was_first = is_first.*;
            is_first.* = false;
            const ws = try whitespace_pattern(self.allocator, self.max_whitespace_cnt);
            defer self.allocator.free(ws);
            if (was_first or is_end) {
                return self.allocator.dupe(u8, ws);
            }
            return std.fmt.allocPrint(self.allocator, "{s} \"{s}\" {s}", .{ ws, self.separator, ws });
        }

        var res: std.ArrayList(u8) = .empty;
        defer res.deinit(self.allocator);
        if (!is_first.* and !is_end) {
            try res.appendSlice(self.allocator, self.separator);
        }
        is_first.* = false;

        if (self.enable_newline) {
            try res.appendSlice(self.allocator, "\\n");
        }

        const pad = if (is_end)
            self.total_indent - self.indent
        else
            self.total_indent;
        const pad_str = try spaces(self.allocator, @max(pad, 0));
        defer self.allocator.free(pad_str);
        try res.appendSlice(self.allocator, pad_str);

        return std.fmt.allocPrint(self.allocator, "\"{s}\"", .{res.items});
    }
};

/// `n` spaces (the Rust `" ".repeat(n)`); the caller frees.
pub fn spaces(allocator: Allocator, n: i32) Allocator.Error![]u8 {
    const out = try allocator.alloc(u8, @intCast(n));
    @memset(out, ' ');
    return out;
}
