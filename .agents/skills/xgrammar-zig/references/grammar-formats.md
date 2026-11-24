# Supported Grammar Input Formats

## 1. JSON Schema & XML Tool-Calling Formats

Pass schemas to `GrammarCompiler.compileJsonSchema`, `Grammar.fromJsonSchema`, or `jsonSchemaToEbnf`.

### Supported JSON Schema Features

- Boolean schemas: `true` (any JSON value), `false` (fails with `error.UnsatisfiableSchema`).
- Primitive types: `string`, `integer`, `number`, `boolean`, `null`, and `type: [...]` type arrays.
- Number/integer bounds: `minimum`, `maximum`, `exclusiveMinimum`, `exclusiveMaximum`.
- Strings: `pattern`, `format`, `minLength`, `maxLength`.
- Supported built-in string `format` values (14 total):
  `email`, `date`, `time`, `date-time`, `duration`, `ipv4`, `ipv6`, `hostname`, `uuid`, `uri`, `uri-reference`, `uri-template`, `json-pointer`, `relative-json-pointer`.
- Objects: `properties`, `required`, `additionalProperties` (`bool` or schema), `unevaluatedProperties`, `propertyNames`, `patternProperties`, `minProperties`, `maxProperties`.
- Arrays: `items`, `prefixItems`, `additionalItems`, `minItems`, `maxItems`.
- Composition & constants: `const`, `enum`, `anyOf`, `oneOf`, `allOf`, `$ref` (`#/...` JSON Pointers).

### `JsonSchemaOptions` & XML Tool Formats

```zig
.{
    .any_whitespace = true,         // allow flexible JSON whitespace unless false
    .indent = null,                 // pretty-print indentation width when specified
    .separators = null,             // null uses default (": " and ", " when no indent); set .{ .item = ",", .colon = ":" } for compact no-space JSON
    .strict_mode = true,            // false relaxes additionalProperties/items when omitted
    .max_whitespace_cnt = null,     // cap consecutive whitespace chars when non-null (> 0)
    .any_order = false,             // allow object keys in any permutation
    .json_format = .json,           // select JSON or XML tool-call wire syntax
    .excludes = &.{},               // substrings forbidden in string values & property keys
    .print_converted_ebnf = false,  // log intermediate EBNF at info scope
    .diag = null,
}
```

Supported `JsonFormat` values:
- `.json` — standard JSON
- `.qwen_xml` — `<parameter=name>...</parameter>`
- `.minimax_xml` — `<parameter name="name">...</parameter>`
- `.deepseek_xml` — `<｜DSML｜parameter name="name"...>...</｜DSML｜parameter>`
- `.deepseek_v4_1_xml` — `<｜DSML｜ parameter name="name"...>...</｜DSML｜ parameter>`
- `.glm_xml` — `<arg_key>name</arg_key><arg_value>...</arg_value>`
- `.cohere_xml` — `<cofl:value...>` parameter wrappers
- `.kimi_k3_xml` — `<|open|>argument key="name" type="..."<|sep|>...<|close|>argument<|sep|>`
- `.minimax_m3_xml` — `]<]minimax[>[<name>...`

**Constraints**:
- `.excludes` is **not supported** with `.cohere_xml` or `.minimax_m3_xml` (returns `error.InvalidSchema`).
- `.minimax_m3_xml` requires fixed object property names (cannot use `.strict_mode = false` on an unconstrained `"object"`).
- `max_whitespace_cnt` must be positive (`>= 1`) when non-null.

---

## 2. Regular Expressions & Numeric Ranges

Compiled with `GrammarCompiler.compileRegex` / `Grammar.fromRegex`, or inspected with `regexToEbnf`.

- Uses JavaScript-flavored regex syntax (`[a-z]`, `[^...]`, `(a|b)`, `(?:...)`, quantifiers `*`, `+`, `?`, `{m}`, `{m,}`, `{m,n}`, Unicode escapes, `.` matching codepoints).
- NUL (`\x00`) bytes are rejected with `error.Regex`.
- `diag` records 1-based character offset (or `0` when a downstream EBNF/FSM error occurs).

Range helpers generate anchored regex strings (caller owns `[]u8` slice):
- `generateRangeRegex(alloc, start: ?i64, end: ?i64)` — inclusive integer range; `null` leaves bound open.
- `generateFloatRangeRegex(alloc, start: ?f64, end: ?f64)` — inclusive float range.
- `generateFloatRangeRegexWithOptions(alloc, start, end, .{ .exclusive_start = true, .exclusive_end = false })`.

---

## 3. XGrammar EBNF

Compiled with `GrammarCompiler.compileEbnf(src, .{ .root_rule_name = "root", .diag = ... })` or `Grammar.fromEbnf`.

### Core Syntax

- Rules: `name ::= expr` (default entry rule is `root`).
- Literals & classes: `"text"`, `[a-z0-9_]`, `[^"\n]`, `""` (empty string).
- Grouping & alternation: `(a | b)`, `expr*`, `expr+`, `expr?`, `expr{m}`, `expr{m,}`, `expr{m,n}`.
- Lookahead assertion: `expr (=lookahead_expr)`.

### Rule Attributes (`name [attr1, attr2=val] ::= ...`)

- `max_tokens=N` (`i32` > 0)
- `max_chars=N` (`i32` >= 0)
- `capture` or `capture="name"` (records matched bytes for `GrammarMatcher.getCaptures`)
- `stop_capture="name"`
- `lazy` (shortest-match commit semantics)
- `temperature=T` (finite non-negative `f32`, read via `matcher.temperature()`)
- Internal capture-hidden suffix/stop attributes (`capture_hidden_suffix_bytes`, `capture_hidden_stop_bytes`, `capture_hidden_body_rule_id`, `capture_hidden_marker_rule_id`)

### Built-in Macros

- `Regex("pattern", json_string=false, flags="i")` — `flags` supports `"i"` (case-insensitive), `"s"` (`.` matches `\n`), `"u"`. Setting `json_string=true` adapts escaping for JSON strings.
- `TagDispatch(("tag1", rule1), ("tag2", rule2), loop_after_dispatch=true, excludes=("stop"))`
- `Token(1, 2, ...)` — allow specific token IDs directly.
- `ExcludeToken(1, 2, ...)` — allow any token except listed IDs.
- `TokenTagDispatch((token_id, rule), ..., loop_after_dispatch=true, exclude_tokens=(...))`
- `Substring("str1", ...)` — match prefixes/substrings of the provided strings.

---

## 4. Lark Syntax

Compiled with `GrammarCompiler.compileLark` or `Grammar.fromLark`.

- **Required root rule**: must define `start: ...` (cannot be an uppercase terminal).
- Lowercase names define grammar rules (`foo: ...`); UPPERCASE names (optionally prefixed `_`, `?`, `!`) define terminals (`INT: /[0-9]+/`).
- `%import common.NAME` / `%import common (A, B)` / `%import common.NAME -> ALIAS`: supports 25 built-in terminals:
  `DIGIT`, `HEXDIGIT`, `INT`, `SIGNED_INT`, `DECIMAL`, `_EXP`, `FLOAT`, `SIGNED_FLOAT`, `NUMBER`, `SIGNED_NUMBER`, `ESCAPED_STRING`, `LCASE_LETTER`, `UCASE_LETTER`, `LETTER`, `WORD`, `CNAME`, `WS_INLINE`, `WS`, `CR`, `LF`, `NEWLINE`, `SH_COMMENT`, `CPP_COMMENT`, `C_COMMENT`, `SQL_COMMENT`.
- `%ignore expr`: automatically skips `expr` (e.g., `%ignore /\s+/`).
- `%grammar_options {"allow_initial_skip": true}`: allows `%ignore` before the first token (`no_forcing` and `allow_invalid_utf8` fail if `true`).
- Subgrammars: pass `named_grammars: &.{ NamedGrammar.fromLarkSource("sub", ...), NamedGrammar.fromGrammar("pre", &g) }` in `LarkOptions` and reference via `@sub` or inline `%lark { ... }`.
- Special tokens `<|token|>` and wildcard `<[*]>`: require a `TokenizerInfo` (`GrammarCompiler.compileLark` supplies it automatically; `Grammar.fromLark` requires `.tokenizer_info = &tok`).
- **Rule Attributes (`rule [attr1, attr2=val]: ...`)**:
  `lazy`, `max_tokens=N` (`1..1_000_000`), `max_chars=N`, `capture` / `capture="name"`, `suffix=<str|regex|TERM>`, `stop=<str|regex|TERM>` (`suffix` and `stop` are mutually exclusive), `stop_capture="name"` (requires `stop` or `suffix`), `temperature=T`.
- **Unsupported Lark constructs** (rejected cleanly): rule/terminal priorities (`.2`), parametric grammars (`rule{a}:`), templates, terminal intersection (`&`), and `%if`. (Rule-level `-> alias` suffixes are parsed and ignored; `%import ... -> ALIAS` is supported.)

---

## 5. Structural Tags (JSON)

Compiled with `GrammarCompiler.compileStructuralTag(json, diag)` or `Grammar.fromStructuralTag[WithTokenizer](alloc, json, ...)`.

### Document Wrapper & Tokenizer Rules

- Standard wrapper: `{"type": "structural_tag", "format": { ... }}` (`"type"` is optional if `"format"` is present; you can also pass a bare format object directly).
- Nesting depth is bounded at `MAX_FORMAT_DEPTH = 100`.
- **String-keyed token references** (e.g., `{"type":"token","token":"<tool>"}` or `trigger_tokens: ["<|call|>"]`) **require a tokenizer**: use `GrammarCompiler.compileStructuralTag` or `Grammar.fromStructuralTagWithTokenizer`. Integer token IDs (`"token": 5`) work without a tokenizer.

### Supported `"type"` Formats (20 + 1 Alias)

1. `"const_string"`: `{"type": "const_string", "value": "hello"}`
2. `"json_schema"`: `{"type": "json_schema", "json_schema": {...}, "style": "json" | "qwen_xml" | ..., "any_order": false, "max_whitespace_cnt": null, "excludes": [...]}`
   *(Also accepts `"qwen_xml_parameter"` as an alias setting `style = "qwen_xml"` automatically.)*
3. `"any_text"`: `{"type": "any_text", "excludes": [...], "max_tokens": null, "max_chars": null}`
4. `"grammar"`: `{"type": "grammar", "grammar": "root ::= ..."}` (embedded EBNF)
5. `"regex"`: `{"type": "regex", "pattern": "..."}`
6. `"sequence"`: `{"type": "sequence", "elements": [<format>, ...]}`
7. `"or"`: `{"type": "or", "elements": [<format>, ...]}`
8. `"tag"`: `{"type": "tag", "begin": "<call>" | {"type":"token","token":...}, "content": <format>, "end": "</call>" | ["</call>", "<|eot|>"] | {"type":"token","token":...}}`
9. `"triggered_tags"`: `{"type": "triggered_tags", "triggers": ["<call>"], "tags": [<tag>...], "excludes": [...], "at_least_one": false, "stop_after_first": false}`
10. `"tags_with_separator"`: `{"type": "tags_with_separator", "tags": [<tag>...], "separator": "\n", "at_least_one": false, "stop_after_first": false}`
11. `"optional"`: `{"type": "optional", "content": <format>}`
12. `"plus"`: `{"type": "plus", "content": <format>}`
13. `"star"`: `{"type": "star", "content": <format>}`
14. `"repeat"`: `{"type": "repeat", "min": 1, "max": 3, "content": <format>}` (`max: -1` means unbounded)
15. `"token"`: `{"type": "token", "token": 42 | "<|tool|>"}`
16. `"exclude_token"`: `{"type": "exclude_token", "exclude_tokens": [0, "<eos>"]}`
17. `"any_tokens"`: `{"type": "any_tokens", "exclude_tokens": [...], "max_tokens": null}`
18. `"token_triggered_tags"`: `{"type": "token_triggered_tags", "trigger_tokens": [...], "tags": [<tag>...], "exclude_tokens": [...], "at_least_one": false, "stop_after_first": false}`
19. `"dispatch"`: `{"type": "dispatch", "rules": [["<a", <format>], ...], "loop": true, "excludes": [...]}`
20. `"token_dispatch"`: `{"type": "token_dispatch", "rules": [[42 | "<|a|>", <format>], ...], "loop": true, "exclude_tokens": [...]}`
