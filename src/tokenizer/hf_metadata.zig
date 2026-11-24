//! Hugging Face `tokenizer.json` metadata detection.
//!
//! Note: the reference gates all consumers of the `tokenizers` crate behind a
//! feature; this file only contains the JSON-analysis paths (port of
//! `hf_metadata.rs` without any `tokenizers` dependency).

const std = @import("std");
const Allocator = std.mem.Allocator;

const json_parse = @import("../support/json_parse.zig");
pub const VocabType = @import("../tokenizer.zig").VocabType;

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
/// Frees all temporary JSON DOM allocations before returning.
pub fn detectMetadataFromHf(allocator: Allocator, backend_str: []const u8) DetectError!HfMetadata {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();

    const value = json_parse.parseJson(scratch.allocator(), backend_str) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // DepthExceeded is reported like any other parse failure (Rust: Err(String)).
        else => return error.InvalidJson,
    };
    const object = switch (value) {
        .object => |o| o,
        else => return error.RootNotObject,
    };
    return .{
        .vocab_type = detectVocabType(object),
        .add_prefix_space = detectAddPrefixSpace(object),
    };
}

/// Serializes `HfMetadata` to the JSON string expected by `TokenizerInfo.fromVocabAndMetadata`.
/// Keys are emitted in lexicographic order.
pub fn metadataToJson(allocator: Allocator, metadata: HfMetadata) Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"add_prefix_space\":{},\"vocab_type\":{}}}", .{
        metadata.add_prefix_space,
        @backingInt(metadata.vocab_type),
    });
}

fn getObject(object: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const v = object.get(key) orelse return null;
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

fn getStr(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = object.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn detectVocabType(object: std.json.ObjectMap) VocabType {
    const decoder = getObject(object, "decoder") orelse return .raw;
    const decoder_type = getStr(decoder, "type") orelse return .raw;
    if (std.mem.eql(u8, decoder_type, "Sequence")) {
        if (decoder.get("decoders")) |decoders_value| {
            switch (decoders_value) {
                .array => |items| {
                    for (items.items) |item| {
                        if (detectDecoderKind(item)) |kind| return kind;
                    }
                },
                else => {},
            }
        }
        return .raw;
    }
    if (detectDecoderKind(object.get("decoder") orelse .null)) |kind| return kind;
    return .raw;
}

/// Returns the vocab type contributed by one decoder entry, if any.
fn detectDecoderKind(decoder: std.json.Value) ?VocabType {
    const decoder_obj = switch (decoder) {
        .object => |o| o,
        else => return null,
    };
    const kind = getStr(decoder_obj, "type") orelse return null;
    if (std.mem.eql(u8, kind, "ByteLevel")) return .byte_level;
    if (std.mem.eql(u8, kind, "ByteFallback")) return .byte_fallback;
    return null;
}

fn detectAddPrefixSpace(object: std.json.ObjectMap) bool {
    if (detectPrependNormalizer(object)) return true;
    return detectMetaspacePreTokenizer(object);
}

fn isPrependBlock(normalizer: std.json.Value) bool {
    const normalizer_obj = switch (normalizer) {
        .object => |o| o,
        else => return false,
    };
    const t = getStr(normalizer_obj, "type") orelse return false;
    if (!std.mem.eql(u8, t, "Prepend")) return false;
    const prepend = getStr(normalizer_obj, "prepend") orelse return false;
    return std.mem.eql(u8, prepend, "▁");
}

fn detectPrependNormalizer(object: std.json.ObjectMap) bool {
    const normalizer = getObject(object, "normalizer") orelse return false;
    const normalizer_type = getStr(normalizer, "type") orelse return false;
    if (std.mem.eql(u8, normalizer_type, "Sequence")) {
        if (normalizer.get("normalizers")) |normalizers_value| {
            switch (normalizers_value) {
                .array => |items| {
                    for (items.items) |item| {
                        if (isPrependBlock(item)) return true;
                    }
                },
                else => {},
            }
        }
        return false;
    }
    return isPrependBlock(object.get("normalizer") orelse .null);
}

fn detectMetaspacePreTokenizer(object: std.json.ObjectMap) bool {
    const pre_tokenizer = getObject(object, "pre_tokenizer") orelse return false;
    const kind = getStr(pre_tokenizer, "type") orelse return false;
    const scheme = getStr(pre_tokenizer, "prepend_scheme") orelse return false;
    return std.mem.eql(u8, kind, "Metaspace") and
        (std.mem.eql(u8, scheme, "always") or std.mem.eql(u8, scheme, "first"));
}

test "detect byte level without arena" {
    const a = std.testing.allocator;
    const backend =
        \\{"decoder":{"type":"ByteLevel"},"pre_tokenizer":{"type":"Metaspace","prepend_scheme":"always"},"model":{"type":"BPE"}}
    ;
    const meta = try detectMetadataFromHf(a, backend);
    try std.testing.expectEqual(VocabType.byte_level, meta.vocab_type);
    try std.testing.expect(meta.add_prefix_space);
    const json = try metadataToJson(a, meta);
    defer a.free(json);
    try std.testing.expectEqualStrings(
        "{\"add_prefix_space\":true,\"vocab_type\":2}",
        json,
    );
}

test "detect byte fallback via sequence decoder without arena" {
    const a = std.testing.allocator;
    const backend =
        \\{"decoder":{"type":"Sequence","decoders":[{"type":"Replace"},{"type":"ByteFallback"},{"type":"Fuse"}]},"normalizer":{"type":"Sequence","normalizers":[{"type":"Prepend","prepend":"▁"}]}}
    ;
    const meta = try detectMetadataFromHf(a, backend);
    try std.testing.expectEqual(VocabType.byte_fallback, meta.vocab_type);
    try std.testing.expect(meta.add_prefix_space);
}

test "detect raw defaults without arena" {
    const a = std.testing.allocator;
    const meta = try detectMetadataFromHf(a, "{}");
    try std.testing.expectEqual(VocabType.raw, meta.vocab_type);
    try std.testing.expect(!meta.add_prefix_space);
    try std.testing.expectError(error.RootNotObject, detectMetadataFromHf(a, "[]"));
    try std.testing.expectError(error.InvalidJson, detectMetadataFromHf(a, "not json"));
    // prepend normalizer with a non-▁ char does not count
    const meta2 = try detectMetadataFromHf(
        a,
        "{\"normalizer\":{\"type\":\"Prepend\",\"prepend\":\" \"}}",
    );
    try std.testing.expect(!meta2.add_prefix_space);
}
