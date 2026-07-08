from squirrel_compiler.parser import Scanner
from squirrel_compiler.codegen import sqrrl_prefixed
from squirrel_compiler.driver.discovery import DiscoveryResult
from squirrel_compiler.driver.file_paths import module_path_for


def build_cross_file_symbols(
    discovery: DiscoveryResult, rel_files: List[String], target_root: String
) raises -> Dict[String, String]:
    """Every generated-Mojo identifier a `.rel` file's own output could
    reference that's declared in a *different* file, mapped to the module
    declaring it -- `sqrrl__<Name>TableState` for each `@@struct` (the type
    a relation field's `EntityHandle[...]` or an `ENTITY_PARAM`'s parameter
    type names), and the bare `<Name>` for each plain struct (emitted
    verbatim/unprefixed, so a plain field embedding one by value names it
    exactly that way). `emit_file` scans its own transformed output text for
    whichever of these actually appear, rather than re-deriving "does this
    field need an import" from field-by-field inspection -- one general
    mechanism instead of one bespoke check per place a cross-file reference
    can show up (a relation field inside a struct declaration, a plain
    field naming another file's struct, an `ENTITY_PARAM` in a file with no
    `@@struct` of its own, ...), since enumerating every such place
    one-by-one is exactly what missed the last two.

    Plain-struct names come from a dedicated, lenient scan
    (`Scanner.find_next_plain_struct_name`) rather than
    `discover_plain_structs`' result -- that one only recognizes the
    brace-shorthand body (needed to actually parse fields for
    `check_no_relation_cycles`), so a *real*, hand-written Mojo plain
    struct (the only kind that actually compiles) would otherwise never
    get imported cross-file at all.

    Also registers `sqrrl__<Name>Table` (not just `...TableState`) for
    every `@@struct` -- needed since a struct's own generated `from_json`
    (`emit_table_json_methods`) now takes a `sqrrl__tbl_<Target>:
    sqrrl__<Target>Table` parameter per relation target, which can name a
    struct declared in a different file from the one generating the
    call, same cross-file gap `...TableState` already closes for a
    relation field's own `EntityHandle[...]`."""
    var symbol_of = Dict[String, String]()
    for ds in discovery.structs:
        symbol_of[sqrrl_prefixed(ds.parsed.name) + "TableState"] = ds.module_path
        symbol_of[sqrrl_prefixed(ds.parsed.name) + "Table"] = ds.module_path
    for path in rel_files:
        var module_path = module_path_for(path, target_root)
        var f = open(path, "r")
        var source = f.read()
        f.close()
        var sc = Scanner(source)
        while True:
            var name = sc.find_next_plain_struct_name()
            if not name:
                break
            symbol_of[name.value()] = module_path
    return symbol_of^


