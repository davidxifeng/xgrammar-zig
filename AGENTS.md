# Agent Instructions (`xgrammar-zig`)

## Using `xgrammar-zig` in Applications & Integrations

AI agents integrating or calling `@import("xgrammar")` do **not** need to read files under `src/`.
Read the repository skill first:

1. **Primary Guide**: [`.agents/skills/xgrammar-zig/SKILL.md`](.agents/skills/xgrammar-zig/SKILL.md) — `build.zig` integration, grammar format choice, constrained decoding loop, lifetime/ownership table, batch & speculative decoding, and Zig `0.17.1` gotchas.
2. **Full API Reference**: [`.agents/skills/xgrammar-zig/references/api-reference.md`](.agents/skills/xgrammar-zig/references/api-reference.md) — every public export, option struct, default value, error set, and method signature.
3. **Grammar Input Syntax**: [`.agents/skills/xgrammar-zig/references/grammar-formats.md`](.agents/skills/xgrammar-zig/references/grammar-formats.md) — JSON Schema + 9 `JsonFormat` XML schemas, EBNF macros/attributes, Lark directives & `common.*` terminals, Regex/range helpers, and all 20 Structural Tag JSON formats.
4. **Runnable Examples**: [`.agents/skills/xgrammar-zig/examples/recipes.zig`](.agents/skills/xgrammar-zig/examples/recipes.zig) — compiled `zig test` recipes verified under `std.testing.allocator` (zero leaks).

When consuming `xgrammar-zig` from another repository, you can copy `.agents/skills/xgrammar-zig/` into your project's `.agents/skills/` directory so local coding agents pick it up automatically.

## Contributing to `xgrammar-zig` (Repository Development)

- **Toolchain**: Zig **`0.17.1`** (`std.Io.Writer` with `{f}` formatting, unmanaged `std.ArrayList`).
- **Memory safety**: Every allocation path and test must pass with zero leaks under `std.testing.allocator`.
- **Verification**: Run `zig fmt --check src tools build.zig .agents/skills/xgrammar-zig/examples/recipes.zig`, `zig test --dep xgrammar -Mroot=.agents/skills/xgrammar-zig/examples/recipes.zig -Mxgrammar=src/xgrammar.zig`, and `zig build test` before finishing changes.
- **Compatibility & Parity**: Preserve `"v16"` serialization compatibility and byte-for-byte parity with `tools/oracle-rs`.
- **Do not modify `tools/oracle-rs/`**: It is the Rust reference oracle used for differential parity testing.
