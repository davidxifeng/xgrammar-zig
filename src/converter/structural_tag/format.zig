//! Intermediate representation for parsed structural tags, arena ownership, and
//! comptime-generic structural equality and hashing (`structural_tag_format.rs`,
//! `structural_tag_item.rs`, `any_text_format.rs`, `any_tokens_format.rs`,
//! `json_schema_format.rs`).
//!
//! Every parsed `Format` tree—strings, slices, `std.ArrayList` buffers, boxed `*Format`
//! nodes, and resolver/analyzer-populated metadata—lives inside an `ArenaAllocator`
//! (either owned by `ParsedFormat` or supplied by the caller). All fields participate in
//! `structuralEql` and `structuralHash` so the converter can deduplicate identical
//! sub-formats without manual recursive `eql`, `hash`, `clone`, or `deinit` boilerplate.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Legacy structural-tag item (`begin` / `schema` / `end`).
///
/// Prefer the JSON structural-tag document + converter; retained for API parity with
/// `xgrammar::StructuralTagItem`.
pub const StructuralTagItem = struct {
    /// Opening tag text.
    begin: []const u8,
    /// JSON schema (as a string) between the tags.
    schema: []const u8,
    /// Closing tag text.
    end: []const u8,
};

/// A token reference: a literal id or a vocabulary string (resolved to an id later).
pub const IntOrString = union(enum) {
    int: i32,
    str: []const u8,

    pub fn eql(a: IntOrString, b: IntOrString) bool {
        return structuralEql(a, b);
    }

    pub fn hash(self: IntOrString, hasher: anytype) void {
        structuralHash(hasher, self);
    }
};

/// `{"type":"const_string","value":...}`
pub const ConstStringFormat = struct {
    value: []const u8,
};

/// `{"type":"json_schema","json_schema":...,"style":...}` (the schema is stored serialized).
pub const JsonSchemaFormat = struct {
    json_schema: []const u8,
    /// One of the `JsonFormat` names.
    style: []const u8,
    any_order: bool = false,
    /// Per-tag cap on consecutive whitespace characters.
    max_whitespace_cnt: ?i32 = null,
    /// Substrings forbidden within string values and property names (sorted, deduplicated).
    excludes: []const []const u8 = &.{},
};

/// `{"type":"any_text","excludes":[...],"max_tokens":...,"max_chars":...}`;
/// `detected_end_strs` is filled by the analyzer.
pub const AnyTextFormat = struct {
    excludes: std.ArrayList([]const u8) = .empty,
    /// Token budget of the text.
    max_tokens: ?i32 = null,
    /// Character budget of the text.
    max_chars: ?i32 = null,
    detected_end_strs: std.ArrayList([]const u8) = .empty,
};

/// `{"type":"grammar","grammar":<ebnf>}`
pub const GrammarFormat = struct {
    grammar: []const u8,
};

/// `{"type":"regex","pattern":<regex>}`
pub const RegexFormat = struct {
    pattern: []const u8,
};

pub const SequenceFormat = struct {
    elements: std.ArrayList(Format) = .empty,
    is_unlimited: bool = false,
};

pub const OrFormat = struct {
    elements: std.ArrayList(Format) = .empty,
    is_unlimited: bool = false,
};

/// A tag's begin marker: a literal string or a token.
pub const TagBegin = union(enum) {
    str: []const u8,
    token: TokenFormat,
};

/// A tag's end marker: a set of literal strings or a token.
pub const TagEnd = union(enum) {
    strings: std.ArrayList([]const u8),
    token: TokenFormat,
};

pub const TagFormat = struct {
    begin: TagBegin,
    content: *Format,
    end: TagEnd,
};

pub const TriggeredTagsFormat = struct {
    triggers: std.ArrayList([]const u8) = .empty,
    tags: std.ArrayList(TagFormat) = .empty,
    excludes: std.ArrayList([]const u8) = .empty,
    at_least_one: bool = false,
    stop_after_first: bool = false,
    detected_end_strs: std.ArrayList([]const u8) = .empty,
};

pub const TagsWithSeparatorFormat = struct {
    tags: std.ArrayList(TagFormat) = .empty,
    separator: []const u8 = "",
    at_least_one: bool = false,
    stop_after_first: bool = false,
};

pub const OptionalFormat = struct {
    content: *Format,
};

pub const PlusFormat = struct {
    content: *Format,
};

pub const StarFormat = struct {
    content: *Format,
};

/// `max == -1` is unbounded.
pub const RepeatFormat = struct {
    min: i32,
    max: i32,
    content: *Format,
};

pub const TokenFormat = struct {
    token: IntOrString,
    resolved_token_id: i32,

    pub fn init(token: IntOrString) TokenFormat {
        // An integer token is its own resolved id; a string token resolves later.
        const resolved_token_id = switch (token) {
            .int => |i| i,
            .str => -1,
        };
        return .{ .token = token, .resolved_token_id = resolved_token_id };
    }
};

pub const ExcludeTokenFormat = struct {
    exclude_tokens: std.ArrayList(IntOrString) = .empty,
    resolved_token_ids: std.ArrayList(i32) = .empty,
    detected_end_token_ids: std.ArrayList(i32) = .empty,
};

/// `{"type":"any_tokens","exclude_tokens":[...],"max_tokens":...}`.
pub const AnyTokensFormat = struct {
    exclude_tokens: std.ArrayList(IntOrString) = .empty,
    /// Token budget of the token run.
    max_tokens: ?i32 = null,
    resolved_exclude_token_ids: std.ArrayList(i32) = .empty,
    detected_end_token_ids: std.ArrayList(i32) = .empty,
};

pub const TokenTriggeredTagsFormat = struct {
    trigger_tokens: std.ArrayList(IntOrString) = .empty,
    tags: std.ArrayList(TagFormat) = .empty,
    exclude_tokens: std.ArrayList(IntOrString) = .empty,
    at_least_one: bool = false,
    stop_after_first: bool = false,
    resolved_trigger_token_ids: std.ArrayList(i32) = .empty,
    resolved_exclude_token_ids: std.ArrayList(i32) = .empty,
    detected_end_token_ids: std.ArrayList(i32) = .empty,
};

pub const DispatchFormat = struct {
    rules: std.ArrayList(Rule) = .empty,
    loop_after_dispatch: bool = false,
    excludes: std.ArrayList([]const u8) = .empty,

    /// `(trigger, content)` rule entry.
    pub const Rule = struct {
        trigger: []const u8,
        content: *Format,
    };
};

pub const TokenDispatchFormat = struct {
    rules: std.ArrayList(Rule) = .empty,
    loop_after_dispatch: bool = false,
    exclude_tokens: std.ArrayList(IntOrString) = .empty,
    resolved_trigger_token_ids: std.ArrayList(i32) = .empty,
    resolved_exclude_token_ids: std.ArrayList(i32) = .empty,

    /// `(trigger, content)` rule entry.
    pub const Rule = struct {
        trigger: IntOrString,
        content: *Format,
    };
};

/// Tagged union of all structural-tag format kinds.
pub const Format = union(enum) {
    const_string: ConstStringFormat,
    json_schema: JsonSchemaFormat,
    any_text: AnyTextFormat,
    grammar: GrammarFormat,
    regex: RegexFormat,
    sequence: SequenceFormat,
    or_fmt: OrFormat,
    tag: TagFormat,
    triggered_tags: TriggeredTagsFormat,
    tags_with_separator: TagsWithSeparatorFormat,
    optional: OptionalFormat,
    plus: PlusFormat,
    star: StarFormat,
    repeat: RepeatFormat,
    token: TokenFormat,
    exclude_token: ExcludeTokenFormat,
    any_tokens: AnyTokensFormat,
    token_triggered_tags: TokenTriggeredTagsFormat,
    dispatch: DispatchFormat,
    token_dispatch: TokenDispatchFormat,

    /// Deep structural equality by content.
    pub fn eql(a: *const Format, b: *const Format) bool {
        return structuralEql(a.*, b.*);
    }

    /// Deep structural hash matching `eql`.
    pub fn hash(self: *const Format, hasher: anytype) void {
        structuralHash(hasher, self.*);
    }
};

/// Owning wrapper pairing a parsed `Format` tree with the `ArenaAllocator` holding all
/// of its strings, slices, boxed nodes, lists, and resolved/analyzed metadata.
pub const ParsedFormat = struct {
    arena_state: std.heap.ArenaAllocator,
    root: Format,

    pub fn deinit(self: *ParsedFormat) void {
        self.arena_state.deinit();
        self.* = undefined;
    }

    pub fn allocator(self: *ParsedFormat) Allocator {
        return self.arena_state.allocator();
    }
};

/// HashMap context for deduplicating `Format` subtrees by content.
/// Keys remain valid as long as the backing `Format` arena outlives the map.
pub const FormatHashContext = struct {
    pub fn hash(_: FormatHashContext, key: Format) u64 {
        var hasher = std.hash.Wyhash.init(0);
        structuralHash(&hasher, key);
        return hasher.final();
    }

    pub fn eql(_: FormatHashContext, a: Format, b: Format) bool {
        return structuralEql(a, b);
    }
};

fn isArrayList(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    if (!@hasField(T, "items") or !@hasField(T, "capacity") or !@hasDecl(T, "Slice")) return false;
    const SliceT = @FieldType(T, "items");
    const slice_info = @typeInfo(SliceT);
    if (slice_info != .pointer or slice_info.pointer.size != .slice) return false;
    return T == std.ArrayList(slice_info.pointer.child);
}

/// Comptime-generic deep structural equality across strings (`[]const u8`), slices,
/// `std.ArrayList`, single-item pointers, optionals, tagged unions, structs, and scalars.
///
/// Unlike `std.meta.eql`, byte slices compare contents, non-byte slices and `ArrayList`s
/// compare elements in order (ignoring `ArrayList.capacity`), and single-item pointers
/// dereference recursively.
pub fn structuralEql(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    if (comptime isArrayList(T)) {
        const Elem = std.meta.Elem(@FieldType(T, "items"));
        return structuralEql(@as([]const Elem, a.items), @as([]const Elem, b.items));
    }
    switch (@typeInfo(T)) {
        .void, .null => return true,
        .bool, .int, .comptime_int, .@"enum", .enum_literal => return a == b,
        .float, .comptime_float => return a == b,
        .optional => {
            if (a) |av| {
                if (b) |bv| return structuralEql(av, bv);
                return false;
            }
            return b == null;
        },
        .pointer => |ptr| switch (ptr.size) {
            .one => return structuralEql(a.*, b.*),
            .slice => {
                if (ptr.child == u8) return std.mem.eql(u8, a, b);
                if (a.len != b.len) return false;
                for (a, b) |x, y| {
                    if (!structuralEql(x, y)) return false;
                }
                return true;
            },
            else => @compileError("structuralEql does not support pointer type " ++ @typeName(T)),
        },
        .array => |arr| {
            if (arr.child == u8) return std.mem.eql(u8, &a, &b);
            for (a, b) |x, y| {
                if (!structuralEql(x, y)) return false;
            }
            return true;
        },
        .@"struct" => |st| {
            inline for (st.field_names) |field_name| {
                if (!structuralEql(@field(a, field_name), @field(b, field_name))) return false;
            }
            return true;
        },
        .@"union" => |un| {
            if (un.tag_type == null) @compileError("structuralEql requires a tagged union, got " ++ @typeName(T));
            const tag_a = std.meta.activeTag(a);
            const tag_b = std.meta.activeTag(b);
            if (tag_a != tag_b) return false;
            switch (tag_a) {
                inline else => |tag| return structuralEql(@field(a, @tagName(tag)), @field(b, @tagName(tag))),
            }
        },
        else => @compileError("structuralEql does not support type " ++ @typeName(T)),
    }
}

/// Comptime-generic structural hashing paired with `structuralEql`.
///
/// Guarantees:
/// - `[]const u8` hashes length prefix + bytes (never slice pointer addresses).
/// - Non-byte slices and `std.ArrayList` hash `.len` followed by elements recursively.
/// - Single-item pointers dereference recursively.
/// - Tagged unions hash `@intFromEnum(std.meta.activeTag(value))` before active payload.
/// - Optionals hash `0` for `null` and `1` + payload when present.
/// - Floats normalize `-0.0` to `+0.0` so hash matches IEEE equality (`-0.0 == +0.0`).
pub fn structuralHash(hasher: anytype, value: anytype) void {
    const T = @TypeOf(value);
    if (comptime isArrayList(T)) {
        const Elem = std.meta.Elem(@FieldType(T, "items"));
        structuralHash(hasher, @as([]const Elem, value.items));
        return;
    }
    switch (@typeInfo(T)) {
        .void, .null => {},
        .bool => hasher.update(&.{@intFromBool(value)}),
        .int => |info| {
            if (info.bits == 0) return;
            const byte_len = (info.bits + 7) / 8;
            const ByteInt = @Int(.unsigned, byte_len * 8);
            const UnsignedT = @Int(.unsigned, info.bits);
            var buf: [byte_len]u8 = undefined;
            std.mem.writeInt(ByteInt, &buf, @as(ByteInt, @as(UnsignedT, @bitCast(value))), .little);
            hasher.update(&buf);
        },
        .comptime_int => structuralHash(hasher, @as(i128, value)),
        .float => |info| {
            const norm: T = if (value == 0) 0 else value;
            const Bits = @Int(.unsigned, info.bits);
            structuralHash(hasher, @as(Bits, @bitCast(norm)));
        },
        .comptime_float => structuralHash(hasher, @as(f64, value)),
        .@"enum" => structuralHash(hasher, @backingInt(value)),
        .enum_literal => structuralHash(hasher, @tagName(value)),
        .optional => {
            if (value) |v| {
                hasher.update(&.{1});
                structuralHash(hasher, v);
            } else {
                hasher.update(&.{0});
            }
        },
        .pointer => |ptr| switch (ptr.size) {
            .one => structuralHash(hasher, value.*),
            .slice => {
                structuralHash(hasher, @as(u64, value.len));
                if (ptr.child == u8) {
                    hasher.update(value);
                } else {
                    for (value) |item| {
                        structuralHash(hasher, item);
                    }
                }
            },
            else => @compileError("structuralHash does not support pointer type " ++ @typeName(T)),
        },
        .array => |arr| {
            structuralHash(hasher, @as(u64, value.len));
            if (arr.child == u8) {
                hasher.update(&value);
            } else {
                for (value) |item| {
                    structuralHash(hasher, item);
                }
            }
        },
        .@"struct" => |st| {
            inline for (st.field_names) |field_name| {
                structuralHash(hasher, @field(value, field_name));
            }
        },
        .@"union" => |un| {
            if (un.tag_type == null) @compileError("structuralHash requires a tagged union, got " ++ @typeName(T));
            const tag = std.meta.activeTag(value);
            structuralHash(hasher, @backingInt(tag));
            switch (tag) {
                inline else => |t| structuralHash(hasher, @field(value, @tagName(t))),
            }
        },
        else => @compileError("structuralHash does not support type " ++ @typeName(T)),
    }
}

fn hashValue(value: anytype) u64 {
    var hasher = std.hash.Wyhash.init(0);
    structuralHash(&hasher, value);
    return hasher.final();
}

test "structuralEql and structuralHash distinguish slices, ArrayLists, pointers, optionals, unions, and -0.0" {
    const a = std.testing.allocator;

    // 1. Byte slices compare by content, not pointer address, even for distinct allocations.
    const s1 = try a.dupe(u8, "hello");
    defer a.free(s1);
    const s2 = try a.dupe(u8, "hello");
    defer a.free(s2);
    const s3 = try a.dupe(u8, "world");
    defer a.free(s3);
    try std.testing.expect(s1.ptr != s2.ptr);
    try std.testing.expect(structuralEql(@as([]const u8, s1), @as([]const u8, s2)));
    try std.testing.expectEqual(hashValue(@as([]const u8, s1)), hashValue(@as([]const u8, s2)));
    try std.testing.expect(!structuralEql(@as([]const u8, s1), @as([]const u8, s3)));

    // 2. Non-byte slices / ArrayLists: capacity ignored, order and length boundaries preserved.
    var list_a: std.ArrayList([]const u8) = .empty;
    defer list_a.deinit(a);
    try list_a.ensureTotalCapacity(a, 2);
    try list_a.append(a, "ab");
    try list_a.append(a, "c");

    var list_b: std.ArrayList([]const u8) = .empty;
    defer list_b.deinit(a);
    try list_b.ensureTotalCapacity(a, 32);
    const ab_copy = try a.dupe(u8, "ab");
    defer a.free(ab_copy);
    try list_b.append(a, ab_copy);
    try list_b.append(a, "c");

    try std.testing.expect(list_a.capacity != list_b.capacity);
    try std.testing.expect(structuralEql(list_a, list_b));
    try std.testing.expectEqual(hashValue(list_a), hashValue(list_b));

    // Boundary check: ["ab", "c"] != ["a", "bc"] and ([] + ["a"]) != (["a"] + [])
    const SplitPair = struct { left: []const []const u8, right: []const []const u8 };
    const p1 = SplitPair{ .left = &.{}, .right = &.{"a"} };
    const p2 = SplitPair{ .left = &.{"a"}, .right = &.{} };
    try std.testing.expect(!structuralEql(p1, p2));
    try std.testing.expect(hashValue(p1) != hashValue(p2));

    const boundary1: []const []const u8 = &.{ "ab", "c" };
    const boundary2: []const []const u8 = &.{ "a", "bc" };
    try std.testing.expect(!structuralEql(boundary1, boundary2));
    try std.testing.expect(hashValue(boundary1) != hashValue(boundary2));

    // 3. Optionals: null vs present, and -0.0 == +0.0 hash consistency.
    const OptPair = struct { x: ?i32, y: ?i32 };
    try std.testing.expect(!structuralEql(OptPair{ .x = null, .y = 0 }, OptPair{ .x = 0, .y = null }));
    try std.testing.expect(hashValue(OptPair{ .x = null, .y = 0 }) != hashValue(OptPair{ .x = 0, .y = null }));

    const neg_zero: f64 = -0.0;
    const pos_zero: f64 = 0.0;
    try std.testing.expect(structuralEql(neg_zero, pos_zero));
    try std.testing.expectEqual(hashValue(neg_zero), hashValue(pos_zero));

    // 4. Tagged unions and pointers (*Format) with resolved/detected metadata.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    const inner1 = try aa.create(Format);
    inner1.* = .{ .const_string = .{ .value = try aa.dupe(u8, "x") } };
    const inner2 = try aa.create(Format);
    inner2.* = .{ .const_string = .{ .value = try aa.dupe(u8, "x") } };
    try std.testing.expect(inner1 != inner2);

    const f1 = Format{ .optional = .{ .content = inner1 } };
    const f2 = Format{ .optional = .{ .content = inner2 } };
    const f3 = Format{ .plus = .{ .content = inner2 } };

    try std.testing.expect(f1.eql(&f2));
    try std.testing.expectEqual(hashValue(f1), hashValue(f2));
    try std.testing.expect(!f1.eql(&f3));
    try std.testing.expect(hashValue(f1) != hashValue(f3));

    // Resolved/detected fields participate in equality/hash.
    var at1 = AnyTextFormat{ .max_tokens = 5 };
    try at1.detected_end_strs.append(aa, "</end>");
    var at2 = AnyTextFormat{ .max_tokens = 5 };
    try at2.detected_end_strs.append(aa, "</other>");
    try std.testing.expect(!structuralEql(Format{ .any_text = at1 }, Format{ .any_text = at2 }));
    try std.testing.expect(hashValue(Format{ .any_text = at1 }) != hashValue(Format{ .any_text = at2 }));

    // FormatHashContext in HashMapUnmanaged
    var map: std.HashMapUnmanaged(Format, i32, FormatHashContext, 80) = .empty;
    defer map.deinit(a);
    try map.put(a, f1, 42);
    try std.testing.expectEqual(@as(?i32, 42), map.get(f2));
    try std.testing.expectEqual(@as(?i32, null), map.get(f3));
}
