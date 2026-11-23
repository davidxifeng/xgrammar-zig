use serde_json::json;
use std::hint::black_box;
use std::time::Instant;
use xgrammar::{
    allocate_token_bitmask, apply_token_bitmask_inplace_cpu,
    apply_token_bitmask_inplace_cpu_batch, get_bitmask_size, Grammar, GrammarCompiler,
    GrammarMatcher, TokenizerInfo, VocabType,
};

const VOCAB_SIZE: usize = 32_000;
const TRACE_LEN: usize = 33;

const FIXED_TOKENS: [&str; 25] = [
    "{", "}", "[", "]", ":", ",", "\"", "\"user\"", "\"name\"", "\"Ada\"", "\"age\"", "30",
    "\"active\"", "true", "\"tags\"", "\"zig\"", "\"rust\"", "\"score\"", "99", "\"role\"",
    "\"admin\"", "false", " ", "null", "</s>",
];

const TRACE_IDS: [i32; TRACE_LEN] = [
    0, 7, 4, 0, 8, 4, 9, 5, 10, 4, 11, 5, 12, 4, 13, 5, 19, 4, 20, 1, 5, 14, 4, 2, 15, 5, 16, 3,
    5, 17, 4, 18, 1,
];

const JSON_SCHEMA: &str = r#"{"type":"object","properties":{"user":{"type":"object","properties":{"name":{"type":"string"},"age":{"type":"integer"},"active":{"type":"boolean"},"role":{"type":"string","enum":["admin","member","guest"]}},"required":["name","age","active","role"],"additionalProperties":false},"tags":{"type":"array","items":{"type":"string"}},"score":{"type":"integer"}},"required":["user","tags","score"],"additionalProperties":false}"#;

const EBNF_GRAMMAR: &str = r#"root ::= expr
expr ::= term (("+" | "-") term)*
term ::= factor (("*" | "/") factor)*
factor ::= [0-9]+ | "(" expr ")"
"#;

#[derive(Clone, Copy)]
struct Stats {
    median_us: f64,
    mean_us: f64,
    min_us: f64,
}

fn compute_stats(samples_ns: &mut [u64], divisor: f64) -> Stats {
    samples_ns.sort_unstable();
    let sum: u128 = samples_ns.iter().map(|&v| v as u128).sum();
    let n = samples_ns.len();
    let median_ns = if n % 2 == 1 {
        samples_ns[n / 2] as f64
    } else {
        (samples_ns[n / 2 - 1] + samples_ns[n / 2]) as f64 * 0.5
    };
    let mean_ns = sum as f64 / n as f64;
    let min_ns = samples_ns[0] as f64;
    Stats {
        median_us: (median_ns / 1000.0) / divisor,
        mean_us: (mean_ns / 1000.0) / divisor,
        min_us: (min_ns / 1000.0) / divisor,
    }
}

fn build_vocab() -> Vec<String> {
    let mut vocab = Vec::with_capacity(VOCAB_SIZE);
    for i in 0..VOCAB_SIZE {
        if i < FIXED_TOKENS.len() {
            vocab.push(FIXED_TOKENS[i].to_owned());
        } else {
            let s = match i % 5 {
                0 => format!("val_{i}"),
                1 => format!("key_{i}"),
                2 => format!("pre_word{i}"),
                3 => format!("num{i}"),
                _ => format!("sub_{i}"),
            };
            vocab.push(s);
        }
    }
    vocab
}

fn stat_json(s: Stats) -> serde_json::Value {
    json!({
        "median": s.median_us,
        "mean": s.mean_us,
        "min": s.min_us,
    })
}

fn main() {
    let vocab = build_vocab();

    // 1. TokenizerInfo::new on 32K vocab
    let mut tok_samples = [0u64; 5];
    {
        let _warm = TokenizerInfo::new(&vocab, VocabType::RAW, None, Some(vec![24]), false).unwrap();
        for slot in &mut tok_samples {
            let t0 = Instant::now();
            let ti = TokenizerInfo::new(&vocab, VocabType::RAW, None, Some(vec![24]), false).unwrap();
            let elapsed = t0.elapsed().as_nanos() as u64;
            drop(ti);
            *slot = elapsed;
        }
    }
    let tok_stats = compute_stats(&mut tok_samples, 1.0);

    let tok = TokenizerInfo::new(&vocab, VocabType::RAW, None, Some(vec![24]), false).unwrap();

    // 2. Cold JSON Schema compilation (max_threads = 1)
    let mut json_1t_samples = [0u64; 5];
    {
        let c1 = GrammarCompiler::new(tok.clone(), 1, false, -1);
        let _warm = c1.compile_json_schema(JSON_SCHEMA, true, None, None, true, None).unwrap();
        for slot in &mut json_1t_samples {
            let t0 = Instant::now();
            let cg = c1.compile_json_schema(JSON_SCHEMA, true, None, None, true, None).unwrap();
            let elapsed = t0.elapsed().as_nanos() as u64;
            drop(cg);
            *slot = elapsed;
        }
    }
    let json_1t_stats = compute_stats(&mut json_1t_samples, 1.0);

    // 3. Cold JSON Schema compilation (max_threads = 4)
    let mut json_4t_samples = [0u64; 5];
    {
        let c4 = GrammarCompiler::new(tok.clone(), 4, false, -1);
        let _warm = c4.compile_json_schema(JSON_SCHEMA, true, None, None, true, None).unwrap();
        for slot in &mut json_4t_samples {
            let t0 = Instant::now();
            let cg = c4.compile_json_schema(JSON_SCHEMA, true, None, None, true, None).unwrap();
            let elapsed = t0.elapsed().as_nanos() as u64;
            drop(cg);
            *slot = elapsed;
        }
    }
    let json_4t_stats = compute_stats(&mut json_4t_samples, 1.0);

    // 4. Cold EBNF compilation (max_threads = 1)
    let mut ebnf_1t_samples = [0u64; 5];
    {
        let c1 = GrammarCompiler::new(tok.clone(), 1, false, -1);
        let warm_g = Grammar::from_ebnf(EBNF_GRAMMAR, "root").unwrap();
        let _warm = c1.compile_grammar(&warm_g).unwrap();
        for slot in &mut ebnf_1t_samples {
            let t0 = Instant::now();
            let g = Grammar::from_ebnf(EBNF_GRAMMAR, "root").unwrap();
            let cg = c1.compile_grammar(&g).unwrap();
            let elapsed = t0.elapsed().as_nanos() as u64;
            drop(cg);
            *slot = elapsed;
        }
    }
    let ebnf_1t_stats = compute_stats(&mut ebnf_1t_samples, 1.0);

    let comp = GrammarCompiler::new(tok.clone(), 4, false, -1);
    let compiled = comp.compile_json_schema(JSON_SCHEMA, true, None, None, true, None).unwrap();
    let mut matcher = GrammarMatcher::from_compiled_grammar(&compiled, false);

    let bm_size = get_bitmask_size(tok.vocab_size());
    let shape = [1i64, bm_size as i64];
    let mut bitmask = allocate_token_bitmask(1, tok.vocab_size());

    // 5. fill_next_token_bitmask + accept_token (33 tokens per pass)
    let mut fill_samples = [0u64; 50];
    let mut fill_checksum: u64 = 0;
    let mut accepted_count: usize = 0;
    for pass_idx in 0..55 {
        matcher.reset();
        let t0 = Instant::now();
        let mut local_hash: u64 = 0;
        let mut local_acc: usize = 0;
        for &tid in &TRACE_IDS {
            let _ = matcher.fill_next_token_bitmask(&mut bitmask, &shape, 0).unwrap();
            for &w in &bitmask {
                local_hash = local_hash.wrapping_mul(1099511628211) ^ (w as u32 as u64);
            }
            if matcher.accept_token(tid) {
                local_acc += 1;
            }
        }
        let elapsed = t0.elapsed().as_nanos() as u64;
        if pass_idx >= 5 {
            fill_samples[pass_idx - 5] = elapsed;
        }
        fill_checksum = local_hash;
        accepted_count = local_acc;
    }
    let fill_stats = compute_stats(&mut fill_samples, TRACE_LEN as f64);

    // Mid-generation mask after `{`
    matcher.reset();
    let _ = matcher.accept_token(0);
    let _ = matcher.fill_next_token_bitmask(&mut bitmask, &shape, 0).unwrap();

    // 6. apply_token_bitmask_inplace_cpu on 32K logits (batch = 1)
    let mut logits_b1 = vec![0.0f32; VOCAB_SIZE];
    let mut apply_b1_samples = [0u64; 200];
    for run in 0..220 {
        for (j, v) in logits_b1.iter_mut().enumerate() {
            *v = (j & 255) as f32;
        }
        let t0 = Instant::now();
        for _ in 0..25 {
            apply_token_bitmask_inplace_cpu(&mut logits_b1, &bitmask, tok.vocab_size());
            black_box(logits_b1.as_ptr());
        }
        let elapsed = t0.elapsed().as_nanos() as u64;
        if run >= 20 {
            apply_b1_samples[run - 20] = elapsed;
        }
    }
    let apply_b1_stats = compute_stats(&mut apply_b1_samples, 25.0);

    // 7. apply_token_bitmask_inplace_cpu_batch on 4x32K = 128K logits (batch = 4)
    let mut batch4_bm = allocate_token_bitmask(4, tok.vocab_size());
    let stride = bm_size as usize;
    for b in 0..4 {
        batch4_bm[b * stride..(b + 1) * stride].copy_from_slice(&bitmask);
    }
    let mut logits_b4 = vec![0.0f32; 4 * VOCAB_SIZE];
    let mut apply_b4_samples = [0u64; 100];
    for run in 0..110 {
        for (j, v) in logits_b4.iter_mut().enumerate() {
            *v = (j & 255) as f32;
        }
        let t0 = Instant::now();
        for _ in 0..10 {
            apply_token_bitmask_inplace_cpu_batch(&mut logits_b4, &batch4_bm, tok.vocab_size(), 4, None);
            black_box(logits_b4.as_ptr());
        }
        let elapsed = t0.elapsed().as_nanos() as u64;
        if run >= 10 {
            apply_b4_samples[run - 10] = elapsed;
        }
    }
    let apply_b4_stats = compute_stats(&mut apply_b4_samples, 10.0);

    // 8. End-to-end 33-token constrained decode step
    let mut e2e_samples = [0u64; 50];
    for pass_idx in 0..55 {
        matcher.reset();
        let t0 = Instant::now();
        for &tid in &TRACE_IDS {
            let _ = matcher.fill_next_token_bitmask(&mut bitmask, &shape, 0).unwrap();
            apply_token_bitmask_inplace_cpu(&mut logits_b1, &bitmask, tok.vocab_size());
            black_box(logits_b1.as_ptr());
            let _ = matcher.accept_token(tid);
        }
        let elapsed = t0.elapsed().as_nanos() as u64;
        if pass_idx >= 5 {
            e2e_samples[pass_idx - 5] = elapsed;
        }
    }
    let e2e_stats = compute_stats(&mut e2e_samples, TRACE_LEN as f64);

    let out = json!({
        "impl": "xgrammar-rs-0.2.8",
        "vocab_size": tok.vocab_size(),
        "accepted_count": accepted_count,
        "bitmask_checksum": fill_checksum,
        "tokenizer_info_init_32k_us": stat_json(tok_stats),
        "compile_json_schema_1t_us": stat_json(json_1t_stats),
        "compile_json_schema_4t_us": stat_json(json_4t_stats),
        "compile_ebnf_1t_us": stat_json(ebnf_1t_stats),
        "fill_bitmask_32k_per_token_us": stat_json(fill_stats),
        "apply_bitmask_32k_b1_us": stat_json(apply_b1_stats),
        "apply_bitmask_128k_b4_us": stat_json(apply_b4_stats),
        "e2e_decode_32k_per_token_us": stat_json(e2e_stats),
    });
    println!("{out}");
}
