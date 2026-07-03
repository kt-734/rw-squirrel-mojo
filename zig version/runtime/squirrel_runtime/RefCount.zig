const std = @import("std");

/// Per-table reference count array, indexed by entity id (parallel to the
/// `sqrrl___IdAllocator` and the field `sqrrl___Rel`s). Each entity starts
/// at 0 when created; the caller must call `incref` whenever a new reference
/// is made (relation field `put`/`update`, or the auto-generated incref+defer
/// emitted after a standalone `var/const @@name = @@Type{...}`). `decref`
/// returns the new count; when it hits 0 the table fires `sqrrl___destroy_inner`.
pub const sqrrl___RefCount = struct {
    allocator: std.mem.Allocator,
    counts: std.ArrayList(u32),

    pub fn init(allocator: std.mem.Allocator) @This() {
        return .{ .allocator = allocator, .counts = .empty };
    }

    pub fn deinit(self: *@This()) void {
        self.counts.deinit(self.allocator);
    }

    /// Called once per entity at `sqrrl___create` time. Fresh ids from
    /// `sqrrl___IdAllocator` are strictly sequential, so a new id is always
    /// exactly `counts.len` (one past the end) — panics if the id is further
    /// ahead, since that indicates a skipped id (allocator bug). Recycled ids
    /// are already within bounds and just reset to 0 for the new lifecycle.
    pub fn ensureSlot(self: *@This(), id: u32) !void {
        if (id == self.counts.items.len) {
            try self.counts.append(self.allocator, 0);
        } else if (id < self.counts.items.len) {
            self.counts.items[id] = 0; // recycled id — reset for reuse
        } else {
            @panic("sqrrl___RefCount.ensureSlot: id out of sequence");
        }
    }

    /// Increment `id`'s count. Only valid after `ensureSlot(id)` has been
    /// called — panics if the slot does not exist (programming error). Does
    /// not allocate.
    pub fn incref(self: *@This(), id: u32) void {
        if (id >= self.counts.items.len)
            @panic("sqrrl___RefCount.incref: ensureSlot not called for this id");
        self.counts.items[id] += 1;
    }

    /// Decrement and return the new count. Panics if `id` is out of bounds
    /// or the count is already 0 (decref without a matching incref, or
    /// double-decref — both are programming errors).
    pub fn decref(self: *@This(), id: u32) u32 {
        if (id >= self.counts.items.len or self.counts.items[id] == 0)
            @panic("sqrrl___RefCount.decref: decref without matching incref");
        self.counts.items[id] -= 1;
        return self.counts.items[id];
    }
};

test "RefCount ensureSlot + incref/decref" {
    var rc = sqrrl___RefCount.init(std.testing.allocator);
    defer rc.deinit();
    try rc.ensureSlot(0); // fresh id 0
    rc.incref(0);
    rc.incref(0);
    try std.testing.expectEqual(@as(u32, 2), rc.counts.items[0]);
    try std.testing.expectEqual(@as(u32, 1), rc.decref(0));
    try std.testing.expectEqual(@as(u32, 0), rc.decref(0));
}

test "RefCount ensureSlot resets recycled id to 0" {
    var rc = sqrrl___RefCount.init(std.testing.allocator);
    defer rc.deinit();
    try rc.ensureSlot(0);
    rc.incref(0);
    _ = rc.decref(0);
    try rc.ensureSlot(0); // id 0 recycled — must reset to 0
    try std.testing.expectEqual(@as(u32, 0), rc.counts.items[0]);
}

test "RefCount sequential ids" {
    var rc = sqrrl___RefCount.init(std.testing.allocator);
    defer rc.deinit();
    try rc.ensureSlot(0); // 0 == counts.len (0)
    try rc.ensureSlot(1); // 1 == counts.len (1)
    try rc.ensureSlot(2); // 2 == counts.len (2)
    rc.incref(1);
    try std.testing.expectEqual(@as(u32, 0), rc.counts.items[0]);
    try std.testing.expectEqual(@as(u32, 1), rc.counts.items[1]);
}
