from squirrel_compiler.parser import Field, TypeParam, ParsedStruct, TypeExpr, parse_type_expr
from squirrel_compiler.driver.discovery import DiscoveryResult, DiscoveredStruct
from squirrel_compiler.codegen import (
    relation_targets_for,
    substitute_type_params_expr,
    emit_field_type,
    qualify_type_params_with_self,
    sqrrl_prefixed,
    emit_json_module,
    emit_plain_struct_from_json,
)


def build_relation_targets(
    discovery: DiscoveryResult, plain_struct_fields: Dict[String, List[Field]]
) raises -> Dict[String, List[String]]:
    """`@@struct` name -> the distinct target struct names its own
    `sqrrl__from_json` needs a live table for, direct or transitive
    through an embedded plain struct's own relation field
    (`relation_targets_for` in `codegen.mojo`) -- what
    `sqrrl__world_from_json` (`driver.emit_world_module`) needs to inject
    the right `sqrrl__world.Target` arguments into each struct's own
    `sqrrl__all_from_json` call, without re-deriving them from raw field
    lists there."""
    var out = Dict[String, List[String]]()
    for ds in discovery.structs:
        out[ds.parsed.name] = relation_targets_for(ds.parsed.fields, plain_struct_fields)
    return out^


def _register_plain_struct_dispatch(
    t: TypeExpr,
    plain_struct_fields: Dict[String, List[Field]],
    mut dispatch_seen: Dict[String, Bool],
    mut dispatch_out: List[String],
) raises:
    """Registers `t` (`t.name in plain_struct_fields` -- a plain struct's
    own bare name, or a generic instantiation of one) as needing a
    `sqrrl__from_json[T]` dispatch branch of its own, routing to its
    `sqrrl__<Name>_from_json` companion (`emit_json_module`) -- unless it
    embeds a relation field, which that shared dispatcher (one fixed
    `(mut sc: sqrrl__JsonScanner) raises -> T` signature, the same for
    every type it handles) has no way to supply a sibling table for, the
    way a struct's own directly-declared `from_json` can
    (`_relation_target_params`). Raising here instead of silently
    generating code that would fail downstream (`sqrrl__tbl_<Target>`
    simply wouldn't exist in `sqrrl__from_json[T]`'s own, fixed parameter
    list) -- see `_register_needed`'s own doc comment for exactly when a
    plain struct reaches this at all (never for one used as some struct's
    own *directly* declared field, only through a container or a generic
    plain struct's own bare type parameter)."""
    var rendered = t.render()
    if rendered in dispatch_seen:
        return
    var own_targets = relation_targets_for(plain_struct_fields[t.name], plain_struct_fields)
    if len(own_targets) > 0:
        raise Error(
            "InvalidSquirrelSyntax: '"
            + t.name
            + "' embeds a relation field, so it can't be reconstructed from inside a"
            " List/Set/Optional/Dict field, or as a generic plain struct's own bare"
            " type-parameter field -- only usable as some struct's own directly"
            " (literally) declared field type"
        )
    dispatch_seen[rendered] = True
    dispatch_out.append(rendered)


def _register_needed(
    t: TypeExpr,
    plain_struct_fields: Dict[String, List[Field]],
    plain_struct_type_params: Dict[String, List[TypeParam]],
    mut seen: Dict[String, Bool],
    mut out: List[String],
    mut dispatch_seen: Dict[String, Bool],
    mut dispatch_out: List[String],
) raises:
    """`t` is a position that genuinely needs a `sqrrl__from_json[T]`
    dispatch branch if it resolves to a plain-struct type (bare or a
    generic instantiation) -- a real container's own argument
    (`list_from_json[X]`/`dict_from_json[K, V]`/... all recurse via
    `sqrrl__from_json[X]` generically, with no way to special-case `X`
    even if it happens to be some struct's own literal field type
    elsewhere), or a generic plain struct's own field whose declared type
    is a *bare* reference to one of its own type parameters (`value: T`
    -- `T` is never itself a known struct name, so that field's generated
    code always falls through to the shared dispatcher too, regardless of
    what it's instantiated to -- see `emit_plain_struct_from_json`'s own
    doc comment). Registers `t` if it's a plain struct
    (`_register_plain_struct_dispatch`), then recurses into its own
    fields either way (`_visit_plain_struct_own_fields`); or, if `t` is
    itself a container (`List[List[Address]]`, say), registers and
    recurses the ordinary way instead (`_collect_json_container_types_expr`,
    since a container reached this way needs exactly the same treatment
    as one reached anywhere else). Checked *before* the `is_parameterized()`
    gate below, unlike `_collect_json_container_types_expr`'s own -- a
    bare, non-generic plain struct name (`Address`, no brackets at all)
    is not itself `is_parameterized()`, but still needs registering here
    (it's simply never reached via a struct's own direct field in the
    first place, only via this function, so there's no "handled
    elsewhere" case to defer to for it the way there is at the top level)."""
    if t.name == "EntityHandle":
        return
    if t.name in plain_struct_fields:
        _register_plain_struct_dispatch(t, plain_struct_fields, dispatch_seen, dispatch_out)
        _visit_plain_struct_own_fields(
            t, plain_struct_fields, plain_struct_type_params, seen, out, dispatch_seen, dispatch_out
        )
        return
    if not t.is_parameterized():
        return
    _collect_json_container_types_expr(
        t, plain_struct_fields, plain_struct_type_params, seen, out, dispatch_seen, dispatch_out
    )


def _visit_plain_struct_own_fields(
    t: TypeExpr,
    plain_struct_fields: Dict[String, List[Field]],
    plain_struct_type_params: Dict[String, List[TypeParam]],
    mut seen: Dict[String, Bool],
    mut out: List[String],
    mut dispatch_seen: Dict[String, Bool],
    mut dispatch_out: List[String],
) raises:
    """Recurses into `t`'s (`t.name in plain_struct_fields`) own fields,
    substituted at `t`'s own concrete type arguments if it's a generic
    instantiation -- each field visited via
    `_collect_json_container_types_expr` (never registered itself: that
    struct's own `_emit_from_json_field_parse` already handles a
    literally-declared field directly, routing straight to its
    `sqrrl__<Name>_from_json` companion, regardless of how deeply nested
    in the overall schema this struct itself is), UNLESS the field's own
    type, as literally declared, is a bare reference to one of `t`'s own
    type parameters (`value: T`) -- that field's generated code always
    calls the shared dispatcher regardless of substitution, so its
    substituted result is visited via `_register_needed` instead."""
    var type_params = (
        plain_struct_type_params[t.name].copy() if t.name in plain_struct_type_params else List[TypeParam]()
    )
    var type_args = List[TypeExpr]()
    for i in range(t.arg_count()):
        type_args.append(t.arg(i))
    for field in plain_struct_fields[t.name]:
        var raw = parse_type_expr(emit_field_type(field))
        var substituted = substitute_type_params_expr(raw, type_params, type_args)
        var is_bare_type_param = False
        if raw.kind == TypeExpr.LEAF:
            for tp in type_params:
                if tp.name == raw.name:
                    is_bare_type_param = True
                    break
        if is_bare_type_param:
            _register_needed(substituted, plain_struct_fields, plain_struct_type_params, seen, out, dispatch_seen, dispatch_out)
        else:
            _collect_json_container_types_expr(
                substituted, plain_struct_fields, plain_struct_type_params, seen, out, dispatch_seen, dispatch_out
            )


def _collect_json_container_types_expr(
    t: TypeExpr,
    plain_struct_fields: Dict[String, List[Field]],
    plain_struct_type_params: Dict[String, List[TypeParam]],
    mut seen: Dict[String, Bool],
    mut out: List[String],
    mut dispatch_seen: Dict[String, Bool],
    mut dispatch_out: List[String],
) raises:
    """Visits `t` -- a struct's own literally-declared field type
    (`build_json_container_types`'s own top-level loops), or a plain
    struct's own field type once substituted at some concrete
    instantiation (`_visit_plain_struct_own_fields`) -- WITHOUT
    registering `t` itself: a field whose own declared type directly
    names a known plain struct (`t.name in plain_struct_fields`, generic
    instantiation or not) is always handled directly by that SAME
    struct's own `_emit_from_json_field_parse`
    (`sqrrl__<Name>_from_json`/`sqrrl__<Name>_from_json[<args>]`, never
    the shared dispatcher), regardless of nesting depth in the overall
    schema -- so `t` itself never needs a `sqrrl__from_json[T]` branch
    here. What DOES, and gets registered via `_register_needed`: anything
    reached *through* `t`'s own structure that isn't itself such a direct
    reference -- a real container's own element(s), always (`Dict[K, V]`
    visits both independently -- `Dict[String, List[Int]]` needs
    `List[Int]` registered too, the same as any other nested container),
    or -- for a generic plain struct reached this way -- a bare reference
    to one of *its own* type parameters, once substituted.

    No-op for a bare relation (`EntityHandle[...]`, handled via
    `sqrrl__JsonSerializable` directly) or a leaf (not container-shaped at
    all, and not a plain struct name either)."""
    if not t.is_parameterized():
        return
    if t.name == "EntityHandle":
        return
    if t.name in plain_struct_fields:
        _visit_plain_struct_own_fields(
            t, plain_struct_fields, plain_struct_type_params, seen, out, dispatch_seen, dispatch_out
        )
        return
    var rendered = t.render()
    if rendered not in seen:
        seen[rendered] = True
        out.append(rendered)
    for i in range(t.arg_count()):
        _register_needed(
            t.arg(i), plain_struct_fields, plain_struct_type_params, seen, out, dispatch_seen, dispatch_out
        )


def _collect_json_container_types(
    t: String,
    plain_struct_fields: Dict[String, List[Field]],
    plain_struct_type_params: Dict[String, List[TypeParam]],
    mut seen: Dict[String, Bool],
    mut out: List[String],
    mut dispatch_seen: Dict[String, Bool],
    mut dispatch_out: List[String],
) raises:
    """A thin `String`-in wrapper around `_collect_json_container_types_expr`
    -- every caller still deals in `emit_field_type`'s own `String`
    output, so parsing happens once, here, rather than pushing a
    `TypeExpr` requirement onto every call site. See that function's own
    doc comment (and `_register_needed`'s) for what gets registered into
    `out` (real containers) vs. `dispatch_out` (plain-struct types
    reached in a position that needs the shared dispatcher) and why."""
    _collect_json_container_types_expr(
        parse_type_expr(t), plain_struct_fields, plain_struct_type_params, seen, out, dispatch_seen, dispatch_out
    )


def build_json_container_types(
    discovery: DiscoveryResult,
    plain_structs: List[DiscoveredStruct],
    plain_struct_fields: Dict[String, List[Field]],
    plain_struct_type_params: Dict[String, List[TypeParam]],
    mut plain_struct_dispatch_types: List[String],
) raises -> List[String]:
    """Every distinct `Wrapper[Element]` field type (`List[String]`,
    `Set[UInt32]`, `List[EntityHandle[sqrrl__EmployeeTableState]]`, ...)
    needed anywhere in the project's schema -- `@@struct` fields and
    plain-struct fields alike, both already rewritten through
    `emit_field_type` (so a `multi` field's `Set[...]` wrapping and a
    relation field's `@@Type` -> `EntityHandle[...]` rewrite are already
    applied the same way `emit_table`/`emit_plain_struct` themselves see
    them), transitively through nested containers and generic plain
    struct instantiations alike (`_collect_json_container_types`).
    `emit_json_module` needs this list to know exactly which `elif T ==
    Wrapper[Element]:` branches `sqrrl__to_json`/`sqrrl__from_json` need
    -- there's no way to ask Mojo's own type system "is `T` a container
    of *anything*" generically (confirmed: comparing a bare,
    unparameterized `List` against `T` crashes the compiler outright), so
    the generated dispatcher has to enumerate every concrete combination
    the schema actually needs instead. Deduplicated (`Dict` used purely
    as a set) since the same combination (`List[String]`, say) can easily
    be needed by more than one struct.

    `plain_struct_dispatch_types` (an out-parameter, same convention as
    `_collect_json_container_types`'s own `seen`/`out`) is the second,
    parallel list this same walk fills in: every plain-struct type (bare
    name or generic instantiation) reached in a position that genuinely
    needs `sqrrl__from_json[T]`'s dispatcher -- a container's own element,
    or a generic plain struct's own bare type-parameter field once
    substituted -- as opposed to some struct's own *directly* declared
    field, which never needs it (`_emit_from_json_field_parse` already
    routes that straight to `sqrrl__<Name>_from_json` on its own, see
    `_collect_json_container_types_expr`'s doc comment). `emit_json_module`
    generates a `sqrrl__<Name>_from_json`-routing branch for each one, the
    same way it generates a container-helper-routing branch for each
    entry in the first list -- together, these are what let a plain
    struct nested inside a `List`/`Set`/`Optional`/`Dict` field, or
    substituted into a generic plain struct's own bare type parameter,
    actually round-trip through `from_json` instead of raising
    "unsupported type" the moment `sqrrl__from_json[T]` is asked to
    reconstruct one.

    A generic plain struct's own field (`liste: List[T]` inside `struct
    Example[T]:`) is skipped here directly -- `t` there is `T`'s own
    placeholder, not a real type, so registering it would generate a
    nonsensical `elif T == List[T]:` branch (confirmed: raises "'List'
    parameter 'T' has 'Movable' type, but value has type 'AnyType'").
    `qualify_type_params_with_self` changing `t` at all is exactly "does
    `t` reference one of `ps`'s own parameters" -- reused here as that
    check rather than writing a second, near-identical scan. Its
    concrete instantiations (`Example[String]`, used as some *other*
    field's type) are what actually reach `Example`'s own fields, via
    `_collect_json_container_types`'s substitution branch."""
    var seen = Dict[String, Bool]()
    var out = List[String]()
    var dispatch_seen = Dict[String, Bool]()
    for ds in discovery.structs:
        for field in ds.parsed.fields:
            _collect_json_container_types(
                emit_field_type(field),
                plain_struct_fields,
                plain_struct_type_params,
                seen,
                out,
                dispatch_seen,
                plain_struct_dispatch_types,
            )
    for ps in plain_structs:
        for field in ps.parsed.fields:
            var t = emit_field_type(field)
            if len(ps.parsed.type_params) > 0 and qualify_type_params_with_self(t, ps.parsed.type_params) != t:
                continue
            _collect_json_container_types(
                t, plain_struct_fields, plain_struct_type_params, seen, out, dispatch_seen, plain_struct_dispatch_types
            )
    return out^


def build_json_module_source(
    discovery: DiscoveryResult,
    container_types: List[String],
    plain_struct_dispatch_types: List[String],
    plain_struct_fields: Dict[String, List[Field]],
    plain_struct_type_params: Dict[String, List[TypeParam]],
    cross_file_symbols: Dict[String, String],
) raises -> String:
    """Assembles the full content of `sqrrl__json.mojo`: fixed imports
    (`Set`, `EntityHandle`, the runtime's `sqrrl__JsonScanner`/
    `sqrrl__escape_json_string`/`sqrrl__JsonSerializable`, and the
    container helpers `list_to_json`/`list_from_json`/`set_to_json`/
    `set_from_json`/`optional_to_json`/`optional_from_json`/
    `dict_to_json`/`dict_from_json` -- imported unconditionally rather
    than only the ones this project's own `container_types` actually
    reference, the same simplicity tradeoff the per-struct `Table`
    imports below already make; an unused generic import costs nothing,
    since Mojo only instantiates a generic function where it's actually
    called), one `from
    <module> import sqrrl__<Name>TableState, sqrrl__<Name>Table` per
    `@@struct` declared anywhere in the project (mirroring
    `emit_world_module`'s own per-struct `Table` import loop --
    unconditional rather than scanning for which ones `container_types`
    actually references, the same simplicity tradeoff `emit_world_module`
    already makes; the `Table` half specifically is what lets a plain
    struct's own `from_json` companion below take a `sqrrl__tbl_<Target>:
    sqrrl__<Target>Table` parameter for any relation field it embeds,
    direct or through another plain struct), one `from <module> import
    <Name>` per plain struct project-wide too (`cross_file_symbols`,
    `build_cross_file_symbols` -- every entry that isn't a `Table`/
    `TableState` is a plain struct name; needed since a companion's own
    `-> Address:` return type and `Address(...)` constructor call
    reference the plain struct type *by name*, not just its fields'
    types), `emit_json_module`'s own generated dispatcher body, and
    finally every plain struct's own `sqrrl__<Name>_from_json`
    free-function companion (`plain_struct_fields`,
    `driver.build_plain_struct_fields` -- shorthand and hand-written alike)
    -- this is JSON serialization's one, single home: the generic
    `sqrrl__to_json`/`sqrrl__from_json` dispatch, the container helpers, and
    every plain struct's own reconstruction companion, all in the one file
    a struct-declaring file already imports from unconditionally (see
    `emit_file`'s own `sqrrl__to_json`/`from_json` import check), rather
    than splitting the latter off into `sqrrl__world.mojo` for no
    reason connected to what `sqrrl__World` itself is for (the shared
    table aggregate)."""
    var out = String()
    out += "from std.collections import Set\n"
    out += "from squirrel_runtime.entity import EntityHandle\n"
    out += (
        "from squirrel_runtime.json import sqrrl__JsonScanner, sqrrl__escape_json_string,"
        " sqrrl__JsonSerializable, list_to_json, list_from_json, set_to_json, set_from_json,"
        " optional_to_json, optional_from_json, dict_to_json, dict_from_json\n"
    )
    for ds in discovery.structs:
        var table_name = sqrrl_prefixed(ds.parsed.name) + "Table"
        var state_name = sqrrl_prefixed(ds.parsed.name) + "TableState"
        out += String(t"from {ds.module_path} import {state_name}, {table_name}\n")
    for symbol in cross_file_symbols.keys():
        if not symbol.endswith("TableState") and not symbol.endswith("Table"):
            out += String(t"from {cross_file_symbols[symbol]} import {symbol}\n")
    out += "\n\n"
    out += emit_json_module(container_types, plain_struct_dispatch_types)

    for name in plain_struct_fields.keys():
        out += "\n\n"
        var type_params = (
            plain_struct_type_params[name].copy() if name in plain_struct_type_params else List[TypeParam]()
        )
        out += emit_plain_struct_from_json(
            ParsedStruct(name=name, fields=plain_struct_fields[name].copy(), type_params=type_params^),
            plain_struct_fields,
        )

    return out^


