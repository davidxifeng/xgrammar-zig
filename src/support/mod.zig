//! Foundational utilities: UTF-8 encoding, compact CSR
//! arrays, dynamic bitsets, integer-set operations, hashing helpers, and the
//! recursion-depth guard.
//!
//! One dedicated type per file; re-exported here.

const std = @import("std");

const byte_utils_mod = @import("byte_utils.zig");
const compact_2d_array_mod = @import("compact_2d_array.zig");
const dynamic_bitset_mod = @import("dynamic_bitset.zig");
const encoding_mod = @import("encoding.zig");
const hash_mod = @import("hash.zig");
const int_set_mod = @import("int_set.zig");
const json_parse_mod = @import("json_parse.zig");
const lru_cache_mod = @import("lru_cache.zig");
const recursion_guard_mod = @import("recursion_guard.zig");
const union_find_set_mod = @import("union_find_set.zig");

pub const byte_utils = byte_utils_mod;
pub const compact_2d_array = compact_2d_array_mod;
pub const dynamic_bitset = dynamic_bitset_mod;
pub const encoding = encoding_mod;
pub const hash = hash_mod;
pub const int_set = int_set_mod;
pub const json_parse = json_parse_mod;
pub const lru_cache = lru_cache_mod;
pub const recursion_guard = recursion_guard_mod;
pub const union_find_set = union_find_set_mod;

// pub use byte_utils::common_prefix_len;
pub const common_prefix_len = byte_utils.common_prefix_len;
// pub use compact_2d_array::{Compact2dArray, Compact2dArrayError};
pub const Compact2dArray = compact_2d_array.Compact2dArray;
pub const Compact2dArrayError = compact_2d_array.Compact2dArrayError;
// pub use dynamic_bitset::{BITS_PER_BLOCK, DynamicBitset};
pub const BITS_PER_BLOCK = dynamic_bitset.BITS_PER_BLOCK;
pub const DynamicBitset = dynamic_bitset.DynamicBitset;
// pub use encoding::{...};
pub const CharHandlingError = encoding.CharHandlingError;
pub const Codepoint = encoding.Codepoint;
pub const byte_to_latin1 = encoding.byte_to_latin1;
pub const char_to_utf8_bytes = encoding.char_to_utf8_bytes;
pub const escape_byte = encoding.escape_byte;
pub const escape_bytes = encoding.escape_bytes;
pub const escape_codepoint = encoding.escape_codepoint;
pub const escape_str = encoding.escape_str;
pub const handle_utf8_first_byte = encoding.handle_utf8_first_byte;
pub const hex_char_to_int = encoding.hex_char_to_int;
pub const latin1_to_bytes = encoding.latin1_to_bytes;
pub const parse_next_escaped = encoding.parse_next_escaped;
pub const parse_next_utf8 = encoding.parse_next_utf8;
pub const parse_next_utf8_or_escaped = encoding.parse_next_utf8_or_escaped;
pub const parse_utf8 = encoding.parse_utf8;
// pub use hash::{hash_combine, hash_combine_binary};
pub const hash_combine = hash.hash_combine;
pub const hash_combine_binary = hash.hash_combine_binary;
// pub use int_set::{intset_complement, intset_difference, intset_intersection, intset_union};
pub const intset_complement = int_set.intset_complement;
pub const intset_difference = int_set.intset_difference;
pub const intset_intersection = int_set.intset_intersection;
pub const intset_union = int_set.intset_union;
// pub use json_parse::parse_json;
pub const parse_json = json_parse.parse_json;
// O(1) generic LRU cache
pub const AutoLruCache = lru_cache.AutoLruCache;
pub const LruCache = lru_cache.LruCache;
// pub use recursion_guard::{...};
pub const DEFAULT_MAX_RECURSION_DEPTH = recursion_guard.DEFAULT_MAX_RECURSION_DEPTH;
pub const MAX_REASONABLE_RECURSION_DEPTH = recursion_guard.MAX_REASONABLE_RECURSION_DEPTH;
pub const RecursionError = recursion_guard.RecursionError;
pub const RecursionGuard = recursion_guard.RecursionGuard;
pub const get_max_recursion_depth = recursion_guard.get_max_recursion_depth;
pub const reset_recursion_depth = recursion_guard.reset_recursion_depth;
pub const set_max_recursion_depth = recursion_guard.set_max_recursion_depth;
pub const getMaxRecursionDepth = recursion_guard.getMaxRecursionDepth;
pub const resetRecursionDepth = recursion_guard.resetRecursionDepth;
pub const setMaxRecursionDepth = recursion_guard.setMaxRecursionDepth;
// pub use union_find_set::UnionFindSet;
pub const UnionFindSet = union_find_set.UnionFindSet;

test {
    _ = byte_utils_mod;
    _ = compact_2d_array_mod;
    _ = dynamic_bitset_mod;
    _ = encoding_mod;
    _ = hash_mod;
    _ = int_set_mod;
    _ = json_parse_mod;
    _ = lru_cache_mod;
    _ = recursion_guard_mod;
    _ = union_find_set_mod;
}
