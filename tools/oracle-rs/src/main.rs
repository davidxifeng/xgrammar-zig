//! Parity oracle: drives xgrammar-rs over JSON-specified grammars/vocabs/sequences
//! and dumps per-step token bitmasks so the Zig port can compare word-for-word.
//!
//! Input (file arg or stdin), one JSON doc:
//! {
//!   "vocab": ["...", ...],                  // encoded vocab (UTF-8 strings)
//!   "vocab_type": "raw" | "byte_fallback",
//!   "vocab_size": 151936,                   // optional; pads vocab with special ids
//!   "stop_token_ids": [..],                 // optional
//!   "add_prefix_space": false,
//!   "grammar": {
//!     "type": "json_schema" | "ebnf",
//!     "text": "...",
//!     "root": "root",                       // ebnf only
//!     "any_whitespace": true,               // json_schema only
//!     "strict_mode": false                  // json_schema only
//!   },
//!   "sequences": [[1, 2, 3]]                // per sequence: bitmask is dumped BEFORE
//! }                                          // accepting each token id
//!
//! Output: JSON { vocab_size, bitmask_size, sequences: [{steps:[{token_id, accepted,
//! bitmask:[u32...], completed, terminated}], jump_forward_end}] }

use std::io::Read;

use serde_json::{json, Value};
use xgrammar::{get_bitmask_size, GrammarCompiler, GrammarMatcher, TokenizerInfo, VocabType};

fn fail(msg: &str) -> ! {
    eprintln!("oracle error: {msg}");
    std::process::exit(2);
}

fn main() {
    let mut input = String::new();
    match std::env::args().nth(1) {
        Some(path) => input = std::fs::read_to_string(&path).unwrap_or_else(|e| fail(&format!("read {path}: {e}"))),
        None => {
            std::io::stdin().read_to_string(&mut input).unwrap_or_else(|e| fail(&format!("read stdin: {e}")));
        }
    }
    let doc: Value = serde_json::from_str(&input).unwrap_or_else(|e| fail(&format!("parse input: {e}")));

    let vocab_strings: Vec<String> = doc["vocab"]
        .as_array()
        .unwrap_or_else(|| fail("missing vocab array"))
        .iter()
        .map(|v| v.as_str().unwrap_or_default().to_string())
        .collect();
    let vocab_type = match doc["vocab_type"].as_str().unwrap_or("raw") {
        "raw" => VocabType::Raw,
        "byte_fallback" => VocabType::ByteFallback,
        other => fail(&format!("unknown vocab_type {other}")),
    };
    let vocab_size = doc["vocab_size"].as_i64().map(|v| v as i32);
    let stop_token_ids: Option<Vec<i32>> = doc["stop_token_ids"].as_array().map(|a| {
        a.iter().map(|v| v.as_i64().unwrap_or(-1) as i32).collect()
    });
    let add_prefix_space = doc["add_prefix_space"].as_bool().unwrap_or(false);

    let tokenizer_info = TokenizerInfo::new(
        &vocab_strings,
        vocab_type,
        vocab_size,
        stop_token_ids,
        add_prefix_space,
    )
    .unwrap_or_else(|e| fail(&format!("TokenizerInfo::new: {e}")));

    let vocab_size_before = tokenizer_info.vocab_size();
    let compiler = GrammarCompiler::with_defaults(tokenizer_info);

    let grammar = &doc["grammar"];
    let gtype = grammar["type"].as_str().unwrap_or_else(|| fail("missing grammar.type"));
    let gtext = grammar["text"].as_str().unwrap_or_else(|| fail("missing grammar.text"));
    let compiled = match gtype {
        "json_schema" => {
            let any_whitespace = grammar["any_whitespace"].as_bool().unwrap_or(true);
            let strict_mode = grammar["strict_mode"].as_bool().unwrap_or(false);
            compiler
                .compile_json_schema(gtext, any_whitespace, None, None, strict_mode, None)
                .unwrap_or_else(|e| fail(&format!("compile_json_schema: {e}")))
        }
        "ebnf" => {
            let root = grammar["root"].as_str().unwrap_or("root");
            compiler
                .compile_grammar_ebnf(gtext, root)
                .unwrap_or_else(|e| fail(&format!("compile_grammar_ebnf: {e}")))
        }
        other => fail(&format!("unknown grammar.type {other}")),
    };

    let vocab_size = vocab_size_before;
    let bitmask_size = get_bitmask_size(vocab_size) as usize;

    let seqs = doc["sequences"].as_array().unwrap_or_else(|| fail("missing sequences array"));
    let mut out_seqs = Vec::with_capacity(seqs.len());
    for seq in seqs {
        let ids: Vec<i32> = seq.as_array().unwrap().iter().map(|v| v.as_i64().unwrap_or(-1) as i32).collect();
        let mut matcher = GrammarMatcher::from_compiled_grammar(&compiled, false);
        let mut steps = Vec::with_capacity(ids.len());
        for &id in &ids {
            let mut bitmask = vec![0i32; bitmask_size];
            let fill_ok = matcher
                .fill_next_token_bitmask(&mut bitmask, &[1, bitmask_size as i64], 0)
                .unwrap_or_else(|e| fail(&format!("fill_next_token_bitmask: {e}")));
            let accepted = matcher.accept_token(id);
            steps.push(json!({
                "token_id": id,
                "fill_ok": fill_ok,
                "accepted": accepted,
                "bitmask": bitmask.iter().map(|w| (*w as u32) as u64).collect::<Vec<_>>(),
                "completed": matcher.is_completed(),
                "terminated": matcher.is_terminated(),
            }));
        }
        let jump_forward = matcher
            .find_jump_forward_string()
            .unwrap_or_else(|e| fail(&format!("find_jump_forward_string: {e}")));
        out_seqs.push(json!({
            "ids": ids,
            "steps": steps,
            "jump_forward_end": String::from_utf8_lossy(&jump_forward),
        }));
    }

    let out = json!({
        "vocab_size": vocab_size,
        "bitmask_size": bitmask_size,
        "sequences": out_seqs,
    });
    println!("{}", serde_json::to_string_pretty(&out).unwrap());
}
