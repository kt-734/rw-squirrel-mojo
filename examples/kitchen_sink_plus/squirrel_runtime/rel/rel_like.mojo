trait RelLike:
    """Shared interface every per-field storage variant (`Rel`, `UniqueRel`,
    `ForwardOnlyRel`) provides -- the operations generated `create`/`get_*`/
    `set_*`/`cleanup_relations` code needs, regardless of which variant a
    given field actually uses.

    Declared `raises` here (the widest signature among the three -- only
    `UniqueRel`'s actually can) since a narrower, non-raising
    implementation still satisfies a `raises` trait method (confirmed
    empirically: a struct whose own `put` doesn't raise conforms fine to a
    trait declaring `put(...) raises`) without forcing callers to treat it
    as raising -- generated code always calls a field's own *concrete*
    type directly, never through this trait generically, so `Rel`/
    `ForwardOnlyRel`'s own non-raising `put`/`update` keep behaving exactly as
    before. This trait exists purely to state the shared contract
    formally, not to change how anything is called.

    `_fwd` (the per-id dense-array storage each variant holds) isn't part
    of this trait -- confirmed Mojo traits can't declare fields at all
    (`error: traits do not support 'var' fields`), only methods and
    associated types (`comptime`), so each conforming struct declares its
    own `_fwd: _FwdStore[Self.T]` independently; nothing about it is
    inherited the way an abstract base class's instance state would be.
    Each struct's own type parameter is named `T`, not `FieldType`,
    specifically because redeclaring `comptime FieldType = Self.FieldType`
    under the same name as the struct's own parameter is rejected as a
    redefinition -- `T` for the raw parameter, `FieldType` for the
    trait-satisfying alias to it, used interchangeably in every method
    body below.

    `get_bwd` deliberately isn't part of this trait: `Rel`'s returns
    `Set[UInt32]`, `UniqueRel`'s returns `UInt32` (raises), and `ForwardOnlyRel`
    has none at all -- genuinely incompatible shapes, not just a raises
    difference, and traits can't express covariant return types."""

    comptime FieldType: ImplicitlyDeletable & Copyable

    def put(mut self, id: UInt32, value: Self.FieldType) raises:
        ...

    def update(mut self, id: UInt32, value: Self.FieldType) raises:
        ...

    def get_fwd(self, id: UInt32) -> Optional[Self.FieldType]:
        ...

    def fetch_remove_fwd(mut self, id: UInt32) -> Optional[Self.FieldType]:
        ...
