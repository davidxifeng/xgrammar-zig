//! Pure-Zig port of xgrammar-rs 0.2.8 — structured generation core.
//! Root wiring mirrors lib.rs re-exports; extended wave by wave.
pub const version = "0.2.8";

pub const config = @import("config.zig");
pub const support = @import("support/mod.zig");
pub const tokenizer = @import("tokenizer/mod.zig");
pub const grammar = @import("grammar/mod.zig");

test {
    _ = config;
    _ = support;
    _ = tokenizer;
    _ = grammar;
}
