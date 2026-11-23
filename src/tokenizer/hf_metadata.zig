//! Hugging Face `tokenizer.json` metadata detection.
//!
//! Note: the reference gates all consumers of the `tokenizers` crate behind a
//! feature; this file only contains the JSON-analysis paths (port of
//! `hf_metadata.rs` without any `tokenizers` dependency).

const std = @import("std");
const Allocator = std.mem.Allocator;

const vocab_type = @import("vocab_type.zig");
const json_parse = @import("../support/json_parse.zig");

pub const VocabType = vocab_type.VocabType;

/// Metadata extracted from a Hugging Face tokenizer backend JSON string.
pub const HfMetadata = struct {
    /// Detected vocabulary encoding type.
    vocab_type: VocabType,
    /// Whether a prefix space is added during tokenization.
    add_prefix_space: bool,
};

pub const DetectError = error{
    /// The backend string is not valid JSON.
    InvalidJson,
    /// The JSON root is not an object.
    RootNotObject,
    OutOfMemory,
};

/// Detects vocabulary type and prefix-space behavior from a HF backend JSON string.
pub fn detect_metadata_from_hf(allocator: Allocator, backend_str: []const u8) DetectError!HfMetadata {
    const value = json_parse.parse_json(allocator, backend_str) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // DepthExceeded is reported like any other parse failure (Rust: Err(String)).
        else => return error.InvalidJson,
    };
    const object = switch (value) {
        .object => |o| o,
        else => return error.RootNotObject,
    };
    return .{
        .vocab_type = detect_vocab_type(object),
        .add_prefix_space = detect_add_prefix_space(object) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
        },
    };
}

/// Serializes [`HfMetadata`] to the JSON string expected by
/// [`TokenizerInfo.from_vocab_and_metadata`](tokenizer_info.zig).
/// Keys are emitted in serde_json's (BTreeMap, lexicographic) order.
pub fn metadata_to_json(allocator: Allocator, metadata: HfMetadata) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"add_prefix_space\":{},\"vocab_type\":{}}}", .{
        metadata.add_prefix_space,
        @intFromEnum(metadata.vocab_type),
    });
}

fn get_object(object: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const v = object.get(key) orelse return null;
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

fn get_str(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = object.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn detect_vocab_type(object: std.json.ObjectMap) VocabType {
    const decoder = get_object(object, "decoder") orelse return .Raw;
    const decoder_type = get_str(decoder, "type") orelse return .Raw;
    if (std.mem.eql(u8, decoder_type, "Sequence")) {
        var i: usize = 0;
        if (decoder.get("decoders")) |decoders_value| {
            switch (decoders_value) {
                .array => |items| {
                    while (i < items.items.len) : (i += 1) {
                        if (detect_decoder_kind(items.items[i])) |kind| return kind;
                    }
                },
                else => {},
            }
        }
        return .Raw;
    }
    if (detect_decoder_kind(object.get("decoder") orelse .null)) |kind| return kind;
    return .Raw;
}

/// Returns the vocab type contributed by one decoder entry, if any.
fn detect_decoder_kind(decoder: std.json.Value) ?VocabType {
    const decoder_obj = switch (decoder) {
        .object => |o| o,
        else => return null,
    };
    const kind = get_str(decoder_obj, "type") orelse return null;
    if (std.mem.eql(u8, kind, "ByteLevel")) return .ByteLevel;
    if (std.mem.eql(u8, kind, "ByteFallback")) return .ByteFallback;
    return null;
}

fn detect_add_prefix_space(object: std.json.ObjectMap) error{OutOfMemory}!bool {
    if (try detect_prepend_normalizer(object)) return true;
    return detect_metaspace_pre_tokenizer(object);
}

fn is_prepend_block(normalizer: std.json.Value) bool {
    const normalizer_obj = switch (normalizer) {
        .object => |o| o,
        else => return false,
    };
    const t = get_str(normalizer_obj, "type") orelse return false;
    if (!std.mem.eql(u8, t, "Prepend")) return false;
    const prepend = get_str(normalizer_obj, "prepend") orelse return false;
    return std.mem.eql(u8, prepend, "▁");
}

fn detect_prepend_normalizer(object: std.json.ObjectMap) error{OutOfMemory}!bool {
    const normalizer = get_object(object, "normalizer") orelse return false;
    const normalizer_type = get_str(normalizer, "type") orelse return false;
    if (std.mem.eql(u8, normalizer_type, "Sequence")) {
        if (normalizer.get("normalizers")) |normalizers_value| {
            switch (normalizers_value) {
                .array => |items| {
                    for (items.items) |item| {
                        if (is_prepend_block(item)) return true;
                    }
                },
                else => {},
            }
        }
        return false;
    }
    return is_prepend_block(object.get("normalizer") orelse .null);
}

fn detect_metaspace_pre_tokenizer(object: std.json.ObjectMap) bool {
    const pre_tokenizer = get_object(object, "pre_tokenizer") orelse return false;
    const kind = get_str(pre_tokenizer, "type") orelse return false;
    const scheme = get_str(pre_tokenizer, "prepend_scheme") orelse return false;
    return std.mem.eql(u8, kind, "Metaspace") and
        (std.mem.eql(u8, scheme, "always") or std.mem.eql(u8, scheme, "first"));
}

test "detect byte level" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const backend =
        \\{"decoder":{"type":"ByteLevel"},"pre_tokenizer":{"type":"Metaspace","prepend_scheme":"always"},"model":{"type":"BPE"}}
    ;
    const meta = try detect_metadata_from_hf(a, backend);
    try std.testing.expectEqual(VocabType.ByteLevel, meta.vocab_type);
    try std.testing.expect(meta.add_prefix_space);
    const json = try metadata_to_json(a, meta);
    try std.testing.expectEqualStrings(
        "{\"add_prefix_space\":true,\"vocab_type\":2}",
        json,
    );
}

test "detect byte fallback via sequence decoder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const backend =
        \\{"decoder":{"type":"Sequence","decoders":[{"type":"Replace"},{"type":"ByteFallback"},{"type":"Fuse"}]},"normalizer":{"type":"Sequence","normalizers":[{"type":"Prepend","prepend":"▁"}]}}
    ;
    const meta = try detect_metadata_from_hf(a, backend);
    try std.testing.expectEqual(VocabType.ByteFallback, meta.vocab_type);
    try std.testing.expect(meta.add_prefix_space);
}

test "detect raw defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const meta = try detect_metadata_from_hf(a, "{}");
    try std.testing.expectEqual(VocabType.Raw, meta.vocab_type);
    try std.testing.expect(!meta.add_prefix_space);
    try std.testing.expectError(error.RootNotObject, detect_metadata_from_hf(a, "[]"));
    try std.testing.expectError(error.InvalidJson, detect_metadata_from_hf(a, "not json"));
    // prepend normalizer with a non-▁ char does not count
    const meta2 = try detect_metadata_from_hf(
        a,
        "{\"normalizer\":{\"type\":\"Prepend\",\"prepend\":\" \"}}",
    );
    try std.testing.expect(!meta2.add_prefix_space);
}
