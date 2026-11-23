//! Parity oracle binary reading the same JSON protocol as `tools/oracle-rs/src/main.rs`.

const std = @import("std");
const xgrammar = @import("xgrammar");

fn asObject(val: std.json.Value) !std.json.ObjectMap {
    return switch (val) {
        .object => |obj| obj,
        else => error.InvalidOracleInput,
    };
}

fn asArray(val: std.json.Value) ![]const std.json.Value {
    return switch (val) {
        .array => |arr| arr.items,
        else => error.InvalidOracleInput,
    };
}

fn asString(val: std.json.Value) ![]const u8 {
    return switch (val) {
        .string => |s| s,
        else => error.InvalidOracleInput,
    };
}

fn asBool(val: std.json.Value) !bool {
    return switch (val) {
        .bool => |b| b,
        else => error.InvalidOracleInput,
    };
}

fn asI64(val: std.json.Value) !i64 {
    return switch (val) {
        .integer => |n| n,
        else => error.InvalidOracleInput,
    };
}

fn utf8LossyAlloc(gpa: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return gpa.dupe(u8, bytes);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    const repl = "\xEF\xBF\xBD"; // U+FFFD
    while (i < bytes.len) {
        const b0 = bytes[i];
        if (b0 < 0x80) {
            try out.append(gpa, b0);
            i += 1;
            continue;
        }
        const seq_len = std.unicode.utf8ByteSequenceLength(b0) catch {
            try out.appendSlice(gpa, repl);
            i += 1;
            continue;
        };
        if (i + seq_len <= bytes.len) {
            if (std.unicode.utf8Decode(bytes[i .. i + seq_len])) |_| {
                try out.appendSlice(gpa, bytes[i .. i + seq_len]);
                i += seq_len;
                continue;
            } else |_| {}
        }
        // Maximal subpart of ill-formed UTF-8 sequence (matches Rust `from_utf8_lossy`).
        var step: usize = 1;
        if (seq_len >= 3 and i + 1 < bytes.len) {
            const b1 = bytes[i + 1];
            const valid_b1 = switch (b0) {
                0xE0 => b1 >= 0xA0 and b1 <= 0xBF,
                0xED => b1 >= 0x80 and b1 <= 0x9F,
                0xF0 => b1 >= 0x90 and b1 <= 0xBF,
                0xF4 => b1 >= 0x80 and b1 <= 0x8F,
                else => b1 >= 0x80 and b1 <= 0xBF,
            };
            if (valid_b1) {
                step = 2;
                if (seq_len == 4 and i + 2 < bytes.len and (bytes[i + 2] & 0xC0) == 0x80) {
                    step = 3;
                }
            }
        }
        try out.appendSlice(gpa, repl);
        i += step;
    }
    return out.toOwnedSlice(gpa);
}

fn parseVocabType(s: []const u8) !xgrammar.VocabType {
    if (std.mem.eql(u8, s, "raw")) return .Raw;
    if (std.mem.eql(u8, s, "byte_fallback")) return .ByteFallback;
    if (std.mem.eql(u8, s, "byte_level")) return .ByteLevel;
    return error.UnknownVocabType;
}

fn readInputJson(gpa: std.mem.Allocator, io: std.Io, args: std.process.Args) ![]u8 {
    var it = try args.iterateAllocator(gpa);
    defer it.deinit();
    _ = it.next();
    if (it.next()) |path| {
        return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    }
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
    return stdin_reader.interface.allocRemaining(gpa, .unlimited);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const raw = try readInputJson(gpa, io, init.minimal.args);
    defer gpa.free(raw);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, raw, .{});
    defer parsed.deinit();
    const root_obj = try asObject(parsed.value);

    const vocab_arr = try asArray(root_obj.get("vocab") orelse return error.InvalidOracleInput);
    const vocab = try gpa.alloc([]const u8, vocab_arr.len);
    defer gpa.free(vocab);
    for (vocab_arr, 0..) |item, i| {
        vocab[i] = try asString(item);
    }

    const vocab_type_str = if (root_obj.get("vocab_type")) |v| try asString(v) else "raw";
    const vocab_type = try parseVocabType(vocab_type_str);

    const vocab_size: ?i32 = if (root_obj.get("vocab_size")) |v| switch (v) {
        .null => null,
        else => std.math.cast(i32, try asI64(v)) orelse return error.InvalidOracleInput,
    } else null;

    var stop_ids_buf: std.ArrayList(i32) = .empty;
    defer stop_ids_buf.deinit(gpa);
    const stop_token_ids: ?[]const i32 = if (root_obj.get("stop_token_ids")) |v| switch (v) {
        .null => null,
        else => blk: {
            const arr = try asArray(v);
            try stop_ids_buf.ensureTotalCapacity(gpa, arr.len);
            for (arr) |elem| {
                stop_ids_buf.appendAssumeCapacity(std.math.cast(i32, try asI64(elem)) orelse return error.InvalidOracleInput);
            }
            break :blk stop_ids_buf.items;
        },
    } else null;

    const add_prefix_space = if (root_obj.get("add_prefix_space")) |v| switch (v) {
        .null => false,
        else => try asBool(v),
    } else false;

    var tok = try xgrammar.TokenizerInfo.new(
        gpa,
        vocab,
        vocab_type,
        vocab_size,
        stop_token_ids,
        add_prefix_space,
        null,
    );
    defer tok.deinit();

    const compiler = try xgrammar.GrammarCompiler.with_defaults(gpa, &tok);
    defer compiler.deinit();

    const grammar_obj = try asObject(root_obj.get("grammar") orelse return error.InvalidOracleInput);
    const grammar_type = try asString(grammar_obj.get("type") orelse return error.InvalidOracleInput);
    const grammar_text = try asString(grammar_obj.get("text") orelse return error.InvalidOracleInput);

    var compiled = if (std.mem.eql(u8, grammar_type, "json_schema")) blk: {
        const any_whitespace = if (grammar_obj.get("any_whitespace")) |v| try asBool(v) else true;
        const strict_mode = if (grammar_obj.get("strict_mode")) |v| try asBool(v) else false;
        break :blk try compiler.compile_json_schema(
            grammar_text,
            any_whitespace,
            null,
            null,
            strict_mode,
            null,
            null,
        );
    } else if (std.mem.eql(u8, grammar_type, "ebnf")) blk: {
        const root_rule = if (grammar_obj.get("root")) |v| try asString(v) else "root";
        break :blk try compiler.compile_grammar_ebnf(grammar_text, root_rule, null);
    } else return error.UnknownGrammarType;
    defer compiled.deinit();

    const seqs_arr = try asArray(root_obj.get("sequences") orelse return error.InvalidOracleInput);
    const bm_size: usize = @intCast(xgrammar.get_bitmask_size(tok.vocab_size));
    const shape = [2]i64{ 1, @intCast(bm_size) };

    var out_aw: std.Io.Writer.Allocating = .init(gpa);
    defer out_aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &out_aw.writer };

    try jw.beginObject();
    try jw.objectField("vocab_size");
    try jw.write(tok.vocab_size);
    try jw.objectField("bitmask_size");
    try jw.write(bm_size);
    try jw.objectField("sequences");
    try jw.beginArray();

    for (seqs_arr) |seq_val| {
        const seq_items = try asArray(seq_val);
        var matcher = try xgrammar.GrammarMatcher.from_compiled_grammar(gpa, &compiled, false);
        defer matcher.deinit();

        try jw.beginObject();
        try jw.objectField("ids");
        try jw.beginArray();
        for (seq_items) |id_val| {
            const tok_id = std.math.cast(i32, try asI64(id_val)) orelse return error.InvalidOracleInput;
            try jw.write(tok_id);
        }
        try jw.endArray();

        try jw.objectField("steps");
        try jw.beginArray();
        for (seq_items) |id_val| {
            const tok_id = std.math.cast(i32, try asI64(id_val)) orelse return error.InvalidOracleInput;
            const bitmask = try xgrammar.allocate_token_bitmask(gpa, 1, tok.vocab_size);
            defer gpa.free(bitmask);

            const fill_ok = matcher.fill_next_token_bitmask(bitmask, &shape, 0, null) catch |err| switch (err) {
                error.Terminated => false,
                else => return err,
            };
            const accepted = try matcher.accept_token(tok_id);

            try jw.beginObject();
            try jw.objectField("token_id");
            try jw.write(tok_id);
            try jw.objectField("fill_ok");
            try jw.write(fill_ok);
            try jw.objectField("accepted");
            try jw.write(accepted);
            try jw.objectField("bitmask");
            try jw.beginArray();
            for (bitmask) |w| {
                try jw.write(@as(u64, @as(u32, @bitCast(w))));
            }
            try jw.endArray();
            try jw.objectField("completed");
            try jw.write(matcher.is_completed());
            try jw.objectField("terminated");
            try jw.write(matcher.is_terminated());
            try jw.endObject();
        }
        try jw.endArray();

        const jump_end = if (!matcher.is_terminated())
            try matcher.find_jump_forward_string(gpa, null)
        else
            try gpa.dupe(u8, "");
        defer gpa.free(jump_end);
        const jump_lossy = try utf8LossyAlloc(gpa, jump_end);
        defer gpa.free(jump_lossy);

        try jw.objectField("jump_forward_end");
        try jw.write(jump_lossy);
        try jw.endObject();
    }

    try jw.endArray();
    try jw.endObject();

    try out_aw.writer.writeByte('\n');
    try std.Io.File.stdout().writeStreamingAll(io, out_aw.written());
}
