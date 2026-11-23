//! Generates regular expressions for JSON Schema integer and number ranges
//! (`range_regex.rs`).
//!
//! This is a direct Rust port of upstream XGrammar's `NumberGenerator`. All returned
//! strings are allocated from the `allocator` parameter; the caller frees.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Default fractional precision used by the JSON Schema converter.
const FLOAT_PRECISION: usize = 6;

fn digit_class(allocator: Allocator, lo: u8, hi: u8) Allocator.Error![]u8 {
    if (lo == hi) {
        return std.fmt.allocPrint(allocator, "{c}", .{lo});
    }
    if (lo == '0' and hi == '9') {
        return allocator.dupe(u8, "\\d");
    }
    return std.fmt.allocPrint(allocator, "[{c}-{c}]", .{ lo, hi });
}

fn exact_digits(allocator: Allocator, count: usize) Allocator.Error![]u8 {
    return switch (count) {
        0 => allocator.dupe(u8, ""),
        1 => allocator.dupe(u8, "\\d"),
        else => std.fmt.allocPrint(allocator, "\\d{{{d}}}", .{count}),
    };
}

fn all_char(value: []const u8, expected: u8) bool {
    for (value) |byte| {
        if (byte != expected) return false;
    }
    return true;
}

fn int_same_len(allocator: Allocator, start: []const u8, end: []const u8) Allocator.Error!std.ArrayList([]u8) {
    std.debug.assert(start.len == end.len);
    std.debug.assert(std.mem.order(u8, start, end) != .gt);

    var result: std.ArrayList([]u8) = .empty;
    const len = start.len;
    if (std.mem.eql(u8, start, end)) {
        try result.append(allocator, try allocator.dupe(u8, start));
        return result;
    }
    if (len == 1) {
        try result.append(allocator, try digit_class(allocator, start[0], end[0]));
        return result;
    }

    const start_first = start[0];
    const end_first = end[0];
    if (start_first == end_first) {
        var inner = try int_same_len(allocator, start[1..], end[1..]);
        defer inner.deinit(allocator);
        for (inner.items) |pattern| {
            defer allocator.free(pattern);
            try result.append(allocator, try std.fmt.allocPrint(allocator, "{c}{s}", .{ start_first, pattern }));
        }
        return result;
    }

    const start_suffix = start[1..];
    const end_suffix = end[1..];
    if (all_char(start_suffix, '0') and all_char(end_suffix, '9')) {
        if (start_first == '0' and end_first == '9') {
            try result.append(allocator, try exact_digits(allocator, len));
            return result;
        }
        const digits = try exact_digits(allocator, len - 1);
        defer allocator.free(digits);
        const class = try digit_class(allocator, start_first, end_first);
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
        var head = try int_same_len(allocator, start_suffix, nines);
        defer head.deinit(allocator);
        for (head.items) |pattern| {
            defer allocator.free(pattern);
            try result.append(allocator, try std.fmt.allocPrint(allocator, "{c}{s}", .{ start_first, pattern }));
        }
    }
    if (end_first - start_first >= 2) {
        const class = try digit_class(allocator, start_first + 1, end_first - 1);
        defer allocator.free(class);
        const digits = try exact_digits(allocator, len - 1);
        defer allocator.free(digits);
        try result.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}", .{ class, digits }));
    }
    {
        var tail = try int_same_len(allocator, zeros, end_suffix);
        defer tail.deinit(allocator);
        for (tail.items) |pattern| {
            defer allocator.free(pattern);
            try result.append(allocator, try std.fmt.allocPrint(allocator, "{c}{s}", .{ end_first, pattern }));
        }
    }
    return result;
}

fn compare_digit_str(left: []const u8, right: []const u8) std.math.Order {
    if (left.len != right.len) {
        return if (left.len < right.len) .lt else .gt;
    }
    return std.mem.order(u8, left, right);
}

fn number_patterns_str(allocator: Allocator, start: []const u8, end: []const u8) Allocator.Error!std.ArrayList([]u8) {
    var patterns: std.ArrayList([]u8) = .empty;
    errdefer free_patterns(allocator, &patterns);
    if (compare_digit_str(start, end) == .gt) {
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
        var segment = try int_same_len(allocator, segment_start, segment_end);
        defer segment.deinit(allocator);
        try patterns.appendSlice(allocator, segment.items);
    }
    return patterns;
}

fn free_patterns(allocator: Allocator, patterns: *std.ArrayList([]u8)) void {
    for (patterns.items) |p| allocator.free(p);
    patterns.deinit(allocator);
}

fn sub_range_regex_str(allocator: Allocator, start: []const u8, end: []const u8) Allocator.Error![]u8 {
    var patterns = try number_patterns_str(allocator, start, end);
    defer free_patterns(allocator, &patterns);
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(allocator);
    for (patterns.items, 0..) |pattern, i| {
        if (i != 0) try joined.append(allocator, '|');
        try joined.appendSlice(allocator, pattern);
    }
    return std.fmt.allocPrint(allocator, "({s})", .{joined.items});
}

fn at_least_positive_patterns_str(allocator: Allocator, start: []const u8) Allocator.Error!std.ArrayList([]u8) {
    var result: std.ArrayList([]u8) = .empty;
    errdefer free_patterns(allocator, &result);
    const len = start.len;
    const nines = try allocator.alloc(u8, len);
    defer allocator.free(nines);
    @memset(nines, '9');
    var head = try int_same_len(allocator, start, nines);
    defer head.deinit(allocator);
    try result.appendSlice(allocator, head.items);
    try result.append(allocator, try std.fmt.allocPrint(allocator, "[1-9]\\d{{{d},}}", .{len}));
    return result;
}

fn abs_digits(allocator: Allocator, value: i64) Allocator.Error![]u8 {
    const text = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(text);
    return allocator.dupe(u8, std.mem.trimStart(u8, text, "-"));
}

/// Generates a regular expression matching all integers in `[start, end]`.
///
/// Either bound may be omitted. An empty range produces `^()$`.
pub fn generate_range_regex(allocator: Allocator, start: ?i64, end: ?i64) Allocator.Error![]u8 {
    var parts: std.ArrayList([]u8) = .empty;
    defer free_patterns(allocator, &parts);

    if (start == null and end == null) {
        return allocator.dupe(u8, "^-?\\d+$");
    }
    if (start != null and end == null and start.? <= 0) {
        if (start.? < 0) {
            const sub = try sub_range_regex_str(allocator, "1", try abs_digits(allocator, start.?));
            defer allocator.free(sub);
            try parts.append(allocator, try std.fmt.allocPrint(allocator, "-{s}", .{sub}));
        }
        try parts.append(allocator, try allocator.dupe(u8, "0"));
        try parts.append(allocator, try allocator.dupe(u8, "[1-9]\\d*"));
    } else if (start != null and end == null) {
        var at_least = try at_least_positive_patterns_str(allocator, try std.fmt.allocPrint(allocator, "{d}", .{start.?}));
        defer at_least.deinit(allocator);
        try parts.appendSlice(allocator, at_least.items);
    } else if (start == null and end != null and end.? >= 0) {
        try parts.append(allocator, try allocator.dupe(u8, "-[1-9]\\d*"));
        try parts.append(allocator, try allocator.dupe(u8, "0"));
        if (end.? > 0) {
            const end_str = try std.fmt.allocPrint(allocator, "{d}", .{end.?});
            defer allocator.free(end_str);
            try parts.append(allocator, try sub_range_regex_str(allocator, "1", end_str));
        }
    } else if (start == null) {
        var at_least = try at_least_positive_patterns_str(allocator, try abs_digits(allocator, end.?));
        defer at_least.deinit(allocator);
        for (at_least.items) |pattern| {
            try parts.append(allocator, try std.fmt.allocPrint(allocator, "-{s}", .{pattern}));
        }
    } else {
        if (start.? > end.?) {
            return allocator.dupe(u8, "^()$");
        }
        if (start.? < 0) {
            const negative_end = @min(end.?, -1);
            const low = try abs_digits(allocator, negative_end);
            defer allocator.free(low);
            const high = try abs_digits(allocator, start.?);
            defer allocator.free(high);
            const sub = try sub_range_regex_str(allocator, low, high);
            defer allocator.free(sub);
            try parts.append(allocator, try std.fmt.allocPrint(allocator, "-{s}", .{sub}));
        }
        if (start.? <= 0 and end.? >= 0) {
            try parts.append(allocator, try allocator.dupe(u8, "0"));
        }
        if (end.? > 0) {
            const low = try std.fmt.allocPrint(allocator, "{d}", .{@max(start.?, 1)});
            defer allocator.free(low);
            const high = try std.fmt.allocPrint(allocator, "{d}", .{end.?});
            defer allocator.free(high);
            try parts.append(allocator, try sub_range_regex_str(allocator, low, high));
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

fn format_float(allocator: Allocator, value: f64, precision: usize) Allocator.Error![]u8 {
    const lo: f64 = @floatFromInt(std.math.minInt(i64));
    const hi: f64 = @floatFromInt(std.math.maxInt(i64));
    if (value >= lo and value < hi and value == @as(f64, @floatFromInt(@as(i64, @intFromFloat(value))))) {
        return std.fmt.allocPrint(allocator, "{d}", .{@as(i64, @intFromFloat(value))});
    }

    var result = try format_fixed(allocator, value, precision);
    if (std.mem.indexOfScalar(u8, result, '.')) |decimal_position| {
        var last_non_zero: ?usize = null;
        var idx = result.len;
        while (idx > 0) {
            idx -= 1;
            if (result[idx] != '0') {
                last_non_zero = idx;
                break;
            }
        }
        if (last_non_zero) |last| {
            if (last > decimal_position) {
                result = result[0 .. last + 1];
            } else if (last == decimal_position) {
                result = result[0..decimal_position];
            }
        }
    }
    return result;
}

/// Rust `{:.N}` fixed float formatting with a runtime precision (std.fmt placeholders
/// cannot take a runtime precision). The caller frees.
pub fn format_fixed(allocator: Allocator, value: f64, precision: usize) Allocator.Error![]u8 {
    var buf: [1200]u8 = undefined;
    const rendered = std.fmt.float.render(&buf, value, .{ .mode = .decimal, .precision = precision }) catch |e| switch (e) {
        error.BufferTooSmall => unreachable,
    };
    return allocator.dupe(u8, rendered);
}

fn split_decimal(value: []const u8) struct { integer: []const u8, fraction: []const u8 } {
    if (std.mem.indexOfScalar(u8, value, '.')) |dot| {
        return .{ .integer = value[0..dot], .fraction = value[dot + 1 ..] };
    }
    return .{ .integer = value, .fraction = "" };
}

fn adjust_grid(allocator: Allocator, value: []const u8, precision: usize, increment: bool) Allocator.Error![]u8 {
    const parts = split_decimal(value);
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

fn round_bound_to_grid(
    allocator: Allocator,
    value: f64,
    precision: usize,
    is_lower: bool,
    strict_in: bool,
) Allocator.Error!RoundPair {
    var rounded = try format_float(allocator, value, precision);
    const rounded_value = std.fmt.parseFloat(f64, rounded) catch unreachable;
    if (rounded_value == value) {
        return .{ .bound = rounded, .strict = strict_in };
    }

    if (is_lower and rounded_value < value) {
        rounded = try replace_with_adjusted(allocator, rounded, precision, true);
    } else if (!is_lower and rounded_value > value) {
        rounded = try replace_with_adjusted(allocator, rounded, precision, false);
    }
    return .{ .bound = rounded, .strict = false };
}

const RoundPair = struct { bound: []u8, strict: bool };

/// `adjust_grid` over an owned string; frees the input, returns the adjusted string.
fn replace_with_adjusted(allocator: Allocator, rounded: []u8, precision: usize, increment: bool) Allocator.Error![]u8 {
    defer allocator.free(rounded);
    return adjust_grid(allocator, rounded, precision, increment);
}

fn free_digits(allocator: Allocator, max_count: usize) Allocator.Error![]u8 {
    if (max_count == 0) return allocator.dupe(u8, "");
    return std.fmt.allocPrint(allocator, "\\d{{0,{d}}}", .{max_count});
}

fn optional_zeros(allocator: Allocator, max_count: usize) Allocator.Error![]u8 {
    if (max_count == 0) return allocator.dupe(u8, "");
    return std.fmt.allocPrint(allocator, "0{{0,{d}}}", .{max_count});
}

fn some_zeros(allocator: Allocator, max_count: usize) Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "0{{1,{d}}}", .{max_count});
}

const FractionPatterns = struct {
    parts: std.ArrayList([]u8) = .empty,
    include_empty: bool = false,

    fn deinit(self: *FractionPatterns, allocator: Allocator) void {
        free_patterns(allocator, &self.parts);
    }
};

fn fraction_greater_patterns(allocator: Allocator, start: []const u8, strict: bool, max_len: usize) Allocator.Error!FractionPatterns {
    var result = FractionPatterns{};
    errdefer result.deinit(allocator);
    const len = start.len;
    for (start, 0..) |digit, index| {
        if (digit < '9') {
            const class = try digit_class(allocator, digit + 1, '9');
            defer allocator.free(class);
            const free = try free_digits(allocator, max_len - index - 1);
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
        const free = try free_digits(allocator, max_len - len - zero_count - 1);
        defer allocator.free(free);
        try result.parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}[1-9]{s}", .{ start, zeros, free }));
    }
    if (!strict) {
        if (len > 0) {
            const zeros = try optional_zeros(allocator, max_len - len);
            defer allocator.free(zeros);
            try result.parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}", .{ start, zeros }));
        } else {
            result.include_empty = true;
            if (max_len >= 1) {
                try result.parts.append(allocator, try some_zeros(allocator, max_len));
            }
        }
    }
    return result;
}

fn fraction_less_patterns(allocator: Allocator, end: []const u8, strict: bool, max_len: usize) Allocator.Error!FractionPatterns {
    var result = FractionPatterns{};
    errdefer result.deinit(allocator);
    const len = end.len;
    for (end, 0..) |digit, index| {
        if (digit > '0') {
            const class = try digit_class(allocator, '0', digit - 1);
            defer allocator.free(class);
            const free = try free_digits(allocator, max_len - index - 1);
            defer allocator.free(free);
            try result.parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ end[0..index], class, free }));
        }
    }
    for (0..len) |index| {
        if (index == 0) {
            if (max_len >= 1) {
                try result.parts.append(allocator, try some_zeros(allocator, max_len));
            }
        } else {
            const zeros = try optional_zeros(allocator, max_len - index);
            defer allocator.free(zeros);
            try result.parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}", .{ end[0..index], zeros }));
        }
    }
    if (!strict) {
        if (len > 0) {
            const zeros = try optional_zeros(allocator, max_len - len);
            defer allocator.free(zeros);
            try result.parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}", .{ end, zeros }));
        } else if (max_len >= 1) {
            try result.parts.append(allocator, try some_zeros(allocator, max_len));
        }
    }
    result.include_empty = len > 0 or !strict;
    return result;
}

fn fraction_between_patterns(
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
        const class = try digit_class(allocator, start_digit + 1, end_digit - 1);
        defer allocator.free(class);
        const free = try free_digits(allocator, max_len - common_len - 1);
        defer allocator.free(free);
        try result.parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ common, class, free }));
    }
    if (common_len < start.len) {
        var lower = try fraction_greater_patterns(allocator, start[common_len + 1 ..], strict_start, max_len - common_len - 1);
        defer lower.deinit(allocator);
        for (lower.parts.items) |part| {
            try result.parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ common, start_digit, part }));
        }
        if (lower.include_empty) {
            try result.parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}{c}", .{ common, start_digit }));
        }
    } else {
        var lower = try fraction_greater_patterns(allocator, "", true, max_len - common_len - 1);
        defer lower.deinit(allocator);
        for (lower.parts.items) |part| {
            try result.parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ common, start_digit, part }));
        }
        if (!strict_start) {
            if (start.len != 0) {
                const zeros = try optional_zeros(allocator, max_len - start.len);
                defer allocator.free(zeros);
                try result.parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}", .{ start, zeros }));
            } else {
                result.include_empty = true;
                if (max_len >= 1) {
                    try result.parts.append(allocator, try some_zeros(allocator, max_len));
                }
            }
        }
    }

    var upper = try fraction_less_patterns(allocator, end[common_len + 1 ..], strict_end, max_len - common_len - 1);
    defer upper.deinit(allocator);
    for (upper.parts.items) |part| {
        try result.parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ common, end_digit, part }));
    }
    if (upper.include_empty) {
        try result.parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}{c}", .{ common, end_digit }));
    }
    return result;
}

fn compare_decimal(
    left_integer: []const u8,
    left_fraction: []const u8,
    right_integer: []const u8,
    right_fraction: []const u8,
) std.math.Order {
    const integer_order = compare_digit_str(left_integer, right_integer);
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

fn strip_anchors(regex: []const u8) []const u8 {
    return regex[1 .. regex.len - 1];
}

fn parse_int_capped(digits: []const u8) i64 {
    return std.fmt.parseInt(i64, digits, 10) catch std.math.maxInt(i64);
}

fn add_with_integer_part(
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

fn positive_range_parts(
    allocator: Allocator,
    low: []const u8,
    strict_low_in: bool,
    high: ?[]const u8,
    strict_high: bool,
    precision: usize,
) Allocator.Error!std.ArrayList([]u8) {
    var strict_low = strict_low_in;
    var parts: std.ArrayList([]u8) = .empty;
    errdefer free_patterns(allocator, &parts);
    const low_parts = split_decimal(low);
    const integer_low: []const u8 = low_parts.integer;
    if (std.mem.eql(u8, integer_low, "0") and low_parts.fraction.len == 0) {
        strict_low = true;
    }
    const integer_low_value = parse_int_capped(integer_low);
    const optional_any_fraction = try std.fmt.allocPrint(allocator, "(\\.\\d{{1,{d}}})?", .{precision});
    defer allocator.free(optional_any_fraction);

    const high_val = high orelse {
        var greater = try fraction_greater_patterns(allocator, low_parts.fraction, strict_low, precision);
        defer greater.deinit(allocator);
        try add_with_integer_part(allocator, &parts, integer_low, greater);
        if (integer_low_value < std.math.maxInt(i64)) {
            const range = try generate_range_regex(allocator, integer_low_value + 1, null);
            defer allocator.free(range);
            try parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}", .{ strip_anchors(range), optional_any_fraction }));
        }
        return parts;
    };

    const high_parts = split_decimal(high_val);
    const integer_high: []const u8 = high_parts.integer;
    const integer_high_value = parse_int_capped(integer_high);
    const comparison = compare_decimal(integer_low, low_parts.fraction, integer_high, high_parts.fraction);
    if (comparison == .gt or (comparison == .eq and (strict_low or strict_high))) {
        return parts;
    }
    if (comparison == .eq) {
        if (low_parts.fraction.len == 0) {
            const zeros = try some_zeros(allocator, precision);
            defer allocator.free(zeros);
            try parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}(\\.{s})?", .{ integer_low, zeros }));
        } else {
            const zeros = try optional_zeros(allocator, precision - low_parts.fraction.len);
            defer allocator.free(zeros);
            try parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}\\.{s}{s}", .{ integer_low, low_parts.fraction, zeros }));
        }
        return parts;
    }
    if (std.mem.eql(u8, integer_low, integer_high)) {
        var between = try fraction_between_patterns(allocator, low_parts.fraction, strict_low, high_parts.fraction, strict_high, precision);
        defer between.deinit(allocator);
        try add_with_integer_part(allocator, &parts, integer_low, between);
    } else {
        var greater = try fraction_greater_patterns(allocator, low_parts.fraction, strict_low, precision);
        defer greater.deinit(allocator);
        try add_with_integer_part(allocator, &parts, integer_low, greater);
        if (integer_high_value - integer_low_value >= 2) {
            const range = try generate_range_regex(allocator, integer_low_value + 1, integer_high_value - 1);
            defer allocator.free(range);
            try parts.append(allocator, try std.fmt.allocPrint(allocator, "{s}{s}", .{ strip_anchors(range), optional_any_fraction }));
        }
        var less = try fraction_less_patterns(allocator, high_parts.fraction, strict_high, precision);
        defer less.deinit(allocator);
        try add_with_integer_part(allocator, &parts, integer_high, less);
    }
    return parts;
}

/// Generates a regular expression matching numbers in `[start, end]` with up to six
/// fractional digits. The boolean flags make either bound exclusive.
pub fn generate_float_range_regex_with_options(
    allocator: Allocator,
    start: ?f64,
    end: ?f64,
    exclusive_start: bool,
    exclusive_end: bool,
) Allocator.Error![]u8 {
    const precision = FLOAT_PRECISION;
    if (start != null and end != null) {
        if (start.? > end.? or (start.? == end.? and (exclusive_start or exclusive_end))) {
            return allocator.dupe(u8, "^()$");
        }
    }
    if (start == null and end == null) {
        return std.fmt.allocPrint(allocator, "^-?\\d+(\\.\\d{{1,{d}}})?$", .{precision});
    }

    var parts: std.ArrayList([]u8) = .empty;
    defer free_patterns(allocator, &parts);
    const negatives_in_range = start == null or start.? < 0.0;
    if (negatives_in_range) {
        const low_pair = if (end != null and end.? < 0.0)
            try round_bound_to_grid(allocator, -end.?, precision, true, exclusive_end)
        else
            RoundPair{ .bound = try allocator.dupe(u8, "0"), .strict = true };
        defer allocator.free(low_pair.bound);
        var high_pair: RoundPair = undefined;
        if (start) |s| {
            high_pair = try round_bound_to_grid(allocator, -s, precision, false, exclusive_start);
        } else {
            high_pair = .{ .bound = try allocator.dupe(u8, ""), .strict = false };
        }
        defer allocator.free(high_pair.bound);
        var neg_parts = try positive_range_parts(
            allocator,
            low_pair.bound,
            low_pair.strict,
            if (start != null) high_pair.bound else null,
            high_pair.strict,
            precision,
        );
        defer neg_parts.deinit(allocator);
        for (neg_parts.items) |part| {
            try parts.append(allocator, try std.fmt.allocPrint(allocator, "-{s}", .{part}));
        }
    }

    const zero_allowed = (start == null or start.? < 0.0 or (start.? == 0.0 and !exclusive_start)) and
        (end == null or end.? > 0.0 or (end.? == 0.0 and !exclusive_end));
    if (zero_allowed) {
        const zeros = try some_zeros(allocator, precision);
        defer allocator.free(zeros);
        try parts.append(allocator, try std.fmt.allocPrint(allocator, "0(\\.{s})?", .{zeros}));
        if (negatives_in_range) {
            try parts.append(allocator, try std.fmt.allocPrint(allocator, "-0(\\.{s})", .{zeros}));
        }
    }

    if (end == null or end.? > 0.0) {
        const low_pair = if (start != null and start.? > 0.0)
            try round_bound_to_grid(allocator, start.?, precision, true, exclusive_start)
        else
            RoundPair{ .bound = try allocator.dupe(u8, "0"), .strict = true };
        defer allocator.free(low_pair.bound);
        var high_pair: RoundPair = undefined;
        if (end) |e| {
            high_pair = try round_bound_to_grid(allocator, e, precision, false, exclusive_end);
        } else {
            high_pair = .{ .bound = try allocator.dupe(u8, ""), .strict = false };
        }
        defer allocator.free(high_pair.bound);
        var pos_parts = try positive_range_parts(
            allocator,
            low_pair.bound,
            low_pair.strict,
            if (end != null) high_pair.bound else null,
            high_pair.strict,
            precision,
        );
        defer pos_parts.deinit(allocator);
        try parts.appendSlice(allocator, pos_parts.items);
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
pub fn generate_float_range_regex(
    allocator: Allocator,
    start: ?f64,
    end: ?f64,
) Allocator.Error![]u8 {
    return generate_float_range_regex_with_options(allocator, start, end, false, false);
}
