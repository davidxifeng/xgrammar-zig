//! Data model and supporting structures for JSON Schema conversion:
//! `JsonFormat`, `KeyTrie` (compact flat node pool), `IndentManager`, and the
//! `SchemaSpec` intermediate representation.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------
// 1. JsonFormat
// ---------------------------------------------------------------------------

/// How the converted grammar encodes a JSON Schema instance.
///
/// `.json` produces plain JSON. The XML styles encode the root object as a
/// model-specific tool-call parameter list while nested values stay JSON (MiniMax-M3
/// and Cohere encode nested objects and arrays recursively in their own tags).
pub const JsonFormat = enum {
    /// Plain JSON.
    json,
    /// `<parameter=name>value</parameter>`.
    qwen_xml,
    /// `<parameter name="name">value</parameter>`.
    minimax_xml,
    /// DeepSeek DSML parameters with a `string` attribute.
    deepseek_xml,
    /// `<arg_key>name</arg_key><arg_value>value</arg_value>`.
    glm_xml,
    /// Recursive Cohere `<cofl:value>` tags.
    cohere_xml,
    /// Kimi-K3 `<|open|>argument key=".." type=".."<|sep|>` parameters.
    kimi_k3_xml,
    /// MiniMax-M3 namespace-prefixed recursive elements.
    minimax_m3_xml,
    /// DeepSeek V4.1 DSML parameters.
    deepseek_v4_1_xml,

    const name_map = std.StaticStringMap(JsonFormat).initComptime(.{
        .{ "json", .json },
        .{ "qwen_xml", .qwen_xml },
        .{ "minimax_xml", .minimax_xml },
        .{ "minimax_m3_xml", .minimax_m3_xml },
        .{ "deepseek_xml", .deepseek_xml },
        .{ "deepseek_v4_1_xml", .deepseek_v4_1_xml },
        .{ "glm_xml", .glm_xml },
        .{ "cohere_xml", .cohere_xml },
        .{ "kimi_k3_xml", .kimi_k3_xml },
    });

    /// Parses a format name (`"json"`, `"qwen_xml"`, `"minimax_xml"`, `"minimax_m3_xml"`,
    /// `"deepseek_xml"`, `"deepseek_v4_1_xml"`, `"glm_xml"`, `"cohere_xml"`, or
    /// `"kimi_k3_xml"`).
    pub fn fromName(name: []const u8) ?JsonFormat {
        return name_map.get(name);
    }

    /// Whether this is one of the DeepSeek DSML styles.
    pub fn isDeepseek(self: JsonFormat) bool {
        return self == .deepseek_xml or self == .deepseek_v4_1_xml;
    }
};

// ---------------------------------------------------------------------------
// 2. KeyTrie (compact flat node pool)
// ---------------------------------------------------------------------------

/// A compact prefix trie over byte property-name spellings, stored as a flat node pool.
///
/// Each node maintains sorted `(byte, child_index)` edges so iteration happens in exact
/// ascending byte order without allocating a 256-entry child pointer array per node.
pub const KeyTrie = struct {
    pub const Edge = struct {
        byte: u8,
        child: u32,
    };

    pub const Node = struct {
        is_terminal: bool = false,
        edges: std.ArrayList(Edge) = .empty,
    };

    nodes: std.ArrayList(Node) = .empty,

    pub const empty: KeyTrie = .{};

    /// Builds the trie of `keys` in a flat pool backed by `allocator`.
    pub fn build(allocator: Allocator, keys: []const []const u8) Allocator.Error!KeyTrie {
        var trie: KeyTrie = .empty;
        errdefer trie.deinit(allocator);
        try trie.nodes.append(allocator, .{});
        for (keys) |key| {
            var node_idx: u32 = 0;
            for (key) |unit| {
                node_idx = try trie.getOrInsertChild(allocator, node_idx, unit);
            }
            trie.nodes.items[node_idx].is_terminal = true;
        }
        return trie;
    }

    /// Releases all node edge lists and the node pool.
    pub fn deinit(self: *KeyTrie, allocator: Allocator) void {
        for (self.nodes.items) |*n| n.edges.deinit(allocator);
        self.nodes.deinit(allocator);
        self.* = .empty;
    }

    pub inline fn rootIndex(_: *const KeyTrie) u32 {
        return 0;
    }

    pub inline fn node(self: *const KeyTrie, index: u32) *const Node {
        return &self.nodes.items[index];
    }

    /// Returns whether `key` is stored as a terminal word in this trie.
    pub fn contains(self: *const KeyTrie, key: []const u8) bool {
        if (self.nodes.items.len == 0) return false;
        var node_idx: u32 = 0;
        for (key) |unit| {
            const edges = self.nodes.items[node_idx].edges.items;
            const pos = findEdge(edges, unit);
            if (!pos.found) return false;
            node_idx = edges[pos.index].child;
        }
        return self.nodes.items[node_idx].is_terminal;
    }

    const EdgeSearch = struct { found: bool, index: usize };

    fn findEdge(edges: []const Edge, byte: u8) EdgeSearch {
        var lo: usize = 0;
        var hi: usize = edges.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (edges[mid].byte < byte) {
                lo = mid + 1;
            } else if (edges[mid].byte > byte) {
                hi = mid;
            } else {
                return .{ .found = true, .index = mid };
            }
        }
        return .{ .found = false, .index = lo };
    }

    fn getOrInsertChild(self: *KeyTrie, allocator: Allocator, parent_idx: u32, byte: u8) Allocator.Error!u32 {
        const search = findEdge(self.nodes.items[parent_idx].edges.items, byte);
        if (search.found) {
            return self.nodes.items[parent_idx].edges.items[search.index].child;
        }
        const child_idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(allocator, .{});
        try self.nodes.items[parent_idx].edges.insert(allocator, search.index, .{
            .byte = byte,
            .child = child_idx,
        });
        return child_idx;
    }
};

// ---------------------------------------------------------------------------
// 3. IndentManager
// ---------------------------------------------------------------------------

/// Produces the separator/whitespace fragments for array and object generation.
/// All returned slices are allocated from `self.allocator` and owned by the caller.
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
        const sep_copy = try allocator.dupe(u8, separator);
        errdefer allocator.free(sep_copy);
        var is_first: std.ArrayList(bool) = .empty;
        errdefer is_first.deinit(allocator);
        try is_first.append(allocator, true);
        return .{
            .allocator = allocator,
            .any_whitespace = any_whitespace,
            .enable_newline = indent != null,
            .indent = indent orelse 0,
            .separator = sep_copy,
            .is_first = is_first,
            .max_whitespace_cnt = max_whitespace_cnt,
        };
    }

    pub fn deinit(self: *IndentManager) void {
        self.allocator.free(self.separator);
        self.is_first.deinit(self.allocator);
    }

    /// The JSON whitespace character class, optionally bounded to `max_whitespace_cnt`.
    pub fn whitespacePattern(allocator: Allocator, max_whitespace_cnt: ?i32) Allocator.Error![]u8 {
        if (max_whitespace_cnt) |n| {
            return std.fmt.allocPrint(allocator, "[ \\n\\r\\t]{{0,{d}}}", .{n});
        }
        return allocator.dupe(u8, "[ \\n\\r\\t]*");
    }

    pub fn startIndent(self: *IndentManager) Allocator.Error!void {
        self.total_indent += self.indent;
        try self.is_first.append(self.allocator, true);
    }

    pub fn endIndent(self: *IndentManager) void {
        self.total_indent -= self.indent;
        _ = self.is_first.pop();
    }

    pub fn startSeparator(self: *IndentManager) Allocator.Error![]u8 {
        if (self.any_whitespace) {
            return whitespacePattern(self.allocator, self.max_whitespace_cnt);
        }
        if (!self.enable_newline) {
            return self.allocator.dupe(u8, "\"\"");
        }
        const pad = try spaces(self.allocator, @max(self.total_indent, 0));
        defer self.allocator.free(pad);
        return std.fmt.allocPrint(self.allocator, "\"\\n{s}\"", .{pad});
    }

    pub fn middleSeparator(self: *IndentManager) Allocator.Error![]u8 {
        if (self.any_whitespace) {
            const ws = try whitespacePattern(self.allocator, self.max_whitespace_cnt);
            defer self.allocator.free(ws);
            return std.fmt.allocPrint(self.allocator, "{s} \"{s}\" {s}", .{ ws, self.separator, ws });
        }
        if (!self.enable_newline) {
            return std.fmt.allocPrint(self.allocator, "\"{s}\"", .{self.separator});
        }
        const pad = try spaces(self.allocator, @max(self.total_indent, 0));
        defer self.allocator.free(pad);
        return std.fmt.allocPrint(self.allocator, "\"{s}\\n{s}\"", .{ self.separator, pad });
    }

    pub fn endSeparator(self: *IndentManager) Allocator.Error![]u8 {
        if (self.any_whitespace) {
            return whitespacePattern(self.allocator, self.max_whitespace_cnt);
        }
        if (!self.enable_newline) {
            return self.allocator.dupe(u8, "\"\"");
        }
        const pad = try spaces(self.allocator, @max(self.total_indent - self.indent, 0));
        defer self.allocator.free(pad);
        return std.fmt.allocPrint(self.allocator, "\"\\n{s}\"", .{pad});
    }

    pub fn emptySeparator(self: *IndentManager) Allocator.Error![]u8 {
        if (self.any_whitespace) {
            return whitespacePattern(self.allocator, self.max_whitespace_cnt);
        }
        return self.allocator.dupe(u8, "\"\"");
    }

    pub fn nextSeparator(self: *IndentManager, is_end: bool) Allocator.Error![]u8 {
        const is_first = &self.is_first.items[self.is_first.items.len - 1];
        if (self.any_whitespace) {
            const was_first = is_first.*;
            is_first.* = false;
            const ws = try whitespacePattern(self.allocator, self.max_whitespace_cnt);
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

/// Returns `n` ASCII space bytes allocated from `allocator`; the caller frees.
pub fn spaces(allocator: Allocator, n: i32) Allocator.Error![]u8 {
    const out = try allocator.alloc(u8, @intCast(n));
    @memset(out, ' ');
    return out;
}

// ---------------------------------------------------------------------------
// 4. SchemaSpec IR
// ---------------------------------------------------------------------------

/// Shared schema spec node pointer (allocated in the owning `SchemaParser`'s arena).
pub const SchemaSpecPtr = *const SchemaSpec;

/// `integer` type constraints.
pub const IntegerSpec = struct {
    minimum: ?i64 = null,
    maximum: ?i64 = null,
    exclusive_minimum: ?i64 = null,
    exclusive_maximum: ?i64 = null,
    multiple_of: ?i64 = null,

    pub const EffectiveRange = struct {
        start: ?i64,
        end: ?i64,
    };

    /// Returns the effective inclusive range after combining inclusive and exclusive bounds.
    pub fn effectiveRange(self: *const IntegerSpec) EffectiveRange {
        var start = self.minimum;
        if (self.exclusive_minimum) |exclusive| {
            const exclusive_start = exclusive + 1;
            start = if (start) |value| @max(value, exclusive_start) else exclusive_start;
        }

        var end = self.maximum;
        if (self.exclusive_maximum) |exclusive| {
            const exclusive_end = exclusive - 1;
            end = if (end) |value| @min(value, exclusive_end) else exclusive_end;
        }
        return .{ .start = start, .end = end };
    }
};

/// `number` type constraints.
pub const NumberSpec = struct {
    minimum: ?f64 = null,
    maximum: ?f64 = null,
    exclusive_minimum: ?f64 = null,
    exclusive_maximum: ?f64 = null,
};

/// `string` type constraints.
pub const StringSpec = struct {
    pattern: ?[]const u8 = null,
    format: ?[]const u8 = null,
    min_length: i32 = 0,
    /// `-1` means no limit.
    max_length: i32 = -1,
};

/// `array` type constraints.
pub const ArraySpec = struct {
    prefix_items: std.ArrayList(SchemaSpecPtr) = .empty,
    allow_additional_items: bool = true,
    /// `null` means additional items are not allowed.
    additional_items: ?SchemaSpecPtr = null,
    min_items: i64 = 0,
    /// `-1` means no limit.
    max_items: i64 = -1,
};

/// A named object property.
pub const Property = struct {
    name: []const u8,
    schema: SchemaSpecPtr,
};

/// A `patternProperties` entry: a key-regex and its value schema.
pub const PatternProperty = struct {
    pattern: []const u8,
    schema: SchemaSpecPtr,
};

/// `object` type constraints.
pub const ObjectSpec = struct {
    properties: std.ArrayList(Property) = .empty,
    pattern_properties: std.ArrayList(PatternProperty) = .empty,
    required: std.StringHashMapUnmanaged(void) = .empty,
    allow_additional_properties: bool = false,
    additional_properties_schema: ?SchemaSpecPtr = null,
    allow_unevaluated_properties: bool = true,
    unevaluated_properties_schema: ?SchemaSpecPtr = null,
    property_names: ?SchemaSpecPtr = null,
    min_properties: i32 = 0,
    /// `-1` means no limit.
    max_properties: i32 = -1,
};

/// A `const` value (stored as serialized JSON).
pub const ConstSpec = struct {
    json_value: []const u8,
};

/// An `enum` (stored as serialized JSON values).
pub const EnumSpec = struct {
    json_values: std.ArrayList([]const u8) = .empty,
};

/// A `$ref` to another part of the schema.
pub const RefSpec = struct {
    uri: []const u8,
};

/// An `anyOf` / `oneOf` alternation.
pub const AnyOfSpec = struct {
    options: std.ArrayList(SchemaSpecPtr) = .empty,
};

/// An `allOf` intersection.
pub const AllOfSpec = struct {
    schemas: std.ArrayList(SchemaSpecPtr) = .empty,
};

/// A `type: [.]` array of alternative type schemas.
pub const TypeArraySpec = struct {
    type_schemas: std.ArrayList(SchemaSpecPtr) = .empty,
};

/// The tagged union of all schema kinds.
pub const SchemaSpecVariant = union(enum) {
    Integer: IntegerSpec,
    Number: NumberSpec,
    String: StringSpec,
    Boolean,
    Null,
    Array: ArraySpec,
    Object: ObjectSpec,
    Any,
    Const: ConstSpec,
    Enum: EnumSpec,
    Ref: RefSpec,
    AnyOf: AnyOfSpec,
    AllOf: AllOfSpec,
    TypeArray: TypeArraySpec,
};

/// A schema spec node: its kind plus a de-duplication cache key.
pub const SchemaSpec = struct {
    spec: SchemaSpecVariant,
    cache_key: []const u8,

    /// Wraps a variant into a shared spec node (allocated from `allocator`).
    pub fn make(allocator: Allocator, spec: SchemaSpecVariant, cache_key: []const u8) Allocator.Error!SchemaSpecPtr {
        const node = try allocator.create(SchemaSpec);
        node.* = .{ .spec = spec, .cache_key = cache_key };
        return node;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "JsonFormat.fromName and isDeepseek cover all 9 variants" {
    const cases = [_]struct { name: []const u8, expected: JsonFormat, deepseek: bool }{
        .{ .name = "json", .expected = .json, .deepseek = false },
        .{ .name = "qwen_xml", .expected = .qwen_xml, .deepseek = false },
        .{ .name = "minimax_xml", .expected = .minimax_xml, .deepseek = false },
        .{ .name = "minimax_m3_xml", .expected = .minimax_m3_xml, .deepseek = false },
        .{ .name = "deepseek_xml", .expected = .deepseek_xml, .deepseek = true },
        .{ .name = "deepseek_v4_1_xml", .expected = .deepseek_v4_1_xml, .deepseek = true },
        .{ .name = "glm_xml", .expected = .glm_xml, .deepseek = false },
        .{ .name = "cohere_xml", .expected = .cohere_xml, .deepseek = false },
        .{ .name = "kimi_k3_xml", .expected = .kimi_k3_xml, .deepseek = false },
    };
    for (cases) |c| {
        const parsed = JsonFormat.fromName(c.name) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(c.expected, parsed);
        try std.testing.expectEqual(c.deepseek, parsed.isDeepseek());
    }
    try std.testing.expect(JsonFormat.fromName("unknown_fmt") == null);
    try std.testing.expectEqual(@as(usize, 9), std.enums.values(JsonFormat).len);
}

test "KeyTrie compact flat pool preserves ascending byte order and leaks zero bytes" {
    const a = std.testing.allocator;
    // Verify compact size relative to the legacy 256-slot table.
    try std.testing.expect(@sizeOf(KeyTrie.Node) <= 64);

    var trie = try KeyTrie.build(a, &.{ "name", "id", "index", "a", "ab" });
    defer trie.deinit(a);

    try std.testing.expect(trie.contains("name"));
    try std.testing.expect(trie.contains("id"));
    try std.testing.expect(trie.contains("index"));
    try std.testing.expect(trie.contains("a"));
    try std.testing.expect(trie.contains("ab"));
    try std.testing.expect(!trie.contains(""));
    try std.testing.expect(!trie.contains("in"));
    try std.testing.expect(!trie.contains("names"));

    // Root edges must be strictly sorted in ascending byte order: 'a', 'i', 'n'.
    const root_edges = trie.node(trie.rootIndex()).edges.items;
    try std.testing.expectEqual(@as(usize, 3), root_edges.len);
    try std.testing.expectEqual(@as(u8, 'a'), root_edges[0].byte);
    try std.testing.expectEqual(@as(u8, 'i'), root_edges[1].byte);
    try std.testing.expectEqual(@as(u8, 'n'), root_edges[2].byte);

    // Under 'i' -> 'n', edges must be sorted: 'd' (for "id" -> wait: "id" is 'i'->'d', "index" is 'i'->'n').
    const i_edges = trie.node(root_edges[1].child).edges.items;
    try std.testing.expectEqual(@as(usize, 2), i_edges.len);
    try std.testing.expectEqual(@as(u8, 'd'), i_edges[0].byte);
    try std.testing.expectEqual(@as(u8, 'n'), i_edges[1].byte);

    // Empty key handling.
    var empty_trie = try KeyTrie.build(a, &.{""});
    defer empty_trie.deinit(a);
    try std.testing.expect(empty_trie.node(0).is_terminal);
    try std.testing.expect(empty_trie.contains(""));
}

test "IndentManager separators with zero leaks" {
    const a = std.testing.allocator;
    var im = try IndentManager.init(a, 2, ",", false, null);
    defer im.deinit();

    try im.startIndent();
    const s1 = try im.startSeparator();
    defer a.free(s1);
    try std.testing.expectEqualStrings("\"\\n  \"", s1);

    const m1 = try im.middleSeparator();
    defer a.free(m1);
    try std.testing.expectEqualStrings("\",\\n  \"", m1);

    const n1 = try im.nextSeparator(false);
    defer a.free(n1);
    try std.testing.expectEqualStrings("\"\\n  \"", n1);

    const n2 = try im.nextSeparator(false);
    defer a.free(n2);
    try std.testing.expectEqualStrings("\",\\n  \"", n2);

    const n_end = try im.nextSeparator(true);
    defer a.free(n_end);
    try std.testing.expectEqualStrings("\"\\n\"", n_end);

    const e1 = try im.endSeparator();
    defer a.free(e1);
    try std.testing.expectEqualStrings("\"\\n\"", e1);

    im.endIndent();
}
