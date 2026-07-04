from std.os import listdir, makedirs
from std.os.path import dirname, isdir, isfile, join

from squirrel_compiler.parser import (
    Scanner,
    ParsedStruct,
    FieldModifier,
    is_ident_char,
    is_wrapped_relation_type,
    relation_target_of,
    relation_wrapper_of,
)
from squirrel_compiler.codegen import (
    sqrrl_prefixed,
    transform_source,
    encode_container_type,
    is_container_type,
    container_element_of,
)


def find_rel_files(root: String) raises -> List[String]:
    """Recursively finds every `.rel` file under `root`, depth-first,
    returning full paths (root-relative, joined via `os.path.join`)."""
    var out = List[String]()
    _collect_rel_files(root, out)
    return out^


def _collect_rel_files(dir: String, mut out: List[String]) raises:
    for entry in listdir(dir):
        var full = join(dir, entry)
        if isdir(full):
            _collect_rel_files(full, out)
        elif isfile(full) and entry.endswith(".rel"):
            out.append(full)


def mojo_output_path(rel_path: String) -> String:
    """`foo/bar.rel` -> `foo/bar.mojo`, written alongside the source file,
    matching the Zig converter's `stem ++ ".zig"` convention."""
    return String(rel_path[byte = 0 : rel_path.byte_length() - String(".rel").byte_length()]) + ".mojo"


def module_path_for(rel_path: String, target_root: String) -> String:
    """`sub/employee.rel` (rooted at `target_root`) -> `sub.employee`, the
    dotted Mojo module path a cross-file relation import needs."""
    var root_prefix = target_root
    if not root_prefix.endswith("/"):
        root_prefix += "/"
    var relative = rel_path
    if relative.startswith(root_prefix):
        relative = String(relative.removeprefix(root_prefix))
    var without_ext = String(
        relative[byte = 0 : relative.byte_length() - String(".rel").byte_length()]
    )
    return without_ext.replace("/", ".")


struct DiscoveredStruct(Copyable, Movable, ImplicitlyDeletable):
    """One `@@struct` found during the directory walk, tagged with the
    dotted module path of the file that declared it -- used in the second
    pass to resolve which relation fields need a cross-file import."""

    var module_path: String
    var parsed: ParsedStruct

    def __init__(out self, var module_path: String, var parsed: ParsedStruct):
        self.module_path = module_path^
        self.parsed = parsed^


struct DiscoveryResult(Movable):
    """The output of `discover_structs`' pass over every `.rel` file:
    every struct found, and a `struct name -> declaring module` map."""

    var structs: List[DiscoveredStruct]
    var module_of: Dict[String, String]

    def __init__(out self, var structs: List[DiscoveredStruct], var module_of: Dict[String, String]):
        self.structs = structs^
        self.module_of = module_of^


def discover_structs(rel_files: List[String], target_root: String) raises -> DiscoveryResult:
    """Pass 1: parses every `@@struct` in every `.rel` file under
    `target_root`, without emitting anything yet. Returns the structs found
    (each tagged with its declaring module) and a `struct name -> declaring
    module` map -- both needed before any file's code can be emitted,
    since a relation field's target might live in a file we haven't walked
    to yet."""
    var discovered = List[DiscoveredStruct]()
    var module_of = Dict[String, String]()

    for path in rel_files:
        var module_path = module_path_for(path, target_root)
        var f = open(path, "r")
        var source = f.read()
        f.close()

        var sc = Scanner(source)
        try:
            while sc.find_next_struct_decl():
                var parsed = sc.parse_struct()
                module_of[parsed.name] = module_path
                discovered.append(DiscoveredStruct(module_path, parsed^))
        except e:
            raise Error(path + ": " + String(e))

    return DiscoveryResult(discovered^, module_of^)


def build_relation_schema(discovery: DiscoveryResult) -> Dict[String, Dict[String, String]]:
    """Struct name -> relation field name -> target struct name, for every
    `@@struct` declared project-wide. `transform_source` needs this to
    resolve a chained field access (`@@alice.@@employee.title`): an
    intermediate hop's target struct can be declared in a different file
    than the script using the chain (same reasoning `emit_file`'s cross-file
    import resolution already relies on), so this can't be derived from a
    single file's own source text. A collection-typed relation field
    (`@@members: List[@@Employee]`) registers its *element* type the same
    way a bare one does, but `encode_container_type`-encoded (`"List
    [Employee]"`, not bare `"Employee"`) -- `get_<field>` on one of these
    returns a `List[EntityHandle[...]]`, not a single entity, so callers
    that key off this schema (`transform_source`'s `get_<field>` return-type
    inference) need to tell the two apart the same way `entity_to_type`
    already distinguishes a container-tracked variable from a plain one.
    A collection field can't be hopped through as a chain intermediate
    (there's no single entity to continue from), so the hop-chain walk
    below is the one reader of this schema that only ever encounters the
    bare form in practice -- but it still gets the encoded string for a
    wrapped field rather than silently mismatching it, since a `.field`
    chain accidentally stepping through a collection field is exactly the
    kind of mistake that should surface as an error, not be hidden. A
    `multi` relation field (`multi @@members: @@Employee`) is registered
    the same encoded way as a wrapped one, even though its own `type_str`
    is the bare element type, not `Set[@@Employee]` -- `get_members`
    still actually returns `Set[EntityHandle[...]]` (`multi` is what
    turns the declared element type into a `Set[...]` field; see
    `codegen.emit_field_type`), so this schema needs to reflect that
    actual shape, not the syntax `multi`'s own field happened to be
    written with."""
    var schema = Dict[String, Dict[String, String]]()
    for ds in discovery.structs:
        var fields = Dict[String, String]()
        for field in ds.parsed.fields:
            if field.modifier == FieldModifier.MULTI and field.type_str.startswith("@@"):
                # A plain (non-relation) `multi` field, e.g. `multi tags:
                # String`, has nothing to register here at all -- it isn't
                # a relation to another `@@struct`, just a collection of
                # plain values, so it's no different from any other plain
                # field as far as this schema is concerned.
                fields[field.name] = encode_container_type("Set", relation_target_of(field.type_str))
            elif field.type_str.startswith("@@"):
                fields[field.name] = relation_target_of(field.type_str)
            elif is_wrapped_relation_type(field.type_str):
                fields[field.name] = encode_container_type(
                    relation_wrapper_of(field.type_str), relation_target_of(field.type_str)
                )
        schema[ds.parsed.name] = fields^
    return schema^


def build_unique_fields(discovery: DiscoveryResult) -> Dict[String, List[String]]:
    """Struct name -> names of its `unique`-marked fields, for every
    `@@struct` declared project-wide. Lets `rewrite_markers` tell whether a
    `@@Type.for_<field>(...)` table-level call returns a single
    `EntityHandle[...]` (a `unique` field's `for_<field>`, or `create`) or a
    `List[EntityHandle[...]]` (any other field's) -- only the former can
    sensibly be bound to an `@@`-marked variable for further `@@name.field`
    access afterward, same reasoning as `build_function_returns`."""
    var unique_fields = Dict[String, List[String]]()
    for ds in discovery.structs:
        var names = List[String]()
        for field in ds.parsed.fields:
            if field.modifier == FieldModifier.UNIQUE:
                names.append(field.name)
        unique_fields[ds.parsed.name] = names^
    return unique_fields^


def build_ordered_fields(discovery: DiscoveryResult) -> Dict[String, List[String]]:
    """Struct name -> names of its `ordered`-marked fields, for every
    `@@struct` declared project-wide. Lets `rewrite_markers`
    (`_is_ordered_field_query`) tell whether a `@@Type.for_<field>(...)`
    (or one of its five range-shaped siblings) table-level call returns
    `Set[EntityHandle[...]]` (an `ordered` field's own six query methods,
    see `emit_table`'s `FieldModifier.ORDERED` branch) rather than the
    `List[EntityHandle[...]]` any other field's `for_<field>` returns --
    same reasoning as `build_unique_fields`."""
    var ordered_fields = Dict[String, List[String]]()
    for ds in discovery.structs:
        var names = List[String]()
        for field in ds.parsed.fields:
            if field.modifier == FieldModifier.ORDERED:
                names.append(field.name)
        ordered_fields[ds.parsed.name] = names^
    return ordered_fields^


def build_function_returns(rel_files: List[String]) raises -> Dict[String, String]:
    """Function name -> the `@@Type` it returns, for every `def @@funcName(
    ...) -> @@Type:` signature project-wide (a def's own signature is
    assumed to fit on one line, same as elsewhere in this compiler). Lets a
    call site (`@@funcName(...)`) both infer `entity_to_type` automatically
    -- no explicit `: @@Type` annotation needed -- and reject binding the
    result to an unmarked variable (`var x = @@funcName();`), since
    `MarkerKind.WORLD_FUNC`'s call-site handling can now look the function
    up regardless of what arguments (if any) it's called with.

    Also recognizes the container form, `-> Container[@@Type]:`, storing it
    with the same `"Container[Type]"` encoding `entity_to_type` itself uses
    (`encode_container_type`) -- so a function returning, say,
    `List[@@Person]` is tracked exactly like a `for_<field>` call is."""
    var out = Dict[String, String]()
    for path in rel_files:
        var f = open(path, "r")
        var source = f.read()
        f.close()
        var bytes = source.as_bytes()
        var sc = Scanner(source)
        while True:
            sc.skip_trivia()
            if sc.at_end():
                break
            if sc.starts_with("def @@"):
                var line_start = sc.pos
                var line_end = line_start
                while line_end < len(bytes) and bytes[line_end] != UInt8(ord("\n")):
                    line_end += 1
                var line_sc = Scanner(String(source[byte = line_start : line_end]))
                _ = line_sc.try_consume("def ")
                _ = line_sc.try_consume("@@")
                var func_name = line_sc.scan_ident()
                var found_arrow = False
                while not line_sc.at_end():
                    if line_sc.try_consume("->"):
                        found_arrow = True
                        break
                    line_sc.pos += 1
                if found_arrow:
                    line_sc.skip_trivia()
                    if line_sc.try_consume("@@"):
                        var ret_type = line_sc.scan_ident()
                        if ret_type.byte_length() > 0 and func_name.byte_length() > 0:
                            out[func_name] = ret_type
                    else:
                        var wrapper = line_sc.scan_ident()
                        line_sc.skip_trivia()
                        if wrapper.byte_length() > 0 and line_sc.try_consume("["):
                            line_sc.skip_trivia()
                            if line_sc.try_consume("@@"):
                                var ret_type = line_sc.scan_ident()
                                line_sc.skip_trivia()
                                if ret_type.byte_length() > 0 and func_name.byte_length() > 0:
                                    if line_sc.try_consume("]"):
                                        out[func_name] = encode_container_type(wrapper, ret_type)
                                    elif line_sc.try_consume(","):
                                        # A second (or later) type parameter,
                                        # e.g. `Dict[@@Type, V]` -- iterating
                                        # yields keys of the first parameter,
                                        # which is all `entity_to_type`
                                        # tracking cares about here, so the
                                        # rest is skipped rather than parsed
                                        # (bracket-depth-aware, in case it's
                                        # itself a generic type).
                                        var depth = 1
                                        while depth > 0 and not line_sc.at_end():
                                            if line_sc.peek() == UInt8(ord("[")):
                                                depth += 1
                                            elif line_sc.peek() == UInt8(ord("]")):
                                                depth -= 1
                                            line_sc.pos += 1
                                        if depth == 0:
                                            out[func_name] = encode_container_type(wrapper, ret_type)
                sc.pos = line_end
                continue
            sc.pos += 1
    return out^


def discover_plain_structs(rel_files: List[String], target_root: String) raises -> List[DiscoveredStruct]:
    """Parses every bare `struct Name { ... }` (not `@@struct`) declared in
    any `.rel` file -- these never get a generated Table/State pair, but
    `check_no_relation_cycles` still needs their fields: a plain field
    elsewhere naming one of these is otherwise an invisible way to smuggle
    a `@@`-marked relation back through it, completing a construction cycle
    without ever writing `@@Type` on both ends directly (see notes.md's
    `Other`/`Person` example). Tagged with each one's declaring module
    (like `discover_structs` tags `@@struct`s), since a plain field naming
    one of these from a *different* file needs to import it -- see
    `emit_file`."""
    var out = List[DiscoveredStruct]()
    for path in rel_files:
        var module_path = module_path_for(path, target_root)
        var f = open(path, "r")
        var source = f.read()
        f.close()

        var sc = Scanner(source)
        try:
            while sc.find_next_plain_struct_decl():
                out.append(DiscoveredStruct(module_path, sc.parse_plain_struct()))
        except e:
            raise Error(path + ": " + String(e))

    return out^


def check_single_init_call(rel_files: List[String]) raises:
    """Rejects more than one `@@init()` call across the whole project.
    Each call independently constructs its own `sqrrl__Squirrel` -- nothing
    else stops a second one from silently creating a disconnected "world"
    instead of sharing the one everything else uses (confirmed: a second
    `@@init()` compiles and runs fine, producing two independent tables
    instead of the single shared one the whole `sqrrl__world`/`@@`
    threading design assumes). `@@init()` is meant to be called exactly
    once, wherever the top of the call chain is (typically `main()`), with
    `@@` threading the result everywhere else -- so a second call anywhere
    in the project is always a mistake (calling `@@init()` again instead
    of adding `@@` to a function's own parameters), never a legitimate
    need for two worlds."""
    var call_sites = List[String]()
    for path in rel_files:
        var f = open(path, "r")
        var source = f.read()
        f.close()

        var sc = Scanner(source)
        while sc.find_next_init_call():
            sc.parse_init()
            call_sites.append(path)

    if len(call_sites) > 1:
        var files = String()
        for i in range(len(call_sites)):
            if i > 0:
                files += ", "
            files += call_sites[i]
        raise Error(
            "InvalidSquirrelSyntax: @@init() called "
            + String(len(call_sites))
            + " times across the project ("
            + files
            + ") -- it should be called exactly once (typically in the"
            " entry point); thread the result to every other function via"
            " '@@' in its parameters instead of calling @@init() again"
        )


def _relation_targets(parsed: ParsedStruct, known_names: Dict[String, Bool]) -> List[String]:
    """A field is a graph edge in one of three ways: `@@`-marked (an actual
    relation field, `multi` or not -- always followed, matching prior
    behavior, since an edge to an undeclared target is harmlessly skipped
    later wherever the graph is walked), a wrapped relation
    (`List[@@Employee]`) or `multi`-of-a-plain-value field whose element
    names a known struct, or a *plain* field whose type text happens to
    exactly name another known struct (`@@` or plain) -- an embed-by-value
    that can still smuggle a cycle back through whatever that struct's own
    fields point at, even though it isn't a relation field itself. An
    ordinary plain field (`String`, `UInt32`, ...) whose type isn't any
    known struct's name is not an edge.

    `multi` gets no special exemption here: a `.rel` author never needs
    to declare it on *both* sides of a many-to-many relationship to begin
    with -- `MultiRel`'s own `get_fwd`/`get_bwd` already answer both
    directions (`Course.get_students(math)` and
    `Course.for_students(alice)`) from a single field declared on just one
    struct, with nothing on the other at all (confirmed end-to-end: a bare
    `multi @@students: @@Student` on `Course` alone gives both queries).
    Declaring the same relationship redundantly on both sides -- `Student.
    courses`/`Course.students`, each pointing at the other -- is a genuine
    graph cycle like any other and is rejected the same way, since nothing
    is gained over the one-sided form that a real `ArcPointer` cycle risk
    would be worth accepting for."""
    var targets = List[String]()
    for field in parsed.fields:
        if field.type_str.startswith("@@"):
            targets.append(String(field.type_str[byte=2 : field.type_str.byte_length()]))
        elif is_wrapped_relation_type(field.type_str):
            targets.append(relation_target_of(field.type_str))
        elif field.type_str in known_names:
            targets.append(field.type_str)
        elif is_container_type(field.type_str):
            var inner = container_element_of(field.type_str)
            if inner in known_names:
                targets.append(inner)
    return targets^


def _find_relation_cycle(
    name: String,
    targets_of: Dict[String, List[String]],
    module_of: Dict[String, String],
    mut state: Dict[String, Int],
    mut path: List[String],
) raises:
    """DFS over the project-wide relation graph (`targets_of`: struct name
    -> the names of the structs its `@@`-marked fields point at). `state`
    tracks each struct as unseen (absent), in-progress (`1`, still on the
    current path) or done (`2`, fully explored with no cycle found through
    it) -- finding an in-progress struct again means the path just walked
    back to something it's still inside of, i.e. a cycle, however many hops
    it took to get there (`A -> B -> C -> A`, not just a direct pair). A
    target that isn't itself a declared struct (an undeclared relation
    type -- a separate, pre-existing gap) is skipped rather than treated as
    a dead end worth erroring on here. `module_of` (struct name -> declaring
    module, `discover_structs`/`discover_plain_structs` combined) annotates
    each struct in the reported chain with where it's declared -- a cycle
    can span multiple files, so there's no single `file:line:col` for the
    error as a whole the way a single-point syntax error gets."""
    state[name] = 1
    path.append(name)
    if name in targets_of:
        for target in targets_of[name]:
            if target not in targets_of:
                continue
            if target in state:
                if state[target] == 1:
                    var cycle = String()
                    var started = False
                    for n in path:
                        if n == target:
                            started = True
                        if started:
                            if cycle.byte_length() > 0:
                                cycle += " -> "
                            cycle += n
                            if n in module_of:
                                cycle += " (" + module_of[n] + ")"
                    cycle += " -> " + target
                    raise Error("CyclicRelation: " + cycle)
            else:
                _find_relation_cycle(target, targets_of, module_of, state, path)
    _ = path.pop(len(path) - 1)
    state[name] = 2


def check_no_relation_cycles(
    discovery: DiscoveryResult, plain_structs: List[DiscoveredStruct]
) raises:
    """Rejects a schema whose relation fields form a cycle -- `A`'s field
    relates to `B` and (directly or transitively, any number of hops) `B`'s
    relates back to `A`, including a struct relating to itself. Two
    independent reasons this can't be allowed: `create()` requires every
    relation field's target to already exist (relation fields aren't
    `Optional`, see `emit_table`), so a cycle has no valid *first* struct
    to construct -- whichever one you try to create first needs a live
    handle of the next one in the cycle, which doesn't exist yet
    (confirmed: Mojo happily compiles the circular cross-file imports a
    struct-level cycle produces, so this doesn't fail until `create()` is
    actually called, with a confusing type error rather than a
    schema-level one). Separately, even if it were constructible some
    other way, Mojo's `ArcPointer` has no cycle collector -- two entities
    holding live references to each other would keep each other's refcount
    above zero forever, since `TableStateLike`'s cascade-cleanup only ever
    runs after an entity's own refcount already reached zero.

    `plain_structs` (`discover_plain_structs`) are folded into the same
    graph as `@@struct`s -- a bare `struct` never gets a generated
    Table/State pair, but a `@@struct` field can still embed one by value,
    and that plain struct's own body can itself smuggle a `@@`-marked
    relation back, completing a cycle that never has `@@Type` written on
    both ends directly (see notes.md's `Other`/`Person` example). Checked
    project-wide (not per file), since a relation field's target -- or a
    plain struct's declaration -- can live in a different file."""
    var known_names = Dict[String, Bool]()
    for ds in discovery.structs:
        known_names[ds.parsed.name] = True
    for ps in plain_structs:
        known_names[ps.parsed.name] = True

    var module_of = discovery.module_of.copy()
    for ps in plain_structs:
        module_of[ps.parsed.name] = ps.module_path

    var targets_of = Dict[String, List[String]]()
    var all_names = List[String]()
    for ds in discovery.structs:
        targets_of[ds.parsed.name] = _relation_targets(ds.parsed, known_names)
        all_names.append(ds.parsed.name)
    for ps in plain_structs:
        targets_of[ps.parsed.name] = _relation_targets(ps.parsed, known_names)
        all_names.append(ps.parsed.name)

    var state = Dict[String, Int]()
    for name in all_names:
        if name in state:
            continue
        var path = List[String]()
        _find_relation_cycle(name, targets_of, module_of, state, path)


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
    get imported cross-file at all."""
    var symbol_of = Dict[String, String]()
    for ds in discovery.structs:
        symbol_of[sqrrl_prefixed(ds.parsed.name) + "TableState"] = ds.module_path
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


def emit_squirrel_module(discovery: DiscoveryResult) raises -> String:
    """Emits `sqrrl__Squirrel.mojo`'s content: `sqrrl__Squirrel`, the single
    aggregate holding one table per `@@struct` declared anywhere in the
    project, plus `sqrrl__init()`, the one factory a script calls (via
    `@@init()`) to obtain it. Built project-wide, in its own file, rather
    than per `.rel` file or inlined into one of them -- a struct's
    declaring file and a script that wants to construct/read/write it can
    be different files, and Mojo has no mutable global/static state (see
    `Table`'s doc comment in `entity.mojo`) for either side to reach a
    shared instance by name otherwise. This is also what resolves the
    former cross-file gap for script-level table references (see
    `emit_file`'s doc comment): `sqrrl__world.TypeName` works the same
    regardless of which file declared `TypeName`, since every table hangs
    off this one aggregate rather than a file-local variable."""
    var out = String()
    for ds in discovery.structs:
        var table_name = sqrrl_prefixed(ds.parsed.name) + "Table"
        out += String(t"from {ds.module_path} import {table_name}\n")

    out += "\n\n"
    out += "struct sqrrl__Squirrel(Movable):\n"
    for ds in discovery.structs:
        var table_name = sqrrl_prefixed(ds.parsed.name) + "Table"
        out += String(t"    var {ds.parsed.name}: {table_name}\n")
    out += "\n"
    out += "    def __init__(out self):\n"
    if len(discovery.structs) == 0:
        out += "        pass\n"
    for ds in discovery.structs:
        var table_name = sqrrl_prefixed(ds.parsed.name) + "Table"
        out += String(t"        self.{ds.parsed.name} = {table_name}()\n")

    out += "\n\n"
    out += "def sqrrl__init() -> sqrrl__Squirrel:\n"
    out += "    return sqrrl__Squirrel()\n"
    return out


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
    `sqrrl__world` at all, a `from sqrrl__Squirrel import sqrrl__init,
    sqrrl__Squirrel` line (see `emit_squirrel_module`).

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
    (an `ordered` field's own six query methods)."""
    var f = open(path, "r")
    var source = f.read()
    f.close()
    var transformed: String
    try:
        transformed = transform_source(source, relation_schema, function_returns, unique_fields, ordered_fields)
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
        out += "from sqrrl__Squirrel import sqrrl__init, sqrrl__Squirrel\n"

    for symbol in cross_file_symbols.keys():
        var target_module = cross_file_symbols[symbol]
        if target_module == module_path:
            continue
        if _contains_word(transformed, symbol):
            out += String(t"from {target_module} import {symbol}\n")

    out += "\n\n"
    out += transformed
    return out


def ensure_init_files(rel_files: List[String], target_root: String) raises:
    """Writes an empty `__init__.mojo` in every directory (below
    `target_root`, exclusive) that contains a converted file -- Mojo only
    treats a directory as an importable package if it has one (confirmed:
    `from sub.employee import EmployeeTableState` failed with "unable to
    locate module 'sub'" until `sub/__init__.mojo` existed), same
    requirement `squirrel_runtime`/`squirrel_compiler` already have."""
    var seen = List[String]()
    for path in rel_files:
        var dir = dirname(path)
        while dir != target_root and dir not in seen:
            seen.append(dir)
            var init_path = join(dir, "__init__.mojo")
            if not isfile(init_path):
                var f = open(init_path, "w")
                f.close()
            dir = dirname(dir)


def copy_runtime(this_project_root: String, dest_root: String) raises:
    """Copies `squirrel_runtime`'s `.mojo` files into
    `dest_root/squirrel_runtime`, so generated files' `from
    squirrel_runtime...` imports resolve at the conversion root -- matching
    `main.zig`'s `copyRuntime`, but as a plain filesystem copy (reading from
    this project's own `src/squirrel_runtime`) rather than Zig's
    `@embedFile`-into-the-binary approach; this tool isn't distributed as a
    standalone binary yet, so there's nothing to embed into."""
    var src_dir = join(this_project_root, "src", "squirrel_runtime")
    var dest_dir = join(dest_root, "squirrel_runtime")
    _copy_tree(src_dir, dest_dir)


def _copy_tree(src_dir: String, dest_dir: String) raises:
    """Recursively copies every file and subdirectory under `src_dir` into
    `dest_dir`, mirroring the structure exactly -- so `squirrel_runtime`'s
    own package layout (e.g. `rel/` being a subpackage of several files,
    not a single flat one) never needs a maintained file list here that
    has to be kept in sync by hand whenever a file's added, removed, or
    renamed. Mirrors `find_rel_files`/`_collect_rel_files`'s own
    `listdir`/`isdir` recursion above, just copying instead of collecting."""
    makedirs(dest_dir, exist_ok=True)
    for entry in listdir(src_dir):
        var src_path = join(src_dir, entry)
        var dest_path = join(dest_dir, entry)
        if isdir(src_path):
            _copy_tree(src_path, dest_path)
        else:
            var f = open(src_path, "r")
            var content = f.read()
            f.close()

            var out = open(dest_path, "w")
            out.write(content)
            out.close()


def convert_directory(this_project_root: String, target_root: String) raises:
    """Walks `target_root` for `.rel` files, writes a generated `.mojo` file
    alongside each one (resolving cross-file relation imports along the
    way), writes the project-wide `sqrrl__Squirrel.mojo`
    (`emit_squirrel_module`), and copies `squirrel_runtime` into
    `target_root`. Mirrors `main.zig`'s `pub fn main`, minus the init/deinit
    aggregator -- `sqrrl__Squirrel` is a plain instance a script obtains via
    `@@init()` and threads by hand, so there's no static lifecycle to
    aggregate."""
    var rel_files = find_rel_files(target_root)
    var discovery = discover_structs(rel_files, target_root)
    var plain_structs = discover_plain_structs(rel_files, target_root)
    check_no_relation_cycles(discovery, plain_structs)
    check_single_init_call(rel_files)
    ensure_init_files(rel_files, target_root)
    var relation_schema = build_relation_schema(discovery)
    var function_returns = build_function_returns(rel_files)
    var unique_fields = build_unique_fields(discovery)
    var ordered_fields = build_ordered_fields(discovery)
    var cross_file_symbols = build_cross_file_symbols(discovery, rel_files, target_root)

    var squirrel_module = emit_squirrel_module(discovery)
    var squirrel_path = join(target_root, "sqrrl__Squirrel.mojo")
    var sf = open(squirrel_path, "w")
    sf.write(squirrel_module)
    sf.close()

    var converted = 0
    for path in rel_files:
        var module_path = module_path_for(path, target_root)
        var generated = emit_file(
            path,
            module_path,
            discovery,
            relation_schema,
            function_returns,
            unique_fields,
            ordered_fields,
            cross_file_symbols,
        )
        var out_path = mojo_output_path(path)

        var f = open(out_path, "w")
        f.write(generated)
        f.close()

        print(path, "->", out_path)
        converted += 1

    copy_runtime(this_project_root, target_root)
    print("Done:", converted, "file(s) converted.")
