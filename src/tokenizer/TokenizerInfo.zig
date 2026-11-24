//! The tokenizer info class to handle tokenizer information for grammar-guided generation.

const std = @import("std");
const Allocator = std.mem.Allocator;

const tokenizer_mod = @import("../tokenizer.zig");
const VocabType = tokenizer_mod.VocabType;
const TokenizerError = tokenizer_mod.TokenizerError;
const DeserializeError = tokenizer_mod.DeserializeError;
const DeserializeErrorAll = tokenizer_mod.DeserializeErrorAll;
const token_decoder = @import("token_decoder.zig");
const hf_metadata = @import("hf_metadata.zig");
const Diagnostic = @import("../Diagnostic.zig").Diagnostic;
const config = @import("../config.zig");
const DynamicBitset = @import("../support/dynamic_bitset.zig").DynamicBitset;
const encoding = @import("../support/encoding.zig");
const json_parse = @import("../support/json_parse.zig");

/// Tokens whose presence marks a stop token when explicit ids are not supplied.
const detection_stop_tokens: [8][]const u8 = .{
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

const TokenizerStorage = struct {
    refs: std.atomic.Value(usize),
    arena: std.heap.ArenaAllocator,
    vocab_type: VocabType = .raw,
    vocab_size: usize = 0,
    add_prefix_space: bool = false,
    decoded_vocab: []const []const u8 = &.{},
    sorted_decoded_vocab: []const SortedDecodedToken = &.{},
    trie_subtree_nodes_range: []const i32 = &.{},
    stop_token_ids: []const u32 = &.{},
    special_token_ids: []const u32 = &.{},
    token_id_to_sorted_vocab_index: []const i32 = &.{},
    token_char_counts: []const i32 = &.{},
    max_token_chars: i32 = 0,
};

/// Value handle wrapping reference-counted tokenizer vocabulary and metadata.
///
/// `retain()` increments the atomic reference count in O(1) without copying.
/// Callers must ensure the allocator used to construct the original `TokenizerInfo`
/// outlives all retained handles and call `deinit()` on each handle.
/// Use `dupe(allocator)` to copy into an independent allocator lifetime.
pub const TokenizerInfo = struct {
    storage: *TokenizerStorage,

    pub const InitOptions = struct {
        vocab_type: VocabType = .raw,
        vocab_size: ?usize = null,
        stop_token_ids: ?[]const u32 = null,
        add_prefix_space: bool = false,
        diag: ?*Diagnostic = null,
    };

    /// Constructs a `TokenizerInfo` from `encoded_vocab` and `options`.
    pub fn init(
        allocator: Allocator,
        encoded_vocab: []const []const u8,
        options: InitOptions,
    ) TokenizerError!TokenizerInfo {
        const size: usize = options.vocab_size orelse encoded_vocab.len;
        // vocab_size only ever pads the encoded vocab with special ids; a smaller value would
        // leave token ids without a slot.
        if (size < encoded_vocab.len) {
            if (options.diag) |d| {
                d.setNumbers(
                    .tokenizer_vocab_too_small,
                    std.math.cast(i64, size) orelse std.math.maxInt(i64),
                    std.math.cast(i64, encoded_vocab.len) orelse std.math.maxInt(i64),
                );
            }
            return error.VocabSizeTooSmall;
        }

        var stop_bitset: DynamicBitset = .empty;
        defer stop_bitset.deinit(allocator);
        if (options.stop_token_ids) |ids| {
            if (ids.len > 4 and encoded_vocab.len > 0) {
                stop_bitset = try DynamicBitset.init(allocator, encoded_vocab.len);
                for (ids) |stop_id| {
                    if (stop_id < encoded_vocab.len) {
                        stop_bitset.set(stop_id, true);
                    }
                }
            }
        }

        var unsorted: std.ArrayList(SortedDecodedToken) = .empty;
        defer unsorted.deinit(allocator);
        try unsorted.ensureTotalCapacity(allocator, encoded_vocab.len);

        const storage = try allocator.create(TokenizerStorage);
        errdefer allocator.destroy(storage);
        storage.* = .{
            .refs = std.atomic.Value(usize).init(1),
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer storage.arena.deinit();
        const a = storage.arena.allocator();

        const decoded_vocab = try a.alloc([]const u8, encoded_vocab.len);
        var stop_ids: std.ArrayList(u32) = .empty;
        var special_ids: std.ArrayList(u32) = .empty;

        // Pack `.raw` tokens into one contiguous slab to avoid per-token arena allocations.
        var raw_slab: []u8 = &.{};
        var raw_cursor: usize = 0;
        if (options.vocab_type == .raw and encoded_vocab.len > 0) {
            var total_bytes: usize = 0;
            for (encoded_vocab) |encoded| total_bytes += encoded.len;
            raw_slab = try a.alloc(u8, total_bytes);
        }

        var counts: [256]usize = @splat(0);
        for (encoded_vocab, 0..) |encoded, i| {
            const id: i32 = @intCast(i);
            const uid: u32 = @intCast(i);
            const token: []const u8 = if (options.vocab_type == .raw) blk: {
                const dst = raw_slab[raw_cursor .. raw_cursor + encoded.len];
                @memcpy(dst, encoded);
                raw_cursor += encoded.len;
                break :blk dst;
            } else try token_decoder.decodeTokenBytes(a, encoded, options.vocab_type);

            const is_stop = if (options.stop_token_ids) |ids| blk: {
                if (ids.len > 4) {
                    break :blk stop_bitset.get(i);
                }
                for (ids) |stop_id| {
                    if (stop_id == uid) break :blk true;
                }
                break :blk false;
            } else blk: {
                if (token.len > 0 and token[0] == '<') {
                    for (detection_stop_tokens) |s| {
                        if (std.mem.eql(u8, s, token)) break :blk true;
                    }
                }
                break :blk false;
            };

            if (is_stop) {
                try stop_ids.append(a, uid);
            } else if (token.len == 0) {
                // The only special token is the empty decoded token.
                try special_ids.append(a, uid);
            } else {
                counts[token[0]] += 1;
                unsorted.appendAssumeCapacity(.{ .id = id, .token = token });
            }
            decoded_vocab[i] = token;
        }

        const pad_count = size - encoded_vocab.len;
        if (pad_count > 0) {
            try special_ids.ensureUnusedCapacity(a, pad_count);
            for (encoded_vocab.len..size) |padded| {
                special_ids.appendAssumeCapacity(@intCast(padded));
            }
        }

        const sorted_decoded_vocab = try sortVocabBucketed(a, unsorted.items, &counts);
        const trie_ranges = try buildTrieRanges(a, allocator, sorted_decoded_vocab);

        return withDerivedData(
            storage,
            options.vocab_type,
            size,
            options.add_prefix_space,
            decoded_vocab,
            sorted_decoded_vocab,
            trie_ranges,
            try stop_ids.toOwnedSlice(a),
            try special_ids.toOwnedSlice(a),
        );
    }

    /// Builds tokenizer info from an encoded vocabulary and a JSON metadata string with keys
    /// `vocab_type`, `vocab_size`, `add_prefix_space`, and optional `stop_token_ids`.
    pub fn fromVocabAndMetadata(
        allocator: Allocator,
        encoded_vocab: []const []const u8,
        metadata: []const u8,
        diag: ?*Diagnostic,
    ) TokenizerError!TokenizerInfo {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const sa = scratch.allocator();

        const meta = json_parse.parseJson(sa, metadata) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // DepthExceeded is reported like any other parse failure.
            else => {
                if (diag) |d| d.setStatic(.message, "Failed to parse metadata");
                return error.InvalidMetadata;
            },
        };
        const object = switch (meta) {
            .object => |o| o,
            else => {
                if (diag) |d| d.setStatic(.message, "Failed to parse metadata");
                return error.InvalidMetadata;
            },
        };
        const vocab_type_i64: i64 = switch (object.get("vocab_type") orelse {
            if (diag) |d| d.setStatic(.message, "metadata missing vocab_type");
            return error.InvalidMetadata;
        }) {
            .integer => |n| n,
            else => {
                if (diag) |d| d.setStatic(.message, "metadata missing vocab_type");
                return error.InvalidMetadata;
            },
        };
        const vocab = VocabType.fromInt(vocab_type_i64) catch {
            if (diag) |d| d.setStatic(.message, "invalid vocab type");
            return error.InvalidMetadata;
        };

        var size: ?usize = null;
        if (object.get("vocab_size")) |vs_val| {
            switch (vs_val) {
                .integer => |n| {
                    if (n < 0) {
                        if (diag) |d| {
                            d.setNumbers(
                                .tokenizer_vocab_too_small,
                                n,
                                std.math.cast(i64, encoded_vocab.len) orelse std.math.maxInt(i64),
                            );
                        }
                        return error.VocabSizeTooSmall;
                    }
                    size = std.math.cast(usize, n) orelse {
                        if (diag) |d| d.setStatic(.message, "vocab_size out of range");
                        return error.InvalidMetadata;
                    };
                },
                else => {},
            }
        }

        const prefix_space: bool = switch (object.get("add_prefix_space") orelse .null) {
            .bool => |b| b,
            else => false,
        };

        var stop_ids: ?[]const u32 = null;
        if (object.get("stop_token_ids")) |stop_value| {
            switch (stop_value) {
                .array => |arr| {
                    var ids: std.ArrayList(u32) = .empty;
                    try ids.ensureTotalCapacity(sa, arr.items.len);
                    for (arr.items) |item| {
                        switch (item) {
                            .integer => |n| {
                                if (std.math.cast(u32, n)) |u| {
                                    ids.appendAssumeCapacity(u);
                                }
                            },
                            else => {},
                        }
                    }
                    stop_ids = ids.items;
                },
                else => {},
            }
        }

        return init(allocator, encoded_vocab, .{
            .vocab_type = vocab,
            .vocab_size = size,
            .stop_token_ids = stop_ids,
            .add_prefix_space = prefix_space,
            .diag = diag,
        });
    }

    /// Returns a zero-copy handle sharing the underlying ref-counted storage.
    pub fn retain(self: *const TokenizerInfo) TokenizerInfo {
        _ = self.storage.refs.fetchAdd(1, .monotonic);
        return .{ .storage = self.storage };
    }

    /// Deep-copies `self` into an independent ref-counted storage backed by `allocator`.
    pub fn dupe(self: *const TokenizerInfo, allocator: Allocator) Allocator.Error!TokenizerInfo {
        const storage = try allocator.create(TokenizerStorage);
        errdefer allocator.destroy(storage);
        storage.* = .{
            .refs = std.atomic.Value(usize).init(1),
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer storage.arena.deinit();
        const a = storage.arena.allocator();

        const src = self.storage;
        var total_bytes: usize = 0;
        for (src.decoded_vocab) |bytes| total_bytes += bytes.len;
        const slab = try a.alloc(u8, total_bytes);
        var cursor: usize = 0;
        const decoded_copy = try a.alloc([]const u8, src.decoded_vocab.len);
        for (src.decoded_vocab, 0..) |bytes, i| {
            const dst = slab[cursor .. cursor + bytes.len];
            @memcpy(dst, bytes);
            cursor += bytes.len;
            decoded_copy[i] = dst;
        }

        const sorted_copy = try a.alloc(SortedDecodedToken, src.sorted_decoded_vocab.len);
        for (src.sorted_decoded_vocab, 0..) |entry, i| {
            const token_slice = if (entry.id >= 0 and @as(usize, @intCast(entry.id)) < decoded_copy.len and std.mem.eql(u8, decoded_copy[@intCast(entry.id)], entry.token))
                decoded_copy[@intCast(entry.id)]
            else
                try a.dupe(u8, entry.token);
            sorted_copy[i] = .{ .id = entry.id, .token = token_slice };
        }

        storage.vocab_type = src.vocab_type;
        storage.vocab_size = src.vocab_size;
        storage.add_prefix_space = src.add_prefix_space;
        storage.decoded_vocab = decoded_copy;
        storage.sorted_decoded_vocab = sorted_copy;
        storage.trie_subtree_nodes_range = try a.dupe(i32, src.trie_subtree_nodes_range);
        storage.stop_token_ids = try a.dupe(u32, src.stop_token_ids);
        storage.special_token_ids = try a.dupe(u32, src.special_token_ids);
        storage.token_id_to_sorted_vocab_index = try a.dupe(i32, src.token_id_to_sorted_vocab_index);
        storage.token_char_counts = try a.dupe(i32, src.token_char_counts);
        storage.max_token_chars = src.max_token_chars;
        return .{ .storage = storage };
    }

    /// Returns `true` when `self` and `other` reference the same backing storage.
    pub fn sharesStorage(self: *const TokenizerInfo, other: *const TokenizerInfo) bool {
        return self.storage == other.storage;
    }

    /// Decrements the reference count and frees the backing storage when the last handle drops.
    pub fn deinit(self: *TokenizerInfo) void {
        if (self.storage.refs.fetchSub(1, .acq_rel) == 1) {
            const parent = self.storage.arena.child_allocator;
            self.storage.arena.deinit();
            parent.destroy(self.storage);
        }
        self.* = undefined;
    }

    // --- Accessors ---

    pub fn vocabSize(self: *const TokenizerInfo) usize {
        return self.storage.vocab_size;
    }

    pub fn vocabType(self: *const TokenizerInfo) VocabType {
        return self.storage.vocab_type;
    }

    pub fn addPrefixSpace(self: *const TokenizerInfo) bool {
        return self.storage.add_prefix_space;
    }

    pub fn decodedVocab(self: *const TokenizerInfo) []const []const u8 {
        return self.storage.decoded_vocab;
    }

    pub fn sortedDecodedVocab(self: *const TokenizerInfo) []const SortedDecodedToken {
        return self.storage.sorted_decoded_vocab;
    }

    pub fn trieSubtreeNodesRange(self: *const TokenizerInfo) []const i32 {
        return self.storage.trie_subtree_nodes_range;
    }

    pub fn stopTokenIds(self: *const TokenizerInfo) []const u32 {
        return self.storage.stop_token_ids;
    }

    pub fn specialTokenIds(self: *const TokenizerInfo) []const u32 {
        return self.storage.special_token_ids;
    }

    pub fn tokenIdToSortedVocabIndex(self: *const TokenizerInfo) []const i32 {
        return self.storage.token_id_to_sorted_vocab_index;
    }

    pub fn tokenCharCounts(self: *const TokenizerInfo) []const i32 {
        return self.storage.token_char_counts;
    }

    pub fn maxTokenChars(self: *const TokenizerInfo) i32 {
        return self.storage.max_token_chars;
    }

    // --- Metadata & Serialization ---

    /// Streams tokenizer metadata JSON in lexicographic key order directly to `jw`.
    pub fn writeMetadataJson(self: *const TokenizerInfo, jw: *std.json.Stringify) std.json.Stringify.Error!void {
        try jw.beginObject();
        try jw.objectField("add_prefix_space");
        try jw.write(self.storage.add_prefix_space);
        try jw.objectField("stop_token_ids");
        try jw.beginArray();
        for (self.storage.stop_token_ids) |id| try jw.write(id);
        try jw.endArray();
        try jw.objectField("vocab_size");
        try jw.write(self.storage.vocab_size);
        try jw.objectField("vocab_type");
        try jw.write(@backingInt(self.storage.vocab_type));
        try jw.endObject();
    }

    /// Dumps the tokenizer metadata as a compact JSON string for compiled-grammar checks.
    /// Caller owns the returned memory.
    pub fn dumpMetadata(self: *const TokenizerInfo, allocator: Allocator) Allocator.Error![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        var jw: std.json.Stringify = .{ .writer = &aw.writer };
        self.writeMetadataJson(&jw) catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }

    /// Returns `error.Format` when `metadata` does not match this tokenizer info.
    pub fn checkMetadataMatch(
        self: *const TokenizerInfo,
        metadata: std.json.Value,
        diag: ?*Diagnostic,
    ) DeserializeError!void {
        const obj = switch (metadata) {
            .object => |o| o,
            else => return failFormatStatic(diag, "tokenizer metadata mismatch"),
        };
        const vt = obj.get("vocab_type") orelse return failFormatStatic(diag, "tokenizer metadata mismatch");
        if (vt != .integer or vt.integer != @backingInt(self.storage.vocab_type)) {
            return failFormatStatic(diag, "tokenizer metadata mismatch");
        }
        const vs = obj.get("vocab_size") orelse return failFormatStatic(diag, "tokenizer metadata mismatch");
        if (vs != .integer or vs.integer != @as(i64, @intCast(self.storage.vocab_size))) {
            return failFormatStatic(diag, "tokenizer metadata mismatch");
        }
        const aps = obj.get("add_prefix_space") orelse return failFormatStatic(diag, "tokenizer metadata mismatch");
        if (aps != .bool or aps.bool != self.storage.add_prefix_space) {
            return failFormatStatic(diag, "tokenizer metadata mismatch");
        }
        const st = obj.get("stop_token_ids") orelse return failFormatStatic(diag, "tokenizer metadata mismatch");
        if (st != .array or st.array.items.len != self.storage.stop_token_ids.len) {
            return failFormatStatic(diag, "tokenizer metadata mismatch");
        }
        for (st.array.items, self.storage.stop_token_ids) |got, exp| {
            if (got != .integer or got.integer != @as(i64, exp)) {
                return failFormatStatic(diag, "tokenizer metadata mismatch");
            }
        }
    }

    /// Detects tokenizer metadata from a Hugging Face backend JSON string and serializes it
    /// to the metadata JSON string. Caller owns the returned memory.
    pub fn detectMetadataFromHf(allocator: Allocator, backend_str: []const u8) hf_metadata.DetectError![]u8 {
        const metadata = try hf_metadata.detectMetadataFromHf(allocator, backend_str);
        return hf_metadata.metadataToJson(allocator, metadata);
    }

    /// Streams the `"v16"` JSON representation directly to `jw` without building an intermediate DOM.
    pub fn writeJson(self: *const TokenizerInfo, jw: *std.json.Stringify) std.json.Stringify.Error!void {
        const s = self.storage;
        try jw.beginObject();

        try jw.objectField("__VERSION__");
        try jw.write(config.serialization_version);

        try jw.objectField("add_prefix_space");
        try jw.write(s.add_prefix_space);

        try jw.objectField("decoded_vocab");
        try jw.beginArray();
        for (s.decoded_vocab) |bytes| {
            try writeLatin1JsonString(jw, bytes);
        }
        try jw.endArray();

        try jw.objectField("sorted_decoded_vocab");
        try jw.beginArray();
        for (s.sorted_decoded_vocab) |entry| {
            try jw.beginArray();
            try jw.write(entry.id);
            try writeLatin1JsonString(jw, entry.token);
            try jw.endArray();
        }
        try jw.endArray();

        try jw.objectField("special_token_ids");
        try jw.beginArray();
        for (s.special_token_ids) |id| try jw.write(id);
        try jw.endArray();

        try jw.objectField("stop_token_ids");
        try jw.beginArray();
        for (s.stop_token_ids) |id| try jw.write(id);
        try jw.endArray();

        try jw.objectField("trie_subtree_nodes_range");
        try jw.beginArray();
        for (s.trie_subtree_nodes_range) |r| try jw.write(r);
        try jw.endArray();

        try jw.objectField("vocab_size");
        try jw.write(s.vocab_size);

        try jw.objectField("vocab_type");
        try jw.write(@backingInt(s.vocab_type));

        try jw.endObject();
    }

    /// Serializes the tokenizer info to its `"v16"` JSON form (byte strings encoded as Latin-1).
    /// Caller owns the returned memory.
    pub fn serializeJson(self: *const TokenizerInfo, allocator: Allocator) Allocator.Error![]u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        errdefer aw.deinit();
        var jw: std.json.Stringify = .{ .writer = &aw.writer };
        self.writeJson(&jw) catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }

    /// Deserializes tokenizer info from its `"v16"` JSON form. Fields are decoded directly into
    /// the backing storage arena and validated; derived per-token arrays are rebuilt.
    pub fn deserializeJson(
        allocator: Allocator,
        json_str: []const u8,
        diag: ?*Diagnostic,
    ) DeserializeErrorAll!TokenizerInfo {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();

        const value = json_parse.parseJson(scratch.allocator(), json_str) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // DepthExceeded is reported as invalid input.
            else => {
                if (diag) |d| d.setStatic(.deserialize_invalid_json, "invalid JSON");
                return error.InvalidJson;
            },
        };

        const object = switch (value) {
            .object => |o| o,
            else => return failFormatStatic(diag, "missing __VERSION__"),
        };
        const version: []const u8 = switch (object.get("__VERSION__") orelse .null) {
            .string => |s| s,
            else => return failFormatStatic(diag, "missing __VERSION__"),
        };
        if (!std.mem.eql(u8, version, config.serialization_version)) {
            if (diag) |d| try d.setVersionMismatch(allocator, config.serialization_version, version);
            return error.Version;
        }

        const vocab_type_i64: i64 = switch (object.get("vocab_type") orelse .null) {
            .integer => |n| n,
            else => return failFormatStatic(diag, "vocab_type"),
        };
        const vocab = VocabType.fromInt(vocab_type_i64) catch
            return failFormatStatic(diag, "invalid vocab type");

        const size_i64: i64 = switch (object.get("vocab_size") orelse .null) {
            .integer => |n| n,
            else => return failFormatStatic(diag, "vocab_size"),
        };
        const prefix_space: bool = switch (object.get("add_prefix_space") orelse .null) {
            .bool => |b| b,
            else => false,
        };

        const stop_arr = switch (object.get("stop_token_ids") orelse .null) {
            .array => |arr| arr,
            else => return failFormatStatic(diag, "expected array"),
        };
        const special_arr = switch (object.get("special_token_ids") orelse .null) {
            .array => |arr| arr,
            else => return failFormatStatic(diag, "expected array"),
        };
        const decoded_arr = switch (object.get("decoded_vocab") orelse .null) {
            .array => |arr| arr,
            else => return failFormatStatic(diag, "decoded_vocab"),
        };
        const sorted_arr = switch (object.get("sorted_decoded_vocab") orelse .null) {
            .array => |arr| arr,
            else => return failFormatStatic(diag, "sorted_decoded_vocab"),
        };
        const trie_arr = switch (object.get("trie_subtree_nodes_range") orelse .null) {
            .array => |arr| arr,
            else => return failFormatStatic(diag, "expected array"),
        };

        const num_tokens: i64 = @intCast(decoded_arr.items.len);
        if (size_i64 < num_tokens) {
            if (diag) |d| {
                try d.setFmt(
                    allocator,
                    .deserialize_format,
                    "vocab_size {d} is smaller than the number of tokens {d}",
                    .{ size_i64, num_tokens },
                );
            }
            return error.Format;
        }
        const size: usize = std.math.cast(usize, size_i64) orelse return failFormatStatic(diag, "vocab_size");
        if (size_i64 > std.math.maxInt(i32)) return failFormatStatic(diag, "vocab_size");

        // Allocate ref-counted storage and decode directly into its arena (single copy).
        const storage = try allocator.create(TokenizerStorage);
        errdefer allocator.destroy(storage);
        storage.* = .{
            .refs = std.atomic.Value(usize).init(1),
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
        errdefer storage.arena.deinit();
        const a = storage.arena.allocator();

        var id_out_of_range = false;
        const stop_token_ids = try decodeU32IdArray(a, stop_arr.items, size_i64, &id_out_of_range, diag);
        const special_token_ids = try decodeU32IdArray(a, special_arr.items, size_i64, &id_out_of_range, diag);

        const decoded_vocab = try a.alloc([]const u8, decoded_arr.items.len);
        for (decoded_arr.items, 0..) |item, i| {
            const s = switch (item) {
                .string => |s| s,
                else => return failFormatStatic(diag, "decoded token"),
            };
            decoded_vocab[i] = encoding.latin1ToBytes(a, s) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return failFormatStatic(diag, "decoded token"),
            };
        }

        const sorted_decoded_vocab = try a.alloc(SortedDecodedToken, sorted_arr.items.len);
        for (sorted_arr.items, 0..) |entry, i| {
            const pair = switch (entry) {
                .array => |p| p,
                else => return failFormatStatic(diag, "sorted_decoded_vocab entry"),
            };
            if (pair.items.len != 2) return failFormatStatic(diag, "sorted_decoded_vocab entry");
            const id: i32 = switch (pair.items[0]) {
                .integer => |n| std.math.cast(i32, n) orelse return failFormatStatic(diag, "token id"),
                else => return failFormatStatic(diag, "token id"),
            };
            const tok_str = switch (pair.items[1]) {
                .string => |s| s,
                else => return failFormatStatic(diag, "sorted_decoded_vocab entry"),
            };
            const token = encoding.latin1ToBytes(a, tok_str) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return failFormatStatic(diag, "decoded token"),
            };
            sorted_decoded_vocab[i] = .{ .id = id, .token = token };
        }

        const trie_subtree_nodes_range = try a.alloc(i32, trie_arr.items.len);
        for (trie_arr.items, 0..) |item, i| {
            const n = switch (item) {
                .integer => |n| n,
                else => return failFormatStatic(diag, "expected array"),
            };
            trie_subtree_nodes_range[i] = std.math.cast(i32, n) orelse return failFormatStatic(diag, "expected array");
        }

        for (sorted_decoded_vocab) |entry| {
            if (entry.id < 0 or @as(i64, entry.id) >= num_tokens) {
                if (diag) |d| {
                    try d.setFmt(
                        allocator,
                        .deserialize_format,
                        "sorted_decoded_vocab contains token id {d} out of range",
                        .{entry.id},
                    );
                }
                return error.Format;
            }
        }
        if (trie_subtree_nodes_range.len != sorted_decoded_vocab.len) {
            return failFormatStatic(diag, "trie_subtree_nodes_range must have one entry per sorted token");
        }
        if (id_out_of_range) {
            return failFormatStatic(diag, "stop_token_ids or special_token_ids contains a token id out of range");
        }

        return withDerivedData(
            storage,
            vocab,
            size,
            prefix_space,
            decoded_vocab,
            sorted_decoded_vocab,
            trie_subtree_nodes_range,
            stop_token_ids,
            special_token_ids,
        );
    }
};

fn failFormatStatic(diag: ?*Diagnostic, msg: []const u8) DeserializeError {
    if (diag) |d| d.setStatic(.deserialize_format, msg);
    return error.Format;
}

fn decodeU32IdArray(
    a: Allocator,
    items: []const std.json.Value,
    vocab_size_i64: i64,
    id_out_of_range: *bool,
    diag: ?*Diagnostic,
) (DeserializeError || Allocator.Error)![]const u32 {
    const out = try a.alloc(u32, items.len);
    for (items, 0..) |item, i| {
        const n = switch (item) {
            .integer => |v| v,
            else => return failFormatStatic(diag, "expected array"),
        };
        if (n < 0 or n >= vocab_size_i64) {
            id_out_of_range.* = true;
        } else {
            out[i] = @intCast(n);
        }
    }
    return out;
}

/// Streams `bytes` as a Latin-1 JSON string directly to `jw` using stack buffering (no heap allocs).
fn writeLatin1JsonString(jw: *std.json.Stringify, bytes: []const u8) std.json.Stringify.Error!void {
    try jw.beginWriteRaw();
    try jw.writer.writeByte('"');
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(offset + 256, bytes.len);
        var buf: [512]u8 = undefined;
        var fw: std.Io.Writer = .fixed(&buf);
        encoding.writeLatin1(&fw, bytes[offset..end]) catch unreachable;
        try std.json.Stringify.encodeJsonStringChars(fw.buffered(), jw.options, jw.writer);
        offset = end;
    }
    try jw.writer.writeByte('"');
    jw.endWriteRaw();
}

/// Performs a 256-bucket MSD counting sort on `token[0]` into `out_alloc`, then sorts
/// each multi-element bucket by `(token[1..], id)`. Every entry in `unsorted` must be non-empty.
fn sortVocabBucketed(
    out_alloc: Allocator,
    unsorted: []const SortedDecodedToken,
    counts: *const [256]usize,
) Allocator.Error![]const SortedDecodedToken {
    const sorted = try out_alloc.alloc(SortedDecodedToken, unsorted.len);
    if (unsorted.len == 0) return sorted;

    var offsets: [256]usize = undefined;
    var total: usize = 0;
    for (counts.*, 0..) |c, b| {
        offsets[b] = total;
        total += c;
    }
    std.debug.assert(total == unsorted.len);

    var write_pos = offsets;
    for (unsorted) |entry| {
        std.debug.assert(entry.token.len > 0);
        const b = entry.token[0];
        sorted[write_pos[b]] = entry;
        write_pos[b] += 1;
    }

    const SortCtx = struct {
        fn lessThan(_: void, lhs: SortedDecodedToken, rhs: SortedDecodedToken) bool {
            return switch (std.mem.order(u8, lhs.token[1..], rhs.token[1..])) {
                .lt => true,
                .gt => false,
                .eq => lhs.id < rhs.id,
            };
        }
    };

    for (counts.*, 0..) |c, b| {
        if (c > 1) {
            const start = offsets[b];
            std.mem.sortUnstable(SortedDecodedToken, sorted[start .. start + c], {}, SortCtx.lessThan);
        }
    }
    return sorted;
}

/// Assembles tokenizer info and builds the derived per-token arrays (the reverse index and
/// the codepoint counts), which are not serialized.
fn withDerivedData(
    storage: *TokenizerStorage,
    vocab: VocabType,
    size: usize,
    prefix_space: bool,
    decoded_vocab: []const []const u8,
    sorted_decoded_vocab: []const SortedDecodedToken,
    trie_subtree_nodes_range: []const i32,
    stop_token_ids: []const u32,
    special_token_ids: []const u32,
) Allocator.Error!TokenizerInfo {
    const a = storage.arena.allocator();
    const token_id_to_sorted_vocab_index = try a.alloc(i32, size);
    @memset(token_id_to_sorted_vocab_index, -1);
    for (sorted_decoded_vocab, 0..) |entry, i| {
        token_id_to_sorted_vocab_index[@intCast(entry.id)] = @intCast(i);
    }
    const token_char_counts = try a.alloc(i32, sorted_decoded_vocab.len);
    var max_token_chars: i32 = 0;
    for (sorted_decoded_vocab, 0..) |entry, i| {
        var count: i32 = 0;
        for (entry.token) |byte| {
            if ((byte & 0xC0) != 0x80) count += 1;
        }
        token_char_counts[i] = count;
        if (count > max_token_chars) max_token_chars = count;
    }

    storage.vocab_type = vocab;
    storage.vocab_size = size;
    storage.add_prefix_space = prefix_space;
    storage.decoded_vocab = decoded_vocab;
    storage.sorted_decoded_vocab = sorted_decoded_vocab;
    storage.trie_subtree_nodes_range = trie_subtree_nodes_range;
    storage.stop_token_ids = stop_token_ids;
    storage.special_token_ids = special_token_ids;
    storage.token_id_to_sorted_vocab_index = token_id_to_sorted_vocab_index;
    storage.token_char_counts = token_char_counts;
    storage.max_token_chars = max_token_chars;
    return .{ .storage = storage };
}

/// Whether `needle` occurs as a contiguous subsequence of `haystack` (byte `find != npos`).
fn byteContains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// Builds the pseudo-trie subtree ranges over the sorted vocabulary.
/// Allocates `ranges` from `out_alloc` and temporary stack storage from `scratch_alloc`.
fn buildTrieRanges(
    out_alloc: Allocator,
    scratch_alloc: Allocator,
    sorted: []const SortedDecodedToken,
) Allocator.Error![]const i32 {
    const ranges = try out_alloc.alloc(i32, sorted.len);
    @memset(ranges, 0);
    // Sorted indices of the currently-active prefixes.
    var prefix_stack: std.ArrayList(usize) = .empty;
    defer prefix_stack.deinit(scratch_alloc);
    for (sorted, 0..) |entry, i| {
        while (prefix_stack.items.len > 0) {
            const top = prefix_stack.items[prefix_stack.items.len - 1];
            if (byteContains(entry.token, sorted[top].token)) break;
            ranges[top] = @intCast(i);
            _ = prefix_stack.pop();
        }
        try prefix_stack.append(scratch_alloc, i);
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
        var diag: Diagnostic = .{};
        defer diag.deinit(a);
        const result = TokenizerInfo.init(a, &.{ "a", "b" }, .{ .vocab_size = 1, .diag = &diag });
        try std.testing.expectError(error.VocabSizeTooSmall, result);
        try std.testing.expectEqual(Diagnostic.Kind.tokenizer_vocab_too_small, diag.kind);
        try std.testing.expectEqual(@as(i64, 1), diag.primary_num);
        try std.testing.expectEqual(@as(i64, 2), diag.secondary_num);
    }
    // basic construction with padding
    {
        var info = try TokenizerInfo.init(a, &.{ "hello", "world" }, .{ .vocab_size = 40 });
        defer info.deinit();
        try std.testing.expectEqual(@as(usize, 40), info.vocabSize());
        try std.testing.expectEqual(@as(usize, 2), info.decodedVocab().len);
        try std.testing.expectEqual(@as(usize, 2), info.sortedDecodedVocab().len);
        try std.testing.expectEqual(@as(usize, 0), info.stopTokenIds().len);
        // padding ids 2..39 are special
        try std.testing.expectEqual(@as(usize, 38), info.specialTokenIds().len);
        try std.testing.expectEqual(@as(u32, 2), info.specialTokenIds()[0]);
        try std.testing.expectEqual(@as(u32, 39), info.specialTokenIds()[37]);
        try std.testing.expectEqual(@as(i32, 5), info.maxTokenChars());
        // sorted: "hello" < "world"
        try std.testing.expectEqual(@as(i32, 0), info.sortedDecodedVocab()[0].id);
        try std.testing.expectEqual(@as(i32, 1), info.sortedDecodedVocab()[1].id);
        try std.testing.expectEqual(@as(i32, 0), info.tokenIdToSortedVocabIndex()[0]);
        try std.testing.expectEqual(@as(i32, 1), info.tokenIdToSortedVocabIndex()[1]);
        try std.testing.expectEqual(@as(i32, -1), info.tokenIdToSortedVocabIndex()[2]);
    }
    // default vocab_size is the vocab length
    {
        var info = try TokenizerInfo.init(a, &.{ "a", "b", "c" }, .{ .add_prefix_space = true });
        defer info.deinit();
        try std.testing.expectEqual(@as(usize, 3), info.vocabSize());
        try std.testing.expect(info.addPrefixSpace());
    }
}

test "stop token classification including >4 explicit ids bitset path" {
    const a = std.testing.allocator;
    // auto-detection
    {
        var info = try TokenizerInfo.init(a, &.{ "</s>", "<eos>", "word", "" }, .{});
        defer info.deinit();
        try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, info.stopTokenIds());
        // empty decoded token is special
        try std.testing.expectEqualSlices(u32, &.{3}, info.specialTokenIds());
    }
    // explicit stop ids <= 4 override detection
    {
        var info = try TokenizerInfo.init(a, &.{ "</s>", "<eos>", "word" }, .{ .stop_token_ids = &.{2} });
        defer info.deinit();
        try std.testing.expectEqualSlices(u32, &.{2}, info.stopTokenIds());
    }
    // explicit stop ids > 4 uses DynamicBitset and preserves ascending token-index order + dedup
    {
        var info = try TokenizerInfo.init(
            a,
            &.{ "t0", "t1", "t2", "t3", "t4", "t5", "t6", "t7" },
            .{ .stop_token_ids = &.{ 6, 1, 4, 2, 1, 0, 99 } },
        );
        defer info.deinit();
        try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 4, 6 }, info.stopTokenIds());
        try std.testing.expectEqual(@as(usize, 3), info.sortedDecodedVocab().len);
    }
}

test "byte fallback vocab decodes prefix-space and byte tokens" {
    const a = std.testing.allocator;
    var info = try TokenizerInfo.init(a, &.{ "<0x1B>", "▁apple", "plain" }, .{ .vocab_type = .byte_fallback });
    defer info.deinit();
    const dv = info.decodedVocab();
    try std.testing.expectEqualSlices(u8, &[1]u8{0x1B}, dv[0]);
    try std.testing.expectEqualStrings(" apple", dv[1]);
    try std.testing.expectEqualStrings("plain", dv[2]);
}

test "trie subtree ranges" {
    const a = std.testing.allocator;
    // sorted vocab: "a", "ab", "b" -> ranges [2, 2, 3]
    var info = try TokenizerInfo.init(a, &.{ "ab", "a", "b" }, .{});
    defer info.deinit();
    try std.testing.expectEqualSlices(i32, &.{ 2, 2, 3 }, info.trieSubtreeNodesRange());
}

test "256-bucket vocab sort matches full (token, id) sort" {
    const a = std.testing.allocator;
    const raw_tokens = [_][]const u8{
        "zz",
        "a",
        "ab",
        "a", // duplicate token with larger id
        "\x00",
        "\xff\x00",
        "\xff",
        "B",
        "b",
        "ab\x00",
        "apple",
        "ap",
        "a", // third duplicate
        "\x80hello",
        "\x7f",
        "!",
        "\"quote\"",
        "\\",
        "", // empty -> special
        "</s>", // auto stop -> excluded
    };

    var info = try TokenizerInfo.init(a, &raw_tokens, .{});
    defer info.deinit();

    // Build expected order via full-string (token, id) reference sort.
    var expected: std.ArrayList(SortedDecodedToken) = .empty;
    defer expected.deinit(a);
    for (raw_tokens, 0..) |tok, idx| {
        if (tok.len == 0 or std.mem.eql(u8, tok, "</s>")) continue;
        try expected.append(a, .{ .id = @intCast(idx), .token = tok });
    }
    std.mem.sortUnstable(SortedDecodedToken, expected.items, {}, struct {
        fn lessThan(_: void, lhs: SortedDecodedToken, rhs: SortedDecodedToken) bool {
            return switch (std.mem.order(u8, lhs.token, rhs.token)) {
                .lt => true,
                .gt => false,
                .eq => lhs.id < rhs.id,
            };
        }
    }.lessThan);

    const actual = info.sortedDecodedVocab();
    try std.testing.expectEqual(expected.items.len, actual.len);
    for (expected.items, actual) |exp, act| {
        try std.testing.expectEqual(exp.id, act.id);
        try std.testing.expectEqualSlices(u8, exp.token, act.token);
    }
}

test "fromVocabAndMetadata round trip and diagnostics" {
    const a = std.testing.allocator;
    var info = try TokenizerInfo.fromVocabAndMetadata(
        a,
        &.{ "<0x41>", "▁x" },
        "{\"vocab_type\":1,\"vocab_size\":40,\"add_prefix_space\":true,\"stop_token_ids\":[1]}",
        null,
    );
    defer info.deinit();
    try std.testing.expectEqual(VocabType.byte_fallback, info.vocabType());
    try std.testing.expectEqual(@as(usize, 40), info.vocabSize());
    try std.testing.expect(info.addPrefixSpace());
    try std.testing.expectEqualSlices(u32, &.{1}, info.stopTokenIds());

    // missing vocab_type is an error
    var diag: Diagnostic = .{};
    defer diag.deinit(a);
    const bad = TokenizerInfo.fromVocabAndMetadata(a, &.{"x"}, "{\"vocab_size\":3}", &diag);
    try std.testing.expectError(error.InvalidMetadata, bad);
    try std.testing.expectEqual(Diagnostic.Kind.message, diag.kind);
    try std.testing.expectEqualStrings("metadata missing vocab_type", diag.message);

    // metadata dump matches the same shape and exact lexicographic key order
    const dumped = try info.dumpMetadata(a);
    defer a.free(dumped);
    try std.testing.expectEqualStrings(
        "{\"add_prefix_space\":true,\"stop_token_ids\":[1],\"vocab_size\":40,\"vocab_type\":1}",
        dumped,
    );
    const parsed = try std.json.parseFromSlice(std.json.Value, a, dumped, .{});
    defer parsed.deinit();
    try info.checkMetadataMatch(parsed.value, null);

    // mismatch is detected with Diagnostic
    const wrong = try std.json.parseFromSlice(
        std.json.Value,
        a,
        "{\"vocab_type\":1,\"vocab_size\":30,\"add_prefix_space\":true,\"stop_token_ids\":[1]}",
        .{},
    );
    defer wrong.deinit();
    try std.testing.expectError(error.Format, info.checkMetadataMatch(wrong.value, &diag));
    try std.testing.expectEqual(Diagnostic.Kind.deserialize_format, diag.kind);
    try std.testing.expectEqualStrings("tokenizer metadata mismatch", diag.message);
}

test "serialize/deserialize round trip including special bytes and long tokens" {
    const a = std.testing.allocator;
    const long_tok: [300]u8 = @splat('x');
    var info = try TokenizerInfo.init(
        a,
        &.{ "<0xFF>", "▁ab", "</s>", "a\"b\\c\n", &long_tok },
        .{ .vocab_type = .byte_fallback, .vocab_size = 10, .add_prefix_space = true },
    );
    defer info.deinit();

    const serialized = try info.serializeJson(a);
    defer a.free(serialized);

    var restored = try TokenizerInfo.deserializeJson(a, serialized, null);
    defer restored.deinit();

    try std.testing.expectEqual(info.vocabType(), restored.vocabType());
    try std.testing.expectEqual(info.vocabSize(), restored.vocabSize());
    try std.testing.expectEqual(info.addPrefixSpace(), restored.addPrefixSpace());
    try std.testing.expectEqual(info.decodedVocab().len, restored.decodedVocab().len);
    for (info.decodedVocab(), restored.decodedVocab()) |l, r| {
        try std.testing.expectEqualSlices(u8, l, r);
    }
    try std.testing.expectEqual(info.sortedDecodedVocab().len, restored.sortedDecodedVocab().len);
    for (info.sortedDecodedVocab(), restored.sortedDecodedVocab()) |l, r| {
        try std.testing.expectEqual(l.id, r.id);
        try std.testing.expectEqualSlices(u8, l.token, r.token);
    }
    try std.testing.expectEqualSlices(i32, info.trieSubtreeNodesRange(), restored.trieSubtreeNodesRange());
    try std.testing.expectEqualSlices(u32, info.stopTokenIds(), restored.stopTokenIds());
    try std.testing.expectEqualSlices(u32, info.specialTokenIds(), restored.specialTokenIds());
    try std.testing.expectEqualSlices(i32, info.tokenIdToSortedVocabIndex(), restored.tokenIdToSortedVocabIndex());
    try std.testing.expectEqualSlices(i32, info.tokenCharCounts(), restored.tokenCharCounts());
    try std.testing.expectEqual(info.maxTokenChars(), restored.maxTokenChars());

    // version mismatch
    var diag: Diagnostic = .{};
    defer diag.deinit(a);
    try std.testing.expectError(error.Version, TokenizerInfo.deserializeJson(a, "{\"__VERSION__\":\"v15\"}", &diag));
    try std.testing.expectEqual(Diagnostic.Kind.deserialize_version, diag.kind);
    try std.testing.expectEqualStrings("v15", diag.got);
    try std.testing.expectEqualStrings(config.serialization_version, diag.expected);

    // missing version
    try std.testing.expectError(error.Format, TokenizerInfo.deserializeJson(a, "{}", &diag));
    try std.testing.expectEqual(Diagnostic.Kind.deserialize_format, diag.kind);

    // invalid json
    try std.testing.expectError(error.InvalidJson, TokenizerInfo.deserializeJson(a, "{", &diag));
    try std.testing.expectEqual(Diagnostic.Kind.deserialize_invalid_json, diag.kind);

    // error-path leak checks on malformed serialized inputs after storage allocation
    try std.testing.expectError(
        error.Format,
        TokenizerInfo.deserializeJson(
            a,
            "{\"__VERSION__\":\"v16\",\"vocab_type\":0,\"vocab_size\":2,\"add_prefix_space\":false,\"stop_token_ids\":[9],\"special_token_ids\":[],\"decoded_vocab\":[\"a\",\"b\"],\"sorted_decoded_vocab\":[[0,\"a\"],[1,\"b\"]],\"trie_subtree_nodes_range\":[1,2]}",
            &diag,
        ),
    );
    try std.testing.expectError(
        error.Format,
        TokenizerInfo.deserializeJson(
            a,
            "{\"__VERSION__\":\"v16\",\"vocab_type\":0,\"vocab_size\":2,\"add_prefix_space\":false,\"stop_token_ids\":[],\"special_token_ids\":[],\"decoded_vocab\":[\"a\",\"b\"],\"sorted_decoded_vocab\":[[5,\"a\"],[1,\"b\"]],\"trie_subtree_nodes_range\":[1,2]}",
            &diag,
        ),
    );
    try std.testing.expectError(
        error.Format,
        TokenizerInfo.deserializeJson(
            a,
            "{\"__VERSION__\":\"v16\",\"vocab_type\":0,\"vocab_size\":1,\"add_prefix_space\":false,\"stop_token_ids\":[],\"special_token_ids\":[],\"decoded_vocab\":[\"a\",\"b\"],\"sorted_decoded_vocab\":[],\"trie_subtree_nodes_range\":[]}",
            &diag,
        ),
    );

    // empty vocabulary round trip + exact JSON key order verification
    {
        var empty_tok = try TokenizerInfo.init(a, &.{}, .{});
        defer empty_tok.deinit();
        const empty_json = try empty_tok.serializeJson(a);
        defer a.free(empty_json);
        try std.testing.expectEqualStrings(
            "{\"__VERSION__\":\"v16\",\"add_prefix_space\":false,\"decoded_vocab\":[],\"sorted_decoded_vocab\":[],\"special_token_ids\":[],\"stop_token_ids\":[],\"trie_subtree_nodes_range\":[],\"vocab_size\":0,\"vocab_type\":0}",
            empty_json,
        );
        var restored_empty = try TokenizerInfo.deserializeJson(a, empty_json, null);
        defer restored_empty.deinit();
        try std.testing.expectEqual(@as(usize, 0), restored_empty.vocabSize());
        try std.testing.expectEqual(@as(i32, 0), restored_empty.maxTokenChars());
    }
}

test "detectMetadataFromHf wrapper" {
    const a = std.testing.allocator;
    const json = try TokenizerInfo.detectMetadataFromHf(a, "{\"decoder\":{\"type\":\"ByteLevel\"}}");
    defer a.free(json);
    try std.testing.expectEqualStrings("{\"add_prefix_space\":false,\"vocab_type\":2}", json);
}

test "retain shares ref-counted storage and dupe decouples" {
    const a = std.testing.allocator;
    var original = try TokenizerInfo.init(a, &.{ "alpha", "beta", "</s>" }, .{});
    var shared_a = original.retain();
    var shared_b = shared_a.retain();
    try std.testing.expect(original.sharesStorage(&shared_a));
    try std.testing.expect(shared_a.sharesStorage(&shared_b));

    var deep = try original.dupe(a);
    try std.testing.expect(!original.sharesStorage(&deep));
    try std.testing.expectEqualStrings("alpha", shared_b.decodedVocab()[0]);
    try std.testing.expectEqualStrings("beta", deep.decodedVocab()[1]);

    // Drop original before shared handles; backing arena survives until last ref drops.
    original.deinit();
    shared_a.deinit();
    try std.testing.expectEqualStrings("beta", shared_b.decodedVocab()[1]);
    shared_b.deinit();
    deep.deinit();
}

test {
    std.testing.refAllDecls(TokenizerInfo);
}
