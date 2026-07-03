from std.memory import ArcPointer
from std.hashlib import Hasher

from squirrel_runtime.id_allocator import IdAllocator


trait TableStateLike:
    """What a generated table's state struct must provide so the shared
    machinery can cascade-clean relation fields when an entity dies without
    knowing what fields a specific table has.

    A generated `sqrrl__EmployeeTableState` implements this with just one
    method: `sqrrl__cleanup_relations` -- prefixed, like the generated
    struct names themselves, so it can never collide with a `.rel`-declared
    field of the same name (a `.rel` author could plausibly name a field
    `cleanup_relations`; they can't plausibly type `sqrrl__cleanup_relations`
    by accident). It calls `fetch_remove_fwd` on each of its own `Rel`
    fields for the given id and discards the result -- for a relation
    field, that drops the returned `EntityHandle`, decref'ing whatever it
    pointed to; for a plain field, it's just freeing the table's own stored
    copy. Without this, destroying an entity would free its id but leave its
    relation fields' stored references behind forever: `sqrrl__PersonTableState`'s
    `employee: Rel[EntityHandle[sqrrl__EmployeeTableState]]` doesn't live
    inside `EntityInner` itself, so Mojo's automatic field-wise destruction
    cascade (which does work for a relation embedded as a direct struct
    field) can't reach it -- confirmed by tracing through a concrete leak:
    destroying a Person left `PersonTableState.employee.fwd[alice_id]` still
    holding a live reference to Bob, permanently inflating his refcount.

    Id allocation itself (`alloc_id`/`free_id`/`is_live`) is *not* part of
    this trait -- it lives on `TableStorage` instead (a fixed, non-generated
    wrapper), since it's mechanically identical for every table and doesn't
    need to vary per `@@struct`. Mojo trait methods can have default bodies
    that call other required methods, but not ones that return a reference
    to a field (confirmed: the trait's abstract return-origin annotation and
    an implementation's field-specific one don't unify, even when they
    should be compatible) -- so hoisting id allocation into `TableStorage`,
    rather than trying to default-implement it on the trait, is what
    actually removes the boilerplate from generated code."""

    def sqrrl__cleanup_relations(mut self, id: UInt32):
        ...


struct TableStorage[State: TableStateLike & Movable & ImplicitlyDeletable](Movable, ImplicitlyDeletable):
    """The actual payload behind every entity's `ArcPointer` -- an
    `IdAllocator` (shared, identical logic for every table) plus the
    generated `State` (the table's own `Rel` fields and `cleanup_relations`).
    Splitting these apart is what lets `alloc_id`/`free_id`/`is_live` be
    written once here instead of once per generated table."""

    var ids: IdAllocator
    var state: Self.State

    def __init__(out self, var state: Self.State):
        self.ids = IdAllocator()
        self.state = state^

    def alloc_id(mut self) -> UInt32:
        return self.ids.alloc()

    def free_id(mut self, id: UInt32):
        self.ids.free(id)

    def is_live(self, id: UInt32) -> Bool:
        return self.ids.is_live(id)

    def cleanup_relations(mut self, id: UInt32):
        self.state.sqrrl__cleanup_relations(id)


@fieldwise_init
struct EntityInner[State: TableStateLike & Movable & ImplicitlyDeletable](Movable):
    """The payload behind an `EntityHandle`. Destroyed exactly once, when the
    last `ArcPointer` copy referencing it drops -- see `__del__`, which
    cascades into the owning table's own relation fields (via
    `cleanup_relations`) before freeing the id. Holding a copy of `table`
    (rather than a pointer into it) is what makes reaching back into it
    safe: the shared state can't be torn down while this entity still
    exists, because this entity itself is one of the things keeping it
    alive."""

    var id: UInt32
    var table: ArcPointer[TableStorage[Self.State]]

    def __del__(deinit self):
        # No try/except needed: cleanup_relations/free_id no longer raise --
        # they abort on a violated invariant instead (see `Rel`'s doc
        # comment), since this id was live from construction and is only
        # ever cleaned up/freed here, exactly once, by construction.
        self.table[].cleanup_relations(self.id)
        self.table[].free_id(self.id)


struct EntityHandle[State: TableStateLike & Movable & ImplicitlyDeletable](ImplicitlyCopyable, ImplicitlyDeletable, Hashable, Equatable):
    """A distinct wrapper around `ArcPointer[EntityInner[State]]`, rather
    than a bare alias, so it can conform to `Hashable`/`Equatable` by id --
    needed so `Rel[EntityHandle[SomeState]]` (a relation field) can use it
    as a `bwd` dict key, same as any other `FieldType`. Copy/move/drop are
    auto-synthesized from the single `ArcPointer` field, so refcounting
    still works exactly like the untagged version did.

    `EntityHandle[PersonTableState]` and `EntityHandle[EmployeeTableState]`
    are distinct, mutually-incompatible types -- passing one where the
    other is expected is a compile error, matching the original Zig
    codegen's per-table `sqrrl___Entity` nested type."""

    var inner: ArcPointer[EntityInner[Self.State]]

    def __init__(out self, var inner: EntityInner[Self.State]):
        self.inner = ArcPointer(inner^)

    def id(self) -> UInt32:
        return self.inner[].id

    def count(self) -> Int:
        return Int(self.inner.count())

    def __hash__[H: Hasher](self, mut hasher: H):
        hasher.update(self.id())

    def __eq__(self, other: Self) -> Bool:
        return self.id() == other.id()

    def __ne__(self, other: Self) -> Bool:
        return self.id() != other.id()


struct Table[State: TableStateLike & Movable & ImplicitlyDeletable](Movable):
    """User-facing handle to one generated table. The caller constructs and
    passes in the generated `State` (which holds every field's `Rel`) --
    `Table` wraps it in a `TableStorage` (adding the `IdAllocator`) behind
    an `ArcPointer`, giving every entity a live path back to it without a
    borrowed pointer (Mojo has no mutable global/static state -- confirmed:
    a bare `var` at module scope errors with "global variables are not
    supported", and `static`/`class`-level fields aren't implemented yet
    either -- so a raw pointer back to a stack-resident table couldn't
    safely outlive the entity handles that would hold it). A generated
    table's field accessors reach the actual `Rel`s via
    `self.table.state[].state.<field>`, the extra `.state` hop being
    `TableStorage`'s own field holding the generated `State`."""

    var state: ArcPointer[TableStorage[Self.State]]

    def __init__(out self, var state: Self.State):
        self.state = ArcPointer(TableStorage[Self.State](state^))

    def create(mut self) -> EntityHandle[Self.State]:
        var id = self.state[].alloc_id()
        return EntityHandle[Self.State](EntityInner[Self.State](id=id, table=self.state))

    def is_live(self, id: UInt32) -> Bool:
        return self.state[].is_live(id)
