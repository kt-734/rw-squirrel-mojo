from squirrel_compiler.parser import TypeExpr, parse_type_expr
from squirrel_compiler.codegen.helpers import container_wrapper_of, container_element_of
from squirrel_compiler.codegen.plain_struct import _is_entity_handle_type


def emit_json_module(container_types: List[String], plain_struct_dispatch_types: List[String]) -> String:
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
    dependency, a runtime file importing from a generated one, is safe).

    `plain_struct_dispatch_types` (`driver.build_json_container_types`)
    is the from_json-only counterpart to `container_types`: every plain
    struct (bare name, or a generic instantiation) reached in a position
    that genuinely needs `sqrrl__from_json[T]`'s dispatcher -- a
    container's own element, or a generic plain struct's own bare type-
    parameter field once substituted -- as opposed to some struct's own
    *directly* declared field, which `_emit_from_json_field_parse`
    already routes straight to `sqrrl__<Name>_from_json` without ever
    going through this shared dispatcher at all. `sqrrl__to_json` needs
    no matching branches -- its reflection-based fallback (the final
    `else`) already serializes any plain struct, instantiated or not,
    generically, the same as it would for one reached any other way."""
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
    for pst in plain_struct_dispatch_types:
        var parsed = parse_type_expr(pst)
        out += String(t"    elif T == {pst}:\n")
        if parsed.is_parameterized():
            var args = String()
            for i in range(parsed.arg_count()):
                if i > 0:
                    args += ", "
                args += parsed.arg(i).render()
            out += String(
                t"        return rebind[T](sqrrl__{parsed.name}_from_json[{args}](sc)).copy()\n"
            )
        else:
            out += String(t"        return rebind[T](sqrrl__{parsed.name}_from_json(sc)).copy()\n")
    out += "    else:\n"
    out += (
        '        raise Error("sqrrl__from_json: unsupported type -- structs use their own'
        ' generated from_json")\n'
    )
    return out^


