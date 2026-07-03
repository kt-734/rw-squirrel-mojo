const std = @import("std");

pub const O2O = @import("squirrel_runtime/O2O.zig").O2O;
pub const M2O = @import("squirrel_runtime/M2O.zig").M2O;
pub const M2M = @import("squirrel_runtime/M2M.zig").M2M;
pub const sqrrl___Rel = @import("squirrel_runtime/Rel.zig").sqrrl___Rel;
pub const sqrrl___OwnedSliceRel = @import("squirrel_runtime/Rel.zig").sqrrl___OwnedSliceRel;
pub const sqrrl___RefCount = @import("squirrel_runtime/RefCount.zig").sqrrl___RefCount;
pub const sqrrl___increfAll = @import("squirrel_runtime/RefWalk.zig").sqrrl___increfAll;
pub const sqrrl___decrefAll = @import("squirrel_runtime/RefWalk.zig").sqrrl___decrefAll;
pub const sqrrl___IdAllocator = @import("squirrel_runtime/IdAllocator.zig").sqrrl___IdAllocator;

test "O2O" {
    var map = O2O(u32, u32).init(std.heap.page_allocator);
    defer map.deinit();

    try map.put(1, 10);
    try map.put(2, 20);
    try map.put(3, 30);

    try std.testing.expect(map.getFwd(1) == 10);
    try std.testing.expect(map.getBwd(20) == 2);

    try map.put(1, 100); // replace mapping for 1
    try std.testing.expect(map.getFwd(1) == 100);
    try std.testing.expect(map.getBwd(10) == null); // old mapping removed

    _ = map.fetchRemoveFwd(2);
    try std.testing.expect(map.getFwd(2) == null);
    try std.testing.expect(map.getBwd(20) == null);
}