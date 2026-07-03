const std = @import("std");

/// Hands out `u32` entity ids for a generated `sqrrl__name`, recycling freed
/// ids instead of growing `next_id` forever. This is the only thing that
/// decides which id a new entity gets — `Rel.put`/`update` and
/// `O2O`/`M2O`/`M2M` trust whatever id they're given and never validate its
/// provenance themselves.
pub const sqrrl___IdAllocator = struct {
    allocator: std.mem.Allocator,
    next_id: u32 = 0,
    free_list: std.ArrayList(u32) = .empty,
    live: std.bit_set.Dynamic = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.free_list.deinit(self.allocator);
        self.live.deinit(self.allocator);
    }

    /// Allocate an id: a recycled one if any are free, otherwise the next
    /// id that's never been handed out before.
    pub fn alloc(self: *Self) !u32 {
        const id = self.free_list.pop() orelse blk: {
            const id = self.next_id;
            self.next_id += 1;
            break :blk id;
        };
        if (id >= self.live.bit_length) {
            try self.live.resize(self.allocator, id + 1, false);
        }
        self.live.set(id);
        return id;
    }

    /// Release id back to the free list for reuse. Errors if id isn't
    /// currently allocated — a double free, or a bug in the caller.
    pub fn free(self: *Self, id: u32) !void {
        if (!self.isLive(id)) return error.IdNotAllocated;
        self.live.unset(id);
        try self.free_list.append(self.allocator, id);
    }

    pub fn isLive(self: *const Self, id: u32) bool {
        return id < self.live.bit_length and self.live.isSet(id);
    }
};

test "IdAllocator basic alloc/free" {
    var ids = sqrrl___IdAllocator.init(std.testing.allocator);
    defer ids.deinit();

    try std.testing.expectEqual(@as(u32, 0), try ids.alloc());
    try std.testing.expectEqual(@as(u32, 1), try ids.alloc());
    try std.testing.expectEqual(@as(u32, 2), try ids.alloc());
    try std.testing.expect(ids.isLive(0));
    try std.testing.expect(ids.isLive(1));
    try std.testing.expect(ids.isLive(2));
}

test "IdAllocator recycles freed ids" {
    var ids = sqrrl___IdAllocator.init(std.testing.allocator);
    defer ids.deinit();

    _ = try ids.alloc(); // 0
    _ = try ids.alloc(); // 1
    _ = try ids.alloc(); // 2

    try ids.free(1);
    try std.testing.expect(!ids.isLive(1));

    const recycled = try ids.alloc();
    try std.testing.expectEqual(@as(u32, 1), recycled);
    try std.testing.expect(ids.isLive(1));

    // 1 is taken again now; the next fresh id continues from next_id, not 0.
    try std.testing.expectEqual(@as(u32, 3), try ids.alloc());
}

test "IdAllocator double free errors" {
    var ids = sqrrl___IdAllocator.init(std.testing.allocator);
    defer ids.deinit();

    _ = try ids.alloc(); // 0
    try ids.free(0);
    try std.testing.expectError(error.IdNotAllocated, ids.free(0));
    try std.testing.expectError(error.IdNotAllocated, ids.free(99)); // never allocated
}
