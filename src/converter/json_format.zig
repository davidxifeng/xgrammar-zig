//! The output encoding of a JSON-schema conversion (`json_format.rs`).

/// How the converted grammar encodes a JSON Schema instance.
///
/// [`JsonFormat.Json`] produces plain JSON. The XML styles encode the root object as a
/// model-specific tool-call parameter list while nested values stay JSON (MiniMax-M3 and
/// Cohere encode nested objects and arrays recursively in their own tags).
pub const JsonFormat = enum {
    /// Plain JSON.
    Json,
    /// `<parameter=name>value</parameter>`.
    QwenXml,
    /// `<parameter name="name">value</parameter>`.
    MiniMaxXml,
    /// DeepSeek DSML parameters with a `string` attribute.
    DeepSeekXml,
    /// `<arg_key>name</arg_key><arg_value>value</arg_value>`.
    GlmXml,
    /// Recursive Cohere `<cofl:value>` tags.
    CohereXml,
    /// Kimi-K3 `<|open|>argument key=".." type=".."<|sep|>` parameters.
    KimiK3Xml,
    /// MiniMax-M3 namespace-prefixed recursive elements.
    MiniMaxM3Xml,
    /// DeepSeek V4.1 DSML parameters.
    DeepSeekV41Xml,

    /// Parses a format name: `"json"`, `"qwen_xml"`, `"minimax_xml"`, `"minimax_m3_xml"`,
    /// `"deepseek_xml"`, `"deepseek_v4_1_xml"`, `"glm_xml"`, `"cohere_xml"`, or
    /// `"kimi_k3_xml"`.
    pub fn from_name(name: []const u8) ?JsonFormat {
        const map = .{
            .{ "json", JsonFormat.Json },
            .{ "qwen_xml", JsonFormat.QwenXml },
            .{ "minimax_xml", JsonFormat.MiniMaxXml },
            .{ "minimax_m3_xml", JsonFormat.MiniMaxM3Xml },
            .{ "deepseek_xml", JsonFormat.DeepSeekXml },
            .{ "deepseek_v4_1_xml", JsonFormat.DeepSeekV41Xml },
            .{ "glm_xml", JsonFormat.GlmXml },
            .{ "cohere_xml", JsonFormat.CohereXml },
            .{ "kimi_k3_xml", JsonFormat.KimiK3Xml },
        };
        inline for (map) |entry| {
            if (std.mem.eql(u8, name, entry[0])) return entry[1];
        }
        return null;
    }

    /// Whether this is one of the DeepSeek DSML styles.
    pub fn is_deepseek(self: JsonFormat) bool {
        return self == .DeepSeekXml or self == .DeepSeekV41Xml;
    }
};

const std = @import("std");
