from squirrel_runtime.rel.fwd_store import _FwdStore
from squirrel_runtime.rel.rel_like import RelLike


struct PlainRel[T: ImplicitlyDeletable & Copyable](RelLike, Movable):
    """Per-field storage for a field whose type isn't `KeyElement`
    (Hashable & Equatable) -- most commonly a collection type like
    `List[EntityHandle[...]]`, backing a `@@struct`'s own
    `List[@@Type]`-typed field. No `bwd` reverse index at all, unlike
    `Rel`/`UniqueRel`: a `Dict` needs hashable keys, and "which rows have
    exactly this literal list of members" isn't a meaningful query anyway
    (there's no `for_<field>` generated for a field backed by this type,
    for exactly that reason). Just exposes `_FwdStore` directly under
    `Rel`/`UniqueRel`'s own method names (`put`/`update`/`get_fwd`/
    `fetch_remove_fwd`), so generated `create`/`get_*`/`set_*`/
    `cleanup_relations` code doesn't need to special-case which of the
    three a field uses -- `cleanup_relations`'s `fetch_remove_fwd` still
    correctly decref's every entity *inside* a collection value when the
    owning row dies, for free: dropping the returned `List[EntityHandle
    [...]]` runs each element's own destructor, same as dropping a bare
    `EntityHandle` already does for a single-valued relation field."""

    comptime FieldType = Self.T

    var _fwd: _FwdStore[Self.T]

    def __init__(out self):
        self._fwd = _FwdStore[Self.T]()

    def put(mut self, id: UInt32, value: Self.T):
        """Set id's value for the first time. Aborts if id already holds a
        value (call `update` instead)."""
        self._fwd.set_new(id, value)

    def update(mut self, id: UInt32, value: Self.T):
        """Replace id's existing value. Aborts if id doesn't currently hold
        one (call `put` instead)."""
        _ = self._fwd.replace(id, value)

    def get_fwd(self, id: UInt32) -> Optional[Self.T]:
        return self._fwd.get(id)

    def fetch_remove_fwd(mut self, id: UInt32) -> Optional[Self.T]:
        """Clear id's value; returns the value it held, or None."""
        return self._fwd.clear(id)
