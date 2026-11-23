//! Golden snapshot tests for src/converter/, generated against the reference
//! xgrammar-rs 0.2.8 (cargo-run goldens; oracle per docs/PORTING.md).

const std = @import("std");
const range_regex = @import("range_regex.zig");
const json_schema_converter = @import("json_schema_converter.zig");
const JsonFormat = @import("json_format.zig").JsonFormat;

const IntRangeCase = struct { s: ?i64, e: ?i64, expect: []const u8 };
const FloatRangeCase = struct { s: ?f64, e: ?f64, xs: bool = false, xe: bool = false, expect: []const u8 };
const SchemaCase = struct { name: []const u8, schema: []const u8, any_whitespace: bool = false, indent: ?i32 = null, strict_mode: bool = false, any_order: bool = false, expect: []const u8 };

const int_range_cases = [_]IntRangeCase{
    .{ .s = null, .e = null, .expect = \\^-?\d+$
 },
    .{ .s = 0, .e = null, .expect = \\^(0|[1-9]\d*)$
 },
    .{ .s = 1, .e = null, .expect = \\^([1-9]|[1-9]\d{1,})$
 },
    .{ .s = -1, .e = null, .expect = \\^(-(1)|0|[1-9]\d*)$
 },
    .{ .s = null, .e = 0, .expect = \\^(-[1-9]\d*|0)$
 },
    .{ .s = null, .e = 5, .expect = \\^(-[1-9]\d*|0|([1-5]))$
 },
    .{ .s = null, .e = -1, .expect = \\^(-[1-9]|-[1-9]\d{1,})$
 },
    .{ .s = null, .e = -10, .expect = \\^(-[1-9]\d|-[1-9]\d{2,})$
 },
    .{ .s = 0, .e = 0, .expect = \\^(0)$
 },
    .{ .s = 0, .e = 5, .expect = \\^(0|([1-5]))$
 },
    .{ .s = 3, .e = 7, .expect = \\^(([3-7]))$
 },
    .{ .s = 5, .e = 23, .expect = \\^(([5-9]|1\d|2[0-3]))$
 },
    .{ .s = 19, .e = 42, .expect = \\^((19|[2-3]\d|4[0-2]))$
 },
    .{ .s = 1, .e = 999, .expect = \\^(([1-9]|[1-9]\d|[1-9]\d{2}))$
 },
    .{ .s = -3, .e = 7, .expect = \\^(-([1-3])|0|([1-7]))$
 },
    .{ .s = -7, .e = -3, .expect = \\^(-([3-7]))$
 },
    .{ .s = 100, .e = 100, .expect = \\^((100))$
 },
    .{ .s = -100, .e = 100, .expect = \\^(-([1-9]|[1-9]\d|100)|0|([1-9]|[1-9]\d|100))$
 },
    .{ .s = 0, .e = 99, .expect = \\^(0|([1-9]|[1-9]\d))$
 },
    .{ .s = 10, .e = 10, .expect = \\^((10))$
 },
    .{ .s = 95, .e = 105, .expect = \\^((9[5-9]|10[0-5]))$
 },
    .{ .s = -105, .e = -95, .expect = \\^(-(9[5-9]|10[0-5]))$
 },
    .{ .s = 0, .e = 1000000, .expect = \\^(0|([1-9]|[1-9]\d|[1-9]\d{2}|[1-9]\d{3}|[1-9]\d{4}|[1-9]\d{5}|1000000))$
 },
    .{ .s = 999, .e = 1001, .expect = \\^((999|100[0-1]))$
 },
    .{ .s = 5, .e = 3, .expect = \\^()$
 },
    .{ .s = 9223372036854775807, .e = null, .expect = \\^(922337203685477580[7-9]|92233720368547758[1-8]\d|922337203685477589\d|92233720368547759\d{2}|922337203685477[6-8]\d{3}|9223372036854779\d{3}|922337203685478\d{4}|922337203685479\d{4}|92233720368548\d{5}|92233720368549\d{5}|922337203685[5-8]\d{6}|9223372036859\d{6}|92233720368[6-8]\d{7}|922337203689\d{7}|92233720369\d{8}|922337203[7-8]\d{9}|9223372039\d{9}|92233720[4-8]\d{10}|922337209\d{10}|9223372[1-8]\d{11}|92233729\d{11}|922337[3-8]\d{12}|9223379\d{12}|922338\d{13}|922339\d{13}|9223[4-8]\d{14}|92239\d{14}|922[4-8]\d{15}|9229\d{15}|92[3-8]\d{16}|929\d{16}|9[3-8]\d{17}|99\d{17}|[1-9]\d{19,})$
 },
    .{ .s = null, .e = -9223372036854775808, .expect = \\^(-922337203685477580[8-9]|-92233720368547758[1-8]\d|-922337203685477589\d|-92233720368547759\d{2}|-922337203685477[6-8]\d{3}|-9223372036854779\d{3}|-922337203685478\d{4}|-922337203685479\d{4}|-92233720368548\d{5}|-92233720368549\d{5}|-922337203685[5-8]\d{6}|-9223372036859\d{6}|-92233720368[6-8]\d{7}|-922337203689\d{7}|-92233720369\d{8}|-922337203[7-8]\d{9}|-9223372039\d{9}|-92233720[4-8]\d{10}|-922337209\d{10}|-9223372[1-8]\d{11}|-92233729\d{11}|-922337[3-8]\d{12}|-9223379\d{12}|-922338\d{13}|-922339\d{13}|-9223[4-8]\d{14}|-92239\d{14}|-922[4-8]\d{15}|-9229\d{15}|-92[3-8]\d{16}|-929\d{16}|-9[3-8]\d{17}|-99\d{17}|-[1-9]\d{19,})$
 },
};

const float_range_cases = [_]FloatRangeCase{
    .{ .s = null, .e = null, .xs = false, .xe = false, .expect = \\^-?\d+(\.\d{1,6})?$
 },
    .{ .s = 0.0, .e = 1.0, .xs = false, .xe = false, .expect = \\^(0(\.0{1,6})?|0\.[1-9]\d{0,5}|0\.0[1-9]\d{0,4}|0\.00[1-9]\d{0,3}|0\.000[1-9]\d{0,2}|0\.0000[1-9]\d{0,1}|0\.00000[1-9]|1\.0{1,6}|1)$
 },
    .{ .s = 1.5, .e = 2.5, .xs = false, .xe = false, .expect = \\^(1\.[6-9]\d{0,5}|1\.5[1-9]\d{0,4}|1\.50[1-9]\d{0,3}|1\.500[1-9]\d{0,2}|1\.5000[1-9]\d{0,1}|1\.50000[1-9]|1\.50{0,5}|2\.[0-4]\d{0,5}|2\.0{1,6}|2\.50{0,5}|2)$
 },
    .{ .s = -1.5, .e = 1.5, .xs = false, .xe = false, .expect = \\^(-0\.[1-9]\d{0,5}|-0\.0[1-9]\d{0,4}|-0\.00[1-9]\d{0,3}|-0\.000[1-9]\d{0,2}|-0\.0000[1-9]\d{0,1}|-0\.00000[1-9]|-1\.[0-4]\d{0,5}|-1\.0{1,6}|-1\.50{0,5}|-1|0(\.0{1,6})?|-0(\.0{1,6})|0\.[1-9]\d{0,5}|0\.0[1-9]\d{0,4}|0\.00[1-9]\d{0,3}|0\.000[1-9]\d{0,2}|0\.0000[1-9]\d{0,1}|0\.00000[1-9]|1\.[0-4]\d{0,5}|1\.0{1,6}|1\.50{0,5}|1)$
 },
    .{ .s = 0.0, .e = 0.5, .xs = false, .xe = false, .expect = \\^(0(\.0{1,6})?|0\.[1-4]\d{0,5}|0\.0[1-9]\d{0,4}|0\.00[1-9]\d{0,3}|0\.000[1-9]\d{0,2}|0\.0000[1-9]\d{0,1}|0\.00000[1-9]|0\.50{1,5}|0\.5)$
 },
    .{ .s = 1.0, .e = 1.0, .xs = false, .xe = false, .expect = \\^(1(\.0{1,6})?)$
 },
    .{ .s = null, .e = 0.0, .xs = false, .xe = false, .expect = \\^(-0\.[1-9]\d{0,5}|-0\.0[1-9]\d{0,4}|-0\.00[1-9]\d{0,3}|-0\.000[1-9]\d{0,2}|-0\.0000[1-9]\d{0,1}|-0\.00000[1-9]|-([1-9]|[1-9]\d{1,})(\.\d{1,6})?|0(\.0{1,6})?|-0(\.0{1,6}))$
 },
    .{ .s = 0.0, .e = null, .xs = false, .xe = false, .expect = \\^(0(\.0{1,6})?|0\.[1-9]\d{0,5}|0\.0[1-9]\d{0,4}|0\.00[1-9]\d{0,3}|0\.000[1-9]\d{0,2}|0\.0000[1-9]\d{0,1}|0\.00000[1-9]|([1-9]|[1-9]\d{1,})(\.\d{1,6})?)$
 },
    .{ .s = 3.14159, .e = 3.14159, .xs = false, .xe = false, .expect = \\^(3\.141590{0,1})$
 },
    .{ .s = -2.75, .e = -2.5, .xs = false, .xe = false, .expect = \\^(-2\.6\d{0,5}|-2\.5[1-9]\d{0,4}|-2\.50[1-9]\d{0,3}|-2\.500[1-9]\d{0,2}|-2\.5000[1-9]\d{0,1}|-2\.50000[1-9]|-2\.50{1,5}|-2\.5|-2\.7[0-4]\d{0,4}|-2\.70{1,5}|-2\.750{0,4}|-2\.7)$
 },
    .{ .s = 0.1, .e = 0.3, .xs = false, .xe = false, .expect = \\^(0\.2\d{0,5}|0\.1[1-9]\d{0,4}|0\.10[1-9]\d{0,3}|0\.100[1-9]\d{0,2}|0\.1000[1-9]\d{0,1}|0\.10000[1-9]|0\.10{1,5}|0\.1|0\.30{1,5}|0\.3)$
 },
    .{ .s = 10.0, .e = 20.0, .xs = false, .xe = false, .expect = \\^(10\.[1-9]\d{0,5}|10\.0[1-9]\d{0,4}|10\.00[1-9]\d{0,3}|10\.000[1-9]\d{0,2}|10\.0000[1-9]\d{0,1}|10\.00000[1-9]|10\.0{1,6}|10|((1[1-9]))(\.\d{1,6})?|20\.0{1,6}|20)$
 },
    .{ .s = 1.0, .e = 3.0, .xs = false, .xe = false, .expect = \\^(1\.[1-9]\d{0,5}|1\.0[1-9]\d{0,4}|1\.00[1-9]\d{0,3}|1\.000[1-9]\d{0,2}|1\.0000[1-9]\d{0,1}|1\.00000[1-9]|1\.0{1,6}|1|((2))(\.\d{1,6})?|3\.0{1,6}|3)$
 },
    .{ .s = 0.0, .e = 1.0, .xs = true, .xe = false, .expect = \\^(0\.[1-9]\d{0,5}|0\.0[1-9]\d{0,4}|0\.00[1-9]\d{0,3}|0\.000[1-9]\d{0,2}|0\.0000[1-9]\d{0,1}|0\.00000[1-9]|1\.0{1,6}|1)$
 },
    .{ .s = 1.0, .e = 2.0, .xs = false, .xe = true, .expect = \\^(1\.[1-9]\d{0,5}|1\.0[1-9]\d{0,4}|1\.00[1-9]\d{0,3}|1\.000[1-9]\d{0,2}|1\.0000[1-9]\d{0,1}|1\.00000[1-9]|1\.0{1,6}|1)$
 },
    .{ .s = 1.0, .e = 1.0, .xs = true, .xe = false, .expect = \\^()$
 },
};

const schema_cases = [_]SchemaCase{
    .{ .name = "string", .schema = \\
\\{"type":"string"}
, .expect = \\
\\basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]))
\\basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=([ \n\r\t]* [,}\]:]))
\\basic_any ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer ::= (("0") | (basic_integer_1 [1-9] [0-9]*))
\\basic_number ::= ((basic_number_1 basic_number_2 basic_number_3 basic_number_5))
\\basic_string ::= (("\"" basic_string_sub))
\\basic_boolean ::= (("true") | ("false"))
\\basic_null ::= (("null"))
\\basic_array ::= (("[" basic_any basic_array_items{0, -1} "]") | ("[" "]"))
\\basic_object ::= (("{" basic_string ":" basic_any basic_object_properties{0, -1} "}") | ("{" "}"))
\\basic_number_digits ::= (([0-9]))
\\basic_array_items ::= ((", " basic_any))
\\basic_object_properties ::= ((", " basic_string ":" basic_any))
\\root ::= ((basic_string))
\\basic_integer_1 ::= ("" | ("-"))
\\basic_number_1 ::= ("" | ("-"))
\\basic_number_2 ::= (("0") | ([1-9] [0-9]*))
\\basic_number_3 ::= ("" | ("." basic_number_digits{1, -1}))
\\basic_number_4 ::= ("" | ([+\-]))
\\basic_number_5 ::= ("" | ([eE] basic_number_4 basic_number_digits{1, -1}))
\\
\\
},
    .{ .name = "string_len", .schema = \\
\\{"type":"string","minLength":2,"maxLength":4}
, .expect = \\
\\basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]))
\\basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=([ \n\r\t]* [,}\]:]))
\\basic_any ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer ::= (("0") | (basic_integer_1 [1-9] [0-9]*))
\\basic_number ::= ((basic_number_1 basic_number_2 basic_number_3 basic_number_5))
\\basic_string ::= (("\"" basic_string_sub))
\\basic_boolean ::= (("true") | ("false"))
\\basic_null ::= (("null"))
\\basic_array ::= (("[" basic_any basic_array_items{0, -1} "]") | ("[" "]"))
\\basic_object ::= (("{" basic_string ":" basic_any basic_object_properties{0, -1} "}") | ("{" "}"))
\\basic_number_digits ::= (([0-9]))
\\basic_array_items ::= ((", " basic_any))
\\basic_object_properties ::= ((", " basic_string ":" basic_any))
\\root ::= (("\"" root_characters{2, 4} "\""))
\\root_characters ::= (([^\"\\\r\n]))
\\basic_integer_1 ::= ("" | ("-"))
\\basic_number_1 ::= ("" | ("-"))
\\basic_number_2 ::= (("0") | ([1-9] [0-9]*))
\\basic_number_3 ::= ("" | ("." basic_number_digits{1, -1}))
\\basic_number_4 ::= ("" | ([+\-]))
\\basic_number_5 ::= ("" | ([eE] basic_number_4 basic_number_digits{1, -1}))
\\
\\
},
    .{ .name = "pattern", .schema = \\
\\{"type":"string","pattern":"^a[0-9]+$"}
, .expect = \\
\\basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]))
\\basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=([ \n\r\t]* [,}\]:]))
\\basic_any ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer ::= (("0") | (basic_integer_1 [1-9] [0-9]*))
\\basic_number ::= ((basic_number_1 basic_number_2 basic_number_3 basic_number_5))
\\basic_string ::= (("\"" basic_string_sub))
\\basic_boolean ::= (("true") | ("false"))
\\basic_null ::= (("null"))
\\basic_array ::= (("[" basic_any basic_array_items{0, -1} "]") | ("[" "]"))
\\basic_object ::= (("{" basic_string ":" basic_any basic_object_properties{0, -1} "}") | ("{" "}"))
\\basic_number_digits ::= (([0-9]))
\\basic_array_items ::= ((", " basic_any))
\\basic_object_properties ::= ((", " basic_string ":" basic_any))
\\root ::= (("\"" root_1 "\""))
\\basic_integer_1 ::= ("" | ("-"))
\\basic_number_1 ::= ("" | ("-"))
\\basic_number_2 ::= (("0") | ([1-9] [0-9]*))
\\basic_number_3 ::= ("" | ("." basic_number_digits{1, -1}))
\\basic_number_4 ::= ("" | ([+\-]))
\\basic_number_5 ::= ("" | ([eE] basic_number_4 basic_number_digits{1, -1}))
\\root_1 ::= Regex("^a[0-9]+$", json_string=true)
\\
\\
},
    .{ .name = "number", .schema = \\
\\{"type":"number"}
, .expect = \\
\\basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]))
\\basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=([ \n\r\t]* [,}\]:]))
\\basic_any ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer ::= (("0") | (basic_integer_1 [1-9] [0-9]*))
\\basic_number ::= ((basic_number_1 basic_number_2 basic_number_3 basic_number_5))
\\basic_string ::= (("\"" basic_string_sub))
\\basic_boolean ::= (("true") | ("false"))
\\basic_null ::= (("null"))
\\basic_array ::= (("[" basic_any basic_array_items{0, -1} "]") | ("[" "]"))
\\basic_object ::= (("{" basic_string ":" basic_any basic_object_properties{0, -1} "}") | ("{" "}"))
\\basic_number_digits ::= (([0-9]))
\\basic_array_items ::= ((", " basic_any))
\\basic_object_properties ::= ((", " basic_string ":" basic_any))
\\root ::= ((basic_number))
\\basic_integer_1 ::= ("" | ("-"))
\\basic_number_1 ::= ("" | ("-"))
\\basic_number_2 ::= (("0") | ([1-9] [0-9]*))
\\basic_number_3 ::= ("" | ("." basic_number_digits{1, -1}))
\\basic_number_4 ::= ("" | ([+\-]))
\\basic_number_5 ::= ("" | ([eE] basic_number_4 basic_number_digits{1, -1}))
\\
\\
},
    .{ .name = "num_range", .schema = \\
\\{"type":"number","minimum":1.5,"maximum":2.5}
, .expect = \\
\\basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]))
\\basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=([ \n\r\t]* [,}\]:]))
\\basic_any ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer ::= (("0") | (basic_integer_1 [1-9] [0-9]*))
\\basic_number ::= ((basic_number_1 basic_number_2 basic_number_3 basic_number_5))
\\basic_string ::= (("\"" basic_string_sub))
\\basic_boolean ::= (("true") | ("false"))
\\basic_null ::= (("null"))
\\basic_array ::= (("[" basic_any basic_array_items{0, -1} "]") | ("[" "]"))
\\basic_object ::= (("{" basic_string ":" basic_any basic_object_properties{0, -1} "}") | ("{" "}"))
\\basic_number_digits ::= (([0-9]))
\\basic_array_items ::= ((", " basic_any))
\\basic_object_properties ::= ((", " basic_string ":" basic_any))
\\root ::= ((root_1))
\\root_1 ::= (("1" "." [6-9] root_1_1{0, 5}) | ("1" "." "5" [1-9] root_2{0, 4}) | ("1" "." "5" "0" [1-9] root_3{0, 3}) | ("1" "." "5" "0" "0" [1-9] root_4{0, 2}) | ("1" "." "5" "0" "0" "0" [1-9] root_5{0, 1}) | ("1" "." "5" "0" "0" "0" "0" [1-9]) | ("1" "." "5" root_6{0, 5}) | ("2" "." [0-4] root_7{0, 5}) | ("2" "." root_8{1, 6}) | ("2" "." "5" root_9{0, 5}) | ("2"))
\\root_1_1 ::= (([0-9]))
\\root_2 ::= (([0-9]))
\\root_3 ::= (([0-9]))
\\root_4 ::= (([0-9]))
\\root_5 ::= (([0-9]))
\\root_6 ::= (("0"))
\\root_7 ::= (([0-9]))
\\root_8 ::= (("0"))
\\root_9 ::= (("0"))
\\basic_integer_1 ::= ("" | ("-"))
\\basic_number_1 ::= ("" | ("-"))
\\basic_number_2 ::= (("0") | ([1-9] [0-9]*))
\\basic_number_3 ::= ("" | ("." basic_number_digits{1, -1}))
\\basic_number_4 ::= ("" | ([+\-]))
\\basic_number_5 ::= ("" | ([eE] basic_number_4 basic_number_digits{1, -1}))
\\
\\
},
    .{ .name = "int_range", .schema = \\
\\{"type":"integer","minimum":3,"maximum":9}
, .expect = \\
\\basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]))
\\basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=([ \n\r\t]* [,}\]:]))
\\basic_any ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer ::= (("0") | (basic_integer_1 [1-9] [0-9]*))
\\basic_number ::= ((basic_number_1 basic_number_2 basic_number_3 basic_number_5))
\\basic_string ::= (("\"" basic_string_sub))
\\basic_boolean ::= (("true") | ("false"))
\\basic_null ::= (("null"))
\\basic_array ::= (("[" basic_any basic_array_items{0, -1} "]") | ("[" "]"))
\\basic_object ::= (("{" basic_string ":" basic_any basic_object_properties{0, -1} "}") | ("{" "}"))
\\basic_number_digits ::= (([0-9]))
\\basic_array_items ::= ((", " basic_any))
\\basic_object_properties ::= ((", " basic_string ":" basic_any))
\\root ::= ((root_1))
\\root_1 ::= (([3-9]))
\\basic_integer_1 ::= ("" | ("-"))
\\basic_number_1 ::= ("" | ("-"))
\\basic_number_2 ::= (("0") | ([1-9] [0-9]*))
\\basic_number_3 ::= ("" | ("." basic_number_digits{1, -1}))
\\basic_number_4 ::= ("" | ([+\-]))
\\basic_number_5 ::= ("" | ([eE] basic_number_4 basic_number_digits{1, -1}))
\\
\\
},
    .{ .name = "int_mult", .schema = \\
\\{"type":"integer","multipleOf":2,"minimum":2,"maximum":8}
, .expect = \\
\\basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]))
\\basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=([ \n\r\t]* [,}\]:]))
\\basic_any ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer ::= (("0") | (basic_integer_1 [1-9] [0-9]*))
\\basic_number ::= ((basic_number_1 basic_number_2 basic_number_3 basic_number_5))
\\basic_string ::= (("\"" basic_string_sub))
\\basic_boolean ::= (("true") | ("false"))
\\basic_null ::= (("null"))
\\basic_array ::= (("[" basic_any basic_array_items{0, -1} "]") | ("[" "]"))
\\basic_object ::= (("{" basic_string ":" basic_any basic_object_properties{0, -1} "}") | ("{" "}"))
\\basic_number_digits ::= (([0-9]))
\\basic_array_items ::= ((", " basic_any))
\\basic_object_properties ::= ((", " basic_string ":" basic_any))
\\root ::= (("2") | ("4") | ("6") | ("8"))
\\basic_integer_1 ::= ("" | ("-"))
\\basic_number_1 ::= ("" | ("-"))
\\basic_number_2 ::= (("0") | ([1-9] [0-9]*))
\\basic_number_3 ::= ("" | ("." basic_number_digits{1, -1}))
\\basic_number_4 ::= ("" | ([+\-]))
\\basic_number_5 ::= ("" | ([eE] basic_number_4 basic_number_digits{1, -1}))
\\
\\
},
    .{ .name = "bool_null", .schema = \\
\\{"type":["boolean","null"]}
, .expect = \\
\\basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]))
\\basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=([ \n\r\t]* [,}\]:]))
\\basic_any ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer ::= (("0") | (basic_integer_1 [1-9] [0-9]*))
\\basic_number ::= ((basic_number_1 basic_number_2 basic_number_3 basic_number_5))
\\basic_string ::= (("\"" basic_string_sub))
\\basic_boolean ::= (("true") | ("false"))
\\basic_null ::= (("null"))
\\basic_array ::= (("[" basic_any basic_array_items{0, -1} "]") | ("[" "]"))
\\basic_object ::= (("{" basic_string ":" basic_any basic_object_properties{0, -1} "}") | ("{" "}"))
\\basic_number_digits ::= (([0-9]))
\\basic_array_items ::= ((", " basic_any))
\\basic_object_properties ::= ((", " basic_string ":" basic_any))
\\root ::= ((basic_boolean) | (basic_null))
\\basic_integer_1 ::= ("" | ("-"))
\\basic_number_1 ::= ("" | ("-"))
\\basic_number_2 ::= (("0") | ([1-9] [0-9]*))
\\basic_number_3 ::= ("" | ("." basic_number_digits{1, -1}))
\\basic_number_4 ::= ("" | ([+\-]))
\\basic_number_5 ::= ("" | ([eE] basic_number_4 basic_number_digits{1, -1}))
\\
\\
},
    .{ .name = "enum_basic", .schema = \\
\\{"enum":["red","green",3,true,null]}
, .expect = \\
\\basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]))
\\basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=([ \n\r\t]* [,}\]:]))
\\basic_any ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer ::= (("0") | (basic_integer_1 [1-9] [0-9]*))
\\basic_number ::= ((basic_number_1 basic_number_2 basic_number_3 basic_number_5))
\\basic_string ::= (("\"" basic_string_sub))
\\basic_boolean ::= (("true") | ("false"))
\\basic_null ::= (("null"))
\\basic_array ::= (("[" basic_any basic_array_items{0, -1} "]") | ("[" "]"))
\\basic_object ::= (("{" basic_string ":" basic_any basic_object_properties{0, -1} "}") | ("{" "}"))
\\basic_number_digits ::= (([0-9]))
\\basic_array_items ::= ((", " basic_any))
\\basic_object_properties ::= ((", " basic_string ":" basic_any))
\\root ::= (("\"red\"") | ("\"green\"") | ("3") | ("true") | ("null"))
\\basic_integer_1 ::= ("" | ("-"))
\\basic_number_1 ::= ("" | ("-"))
\\basic_number_2 ::= (("0") | ([1-9] [0-9]*))
\\basic_number_3 ::= ("" | ("." basic_number_digits{1, -1}))
\\basic_number_4 ::= ("" | ([+\-]))
\\basic_number_5 ::= ("" | ([eE] basic_number_4 basic_number_digits{1, -1}))
\\
\\
},
    .{ .name = "const_basic", .schema = \\
\\{"const":{"a":1,"b":[1,2]}}
, .expect = \\
\\basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]))
\\basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=([ \n\r\t]* [,}\]:]))
\\basic_any ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer ::= (("0") | (basic_integer_1 [1-9] [0-9]*))
\\basic_number ::= ((basic_number_1 basic_number_2 basic_number_3 basic_number_5))
\\basic_string ::= (("\"" basic_string_sub))
\\basic_boolean ::= (("true") | ("false"))
\\basic_null ::= (("null"))
\\basic_array ::= (("[" basic_any basic_array_items{0, -1} "]") | ("[" "]"))
\\basic_object ::= (("{" basic_string ":" basic_any basic_object_properties{0, -1} "}") | ("{" "}"))
\\basic_number_digits ::= (([0-9]))
\\basic_array_items ::= ((", " basic_any))
\\basic_object_properties ::= ((", " basic_string ":" basic_any))
\\root ::= (("{\"a\":1,\"b\":[1,2]}"))
\\basic_integer_1 ::= ("" | ("-"))
\\basic_number_1 ::= ("" | ("-"))
\\basic_number_2 ::= (("0") | ([1-9] [0-9]*))
\\basic_number_3 ::= ("" | ("." basic_number_digits{1, -1}))
\\basic_number_4 ::= ("" | ([+\-]))
\\basic_number_5 ::= ("" | ([eE] basic_number_4 basic_number_digits{1, -1}))
\\
\\
},
    .{ .name = "object_simple", .schema = \\
\\{"type":"object","properties":{"id":{"type":"integer"},"name":{"type":"string"}},"required":["id"]}
, .expect = \\
\\basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]))
\\basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=([ \n\r\t]* [,}\]:]))
\\basic_any ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer ::= (("0") | (basic_integer_1 [1-9] [0-9]*))
\\basic_number ::= ((basic_number_1 basic_number_2 basic_number_3 basic_number_5))
\\basic_string ::= (("\"" basic_string_sub))
\\basic_boolean ::= (("true") | ("false"))
\\basic_null ::= (("null"))
\\basic_array ::= (("[" basic_any basic_array_items{0, -1} "]") | ("[" "]"))
\\basic_object ::= (("{" basic_string ":" basic_any basic_object_properties{0, -1} "}") | ("{" "}"))
\\basic_number_digits ::= (([0-9]))
\\basic_array_items ::= ((", " basic_any))
\\basic_object_properties ::= ((", " basic_string ":" basic_any))
\\root ::= (("{" "\"id\"" ":" basic_integer root_part_0 "}"))
\\root_addl ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\root_addl_key ::= (("\"" root_addl_key_7)) (=([ \n\r\t]* [,}\]:]))
\\root_additional_properties ::= (("," root_addl_key ":" root_addl))
\\root_part_1 ::= ((root_additional_properties{0, -1}))
\\root_part_0 ::= ((root_part_1) | ("," "\"name\"" ":" basic_string root_part_1))
\\basic_integer_1 ::= ("" | ("-"))
\\basic_number_1 ::= ("" | ("-"))
\\basic_number_2 ::= (("0") | ([1-9] [0-9]*))
\\basic_number_3 ::= ("" | ("." basic_number_digits{1, -1}))
\\basic_number_4 ::= ("" | ([+\-]))
\\basic_number_5 ::= ("" | ([eE] basic_number_4 basic_number_digits{1, -1}))
\\root_addl_key_1 ::= (([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub))
\\root_addl_key_2 ::= (("\"") | ([^\0-\x1f\"\\\r\nd] basic_string_sub) | ("\\" basic_escape basic_string_sub) | ("d" root_addl_key_1))
\\root_addl_key_3 ::= (([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub))
\\root_addl_key_4 ::= (("\"") | ([^\0-\x1f\"\\\r\ne] basic_string_sub) | ("\\" basic_escape basic_string_sub) | ("e" root_addl_key_3))
\\root_addl_key_5 ::= (("\"") | ([^\0-\x1f\"\\\r\nm] basic_string_sub) | ("\\" basic_escape basic_string_sub) | ("m" root_addl_key_4))
\\root_addl_key_6 ::= (("\"") | ([^\0-\x1f\"\\\r\na] basic_string_sub) | ("\\" basic_escape basic_string_sub) | ("a" root_addl_key_5))
\\root_addl_key_7 ::= (("\"") | ([^\0-\x1f\"\\\r\nin] basic_string_sub) | ("\\" basic_escape basic_string_sub) | ("i" root_addl_key_2) | ("n" root_addl_key_6))
\\
\\
},
    .{ .name = "object_indent", .indent = 2, .schema = \\
\\{"type":"object","properties":{"a":{"type":"string"},"b":{"type":"integer"}},"required":["a","b"]}
, .expect = \\
\\basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]))
\\basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=([ \n\r\t]* [,}\]:]))
\\basic_any ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer ::= (("0") | (basic_integer_1 [1-9] [0-9]*))
\\basic_number ::= ((basic_number_1 basic_number_2 basic_number_3 basic_number_5))
\\basic_string ::= (("\"" basic_string_sub))
\\basic_boolean ::= (("true") | ("false"))
\\basic_null ::= (("null"))
\\basic_array ::= (("[" basic_any basic_array_items{0, -1} "]") | ("[" "]"))
\\basic_object ::= (("{" basic_string ":" basic_any basic_object_properties{0, -1} "}") | ("{" "}"))
\\basic_number_digits ::= (([0-9]))
\\basic_array_items ::= ((", " basic_any))
\\basic_object_properties ::= ((", " basic_string ":" basic_any))
\\root ::= (("{" "\n  " "\"a\"" ":" basic_string root_part_0 "\n" "}"))
\\root_addl ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\root_addl_key ::= (("\"" root_addl_key_3)) (=([ \n\r\t]* [,}\]:]))
\\root_additional_properties ::= ((",\n  " root_addl_key ":" root_addl))
\\root_part_1 ::= ((root_additional_properties{0, -1}))
\\root_part_0 ::= ((",\n  " "\"b\"" ":" basic_integer root_part_1))
\\basic_integer_1 ::= ("" | ("-"))
\\basic_number_1 ::= ("" | ("-"))
\\basic_number_2 ::= (("0") | ([1-9] [0-9]*))
\\basic_number_3 ::= ("" | ("." basic_number_digits{1, -1}))
\\basic_number_4 ::= ("" | ([+\-]))
\\basic_number_5 ::= ("" | ([eE] basic_number_4 basic_number_digits{1, -1}))
\\root_addl_key_1 ::= (([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub))
\\root_addl_key_2 ::= (([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub))
\\root_addl_key_3 ::= (("\"") | ([^\0-\x1f\"\\\r\nab] basic_string_sub) | ("\\" basic_escape basic_string_sub) | ("a" root_addl_key_1) | ("b" root_addl_key_2))
\\
\\
},
    .{ .name = "object_anyws", .any_whitespace = true, .schema = \\
\\{"type":"object","properties":{"a":{"type":"string"}},"required":["a"]}
, .expect = \\
\\basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]))
\\basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=([ \n\r\t]* [,}\]:]))
\\basic_any ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer ::= (("0") | (basic_integer_1 [1-9] [0-9]*))
\\basic_number ::= ((basic_number_1 basic_number_2 basic_number_3 basic_number_5))
\\basic_string ::= (("\"" basic_string_sub))
\\basic_boolean ::= (("true") | ("false"))
\\basic_null ::= (("null"))
\\basic_array ::= (("[" [ \n\r\t]* basic_any basic_array_items{0, -1} [ \n\r\t]* "]") | ("[" [ \n\r\t]* "]"))
\\basic_object ::= (("{" [ \n\r\t]* basic_string [ \n\r\t]* ":" [ \n\r\t]* basic_any basic_object_properties{0, -1} [ \n\r\t]* "}") | ("{" [ \n\r\t]* "}"))
\\basic_number_digits ::= (([0-9]))
\\basic_array_items ::= (([ \n\r\t]* "," [ \n\r\t]* basic_any))
\\basic_object_properties ::= (([ \n\r\t]* "," [ \n\r\t]* basic_string [ \n\r\t]* ":" [ \n\r\t]* basic_any))
\\root ::= (("{" [ \n\r\t]* "\"a\"" [ \n\r\t]* ":" [ \n\r\t]* basic_string root_part_0 [ \n\r\t]* "}"))
\\root_addl ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\root_addl_key ::= (("\"" root_addl_key_2)) (=([ \n\r\t]* [,}\]:]))
\\root_additional_properties ::= (([ \n\r\t]* "," [ \n\r\t]* root_addl_key [ \n\r\t]* ":" [ \n\r\t]* root_addl))
\\root_part_0 ::= ((root_additional_properties{0, -1}))
\\basic_integer_1 ::= ("" | ("-"))
\\basic_number_1 ::= ("" | ("-"))
\\basic_number_2 ::= (("0") | ([1-9] [0-9]*))
\\basic_number_3 ::= ("" | ("." basic_number_digits{1, -1}))
\\basic_number_4 ::= ("" | ([+\-]))
\\basic_number_5 ::= ("" | ([eE] basic_number_4 basic_number_digits{1, -1}))
\\root_addl_key_1 ::= (([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub))
\\root_addl_key_2 ::= (("\"") | ([^\0-\x1f\"\\\r\na] basic_string_sub) | ("\\" basic_escape basic_string_sub) | ("a" root_addl_key_1))
\\
\\
},
    .{ .name = "object_addl", .schema = \\
\\{"type":"object","properties":{"a":{"type":"integer"}},"additionalProperties":{"type":"string"},"required":["a"]}
, .expect = \\
\\basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]))
\\basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=([ \n\r\t]* [,}\]:]))
\\basic_any ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer ::= (("0") | (basic_integer_1 [1-9] [0-9]*))
\\basic_number ::= ((basic_number_1 basic_number_2 basic_number_3 basic_number_5))
\\basic_string ::= (("\"" basic_string_sub))
\\basic_boolean ::= (("true") | ("false"))
\\basic_null ::= (("null"))
\\basic_array ::= (("[" basic_any basic_array_items{0, -1} "]") | ("[" "]"))
\\basic_object ::= (("{" basic_string ":" basic_any basic_object_properties{0, -1} "}") | ("{" "}"))
\\basic_number_digits ::= (([0-9]))
\\basic_array_items ::= ((", " basic_any))
\\basic_object_properties ::= ((", " basic_string ":" basic_any))
\\root ::= (("{" "\"a\"" ":" basic_integer root_part_0 "}"))
\\root_addl_key ::= (("\"" root_addl_key_2)) (=([ \n\r\t]* [,}\]:]))
\\root_additional_properties ::= (("," root_addl_key ":" basic_string))
\\root_part_0 ::= ((root_additional_properties{0, -1}))
\\basic_integer_1 ::= ("" | ("-"))
\\basic_number_1 ::= ("" | ("-"))
\\basic_number_2 ::= (("0") | ([1-9] [0-9]*))
\\basic_number_3 ::= ("" | ("." basic_number_digits{1, -1}))
\\basic_number_4 ::= ("" | ([+\-]))
\\basic_number_5 ::= ("" | ([eE] basic_number_4 basic_number_digits{1, -1}))
\\root_addl_key_1 ::= (([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub))
\\root_addl_key_2 ::= (("\"") | ([^\0-\x1f\"\\\r\na] basic_string_sub) | ("\\" basic_escape basic_string_sub) | ("a" root_addl_key_1))
\\
\\
},
    .{ .name = "object_pp", .schema = \\
\\{"type":"object","patternProperties":{"^S_":{"type":"string"},"^I_":{"type":"integer"}},"required":[]}
, .expect = \\
\\basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]))
\\basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=([ \n\r\t]* [,}\]:]))
\\basic_any ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer ::= (("0") | (basic_integer_1 [1-9] [0-9]*))
\\basic_number ::= ((basic_number_1 basic_number_2 basic_number_3 basic_number_5))
\\basic_string ::= (("\"" basic_string_sub))
\\basic_boolean ::= (("true") | ("false"))
\\basic_null ::= (("null"))
\\basic_array ::= (("[" basic_any basic_array_items{0, -1} "]") | ("[" "]"))
\\basic_object ::= (("{" basic_string ":" basic_any basic_object_properties{0, -1} "}") | ("{" "}"))
\\basic_number_digits ::= (([0-9]))
\\basic_array_items ::= ((", " basic_any))
\\basic_object_properties ::= ((", " basic_string ":" basic_any))
\\root ::= (("{" root_prop root_properties{0, -1} "}") | ("{" "}"))
\\root_prop_0_key ::= (("\"" root_prop_0_key_1 "\""))
\\root_prop_1_key ::= (("\"" root_prop_1_key_1 "\""))
\\root_prop ::= ((root_prop_0_key ":" basic_string) | (root_prop_1_key ":" basic_integer))
\\root_properties ::= (("," root_prop))
\\basic_integer_1 ::= ("" | ("-"))
\\basic_number_1 ::= ("" | ("-"))
\\basic_number_2 ::= (("0") | ([1-9] [0-9]*))
\\basic_number_3 ::= ("" | ("." basic_number_digits{1, -1}))
\\basic_number_4 ::= ("" | ([+\-]))
\\basic_number_5 ::= ("" | ([eE] basic_number_4 basic_number_digits{1, -1}))
\\root_prop_0_key_1 ::= Regex("^S_", json_string=true)
\\root_prop_1_key_1 ::= Regex("^I_", json_string=true)
\\
\\
},
    .{ .name = "array_items", .schema = \\
\\{"type":"array","items":{"type":"integer"},"minItems":1,"maxItems":3}
, .expect = \\
\\basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]))
\\basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=([ \n\r\t]* [,}\]:]))
\\basic_any ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer ::= (("0") | (basic_integer_1 [1-9] [0-9]*))
\\basic_number ::= ((basic_number_1 basic_number_2 basic_number_3 basic_number_5))
\\basic_string ::= (("\"" basic_string_sub))
\\basic_boolean ::= (("true") | ("false"))
\\basic_null ::= (("null"))
\\basic_array ::= (("[" basic_any basic_array_items{0, -1} "]") | ("[" "]"))
\\basic_object ::= (("{" basic_string ":" basic_any basic_object_properties{0, -1} "}") | ("{" "}"))
\\basic_number_digits ::= (([0-9]))
\\basic_array_items ::= ((", " basic_any))
\\basic_object_properties ::= ((", " basic_string ":" basic_any))
\\root ::= (("[" basic_integer root_items{0, 2} "]"))
\\root_items ::= (("," basic_integer))
\\basic_integer_1 ::= ("" | ("-"))
\\basic_number_1 ::= ("" | ("-"))
\\basic_number_2 ::= (("0") | ([1-9] [0-9]*))
\\basic_number_3 ::= ("" | ("." basic_number_digits{1, -1}))
\\basic_number_4 ::= ("" | ([+\-]))
\\basic_number_5 ::= ("" | ([eE] basic_number_4 basic_number_digits{1, -1}))
\\
\\
},
    .{ .name = "array_prefix", .schema = \\
\\{"prefixItems":[{"type":"string"},{"type":"integer"}],"items":{"type":"boolean"},"minItems":2}
, .expect = \\
\\basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]))
\\basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=([ \n\r\t]* [,}\]:]))
\\basic_any ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer ::= (("0") | (basic_integer_1 [1-9] [0-9]*))
\\basic_number ::= ((basic_number_1 basic_number_2 basic_number_3 basic_number_5))
\\basic_string ::= (("\"" basic_string_sub))
\\basic_boolean ::= (("true") | ("false"))
\\basic_null ::= (("null"))
\\basic_array ::= (("[" basic_any basic_array_items{0, -1} "]") | ("[" "]"))
\\basic_object ::= (("{" basic_string ":" basic_any basic_object_properties{0, -1} "}") | ("{" "}"))
\\basic_number_digits ::= (([0-9]))
\\basic_array_items ::= ((", " basic_any))
\\basic_object_properties ::= ((", " basic_string ":" basic_any))
\\root ::= (("[" basic_string "," basic_integer root_additional_items{0, -1} "]"))
\\root_additional_items ::= (("," basic_boolean))
\\basic_integer_1 ::= ("" | ("-"))
\\basic_number_1 ::= ("" | ("-"))
\\basic_number_2 ::= (("0") | ([1-9] [0-9]*))
\\basic_number_3 ::= ("" | ("." basic_number_digits{1, -1}))
\\basic_number_4 ::= ("" | ([+\-]))
\\basic_number_5 ::= ("" | ([eE] basic_number_4 basic_number_digits{1, -1}))
\\
\\
},
    .{ .name = "ref_root", .schema = \\
\\{"$defs":{"node":{"type":"object","properties":{"next":{"$ref":"#/$defs/node"}},"required":["next"]}},"$ref":"#/$defs/node"}
, .expect = \\
\\basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]))
\\basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=([ \n\r\t]* [,}\]:]))
\\basic_any ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer ::= (("0") | (basic_integer_1 [1-9] [0-9]*))
\\basic_number ::= ((basic_number_1 basic_number_2 basic_number_3 basic_number_5))
\\basic_string ::= (("\"" basic_string_sub))
\\basic_boolean ::= (("true") | ("false"))
\\basic_null ::= (("null"))
\\basic_array ::= (("[" basic_any basic_array_items{0, -1} "]") | ("[" "]"))
\\basic_object ::= (("{" basic_string ":" basic_any basic_object_properties{0, -1} "}") | ("{" "}"))
\\basic_number_digits ::= (([0-9]))
\\basic_array_items ::= ((", " basic_any))
\\basic_object_properties ::= ((", " basic_string ":" basic_any))
\\root ::= ((defs_node))
\\defs_node ::= (("{" "\"next\"" ":" defs_node_prop_0 defs_node_part_0 "}"))
\\defs_node_prop_0 ::= ((defs_node))
\\defs_node_addl ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\defs_node_addl_key ::= (("\"" defs_node_addl_key_5)) (=([ \n\r\t]* [,}\]:]))
\\defs_node_additional_properties ::= (("," defs_node_addl_key ":" defs_node_addl))
\\defs_node_part_0 ::= ((defs_node_additional_properties{0, -1}))
\\basic_integer_1 ::= ("" | ("-"))
\\basic_number_1 ::= ("" | ("-"))
\\basic_number_2 ::= (("0") | ([1-9] [0-9]*))
\\basic_number_3 ::= ("" | ("." basic_number_digits{1, -1}))
\\basic_number_4 ::= ("" | ([+\-]))
\\basic_number_5 ::= ("" | ([eE] basic_number_4 basic_number_digits{1, -1}))
\\defs_node_addl_key_1 ::= (([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub))
\\defs_node_addl_key_2 ::= (("\"") | ([^\0-\x1f\"\\\r\nt] basic_string_sub) | ("\\" basic_escape basic_string_sub) | ("t" defs_node_addl_key_1))
\\defs_node_addl_key_3 ::= (("\"") | ([^\0-\x1f\"\\\r\nx] basic_string_sub) | ("\\" basic_escape basic_string_sub) | ("x" defs_node_addl_key_2))
\\defs_node_addl_key_4 ::= (("\"") | ([^\0-\x1f\"\\\r\ne] basic_string_sub) | ("\\" basic_escape basic_string_sub) | ("e" defs_node_addl_key_3))
\\defs_node_addl_key_5 ::= (("\"") | ([^\0-\x1f\"\\\r\nn] basic_string_sub) | ("\\" basic_escape basic_string_sub) | ("n" defs_node_addl_key_4))
\\
\\
},
    .{ .name = "ref_rec", .schema = \\
\\{"type":"object","properties":{"a":{"$ref":"#"},"b":{"type":"integer"}},"required":["a"]}
, .expect = \\
\\basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]))
\\basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=([ \n\r\t]* [,}\]:]))
\\basic_any ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer ::= (("0") | (basic_integer_1 [1-9] [0-9]*))
\\basic_number ::= ((basic_number_1 basic_number_2 basic_number_3 basic_number_5))
\\basic_string ::= (("\"" basic_string_sub))
\\basic_boolean ::= (("true") | ("false"))
\\basic_null ::= (("null"))
\\basic_array ::= (("[" basic_any basic_array_items{0, -1} "]") | ("[" "]"))
\\basic_object ::= (("{" basic_string ":" basic_any basic_object_properties{0, -1} "}") | ("{" "}"))
\\basic_number_digits ::= (([0-9]))
\\basic_array_items ::= ((", " basic_any))
\\basic_object_properties ::= ((", " basic_string ":" basic_any))
\\root ::= (("{" "\"a\"" ":" root_prop_0 root_part_0 "}"))
\\root_prop_0 ::= ((root))
\\root_addl ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\root_addl_key ::= (("\"" root_addl_key_3)) (=([ \n\r\t]* [,}\]:]))
\\root_additional_properties ::= (("," root_addl_key ":" root_addl))
\\root_part_1 ::= ((root_additional_properties{0, -1}))
\\root_part_0 ::= ((root_part_1) | ("," "\"b\"" ":" basic_integer root_part_1))
\\basic_integer_1 ::= ("" | ("-"))
\\basic_number_1 ::= ("" | ("-"))
\\basic_number_2 ::= (("0") | ([1-9] [0-9]*))
\\basic_number_3 ::= ("" | ("." basic_number_digits{1, -1}))
\\basic_number_4 ::= ("" | ([+\-]))
\\basic_number_5 ::= ("" | ([eE] basic_number_4 basic_number_digits{1, -1}))
\\root_addl_key_1 ::= (([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub))
\\root_addl_key_2 ::= (([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub))
\\root_addl_key_3 ::= (("\"") | ([^\0-\x1f\"\\\r\nab] basic_string_sub) | ("\\" basic_escape basic_string_sub) | ("a" root_addl_key_1) | ("b" root_addl_key_2))
\\
\\
},
    .{ .name = "anyof", .schema = \\
\\{"anyOf":[{"type":"integer"},{"type":"string"}]}
, .expect = \\
\\basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]))
\\basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=([ \n\r\t]* [,}\]:]))
\\basic_any ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer ::= (("0") | (basic_integer_1 [1-9] [0-9]*))
\\basic_number ::= ((basic_number_1 basic_number_2 basic_number_3 basic_number_5))
\\basic_string ::= (("\"" basic_string_sub))
\\basic_boolean ::= (("true") | ("false"))
\\basic_null ::= (("null"))
\\basic_array ::= (("[" basic_any basic_array_items{0, -1} "]") | ("[" "]"))
\\basic_object ::= (("{" basic_string ":" basic_any basic_object_properties{0, -1} "}") | ("{" "}"))
\\basic_number_digits ::= (([0-9]))
\\basic_array_items ::= ((", " basic_any))
\\basic_object_properties ::= ((", " basic_string ":" basic_any))
\\root ::= ((basic_integer) | (basic_string))
\\basic_integer_1 ::= ("" | ("-"))
\\basic_number_1 ::= ("" | ("-"))
\\basic_number_2 ::= (("0") | ([1-9] [0-9]*))
\\basic_number_3 ::= ("" | ("." basic_number_digits{1, -1}))
\\basic_number_4 ::= ("" | ([+\-]))
\\basic_number_5 ::= ("" | ([eE] basic_number_4 basic_number_digits{1, -1}))
\\
\\
},
    .{ .name = "allof_single", .schema = \\
\\{"allOf":[{"type":"string"}]}
, .expect = \\
\\basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]))
\\basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=([ \n\r\t]* [,}\]:]))
\\basic_any ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer ::= (("0") | (basic_integer_1 [1-9] [0-9]*))
\\basic_number ::= ((basic_number_1 basic_number_2 basic_number_3 basic_number_5))
\\basic_string ::= (("\"" basic_string_sub))
\\basic_boolean ::= (("true") | ("false"))
\\basic_null ::= (("null"))
\\basic_array ::= (("[" basic_any basic_array_items{0, -1} "]") | ("[" "]"))
\\basic_object ::= (("{" basic_string ":" basic_any basic_object_properties{0, -1} "}") | ("{" "}"))
\\basic_number_digits ::= (([0-9]))
\\basic_array_items ::= ((", " basic_any))
\\basic_object_properties ::= ((", " basic_string ":" basic_any))
\\root ::= (("\"" basic_string_sub))
\\basic_integer_1 ::= ("" | ("-"))
\\basic_number_1 ::= ("" | ("-"))
\\basic_number_2 ::= (("0") | ([1-9] [0-9]*))
\\basic_number_3 ::= ("" | ("." basic_number_digits{1, -1}))
\\basic_number_4 ::= ("" | ([+\-]))
\\basic_number_5 ::= ("" | ([eE] basic_number_4 basic_number_digits{1, -1}))
\\
\\
},
    .{ .name = "allof_multi", .schema = \\
\\{"allOf":[{"type":"string"},{"type":"integer"}]}
, .expect = \\
\\basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]))
\\basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=([ \n\r\t]* [,}\]:]))
\\basic_any ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer ::= (("0") | (basic_integer_1 [1-9] [0-9]*))
\\basic_number ::= ((basic_number_1 basic_number_2 basic_number_3 basic_number_5))
\\basic_string ::= (("\"" basic_string_sub))
\\basic_boolean ::= (("true") | ("false"))
\\basic_null ::= (("null"))
\\basic_array ::= (("[" basic_any basic_array_items{0, -1} "]") | ("[" "]"))
\\basic_object ::= (("{" basic_string ":" basic_any basic_object_properties{0, -1} "}") | ("{" "}"))
\\basic_number_digits ::= (([0-9]))
\\basic_array_items ::= ((", " basic_any))
\\basic_object_properties ::= ((", " basic_string ":" basic_any))
\\root ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer_1 ::= ("" | ("-"))
\\basic_number_1 ::= ("" | ("-"))
\\basic_number_2 ::= (("0") | ([1-9] [0-9]*))
\\basic_number_3 ::= ("" | ("." basic_number_digits{1, -1}))
\\basic_number_4 ::= ("" | ([+\-]))
\\basic_number_5 ::= ("" | ([eE] basic_number_4 basic_number_digits{1, -1}))
\\
\\
},
    .{ .name = "empty_schema", .schema = \\
\\{}
, .expect = \\
\\basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]))
\\basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=([ \n\r\t]* [,}\]:]))
\\basic_any ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer ::= (("0") | (basic_integer_1 [1-9] [0-9]*))
\\basic_number ::= ((basic_number_1 basic_number_2 basic_number_3 basic_number_5))
\\basic_string ::= (("\"" basic_string_sub))
\\basic_boolean ::= (("true") | ("false"))
\\basic_null ::= (("null"))
\\basic_array ::= (("[" basic_any basic_array_items{0, -1} "]") | ("[" "]"))
\\basic_object ::= (("{" basic_string ":" basic_any basic_object_properties{0, -1} "}") | ("{" "}"))
\\basic_number_digits ::= (([0-9]))
\\basic_array_items ::= ((", " basic_any))
\\basic_object_properties ::= ((", " basic_string ":" basic_any))
\\root ::= ((basic_any))
\\basic_integer_1 ::= ("" | ("-"))
\\basic_number_1 ::= ("" | ("-"))
\\basic_number_2 ::= (("0") | ([1-9] [0-9]*))
\\basic_number_3 ::= ("" | ("." basic_number_digits{1, -1}))
\\basic_number_4 ::= ("" | ([+\-]))
\\basic_number_5 ::= ("" | ([eE] basic_number_4 basic_number_digits{1, -1}))
\\
\\
},
    .{ .name = "bool_schema", .schema = \\
\\true
, .expect = \\
\\basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]))
\\basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=([ \n\r\t]* [,}\]:]))
\\basic_any ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer ::= (("0") | (basic_integer_1 [1-9] [0-9]*))
\\basic_number ::= ((basic_number_1 basic_number_2 basic_number_3 basic_number_5))
\\basic_string ::= (("\"" basic_string_sub))
\\basic_boolean ::= (("true") | ("false"))
\\basic_null ::= (("null"))
\\basic_array ::= (("[" basic_any basic_array_items{0, -1} "]") | ("[" "]"))
\\basic_object ::= (("{" basic_string ":" basic_any basic_object_properties{0, -1} "}") | ("{" "}"))
\\basic_number_digits ::= (([0-9]))
\\basic_array_items ::= ((", " basic_any))
\\basic_object_properties ::= ((", " basic_string ":" basic_any))
\\root ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer_1 ::= ("" | ("-"))
\\basic_number_1 ::= ("" | ("-"))
\\basic_number_2 ::= (("0") | ([1-9] [0-9]*))
\\basic_number_3 ::= ("" | ("." basic_number_digits{1, -1}))
\\basic_number_4 ::= ("" | ([+\-]))
\\basic_number_5 ::= ("" | ([eE] basic_number_4 basic_number_digits{1, -1}))
\\
\\
},
    .{ .name = "email_fmt", .schema = \\
\\{"type":"string","format":"email"}
, .expect = \\
\\basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]))
\\basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=([ \n\r\t]* [,}\]:]))
\\basic_any ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer ::= (("0") | (basic_integer_1 [1-9] [0-9]*))
\\basic_number ::= ((basic_number_1 basic_number_2 basic_number_3 basic_number_5))
\\basic_string ::= (("\"" basic_string_sub))
\\basic_boolean ::= (("true") | ("false"))
\\basic_null ::= (("null"))
\\basic_array ::= (("[" basic_any basic_array_items{0, -1} "]") | ("[" "]"))
\\basic_object ::= (("{" basic_string ":" basic_any basic_object_properties{0, -1} "}") | ("{" "}"))
\\basic_number_digits ::= (([0-9]))
\\basic_array_items ::= ((", " basic_any))
\\basic_object_properties ::= ((", " basic_string ":" basic_any))
\\root ::= (("\"" root_1 "\""))
\\root_1 ::= ((root_7 "@" [A-Za-z0-9] root_5 root_6))
\\root_1_1 ::= (([a-zA-Z0-9_!#$%&\'*+/=\?^`{|}~\-] root_1_1) | ([a-zA-Z0-9_!#$%&\'*+/=\?^`{|}~\-]))
\\root_2 ::= (([a-zA-Z0-9_!#$%&\'*+/=\?^`{|}~\-] root_2) | ([a-zA-Z0-9_!#$%&\'*+/=\?^`{|}~\-]))
\\root_3 ::= ("" | ("." root_2 root_3))
\\root_4 ::= ("" | (root_4_1 root_4))
\\root_5 ::= ("" | ([\-A-Za-z0-9]* [A-Za-z0-9]))
\\root_6 ::= ("" | ("." [A-Za-z0-9] [\-A-Za-z0-9]* [A-Za-z0-9] root_6))
\\root_7 ::= ((root_1_1 root_3) | ("\\" "\"" root_4 "\\" "\""))
\\root_4_1 ::= (("\\" [ -~]) | ([ !#-[\]-~]))
\\basic_integer_1 ::= ("" | ("-"))
\\basic_number_1 ::= ("" | ("-"))
\\basic_number_2 ::= (("0") | ([1-9] [0-9]*))
\\basic_number_3 ::= ("" | ("." basic_number_digits{1, -1}))
\\basic_number_4 ::= ("" | ([+\-]))
\\basic_number_5 ::= ("" | ([eE] basic_number_4 basic_number_digits{1, -1}))
\\
\\
},
    .{ .name = "propnames", .schema = \\
\\{"type":"object","propertyNames":{"type":"string","minLength":1},"minProperties":1}
, .expect = \\
\\basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]))
\\basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=([ \n\r\t]* [,}\]:]))
\\basic_any ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer ::= (("0") | (basic_integer_1 [1-9] [0-9]*))
\\basic_number ::= ((basic_number_1 basic_number_2 basic_number_3 basic_number_5))
\\basic_string ::= (("\"" basic_string_sub))
\\basic_boolean ::= (("true") | ("false"))
\\basic_null ::= (("null"))
\\basic_array ::= (("[" basic_any basic_array_items{0, -1} "]") | ("[" "]"))
\\basic_object ::= (("{" basic_string ":" basic_any basic_object_properties{0, -1} "}") | ("{" "}"))
\\basic_number_digits ::= (([0-9]))
\\basic_array_items ::= ((", " basic_any))
\\basic_object_properties ::= ((", " basic_string ":" basic_any))
\\root ::= (("{" root_prop root_properties{0, -1} "}"))
\\root_name ::= (("\"" root_name_characters{1, -1} "\""))
\\root_name_characters ::= (([^\"\\\r\n]))
\\root_addl ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\root_prop ::= ((root_name ":" root_addl))
\\root_properties ::= (("," root_prop))
\\basic_integer_1 ::= ("" | ("-"))
\\basic_number_1 ::= ("" | ("-"))
\\basic_number_2 ::= (("0") | ([1-9] [0-9]*))
\\basic_number_3 ::= ("" | ("." basic_number_digits{1, -1}))
\\basic_number_4 ::= ("" | ([+\-]))
\\basic_number_5 ::= ("" | ([eE] basic_number_4 basic_number_digits{1, -1}))
\\
\\
},
    .{ .name = "strict_obj", .strict_mode = true, .schema = \\
\\{"type":"object","properties":{"a":{"type":"integer"}},"required":["a"]}
, .expect = \\
\\basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]))
\\basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=([ \n\r\t]* [,}\]:]))
\\basic_any ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer ::= (("0") | (basic_integer_1 [1-9] [0-9]*))
\\basic_number ::= ((basic_number_1 basic_number_2 basic_number_3 basic_number_5))
\\basic_string ::= (("\"" basic_string_sub))
\\basic_boolean ::= (("true") | ("false"))
\\basic_null ::= (("null"))
\\basic_array ::= (("[" basic_any basic_array_items{0, -1} "]") | ("[" "]"))
\\basic_object ::= (("{" basic_string ":" basic_any basic_object_properties{0, -1} "}") | ("{" "}"))
\\basic_number_digits ::= (([0-9]))
\\basic_array_items ::= ((", " basic_any))
\\basic_object_properties ::= ((", " basic_string ":" basic_any))
\\root ::= (("{" "\"a\"" ":" basic_integer "}"))
\\basic_integer_1 ::= ("" | ("-"))
\\basic_number_1 ::= ("" | ("-"))
\\basic_number_2 ::= (("0") | ([1-9] [0-9]*))
\\basic_number_3 ::= ("" | ("." basic_number_digits{1, -1}))
\\basic_number_4 ::= ("" | ([+\-]))
\\basic_number_5 ::= ("" | ([eE] basic_number_4 basic_number_digits{1, -1}))
\\
\\
},
    .{ .name = "required_only", .schema = \\
\\{"type":"object","properties":{"a":{"type":"integer"},"b":{"type":"integer"},"c":{"type":"integer"}},"required":["a","c"]}
, .expect = \\
\\basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]))
\\basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=([ \n\r\t]* [,}\]:]))
\\basic_any ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer ::= (("0") | (basic_integer_1 [1-9] [0-9]*))
\\basic_number ::= ((basic_number_1 basic_number_2 basic_number_3 basic_number_5))
\\basic_string ::= (("\"" basic_string_sub))
\\basic_boolean ::= (("true") | ("false"))
\\basic_null ::= (("null"))
\\basic_array ::= (("[" basic_any basic_array_items{0, -1} "]") | ("[" "]"))
\\basic_object ::= (("{" basic_string ":" basic_any basic_object_properties{0, -1} "}") | ("{" "}"))
\\basic_number_digits ::= (([0-9]))
\\basic_array_items ::= ((", " basic_any))
\\basic_object_properties ::= ((", " basic_string ":" basic_any))
\\root ::= (("{" "\"a\"" ":" basic_integer root_part_0 "}"))
\\root_addl ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\root_addl_key ::= (("\"" root_addl_key_4)) (=([ \n\r\t]* [,}\]:]))
\\root_additional_properties ::= (("," root_addl_key ":" root_addl))
\\root_part_2 ::= ((root_additional_properties{0, -1}))
\\root_part_1 ::= (("," "\"c\"" ":" basic_integer root_part_2))
\\root_part_0 ::= ((root_part_1) | ("," "\"b\"" ":" basic_integer root_part_1))
\\basic_integer_1 ::= ("" | ("-"))
\\basic_number_1 ::= ("" | ("-"))
\\basic_number_2 ::= (("0") | ([1-9] [0-9]*))
\\basic_number_3 ::= ("" | ("." basic_number_digits{1, -1}))
\\basic_number_4 ::= ("" | ([+\-]))
\\basic_number_5 ::= ("" | ([eE] basic_number_4 basic_number_digits{1, -1}))
\\root_addl_key_1 ::= (([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub))
\\root_addl_key_2 ::= (([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub))
\\root_addl_key_3 ::= (([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub))
\\root_addl_key_4 ::= (("\"") | ([^\0-\x1f\"\\\r\nabc] basic_string_sub) | ("\\" basic_escape basic_string_sub) | ("a" root_addl_key_1) | ("b" root_addl_key_2) | ("c" root_addl_key_3))
\\
\\
},
    .{ .name = "typearr_empty", .schema = \\
\\{"type":[]}
, .expect = \\
\\basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]))
\\basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=([ \n\r\t]* [,}\]:]))
\\basic_any ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer ::= (("0") | (basic_integer_1 [1-9] [0-9]*))
\\basic_number ::= ((basic_number_1 basic_number_2 basic_number_3 basic_number_5))
\\basic_string ::= (("\"" basic_string_sub))
\\basic_boolean ::= (("true") | ("false"))
\\basic_null ::= (("null"))
\\basic_array ::= (("[" basic_any basic_array_items{0, -1} "]") | ("[" "]"))
\\basic_object ::= (("{" basic_string ":" basic_any basic_object_properties{0, -1} "}") | ("{" "}"))
\\basic_number_digits ::= (([0-9]))
\\basic_array_items ::= ((", " basic_any))
\\basic_object_properties ::= ((", " basic_string ":" basic_any))
\\root ::= ((basic_any))
\\basic_integer_1 ::= ("" | ("-"))
\\basic_number_1 ::= ("" | ("-"))
\\basic_number_2 ::= (("0") | ([1-9] [0-9]*))
\\basic_number_3 ::= ("" | ("." basic_number_digits{1, -1}))
\\basic_number_4 ::= ("" | ([+\-]))
\\basic_number_5 ::= ("" | ([eE] basic_number_4 basic_number_digits{1, -1}))
\\
\\
},
    .{ .name = "nested", .indent = 2, .schema = \\
\\{"type":"object","properties":{"list":{"type":"array","items":{"type":"object","properties":{"x":{"type":"number"}}}}},"required":["list"]}
, .expect = \\
\\basic_escape ::= (([\"\\/bfnrt]) | ("u" [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9] [A-Fa-f0-9]))
\\basic_string_sub ::= (("\"") | ([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub)) (=([ \n\r\t]* [,}\]:]))
\\basic_any ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\basic_integer ::= (("0") | (basic_integer_1 [1-9] [0-9]*))
\\basic_number ::= ((basic_number_1 basic_number_2 basic_number_3 basic_number_5))
\\basic_string ::= (("\"" basic_string_sub))
\\basic_boolean ::= (("true") | ("false"))
\\basic_null ::= (("null"))
\\basic_array ::= (("[" basic_any basic_array_items{0, -1} "]") | ("[" "]"))
\\basic_object ::= (("{" basic_string ":" basic_any basic_object_properties{0, -1} "}") | ("{" "}"))
\\basic_number_digits ::= (([0-9]))
\\basic_array_items ::= ((", " basic_any))
\\basic_object_properties ::= ((", " basic_string ":" basic_any))
\\root ::= (("{" "\n  " "\"list\"" ":" root_prop_0 root_part_0 "\n" "}"))
\\root_prop_0 ::= (("[" "\n    " root_prop_0_additional root_prop_0_items{0, -1} "\n  " "]") | ("[" "]"))
\\root_prop_0_additional ::= (("{" "\n      " root_prop_0_additional_1 "\n    " "}") | ("{" "}"))
\\root_prop_0_additional_addl ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\root_prop_0_additional_addl_key ::= (("\"" root_prop_0_additional_addl_key_2)) (=([ \n\r\t]* [,}\]:]))
\\root_prop_0_additional_additional_properties ::= ((",\n      " root_prop_0_additional_addl_key ":" root_prop_0_additional_addl))
\\root_prop_0_additional_part_0 ::= ((root_prop_0_additional_additional_properties{0, -1}))
\\root_prop_0_items ::= ((",\n    " root_prop_0_additional))
\\root_addl ::= ((basic_number) | (basic_string) | (basic_boolean) | (basic_null) | (basic_array) | (basic_object))
\\root_addl_key ::= (("\"" root_addl_key_5)) (=([ \n\r\t]* [,}\]:]))
\\root_additional_properties ::= ((",\n  " root_addl_key ":" root_addl))
\\root_part_0 ::= ((root_additional_properties{0, -1}))
\\basic_integer_1 ::= ("" | ("-"))
\\basic_number_1 ::= ("" | ("-"))
\\basic_number_2 ::= (("0") | ([1-9] [0-9]*))
\\basic_number_3 ::= ("" | ("." basic_number_digits{1, -1}))
\\basic_number_4 ::= ("" | ([+\-]))
\\basic_number_5 ::= ("" | ([eE] basic_number_4 basic_number_digits{1, -1}))
\\root_prop_0_additional_1 ::= (("\"x\"" ":" basic_number root_prop_0_additional_part_0) | (root_prop_0_additional_addl_key ":" root_prop_0_additional_addl root_prop_0_additional_part_0))
\\root_prop_0_additional_addl_key_1 ::= (([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub))
\\root_prop_0_additional_addl_key_2 ::= (("\"") | ([^\0-\x1f\"\\\r\nx] basic_string_sub) | ("\\" basic_escape basic_string_sub) | ("x" root_prop_0_additional_addl_key_1))
\\root_addl_key_1 ::= (([^\0-\x1f\"\\\r\n] basic_string_sub) | ("\\" basic_escape basic_string_sub))
\\root_addl_key_2 ::= (("\"") | ([^\0-\x1f\"\\\r\nt] basic_string_sub) | ("\\" basic_escape basic_string_sub) | ("t" root_addl_key_1))
\\root_addl_key_3 ::= (("\"") | ([^\0-\x1f\"\\\r\ns] basic_string_sub) | ("\\" basic_escape basic_string_sub) | ("s" root_addl_key_2))
\\root_addl_key_4 ::= (("\"") | ([^\0-\x1f\"\\\r\ni] basic_string_sub) | ("\\" basic_escape basic_string_sub) | ("i" root_addl_key_3))
\\root_addl_key_5 ::= (("\"") | ([^\0-\x1f\"\\\r\nl] basic_string_sub) | ("\\" basic_escape basic_string_sub) | ("l" root_addl_key_4))
\\
},
};


fn expect_snapshot(expected: []const u8, got: []const u8) !void {
    try std.testing.expectEqualStrings(std.mem.trim(u8, expected, "\n\r \t"), std.mem.trim(u8, got, "\n\r \t"));
}

test "range_regex integer goldens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (int_range_cases) |c| {
        const got = try range_regex.generate_range_regex(arena.allocator(), c.s, c.e);
        defer arena.allocator().free(got);
        expect_snapshot(c.expect, got) catch |err| {
            std.debug.print("int range {?d}..{?d}\n got: {s}\nwant: {s}\n", .{ c.s, c.e, got, c.expect });
            return err;
        };
    }
}

test "range_regex float goldens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (float_range_cases) |c| {
        const got = if (c.xs or c.xe)
            try range_regex.generate_float_range_regex_with_options(arena.allocator(), c.s, c.e, c.xs, c.xe)
        else
            try range_regex.generate_float_range_regex(arena.allocator(), c.s, c.e);
        defer arena.allocator().free(got);
        expect_snapshot(c.expect, got) catch |err| {
            std.debug.print("float range {?d}..{?d}\n got: {s}\nwant: {s}\n", .{ c.s, c.e, got, c.expect });
            return err;
        };
    }
}

test "json_schema_to_ebnf goldens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    for (schema_cases) |c| {
        const got = try json_schema_converter.json_schema_to_ebnf(
            gpa,
            c.schema,
            c.any_whitespace,
            c.indent,
            .{ .item = ",", .colon = ":" },
            c.strict_mode,
            null,
            .Json,
            c.any_order,
            &.{},
            null,
        );
        defer gpa.free(got);
        expect_snapshot(c.expect, got) catch |err| {
            std.debug.print("case {s}\n got:\n{s}\nwant:\n{s}\n", .{ c.name, got, c.expect });
            return err;
        };
    }
}

test "xml tool calling formats and leak checks" {
    const gpa = std.testing.allocator;
    const schema =
        \\{"type":"object","properties":{"name":{"type":"string"},"count":{"type":"integer"},"tags":{"type":"array","items":{"type":"string"}}},"required":["name","count"],"additionalProperties":false}
    ;
    const formats = [_]JsonFormat{
        .Json,
        .QwenXml,
        .MiniMaxXml,
        .DeepSeekXml,
        .DeepSeekV41Xml,
        .GlmXml,
        .CohereXml,
        .KimiK3Xml,
        .MiniMaxM3Xml,
    };
    for (formats) |fmt| {
        const ebnf = try json_schema_converter.json_schema_to_ebnf(
            gpa,
            schema,
            true,
            null,
            null,
            true,
            null,
            fmt,
            false,
            &.{},
            null,
        );
        defer gpa.free(ebnf);
        try std.testing.expect(ebnf.len > 0);
        switch (fmt) {
            .QwenXml => try std.testing.expect(std.mem.indexOf(u8, ebnf, "<parameter=name") != null),
            .MiniMaxXml => try std.testing.expect(std.mem.indexOf(u8, ebnf, "<parameter name=\\\"name") != null),
            .DeepSeekXml => try std.testing.expect(std.mem.indexOf(u8, ebnf, "DSML") != null),
            .DeepSeekV41Xml => try std.testing.expect(std.mem.indexOf(u8, ebnf, "DSML") != null),
            .GlmXml => try std.testing.expect(std.mem.indexOf(u8, ebnf, "<arg_key>") != null),
            .CohereXml => try std.testing.expect(std.mem.indexOf(u8, ebnf, "<cofl:value") != null),
            .KimiK3Xml => try std.testing.expect(std.mem.indexOf(u8, ebnf, "<|open|>argument") != null),
            .MiniMaxM3Xml => try std.testing.expect(std.mem.indexOf(u8, ebnf, "]<]minimax[>[<name>") != null),
            .Json => try std.testing.expect(std.mem.indexOf(u8, ebnf, "root ::=") != null),
        }
    }
}

test "structural tag converter smoke and leak check" {
    const gpa = std.testing.allocator;
    const structural_tag_converter = @import("structural_tag_converter.zig");
    const printer = @import("../grammar/printer.zig");
    const stag =
        \\{"type":"structural_tag","format":{"type":"triggered_tags","triggers":["<call>"],"tags":[{"begin":"<call>","content":{"type":"json_schema","json_schema":{"type":"object","properties":{"x":{"type":"integer"}},"required":["x"],"additionalProperties":false}},"end":"</call>"}]}}
    ;
    const grammar = try structural_tag_converter.from_structural_tag(gpa, stag, null);
    defer grammar.deinit();
    const ebnf = try printer.to_string_ebnf(grammar, gpa);
    defer gpa.free(ebnf);
    try std.testing.expect(std.mem.indexOf(u8, ebnf, "TagDispatch") != null);
    try std.testing.expect(std.mem.indexOf(u8, ebnf, "<call>") != null);
}
