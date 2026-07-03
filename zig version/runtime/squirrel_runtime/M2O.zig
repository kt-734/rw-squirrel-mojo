const std = @import("std");

/// Many-to-one bidirectional map. Many As map to one B; each B indexes all its As.
pub fn M2O(comptime A: type, comptime B: type) type {
    return struct {
        allocator: std.mem.Allocator,
        fwd: std.AutoHashMap(A, B),
        bwd: std.AutoHashMap(B, std.ArrayList(A)),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .fwd = std.AutoHashMap(A, B).init(allocator),
                .bwd = std.AutoHashMap(B, std.ArrayList(A)).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.bwd.valueIterator();
            while (it.next()) |list| list.deinit(self.allocator);
            self.bwd.deinit();
            self.fwd.deinit();
        }

        /// Map A → B.  If A was already mapped, it is moved from its old B bucket.
        pub fn put(self: *Self, a: A, b: B) !void {
            if (self.fwd.get(a)) |old_b| self.removeFromBucket(old_b, a);
            try self.fwd.put(a, b);
            const entry = try self.bwd.getOrPut(b);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(self.allocator, a);
        }

        /// Remove A and its mapping; returns the B it was mapped to, or null.
        pub fn fetchRemoveFwd(self: *Self, a: A) ?B {
            const e = self.fwd.fetchRemove(a) orelse return null;
            self.removeFromBucket(e.value, a);
            return e.value;
        }

        pub fn getFwd(self: *const Self, a: A) ?B { return self.fwd.get(a); }

        /// All As currently mapped to B (empty slice if none).
        pub fn getBwd(self: *const Self, b: B) []const A {
            if (self.bwd.get(b)) |list| return list.items;
            return &.{};
        }

        /// All As sharing the same B as `a`, including `a` itself.
        pub fn getSiblings(self: *const Self, a: A) []const A {
            const b = self.getFwd(a) orelse return &.{};
            return self.getBwd(b);
        }

        fn removeFromBucket(self: *Self, b: B, a: A) void {
            const list = self.bwd.getPtr(b).?;
            for (list.items, 0..) |item, i| {
                if (std.meta.eql(item, a)) { _ = list.swapRemove(i); break; }
            }
        }
    };
}
