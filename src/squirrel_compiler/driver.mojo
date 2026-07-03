from std.os import listdir, makedirs
from std.os.path import dirname, isdir, isfile, join

from squirrel_compiler.parser import Scanner, ParsedStruct
from squirrel_compiler.codegen import sqrrl_prefixed, transform_source


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
        while sc.find_next_struct_decl():
            var parsed = sc.parse_struct()
            module_of[parsed.name] = module_path
            discovered.append(DiscoveredStruct(module_path, parsed^))

    return DiscoveryResult(discovered^, module_of^)


def build_relation_schema(discovery: DiscoveryResult) -> Dict[String, Dict[String, String]]:
    """Struct name -> relation field name -> target struct name, for every
    `@@struct` declared project-wide. `transform_source` needs this to
    resolve a chained field access (`@@alice.@@employee.title`): an
    intermediate hop's target struct can be declared in a different file
    than the script using the chain (same reasoning `emit_file`'s cross-file
    import resolution already relies on), so this can't be derived from a
    single file's own source text."""
    var schema = Dict[String, Dict[String, String]]()
    for ds in discovery.structs:
        var fields = Dict[String, String]()
        for field in ds.parsed.fields:
            if field.type_str.startswith("@@"):
                fields[field.name] = String(
                    field.type_str[byte=2 : field.type_str.byte_length()]
                )
        schema[ds.parsed.name] = fields^
    return schema^


def discover_plain_structs(rel_files: List[String]) raises -> List[ParsedStruct]:
    """Parses every bare `struct Name { ... }` (not `@@struct`) declared in
    any `.rel` file -- these never get a generated Table/State pair, but
    `check_no_relation_cycles` still needs their fields: a plain field
    elsewhere naming one of these is otherwise an invisible way to smuggle
    a `@@`-marked relation back through it, completing a construction cycle
    without ever writing `@@Type` on both ends directly (see notes.md's
    `Other`/`Person` example)."""
    var out = List[ParsedStruct]()
    for path in rel_files:
        var f = open(path, "r")
        var source = f.read()
        f.close()

        var sc = Scanner(source)
        while sc.find_next_plain_struct_decl():
            out.append(sc.parse_plain_struct())

    return out^


def _relation_targets(parsed: ParsedStruct, known_names: Dict[String, Bool]) -> List[String]:
    """A field is a graph edge in one of two ways: `@@`-marked (an actual
    relation field -- always followed, matching prior behavior, since an
    edge to an undeclared target is harmlessly skipped later wherever the
    graph is walked) or a *plain* field whose type text happens to name
    another known struct (`@@` or plain) -- an embed-by-value that can
    still smuggle a cycle back through whatever that struct's own fields
    point at, even though it isn't a relation field itself. An ordinary
    plain field (`String`, `UInt32`, ...) whose type isn't any known
    struct's name is not an edge."""
    var targets = List[String]()
    for field in parsed.fields:
        if field.type_str.startswith("@@"):
            targets.append(String(field.type_str[byte=2 : field.type_str.byte_length()]))
        elif field.type_str in known_names:
            targets.append(field.type_str)
    return targets^


def _find_relation_cycle(
    name: String,
    targets_of: Dict[String, List[String]],
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
    a dead end worth erroring on here."""
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
                    cycle += " -> " + target
                    raise Error("CyclicRelation: " + cycle)
            else:
                _find_relation_cycle(target, targets_of, state, path)
    _ = path.pop(len(path) - 1)
    state[name] = 2


def check_no_relation_cycles(
    discovery: DiscoveryResult, plain_structs: List[ParsedStruct]
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
        known_names[ps.name] = True

    var targets_of = Dict[String, List[String]]()
    var all_names = List[String]()
    for ds in discovery.structs:
        targets_of[ds.parsed.name] = _relation_targets(ds.parsed, known_names)
        all_names.append(ds.parsed.name)
    for ps in plain_structs:
        targets_of[ps.name] = _relation_targets(ps, known_names)
        all_names.append(ps.name)

    var state = Dict[String, Int]()
    for name in all_names:
        if name in state:
            continue
        var path = List[String]()
        _find_relation_cycle(name, targets_of, state, path)


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


def emit_file(
    path: String,
    module_path: String,
    discovery: DiscoveryResult,
    relation_schema: Dict[String, Dict[String, String]],
) raises -> String:
    """Pass 2: emits the generated Mojo source for `path` (a single `.rel`
    file, module `module_path`), prefixed with the runtime imports plus one
    `from <module> import sqrrl__<Target>TableState` line per relation
    field whose target is declared in a *different* file -- without this, a
    relation field crossing files compiles to a reference to a type nothing
    ever imported (confirmed: this failed with "use of unknown declaration"
    on the first real cross-file example) -- and, if this file's script
    body touches `sqrrl__world` at all, a `from sqrrl__Squirrel import
    sqrrl__init, sqrrl__Squirrel` line (see `emit_squirrel_module`).

    The struct-definition and script-body rewriting itself is
    `transform_source`'s job, run once over the whole file -- it handles
    `@@struct` and script markers (`@@Type{...}`, `@@entity.field` (single-
    or multi-hop), `@@init()`, bare `@@`) in a single pass, so a file mixing
    schema and script (the common case) comes out correctly ordered without
    this function needing to know the difference. `relation_schema`
    (`build_relation_schema`, project-wide) is what lets it resolve a
    chained field access whose intermediate hop targets a struct declared
    in a different file."""
    var f = open(path, "r")
    var source = f.read()
    f.close()
    var transformed = transform_source(source, relation_schema)

    var out = String(
        "from squirrel_runtime.entity import Table, EntityHandle,"
        " TableStateLike\n"
    )
    out += "from squirrel_runtime.rel import Rel\n"
    if "sqrrl__world" in transformed:
        out += "from sqrrl__Squirrel import sqrrl__init, sqrrl__Squirrel\n"

    var cross_file_imports = List[String]()
    for ds in discovery.structs:
        if ds.module_path != module_path:
            continue

        for field in ds.parsed.fields:
            if not field.type_str.startswith("@@"):
                continue
            var target = String(field.type_str[byte=2 : field.type_str.byte_length()])
            if target not in discovery.module_of:
                continue
            var target_module = discovery.module_of[target]
            if target_module == module_path:
                continue
            var target_state_name = sqrrl_prefixed(target) + "TableState"
            var line = String(t"from {target_module} import {target_state_name}\n")
            if line not in cross_file_imports:
                cross_file_imports.append(line)

    for line in cross_file_imports:
        out += line

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


def runtime_file_names() -> List[String]:
    return ["__init__.mojo", "id_allocator.mojo", "entity.mojo", "rel.mojo"]


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
    makedirs(dest_dir, exist_ok=True)

    for name in runtime_file_names():
        var f = open(join(src_dir, name), "r")
        var content = f.read()
        f.close()

        var out = open(join(dest_dir, name), "w")
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
    var plain_structs = discover_plain_structs(rel_files)
    check_no_relation_cycles(discovery, plain_structs)
    ensure_init_files(rel_files, target_root)
    var relation_schema = build_relation_schema(discovery)

    var squirrel_module = emit_squirrel_module(discovery)
    var squirrel_path = join(target_root, "sqrrl__Squirrel.mojo")
    var sf = open(squirrel_path, "w")
    sf.write(squirrel_module)
    sf.close()

    var converted = 0
    for path in rel_files:
        var module_path = module_path_for(path, target_root)
        var generated = emit_file(path, module_path, discovery, relation_schema)
        var out_path = mojo_output_path(path)

        var f = open(out_path, "w")
        f.write(generated)
        f.close()

        print(path, "->", out_path)
        converted += 1

    copy_runtime(this_project_root, target_root)
    print("Done:", converted, "file(s) converted.")
