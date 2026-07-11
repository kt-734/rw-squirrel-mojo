from squirrel_compiler.codegen import sqrrl_prefixed
from squirrel_compiler.driver.discovery import DiscoveryResult, DiscoveredStruct


def _topo_visit_struct(
    name: String,
    discovery: DiscoveryResult,
    relation_targets: Dict[String, List[String]],
    by_name: Dict[String, Int],
    mut visited: Dict[String, Bool],
    mut order: List[DiscoveredStruct],
) raises:
    if name in visited:
        return
    visited[name] = True
    if name in relation_targets:
        for dep in relation_targets[name]:
            _topo_visit_struct(dep, discovery, relation_targets, by_name, visited, order)
    if name in by_name:
        order.append(discovery.structs[by_name[name]].copy())


def _topo_sort_structs(
    discovery: DiscoveryResult, relation_targets: Dict[String, List[String]]
) raises -> List[DiscoveredStruct]:
    """Every `@@struct`, ordered so a struct always comes *after* every
    other struct its own fields relation-target (`relation_targets`,
    `build_relation_targets` -- direct or transitive through an embedded
    plain struct's own relation field, same set `from_json`'s own sibling-
    table parameters are built from). `sqrrl__world_from_json`'s own
    reconstruction (`emit_world_module`) needs this: a relation field
    resolves via `Table.handle_for(id)`, which only works if that id is
    already live in the *target* table, so `sqrrl__World.to_json` has to
    write each struct's entities in this same order for a later
    `sqrrl__world_from_json` to read them back correctly (a single
    forward pass over the JSON text, not a DOM -- see that function's own
    doc comment). Plain DFS postorder rather than Kahn's algorithm: no
    in-degree bookkeeping needed since `check_no_relation_cycles` already
    guarantees this graph is acyclic before this ever runs."""
    var by_name = Dict[String, Int]()
    for i in range(len(discovery.structs)):
        by_name[discovery.structs[i].parsed.name] = i
    var visited = Dict[String, Bool]()
    var order = List[DiscoveredStruct]()
    for ds in discovery.structs:
        _topo_visit_struct(ds.parsed.name, discovery, relation_targets, by_name, visited, order)
    return order^


def emit_world_module(discovery: DiscoveryResult, relation_targets: Dict[String, List[String]]) raises -> String:
    """Emits `sqrrl__world.mojo`'s content: `sqrrl__World`, the single
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
    off this one aggregate rather than a file-local variable.

    A single struct's own `sqrrl__to_json`/`sqrrl__from_json`, and the
    whole-table `sqrrl__all_to_json`/`sqrrl__all_from_json` built on top
    of them, are methods on its own `sqrrl__<Name>Table`
    (`emit_table_json_methods`, in its declaring file) -- nothing here
    duplicates any of that per-struct machinery. What *does* live here is
    the whole-`sqrrl__World` snapshot: `sqrrl__World.to_json(self) ->
    String` (just `"Name":` plus `self.Name.sqrrl__all_to_json()` per
    struct, comma-joined) and the free-function counterpart
    `sqrrl__world_from_json(mut sc: sqrrl__JsonScanner) raises ->
    sqrrl__World` (paralleling `sqrrl__init`'s own factory shape, since
    reconstruction builds a fresh `sqrrl__World` rather than mutating an
    existing one) -- just one `sqrrl__world.Name.sqrrl__all_from_json(...)`
    call per struct, each passed whichever sibling `sqrrl__world.Target`
    tables its own relation fields need (`relation_targets`).

    `_topo_sort_structs` is what makes a single forward scan of the JSON
    text sufficient for `sqrrl__world_from_json`: `to_json` writes each
    struct's own entities only after every struct it relation-targets, so
    by the time `sqrrl__world_from_json` reaches a given struct's array,
    every table `Table.handle_for` (inside `sqrrl__all_from_json` ->
    `sqrrl__from_json_with_id`) might need to reach into has already been
    fully populated -- an unknown/misplaced key still isn't defended
    against, same "trust the input" convention every other generated
    `from_json` already follows. `sqrrl__all_from_json` itself is what
    lands each reconstructed entity back on its *original* id
    (`sqrrl__from_json_with_id` -> `self.sqrrl__create_with_id(id, ...)`,
    not `self.create(...)`) -- a `keepalive`-tagged struct's own table
    retains it automatically the same way `create` does, but a non-tagged
    struct's freshly reconstructed entity has nothing else holding it yet
    (no relation field pointing at it, not `keepalive`-tagged), so it
    needs *somewhere* to live temporarily -- see `TempKeepAlives` below,
    entirely `emit_table_json_methods`'s concern otherwise, not this
    function's.

    `TempKeepAlives` -- one `List[EntityHandle[...]]` field per struct
    that *isn't* `keepalive`-tagged -- is where every such reconstructed
    entity is retained instead, deliberately kept off the individual
    tables' own `keepalive` sets (those are for genuinely `keepalive`-
    tagged structs only, see `emit_table`). `sqrrl__World`'s own
    `sqrrl__temp_keep_alives: Optional[TempKeepAlives]` field holds it --
    `None` for an ordinary `sqrrl__init()`-built world (nothing temporary
    to hold), populated by `sqrrl__world_from_json` right before
    reconstruction begins. `@@end_init_from_json()` (see
    `rewrite_markers`) drops every one of them via
    `sqrrl__finalize_temp_keep_alives()` once a script has re-established
    whatever references it actually needs -- anything with no relation and
    no `keepalive` tag pointing at it dies right then, same as any other
    last handle dropping.

    `sqrrl__finalize_temp_keep_alives` sets the field to `None` inside its
    *own* method body rather than that being inlined at the call site --
    confirmed empirically load-bearing, not stylistic: inlining `sqrrl__world.
    sqrrl__temp_keep_alives = None` directly into the caller's own function
    (whether the `@@`-marked call site or a hand-written equivalent for a
    manually-threaded world) causes every entity `sqrrl__temp_keep_alives`
    was retaining to already read back as gone by the time *earlier*
    statements in that same function are reached -- e.g. a `.for_<unique>`
    lookup partway through the function observing a collapsed table that a
    `.all()` call two lines above it, in the same function, still saw at
    full count. Moving the assignment into its own function avoids it.

    `sqrrl__check_no_leaks`/`__del__` are the other side of `@@{`'s
    own simplification (see `rewrite_markers`'s doc comment): since
    `@@{` builds a real, live `sqrrl__World` immediately rather
    than leaving it uninitialized, `sqrrl__world` is *never* in a state
    where reading it would be unsafe -- there's no `world_available` left
    to track. What *is* worth catching instead: `@@init()`/
    `@@begin_init_from_json(...)` replacing an already-live world (see
    `rewrite_markers`), or `sqrrl__world` itself going out of scope, while
    something *outside* the world still holds a live handle into it --
    `sqrrl__check_no_leaks` is called at both points, `abort`ing with a
    `LeakedEntities` message if any table isn't empty once the world's own
    `keepalive` retention has been dropped -- not `raises`, even at the
    explicit-re-init call site where that would be possible: a leak is
    the same kind of bug regardless of when it's discovered, never a
    legitimate business-logic condition worth making catchable at one
    call site and fatal at the other (`__del__` can't propagate a raise
    at all -- a destructor running as part of an unwind can't itself
    throw). Matches `EntityInner.__del__`'s own established convention
    for a violated invariant."""
    var out = String()
    for ds in discovery.structs:
        var table_name = sqrrl_prefixed(ds.parsed.name) + "Table"
        var state_name = sqrrl_prefixed(ds.parsed.name) + "TableState"
        out += String(t"from {ds.module_path} import {table_name}, {state_name}\n")
    out += "from squirrel_runtime.json import sqrrl__JsonScanner\n"
    out += "from squirrel_runtime.entity import EntityHandle\n"
    out += "from std.os import abort\n"

    out += "\n\n"
    out += "struct TempKeepAlives(Movable):\n"
    var non_keepalive_structs = List[DiscoveredStruct]()
    for ds in discovery.structs:
        if not ds.parsed.is_keepalive:
            non_keepalive_structs.append(ds.copy())
    if len(non_keepalive_structs) == 0:
        out += "    pass\n"
    for ds in non_keepalive_structs:
        var state_name = sqrrl_prefixed(ds.parsed.name) + "TableState"
        out += String(t"    var {ds.parsed.name}: List[EntityHandle[{state_name}]]\n")
    out += "\n"
    out += "    def __init__(out self):\n"
    if len(non_keepalive_structs) == 0:
        out += "        pass\n"
    for ds in non_keepalive_structs:
        var state_name = sqrrl_prefixed(ds.parsed.name) + "TableState"
        out += String(t"        self.{ds.parsed.name} = List[EntityHandle[{state_name}]]()\n")

    out += "\n\n"
    out += "struct sqrrl__World(Movable):\n"
    for ds in discovery.structs:
        var table_name = sqrrl_prefixed(ds.parsed.name) + "Table"
        out += String(t"    var {ds.parsed.name}: {table_name}\n")
    out += "    var sqrrl__temp_keep_alives: Optional[TempKeepAlives]\n"
    out += "\n"
    out += "    def __init__(out self):\n"
    for ds in discovery.structs:
        var table_name = sqrrl_prefixed(ds.parsed.name) + "Table"
        out += String(t"        self.{ds.parsed.name} = {table_name}()\n")
    out += "        self.sqrrl__temp_keep_alives = None\n"

    var ordered = _topo_sort_structs(discovery, relation_targets)

    out += "\n"
    out += "    def sqrrl__finalize_temp_keep_alives(mut self):\n"
    out += "        self.sqrrl__temp_keep_alives = None\n"

    # `sqrrl__check_no_leaks` -- called both explicitly, right before
    # `@@init()`/`@@begin_init_from_json(...)` replaces an already-live
    # `sqrrl__world` (see `rewrite_markers`), and from `__del__` below, when
    # `sqrrl__world` itself is dropped at the end of whatever function
    # declared it. Either way, the world is about to stop being *this*
    # world -- `keepalive`-tagged tables' own retention is the world's own
    # doing, so it's dropped first (same reasoning as `TempKeepAlives`:
    # internal retention the world controls is fair to release when the
    # world itself is going away); whatever's still alive in any table
    # after that is being held from *outside* the world -- a stray local
    # var, a list some other code built out of its handles, ... -- which
    # is exactly the "leak" worth surfacing, not a memory-safety issue
    # (`ArcPointer` keeps it alive correctly regardless) but a logical one.
    #
    # `abort`s rather than raises -- deliberately *not* `raises`/
    # `Error(...)`, even at the explicit-re-init call site where that would
    # be possible. A leak is the same kind of bug regardless of when it's
    # discovered (forgetting to drop a reference before discarding the
    # world), never a legitimate business-logic condition a script would
    # want to branch on the way `UniqueConstraintViolation` is -- treating
    # it as catchable at one call site and fatal at the other (`__del__`
    # can't propagate a raise at all -- a destructor running as part of an
    # unwind can't itself throw) would be an arbitrary inconsistency.
    # Matches `EntityInner.__del__`'s own established convention: abort on
    # a violated invariant instead of raising. Also means `@@init()` alone
    # no longer forces its enclosing function to be `raises` -- this was
    # its only raising call.
    out += "\n"
    out += "    def sqrrl__check_no_leaks(mut self):\n"
    if len(discovery.structs) == 0:
        out += "        pass\n"
    else:
        for ds in discovery.structs:
            if ds.parsed.is_keepalive:
                out += String(t"        self.{ds.parsed.name}.sqrrl__clear_keepalive()\n")
        for ds in discovery.structs:
            var count_var = "sqrrl__leaked_" + ds.parsed.name
            out += String(t"        var {count_var} = len(self.{ds.parsed.name}.all())\n")
            out += String(t"        if {count_var} > 0:\n")
            out += String(
                t'            abort("LeakedEntities: \'{ds.parsed.name}\' still has "'
                t' + String({count_var}) + " live entities outside sqrrl__world -- something'
                t' external still references them")\n'
            )

    out += "\n"
    out += "    def __del__(deinit self):\n"
    out += "        self.sqrrl__check_no_leaks()\n"

    out += "\n"
    out += "    def to_json(self) -> String:\n"
    out += '        var out = String("{")\n'
    var first = True
    for ds in ordered:
        if not first:
            out += '        out += ","\n'
        first = False
        out += String(
            t'        out += "\\"{ds.parsed.name}\\":" + self.{ds.parsed.name}.sqrrl__all_to_json()\n'
        )
    out += '        out += "}"\n'
    out += "        return out^\n"

    out += "\n\n"
    out += "def sqrrl__init() -> sqrrl__World:\n"
    out += "    return sqrrl__World()\n"

    out += "\n\n"
    out += "def sqrrl__world_from_json(mut sc: sqrrl__JsonScanner) raises -> sqrrl__World:\n"
    out += "    var sqrrl__world = sqrrl__World()\n"
    out += "    sqrrl__world.sqrrl__temp_keep_alives = Optional[TempKeepAlives](TempKeepAlives())\n"
    out += '    sc.expect_byte(UInt8(ord("{")))\n'
    if len(discovery.structs) == 0:
        out += '    _ = sc.try_consume_byte(UInt8(ord("}")))\n'
    else:
        out += '    if not sc.try_consume_byte(UInt8(ord("}"))):\n'
        out += "        while True:\n"
        out += "            var sqrrl__key = sc.parse_json_string()\n"
        out += '            sc.expect_byte(UInt8(ord(":")))\n'
        var first_key = True
        for ds in discovery.structs:
            var keyword = "if" if first_key else "elif"
            first_key = False
            out += String(t'            {keyword} sqrrl__key == "{ds.parsed.name}":\n')
            var targets = relation_targets[ds.parsed.name].copy() if ds.parsed.name in relation_targets else List[String]()
            var injected = String()
            for t in targets:
                injected += String(t"sqrrl__world.{t}, ")
            if ds.parsed.is_keepalive:
                out += String(
                    t"                sqrrl__world.{ds.parsed.name}.sqrrl__all_from_json({injected}sc)\n"
                )
            else:
                out += String(
                    t"                sqrrl__world.{ds.parsed.name}.sqrrl__all_from_json({injected}"
                    t"sqrrl__world.sqrrl__temp_keep_alives.value().{ds.parsed.name}, sc)\n"
                )
        out += '            if sc.try_consume_byte(UInt8(ord(","))):\n'
        out += "                continue\n"
        out += '            sc.expect_byte(UInt8(ord("}")))\n'
        out += "            break\n"
    out += "    return sqrrl__world^\n"

    # `sqrrl__init_from_json` -- `@@begin_init_from_json(json)`'s own
    # call target (see `rewrite_markers`), taking the JSON `String`
    # directly rather than a `sqrrl__JsonScanner` the caller has to build
    # itself. Not just convenience: `@@begin_init_from_json(...)` may now
    # be called more than once in the same straight-line function (any
    # number of times after `@@{`), and inlining `var sqrrl__scanner
    # = sqrrl__JsonScanner(...)` at each call site the way a single call
    # could get away with would redeclare that same name a second time --
    # a real Mojo error, not just a style concern. Wrapping the scanner
    # construction in its own function sidesteps that entirely: each call
    # gets its own fresh local, scoped to this function, never the
    # caller's.
    out += "\n\n"
    out += "def sqrrl__init_from_json(json: String) raises -> sqrrl__World:\n"
    out += "    var sqrrl__scanner = sqrrl__JsonScanner(json)\n"
    out += "    return sqrrl__world_from_json(sqrrl__scanner)\n"
    return out


