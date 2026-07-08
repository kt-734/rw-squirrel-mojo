from squirrel_compiler.parser import ParsedStruct, Field, TypeParam
from squirrel_compiler.codegen.helpers import (
    emit_field_type,
    is_container_type,
    container_wrapper_of,
    container_element_of,
    sqrrl_prefixed,
    _rewrite_type_str,
)
from squirrel_compiler.codegen.generics import _emit_type_param_list, qualify_type_params_with_self


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


