//! Precomputes tag-dispatch second-slicing bitsets (`tag_dispatch_optimization.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const grammar_mod = @import("../grammar/mod.zig");
const Grammar = grammar_mod.Grammar;
const GrammarExprType = grammar_mod.GrammarExprType;
const support = @import("../support/mod.zig");
const DynamicBitset = support.DynamicBitset;
const tokenizer_mod = @import("../tokenizer/mod.zig");
const TokenizerInfo = tokenizer_mod.tokenizer_info.TokenizerInfo;

/// Maps tag-dispatch rule ids to bitsets over sorted-vocab indices: tokens whose suffix
/// (from the second byte onward) contains no trigger or exclude string are marked true.
pub const TagDispatchSecondSlicingBitsets = struct {
    allocator: Allocator,
    map: std.AutoHashMapUnmanaged(i32, DynamicBitset),

    pub fn deinit(self: *TagDispatchSecondSlicingBitsets) void {
        var it = self.map.valueIterator();
        while (it.next()) |bs| {
            bs.deinit();
        }
        self.map.deinit(self.allocator);
    }

    pub fn contains(self: *const TagDispatchSecondSlicingBitsets, rule_id: i32) bool {
        return self.map.contains(rule_id);
    }

    pub fn get(self: *const TagDispatchSecondSlicingBitsets, rule_id: i32) ?*const DynamicBitset {
        return self.map.getPtr(rule_id);
    }
};

/// Builds the tag-dispatch second-slicing map for `grammar` and `tokenizer_info`.
pub fn tag_dispatch_optimization(
    allocator: Allocator,
    grammar: *const Grammar,
    tokenizer_info: *const TokenizerInfo,
) Allocator.Error!TagDispatchSecondSlicingBitsets {
    const sorted_decoded_vocab = tokenizer_info.sorted_decoded_vocab;
    var map: std.AutoHashMapUnmanaged(i32, DynamicBitset) = .empty;
    errdefer {
        var it = map.valueIterator();
        while (it.next()) |bs| {
            bs.deinit();
        }
        map.deinit(allocator);
    }

    var rule_id: i32 = 0;
    while (rule_id < grammar.num_rules()) : (rule_id += 1) {
        const rule = grammar.rule(rule_id);
        const rule_body = grammar.expr(rule.body_expr_id);
        if (rule_body.ty != GrammarExprType.TagDispatch) {
            continue;
        }
        var tag_dispatch = try grammar_mod.tag_dispatch.tag_dispatch(grammar, allocator, rule.body_expr_id);
        defer tag_dispatch.deinit(allocator);

        var definite_accepted = try DynamicBitset.init(allocator, sorted_decoded_vocab.len);
        errdefer definite_accepted.deinit();

        for (sorted_decoded_vocab, 0..) |entry, j| {
            const token = entry.token;
            if (token.len == 0) {
                definite_accepted.set(j, true);
                continue;
            }

            var definite_accept_since_second_char = true;
            for (tag_dispatch.tag_rule_pairs.items) |pair| {
                if (contains_from_second(token, pair.tag)) {
                    definite_accept_since_second_char = false;
                    break;
                }
            }
            if (definite_accept_since_second_char) {
                for (tag_dispatch.excludes.items) |excl| {
                    if (contains_from_second(token, excl)) {
                        definite_accept_since_second_char = false;
                        break;
                    }
                }
            }

            if (definite_accept_since_second_char) {
                definite_accepted.set(j, true);
            }
        }

        try map.put(allocator, rule_id, definite_accepted);
    }

    return .{ .allocator = allocator, .map = map };
}

fn contains_from_second(token: []const u8, pattern: []const u8) bool {
    if (pattern.len == 0 or token.len <= 1) {
        return false;
    }
    return std.mem.indexOf(u8, token[1..], pattern) != null;
}
