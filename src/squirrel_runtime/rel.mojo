from std.os import abort


struct Rel[FieldType: KeyElement & ImplicitlyDeletable & ImplicitlyCopyable](Movable):
    """Per-field storage for one generated table: `fwd` is a dense array
    indexed by entity id; `bwd` maps a field value back to every entity id
    currently holding it. Mirrors the Zig `sqrrl___Rel`, minus the manual
    incref/decref bookkeeping -- when `FieldType` is itself an `EntityHandle`
    (a relation field), storing a copy in `fwd` is an ordinary Mojo copy and
    refcounts automatically.

    When `FieldType` is itself an `EntityHandle`, `bwd`'s dict-key storage
    holds a real strong reference too (inserting a new key is a real Mojo
    copy, same as any other). `_remove_from_bucket` deletes the key once its
    bucket empties -- not just truncates its value list -- specifically so
    that reference is dropped along with it, symmetric with `fwd`.

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
    built on top of `Rel`.
    """

    var fwd: List[Optional[Self.FieldType]]
    var bwd: Dict[Self.FieldType, List[UInt32]]

    def __init__(out self):
        self.fwd = List[Optional[Self.FieldType]]()
        self.bwd = Dict[Self.FieldType, List[UInt32]]()

    def put(mut self, id: UInt32, value: Self.FieldType):
        """Set id's value for the first time. Aborts if id already holds a
        value (call `update` instead)."""
        while Int(id) >= len(self.fwd):
            self.fwd.append(None)
        if self.fwd[Int(id)] is not None:
            abort("Rel.put: id already has a value")
        self.fwd[Int(id)] = value.copy()
        self._add_to_bucket(value, id)

    def update(mut self, id: UInt32, value: Self.FieldType):
        """Replace id's existing value. Aborts if id doesn't currently hold
        one (call `put` instead)."""
        if Int(id) >= len(self.fwd) or not self.fwd[Int(id)]:
            abort("Rel.update: id not found")
        var old = self.fwd[Int(id)].value().copy()
        self._remove_from_bucket(old, id)
        self.fwd[Int(id)] = value.copy()
        self._add_to_bucket(value, id)

    def get_fwd(self, id: UInt32) -> Optional[Self.FieldType]:
        if Int(id) >= len(self.fwd):
            return None
        return self.fwd[Int(id)].copy()

    def get_bwd(self, value: Self.FieldType) -> List[UInt32]:
        """All ids currently holding `value` (empty if none)."""
        try:
            return self.bwd[value].copy()
        except:
            return List[UInt32]()

    def fetch_remove_fwd(mut self, id: UInt32) -> Optional[Self.FieldType]:
        """Clear id's value; returns the value it held, or None."""
        if Int(id) >= len(self.fwd):
            return None
        var old = self.fwd[Int(id)].copy()
        if not old:
            return None
        self._remove_from_bucket(old.value(), id)
        self.fwd[Int(id)] = None
        return old

    def _add_to_bucket(mut self, value: Self.FieldType, id: UInt32):
        try:
            if value not in self.bwd:
                self.bwd[value] = List[UInt32]()
            self.bwd[value].append(id)
        except:
            abort("Rel._add_to_bucket: unreachable Dict operation failure")

    def _remove_from_bucket(mut self, value: Self.FieldType, id: UInt32):
        try:
            if value not in self.bwd:
                return
            var bucket = self.bwd[value].copy()
            for i in range(len(bucket)):
                if bucket[i] == id:
                    _ = bucket.pop(i)
                    break
            if len(bucket) == 0:
                # Delete the key itself, not just empty its list -- when
                # FieldType is an EntityHandle, the key's own copy is a real
                # strong reference, and leaving an empty entry behind would
                # keep that reference alive forever.
                _ = self.bwd.pop(value)
            else:
                self.bwd[value] = bucket^
        except:
            abort("Rel._remove_from_bucket: unreachable Dict operation failure")
