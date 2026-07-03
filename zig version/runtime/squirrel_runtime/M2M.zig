const std = @import("std");

/// Many-to-many bidirectional map.
pub fn M2M(comptime A: type, comptime B: type) type {
    return struct {
        allocator: std.mem.Allocator,
        fwd: std.AutoHashMap(A, std.ArrayList(B)),
        bwd: std.AutoHashMap(B, std.ArrayList(A)),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .fwd = std.AutoHashMap(A, std.ArrayList(B)).init(allocator),
                .bwd = std.AutoHashMap(B, std.ArrayList(A)).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            var fi = self.fwd.valueIterator();
            while (fi.next()) |list| list.deinit(self.allocator);
            var bi = self.bwd.valueIterator();
            while (bi.next()) |list| list.deinit(self.allocator);
            self.fwd.deinit();
            self.bwd.deinit();
        }

        /// Add a single A↔B link (idempotent — duplicate links are not checked).
        pub fn put(self: *Self, a: A, b: B) !void {
            const fe = try self.fwd.getOrPut(a);
            if (!fe.found_existing) fe.value_ptr.* = .empty;
            try fe.value_ptr.append(self.allocator, b);

            const be = try self.bwd.getOrPut(b);
            if (!be.found_existing) be.value_ptr.* = .empty;
            try be.value_ptr.append(self.allocator, a);
        }

        /// Remove one A↔B link; returns true if the link existed.
        pub fn fetchRemoveLink(self: *Self, a: A, b: B) bool {
            const removed = removeFrom(B, self.fwd.getPtr(a), b);
            _ = removeFrom(A, self.bwd.getPtr(b), a);
            return removed;
        }

        /// Remove all links from A; returns the slice of Bs it was linked to, or null.
        pub fn fetchRemoveFwd(self: *Self, a: A) ?[]B {
            const e = self.fwd.fetchRemove(a) orelse return null;
            for (e.value.items) |b| _ = removeFrom(A, self.bwd.getPtr(b), a);
            var list = e.value;
            return list.toOwnedSlice(self.allocator) catch null;
        }

        /// Remove all links to B; returns the slice of As linked to it, or null.
        pub fn fetchRemoveBwd(self: *Self, b: B) ?[]A {
            const e = self.bwd.fetchRemove(b) orelse return null;
            for (e.value.items) |a| _ = removeFrom(B, self.fwd.getPtr(a), b);
            var list = e.value;
            return list.toOwnedSlice(self.allocator) catch null;
        }

        pub fn getFwd(self: *const Self, a: A) []const B {
            if (self.fwd.get(a)) |list| return list.items;
            return &.{};
        }

        pub fn getBwd(self: *const Self, b: B) []const A {
            if (self.bwd.get(b)) |list| return list.items;
            return &.{};
        }

        fn removeFrom(comptime T: type, list_ptr: ?*std.ArrayList(T), val: T) bool {
            const list = list_ptr orelse return false;
            for (list.items, 0..) |item, i| {
                if (std.meta.eql(item, val)) { _ = list.swapRemove(i); return true; }
            }
            return false;
        }
    };
}
