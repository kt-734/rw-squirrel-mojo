from std.memory import ArcPointer
from std.hashlib import Hasher

from squirrel_runtime.entity.table_state_like import TableStateLike
from squirrel_runtime.entity.entity_inner import EntityInner
from squirrel_runtime.json import sqrrl__JsonSerializable


struct EntityHandle[State: TableStateLike & Movable & ImplicitlyDeletable](
    ImplicitlyCopyable, ImplicitlyDeletable, Hashable, Equatable, sqrrl__JsonSerializable
):
    """A distinct wrapper around `ArcPointer[EntityInner[State]]`, rather
    than a bare alias, so it can conform to `Hashable`/`Equatable` by id --
    needed so `Rel[EntityHandle[SomeState]]` (a relation field) can use it
    as a `_bwd` dict key, same as any other `FieldType`. Copy/move/drop are
    auto-synthesized from the single `ArcPointer` field, so refcounting
    still works exactly like the untagged version did.

    `EntityHandle[PersonTableState]` and `EntityHandle[EmployeeTableState]`
    are distinct, mutually-incompatible types -- passing one where the
    other is expected is a compile error, matching the original Zig
    codegen's per-table `sqrrl___Entity` nested type.

    `_inner` is `_`-prefixed as a signal, not an enforced guarantee (see
    `EntityInner`'s doc comment) -- accessing it directly and mutating what
    it points to (`some_handle._inner[]._id = ...`) compiles and corrupts
    the entity's id with no error until something else later notices (e.g.
    `IdAllocator.free` aborting on an id it never allocated). Use `.id()`/
    `.count()` instead; nothing outside this file should ever need `_inner`
    itself."""

    var _inner: ArcPointer[EntityInner[Self.State]]

    def __init__(out self, var inner: EntityInner[Self.State]):
        self._inner = ArcPointer(inner^)

    def __init__(out self, var inner: ArcPointer[EntityInner[Self.State]]):
        """Wraps an *existing* `ArcPointer` directly (a real share of some
        other handle's, e.g. from `Table.handle_for`'s `try_upgrade`)
        instead of allocating a fresh one -- unlike the other overload,
        this doesn't create a new, independent owner."""
        self._inner = inner^

    def id(self) -> UInt32:
        return self._inner[]._id

    def sqrrl__to_json(self) -> String:
        """A relation field serializes as the referenced entity's bare id
        -- not its own fields (reflecting `_inner` would expose table-
        internal storage, not the target entity's data) and not the
        target entity's *contents* either (that would inline a whole
        copy of it at every reference, duplicating data and losing the
        sharing a relation is for). Reconstructing a live handle from
        this id on the way back in needs the *target's own table*, so
        that half of the round trip is handled by generated code at the
        relation field's own call site, not here."""
        return String(self.id())

    def count(self) -> Int:
        return Int(self._inner.count())

    def __hash__[H: Hasher](self, mut hasher: H):
        hasher.update(self.id())

    def __eq__(self, other: Self) -> Bool:
        return self.id() == other.id()

    def __ne__(self, other: Self) -> Bool:
        return self.id() != other.id()
