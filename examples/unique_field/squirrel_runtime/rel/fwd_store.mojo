from std.os import abort


struct _FwdStore[FieldType: ImplicitlyDeletable & Copyable](Movable):
    """The dense-array-by-id half of per-field storage, shared verbatim by
    `Rel`, `UniqueRel`, and `ForwardOnlyRel` -- it doesn't care whether a value
    can repeat across ids, only that each id holds at most one, so there's
    nothing about it that varies between any of them. `_bwd` (the
    value-to-id index) is where `Rel`/`UniqueRel` actually differ (and
    `ForwardOnlyRel` has none at all), so it stays out of this struct and lives
    on each of them instead. Bounded by plain `Copyable`, not
    `ImplicitlyCopyable` -- every copy here goes through an explicit
    `.copy()` call already, and `ForwardOnlyRel`'s own field type is typically a
    collection (`List[EntityHandle[...]]`), which is `Copyable` but not
    `ImplicitlyCopyable` (confirmed: `List[Int]` satisfies `Copyable` but
    is rejected by an `ImplicitlyCopyable`-bounded parameter)."""

    var items: List[Optional[Self.FieldType]]

    def __init__(out self):
        self.items = List[Optional[Self.FieldType]]()

    def get(self, id: UInt32) -> Optional[Self.FieldType]:
        if Int(id) >= len(self.items):
            return None
        return self.items[Int(id)].copy()

    def set_new(mut self, id: UInt32, value: Self.FieldType):
        """Set id's value for the first time. Aborts if id already holds a
        value (call `replace` instead)."""
        while Int(id) >= len(self.items):
            self.items.append(None)
        if self.items[Int(id)] is not None:
            abort("_FwdStore.set_new: id already has a value")
        self.items[Int(id)] = value.copy()

    def replace(mut self, id: UInt32, value: Self.FieldType) -> Self.FieldType:
        """Replace id's existing value, returning the one it held. Aborts if
        id doesn't currently hold one (call `set_new` instead)."""
        if Int(id) >= len(self.items) or not self.items[Int(id)]:
            abort("_FwdStore.replace: id not found")
        var old = self.items[Int(id)].value().copy()
        self.items[Int(id)] = value.copy()
        return old^

    def clear(mut self, id: UInt32) -> Optional[Self.FieldType]:
        """Clear id's value; returns the value it held, or None."""
        if Int(id) >= len(self.items):
            return None
        var old = self.items[Int(id)].copy()
        self.items[Int(id)] = None
        return old^

    def get_mut(mut self, id: UInt32) -> ref [self.items] Optional[Self.FieldType]:
        """A mutable reference to id's stored slot, letting a caller (e.g.
        `MultiRel.add`/`remove`) mutate the value in place -- appending to
        or removing from a stored collection without a get+copy+replace
        round trip through `get`/`replace`. Requires `id < len(items)`
        (i.e. `set_new` already ran for it, same precondition `replace`/
        `clear` already assume) -- an out-of-range id aborts via the
        underlying `List.__getitem__` rather than returning `None`, since
        there's no sentinel `ref` to return in place of one."""
        return self.items[Int(id)]
