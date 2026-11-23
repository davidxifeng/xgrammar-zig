const sup = @import("../src/support/mod.zig");
pub fn main() void { _ = sup; }
test "x" { var a: sup.Compact2dArray(i32) = try sup.Compact2dArray(i32).init(std.heap.page_allocator); defer a.deinit(); _ = try a.push_row_noncontiguous(7, &.{1,2}); if (a.row(0)[0] != 7) return error.Bad; }
const std = @import("std");
