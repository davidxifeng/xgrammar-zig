# xgrammar-zig Public API Reference

All symbols below are exported directly at the root of `@import("xgrammar")` (`src/xgrammar.zig`).
Internal implementation packages live under `xgrammar.internal` (`config`, `support`, `tokenizer`, `fsm`, `grammar`, `parser`, `functor`, `converter`, `compiler`, `matcher`) and are not needed for normal library use.

## Versioning & Diagnostics

- `pub const version = "0.2.8"`
- `pub const serialization_version = "v16"`
- `pub fn getSerializationVersion() []const u8` — returns `"v16"`.

### `Diagnostic`

Structured error reporter passed optionally via `.diag: ?*Diagnostic` or `diag: ?*Diagnostic`.

- `pub const Kind = enum { none, static_msg, message, version_mismatch, ebnf_lexer, ebnf_parser, regex, grammar_expr_type, unknown_vocab_type, grammar_normalization, fsm_build, invalid_repetition_range, lazy_rule_body_not_choices, lazy_rule_element_not_terminal, recursion_depth_exceeded, lark_message, lark_located, structural_tag_invalid_json, structural_tag_invalid_schema, structural_tag_invalid, invalid_fsm_node_type, invalid_fsm_edge_range, matcher_terminated, matcher_empty_override_stop_tokens }`: Default `.none`.
- `pub const Location = struct { line: usize = 0, column: usize = 0, offset: usize = 0 }`.
- Initialize with `var diag: Diagnostic = .{};` (zero-allocated `.empty`).
- `pub fn deinit(self: *Diagnostic, allocator: Allocator) void` — frees any owned heap message and resets to `.empty`. Safe to omit only when no failing call with `&diag` ever allocated (`Diagnostic` automatically frees prior buffers before overwriting on subsequent failures).
- `pub fn clear(self: *Diagnostic, allocator: Allocator) void` — alias to reset cleanly between unrelated calls.
- `pub fn format(self: Diagnostic, writer: *std.Io.Writer) std.Io.Writer.Error!void` — use `{f}` in Zig 0.17 `std.fmt` / `std.debug.print`.
- `pub fn formatAlloc(self: Diagnostic, allocator: Allocator) Allocator.Error![]u8` — caller owns slice.

---

## Tokenizer & Metadata

### Types & Errors

- `pub const VocabType = enum(i32) { raw = 0, byte_fallback = 1, byte_level = 2 }`:
  - `pub fn fromInt(raw: i32) error{UnknownVocabType}!VocabType`
- `pub const HfMetadata = struct { vocab_type: VocabType, add_prefix_space: bool }`
- `pub const TokenizerError = error{ VocabSizeTooSmall, InvalidMetadata, OutOfMemory }`
- `pub const DeserializeError = error{ InvalidJson, Version, Format }`

### Top-Level Tokenizer Functions

- `pub fn detectMetadataFromHf(allocator: Allocator, backend_str: []const u8) error{ InvalidJson, RootNotObject, OutOfMemory }!HfMetadata`
  Parses Hugging Face `tokenizer.json` contents and returns `HfMetadata` struct.
- `pub fn decodeToken(allocator: Allocator, token: []const u8, vocab: VocabType) Allocator.Error![]u8`
- `pub fn decodeTokenBytes(allocator: Allocator, token: []const u8, vocab: VocabType) Allocator.Error![]u8`
  Decodes an encoded token string/bytes according to `VocabType` (`.byte_fallback` handles `<0xNN>` and `▁` -> space; `.byte_level` inverts GPT-2 byte-to-unicode mapping; `.raw` duplicates verbatim). Caller owns returned slice.

### `TokenizerInfo`

- `pub const InitOptions = struct`:
  ```zig
  pub const InitOptions = struct {
      vocab_type: VocabType = .raw,
      vocab_size: ?usize = null,        // defaults to encoded_vocab.len; errors if < encoded_vocab.len
      stop_token_ids: ?[]const u32 = null,
      add_prefix_space: bool = false,
      diag: ?*Diagnostic = null,
  };
  ```
- **Constructors & Lifetime**:
  - `pub fn init(allocator: Allocator, encoded_vocab: []const []const u8, options: InitOptions) TokenizerError!TokenizerInfo`
  - `pub fn fromVocabAndMetadata(allocator: Allocator, encoded_vocab: []const []const u8, metadata: []const u8, diag: ?*Diagnostic) TokenizerError!TokenizerInfo`
  - `pub fn detectMetadataFromHf(allocator: Allocator, backend_str: []const u8) DetectError![]u8` — returns JSON metadata string compatible with `fromVocabAndMetadata`. Caller owns slice.
  - `pub fn retain(self: *const TokenizerInfo) TokenizerInfo` — increments atomic refcount and shares storage.
  - `pub fn dupe(self: *const TokenizerInfo, allocator: Allocator) Allocator.Error!TokenizerInfo` — independent deep copy.
  - `pub fn sharesStorage(self: *const TokenizerInfo, other: *const TokenizerInfo) bool`
  - `pub fn deinit(self: *TokenizerInfo) void`
- **Accessors**:
  - `vocabSize(self: *const TokenizerInfo) usize`
  - `vocabType(self: *const TokenizerInfo) VocabType`
  - `addPrefixSpace(self: *const TokenizerInfo) bool`
  - `decodedVocab(self: *const TokenizerInfo) []const []const u8`
  - `sortedDecodedVocab(self: *const TokenizerInfo) []const SortedDecodedToken` (`{ id: i32, token: []const u8 }`)
  - `trieSubtreeNodesRange(self: *const TokenizerInfo) []const i32`
  - `stopTokenIds(self: *const TokenizerInfo) []const u32`
  - `specialTokenIds(self: *const TokenizerInfo) []const u32`
  - `tokenIdToSortedVocabIndex(self: *const TokenizerInfo) []const i32`
  - `tokenCharCounts(self: *const TokenizerInfo) []const i32`
  - `maxTokenChars(self: *const TokenizerInfo) i32`
- **Metadata & JSON Serialization (`"v16"`)**:
  - `writeMetadataJson(self: *const TokenizerInfo, jw: *std.json.Stringify) std.json.Stringify.Error!void`
  - `dumpMetadata(self: *const TokenizerInfo, allocator: Allocator) Allocator.Error![]u8`
  - `checkMetadataMatch(self: *const TokenizerInfo, metadata: std.json.Value, diag: ?*Diagnostic) DeserializeError!void`
  - `writeJson(self: *const TokenizerInfo, jw: *std.json.Stringify) std.json.Stringify.Error!void`
  - `serializeJson(self: *const TokenizerInfo, allocator: Allocator) Allocator.Error![]u8`
  - `deserializeJson(allocator: Allocator, json_str: []const u8, diag: ?*Diagnostic) (DeserializeError || Allocator.Error)!TokenizerInfo`

---

## `Grammar` & External Converters

### Option Structs & Error Sets

- `pub const JsonFormat = enum { json, qwen_xml, minimax_xml, deepseek_xml, glm_xml, cohere_xml, kimi_k3_xml, minimax_m3_xml, deepseek_v4_1_xml }`
  - `pub fn fromName(name: []const u8) ?JsonFormat`
  - `pub fn isDeepseek(self: JsonFormat) bool`
- `pub const Separators = struct { item: []const u8, colon: []const u8 }`
- `pub const JsonSchemaOptions = struct`:
  ```zig
  pub const JsonSchemaOptions = struct {
      any_whitespace: bool = true,
      indent: ?i32 = null,
      separators: ?Separators = null,
      strict_mode: bool = true,
      max_whitespace_cnt: ?i32 = null,
      any_order: bool = false,
      json_format: JsonFormat = .json,
      excludes: []const []const u8 = &.{},
      print_converted_ebnf: bool = false,
      diag: ?*Diagnostic = null,
  };
  ```
- `pub const FloatRangeOptions = struct { exclusive_start: bool = false, exclusive_end: bool = false }`
- `pub const StructuralTagItem = struct { begin: []const u8, schema: []const u8, end: []const u8 }`
- `pub const NamedGrammar`:
  - `pub fn fromGrammar(grammar_name: []const u8, g: *const Grammar) NamedGrammar`
  - `pub fn fromLarkSource(grammar_name: []const u8, source: []const u8) NamedGrammar`
  - `pub fn name(self: *const NamedGrammar) []const u8`
- **Error sets**:
  - `SchemaError = error{ InvalidSchema, UnsatisfiableSchema, OutOfMemory }`
  - `RegexError = error{ Regex, OutOfMemory }`
  - `LarkError = error{ Lark, OutOfMemory }`
  - `StructuralTagError = error{ InvalidJson, InvalidJsonSchema, InvalidStructuralTag, OutOfMemory }`
  - `DeserializeError` (re-exported for grammar/tokenizer deserialization: `error{ InvalidJson, Version, Format }`)

### `Grammar`

- `pub const EbnfOptions = struct { root_rule_name: []const u8 = "root", diag: ?*Diagnostic = null }`
- `pub const LarkOptions = struct { tokenizer_info: ?*const TokenizerInfo = null, named_grammars: []const NamedGrammar = &.{}, diag: ?*Diagnostic = null }`
- **Constructors & Combinators** (caller must call `g.deinit()`):
  - `Grammar.fromEbnf(allocator: Allocator, ebnf_str: []const u8, options: EbnfOptions) !Grammar`
  - `Grammar.builtinJson(allocator: Allocator) Allocator.Error!Grammar`
  - `Grammar.fromJsonSchema(allocator: Allocator, schema: []const u8, options: JsonSchemaOptions) !Grammar`
  - `Grammar.fromRegex(allocator: Allocator, regex_str: []const u8, diag: ?*Diagnostic) !Grammar`
  - `Grammar.fromLark(allocator: Allocator, lark_str: []const u8, options: LarkOptions) !Grammar`
  - `Grammar.fromStructuralTag(allocator: Allocator, json: []const u8, diag: ?*Diagnostic) !Grammar`
  - `Grammar.fromStructuralTagWithTokenizer(allocator: Allocator, json: []const u8, tokenizer_info: *const TokenizerInfo, diag: ?*Diagnostic) !Grammar`
  - `Grammar.unionOf(allocator: Allocator, grammars: []const Grammar) Allocator.Error!Grammar`
  - `Grammar.concatOf(allocator: Allocator, grammars: []const Grammar) Allocator.Error!Grammar`
- **Methods**:
  - `deinit(self: *Grammar) void`
  - `dupe(self: *const Grammar, allocator: Allocator) Allocator.Error!Grammar`
  - `eql(self: *const Grammar, other: *const Grammar) bool`
  - `numRules(self: *const Grammar) usize`
  - `numExprs(self: *const Grammar) usize`
  - `rulesSlice(self: *const Grammar) []const Rule`
  - `rootRuleId(self: *const Grammar) i32`
  - `rootRule(self: *const Grammar) *const Rule`
  - `rule(self: *const Grammar, id: i32) *const Rule`
  - `expr(self: *const Grammar, id: i32) Expr`
  - `isOptimized(self: *const Grammar) bool`
  - `toStringEbnf(self: *const Grammar, allocator: Allocator) Allocator.Error![]u8` — caller owns slice.
  - `format(self: Grammar, writer: *std.Io.Writer) std.Io.Writer.Error!void` — supports `{f}`.
  - `serializeJson(self: *const Grammar, allocator: Allocator) Allocator.Error![]u8` — caller owns slice.
  - `writeJson(self: *const Grammar, jw: *std.json.Stringify) std.json.Stringify.Error!void`
  - `writeJsonEmbedded(self: *const Grammar, jw: *std.json.Stringify) std.json.Stringify.Error!void`
  - `Grammar.deserializeJson(backing: Allocator, json_str: []const u8, diag: ?*Diagnostic) (DeserializeError || Allocator.Error)!Grammar`

### String Conversion Utilities (Caller Owns Returned `[]u8`)

- `pub fn jsonSchemaToEbnf(gpa: Allocator, schema: []const u8, options: JsonSchemaOptions) SchemaError![]u8`
- `pub fn regexToEbnf(gpa: Allocator, regex: []const u8, with_rule_name: bool, diag: ?*Diagnostic) RegexError![]u8`
- `pub fn generateRangeRegex(allocator: Allocator, start: ?i64, end: ?i64) Allocator.Error![]u8`
- `pub fn generateFloatRangeRegex(allocator: Allocator, start: ?f64, end: ?f64) Allocator.Error![]u8`
- `pub fn generateFloatRangeRegexWithOptions(allocator: Allocator, start: ?f64, end: ?f64, options: FloatRangeOptions) Allocator.Error![]u8`

---

## Compiler & Artifacts

### `CompileError`

`Allocator.Error || Compact2dArrayError || EbnfError || SchemaError || RegexError || StructuralTagError || LarkError || FunctorError || error{TokenIdOutOfRange}`

### `GrammarCompiler`

- `pub const Options = struct`:
  ```zig
  pub const Options = struct {
      max_threads: ?u32 = null,        // null or 0 => CPU count
      cache_enabled: bool = true,
      max_memory_bytes: ?usize = null, // LRU cache memory ceiling in bytes
  };
  ```
- `pub const EbnfOptions = struct { root_rule_name: []const u8 = "root", diag: ?*Diagnostic = null }`
- `pub const JsonSchemaOptions = xgrammar.JsonSchemaOptions`
- `pub const LarkOptions = struct { named_grammars: []const NamedGrammar = &.{}, diag: ?*Diagnostic = null }`
- **Lifecycle**:
  - `init(allocator: Allocator, tokenizer: *const TokenizerInfo, options: Options) Allocator.Error!GrammarCompiler`
  - `deinit(self: *GrammarCompiler) void`
- **Compilation Methods** (caller must `compiled.deinit()`):
  - `compileGrammar(self: *const GrammarCompiler, grammar: *const Grammar, diag: ?*Diagnostic) CompileError!CompiledGrammar`
  - `compileEbnf(self: *const GrammarCompiler, ebnf: []const u8, options: EbnfOptions) CompileError!CompiledGrammar`
  - `compileBuiltinJson(self: *const GrammarCompiler, diag: ?*Diagnostic) Allocator.Error!CompiledGrammar`
  - `compileJsonSchema(self: *const GrammarCompiler, schema: []const u8, options: JsonSchemaOptions) CompileError!CompiledGrammar`
  - `compileRegex(self: *const GrammarCompiler, regex: []const u8, diag: ?*Diagnostic) CompileError!CompiledGrammar`
  - `compileLark(self: *const GrammarCompiler, lark: []const u8, options: LarkOptions) CompileError!CompiledGrammar`
  - `compileStructuralTag(self: *const GrammarCompiler, json: []const u8, diag: ?*Diagnostic) CompileError!CompiledGrammar`
- **Cache Inspection & Control**:
  - `clearCache(self: *const GrammarCompiler) void`
  - `cacheSizeBytes(self: *const GrammarCompiler) usize`
  - `cacheLimitBytes(self: *const GrammarCompiler) ?usize`
  - `maxThreads(self: *const GrammarCompiler) ?u32`
  - `tokenizerInfo(self: *const GrammarCompiler) *const TokenizerInfo`

### `CompiledGrammar`

- `retain(self: *const CompiledGrammar) CompiledGrammar`
- `deinit(self: *CompiledGrammar) void`
- `sharesStorage(self: *const CompiledGrammar, other: *const CompiledGrammar) bool`
- `grammar(self: *const CompiledGrammar) *const Grammar`
- `tokenizerInfo(self: *const CompiledGrammar) *const TokenizerInfo`
- `adaptiveTokenMaskCache(self: *const CompiledGrammar) *const AdaptiveTokenMaskCache`
- `memorySizeBytes(self: *const CompiledGrammar) usize`
- `writeJson(self: *const CompiledGrammar, jw: *std.json.Stringify) std.json.Stringify.Error!void`
- `serializeJson(self: *const CompiledGrammar, allocator: Allocator) Allocator.Error![]u8`
- `CompiledGrammar.deserializeJson(allocator: Allocator, json_str: []const u8, tokenizer: *const TokenizerInfo, diag: ?*Diagnostic) DeserializeErrorAll!CompiledGrammar`
- `CompiledGrammar.deserializeJsonValue(allocator: Allocator, value: std.json.Value, tokenizer: *const TokenizerInfo, diag: ?*Diagnostic) DeserializeErrorAll!CompiledGrammar`

---

## Matchers, Captures & Token Bitmasks

### `MatcherError`

`Allocator.Error || error{ Terminated, EmptyOverrideStopTokens, StopTokenOutOfRange, InvalidDefaultTemperature, RollbackTooFar, InvalidArgument }`

### `Capture`

- `name: []const u8`
- `bytes: []const u8`
- `pub fn freeSlice(allocator: Allocator, captures: []Capture) void`

### `GrammarMatcher`

- `pub const Options = struct`:
  ```zig
  pub const Options = struct {
      override_stop_tokens: ?[]const u32 = null,
      terminate_without_stop_token: bool = false,
      default_temperature: ?f32 = null,
      diag: ?*Diagnostic = null,
  };
  ```
- **Lifecycle**:
  - `init(allocator: Allocator, compiled: *const CompiledGrammar, options: Options) MatcherError!GrammarMatcher`
  - `deinit(self: *GrammarMatcher) void`
  - `clone(self: *const GrammarMatcher, allocator: Allocator) Allocator.Error!GrammarMatcher`
  - `fork(self: *const GrammarMatcher) Allocator.Error!GrammarMatcher`
  - `reset(self: *GrammarMatcher) Allocator.Error!void`
- **State Inspection**:
  - `grammar(self: *const GrammarMatcher) *const Grammar`
  - `tokenizerInfo(self: *const GrammarMatcher) *const TokenizerInfo`
  - `stopTokenIds(self: *const GrammarMatcher) []const u32`
  - `maxRollbackTokens(_: *const GrammarMatcher) i32`
  - `isCompleted(self: *const GrammarMatcher) bool`
  - `isStopTokenAccepted(self: *const GrammarMatcher) bool`
  - `isTerminated(self: *const GrammarMatcher) bool`
  - `temperature(self: *const GrammarMatcher) ?f32` — returns active rule temperature override (conflict-checked) or `default_temperature`.
  - `getCaptures(self: *const GrammarMatcher, allocator: Allocator, deduplicate: bool) Allocator.Error![]Capture`
  - `debugPrintInternalState(self: *const GrammarMatcher, writer: *std.Io.Writer) std.Io.Writer.Error!void`
- **Bitmask Filling** (returns `true` if masking is needed, `false` if every token in `0..vocabSize()` is allowed):
  - `fillNextTokenBitmask(self: *GrammarMatcher, bitmask: *TokenBitmask, row_index: usize, diag: ?*Diagnostic) MatcherError!bool`
  - `fillNextTokenBitmaskView(self: *GrammarMatcher, view: TokenBitmaskView, row_index: usize, diag: ?*Diagnostic) MatcherError!bool`
  - `fillNextTokenBitmaskRaw(self: *GrammarMatcher, bitmask: []i32, shape: []const i64, index: usize, diag: ?*Diagnostic) MatcherError!bool`
- **Advancing & Backtracking**:
  - `acceptToken(self: *GrammarMatcher, token_id: u32, diag: ?*Diagnostic) MatcherError!bool`
  - `acceptString(self: *GrammarMatcher, bytes: []const u8, diag: ?*Diagnostic) MatcherError!bool`
  - `acceptStopToken(self: *GrammarMatcher) Allocator.Error!bool`
  - `findJumpForwardString(self: *GrammarMatcher, allocator: Allocator, diag: ?*Diagnostic) MatcherError![]u8` (UTF-8 aligned deterministic suffix; does not mutate matcher state)
  - `rollback(self: *GrammarMatcher, num_tokens: usize, diag: ?*Diagnostic) MatcherError!void`
- **Speculative Draft Tree Verification**:
  - `traverseDraftTree(self: *GrammarMatcher, retrieve_next_token: []const i32, retrieve_next_sibling: []const i32, draft_tokens: []const i32, bitmask: *TokenBitmask, time_threshold: f64, temperatures: ?[]f32, diag: ?*Diagnostic) MatcherError!bool`
  - `traverseDraftTreeView(self: *GrammarMatcher, retrieve_next_token: []const i32, retrieve_next_sibling: []const i32, draft_tokens: []const i32, view: TokenBitmaskView, time_threshold: f64, temperatures: ?[]f32, diag: ?*Diagnostic) MatcherError!bool`
  - `traverseDraftTreeRaw(self: *GrammarMatcher, retrieve_next_token: []const i32, retrieve_next_sibling: []const i32, draft_tokens: []const i32, token_bitmask: []i32, time_threshold: f64, temperatures: ?[]f32, diag: ?*Diagnostic) MatcherError!bool`

### `BatchMatcher`

- `pub const Options = struct { max_threads: ?u32 = null };`
- `init(allocator: Allocator, options: Options) BatchMatcher` / `deinit(self: *BatchMatcher) void`
- `maxThreads(self: *const BatchMatcher) ?u32` / `effectiveThreads(self: *const BatchMatcher) usize`
- `fillNextTokenBitmask(self: *const BatchMatcher, matchers: []GrammarMatcher, bitmask: *TokenBitmask, indices: ?[]const usize, diag: ?*Diagnostic) MatcherError!void`
- `fillNextTokenBitmaskView(self: *const BatchMatcher, matchers: []GrammarMatcher, view: TokenBitmaskView, indices: ?[]const usize, diag: ?*Diagnostic) MatcherError!void`
- `fillNextTokenBitmaskRaw(self: *const BatchMatcher, matchers: []GrammarMatcher, bitmask: []i32, shape: []const i64, indices: ?[]const usize, diag: ?*Diagnostic) MatcherError!void`
- `acceptTokenBatch(self: *const BatchMatcher, allocator: Allocator, matchers: []GrammarMatcher, token_ids: []const u32, diag: ?*Diagnostic) MatcherError![]bool`
- `acceptTokenBatchInto(self: *const BatchMatcher, out: []bool, matchers: []GrammarMatcher, token_ids: []const u32, diag: ?*Diagnostic) MatcherError!void`
- `acceptStringBatch(self: *const BatchMatcher, allocator: Allocator, matchers: []GrammarMatcher, inputs: []const []const u8, diag: ?*Diagnostic) MatcherError![]bool`
- `acceptStringBatchInto(self: *const BatchMatcher, out: []bool, matchers: []GrammarMatcher, inputs: []const []const u8, diag: ?*Diagnostic) MatcherError!void`
- `rollbackBatch(self: *const BatchMatcher, matchers: []GrammarMatcher, num_tokens: []const usize, diag: ?*Diagnostic) MatcherError!void`
- `fillTemperatureBatch(self: *const BatchMatcher, matchers: []const GrammarMatcher, temperatures: []f32, indices: ?[]const usize, diag: ?*Diagnostic) MatcherError!void`
- `applyBitmaskInplaceBatch(self: *const BatchMatcher, bitmask: *const TokenBitmask, logits: []f32, indices: ?[]const usize, diag: ?*Diagnostic) MatcherError!void`
- `applyBitmaskViewInplaceBatch(self: *const BatchMatcher, view: TokenBitmaskConstView, logits: []f32, indices: ?[]const usize, diag: ?*Diagnostic) MatcherError!void`

### `TokenBitmask`, `TokenBitmaskView`, `TokenBitmaskConstView` & Helpers

Bit `t % 32` (LSB-first) of word `t / 32` is `1` when token `t` is allowed and `0` when rejected. Words initialize to `-1` (all allowed).

- `TokenBitmask`:
  - `init(allocator: Allocator, batch_size: usize, vocab_size: usize) Allocator.Error!TokenBitmask`
  - `initSingle(allocator: Allocator, vocab_size: usize) Allocator.Error!TokenBitmask`
  - `deinit(self: *TokenBitmask) void`
  - `view(self: *TokenBitmask) TokenBitmaskView` / `constView(self: *const TokenBitmask) TokenBitmaskConstView`
  - `shape()`, `row(row_idx)`, `constRow(row_idx)`, `reset()`, `resetRow(row_idx)`
  - `isAllowed(token_id)`, `isAllowedInRow(row_idx, token_id)`, `setAllowed(token_id, allowed)`, `setAllowedInRow(row_idx, token_id, allowed)`
  - `countAllowed()`, `countAllowedInRow(row_idx)`
  - `singleAllowedToken()`, `singleAllowedTokenInRow(row_idx)` (`?u32`)
  - `maskedTokens(allocator, row_idx) Allocator.Error![]u32` — returns rejected token IDs (caller owns slice).
  - `applyToLogits(logits: []f32)`, `applyRowToLogits(row_idx, logits: []f32)`, `applyBatchToLogits(logits: []f32, indices: ?[]const usize)`
- `TokenBitmaskView` (mutable non-owning view) & `TokenBitmaskConstView` (read-only non-owning view):
  - `init(words, batch_size, vocab_size) MatcherError!Self` (returns `error.InvalidArgument` if `words.len < batch_size * bitmaskSize(vocab_size)`).
  - Mirrors `shape`, `constRow`, `row` (mutable only), `rowRange`, `rowRangeDiag`, `reset`/`resetRow` (mutable only), `isAllowed*`, `setAllowed*` (mutable only), `countAllowed*`, `singleAllowedToken*`, `maskedTokens`, `apply*ToLogits`.
- **Standalone Helpers**:
  - `pub const BitmaskDlType = struct { code: u8, bits: u8, lanes: u16 }`
  - `pub fn dlType() BitmaskDlType` — returns `{ .code = 0, .bits = 32, .lanes = 1 }` (`DLDataType` int32).
  - `pub fn bitmaskSize(vocab_size: usize) usize` — words per row: `ceil(vocab_size / 32)`.
  - `pub fn resetBitmaskWords(words: []i32) void` — `@memset(words, -1)`.
  - `pub fn getMaskedTokensFromBitmask(allocator: Allocator, bitmask: []const i32, vocab_size: usize, index: usize) Allocator.Error![]u32`
  - `pub fn isSingleTokenBitmask(bitmask: []const i32, vocab_size: usize, index: usize) ?u32`
  - `pub fn applyTokenBitmaskInplaceCpu(logits: []f32, bitmask: []const i32, vocab_size: usize) void`
  - `pub fn applyTokenBitmaskInplaceCpuBatch(logits: []f32, bitmask: []const i32, vocab_size: usize, batch_size: usize, indices: ?[]const usize) void`

---

## Utilities & Testing Helpers

- `pub fn LruCache(comptime K: type, comptime V: type, comptime Context: type) type`
  - `pub const Entry = struct { key: K, value: V };`
  - `init()`, `deinit(allocator)`, `clearRetainingCapacity()`, `count()`, `contains(key)`, `getPtr(key)`, `getPtrNoTouch(key)`, `put(allocator, key, value) -> !?Entry` (returns displaced previous entry if overwritten so caller can free owned resources), `popLru() -> ?Entry`, `remove(key) -> ?Entry`, `valueIterator()`.
- `pub fn AutoLruCache(comptime K: type, comptime V: type) type`
- `pub const RecursionError = error{ InvalidMax, DepthExceeded }`
- `pub fn getMaxRecursionDepth() u32` / `pub fn setMaxRecursionDepth(max_depth: u32) RecursionError!void` / `pub fn resetRecursionDepth() void`
- `pub const testing`:
  - `pub const TestingError = Allocator.Error || error{ NoPerRuleFsms, RuleIdOutOfRange, RuleHasNoFsm }`
  - `printTokenByIds(allocator, tokenizer_info, token_ids, max_print_num) Allocator.Error![]u8`
  - `printGrammarFsms(allocator, grammar) TestingError![]u8`
  - `isRuleFsmAcceptString(allocator, grammar, rule_id, input_str) TestingError!bool`
