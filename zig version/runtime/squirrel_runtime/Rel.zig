const std = @import("std");

/// Per-field relation for a generated `@@struct`: `fwd` is a dense array
/// indexed by entity id (O(1), no hashing needed since ids are sequential
/// u32s); `bwd` maps a field value back to every entity currently holding it.
///
/// `EntityType` is the owning table's `sqrrl___Entity` — a struct with a
/// `sqrrl___id: u32` field. The public API takes/returns entity handles
/// instead of bare u32s; a comptime assertion enforces the requirement.
///
/// `Rel` does not generate or recycle ids — that's `sqrrl__name`'s job.
/// `put` only accepts entities that don't already hold a value (it errors
/// otherwise, to catch `sqrrl__name` id-recycling bugs); a genuinely new id
/// beyond the current length silently grows `fwd` to fit.
///
/// The `bwd` key strategy is chosen per `FieldType`:
///   - `[]const u8` hashes/compares the string's bytes (`StringContext`).
///   - floats hash/compare their raw bit pattern (`FloatBitcastContext`),
///     since the default auto-hasher refuses floats outright.
///   - everything else uses the normal auto context.
/// Asserts at comptime that `T` is a valid entity handle type — a struct with
/// a `sqrrl___id: u32` field. Both `sqrrl___Rel` and `sqrrl___OwnedSliceRel`
/// call this so the requirement is checked once, in one place.
fn assertEntityType(comptime T: type) void {
    if (!@hasField(T, "sqrrl___id"))
        @compileError(@typeName(T) ++ " must have field `sqrrl___id: u32`");
    const s = @typeInfo(T).@"struct";
    for (s.field_names, s.field_types) |fname, ftype| {
        if (std.mem.eql(u8, fname, "sqrrl___id") and ftype != u32)
            @compileError(@typeName(T) ++ ".sqrrl___id must be u32, found " ++ @typeName(ftype));
    }
}

pub fn sqrrl___Rel(comptime EntityType: type, comptime FieldType: type) type {
    comptime assertEntityType(EntityType);

    const BwdMap = std.HashMap(FieldType, std.ArrayList(EntityType), BwdContext(FieldType), std.hash_map.default_max_load_percentage);

    return struct {
        allocator: std.mem.Allocator,
        fwd: std.ArrayList(?FieldType),
        bwd: BwdMap,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .fwd = .empty,
                .bwd = BwdMap.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.bwd.valueIterator();
            while (it.next()) |list| list.deinit(self.allocator);
            self.bwd.deinit();
            self.fwd.deinit(self.allocator);
        }

        /// Set entity's field value for the first time. Errors if entity
        /// already holds a value (call `update` instead) — ids are owned by
        /// `sqrrl__name`, so a collision here means its allocator handed out
        /// an id that's still in use. A never-before-seen id silently grows
        /// `fwd` to fit.
        pub fn put(self: *Self, entity: EntityType, value: FieldType) !void {
            const id = entity.sqrrl___id;
            if (id >= self.fwd.items.len) {
                try self.fwd.appendNTimes(self.allocator, null, id + 1 - self.fwd.items.len);
            } else if (self.fwd.items[id] != null) {
                return error.IdAlreadyExists;
            }
            self.fwd.items[id] = value;
            try self.addToBucket(value, entity);
        }

        /// Replace entity's existing field value. Errors if entity doesn't
        /// currently hold one (call `put` instead).
        pub fn update(self: *Self, entity: EntityType, value: FieldType) !void {
            const id = entity.sqrrl___id;
            if (id >= self.fwd.items.len or self.fwd.items[id] == null) {
                return error.IdNotFound;
            }
            self.removeFromBucket(self.fwd.items[id].?, entity);
            self.fwd.items[id] = value;
            try self.addToBucket(value, entity);
        }

        pub fn getFwd(self: *const Self, entity: EntityType) ?FieldType {
            const id = entity.sqrrl___id;
            if (id >= self.fwd.items.len) return null;
            return self.fwd.items[id];
        }

        /// All entities currently holding `value` (empty slice if none).
        pub fn getBwd(self: *const Self, value: FieldType) []const EntityType {
            if (self.bwd.get(value)) |list| return list.items;
            return &.{};
        }

        /// Clear entity's field value; returns the value it held, or null.
        pub fn fetchRemoveFwd(self: *Self, entity: EntityType) ?FieldType {
            const id = entity.sqrrl___id;
            if (id >= self.fwd.items.len) return null;
            const old = self.fwd.items[id] orelse return null;
            self.removeFromBucket(old, entity);
            self.fwd.items[id] = null;
            return old;
        }

        fn addToBucket(self: *Self, value: FieldType, entity: EntityType) !void {
            const entry = try self.bwd.getOrPut(value);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(self.allocator, entity);
        }

        fn removeFromBucket(self: *Self, value: FieldType, entity: EntityType) void {
            const list = self.bwd.getPtr(value) orelse return;
            for (list.items, 0..) |item, i| {
                if (item.sqrrl___id == entity.sqrrl___id) {
                    _ = list.swapRemove(i);
                    break;
                }
            }
        }
    };
}

/// Returns the correct bwd hash/eql context for `FieldType`:
///   - `[]const u8` → `StringContext` (content comparison)
///   - float → `FloatBitcastContext` (bitwise equality, so +0.0 ≠ -0.0)
///   - struct → `RecursiveContext` (walks each field, dispatching the same
///     rules recursively so a struct containing a string or float field is
///     handled correctly rather than falling through to `AutoContext`, which
///     would hash a `[]const u8` field's slice HEADER instead of its content)
///   - everything else → `AutoContext`
fn BwdContext(comptime FieldType: type) type {
    if (FieldType == []const u8) return std.hash_map.StringContext;
    return switch (@typeInfo(FieldType)) {
        .float => FloatBitcastContext(FieldType),
        .@"struct" => RecursiveContext(FieldType),
        else => std.hash_map.AutoContext(FieldType),
    };
}

/// Hashes/compares a float by its raw bit pattern rather than IEEE-754 value
/// equality. This means +0.0 and -0.0 are distinct keys, and any given NaN
/// bit pattern is reflexively equal to itself (unlike `==`) — a deliberate
/// departure from float semantics, but the only way to get O(1) float keys.
fn FloatBitcastContext(comptime F: type) type {
    const Bits = @Int(.unsigned, @bitSizeOf(F));
    const IntContext = std.hash_map.AutoContext(Bits);

    return struct {
        pub fn hash(self: @This(), key: F) u64 {
            _ = self;
            return (IntContext{}).hash(@bitCast(key));
        }
        pub fn eql(self: @This(), a: F, b: F) bool {
            _ = self;
            const ba: Bits = @bitCast(a);
            const bb: Bits = @bitCast(b);
            return (IntContext{}).eql(ba, bb);
        }
    };
}

/// Comptime-recursive hash/eql context for struct-typed fields. Walks each
/// field of `T` and applies the same dispatch as `BwdContext` — so a struct
/// containing a `[]const u8` field gets string-content comparison, a float
/// field gets bitwise comparison, and so on, however deeply nested.
fn RecursiveContext(comptime T: type) type {
    return struct {
        pub fn hash(self: @This(), key: T) u64 {
            _ = self;
            var wh = std.hash.Wyhash.init(0);
            recursiveHash(&wh, key);
            return wh.final();
        }
        pub fn eql(self: @This(), a: T, b: T) bool {
            _ = self;
            return recursiveEql(a, b);
        }
    };
}

fn recursiveHash(wh: *std.hash.Wyhash, value: anytype) void {
    const T = @TypeOf(value);
    if (T == []const u8) {
        wh.update(value);
        return;
    }
    switch (@typeInfo(T)) {
        .float => {
            const Bits = @Int(.unsigned, @bitSizeOf(T));
            const bits: Bits = @bitCast(value);
            wh.update(std.mem.asBytes(&bits));
        },
        .@"struct" => |info| {
            inline for (info.field_names) |fname| {
                recursiveHash(wh, @field(value, fname));
            }
        },
        else => std.hash.autoHash(wh, value),
    }
}

fn recursiveEql(a: anytype, b: anytype) bool {
    const T = @TypeOf(a);
    if (T == []const u8) return std.mem.eql(u8, a, b);
    return switch (@typeInfo(T)) {
        .float => {
            const Bits = @Int(.unsigned, @bitSizeOf(T));
            return @as(Bits, @bitCast(a)) == @as(Bits, @bitCast(b));
        },
        .@"struct" => |info| {
            inline for (info.field_names) |fname| {
                if (!recursiveEql(@field(a, fname), @field(b, fname))) return false;
            }
            return true;
        },
        else => a == b,
    };
}

const TestEntity = struct { sqrrl___id: u32 };
fn e(id: u32) TestEntity { return .{ .sqrrl___id = id }; }

test "Rel int field" {
    var rel = sqrrl___Rel(TestEntity, u32).init(std.testing.allocator);
    defer rel.deinit();

    try rel.put(e(0), 10);
    try rel.put(e(1), 20);
    try rel.put(e(2), 10); // shared value, not a bijection

    try std.testing.expectEqual(@as(?u32, 10), rel.getFwd(e(0)));
    try std.testing.expectError(error.IdAlreadyExists, rel.put(e(0), 99));
    try std.testing.expectError(error.IdNotFound, rel.update(e(99), 1)); // never put

    const holders = rel.getBwd(10);
    try std.testing.expectEqual(@as(usize, 2), holders.len);

    try rel.update(e(0), 999); // 0 moves out of the shared "10" bucket
    try std.testing.expectEqual(@as(?u32, 999), rel.getFwd(e(0)));
    try std.testing.expectEqual(@as(usize, 1), rel.getBwd(10).len);
    try std.testing.expectEqual(@as(usize, 1), rel.getBwd(999).len);

    try std.testing.expectEqual(@as(?u32, 999), rel.fetchRemoveFwd(e(0)));
    try std.testing.expectEqual(@as(usize, 0), rel.getBwd(999).len);
    try std.testing.expectEqual(@as(usize, 1), rel.getBwd(10).len); // id 2 untouched
    try std.testing.expectEqual(@as(?u32, null), rel.getFwd(e(0)));

    try rel.put(e(0), 30); // freed slot can be reused
    try std.testing.expectEqual(@as(?u32, 30), rel.getFwd(e(0)));
}

test "Rel string field" {
    var rel = sqrrl___Rel(TestEntity, []const u8).init(std.testing.allocator);
    defer rel.deinit();

    try rel.put(e(0), "alice");
    try rel.put(e(1), "bob");

    try std.testing.expectEqualStrings("alice", rel.getFwd(e(0)).?);
    try std.testing.expectEqual(@as(usize, 1), rel.getBwd("bob").len);
    try std.testing.expectEqual(@as(usize, 0), rel.getBwd("carol").len);
}

test "Rel float field" {
    var rel = sqrrl___Rel(TestEntity, f32).init(std.testing.allocator);
    defer rel.deinit();

    try rel.put(e(0), 1.5);
    try rel.put(e(1), -0.0);
    try rel.put(e(2), 0.0);

    try std.testing.expectEqual(@as(?f32, 1.5), rel.getFwd(e(0)));
    // bit-pattern equality: +0.0 and -0.0 are distinct keys here, unlike `==`.
    try std.testing.expectEqual(@as(usize, 1), rel.getBwd(0.0).len);
    try std.testing.expectEqual(@as(usize, 1), rel.getBwd(-0.0).len);

    const nan: f32 = std.math.nan(f32);
    try rel.put(e(3), nan);
    try std.testing.expectEqual(@as(usize, 1), rel.getBwd(nan).len);
}

test "Rel comptime rejects EntityType without sqrrl___id" {
    // Compile-time only — confirming a valid EntityType compiles fine
    // (the bad-type case is a @compileError, untestable at runtime).
    const Valid = struct { sqrrl___id: u32 };
    var rel = sqrrl___Rel(Valid, u32).init(std.testing.allocator);
    defer rel.deinit();
    try rel.put(.{ .sqrrl___id = 0 }, 42);
    try std.testing.expectEqual(@as(?u32, 42), rel.getFwd(.{ .sqrrl___id = 0 }));
}

/// Per-field storage for owned array fields — `@@struct Person { tags: []u32 }`.
/// Each entity owns a heap-allocated copy of its slice. There is no bwd index
/// (reverse lookup by array value doesn't make sense); use `sqrrl___Rel` for
/// scalar fields that need `for*` reverse lookup. `put` dupes the input;
/// `update` dupes the new value before freeing the old one (so a failed dupe
/// leaves the entity's value intact); `remove` and `deinit` free everything.
/// Uses `assertEntityType` — same `sqrrl___id: u32` contract as `sqrrl___Rel`.
pub fn sqrrl___OwnedSliceRel(comptime EntityType: type, comptime Elem: type) type {
    comptime assertEntityType(EntityType);

    return struct {
        allocator: std.mem.Allocator,
        fwd: std.ArrayList(?[]Elem),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator, .fwd = .empty };
        }

        pub fn deinit(self: *Self) void {
            for (self.fwd.items) |maybe| {
                if (maybe) |s| self.allocator.free(s);
            }
            self.fwd.deinit(self.allocator);
        }

        pub fn put(self: *Self, entity: EntityType, value: []const Elem) !void {
            const id = entity.sqrrl___id;
            if (id < self.fwd.items.len and self.fwd.items[id] != null)
                return error.IdAlreadyExists;
            const owned = try self.allocator.dupe(Elem, value);
            errdefer self.allocator.free(owned);
            if (id >= self.fwd.items.len)
                try self.fwd.appendNTimes(self.allocator, null, id + 1 - self.fwd.items.len);
            self.fwd.items[id] = owned;
        }

        pub fn update(self: *Self, entity: EntityType, value: []const Elem) !void {
            const id = entity.sqrrl___id;
            if (id >= self.fwd.items.len or self.fwd.items[id] == null)
                return error.IdNotFound;
            const owned = try self.allocator.dupe(Elem, value);
            self.allocator.free(self.fwd.items[id].?);
            self.fwd.items[id] = owned;
        }

        pub fn getFwd(self: *const Self, entity: EntityType) ?[]const Elem {
            const id = entity.sqrrl___id;
            if (id >= self.fwd.items.len) return null;
            return self.fwd.items[id];
        }

        /// Remove and free entity's value. No-op if not set.
        pub fn remove(self: *Self, entity: EntityType) void {
            const id = entity.sqrrl___id;
            if (id >= self.fwd.items.len) return;
            if (self.fwd.items[id]) |s| {
                self.allocator.free(s);
                self.fwd.items[id] = null;
            }
        }

        /// Remove entity's value and hand ownership to the caller, who must
        /// free it. Returns null if not set.
        pub fn fetchRemoveFwd(self: *Self, entity: EntityType) ?[]Elem {
            const id = entity.sqrrl___id;
            if (id >= self.fwd.items.len) return null;
            const old = self.fwd.items[id] orelse return null;
            self.fwd.items[id] = null;
            return old;
        }
    };
}

test "OwnedSliceRel put and getFwd" {
    var rel = sqrrl___OwnedSliceRel(TestEntity, u32).init(std.testing.allocator);
    defer rel.deinit();
    try rel.put(e(0), &.{ 1, 2, 3 });
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, rel.getFwd(e(0)).?);
    try std.testing.expectEqual(@as(?[]const u32, null), rel.getFwd(e(1)));
}

test "OwnedSliceRel stores an independent copy" {
    var rel = sqrrl___OwnedSliceRel(TestEntity, u32).init(std.testing.allocator);
    defer rel.deinit();
    var buf = [_]u32{ 10, 20 };
    try rel.put(e(0), &buf);
    buf[0] = 99;
    try std.testing.expectEqual(@as(u32, 10), rel.getFwd(e(0)).?[0]);
}

test "OwnedSliceRel update replaces value without leaking" {
    var rel = sqrrl___OwnedSliceRel(TestEntity, u32).init(std.testing.allocator);
    defer rel.deinit();
    try rel.put(e(0), &.{1});
    try rel.update(e(0), &.{ 7, 8, 9 });
    try std.testing.expectEqualSlices(u32, &.{ 7, 8, 9 }, rel.getFwd(e(0)).?);
}

test "OwnedSliceRel remove and put errors" {
    var rel = sqrrl___OwnedSliceRel(TestEntity, u32).init(std.testing.allocator);
    defer rel.deinit();
    try rel.put(e(0), &.{ 1, 2 });
    try std.testing.expectError(error.IdAlreadyExists, rel.put(e(0), &.{3}));
    try std.testing.expectError(error.IdNotFound, rel.update(e(1), &.{3}));
    rel.remove(e(0));
    try std.testing.expectEqual(@as(?[]const u32, null), rel.getFwd(e(0)));
    rel.remove(e(0)); // no-op is safe
}

const Profile = struct { name: []const u8, score: f32 };

test "Rel struct field with nested string: getBwd compares string content" {
    var rel = sqrrl___Rel(TestEntity, Profile).init(std.testing.allocator);
    defer rel.deinit();

    // Two separate string literals with the same content — different addresses.
    const a: []const u8 = "alice";
    const a2: []const u8 = try std.testing.allocator.dupe(u8, "alice");
    defer std.testing.allocator.free(a2);

    try rel.put(e(0), .{ .name = a, .score = 1.0 });
    try rel.put(e(1), .{ .name = "bob", .score = 2.0 });

    // Both entities whose profile.name == "alice" (by content, not pointer)
    // should be found — entity 0's name pointer != a2 pointer, but content matches.
    try rel.put(e(2), .{ .name = a2, .score = 1.0 });

    const holders = rel.getBwd(.{ .name = "alice", .score = 1.0 });
    try std.testing.expectEqual(@as(usize, 2), holders.len);
}

test "Rel struct field with nested float: getBwd treats +0.0 and -0.0 as distinct" {
    var rel = sqrrl___Rel(TestEntity, Profile).init(std.testing.allocator);
    defer rel.deinit();

    try rel.put(e(0), .{ .name = "x", .score = 0.0 });
    try rel.put(e(1), .{ .name = "x", .score = -0.0 });

    // Bitwise comparison: +0.0 and -0.0 are distinct hash keys.
    try std.testing.expectEqual(@as(usize, 1), rel.getBwd(.{ .name = "x", .score = 0.0 }).len);
    try std.testing.expectEqual(@as(usize, 1), rel.getBwd(.{ .name = "x", .score = -0.0 }).len);
}
