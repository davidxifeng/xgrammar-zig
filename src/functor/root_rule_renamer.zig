//! Renames the root rule to `root` (`root_rule_renamer.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_mod = @import("grammar/mod.zig");
const Grammar = grammar_mod.Grammar;

/// Ensures the root rule is named `root`. If another rule already has that name, it is
/// renamed to the first free `root_N`. The result is a fresh clone; the input is untouched.
pub fn root_rule_renamer(allocator: Allocator, grammar: *const Grammar) Allocator.Error!*Grammar {
    if (std.mem.eql(u8, grammar.root_rule().name, "root")) {
        return grammar.clone(allocator);
    }

    var names = std.StringHashMap(void).init(allocator);
    defer names.deinit();
    for (grammar.rules.items) |r| try names.put(r.name, {});

    var collision: ?i32 = null;
    for (grammar.rules.items, 0..) |r, i| {
        if (std.mem.eql(u8, r.name, "root")) {
            collision = @intCast(i);
            break;
        }
    }

    const renamed = try grammar.clone(allocator);
    errdefer renamed.deinit();
    const root_id = renamed.root_rule_id;
    try renamed.rename_rule(root_id, "root");

    if (collision) |collision_id| {
        var i: usize = 0;
        while (i <= @as(usize, @intCast(grammar.num_rules()))) : (i += 1) {
            var buf: [32]u8 = undefined;
            const candidate = try std.fmt.bufPrint(&buf, "root_{d}", .{i});
            if (!names.contains(candidate)) {
                try renamed.rename_rule(collision_id, candidate);
                break;
            }
        }
    }
    return renamed;
}

test "root rule renamer without and with collision" {
    const gpa = std.testing.allocator;
    const grammar_builder_mod = @import("grammar/mod.zig").grammar_builder;
    const GrammarBuilder = grammar_builder_mod.GrammarBuilder;
    {
        var builder = try GrammarBuilder.new(gpa);
        defer builder.deinit();
        const bs = try builder.add_byte_string("a");
        _ = try builder.add_rule_named("main", bs);
        const grammar = try builder.into_grammar(gpa, "main", null);
        defer grammar.deinit();
        const renamed = try root_rule_renamer(gpa, grammar);
        defer renamed.deinit();
        try std.testing.expectEqualStrings("root", renamed.root_rule().name);
        try std.testing.expectEqualStrings("main", grammar.root_rule().name);
    }
    {
        var builder = try GrammarBuilder.new(gpa);
        defer builder.deinit();
        const bs = try builder.add_byte_string("a");
        _ = try builder.add_rule_named("root", bs);
        const bs2 = try builder.add_byte_string("b");
        _ = try builder.add_rule_named("other", bs2);
        const grammar = try builder.into_grammar(gpa, "other", null);
        defer grammar.deinit();
        const renamed = try root_rule_renamer(gpa, grammar);
        defer renamed.deinit();
        // `other` becomes root; the old `root` is renamed to the first free root_N.
        try std.testing.expectEqualStrings("root", renamed.root_rule().name);
        try std.testing.expectEqualStrings("root_1", renamed.rule(0).name);
        try std.testing.expectEqualStrings("other", renamed.rule(2).name);
    }
}
