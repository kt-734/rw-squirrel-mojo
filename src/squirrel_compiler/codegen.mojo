from squirrel_compiler.parser import (
    ParsedStruct,
    Field,
    TypeParam,
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


def emit_table(parsed: ParsedStruct, plain_struct_fields: Dict[String, List[Field]]) raises -> String:
    """Emits two generated structs per `@@struct`.

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
    # Every table gets a `keepalive` set, not just `keepalive`-tagged
    # structs -- `create`/`sqrrl__create_with_id` still only *auto*-add to
    # it when `is_keepalive` (below), but a non-tagged struct's own table
    # still needs somewhere to retain entities `sqrrl__from_json_with_id`
    # reconstructs (`emit_world_module`'s `sqrrl__world_from_json`): those
    # have no relation field pointing at them yet and aren't
    # `keepalive`-tagged, so without this they'd die the instant their
    # return value is otherwise discarded, same as any entity in this
    # framework does once nothing holds a strong reference to it.
    out += String(t"    var keepalive: Set[EntityHandle[{state_name}]]\n")
    out += "\n"
    out += "    def __init__(out self):\n"
    out += String(t"        self.table = Table[{state_name}]({state_name}())\n")
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

    # `sqrrl__create_with_id` -- `create`'s twin, for `sqrrl__world_from_json`
    # (see `emit_world_module`) reconstructing a `sqrrl__World` from a JSON
    # dump: a relation field elsewhere in the dump serializes as another
    # entity's exact original id, so recreating that entity has to land on
    # that same id, not whatever `Table.create`'s own auto-allocation would
    # hand out. Always `raises`, unlike `create` (conditionally `raises` only
    # if a `unique` field's `UniqueRel.put` could reject a duplicate) --
    # `Table.create_with_id` itself raises if the requested id is already
    # live.
    out += String(t"    def sqrrl__create_with_id(mut self, sqrrl__id: UInt32")
    for f in parsed.fields:
        out += String(t", {f.name}: {emit_field_type(f)}")
    out += String(t") raises -> EntityHandle[{state_name}]:\n")
    out += "        var e = self.table.create_with_id(sqrrl__id)\n"
    for f in parsed.fields:
        out += String(t"        self.table.state[].state.{f.name}.put(e.id(), {f.name})\n")
    if parsed.is_keepalive:
        out += "        self.keepalive.add(e.copy())\n"
    out += "        return e\n"
    out += "\n"
    out += String(t"    def all(self) -> Set[EntityHandle[{state_name}]]:\n")
    out += "        return self.table.all()\n"
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

    out += "\n"
    out += emit_table_json_methods(parsed, state_name, plain_struct_fields)
    return out


def _plain_struct_base_name(type_str: String) -> String:
    """`Box[String]` -> `Box`; `Address` -> `Address` unchanged -- strips a
    generic plain struct's own type-argument suffix so a field naming an
    *instantiation* (`home: Box[String]`) still resolves against
    `plain_struct_fields`'s bare-name keys, the same way a non-generic
    plain struct's bare name already does. Safe to call on any type
    string -- a real container like `List[String]` also has a `[`, but
    `"List"` was never registered as a plain struct name, so the dict
    lookup this feeds into is the actual disambiguator; this alone can't
    misidentify one."""
    var bracket = type_str.find("[")
    if bracket < 0:
        return type_str
    return String(type_str[byte=0 : bracket])


def _collect_relation_targets(
    fields: List[Field],
    plain_struct_fields: Dict[String, List[Field]],
    mut seen: Dict[String, Bool],
    mut out: List[String],
) raises:
    """Every distinct `@@struct` name `fields` needs a live table
    reference to reconstruct, direct *or* transitive through an embedded
    plain struct's own relation field (`Note { @@author: @@Employee,
    ... }` embedded via a plain `note: Note` field still needs
    `Employee`'s table to reconstruct `Note`'s own `@@author`) -- this is
    exactly the parameter list `from_json` needs beyond `mut self`/`mut
    sc`, deduplicated and in first-encountered order. Safe against
    infinite recursion through plain structs embedding each other: the
    same relation graph `check_no_relation_cycles` already walks (which
    includes plain-struct-embedding edges) is guaranteed acyclic before
    codegen ever runs."""
    for f in fields:
        if f.modifier == FieldModifier.MULTI:
            if f.type_str.startswith("@@"):
                var target = String(f.type_str[byte=2 : f.type_str.byte_length()])
                if target not in seen:
                    seen[target] = True
                    out.append(target)
            continue
        if f.type_str.startswith("@@"):
            var target = String(f.type_str[byte=2 : f.type_str.byte_length()])
            if target not in seen:
                seen[target] = True
                out.append(target)
            continue
        if is_wrapped_relation_type(f.type_str):
            var target = relation_target_of(f.type_str)
            if target not in seen:
                seen[target] = True
                out.append(target)
            continue
        var base_name = _plain_struct_base_name(f.type_str)
        if base_name in plain_struct_fields:
            _collect_relation_targets(plain_struct_fields[base_name], plain_struct_fields, seen, out)


def relation_targets_for(
    fields: List[Field], plain_struct_fields: Dict[String, List[Field]]
) raises -> List[String]:
    """Convenience wrapper around `_collect_relation_targets`, allocating
    its own fresh `seen`/`out` -- used both internally (`from_json`
    codegen for one struct's own field list) and by
    `driver.build_relation_targets` to build the project-wide "struct
    name -> its own relation targets" map the `@@Type.from_json(...)`
    call-site rewrite needs (see `rewrite_markers`)."""
    var seen = Dict[String, Bool]()
    var out = List[String]()
    _collect_relation_targets(fields, plain_struct_fields, seen, out)
    return out^


def _relation_target_params(targets: List[String]) -> String:
    """`, mut sqrrl__tbl_Department: sqrrl__DepartmentTable, ...` --
    `from_json`'s own parameter list beyond `mut self`/`mut sc`, one per
    entry in `_collect_relation_targets`'s output. `sqrrl__tbl_`-prefixed
    so a parameter can never collide with a field literally named the
    same as a target struct."""
    var out = String()
    for t in targets:
        out += String(t", mut sqrrl__tbl_{t}: {sqrrl_prefixed(t)}Table")
    return out^


def _relation_target_args(targets: List[String]) -> String:
    """The call-site counterpart to `_relation_target_params` -- passes
    each already-in-scope `sqrrl__tbl_<Target>` parameter straight
    through, whether at a `@@Type.from_json(...)` call site (see
    `rewrite_markers`) or from an enclosing struct's own `from_json` into
    a nested plain struct's `sqrrl__<Name>_from_json` (always a subset of
    the enclosing struct's own parameters, by construction -- see
    `_collect_relation_targets`)."""
    var out = String()
    for t in targets:
        if out.byte_length() > 0:
            out += ", "
        out += String(t"sqrrl__tbl_{t}")
    return out^


def _relation_field_shape(f: Field) -> String:
    """Which of `from_json`'s three field-parsing shapes `f` needs --
    `"bare"` (a single id, `@@Employee`), `"multi"`/`"wrapped"` (an array
    of ids, `multi @@members: @@Employee` or `List[@@Employee]`), or
    `"optional"` (either an id or `null`, `Optional[@@Employee]`) for a
    relation field, versus `"plain"` for anything else (a leaf, a plain
    container, a nested plain struct, or a `multi`/wrapped field whose
    *element* isn't itself a relation) -- reconstructing a relation needs
    the target's own table (`self.<Target>.table.handle_for`), which the
    shared `sqrrl__from_json[T]` dispatcher has no way to reach, so these
    three shapes are the ones `emit_squirrel_from_json_method` inlines by
    hand instead of delegating to it."""
    if f.modifier == FieldModifier.MULTI:
        return "multi" if f.type_str.startswith("@@") else "plain"
    if f.type_str.startswith("@@"):
        return "bare"
    if is_wrapped_relation_type(f.type_str):
        if relation_wrapper_of(f.type_str) == "Optional":
            return "optional"
        return "wrapped"
    return "plain"


def _emit_from_json_field_parse(
    f: Field, tmp_prefix: String, plain_struct_fields: Dict[String, List[Field]]
) raises -> String:
    """The statement(s) `emit_table_json_methods`'s `from_json` runs once
    it's matched a JSON object key to field `f` -- assigns into
    `{tmp_prefix}{f.name}`, an `Optional[<field type>]` local declared
    before the parsing loop starts (see its own doc comment for why
    `Optional`, not the field type itself, is what gets declared). Relation
    lookups go through the already-in-scope `sqrrl__tbl_<Target>`
    parameter (see `_collect_relation_targets`/`_relation_target_params`)
    -- `from_json` takes one such parameter per distinct target its own
    fields need, rather than the whole `sqrrl__World`, specifically so
    it can stay a method on the struct's own table instead of moving to
    `sqrrl__World` (confirmed: `mut self: sqrrl__<Name>Table` plus
    disjoint sibling-table parameters doesn't alias, unlike `mut self`
    plus the whole `sqrrl__World` `self` is already part of).

    A `"plain"`-shaped field whose *own* type names a known plain struct
    (`home: Address`) can't go through the shared `sqrrl__from_json[T]`
    dispatcher either, for the same reason no struct ever can (see
    `emit_json_module`'s own doc comment) -- it's routed to
    `sqrrl__<Type>_from_json(...)` instead, a free function (a plain
    struct has no table of its own to be a method on), passed whichever
    subset of the enclosing `sqrrl__tbl_<Target>` parameters *that*
    struct's own fields need (always already in scope here, by
    construction -- see `_collect_relation_targets`). `sqrrl__`-*prefixed*,
    unlike an entity's own bare `from_json` method -- a plain struct's
    name isn't otherwise protected from colliding with an `@@struct`'s
    the way `sqrrl__<Name>TableState` already is."""
    var shape = _relation_field_shape(f)
    var var_name = tmp_prefix + f.name
    if shape == "bare":
        var target = String(f.type_str[byte=2 : f.type_str.byte_length()])
        return String(
            t"                    {var_name} ="
            t" sqrrl__tbl_{target}.table.handle_for(UInt32(sc.parse_json_int()))\n"
        )
    if shape == "multi" or shape == "wrapped":
        var target = String(f.type_str[byte=2 : f.type_str.byte_length()]) if shape == "multi" else relation_target_of(f.type_str)
        var wrapper = "Set" if shape == "multi" else relation_wrapper_of(f.type_str)
        var elem = String(t"EntityHandle[{sqrrl_prefixed(String(target))}TableState]")
        var out = String()
        out += String(t"                    var {var_name}_tmp = {wrapper}[{elem}]()\n")
        out += '                    sc.expect_byte(UInt8(ord("[")))\n'
        out += '                    if not sc.try_consume_byte(UInt8(ord("]"))):\n'
        out += "                        while True:\n"
        var add_call = "add" if wrapper == "Set" else "append"
        out += String(
            t"                            {var_name}_tmp.{add_call}(sqrrl__tbl_{target}.table.handle_for(UInt32(sc.parse_json_int())))\n"
        )
        out += '                            if sc.try_consume_byte(UInt8(ord(","))):\n'
        out += "                                continue\n"
        out += '                            sc.expect_byte(UInt8(ord("]")))\n'
        out += "                            break\n"
        out += String(t"                    {var_name} = {var_name}_tmp^\n")
        return out^
    if shape == "optional":
        var target = relation_target_of(f.type_str)
        var elem = String(t"EntityHandle[{sqrrl_prefixed(String(target))}TableState]")
        var out = String()
        out += '                    if sc.try_consume_literal("null"):\n'
        out += String(t"                        {var_name} = Optional[{elem}](None)\n")
        out += "                    else:\n"
        out += String(
            t"                        {var_name} ="
            t" Optional[{elem}](sqrrl__tbl_{target}.table.handle_for(UInt32(sc.parse_json_int())))\n"
        )
        return out^
    var field_type = emit_field_type(f)
    var base_name = _plain_struct_base_name(field_type)
    if base_name in plain_struct_fields:
        var nested_seen = Dict[String, Bool]()
        var nested_targets = List[String]()
        _collect_relation_targets(plain_struct_fields[base_name], plain_struct_fields, nested_seen, nested_targets)
        var nested_args = _relation_target_args(nested_targets)
        if nested_args.byte_length() > 0:
            nested_args += ", "
        if field_type != base_name:
            # A generic plain struct instantiation (`home: Box[String]`)
            # -- forward its own type argument(s), verbatim, as explicit
            # compile-time parameters to the companion, which declares
            # the matching `[T, ...]` list itself (see
            # `emit_plain_struct_from_json`). Only the *direct* field
            # type is handled this way -- a generic instantiation nested
            # inside a container (`List[Box[String]]`) is the one known
            # gap this doesn't cover, same as a non-generic plain struct
            # nested in a container never has either.
            var type_args = String(
                field_type[byte = base_name.byte_length() + 1 : field_type.byte_length() - 1]
            )
            return String(
                t"                    {var_name} ="
                t" sqrrl__{base_name}_from_json[{type_args}]({nested_args}sc)\n"
            )
        return String(t"                    {var_name} = sqrrl__{base_name}_from_json({nested_args}sc)\n")
    return String(t"                    {var_name} = sqrrl__from_json[{field_type}](sc)\n")


def _emit_from_json_parse_loop(
    parsed: ParsedStruct, plain_struct_fields: Dict[String, List[Field]]
) raises -> String:
    """The field-declaration/parsing-loop body shared by `from_json` and
    `sqrrl__from_json_with_id` (`emit_table_json_methods`) -- byte-for-byte
    identical between the two; only the method signature around it and the
    final construction call (`self.create(...)` vs
    `self.sqrrl__create_with_id(id, ...)`) differ."""
    var out = String()
    for f in parsed.fields:
        out += String(t"        var sqrrl__parsed_{f.name}: Optional[{emit_field_type(f)}] = None\n")
    out += '        sc.expect_byte(UInt8(ord("{")))\n'
    out += '        if not sc.try_consume_byte(UInt8(ord("}"))):\n'
    out += "            while True:\n"
    out += "                var sqrrl__key = sc.parse_json_string()\n"
    out += '                sc.expect_byte(UInt8(ord(":")))\n'
    var first_field = True
    for f in parsed.fields:
        var keyword = "if" if first_field else "elif"
        out += String(t'                {keyword} sqrrl__key == "{f.name}":\n')
        first_field = False
        out += _emit_from_json_field_parse(f, "sqrrl__parsed_", plain_struct_fields)
    out += '                if sc.try_consume_byte(UInt8(ord(","))):\n'
    out += "                    continue\n"
    out += '                sc.expect_byte(UInt8(ord("}")))\n'
    out += "                break\n"
    return out^


def emit_table_json_methods(
    parsed: ParsedStruct, state_name: String, plain_struct_fields: Dict[String, List[Field]]
) raises -> String:
    """Generates `to_json`/`from_json` for one `@@struct`'s own
    `sqrrl__<Name>Table` -- unlike a plain struct (fully handled by
    `sqrrl__to_json`'s own reflection-based fallback with zero code
    generated for it, see `emit_json_module`), an entity's fields live in
    per-field `Rel`-backed table storage, not a flat, reflectable value
    struct -- serializing *one row* means going through `get_<field>`,
    the same accessor every other generated method already uses, not
    reflecting the `sqrrl__<Name>TableState` struct itself (that would
    expose the table's *storage machinery* -- every field wrapped in a
    `Rel`/`UniqueRel`/... -- not the row's own logical values).

    Uniform across every field regardless of shape: a bare relation
    field's `get_<field>` already returns a live `EntityHandle[...]`, and
    `EntityHandle` conforms to `sqrrl__JsonSerializable` (serializing as
    its own bare id), so `sqrrl__to_json(self.get_<field>(e))` is correct
    whether the field is a leaf, a container, or a relation, wrapped or
    not.

    `from_json` is a method on `sqrrl__<Name>Table` itself (`self`,
    matching `to_json`/`create`/`get_*`/`set_*`) rather than on
    `sqrrl__World` -- reconstructing a relation field needs the
    *target's own table* (`sqrrl__tbl_<Target>.table.handle_for`, to turn
    a parsed id back into a live handle), and passing the *whole*
    `sqrrl__World` as a second parameter alongside `self` doesn't
    actually work: `self` (`sqrrl__world.<Name>`) would already be *part
    of* `sqrrl__world`, so passing `sqrrl__world` again as an argument
    aliases memory `self` already holds a `mut` reference into --
    confirmed, Mojo's own exclusivity checker rejects exactly this call
    shape ("argument ... allows writing a memory location previously
    writable through another aliased argument"). Passing only the
    *specific, disjoint* sibling tables a struct's own fields actually
    need (via `_collect_relation_targets`/`_relation_target_params`)
    sidesteps the conflict entirely: `self` and each `sqrrl__tbl_<Target>`
    are always different fields of `sqrrl__World`, never the whole
    aggregate. The call site (`@@Type.from_json(...)`) is rewritten to
    match (`sqrrl__world.Type.from_json(sqrrl__world.Target1, ...)`) --
    see `rewrite_markers`'s `is_entity_returning` handling.

    `_relation_field_shape`/`_emit_from_json_field_parse` inline
    bare/wrapped/`multi`/`Optional` relation parsing by hand per field
    (the shared `sqrrl__from_json[T]` dispatcher has no way to reach
    another table at all, regardless of this aliasing issue), falling
    back to `sqrrl__from_json[FieldType](sc)` for everything else. Every
    parsed field is collected into an `Optional[<field type>]` local (not
    the field type directly) purely so a field can be declared *before*
    the order-independent key-matching loop populates it, then unwrapped
    via `.take()` (aborts if a required key was missing from the JSON
    object -- same "trust the input" convention `Rel`/`OrderedRel`
    already use elsewhere) when building the final `self.create(...)`
    call, since JSON object keys have no guaranteed order to rely on
    instead."""
    var out = String()
    out += String(t"    def to_json(self, e: EntityHandle[{state_name}]) -> String:\n")
    out += '        var out = String("{")\n'
    var first = True
    for f in parsed.fields:
        if not first:
            out += '        out += ","\n'
        first = False
        out += String(
            t'        out += "\\"{f.name}\\":" + sqrrl__to_json(self.get_{f.name}(e))\n'
        )
    out += '        out += "}"\n'
    out += "        return out^\n"

    var targets = List[String]()
    var seen = Dict[String, Bool]()
    _collect_relation_targets(parsed.fields, plain_struct_fields, seen, targets)

    out += "\n"
    out += String(t"    def from_json(mut self{_relation_target_params(targets)}, mut sc: sqrrl__JsonScanner) raises ->")
    out += String(t" EntityHandle[{state_name}]:\n")
    out += _emit_from_json_parse_loop(parsed, plain_struct_fields)
    out += String(t"        return self.create(")
    var first_arg = True
    for f in parsed.fields:
        if not first_arg:
            out += ", "
        first_arg = False
        out += String(t"sqrrl__parsed_{f.name}.take()")
    out += ")\n"

    # `sqrrl__from_json_with_id` -- `from_json`'s twin, used only by
    # `sqrrl__world_from_json` (`emit_world_module`) to reconstruct a whole
    # `sqrrl__World` from a JSON dump: an entity has to land back on its
    # exact original id (embedded alongside its own JSON blob at the world
    # level, unlike a lone struct's own `to_json`/`from_json`, which never
    # need an entity's own id -- only what it *references* is ever a bare
    # id) for any other entity's relation field pointing at it to resolve
    # correctly, hence `self.sqrrl__create_with_id(sqrrl__id, ...)` in place
    # of `self.create(...)`.
    out += "\n"
    out += String(
        t"    def sqrrl__from_json_with_id(mut self{_relation_target_params(targets)}, sqrrl__id:"
        t" UInt32, mut sc: sqrrl__JsonScanner) raises ->"
    )
    out += String(t" EntityHandle[{state_name}]:\n")
    out += _emit_from_json_parse_loop(parsed, plain_struct_fields)
    out += String(t"        return self.sqrrl__create_with_id(sqrrl__id")
    for f in parsed.fields:
        out += String(t", sqrrl__parsed_{f.name}.take()")
    out += ")\n"

    # `all_to_json`/`all_from_json` -- the whole-table counterpart to a
    # single entity's own `to_json`/`from_json`, used only by
    # `sqrrl__World.to_json`/`sqrrl__world_from_json` (`emit_world_module`)
    # so the per-table "array of [id, entity json] pairs" shape (and its
    # parsing) is written once here rather than re-spelled inline once per
    # struct at the world level. `all_to_json` needs no sibling-table
    # params (a single entity's own `to_json` never does either); returns
    # just the bracketed array, not `"Name":[...]` -- the key itself is
    # the one thing only the world level knows to attach. `all_from_json`
    # is the exact reverse: parses that same array, reconstructing each
    # entity via `sqrrl__from_json_with_id` (landing it back on its
    # original id) and retaining it immediately in `self.keepalive` (see
    # `emit_table`'s own doc comment) unless `is_keepalive` already does
    # that automatically inside `sqrrl__create_with_id`.
    out += "\n"
    out += "    def all_to_json(self) -> String:\n"
    out += '        var out = String("[")\n'
    out += "        var sqrrl__first = True\n"
    out += "        for sqrrl__e in self.all():\n"
    out += "            if not sqrrl__first:\n"
    out += '                out += ","\n'
    out += "            sqrrl__first = False\n"
    out += (
        '            out += "[" + String(sqrrl__e.id()) + "," + self.to_json(sqrrl__e) + "]"\n'
    )
    out += '        out += "]"\n'
    out += "        return out^\n"

    out += "\n"
    out += String(
        t"    def all_from_json(mut self{_relation_target_params(targets)}, mut sc:"
        t" sqrrl__JsonScanner) raises:\n"
    )
    out += '        sc.expect_byte(UInt8(ord("[")))\n'
    out += '        if not sc.try_consume_byte(UInt8(ord("]"))):\n'
    out += "            while True:\n"
    out += '                sc.expect_byte(UInt8(ord("[")))\n'
    out += "                var sqrrl__id = UInt32(sc.parse_json_int())\n"
    out += '                sc.expect_byte(UInt8(ord(",")))\n'
    var target_args = _relation_target_args(targets)
    if target_args.byte_length() > 0:
        target_args += ", "
    if parsed.is_keepalive:
        out += String(
            t"                _ = self.sqrrl__from_json_with_id({target_args}sqrrl__id, sc)\n"
        )
    else:
        out += String(
            t"                var sqrrl__e ="
            t" self.sqrrl__from_json_with_id({target_args}sqrrl__id, sc)\n"
        )
        out += "                self.keepalive.add(sqrrl__e^)\n"
    out += '                sc.expect_byte(UInt8(ord("]")))\n'
    out += '                if sc.try_consume_byte(UInt8(ord(","))):\n'
    out += "                    continue\n"
    out += '                sc.expect_byte(UInt8(ord("]")))\n'
    out += "                break\n"
    return out^


def emit_plain_struct_from_json(
    parsed: ParsedStruct, plain_struct_fields: Dict[String, List[Field]]
) raises -> String:
    """Generates `sqrrl__{Name}_from_json`, a plain struct's own
    reconstruction companion (shorthand or hand-written -- `parsed.fields`
    already carries either shape uniformly by the time this runs, see
    `driver.build_plain_struct_fields`) -- `sqrrl__to_json` already
    handles *serializing* any plain struct automatically via reflection
    (see `emit_json_module`'s own doc comment), so this is only needed for
    the opposite direction, same reasoning `emit_table_json_methods`
    documents for `@@struct`s: writing into a reflected field requires
    `Ti` to prove `Movable`/`ImplicitlyDeletable` as an explicit type
    argument, which never works, so the field list has to be known and
    spelled out literally by the generator instead. Generated into
    `sqrrl__json.mojo` (`driver.build_json_module_source`), alongside the
    rest of JSON serialization's generated code, not `sqrrl__world.mojo`
    -- nothing about it needs anything `sqrrl__World` itself provides.

    A free function (a plain struct has no table of its own to be a
    method on), taking one `sqrrl__tbl_<Target>` parameter per distinct
    relation target its *own* fields need, for the same reason an
    entity's own `from_json` does: a plain struct can embed a relation
    field of its own (`Note { @@author: @@Employee, ... }`, see the
    README's "Plain structs" section), which needs
    `sqrrl__tbl_<Target>.table.handle_for` to reconstruct.
    `sqrrl__`-prefixed (unlike the entity case) so it can never collide
    with an `@@struct`'s own `from_json` even if a project somehow
    declares both with the identical name -- see
    `_emit_from_json_field_parse`'s own doc comment.

    A *generic* plain struct (`parsed.type_params` non-empty) gets its own
    `[T: Bound, ...]` list spliced in between the function name and its
    value-parameter list (`_emit_type_param_list`), and its return type
    becomes the concrete instantiation `{Name}[T, ...]`
    (`_emit_type_arg_list`) rather than the bare name -- a field typed
    `T` then just falls through `_emit_from_json_field_parse`'s ordinary
    `sqrrl__from_json[T](sc)` fallback, `T` already being in scope as one
    of this function's own type parameters, no different from any other
    concrete field type. The final constructor call is instantiated
    explicitly (`{Name}[T, ...](...)`, not the bare name) rather than
    relying on Mojo to infer it from the field arguments' own types --
    cheap to spell out, and removes any doubt about whether inference
    would actually land on the right instantiation."""
    var targets = List[String]()
    var seen = Dict[String, Bool]()
    _collect_relation_targets(parsed.fields, plain_struct_fields, seen, targets)
    var params = _relation_target_params(targets)
    # `_relation_target_params` is built for `def from_json(mut self, ...)`
    # (leading `, `) -- here there's no `mut self` to lead with, so the
    # first parameter (if any) needs its leading ", " trimmed to " ".
    if params.byte_length() > 0:
        params = String(params[byte=2 : params.byte_length()])

    var out = String()
    out += String(
        t"def sqrrl__{parsed.name}_from_json{_emit_type_param_list(parsed.type_params)}({params}"
    )
    if params.byte_length() > 0:
        out += ", "
    out += String(t"mut sc: sqrrl__JsonScanner) raises ->")
    out += String(t" {parsed.name}{_emit_type_arg_list(parsed.type_params)}:\n")
    for f in parsed.fields:
        out += String(t"    var sqrrl__parsed_{f.name}: Optional[{emit_field_type(f)}] = None\n")
    out += '    sc.expect_byte(UInt8(ord("{")))\n'
    out += '    if not sc.try_consume_byte(UInt8(ord("}"))):\n'
    out += "        while True:\n"
    out += "            var sqrrl__key = sc.parse_json_string()\n"
    out += '            sc.expect_byte(UInt8(ord(":")))\n'
    var first_field = True
    for f in parsed.fields:
        var keyword = "if" if first_field else "elif"
        out += String(t'            {keyword} sqrrl__key == "{f.name}":\n')
        first_field = False
        out += _emit_from_json_field_parse(f, "sqrrl__parsed_", plain_struct_fields)
    out += '            if sc.try_consume_byte(UInt8(ord(","))):\n'
    out += "                continue\n"
    out += '            sc.expect_byte(UInt8(ord("}")))\n'
    out += "            break\n"
    out += String(t"    return {parsed.name}{_emit_type_arg_list(parsed.type_params)}(")
    var first_arg = True
    for f in parsed.fields:
        if not first_arg:
            out += ", "
        first_arg = False
        out += String(t"sqrrl__parsed_{f.name}.take()")
    out += ")\n"
    return out^


def _emit_type_param_list(type_params: List[TypeParam]) -> String:
    """`[T: Bound, U: Bound2]`, or `""` if `type_params` is empty -- the
    generic-parameter suffix on a plain struct's own generated header
    (`emit_plain_struct`) and its `from_json` companion's own type-param
    list (`emit_plain_struct_from_json`), both immediately after the
    struct/function name, before the parenthesized trait list or value
    parameter list respectively."""
    if len(type_params) == 0:
        return ""
    var out = String("[")
    var first = True
    for tp in type_params:
        if not first:
            out += ", "
        first = False
        out += String(t"{tp.name}: {tp.bound}")
    out += "]"
    return out^


def _emit_type_arg_list(type_params: List[TypeParam]) -> String:
    """`[T, U]`, or `""` if `type_params` is empty -- the bare parameter
    *names* (no bounds), used wherever a generic plain struct's own
    declared parameters need to be supplied as concrete type arguments to
    itself (its `from_json` companion's own `-> Name[T, U]:` return type)
    rather than redeclared with their bounds."""
    if len(type_params) == 0:
        return ""
    var out = String("[")
    var first = True
    for tp in type_params:
        if not first:
            out += ", "
        first = False
        out += tp.name
    out += "]"
    return out^


def qualify_type_params_with_self(type_str: String, type_params: List[TypeParam]) -> String:
    """Replaces every whole-word occurrence of one of `type_params`'s own
    names within `type_str` with `Self.<name>` -- Mojo requires a generic
    struct's own fields/methods to refer to its own type parameter this
    way (confirmed: `var value: T` inside `struct Box[T]:`'s own body
    raises "unqualified access to struct parameter 'T'; use 'Self.T'
    instead", even nested inside a container like `List[T]`), unlike a
    *free function's* own type parameter, which stays bare
    (`emit_plain_struct_from_json`'s generated `from_json` companion is
    always a free function, never a method, so it never needs this --
    confirmed the reverse case, a free function referencing its own type
    parameter bare, compiles and runs correctly with no qualification at
    all). No-op (and skipped entirely) when `type_params` is empty, the
    overwhelmingly common, non-generic case. Whole-word matched (not a
    bare substring check) so a field genuinely named e.g. `Type` isn't
    mistaken for a one-letter parameter `T`."""
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
            var word = String(type_str[byte=start:i])
            var matched = False
            for tp in type_params:
                if tp.name == word:
                    matched = True
                    break
            out += String(t"Self.{word}") if matched else word
        else:
            out += String(type_str[byte = i : i + 1])
            i += 1
    return out^


def split_top_level_type_args(s: String) -> List[String]:
    """Splits `s` (the text between a generic instantiation's own outer
    `[`/`]`, e.g. `"String, Int"` from `Pair[String, Int]`) on every
    top-level `,` -- ignoring one nested inside further brackets
    (`Dict[String, Int]` as a single argument mustn't split on its own
    inner comma), trimming whitespace from each piece. Used to pair a
    generic plain struct's own concrete type arguments positionally
    against its declared type parameters (`substitute_type_params`,
    `driver.build_json_container_types`)."""
    var out = List[String]()
    var depth = 0
    var start = 0
    var bytes = s.as_bytes()
    var n = len(bytes)
    for i in range(n):
        var b = bytes[i]
        if b == UInt8(ord("[")) or b == UInt8(ord("(")) or b == UInt8(ord("{")):
            depth += 1
        elif b == UInt8(ord("]")) or b == UInt8(ord(")")) or b == UInt8(ord("}")):
            depth -= 1
        elif b == UInt8(ord(",")) and depth == 0:
            out.append(String(String(s[byte = start : i]).strip()))
            start = i + 1
    out.append(String(String(s[byte = start : n]).strip()))
    return out^


def substitute_type_params(type_str: String, type_params: List[TypeParam], type_args: List[String]) -> String:
    """Replaces every whole-word occurrence of one of `type_params`'s own
    names within `type_str` with the correspondingly-positioned entry in
    `type_args` -- e.g. substituting `T -> String` turns `List[T]` into
    `List[String]`. Needed to compute what a generic plain struct's own
    field types look like once instantiated at a concrete type argument,
    so whatever concrete container types they need (`List[String]`, ...)
    can be registered project-wide the same as any other field's
    (`driver.build_json_container_types`) -- nothing else would ever
    discover that `Example[String]` (used as some *other* struct's field
    type) needs `List[String]` registered, since `Example`'s own
    declared field is still abstract (`liste: List[T]`) until an actual
    instantiation substitutes a concrete argument in. No-op when
    `type_params` is empty. Falls back to leaving a parameter's own name
    bare if `type_args` doesn't have a correspondingly-positioned entry
    (a malformed instantiation with too few type arguments) -- this
    function's job is to emit useful Mojo, not validate arity; a
    genuinely wrong arity surfaces as an ordinary Mojo compile error
    downstream instead."""
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
            var replacement = word
            for idx in range(len(type_params)):
                if type_params[idx].name == word:
                    if idx < len(type_args):
                        replacement = type_args[idx]
                    break
            out += replacement
        else:
            out += String(type_str[byte = i : i + 1])
            i += 1
    return out^


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
    `Copyable, Movable, ImplicitlyDeletable` -- not `ImplicitlyCopyable`,
    and not `Hashable, Equatable` either -- so it works as a
    `forwardonly`, `Rel`-backed field's plain value on the default path
    without guessing at hash/eq for arbitrary field types that might not
    support it; a `.rel` author whose own field types aren't `Hashable`
    adds `forwardonly` on the *containing* field instead, the same
    escape hatch used for any other non-`KeyElement` field type (and the
    only shape a plain-struct-typed field is ever actually declared with
    in practice, since a plain struct never derives `Hashable`/`Equatable`
    itself) -- `ForwardOnlyRel[T: ImplicitlyDeletable & Copyable]` only
    ever needs `Copyable`, confirmed. `ImplicitlyCopyable` specifically
    would reject a field type that's merely `Copyable` (needs an explicit
    `.copy()`, not an implicit one) but not `ImplicitlyCopyable` --
    `List`/`Set`/`Dict` all fall in exactly that gap, confirmed rejecting
    a struct with a bare `List[String]` field outright ("cannot
    synthesize implicit copy constructor") until this was `Copyable`
    instead. A generic plain struct (`type_params` non-empty) gets its
    own `[T: Bound, ...]` list spliced in right after the name, same
    position real Mojo puts it -- see `_emit_type_param_list`."""
    var out = String(
        t"struct {parsed.name}{_emit_type_param_list(parsed.type_params)}(Copyable, Movable,"
        t" ImplicitlyDeletable):\n"
    )
    for f in parsed.fields:
        out += String(
            t"    var {f.name}: {qualify_type_params_with_self(emit_field_type(f), parsed.type_params)}\n"
        )
    out += "\n"
    out += "    def __init__(out self"
    for f in parsed.fields:
        out += String(
            t", var {f.name}: {qualify_type_params_with_self(emit_field_type(f), parsed.type_params)}"
        )
    out += "):\n"
    if len(parsed.fields) == 0:
        out += "        pass\n"
    for f in parsed.fields:
        out += String(t"        self.{f.name} = {f.name}^\n")
    return out


def _is_entity_handle_type(t: String) -> Bool:
    """True if `t` (a rewritten field type, from `emit_field_type`) is
    `EntityHandle[...]` itself -- distinguishes a *relation* container
    element (`List[@@Employee]` -> `List[EntityHandle[...]]`) from a
    *plain* one (`List[String]`) for `emit_json_module`'s purposes: the
    former can't be reconstructed by the shared `sqrrl__from_json[T]`
    dispatcher at all (an `EntityHandle` needs its *target's own table* to
    look an id back up into a live handle, which a bare `mut sc:
    sqrrl__JsonScanner` parameter has no way to reach) -- those fields get
    bespoke, per-struct-generated parsing instead (see `emit_table`'s
    `to_json`/`from_json` methods), never routed through this shared
    module."""
    return t.startswith("EntityHandle[")


def _recover_struct_name(state_name: String) -> String:
    """`sqrrl__EmployeeTableState` -> `Employee` -- the exact inverse of
    `sqrrl_prefixed(name) + "TableState"` (see `emit_table`). Needed by
    `recover_relation_type_str` to recover the original `@@struct` name
    from a hand-written plain struct's already-converted `EntityHandle[...]`
    field type, since that struct's own fields were never `@@`-marked
    shorthand to begin with -- there's no other record of which struct
    `sqrrl__EmployeeTableState` came from once it's already spelled out by
    hand. Returns `state_name` unchanged if it doesn't actually have both
    the prefix and suffix -- conservatively leaves an unrecognized shape
    alone rather than mangling it (see `recover_relation_type_str`)."""
    var prefix = "sqrrl__"
    var suffix = "TableState"
    if not state_name.startswith(prefix) or not state_name.endswith(suffix):
        return state_name
    return String(
        state_name[byte = prefix.byte_length() : state_name.byte_length() - suffix.byte_length()]
    )


def recover_relation_type_str(t: String) -> String:
    """Reverses `_rewrite_type_str` for a hand-written plain struct's own
    field type -- `EntityHandle[sqrrl__EmployeeTableState]` back to the
    pseudo `@@Employee` shorthand, and the collection-wrapped forms
    (`List[EntityHandle[...]]`/`Set[...]`/`Optional[...]`) back to
    `List[@@Employee]`/... -- so a hand-written struct's own relation
    field can flow through exactly the same `_relation_field_shape`/
    `_collect_relation_targets`/`_emit_from_json_field_parse` machinery a
    shorthand plain struct's or `@@struct`'s own relation field already
    does, with no separate code path to maintain for it. Passed through
    unchanged for anything else (a leaf, a plain container, a nested
    plain-struct reference) -- exactly the shapes `_rewrite_type_str`
    itself leaves alone, so `emit_field_type`'s own round trip through
    this and back is exact either way."""
    if _is_entity_handle_type(t):
        var inner = String(t[byte = String("EntityHandle[").byte_length() : t.byte_length() - 1])
        var recovered = _recover_struct_name(inner)
        if recovered != inner:
            return "@@" + recovered
        return t
    if is_container_type(t):
        var wrapper = container_wrapper_of(t)
        var elem = container_element_of(t)
        if _is_entity_handle_type(elem):
            var inner = String(
                elem[byte = String("EntityHandle[").byte_length() : elem.byte_length() - 1]
            )
            var recovered = _recover_struct_name(inner)
            if recovered != inner:
                return String(t"{wrapper}[@@{recovered}]")
    return t


def emit_json_module(container_types: List[String]) -> String:
    """Emits the body of `sqrrl__json.mojo` -- the two shared, fully
    generic (de)serialization entry points every generated `to_json`/
    `from_json` (per `@@struct`, per shorthand plain struct) calls into:
    `sqrrl__to_json[T](value: T) -> String` and `sqrrl__from_json[T](mut
    sc: sqrrl__JsonScanner) raises -> T`. Its own header (imports) is
    assembled by the caller (`build_json_module_source` in `driver.mojo`),
    which alone knows which module declared each `@@struct` referenced
    here as an `EntityHandle[...]`.

    This dispatch table can't be a static file copied verbatim into every
    project the way the rest of `squirrel_runtime` is (`copy_runtime`): a
    container-typed field (`List[String]`, `Set[UInt32]`, ...) needs its
    own `elif T == List[String]:` branch naming its *element* type
    literally, because there's no way to ask Mojo's own type system "is
    `T` a `List` of *anything*" generically (confirmed: comparing a bare,
    unparameterized `List` against `T` crashes the compiler outright, and
    `List[Int].ElementType`/`.Element`/`.T` don't exist) -- so exactly
    which branches exist has to vary per project, based on
    `container_types` (every distinct `Wrapper[Element]` field type
    `build_json_container_types` found anywhere in the schema), the same
    way `sqrrl__world.mojo` itself is already generated per project
    rather than copied. `container_types` already carries the fully
    rewritten Mojo type text (`emit_field_type`'s own output), including
    relation containers (`List[EntityHandle[...]]`) -- those still need a
    `to_json` branch here (serializing one is uniform: recurse into each
    element, and `EntityHandle` knows how to serialize itself via
    `sqrrl__JsonSerializable`), but never a `from_json` one
    (`_is_entity_handle_type` filters them back out on that side) --
    reconstructing one needs the target's own table, which only the
    owning struct's own generated `from_json` has access to.

    `sqrrl__to_json`'s own struct fallback (the final `else`) is what
    makes *every* plain struct -- `@@struct`-declared or not, however
    deeply nested -- serialize with zero code generated for it at all:
    `reflect[T]` walks its fields generically (`field_names`/
    `field_types`/`field_offset`), recursing back into `sqrrl__to_json`
    for each one via ordinary argument-inferred function calls -- the one
    shape of recursion through a reflected field that actually survives
    Mojo's own type-checking (confirmed: an explicit type argument or
    return-type inference through a reflected field type fails
    unconditionally, regardless of bound). `sqrrl__from_json` has no such
    fallback -- writing into a reflected field requires `Ti` (from
    `reflect[T].field_types()`) to prove `Movable`/`ImplicitlyDeletable`
    as an explicit type argument, which is exactly the shape that never
    works -- so every struct's own `from_json` is generated with each
    field's type spelled out as a literal instead (see `emit_table`'s
    `to_json`/`from_json` methods and `emit_plain_struct_from_json`).

    Unlike the dispatch table, the container helpers this dispatches to
    (`list_to_json`/`list_from_json`/`set_to_json`/`set_from_json`/
    `optional_to_json`/`optional_from_json`/`dict_to_json`/
    `dict_from_json`) are already fully generic over their element
    type(s) -- they don't need `container_types` at all, so they live as
    static code in `squirrel_runtime/json.mojo` instead of being
    generated here (see that file for why the resulting two-way
    dependency, a runtime file importing from a generated one, is safe)."""
    var out = String()
    out += "def sqrrl__to_json[T: AnyType](value: T) -> String:\n"
    out += "    comptime if T == String:\n"
    out += "        return sqrrl__escape_json_string(rebind[String](value))\n"
    for leaf in ["Int", "UInt32", "Int64", "UInt64", "Float64"]:
        out += String(t"    elif T == {leaf}:\n")
        out += String(t"        return String(rebind[{leaf}](value))\n")
    out += "    elif T == Bool:\n"
    out += '        return "true" if rebind[Bool](value) else "false"\n'
    for ct in container_types:
        var wrapper = container_wrapper_of(ct)
        out += String(t"    elif T == {ct}:\n")
        out += String(t"        return {wrapper.lower()}_to_json(rebind[{ct}](value).copy())\n")
    out += "    elif conforms_to(T, sqrrl__JsonSerializable):\n"
    out += "        return value.sqrrl__to_json()\n"
    out += "    else:\n"
    out += "        comptime r = reflect[T]\n"
    out += "        comptime names = r.field_names()\n"
    out += "        comptime ts = r.field_types()\n"
    out += "        var p = UnsafePointer(to=value).bitcast[UInt8]()\n"
    out += '        var out = String("{")\n'
    out += "        comptime for i in range(r.field_count()):\n"
    out += "            comptime Ti = ts[i]\n"
    out += "            comptime off = r.field_offset[index=i]()\n"
    out += "            var field_ptr = (p + off).bitcast[Ti]()\n"
    out += "            if i > 0:\n"
    out += '                out += ","\n'
    out += (
        '            out += "\\"" + String(names[i]) + "\\":" + sqrrl__to_json(field_ptr[])\n'
    )
    out += '        out += "}"\n'
    out += "        return out^\n"
    out += "\n\n"

    out += (
        "def sqrrl__from_json[T: Copyable & ImplicitlyDeletable](mut sc: sqrrl__JsonScanner)"
        " raises -> T:\n"
    )
    out += "    comptime if T == String:\n"
    out += "        var v = sc.parse_json_string()\n"
    out += "        return rebind[T](v^).copy()\n"
    out += "    elif T == Int:\n"
    out += "        var v = sc.parse_json_int()\n"
    out += "        return rebind[T](v).copy()\n"
    for leaf in ["UInt32", "Int64", "UInt64"]:
        out += String(t"    elif T == {leaf}:\n")
        out += String(t"        var v = {leaf}(sc.parse_json_int())\n")
        out += "        return rebind[T](v).copy()\n"
    out += "    elif T == Float64:\n"
    out += "        var v = sc.parse_json_float()\n"
    out += "        return rebind[T](v).copy()\n"
    out += "    elif T == Bool:\n"
    out += "        var v = sc.parse_json_bool()\n"
    out += "        return rebind[T](v).copy()\n"
    for ct in container_types:
        var wrapper = container_wrapper_of(ct)
        var element = container_element_of(ct)
        if _is_entity_handle_type(element):
            continue
        out += String(t"    elif T == {ct}:\n")
        out += String(
            t"        return rebind[T]({wrapper.lower()}_from_json[{element}](sc)).copy()\n"
        )
    out += "    else:\n"
    out += (
        '        raise Error("sqrrl__from_json: unsupported type -- structs use their own'
        ' generated from_json")\n'
    )
    return out^


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
    plain_struct_fields: Dict[String, List[Field]],
    relation_targets: Dict[String, List[String]],
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
            plain_struct_fields,
            relation_targets,
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
    plain_struct_fields: Dict[String, List[Field]],
    relation_targets: Dict[String, List[String]],
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
    project-wide `sqrrl__World` (see `driver.emit_world_module`) --
    there's no per-file, per-type table variable anymore. A script obtains
    it explicitly, once per function that needs it, one of three ways:
    `@@init()` becomes `var sqrrl__world = sqrrl__init()`,
    `@@init_from_json(json)` becomes `var sqrrl__scanner =
    sqrrl__JsonScanner(json); var sqrrl__world =
    sqrrl__world_from_json(sqrrl__scanner)` (reload instead of a fresh,
    empty world -- `json`'s own text is spliced in verbatim, unparsed,
    same as any other construct's field value; the scanner needs its own
    `var` first since `sqrrl__world_from_json` takes it `mut`, and a
    temporary can't bind to that directly), or a function whose own name
    is marked (`@@name(`, `MarkerKind.WORLD_FUNC`) gets
    `sqrrl__world` auto-inserted as its first parameter (a definition) or
    first argument (a call site), silently -- `def @@make_department(a:
    Int)` becomes `def sqrrl__make_department(mut sqrrl__world:
    sqrrl__World, a: Int)`, and `@@make_department(x)` becomes
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
            out += emit_table(parsed, plain_struct_fields)
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

        elif kind == MarkerKind.INIT_FROM_JSON:
            var json_expr = sc.parse_init_from_json()
            # `sqrrl__world_from_json` takes `mut sc: sqrrl__JsonScanner`
            # -- a temporary `sqrrl__JsonScanner(...)` can't bind to a
            # mutable parameter directly, so it needs its own `var` first,
            # same as any hand-written call site would.
            out += String(
                t"var sqrrl__scanner = sqrrl__JsonScanner({json_expr}); var sqrrl__world ="
                t" sqrrl__world_from_json(sqrrl__scanner)"
            )
            world_available = True
            pending_decl = None
            pending_for_loop_decl = None

        elif kind == MarkerKind.WORLD_FUNC:
            var func_name = sc.parse_world_func()
            sc.skip_whitespace()
            var has_more_args = sc.peek() != UInt8(ord(")"))
            if is_in_def_signature(source, marker_start):
                out += String(
                    t"{sqrrl_prefixed(func_name)}(mut sqrrl__world: sqrrl__World"
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
                plain_struct_fields,
                relation_targets,
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
                    plain_struct_fields,
                    relation_targets,
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
                # `create`, `from_json` (see `emit_table_json_methods`), and
                # a `unique` field's own `for_<field>` return a single
                # EntityHandle of *this* type; `get_<field>` for a
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
                var is_entity_returning = fa.field == "create" or fa.field == "from_json"
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
                if fa.field == "from_json":
                    # A table method like any other (`emit_table_json_methods`),
                    # but one needing sibling tables beyond `self` to
                    # reconstruct its own relation fields -- injected here
                    # as leading arguments, same technique the
                    # `add_to_<field>`/... instance-call branch below uses
                    # to inject `expr` as a first argument: `parse_field_access`
                    # left the call's own `(args)` unconsumed, so the
                    # opening `(` is consumed here to splice extra
                    # arguments in before whatever follows (just `sc`, in
                    # practice).
                    if not sc.try_consume("("):
                        raise sc.err("InvalidSquirrelSyntax: expected '(' after 'from_json'")
                    sc.skip_whitespace()
                    var has_more_args = sc.peek() != UInt8(ord(")"))
                    var targets = relation_targets[fa.entity].copy() if fa.entity in relation_targets else List[String]()
                    var injected = String()
                    for t in targets:
                        if injected.byte_length() > 0:
                            injected += ", "
                        injected += String(t"sqrrl__world.{t}")
                    out += String(t"sqrrl__world.{fa.entity}.from_json({injected}")
                    if injected.byte_length() > 0 and has_more_args:
                        out += ", "
                else:
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
                            plain_struct_fields,
                            relation_targets,
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
    plain_struct_fields: Dict[String, List[Field]],
    relation_targets: Dict[String, List[String]],
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
        source,
        relation_schema,
        function_returns,
        unique_fields,
        ordered_fields,
        plain_struct_fields,
        relation_targets,
        entity_to_type,
        world_available,
    )
