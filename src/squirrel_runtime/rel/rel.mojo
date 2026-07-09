from std.os import abort
from std.collections import Set

from squirrel_runtime.rel.fwd_store import _FwdStore
from squirrel_runtime.rel.rel_like import RelLike


struct Rel[T: KeyElement & ImplicitlyDeletable & Copyable](RelLike, Movable):
    """Per-field storage for one generated table: `_fwd` is a dense array
    indexed by entity id; `_bwd` maps a field value back to every entity id
    currently holding it. Mirrors the Zig `sqrrl___Rel`, minus the manual
    incref/decref bookkeeping -- when `FieldType` is itself an `EntityHandle`
    (a relation field), storing a copy in `_fwd` is an ordinary Mojo copy and
    refcounts automatically.

    Bounded by plain `Copyable`, not `ImplicitlyCopyable` -- `KeyElement`
    (Hashable & Equatable & Copyable & Movable) doesn't itself require
    implicit copyability, and a collection-typed field genuinely can
    satisfy `KeyElement` when its element type does (confirmed:
    `List[EntityHandle[...]]` conforms to `Hashable`/`KeyElement` -- being a
    container says nothing about hashability on its own, only the element
    type does), so this field's storage shouldn't be artificially
    restricted to non-collection types. `emit_rel_type` picks `Rel` for
    exactly this case by default; `forwardonly` is the explicit escape
    hatch for a field whose type genuinely isn't `KeyElement` (a plain,
    non-hashable collection like `List[Int]`, or any other type Mojo
    itself would reject here) -- see `ForwardOnlyRel`.

    When `FieldType` is itself an `EntityHandle`, `_bwd`'s dict-key storage
    holds a real strong reference too (inserting a new key is a real Mojo
    copy, same as any other). `_remove_from_bucket` deletes the key once its
    bucket empties -- not just truncates its value list -- specifically so
    that reference is dropped along with it, symmetric with `_fwd`.

    `put`/`update` abort rather than raise on a violated invariant (id
    already/not yet holding a value) -- generated `create`/`set_*` methods
    only ever call these in ways that can't fail if codegen and the
    IdAllocator are doing their job (a fresh id from `create` is always
    unused; a `set_*` always targets a field `create` already populated),
    so there's nothing a caller could meaningfully recover from if it does.
    That also means `_add_to_bucket`/`_remove_from_bucket` can't raise
    either, even though they call `Dict` operations that are themselves
    `raises`-signatured (by Mojo's own API, regardless of whether the key
    is actually present) -- wrapped in `try`/`except: abort(...)` so that
    unavoidable propagation doesn't leak back out as `raises` on everything
    built on top of `Rel`. See `UniqueRel` for the variant backing a
    `unique`-marked field, where a duplicate value *is* something a caller
    can meaningfully recover from, so it raises instead, and `ForwardOnlyRel` for
    the variant backing a non-`KeyElement` (e.g. collection-typed) field,
    which has no `_bwd` at all.
    """

    comptime FieldType = Self.T

    var _fwd: _FwdStore[Self.T]
    var _bwd: Dict[Self.T, Set[UInt32]]

    def __init__(out self):
        self._fwd = _FwdStore[Self.T]()
        self._bwd = Dict[Self.T, Set[UInt32]]()

    def put(mut self, id: UInt32, value: Self.T):
        """Set id's value for the first time. Aborts if id already holds a
        value (call `update` instead)."""
        self._fwd.set_new(id, value)
        self._add_to_bucket(value, id)

    def update(mut self, id: UInt32, value: Self.T):
        """Replace id's existing value. Aborts if id doesn't currently hold
        one (call `put` instead)."""
        var old = self._fwd.replace(id, value)
        self._remove_from_bucket(old, id)
        self._add_to_bucket(value, id)

    def get_fwd(self, id: UInt32) -> Optional[Self.T]:
        return self._fwd.get(id)

    def get_bwd(self, value: Self.T) -> Set[UInt32]:
        """All ids currently holding `value` (empty if none)."""
        try:
            return self._bwd[value].copy()
        except:
            return Set[UInt32]()

    def all_bwd(self) -> Dict[Self.T, Set[UInt32]]:
        """Every value currently in use, each mapped to every id holding it
        -- the whole reverse index at once, rather than one bucket via
        `get_bwd`. What `group_by_<field>` (`codegen.table`) walks; a plain
        `.copy()` since `_bwd` already *is* exactly this shape."""
        return self._bwd.copy()

    def fetch_remove_fwd(mut self, id: UInt32) -> Optional[Self.T]:
        """Clear id's value; returns the value it held, or None."""
        var old = self._fwd.clear(id)
        if not old:
            return None
        self._remove_from_bucket(old.value(), id)
        return old^

    def _add_to_bucket(mut self, value: Self.T, id: UInt32):
        try:
            if value not in self._bwd:
                self._bwd[value.copy()] = Set[UInt32]()
            self._bwd[value].add(id)
        except:
            abort("Rel._add_to_bucket: unreachable Dict operation failure")

    def _remove_from_bucket(mut self, value: Self.T, id: UInt32):
        try:
            if value not in self._bwd:
                return
            var bucket = self._bwd[value].copy()
            if id in bucket:
                try:
                    bucket.remove(id)
                except:
                    abort("Rel._remove_from_bucket: unreachable Set.remove failure")
            if len(bucket) == 0:
                # Delete the key itself, not just empty its set -- when
                # FieldType is an EntityHandle, the key's own copy is a real
                # strong reference, and leaving an empty entry behind would
                # keep that reference alive forever.
                _ = self._bwd.pop(value)
            else:
                self._bwd[value.copy()] = bucket^
        except:
            abort("Rel._remove_from_bucket: unreachable Dict operation failure")
