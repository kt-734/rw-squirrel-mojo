from squirrel_compiler.parser import (
    Scanner,
    Field,
    MarkerKind,
    ParsedStruct,
    ConstructField,
    Construct,
    FieldAccess,
    NameRef,
    EntityParam,
    is_unmarked_container_declaration,
    preceding_unmarked_ident,
    PrecedingIdent,
)
from squirrel_compiler.codegen.helpers import (
    sqrrl_prefixed,
    encode_container_type,
    is_container_type,
    container_wrapper_of,
    container_element_of,
    _is_ordered_field_query,
    _resolve_relation_field_target,
)
from squirrel_compiler.codegen.table import emit_table
from squirrel_compiler.codegen.plain_struct import emit_plain_struct
from squirrel_compiler.codegen.script_utils import (
    is_in_def_signature,
    is_in_import_statement,
    crosses_top_level_def,
    is_unmarked_var_target,
    enforce_entity_binding,
    build_create_call,
    indent_of,
)


def rewrite_markers(
    source: String,
    relation_schema: Dict[String, Dict[String, String]],
    function_returns: Dict[String, String],
    unique_fields: Dict[String, List[String]],
    ordered_fields: Dict[String, List[String]],
    plain_struct_fields: Dict[String, List[Field]],
    relation_targets: Dict[String, List[String]],
    mut entity_to_type: Dict[String, String],
    mut world_declared: Bool,
    multi_fields: Dict[String, List[String]] = Dict[String, List[String]](),
) raises -> String:
    """Rewrites every `@@`-marked construct in `source` to plain Mojo,
    leaving everything else byte-for-byte untouched -- mirrors the Zig
    parser's `transformSquirrel`, minus the incref/auto-defer machinery it
    needed (Mojo's own ASAP destruction already handles that, see
    `Scanner.find_next_marker`'s doc comment).

    `entity_to_type`/`world_declared` are `mut` rather than owned locals
    here because this is *shared*, recursively-invokable core:
    `transform_source` calls it once for a whole file, starting both fresh,
    and `build_create_call` calls it again for each construct field's own
    value text (`Address(@@dept.name)`, `@@Employee { ... }`, `@@bob`, ...),
    passing the *same* two along rather than fresh ones -- a field's value
    can reference an entity the enclosing function already constructed, or
    need `sqrrl__world` the enclosing function already has, so a nested
    fragment has to see exactly what's already been established, not start
    over. Neither a top-level construct nor one nested inside a field's
    value binds a name of its own (only a `var @@name = ...` declaration
    does, tracked below via `pending_decl`), so recursing doesn't need its
    own copy of either -- but Mojo requires `mut` regardless, to let
    mutations from the (rare) nested `@@init()`/entity-declaration case
    flow back to the caller.

    `relation_schema` (`driver.build_relation_schema`) is struct name ->
    relation field name -> target struct name, project-wide -- needed to
    resolve a chained field access (`@@alice.@@employee.@@boss.title`):
    starting from `entity_to_type[fa.entity]`, each hop in
    `FieldAccess.hops` looks up its target type in this schema (an
    intermediate hop can point at a struct declared in a different file, so
    this can't be resolved from local knowledge of `source` alone) before
    moving on to the next one, exactly mirroring how `emit_file` already
    needed project-wide struct info to resolve cross-file relation *field
    types* -- this is the same resolution, just applied at a script's
    *use* site instead of a struct's declaration site.

    `function_returns` (`driver.build_function_returns`) is function name
    -> the `@@Type` it returns, project-wide -- lets a call site
    (`@@funcName(...)`, `MarkerKind.WORLD_FUNC`) infer `entity_to_type`
    automatically when its result is bound to a fresh `@@`-marked variable
    (`var @@x = @@make_employer();`, no explicit `: @@Type` needed), and
    reject binding it to an unmarked one instead (`var x =
    @@make_employer();`) -- the same call used as a sub-expression/argument
    rather than a fresh declaration is left alone, since there's no
    variable there to mark in the first place.

    `@@struct` becomes a generated table pair (`emit_table`), same as
    before. But table *instances* now all live in one place: the generated,
    project-wide `sqrrl__World` (see `driver.emit_world_module`) --
    there's no per-file, per-type table variable anymore. A script brings
    it into scope explicitly, once per function that needs it, starting
    with `@@{`, which becomes `var sqrrl__world = sqrrl__init()`
    -- a real, live, empty world immediately, not an uninitialized
    declaration. That's what lets `@@init()`/`@@start_init_from_json(...)`
    be called any number of times afterward, in any control-flow shape
    (including conditionally, `if .../else @@init();`), each one just
    replacing whatever `sqrrl__world` currently holds: there's no
    "uninitialized on some path" state for Mojo's own definite-
    initialization checking to need to rule out, since `@@{`
    already guaranteed a valid value up front. `@@init()` becomes
    `sqrrl__world.sqrrl__check_no_leaks(); sqrrl__world = sqrrl__init()`,
    `@@start_init_from_json(json)` becomes
    `sqrrl__world.sqrrl__check_no_leaks(); sqrrl__world =
    sqrrl__init_from_json(json)` (reload instead of a fresh, empty world --
    `json`'s own text is spliced in verbatim, unparsed, same as any other
    construct's field value). `sqrrl__init_from_json` (see
    `driver.emit_world_module`) is its own generated function, not inlined
    here, specifically because `@@start_init_from_json(...)` can now be
    called more than once in the same straight-line function -- inlining
    the `var sqrrl__scanner = sqrrl__JsonScanner(json)` a single call site
    could get away with would redeclare that same local a second time.
    `sqrrl__check_no_leaks` (see
    `driver.emit_world_module`) verifies the world *being replaced* is
    actually empty (`abort`ing with a `LeakedEntities` message if not,
    deliberately not `raises` -- see its own doc comment) before either
    one proceeds -- harmless the very first time this runs, since
    `@@{`'s own world starts out empty by construction, so there's
    no special-casing needed for "is this the first call." Both `@@init()`/
    `@@start_init_from_json(...)` are bare assignments, never a fresh
    `var`, since `@@{` already declared the name; using either one
    before `@@{` has run is rejected (see their own branches
    below). Or a function whose own name
    is marked (`@@name(`, `MarkerKind.WORLD_FUNC`) gets
    `sqrrl__world` auto-inserted as its first parameter (a definition) or
    first argument (a call site), silently -- `def @@make_department(a:
    Int)` becomes `def sqrrl__make_department(mut sqrrl__world:
    sqrrl__World, a: Int)`, and `@@make_department(x)` becomes
    `sqrrl__make_department(sqrrl__world, x)`. Marking the *name* rather
    than threading a separate `@@` parameter/argument means the function is
    unambiguously "one that needs world" at both its definition and every
    call site, with nothing extra to keep in sync between them. `@@TypeName
    { ... }` becomes `sqrrl__world.TypeName.create(...)`, and `var @@alice =
    @@TypeName { ... };` additionally records that `alice` was constructed
    as a `TypeName`, so a later `@@alice.field` read/write knows which
    table to route through: `sqrrl__world.TypeName.get_field(sqrrl__alice)`
    / `.set_field(sqrrl__alice, expr)`. A chain
    (`@@alice.@@employee.title`) nests one `get_<hop>(...)` call per
    intermediate relation inside the next, all as a single expression --
    `sqrrl__world.Employee.get_title(sqrrl__world.Person.get_employee(
    sqrrl__alice))` -- rather than splicing intermediate temp-variable
    declarations, so it stays usable inline (`print(@@alice.@@employee.title)`)
    the same way a plain single-hop access already is.

    A function can also *return* an entity: `-> @@Department:` becomes
    `-> EntityHandle[sqrrl__DepartmentTableState]:`. Binding that at a call
    site needs the explicit `@@name: @@Type` form too
    (`var @@dept: @@Department = @@make_department();`), not the bare
    `var @@dept = ...` construct-inferring form -- there's no `@@Type{...}`
    or bare `@@name` on the right for `entity_to_type` to infer the type
    from (it's a function call), so the type has to be stated directly
    instead. The same `@@name: @@Type` shape used for entity parameters
    handles this uniformly, just with `=` following instead of a
    signature's `,`/`)`.

    `entity_to_type` and whether `sqrrl__world` has been declared
    (`world_declared`) are both function-scoped, reset at every top-level
    `def` (`crosses_top_level_def`) -- Mojo has no mutable global/static
    state (see `Table`'s doc comment in `entity.mojo`), so neither an
    entity variable nor `sqrrl__world` itself outlives the function it was
    bound in. There's no separate "is `sqrrl__world` initialized and
    usable yet" flag the way there used to be (`world_available`) --
    `@@{` makes `sqrrl__world` a real, live value immediately (see
    above), so once it's declared, it's *always* safe to read; the only
    thing left to guard against is `@@Type{...}`/`@@name(`/
    `@@finalize_init_from_json()`/`@@init()`/`@@start_init_from_json(...)`
    appearing before `@@{` has run at all in this function, which
    `world_declared` alone is enough to catch. Referencing an entity that
    was never constructed via `@@Type{...}` in this same function, or
    using `@@Type{...}`/`@@entity.field`/a bare `@@` before this function
    has `sqrrl__world` declared, raises a clear error rather than emitting
    code that fails to compile downstream."""
    var sc = Scanner(source)
    var out = String()
    var pos = 0

    var pending_decl: Optional[String] = None
    var pending_for_loop_decl: Optional[String] = None
    # Set by `MarkerKind.DECLARE` (`@@{`) and cleared by `MarkerKind.
    # UNDECLARE` (`@@}`) -- tracks whether a `try:` is currently open in
    # this function, so a missing `@@}` can be caught (at the next top-level
    # `def` or end of file) instead of silently leaving `sqrrl__world`
    # declared. Unlike the two markers' first implementation, there's no
    # byte-offset/re-indentation bookkeeping needed here anymore: `@@{`/
    # `@@}` don't touch the indentation of anything between them -- the
    # script itself is expected to already be written one level deeper in
    # between, exactly as a hand-written `try:`/`finally:` would be.
    var declare_open = False

    while True:
        var kind = sc.find_next_marker()
        if kind == MarkerKind.NONE:
            break
        var marker_start = sc.pos
        var between = String(source[byte = pos : marker_start])
        out += between
        if ";" in between:
            # The declaration statement that set `pending_decl` (if any)
            # already ended without a construct following it -- don't let
            # it leak onto some unrelated, later construct.
            pending_decl = None
        if ":" in between:
            # Same idea for `pending_for_loop_decl`: the `for @@name in
            # ...:` header it came from already ended (its own trailing
            # `:`) without the iterated expression turning out to be a
            # recognized container call -- don't let it leak into the loop
            # body's own, unrelated markers.
            pending_for_loop_decl = None
        if crosses_top_level_def(between):
            if declare_open:
                raise sc.err(
                    "InvalidSquirrelSyntax: '@@{' needs a matching '@@}'"
                    " before this function ends"
                )
            entity_to_type = Dict[String, String]()
            world_declared = False
            declare_open = False

        if kind == MarkerKind.STRUCT:
            var parsed = sc.parse_struct()
            out += emit_table(parsed, plain_struct_fields)
            pending_decl = None
            pending_for_loop_decl = None

        elif kind == MarkerKind.PLAIN_STRUCT:
            var parsed = sc.parse_plain_struct()
            out += emit_plain_struct(parsed)
            pending_decl = None
            pending_for_loop_decl = None

        elif kind == MarkerKind.DECLARE:
            sc.parse_declare()
            if world_declared:
                raise sc.err(
                    "InvalidSquirrelSyntax: '@@{' already opened in"
                    " this function -- 'sqrrl__world' only needs declaring"
                    " once"
                )
            # Opens a `try:` right here, closed by `MarkerKind.UNDECLARE`'s
            # (`@@}`'s) own `finally:`. Unlike this pair's first
            # implementation, nothing between `@@{` and `@@}` is
            # re-indented -- the script is expected to already be written
            # one level deeper there, exactly like a hand-written
            # `try:`/`finally:` body would be. This exists specifically
            # because `sqrrl__World`'s `__del__` (invoked implicitly at
            # ordinary end-of-scope) has been observed to run before a
            # same-scope temporary's own destructor -- a Mojo
            # destructor-ordering bug, not a bug in generated code (see
            # `mojo-del-destructor-ordering-bug.md`) -- so `sqrrl__world`
            # needing an explicit `finally:`-based check, rather than
            # relying on `__del__` alone, is the workaround. `__del__`
            # itself is left in place regardless, as a backstop for
            # anything that manages to skip `@@}` anyway (a `raise`
            # propagating past the `try:`, say).
            var declare_indent = indent_of(source, marker_start)
            out += "var sqrrl__world = sqrrl__init()\n" + declare_indent + "try:"
            declare_open = True
            world_declared = True
            pending_decl = None
            pending_for_loop_decl = None

        elif kind == MarkerKind.UNDECLARE:
            sc.parse_undeclare()
            if not declare_open:
                raise sc.err(
                    "InvalidSquirrelSyntax: '@@}' needs a matching '@@{'"
                    " earlier in this function"
                )
            # `@@}` is replaced in place, on the same line as whatever
            # indentation `between` already copied into `out` -- only the
            # *second* line (`sqrrl__check_no_leaks()`) is a fresh line that
            # needs its own indent prepended explicitly, same reasoning as
            # `MarkerKind.DECLARE`'s own `try:` line above.
            var undeclare_indent = indent_of(source, marker_start)
            out += "finally:\n" + undeclare_indent + "    sqrrl__world.sqrrl__check_no_leaks()"
            world_declared = False
            declare_open = False
            pending_decl = None
            pending_for_loop_decl = None

        elif kind == MarkerKind.INIT:
            sc.parse_init()
            if not world_declared:
                raise sc.err(
                    "InvalidSquirrelSyntax: '@@init()' needs '@@{'"
                    " called first in this function"
                )
            # `sqrrl__check_no_leaks` verifies whatever `sqrrl__world`
            # currently holds is empty before it's replaced -- harmless the
            # very first time this runs (right after `@@{`, still
            # empty by construction), so every occurrence gets the same
            # codegen, first or not (see `driver.emit_world_module`).
            out += "sqrrl__world.sqrrl__check_no_leaks(); sqrrl__world = sqrrl__init()"
            pending_decl = None
            pending_for_loop_decl = None

        elif kind == MarkerKind.START_INIT_FROM_JSON:
            var json_expr = sc.parse_start_init_from_json()
            if not world_declared:
                raise sc.err(
                    "InvalidSquirrelSyntax: '@@start_init_from_json(...)'"
                    " needs '@@{' called first in this function"
                )
            # `sqrrl__init_from_json` (see `driver.emit_world_module`) wraps
            # building a `sqrrl__JsonScanner` and calling
            # `sqrrl__world_from_json` in its own function, rather than
            # inlining `var sqrrl__scanner = sqrrl__JsonScanner(...)` here
            # -- `@@start_init_from_json(...)` may now be called more than
            # once in the same straight-line function (any number of times
            # after `@@{`), and inlining it would redeclare that
            # same local a second time, a genuine Mojo error, not just a
            # style concern. Same `sqrrl__check_no_leaks()` call as
            # `@@init()`, and for the same reason.
            out += String(
                t"sqrrl__world.sqrrl__check_no_leaks(); sqrrl__world ="
                t" sqrrl__init_from_json({json_expr})"
            )
            pending_decl = None
            pending_for_loop_decl = None

        elif kind == MarkerKind.INIT_FROM_JSON:
            var json_expr = sc.parse_init_from_json()
            if not world_declared:
                raise sc.err(
                    "InvalidSquirrelSyntax: '@@init_from_json(...)' needs"
                    " '@@{' called first in this function"
                )
            # `@@start_init_from_json(...)` immediately followed by
            # `@@finalize_init_from_json()`, for the common case where the
            # caller doesn't need to grab anything from the reload beyond
            # what real relation fields/`keepalive` tags already keep
            # alive on their own -- finalizing isn't an optional cleanup
            # step (see `FINALIZE_INIT_FROM_JSON` below): skip it and the
            # very next leak check (the next `@@init()`-family call, or
            # `sqrrl__world.__del__` if the function just returns) aborts,
            # since every non-`keepalive` entity `@@start_init_from_json`
            # retained is still "live" as far as `Table.all()` is
            # concerned until `sqrrl__finalize_temp_keep_alives()` drops
            # them. This marker exists so that's not a footgun you can
            # forget to reach for.
            out += String(
                t"sqrrl__world.sqrrl__check_no_leaks(); sqrrl__world ="
                t" sqrrl__init_from_json({json_expr});"
                t" sqrrl__world.sqrrl__finalize_temp_keep_alives()"
            )
            pending_decl = None
            pending_for_loop_decl = None

        elif kind == MarkerKind.FINALIZE_INIT_FROM_JSON:
            sc.parse_finalize_init_from_json()
            if not world_declared:
                raise sc.err(
                    "InvalidSquirrelSyntax: '@@finalize_init_from_json()' needs"
                    " 'sqrrl__world' -- open @@{ then @@init() or"
                    " @@start_init_from_json(...) first"
                )
            # `sqrrl__world.sqrrl__finalize_temp_keep_alives()`, not an
            # inlined `sqrrl__world.sqrrl__temp_keep_alives = None` here --
            # see `driver.emit_world_module`'s doc comment for the
            # (confirmed) reason inlining it directly into the caller's own
            # function silently corrupts *earlier* statements in that same
            # function.
            out += "sqrrl__world.sqrrl__finalize_temp_keep_alives()"
            pending_decl = None
            pending_for_loop_decl = None

        elif kind == MarkerKind.WORLD_FUNC:
            var func_name = sc.parse_world_func()
            sc.skip_whitespace()
            var has_more_args = sc.peek() != UInt8(ord(")"))
            if is_in_def_signature(source, marker_start):
                out += String(
                    t"{sqrrl_prefixed(func_name)}(mut sqrrl__world: sqrrl__World"
                )
                world_declared = True
            else:
                if not world_declared:
                    raise sc.err(
                        "InvalidSquirrelSyntax: calling '@@"
                        + func_name
                        + "(...)' needs 'sqrrl__world' -- open @@{"
                        " or mark this function's own name with '@@' too"
                    )
                out += String(t"{sqrrl_prefixed(func_name)}(sqrrl__world")
                if func_name in function_returns:
                    enforce_entity_binding(
                        source, marker_start, pending_decl, entity_to_type, function_returns[func_name], func_name + "()"
                    )
                    if pending_for_loop_decl and is_container_type(function_returns[func_name]):
                        # `for @@name in @@some_func():` -- same element-type
                        # binding the table-call branch does for
                        # `for_<field>`/`all()`, just for a `@@`-marked
                        # function's own container return type instead.
                        entity_to_type[pending_for_loop_decl.value()] = container_element_of(function_returns[func_name])
            if has_more_args:
                out += ", "
            pending_decl = None
            pending_for_loop_decl = None

        elif kind == MarkerKind.ENTITY_PARAM:
            var ep = sc.parse_entity_param()
            var is_param = is_in_def_signature(source, marker_start)
            var is_var_decl = False
            if not is_param:
                var save = sc.pos
                sc.skip_trivia()
                is_var_decl = sc.peek() == UInt8(ord("=")) and sc.peek_at(1) != UInt8(ord("="))
                sc.pos = save
            if not is_param and not is_var_decl:
                raise sc.err(
                    "InvalidSquirrelSyntax: '@@"
                    + ep.name
                    + ": @@"
                    + ep.type_name
                    + "' is only valid as a function parameter or a"
                    " variable declaration ('var @@"
                    + ep.name
                    + ": @@"
                    + ep.type_name
                    + " = expr;') -- did you mean '@@"
                    + ep.name
                    + " = @@"
                    + ep.type_name
                    + "{...}' to construct one directly instead?"
                )
            if ep.wrapper:
                out += String(
                    t"{sqrrl_prefixed(ep.name)}: {ep.wrapper.value()}[EntityHandle[{sqrrl_prefixed(ep.type_name)}TableState]]"
                )
                entity_to_type[ep.name] = encode_container_type(ep.wrapper.value(), ep.type_name)
            else:
                out += String(
                    t"{sqrrl_prefixed(ep.name)}: EntityHandle[{sqrrl_prefixed(ep.type_name)}TableState]"
                )
                entity_to_type[ep.name] = ep.type_name
            pending_decl = None
            pending_for_loop_decl = None

        elif kind == MarkerKind.PLAIN_VAR_DECL:
            # `var name: TypeName` -- unmarked on both sides, the plain-
            # struct-typed counterpart to `ENTITY_PARAM`'s own `@@name:
            # @@Type`. Only actually registers anything if `TypeName` is a
            # known plain struct; an ordinary `var x: Int = ...` (or any
            # other non-plain-struct type) matches this marker's syntax
            # too, but is left alone -- `entity_to_type` stays untouched,
            # and the text is emitted back byte-for-byte either way, since
            # neither side ever needs rewriting (no `@@` to strip, no
            # `EntityHandle[...]` to wrap in).
            var pv = sc.parse_plain_var_decl()
            if pv.type_name in plain_struct_fields:
                entity_to_type[pv.name] = pv.type_name
            out += String(t"var {pv.name}: {pv.type_name}")
            pending_decl = None
            pending_for_loop_decl = None

        elif kind == MarkerKind.RETURN_TYPE:
            # A container return type's own `List[`/`]` are never consumed
            # by this marker (they sit outside it, already copied through
            # as ordinary text) -- both the bare `-> @@Type:` and container
            # `-> List[@@Type]:` forms emit the identical `EntityHandle
            # [...]` text here; see `NameRef`'s doc comment. But this same
            # `Ident[@@Type]` shape is also how an *unmarked* `name:
            # List[@@Type]` declaration looks by the time the scanner
            # reaches the inner `@@Type` (a marked `@@name: List[@@Type]`
            # would already have been claimed as `ENTITY_PARAM` before
            # getting here) -- reject that the same way `parse_fields`
            # already rejects it inside a `@@struct` body, rather than
            # silently rewriting the type and leaving the name inconsistent.
            if is_unmarked_container_declaration(source, marker_start):
                raise sc.err(
                    "InvalidSquirrelSyntax: a 'name: Container[@@Type]'"
                    " declaration needs its own name '@@'-marked too"
                    " ('@@name: Container[@@Type]', not 'name:"
                    " Container[@@Type]') -- same as a relation field"
                    " inside a '@@struct'"
                )
            var nr = sc.parse_name_ref()
            out += String(t"EntityHandle[{sqrrl_prefixed(nr.name)}TableState]")
            pending_decl = None
            pending_for_loop_decl = None

        elif kind == MarkerKind.CONSTRUCT:
            var c = sc.parse_construct()
            if not world_declared:
                raise sc.err(
                    "InvalidSquirrelSyntax: constructing '@@"
                    + c.type_name
                    + "' needs 'sqrrl__world' -- open @@{ or add"
                    " '@@' to this function's own parameters first"
                )
            out += build_create_call(
                source,
                marker_start,
                c.type_name,
                c.fields,
                relation_schema,
                function_returns,
                unique_fields,
                ordered_fields,
                plain_struct_fields,
                relation_targets,
                entity_to_type,
                world_declared,
                multi_fields,
            )
            if pending_decl:
                entity_to_type[pending_decl.value()] = c.type_name
            pending_decl = None
            pending_for_loop_decl = None

        elif kind == MarkerKind.FOR_ENTITY_LOOP:
            # `for @@name in <expr>:` -- consumes through `in`, leaving
            # whatever follows (the iterated expression) for the very next
            # marker to handle; that marker's own classification (currently
            # only a table-level call's `is_list_returning` case, e.g.
            # `@@Type.for_<field>(...)`/`@@Type.all()`) is what actually
            # registers `name`'s element type, once it knows what the
            # container's element type even is.
            var name = sc.parse_for_entity_loop()
            out += String(t"{sqrrl_prefixed(name)} in ")
            pending_decl = None
            pending_for_loop_decl = Optional[String](name)

        elif kind == MarkerKind.FIELD_ACCESS:
            var fa = sc.parse_field_access()
            # `note.@@author` -- `find_next_marker` only ever recognizes a
            # marker starting at literal `@@` text, so the parse above
            # already ran as if `@@author` were the whole reference,
            # `note.` having been copied through as ordinary text (part of
            # `between`) before this branch ever runs. If `note` turns out
            # to be a tracked variable (an `@@`-marked one, or a plain
            # struct one from `PLAIN_VAR_DECL`) and `author` *isn't*
            # already tracked on its own, reinterpret: `note` becomes the
            # real entity, `author` becomes its first hop -- trimming the
            # already-appended "note." back out of `out` (using the exact
            # source span `preceding_unmarked_ident` found, not a guessed
            # length, so surrounding whitespace round-trips correctly).
            # Falls through to the ordinary, unchanged path otherwise --
            # `@@alice.@@job.title` never reaches here at all (the first
            # `@@alice` marker's own hop-loop already consumes the whole
            # chain in one `parse_field_access` call), and an untracked
            # prefix (or one that's ALSO independently tracked already)
            # just means nothing to reinterpret.
            if fa.field != "" and not fa.is_call and fa.entity not in entity_to_type:
                var implicit_prefix = preceding_unmarked_ident(source, marker_start)
                if implicit_prefix and implicit_prefix.value().name in entity_to_type:
                    var prefix = implicit_prefix.value().copy()
                    var trim_count = marker_start - prefix.start
                    out = String(out[byte = 0 : out.byte_length() - trim_count])
                    if fa.index_expr and len(fa.hops) == 0:
                        # `team.@@members[1].name` -- the original parse
                        # (starting at `@@members`, since `team.` was
                        # unmarked prefix text) read `index_expr` as
                        # indexing `members` itself (its own entity),
                        # exactly like a tracked container variable would
                        # (`@@matches[0].name`). After reshaping, `members`
                        # becomes the *field* being read off `team`, not a
                        # hop -- so the index moves to `post_index_expr`
                        # and the original terminal `field` becomes
                        # `post_field`, the same one-level-deep shape a
                        # direct `@@dept.@@employees[0].name` already
                        # produces on its own. Only supported for a read
                        # (matching `post_index_expr`'s own read-only
                        # scope) -- a write through this shape raises
                        # rather than silently mishandling it.
                        if fa.write_value:
                            raise sc.err(
                                "InvalidSquirrelSyntax: writing through an"
                                " indexed, implicitly-prefixed field isn't"
                                " supported ('"
                                + prefix.name
                                + ".@@"
                                + fa.entity
                                + "[...]."
                                + fa.field
                                + " = ...')"
                            )
                        fa = FieldAccess(
                            entity=prefix.name,
                            hops=List[String](),
                            field=fa.entity,
                            field_marked=True,
                            write_value=None,
                            is_call=False,
                            index_expr=None,
                            entity_unmarked=True,
                            post_index_expr=fa.index_expr,
                            post_field=Optional[String](fa.field),
                            post_field_marked=fa.field_marked,
                        )
                        pending_decl = None
                        pending_for_loop_decl = None
                    else:
                        var new_hops = List[String]()
                        new_hops.append(fa.entity)
                        for h in fa.hops:
                            new_hops.append(h)
                        fa = FieldAccess(
                            entity=prefix.name,
                            hops=new_hops^,
                            field=fa.field,
                            field_marked=fa.field_marked,
                            write_value=fa.write_value,
                            is_call=fa.is_call,
                            index_expr=fa.index_expr,
                            entity_unmarked=True,
                            post_index_expr=fa.post_index_expr,
                        post_field=fa.post_field,
                        post_field_marked=fa.post_field_marked,
                    )
            if fa.field == "" and fa.index_expr:
                # A bare indexed reference, `@@matches[0]`, used as a value
                # in its own right (an argument, a plain `var x = ...` RHS,
                # ...) rather than the start of a `.field` chain. Never
                # enforced-marked the way create/for_<field>/a relation
                # get_<field> are -- extracting a raw, untracked
                # `EntityHandle` this way is deliberately as friction-free
                # as any other escaped value (usable via `@@Type.method
                # (value)` regardless), not something that needs `@@`
                # marking to be useful. If it *is* marked, though,
                # `entity_to_type` still gets the container's element type,
                # for free -- no reason not to track it when asked to.
                if fa.entity not in entity_to_type:
                    raise sc.err(
                        "InvalidSquirrelSyntax: '"
                        + fa.entity
                        + "' was never constructed via @@Type{...} in this"
                        " function -- can't tell which table its fields live in"
                    )
                var declared_type = entity_to_type[fa.entity]
                if not is_container_type(declared_type):
                    raise sc.err(
                        "InvalidSquirrelSyntax: '@@" + fa.entity + "' isn't a container -- can't index into it"
                    )
                var rewritten_index = rewrite_markers(
                    fa.index_expr.value(),
                    relation_schema,
                    function_returns,
                    unique_fields,
                    ordered_fields,
                    plain_struct_fields,
                    relation_targets,
                    entity_to_type,
                    world_declared,
                )
                out += String(t"{sqrrl_prefixed(fa.entity)}[{rewritten_index}]")
                if pending_decl:
                    entity_to_type[pending_decl.value()] = container_element_of(declared_type)
                pending_decl = None
                pending_for_loop_decl = None

            elif fa.is_call and fa.entity not in entity_to_type:
                # @@Type.method(args) -- a table-level call (e.g. a generated
                # for_<field> lookup), not an instance field access. Only
                # reachable when `entity` isn't itself a declared variable,
                # so this can't shadow the ordinary @@entity.field path
                # below.
                if fa.index_expr:
                    raise sc.err(
                        "InvalidSquirrelSyntax: '@@"
                        + fa.entity
                        + "[...]' -- can't index a type name, only a"
                        " container-tracked '@@'-marked variable"
                    )
                if fa.entity not in relation_schema:
                    raise sc.err(
                        "InvalidSquirrelSyntax: '@@"
                        + fa.entity
                        + "' is neither a constructed entity nor a known"
                        " @@struct -- can't call '"
                        + fa.field
                        + "' on it"
                    )
                if len(fa.hops) > 0:
                    raise sc.err(
                        "InvalidSquirrelSyntax: '@@"
                        + fa.entity
                        + "."
                        + fa.field
                        + "(...)' -- relation hops aren't valid before a"
                        " table-level call"
                    )
                if not world_declared:
                    raise sc.err(
                        "InvalidSquirrelSyntax: calling '@@"
                        + fa.entity
                        + "."
                        + fa.field
                        + "(...)' needs 'sqrrl__world' -- open @@{ or"
                        " add '@@' to this function's own parameters first"
                    )
                # `create` and a `unique` field's own `for_<field>` return
                # a single EntityHandle of *this* type; `get_<field>` for a
                # *relation* field also returns a single EntityHandle, but
                # of that field's own target type instead (`relation_schema
                # [fa.entity][field]`), not `fa.entity` itself -- easy to
                # miss since it's not literally `fa.entity`'s own table.
                # An `ordered` field's `for_<field>` (exact match only --
                # its five range-shaped siblings stay `List`-returning like
                # any other field's `for_<field>`) returns
                # `Set[EntityHandle[...]]` instead, matching `emit_table`'s
                # own codegen for it (see its `FieldModifier.ORDERED`
                # branch). Any other `for_<field>` returns
                # `List[EntityHandle[...]]` (tracked via `entity_to_type`'s
                # container encoding, `encode_container_type`). All these
                # are tracked and enforced the same way now that both a single entity
                # and a container of them can be properly followed up with
                # `@@name.field`/`@@name[i].field`; anything else
                # (`get_<field>`/`set_<field>` for a *plain* field, `to_json`/
                # `from_json` -- not DSL-reachable at all, `sqrrl__`-prefixed
                # and internal-only now, see `emit_table_json_methods` --
                # ...) is none of these and is never tracked/enforced here,
                # mirroring WORLD_FUNC's own function_returns-gated check
                # below.
                var is_entity_returning = fa.field == "create"
                var is_list_returning = False
                var registered_type = fa.entity
                if not is_entity_returning and fa.field.startswith("for_"):
                    var target_field = String(fa.field[byte=4 : fa.field.byte_length()])
                    var is_unique_field = False
                    if fa.entity in unique_fields:
                        for uf in unique_fields[fa.entity]:
                            if uf == target_field:
                                is_unique_field = True
                                break
                    if is_unique_field:
                        is_entity_returning = True
                    else:
                        is_list_returning = True
                        if _is_ordered_field_query(fa.entity, target_field, ordered_fields):
                            registered_type = encode_container_type("Set", fa.entity)
                        else:
                            registered_type = encode_container_type("List", fa.entity)
                elif fa.field.startswith("get_") and fa.entity in relation_schema:
                    var target_field = String(fa.field[byte=4 : fa.field.byte_length()])
                    if target_field in relation_schema[fa.entity]:
                        registered_type = relation_schema[fa.entity][target_field]
                        # A collection-typed relation field's `get_<field>`
                        # returns `List[EntityHandle[...]]`, not a single
                        # entity -- `relation_schema` already carries that
                        # distinction pre-encoded (see
                        # `build_relation_schema`), same shape
                        # `for_<field>`'s own `is_list_returning` case builds
                        # above, just via `encode_container_type` here
                        # instead of there.
                        if is_container_type(registered_type):
                            is_list_returning = True
                        else:
                            is_entity_returning = True
                elif fa.field == "all":
                    # Generated for every struct (`keepalive` or not, see
                    # `emit_table`), returning `Set[EntityHandle[...]]` --
                    # `Set`, not `List`, unlike every other container case
                    # above, since that's `Table.all()`'s own actual return
                    # type.
                    is_list_returning = True
                    registered_type = encode_container_type("Set", fa.entity)
                elif fa.field.startswith("distinct_") and fa.entity in relation_schema:
                    # `distinct_<field>`/`group_by_<field>`/`count_by_<field>`
                    # (`codegen.table`) are all keyed by the *field's own*
                    # type, not `fa.entity` -- unlike every other case above,
                    # whose container element is always `fa.entity` itself.
                    # `_resolve_relation_field_target` (shared by all three,
                    # `codegen.helpers`) is what resolves that shared target
                    # type -- see its own doc comment for why a plain field or
                    # a wrapped-but-not-`multi` one isn't tracked at all.
                    # `distinct_<field>` itself wraps the result in `Set[...]`
                    # (`List[...]` for `ordered` -- not tracked here at all,
                    # since `ordered` on a relation field can't actually
                    # compile in the first place, `EntityHandle` not being
                    # `Comparable`).
                    var target_field = String(fa.field[byte=9 : fa.field.byte_length()])
                    var target = _resolve_relation_field_target(fa.entity, target_field, relation_schema, multi_fields)
                    if target:
                        is_list_returning = True
                        registered_type = encode_container_type("Set", target.value())
                elif fa.field.startswith("group_by_") and fa.entity in relation_schema:
                    # Same target-type resolution as `distinct_<field>`
                    # above, wrapped in `Dict[...]` instead -- matching
                    # `group_by_<field>`'s own `Dict[Target, ...]` return.
                    # Only the *first* type parameter (the key) is tracked
                    # here, same as a `@@`-marked function's own `-> Dict[
                    # @@Type, V]:` return type already is
                    # (`build_function_returns`) -- iterating a bare `Dict`
                    # yields keys, so that's the only parameter `for @@name
                    # in ...:` binding needs; the value side (a `List[
                    # EntityHandle[...]]`/`EntityHandle[...]` per key) isn't
                    # `@@`-tracked at all yet.
                    var target_field = String(fa.field[byte=9 : fa.field.byte_length()])
                    var target = _resolve_relation_field_target(fa.entity, target_field, relation_schema, multi_fields)
                    if target:
                        is_list_returning = True
                        registered_type = encode_container_type("Dict", target.value())
                elif fa.field.startswith("count_by_") and fa.entity in relation_schema:
                    # Same as `group_by_<field>` immediately above --
                    # `count_by_<field>` returns `Dict[Target, Int]`, so the
                    # key side is tracked identically; the `Int` value side
                    # was never trackable to begin with (it isn't an entity).
                    var target_field = String(fa.field[byte=9 : fa.field.byte_length()])
                    var target = _resolve_relation_field_target(fa.entity, target_field, relation_schema, multi_fields)
                    if target:
                        is_list_returning = True
                        registered_type = encode_container_type("Dict", target.value())
                elif (
                    fa.field.startswith("sum_")
                    or fa.field.startswith("avg_")
                    or fa.field.startswith("min_")
                    or fa.field.startswith("max_")
                ) and fa.entity in relation_schema:
                    # `sum_<y>_by_<x>`/`avg_`/`min_`/`max_` (`codegen.
                    # aggregates`) return `Dict[Target, ResultType]`, `x`
                    # (the *grouping* field) supplying `Target` the same way
                    # `group_by_<field>`/`count_by_<field>` do -- `y` (the
                    # aggregated field) never enters this at all, since it's
                    # never the container's key type. Split on the *last*
                    # `_by_` rather than the first, in case `y`'s own name
                    # happens to contain that substring -- `x`'s name is
                    # whatever follows it either way. The singular
                    # `_for_<x>(value)` sibling and the whole-table `sum_<y>
                    # ()` form both return a scalar, not a container, so
                    # neither has anything to track here; `_by_` not
                    # appearing in either name is what naturally excludes
                    # them, with no separate check needed.
                    var by_pos = fa.field.rfind("_by_")
                    if by_pos >= 0:
                        var target_field = String(
                            fa.field[byte = by_pos + 4 : fa.field.byte_length()]
                        )
                        var target = _resolve_relation_field_target(
                            fa.entity, target_field, relation_schema, multi_fields
                        )
                        if target:
                            is_list_returning = True
                            registered_type = encode_container_type("Dict", target.value())
                if is_entity_returning or is_list_returning:
                    enforce_entity_binding(
                        source,
                        marker_start,
                        pending_decl,
                        entity_to_type,
                        registered_type,
                        fa.entity + "." + fa.field + "(...)",
                    )
                if is_list_returning and pending_for_loop_decl:
                    # `for @@name in @@Type.for_<field>(...)/.all():` binds
                    # `@@name` to the container's *element* type, not the
                    # container type `enforce_entity_binding` above just
                    # registered `pending_decl` (if any) as -- the two are
                    # mutually exclusive in practice (a `for` loop header has
                    # no `var @@x =` of its own to set `pending_decl`), but
                    # kept as separate state regardless, since they mean
                    # different things.
                    entity_to_type[pending_for_loop_decl.value()] = container_element_of(registered_type)
                out += String(t"sqrrl__world.{fa.entity}.{fa.field}")
                pending_decl = None
                pending_for_loop_decl = None

            else:
                if fa.entity not in entity_to_type:
                    raise sc.err(
                        "InvalidSquirrelSyntax: '"
                        + fa.entity
                        + "' was never constructed via @@Type{...} in this"
                        " function -- can't tell which table its fields live in"
                    )
                var declared_type = entity_to_type[fa.entity]
                if is_container_type(declared_type) and fa.is_call and not fa.index_expr:
                    # A method call directly on the container itself
                    # (`@@team.append(...)`, `.extend`, `.count`, ...), not
                    # a field access on one of its elements -- pass through
                    # untouched (just `@@` stripped) rather than either
                    # requiring `[i]` first or routing through a generated
                    # get_/set_<field>. There's no way to tell "is `field` a
                    # real container method" from "a coincidentally-named
                    # struct field" without real type information, but
                    # every field access on an *element* already goes
                    # through `[i].field` instead, so this can't collide
                    # with that path -- and it needs no `sqrrl__world`
                    # either, since it's a plain Mojo list operation, not a
                    # table access.
                    out += String(t"{sqrrl_prefixed(fa.entity)}.{fa.field}")
                    pending_decl = None
                    pending_for_loop_decl = None
                else:
                    if not world_declared:
                        raise sc.err(
                            "InvalidSquirrelSyntax: accessing '@@"
                            + fa.entity
                            + "."
                            + fa.field
                            + "' needs 'sqrrl__world' -- open @@{ or"
                            " add '@@' to this function's own parameters"
                            " first"
                        )
                    var current_type: String
                    var expr: String
                    if is_container_type(declared_type):
                        if not fa.index_expr:
                            raise sc.err(
                                "InvalidSquirrelSyntax: '@@"
                                + fa.entity
                                + "' is a "
                                + container_wrapper_of(declared_type)
                                + " of '@@"
                                + container_element_of(declared_type)
                                + "' -- index into it first ('@@"
                                + fa.entity
                                + "[i]."
                                + fa.field
                                + "')"
                            )
                        current_type = container_element_of(declared_type)
                        var rewritten_index = rewrite_markers(
                            fa.index_expr.value(),
                            relation_schema,
                            function_returns,
                            unique_fields,
                            ordered_fields,
                            plain_struct_fields,
                            relation_targets,
                            entity_to_type,
                            world_declared,
                        )
                        var entity_expr = fa.entity if fa.entity_unmarked else sqrrl_prefixed(fa.entity)
                        expr = String(t"{entity_expr}[{rewritten_index}]")
                    else:
                        if fa.index_expr:
                            raise sc.err(
                                "InvalidSquirrelSyntax: '@@"
                                + fa.entity
                                + "' isn't a container -- can't index into it"
                            )
                        current_type = declared_type
                        expr = fa.entity if fa.entity_unmarked else sqrrl_prefixed(fa.entity)
                    for hop in fa.hops:
                        if current_type not in relation_schema or hop not in relation_schema[current_type]:
                            raise sc.err(
                                "InvalidSquirrelSyntax: '"
                                + current_type
                                + "' has no relation field '"
                                + hop
                                + "'"
                            )
                        if current_type in plain_struct_fields:
                            # A plain struct's own relation field is a real
                            # Mojo field, not a generated `get_<field>`
                            # method -- there's no `sqrrl__world.<Name>`
                            # table for a plain struct at all, unlike an
                            # entity. Direct field access, same as reading
                            # any other field on it.
                            expr = String(t"{expr}.{hop}")
                        else:
                            expr = String(t"sqrrl__world.{current_type}.get_{hop}({expr})")
                        current_type = relation_schema[current_type][hop]
                    if fa.write_value:
                        if current_type in plain_struct_fields:
                            # A plain struct's own field is written
                            # directly -- no `set_<field>` method exists
                            # for it (that's an entity-table concept), just
                            # an ordinary Mojo field assignment.
                            out += String(t"{expr}.{fa.field} = {fa.write_value.value()};")
                        else:
                            out += String(
                                t"sqrrl__world.{current_type}.set_{fa.field}({expr}, {fa.write_value.value()});"
                            )
                    elif fa.is_call:
                        if not sc.try_consume("("):
                            raise sc.err("InvalidSquirrelSyntax: expected '(' after '" + fa.field + "'")
                        if current_type in plain_struct_fields:
                            # An ordinary Mojo method call on the plain
                            # struct's own value (`expr` is the real
                            # receiver via dot-call syntax) -- unlike the
                            # entity case just below, there's no injected
                            # first argument, so whatever args follow pass
                            # through completely unchanged.
                            out += String(t"{expr}.{fa.field}(")
                        else:
                            # An instance method call on the field itself
                            # (`@@eng.add_to_projects(@@website)`), not a
                            # plain field read -- the generated method
                            # (`add_to_<field>`/`remove_from_<field>`, ...)
                            # takes the entity as its own first argument, so
                            # `get_` isn't spliced in and `expr` is injected
                            # as that first argument. The opening `(` was
                            # consumed just above to inject a comma before
                            # whatever follows, if anything did -- same
                            # technique `MarkerKind.WORLD_FUNC` uses to
                            # inject `sqrrl__world` as a call's own first
                            # argument.
                            sc.skip_whitespace()
                            var has_more_args = sc.peek() != UInt8(ord(")"))
                            out += String(t"sqrrl__world.{current_type}.{fa.field}({expr}")
                            if has_more_args:
                                out += ", "
                    else:
                        var is_relation_field = current_type in relation_schema and fa.field in relation_schema[current_type]
                        if is_relation_field and not fa.field_marked:
                            # There's no plain `.dept` spelling for a
                            # relation field -- only `.@@dept` -- the same
                            # way a `@@struct` body itself requires `@@` on
                            # a relation field's own name. `fa.field_marked`
                            # is false here, meaning this was written
                            # `@@alice.dept`, not `@@alice.@@dept`.
                            raise sc.err(
                                "InvalidSquirrelSyntax: '"
                                + current_type
                                + "."
                                + fa.field
                                + "' is a relation field -- read it as '@@"
                                + fa.entity
                                + ".@@"
                                + fa.field
                                + "', not '@@"
                                + fa.entity
                                + "."
                                + fa.field
                                + "'"
                            )
                        if fa.field_marked and not is_relation_field:
                            raise sc.err(
                                "InvalidSquirrelSyntax: '"
                                + current_type
                                + "' has no relation field '"
                                + fa.field
                                + "' -- '@@"
                                + fa.field
                                + "' marks a relation; use '."
                                + fa.field
                                + "' (no '@@') for a plain field"
                            )
                        var field_expr: String
                        if current_type in plain_struct_fields:
                            field_expr = String(t"{expr}.{fa.field}")
                        else:
                            field_expr = String(t"sqrrl__world.{current_type}.get_{fa.field}({expr})")

                        if fa.post_index_expr:
                            # `@@dept.@@employees[0].name` -- `fa.field`
                            # read above is the whole container; index into
                            # it, then (if `fa.post_field` is set) read one
                            # more field off the indexed element -- see
                            # `FieldAccess`'s own doc comment.
                            if not is_relation_field:
                                raise sc.err(
                                    "InvalidSquirrelSyntax: '"
                                    + current_type
                                    + "."
                                    + fa.field
                                    + "' isn't a relation field -- can't"
                                    " resolve a field on its indexed element"
                                )
                            var raw_target = relation_schema[current_type][fa.field]
                            if not is_container_type(raw_target):
                                raise sc.err(
                                    "InvalidSquirrelSyntax: '"
                                    + current_type
                                    + "."
                                    + fa.field
                                    + "' isn't a container -- can't index"
                                    " into it"
                                )
                            var element_type = container_element_of(raw_target)
                            var rewritten_post_index = rewrite_markers(
                                fa.post_index_expr.value(),
                                relation_schema,
                                function_returns,
                                unique_fields,
                                ordered_fields,
                                plain_struct_fields,
                                relation_targets,
                                entity_to_type,
                                world_declared,
                            )
                            var indexed_expr = String(t"{field_expr}[{rewritten_post_index}]")
                            if fa.post_field:
                                var pf = fa.post_field.value()
                                var post_is_relation = (
                                    element_type in relation_schema and pf in relation_schema[element_type]
                                )
                                if post_is_relation and not fa.post_field_marked:
                                    raise sc.err(
                                        "InvalidSquirrelSyntax: '"
                                        + element_type
                                        + "."
                                        + pf
                                        + "' is a relation field -- read it"
                                        " as '.@@"
                                        + pf
                                        + "', not '."
                                        + pf
                                        + "'"
                                    )
                                if fa.post_field_marked and not post_is_relation:
                                    raise sc.err(
                                        "InvalidSquirrelSyntax: '"
                                        + element_type
                                        + "' has no relation field '"
                                        + pf
                                        + "' -- '@@"
                                        + pf
                                        + "' marks a relation; use '."
                                        + pf
                                        + "' (no '@@') for a plain field"
                                    )
                                if fa.post_field_marked:
                                    enforce_entity_binding(
                                        source,
                                        marker_start,
                                        pending_decl,
                                        entity_to_type,
                                        relation_schema[element_type][pf],
                                        fa.entity + "." + fa.field + "[...]." + pf,
                                    )
                                if element_type in plain_struct_fields:
                                    out += String(t"{indexed_expr}.{pf}")
                                else:
                                    out += String(t"sqrrl__world.{element_type}.get_{pf}({indexed_expr})")
                            else:
                                # A bare indexed value, `@@dept.@@employees
                                # [0]` -- tracked the same way a plain
                                # `@@matches[0]` would be, if bound to a
                                # marked variable.
                                if pending_decl:
                                    entity_to_type[pending_decl.value()] = element_type
                                out += indexed_expr
                        else:
                            if fa.field_marked:
                                # `@@alice.@@dept` reads a relation field
                                # the same way a table-level `@@Employee.
                                # get_dept(...)` call does, so it's tracked
                                # the same way that call's own
                                # `enforce_entity_binding` above tracks its
                                # result: bind it to an '@@'-marked
                                # variable to keep using it with
                                # '@@name.field' sugar, same as
                                # `create`/`for_<field>`.
                                enforce_entity_binding(
                                    source,
                                    marker_start,
                                    pending_decl,
                                    entity_to_type,
                                    relation_schema[current_type][fa.field],
                                    fa.entity + "." + fa.field,
                                )
                                if pending_for_loop_decl:
                                    # `for @@e in @@dept.@@employees:` binds
                                    # `@@e` to the container's own *element*
                                    # type, the same way iterating a
                                    # table-level call's result already
                                    # does -- an instance field read never
                                    # consulted this before, so this case
                                    # (as opposed to `@@Employee.for_dept
                                    # (...)`'s own call-based container
                                    # reads) silently left `@@e` untracked.
                                    var raw_target = relation_schema[current_type][fa.field]
                                    if is_container_type(raw_target):
                                        entity_to_type[pending_for_loop_decl.value()] = container_element_of(
                                            raw_target
                                        )
                            out += field_expr
                    pending_decl = None
                    pending_for_loop_decl = None

        else:  # MarkerKind.NAME_REF
            var nr = sc.parse_name_ref()
            var reshaped_current_type: Optional[String] = None
            if nr.name not in entity_to_type:
                var implicit_prefix = preceding_unmarked_ident(source, marker_start)
                if implicit_prefix and implicit_prefix.value().name in entity_to_type:
                    # `for @@m in team.@@members:` -- `@@members` here has
                    # nothing after it but the loop's own `:`, so it parses
                    # as a bare `NAME_REF`, not `FIELD_ACCESS` (which needs
                    # a `.`/`[` to follow) -- same recovery as
                    # `FIELD_ACCESS`'s own implicit-prefix handling, just
                    # for this shape instead.
                    var prefix = implicit_prefix.value().copy()
                    var peek_pos = marker_start + 2 + nr.name.byte_length()
                    var peek_save = sc.pos
                    sc.pos = peek_pos
                    sc.skip_trivia()
                    var is_write_attempt = sc.peek() == UInt8(ord("=")) and sc.peek_at(1) != UInt8(ord("="))
                    sc.pos = peek_save
                    if is_write_attempt:
                        raise sc.err(
                            "InvalidSquirrelSyntax: writing through an"
                            " implicitly-prefixed field isn't supported"
                            " ('"
                            + prefix.name
                            + ".@@"
                            + nr.name
                            + " = ...')"
                        )
                    var trim_count = marker_start - prefix.start
                    out = String(out[byte = 0 : out.byte_length() - trim_count])
                    var current_type = entity_to_type[prefix.name]
                    if current_type not in relation_schema or nr.name not in relation_schema[current_type]:
                        raise sc.err(
                            "InvalidSquirrelSyntax: '"
                            + current_type
                            + "' has no relation field '"
                            + nr.name
                            + "'"
                        )
                    reshaped_current_type = current_type
                    if current_type in plain_struct_fields:
                        out += String(t"{prefix.name}.{nr.name}")
                    else:
                        out += String(t"sqrrl__world.{current_type}.get_{nr.name}({prefix.name})")
            if reshaped_current_type:
                if pending_for_loop_decl:
                    var raw_target = relation_schema[reshaped_current_type.value()][nr.name]
                    if is_container_type(raw_target):
                        entity_to_type[pending_for_loop_decl.value()] = container_element_of(raw_target)
                pending_decl = None
                pending_for_loop_decl = None
                pos = sc.pos
                continue
            out += sqrrl_prefixed(nr.name)
            var save = sc.pos
            sc.skip_trivia()
            var is_decl = sc.peek() == UInt8(ord("=")) and sc.peek_at(1) != UInt8(ord("="))
            if not is_decl and not is_in_import_statement(source, marker_start) and nr.name not in entity_to_type:
                raise sc.err(
                    "InvalidSquirrelSyntax: '@@"
                    + nr.name
                    + "' is referenced but was never constructed or bound"
                    " -- every '@@'-marked entity must come from a"
                    " '@@Type{...}' construct, an entity-returning call, or"
                    " an entity parameter before it can be used"
                )
            if is_decl:
                sc.pos += 1  # consume '='
                sc.skip_trivia()
                if not sc.starts_with("@@"):
                    # Not itself `@@`-marked -- the one other shape that's
                    # still legitimate is a bare container constructor,
                    # `Container[@@Type](...)` (`List[@@Person]()`): the
                    # `@@Type` inside it gets found and rewritten as its
                    # own marker later regardless (any `@@Type` sitting in
                    # an `Ident[...]` position does, see `MarkerKind.
                    # RETURN_TYPE`'s container form), but nothing else
                    # registers `entity_to_type` for *this* declaration in
                    # that case, since there's no `@@Type{...}`/`@@Type.
                    # method()` marker here for `pending_decl` to attach
                    # to -- so this does it directly, as a lookahead,
                    # without consuming anything (the constructor call
                    # itself is left for the normal pass-through/marker
                    # loop to handle unchanged).
                    var lookahead = sc.pos
                    var wrapper = sc.scan_ident()
                    sc.skip_trivia()
                    var matched_container = False
                    if wrapper.byte_length() > 0 and sc.try_consume("["):
                        sc.skip_trivia()
                        if sc.try_consume("@@"):
                            var type_name = sc.scan_ident()
                            if type_name.byte_length() > 0:
                                matched_container = True
                                entity_to_type[nr.name] = encode_container_type(wrapper, type_name)
                    sc.pos = lookahead
                    if not matched_container:
                        raise sc.err(
                            "InvalidSquirrelSyntax: '@@"
                            + nr.name
                            + "' must be initialized from a '@@'-marked"
                            " value (e.g. '@@Type{...}', another"
                            " '@@'-marked entity, or a container"
                            " constructor like 'List[@@Type]()') -- an"
                            " unmarked right-hand side would silently"
                            " skip the construct rewrite"
                        )
            sc.pos = save
            if not is_decl and pending_for_loop_decl and nr.name in entity_to_type and is_container_type(entity_to_type[nr.name]):
                # `for @@l in @@localList:` -- `@@localList` is a bound
                # container variable (not a fresh call like `@@Type.all()`/
                # `@@some_func()`, which the FIELD_ACCESS/WORLD_FUNC
                # branches already bind the loop variable from), so this is
                # the only place left to register `@@l`'s own element type
                # before `pending_for_loop_decl` is cleared below.
                entity_to_type[pending_for_loop_decl.value()] = container_element_of(entity_to_type[nr.name])
            pending_decl = String(nr.name) if is_decl else None
            pending_for_loop_decl = None

        pos = sc.pos

    if declare_open:
        raise sc.err(
            "InvalidSquirrelSyntax: '@@{' needs a matching '@@}' before"
            " this function ends"
        )

    out += String(source[byte = pos : source.byte_length()])
    return out


