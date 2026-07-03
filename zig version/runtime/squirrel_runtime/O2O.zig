const std = @import("std");

/// One-to-one bidirectional map. Each A maps to exactly one B and vice versa.
pub fn O2O(comptime A: type, comptime B: type) type {
    return struct {
        fwd: std.AutoHashMap(A, B),
        bwd: std.AutoHashMap(B, A),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .fwd = std.AutoHashMap(A, B).init(allocator),
                .bwd = std.AutoHashMap(B, A).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.fwd.deinit();
            self.bwd.deinit();
        }

        /// Insert or replace the A↔B pair.
        /// Any prior mapping from A or to B is evicted first.
        pub fn put(self: *Self, a: A, b: B) !void {
            if (self.fwd.get(a)) |old_b| _ = self.bwd.remove(old_b);
            if (self.bwd.get(b)) |old_a| _ = self.fwd.remove(old_a);
            try self.fwd.put(a, b);
            try self.bwd.put(b, a);
        }

        /// Remove by A; returns the associated B, or null if A was not present.
        pub fn fetchRemoveFwd(self: *Self, a: A) ?B {
            const e = self.fwd.fetchRemove(a) orelse return null;
            _ = self.bwd.remove(e.value);
            return e.value;
        }

        /// Remove by B; returns the associated A, or null if B was not present.
        pub fn fetchRemoveBwd(self: *Self, b: B) ?A {
            const e = self.bwd.fetchRemove(b) orelse return null;
            _ = self.fwd.remove(e.value);
            return e.value;
        }

        pub fn getFwd(self: *const Self, a: A) ?B { return self.fwd.get(a); }
        pub fn getBwd(self: *const Self, b: B) ?A { return self.bwd.get(b); }
    };
}
