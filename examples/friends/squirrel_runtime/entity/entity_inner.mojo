from std.memory import ArcPointer

from squirrel_runtime.entity.table_state_like import TableStateLike
from squirrel_runtime.entity.table_storage import TableStorage


@fieldwise_init
struct EntityInner[State: TableStateLike & Movable & ImplicitlyDeletable](Movable):
    """The payload behind an `EntityHandle`. Destroyed exactly once, when the
    last `ArcPointer` copy referencing it drops -- see `__del__`, which
    cascades into the owning table's own relation fields (via
    `cleanup_relations`) before freeing the id. Holding a copy of `_table`
    (rather than a pointer into it) is what makes reaching back into it
    safe: the shared state can't be torn down while this entity still
    exists, because this entity itself is one of the things keeping it
    alive.

    `_id`/`_table` are `_`-prefixed as a signal that they're meant to be
    fixed at construction and read-only from then on -- Mojo has no actual
    field-level access control to enforce that (confirmed: no `private`
    keyword, no `let`/const struct fields, and even a `_`-prefixed field is
    just as directly externally settable as an unprefixed one), so this is
    a naming convention only, not a real guarantee. Nothing in this file
    ever mutates either after `__init__`."""

    var _id: UInt32
    var _table: ArcPointer[TableStorage[Self.State]]

    def __del__(deinit self):
        # No try/except needed: cleanup_relations/free_id no longer raise --
        # they abort on a violated invariant instead (see `Rel`'s doc
        # comment), since this id was live from construction and is only
        # ever cleaned up/freed here, exactly once, by construction.
        self._table[].cleanup_relations(self._id)
        self._table[].free_id(self._id)
        self._table[].clear_weak_ref(self._id)
