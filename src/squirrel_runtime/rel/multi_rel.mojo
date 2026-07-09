from std.os import abort
from std.collections import Set

from squirrel_runtime.rel.fwd_store import _FwdStore
from squirrel_runtime.rel.rel_like import RelLike


struct MultiRel[T: KeyElement & ImplicitlyDeletable & Copyable](RelLike, Movable):
    """Per-field storage for a `multi`-marked collection relation field --
    e.g. `multi @@members: @@Employee` on Department -- backing a genuine
    many-to-many relation. Ordinary `Rel` applied to a collection-typed
    field indexes `_bwd` by the *whole* value (only ever answers "which
    rows have exactly this collection"); `multi` indexes by each *element*
    instead, so `get_bwd(some_employee)` answers "which departments
    contain this employee" -- the actual reverse direction a many-to-many
    relation needs, symmetric with the forward direction (`get_fwd(id)` --
    "which employees does this department contain"). This is what makes
    it a different storage choice from `unique` (at most one id per exact
    value) or `forwardonly` (no `_bwd` at all) -- `multi` is its own third
    shape, not a variant of either.

    `Self.T` here is the *element* type (`EntityHandle[...]`, or any other
    `KeyElement`), not the field's own collection type -- `FieldType`
    (what `RelLike`'s `put`/`get_fwd`/etc. actually operate on, matching
    the field's own declared type) is `Set[Self.T]`, not `List[Self.T]`:
    membership is genuinely a set (this department either has this member
    or it doesn't, order doesn't matter, and a duplicate can't exist), so
    `Set` makes that structural rather than a runtime check `put`/`update`
    would otherwise have to enforce by hand -- and `add`/`remove` get
    O(1)-average membership tests instead of a linear scan. `get_bwd`
    takes a bare `Self.T`, the one place this genuinely differs in shape
    from `Rel`'s own `get_bwd(value: Self.T) -> Set[UInt32]` where `T` is
    the whole field type.

    `add`/`remove` mutate a single element in place (via `_FwdStore.
    get_mut`) rather than requiring the get_fwd+copy+add+update round trip
    every other collection-typed field needs -- the actual ergonomic point
    of a many-to-many relation being "add this one member", not "replace
    the whole membership set". Both return `Bool`: whether they actually
    changed anything, so a caller can tell "already a member"/"wasn't a
    member" apart from a real change without a separate lookup -- checked
    explicitly via `in` rather than relying on `Set.add`/`remove`'s own
    return value, since neither reports whether anything changed (`add`
    returns `None`; `remove` raises `DictKeyError` if the element wasn't
    present, which `in` sidesteps rather than needing a try/except for the
    ordinary, expected case). Both also abort if id has never held a
    value at all (no `put` yet) -- the same invariant-violation convention
    `Rel.put`/`update` already use (a real bug, not realistic bad input)."""

    comptime FieldType = Set[Self.T]

    var _fwd: _FwdStore[Self.FieldType]
    var _bwd: Dict[Self.T, Set[UInt32]]

    def __init__(out self):
        self._fwd = _FwdStore[Self.FieldType]()
        self._bwd = Dict[Self.T, Set[UInt32]]()

    def put(mut self, id: UInt32, value: Self.FieldType):
        """Set id's value for the first time. Aborts if id already holds a
        value (call `update` instead)."""
        self._fwd.set_new(id, value)
        for item in value:
            self._add_to_bucket(item, id)

    def update(mut self, id: UInt32, value: Self.FieldType):
        """Replace id's existing value. Aborts if id doesn't currently hold
        one (call `put` instead)."""
        var old = self._fwd.replace(id, value)
        for item in old:
            self._remove_from_bucket(item, id)
        for item in value:
            self._add_to_bucket(item, id)

    def get_fwd(self, id: UInt32) -> Optional[Self.FieldType]:
        return self._fwd.get(id)

    def get_bwd(self, value: Self.T) -> Set[UInt32]:
        """All ids whose set *contains* `value` (empty if none) -- the
        many-to-many reverse query."""
        try:
            return self._bwd[value].copy()
        except:
            return Set[UInt32]()

    def all_bwd(self) -> Dict[Self.T, Set[UInt32]]:
        """Every element currently a member of at least one id's set, each
        mapped to every id whose set contains it -- the whole reverse
        index at once, rather than one bucket via `get_bwd`. What
        `group_by_<field>` (`codegen.table`) walks; a plain `.copy()` since
        `_bwd` already *is* exactly this shape."""
        return self._bwd.copy()

    def fetch_remove_fwd(mut self, id: UInt32) -> Optional[Self.FieldType]:
        """Clear id's value; returns the value it held, or None."""
        var old = self._fwd.clear(id)
        if not old:
            return None
        for item in old.value():
            self._remove_from_bucket(item, id)
        return old^

    def add(mut self, id: UInt32, value: Self.T) -> Bool:
        """Add `value` to id's set of members, in place, if it isn't
        already there. Returns `True` if it was newly added, `False` if
        it was already present (no-op). Aborts if id doesn't currently
        hold a value at all (call `put` first, e.g. via `create` with an
        empty set)."""
        ref slot = self._fwd.get_mut(id)
        if not slot:
            abort("MultiRel.add: id not found")
        ref s = slot.value()
        if value in s:
            return False
        s.add(value.copy())
        self._add_to_bucket(value, id)
        return True

    def remove(mut self, id: UInt32, value: Self.T) -> Bool:
        """Remove `value` from id's set in place, if present. Returns
        `True` if it was removed, `False` if `value` itself just wasn't a
        member. Aborts if id doesn't currently hold a value at all, same
        as `add`."""
        ref slot = self._fwd.get_mut(id)
        if not slot:
            abort("MultiRel.remove: id not found")
        ref s = slot.value()
        if value not in s:
            return False
        try:
            s.remove(value)
        except:
            # Unreachable: `value in s` was just confirmed above, so
            # `Set.remove`'s own `DictKeyError` can't actually fire here --
            # it's still `raises`-signatured, though, since `Set` itself
            # has no way to know that from its own side.
            abort("MultiRel.remove: unreachable Set.remove failure")
        self._remove_from_bucket(value, id)
        return True

    def _add_to_bucket(mut self, value: Self.T, id: UInt32):
        try:
            if value not in self._bwd:
                self._bwd[value.copy()] = Set[UInt32]()
            self._bwd[value].add(id)
        except:
            abort("MultiRel._add_to_bucket: unreachable Dict operation failure")

    def _remove_from_bucket(mut self, value: Self.T, id: UInt32):
        try:
            if value not in self._bwd:
                return
            var bucket = self._bwd[value].copy()
            if id in bucket:
                try:
                    bucket.remove(id)
                except:
                    abort("MultiRel._remove_from_bucket: unreachable Set.remove failure")
            if len(bucket) == 0:
                _ = self._bwd.pop(value)
            else:
                self._bwd[value.copy()] = bucket^
        except:
            abort("MultiRel._remove_from_bucket: unreachable Dict operation failure")
