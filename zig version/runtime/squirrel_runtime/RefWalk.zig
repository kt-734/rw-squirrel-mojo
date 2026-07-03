const std = @import("std");

/// Comptime-recursive incref/decref walk over any value.  Handles:
///   - Any type with `incref()`/`decref()` methods (e.g. `sqrrl___Entity`)
///     → calls the method directly.
///   - Structs → walks every field recursively.
///   - Tagged unions → switches on the active variant, then recurses.
///   - Everything else (scalars, slices, ...) → no-op.
///
/// Used for RC management of struct/union variables that contain entity
/// handles — either directly or at arbitrary nesting depth — without
/// requiring the codegen to know the exact structure ahead of time.
fn sqrrl___refWalk(comptime action: enum { incref, decref }, value: anytype) void {
    const T = @TypeOf(value);
    if (@hasDecl(T, "incref") and @hasDecl(T, "decref")) {
        switch (action) {
            .incref => _ = value.incref(),
            .decref => value.decref(),
        }
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            inline for (info.field_names) |fname| {
                sqrrl___refWalk(action, @field(value, fname));
            }
        },
        .@"union" => {
            switch (value) {
                inline else => |v| sqrrl___refWalk(action, v),
            }
        },
        else => {},
    }
}

/// Incref every entity handle reachable from `value` — directly, in a
/// struct field, in a union variant, or nested arbitrarily deep.
pub fn sqrrl___increfAll(value: anytype) void {
    sqrrl___refWalk(.incref, value);
}

/// Decref every entity handle reachable from `value`.  Triggers
/// `sqrrl___destroy_inner` on each entity whose rc reaches 0.
pub fn sqrrl___decrefAll(value: anytype) void {
    sqrrl___refWalk(.decref, value);
}

// --- Tests ---

const TestEntity = struct {
    sqrrl___id: u32,
    pub fn incref(self: @This()) @This() { return self; }
    pub fn decref(_: @This()) void {}
};

test "sqrrl___increfAll on entity handle" {
    var e = TestEntity{ .sqrrl___id = 1 };
    sqrrl___increfAll(e);
    sqrrl___decrefAll(e);
    _ = &e;
}

test "sqrrl___increfAll on struct containing entity" {
    const Holder = struct { entity: TestEntity, count: u32 };
    const h = Holder{ .entity = TestEntity{ .sqrrl___id = 1 }, .count = 5 };
    sqrrl___increfAll(h);
    sqrrl___decrefAll(h);
}

test "sqrrl___increfAll on union of entities" {
    const Animal = union(enum) { dog: TestEntity, cat: TestEntity };
    const a = Animal{ .dog = TestEntity{ .sqrrl___id = 1 } };
    sqrrl___increfAll(a);
    sqrrl___decrefAll(a);
}

test "sqrrl___increfAll on nested struct" {
    const Inner = struct { entity: TestEntity };
    const Outer = struct { inner: Inner, count: u32 };
    const o = Outer{ .inner = .{ .entity = TestEntity{ .sqrrl___id = 1 } }, .count = 0 };
    sqrrl___increfAll(o);
    sqrrl___decrefAll(o);
}

test "sqrrl___increfAll on scalar is no-op" {
    sqrrl___increfAll(@as(u32, 42));
    sqrrl___decrefAll(@as([]const u8, "hello"));
}
