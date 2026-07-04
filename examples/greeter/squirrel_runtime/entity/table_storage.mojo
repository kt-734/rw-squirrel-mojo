from std.memory import ArcPointer

from squirrel_runtime.id_allocator import IdAllocator
from squirrel_runtime.entity.table_state_like import TableStateLike
from squirrel_runtime.entity.entity_inner import EntityInner


struct TableStorage[State: TableStateLike & Movable & ImplicitlyDeletable](Movable, ImplicitlyDeletable):
    """The actual payload behind every entity's `ArcPointer` -- an
    `IdAllocator` (shared, identical logic for every table) plus the
    generated `State` (the table's own `Rel` fields and `cleanup_relations`).
    Splitting these apart is what lets `alloc_id`/`free_id`/`is_live` be
    written once here instead of once per generated table.

    Exactly one `TableStorage` exists per `Table` -- `Table.__init__` builds
    it once and wraps it in one `ArcPointer`, a copy of which every entity's
    `EntityInner._table` holds. `weak_refs` (one `WeakPointer` per id, to
    that id's own `EntityInner`) is what makes `Table.handle_for` (looking
    up a live `EntityHandle` from a bare id, e.g. for a generated
    `for_<field>`) safe: stored once, here, per row -- not duplicated once
    per field inside each `Rel`/`UniqueRel`, which would also need an extra
    type parameter for "which table owns me" just to hold it, on top of the
    field's own value type. A `WeakPointer` doesn't keep anything alive
    (unlike a strong copy, which would prevent an id's `ArcPointer` strong
    count from ever reaching zero and defeat destruction entirely) -- an
    entity still gets destroyed exactly when its last *external*
    `EntityHandle` drops, same as before this existed; `try_upgrade` just
    lets a later lookup ask "is it still alive, and if so, hand me a real
    share of it" without ever fabricating an independent, uncoordinated
    second owner the way constructing a fresh `EntityHandle` from a bare id
    would (confirmed by a direct repro: that path double-frees the id once
    the fabricated handle drops, even while a legitimate handle is still
    alive).

    `TableStorage`/`EntityInner` import each other (`TableStorage` needs
    `EntityInner` for `weak_refs`'s element type; `EntityInner` needs
    `TableStorage` for its own `_table` field) -- confirmed empirically
    that Mojo allows this kind of circular import between two files in the
    same package, same as it already worked when both lived in one file."""

    var ids: IdAllocator
    var state: Self.State
    var weak_refs: List[Optional[ArcPointer[EntityInner[Self.State]].WeakPointer]]

    def __init__(out self, var state: Self.State):
        self.ids = IdAllocator()
        self.state = state^
        self.weak_refs = List[Optional[ArcPointer[EntityInner[Self.State]].WeakPointer]]()

    def alloc_id(mut self) -> UInt32:
        return self.ids.alloc()

    def free_id(mut self, id: UInt32):
        self.ids.free(id)

    def is_live(self, id: UInt32) -> Bool:
        return self.ids.is_live(id)

    def id_count(self) -> Int:
        return self.ids.id_count()

    def cleanup_relations(mut self, id: UInt32):
        self.state.sqrrl__cleanup_relations(id)

    def store_weak_ref(mut self, id: UInt32, w: ArcPointer[EntityInner[Self.State]].WeakPointer):
        while Int(id) >= len(self.weak_refs):
            self.weak_refs.append(None)
        self.weak_refs[Int(id)] = w

    def clear_weak_ref(mut self, id: UInt32):
        """Drops id's stored `WeakPointer` once its entity is gone (called
        from `EntityInner.__del__`, alongside `free_id`) -- otherwise it'd
        linger there doing nothing useful until this id slot happens to get
        overwritten by some future `create()` reusing the same id. A
        `WeakPointer` keeps its target's underlying allocation (not the
        already-destroyed value, just the shared strong/weak-count block)
        alive as long as it exists, so leaving it in place would hold that
        allocation longer than necessary -- bounded, since id reuse would
        eventually overwrite it anyway, but not immediate."""
        if Int(id) < len(self.weak_refs):
            self.weak_refs[Int(id)] = None

    def try_upgrade(self, id: UInt32) -> Optional[ArcPointer[EntityInner[Self.State]]]:
        if Int(id) >= len(self.weak_refs) or not self.weak_refs[Int(id)]:
            return None
        return self.weak_refs[Int(id)].value().try_upgrade()
