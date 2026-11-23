//! A cache to get the compiled grammar for a grammar or schema (`grammar_compiler.rs`).

const std = @import("std");
const Allocator = std.mem.Allocator;

const compiled_grammar_mod = @import("compiled_grammar.zig");
const CompiledGrammar = compiled_grammar_mod.CompiledGrammar;
const error_mod = @import("error.zig");
const CompileError = error_mod.CompileError;
const CompileErrorInfo = error_mod.CompileErrorInfo;
const rule_level_cache_mod = @import("rule_level_cache.zig");
const RuleLevelCache = rule_level_cache_mod.RuleLevelCache;
const UNLIMITED_SIZE = rule_level_cache_mod.UNLIMITED_SIZE;

const converter = @import("../converter/mod.zig");
const functor = @import("../functor/mod.zig");
const grammar_mod = @import("../grammar/mod.zig");
const Grammar = grammar_mod.Grammar;
const parser_mod = @import("../parser/mod.zig");
const support = @import("../support/mod.zig");
const tokenizer_mod = @import("../tokenizer/mod.zig");
const TokenizerInfo = tokenizer_mod.tokenizer_info.TokenizerInfo;

/// Unlimited cache size sentinel.
const UNLIMITED: i64 = -1;

const CacheState = struct {
    allocator: Allocator,
    lru: support.LruCache([]const u8, CompiledGrammar, std.hash_map.StringContext),
    size_bytes: i64,

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
        return val.clone();
    }

    /// Takes ownership of `key_owned` (allocated with `self.allocator`) and `value` (cloned or moved).
    fn insert(
        self: *CacheState,
        key_owned: []u8,
        value_in: CompiledGrammar,
        max_memory_bytes: i64,
    ) Allocator.Error!void {
        var value = value_in;
        errdefer {
            self.allocator.free(key_owned);
            value.deinit();
        }
        const entry_size: i64 = @intCast(value.memory_size_bytes());
        if (self.lru.remove(key_owned)) |old| {
            var old_val = old.value;
            self.size_bytes -= @as(i64, @intCast(old_val.memory_size_bytes()));
            old_val.deinit();
            self.allocator.free(old.key);
        }
        _ = try self.lru.put(self.allocator, key_owned, value);
        self.size_bytes += entry_size;
        if (self.size_bytes < 0) self.size_bytes = 0;
        self.evict_to_limit(max_memory_bytes);
    }

    fn evict_to_limit(self: *CacheState, max_memory_bytes: i64) void {
        if (max_memory_bytes < 0) return;
        while (self.size_bytes > max_memory_bytes) {
            const oldest = self.lru.popLru() orelse break;
            var removed_val = oldest.value;
            self.size_bytes -= @as(i64, @intCast(removed_val.memory_size_bytes()));
            removed_val.deinit();
            self.allocator.free(oldest.key);
        }
        if (self.size_bytes < 0) self.size_bytes = 0;
    }
};

/// A cache to get the compiled grammar for a grammar or schema.
///
/// Avoids redundant preprocessing when constructing a `CompiledGrammar`. Always creates
/// compiled grammars with the vocabulary supplied at construction.
pub const GrammarCompiler = struct {
    allocator: Allocator,
    tokenizer_info: TokenizerInfo,
    max_threads: i32,
    cache_enabled: bool,
    max_memory_bytes: i64,
    grammar_cache_limit_bytes: i64,
    rule_level_cache: ?*RuleLevelCache,
    cache_mutex: std.atomic.Mutex,
    cache: CacheState,

    fn lock_cache(self: *GrammarCompiler) void {
        while (!self.cache_mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock_cache(self: *GrammarCompiler) void {
        self.cache_mutex.unlock();
    }

    /// Constructs a heap-allocated `GrammarCompiler` with a vocabulary (cloning `tokenizer`).
    ///
    /// `max_threads` is the maximum number of threads to use for compiling grammars.
    /// `cache_enabled` controls whether the cache is enabled.
    /// `max_memory_bytes` is the maximum memory usage in bytes (`-1` for unlimited).
    pub fn new(
        allocator: Allocator,
        tokenizer: *const TokenizerInfo,
        max_threads_arg: i32,
        cache_enabled: bool,
        max_memory_bytes: i64,
    ) Allocator.Error!*GrammarCompiler {
        std.debug.assert(max_memory_bytes >= -1);
        const grammar_cache_limit_bytes: i64 = if (max_memory_bytes < 0)
            UNLIMITED
        else
            @divTrunc(max_memory_bytes, 3) * 2;

        const rlc: ?*RuleLevelCache = if (cache_enabled) blk: {
            const rl_limit: usize = if (max_memory_bytes < 0)
                UNLIMITED_SIZE
            else
                @intCast(max_memory_bytes - @divTrunc(max_memory_bytes, 3) * 2);
            break :blk try RuleLevelCache.new(allocator, rl_limit);
        } else null;
        errdefer if (rlc) |c| c.deinit();

        var tok_copy = try tokenizer.clone(allocator);
        errdefer tok_copy.deinit();

        const self = try allocator.create(GrammarCompiler);
        self.* = .{
            .allocator = allocator,
            .tokenizer_info = tok_copy,
            .max_threads = max_threads_arg,
            .cache_enabled = cache_enabled,
            .max_memory_bytes = max_memory_bytes,
            .grammar_cache_limit_bytes = grammar_cache_limit_bytes,
            .rule_level_cache = rlc,
            .cache_mutex = .unlocked,
            .cache = CacheState.init(allocator),
        };
        return self;
    }

    /// Creates a compiler with default settings (`max_threads=8`, cache enabled, unlimited memory).
    pub fn with_defaults(allocator: Allocator, tokenizer: *const TokenizerInfo) Allocator.Error!*GrammarCompiler {
        return GrammarCompiler.new(allocator, tokenizer, 8, true, UNLIMITED);
    }

    pub fn deinit(self: *GrammarCompiler) void {
        const a = self.allocator;
        self.cache.deinit();
        if (self.rule_level_cache) |c| c.deinit();
        self.tokenizer_info.deinit();
        a.destroy(self);
    }

    /// Gets the compiled grammar for a grammar.
    pub fn compile_grammar(
        self: *GrammarCompiler,
        grammar: *const Grammar,
        diag: ?*CompileErrorInfo,
    ) CompileError!CompiledGrammar {
        const printed = try grammar_mod.printer.to_string_ebnf(grammar, self.allocator);
        defer self.allocator.free(printed);
        const key = try std.fmt.allocPrint(self.allocator, "grammar:{s}", .{printed});
        if (self.try_cache_get(key)) |hit| {
            self.allocator.free(key);
            return hit;
        }
        const compiled = self.optimize(grammar, diag) catch |err| {
            self.allocator.free(key);
            return err;
        };
        return self.compile_and_store(key, compiled);
    }

    /// Compiles a grammar from an EBNF string.
    pub fn compile_grammar_ebnf(
        self: *GrammarCompiler,
        ebnf_str: []const u8,
        root_rule_name: []const u8,
        diag: ?*CompileErrorInfo,
    ) CompileError!CompiledGrammar {
        const key = try std.fmt.allocPrint(self.allocator, "ebnf:{s}:{s}", .{ root_rule_name, ebnf_str });
        if (self.try_cache_get(key)) |hit| {
            self.allocator.free(key);
            return hit;
        }
        var ebnf_diag: parser_mod.EbnfErrorInfo = undefined;
        const grammar = functor.grammar_normalizer_mod.from_ebnf(
            self.allocator,
            ebnf_str,
            root_rule_name,
            if (diag != null) &ebnf_diag else null,
        ) catch |err| {
            self.allocator.free(key);
            if (err != error.OutOfMemory) {
                if (diag) |d| d.* = .{ .Ebnf = ebnf_diag };
            }
            return err;
        };
        defer grammar.deinit();
        const compiled = self.optimize(grammar, diag) catch |err| {
            self.allocator.free(key);
            return err;
        };
        return self.compile_and_store(key, compiled);
    }

    /// Gets the compiled grammar for pure JSON.
    pub fn compile_builtin_json_grammar(self: *GrammarCompiler) Allocator.Error!CompiledGrammar {
        const key = try self.allocator.dupe(u8, "builtin_json");
        if (self.try_cache_get(key)) |hit| {
            self.allocator.free(key);
            return hit;
        }
        const grammar = try functor.grammar_normalizer_mod.builtin_json_grammar(self.allocator);
        defer grammar.deinit();
        const compiled = self.optimize(grammar, null) catch |err| switch (err) {
            error.OutOfMemory => {
                self.allocator.free(key);
                return error.OutOfMemory;
            },
            else => unreachable,
        };
        return self.compile_and_store(key, compiled);
    }

    /// Gets the compiled grammar for a JSON schema string.
    pub fn compile_json_schema(
        self: *GrammarCompiler,
        schema: []const u8,
        any_whitespace: bool,
        indent: ?i32,
        separators: ?converter.Separators,
        strict_mode: bool,
        max_whitespace_cnt: ?i32,
        diag: ?*CompileErrorInfo,
    ) CompileError!CompiledGrammar {
        return self.compile_json_schema_with_any_order(
            schema,
            any_whitespace,
            indent,
            separators,
            strict_mode,
            max_whitespace_cnt,
            false,
            diag,
        );
    }

    /// Gets the compiled grammar for a JSON schema string, with optional property-order
    /// independence.
    pub fn compile_json_schema_with_any_order(
        self: *GrammarCompiler,
        schema: []const u8,
        any_whitespace: bool,
        indent: ?i32,
        separators: ?converter.Separators,
        strict_mode: bool,
        max_whitespace_cnt: ?i32,
        any_order: bool,
        diag: ?*CompileErrorInfo,
    ) CompileError!CompiledGrammar {
        const sep_str = if (separators) |s|
            try std.fmt.allocPrint(self.allocator, "some:{d}:{s}:{d}:{s}", .{ s.item.len, s.item, s.colon.len, s.colon })
        else
            try self.allocator.dupe(u8, "none");
        defer self.allocator.free(sep_str);

        const key = try std.fmt.allocPrint(
            self.allocator,
            "schema:ws={any}:ind={?d}:sep={s}:strict={any}:mwc={?d}:order={any}:len={d}:{s}",
            .{ any_whitespace, indent, sep_str, strict_mode, max_whitespace_cnt, any_order, schema.len, schema },
        );
        if (self.try_cache_get(key)) |hit| {
            self.allocator.free(key);
            return hit;
        }
        var schema_diag: converter.SchemaErrorInfo = undefined;
        const grammar = converter.from_json_schema_with_any_order(
            self.allocator,
            schema,
            any_whitespace,
            indent,
            separators,
            strict_mode,
            max_whitespace_cnt,
            any_order,
            if (diag != null) &schema_diag else null,
        ) catch |err| {
            self.allocator.free(key);
            if (err != error.OutOfMemory) {
                if (diag) |d| d.* = .{ .Schema = schema_diag };
            }
            return err;
        };
        defer grammar.deinit();
        const compiled = self.optimize(grammar, diag) catch |err| {
            self.allocator.free(key);
            return err;
        };
        return self.compile_and_store(key, compiled);
    }

    /// Gets the compiled grammar for a regex.
    pub fn compile_regex(
        self: *GrammarCompiler,
        regex: []const u8,
        diag: ?*CompileErrorInfo,
    ) CompileError!CompiledGrammar {
        const key = try std.fmt.allocPrint(self.allocator, "regex:{s}", .{regex});
        if (self.try_cache_get(key)) |hit| {
            self.allocator.free(key);
            return hit;
        }
        var regex_diag: converter.RegexErrorInfo = undefined;
        const grammar = converter.from_regex(
            self.allocator,
            regex,
            if (diag != null) &regex_diag else null,
        ) catch |err| {
            self.allocator.free(key);
            if (err != error.OutOfMemory) {
                if (diag) |d| d.* = .{ .Regex = regex_diag };
            }
            return err;
        };
        defer grammar.deinit();
        const compiled = self.optimize(grammar, diag) catch |err| {
            self.allocator.free(key);
            return err;
        };
        return self.compile_and_store(key, compiled);
    }

    /// Gets the compiled grammar for a Lark grammar string. The root rule must be named `start`.
    pub fn compile_lark(
        self: *GrammarCompiler,
        lark: []const u8,
        named_grammars: []const converter.NamedGrammar,
        diag: ?*CompileErrorInfo,
    ) CompileError!CompiledGrammar {
        const NamedKey = struct {
            name: []const u8,
            is_lark_source: bool,
            content: []const u8,
            owned_content: ?[]u8,
            root_rule_name: []const u8,
        };
        var named_keys = try std.ArrayList(NamedKey).initCapacity(self.allocator, named_grammars.len);
        defer {
            for (named_keys.items) |nk| {
                if (nk.owned_content) |oc| self.allocator.free(oc);
            }
            named_keys.deinit(self.allocator);
        }
        for (named_grammars) |ng| {
            switch (ng) {
                .grammar => |entry| {
                    const printed = try grammar_mod.printer.to_string_ebnf(entry.grammar, self.allocator);
                    named_keys.appendAssumeCapacity(.{
                        .name = entry.name,
                        .is_lark_source = false,
                        .content = printed,
                        .owned_content = printed,
                        .root_rule_name = entry.grammar.root_rule().name,
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
        std.mem.sort(NamedKey, named_keys.items, {}, struct {
            fn less(_: void, a: NamedKey, b: NamedKey) bool {
                const no = std.mem.order(u8, a.name, b.name);
                if (no != .eq) return no == .lt;
                if (a.is_lark_source != b.is_lark_source) return !a.is_lark_source and b.is_lark_source;
                const co = std.mem.order(u8, a.content, b.content);
                if (co != .eq) return co == .lt;
                return std.mem.order(u8, a.root_rule_name, b.root_rule_name) == .lt;
            }
        }.less);

        var key_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer key_writer.deinit();
        {
            const w = &key_writer.writer;
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
        }
        const key = try self.allocator.dupe(u8, key_writer.written());
        if (self.try_cache_get(key)) |hit| {
            self.allocator.free(key);
            return hit;
        }
        var lark_diag: ?converter.LarkErrorInfo = null;
        const grammar = converter.from_lark(
            self.allocator,
            lark,
            &self.tokenizer_info,
            named_grammars,
            if (diag != null) &lark_diag else null,
        ) catch |err| {
            self.allocator.free(key);
            if (lark_diag) |ld| {
                if (diag) |d| {
                    d.* = .{ .Lark = ld };
                } else {
                    var tmp = ld;
                    tmp.deinit(self.allocator);
                }
            }
            return err;
        };
        defer grammar.deinit();
        const compiled = self.optimize(grammar, diag) catch |err| {
            self.allocator.free(key);
            return err;
        };
        return self.compile_and_store(key, compiled);
    }

    /// Gets the compiled grammar for a structural tag.
    pub fn compile_structural_tag(
        self: *GrammarCompiler,
        structural_tag_json: []const u8,
        diag: ?*CompileErrorInfo,
    ) CompileError!CompiledGrammar {
        const key = try std.fmt.allocPrint(self.allocator, "stag:{s}", .{structural_tag_json});
        if (self.try_cache_get(key)) |hit| {
            self.allocator.free(key);
            return hit;
        }
        var st_diag: ?converter.StructuralTagErrorInfo = null;
        const grammar = converter.from_structural_tag_with_tokenizer(
            self.allocator,
            structural_tag_json,
            &self.tokenizer_info,
            if (diag != null) &st_diag else null,
        ) catch |err| {
            self.allocator.free(key);
            if (st_diag) |sd| {
                if (diag) |d| {
                    d.* = .{ .StructuralTag = sd };
                } else {
                    var tmp = sd;
                    tmp.deinit(self.allocator);
                }
            }
            return err;
        };
        defer grammar.deinit();
        const compiled = self.optimize(grammar, diag) catch |err| {
            self.allocator.free(key);
            return err;
        };
        return self.compile_and_store(key, compiled);
    }

    /// Clears the internal cache of compiled grammars.
    pub fn clear_cache(self: *GrammarCompiler) void {
        self.lock_cache();
        defer self.unlock_cache();
        self.cache.clear();
    }

    /// Returns the approximate memory usage of the compiler cache in bytes.
    pub fn get_cache_size_bytes(self: *GrammarCompiler) i64 {
        self.lock_cache();
        defer self.unlock_cache();
        return self.cache.size_bytes;
    }

    /// Returns the approximate memory usage limit of the compiler cache in bytes (`-1` = unlimited).
    pub fn cache_limit_bytes(self: *const GrammarCompiler) i64 {
        return self.max_memory_bytes;
    }

    /// The configured compile parallelism for the adaptive token-mask cache.
    pub fn get_max_threads(self: *const GrammarCompiler) i32 {
        return self.max_threads;
    }

    // --- Idiomatic Zig 0.17 options & methods ---

    pub const InitOptions = struct {
        max_threads: i32 = 8,
        cache_enabled: bool = true,
        max_memory_bytes: ?usize = null,
    };

    pub const JsonSchemaOptions = struct {
        any_whitespace: bool = true,
        indent: ?i32 = null,
        separators: ?converter.Separators = null,
        strict_mode: bool = true,
        max_whitespace_cnt: ?i32 = null,
        any_order: bool = false,
        diag: ?*CompileErrorInfo = null,
    };

    pub fn init(
        allocator: Allocator,
        tokenizer: *const TokenizerInfo,
        options: InitOptions,
    ) Allocator.Error!*GrammarCompiler {
        const limit: i64 = if (options.max_memory_bytes) |bytes| @intCast(bytes) else UNLIMITED;
        return new(allocator, tokenizer, options.max_threads, options.cache_enabled, limit);
    }

    pub fn compileGrammar(self: *GrammarCompiler, grammar: *const Grammar) CompileError!CompiledGrammar {
        return self.compile_grammar(grammar, null);
    }

    pub fn compileEbnf(self: *GrammarCompiler, ebnf_str: []const u8, root_rule_name: []const u8) CompileError!CompiledGrammar {
        return self.compile_grammar_ebnf(ebnf_str, root_rule_name, null);
    }

    pub fn compileBuiltinJson(self: *GrammarCompiler) Allocator.Error!CompiledGrammar {
        return self.compile_builtin_json_grammar();
    }

    pub fn compileJsonSchema(
        self: *GrammarCompiler,
        schema: []const u8,
        options: JsonSchemaOptions,
    ) CompileError!CompiledGrammar {
        return self.compile_json_schema_with_any_order(
            schema,
            options.any_whitespace,
            options.indent,
            options.separators,
            options.strict_mode,
            options.max_whitespace_cnt,
            options.any_order,
            options.diag,
        );
    }

    pub fn compileRegex(self: *GrammarCompiler, regex_str: []const u8) CompileError!CompiledGrammar {
        return self.compile_regex(regex_str, null);
    }

    pub fn compileLark(self: *GrammarCompiler, lark_str: []const u8, named_grammars: []const converter.NamedGrammar) CompileError!CompiledGrammar {
        return self.compile_lark(lark_str, named_grammars, null);
    }

    pub fn compileStructuralTag(self: *GrammarCompiler, structural_tag_json: []const u8) CompileError!CompiledGrammar {
        return self.compile_structural_tag(structural_tag_json, null);
    }

    pub const clearCache = clear_cache;
    pub const getCacheSizeBytes = get_cache_size_bytes;
    pub const cacheLimitBytes = cache_limit_bytes;

    fn try_cache_get(self: *GrammarCompiler, key: []const u8) ?CompiledGrammar {
        if (!self.cache_enabled) return null;
        self.lock_cache();
        defer self.unlock_cache();
        return self.cache.get(key);
    }

    fn compile_and_store(
        self: *GrammarCompiler,
        key_owned: []u8,
        compiled_in: CompiledGrammar,
    ) Allocator.Error!CompiledGrammar {
        if (!self.cache_enabled) {
            self.allocator.free(key_owned);
            return compiled_in;
        }
        var compiled = compiled_in;
        errdefer compiled.deinit();
        const result_handle = compiled.clone();
        errdefer {
            var r = result_handle;
            r.deinit();
        }
        self.lock_cache();
        defer self.unlock_cache();
        try self.cache.insert(key_owned, compiled, self.grammar_cache_limit_bytes);
        return result_handle;
    }

    /// Optimizes `grammar` (if needed), builds the adaptive token-mask cache, and bundles
    /// the result with the tokenizer.
    fn optimize(
        self: *const GrammarCompiler,
        grammar: *const Grammar,
        diag: ?*CompileErrorInfo,
    ) CompileError!CompiledGrammar {
        var functor_diag: functor.FunctorErrorInfo = undefined;
        const optimized = if (grammar.is_optimized())
            try grammar.clone(self.allocator)
        else
            functor.grammar_optimizer(self.allocator, grammar, if (diag != null) &functor_diag else null) catch |err| {
                if (err != error.OutOfMemory and diag != null) {
                    diag.?.* = .{ .Functor = functor_diag };
                }
                return err;
            };
        errdefer optimized.deinit();

        try self.check_token_ids_in_vocab(optimized, diag);
        if (self.rule_level_cache != null) {
            try functor.grammar_fsm_hasher(self.allocator, optimized);
        }
        return CompiledGrammar.build(
            self.allocator,
            optimized,
            &self.tokenizer_info,
            self.max_threads,
            self.rule_level_cache,
        );
    }

    /// Checks that every token id written in `Token(...)`, `ExcludeToken(...)` and
    /// `TokenTagDispatch` exists in the vocabulary.
    fn check_token_ids_in_vocab(
        self: *const GrammarCompiler,
        grammar: *const Grammar,
        diag: ?*CompileErrorInfo,
    ) CompileError!void {
        const vocab_size = self.tokenizer_info.vocab_size;
        const fsm = grammar.complete_fsm;
        var state: i32 = 0;
        while (state < fsm.num_states()) : (state += 1) {
            for (fsm.state_edges(state)) |edge| {
                if (!edge.is_token() and !edge.is_exclude_token()) continue;
                // Token and exclude-token edges share the `[count, token_id...]` aux layout.
                for (fsm.token_edge_info(edge.aux_index()).token_ids()) |token_id| {
                    if (token_id < 0 or token_id >= vocab_size) {
                        if (diag) |d| {
                            d.* = .{ .TokenIdOutOfRange = .{
                                .token_id = token_id,
                                .vocab_size = vocab_size,
                            } };
                        }
                        return error.TokenIdOutOfRange;
                    }
                }
            }
        }
    }
};
