//! A Lark rule or terminal definition (`lark_definition.rs`).

const std = @import("std");
const lark_location = @import("lark_location.zig");
const lark_node = @import("lark_node.zig");
const LarkLocation = lark_location.LarkLocation;
const LarkNode = lark_node.LarkNode;

/// A rule (`name: ...`) or terminal (`NAME: ...`) definition with its attributes. All payloads
/// live in the owning document's arena.
pub const LarkDefinition = struct {
    /// The name without a `!`/`?` prefix.
    name: []const u8,
    /// Whether the name denotes a terminal (uppercase after an optional `_`).
    is_terminal: bool,
    /// The `lazy` attribute.
    lazy: bool = false,
    /// The `suffix=` marker.
    suffix: ?LarkNode = null,
    /// The `stop=` marker.
    stop: ?LarkNode = null,
    /// The `stop_capture=` name.
    stop_capture_name: ?[]const u8 = null,
    /// The `temperature=` value.
    temperature: ?f32 = null,
    /// The `max_tokens=` value and the location of its key.
    max_tokens: ?MaxTokens = null,
    /// The `max_chars=` value.
    max_chars: ?i32 = null,
    /// The capture name and the location of its value.
    capture_name: ?CaptureName = null,
    /// The definition body.
    body: LarkNode,
    /// Where the name starts.
    location: LarkLocation,

    /// Rust tuple `(i32, LarkLocation)`.
    pub const MaxTokens = struct {
        value: i32,
        key_location: LarkLocation,
    };

    /// Rust tuple `(String, LarkLocation)`.
    pub const CaptureName = struct {
        name: []const u8,
        value_location: LarkLocation,
    };

    /// Creates a definition without attributes.
    pub fn new(name: []const u8, is_terminal: bool, body: LarkNode, location: LarkLocation) LarkDefinition {
        return .{
            .name = name,
            .is_terminal = is_terminal,
            .body = body,
            .location = location,
        };
    }

    /// Whether the rule is lazy or carries a suffix or stop marker.
    pub fn has_lazy_semantics(self: *const LarkDefinition) bool {
        return self.lazy or self.suffix != null or self.stop != null;
    }

    /// Deep copy into `allocator` (Rust `Clone`).
    pub fn clone(self: *const LarkDefinition, allocator: std.mem.Allocator) std.mem.Allocator.Error!LarkDefinition {
        var definition = LarkDefinition.new(try allocator.dupe(u8, self.name), self.is_terminal, try self.body.clone(allocator), self.location);
        definition.lazy = self.lazy;
        if (self.suffix) |suffix| definition.suffix = try suffix.clone(allocator);
        if (self.stop) |stop| definition.stop = try stop.clone(allocator);
        if (self.stop_capture_name) |name| definition.stop_capture_name = try allocator.dupe(u8, name);
        definition.temperature = self.temperature;
        definition.max_tokens = self.max_tokens;
        definition.max_chars = self.max_chars;
        if (self.capture_name) |capture| definition.capture_name = .{
            .name = try allocator.dupe(u8, capture.name),
            .value_location = capture.value_location,
        };
        return definition;
    }
};
