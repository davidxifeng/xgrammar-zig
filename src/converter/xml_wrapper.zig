//! The XML parameter tags of the tool-calling formats (`xml_wrapper.rs`).

const json_format = @import("json_format.zig");
const JsonFormat = json_format.JsonFormat;

/// The literal pieces around one XML tool-call parameter: `key_prefix` NAME `key_suffix`
/// `value_prefix` VALUE `parameter_suffix`.
pub const XmlWrapper = struct {
    key_prefix: []const u8,
    key_suffix: []const u8,
    value_prefix: []const u8,
    parameter_suffix: []const u8,

    /// Kimi-K3 renders the value's type between the key and `<|sep|>`; see `KIMI_K3_TYPES`.
    pub const KIMI_K3_TYPE_PREFIX: []const u8 = "\" type=\"";
    /// The type attribute values of Kimi-K3 parameters.
    pub const KIMI_K3_TYPES: [7][]const u8 = .{ "string", "number", "integer", "boolean", "object", "array", "null" };
    /// The end of a Kimi-K3 parameter's opening tag.
    pub const KIMI_K3_TYPE_SUFFIX: []const u8 = "\"<|sep|>";

    /// The wrapper of an XML parameter-list format, or null for the other formats.
    pub fn for_format(format: JsonFormat) ?XmlWrapper {
        const parts: ?struct { key_prefix: []const u8, key_suffix: []const u8, value_prefix: []const u8, parameter_suffix: []const u8 } = switch (format) {
            .QwenXml => .{ .key_prefix = "<parameter=", .key_suffix = ">", .value_prefix = "", .parameter_suffix = "</parameter>" },
            .MiniMaxXml => .{ .key_prefix = "<parameter name=\"", .key_suffix = "\">", .value_prefix = "", .parameter_suffix = "</parameter>" },
            .DeepSeekXml => .{ .key_prefix = "<｜DSML｜parameter name=\"", .key_suffix = "", .value_prefix = "", .parameter_suffix = "</｜DSML｜parameter>" },
            .DeepSeekV41Xml => .{ .key_prefix = "<｜DSML｜ parameter name=\"", .key_suffix = "", .value_prefix = "", .parameter_suffix = "</｜DSML｜ parameter>" },
            .GlmXml => .{ .key_prefix = "<arg_key>", .key_suffix = "</arg_key>", .value_prefix = "<arg_value>", .parameter_suffix = "</arg_value>" },
            .CohereXml => .{ .key_prefix = "<cofl:value", .key_suffix = ">", .value_prefix = "", .parameter_suffix = "</cofl:value>" },
            // The key suffix (type attribute and <|sep|>) is generated per property.
            .KimiK3Xml => .{ .key_prefix = "<|open|>argument key=\"", .key_suffix = "", .value_prefix = "", .parameter_suffix = "<|close|>argument<|sep|>" },
            else => null,
        };
        const p = parts orelse return null;
        return .{
            .key_prefix = p.key_prefix,
            .key_suffix = p.key_suffix,
            .value_prefix = p.value_prefix,
            .parameter_suffix = p.parameter_suffix,
        };
    }
};
