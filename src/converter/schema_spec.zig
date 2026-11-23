//! The intermediate representation for a parsed JSON Schema (`schema_spec.rs`).
//!
//! `SchemaParser` produces a tree of these (shared via borrowed `*const SchemaSpec` for
//! `$ref` reuse and de-duplication); `JsonSchemaConverter` walks the tree to emit EBNF.
//! All nodes live in the owning `SchemaParser`'s arena; the pointers are valid as long as
//! the parser (and thus its owning converter) is alive.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The shared schema spec node (Rust `Rc<SchemaSpec>` → borrowed pointer into the
/// parser's arena).
pub const SchemaSpecPtr = *const SchemaSpec;

/// `integer` type constraints.
pub const IntegerSpec = struct {
    minimum: ?i64 = null,
    maximum: ?i64 = null,
    exclusive_minimum: ?i64 = null,
    exclusive_maximum: ?i64 = null,
    multiple_of: ?i64 = null,

    /// Returns the effective inclusive range after combining inclusive and exclusive
    /// bounds (Rust tuple return → named struct).
    pub fn effective_range(self: *const IntegerSpec) EffectiveRange {
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

    pub const EffectiveRange = struct {
        start: ?i64,
        end: ?i64,
    };
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
    /// Rust `HashSet<String>`; only queried with `contains`/`len`, so a hash map keeps the
    /// (order-independent) semantics.
    required: std.StringHashMap(void),
    allow_additional_properties: bool = false,
    additional_properties_schema: ?SchemaSpecPtr = null,
    allow_unevaluated_properties: bool = true,
    unevaluated_properties_schema: ?SchemaSpecPtr = null,
    property_names: ?SchemaSpecPtr = null,
    min_properties: i32 = 0,
    /// `-1` means no limit.
    max_properties: i32 = -1,

    pub fn default(allocator: Allocator) Allocator.Error!ObjectSpec {
        return .{ .required = std.StringHashMap(void).init(allocator) };
    }
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
