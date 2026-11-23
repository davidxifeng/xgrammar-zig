//! The tokenizer info class to handle tokenizer information for grammar-guided generation.

const std = @import("std");
const Allocator = std.mem.Allocator;

const vocab_type_mod = @import("vocab_type.zig");
const error_mod = @import("error.zig");
const token_decoder = @import("token_decoder.zig");
const hf_metadata = @import("hf_metadata.zig");
const encoding = @import("../support/encoding.zig");
const json_parse = @import("../support/json_parse.zig");
const config = @import("../config.zig");
const grammar_error = @import("../grammar/error.zig");

pub const VocabType = vocab_type_mod.VocabType;
pub const TokenizerError = error_mod.TokenizerError;
pub const TokenizerErrorInfo = error_mod.TokenizerErrorInfo;
pub const DeserializeError = grammar_error.DeserializeError;
pub const DeserializeErrorInfo = grammar_error.DeserializeErrorInfo;
/// Deserialization fallibility including allocation (mirrors the grammar wave's
/// `DeserializeErrorAll` shape).
pub const DeserializeErrorAll = DeserializeError || Allocator.Error;
pub const SERIALIZATION_VERSION = config.SERIALIZATION_VERSION;

const set_tokenizer_diag = error_mod.set_diag;

/// Tokens whose presence marks a stop token when explicit ids are not supplied.
const DETECTION_STOP_TOKENS: [8][]const u8 = .{
    "</s>",
    "<|end_of_text|>",
    "<|eot_id|>",
    "<|endoftext|>",
    "<eos>",
    "<|eos|>",
    "<end_of_turn>",
    "<｜end▁of▁sentence｜>",
};

/// An `(id, decoded)` pair of the lexicographically sorted vocabulary.
pub const SortedDecodedToken = struct {
    id: i32,
    token: []const u8,
};

/// The tokenizer info contains the vocabulary, the type of the vocabulary, and necessary
/// information for grammar-guided generation.
pub const TokenizerInfo = struct {
    /// Every top-level object holds its own arena; all internal data is allocated from it.
    /// Heap-allocated so the constructor can hand a stable mutable pointer.
    arena: *std.heap.ArenaAllocator,

    vocab_type: VocabType,
    vocab_size: i32,
    add_prefix_space: bool,
    decoded_vocab: []const []const u8,
    sorted_decoded_vocab: []const SortedDecodedToken,
    trie_subtree_nodes_range: []const i32,
    stop_token_ids: []const i32,
    special_token_ids: []const i32,
    token_id_to_sorted_vocab_index: []const i32,
    /// Unicode codepoint counts for the sorted decoded vocabulary.
    token_char_counts: []const i32,
    /// The maximum of `token_char_counts`.
    max_token_chars: i32,

    pub fn deinit(self: *TokenizerInfo) void {
        const parent = self.arena.child_allocator;
        self.arena.deinit();
        parent.destroy(self.arena);
    }

    /// Constructs the tokenizer info.
    ///
    /// `encoded_vocab` is the encoded vocabulary of the tokenizer.
    /// `vocab_type` is the type of the vocabulary; see [`VocabType`].
    /// `vocab_size`, if not provided, defaults to `encoded_vocab.len`.
    /// `stop_token_ids`, if not provided, are auto-detected (but may not be correct).
    /// `add_prefix_space` indicates whether the tokenizer prepends a space before text during
    /// tokenization.
    pub fn new(
        allocator: Allocator,
        encoded_vocab: []const []const u8,
        vocab: VocabType,
        vocab_size: ?i32,
        stop_token_ids: ?[]const i32,
        add_prefix_space: bool,
        diag: ?*TokenizerErrorInfo,
    ) TokenizerError!TokenizerInfo {
        return new_from_bytes(allocator, encoded_vocab, vocab, vocab_size, stop_token_ids, add_prefix_space, diag);
    }

    /// Builds tokenizer info from an encoded vocabulary containing arbitrary bytes.
    pub fn new_from_bytes(
        allocator: Allocator,
        encoded_vocab: []const []const u8,
        vocab: VocabType,
        vocab_size: ?i32,
        stop_token_ids: ?[]const i32,
        add_prefix_space: bool,
        diag: ?*TokenizerErrorInfo,
    ) TokenizerError!TokenizerInfo {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const size: i32 = vocab_size orelse @intCast(encoded_vocab.len);
        // vocab_size only ever pads the encoded vocab with special ids; a smaller value would
        // leave token ids without a slot.
        if (size < @as(i32, @intCast(encoded_vocab.len))) {
            set_tokenizer_diag(diag, .{ .VocabSizeTooSmall = .{
                .vocab_size = size,
                .num_tokens = encoded_vocab.len,
            } });
            return error.VocabSizeTooSmall;
        }
        var decoded_vocab = std.array_list.Managed([]const u8).init(a);
        var sorted_decoded_vocab = std.array_list.Managed(SortedDecodedToken).init(a);
        var stop_ids = std.array_list.Managed(i32).init(a);
        var special_ids = std.array_list.Managed(i32).init(a);

        for (encoded_vocab, 0..) |encoded, i| {
            const id: i32 = @intCast(i);
            const token = try token_decoder.decode_token_bytes(a, encoded, vocab);
            const is_stop = if (stop_token_ids == null)
                blk: {
                    for (DETECTION_STOP_TOKENS) |s| {
                        if (std.mem.eql(u8, s, token)) break :blk true;
                    }
                    break :blk false;
                }
            else blk: {
                for (stop_token_ids.?) |stop_id| {
                    if (stop_id == id) break :blk true;
                }
                break :blk false;
            };
            if (is_stop) {
                try stop_ids.append(id);
            } else if (token.len == 0) {
                // The only special token is the empty decoded token.
                try special_ids.append(id);
            } else {
                try sorted_decoded_vocab.append(.{ .id = id, .token = token });
            }
            try decoded_vocab.append(token);
        }
        var padded: i32 = @intCast(encoded_vocab.len);
        while (padded < size) : (padded += 1) {
            try special_ids.append(padded);
        }

        // Stable sort by decoded bytes (matches Rust `sort_by`, ties keep id order).
        std.sort.insertion(SortedDecodedToken, sorted_decoded_vocab.items, {}, struct {
            fn lessThan(_: void, lhs: SortedDecodedToken, rhs: SortedDecodedToken) bool {
                return std.mem.order(u8, lhs.token, rhs.token) == .lt;
            }
        }.lessThan);
        const trie_ranges = try build_trie_ranges(a, sorted_decoded_vocab.items);

        return with_derived_data(arena, vocab, size, add_prefix_space, try decoded_vocab.toOwnedSlice(), try sorted_decoded_vocab.toOwnedSlice(), trie_ranges, try stop_ids.toOwnedSlice(), try special_ids.toOwnedSlice());
    }

    /// Assembles tokenizer info and builds the derived per-token arrays (the reverse index and
    /// the codepoint counts), which are not serialized.
    fn with_derived_data(
        arena: *std.heap.ArenaAllocator,
        vocab: VocabType,
        size: i32,
        prefix_space: bool,
        decoded_vocab: []const []const u8,
        sorted_decoded_vocab: []const SortedDecodedToken,
        trie_subtree_nodes_range: []const i32,
        stop_token_ids: []const i32,
        special_token_ids: []const i32,
    ) TokenizerInfo {
        const a = arena.allocator();
        const token_id_to_sorted_vocab_index = a.alloc(i32, @intCast(size)) catch @panic("OOM");
        @memset(token_id_to_sorted_vocab_index, -1);
        for (sorted_decoded_vocab, 0..) |entry, i| {
            token_id_to_sorted_vocab_index[@intCast(entry.id)] = @intCast(i);
        }
        const token_char_counts = a.alloc(i32, sorted_decoded_vocab.len) catch @panic("OOM");
        var max_token_chars: i32 = 0;
        for (sorted_decoded_vocab, 0..) |entry, i| {
            var count: i32 = 0;
            for (entry.token) |byte| {
                if ((byte & 0xC0) != 0x80) count += 1;
            }
            token_char_counts[i] = count;
            if (count > max_token_chars) max_token_chars = count;
        }
        return .{
            .arena = arena,
            .vocab_type = vocab,
            .vocab_size = size,
            .add_prefix_space = prefix_space,
            .decoded_vocab = decoded_vocab,
            .sorted_decoded_vocab = sorted_decoded_vocab,
            .trie_subtree_nodes_range = trie_subtree_nodes_range,
            .stop_token_ids = stop_token_ids,
            .special_token_ids = special_token_ids,
            .token_id_to_sorted_vocab_index = token_id_to_sorted_vocab_index,
            .token_char_counts = token_char_counts,
            .max_token_chars = max_token_chars,
        };
    }

    /// Builds tokenizer info from an encoded vocabulary and a JSON metadata string with keys
    /// `vocab_type`, `vocab_size`, `add_prefix_space`, and optional `stop_token_ids`.
    pub fn from_vocab_and_metadata(
        allocator: Allocator,
        encoded_vocab: []const []const u8,
        metadata: []const u8,
        diag: ?*TokenizerErrorInfo,
    ) TokenizerError!TokenizerInfo {
        return from_vocab_and_metadata_bytes(allocator, encoded_vocab, metadata, diag);
    }

    /// Builds tokenizer info from an arbitrary-byte vocabulary and JSON metadata.
    pub fn from_vocab_and_metadata_bytes(
        allocator: Allocator,
        encoded_vocab: []const []const u8,
        metadata: []const u8,
        diag: ?*TokenizerErrorInfo,
    ) TokenizerError!TokenizerInfo {
        // The parse is allocated from a short-lived scratch arena; only scalar values
        // extracted below survive this function.
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const meta = json_parse.parse_json(scratch.allocator(), metadata) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // DepthExceeded is reported like any other parse failure.
            else => {
                set_tokenizer_diag(diag, .{ .InvalidMetadata = "Failed to parse metadata" });
                return error.InvalidMetadata;
            },
        };
        const object = switch (meta) {
            .object => |o| o,
            else => {
                set_tokenizer_diag(diag, .{ .InvalidMetadata = "Failed to parse metadata" });
                return error.InvalidMetadata;
            },
        };
        const vocab_type_i64: i64 = switch (object.get("vocab_type") orelse {
            set_tokenizer_diag(diag, .{ .InvalidMetadata = "metadata missing vocab_type" });
            return error.InvalidMetadata;
        }) {
            .integer => |n| n,
            else => {
                set_tokenizer_diag(diag, .{ .InvalidMetadata = "metadata missing vocab_type" });
                return error.InvalidMetadata;
            },
        };
        const vocab: VocabType = vocab_type_mod.try_from(vocab_type_i64) catch {
            set_tokenizer_diag(diag, .{ .InvalidMetadata = "invalid vocab type" });
            return error.InvalidMetadata;
        };
        const size: ?i32 = switch (object.get("vocab_size") orelse std.json.Value.null) {
            .integer => |n| @intCast(n),
            else => null,
        };
        const prefix_space: bool = switch (object.get("add_prefix_space") orelse std.json.Value.null) {
            .bool => |b| b,
            else => false,
        };
        var stop_ids: ?[]i32 = null;
        if (object.get("stop_token_ids")) |stop_value| {
            switch (stop_value) {
                .array => |arr| {
                    var ids = std.array_list.Managed(i32).init(allocator);
                    for (arr.items) |item| {
                        switch (item) {
                            .integer => |n| ids.append(@intCast(n)) catch return error.OutOfMemory,
                            else => {},
                        }
                    }
                    stop_ids = ids.toOwnedSlice() catch return error.OutOfMemory;
                },
                else => {},
            }
        }
        defer if (stop_ids) |ids| allocator.free(ids);
        return new_from_bytes(allocator, encoded_vocab, vocab, size, stop_ids, prefix_space, diag);
    }

    /// Dumps the tokenizer metadata as a compact JSON string for compiled-grammar checks.
    /// Caller owns the returned memory.
    pub fn dump_metadata(self: *TokenizerInfo, allocator: Allocator) error{OutOfMemory}![]u8 {
        return json_stringify(allocator, metadata_value_into(self.arena.allocator(), self) catch return error.OutOfMemory);
    }

    /// Returns tokenizer metadata as a JSON object (serde_json key order: sorted).
    /// Built inside the info's own arena; the returned `std.json.Value` borrows it.
    pub fn metadata_value(self: *TokenizerInfo) std.json.Value {
        return metadata_value_into(self.arena.allocator(), self) catch @panic("OOM");
    }

    fn metadata_value_into(a: Allocator, self: *const TokenizerInfo) error{OutOfMemory}!std.json.Value {
        var obj = std.json.ObjectMap{};
        // serde_json serializes maps with lexicographically sorted keys.
        try obj.put(a, "add_prefix_space", .{ .bool = self.add_prefix_space });
        const stop_ids = try a.alloc(std.json.Value, self.stop_token_ids.len);
        for (self.stop_token_ids, 0..) |id, i| stop_ids[i] = .{ .integer = id };
        try obj.put(a, "stop_token_ids", .{ .array = blk: {
            var arr = std.json.Array.init(a);
            arr.items = stop_ids;
            arr.capacity = stop_ids.len;
            break :blk arr;
        } });
        try obj.put(a, "vocab_size", .{ .integer = self.vocab_size });
        try obj.put(a, "vocab_type", .{ .integer = @intFromEnum(self.vocab_type) });
        return .{ .object = obj };
    }

    /// Returns an error when `metadata` does not match this tokenizer info.
    pub fn check_metadata_match(
        self: *TokenizerInfo,
        metadata: std.json.Value,
        diag: ?*DeserializeErrorInfo,
    ) DeserializeError!void {
        const expected = self.metadata_value();
        inline for ([_][]const u8{ "vocab_type", "vocab_size", "add_prefix_space", "stop_token_ids" }) |key| {
            const exp = get_field(expected, key);
            const got = get_field(metadata, key);
            if (!json_value_eql(exp, got)) {
                if (diag) |d| d.* = .{ .Format = "tokenizer metadata mismatch" };
                return error.Format;
            }
        }
    }

    /// Detects tokenizer metadata from a Hugging Face backend JSON string and serializes it
    /// to the metadata JSON string. Caller owns the returned memory.
    pub fn detect_metadata_from_hf(allocator: Allocator, backend_str: []const u8) error{ OutOfMemory, InvalidJson, RootNotObject }![]u8 {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const metadata = try hf_metadata.detect_metadata_from_hf(scratch.allocator(), backend_str);
        return hf_metadata.metadata_to_json(allocator, metadata);
    }

    /// Serializes the tokenizer info to its `"v16"` JSON form (byte strings are encoded as
    /// Latin-1, matching the C++). Caller owns the returned memory.
    pub fn serialize_json(self: *const TokenizerInfo, allocator: Allocator) error{OutOfMemory}![]u8 {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const a = scratch.allocator();

        var obj = std.json.ObjectMap{};
        // serde_json serializes maps with lexicographically sorted keys.
        try obj.put(a, "__VERSION__", .{ .string = SERIALIZATION_VERSION });
        try obj.put(a, "add_prefix_space", .{ .bool = self.add_prefix_space });
        var decoded_arr = std.json.Array.init(a);
        for (self.decoded_vocab) |bytes| {
            try decoded_arr.append(.{ .string = try encoding.byte_to_latin1(a, bytes) });
        }
        try obj.put(a, "decoded_vocab", .{ .array = decoded_arr });
        var sorted_arr = std.json.Array.init(a);
        for (self.sorted_decoded_vocab) |entry| {
            var pair = std.json.Array.init(a);
            try pair.append(.{ .integer = entry.id });
            try pair.append(.{ .string = try encoding.byte_to_latin1(a, entry.token) });
            try sorted_arr.append(.{ .array = pair });
        }
        try obj.put(a, "sorted_decoded_vocab", .{ .array = sorted_arr });
        try obj.put(a, "special_token_ids", try i32_value_array(a, self.special_token_ids));
        try obj.put(a, "stop_token_ids", try i32_value_array(a, self.stop_token_ids));
        try obj.put(a, "trie_subtree_nodes_range", try i32_value_array(a, self.trie_subtree_nodes_range));
        try obj.put(a, "vocab_size", .{ .integer = self.vocab_size });
        try obj.put(a, "vocab_type", .{ .integer = @intFromEnum(self.vocab_type) });
        return json_stringify(allocator, .{ .object = obj });
    }

    /// Deserializes tokenizer info from its `"v16"` JSON form. The fields are restored verbatim
    /// and validated; the derived per-token arrays are rebuilt.
    pub fn deserialize_json(
        allocator: Allocator,
        json_str: []const u8,
        diag: ?*DeserializeErrorInfo,
    ) DeserializeErrorAll!TokenizerInfo {
        const set = struct {
            fn f(d: ?*DeserializeErrorInfo, info: DeserializeErrorInfo) DeserializeError {
                if (d) |dd| dd.* = info;
                return error.Format;
            }
        };
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const value = json_parse.parse_json(sa, json_str) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // DepthExceeded is reported as invalid input (Rust: DeserializeError::InvalidJson).
            else => {
                if (diag) |d| d.* = .{ .InvalidJson = "invalid JSON" };
                return error.InvalidJson;
            },
        };
        const object = switch (value) {
            .object => |o| o,
            else => return set.f(diag, .{ .Format = "missing __VERSION__" }),
        };
        const version: ?[]const u8 = switch (object.get("__VERSION__") orelse std.json.Value.null) {
            .string => |s| s,
            else => null,
        };
        if (version == null) return set.f(diag, .{ .Format = "missing __VERSION__" });
        if (!std.mem.eql(u8, version.?, SERIALIZATION_VERSION)) {
            if (diag) |d| {
                // Strings outlive the scratch arena: dupe into the caller's allocator
                // (caller owns and must free the diag payload strings).
                d.* = .{ .Version = .{
                    .expected = allocator.dupe(u8, SERIALIZATION_VERSION) catch return error.OutOfMemory,
                    .got = allocator.dupe(u8, version.?) catch return error.OutOfMemory,
                } };
            }
            return error.Version;
        }

        const vocab_type_i64: i64 = switch (object.get("vocab_type") orelse std.json.Value.null) {
            .integer => |n| n,
            else => return set.f(diag, .{ .Format = "vocab_type" }),
        };
        const vocab: VocabType = vocab_type_mod.try_from(vocab_type_i64) catch
            return set.f(diag, .{ .Format = "invalid vocab type" });
        const size: i32 = switch (object.get("vocab_size") orelse std.json.Value.null) {
            .integer => |n| @intCast(n),
            else => return set.f(diag, .{ .Format = "vocab_size" }),
        };
        const prefix_space: bool = switch (object.get("add_prefix_space") orelse std.json.Value.null) {
            .bool => |b| b,
            else => false,
        };
        const stop_token_ids = try i32_array(sa, object.get("stop_token_ids") orelse std.json.Value.null) orelse
            return set.f(diag, .{ .Format = "expected array" });
        const special_token_ids = try i32_array(sa, object.get("special_token_ids") orelse std.json.Value.null) orelse
            return set.f(diag, .{ .Format = "expected array" });
        const decoded_vocab = blk: {
            const arr = switch (object.get("decoded_vocab") orelse std.json.Value.null) {
                .array => |arr| arr,
                else => return set.f(diag, .{ .Format = "decoded_vocab" }),
            };
            var out = std.array_list.Managed([]const u8).init(sa);
            for (arr.items) |item| {
                switch (item) {
                    .string => |s| {
                        const bytes = encoding.latin1_to_bytes(sa, s) catch |e| switch (e) {
                            error.OutOfMemory => return error.OutOfMemory,
                            else => return set.f(diag, .{ .Format = "decoded token" }),
                        };
                        out.append(bytes) catch return error.OutOfMemory;
                    },
                    else => return set.f(diag, .{ .Format = "decoded token" }),
                }
            }
            break :blk out.toOwnedSlice() catch return error.OutOfMemory;
        };
        const sorted_decoded_vocab = blk: {
            const arr = switch (object.get("sorted_decoded_vocab") orelse std.json.Value.null) {
                .array => |arr| arr,
                else => return set.f(diag, .{ .Format = "sorted_decoded_vocab" }),
            };
            var out = std.array_list.Managed(SortedDecodedToken).init(sa);
            for (arr.items) |entry| {
                switch (entry) {
                    .array => |pair| {
                        if (pair.items.len != 2) return set.f(diag, .{ .Format = "sorted_decoded_vocab entry" });
                        const id: i32 = switch (pair.items[0]) {
                            .integer => |n| (if (n >= std.math.minInt(i32) and n <= std.math.maxInt(i32)) @as(i32, @intCast(n)) else return set.f(diag, .{ .Format = "token id" })),
                            else => return set.f(diag, .{ .Format = "token id" }),
                        };
                        const token: []const u8 = switch (pair.items[1]) {
                            .string => |s| encoding.latin1_to_bytes(sa, s) catch |e| switch (e) {
                                error.OutOfMemory => return error.OutOfMemory,
                                else => return set.f(diag, .{ .Format = "decoded token" }),
                            },
                            else => return set.f(diag, .{ .Format = "sorted_decoded_vocab entry" }),
                        };
                        out.append(.{ .id = id, .token = token }) catch return error.OutOfMemory;
                    },
                    else => return set.f(diag, .{ .Format = "sorted_decoded_vocab entry" }),
                }
            }
            break :blk out.toOwnedSlice() catch return error.OutOfMemory;
        };
        const trie_subtree_nodes_range = (try i32_array(sa, object.get("trie_subtree_nodes_range") orelse std.json.Value.null)) orelse
            return set.f(diag, .{ .Format = "expected array" });

        const num_tokens: i64 = @intCast(decoded_vocab.len);
        if (@as(i64, size) < num_tokens) {
            const msg = std.fmt.allocPrint(allocator, "vocab_size {d} is smaller than the number of tokens {d}", .{ size, num_tokens }) catch return error.OutOfMemory;
            return set.f(diag, .{ .Format = msg });
        }
        for (sorted_decoded_vocab) |entry| {
            if (entry.id < 0 or @as(i64, entry.id) >= num_tokens) {
                const msg = std.fmt.allocPrint(allocator, "sorted_decoded_vocab contains token id {d} out of range", .{entry.id}) catch return error.OutOfMemory;
                return set.f(diag, .{ .Format = msg });
            }
        }
        if (trie_subtree_nodes_range.len != sorted_decoded_vocab.len) {
            return set.f(diag, .{ .Format = "trie_subtree_nodes_range must have one entry per sorted token" });
        }
        for (stop_token_ids) |id| {
            if (id < 0 or id >= size) {
                return set.f(diag, .{ .Format = "stop_token_ids or special_token_ids contains a token id out of range" });
            }
        }
        for (special_token_ids) |id| {
            if (id < 0 or id >= size) {
                return set.f(diag, .{ .Format = "stop_token_ids or special_token_ids contains a token id out of range" });
            }
        }

        // Copy the validated fields into the info's own arena.
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const decoded_copy = try a.alloc([]const u8, decoded_vocab.len);
        for (decoded_vocab, 0..) |bytes, i| decoded_copy[i] = try a.dupe(u8, bytes);
        const sorted_copy = try a.alloc(SortedDecodedToken, sorted_decoded_vocab.len);
        for (sorted_decoded_vocab, 0..) |entry, i| {
            sorted_copy[i] = .{ .id = entry.id, .token = try a.dupe(u8, entry.token) };
        }
        return with_derived_data(
            arena,
            vocab,
            size,
            prefix_space,
            decoded_copy,
            sorted_copy,
            try a.dupe(i32, trie_subtree_nodes_range),
            try a.dupe(i32, stop_token_ids),
            try a.dupe(i32, special_token_ids),
        );
    }
};

/// Serializes a `std.json.Value` to a compact JSON string (Rust: `serde_json::to_string`).
/// Caller owns the returned memory.
fn json_stringify(allocator: Allocator, value: std.json.Value) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

fn i32_value_array(a: Allocator, ids: []const i32) error{OutOfMemory}!std.json.Value {
    const values = try a.alloc(std.json.Value, ids.len);
    for (ids, 0..) |id, i| values[i] = .{ .integer = id };
    return .{ .array = blk: {
        var arr = std.json.Array.init(a);
        arr.items = values;
        arr.capacity = values.len;
        break :blk arr;
    } };
}

/// `i32_array` in the reference: null when the value is not an array of integers.
fn i32_array(a: Allocator, value: std.json.Value) error{OutOfMemory}!?[]const i32 {
    const arr = switch (value) {
        .array => |arr| arr,
        else => return null,
    };
    var out = std.array_list.Managed(i32).init(a);
    for (arr.items) |item| {
        switch (item) {
            .integer => |n| try out.append(@intCast(n)),
            else => return null,
        }
    }
    return try out.toOwnedSlice();
}

/// serde `Value::get`: object field or null-ish.
fn get_field(value: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |o| o.get(key),
        else => null,
    };
}

/// Deep JSON equality (mirror of serde_json `Value` `PartialEq`).
fn json_value_eql(lhs: ?std.json.Value, rhs: ?std.json.Value) bool {
    if (lhs == null and rhs == null) return true;
    if (lhs == null or rhs == null) return false;
    const l = lhs.?;
    const r = rhs.?;
    return switch (l) {
        .null => r == .null,
        .bool => |b| r == .bool and r.bool == b,
        .integer => |n| r == .integer and r.integer == n,
        .float => |f| r == .float and r.float == f,
        .number_string => |s| r == .number_string and std.mem.eql(u8, r.number_string, s),
        .string => |s| r == .string and std.mem.eql(u8, r.string, s),
        .array => |arr| blk: {
            if (r != .array or r.array.items.len != arr.items.len) break :blk false;
            for (arr.items, r.array.items) |li, ri| {
                if (!json_value_eql(li, ri)) break :blk false;
            }
            break :blk true;
        },
        .object => |obj| blk: {
            if (r != .object or r.object.count() != obj.count()) break :blk false;
            var it = obj.iterator();
            while (it.next()) |entry| {
                const rv = r.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!json_value_eql(entry.value_ptr.*, rv)) break :blk false;
            }
            break :blk true;
        },
    };
}

/// Whether `needle` occurs as a contiguous subsequence of `haystack` (byte `find != npos`).
fn byte_contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// Builds the pseudo-trie subtree ranges over the sorted vocabulary.
fn build_trie_ranges(a: Allocator, sorted: []const SortedDecodedToken) error{OutOfMemory}![]const i32 {
    const ranges = try a.alloc(i32, sorted.len);
    @memset(ranges, 0);
    // Sorted indices of the currently-active prefixes.
    var prefix_stack = std.array_list.Managed(usize).init(a);
    defer prefix_stack.deinit();
    for (sorted, 0..) |entry, i| {
        while (prefix_stack.items.len > 0) {
            const top = prefix_stack.items[prefix_stack.items.len - 1];
            if (byte_contains(entry.token, sorted[top].token)) break;
            ranges[top] = @intCast(i);
            _ = prefix_stack.pop();
        }
        try prefix_stack.append(i);
    }
    while (prefix_stack.items.len > 0) {
        const top = prefix_stack.pop().?;
        ranges[top] = @intCast(sorted.len);
    }
    return ranges;
}

test "construction and vocab size validation" {
    const a = std.testing.allocator;
    // vocab_size smaller than the vocabulary is rejected
    {
        var diag: TokenizerErrorInfo = undefined;
        const result = TokenizerInfo.new(a, &.{ "a", "b" }, .Raw, 1, null, false, &diag);
        try std.testing.expectError(error.VocabSizeTooSmall, result);
        try std.testing.expectEqual(@as(i32, 1), diag.VocabSizeTooSmall.vocab_size);
        try std.testing.expectEqual(@as(usize, 2), diag.VocabSizeTooSmall.num_tokens);
    }
    // basic construction with padding
    {
        var info = try TokenizerInfo.new(a, &.{ "hello", "world" }, .Raw, 40, null, false, null);
        defer info.deinit();
        try std.testing.expectEqual(@as(i32, 40), info.vocab_size);
        try std.testing.expectEqual(@as(usize, 2), info.decoded_vocab.len);
        try std.testing.expectEqual(@as(usize, 2), info.sorted_decoded_vocab.len);
        try std.testing.expectEqual(@as(usize, 0), info.stop_token_ids.len);
        // padding ids 2..39 are special
        try std.testing.expectEqual(@as(usize, 38), info.special_token_ids.len);
        try std.testing.expectEqual(@as(i32, 2), info.special_token_ids[0]);
        try std.testing.expectEqual(@as(i32, 39), info.special_token_ids[37]);
        try std.testing.expectEqual(@as(i32, 5), info.max_token_chars);
        // sorted: "hello" < "world"
        try std.testing.expectEqual(@as(i32, 0), info.sorted_decoded_vocab[0].id);
        try std.testing.expectEqual(@as(i32, 1), info.sorted_decoded_vocab[1].id);
        try std.testing.expectEqual(@as(i32, 0), info.token_id_to_sorted_vocab_index[0]);
        try std.testing.expectEqual(@as(i32, 1), info.token_id_to_sorted_vocab_index[1]);
        try std.testing.expectEqual(@as(i32, -1), info.token_id_to_sorted_vocab_index[2]);
    }
    // default vocab_size is the vocab length
    {
        var info = try TokenizerInfo.new(a, &.{ "a", "b", "c" }, .Raw, null, null, true, null);
        defer info.deinit();
        try std.testing.expectEqual(@as(i32, 3), info.vocab_size);
        try std.testing.expect(info.add_prefix_space);
    }
}

test "stop token classification" {
    const a = std.testing.allocator;
    // auto-detection
    {
        var info = try TokenizerInfo.new(a, &.{ "</s>", "<eos>", "word", "" }, .Raw, null, null, false, null);
        defer info.deinit();
        try std.testing.expectEqualSlices(i32, &.{ 0, 1 }, info.stop_token_ids);
        // empty decoded token is special
        try std.testing.expectEqualSlices(i32, &.{3}, info.special_token_ids);
    }
    // explicit stop ids override detection
    {
        var info = try TokenizerInfo.new(a, &.{ "</s>", "<eos>", "word" }, .Raw, null, &.{2}, false, null);
        defer info.deinit();
        try std.testing.expectEqualSlices(i32, &.{2}, info.stop_token_ids);
    }
}

test "byte fallback vocab decodes prefix-space and byte tokens" {
    const a = std.testing.allocator;
    var info = try TokenizerInfo.new(a, &.{ "<0x1B>", "▁apple", "plain" }, .ByteFallback, null, null, false, null);
    defer info.deinit();
    const dv = info.decoded_vocab;
    try std.testing.expectEqualSlices(u8, &[1]u8{0x1B}, dv[0]);
    try std.testing.expectEqualStrings(" apple", dv[1]);
    try std.testing.expectEqualStrings("plain", dv[2]);
}

test "trie subtree ranges" {
    const a = std.testing.allocator;
    // sorted vocab: "a", "ab", "b" → ranges [2, 2, 2]
    var info = try TokenizerInfo.new(a, &.{ "ab", "a", "b" }, .Raw, null, null, false, null);
    defer info.deinit();
    try std.testing.expectEqualSlices(i32, &.{ 2, 2, 3 }, info.trie_subtree_nodes_range);
}

test "from_vocab_and_metadata round trip" {
    const a = std.testing.allocator;
    var info = try TokenizerInfo.from_vocab_and_metadata(
        a,
        &.{ "<0x41>", "▁x" },
        "{\"vocab_type\":1,\"vocab_size\":40,\"add_prefix_space\":true,\"stop_token_ids\":[1]}",
        null,
    );
    defer info.deinit();
    try std.testing.expectEqual(VocabType.ByteFallback, info.vocab_type);
    try std.testing.expectEqual(@as(i32, 40), info.vocab_size);
    try std.testing.expect(info.add_prefix_space);
    try std.testing.expectEqualSlices(i32, &.{1}, info.stop_token_ids);
    // missing vocab_type is an error
    var diag: TokenizerErrorInfo = undefined;
    const bad = TokenizerInfo.from_vocab_and_metadata(a, &.{"x"}, "{\"vocab_size\":3}", &diag);
    try std.testing.expectError(error.InvalidMetadata, bad);
    try std.testing.expectEqualStrings("metadata missing vocab_type", diag.InvalidMetadata);

    // metadata dump matches the same shape
    const dumped = try info.dump_metadata(a);
    defer a.free(dumped);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, dumped, .{});
    defer parsed.deinit();
    try info.check_metadata_match(parsed.value, null);
    // mismatch is detected
    const wrong = try std.json.parseFromSlice(std.json.Value, a, "{\"vocab_type\":1,\"vocab_size\":30,\"add_prefix_space\":true,\"stop_token_ids\":[1]}", .{});
    defer wrong.deinit();
    var derr: DeserializeErrorInfo = undefined;
    try std.testing.expectError(error.Format, info.check_metadata_match(wrong.value, &derr));
}

test "serialize/deserialize round trip" {
    const a = std.testing.allocator;
    var info = try TokenizerInfo.new(a, &.{ "<0xFF>", "▁ab", "</s>" }, .ByteFallback, 10, null, true, null);
    defer info.deinit();
    const serialized = try info.serialize_json(a);
    defer a.free(serialized);
    var restored = try TokenizerInfo.deserialize_json(a, serialized, null);
    defer restored.deinit();

    try std.testing.expectEqual(info.vocab_type, restored.vocab_type);
    try std.testing.expectEqual(info.vocab_size, restored.vocab_size);
    try std.testing.expectEqual(info.add_prefix_space, restored.add_prefix_space);
    try std.testing.expectEqual(info.decoded_vocab.len, restored.decoded_vocab.len);
    for (info.decoded_vocab, restored.decoded_vocab) |l, r| {
        try std.testing.expectEqualSlices(u8, l, r);
    }
    try std.testing.expectEqual(info.sorted_decoded_vocab.len, restored.sorted_decoded_vocab.len);
    for (info.sorted_decoded_vocab, restored.sorted_decoded_vocab) |l, r| {
        try std.testing.expectEqual(l.id, r.id);
        try std.testing.expectEqualSlices(u8, l.token, r.token);
    }
    try std.testing.expectEqualSlices(i32, info.trie_subtree_nodes_range, restored.trie_subtree_nodes_range);
    try std.testing.expectEqualSlices(i32, info.stop_token_ids, restored.stop_token_ids);
    try std.testing.expectEqualSlices(i32, info.special_token_ids, restored.special_token_ids);
    try std.testing.expectEqualSlices(i32, info.token_id_to_sorted_vocab_index, restored.token_id_to_sorted_vocab_index);
    try std.testing.expectEqualSlices(i32, info.token_char_counts, restored.token_char_counts);
    try std.testing.expectEqual(info.max_token_chars, restored.max_token_chars);

    // version mismatch
    var derr: DeserializeErrorInfo = undefined;
    try std.testing.expectError(error.Version, TokenizerInfo.deserialize_json(a, "{\"__VERSION__\":\"v15\"}", &derr));
    try std.testing.expectEqualStrings("v15", derr.Version.got);
    a.free(derr.Version.expected);
    a.free(derr.Version.got);
    // missing version
    try std.testing.expectError(error.Format, TokenizerInfo.deserialize_json(a, "{}", &derr));
}

test "detect_metadata_from_hf wrapper" {
    const a = std.testing.allocator;
    const json = try TokenizerInfo.detect_metadata_from_hf(a, "{\"decoder\":{\"type\":\"ByteLevel\"}}");
    defer a.free(json);
    try std.testing.expectEqualStrings("{\"add_prefix_space\":false,\"vocab_type\":2}", json);
}
