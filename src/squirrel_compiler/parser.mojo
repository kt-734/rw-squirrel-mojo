def source_location(source: String, byte_pos: Int) -> String:
    """1-indexed `"line:col"` for `byte_pos` within `source` -- column counts
    bytes since the last newline, not Unicode codepoints (fine here: every
    position this is ever called with points at a grammar token -- `{`,
    `@@`, an identifier, ... -- and those are all ASCII; only string-literal
    *contents* can be non-ASCII, and nothing ever raises pointing inside
    one). Spliced into every raised error so a message says exactly where in
    a `.rel` file it happened, not just that it did -- `Scanner.err` is the
    usual way this gets called, but it's a free function (not a method)
    since a couple of raise sites (`codegen.build_create_call`,
    `enforce_entity_binding`) have a `source`/position in scope without a
    live `Scanner` there to ask."""
    var line = 1
    var col = 1
    var bytes = source.as_bytes()
    var limit = byte_pos if byte_pos < len(bytes) else len(bytes)
    for i in range(limit):
        if bytes[i] == UInt8(ord("\n")):
            line += 1
            col = 1
        else:
            col += 1
    return String(line) + ":" + String(col)


def line_indent_of(source: String, pos: Int) -> Int:
    """Number of leading space/tab bytes on the line containing byte offset
    `pos` -- the baseline `Scanner.scan_indented_block` compares every
    following line's own indentation against, the same way a `@@struct`
    header's column tells Python/Mojo where its body block's fields must be
    indented past."""
    var bytes = source.as_bytes()
    var line_start = pos
    while line_start > 0 and bytes[line_start - 1] != UInt8(ord("\n")):
        line_start -= 1
    var i = line_start
    while i < len(bytes) and (bytes[i] == UInt8(ord(" ")) or bytes[i] == UInt8(ord("\t"))):
        i += 1
    return i - line_start


def is_ident_char(b: UInt8) -> Bool:
    return (
        (b >= UInt8(ord("a")) and b <= UInt8(ord("z")))
        or (b >= UInt8(ord("A")) and b <= UInt8(ord("Z")))
        or (b >= UInt8(ord("0")) and b <= UInt8(ord("9")))
        or b == UInt8(ord("_"))
    )


def is_after_arrow(source: String, pos: Int) -> Bool:
    """True if, scanning backward from byte offset `pos` (skipping spaces
    and tabs), the two bytes immediately before are `-` then `>` -- i.e.
    `pos` sits right after a `->` (Mojo's return-type arrow), modulo
    whitespace. Used to tell a return-type marking (`-> @@Type:`) apart
    from any other bare `@@name:` shape (which keeps its existing
    `MarkerKind.NAME_REF` fallback -- see `Scanner.find_next_marker`)."""
    var bytes = source.as_bytes()
    var i = pos
    while i > 0 and (bytes[i - 1] == UInt8(ord(" ")) or bytes[i - 1] == UInt8(ord("\t"))):
        i -= 1
    return i >= 2 and bytes[i - 1] == UInt8(ord(">")) and bytes[i - 2] == UInt8(ord("-"))


def is_after_for_keyword(source: String, pos: Int) -> Bool:
    """True if, scanning backward from byte offset `pos` (skipping spaces/
    tabs, and one optional `var`/`ref` keyword in between), the preceding
    text is `for` with a word boundary before it too -- `pos` sits right
    after `for `, `for var `, or `for ref ` (mod whitespace), the shapes a
    `for @@name in ...:`/`for var @@name in ...:`/`for ref @@name in ...:`
    loop's own target variable needs to recognize itself by (see
    `MarkerKind.FOR_ENTITY_LOOP`), as opposed to an ordinary, unmarked-target
    `for name in ...:` loop (left untouched -- no `@@` there for this
    scanner to ever reach in the first place). `var`/`ref` matter in
    practice, not just style: Mojo's own exclusivity checker sometimes
    *requires* one of them on a loop target -- `var` for an owned copy,
    `ref` for an explicit (rather than the default, sometimes-ambiguous
    implicit) reference -- when the loop body indexes back into the same
    container being iterated. Confirmed via a direct repro (`for state in
    capitals: print(capitals[state])` rejected with 'argument of
    __getitem__ call allows reading a memory location previously writable
    through another aliased argument'; `for var state in capitals:`
    compiles fine)."""
    var bytes = source.as_bytes()
    var i = pos
    while i > 0 and (bytes[i - 1] == UInt8(ord(" ")) or bytes[i - 1] == UInt8(ord("\t"))):
        i -= 1
    if i >= 3 and (
        String(source[byte = i - 3 : i]) == "var" or String(source[byte = i - 3 : i]) == "ref"
    ) and (i == 3 or not is_ident_char(bytes[i - 4])):
        i -= 3
        while i > 0 and (bytes[i - 1] == UInt8(ord(" ")) or bytes[i - 1] == UInt8(ord("\t"))):
            i -= 1
    if i < 3:
        return False
    if String(source[byte = i - 3 : i]) != "for":
        return False
    return i == 3 or not is_ident_char(bytes[i - 4])


def is_after_container_bracket(source: String, pos: Int) -> Bool:
    """True if byte offset `pos` sits inside `Ident[...]`'s bracket list, at
    *any* parameter position -- not just immediately after `[`
    (`List[@@Type`), but also after a `,` for a later parameter
    (`Dict[@@Type, V]`'s second slot, `Dict[K, @@Type]`'s own -- wherever
    that container appears: a return type (`-> Dict[@@Type, V]:`), a
    parameter type, or a bare generic-instantiation expression
    (`Dict[@@Type, V]()`). Scans backward from `pos` (the `@@` of the type
    name itself -- that's where the marker scanner finds it, the outer
    `Ident[` already scanned past as ordinary text on an earlier
    iteration), tracking bracket/paren/brace depth so an intervening
    parameter that's itself generic (`Dict[@@Type, List[Int]]`) doesn't
    confuse it, until it finds the *enclosing* `[` at depth 0 and checks
    for an identifier immediately before that. Bounded to the current
    line (stops at a newline) -- same single-line assumption
    `is_in_def_signature` already makes -- so this can't wander off into
    unrelated, far-earlier code looking for some other `Ident[`."""
    var bytes = source.as_bytes()
    var i = pos
    var depth = 0
    while i > 0:
        var b = bytes[i - 1]
        if b == UInt8(ord("\n")):
            return False
        if b == UInt8(ord("]")) or b == UInt8(ord(")")) or b == UInt8(ord("}")):
            depth += 1
        elif b == UInt8(ord("[")):
            if depth == 0:
                var j = i - 1
                while j > 0 and (bytes[j - 1] == UInt8(ord(" ")) or bytes[j - 1] == UInt8(ord("\t"))):
                    j -= 1
                var ident_end = j
                while j > 0 and is_ident_char(bytes[j - 1]):
                    j -= 1
                return j != ident_end
            depth -= 1
        elif b == UInt8(ord("(")) or b == UInt8(ord("{")):
            if depth == 0:
                return False
            depth -= 1
        i -= 1
    return False


def is_unmarked_container_declaration(source: String, marker_start: Int) -> Bool:
    """True if, scanning further backward past the `Ident[` that
    `is_after_container_bracket(source, marker_start)` already confirmed
    precedes `marker_start`, the text matches `name: Ident[` (mod
    whitespace) -- a `name: Container[@@Type]` field or variable
    declaration whose `name` isn't itself `@@`-marked, the same shape
    `parse_fields` already rejects inside a `@@struct` body but which
    reaches ordinary marker scanning unenforced anywhere else (a
    hand-written plain `struct`'s own field, or a bare `var name:
    List[@@Type] = ...`) -- confirmed empirically: `var members:
    List[@@Employee]` inside a plain Mojo struct compiled silently, with
    the type rewritten to `List[EntityHandle[...]]` but no requirement that
    `members` itself be written `@@members`.

    If `name` WERE `@@`-marked, `EntityParam`'s own forward-looking
    `@@name: Container[@@Type]` check (`Scanner.at_wrapped_entity_param`)
    would already have classified the whole thing as `ENTITY_PARAM` the
    moment the scanner reached `@@name`, well before it ever got to this
    inner `@@Type` as an independent marker -- so simply finding an
    unmarked `name:` here is sufficient; there's no marked case this could
    also be matching. Returns `False` for a return type (`->
    Container[@@Type]:`, nothing before `Ident[` but an arrow) or a bare
    generic instantiation (`Container[@@Type]()`, nothing meaningful
    before `Ident[` at all) -- neither has a name to enforce marking on."""
    var bytes = source.as_bytes()
    var i = marker_start
    while i > 0 and (bytes[i - 1] == UInt8(ord(" ")) or bytes[i - 1] == UInt8(ord("\t"))):
        i -= 1
    if i == 0 or bytes[i - 1] != UInt8(ord("[")):
        return False
    i -= 1
    while i > 0 and (bytes[i - 1] == UInt8(ord(" ")) or bytes[i - 1] == UInt8(ord("\t"))):
        i -= 1
    var wrapper_end = i
    while i > 0 and is_ident_char(bytes[i - 1]):
        i -= 1
    if i == wrapper_end:
        return False
    while i > 0 and (bytes[i - 1] == UInt8(ord(" ")) or bytes[i - 1] == UInt8(ord("\t"))):
        i -= 1
    if i == 0 or bytes[i - 1] != UInt8(ord(":")):
        return False
    i -= 1
    while i > 0 and (bytes[i - 1] == UInt8(ord(" ")) or bytes[i - 1] == UInt8(ord("\t"))):
        i -= 1
    var name_end = i
    while i > 0 and is_ident_char(bytes[i - 1]):
        i -= 1
    return i != name_end


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
    `is_keepalive` gets the generated table a `keepalive:
    Set[EntityHandle[...]]` (holding a strong reference to every entity
    `create` makes, so it survives past whatever scope constructed it), a
    `dont_keepalive(e)` method to release one back to ordinary refcounted
    lifetime, and an `all()` method returning the current keepalive set --
    see `emit_table`.

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

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        return self.value != other.value


def parse_construct_fields(body: String) raises -> List[ConstructField]:
    """Splits a construct's braced body into `.name = value` /
    `.@@name = value` segments, each becoming a `ConstructField` -- same
    top-level-comma/bracket-depth tracking an earlier flat-text version of
    this used, but keeping each field's name, relation-marking, and value
    text apart instead of collapsing everything back into one opaque
    string (dots and commas nested inside brackets or strings still pass
    through untouched, as part of a field's `value`, same as before)."""
    var bs = Scanner(body)
    var out = List[ConstructField]()
    while True:
        bs.skip_trivia()
        if bs.at_end():
            break
        if not bs.try_consume("."):
            raise bs.err(
                "InvalidSquirrelSyntax: expected '.' before field name in"
                " construct"
            )
        var is_relation = bs.try_consume("@@")
        var name = bs.scan_ident()
        if name.byte_length() == 0:
            raise bs.err("InvalidSquirrelSyntax: expected field name in construct")
        bs.skip_trivia()
        if not bs.try_consume("="):
            raise bs.err(
                "InvalidSquirrelSyntax: expected '=' after field name in"
                " construct"
            )
        bs.skip_whitespace()
        var value_start = bs.pos
        var depth = 0
        while not bs.at_end():
            var before = bs.pos
            bs.skip_non_code()
            if bs.pos != before:
                continue
            var b = bs.peek()
            if b == UInt8(ord("(")) or b == UInt8(ord("[")) or b == UInt8(ord("{")):
                depth += 1
            elif b == UInt8(ord(")")) or b == UInt8(ord("]")) or b == UInt8(ord("}")):
                depth -= 1
            elif b == UInt8(ord(",")) and depth == 0:
                break
            bs.pos += 1
        var value = String(body[byte = value_start : bs.pos]).strip()
        out.append(ConstructField(name=name, is_relation=is_relation, value=String(value)))
        _ = bs.try_consume(",")
    return out^


struct Scanner(Movable):
    """A cursor over `.rel` source text. Every scanning/skipping operation
    here routes through `skip_non_code` so that a `{`, `}`, `,`, or `@@`
    sitting inside a `//` comment or a string literal never desyncs
    anything -- matching the Zig parser's `skipNonCode`, just expressed as
    mutating cursor state instead of threading `(source, pos)` through every
    call."""

    var source: String
    var pos: Int

    def __init__(out self, var source: String):
        self.source = source^
        self.pos = 0

    def err(self, msg: String) -> Error:
        """Builds an `Error` prefixed with this scanner's current position
        (`source_location(self.source, self.pos)`) -- every raise site in
        this file does `raise self.err("...")` instead of `raise
        Error("...")`, so every `InvalidSquirrelSyntax` (and friends) says
        where in the source text it happened, not just that it did. Returns
        (rather than itself raising) so the call site keeps its own `raise`,
        same as constructing an `Error` directly."""
        return Error(source_location(self.source, self.pos) + ": " + msg)

    def at_end(self) -> Bool:
        return self.pos >= self.source.byte_length()

    def byte_at(self, i: Int) -> UInt8:
        return self.source.as_bytes()[i]

    def peek(self) -> UInt8:
        if self.at_end():
            return 0
        return self.byte_at(self.pos)

    def peek_at(self, offset: Int) -> UInt8:
        var i = self.pos + offset
        if i >= self.source.byte_length():
            return 0
        return self.byte_at(i)

    def starts_with(self, literal: String) -> Bool:
        var end = self.pos + literal.byte_length()
        if end > self.source.byte_length():
            return False
        return self.source[byte = self.pos : end] == literal

    def try_consume(mut self, literal: String) -> Bool:
        if self.starts_with(literal):
            self.pos += literal.byte_length()
            return True
        return False

    def skip_whitespace(mut self):
        while not self.at_end():
            var b = self.peek()
            if (
                b == UInt8(ord(" "))
                or b == UInt8(ord("\t"))
                or b == UInt8(ord("\n"))
                or b == UInt8(ord("\r"))
            ):
                self.pos += 1
            else:
                break

    def skip_non_code(mut self):
        """If positioned at a `#` or `//` line comment or a `"`/`'` string
        literal, advances past it. No-op otherwise. `#` is real Mojo's own
        comment syntax; `//` is carried over from this compiler's original
        Zig-targeting version -- kept alongside `#` rather than replaced,
        since recognizing it costs nothing and a stray `//` in a string or
        elsewhere is already handled by the ordering here (checked before
        this function is reached, `//` only ever matters at a real code
        position). Undiscovered until a real `.rel` example first used a
        `#` comment mentioning `@@` and had it wrongly treated as a live
        marker -- no earlier example ever used a comment at all."""
        if self.at_end():
            return
        if self.peek() == UInt8(ord("#")) or (
            self.peek() == UInt8(ord("/")) and self.peek_at(1) == UInt8(ord("/"))
        ):
            while not self.at_end() and self.peek() != UInt8(ord("\n")):
                self.pos += 1
            return
        if self.peek() == UInt8(ord('"')) or self.peek() == UInt8(ord("'")):
            var quote = self.peek()
            self.pos += 1
            while not self.at_end() and self.peek() != quote:
                if self.peek() == UInt8(ord("\\")) and not self.at_end():
                    self.pos += 1
                self.pos += 1
            if not self.at_end():
                self.pos += 1  # consume closing quote

    def skip_trivia(mut self):
        """Skips whitespace and comments/strings, interleaved, until real
        code or end of input."""
        while True:
            var before = self.pos
            self.skip_whitespace()
            self.skip_non_code()
            if self.pos == before:
                return

    def scan_ident(mut self) -> String:
        var start = self.pos
        while not self.at_end() and is_ident_char(self.peek()):
            self.pos += 1
        return String(self.source[byte = start : self.pos])

    def scan_braced_span(mut self) raises -> String:
        """Requires `self.pos` at `{`. Returns the body between the matching
        braces (exclusive), and advances `self.pos` past the closing `}`."""
        if self.peek() != UInt8(ord("{")):
            raise self.err("InvalidSquirrelSyntax: expected '{'")
        self.pos += 1
        var body_start = self.pos
        var depth = 1
        while not self.at_end() and depth > 0:
            var before = self.pos
            self.skip_non_code()
            if self.pos != before:
                continue
            var b = self.peek()
            if b == UInt8(ord("{")):
                depth += 1
            elif b == UInt8(ord("}")):
                depth -= 1
            self.pos += 1
        if depth != 0:
            raise self.err("InvalidSquirrelSyntax: unterminated '{'")
        return String(self.source[byte = body_start : self.pos - 1])

    def scan_indented_block(mut self, header_indent: Int) -> String:
        """Requires `self.pos` right after a block header's own trailing
        `:` (e.g. `@@struct @@Name:`). Consumes the rest of the header line
        (assumed empty beyond the `:`) plus every following line that's
        either blank or indented more than `header_indent`, matching
        Python/Mojo's own indentation-block convention -- stopping (without
        consuming) at the first non-blank line indented at or below
        `header_indent`, or at end of input. Returns the consumed span, from
        just after the header's own newline through just before the
        stopping line (or end of input) -- unlike `scan_braced_span`, there's
        no explicit closing token to exclude, so nothing needs trimming off
        the end."""
        while not self.at_end() and self.peek() != UInt8(ord("\n")):
            self.pos += 1
        if not self.at_end():
            self.pos += 1
        var body_start = self.pos
        var bytes = self.source.as_bytes()
        while not self.at_end():
            var line_start = self.pos
            var i = line_start
            while i < len(bytes) and (
                bytes[i] == UInt8(ord(" ")) or bytes[i] == UInt8(ord("\t"))
            ):
                i += 1
            var is_blank = i >= len(bytes) or bytes[i] == UInt8(ord("\n"))
            if not is_blank and (i - line_start) <= header_indent:
                break
            while not self.at_end() and self.peek() != UInt8(ord("\n")):
                self.pos += 1
            if not self.at_end():
                self.pos += 1
        return String(self.source[byte = body_start : self.pos])

    def scan_bracketed_span(mut self) raises -> String:
        """Requires `self.pos` at `[`. Returns the body between the matching
        brackets (exclusive), and advances `self.pos` past the closing `]`
        -- mirrors `scan_braced_span`, for `@@entity[index_expr]`."""
        if self.peek() != UInt8(ord("[")):
            raise self.err("InvalidSquirrelSyntax: expected '['")
        self.pos += 1
        var body_start = self.pos
        var depth = 1
        while not self.at_end() and depth > 0:
            var before = self.pos
            self.skip_non_code()
            if self.pos != before:
                continue
            var b = self.peek()
            if b == UInt8(ord("[")):
                depth += 1
            elif b == UInt8(ord("]")):
                depth -= 1
            self.pos += 1
        if depth != 0:
            raise self.err("InvalidSquirrelSyntax: unterminated '['")
        return String(self.source[byte = body_start : self.pos - 1])

    def scan_type(mut self) -> String:
        """Scans a field's type text: up to the next top-level `,` or `\\n`
        (ignoring either nested inside `[]`/`()`/`{}`) or the end of input.
        Trimmed. The `\\n` case is what lets `@@struct`'s newline-separated
        fields (no trailing comma required, one per line) terminate a type
        correctly; a comma-separated body (a plain struct's brace form)
        still stops at its comma first, on the same line, same as always."""
        var start = self.pos
        var depth = 0
        while not self.at_end():
            var before = self.pos
            self.skip_non_code()
            if self.pos != before:
                continue
            var b = self.peek()
            if b == UInt8(ord("[")) or b == UInt8(ord("(")) or b == UInt8(ord("{")):
                depth += 1
            elif b == UInt8(ord("]")) or b == UInt8(ord(")")) or b == UInt8(ord("}")):
                depth -= 1
            elif b == UInt8(ord(",")) and depth == 0:
                break
            elif b == UInt8(ord("\n")) and depth == 0:
                break
            self.pos += 1
        var raw = String(self.source[byte = start : self.pos])
        return String(raw.strip())

    def _scan_type_param_bound(mut self) -> String:
        """Like `scan_type`, but for a `[T: Bound, ...]` type-parameter
        list's own bound text specifically -- stops (without consuming) at
        a top-level `,` *or* a top-level closing `]`/`)`/`}`, rather than
        `scan_type`'s `,`/`\\n`. `scan_type` can't be reused here: its own
        depth counter starts at 0 assuming it's scanning a type that owns
        its *own* brackets, so hitting the type-parameter list's closing
        `]` (already consumed by the caller as the list's own delimiter,
        not part of any type this scans) would decrement past zero and
        keep consuming instead of stopping -- confirmed by direct
        inspection of what `scan_type` does at depth 0 on a closing
        bracket it didn't open."""
        var start = self.pos
        var depth = 0
        while not self.at_end():
            var before = self.pos
            self.skip_non_code()
            if self.pos != before:
                continue
            var b = self.peek()
            if b == UInt8(ord("[")) or b == UInt8(ord("(")) or b == UInt8(ord("{")):
                depth += 1
            elif b == UInt8(ord("]")) or b == UInt8(ord(")")) or b == UInt8(ord("}")):
                if depth == 0:
                    break
                depth -= 1
            elif b == UInt8(ord(",")) and depth == 0:
                break
            self.pos += 1
        var raw = String(self.source[byte = start : self.pos])
        return String(raw.strip())

    def parse_type_params(mut self) raises -> List[TypeParam]:
        """Requires `self.pos` at `[` -- a plain struct's own `[T: Bound,
        ...]` type-parameter list, immediately after its name (shorthand
        or hand-written; an `@@struct` never has one). Returns the parsed
        list, advancing `self.pos` past the closing `]`. A parameter with
        no explicit `: Bound` gets `"Copyable & ImplicitlyDeletable"` --
        see `TypeParam`'s own doc comment for why."""
        if not self.try_consume("["):
            raise self.err("InvalidSquirrelSyntax: expected '['")
        var out = List[TypeParam]()
        self.skip_trivia()
        if self.try_consume("]"):
            return out^
        while True:
            self.skip_trivia()
            var name = self.scan_ident()
            if name.byte_length() == 0:
                raise self.err("InvalidSquirrelSyntax: expected type parameter name")
            self.skip_trivia()
            var bound = "Copyable & ImplicitlyDeletable"
            if self.try_consume(":"):
                self.skip_trivia()
                bound = self._scan_type_param_bound()
                if bound.byte_length() == 0:
                    raise self.err(
                        "InvalidSquirrelSyntax: expected type parameter bound after ':'"
                    )
            out.append(TypeParam(name=name, bound=bound))
            self.skip_trivia()
            if self.try_consume(","):
                continue
            if self.try_consume("]"):
                break
            raise self.err("InvalidSquirrelSyntax: expected ',' or ']' in type parameter list")
        return out^

    def find_next_struct_decl(mut self) -> Bool:
        """Advances to the start of the next `@@struct` occurrence at
        real-code depth. Returns False (leaving `self.pos` at the end) if
        there isn't one."""
        while True:
            self.skip_trivia()
            if self.at_end():
                return False
            if self.starts_with("@@struct"):
                return True
            self.pos += 1

    def peek_empty_call_follows(mut self) -> Bool:
        """True if, from `self.pos` (skipping trivia around both the `(`
        and `)`), an empty call `()` follows -- never moves `self.pos`
        permanently either way, since callers manage that differently
        afterward (one resets to a saved marker start and returns a marker
        kind, the other resets and returns a plain `Bool`). Shared by
        `find_next_marker`'s and `find_next_init_call`'s identical
        `@@init()` detection."""
        var save = self.pos
        self.skip_trivia()
        var matched = False
        if self.peek() == UInt8(ord("(")):
            self.pos += 1
            self.skip_trivia()
            matched = self.peek() == UInt8(ord(")"))
        self.pos = save
        return matched

    def find_next_init_call(mut self) -> Bool:
        """Advances to the start of the next `@@init()` call at real-code
        depth -- used only to *count* occurrences project-wide
        (`driver.check_single_init_call`), not to parse or consume anything
        else about the surrounding source, so it doesn't need the full
        marker-dispatch loop `transform_source` runs. Returns False
        (leaving `self.pos` at the end) if there isn't one."""
        while True:
            self.skip_trivia()
            if self.at_end():
                return False
            if self.starts_with("@@"):
                var marker_start = self.pos
                self.pos += 2
                var ident = self.scan_ident()
                if ident == "init" and self.peek_empty_call_follows():
                    self.pos = marker_start
                    return True
                self.pos = marker_start + 2
                continue
            self.pos += 1

    def at_bare_struct_keyword(self) -> Bool:
        """True if `self.pos` sits at a bare `struct` keyword occurrence
        (not `@@struct`) with a word boundary on both sides -- not preceded
        by an identifier char or by `@@`, not followed by an identifier
        char -- so `construct`, `MyStructType`, or a real `@@struct` aren't
        mistaken for it. Shared by `find_next_plain_struct_decl` and
        `find_next_plain_struct_name`, which differ only in what they do
        once they've found one (parse a shorthand body's fields vs. just
        take the name)."""
        if not self.starts_with("struct"):
            return False
        var before_is_ident = self.pos > 0 and is_ident_char(self.byte_at(self.pos - 1))
        var before_is_at = self.pos >= 2 and self.byte_at(self.pos - 1) == UInt8(
            ord("@")
        ) and self.byte_at(self.pos - 2) == UInt8(ord("@"))
        var after = self.pos + String("struct").byte_length()
        var after_is_ident = after < self.source.byte_length() and is_ident_char(
            self.byte_at(after)
        )
        return not before_is_ident and not before_is_at and not after_is_ident

    def find_next_plain_struct_decl(mut self) raises -> Bool:
        """Advances to the start of the next bare `struct` occurrence (not
        `@@struct`) at real-code depth, *only* if its body uses the same
        brace-delimited shorthand grammar `@@struct` bodies do (`struct Name
        { field: Type, ... }`) -- an ordinary Mojo struct a `.rel` file
        defines directly, outside the managed-table DSL. It never gets a
        generated Table/State pair the way `@@struct` does; this exists
        purely so `check_no_relation_cycles` can see whether such a
        struct's body smuggles a `@@`-marked relation field that would
        otherwise be an invisible way to complete a construction cycle back
        through a real `@@struct` (a plain field elsewhere naming this
        struct wouldn't reveal that on its own).

        A *real*, hand-written Mojo struct (`struct Name(Traits...):` or
        `struct Name:`, followed by an indented `var` block, not `{`) is
        left invisible here rather than raising a parse error -- confirmed:
        `scan_braced_span` unconditionally requiring `{` right after the
        name used to abort the *entire* `convert_directory` run the moment
        any `.rel` file declared an ordinary Mojo struct anywhere, since
        that's the only way to declare a non-generated helper type at all.
        The tradeoff: a relation smuggled through a real (non-shorthand)
        plain struct's own fields isn't caught by `check_no_relation_cycles`
        -- accepted, since writing that requires spelling out the
        underlying generated type (`EntityHandle[sqrrl__PersonTableState]`)
        by hand, a much more deliberate act than the shorthand form's `@@`
        sugar. Returns False (leaving `self.pos` at the end) if there isn't
        a brace-shorthand one. A generic plain struct's own `[T: Bound,
        ...]` list (if any) sits between the name and the `{`/non-`{`
        that decides shorthand vs hand-written -- skipped here via
        `parse_type_params` (discarding the result) purely to see past it
        to whatever follows."""
        while True:
            self.skip_trivia()
            if self.at_end():
                return False
            if self.at_bare_struct_keyword():
                var struct_start = self.pos
                var after = self.pos + String("struct").byte_length()
                self.pos = after
                self.skip_trivia()
                var name = self.scan_ident()
                self.skip_trivia()
                if name.byte_length() > 0 and self.peek() == UInt8(ord("[")):
                    _ = self.parse_type_params()
                    self.skip_trivia()
                var is_shorthand = name.byte_length() > 0 and self.peek() == UInt8(ord("{"))
                if is_shorthand:
                    self.pos = struct_start
                    return True
                self.pos = after
                continue
            self.pos += 1

    def find_next_plain_struct_name(mut self) -> Optional[String]:
        """Advances past the next bare `struct Name` occurrence (not
        `@@struct`) and returns `Name`, regardless of what follows it -- a
        brace-shorthand body (`{ ... }`) or a real, hand-written Mojo one
        (`(Traits...):`/`:` + an indented `var` block). Unlike
        `find_next_plain_struct_decl`, this never needs to parse the body
        at all, just the name -- used only to know a plain struct's name
        and declaring file for cross-file import purposes
        (`driver.build_cross_file_symbols`), which doesn't care whether the
        body is parseable the way `check_no_relation_cycles` does. Returns
        `None` (leaving `self.pos` at the end) once there are no more."""
        while True:
            self.skip_trivia()
            if self.at_end():
                return None
            if self.at_bare_struct_keyword():
                var after = self.pos + String("struct").byte_length()
                self.pos = after
                self.skip_trivia()
                var name = self.scan_ident()
                if name.byte_length() > 0:
                    return name
                continue
            self.pos += 1

    def parse_struct(mut self) raises -> ParsedStruct:
        """Requires `self.pos` at the `@@struct` token, e.g. right after
        `find_next_struct_decl` returns True. Grammar: `@@struct [keepalive]
        @@Name:` followed by an indented block of newline-separated fields
        (no commas) -- real Mojo's own struct-header shape, unlike the plain
        shorthand struct's brace-delimited body (see `parse_plain_struct`).
        The name is `@@`-marked (`@@struct @@Department:`, not `@@struct
        Department:`) for the same reason a relation field's own name is --
        every place an entity-struct's name appears stays consistently
        `@@`-prefixed, matching `@@Department{...}`/`@@dept: @@Department`."""
        var header_indent = line_indent_of(self.source, self.pos)
        if not self.try_consume("@@struct"):
            raise self.err("InvalidSquirrelSyntax: expected '@@struct'")
        self.skip_trivia()
        var is_keepalive = False
        if self.starts_with("keepalive") and not is_ident_char(self.peek_at(9)):
            self.pos += 9
            self.skip_trivia()
            is_keepalive = True
        if not self.try_consume("@@"):
            raise self.err("InvalidSquirrelSyntax: expected '@@' before struct name ('@@struct @@Name:')")
        var name = self.scan_ident()
        if name.byte_length() == 0:
            raise self.err("InvalidSquirrelSyntax: expected struct name")
        self.skip_trivia()
        if not self.try_consume(":"):
            raise self.err("InvalidSquirrelSyntax: expected ':' after struct name")
        var body = self.scan_indented_block(header_indent)
        var fields = parse_fields(body)
        return ParsedStruct(name=name, fields=fields^, is_keepalive=is_keepalive)

    def parse_plain_struct(mut self) raises -> ParsedStruct:
        """Requires `self.pos` at the bare `struct` token, e.g. right after
        `find_next_plain_struct_decl` returns True. Unlike `parse_struct`,
        this keeps the brace-delimited shorthand grammar (`struct Name {
        field: Type, ... }`) -- a plain struct never gets a generated table,
        so there's no `@@`-marked name either (it isn't itself a tracked
        entity type). An optional `[T: Bound, ...]` type-parameter list
        (`parse_type_params`) sits between the name and the `{` -- a field
        can then use `T` bare (`value: T`), the intended shorthand style,
        same as any other type. Also tolerates a field spelled out with
        the real-Mojo `Self.T` qualification instead (`unqualify_self_type_params`
        normalizes either spelling to the same bare form) -- harmless
        either way for a *shorthand* struct (unlike a hand-written one,
        where `Self.T` is the only form Mojo itself accepts), but
        skipping the normalization here would double-qualify it right
        back to `Self.Self.T` when `emit_plain_struct` adds its own
        `Self.` prefix, and would leak a literal `Self.T` into
        `emit_plain_struct_from_json`'s generated companion -- a free
        function, where `Self` doesn't exist at all (confirmed both
        failure modes directly)."""
        if not self.try_consume("struct"):
            raise self.err("InvalidSquirrelSyntax: expected 'struct'")
        self.skip_trivia()
        var name = self.scan_ident()
        if name.byte_length() == 0:
            raise self.err("InvalidSquirrelSyntax: expected struct name")
        self.skip_trivia()
        var type_params = List[TypeParam]()
        if self.peek() == UInt8(ord("[")):
            type_params = self.parse_type_params()
            self.skip_trivia()
        var body = self.scan_braced_span()
        var raw_fields = parse_fields(body)
        var fields = List[Field]()
        for field in raw_fields:
            fields.append(
                Field(
                    name=field.name,
                    type_str=unqualify_self_type_params(field.type_str, type_params),
                    modifier=field.modifier,
                )
            )
        return ParsedStruct(name=name, fields=fields^, type_params=type_params^)

    def find_next_hand_written_plain_struct_decl(mut self) raises -> Bool:
        """Advances to the start of the next bare `struct Name(...):`/
        `struct Name:` occurrence (not `@@struct`, and not the brace-
        shorthand form `find_next_plain_struct_decl` already handles) -- a
        *real*, hand-written Mojo struct. Its body is never fully parsed by
        this compiler (`check_no_relation_cycles` still can't see through
        one -- see `find_next_plain_struct_decl`'s own doc comment, an
        accepted, unrelated gap this doesn't change), but `from_json`
        codegen still needs its field list to serialize/deserialize a
        field of this type correctly instead of raising at runtime -- see
        `parse_hand_written_plain_struct`. Returns False (leaving
        `self.pos` at the end) once there are none left."""
        while True:
            self.skip_trivia()
            if self.at_end():
                return False
            if self.at_bare_struct_keyword():
                var struct_start = self.pos
                var after = self.pos + String("struct").byte_length()
                self.pos = after
                self.skip_trivia()
                var name = self.scan_ident()
                self.skip_trivia()
                if name.byte_length() == 0:
                    self.pos = after
                    continue
                if self.peek() == UInt8(ord("[")):
                    # A generic struct's own `[T: Bound, ...]` sits before
                    # either the `{` this loop is checking for below, or
                    # the `(Traits...)`/`:` `parse_hand_written_plain_struct`
                    # handles -- skip past it here too, purely to see past
                    # it to whichever of those actually follows.
                    _ = self.parse_type_params()
                    self.skip_trivia()
                if self.peek() == UInt8(ord("{")):
                    # Brace shorthand -- already handled by
                    # `find_next_plain_struct_decl`/`discover_plain_structs`
                    # elsewhere; skip past its whole body so it isn't seen
                    # (or double-counted) here too.
                    _ = self.scan_braced_span()
                    continue
                self.pos = struct_start
                return True
            self.pos += 1

    def parse_hand_written_plain_struct(mut self) raises -> ParsedStruct:
        """Requires `self.pos` at the bare `struct` token of a hand-written
        (non-brace) plain struct, e.g. right after
        `find_next_hand_written_plain_struct_decl` returns True. Extracts
        the struct's own name, its own optional `[T: Bound, ...]`
        type-parameter list (`parse_type_params` -- real Mojo syntax
        order: type parameters before the parenthesized trait list), and
        its leading `var name: Type` field declarations (see
        `parse_hand_written_struct_fields`), skipping over an optional
        parenthesized trait list (`(Copyable, Movable, ...)`) between that
        and the header's own trailing `:`. A best-effort structural read,
        not a full Mojo parse -- enough for `from_json` to know this
        struct's own fields, the one thing `sqrrl__from_json[T]`'s generic
        dispatcher can't do for any struct (see its own doc comment in
        `emit_json_module`).

        A field referencing the struct's own type parameter has to say
        `Self.T` in real, hand-written Mojo (Mojo's own requirement, not
        this DSL's -- see `unqualify_self_type_params`'s own doc comment),
        but the extracted field list feeds a *free function*
        (`emit_plain_struct_from_json`'s generated companion), where
        `Self` doesn't exist at all -- so every field's own `type_str` is
        unqualified back to bare `T` right here, once, rather than
        leaving every downstream consumer of this struct's fields to
        remember to do it."""
        var header_indent = line_indent_of(self.source, self.pos)
        if not self.try_consume("struct"):
            raise self.err("InvalidSquirrelSyntax: expected 'struct'")
        self.skip_trivia()
        var name = self.scan_ident()
        if name.byte_length() == 0:
            raise self.err("InvalidSquirrelSyntax: expected struct name")
        self.skip_trivia()
        var type_params = List[TypeParam]()
        if self.peek() == UInt8(ord("[")):
            type_params = self.parse_type_params()
            self.skip_trivia()
        if self.peek() == UInt8(ord("(")):
            var depth = 0
            while not self.at_end():
                var b = self.peek()
                self.pos += 1
                if b == UInt8(ord("(")):
                    depth += 1
                elif b == UInt8(ord(")")):
                    depth -= 1
                    if depth == 0:
                        break
            self.skip_trivia()
        if not self.try_consume(":"):
            raise self.err("InvalidSquirrelSyntax: expected ':' after struct name")
        var body = self.scan_indented_block(header_indent)
        var raw_fields = parse_hand_written_struct_fields(body)
        var fields = List[Field]()
        for field in raw_fields:
            fields.append(
                Field(
                    name=field.name,
                    type_str=unqualify_self_type_params(field.type_str, type_params),
                    modifier=field.modifier,
                )
            )
        return ParsedStruct(name=name, fields=fields^, type_params=type_params^)

    def find_next_marker(mut self) raises -> MarkerKind:
        """Advances to the next `@@`-marked construct at real-code depth and
        reports which kind it is, leaving `self.pos` at the start of the
        marker (ready for the matching `parse_*` call) -- mirrors the Zig
        parser's `findNextMarker`, minus chained relation hops
        (`@@entity.@@relation.field`): those aren't recognized here, so a
        script using them fails with a clear parse error from
        `parse_field_access` rather than being silently mishandled.

        No `.destroy()` marker, unlike Zig's parser: Zig needed it because
        `defer sqrrl__alice.decref()` only releases at the *end of the
        enclosing function*, so an explicit call was the only way to release
        earlier. Mojo's own destruction is already more precise than
        that -- a plain `var alice = ...` drops at its actual last
        mention, not at scope exit -- so there's no gap left for
        `.destroy()` to fill; a `.rel` script just stops referencing an
        entity when it's done, same as any other Mojo value.

        Four more kinds beyond the original four, all driven by Mojo having
        no mutable global/static state (see `Table`'s doc comment in
        `entity.mojo`): `@@init()` (`MarkerKind.INIT`) is the explicit call
        a script makes to obtain `sqrrl__World`'s shared instance,
        `@@name(` (`MarkerKind.WORLD_FUNC`, e.g. `def @@make_department(a:
        Int)` or, at a call site, `@@make_department(x)`) marks a function
        whose *own name* -- not a separate parameter -- signals that it
        needs `sqrrl__world`: a definition gets it auto-inserted as its
        first parameter, a call site gets it auto-inserted as its first
        argument, both silently, so neither the signature nor the call
        needs a separate `@@` token the way an ordinary parameter would.
        `@@name: @@Type` (`MarkerKind.ENTITY_PARAM`, e.g. `def example(a:
        Int, @@test: @@Test)`) is how a *different* function's own
        parameter list -- or a local variable declaration, `var @@dept:
        @@Department = @@make_department();` -- opts an already-constructed
        entity into scope, same shape as a `@@struct` relation field, just
        written in a signature or a `var` declaration instead of a struct
        body, and `@@Type:` sitting right after `->` (`MarkerKind.
        RETURN_TYPE`, e.g. `def @@make_department() raises -> @@Department:`)
        is how a function's own return type is marked as yielding an
        entity. `@@init` not immediately followed by `()`, or `@@name:` not
        followed by another `@@` and not sitting right after `->`, falls
        through to ordinary name-ref handling instead -- a variable
        literally named `init`, or one immediately followed by an ordinary
        (non-`@@`) type annotation somewhere that isn't a return type,
        isn't either of these markers. Returns `MarkerKind.NONE` at end of
        input."""
        while True:
            self.skip_trivia()
            if self.at_end():
                return MarkerKind.NONE
            if self.starts_with("@@struct"):
                return MarkerKind.STRUCT
            if self.at_bare_struct_keyword():
                # A shorthand plain struct (`struct Name { field: Type,
                # ... }`) needs its own marker: without this, this same
                # scanning loop walks straight past its opening `struct
                # Name {` as ordinary text, then finds any `@@`-marked
                # field *inside* it as an independent marker later --
                # confirmed empirically indistinguishable from
                # `MarkerKind.ENTITY_PARAM`, since `@@name: @@Type` is
                # recognized as that shape wherever it occurs, not just in
                # a signature or `var` declaration. Checking here, in the
                # same single pass, means a real hand-written Mojo struct
                # (no `{` right after the name) is left alone exactly like
                # today -- only the brace-shorthand form is claimed.
                var save = self.pos
                var after_struct = self.pos + String("struct").byte_length()
                self.pos = after_struct
                self.skip_trivia()
                var name = self.scan_ident()
                self.skip_trivia()
                if name.byte_length() > 0 and self.peek() == UInt8(ord("[")):
                    # A generic plain struct's own `[T: Bound, ...]` sits
                    # before the `{` this is checking for -- skip past it
                    # (discarding the result) purely to see past it, same
                    # as `find_next_plain_struct_decl`/
                    # `find_next_hand_written_plain_struct_decl` already
                    # do for their own, separate shorthand-vs-not checks.
                    _ = self.parse_type_params()
                    self.skip_trivia()
                var is_shorthand = name.byte_length() > 0 and self.peek() == UInt8(ord("{"))
                self.pos = save
                if is_shorthand:
                    return MarkerKind.PLAIN_STRUCT
                self.pos = after_struct
                continue
            if self.starts_with("@@"):
                var marker_start = self.pos
                self.pos += 2
                var ident_start = self.pos
                var ident = self.scan_ident()
                if self.pos == ident_start:
                    # Bare "@@" with no identifier -- stray noise; step past
                    # it so the outer loop makes progress.
                    self.pos = marker_start + 1
                    continue
                if ident == "init" and self.peek_empty_call_follows():
                    self.pos = marker_start
                    return MarkerKind.INIT
                self.skip_trivia()
                var kind: MarkerKind
                if self.peek() == UInt8(ord("{")):
                    kind = MarkerKind.CONSTRUCT
                elif self.peek() == UInt8(ord(".")) or self.peek() == UInt8(ord("[")):
                    kind = MarkerKind.FIELD_ACCESS
                elif self.peek() == UInt8(ord("(")):
                    kind = MarkerKind.WORLD_FUNC
                elif self.peek() == UInt8(ord(":")):
                    var save_colon = self.pos
                    self.pos += 1
                    self.skip_trivia()
                    if self.starts_with("@@"):
                        kind = MarkerKind.ENTITY_PARAM
                    elif is_after_arrow(self.source, marker_start):
                        kind = MarkerKind.RETURN_TYPE
                    elif self.at_wrapped_entity_param():
                        kind = MarkerKind.ENTITY_PARAM
                    else:
                        kind = MarkerKind.NAME_REF
                    self.pos = save_colon
                elif self.peek() == UInt8(ord("]")):
                    # `@@Type` sitting inside `Ident[...]` -- a generic
                    # type-argument position, wherever it occurs: a return
                    # type (`-> List[@@Type]:`), a parameter type (`items:
                    # List[@@Type]`), or a bare generic-instantiation
                    # expression (`List[@@Type]()`). The marker sits
                    # *inside* the container brackets (already scanned past
                    # on an earlier iteration as ordinary text), so only
                    # the backward (`Ident[`) context needs checking --
                    # unlike a plain list literal, `[@@alice, @@bob]`,
                    # which has no identifier immediately before its `[`
                    # and keeps the ordinary `MarkerKind.NAME_REF` fallback.
                    if is_after_container_bracket(self.source, marker_start):
                        kind = MarkerKind.RETURN_TYPE
                    else:
                        kind = MarkerKind.NAME_REF
                elif self.peek() == UInt8(ord(",")) and is_after_container_bracket(self.source, marker_start):
                    # Same shape as the `]` case just above, but `@@Type`
                    # isn't the *last* type parameter -- `Dict[@@Type, V]`,
                    # not just `List[@@Type]`. Still sits right inside
                    # `Ident[`, so the same backward check applies; a plain
                    # list literal's first element (`[@@alice, @@bob]`) is
                    # also followed by `,` but has no identifier before its
                    # own `[`, so `is_after_container_bracket` already tells
                    # the two apart correctly.
                    kind = MarkerKind.RETURN_TYPE
                elif (
                    self.starts_with("in")
                    and not is_ident_char(self.peek_at(2))
                    and is_after_for_keyword(self.source, marker_start)
                ):
                    # `for @@name in ...:` -- the loop's own target variable,
                    # bound to the iterated expression's *element* type
                    # (unlike `var @@name = ...`, which binds to the whole
                    # return type) once codegen sees what follows `in`.
                    kind = MarkerKind.FOR_ENTITY_LOOP
                else:
                    kind = MarkerKind.NAME_REF
                self.pos = marker_start
                return kind
            self.pos += 1

    def at_wrapped_entity_param(mut self) -> Bool:
        """True if, from the current position, the text matches
        `Ident[@@` -- a container-wrapped entity-param type
        (`List[@@Person]`, `InlineArray[@@Person]`, or any other container
        identifier), which `find_next_marker`'s `:` branch also classifies
        as `MarkerKind.ENTITY_PARAM`, alongside the bare `@@name: @@Type`
        form. Restores `self.pos` before returning either way -- purely a
        lookahead."""
        var save = self.pos
        var wrapper = self.scan_ident()
        if wrapper.byte_length() == 0:
            self.pos = save
            return False
        self.skip_trivia()
        if self.peek() != UInt8(ord("[")):
            self.pos = save
            return False
        self.pos += 1
        self.skip_trivia()
        var result = self.starts_with("@@")
        self.pos = save
        return result

    def parse_entity_param(mut self) raises -> EntityParam:
        """Requires `self.pos` at the `@@` of `@@name: @@Type` (or the
        container form, `@@name: Container[@@Type]`), e.g. right after
        `find_next_marker` returns `MarkerKind.ENTITY_PARAM`."""
        if not self.try_consume("@@"):
            raise self.err("InvalidSquirrelSyntax: expected '@@'")
        var name = self.scan_ident()
        if name.byte_length() == 0:
            raise self.err("InvalidSquirrelSyntax: expected entity parameter name")
        self.skip_trivia()
        if not self.try_consume(":"):
            raise self.err("InvalidSquirrelSyntax: expected ':' after entity parameter name")
        self.skip_trivia()

        var wrapper: Optional[String] = None
        if not self.starts_with("@@"):
            var w = self.scan_ident()
            if w.byte_length() == 0:
                raise self.err("InvalidSquirrelSyntax: expected '@@Type' or 'Container[@@Type]' after ':'")
            self.skip_trivia()
            if not self.try_consume("["):
                raise self.err("InvalidSquirrelSyntax: expected '[' after '" + w + "'")
            self.skip_trivia()
            wrapper = w

        if not self.try_consume("@@"):
            raise self.err("InvalidSquirrelSyntax: expected '@@Type' after ':'")
        var type_name = self.scan_ident()
        if type_name.byte_length() == 0:
            raise self.err("InvalidSquirrelSyntax: expected entity parameter type")

        if wrapper:
            self.skip_trivia()
            if not self.try_consume("]"):
                raise self.err("InvalidSquirrelSyntax: expected ']' after '" + wrapper.value() + "[@@" + type_name + "'")

        return EntityParam(name=name, type_name=type_name, wrapper=wrapper)

    def parse_construct(mut self) raises -> Construct:
        """Requires `self.pos` at the `@@` of a `@@TypeName { ... }`
        construct, e.g. right after `find_next_marker` returns
        `MARKER_CONSTRUCT`."""
        if not self.try_consume("@@"):
            raise self.err("InvalidSquirrelSyntax: expected '@@'")
        var type_name = self.scan_ident()
        if type_name.byte_length() == 0:
            raise self.err("InvalidSquirrelSyntax: expected type name")
        self.skip_trivia()
        var body = self.scan_braced_span()
        return Construct(type_name=type_name, fields=parse_construct_fields(body))

    def parse_field_access(mut self) raises -> FieldAccess:
        """Requires `self.pos` at the `@@` of `@@entity.field` (or a chain,
        `@@entity.@@relation.field`, ...), e.g. right after
        `find_next_marker` returns `MARKER_FIELD_ACCESS`. Loops consuming
        `.@@relation` segments (each an intermediate hop, collected into
        `FieldAccess.hops`) until it hits a `.` followed by a *plain*
        (non-`@@`) identifier -- that one is the terminal `field`, read,
        written (if followed by `=`), or called (if followed by `(`, see
        `FieldAccess.is_call`). Neither a read nor a call consumes anything
        past the terminal identifier -- codegen splices its own rewritten
        prefix in and lets whatever follows (a call's `(args)`, or nothing
        at all for a read) pass through the normal copy loop unchanged.

        An indexed entity (`@@matches[0]`) not followed by `.` at all --
        used as a value in its own right, not the start of a field chain --
        returns early with `field=""` (see that check just below) instead
        of falling into the loop, which would otherwise demand a `.`."""
        if not self.try_consume("@@"):
            raise self.err("InvalidSquirrelSyntax: expected '@@'")
        var entity = self.scan_ident()
        if entity.byte_length() == 0:
            raise self.err("InvalidSquirrelSyntax: expected entity name")

        var index_expr: Optional[String] = None
        self.skip_trivia()
        if self.peek() == UInt8(ord("[")):
            index_expr = self.scan_bracketed_span()

        if index_expr:
            var save = self.pos
            self.skip_trivia()
            if self.peek() != UInt8(ord(".")):
                # A bare indexed reference, `@@matches[0]`, used as a value
                # in its own right (an argument, the RHS of a plain `var
                # x = ...`, ...) rather than as the start of a further
                # `.field` chain -- `field=""` is the sentinel for this
                # (never a legitimate field name; `scan_ident` returning
                # empty already raises everywhere else a real field name is
                # expected, so this can't collide with one).
                self.pos = save
                return FieldAccess(
                    entity=entity, hops=List[String](), field="", write_value=None, is_call=False, index_expr=index_expr
                )

        var hops = List[String]()
        var field: String
        while True:
            self.skip_trivia()
            if not self.try_consume("."):
                raise self.err(
                    "InvalidSquirrelSyntax: expected '.' after entity/relation"
                    " name"
                )
            self.skip_trivia()
            if self.try_consume("@@"):
                var hop = self.scan_ident()
                if hop.byte_length() == 0:
                    raise self.err(
                        "InvalidSquirrelSyntax: expected relation field name"
                        " after '@@'"
                    )
                hops.append(hop)
                continue
            field = self.scan_ident()
            if field.byte_length() == 0:
                raise self.err("InvalidSquirrelSyntax: expected field name")
            break
        var after_field = self.pos

        self.skip_trivia()
        if self.peek() == UInt8(ord("(")):
            self.pos = after_field
            return FieldAccess(
                entity=entity, hops=hops^, field=field, write_value=None, is_call=True, index_expr=index_expr
            )

        var is_write = self.peek() == UInt8(ord("=")) and self.peek_at(1) != UInt8(ord("="))
        if not is_write:
            self.pos = after_field
            return FieldAccess(
                entity=entity, hops=hops^, field=field, write_value=None, is_call=False, index_expr=index_expr
            )

        self.pos += 1  # consume '='
        self.skip_whitespace()
        var value_start = self.pos
        var depth = 0
        while not self.at_end():
            var before = self.pos
            self.skip_non_code()
            if self.pos != before:
                continue
            var b = self.peek()
            if b == UInt8(ord("(")) or b == UInt8(ord("[")) or b == UInt8(ord("{")):
                depth += 1
            elif b == UInt8(ord(")")) or b == UInt8(ord("]")) or b == UInt8(ord("}")):
                depth -= 1
            elif b == UInt8(ord(";")) and depth == 0:
                break
            self.pos += 1
        if self.at_end():
            raise self.err("InvalidSquirrelSyntax: unterminated write expression")
        var value = String(self.source[byte = value_start : self.pos])
        self.pos += 1  # consume ';'
        return FieldAccess(
            entity=entity,
            hops=hops^,
            field=field,
            write_value=String(value.strip()),
            is_call=False,
            index_expr=index_expr,
        )

    def parse_init(mut self) raises:
        """Requires `self.pos` at the `@@` of `@@init()`, e.g. right after
        `find_next_marker` returns `MarkerKind.INIT`. Takes no arguments --
        just consumes the token; `sqrrl__init`'s doc comment (generated
        `sqrrl__world.mojo`) is where the actual construction happens."""
        if not self.try_consume("@@init"):
            raise self.err("InvalidSquirrelSyntax: expected '@@init'")
        self.skip_trivia()
        if not self.try_consume("("):
            raise self.err("InvalidSquirrelSyntax: expected '(' after '@@init'")
        self.skip_trivia()
        if not self.try_consume(")"):
            raise self.err("InvalidSquirrelSyntax: '@@init' takes no arguments")

    def parse_world_func(mut self) raises -> String:
        """Requires `self.pos` at the `@@` of `@@name(`, e.g. right after
        `find_next_marker` returns `MarkerKind.WORLD_FUNC`. Consumes through
        the opening `(` (but not what follows it -- codegen decides what to
        splice in right after, depending on whether this is a definition or
        a call site, and whether more arguments follow) and returns
        `name`."""
        if not self.try_consume("@@"):
            raise self.err("InvalidSquirrelSyntax: expected '@@'")
        var name = self.scan_ident()
        if name.byte_length() == 0:
            raise self.err("InvalidSquirrelSyntax: expected function name")
        self.skip_trivia()
        if not self.try_consume("("):
            raise self.err("InvalidSquirrelSyntax: expected '(' after function name")
        return name

    def parse_name_ref(mut self) raises -> NameRef:
        """Requires `self.pos` at the `@@` of a bare `@@name`, e.g. right
        after `find_next_marker` returns `MARKER_NAME_REF` or the (bare or
        container) `MarkerKind.RETURN_TYPE` -- both parse identically, see
        `NameRef`'s own doc comment for why a container return type needs
        nothing extra here."""
        if not self.try_consume("@@"):
            raise self.err("InvalidSquirrelSyntax: expected '@@'")
        var name = self.scan_ident()
        if name.byte_length() == 0:
            raise self.err("InvalidSquirrelSyntax: expected name")
        return NameRef(name=name)

    def parse_for_entity_loop(mut self) raises -> String:
        """Requires `self.pos` at the `@@` of `for @@name in ...:`, e.g.
        right after `find_next_marker` returns `MarkerKind.FOR_ENTITY_LOOP`.
        Consumes through the `in` keyword (leaving `self.pos` right at the
        start of the iterated expression, whatever marker that turns out to
        be -- codegen decides what to splice in from there, same technique
        `parse_world_func` uses for its own trailing `(`). Returns `name`."""
        if not self.try_consume("@@"):
            raise self.err("InvalidSquirrelSyntax: expected '@@'")
        var name = self.scan_ident()
        if name.byte_length() == 0:
            raise self.err("InvalidSquirrelSyntax: expected name")
        self.skip_trivia()
        if not self.try_consume("in") or is_ident_char(self.peek()):
            raise self.err("InvalidSquirrelSyntax: expected 'in' after 'for @@" + name + "'")
        return name


def is_wrapped_relation_type(type_str: String) -> Bool:
    """True if `type_str` (a `@@struct` field's raw type text, from
    `Scanner.scan_type`) looks like `Ident[@@Type]` -- e.g.
    `List[@@Employee]` -- the collection form of a relation field,
    alongside the existing bare `@@Type` form. Mirrors `EntityParam.wrapper`'s
    `Container[@@Type]` shape, just written directly as a struct field's
    type instead of after a `:` in a declaration."""
    return type_str.find("[@@") > 0 and type_str.endswith("]")


def relation_target_of(type_str: String) -> String:
    """The target type name of a relation field's `type_str`, whether bare
    (`@@Employee` -> `Employee`) or wrapped (`List[@@Employee]` ->
    `Employee`). Requires `type_str.startswith("@@")` or
    `is_wrapped_relation_type(type_str)`."""
    if type_str.startswith("@@"):
        return String(type_str[byte=2 : type_str.byte_length()])
    var start = type_str.find("[@@") + 3
    return String(type_str[byte=start : type_str.byte_length() - 1])


def relation_wrapper_of(type_str: String) -> String:
    """The container identifier of a wrapped relation field's `type_str`
    -- `List[@@Employee]` -> `List`. Requires
    `is_wrapped_relation_type(type_str)`."""
    return String(type_str[byte=0 : type_str.find("[")])


def parse_fields(body: String) raises -> List[Field]:
    """Splits a `@@struct` body into `name: Type` fields. A relation field's
    name must itself be `@@`-marked (`@@employee: @@Employee`, not
    `employee: @@Employee`) so the marking stays consistent between a field's
    name and its type -- true whether the field is a bare relation
    (`@@Employee`) or a collection of them (`List[@@Employee]`); the `@@`
    is stripped from the stored name either way. A field may also be
    prefixed with the bare `unique` keyword (`unique name: Type`, or
    `unique @@employee: @@Employee`/`unique @@members: List[@@Employee]`
    for a relation field -- a collection is `KeyElement` exactly when its
    element type is, so there's nothing collection-specific to reject
    here), the `forwardonly` keyword (`forwardonly scores:
    List[Int]`) -- forcing `ForwardOnlyRel` storage for a field whose type
    genuinely isn't `KeyElement`, which this parser has no way to detect
    from raw type text alone (unlike, say, `List[Int]` vs `List[Address]`
    vs `List[@@Employee]` -- all the same shape, only one of which Mojo
    would actually reject as a `Rel`/`UniqueRel` field) -- or the `multi`
    keyword (`multi @@members: @@Employee`), forcing `MultiRel` storage: a
    genuine many-to-many relation. `multi` is written on the *element*
    type directly (`@@Employee`, not `List[@@Employee]`) -- the keyword
    itself already says "many of these"; codegen is what turns the
    declared element type into the actual `List[EntityHandle[...]]`
    field, the same direction `List[@@Employee]` unwraps its own element
    type today, just reversed. `type_str` isn't required to be a bare,
    unwrapped type here, though -- `multi @@tags: List[@@Category]` is a
    field where each row can hold several `List[@@Category]` values, no
    different in kind from `multi`-ing any other element type; nothing
    about `type_str` looking container-shaped on its own says which case
    it is. There's also `ordered` (`ordered name: Type`), for a
    range-queryable field -- see `FieldModifier`. Every keyword is checked
    with a word-boundary on both sides so a field literally named
    `unique`/`forwardonlyId`/`multiplier`/`orderedBy` isn't mistaken for
    one of them; a *second* keyword on the same field is rejected
    immediately (there's only one `FieldModifier` slot to put it in), not
    collected and checked pairwise afterward."""
    var bs = Scanner(body)
    var fields = List[Field]()
    while True:
        bs.skip_trivia()
        if bs.at_end():
            break

        var modifier = FieldModifier.NONE
        var modifier_keyword = String()
        while True:
            var next_keyword: String
            var next_modifier: FieldModifier
            if bs.starts_with("unique") and not is_ident_char(bs.peek_at(6)):
                next_keyword = "unique"
                next_modifier = FieldModifier.UNIQUE
            elif bs.starts_with("forwardonly") and not is_ident_char(bs.peek_at(11)):
                next_keyword = "forwardonly"
                next_modifier = FieldModifier.FORWARD_ONLY
            elif bs.starts_with("multi") and not is_ident_char(bs.peek_at(5)):
                next_keyword = "multi"
                next_modifier = FieldModifier.MULTI
            elif bs.starts_with("ordered") and not is_ident_char(bs.peek_at(7)):
                next_keyword = "ordered"
                next_modifier = FieldModifier.ORDERED
            else:
                break
            if modifier != FieldModifier.NONE:
                raise bs.err(
                    "InvalidSquirrelSyntax: a field can't be both '"
                    + modifier_keyword
                    + "' and '"
                    + next_keyword
                    + "' -- each selects its own, mutually exclusive storage"
                    " shape"
                )
            modifier = next_modifier
            modifier_keyword = next_keyword
            bs.pos += next_keyword.byte_length()
            bs.skip_trivia()

        var name_is_marked = bs.try_consume("@@")
        var name = bs.scan_ident()
        if name.byte_length() == 0:
            raise bs.err("InvalidSquirrelSyntax: expected field name")

        for existing in fields:
            if existing.name == name:
                raise bs.err("DuplicateFieldName: " + name)

        bs.skip_trivia()
        if not bs.try_consume(":"):
            raise bs.err("InvalidSquirrelSyntax: expected ':' after field name")
        bs.skip_trivia()

        var type_str = bs.scan_type()
        if type_str.byte_length() == 0:
            raise bs.err("InvalidSquirrelSyntax: empty field type")

        var type_is_relation = type_str.startswith("@@") or is_wrapped_relation_type(type_str)
        if name_is_marked != type_is_relation:
            raise bs.err(
                "InvalidSquirrelSyntax: @@ marking must match between field"
                " name and type"
            )
        fields.append(
            Field(
                name=name,
                type_str=type_str,
                modifier=modifier,
            )
        )
        _ = bs.try_consume(",")

    return fields^


def unqualify_self_type_params(type_str: String, type_params: List[TypeParam]) -> String:
    """Collapses `Self.T` back to bare `T` wherever `T` names one of
    `type_params`'s own parameters, applied to a generic plain struct's
    own field types right after parsing -- both a hand-written one
    (`parse_hand_written_plain_struct`, where `Self.T` is the *only* form
    real Mojo accepts in its own body) and a shorthand one
    (`parse_plain_struct`, where an author might still write `Self.T`
    even though bare `T` is the intended, simpler style there). Either
    way, the extracted `type_str` feeds `codegen.
    emit_plain_struct_from_json`'s generated `from_json` companion,
    always a *free function*, where `Self` doesn't exist at all
    (confirmed the reverse case -- a free function referencing its own
    type parameter bare -- compiles and runs correctly with no
    qualification at all); a literal `Optional[Self.T]` local there
    wouldn't compile, and for the shorthand case specifically, leaving an
    already-qualified `Self.T` in place would also get double-qualified
    right back to `Self.Self.T` when `emit_plain_struct` adds its own
    `Self.` prefix on the way to generating the struct's own body
    (confirmed both failure modes directly). No-op when `type_params` is
    empty, the overwhelmingly common, non-generic case. `codegen.
    _qualify_type_params_with_self` is the exact reverse, applied when
    *generating* a struct's own body instead of extracting one already
    written (by hand, or normalized from shorthand) that might already
    carry the qualification."""
    if len(type_params) == 0:
        return type_str
    var out = String()
    var bytes = type_str.as_bytes()
    var i = 0
    var n = len(bytes)
    while i < n:
        if is_ident_char(bytes[i]):
            var start = i
            while i < n and is_ident_char(bytes[i]):
                i += 1
            var word = String(type_str[byte = start : i])
            if word == "Self" and i < n and bytes[i] == UInt8(ord(".")):
                var after_dot = i + 1
                var j = after_dot
                while j < n and is_ident_char(bytes[j]):
                    j += 1
                var next_word = String(type_str[byte = after_dot : j])
                var matched = False
                for tp in type_params:
                    if tp.name == next_word:
                        matched = True
                        break
                if matched:
                    out += next_word
                    i = j
                    continue
            out += word
        else:
            out += String(type_str[byte = i : i + 1])
            i += 1
    return out^


def parse_hand_written_struct_fields(body: String) -> List[Field]:
    """Best-effort extraction of a hand-written plain struct's own `var
    name: Type` field declarations from its body -- unlike `parse_fields`
    (`@@struct`/shorthand-plain-struct syntax: no `var` keyword, `@@`-marked
    relation fields, comma/newline-terminated types with no method bodies
    mixed in), a hand-written struct's fields are ordinary, already-valid
    Mojo (`var name: Type`), and its body can contain arbitrary methods
    afterward that this parser has no business trying to understand.
    Stops at the first token that isn't the `var` keyword (matching the
    universal Mojo convention -- and this project's own `emit_plain_struct`
    codegen -- of declaring every field before any method), rather than
    requiring the whole body to consist of field declarations; never
    raises; a name or type this can't make sense of just stops the scan
    there; whatever fields were found before that point are still fields
    it correctly understood. Every field's `type_str` is already a real,
    concrete Mojo type (no `@@` marking possible here -- a hand-written
    struct's own relation field, if any, is already spelled out as
    `EntityHandle[sqrrl__<Name>TableState]` by hand), so `modifier` is
    always `FieldModifier.NONE` -- `unique`/`forwardonly`/`multi`/`ordered`
    are relation-table storage concepts with nothing to mean for a plain
    struct's own value fields."""
    var bs = Scanner(body)
    var fields = List[Field]()
    while True:
        bs.skip_trivia()
        if bs.at_end():
            break
        if not (bs.starts_with("var") and not is_ident_char(bs.peek_at(3))):
            break
        bs.pos += 3
        bs.skip_trivia()
        var name = bs.scan_ident()
        if name.byte_length() == 0:
            break
        bs.skip_trivia()
        if not bs.try_consume(":"):
            break
        bs.skip_trivia()
        var type_str = bs.scan_type()
        if type_str.byte_length() == 0:
            break
        fields.append(Field(name=name, type_str=type_str, modifier=FieldModifier.NONE))
        bs.skip_trivia()
        _ = bs.try_consume(",")

    return fields^
