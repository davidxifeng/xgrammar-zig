//! A cache to get the compiled grammar for a grammar or schema (`grammar_compiler.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const compiled_grammar_mod = @import("CompiledGrammar.zig");
const CompiledGrammar = compiled_grammar_mod.CompiledGrammar;
const rule_level_cache_mod = @import("rule_level_cache.zig");
const RuleLevelCache = rule_level_cache_mod.RuleLevelCache;
const UNLIMITED_SIZE = rule_level_cache_mod.UNLIMITED_SIZE;

const converter = @import("../converter.zig");
const Diagnostic = @import("../Diagnostic.zig").Diagnostic;
const functor = @import("../functor.zig");
const grammar_mod = @import("../grammar.zig");
const Grammar = grammar_mod.Grammar;
const parser_mod = @import("../parser.zig");
const support = @import("../support.zig");
const tokenizer_mod = @import("../tokenizer.zig");
const TokenizerInfo = tokenizer_mod.TokenizerInfo;

/// Unified error set from converting, validating, or compiling a grammar.
pub const CompileError = Allocator.Error ||
    support.Compact2dArrayError ||
    parser_mod.EbnfError ||
    converter.SchemaError ||
    converter.RegexError ||
    converter.StructuralTagError ||
    converter.LarkError ||
    functor.FunctorError ||
    error{TokenIdOutOfRange};

const CacheState = struct {
    allocator: Allocator,
    lru: support.LruCache([]const u8, CompiledGrammar, std.hash_map.StringContext),
    size_bytes: usize,

    fn init(allocator: Allocator) CacheState {
        return .{
            .allocator = allocator,
            .lru = support.LruCache([]const u8, CompiledGrammar, std.hash_map.StringContext).init(),
            .size_bytes = 0,
        };
    }

    fn deinit(self: *CacheState) void {
        self.clear();
        self.lru.deinit(self.allocator);
    }

    fn clear(self: *CacheState) void {
        while (self.lru.popLru()) |entry| {
            self.allocator.free(entry.key);
            var val = entry.value;
            val.deinit();
        }
        self.lru.clearRetainingCapacity();
        self.size_bytes = 0;
    }

    fn get(self: *CacheState, key: []const u8) ?CompiledGrammar {
        const val = self.lru.getPtr(key) orelse return null;
        return val.retain();
    }

    /// Inserts `key_owned -> value` into the LRU cache; takes ownership on success only.
    fn insert(
        self: *CacheState,
        key_owned: []u8,
        value: CompiledGrammar,
        max_memory_bytes: ?usize,
    ) Allocator.Error!void {
        const entry_size = value.memorySizeBytes();
        if (try self.lru.put(self.allocator, key_owned, value)) |old| {
            var old_val = old.value;
            self.size_bytes -|= old_val.memorySizeBytes();
            old_val.deinit();
            self.allocator.free(old.key);
        }
        self.size_bytes += entry_size;
        self.evictToLimit(max_memory_bytes);
    }

    fn evictToLimit(self: *CacheState, max_memory_bytes: ?usize) void {
        const limit = max_memory_bytes orelse return;
        while (self.size_bytes > limit) {
            const oldest = self.lru.popLru() orelse break;
            var removed_val = oldest.value;
            self.size_bytes -|= removed_val.memorySizeBytes();
            removed_val.deinit();
            self.allocator.free(oldest.key);
        }
    }
};

const CompilerState = struct {
    allocator: Allocator,
    tokenizer_info: TokenizerInfo,
    max_threads: ?u32,
    cache_enabled: bool,
    max_memory_bytes: ?usize,
    grammar_cache_limit_bytes: ?usize,
    rule_level_cache: ?*RuleLevelCache,
    cache_mutex: std.atomic.Mutex,
    cache: CacheState,
};

/// Value handle to a grammar compiler with optional compiled-grammar and rule-level caching.
///
/// Always compiles grammars against the vocabulary supplied at `init`.
pub const GrammarCompiler = struct {
    state: *CompilerState,

    pub const Options = struct {
        max_threads: ?u32 = null,
        cache_enabled: bool = true,
        max_memory_bytes: ?usize = null,
    };

    pub const EbnfOptions = struct {
        root_rule_name: []const u8 = "root",
        diag: ?*Diagnostic = null,
    };

    pub const JsonSchemaOptions = converter.JsonSchemaOptions;

    pub const LarkOptions = struct {
        named_grammars: []const converter.NamedGrammar = &.{},
        diag: ?*Diagnostic = null,
    };

    /// Constructs a `GrammarCompiler` bound to `tokenizer` (retaining its storage).
    pub fn init(
        allocator: Allocator,
        tokenizer: *const TokenizerInfo,
        options: Options,
    ) Allocator.Error!GrammarCompiler {
        const grammar_cache_limit_bytes: ?usize = if (options.max_memory_bytes) |bytes|
            (bytes / 3) * 2
        else
            null;

        const rlc: ?*RuleLevelCache = if (options.cache_enabled) blk: {
            const rl_limit: usize = if (options.max_memory_bytes) |bytes|
                bytes - (bytes / 3) * 2
            else
                UNLIMITED_SIZE;
            break :blk try RuleLevelCache.init(allocator, rl_limit);
        } else null;
        errdefer if (rlc) |c| c.deinit();

        var tok_copy = tokenizer.retain();
        errdefer tok_copy.deinit();

        const state = try allocator.create(CompilerState);
        state.* = .{
            .allocator = allocator,
            .tokenizer_info = tok_copy,
            .max_threads = options.max_threads,
            .cache_enabled = options.cache_enabled,
            .max_memory_bytes = options.max_memory_bytes,
            .grammar_cache_limit_bytes = grammar_cache_limit_bytes,
            .rule_level_cache = rlc,
            .cache_mutex = .unlocked,
            .cache = CacheState.init(allocator),
        };
        return .{ .state = state };
    }

    pub fn deinit(self: *GrammarCompiler) void {
        const a = self.state.allocator;
        self.state.cache.deinit();
        if (self.state.rule_level_cache) |c| c.deinit();
        self.state.tokenizer_info.deinit();
        a.destroy(self.state);
        self.* = undefined;
    }

    fn lockCache(self: *const GrammarCompiler) void {
        while (!self.state.cache_mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlockCache(self: *const GrammarCompiler) void {
        self.state.cache_mutex.unlock();
    }

    /// Compiles an existing `Grammar`.
    pub fn compileGrammar(
        self: *const GrammarCompiler,
        grammar: *const Grammar,
        diag: ?*Diagnostic,
    ) CompileError!CompiledGrammar {
        const a = self.state.allocator;
        if (!self.state.cache_enabled) {
            return self.optimize(grammar, diag);
        }
        const printed = try grammar.toStringEbnf(a);
        defer a.free(printed);
        const key = try std.fmt.allocPrint(a, "grammar:{s}", .{printed});
        if (self.tryCacheGet(key)) |hit| {
            a.free(key);
            return hit;
        }
        errdefer a.free(key);
        const compiled = try self.optimize(grammar, diag);
        return self.compileAndStore(key, compiled);
    }

    /// Compiles a grammar from an EBNF string.
    pub fn compileEbnf(
        self: *const GrammarCompiler,
        ebnf: []const u8,
        options: EbnfOptions,
    ) CompileError!CompiledGrammar {
        const a = self.state.allocator;
        if (!self.state.cache_enabled) {
            var grammar = try functor.fromEbnf(a, ebnf, options.root_rule_name, options.diag);
            defer grammar.deinit();
            return self.optimize(&grammar, options.diag);
        }
        const key = try std.fmt.allocPrint(
            a,
            "ebnf:{d}:{s}:{d}:{s}",
            .{ options.root_rule_name.len, options.root_rule_name, ebnf.len, ebnf },
        );
        if (self.tryCacheGet(key)) |hit| {
            a.free(key);
            return hit;
        }
        errdefer a.free(key);
        var grammar = try functor.fromEbnf(a, ebnf, options.root_rule_name, options.diag);
        defer grammar.deinit();
        const compiled = try self.optimize(&grammar, options.diag);
        return self.compileAndStore(key, compiled);
    }

    /// Compiles the built-in JSON grammar.
    pub fn compileBuiltinJson(
        self: *const GrammarCompiler,
        diag: ?*Diagnostic,
    ) Allocator.Error!CompiledGrammar {
        const a = self.state.allocator;
        if (!self.state.cache_enabled) {
            var grammar = try functor.builtinJsonGrammar(a);
            defer grammar.deinit();
            return self.optimize(&grammar, diag) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => unreachable,
            };
        }
        const key = try a.dupe(u8, "builtin_json");
        if (self.tryCacheGet(key)) |hit| {
            a.free(key);
            return hit;
        }
        errdefer a.free(key);
        var grammar = try functor.builtinJsonGrammar(a);
        defer grammar.deinit();
        const compiled = self.optimize(&grammar, diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };
        return self.compileAndStore(key, compiled);
    }

    /// Compiles a JSON Schema string using `converter.JsonSchemaOptions`.
    pub fn compileJsonSchema(
        self: *const GrammarCompiler,
        schema: []const u8,
        options: JsonSchemaOptions,
    ) CompileError!CompiledGrammar {
        const a = self.state.allocator;
        if (!self.state.cache_enabled) {
            var grammar = try converter.fromJsonSchema(a, schema, options);
            defer grammar.deinit();
            return self.optimize(&grammar, options.diag);
        }
        const key = try buildJsonSchemaCacheKey(a, schema, options);
        if (self.tryCacheGet(key)) |hit| {
            a.free(key);
            return hit;
        }
        errdefer a.free(key);
        var grammar = try converter.fromJsonSchema(a, schema, options);
        defer grammar.deinit();
        const compiled = try self.optimize(&grammar, options.diag);
        return self.compileAndStore(key, compiled);
    }

    /// Compiles a regular expression string.
    pub fn compileRegex(
        self: *const GrammarCompiler,
        regex: []const u8,
        diag: ?*Diagnostic,
    ) CompileError!CompiledGrammar {
        const a = self.state.allocator;
        if (!self.state.cache_enabled) {
            var grammar = try converter.fromRegex(a, regex, diag);
            defer grammar.deinit();
            return self.optimize(&grammar, diag);
        }
        const key = try std.fmt.allocPrint(a, "regex:{s}", .{regex});
        if (self.tryCacheGet(key)) |hit| {
            a.free(key);
            return hit;
        }
        errdefer a.free(key);
        var grammar = try converter.fromRegex(a, regex, diag);
        defer grammar.deinit();
        const compiled = try self.optimize(&grammar, diag);
        return self.compileAndStore(key, compiled);
    }

    /// Compiles a Lark grammar string (root rule must be named `start`).
    pub fn compileLark(
        self: *const GrammarCompiler,
        lark: []const u8,
        options: LarkOptions,
    ) CompileError!CompiledGrammar {
        const a = self.state.allocator;
        if (!self.state.cache_enabled) {
            var grammar = try converter.fromLark(
                a,
                lark,
                &self.state.tokenizer_info,
                options.named_grammars,
                options.diag,
            );
            defer grammar.deinit();
            return self.optimize(&grammar, options.diag);
        }
        const key = try buildLarkCacheKey(a, lark, options.named_grammars);
        if (self.tryCacheGet(key)) |hit| {
            a.free(key);
            return hit;
        }
        errdefer a.free(key);
        var grammar = try converter.fromLark(
            a,
            lark,
            &self.state.tokenizer_info,
            options.named_grammars,
            options.diag,
        );
        defer grammar.deinit();
        const compiled = try self.optimize(&grammar, options.diag);
        return self.compileAndStore(key, compiled);
    }

    /// Compiles a structural tag JSON specification against the compiler's tokenizer.
    pub fn compileStructuralTag(
        self: *const GrammarCompiler,
        json: []const u8,
        diag: ?*Diagnostic,
    ) CompileError!CompiledGrammar {
        const a = self.state.allocator;
        if (!self.state.cache_enabled) {
            var grammar = try converter.fromStructuralTagWithTokenizer(a, json, &self.state.tokenizer_info, diag);
            defer grammar.deinit();
            return self.optimize(&grammar, diag);
        }
        const key = try std.fmt.allocPrint(a, "stag:{s}", .{json});
        if (self.tryCacheGet(key)) |hit| {
            a.free(key);
            return hit;
        }
        errdefer a.free(key);
        var grammar = try converter.fromStructuralTagWithTokenizer(a, json, &self.state.tokenizer_info, diag);
        defer grammar.deinit();
        const compiled = try self.optimize(&grammar, diag);
        return self.compileAndStore(key, compiled);
    }

    /// Clears the compiled-grammar cache.
    pub fn clearCache(self: *const GrammarCompiler) void {
        self.lockCache();
        defer self.unlockCache();
        self.state.cache.clear();
    }

    /// Returns the approximate memory usage of the compiled-grammar cache in bytes.
    pub fn cacheSizeBytes(self: *const GrammarCompiler) usize {
        self.lockCache();
        defer self.unlockCache();
        return self.state.cache.size_bytes;
    }

    /// Returns the configured cache memory limit in bytes, or `null` if unlimited.
    pub fn cacheLimitBytes(self: *const GrammarCompiler) ?usize {
        return self.state.max_memory_bytes;
    }

    /// Returns the configured maximum worker thread count, or `null` for automatic.
    pub fn maxThreads(self: *const GrammarCompiler) ?u32 {
        return self.state.max_threads;
    }

    /// Returns the bound tokenizer info.
    pub fn tokenizerInfo(self: *const GrammarCompiler) *const TokenizerInfo {
        return &self.state.tokenizer_info;
    }

    fn tryCacheGet(self: *const GrammarCompiler, key: []const u8) ?CompiledGrammar {
        if (!self.state.cache_enabled) return null;
        self.lockCache();
        defer self.unlockCache();
        return self.state.cache.get(key);
    }

    fn compileAndStore(
        self: *const GrammarCompiler,
        key_owned: []u8,
        compiled_in: CompiledGrammar,
    ) Allocator.Error!CompiledGrammar {
        const a = self.state.allocator;
        if (!self.state.cache_enabled) {
            a.free(key_owned);
            return compiled_in;
        }
        var compiled = compiled_in;
        var stored = false;
        errdefer if (!stored) {
            a.free(key_owned);
            compiled.deinit();
        };
        var result_handle = compiled.retain();
        errdefer result_handle.deinit();

        self.lockCache();
        defer self.unlockCache();
        try self.state.cache.insert(key_owned, compiled, self.state.grammar_cache_limit_bytes);
        stored = true;
        return result_handle;
    }

    /// Optimizes `grammar` (if needed), checks token id bounds, builds the adaptive
    /// token-mask cache, and bundles the result with the tokenizer.
    fn optimize(
        self: *const GrammarCompiler,
        grammar: *const Grammar,
        diag: ?*Diagnostic,
    ) CompileError!CompiledGrammar {
        const a = self.state.allocator;
        var optimized = if (grammar.isOptimized())
            try grammar.dupe(a)
        else
            try functor.optimizeGrammar(a, grammar, diag);
        {
            errdefer optimized.deinit();
            try self.checkTokenIdsInVocab(&optimized, diag);
            if (self.state.rule_level_cache != null) {
                try functor.hashGrammarFsms(a, &optimized);
            }
        }
        return CompiledGrammar.build(
            a,
            optimized,
            &self.state.tokenizer_info,
            self.state.max_threads,
            self.state.rule_level_cache,
        );
    }

    /// Checks that every token id referenced in `Token`, `ExcludeToken`, and
    /// `TokenTagDispatch` edges falls within `[0, vocabSize())`.
    fn checkTokenIdsInVocab(
        self: *const GrammarCompiler,
        grammar: *const Grammar,
        diag: ?*Diagnostic,
    ) CompileError!void {
        const vocab_size = self.state.tokenizer_info.vocabSize();
        const fsm = grammar.completeFsm();
        var state: i32 = 0;
        while (state < fsm.numStates()) : (state += 1) {
            for (fsm.stateEdges(state)) |edge| {
                if (!edge.isToken() and !edge.isExcludeToken()) continue;
                // Token and exclude-token edges share the `[count, token_id...]` aux layout.
                for (fsm.tokenEdgeInfo(edge.auxIndex()).tokenIds()) |token_id| {
                    if (token_id < 0 or @as(usize, @intCast(token_id)) >= vocab_size) {
                        if (diag) |d| {
                            d.setNumbers(
                                .compile_token_id_out_of_range,
                                token_id,
                                std.math.cast(i64, vocab_size) orelse std.math.maxInt(i64),
                            );
                        }
                        return error.TokenIdOutOfRange;
                    }
                }
            }
        }
    }
};

fn buildJsonSchemaCacheKey(
    allocator: Allocator,
    schema: []const u8,
    options: converter.JsonSchemaOptions,
) Allocator.Error![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    w.print(
        "schema:ws={any}:ind={?d}:strict={any}:mwc={?d}:order={any}:fmt={s}:",
        .{
            options.any_whitespace,
            options.indent,
            options.strict_mode,
            options.max_whitespace_cnt,
            options.any_order,
            @tagName(options.json_format),
        },
    ) catch return error.OutOfMemory;
    if (options.separators) |s| {
        w.print("sep=some:{d}:{s}:{d}:{s}:", .{ s.item.len, s.item, s.colon.len, s.colon }) catch
            return error.OutOfMemory;
    } else {
        w.writeAll("sep=none:") catch return error.OutOfMemory;
    }
    w.print("excl={d}:[", .{options.excludes.len}) catch return error.OutOfMemory;
    for (options.excludes) |excl| {
        w.print("{d}:{s};", .{ excl.len, excl }) catch return error.OutOfMemory;
    }
    w.print("]:len={d}:{s}", .{ schema.len, schema }) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn buildLarkCacheKey(
    allocator: Allocator,
    lark: []const u8,
    named_grammars: []const converter.NamedGrammar,
) Allocator.Error![]u8 {
    if (named_grammars.len == 0) {
        return std.fmt.allocPrint(allocator, "lark:{d}:{s}:[]", .{ lark.len, lark });
    }
    const NamedKey = struct {
        name: []const u8,
        is_lark_source: bool,
        content: []const u8,
        owned_content: ?[]u8,
        root_rule_name: []const u8,
    };
    var named_keys = try std.ArrayList(NamedKey).initCapacity(allocator, named_grammars.len);
    defer {
        for (named_keys.items) |nk| {
            if (nk.owned_content) |oc| allocator.free(oc);
        }
        named_keys.deinit(allocator);
    }
    for (named_grammars) |ng| {
        switch (ng) {
            .grammar => |entry| {
                const printed = try entry.grammar.toStringEbnf(allocator);
                named_keys.appendAssumeCapacity(.{
                    .name = entry.name,
                    .is_lark_source = false,
                    .content = printed,
                    .owned_content = printed,
                    .root_rule_name = entry.grammar.rootRule().name,
                });
            },
            .lark => |entry| {
                named_keys.appendAssumeCapacity(.{
                    .name = entry.name,
                    .is_lark_source = true,
                    .content = entry.source,
                    .owned_content = null,
                    .root_rule_name = "",
                });
            },
        }
    }
    std.mem.sortUnstable(NamedKey, named_keys.items, {}, struct {
        fn less(_: void, a: NamedKey, b: NamedKey) bool {
            const no = std.mem.order(u8, a.name, b.name);
            if (no != .eq) return no == .lt;
            if (a.is_lark_source != b.is_lark_source) return !a.is_lark_source and b.is_lark_source;
            const co = std.mem.order(u8, a.content, b.content);
            if (co != .eq) return co == .lt;
            return std.mem.order(u8, a.root_rule_name, b.root_rule_name) == .lt;
        }
    }.less);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;
    w.print("lark:{d}:{s}:[", .{ lark.len, lark }) catch return error.OutOfMemory;
    for (named_keys.items) |nk| {
        w.print("({d}:{s},{any},{d}:{s},{d}:{s})", .{
            nk.name.len,
            nk.name,
            nk.is_lark_source,
            nk.content.len,
            nk.content,
            nk.root_rule_name.len,
            nk.root_rule_name,
        }) catch return error.OutOfMemory;
    }
    w.writeByte(']') catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

test {
    std.testing.refAllDecls(GrammarCompiler);
}
