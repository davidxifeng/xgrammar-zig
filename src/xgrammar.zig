//! Pure-Zig port of xgrammar-rs 0.2.8 — structured generation core.
//! Root wiring mirrors lib.rs re-exports; extended wave by wave.
pub const version = "0.2.8";

pub const config = @import("config.zig");
pub const support = @import("support/mod.zig");
pub const tokenizer = @import("tokenizer/mod.zig");
pub const grammar = @import("grammar/mod.zig");
pub const parser = @import("parser/mod.zig");
pub const fsm = @import("fsm/mod.zig");
pub const functor = @import("functor/mod.zig");
pub const converter = @import("converter/mod.zig");
pub const compiler = @import("compiler/mod.zig");

test {
    _ = config;
    _ = support;
    _ = tokenizer;
    _ = grammar;
    _ = parser;
    _ = fsm;
    _ = functor;
    _ = converter;
    _ = compiler;
}
