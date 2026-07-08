@fieldwise_init
struct FieldModifier(ImplicitlyCopyable, Movable, Equatable):
    """Which (if any) modifier keyword a `@@struct` field was declared
    with. Mojo has no `enum` keyword -- same idiom as `MarkerKind`: a
    struct wrapping a discriminant, with named `comptime` values. A
    `Field` holds exactly one `FieldModifier`, not one `Bool` per keyword
    -- `unique`/`forwardonly`/`multi`/`ordered` become structurally
    mutually exclusive (a field simply can't represent two at once)
    rather than needing a pairwise rejection check per combination after
    the fact."""

    var value: Int

    comptime NONE = Self(0)
    comptime UNIQUE = Self(1)
    comptime FORWARD_ONLY = Self(2)
    comptime MULTI = Self(3)
    comptime ORDERED = Self(4)

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        return self.value != other.value


@fieldwise_init
struct Field(Copyable, Movable):
    """A single `name: Type` entry inside a `@@struct` body. `type_str` is
    left as raw, untouched text -- whether it's a plain Mojo type or a
    `@@`-marked relation is for codegen to interpret, not this parser.

    `modifier == FieldModifier.UNIQUE` is set by a leading `unique` keyword
    (`unique name: Type`), orthogonal to whether the field is itself a
    relation -- a relation field can be `unique` too (at most one entity
    may point at any given target).

    `modifier == FieldModifier.FORWARD_ONLY` is set by a leading
    `forwardonly` keyword (`forwardonly name: Type`) -- the only thing
    that selects `ForwardOnlyRel` storage. A collection isn't
    automatically assumed to need it: `List[@@Employee]` is `KeyElement`
    exactly when `@@Employee` (an `EntityHandle`) is, which it always is,
    so a wrapped relation field gets ordinary `Rel`/`UniqueRel` by
    default, same as any other field -- confirmed `List[EntityHandle[...]]`
    really does conform to `Hashable`/`KeyElement` (being a container says
    nothing about hashability on its own, only the element type does).
    This parser has no way to know from raw type text alone whether some
    other field's type is `KeyElement` or not (`List[Int]` vs
    `List[Address]` are the same shape, but Mojo would accept one as a
    `Rel` field and reject the other), so `forwardonly` is how a caller
    states that explicitly instead.

    `modifier == FieldModifier.MULTI` is set by a leading `multi` keyword
    (`multi @@members: @@Employee`) -- selects `MultiRel` storage: a
    genuine many-to-many relation, indexed by each *element* of the
    field's own collection rather than the collection's whole value (what
    ordinary `Rel` does) or not indexed at all (`forwardonly`). Unlike a
    wrapped relation field (`List[@@Employee]`), `multi`'s own `type_str`
    is the bare *element* type, not a container -- the keyword itself
    already means "many of these"; codegen turns it into the actual
    `List[EntityHandle[...]]` field.

    `modifier == FieldModifier.ORDERED` is set by a leading `ordered`
    keyword (`ordered name: Type`) -- selects `OrderedRel` storage,
    generating `for_<name>_greater_than`/`_less_than`/`_at_least`/
    `_at_most`/`_between` range-query methods (a binary search over ids
    kept sorted by value, not a linear scan). Doesn't change storage
    shape the way the other three do on its own terms so much as add a
    genuinely different capability (ordering, not just presence/absence
    of a reverse index), which is why it's still one more mutually
    exclusive case rather than a fifth independent `Bool` -- comparing a
    whole `Set[...]` (`multi`) or skipping the reverse index entirely
    (`forwardonly`) doesn't have a sensible ordering to offer in the
    first place."""

    var name: String
    var type_str: String
    var modifier: FieldModifier


@fieldwise_init
struct TypeParam(Copyable, Movable):
    """One entry in a plain struct's own `[T: Bound, ...]` type-parameter
    list (shorthand or hand-written -- see `parse_type_params`). `bound`
    defaults to `"Copyable & ImplicitlyDeletable"` when the `.rel` author
    writes no `: Bound` at all, matching whatever the generated struct's
    own derived conformances (`emit_plain_struct`) require of every
    field's type, `T` included -- a field typed bare `T` has to satisfy
    the same bounds any other field's concrete type already does
    implicitly, no tighter: `ImplicitlyCopyable` here would wrongly
    reject instantiating a generic plain struct at a merely-`Copyable`
    type (`List`/`Set`/`Dict`, confirmed rejected before this used
    `Copyable`), even though `emit_plain_struct`'s own struct-level
    conformance never needed `ImplicitlyCopyable` in the first place --
    see its own doc comment. `Movable` isn't spelled out too, unlike
    `emit_plain_struct`'s own trait list -- confirmed plain `Copyable`
    doesn't imply it the way `ImplicitlyCopyable` does, but nothing here
    (a bare field's own type) ever needs a struct to be independently
    `Movable` beyond what `Copyable` already requires of it. Never
    populated for an `@@struct` (`parse_struct`) -- only plain structs
    can declare their own type parameters."""

    var name: String
    var bound: String


struct ParsedStruct(Copyable, Movable):
    """One `@@struct [keepalive] @@Name: <indented fields>` declaration (or
    a plain `struct Name { field: Type, ... }` / a hand-written `struct
    Name(Traits...):`, neither of which ever sets `is_keepalive`).
    Every generated table gets a `keepalive: Set[EntityHandle[...]]` field
    and a `dont_keepalive(e)` method to release an entry from it, whether
    or not `is_keepalive` is set (`sqrrl__world_from_json` relies on a
    non-`keepalive` table's own `keepalive` set too, to retain whatever it
    reconstructs -- see `emit_world_module`); `is_keepalive` only
    controls whether *ordinary* `create`/`sqrrl__create_with_id`
    automatically add every entity to it (holding a strong reference, so
    it survives past whatever scope constructed it) -- see `emit_table`.
    `all()` (unconditional, regardless of `is_keepalive`) returns every
    currently-live entity via the table's own id allocator, not this set.

    `type_params` (only ever non-empty for a plain struct -- an `@@struct`
    is never generic) is its own `[T: Bound, ...]` list, if any -- see
    `TypeParam`'s own doc comment."""

    var name: String
    var fields: List[Field]
    var is_keepalive: Bool
    var type_params: List[TypeParam]

    def __init__(
        out self,
        var name: String,
        var fields: List[Field],
        is_keepalive: Bool = False,
        var type_params: List[TypeParam] = List[TypeParam](),
    ):
        self.name = name^
        self.fields = fields^
        self.is_keepalive = is_keepalive
        self.type_params = type_params^


@fieldwise_init
struct ConstructField(Copyable, Movable):
    """One `.name = value` (or, for a relation field, `.@@name = value`)
    segment inside a `@@TypeName { ... }` construct body -- `is_relation`
    mirrors the struct declaration's own marking (`@@name: @@Type`), which
    codegen validates against the project-wide relation schema (a
    mismatch, either direction, is rejected the same way a struct
    declaration's own name/type marking mismatch already is). It's also
    what tells codegen `value` might itself need marker rewriting -- a bare
    reference to an already-constructed entity (`@@bob`) or a nested
    construct (`@@Employee { ... }`) -- rather than being passed through as
    opaque text; a plain (non-`@@`) value is assumed already-valid Mojo and
    left untouched either way. `value` is raw, untrimmed-of-markers text --
    interpreting it is codegen's job, not this parser's."""

    var name: String
    var is_relation: Bool
    var value: String


@fieldwise_init
struct Construct(Copyable, Movable):
    """A `@@TypeName { .field = expr, ... }` construction use site --
    `fields` is `parse_construct_fields`' structured breakdown of the
    braced body, one entry per top-level `.name = value` segment."""

    var type_name: String
    var fields: List[ConstructField]


@fieldwise_init
struct FieldAccess(Copyable, Movable):
    """A `@@entity.field` use-site access -- a read, or (if `write_value` is
    set) a write from `@@entity.field = expr;`. `hops` holds any
    intermediate `@@relation` segments in a chain (`@@alice.@@employee.@@boss.title`
    -> `hops = ["employee", "boss"]`, `field = "title"`) -- each one is
    itself a relation field, followed to reach the next entity, with
    `field` (never `@@`-marked) being the terminal, actual field read or
    written. `hops` is empty for the ordinary single-hop case
    (`@@entity.field`).

    `is_call` is set instead when `field` is immediately followed by `(` --
    `@@Type.method(args)`, a table-level call (e.g. `@@Person.for_name(...)`)
    rather than an instance field access. Codegen (not this parser) is what
    actually tells the two apart semantically, by checking whether `entity`
    names a declared variable or a known `@@struct` type -- this parser
    only distinguishes them syntactically, same as it already does for a
    write (`field =`) vs. a read (bare `field`).

    `field_marked` is true when the terminal `field` itself was reached via
    a `.@@name` segment with nothing further after it (`@@alice.@@dept`)
    rather than a plain `.name` (`@@alice.dept`) -- both parse to the same
    `field`, but codegen (not this parser) requires the two to agree with
    whether `field` actually names a relation: a relation must be marked to
    be read this way, a plain field must not be, so the `@@` marking on the
    very last hop stays meaningful instead of becoming cosmetic.

    `index_expr` holds the raw text between `[` and `]` when `entity` is
    immediately followed by that instead of `.` -- `@@people[0].name`,
    indexing into a container-typed `@@`-tracked variable (see
    `EntityParam.wrapper`) before resolving the rest of the chain exactly
    as an ordinary single entity would. `None` for the ordinary,
    non-indexed case. Left as raw text (not parsed further here) since it
    may itself embed further `@@`-marked sub-expressions -- codegen
    recursively rewrites it through `rewrite_markers`, same treatment as a
    construct field's value."""

    var entity: String
    var hops: List[String]
    var field: String
    var field_marked: Bool
    var write_value: Optional[String]
    var is_call: Bool
    var index_expr: Optional[String]


@fieldwise_init
struct NameRef(Copyable, Movable):
    """A bare `@@name` -- covers both a declaration (`var @@alice = ...`)
    and a plain reference; both rewrite the same way (strip the `@@`).
    Also what `MarkerKind.RETURN_TYPE` parses (both the bare `-> @@Type:`
    and container `-> List[@@Type]:` forms) -- codegen emits the identical
    `EntityHandle[...]` text either way, since a container wrapper's own
    `List[`/`]` are never consumed here at all, just left as ordinary
    pass-through text on either side of the marker (unlike `EntityParam`'s
    `wrapper`, which *is* consumed, because there the whole `@@name:
    Container[@@Type]` span belongs to one marker with nothing of its own
    already sitting outside it)."""

    var name: String


@fieldwise_init
struct EntityParam(Copyable, Movable):
    """A `@@name: @@Type` declaration -- same shape as a `@@struct` relation
    field (`@@employee: @@Employee`) -- used in two places: a `def`'s own
    parameter list (`def foo(@@subject: @@Person, @@)`), letting an
    already-constructed entity (a plain Mojo local otherwise, same as any
    `@@`-marked variable) cross into a different function by naming it and
    its type; or a local variable declaration
    (`var @@dept: @@Department = make_department(@@);`), needed whenever
    the right-hand side isn't itself a bare `@@`-marked expression (a
    `@@Type{...}` construct or another `@@`-marked entity) -- a function
    call, for instance -- so there's no construct/reference for
    `entity_to_type` to infer the type from; the explicit annotation gives
    it directly instead. Either way this both gives the name a properly
    typed Mojo declaration and registers it in `entity_to_type` so
    `@@name.field` works afterward. Passing an existing entity at a call
    site needs no new syntax either way, since a bare `@@name` there
    already rewrites to a plain reference.

    `wrapper` is set instead for a container form, `@@name: Container[@@Type]`
    (`List[@@Person]`, `InlineArray[@@Person]`, or any other container
    identifier -- this parser doesn't care which, since codegen only ever
    splices `wrapper` back in verbatim as the Mojo type constructor to wrap
    `EntityHandle[...]` in, never inspecting it itself). `@@name[i].field`
    then indexes into it before resolving the field, same grammar as
    `FieldAccess.index_expr`."""

    var name: String
    var type_name: String
    var wrapper: Optional[String]


@fieldwise_init
struct MarkerKind(ImplicitlyCopyable, Movable, Equatable):
    """What `Scanner.find_next_marker` found. Mojo has no `enum` keyword --
    this is the standard idiom: a struct wrapping a discriminant, with
    named `comptime` values, giving a distinct type instead of a bare `Int`
    that any stray integer could be mistaken for."""

    var value: Int

    comptime NONE = Self(0)
    comptime STRUCT = Self(1)
    comptime CONSTRUCT = Self(2)
    comptime FIELD_ACCESS = Self(3)
    comptime NAME_REF = Self(4)
    comptime INIT = Self(5)
    comptime WORLD_FUNC = Self(6)
    comptime ENTITY_PARAM = Self(7)
    comptime RETURN_TYPE = Self(8)
    comptime PLAIN_STRUCT = Self(9)
    comptime FOR_ENTITY_LOOP = Self(10)
    comptime START_INIT_FROM_JSON = Self(11)
    comptime FINALIZE_INIT_FROM_JSON = Self(12)
    comptime DECLARE = Self(13)

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        return self.value != other.value


