from std.memory import ArcPointer
from std.os import abort
from std.collections import Set

from squirrel_runtime.entity.table_state_like import TableStateLike
from squirrel_runtime.entity.table_storage import TableStorage
from squirrel_runtime.entity.entity_inner import EntityInner
from squirrel_runtime.entity.entity_handle import EntityHandle


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
        var handle = EntityHandle[Self.State](EntityInner[Self.State](_id=id, _table=self.state))
        var weak = ArcPointer[EntityInner[Self.State]].WeakPointer(downgrade=handle._inner)
        self.state[].store_weak_ref(id, weak)
        return handle

    def create_with_id(mut self, id: UInt32) raises -> EntityHandle[Self.State]:
        """Like `create`, but reserves a caller-chosen id instead of
        auto-allocating one -- the one caller is `sqrrl__world_from_json`
        reconstructing a `sqrrl__World` from a JSON dump, where an
        entity's id has to match whatever a relation field elsewhere in
        the dump already serialized it as (see `IdAllocator.alloc_specific`).
        Raises if `id` is already live."""
        self.state[].alloc_specific_id(id)
        var handle = EntityHandle[Self.State](EntityInner[Self.State](_id=id, _table=self.state))
        var weak = ArcPointer[EntityInner[Self.State]].WeakPointer(downgrade=handle._inner)
        self.state[].store_weak_ref(id, weak)
        return handle

    def is_live(self, id: UInt32) -> Bool:
        return self.state[].is_live(id)

    def handle_for(self, id: UInt32) -> EntityHandle[Self.State]:
        """A safe alternative to fabricating `EntityHandle(EntityInner(_id=id,
        _table=...))` for an id you don't already hold a handle to (e.g. a
        generated `for_<field>` reverse lookup) -- upgrades the id's stored
        `WeakPointer` instead, sharing whatever `EntityHandle`(s) already
        exist for it rather than creating an uncoordinated second owner.
        Aborts rather than raises if the id is no longer live, matching
        `Rel.put`/`update`'s own invariant-violation convention: every
        current caller (a generated `for_<field>`) only ever passes an id
        fresh out of `Rel`/`UniqueRel.get_bwd`, whose _bwd index is kept in
        sync with which ids are currently live (see `Rel`'s doc comment) --
        a dead id reaching here would mean that invariant broke, not
        realistic bad input a caller could meaningfully recover from."""
        var upgraded = self.state[].try_upgrade(id)
        if not upgraded:
            abort("Table.handle_for: id is no longer live")
        return EntityHandle[Self.State](upgraded.value())

    def all(self) -> Set[EntityHandle[Self.State]]:
        """Every currently-live entity in this table, as a fresh `Set` of
        handles -- a single pass over every id ever handed out
        (`IdAllocator.id_count()`), checking `is_live` and building a handle
        only for the ones still allocated, rather than materializing an
        intermediate list of live ids first. Finds an entity regardless of
        what's actually keeping it alive (a relation elsewhere, a local
        handle, `keepalive`, ...) -- ground truth is the id allocator, not
        any one field's own `_bwd` index. Every generated `sqrrl__NameTable`
        gets this unconditionally, whether or not the struct is
        `keepalive`-tagged."""
        var out = Set[EntityHandle[Self.State]]()
        for i in range(self.state[].id_count()):
            var id = UInt32(i)
            if self.state[].is_live(id):
                out.add(self.handle_for(id))
        return out^

    def count(self) -> Int:
        """How many entities are currently live in this table -- `len(self.
        all())` without the wasted work of actually building a handle for
        every one just to throw it away right after: `IdAllocator.
        live_count()` is O(1), tracked from `free_list`'s own size rather
        than scanned."""
        return self.state[].live_count()
