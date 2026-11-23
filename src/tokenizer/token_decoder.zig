//! Decodes raw vocabulary tokens into their byte strings.

const std = @import("std");
const Allocator = std.mem.Allocator;

const vocab_type = @import("vocab_type.zig");
const encoding = @import("../support/encoding.zig");

pub const VocabType = vocab_type.VocabType;

/// Decodes an encoded vocabulary `token` into its byte string per `vocab_type`.
/// Caller owns the returned memory.
pub fn decode_token(allocator: Allocator, token: []const u8, vocab: VocabType) Allocator.Error![]u8 {
    return decode_token_bytes(allocator, token, vocab);
}

/// Decodes an encoded vocabulary token supplied as arbitrary bytes.
/// Caller owns the returned memory.
pub fn decode_token_bytes(allocator: Allocator, token: []const u8, vocab: VocabType) Allocator.Error![]u8 {
    return switch (vocab) {
        .ByteFallback => space_replacer_decoder(allocator, try byte_fallback_decoder(allocator, token)),
        .ByteLevel => byte_level_decoder(allocator, token),
        .Raw => allocator.dupe(u8, token),
    };
}

/// Transforms `<0xNN>` byte tokens into the raw byte `NN`; other tokens pass through.
fn byte_fallback_decoder(allocator: Allocator, token: []const u8) Allocator.Error![]u8 {
    if (token.len == 6 and std.mem.eql(u8, token[0..3], "<0x") and token[5] == '>') {
        const hi = hex_val(token[3]);
        const lo = hex_val(token[4]);
        if (hi != null and lo != null) {
            const byte: u8 = @truncate(@as(u32, hi.?) * 16 + lo.?);
            return allocator.dupe(u8, &[1]u8{byte});
        }
    }
    return allocator.dupe(u8, token);
}

/// Hex digit value, accepting `0-9` and uppercase `A-F`.
fn hex_val(c: u8) ?u32 {
    return switch (c) {
        '0'...'9' => c - '0',
        'A'...'F' => @as(u32, c - 'A') + 10,
        else => null,
    };
}

/// Replaces the `▁` block (U+2581, UTF-8 `E2 96 81`) with a space.
fn space_replacer_decoder(allocator: Allocator, token: []const u8) Allocator.Error![]u8 {
    defer allocator.free(token); // intermediate from byte_fallback_decoder
    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();
    try result.ensureTotalCapacity(token.len);
    var i: usize = 0;
    while (i < token.len) {
        if (i + 2 < token.len and token[i] == 0xE2 and token[i + 1] == 0x96 and token[i + 2] == 0x81) {
            try result.append(' ');
            i += 3;
        } else {
            try result.append(token[i]);
            i += 1;
        }
    }
    return result.toOwnedSlice();
}

/// Inverts the GPT-2 bytes-to-unicode mapping; tokens with unmapped codepoints pass through.
fn byte_level_decoder(allocator: Allocator, token: []const u8) Allocator.Error![]u8 {
    var codepoints = encoding.parse_utf8(allocator, token, false) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return allocator.dupe(u8, token), // InvalidUtf8: token passes through
    };
    defer codepoints.deinit(allocator);
    var decoded = std.array_list.Managed(u8).init(allocator);
    errdefer decoded.deinit();
    for (codepoints.items) |cp| {
        // Codepoint is i32; negatives cannot occur from strict UTF-8 parsing, but the
        // reference guards them anyway.
        if (cp < 0) return allocator.dupe(u8, token);
        const idx: usize = @intCast(cp);
        if (idx >= CHAR_TO_BYTE_MAP.len or CHAR_TO_BYTE_MAP[idx] == -1) {
            return allocator.dupe(u8, token);
        }
        try decoded.append(@intCast(CHAR_TO_BYTE_MAP[idx]));
    }
    return decoded.toOwnedSlice();
}

/// The inverse of GPT-2's `bytes_to_unicode`; `-1` marks codepoints with no mapping.
pub const CHAR_TO_BYTE_MAP: [324]i32 = .{
      -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,
      -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,
      -1,   -1,   -1,   -1,   -1,   -1,   -1,   33,   34,   35,   36,   37,   38,
      39,   40,   41,   42,   43,   44,   45,   46,   47,   48,   49,   50,   51,
      52,   53,   54,   55,   56,   57,   58,   59,   60,   61,   62,   63,   64,
      65,   66,   67,   68,   69,   70,   71,   72,   73,   74,   75,   76,   77,
      78,   79,   80,   81,   82,   83,   84,   85,   86,   87,   88,   89,   90,
      91,   92,   93,   94,   95,   96,   97,   98,   99,  100,  101,  102,  103,
     104,  105,  106,  107,  108,  109,  110,  111,  112,  113,  114,  115,  116,
     117,  118,  119,  120,  121,  122,  123,  124,  125,  126,   -1,   -1,   -1,
      -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,
      -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,   -1,
      -1,   -1,   -1,   -1,   -1,  161,  162,  163,  164,  165,  166,  167,  168,
     169,  170,  171,  172,   -1,  174,  175,  176,  177,  178,  179,  180,  181,
     182,  183,  184,  185,  186,  187,  188,  189,  190,  191,  192,  193,  194,
     195,  196,  197,  198,  199,  200,  201,  202,  203,  204,  205,  206,  207,
     208,  209,  210,  211,  212,  213,  214,  215,  216,  217,  218,  219,  220,
     221,  222,  223,  224,  225,  226,  227,  228,  229,  230,  231,  232,  233,
     234,  235,  236,  237,  238,  239,  240,  241,  242,  243,  244,  245,  246,
     247,  248,  249,  250,  251,  252,  253,  254,  255,    0,    1,    2,    3,
       4,    5,    6,    7,    8,    9,   10,   11,   12,   13,   14,   15,   16,
      17,   18,   19,   20,   21,   22,   23,   24,   25,   26,   27,   28,   29,
      30,   31,   32,  127,  128,  129,  130,  131,  132,  133,  134,  135,  136,
     137,  138,  139,  140,  141,  142,  143,  144,  145,  146,  147,  148,  149,
     150,  151,  152,  153,  154,  155,  156,  157,  158,  159,  160,  173,
};

test "byte fallback decode" {
    const a = std.testing.allocator;
    // "\u001b" was encoded as "<0x1B>"
    {
        const out = try decode_token(a, "<0x1B>", .ByteFallback);
        defer a.free(out);
        try std.testing.expectEqualSlices(u8, &[1]u8{0x1B}, out);
    }
    // lowercase hex is not accepted by the reference decoder
    {
        const out = try decode_token(a, "<0x1b>", .ByteFallback);
        defer a.free(out);
        try std.testing.expectEqualStrings("<0x1b>", out);
    }
    // " apple" was encoded as "▁apple" (U+2581 = E2 96 81)
    {
        const out = try decode_token(a, "▁apple", .ByteFallback);
        defer a.free(out);
        try std.testing.expectEqualStrings(" apple", out);
    }
    // raw passthrough
    {
        const out = try decode_token(a, "hello", .Raw);
        defer a.free(out);
        try std.testing.expectEqualStrings("hello", out);
    }
}

test "byte level decode" {
    const a = std.testing.allocator;
    // "Ġ" (U+0120 = 288) maps to byte 32 (space)
    {
        const out = try decode_token(a, "Ġ", .ByteLevel);
        defer a.free(out);
        try std.testing.expectEqualStrings(" ", out);
    }
    // printable ASCII maps to itself
    {
        const out = try decode_token(a, "abc", .ByteLevel);
        defer a.free(out);
        try std.testing.expectEqualStrings("abc", out);
    }
    // unmapped codepoint (U+0121 = 289 maps to 127? no: 289 -> 127) — use U+007F control (unmapped)
    {
        const out = try decode_token(a, "\x7f", .ByteLevel);
        defer a.free(out);
        try std.testing.expectEqualStrings("\x7f", out);
    }
    // invalid UTF-8 passes through
    {
        const out = try decode_token(a, "\xff\xfe", .ByteLevel);
        defer a.free(out);
        try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xfe }, out);
    }
    // non-ASCII mapped codepoint: "Č" (U+010C = 268) maps to 12
    {
        const out = try decode_token(a, "Č", .ByteLevel);
        defer a.free(out);
        try std.testing.expectEqualSlices(u8, &[1]u8{12}, out);
    }
}
