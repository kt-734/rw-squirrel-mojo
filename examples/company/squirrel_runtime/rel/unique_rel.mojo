from std.os import abort

from squirrel_runtime.rel.fwd_store import _FwdStore
from squirrel_runtime.rel.rel_like import RelLike


struct UniqueRel[T: KeyElement & ImplicitlyDeletable & Copyable](RelLike, Movable):
    """The `unique`-marked-field counterpart to `Rel`: shares `_FwdStore`
    for the per-id half, but `_bwd` maps a value to *at most one* id instead
    of a list -- `put`/`update` enforce that by raising a catchable error
    (not aborting, unlike `Rel`'s invariants) when the value already
    belongs to a *different* id, since a duplicate unique value is realistic
    bad input a caller should be able to catch, not a codegen/IdAllocator
    bug. `get_bwd` mirrors that: it raises rather than returning an empty
    list, since callers of a unique lookup want the single entity or a
    clear failure, not an always-a-list shape that's misleading when at
    most one result is possible.

    Bounded by plain `Copyable`, not `ImplicitlyCopyable` -- see `Rel`'s
    own doc comment for why (a collection-typed field, e.g. `unique
    @@members: List[@@Employee]`, is `KeyElement` exactly when its element
    type is, and doesn't need implicit copyability to be one)."""

    comptime FieldType = Self.T

    var _fwd: _FwdStore[Self.T]
    var _bwd: Dict[Self.T, UInt32]

    def __init__(out self):
        self._fwd = _FwdStore[Self.T]()
        self._bwd = Dict[Self.T, UInt32]()

    def put(mut self, id: UInt32, value: Self.T) raises:
        """Set id's value for the first time. Aborts if id already holds a
        value (call `update` instead); raises if another id already holds
        `value`."""
        self._check_unique(value, id)
        self._fwd.set_new(id, value)
        self._bwd[value.copy()] = id

    def update(mut self, id: UInt32, value: Self.T) raises:
        """Replace id's existing value. Aborts if id doesn't currently hold
        one (call `put` instead); raises if another id already holds
        `value`."""
        self._check_unique(value, id)
        var old = self._fwd.replace(id, value)
        self._forget(old)
        self._bwd[value.copy()] = id

    def get_fwd(self, id: UInt32) -> Optional[Self.T]:
        return self._fwd.get(id)

    def get_bwd(self, value: Self.T) raises -> UInt32:
        """The single id currently holding `value`. Raises if none does."""
        try:
            return self._bwd[value]
        except:
            raise Error(
                "UniqueConstraintViolation: no entity currently holds this value"
            )

    def all_bwd(self) -> ref [self._bwd] Dict[Self.T, UInt32]:
        """Every value currently in use, each mapped to the single id
        holding it -- the whole reverse index at once, rather than one
        value via `get_bwd`. What `group_by_<field>` (`codegen.table`)
        walks. A borrowed reference straight into `_bwd` (one id per
        value, by construction of `unique`), not a copy -- see `Rel.
        all_bwd`'s own doc comment for why: read-only since `self` itself
        is only borrowed here, and `group_by_<field>` immediately builds
        its own fresh `Dict` from this one anyway (converting each id to a
        real handle), so copying `_bwd` first would be wasted work."""
        return self._bwd

    def fetch_remove_fwd(mut self, id: UInt32) -> Optional[Self.T]:
        """Clear id's value; returns the value it held, or None."""
        var old = self._fwd.clear(id)
        if not old:
            return None
        self._forget(old.value())
        return old^

    def _check_unique(self, value: Self.T, id: UInt32) raises:
        # `self._bwd[value]` only runs once `value in self._bwd` has already
        # confirmed the key is present, so this can't hit `DictKeyError`.
        if value in self._bwd and self._bwd[value] != id:
            raise Error(
                "UniqueConstraintViolation: value already in use by"
                " another entity"
            )

    def _forget(mut self, value: Self.T):
        try:
            _ = self._bwd.pop(value)
        except:
            abort("UniqueRel._forget: unreachable Dict operation failure")
