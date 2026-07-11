from squirrel_compiler.parser import is_ident_char, Field
from squirrel_compiler.codegen import transform_source
from squirrel_compiler.driver.discovery import DiscoveryResult


def _contains_word(haystack: String, needle: String) -> Bool:
    """True if `needle` appears in `haystack` at a word boundary on both
    sides (not preceded/followed by an identifier char) -- a plain
    substring check is fine for `sqrrl__`-prefixed names (collision-proof
    by construction, same reasoning as `sqrrl_prefixed`'s own doc comment),
    but a plain struct's bare name (`Address`) is an ordinary word that
    could otherwise false-positive inside an unrelated longer identifier or
    a string literal."""
    var h = haystack.as_bytes()
    var n = needle.as_bytes()
    if len(n) == 0 or len(n) > len(h):
        return False
    for start in range(len(h) - len(n) + 1):
        var matches = True
        for i in range(len(n)):
            if h[start + i] != n[i]:
                matches = False
                break
        if not matches:
            continue
        var before_ok = start == 0 or not is_ident_char(h[start - 1])
        var after_ok = start + len(n) >= len(h) or not is_ident_char(h[start + len(n)])
        if before_ok and after_ok:
            return True
    return False


def emit_file(
    path: String,
    module_path: String,
    discovery: DiscoveryResult,
    relation_schema: Dict[String, Dict[String, String]],
    function_returns: Dict[String, String],
    unique_fields: Dict[String, List[String]],
    ordered_fields: Dict[String, List[String]],
    cross_file_symbols: Dict[String, String],
    plain_struct_fields: Dict[String, List[Field]],
    relation_targets: Dict[String, List[String]],
    multi_fields: Dict[String, List[String]] = Dict[String, List[String]](),
) raises -> String:
    """Pass 2: emits the generated Mojo source for `path` (a single `.rel`
    file, module `module_path`), prefixed with the runtime imports, an
    import for every `cross_file_symbols` (`build_cross_file_symbols`)
    entry this file's *own transformed output* actually references and
    that isn't declared in this file -- without this, a relation field, a
    plain field, or an `ENTITY_PARAM` crossing files compiles to a
    reference to a type nothing ever imported (confirmed: each of those
    three failed with "use of unknown declaration" before this was general
    rather than only covering relation fields inside a struct declared in
    this same file) -- and, if this file's script body touches
    `sqrrl__world` at all, a `from sqrrl__world import sqrrl__init,
    sqrrl__World, sqrrl__world_from_json, sqrrl__init_from_json` line (see
    `emit_world_module`).

    The struct-definition and script-body rewriting itself is
    `transform_source`'s job, run once over the whole file -- it handles
    `@@struct` and script markers (`@@Type{...}`, `@@entity.field` (single-
    or multi-hop), `@@init()`, bare `@@`) in a single pass, so a file mixing
    schema and script (the common case) comes out correctly ordered without
    this function needing to know the difference. `relation_schema`
    (`build_relation_schema`, project-wide) is what lets it resolve a
    chained field access whose intermediate hop targets a struct declared
    in a different file, `function_returns` (`build_function_returns`,
    project-wide) is what lets a call site infer/validate an entity-
    returning function's binding regardless of which file declares it, and
    `unique_fields` (`build_unique_fields`, project-wide) does the same for
    a `@@Type.for_<field>(...)`/`@@Type.create(...)` table-level call, and
    `ordered_fields` (`build_ordered_fields`, project-wide) tells that same
    call site whether such a call instead returns `Set[EntityHandle[...]]`
    (an `ordered` field's own six query methods). Also imports
    `sqrrl__to_json`/`sqrrl__from_json` (from the project-wide generated
    `sqrrl__json.mojo`, see `build_json_module_source`) whenever this
    file's own generated `to_json`/`from_json` methods (per `@@struct`)
    reference them -- every struct gets these two methods
    unconditionally, so this is really "does this file declare a struct
    at all", checked the same way the `sqrrl__world` import above is.
    That same condition also imports every plain struct's own
    `sqrrl__<Name>_from_json` companion (`plain_struct_fields`,
    `build_plain_struct_fields`, shorthand and hand-written alike, all
    generated into `sqrrl__json.mojo` alongside the dispatcher itself)
    unconditionally -- a struct's own `from_json` can route any
    plain-struct-typed field to *any* of them by name
    (`_emit_from_json_field_parse`), so there's no cheaper check than
    "this file has a struct with a `from_json` at all" that's still
    correct, same simplicity tradeoff as importing every `Table`/
    `TableState` unconditionally rather than scanning field-by-field."""
    var f = open(path, "r")
    var source = f.read()
    f.close()
    var transformed: String
    try:
        transformed = transform_source(
            source,
            relation_schema,
            function_returns,
            unique_fields,
            ordered_fields,
            plain_struct_fields,
            relation_targets,
            multi_fields,
        )
    except e:
        raise Error(path + ": " + String(e))

    var out = String(
        "from squirrel_runtime.entity import Table, EntityHandle,"
        " EntityInner, TableStateLike\n"
    )
    out += "from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel\n"
    out += "from std.collections import Set\n"
    out += "from std.os import abort\n"
    if "sqrrl__world" in transformed:
        out += (
            "from sqrrl__world import sqrrl__init, sqrrl__World,"
            " sqrrl__world_from_json, sqrrl__init_from_json\n"
        )
    if (
        "sqrrl__to_json" in transformed
        or "sqrrl__from_json" in transformed
        or "sqrrl__JsonScanner" in transformed
    ):
        # A struct-declaring file needs `sqrrl__to_json`/`sqrrl__from_json`
        # because its own generated `sqrrl__to_json`/`sqrrl__from_json`
        # methods (`emit_table_json_methods`) call the shared free
        # functions of the same name (leaf/container field
        # serialization); a *script*-only file needs `sqrrl__JsonScanner`
        # if it hand-threads a whole-world reload directly (`var sc =
        # sqrrl__JsonScanner(dump); var reloaded =
        # sqrrl__world_from_json(sc);`, see ADVANCED_FEATURES.md) rather
        # than going through `@@begin_init_from_json(...)` sugar -- either
        # substring appearing is reason enough to import both, same as
        # `Rel`/`UniqueRel`/... are always imported together regardless of
        # which ones a specific file actually uses.
        out += "from sqrrl__json import sqrrl__to_json, sqrrl__from_json\n"
        out += "from squirrel_runtime.json import sqrrl__JsonScanner\n"
        for plain_struct_name in plain_struct_fields.keys():
            out += String(t"from sqrrl__json import sqrrl__{plain_struct_name}_from_json\n")

    for symbol in cross_file_symbols.keys():
        var target_module = cross_file_symbols[symbol]
        if target_module == module_path:
            continue
        if _contains_word(transformed, symbol):
            out += String(t"from {target_module} import {symbol}\n")

    out += "\n\n"
    out += transformed
    return out


