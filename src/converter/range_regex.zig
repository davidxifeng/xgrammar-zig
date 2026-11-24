//! Generates regular expressions for JSON Schema integer and number ranges
//! (`range_regex.rs`).
//!
//! All returned strings are allocated from `allocator`; the caller frees.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Default fractional precision used by the JSON Schema converter.
const FLOAT_PRECISION: usize = 6;

/// Options controlling endpoint exclusivity for float range regex generation.
pub const FloatRangeOptions = struct {
    exclusive_start: bool = false,
    exclusive_end: bool = false,
};

fn digitClass(allocator: Allocator, lo: u8, hi: u8) Allocator.Error![]u8 {
    if (lo == hi) {
        return std.fmt.allocPrint(allocator, "{c}", .{lo});
    }
    if (lo == '0' and hi == '9') {
        return allocator.dupe(u8, "\\d");
    }
    return std.fmt.allocPrint(allocator, "[{c}-{c}]", .{ lo, hi });
}

fn exactDigits(allocator: Allocator, count: usize) Allocator.Error![]u8 {
    return switch (count) {
        0 => allocator.dupe(u8, ""),
        1 => allocator.dupe(u8, "\\d"),
        else => std.fmt.allocPrint(allocator, "\\d{{{d}}}", .{count}),
    };
}

fn allChar(value: []const u8, expected: u8) bool {
    for (value) |byte| {
        if (byte != expected) return false;
    }
    return true;
}

fn freePatterns(allocator: Allocator, patterns: *std.ArrayList([]u8)) void {
    for (patterns.items) |p| allocator.free(p);
    patterns.deinit(allocator);
}

fn intSameLen(allocator: Allocator, start: []const u8, end: []const u8) Allocator.Error!std.ArrayList([]u8) {
    std.debug.assert(start.len == end.len);
    std.debug.assert(std.mem.order(u8, start, end) != .gt);

    var result: std.ArrayList([]u8) = .empty;
    errdefer freePatterns(allocator, &result);

    const len = start.len;
    if (std.mem.eql(u8, start, end)) {
        try result.append(allocator, try allocator.dupe(u8, start));
        return result;
    }
    if (len == 1) {
        try result.append(allocator, try digitClass(allocator, start[0], end[0]));
        return result;
    }

    const start_first = start[0];
    const end_first = end[0];
    if (start_first == end_first) {
        var inner = try intSameLen(allocator, start[1..], end[1..]);
        defer freePatterns(allocator, &inner);
        for (inner.items) |pattern| {
            try result.append(allocator, try std.fmt.allocPrint(allocator, "{c}{s}", .{ start_first, pattern }));
        }
        return result;
    }

    const start_suffix = start[1..];
    const end_suffix = end[1..];
    if (allChar(start_suffix, '0') and allChar(end_suffix, '9')) {
        if (start_first == '0' and end_first == '9') {
            try result.append(allocator, try exactDigits(allocator, len));
            return result;
        }
        const digits = try exactDigits(allocator, len - 1);
        defer allocator.free(digits);
        const class = try digitClass(allocator, start_first, end_first);
        defer allocator.free(class);
        try result.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}", .{ class, digits }));
        return result;
    }

    const nines = try allocator.alloc(u8, len - 1);
    defer allocator.free(nines);
    @memset(nines, '9');
    const zeros = try allocator.alloc(u8, len - 1);
    defer allocator.free(zeros);
    @memset(zeros, '0');

    {
        var head = try intSameLen(allocator, start_suffix, nines);
        defer freePatterns(allocator, &head);
        for (head.items) |pattern| {
            try result.append(allocator, try std.fmt.allocPrint(allocator, "{c}{s}", .{ start_first, pattern }));
        }
    }
    if (end_first - start_first >= 2) {
        const class = try digitClass(allocator, start_first + 1, end_first - 1);
        defer allocator.free(class);
        const digits = try exactDigits(allocator, len - 1);
        defer allocator.free(digits);
        try result.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}", .{ class, digits }));
    }
    {
        var tail = try intSameLen(allocator, zeros, end_suffix);
        defer freePatterns(allocator, &tail);
        for (tail.items) |pattern| {
            try result.append(allocator, try std.fmt.allocPrint(allocator, "{c}{s}", .{ end_first, pattern }));
        }
    }
    return result;
}

fn compareDigitStr(left: []const u8, right: []const u8) std.math.Order {
    if (left.len != right.len) {
        return if (left.len < right.len) .lt else .gt;
    }
    return std.mem.order(u8, left, right);
}

fn numberPatternsStr(allocator: Allocator, start: []const u8, end: []const u8) Allocator.Error!std.ArrayList([]u8) {
    var patterns: std.ArrayList([]u8) = .empty;
    errdefer freePatterns(allocator, &patterns);
    if (compareDigitStr(start, end) == .gt) {
        return patterns;
    }

    var len = start.len;
    while (len <= end.len) : (len += 1) {
        const segment_start = if (len == start.len) blk: {
            break :blk try allocator.dupe(u8, start);
        } else blk: {
            const s = try allocator.alloc(u8, len);
            s[0] = '1';
            @memset(s[1..], '0');
            break :blk s;
        };
        defer allocator.free(segment_start);

        const segment_end = if (len == end.len) blk: {
            break :blk try allocator.dupe(u8, end);
        } else blk: {
            const s = try allocator.alloc(u8, len);
            @memset(s, '9');
            break :blk s;
        };
        defer allocator.free(segment_end);

        var segment = try intSameLen(allocator, segment_start, segment_end);
        errdefer freePatterns(allocator, &segment);
        try patterns.appendSlice(allocator, segment.items);
        segment.deinit(allocator);
    }
    return patterns;
}

fn subRangeRegexStr(allocator: Allocator, start: []const u8, end: []const u8) Allocator.Error![]u8 {
    var patterns = try numberPatternsStr(allocator, start, end);
    defer freePatterns(allocator, &patterns);
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(allocator);
    for (patterns.items, 0..) |pattern, i| {
        if (i != 0) try joined.append(allocator, '|');
        try joined.appendSlice(allocator, pattern);
    }
    return std.fmt.allocPrint(allocator, "({s})", .{joined.items});
}

fn atLeastPositivePatternsStr(allocator: Allocator, start: []const u8) Allocator.Error!std.ArrayList([]u8) {
    var result: std.ArrayList([]u8) = .empty;
    errdefer freePatterns(allocator, &result);
    const len = start.len;
    const nines = try allocator.alloc(u8, len);
    defer allocator.free(nines);
    @memset(nines, '9');
    var head = try intSameLen(allocator, start, nines);
    errdefer freePatterns(allocator, &head);
    try result.appendSlice(allocator, head.items);
    head.deinit(allocator);
    try result.append(allocator, try std.fmt.allocPrint(allocator, "[1-9]\\d{{{d},}}", .{len}));
    return result;
}

fn absDigitsBuf(buf: []u8, value: i64) []const u8 {
    const text = std.fmt.bufPrint(buf, "{d}", .{value}) catch unreachable;
    return std.mem.trimStart(u8, text, "-");
}

/// Generates a regular expression matching all integers in `[start, end]`.
///
/// Either bound may be omitted. An empty range produces `^()$`.
pub fn generateRangeRegex(allocator: Allocator, start: ?i64, end: ?i64) Allocator.Error![]u8 {
    if (start == null and end == null) {
        return allocator.dupe(u8, "^-?\\d+$");
    }

    var parts: std.ArrayList([]u8) = .empty;
    defer freePatterns(allocator, &parts);

    if (start != null and end == null and start.? <= 0) {
        if (start.? < 0) {
            var buf: [32]u8 = undefined;
            const sub = try subRangeRegexStr(allocator, "1", absDigitsBuf(&buf, start.?));
            defer allocator.free(sub);
            try parts.append(allocator, try std.fmt.allocPrint(allocator, "-{s}", .{sub}));
        }
        try parts.append(allocator, try allocator.dupe(u8, "0"));
        try parts.append(allocator, try allocator.dupe(u8, "[1-9]\\d*"));
    } else if (start != null and end == null) {
        var buf: [32]u8 = undefined;
        const start_str = std.fmt.bufPrint(&buf, "{d}", .{start.?}) catch unreachable;
        var at_least = try atLeastPositivePatternsStr(allocator, start_str);
        errdefer freePatterns(allocator, &at_least);
        try parts.appendSlice(allocator, at_least.items);
        at_least.deinit(allocator);
    } else if (start == null and end != null and end.? >= 0) {
        try parts.append(allocator, try allocator.dupe(u8, "-[1-9]\\d*"));
        try parts.append(allocator, try allocator.dupe(u8, "0"));
        if (end.? > 0) {
            var buf: [32]u8 = undefined;
            const end_str = std.fmt.bufPrint(&buf, "{d}", .{end.?}) catch unreachable;
            try parts.append(allocator, try subRangeRegexStr(allocator, "1", end_str));
        }
    } else if (start == null) {
        var buf: [32]u8 = undefined;
        var at_least = try atLeastPositivePatternsStr(allocator, absDigitsBuf(&buf, end.?));
        defer freePatterns(allocator, &at_least);
        for (at_least.items) |pattern| {
            try parts.append(allocator, try std.fmt.allocPrint(allocator, "-{s}", .{pattern}));
        }
    } else {
        if (start.? > end.?) {
            return allocator.dupe(u8, "^()$");
        }
        if (start.? < 0) {
            const negative_end = @min(end.?, -1);
            var lo_buf: [32]u8 = undefined;
            var hi_buf: [32]u8 = undefined;
            const sub = try subRangeRegexStr(allocator, absDigitsBuf(&lo_buf, negative_end), absDigitsBuf(&hi_buf, start.?));
            defer allocator.free(sub);
            try parts.append(allocator, try std.fmt.allocPrint(allocator, "-{s}", .{sub}));
        }
        if (start.? <= 0 and end.? >= 0) {
            try parts.append(allocator, try allocator.dupe(u8, "0"));
        }
        if (end.? > 0) {
            var lo_buf: [32]u8 = undefined;
            var hi_buf: [32]u8 = undefined;
            const low = std.fmt.bufPrint(&lo_buf, "{d}", .{@max(start.?, 1)}) catch unreachable;
            const high = std.fmt.bufPrint(&hi_buf, "{d}", .{end.?}) catch unreachable;
            try parts.append(allocator, try subRangeRegexStr(allocator, low, high));
        }
    }

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(allocator);
    for (parts.items, 0..) |part, i| {
        if (i != 0) try joined.append(allocator, '|');
        try joined.appendSlice(allocator, part);
    }
    return std.fmt.allocPrint(allocator, "^({s})$", .{joined.items});
}

fn formatFloat(allocator: Allocator, value: f64, precision: usize) Allocator.Error![]u8 {
    const lo: f64 = @floatFromInt(std.math.minInt(i64));
    const hi: f64 = @floatFromInt(std.math.maxInt(i64));
    if (value >= lo and value < hi and value == @as(f64, @floatFromInt(@as(i64, @intFromFloat(value))))) {
        return std.fmt.allocPrint(allocator, "{d}", .{@as(i64, @intFromFloat(value))});
    }

    const result = try formatFixed(allocator, value, precision);
    defer allocator.free(result);
    var trimmed_len = result.len;
    if (std.mem.indexOfScalar(u8, result, '.')) |decimal_position| {
        var idx = result.len;
        while (idx > 0) {
            idx -= 1;
            if (result[idx] != '0') {
                if (idx > decimal_position) {
                    trimmed_len = idx + 1;
                } else if (idx == decimal_position) {
                    trimmed_len = decimal_position;
                }
                break;
            }
        }
    }
    return allocator.dupe(u8, result[0..trimmed_len]);
}

/// Fixed-precision float formatting with a runtime precision (`std.fmt` placeholders cannot
/// take a runtime precision). The caller frees.
pub fn formatFixed(allocator: Allocator, value: f64, precision: usize) Allocator.Error![]u8 {
    var buf: [1200]u8 = undefined;
    const rendered = std.fmt.float.render(&buf, value, .{ .mode = .decimal, .precision = precision }) catch |e| switch (e) {
        error.BufferTooSmall => unreachable,
    };
    return allocator.dupe(u8, rendered);
}

fn splitDecimal(value: []const u8) struct { integer: []const u8, fraction: []const u8 } {
    if (std.mem.indexOfScalar(u8, value, '.')) |dot| {
        return .{ .integer = value[0..dot], .fraction = value[dot + 1 ..] };
    }
    return .{ .integer = value, .fraction = "" };
}

fn adjustGrid(allocator: Allocator, value: []const u8, precision: usize, increment: bool) Allocator.Error![]u8 {
    const parts = splitDecimal(value);
    var number: std.ArrayList(u8) = .empty;
    defer number.deinit(allocator);
    try number.appendSlice(allocator, parts.integer);
    try number.appendSlice(allocator, parts.fraction);
    if (precision > parts.fraction.len) {
        try number.appendNTimes(allocator, '0', precision - parts.fraction.len);
    }

    if (increment) {
        var index = number.items.len;
        while (index > 0 and number.items[index - 1] == '9') {
            number.items[index - 1] = '0';
            index -= 1;
        }
        if (index == 0) {
            try number.insert(allocator, 0, '1');
        } else {
            number.items[index - 1] += 1;
        }
    } else {
        var index = number.items.len;
        while (index > 0 and number.items[index - 1] == '0') {
            number.items[index - 1] = '9';
            index -= 1;
        }
        if (index == 0) {
            @memset(number.items, '0');
        } else {
            number.items[index - 1] -= 1;
        }
    }

    while (number.items.len <= precision) {
        try number.insert(allocator, 0, '0');
    }
    const split = number.items.len - precision;
    const new_integer_full = number.items[0..split];
    const new_fraction_full = number.items[split..];
    const first_non_zero = std.mem.indexOfNone(u8, new_integer_full, "0");
    const new_integer = if (first_non_zero) |i| new_integer_full[i..] else "0";
    const trimmed_fraction = std.mem.trimEnd(u8, new_fraction_full, "0");
    if (trimmed_fraction.len == 0) {
        return allocator.dupe(u8, new_integer);
    }
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ new_integer, trimmed_fraction });
}

const RoundPair = struct { bound: []u8, strict: bool };

fn roundBoundToGrid(
    allocator: Allocator,
    value: f64,
    precision: usize,
    is_lower: bool,
    strict_in: bool,
) Allocator.Error!RoundPair {
    const rounded = try formatFloat(allocator, value, precision);
    const rounded_value = std.fmt.parseFloat(f64, rounded) catch unreachable;
    if (rounded_value == value) {
        return .{ .bound = rounded, .strict = strict_in };
    }
    defer allocator.free(rounded);
    const adjusted = if (is_lower and rounded_value < value)
        try adjustGrid(allocator, rounded, precision, true)
    else if (!is_lower and rounded_value > value)
        try adjustGrid(allocator, rounded, precision, false)
    else
        try allocator.dupe(u8, rounded);
    return .{ .bound = adjusted, .strict = false };
}

fn freeDigits(allocator: Allocator, max_count: usize) Allocator.Error![]u8 {
    if (max_count == 0) return allocator.dupe(u8, "");
    return std.fmt.allocPrint(allocator, "\\d{{0,{d}}}", .{max_count});
}

fn optionalZeros(allocator: Allocator, max_count: usize) Allocator.Error![]u8 {
    if (max_count == 0) return allocator.dupe(u8, "");
    return std.fmt.allocPrint(allocator, "0{{0,{d}}}", .{max_count});
}

fn someZeros(allocator: Allocator, max_count: usize) Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "0{{1,{d}}}", .{max_count});
}

const FractionPatterns = struct {
    parts: std.ArrayList([]u8) = .empty,
    include_empty: bool = false,

    fn deinit(self: *FractionPatterns, allocator: Allocator) void {
        freePatterns(allocator, &self.parts);
    }
};

fn fractionGreaterPatterns(allocator: Allocator, start: []const u8, strict: bool, max_len: usize) Allocator.Error!FractionPatterns {
    var result = FractionPatterns{};
    errdefer result.deinit(allocator);
    const len = start.len;
    for (start, 0..) |digit, index| {
        if (digit < '9') {
            const class = try digitClass(allocator, digit + 1, '9');
            defer allocator.free(class);
            const free = try freeDigits(allocator, max_len - index - 1);
            defer allocator.free(free);
            try result.parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ start[0..index], class, free }));
        }
    }
    var zero_count: usize = 0;
    while (true) : (zero_count += 1) {
        if (len + zero_count + 1 > max_len) {
            break;
        }
        const zeros = try allocator.alloc(u8, zero_count);
        defer allocator.free(zeros);
        @memset(zeros, '0');
        const free = try freeDigits(allocator, max_len - len - zero_count - 1);
        defer allocator.free(free);
        try result.parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}[1-9]{s}", .{ start, zeros, free }));
    }
    if (!strict) {
        if (len > 0) {
            const zeros = try optionalZeros(allocator, max_len - len);
            defer allocator.free(zeros);
            try result.parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}", .{ start, zeros }));
        } else {
            result.include_empty = true;
            if (max_len >= 1) {
                try result.parts.append(allocator, try someZeros(allocator, max_len));
            }
        }
    }
    return result;
}

fn fractionLessPatterns(allocator: Allocator, end: []const u8, strict: bool, max_len: usize) Allocator.Error!FractionPatterns {
    var result = FractionPatterns{};
    errdefer result.deinit(allocator);
    const len = end.len;
    for (end, 0..) |digit, index| {
        if (digit > '0') {
            const class = try digitClass(allocator, '0', digit - 1);
            defer allocator.free(class);
            const free = try freeDigits(allocator, max_len - index - 1);
            defer allocator.free(free);
            try result.parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ end[0..index], class, free }));
        }
    }
    for (0..len) |index| {
        if (index == 0) {
            if (max_len >= 1) {
                try result.parts.append(allocator, try someZeros(allocator, max_len));
            }
        } else {
            const zeros = try optionalZeros(allocator, max_len - index);
            defer allocator.free(zeros);
            try result.parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}", .{ end[0..index], zeros }));
        }
    }
    if (!strict) {
        if (len > 0) {
            const zeros = try optionalZeros(allocator, max_len - len);
            defer allocator.free(zeros);
            try result.parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}", .{ end, zeros }));
        } else if (max_len >= 1) {
            try result.parts.append(allocator, try someZeros(allocator, max_len));
        }
    }
    result.include_empty = len > 0 or !strict;
    return result;
}

fn fractionBetweenPatterns(
    allocator: Allocator,
    start: []const u8,
    strict_start: bool,
    end: []const u8,
    strict_end: bool,
    max_len: usize,
) Allocator.Error!FractionPatterns {
    var result = FractionPatterns{};
    errdefer result.deinit(allocator);
    var common_len: usize = 0;
    while (common_len < end.len and
        (if (common_len < start.len) start[common_len] else '0') == end[common_len])
    {
        common_len += 1;
    }
    const common = end[0..common_len];
    const start_digit = if (common_len < start.len) start[common_len] else '0';
    const end_digit = end[common_len];

    if (end_digit - start_digit >= 2) {
        const class = try digitClass(allocator, start_digit + 1, end_digit - 1);
        defer allocator.free(class);
        const free = try freeDigits(allocator, max_len - common_len - 1);
        defer allocator.free(free);
        try result.parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ common, class, free }));
    }
    if (common_len < start.len) {
        var lower = try fractionGreaterPatterns(allocator, start[common_len + 1 ..], strict_start, max_len - common_len - 1);
        defer lower.deinit(allocator);
        for (lower.parts.items) |part| {
            try result.parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ common, start_digit, part }));
        }
        if (lower.include_empty) {
            try result.parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}{c}", .{ common, start_digit }));
        }
    } else {
        var lower = try fractionGreaterPatterns(allocator, "", true, max_len - common_len - 1);
        defer lower.deinit(allocator);
        for (lower.parts.items) |part| {
            try result.parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ common, start_digit, part }));
        }
        if (!strict_start) {
            if (start.len != 0) {
                const zeros = try optionalZeros(allocator, max_len - start.len);
                defer allocator.free(zeros);
                try result.parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}", .{ start, zeros }));
            } else {
                result.include_empty = true;
                if (max_len >= 1) {
                    try result.parts.append(allocator, try someZeros(allocator, max_len));
                }
            }
        }
    }

    var upper = try fractionLessPatterns(allocator, end[common_len + 1 ..], strict_end, max_len - common_len - 1);
    defer upper.deinit(allocator);
    for (upper.parts.items) |part| {
        try result.parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ common, end_digit, part }));
    }
    if (upper.include_empty) {
        try result.parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}{c}", .{ common, end_digit }));
    }
    return result;
}

fn compareDecimal(
    left_integer: []const u8,
    left_fraction: []const u8,
    right_integer: []const u8,
    right_fraction: []const u8,
) std.math.Order {
    const integer_order = compareDigitStr(left_integer, right_integer);
    if (integer_order != .eq) {
        return integer_order;
    }
    const max_fraction = @max(left_fraction.len, right_fraction.len);
    for (0..max_fraction) |index| {
        const left = if (index < left_fraction.len) left_fraction[index] else '0';
        const right = if (index < right_fraction.len) right_fraction[index] else '0';
        if (left != right) {
            return if (left < right) .lt else .gt;
        }
    }
    return .eq;
}

fn stripAnchors(regex: []const u8) []const u8 {
    return regex[1 .. regex.len - 1];
}

fn parseIntCapped(digits: []const u8) i64 {
    return std.fmt.parseInt(i64, digits, 10) catch std.math.maxInt(i64);
}

fn addWithIntegerPart(
    allocator: Allocator,
    parts: *std.ArrayList([]u8),
    integer: []const u8,
    fraction_set: FractionPatterns,
) Allocator.Error!void {
    for (fraction_set.parts.items) |fraction| {
        try parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}\\.{s}", .{ integer, fraction }));
    }
    if (fraction_set.include_empty) {
        try parts.append(allocator, try allocator.dupe(u8, integer));
    }
}

fn positiveRangeParts(
    allocator: Allocator,
    low: []const u8,
    strict_low_in: bool,
    high: ?[]const u8,
    strict_high: bool,
    precision: usize,
) Allocator.Error!std.ArrayList([]u8) {
    var strict_low = strict_low_in;
    var parts: std.ArrayList([]u8) = .empty;
    errdefer freePatterns(allocator, &parts);
    const low_parts = splitDecimal(low);
    const integer_low: []const u8 = low_parts.integer;
    if (std.mem.eql(u8, integer_low, "0") and low_parts.fraction.len == 0) {
        strict_low = true;
    }
    const integer_low_value = parseIntCapped(integer_low);
    const optional_any_fraction = try std.fmt.allocPrint(allocator, "(\\.\\d{{1,{d}}})?", .{precision});
    defer allocator.free(optional_any_fraction);

    const high_val = high orelse {
        var greater = try fractionGreaterPatterns(allocator, low_parts.fraction, strict_low, precision);
        defer greater.deinit(allocator);
        try addWithIntegerPart(allocator, &parts, integer_low, greater);
        if (integer_low_value < std.math.maxInt(i64)) {
            const range = try generateRangeRegex(allocator, integer_low_value + 1, null);
            defer allocator.free(range);
            try parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}", .{ stripAnchors(range), optional_any_fraction }));
        }
        return parts;
    };

    const high_parts = splitDecimal(high_val);
    const integer_high: []const u8 = high_parts.integer;
    const integer_high_value = parseIntCapped(integer_high);
    const comparison = compareDecimal(integer_low, low_parts.fraction, integer_high, high_parts.fraction);
    if (comparison == .gt or (comparison == .eq and (strict_low or strict_high))) {
        return parts;
    }
    if (comparison == .eq) {
        if (low_parts.fraction.len == 0) {
            const zeros = try someZeros(allocator, precision);
            defer allocator.free(zeros);
            try parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}(\\.{s})?", .{ integer_low, zeros }));
        } else {
            const zeros = try optionalZeros(allocator, precision - low_parts.fraction.len);
            defer allocator.free(zeros);
            try parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}\\.{s}{s}", .{ integer_low, low_parts.fraction, zeros }));
        }
        return parts;
    }
    if (std.mem.eql(u8, integer_low, integer_high)) {
        var between = try fractionBetweenPatterns(allocator, low_parts.fraction, strict_low, high_parts.fraction, strict_high, precision);
        defer between.deinit(allocator);
        try addWithIntegerPart(allocator, &parts, integer_low, between);
    } else {
        var greater = try fractionGreaterPatterns(allocator, low_parts.fraction, strict_low, precision);
        defer greater.deinit(allocator);
        try addWithIntegerPart(allocator, &parts, integer_low, greater);
        if (integer_high_value - integer_low_value >= 2) {
            const range = try generateRangeRegex(allocator, integer_low_value + 1, integer_high_value - 1);
            defer allocator.free(range);
            try parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}", .{ stripAnchors(range), optional_any_fraction }));
        }
        var less = try fractionLessPatterns(allocator, high_parts.fraction, strict_high, precision);
        defer less.deinit(allocator);
        try addWithIntegerPart(allocator, &parts, integer_high, less);
    }
    return parts;
}

/// Generates a regular expression matching numbers in `[start, end]` with up to six
/// fractional digits. `options` configures endpoint exclusivity.
pub fn generateFloatRangeRegexWithOptions(
    allocator: Allocator,
    start: ?f64,
    end: ?f64,
    options: FloatRangeOptions,
) Allocator.Error![]u8 {
    const precision = FLOAT_PRECISION;
    if (start != null and end != null) {
        if (start.? > end.? or (start.? == end.? and (options.exclusive_start or options.exclusive_end))) {
            return allocator.dupe(u8, "^()$");
        }
    }
    if (start == null and end == null) {
        return std.fmt.allocPrint(allocator, "^-?\\d+(\\.\\d{{1,{d}}})?$", .{precision});
    }

    var parts: std.ArrayList([]u8) = .empty;
    defer freePatterns(allocator, &parts);
    const negatives_in_range = start == null or start.? < 0.0;
    if (negatives_in_range) {
        const low_pair = if (end != null and end.? < 0.0)
            try roundBoundToGrid(allocator, -end.?, precision, true, options.exclusive_end)
        else
            RoundPair{ .bound = try allocator.dupe(u8, "0"), .strict = true };
        defer allocator.free(low_pair.bound);
        const high_pair = if (start) |s|
            try roundBoundToGrid(allocator, -s, precision, false, options.exclusive_start)
        else
            RoundPair{ .bound = try allocator.dupe(u8, ""), .strict = false };
        defer allocator.free(high_pair.bound);
        var neg_parts = try positiveRangeParts(
            allocator,
            low_pair.bound,
            low_pair.strict,
            if (start != null) high_pair.bound else null,
            high_pair.strict,
            precision,
        );
        defer freePatterns(allocator, &neg_parts);
        for (neg_parts.items) |part| {
            try parts.append(allocator, try std.fmt.allocPrint(allocator, "-{s}", .{part}));
        }
    }

    const zero_allowed = (start == null or start.? < 0.0 or (start.? == 0.0 and !options.exclusive_start)) and
        (end == null or end.? > 0.0 or (end.? == 0.0 and !options.exclusive_end));
    if (zero_allowed) {
        const zeros = try someZeros(allocator, precision);
        defer allocator.free(zeros);
        try parts.append(allocator, try std.fmt.allocPrint(allocator, "0(\\.{s})?", .{zeros}));
        if (negatives_in_range) {
            try parts.append(allocator, try std.fmt.allocPrint(allocator, "-0(\\.{s})", .{zeros}));
        }
    }

    if (end == null or end.? > 0.0) {
        const low_pair = if (start != null and start.? > 0.0)
            try roundBoundToGrid(allocator, start.?, precision, true, options.exclusive_start)
        else
            RoundPair{ .bound = try allocator.dupe(u8, "0"), .strict = true };
        defer allocator.free(low_pair.bound);
        const high_pair = if (end) |e|
            try roundBoundToGrid(allocator, e, precision, false, options.exclusive_end)
        else
            RoundPair{ .bound = try allocator.dupe(u8, ""), .strict = false };
        defer allocator.free(high_pair.bound);
        var pos_parts = try positiveRangeParts(
            allocator,
            low_pair.bound,
            low_pair.strict,
            if (end != null) high_pair.bound else null,
            high_pair.strict,
            precision,
        );
        errdefer freePatterns(allocator, &pos_parts);
        try parts.appendSlice(allocator, pos_parts.items);
        pos_parts.deinit(allocator);
    }

    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(allocator);
    for (parts.items, 0..) |part, i| {
        if (i != 0) try joined.append(allocator, '|');
        try joined.appendSlice(allocator, part);
    }
    return std.fmt.allocPrint(allocator, "^({s})$", .{joined.items});
}

/// Generates a regular expression matching numbers in the inclusive range `[start, end]`.
pub fn generateFloatRangeRegex(
    allocator: Allocator,
    start: ?f64,
    end: ?f64,
) Allocator.Error![]u8 {
    return generateFloatRangeRegexWithOptions(allocator, start, end, .{});
}

test "generateRangeRegex golden parity and zero leaks" {
    const a = std.testing.allocator;
    const cases = [_]struct { s: ?i64, e: ?i64, expect: []const u8 }{
        .{ .s = null, .e = null, .expect = "^-?\\d+$" },
        .{ .s = 0, .e = null, .expect = "^(0|[1-9]\\d*)$" },
        .{ .s = 1, .e = null, .expect = "^([1-9]|[1-9]\\d{1,})$" },
        .{ .s = -1, .e = null, .expect = "^(-(1)|0|[1-9]\\d*)$" },
        .{ .s = null, .e = 0, .expect = "^(-[1-9]\\d*|0)$" },
        .{ .s = null, .e = -10, .expect = "^(-[1-9]\\d|-[1-9]\\d{2,})$" },
        .{ .s = 5, .e = 3, .expect = "^()$" },
        .{ .s = -3, .e = 7, .expect = "^(-([1-3])|0|([1-7]))$" },
        .{ .s = 95, .e = 105, .expect = "^((9[5-9]|10[0-5]))$" },
    };
    for (cases) |c| {
        const got = try generateRangeRegex(a, c.s, c.e);
        defer a.free(got);
        try std.testing.expectEqualStrings(c.expect, got);
    }
}

test "generateFloatRangeRegex and generateFloatRangeRegexWithOptions zero leaks" {
    const a = std.testing.allocator;
    const cases = [_]struct { s: ?f64, e: ?f64, xs: bool = false, xe: bool = false, expect: []const u8 }{
        .{ .s = null, .e = null, .expect = "^-?\\d+(\\.\\d{1,6})?$" },
        .{ .s = 1.5, .e = 2.5, .expect = "^(1\\.[6-9]\\d{0,5}|1\\.5[1-9]\\d{0,4}|1\\.50[1-9]\\d{0,3}|1\\.500[1-9]\\d{0,2}|1\\.5000[1-9]\\d{0,1}|1\\.50000[1-9]|1\\.50{0,5}|2\\.[0-4]\\d{0,5}|2\\.0{1,6}|2\\.50{0,5}|2)$" },
        .{ .s = -1.5, .e = 1.5, .expect = "^(-0\\.[1-9]\\d{0,5}|-0\\.0[1-9]\\d{0,4}|-0\\.00[1-9]\\d{0,3}|-0\\.000[1-9]\\d{0,2}|-0\\.0000[1-9]\\d{0,1}|-0\\.00000[1-9]|-1\\.[0-4]\\d{0,5}|-1\\.0{1,6}|-1\\.50{0,5}|-1|0(\\.0{1,6})?|-0(\\.0{1,6})|0\\.[1-9]\\d{0,5}|0\\.0[1-9]\\d{0,4}|0\\.00[1-9]\\d{0,3}|0\\.000[1-9]\\d{0,2}|0\\.0000[1-9]\\d{0,1}|0\\.00000[1-9]|1\\.[0-4]\\d{0,5}|1\\.0{1,6}|1\\.50{0,5}|1)$" },
        .{ .s = 0.0, .e = 1.0, .xs = true, .xe = false, .expect = "^(0\\.[1-9]\\d{0,5}|0\\.0[1-9]\\d{0,4}|0\\.00[1-9]\\d{0,3}|0\\.000[1-9]\\d{0,2}|0\\.0000[1-9]\\d{0,1}|0\\.00000[1-9]|1\\.0{1,6}|1)$" },
        .{ .s = 1.0, .e = 1.0, .xs = true, .xe = false, .expect = "^()$" },
        .{ .s = 3.14159, .e = 3.14159, .expect = "^(3\\.141590{0,1})$" },
        .{ .s = null, .e = 0.0, .expect = "^(-0\\.[1-9]\\d{0,5}|-0\\.0[1-9]\\d{0,4}|-0\\.00[1-9]\\d{0,3}|-0\\.000[1-9]\\d{0,2}|-0\\.0000[1-9]\\d{0,1}|-0\\.00000[1-9]|-([1-9]|[1-9]\\d{1,})(\\.\\d{1,6})?|0(\\.0{1,6})?|-0(\\.0{1,6}))$" },
    };
    for (cases) |c| {
        const got = if (c.xs or c.xe)
            try generateFloatRangeRegexWithOptions(a, c.s, c.e, .{ .exclusive_start = c.xs, .exclusive_end = c.xe })
        else
            try generateFloatRangeRegex(a, c.s, c.e);
        defer a.free(got);
        try std.testing.expectEqualStrings(c.expect, got);
    }
}
