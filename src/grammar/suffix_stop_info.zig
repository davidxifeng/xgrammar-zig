//! Sparse per-rule metadata used to materialize suffix and stop captures
//! (`suffix_stop_info.rs`).

const std = @import("std");

/// Suffix/stop capture metadata attached to one rule.
pub const SuffixStopInfo = struct {
    /// The rule carrying this metadata.
    rule_id: i32,
    /// Trailing bytes hidden only from this rule's own capture.
    hidden_suffix_bytes: i32,
    /// Trailing bytes hidden from this rule and every enclosing capture.
    hidden_stop_bytes: i32,
    /// Helper rule matching the body before a variable-length marker. A self-reference marks a
    /// zero-width event immediately following a fixed dynamic-dispatch marker.
    body_rule_id: i32,
    /// Helper rule matching a variable-length marker.
    marker_rule_id: i32,
    /// Capture name for the marker bytes.
    stop_capture_name: []const u8,

    /// Rust `Default`.
    pub fn default() SuffixStopInfo {
        return .{
            .rule_id = -1,
            .hidden_suffix_bytes = 0,
            .hidden_stop_bytes = 0,
            .body_rule_id = -1,
            .marker_rule_id = -1,
            .stop_capture_name = "",
        };
    }

    /// Whether the metadata carries no information (and is therefore not stored).
    pub fn is_empty(self: SuffixStopInfo) bool {
        return self.hidden_suffix_bytes == 0 and self.hidden_stop_bytes == 0 and
            self.body_rule_id == -1 and self.marker_rule_id == -1 and
            self.stop_capture_name.len == 0;
    }

    /// Rust `PartialEq` (string compared by content).
    pub fn eql(a: SuffixStopInfo, b: SuffixStopInfo) bool {
        return a.rule_id == b.rule_id and a.hidden_suffix_bytes == b.hidden_suffix_bytes and
            a.hidden_stop_bytes == b.hidden_stop_bytes and a.body_rule_id == b.body_rule_id and
            a.marker_rule_id == b.marker_rule_id and
            std.mem.eql(u8, a.stop_capture_name, b.stop_capture_name);
    }
};

/// Result of the shared `binary_search_by_key(&rule_id)` lookups over a rule-id-sorted
/// info table: `found` mirrors `Ok(index)`, otherwise `index` is the insertion point
/// (Rust `Err(index)`).
pub const SearchResult = struct {
    found: bool,
    index: usize,
};

/// Binary search over an info table sorted by ascending `rule_id`.
pub fn search_by_rule_id(items: []const SuffixStopInfo, rule_id: i32) SearchResult {
    var low: usize = 0;
    var high: usize = items.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (items[mid].rule_id < rule_id) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return .{ .found = low < items.len and items[low].rule_id == rule_id, .index = low };
}

test "suffix stop info default and emptiness" {
    const d = SuffixStopInfo.default();
    try std.testing.expect(d.is_empty());
    var info = d;
    info.hidden_suffix_bytes = 3;
    try std.testing.expect(!info.is_empty());
    info.hidden_suffix_bytes = 0;
    info.stop_capture_name = "stop";
    try std.testing.expect(!info.is_empty());
    try std.testing.expect(info.eql(info));
}

test "search by rule id" {
    const items = [_]SuffixStopInfo{
        .{ .rule_id = 2, .hidden_suffix_bytes = 1, .hidden_stop_bytes = 0, .body_rule_id = -1, .marker_rule_id = -1, .stop_capture_name = "" },
        .{ .rule_id = 5, .hidden_suffix_bytes = 0, .hidden_stop_bytes = 2, .body_rule_id = -1, .marker_rule_id = -1, .stop_capture_name = "" },
    };
    try std.testing.expectEqual(SearchResult{ .found = true, .index = 0 }, search_by_rule_id(&items, 2));
    try std.testing.expectEqual(SearchResult{ .found = true, .index = 1 }, search_by_rule_id(&items, 5));
    try std.testing.expectEqual(SearchResult{ .found = false, .index = 1 }, search_by_rule_id(&items, 3));
    try std.testing.expectEqual(SearchResult{ .found = false, .index = 2 }, search_by_rule_id(&items, 9));
    try std.testing.expectEqual(SearchResult{ .found = false, .index = 0 }, search_by_rule_id(&items, 0));
}
