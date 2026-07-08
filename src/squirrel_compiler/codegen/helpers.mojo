from squirrel_compiler.parser import (
    ParsedStruct,
    Field,
    TypeParam,
    FieldModifier,
    Scanner,
    MarkerKind,
    ConstructField,
    is_ident_char,
    is_unmarked_container_declaration,
    source_location,
    parse_type_expr,
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
    outer `List[...]` wrapped around it.

    Parses `type_str` once and reads both the "is this a relation"
    question and the name(s) it needs off the same `TypeExpr`, rather
    than calling `is_wrapped_relation_type`/`relation_wrapper_of`/
    `relation_target_of` in sequence -- each of those parses `type_str`
    itself now (see their own doc comments), so chaining three of them
    over the same string would parse it three times over for no reason."""
    var t = parse_type_expr(type_str)
    if t.is_relation():
        return String(t"EntityHandle[{sqrrl_prefixed(t.name)}TableState]")
    if t.is_parameterized() and t.arg_count() >= 1 and t.arg(0).is_relation():
        return String(t"{t.name}[EntityHandle[{sqrrl_prefixed(t.arg(0).name)}TableState]]")
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
    return parse_type_expr(t).is_parameterized()


def container_wrapper_of(t: String) -> String:
    """`"List[Person]"` -> `"List"`. Requires `is_container_type(t)`."""
    return parse_type_expr(t).name


def container_element_of(t: String) -> String:
    """`"List[Person]"` -> `"Person"`; `"Dict[String, UInt32]"` ->
    `"String, UInt32"` -- everything between the outermost `[`/`]`,
    comma-joined back together if there's more than one (`emit_json_module`
    splices this straight into a generic argument list,
    `{wrapper.lower()}_from_json[{element}]`, so a `Dict`'s own two type
    arguments both need to come back out, not just the first -- unlike
    `entity_to_type`'s own single-argument encoding elsewhere, which
    happens to still round-trip correctly through the same join since it
    only ever has the one). Requires `is_container_type(t)`."""
    var parsed = parse_type_expr(t)
    var out = String()
    for i in range(parsed.arg_count()):
        if i > 0:
            out += ", "
        out += parsed.arg(i).render()
    return out^


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


