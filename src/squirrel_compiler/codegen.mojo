from squirrel_compiler.parser import (
    ParsedStruct,
    Field,
    FieldModifier,
    Scanner,
    MarkerKind,
    ConstructField,
    is_ident_char,
    is_wrapped_relation_type,
    relation_target_of,
    relation_wrapper_of,
    is_unmarked_container_declaration,
    source_location,
)


def sqrrl_prefixed(name: String) -> String:
    """The single transformation behind every generator-introduced
    identifier that could otherwise collide with a `.rel`-declared field --
    generated struct names (`sqrrl__PersonTableState`) and
    `sqrrl__cleanup_relations`. A `.rel` author could plausibly name a field
    `cleanup_relations`; they can't plausibly type `sqrrl__cleanup_relations`
    by accident. This is the only place that prefix gets written -- every
    other call site goes through here rather than inlining the literal."""
    return "sqrrl__" + name


def _rewrite_type_str(type_str: String) -> String:
    """The Mojo-side rewritten form of a raw `.rel` type string --
    `@@Employee` -> `EntityHandle[sqrrl__EmployeeTableState]` (another
    table's entity handle, not `sqrrl__EmployeeTable` itself -- that would
    mean "store the whole table", not a row reference;
    `sqrrl__EmployeeTableState`, not `sqrrl__EmployeeTable`, is the tag
    `EntityHandle` is parametrized by -- see `emit_table`), a wrapped
    relation type's own element rewritten the same way inside its
    container (`List[@@Employee]` -> `List[EntityHandle[...]]`, the
    wrapper kept verbatim), or passed through unchanged for an ordinary
    Mojo type (`String`, `UInt32`, ...) -- `.rel` sources target Mojo
    directly, so there's nothing to rewrite there. Shared by
    `emit_field_type` (the whole-field-type case) and, for a `multi`
    field, applied to just its element type before that gets its own
    outer `List[...]` wrapped around it."""
    if type_str.startswith("@@"):
        var target = String(type_str[byte=2 : type_str.byte_length()])
        return String(t"EntityHandle[{sqrrl_prefixed(target)}TableState]")
    if is_wrapped_relation_type(type_str):
        var wrapper = relation_wrapper_of(type_str)
        var target = relation_target_of(type_str)
        return String(t"{wrapper}[EntityHandle[{sqrrl_prefixed(target)}TableState]]")
    return type_str


def emit_field_type(f: Field) -> String:
    """The Mojo type a field's `create`/`get_<field>`/`set_<field>` all
    operate on. For a `multi` field, `f.type_str` is the bare *element*
    type (`multi @@members: @@Employee`'s is `@@Employee`, not
    `@@Employee`-in-a-container -- see `Field`'s own doc comment) -- the
    actual field type is `Set[...]` around whatever that element rewrites
    to (membership is a set: this row either has this member or it
    doesn't, order doesn't matter, and a duplicate can't exist -- see
    `MultiRel`'s own doc comment for why that's `Set`, not `List`).
    Every other field's `type_str` is already the whole field type, so
    `_rewrite_type_str` alone is enough."""
    var rewritten = _rewrite_type_str(f.type_str)
    if f.modifier == FieldModifier.MULTI:
        return String(t"Set[{rewritten}]")
    return rewritten


def emit_multi_element_type(f: Field) -> String:
    """The bare element type a `multi` field's `for_<field>`/`add_to_<field>`/
    `remove_from_<field>` all take (`MultiRel.get_bwd`/`add`/`remove`'s own
    `value: Self.T`) -- `container_element_of` strips the `Set[...]`
    `emit_field_type` just added back off, recovering exactly
    `_rewrite_type_str(f.type_str)`. Also `MultiRel`'s own type parameter
    (`emit_rel_type`) -- there's nothing to convert at any boundary here:
    a `multi`/`multi` pair pointing at each other is a real graph cycle
    like any other (`driver._relation_targets` doesn't exempt `multi`),
    and a genuine many-to-many relationship never needs declaring on both
    sides in the first place -- `MultiRel`'s own `get_fwd`/`get_bwd`
    already answer both directions from a single field declared on just
    one struct. Requires `f.modifier == FieldModifier.MULTI`."""
    return container_element_of(emit_field_type(f))


def emit_rel_type(f: Field) -> String:
    """`ForwardOnlyRel` for a field explicitly marked `forwardonly` (no
    `_bwd` reverse index makes sense for a value that isn't `KeyElement`),
    `MultiRel` for a field marked `multi` (indexed by each *element*, not
    the field's whole value -- a genuine many-to-many relation; `MultiRel`'s
    own type parameter is the element type, hence `emit_multi_element_type`
    rather than `emit_field_type` here), `OrderedRel` for a field marked
    `ordered` (adds range-query methods -- see `emit_table`), `UniqueRel`
    for a `unique`-marked field, `Rel` otherwise -- see `squirrel_runtime.rel`
    for how all five differ (`parse_fields` already rejects combining any
    two of these on the same field, structurally, via `FieldModifier`). A
    collection-typed relation field (`List[@@Employee]`) isn't special-cased
    here: it's `KeyElement` exactly when its element type is (always true
    for `EntityHandle`), so it gets ordinary `Rel`/`UniqueRel` like any
    other field unless one of the modifiers says otherwise."""
    if f.modifier == FieldModifier.FORWARD_ONLY:
        return String(t"ForwardOnlyRel[{emit_field_type(f)}]")
    if f.modifier == FieldModifier.MULTI:
        return String(t"MultiRel[{emit_multi_element_type(f)}]")
    if f.modifier == FieldModifier.ORDERED:
        return String(t"OrderedRel[{emit_field_type(f)}]")
    var wrapper = "UniqueRel" if f.modifier == FieldModifier.UNIQUE else "Rel"
    return String(t"{wrapper}[{emit_field_type(f)}]")


def encode_container_type(wrapper: String, type_name: String) -> String:
    """`entity_to_type`'s encoding for a container-tracked `@@` variable
    (`@@name: List[@@Person]`, or an inferred non-unique `for_<field>`
    result): stores `"Wrapper[Type]"` as a plain string, reusing the same
    `Dict[String, String]` `entity_to_type` already is rather than adding a
    second, parallel dict threaded through every signature that already
    carries it. `is_container_type`/`container_wrapper_of`/
    `container_element_of` are the matching readers."""
    return wrapper + "[" + type_name + "]"


def is_container_type(t: String) -> Bool:
    return t.find("[") >= 0


def container_wrapper_of(t: String) -> String:
    """`"List[Person]"` -> `"List"`. Requires `is_container_type(t)`."""
    return String(t[byte=0 : t.find("[")])


def container_element_of(t: String) -> String:
    """`"List[Person]"` -> `"Person"`. Requires `is_container_type(t)`."""
    var start = t.find("[") + 1
    return String(t[byte=start : t.byte_length() - 1])


def _is_ordered_field_query(
    entity: String, target_field: String, ordered_fields: Dict[String, List[String]]
) raises -> Bool:
    """True if `target_field` (a `for_<field>` call's name, `for_` prefix
    already stripped) is an exact match for one of `entity`'s `ordered`
    fields -- that specific call (`OrderedRel.get_bwd`) returns
    `Set[EntityHandle[...]]`, matching `Table.all()`, unlike this same
    field's own five range-shaped siblings (`_greater_than`/`_less_than`/
    `_at_least`/`_at_most`/`_between`, still `List`-returning like any
    other field's `for_<field>`, see `emit_table`'s `FieldModifier.
    ORDERED` branch) or the exact-match `for_<field>` of a non-`ordered`
    field."""
    if entity not in ordered_fields:
        return False
    for of in ordered_fields[entity]:
        if target_field == of:
            return True
    return False


def emit_table(parsed: ParsedStruct) -> String:
    """Emits two generated structs per `@@struct`:

    - `sqrrl__NameTableState` -- implements `TableStateLike` (just one `Rel`
      per field, plus `sqrrl__cleanup_relations`), and is what
      `EntityHandle`/`Table` are actually parametrized by.
      `sqrrl__cleanup_relations` calls `fetch_remove_fwd` on every field and
      discards the result -- for a relation field, that drops the returned
      `EntityHandle`, decref'ing whatever it pointed to, which is what
      makes destroying an entity correctly release its relations instead of
      leaking them (see `TableStateLike`'s doc comment in `entity.mojo` for
      the concrete leak this closes). Id allocation itself lives on the
      runtime's `TableStorage` wrapper, not here -- it's mechanically
      identical for every table, so there's nothing table-specific to
      generate for it.
    - `sqrrl__NameTable` -- the user-facing wrapper, holding a
      `Table[sqrrl__NameTableState]` plus typed `create`/`get_*`/`set_*`/
      `for_*` methods delegating into it, via
      `self.table.state[].state.<field>` (the first `.state` is `Table`'s
      `ArcPointer` target, `TableStorage`; the second is `TableStorage`'s
      own field holding the generated state). `create`/`get_*`/`set_*`/
      `for_*` stay bare, unprefixed -- unlike the struct names and
      `cleanup_relations`, colliding with a `.rel` field literally named
      `create` (or `get_<fieldname>`) is an edge case narrow enough not to
      be worth the extra noise on every accessor.

    Every field, `unique` or not, also gets a reverse-lookup `for_<field>`
    built on the field's own `Rel`/`UniqueRel.get_bwd` (already indexing
    every value -> id(s), just unused before `for_*` existed to expose it):
    a plain field's `for_<field>(value)` returns every matching entity as a
    `List[EntityHandle[...]]` (there can be several), while a `unique`
    field's returns a single `EntityHandle[...]` directly and raises if
    none matches -- reflecting that `UniqueRel.get_bwd` itself raises on a
    genuinely realistic condition (the value was never registered), which a
    plain `Rel.get_bwd` doesn't (it just returns an empty set). Both
    variants call `Table.handle_for(id)` (never
    `EntityHandle(EntityInner(_id=id, _table=...))` directly) to turn a bare
    id from `get_bwd` into a real handle -- fabricating one independently
    would create a second, uncoordinated owner over the same id, corrupting
    the entity's actual refcount (confirmed via a direct repro: doing that
    double-frees the id once the fabricated handle drops, even while a
    legitimate handle for it is still alive). `handle_for` instead upgrades
    a stored `WeakPointer`, sharing whatever handle(s) already exist rather
    than creating a new owner -- see its doc comment in `entity.mojo`.
    `handle_for` itself aborts rather than raises if the id turns out to be
    dead, matching `Rel.put`/`update`'s own invariant-violation convention:
    every id reaching it comes straight from a `get_bwd` whose _bwd index is
    only ever in sync with currently-live ids, so a dead one getting
    through would be a real bug, not recoverable bad input -- which is why
    only the `unique` `for_<field>` needs `raises` at all (from its own
    `UniqueRel.get_bwd`), not the plain one.

    `create` gains `raises` whenever *any* field is `unique` (a `put` on
    that field can raise); `set_<field>` gains it only for that field
    itself.

    Using `sqrrl__NameTableState` as the tag (not a separate marker type,
    and not `sqrrl__NameTable` itself) is what lets
    `EntityHandle[sqrrl__PersonTableState]` and
    `EntityHandle[sqrrl__EmployeeTableState]` be distinct,
    mutually-incompatible types with no duplicated runtime logic per
    `@@struct`."""
    var state_name = sqrrl_prefixed(parsed.name) + "TableState"
    var table_name = sqrrl_prefixed(parsed.name) + "Table"

    var out = String(t"struct {state_name}(TableStateLike, Movable, ImplicitlyDeletable):\n")
    for f in parsed.fields:
        out += String(t"    var {f.name}: {emit_rel_type(f)}\n")
    out += "\n"

    out += "    def __init__(out self):\n"
    if len(parsed.fields) == 0:
        out += "        pass\n"
    for f in parsed.fields:
        out += String(t"        self.{f.name} = {emit_rel_type(f)}()\n")
    out += "\n"

    out += String(t"    def {sqrrl_prefixed('cleanup_relations')}(mut self, id: UInt32):\n")
    if len(parsed.fields) == 0:
        out += "        pass\n"
    for f in parsed.fields:
        out += String(t"        _ = self.{f.name}.fetch_remove_fwd(id)\n")

    out += "\n\n"
    out += String(t"struct {table_name}(Movable):\n")
    out += String(t"    var table: Table[{state_name}]\n")
    if parsed.is_keepalive:
        out += String(t"    var keepalive: Set[EntityHandle[{state_name}]]\n")
    out += "\n"
    out += "    def __init__(out self):\n"
    out += String(t"        self.table = Table[{state_name}]({state_name}())\n")
    if parsed.is_keepalive:
        out += String(t"        self.keepalive = Set[EntityHandle[{state_name}]]()\n")
    out += "\n"

    var any_unique = False
    for f in parsed.fields:
        if f.modifier == FieldModifier.UNIQUE:
            any_unique = True
            break

    out += "    def create(mut self"
    for f in parsed.fields:
        out += String(t", {f.name}: {emit_field_type(f)}")
    out += ")"
    if any_unique:
        # A single `create` sets every field in one body -- if *any* one of
        # them is `unique` (a `UniqueRel.put`, which is `raises`), the whole
        # function must be `raises` too, since Mojo requires that of any
        # caller of a `raises` method. `MultiRel.put` doesn't raise (a
        # `Set`-backed field can't hold a duplicate to reject in the first
        # place), so a `multi` field alone doesn't force this. Unlike
        # `set_<field>` below, there's no per-field granularity available
        # here: it's the same function for every field, not one function
        # each. `raises` must come before the `->`, not after (Mojo
        # syntax), unlike `set_<field>` which has no return type to worry
        # about ordering against.
        out += " raises"
    out += String(t" -> EntityHandle[{state_name}]:\n")
    out += "        var e = self.table.create()\n"
    for f in parsed.fields:
        out += String(t"        self.table.state[].state.{f.name}.put(e.id(), {f.name})\n")
    if parsed.is_keepalive:
        # `create` puts every new entity in `keepalive` by default -- the
        # actual point of the tag, letting it outlive whatever scope
        # constructed it without needing a relation elsewhere or a
        # long-lived local `var` to hold it alive. `.copy()` since `e`
        # itself is still returned below.
        out += "        self.keepalive.add(e.copy())\n"
    out += "        return e\n"
    out += "\n"
    out += String(t"    def all(self) -> Set[EntityHandle[{state_name}]]:\n")
    out += "        return self.table.all()\n"
    if parsed.is_keepalive:
        out += "\n"
        out += String(
            t"    def dont_keepalive(mut self, e: EntityHandle[{state_name}]) -> Bool:\n"
        )
        out += "        try:\n"
        out += "            self.keepalive.remove(e)\n"
        out += "            return True\n"
        out += "        except:\n"
        out += "            return False\n"

    for f in parsed.fields:
        var field_type = emit_field_type(f)
        out += "\n"
        out += String(t"    def get_{f.name}(self, e: EntityHandle[{state_name}]) -> {field_type}:\n")
        out += String(t"        var got = self.table.state[].state.{f.name}.get_fwd(e.id())\n")
        out += "        return got.take()\n"
        out += "\n"
        out += String(t"    def set_{f.name}(mut self, e: EntityHandle[{state_name}], v: {field_type})")
        if f.modifier == FieldModifier.UNIQUE:
            out += " raises"
        out += ":\n"
        out += String(t"        self.table.state[].state.{f.name}.update(e.id(), v)\n")
        out += "\n"
        if f.modifier == FieldModifier.MULTI:
            # `add_to_<field>`/`remove_from_<field>` expose `MultiRel`'s own
            # single-element `add`/`remove` directly -- the actual
            # ergonomic point of `multi` being "add/remove one member",
            # not the get_<field>+copy+append+set_<field> round trip
            # every other collection-typed field needs. `for_<field>`
            # takes the bare *element* type here (`MultiRel.get_bwd`'s own
            # shape), not the whole field type `for_<field>` uses for
            # every other kind of field -- "which rows contain this one
            # member", the actual many-to-many reverse query.
            var element_type = emit_multi_element_type(f)
            out += String(
                t"    def add_to_{f.name}(mut self, e: EntityHandle[{state_name}], value: {element_type}) -> Bool:\n"
            )
            out += String(t"        return self.table.state[].state.{f.name}.add(e.id(), value)\n")
            out += "\n"
            out += String(
                t"    def remove_from_{f.name}(mut self, e: EntityHandle[{state_name}], value: {element_type}) -> Bool:\n"
            )
            out += String(t"        return self.table.state[].state.{f.name}.remove(e.id(), value)\n")
            out += "\n"
            out += String(t"    def for_{f.name}(self, value: {element_type}) -> List[EntityHandle[{state_name}]]:\n")
            out += String(t"        var ids = self.table.state[].state.{f.name}.get_bwd(value)\n")
            out += String(t"        var out = List[EntityHandle[{state_name}]]()\n")
            out += "        for id in ids:\n"
            out += String(t"            out.append(self.table.handle_for(id))\n")
            out += "        return out^\n"
            continue
        if f.modifier == FieldModifier.FORWARD_ONLY:
            # `ForwardOnlyRel` has no `_bwd` reverse index (its value isn't
            # assumed `KeyElement`) and thus no `get_bwd` to build a
            # `for_<field>` from -- a `forwardonly` field only gets
            # `get_*`/`set_*` above, not a reverse lookup. A collection-typed
            # relation field *without* `forwardonly` still gets one like
            # any other field: it's backed by ordinary `Rel`/`UniqueRel`
            # (see `emit_rel_type`), so `get_bwd` exists.
            continue
        if f.modifier == FieldModifier.ORDERED:
            # `OrderedRel.get_bwd` (exact match, same name as every other
            # `Rel` variant's own reverse index) builds `for_<field>` here,
            # a binary search (`between(value, value)`) under the hood
            # rather than a hash lookup -- but returned as `Set`, not
            # `List`, matching `Rel`/`MultiRel`'s own `get_bwd` shape and
            # `Table.all()`: ids matching an exact value have no meaningful
            # order to preserve at the `EntityHandle` level. The
            # range-shaped methods below (`greater_than`/`less_than`/
            # `at_least`/`at_most`/`between`) stay `List`-returning, like
            # any other field's `for_<field>` -- their whole point is the
            # sorted order `_sorted` maintains, which a `Set` would throw
            # away.
            out += String(t"    def for_{f.name}(self, value: {field_type}) -> Set[EntityHandle[{state_name}]]:\n")
            out += String(t"        var ids = self.table.state[].state.{f.name}.get_bwd(value)\n")
            out += String(t"        var out = Set[EntityHandle[{state_name}]]()\n")
            out += "        for id in ids:\n"
            out += String(t"            out.add(self.table.handle_for(id))\n")
            out += "        return out^\n"
            for method_name in ["greater_than", "less_than", "at_least", "at_most"]:
                out += "\n"
                out += String(
                    t"    def for_{f.name}_{method_name}(self, value: {field_type}) -> List[EntityHandle[{state_name}]]:\n"
                )
                out += String(t"        var ids = self.table.state[].state.{f.name}.{method_name}(value)\n")
                out += String(t"        var out = List[EntityHandle[{state_name}]]()\n")
                out += "        for id in ids:\n"
                out += String(t"            out.append(self.table.handle_for(id))\n")
                out += "        return out^\n"
            out += "\n"
            out += String(
                t"    def for_{f.name}_between(self, low: {field_type}, high: {field_type}) ->"
                t" List[EntityHandle[{state_name}]]:\n"
            )
            out += String(t"        var ids = self.table.state[].state.{f.name}.between(low, high)\n")
            out += String(t"        var out = List[EntityHandle[{state_name}]]()\n")
            out += "        for id in ids:\n"
            out += String(t"            out.append(self.table.handle_for(id))\n")
            out += "        return out^\n"
            continue
        if f.modifier == FieldModifier.UNIQUE:
            out += String(t"    def for_{f.name}(self, value: {field_type}) raises -> EntityHandle[{state_name}]:\n")
            out += String(t"        var id = self.table.state[].state.{f.name}.get_bwd(value)\n")
            out += String(t"        return self.table.handle_for(id)\n")
        else:
            out += String(t"    def for_{f.name}(self, value: {field_type}) -> List[EntityHandle[{state_name}]]:\n")
            out += String(t"        var ids = self.table.state[].state.{f.name}.get_bwd(value)\n")
            out += String(t"        var out = List[EntityHandle[{state_name}]]()\n")
            out += "        for id in ids:\n"
            out += String(t"            out.append(self.table.handle_for(id))\n")
            out += "        return out^\n"

    return out


def emit_plain_struct(parsed: ParsedStruct) -> String:
    """Generates an actual, valid Mojo struct definition from a shorthand
    plain struct's parsed fields (`struct Name { field: Type, ... }`) --
    the shorthand grammar itself isn't valid Mojo (no brace-bodied struct
    literal), so this is what makes it a real, emittable construct instead
    of just an internal shape `check_no_relation_cycles` can analyze.
    Field types are rewritten the same way a `@@struct`'s own field types
    are (`emit_field_type` per field) -- `f.modifier` is ignored here even
    though `parse_fields` doesn't reject a modifier keyword on a plain
    struct's fields: those select `Rel`-storage variants for a
    `@@struct`'s generated table machinery, which a plain struct (just a
    value type, never backed by a table) has none of.
    `ImplicitlyCopyable, Movable, ImplicitlyDeletable` -- not also
    `Hashable, Equatable` -- so it works as a `Rel`-backed field's plain
    value on the default path without guessing at hash/eq for arbitrary
    field types that might not support it; a `.rel` author whose own
    field types aren't `Hashable` adds `forwardonly` on the *containing*
    field instead, the same escape hatch used for any other non-`KeyElement`
    field type."""
    var out = String(t"struct {parsed.name}(ImplicitlyCopyable, Movable, ImplicitlyDeletable):\n")
    for f in parsed.fields:
        out += String(t"    var {f.name}: {emit_field_type(f)}\n")
    out += "\n"
    out += "    def __init__(out self"
    for f in parsed.fields:
        out += String(t", var {f.name}: {emit_field_type(f)}")
    out += "):\n"
    if len(parsed.fields) == 0:
        out += "        pass\n"
    for f in parsed.fields:
        out += String(t"        self.{f.name} = {f.name}^\n")
    return out


def line_start_of(source: String, pos: Int) -> Int:
    """Byte offset where the line containing `pos` begins."""
    var bytes = source.as_bytes()
    var line_start = pos
    while line_start > 0 and bytes[line_start - 1] != UInt8(ord("\n")):
        line_start -= 1
    return line_start


def is_in_def_signature(source: String, pos: Int) -> Bool:
    """True if byte offset `pos` sits on a line that starts (after
    indentation) with `def ` -- i.e. `pos` is inside a function's own
    signature rather than somewhere else in its body. Distinguishes a bare
    `@@`'s two roles: opting a function's own signature into
    `sqrrl__world` (`def foo(a: Int, @@)`) versus forwarding it at a call
    site sitting on some other line (`foo(x, @@)`). A def's signature is
    assumed to fit on one line, matching every example so far."""
    var line_start = line_start_of(source, pos)
    var bytes = source.as_bytes()
    var indent_end = line_start
    while indent_end < pos and (
        bytes[indent_end] == UInt8(ord(" ")) or bytes[indent_end] == UInt8(ord("\t"))
    ):
        indent_end += 1
    return String(source[byte = indent_end : pos]).startswith("def ")


def is_in_import_statement(source: String, pos: Int) -> Bool:
    """True if byte offset `pos` sits on a line that starts (after
    indentation) with `from ` or `import ` -- i.e. `pos` names something
    being imported (`from logic.factories import @@make_department`)
    rather than a value being referenced anywhere else. A `WORLD_FUNC`
    name used this way is neither a declaration (there's no `=`) nor
    something `entity_to_type` would ever know about (it's a function
    being imported, not an entity being bound), so `NAME_REF`'s ordinary
    "was this ever constructed or bound" check doesn't apply here -- the
    name just needs its `sqrrl__` prefix, exactly like the plain,
    un-prefixed names already imported alongside it on the same line.
    Assumed to fit on one line, matching every example so far (same
    assumption `is_in_def_signature` already makes for a `def` line)."""
    var line_start = line_start_of(source, pos)
    var bytes = source.as_bytes()
    var indent_end = line_start
    while indent_end < pos and (
        bytes[indent_end] == UInt8(ord(" ")) or bytes[indent_end] == UInt8(ord("\t"))
    ):
        indent_end += 1
    var prefix = String(source[byte = indent_end : pos])
    return prefix.startswith("from ") or prefix.startswith("import ")


def crosses_top_level_def(text: String) -> Bool:
    """True if `text` spans a line starting at column 0 with `def ` --
    i.e. it crosses into a new top-level function body. Mojo has no mutable
    global/static state (see `Table`'s doc comment in `entity.mojo`), so
    `sqrrl__world` only lives inside whichever function called `@@init()`
    or received it as a parameter; `transform_source` uses this to reset
    its per-function bookkeeping (`entity_to_type`, `world_available`) at
    each such boundary, rather than tracking it once for the whole file --
    which previously let a second function silently reference state that
    only existed in a sibling function's scope."""
    if text.startswith("def "):
        return True
    return "\ndef " in text


def is_unmarked_var_target(source: String, pos: Int) -> Bool:
    """True if, scanning backward from byte offset `pos`, the immediately
    preceding text matches `var IDENT = ` where `IDENT` is *not*
    `@@`-marked -- i.e. `pos` is the start of the right-hand side of a
    plain, unmarked variable declaration. Used to reject binding an
    entity-returning function call's result to a variable that isn't
    itself `@@`-marked (`var x = @@make_employer();`) -- the same call used
    as a sub-expression/argument instead (`report(@@make_employer());`),
    where there's no variable at all to mark, correctly doesn't match
    this."""
    var bytes = source.as_bytes()
    var i = pos
    while i > 0 and (bytes[i - 1] == UInt8(ord(" ")) or bytes[i - 1] == UInt8(ord("\t"))):
        i -= 1
    if i == 0 or bytes[i - 1] != UInt8(ord("=")):
        return False
    if i >= 2 and bytes[i - 2] == UInt8(ord("=")):
        return False  # "==" isn't an assignment
    i -= 1
    while i > 0 and (bytes[i - 1] == UInt8(ord(" ")) or bytes[i - 1] == UInt8(ord("\t"))):
        i -= 1
    var ident_end = i
    while i > 0 and is_ident_char(bytes[i - 1]):
        i -= 1
    if i == ident_end:
        return False
    if i >= 2 and bytes[i - 1] == UInt8(ord("@")) and bytes[i - 2] == UInt8(ord("@")):
        return False  # marked -- the existing pending_decl path covers this
    while i > 0 and (bytes[i - 1] == UInt8(ord(" ")) or bytes[i - 1] == UInt8(ord("\t"))):
        i -= 1
    return i >= 3 and String(source[byte = i - 3 : i]) == "var"


def enforce_entity_binding(
    source: String,
    marker_start: Int,
    pending_decl: Optional[String],
    mut entity_to_type: Dict[String, String],
    registered_type: String,
    call_text: String,
) raises:
    """Shared by every call that returns a single entity or a container of
    them (`create`, a `unique` field's `for_<field>`, a non-unique
    `for_<field>`, a relation field's `get_<field>`, or a `def @@funcName(
    ...) -> @@Type:`/`-> Container[@@Type]:` call): binding it to a `var
    @@x = ...` declaration tracks `registered_type` (bare, or
    `encode_container_type`-encoded) in `entity_to_type`; binding it to a
    plain, unmarked variable instead is rejected with a clear,
    container-aware error. `call_text` is the call as written, without its
    leading `@@` (`func_name + "()"`, `fa.entity + "." + fa.field +
    "(...)"`), embedded in the error message either way."""
    if pending_decl:
        entity_to_type[pending_decl.value()] = registered_type
    elif is_unmarked_var_target(source, marker_start):
        raise Error(
            source_location(source, marker_start)
            + ": InvalidSquirrelSyntax: '@@"
            + call_text
            + "' returns "
            + (
                "'"
                + container_wrapper_of(registered_type)
                + "[@@"
                + container_element_of(registered_type)
                + "]'" if is_container_type(registered_type) else "'@@" + registered_type + "'"
            )
            + " -- bind it to an '@@'-marked variable"
            " ('var @@x = @@"
            + call_text
            + ";'), not a plain one"
        )


def build_create_call(
    source: String,
    marker_start: Int,
    type_name: String,
    fields: List[ConstructField],
    relation_schema: Dict[String, Dict[String, String]],
    function_returns: Dict[String, String],
    unique_fields: Dict[String, List[String]],
    ordered_fields: Dict[String, List[String]],
    mut entity_to_type: Dict[String, String],
    mut world_available: Bool,
) raises -> String:
    """Builds `sqrrl__world.TypeName.create(name = value, ...)`, validating
    each field's `@@` marking against `relation_schema[type_name]` -- must
    match the struct's own declaration, the same way a mismatched
    struct-field declaration itself is already rejected (`parse_fields`) --
    and recursively rewriting *every* field's value through
    `rewrite_markers` (not only a relation field's), so any `@@`-marked
    expression embedded anywhere inside it -- a bare reference (`@@bob`), a
    nested construct (`@@Employee { ... }`), a chained field read, a call
    to an `@@`-marked function, however deeply nested inside an otherwise
    ordinary expression (`Address(@@dept.name)`) -- rewrites correctly
    instead of passing straight through as literal, uncompilable text. A
    field with no embedded markers at all comes back byte-for-byte
    unchanged, same as before. `entity_to_type`/`world_available` are
    threaded through (not copied) so a nested fragment sees exactly what
    the enclosing function has already established (an entity it
    constructed earlier, or that `sqrrl__world` is already in scope) --
    neither a top-level nor a nested construct binds a name of its own
    here, so both are only ever read through this call, but still need to
    be `mut` to flow into the recursive `rewrite_markers` calls below.
    `source`/`marker_start` are only for error location -- the `@@TypeName{`
    construct's own start, since individual fields don't carry a position of
    their own (`ConstructField` is built purely from parsed text)."""
    var type_relations = (
        relation_schema[type_name].copy() if type_name in relation_schema else Dict[String, String]()
    )
    var args = String()
    var first = True
    for f in fields:
        var declared_as_relation = f.name in type_relations
        if f.is_relation and not declared_as_relation:
            raise Error(
                source_location(source, marker_start)
                + ": InvalidSquirrelSyntax: '"
                + type_name
                + "."
                + f.name
                + "' isn't declared as a relation field -- use '."
                + f.name
                + "' here, not '.@@"
                + f.name
                + "'"
            )
        if not f.is_relation and declared_as_relation:
            raise Error(
                source_location(source, marker_start)
                + ": InvalidSquirrelSyntax: '"
                + type_name
                + "."
                + f.name
                + "' is declared as a relation field (`@@"
                + f.name
                + ": @@...`) -- must be written '.@@"
                + f.name
                + "' here too"
            )
        var value = rewrite_markers(
            f.value,
            relation_schema,
            function_returns,
            unique_fields,
            ordered_fields,
            entity_to_type,
            world_available,
        )
        if not first:
            args += ", "
        args += f.name + " = " + value
        first = False
    return String(t"sqrrl__world.{type_name}.create({args})")


def rewrite_markers(
    source: String,
    relation_schema: Dict[String, Dict[String, String]],
    function_returns: Dict[String, String],
    unique_fields: Dict[String, List[String]],
    ordered_fields: Dict[String, List[String]],
    mut entity_to_type: Dict[String, String],
    mut world_available: Bool,
) raises -> String:
    """Rewrites every `@@`-marked construct in `source` to plain Mojo,
    leaving everything else byte-for-byte untouched -- mirrors the Zig
    parser's `transformSquirrel`, minus the incref/auto-defer machinery it
    needed (Mojo's own ASAP destruction already handles that, see
    `Scanner.find_next_marker`'s doc comment).

    `entity_to_type`/`world_available` are `mut` rather than owned locals
    here because this is *shared*, recursively-invokable core:
    `transform_source` calls it once for a whole file, starting both fresh,
    and `build_create_call` calls it again for each construct field's own
    value text (`Address(@@dept.name)`, `@@Employee { ... }`, `@@bob`, ...),
    passing the *same* two along rather than fresh ones -- a field's value
    can reference an entity the enclosing function already constructed, or
    need `sqrrl__world` the enclosing function already has, so a nested
    fragment has to see exactly what's already been established, not start
    over. Neither a top-level construct nor one nested inside a field's
    value binds a name of its own (only a `var @@name = ...` declaration
    does, tracked below via `pending_decl`), so recursing doesn't need its
    own copy of either -- but Mojo requires `mut` regardless, to let
    mutations from the (rare) nested `@@init()`/entity-declaration case
    flow back to the caller.

    `relation_schema` (`driver.build_relation_schema`) is struct name ->
    relation field name -> target struct name, project-wide -- needed to
    resolve a chained field access (`@@alice.@@employee.@@boss.title`):
    starting from `entity_to_type[fa.entity]`, each hop in
    `FieldAccess.hops` looks up its target type in this schema (an
    intermediate hop can point at a struct declared in a different file, so
    this can't be resolved from local knowledge of `source` alone) before
    moving on to the next one, exactly mirroring how `emit_file` already
    needed project-wide struct info to resolve cross-file relation *field
    types* -- this is the same resolution, just applied at a script's
    *use* site instead of a struct's declaration site.

    `function_returns` (`driver.build_function_returns`) is function name
    -> the `@@Type` it returns, project-wide -- lets a call site
    (`@@funcName(...)`, `MarkerKind.WORLD_FUNC`) infer `entity_to_type`
    automatically when its result is bound to a fresh `@@`-marked variable
    (`var @@x = @@make_employer();`, no explicit `: @@Type` needed), and
    reject binding it to an unmarked one instead (`var x =
    @@make_employer();`) -- the same call used as a sub-expression/argument
    rather than a fresh declaration is left alone, since there's no
    variable there to mark in the first place.

    `@@struct` becomes a generated table pair (`emit_table`), same as
    before. But table *instances* now all live in one place: the generated,
    project-wide `sqrrl__Squirrel` (see `driver.emit_squirrel_module`) --
    there's no per-file, per-type table variable anymore. A script obtains
    it explicitly, once per function that needs it, one of two ways:
    `@@init()` becomes `var sqrrl__world = sqrrl__init()`, or a function
    whose own name is marked (`@@name(`, `MarkerKind.WORLD_FUNC`) gets
    `sqrrl__world` auto-inserted as its first parameter (a definition) or
    first argument (a call site), silently -- `def @@make_department(a:
    Int)` becomes `def sqrrl__make_department(mut sqrrl__world:
    sqrrl__Squirrel, a: Int)`, and `@@make_department(x)` becomes
    `sqrrl__make_department(sqrrl__world, x)`. Marking the *name* rather
    than threading a separate `@@` parameter/argument means the function is
    unambiguously "one that needs world" at both its definition and every
    call site, with nothing extra to keep in sync between them. `@@TypeName
    { ... }` becomes `sqrrl__world.TypeName.create(...)`, and `var @@alice =
    @@TypeName { ... };` additionally records that `alice` was constructed
    as a `TypeName`, so a later `@@alice.field` read/write knows which
    table to route through: `sqrrl__world.TypeName.get_field(sqrrl__alice)`
    / `.set_field(sqrrl__alice, expr)`. A chain
    (`@@alice.@@employee.title`) nests one `get_<hop>(...)` call per
    intermediate relation inside the next, all as a single expression --
    `sqrrl__world.Employee.get_title(sqrrl__world.Person.get_employee(
    sqrrl__alice))` -- rather than splicing intermediate temp-variable
    declarations, so it stays usable inline (`print(@@alice.@@employee.title)`)
    the same way a plain single-hop access already is.

    A function can also *return* an entity: `-> @@Department:` becomes
    `-> EntityHandle[sqrrl__DepartmentTableState]:`. Binding that at a call
    site needs the explicit `@@name: @@Type` form too
    (`var @@dept: @@Department = @@make_department();`), not the bare
    `var @@dept = ...` construct-inferring form -- there's no `@@Type{...}`
    or bare `@@name` on the right for `entity_to_type` to infer the type
    from (it's a function call), so the type has to be stated directly
    instead. The same `@@name: @@Type` shape used for entity parameters
    handles this uniformly, just with `=` following instead of a
    signature's `,`/`)`.

    Both `entity_to_type` and whether `sqrrl__world` is available
    (`world_available`) are function-scoped, reset at every top-level `def`
    (`crosses_top_level_def`) -- Mojo has no mutable global/static state
    (see `Table`'s doc comment in `entity.mojo`), so neither an entity
    variable nor `sqrrl__world` itself outlives the function it was bound
    in. Referencing an entity that was never constructed via `@@Type{...}`
    in this same function, or using `@@Type{...}`/`@@entity.field`/a bare
    `@@` before this function has `sqrrl__world` in scope, raises a clear
    error rather than emitting code that fails to compile downstream."""
    var sc = Scanner(source)
    var out = String()
    var pos = 0

    var pending_decl: Optional[String] = None
    var pending_for_loop_decl: Optional[String] = None

    while True:
        var kind = sc.find_next_marker()
        if kind == MarkerKind.NONE:
            break
        var marker_start = sc.pos
        var between = String(source[byte = pos : marker_start])
        out += between
        if ";" in between:
            # The declaration statement that set `pending_decl` (if any)
            # already ended without a construct following it -- don't let
            # it leak onto some unrelated, later construct.
            pending_decl = None
        if ":" in between:
            # Same idea for `pending_for_loop_decl`: the `for @@name in
            # ...:` header it came from already ended (its own trailing
            # `:`) without the iterated expression turning out to be a
            # recognized container call -- don't let it leak into the loop
            # body's own, unrelated markers.
            pending_for_loop_decl = None
        if crosses_top_level_def(between):
            entity_to_type = Dict[String, String]()
            world_available = False

        if kind == MarkerKind.STRUCT:
            var parsed = sc.parse_struct()
            out += emit_table(parsed)
            pending_decl = None
            pending_for_loop_decl = None

        elif kind == MarkerKind.PLAIN_STRUCT:
            var parsed = sc.parse_plain_struct()
            out += emit_plain_struct(parsed)
            pending_decl = None
            pending_for_loop_decl = None

        elif kind == MarkerKind.INIT:
            sc.parse_init()
            out += "var sqrrl__world = sqrrl__init()"
            world_available = True
            pending_decl = None
            pending_for_loop_decl = None

        elif kind == MarkerKind.WORLD_FUNC:
            var func_name = sc.parse_world_func()
            sc.skip_whitespace()
            var has_more_args = sc.peek() != UInt8(ord(")"))
            if is_in_def_signature(source, marker_start):
                out += String(
                    t"{sqrrl_prefixed(func_name)}(mut sqrrl__world: sqrrl__Squirrel"
                )
                world_available = True
            else:
                if not world_available:
                    raise sc.err(
                        "InvalidSquirrelSyntax: calling '@@"
                        + func_name
                        + "(...)' needs 'sqrrl__world' -- call @@init() or"
                        " mark this function's own name with '@@' too"
                    )
                out += String(t"{sqrrl_prefixed(func_name)}(sqrrl__world")
                if func_name in function_returns:
                    enforce_entity_binding(
                        source, marker_start, pending_decl, entity_to_type, function_returns[func_name], func_name + "()"
                    )
                    if pending_for_loop_decl and is_container_type(function_returns[func_name]):
                        # `for @@name in @@some_func():` -- same element-type
                        # binding the table-call branch does for
                        # `for_<field>`/`all()`, just for a `@@`-marked
                        # function's own container return type instead.
                        entity_to_type[pending_for_loop_decl.value()] = container_element_of(function_returns[func_name])
            if has_more_args:
                out += ", "
            pending_decl = None
            pending_for_loop_decl = None

        elif kind == MarkerKind.ENTITY_PARAM:
            var ep = sc.parse_entity_param()
            var is_param = is_in_def_signature(source, marker_start)
            var is_var_decl = False
            if not is_param:
                var save = sc.pos
                sc.skip_trivia()
                is_var_decl = sc.peek() == UInt8(ord("=")) and sc.peek_at(1) != UInt8(ord("="))
                sc.pos = save
            if not is_param and not is_var_decl:
                raise sc.err(
                    "InvalidSquirrelSyntax: '@@"
                    + ep.name
                    + ": @@"
                    + ep.type_name
                    + "' is only valid as a function parameter or a"
                    " variable declaration ('var @@"
                    + ep.name
                    + ": @@"
                    + ep.type_name
                    + " = expr;') -- did you mean '@@"
                    + ep.name
                    + " = @@"
                    + ep.type_name
                    + "{...}' to construct one directly instead?"
                )
            if ep.wrapper:
                out += String(
                    t"{sqrrl_prefixed(ep.name)}: {ep.wrapper.value()}[EntityHandle[{sqrrl_prefixed(ep.type_name)}TableState]]"
                )
                entity_to_type[ep.name] = encode_container_type(ep.wrapper.value(), ep.type_name)
            else:
                out += String(
                    t"{sqrrl_prefixed(ep.name)}: EntityHandle[{sqrrl_prefixed(ep.type_name)}TableState]"
                )
                entity_to_type[ep.name] = ep.type_name
            pending_decl = None
            pending_for_loop_decl = None

        elif kind == MarkerKind.RETURN_TYPE:
            # A container return type's own `List[`/`]` are never consumed
            # by this marker (they sit outside it, already copied through
            # as ordinary text) -- both the bare `-> @@Type:` and container
            # `-> List[@@Type]:` forms emit the identical `EntityHandle
            # [...]` text here; see `NameRef`'s doc comment. But this same
            # `Ident[@@Type]` shape is also how an *unmarked* `name:
            # List[@@Type]` declaration looks by the time the scanner
            # reaches the inner `@@Type` (a marked `@@name: List[@@Type]`
            # would already have been claimed as `ENTITY_PARAM` before
            # getting here) -- reject that the same way `parse_fields`
            # already rejects it inside a `@@struct` body, rather than
            # silently rewriting the type and leaving the name inconsistent.
            if is_unmarked_container_declaration(source, marker_start):
                raise sc.err(
                    "InvalidSquirrelSyntax: a 'name: Container[@@Type]'"
                    " declaration needs its own name '@@'-marked too"
                    " ('@@name: Container[@@Type]', not 'name:"
                    " Container[@@Type]') -- same as a relation field"
                    " inside a '@@struct'"
                )
            var nr = sc.parse_name_ref()
            out += String(t"EntityHandle[{sqrrl_prefixed(nr.name)}TableState]")
            pending_decl = None
            pending_for_loop_decl = None

        elif kind == MarkerKind.CONSTRUCT:
            var c = sc.parse_construct()
            if not world_available:
                raise sc.err(
                    "InvalidSquirrelSyntax: constructing '@@"
                    + c.type_name
                    + "' needs 'sqrrl__world' -- call @@init() or add"
                    " '@@' to this function's own parameters first"
                )
            out += build_create_call(
                source,
                marker_start,
                c.type_name,
                c.fields,
                relation_schema,
                function_returns,
                unique_fields,
                ordered_fields,
                entity_to_type,
                world_available,
            )
            if pending_decl:
                entity_to_type[pending_decl.value()] = c.type_name
            pending_decl = None
            pending_for_loop_decl = None

        elif kind == MarkerKind.FOR_ENTITY_LOOP:
            # `for @@name in <expr>:` -- consumes through `in`, leaving
            # whatever follows (the iterated expression) for the very next
            # marker to handle; that marker's own classification (currently
            # only a table-level call's `is_list_returning` case, e.g.
            # `@@Type.for_<field>(...)`/`@@Type.all()`) is what actually
            # registers `name`'s element type, once it knows what the
            # container's element type even is.
            var name = sc.parse_for_entity_loop()
            out += String(t"{sqrrl_prefixed(name)} in ")
            pending_decl = None
            pending_for_loop_decl = Optional[String](name)

        elif kind == MarkerKind.FIELD_ACCESS:
            var fa = sc.parse_field_access()
            if fa.field == "" and fa.index_expr:
                # A bare indexed reference, `@@matches[0]`, used as a value
                # in its own right (an argument, a plain `var x = ...` RHS,
                # ...) rather than the start of a `.field` chain. Never
                # enforced-marked the way create/for_<field>/a relation
                # get_<field> are -- extracting a raw, untracked
                # `EntityHandle` this way is deliberately as friction-free
                # as any other escaped value (usable via `@@Type.method
                # (value)` regardless), not something that needs `@@`
                # marking to be useful. If it *is* marked, though,
                # `entity_to_type` still gets the container's element type,
                # for free -- no reason not to track it when asked to.
                if fa.entity not in entity_to_type:
                    raise sc.err(
                        "InvalidSquirrelSyntax: '"
                        + fa.entity
                        + "' was never constructed via @@Type{...} in this"
                        " function -- can't tell which table its fields live in"
                    )
                var declared_type = entity_to_type[fa.entity]
                if not is_container_type(declared_type):
                    raise sc.err(
                        "InvalidSquirrelSyntax: '@@" + fa.entity + "' isn't a container -- can't index into it"
                    )
                var rewritten_index = rewrite_markers(
                    fa.index_expr.value(),
                    relation_schema,
                    function_returns,
                    unique_fields,
                    ordered_fields,
                    entity_to_type,
                    world_available,
                )
                out += String(t"{sqrrl_prefixed(fa.entity)}[{rewritten_index}]")
                if pending_decl:
                    entity_to_type[pending_decl.value()] = container_element_of(declared_type)
                pending_decl = None
                pending_for_loop_decl = None

            elif fa.is_call and fa.entity not in entity_to_type:
                # @@Type.method(args) -- a table-level call (e.g. a generated
                # for_<field> lookup), not an instance field access. Only
                # reachable when `entity` isn't itself a declared variable,
                # so this can't shadow the ordinary @@entity.field path
                # below.
                if fa.index_expr:
                    raise sc.err(
                        "InvalidSquirrelSyntax: '@@"
                        + fa.entity
                        + "[...]' -- can't index a type name, only a"
                        " container-tracked '@@'-marked variable"
                    )
                if fa.entity not in relation_schema:
                    raise sc.err(
                        "InvalidSquirrelSyntax: '@@"
                        + fa.entity
                        + "' is neither a constructed entity nor a known"
                        " @@struct -- can't call '"
                        + fa.field
                        + "' on it"
                    )
                if len(fa.hops) > 0:
                    raise sc.err(
                        "InvalidSquirrelSyntax: '@@"
                        + fa.entity
                        + "."
                        + fa.field
                        + "(...)' -- relation hops aren't valid before a"
                        " table-level call"
                    )
                if not world_available:
                    raise sc.err(
                        "InvalidSquirrelSyntax: calling '@@"
                        + fa.entity
                        + "."
                        + fa.field
                        + "(...)' needs 'sqrrl__world' -- call @@init() or"
                        " add '@@' to this function's own parameters first"
                    )
                # `create` and a `unique` field's own `for_<field>` return a
                # single EntityHandle of *this* type; `get_<field>` for a
                # *relation* field also returns a single EntityHandle, but
                # of that field's own target type instead (`relation_schema
                # [fa.entity][field]`), not `fa.entity` itself -- easy to
                # miss since it's not literally `fa.entity`'s own table.
                # An `ordered` field's `for_<field>` (exact match only --
                # its five range-shaped siblings stay `List`-returning like
                # any other field's `for_<field>`) returns
                # `Set[EntityHandle[...]]` instead, matching `emit_table`'s
                # own codegen for it (see its `FieldModifier.ORDERED`
                # branch). Any other `for_<field>` returns
                # `List[EntityHandle[...]]` (tracked via `entity_to_type`'s
                # container encoding, `encode_container_type`). All these
                # are tracked and enforced the same way now that both a single entity
                # and a container of them can be properly followed up with
                # `@@name.field`/`@@name[i].field`; anything else
                # (`get_<field>`/`set_<field>` for a *plain* field, ...) is
                # none of these and is never tracked/enforced here,
                # mirroring WORLD_FUNC's own function_returns-gated check
                # below.
                var is_entity_returning = fa.field == "create"
                var is_list_returning = False
                var registered_type = fa.entity
                if not is_entity_returning and fa.field.startswith("for_"):
                    var target_field = String(fa.field[byte=4 : fa.field.byte_length()])
                    var is_unique_field = False
                    if fa.entity in unique_fields:
                        for uf in unique_fields[fa.entity]:
                            if uf == target_field:
                                is_unique_field = True
                                break
                    if is_unique_field:
                        is_entity_returning = True
                    else:
                        is_list_returning = True
                        if _is_ordered_field_query(fa.entity, target_field, ordered_fields):
                            registered_type = encode_container_type("Set", fa.entity)
                        else:
                            registered_type = encode_container_type("List", fa.entity)
                elif fa.field.startswith("get_") and fa.entity in relation_schema:
                    var target_field = String(fa.field[byte=4 : fa.field.byte_length()])
                    if target_field in relation_schema[fa.entity]:
                        registered_type = relation_schema[fa.entity][target_field]
                        # A collection-typed relation field's `get_<field>`
                        # returns `List[EntityHandle[...]]`, not a single
                        # entity -- `relation_schema` already carries that
                        # distinction pre-encoded (see
                        # `build_relation_schema`), same shape
                        # `for_<field>`'s own `is_list_returning` case builds
                        # above, just via `encode_container_type` here
                        # instead of there.
                        if is_container_type(registered_type):
                            is_list_returning = True
                        else:
                            is_entity_returning = True
                elif fa.field == "all":
                    # Generated for every struct (`keepalive` or not, see
                    # `emit_table`), returning `Set[EntityHandle[...]]` --
                    # `Set`, not `List`, unlike every other container case
                    # above, since that's `Table.all()`'s own actual return
                    # type.
                    is_list_returning = True
                    registered_type = encode_container_type("Set", fa.entity)
                if is_entity_returning or is_list_returning:
                    enforce_entity_binding(
                        source,
                        marker_start,
                        pending_decl,
                        entity_to_type,
                        registered_type,
                        fa.entity + "." + fa.field + "(...)",
                    )
                if is_list_returning and pending_for_loop_decl:
                    # `for @@name in @@Type.for_<field>(...)/.all():` binds
                    # `@@name` to the container's *element* type, not the
                    # container type `enforce_entity_binding` above just
                    # registered `pending_decl` (if any) as -- the two are
                    # mutually exclusive in practice (a `for` loop header has
                    # no `var @@x =` of its own to set `pending_decl`), but
                    # kept as separate state regardless, since they mean
                    # different things.
                    entity_to_type[pending_for_loop_decl.value()] = container_element_of(registered_type)
                out += String(t"sqrrl__world.{fa.entity}.{fa.field}")
                pending_decl = None
                pending_for_loop_decl = None

            else:
                if fa.entity not in entity_to_type:
                    raise sc.err(
                        "InvalidSquirrelSyntax: '"
                        + fa.entity
                        + "' was never constructed via @@Type{...} in this"
                        " function -- can't tell which table its fields live in"
                    )
                var declared_type = entity_to_type[fa.entity]
                if is_container_type(declared_type) and fa.is_call and not fa.index_expr:
                    # A method call directly on the container itself
                    # (`@@team.append(...)`, `.extend`, `.count`, ...), not
                    # a field access on one of its elements -- pass through
                    # untouched (just `@@` stripped) rather than either
                    # requiring `[i]` first or routing through a generated
                    # get_/set_<field>. There's no way to tell "is `field` a
                    # real container method" from "a coincidentally-named
                    # struct field" without real type information, but
                    # every field access on an *element* already goes
                    # through `[i].field` instead, so this can't collide
                    # with that path -- and it needs no `sqrrl__world`
                    # either, since it's a plain Mojo list operation, not a
                    # table access.
                    out += String(t"{sqrrl_prefixed(fa.entity)}.{fa.field}")
                    pending_decl = None
                    pending_for_loop_decl = None
                else:
                    if not world_available:
                        raise sc.err(
                            "InvalidSquirrelSyntax: accessing '@@"
                            + fa.entity
                            + "."
                            + fa.field
                            + "' needs 'sqrrl__world' -- call @@init() or add"
                            " '@@' to this function's own parameters first"
                        )
                    var current_type: String
                    var expr: String
                    if is_container_type(declared_type):
                        if not fa.index_expr:
                            raise sc.err(
                                "InvalidSquirrelSyntax: '@@"
                                + fa.entity
                                + "' is a "
                                + container_wrapper_of(declared_type)
                                + " of '@@"
                                + container_element_of(declared_type)
                                + "' -- index into it first ('@@"
                                + fa.entity
                                + "[i]."
                                + fa.field
                                + "')"
                            )
                        current_type = container_element_of(declared_type)
                        var rewritten_index = rewrite_markers(
                            fa.index_expr.value(),
                            relation_schema,
                            function_returns,
                            unique_fields,
                            ordered_fields,
                            entity_to_type,
                            world_available,
                        )
                        expr = String(t"{sqrrl_prefixed(fa.entity)}[{rewritten_index}]")
                    else:
                        if fa.index_expr:
                            raise sc.err(
                                "InvalidSquirrelSyntax: '@@"
                                + fa.entity
                                + "' isn't a container -- can't index into it"
                            )
                        current_type = declared_type
                        expr = sqrrl_prefixed(fa.entity)
                    for hop in fa.hops:
                        if current_type not in relation_schema or hop not in relation_schema[current_type]:
                            raise sc.err(
                                "InvalidSquirrelSyntax: '"
                                + current_type
                                + "' has no relation field '"
                                + hop
                                + "'"
                            )
                        expr = String(t"sqrrl__world.{current_type}.get_{hop}({expr})")
                        current_type = relation_schema[current_type][hop]
                    if fa.write_value:
                        out += String(
                            t"sqrrl__world.{current_type}.set_{fa.field}({expr}, {fa.write_value.value()});"
                        )
                    elif fa.is_call:
                        # An instance method call on the field itself
                        # (`@@eng.add_to_projects(@@website)`), not a plain
                        # field read -- the generated method (`add_to_
                        # <field>`/`remove_from_<field>`, ...) takes the
                        # entity as its own first argument, so `get_` isn't
                        # spliced in and `expr` is injected as that first
                        # argument. `parse_field_access` left the call's own
                        # `(args)` unconsumed, so the opening `(` is consumed
                        # here to inject a comma before whatever follows, if
                        # anything did -- same technique `MarkerKind.
                        # WORLD_FUNC` uses to inject `sqrrl__world` as a
                        # call's own first argument.
                        if not sc.try_consume("("):
                            raise sc.err("InvalidSquirrelSyntax: expected '(' after '" + fa.field + "'")
                        sc.skip_whitespace()
                        var has_more_args = sc.peek() != UInt8(ord(")"))
                        out += String(t"sqrrl__world.{current_type}.{fa.field}({expr}")
                        if has_more_args:
                            out += ", "
                    else:
                        out += String(t"sqrrl__world.{current_type}.get_{fa.field}({expr})")
                    pending_decl = None
                    pending_for_loop_decl = None

        else:  # MarkerKind.NAME_REF
            var nr = sc.parse_name_ref()
            out += sqrrl_prefixed(nr.name)
            var save = sc.pos
            sc.skip_trivia()
            var is_decl = sc.peek() == UInt8(ord("=")) and sc.peek_at(1) != UInt8(ord("="))
            if not is_decl and not is_in_import_statement(source, marker_start) and nr.name not in entity_to_type:
                raise sc.err(
                    "InvalidSquirrelSyntax: '@@"
                    + nr.name
                    + "' is referenced but was never constructed or bound"
                    " -- every '@@'-marked entity must come from a"
                    " '@@Type{...}' construct, an entity-returning call, or"
                    " an entity parameter before it can be used"
                )
            if is_decl:
                sc.pos += 1  # consume '='
                sc.skip_trivia()
                if not sc.starts_with("@@"):
                    # Not itself `@@`-marked -- the one other shape that's
                    # still legitimate is a bare container constructor,
                    # `Container[@@Type](...)` (`List[@@Person]()`): the
                    # `@@Type` inside it gets found and rewritten as its
                    # own marker later regardless (any `@@Type` sitting in
                    # an `Ident[...]` position does, see `MarkerKind.
                    # RETURN_TYPE`'s container form), but nothing else
                    # registers `entity_to_type` for *this* declaration in
                    # that case, since there's no `@@Type{...}`/`@@Type.
                    # method()` marker here for `pending_decl` to attach
                    # to -- so this does it directly, as a lookahead,
                    # without consuming anything (the constructor call
                    # itself is left for the normal pass-through/marker
                    # loop to handle unchanged).
                    var lookahead = sc.pos
                    var wrapper = sc.scan_ident()
                    sc.skip_trivia()
                    var matched_container = False
                    if wrapper.byte_length() > 0 and sc.try_consume("["):
                        sc.skip_trivia()
                        if sc.try_consume("@@"):
                            var type_name = sc.scan_ident()
                            if type_name.byte_length() > 0:
                                matched_container = True
                                entity_to_type[nr.name] = encode_container_type(wrapper, type_name)
                    sc.pos = lookahead
                    if not matched_container:
                        raise sc.err(
                            "InvalidSquirrelSyntax: '@@"
                            + nr.name
                            + "' must be initialized from a '@@'-marked"
                            " value (e.g. '@@Type{...}', another"
                            " '@@'-marked entity, or a container"
                            " constructor like 'List[@@Type]()') -- an"
                            " unmarked right-hand side would silently"
                            " skip the construct rewrite"
                        )
            sc.pos = save
            pending_decl = String(nr.name) if is_decl else None
            pending_for_loop_decl = None

        pos = sc.pos

    out += String(source[byte = pos : source.byte_length()])
    return out


def transform_source(
    source: String,
    relation_schema: Dict[String, Dict[String, String]],
    function_returns: Dict[String, String],
    unique_fields: Dict[String, List[String]],
    ordered_fields: Dict[String, List[String]],
) raises -> String:
    """Entry point for converting one whole `.rel` file: starts
    `entity_to_type`/`world_available` fresh and hands off to
    `rewrite_markers`, which does the actual work (see its own doc comment
    for everything `@@`-marked it handles) -- kept as a separate, minimal
    wrapper so callers converting a full file don't need to know or care
    that the same core is also invoked recursively, per construct field,
    from `build_create_call`."""
    var entity_to_type = Dict[String, String]()
    var world_available = False
    return rewrite_markers(
        source, relation_schema, function_returns, unique_fields, ordered_fields, entity_to_type, world_available
    )
