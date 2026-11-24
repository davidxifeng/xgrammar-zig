//! Lark AST, tokens, document ownership, named grammars, and diagnostics
//! (`lark_location.rs`, `lark_token_type.rs`, `lark_token.rs`, `lark_node_kind.rs`,
//! `lark_node.rs`, `lark_definition.rs`, `lark_document.rs`, `lark_import.rs`,
//! `lark_trigger.rs`, `lark_special_token_set.rs`, `named_grammar.rs`,
//! `named_grammar_registry.rs`, `lark_error.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const diag_mod = @import("../../Diagnostic.zig");
const Diagnostic = diag_mod.Diagnostic;
const extractSourceLine = diag_mod.extractSourceLine;
const grammar_mod = @import("../../grammar.zig");
const Grammar = grammar_mod.Grammar;

/// The error set of every Lark entry point.
pub const LarkError = error{
    Lark,
    OutOfMemory,
};

/// A 1-based line and byte column in a Lark source.
pub const LarkLocation = struct {
    /// 1-based line number.
    line: i32,
    /// 1-based byte column.
    column: i32,

    /// The location of the first byte of a source.
    pub const START: LarkLocation = .{ .line = 1, .column = 1 };
};

/// Records a located Lark diagnostic into `diag` (if non-null) and returns `error.Lark`.
pub fn failLocated(
    gpa: Allocator,
    diag: ?*Diagnostic,
    source: []const u8,
    location: LarkLocation,
    message: []const u8,
) LarkError {
    return failLocatedFmt(gpa, diag, source, location, "{s}", .{message});
}

/// Formats and records a located Lark diagnostic into `diag` (if non-null) and returns `error.Lark`.
pub fn failLocatedFmt(
    gpa: Allocator,
    diag: ?*Diagnostic,
    source: []const u8,
    location: LarkLocation,
    comptime fmt: []const u8,
    args: anytype,
) LarkError {
    if (diag) |d| {
        const line: usize = @intCast(@max(location.line, 1));
        const column: usize = @intCast(@max(location.column, 0));
        const source_line = extractSourceLine(source, line);
        try d.setLocatedFmt(gpa, .lark_located, line, column, source_line, fmt, args);
    }
    return error.Lark;
}

/// Records an unlocated Lark diagnostic message into `diag` (if non-null) and returns `error.Lark`.
pub fn failMessage(
    gpa: Allocator,
    diag: ?*Diagnostic,
    message: []const u8,
) LarkError {
    if (diag) |d| {
        try d.setCopy(gpa, .message, message);
    }
    return error.Lark;
}

/// Formats and records an unlocated Lark diagnostic message into `diag` (if non-null) and returns `error.Lark`.
pub fn failMessageFmt(
    gpa: Allocator,
    diag: ?*Diagnostic,
    comptime fmt: []const u8,
    args: anytype,
) LarkError {
    if (diag) |d| {
        try d.setFmt(gpa, .message, fmt, args);
    }
    return error.Lark;
}

/// The kind of a `LarkToken`.
pub const LarkTokenType = enum {
    Name,
    String,
    Regex,
    Number,
    SpecialToken,
    GrammarRef,
    Json,
    RegexExt,
    GrammarOptions,
    Import,
    Ignore,
    Lark,
    If,
    UnsupportedDirective,
    Colon,
    DoubleColon,
    Comma,
    Dot,
    DotDot,
    Arrow,
    Equals,
    LParen,
    RParen,
    LBracket,
    RBracket,
    LBrace,
    RBrace,
    Pipe,
    And,
    Tilde,
    Question,
    Star,
    Plus,
    Newline,
    End,
};

/// A Lark token: its kind, source text (or re-serialized JSON value), and regex flags.
/// `text`/`flags` are allocated from the parsing document's arena.
pub const LarkToken = struct {
    ty: LarkTokenType,
    text: []const u8,
    flags: []const u8,
    location: LarkLocation,
};

/// The kind of a `LarkNode`.
pub const LarkNodeKind = enum {
    Sequence,
    Choice,
    Repeat,
    String,
    Regex,
    Range,
    Name,
    Json,
    RegexExt,
    NestedLark,
    SpecialToken,
    GrammarRef,
    Not,
};

/// A Lark expression tree node. All payloads live in the owning document's arena.
pub const LarkNode = struct {
    kind: LarkNodeKind,
    location: LarkLocation,
    text: []const u8 = "",
    text2: []const u8 = "",
    flags: []const u8 = "",
    min_repeat: i32 = 0,
    max_repeat: i32 = 0,
    children: std.ArrayList(LarkNode) = .empty,
    nested: ?*const LarkDocument = null,

    /// Creates a node of `kind` with empty payloads.
    pub fn init(kind: LarkNodeKind, location: LarkLocation) LarkNode {
        return .{ .kind = kind, .location = location };
    }

    /// Creates a node of `kind` whose primary payload is `text`.
    pub fn withText(kind: LarkNodeKind, location: LarkLocation, text: []const u8) LarkNode {
        var node = LarkNode.init(kind, location);
        node.text = text;
        return node;
    }

    /// Creates a node of `kind` over `children` (copied into `allocator`).
    pub fn withChildren(
        kind: LarkNodeKind,
        location: LarkLocation,
        children: []const LarkNode,
        allocator: Allocator,
    ) Allocator.Error!LarkNode {
        var node = LarkNode.init(kind, location);
        try node.children.appendSlice(allocator, children);
        return node;
    }

    /// Creates a repetition of `child` between `min_repeat` and `max_repeat` (`-1` unbounded).
    pub fn repeat(
        location: LarkLocation,
        child: LarkNode,
        min_repeat: i32,
        max_repeat: i32,
        allocator: Allocator,
    ) Allocator.Error!LarkNode {
        var node = try LarkNode.withChildren(.Repeat, location, &.{child}, allocator);
        node.min_repeat = min_repeat;
        node.max_repeat = max_repeat;
        return node;
    }

    /// Deep copy into `allocator` (expected to be an arena allocator).
    pub fn clone(self: *const LarkNode, allocator: Allocator) Allocator.Error!LarkNode {
        var node = LarkNode.init(self.kind, self.location);
        node.text = try allocator.dupe(u8, self.text);
        node.text2 = try allocator.dupe(u8, self.text2);
        node.flags = try allocator.dupe(u8, self.flags);
        node.min_repeat = self.min_repeat;
        node.max_repeat = self.max_repeat;
        try node.children.ensureTotalCapacity(allocator, self.children.items.len);
        for (self.children.items) |*child| {
            node.children.appendAssumeCapacity(try child.clone(allocator));
        }
        if (self.nested) |nested| {
            const nested_ptr = try allocator.create(LarkDocument);
            nested_ptr.* = try LarkDocument.deepCloneNested(allocator, nested);
            node.nested = nested_ptr;
        }
        return node;
    }
};

/// A rule (`name: ...`) or terminal (`NAME: ...`) definition with its attributes.
pub const LarkDefinition = struct {
    name: []const u8,
    is_terminal: bool,
    lazy: bool = false,
    suffix: ?LarkNode = null,
    stop: ?LarkNode = null,
    stop_capture_name: ?[]const u8 = null,
    temperature: ?f32 = null,
    max_tokens: ?MaxTokens = null,
    max_chars: ?i32 = null,
    capture_name: ?CaptureName = null,
    body: LarkNode,
    location: LarkLocation,

    pub const MaxTokens = struct {
        value: i32,
        key_location: LarkLocation,
    };

    pub const CaptureName = struct {
        name: []const u8,
        value_location: LarkLocation,
    };

    /// Creates a definition without attributes.
    pub fn init(name: []const u8, is_terminal: bool, body: LarkNode, location: LarkLocation) LarkDefinition {
        return .{
            .name = name,
            .is_terminal = is_terminal,
            .body = body,
            .location = location,
        };
    }

    /// Whether the rule is lazy or carries a suffix or stop marker.
    pub fn hasLazySemantics(self: *const LarkDefinition) bool {
        return self.lazy or self.suffix != null or self.stop != null;
    }

    /// Deep copy into `allocator`.
    pub fn clone(self: *const LarkDefinition, allocator: Allocator) Allocator.Error!LarkDefinition {
        var definition = LarkDefinition.init(
            try allocator.dupe(u8, self.name),
            self.is_terminal,
            try self.body.clone(allocator),
            self.location,
        );
        definition.lazy = self.lazy;
        if (self.suffix) |*suffix| definition.suffix = try suffix.clone(allocator);
        if (self.stop) |*stop| definition.stop = try stop.clone(allocator);
        if (self.stop_capture_name) |name| definition.stop_capture_name = try allocator.dupe(u8, name);
        definition.temperature = self.temperature;
        definition.max_tokens = self.max_tokens;
        definition.max_chars = self.max_chars;
        if (self.capture_name) |capture| {
            definition.capture_name = .{
                .name = try allocator.dupe(u8, capture.name),
                .value_location = capture.value_location,
            };
        }
        return definition;
    }
};

/// One imported terminal: its dotted path and the local name it is bound to.
pub const LarkImport = struct {
    path: []const u8,
    local_name: []const u8,
    location: LarkLocation,
};

/// The items of a Lark grammar (or an inline `%lark { ... }` block).
///
/// Top-level documents own an `ArenaAllocator` (`arena != null`) backed by `backing_alloc`
/// and free it on `deinit()`. Nested `%lark` documents borrow the parent's arena allocator
/// (`arena == null, backing_alloc = parent_alloc`), so `deinit()` is a no-op and the parent
/// reclaims all nested memory cleanly without orphaned `ArenaAllocator` instances.
pub const LarkDocument = struct {
    arena: ?*std.heap.ArenaAllocator = null,
    backing_alloc: Allocator,
    definitions: std.ArrayList(LarkDefinition) = .empty,
    ignores: std.ArrayList(LarkNode) = .empty,
    imports: std.ArrayList(LarkImport) = .empty,
    options: std.ArrayList(Option) = .empty,

    pub const Option = struct {
        value: std.json.Value,
        location: LarkLocation,
    };

    /// Creates an empty document owning a fresh arena under `backing`.
    pub fn init(backing: Allocator) Allocator.Error!LarkDocument {
        const arena = try backing.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(backing);
        return .{
            .arena = arena,
            .backing_alloc = backing,
        };
    }

    /// Creates a nested `%lark` document whose allocations go directly into `parent_alloc`.
    pub fn initNested(parent_alloc: Allocator) LarkDocument {
        return .{
            .arena = null,
            .backing_alloc = parent_alloc,
        };
    }

    /// Returns the document's allocation context (also the JSON value tree's owner).
    pub fn allocator(self: *const LarkDocument) Allocator {
        return if (self.arena) |a| a.allocator() else self.backing_alloc;
    }

    /// Frees the owned arena if this is a top-level document; no-op for nested documents.
    pub fn deinit(self: *LarkDocument) void {
        if (self.arena) |a| {
            const backing = self.backing_alloc;
            a.deinit();
            backing.destroy(a);
            self.arena = null;
        }
    }

    /// Deep copy under `backing` with a fresh owned arena.
    pub fn deepClone(backing: Allocator, other: *const LarkDocument) Allocator.Error!LarkDocument {
        var document = try LarkDocument.init(backing);
        errdefer document.deinit();
        try cloneContents(&document, other);
        return document;
    }

    /// Deep copy as a nested document allocating directly into `parent_alloc`.
    pub fn deepCloneNested(parent_alloc: Allocator, other: *const LarkDocument) Allocator.Error!LarkDocument {
        var document = LarkDocument.initNested(parent_alloc);
        try cloneContents(&document, other);
        return document;
    }

    fn cloneContents(dst: *LarkDocument, src: *const LarkDocument) Allocator.Error!void {
        const a = dst.allocator();
        try dst.definitions.ensureTotalCapacity(a, src.definitions.items.len);
        for (src.definitions.items) |*definition| {
            dst.definitions.appendAssumeCapacity(try definition.clone(a));
        }
        try dst.ignores.ensureTotalCapacity(a, src.ignores.items.len);
        for (src.ignores.items) |*ignore| {
            dst.ignores.appendAssumeCapacity(try ignore.clone(a));
        }
        try dst.imports.ensureTotalCapacity(a, src.imports.items.len);
        for (src.imports.items) |item| {
            dst.imports.appendAssumeCapacity(.{
                .path = try a.dupe(u8, item.path),
                .local_name = try a.dupe(u8, item.local_name),
                .location = item.location,
            });
        }
        try dst.options.ensureTotalCapacity(a, src.options.items.len);
        for (src.options.items) |option| {
            dst.options.appendAssumeCapacity(.{
                .value = try cloneJsonValue(a, option.value),
                .location = option.location,
            });
        }
    }
};

/// Deep copy of a `std.json.Value` tree into `allocator` (typically the document arena).
pub fn cloneJsonValue(allocator: Allocator, value: std.json.Value) Allocator.Error!std.json.Value {
    return switch (value) {
        .null, .bool, .integer, .float, .number_string => value,
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |array| blk: {
            var out = std.json.Array.init(allocator);
            errdefer out.deinit();
            try out.ensureTotalCapacity(array.items.len);
            for (array.items) |item| out.appendAssumeCapacity(try cloneJsonValue(allocator, item));
            break :blk .{ .array = out };
        },
        .object => |object| blk: {
            var out: std.json.ObjectMap = .empty;
            errdefer out.deinit(allocator);
            var it = object.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key);
                const val = try cloneJsonValue(allocator, entry.value_ptr.*);
                try out.put(allocator, key, val);
            }
            break :blk .{ .object = out };
        },
    };
}

/// A lazy-rule trigger: a fixed string or a set of token ids.
pub const LarkTrigger = union(enum) {
    string: []const u8,
    token: []const i32,

    pub fn eql(a: LarkTrigger, b: LarkTrigger) bool {
        if (@as(std.meta.Tag(LarkTrigger), a) != @as(std.meta.Tag(LarkTrigger), b)) return false;
        return switch (a) {
            .string => |s| std.mem.eql(u8, s, b.string),
            .token => |t| std.mem.eql(i32, t, b.token),
        };
    }

    /// Hashes the payload only (used as a map key; callers mix in nothing else).
    pub fn hash(self: LarkTrigger, hasher: anytype) void {
        switch (self) {
            .string => |s| {
                hasher.update("s");
                hasher.update(s);
            },
            .token => |t| {
                hasher.update("t");
                for (t) |id| {
                    var buf: [4]u8 = undefined;
                    std.mem.writeInt(i32, &buf, id, .little);
                    hasher.update(&buf);
                }
            },
        }
    }
};

/// The token ids of a `<...>` special token, and whether they are excluded (`<[^...]>`).
pub const LarkSpecialTokenSet = struct {
    excluded: bool = false,
    token_ids: std.ArrayList(i32) = .empty,
};

/// A grammar or Lark source that can be referenced by `@name` from another Lark grammar.
pub const NamedGrammar = union(enum) {
    /// An existing grammar (value handle passed by pointer, outliving the `fromLark` call).
    grammar: struct {
        name: []const u8,
        grammar: *const Grammar,
    },
    /// A Lark source with its own `start` rule.
    lark: struct {
        name: []const u8,
        source: []const u8,
    },

    pub fn fromGrammar(grammar_name: []const u8, g: *const Grammar) NamedGrammar {
        return .{ .grammar = .{ .name = grammar_name, .grammar = g } };
    }

    pub fn fromLarkSource(grammar_name: []const u8, source: []const u8) NamedGrammar {
        return .{ .lark = .{ .name = grammar_name, .source = source } };
    }

    /// The reference name, without the leading `@`.
    pub fn name(self: *const NamedGrammar) []const u8 {
        return switch (self.*) {
            .grammar => |g| g.name,
            .lark => |l| l.name,
        };
    }
};

/// Tracks named grammar inputs, compiled named Lark sources, and the active compilation
/// stack for cycle detection.
pub const NamedGrammarRegistry = struct {
    gpa: Allocator,
    inputs: std.StringHashMapUnmanaged(*const NamedGrammar) = .empty,
    compiled: std.StringHashMapUnmanaged(Grammar) = .empty,
    active: std.ArrayList([]u8) = .empty,

    pub fn init(gpa: Allocator) NamedGrammarRegistry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *NamedGrammarRegistry) void {
        self.inputs.deinit(self.gpa);
        var it = self.compiled.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
            self.gpa.free(entry.key_ptr.*);
        }
        self.compiled.deinit(self.gpa);
        for (self.active.items) |item| self.gpa.free(item);
        self.active.deinit(self.gpa);
    }

    /// Returns the grammar named `grammar_name`: either the input grammar or compiled Lark source.
    pub fn get(self: *const NamedGrammarRegistry, grammar_name: []const u8) ?*const Grammar {
        const input = self.inputs.get(grammar_name) orelse return null;
        return switch (input.*) {
            .grammar => |g| g.grammar,
            .lark => self.compiled.getPtr(grammar_name),
        };
    }
};

test "LarkDocument owned vs nested lifetime and deepClone have zero leaks" {
    const a = std.testing.allocator;

    var doc = try LarkDocument.init(a);
    defer doc.deinit();

    const doc_alloc = doc.allocator();
    var nested = LarkDocument.initNested(doc_alloc);
    defer nested.deinit(); // must be a no-op; reclaimed by `doc.deinit()`

    const nested_leaf = LarkNode.withText(.String, LarkLocation.START, "inner");
    try nested.definitions.append(nested.allocator(), LarkDefinition.init("start", false, nested_leaf, LarkLocation.START));

    const nested_ptr = try doc_alloc.create(LarkDocument);
    nested_ptr.* = nested;
    var outer_node = LarkNode.init(.NestedLark, LarkLocation.START);
    outer_node.nested = nested_ptr;
    try doc.definitions.append(doc_alloc, LarkDefinition.init("start", false, outer_node, LarkLocation.START));
    try doc.options.append(doc_alloc, .{ .value = .{ .bool = true }, .location = LarkLocation.START });

    var cloned = try LarkDocument.deepClone(a, &doc);
    defer cloned.deinit();
    try std.testing.expectEqual(@as(usize, 1), cloned.definitions.items.len);
    const cloned_nested = cloned.definitions.items[0].body.nested.?;
    try std.testing.expect(cloned_nested.arena == null);
    try std.testing.expectEqualStrings("inner", cloned_nested.definitions.items[0].body.text);
}

test "failLocated and failMessage populate Diagnostic cleanly" {
    const a = std.testing.allocator;
    var diag: Diagnostic = .{};
    defer diag.deinit(a);

    try std.testing.expectEqual(
        error.Lark,
        failLocatedFmt(a, &diag, "first\nsecond: bad", .{ .line = 2, .column = 9 }, "unexpected '{s}'", .{"bad"}),
    );
    const msg1 = try diag.formatAlloc(a);
    defer a.free(msg1);
    try std.testing.expectEqualStrings("Lark error at line 2, column 9: unexpected 'bad'\nsecond: bad\n        ^", msg1);

    try std.testing.expectEqual(error.Lark, failMessage(a, &diag, "Duplicate named grammar 'x'"));
    const msg2 = try diag.formatAlloc(a);
    defer a.free(msg2);
    try std.testing.expectEqualStrings("Duplicate named grammar 'x'", msg2);

    // Null diagnostic returns error.Lark with zero allocations.
    try std.testing.expectEqual(error.Lark, failLocated(a, null, "x", LarkLocation.START, "err"));
}
