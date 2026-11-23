//! Standardized performance benchmark suite comparing Zig (`xgrammar-zig`) against `tools/oracle-rs/src/bin/bench.rs` (`xgrammar-rs 0.2.8`).

const std = @import("std");
const xgrammar = @import("xgrammar");

const VOCAB_SIZE: usize = 32_000;
const TRACE_LEN: usize = 33;

const FIXED_TOKENS = [_][]const u8{
    "{",
    "}",
    "[",
    "]",
    ":",
    ",",
    "\"",
    "\"user\"",
    "\"name\"",
    "\"Ada\"",
    "\"age\"",
    "30",
    "\"active\"",
    "true",
    "\"tags\"",
    "\"zig\"",
    "\"rust\"",
    "\"score\"",
    "99",
    "\"role\"",
    "\"admin\"",
    "false",
    " ",
    "null",
    "</s>",
};

const TRACE_IDS = [TRACE_LEN]i32{
    0,  7,  4,  0,  8,  4,  9,  5,  10, 4, 11,
    5,  12, 4,  13, 5,  19, 4,  20, 1,  5, 14,
    4,  2,  15, 5,  16, 3,  5,  17, 4,  18, 1,
};

const JSON_SCHEMA =
    \\{"type":"object","properties":{"user":{"type":"object","properties":{"name":{"type":"string"},"age":{"type":"integer"},"active":{"type":"boolean"},"role":{"type":"string","enum":["admin","member","guest"]}},"required":["name","age","active","role"],"additionalProperties":false},"tags":{"type":"array","items":{"type":"string"}},"score":{"type":"integer"}},"required":["user","tags","score"],"additionalProperties":false}
;

const EBNF_GRAMMAR =
    \\root ::= expr
    \\expr ::= term (("+" | "-") term)*
    \\term ::= factor (("*" | "/") factor)*
    \\factor ::= [0-9]+ | "(" expr ")"
;

fn nowNs() u64 {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

const Stats = struct {
    median_us: f64,
    mean_us: f64,
    min_us: f64,
};

fn computeStats(samples_ns: []u64, divisor: f64) Stats {
    std.mem.sort(u64, samples_ns, {}, std.sort.asc(u64));
    var sum: u128 = 0;
    for (samples_ns) |v| sum += v;
    const median_ns: f64 = if (samples_ns.len % 2 == 1)
        @floatFromInt(samples_ns[samples_ns.len / 2])
    else
        @as(f64, @floatFromInt(samples_ns[samples_ns.len / 2 - 1] + samples_ns[samples_ns.len / 2])) * 0.5;
    const mean_ns: f64 = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(samples_ns.len));
    const min_ns: f64 = @floatFromInt(samples_ns[0]);
    return .{
        .median_us = (median_ns / 1000.0) / divisor,
        .mean_us = (mean_ns / 1000.0) / divisor,
        .min_us = (min_ns / 1000.0) / divisor,
    };
}

fn buildVocab(gpa: std.mem.Allocator) !struct { owned: [][]u8, slices: [][]const u8 } {
    const owned = try gpa.alloc([]u8, VOCAB_SIZE);
    const slices = try gpa.alloc([]const u8, VOCAB_SIZE);
    for (0..VOCAB_SIZE) |i| {
        if (i < FIXED_TOKENS.len) {
            owned[i] = try gpa.dupe(u8, FIXED_TOKENS[i]);
        } else {
            const fmt_str = switch (i % 5) {
                0 => try std.fmt.allocPrint(gpa, "val_{d}", .{i}),
                1 => try std.fmt.allocPrint(gpa, "key_{d}", .{i}),
                2 => try std.fmt.allocPrint(gpa, "pre_word{d}", .{i}),
                3 => try std.fmt.allocPrint(gpa, "num{d}", .{i}),
                else => try std.fmt.allocPrint(gpa, "sub_{d}", .{i}),
            };
            owned[i] = fmt_str;
        }
        slices[i] = owned[i];
    }
    return .{ .owned = owned, .slices = slices };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const vocab = try buildVocab(gpa);
    defer {
        for (vocab.owned) |s| gpa.free(s);
        gpa.free(vocab.owned);
        gpa.free(vocab.slices);
    }

    // 1. TokenizerInfo init on 32K vocab
    var tok_samples: [5]u64 = undefined;
    {
        var warm = try xgrammar.TokenizerInfo.new(gpa, vocab.slices, .Raw, null, &.{24}, false, null);
        warm.deinit();
        for (&tok_samples) |*slot| {
            const t0 = nowNs();
            var ti = try xgrammar.TokenizerInfo.new(gpa, vocab.slices, .Raw, null, &.{24}, false, null);
            const t1 = nowNs();
            ti.deinit();
            slot.* = t1 - t0;
        }
    }
    const tok_stats = computeStats(&tok_samples, 1.0);

    var tok = try xgrammar.TokenizerInfo.new(gpa, vocab.slices, .Raw, null, &.{24}, false, null);
    defer tok.deinit();

    // 2. Cold JSON Schema compilation (max_threads = 1)
    var json_1t_samples: [5]u64 = undefined;
    {
        const c1 = try xgrammar.GrammarCompiler.new(gpa, &tok, 1, false, -1);
        defer c1.deinit();
        var warm = try c1.compile_json_schema(JSON_SCHEMA, true, null, null, true, null, null);
        warm.deinit();
        for (&json_1t_samples) |*slot| {
            const t0 = nowNs();
            var cg = try c1.compile_json_schema(JSON_SCHEMA, true, null, null, true, null, null);
            const t1 = nowNs();
            cg.deinit();
            slot.* = t1 - t0;
        }
    }
    const json_1t_stats = computeStats(&json_1t_samples, 1.0);

    // 3. Cold JSON Schema compilation (max_threads = 4)
    var json_4t_samples: [5]u64 = undefined;
    {
        const c4 = try xgrammar.GrammarCompiler.new(gpa, &tok, 4, false, -1);
        defer c4.deinit();
        var warm = try c4.compile_json_schema(JSON_SCHEMA, true, null, null, true, null, null);
        warm.deinit();
        for (&json_4t_samples) |*slot| {
            const t0 = nowNs();
            var cg = try c4.compile_json_schema(JSON_SCHEMA, true, null, null, true, null, null);
            const t1 = nowNs();
            cg.deinit();
            slot.* = t1 - t0;
        }
    }
    const json_4t_stats = computeStats(&json_4t_samples, 1.0);

    // 4. Cold EBNF compilation (max_threads = 1)
    var ebnf_1t_samples: [5]u64 = undefined;
    {
        const c1 = try xgrammar.GrammarCompiler.new(gpa, &tok, 1, false, -1);
        defer c1.deinit();
        var warm = try c1.compile_grammar_ebnf(EBNF_GRAMMAR, "root", null);
        warm.deinit();
        for (&ebnf_1t_samples) |*slot| {
            const t0 = nowNs();
            var cg = try c1.compile_grammar_ebnf(EBNF_GRAMMAR, "root", null);
            const t1 = nowNs();
            cg.deinit();
            slot.* = t1 - t0;
        }
    }
    const ebnf_1t_stats = computeStats(&ebnf_1t_samples, 1.0);

    // Compile JSON Schema once for matcher & bitmask benchmarks.
    const comp = try xgrammar.GrammarCompiler.new(gpa, &tok, 4, false, -1);
    defer comp.deinit();
    var compiled = try comp.compile_json_schema(JSON_SCHEMA, true, null, null, true, null, null);
    defer compiled.deinit();

    var matcher = try xgrammar.GrammarMatcher.from_compiled_grammar(gpa, &compiled, false);
    defer matcher.deinit();

    const bm_size = xgrammar.get_bitmask_size(tok.vocab_size);
    const shape = [2]i64{ 1, bm_size };
    const bitmask = try xgrammar.allocate_token_bitmask(gpa, 1, tok.vocab_size);
    defer gpa.free(bitmask);

    // 5. fill_next_token_bitmask + accept_token (33 tokens per pass)
    var fill_samples: [50]u64 = undefined;
    var fill_checksum: u64 = 0;
    var accepted_count: usize = 0;
    for (0..55) |pass_idx| {
        try matcher.reset();
        const t0 = nowNs();
        var local_hash: u64 = 0;
        var local_acc: usize = 0;
        for (TRACE_IDS) |tid| {
            _ = try matcher.fill_next_token_bitmask(bitmask, &shape, 0, null);
            for (bitmask) |w| {
                local_hash = (local_hash *% 1099511628211) ^ @as(u32, @bitCast(w));
            }
            if (try matcher.accept_token(tid)) local_acc += 1;
        }
        const t1 = nowNs();
        if (pass_idx >= 5) {
            fill_samples[pass_idx - 5] = t1 - t0;
        }
        fill_checksum = local_hash;
        accepted_count = local_acc;
    }
    const fill_stats = computeStats(&fill_samples, @floatFromInt(TRACE_LEN));

    // Prepare realistic bitmask from mid-generation step (after `{`) for logit apply bench.
    try matcher.reset();
    _ = try matcher.accept_token(0);
    _ = try matcher.fill_next_token_bitmask(bitmask, &shape, 0, null);

    // 6. apply_token_bitmask_inplace_cpu on 32K logits (batch = 1)
    const logits_b1 = try gpa.alloc(f32, VOCAB_SIZE);
    defer gpa.free(logits_b1);
    var apply_b1_samples: [200]u64 = undefined;
    for (0..220) |run| {
        for (logits_b1, 0..) |*v, j| v.* = @floatFromInt(j & 255);
        const t0 = nowNs();
        var k: usize = 0;
        while (k < 25) : (k += 1) {
            xgrammar.apply_token_bitmask_inplace_cpu(logits_b1, bitmask, tok.vocab_size);
            std.mem.doNotOptimizeAway(logits_b1.ptr);
        }
        const t1 = nowNs();
        if (run >= 20) {
            apply_b1_samples[run - 20] = t1 - t0;
        }
    }
    const apply_b1_stats = computeStats(&apply_b1_samples, 25.0);

    // 7. apply_token_bitmask_inplace_cpu_batch on 4x32K = 128K logits (batch = 4)
    const batch4_bm = try xgrammar.allocate_token_bitmask(gpa, 4, tok.vocab_size);
    defer gpa.free(batch4_bm);
    for (0..4) |b| {
        @memcpy(batch4_bm[b * @as(usize, @intCast(bm_size)) .. (b + 1) * @as(usize, @intCast(bm_size))], bitmask);
    }
    const logits_b4 = try gpa.alloc(f32, 4 * VOCAB_SIZE);
    defer gpa.free(logits_b4);
    var apply_b4_samples: [100]u64 = undefined;
    for (0..110) |run| {
        for (logits_b4, 0..) |*v, j| v.* = @floatFromInt(j & 255);
        const t0 = nowNs();
        var k: usize = 0;
        while (k < 10) : (k += 1) {
            xgrammar.apply_token_bitmask_inplace_cpu_batch(logits_b4, batch4_bm, tok.vocab_size, 4, null);
            std.mem.doNotOptimizeAway(logits_b4.ptr);
        }
        const t1 = nowNs();
        if (run >= 10) {
            apply_b4_samples[run - 10] = t1 - t0;
        }
    }
    const apply_b4_stats = computeStats(&apply_b4_samples, 10.0);

    // 8. End-to-end 33-token constrained decode step (fill + apply_logits + accept)
    var e2e_samples: [50]u64 = undefined;
    for (0..55) |pass_idx| {
        try matcher.reset();
        const t0 = nowNs();
        for (TRACE_IDS) |tid| {
            _ = try matcher.fill_next_token_bitmask(bitmask, &shape, 0, null);
            xgrammar.apply_token_bitmask_inplace_cpu(logits_b1, bitmask, tok.vocab_size);
            std.mem.doNotOptimizeAway(logits_b1.ptr);
            _ = try matcher.accept_token(tid);
        }
        const t1 = nowNs();
        if (pass_idx >= 5) {
            e2e_samples[pass_idx - 5] = t1 - t0;
        }
    }
    const e2e_stats = computeStats(&e2e_samples, @floatFromInt(TRACE_LEN));

    var out_aw: std.Io.Writer.Allocating = .init(gpa);
    defer out_aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &out_aw.writer };
    try jw.beginObject();
    try jw.objectField("impl");
    try jw.write("xgrammar-zig");
    try jw.objectField("vocab_size");
    try jw.write(tok.vocab_size);
    try jw.objectField("accepted_count");
    try jw.write(accepted_count);
    try jw.objectField("bitmask_checksum");
    try jw.write(fill_checksum);
    const entries = [_]struct { name: []const u8, s: Stats }{
        .{ .name = "tokenizer_info_init_32k_us", .s = tok_stats },
        .{ .name = "compile_json_schema_1t_us", .s = json_1t_stats },
        .{ .name = "compile_json_schema_4t_us", .s = json_4t_stats },
        .{ .name = "compile_ebnf_1t_us", .s = ebnf_1t_stats },
        .{ .name = "fill_bitmask_32k_per_token_us", .s = fill_stats },
        .{ .name = "apply_bitmask_32k_b1_us", .s = apply_b1_stats },
        .{ .name = "apply_bitmask_128k_b4_us", .s = apply_b4_stats },
        .{ .name = "e2e_decode_32k_per_token_us", .s = e2e_stats },
    };
    for (entries) |e| {
        try jw.objectField(e.name);
        try jw.beginObject();
        try jw.objectField("median");
        try jw.write(e.s.median_us);
        try jw.objectField("mean");
        try jw.write(e.s.mean_us);
        try jw.objectField("min");
        try jw.write(e.s.min_us);
        try jw.endObject();
    }
    try jw.endObject();
    try out_aw.writer.writeByte('\n');
    try std.Io.File.stdout().writeStreamingAll(io, out_aw.written());
}
