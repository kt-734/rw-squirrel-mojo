from squirrel_compiler.parser import ParsedStruct, is_wrapped_relation_type, relation_target_of
from squirrel_compiler.driver.discovery import DiscoveryResult, DiscoveredStruct
from squirrel_compiler.codegen import is_container_type, container_element_of


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

    `plain_structs` are folded into the same graph as `@@struct`s -- a
    bare `struct` never gets a generated Table/State pair, but a
    `@@struct` field can still embed one by value, and that plain
    struct's own body can itself smuggle a `@@`-marked relation back,
    completing a cycle that never has `@@Type` written on both ends
    directly (see notes.md's `Other`/`Person` example). The caller
    (`convert_directory`) passes both shorthand plain structs
    (`discover_plain_structs`) and hand-written ones
    (`discover_hand_written_plain_structs`) here, merged into one list --
    this function itself doesn't care which grammar a given
    `DiscoveredStruct` came from, only that its `parsed.fields` are
    already in the same `@@Type`/`List[@@Type]`/... shape either way
    (`discover_hand_written_plain_structs` runs a hand-written struct's
    own relation fields through `recover_relation_type_str` for exactly
    this reason). Checked project-wide (not per file), since a relation
    field's target -- or a plain struct's declaration -- can live in a
    different file."""
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


