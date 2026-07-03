from squirrel_compiler.parser import (
    ParsedStruct,
    Field,
    Scanner,
    MarkerKind,
    ConstructField,
    parse_construct_fields,
)


def sqrrl_prefixed(name: String) -> String:
    """The single transformation behind every generator-introduced
    identifier that could otherwise collide with a `.rel`-declared field --
    generated struct names (`sqrrl__PersonTableState`) and
    `sqrrl__cleanup_relations`. A `.rel` author could plausibly name a field
    `cleanup_relations`; they can't plausibly type `sqrrl__cleanup_relations`
    by accident. This is the only place that prefix gets written -- every
    other call site goes through here rather than inlining the literal."""
    return "sqrrl__" + name


def emit_field_type(f: Field) -> String:
    """A relation field (`@@employee: @@Employee`) stores another table's
    entity handle -- `EntityHandle[sqrrl__EmployeeTableState]`, not
    `sqrrl__EmployeeTable` itself (that would mean "store the whole table",
    not a row reference). `sqrrl__EmployeeTableState` (not
    `sqrrl__EmployeeTable`) is the tag `EntityHandle` is parametrized by --
    see `emit_table`. A plain field's `type_str` is emitted verbatim --
    assumed to already be valid Mojo (`String`, `UInt32`, ...), since
    `.rel` sources now target Mojo directly."""
    if f.type_str.startswith("@@"):
        var target = String(f.type_str[byte=2 : f.type_str.byte_length()])
        return String(t"EntityHandle[{sqrrl_prefixed(target)}TableState]")
    return f.type_str


def emit_rel_type(f: Field) -> String:
    return String(t"Rel[{emit_field_type(f)}]")


def emit_table(parsed: ParsedStruct) -> String:
    """Emits two generated structs per `@@struct`:

    - `sqrrl__NameTableState` -- implements `TableStateLike` (just one `Rel`
      per field, plus `sqrrl__cleanup_relations`), and is what
      `EntityHandle`/`Table` are actually parametrized by.
      `sqrrl__cleanup_relations` calls `fetch_remove_fwd` on every field and
      discards the result -- for a relation field, that drops the returned
      `EntityHandle`, decref'ing whatever it pointed to, which is what
      makes destroying an entity correctly release its relations instead of
      leaking them (see `TableStateLike`'s doc comment in `entity.mojo` for
      the concrete leak this closes). Id allocation itself lives on the
      runtime's `TableStorage` wrapper, not here -- it's mechanically
      identical for every table, so there's nothing table-specific to
      generate for it.
    - `sqrrl__NameTable` -- the user-facing wrapper, holding a
      `Table[sqrrl__NameTableState]` plus typed `create`/`get_*`/`set_*`
      methods delegating into it, via `self.table.state[].state.<field>`
      (the first `.state` is `Table`'s `ArcPointer` target, `TableStorage`;
      the second is `TableStorage`'s own field holding the generated
      state). `create`/`get_*`/`set_*` stay bare, unprefixed -- unlike the
      struct names and `cleanup_relations`, colliding with a `.rel` field
      literally named `create` (or `get_<fieldname>`) is an edge case
      narrow enough not to be worth the extra noise on every accessor.

    Using `sqrrl__NameTableState` as the tag (not a separate marker type,
    and not `sqrrl__NameTable` itself) is what lets
    `EntityHandle[sqrrl__PersonTableState]` and
    `EntityHandle[sqrrl__EmployeeTableState]` be distinct,
    mutually-incompatible types with no duplicated runtime logic per
    `@@struct`."""
    var state_name = sqrrl_prefixed(parsed.name) + "TableState"
    var table_name = sqrrl_prefixed(parsed.name) + "Table"

    var out = String(t"struct {state_name}(TableStateLike, Movable, ImplicitlyDeletable):\n")
    for f in parsed.fields:
        out += String(t"    var {f.name}: {emit_rel_type(f)}\n")
    out += "\n"

    out += "    def __init__(out self):\n"
    if len(parsed.fields) == 0:
        out += "        pass\n"
    for f in parsed.fields:
        out += String(t"        self.{f.name} = {emit_rel_type(f)}()\n")
    out += "\n"

    out += String(t"    def {sqrrl_prefixed('cleanup_relations')}(mut self, id: UInt32):\n")
    if len(parsed.fields) == 0:
        out += "        pass\n"
    for f in parsed.fields:
        out += String(t"        _ = self.{f.name}.fetch_remove_fwd(id)\n")

    out += "\n\n"
    out += String(t"struct {table_name}(Movable):\n")
    out += String(t"    var table: Table[{state_name}]\n")
    out += "\n"
    out += "    def __init__(out self):\n"
    out += String(t"        self.table = Table[{state_name}]({state_name}())\n")
    out += "\n"

    out += "    def create(mut self"
    for f in parsed.fields:
        out += String(t", {f.name}: {emit_field_type(f)}")
    out += String(t") -> EntityHandle[{state_name}]:\n")
    out += "        var e = self.table.create()\n"
    for f in parsed.fields:
        out += String(t"        self.table.state[].state.{f.name}.put(e.id(), {f.name})\n")
    out += "        return e\n"

    for f in parsed.fields:
        var field_type = emit_field_type(f)
        out += "\n"
        out += String(t"    def get_{f.name}(self, e: EntityHandle[{state_name}]) -> {field_type}:\n")
        out += String(t"        return self.table.state[].state.{f.name}.get_fwd(e.id()).value()\n")
        out += "\n"
        out += String(t"    def set_{f.name}(mut self, e: EntityHandle[{state_name}], v: {field_type}):\n")
        out += String(t"        self.table.state[].state.{f.name}.update(e.id(), v)\n")

    return out


def line_start_of(source: String, pos: Int) -> Int:
    """Byte offset where the line containing `pos` begins."""
    var bytes = source.as_bytes()
    var line_start = pos
    while line_start > 0 and bytes[line_start - 1] != UInt8(ord("\n")):
        line_start -= 1
    return line_start


def is_in_def_signature(source: String, pos: Int) -> Bool:
    """True if byte offset `pos` sits on a line that starts (after
    indentation) with `def ` -- i.e. `pos` is inside a function's own
    signature rather than somewhere else in its body. Distinguishes a bare
    `@@`'s two roles: opting a function's own signature into
    `sqrrl__world` (`def foo(a: Int, @@)`) versus forwarding it at a call
    site sitting on some other line (`foo(x, @@)`). A def's signature is
    assumed to fit on one line, matching every example so far."""
    var line_start = line_start_of(source, pos)
    var bytes = source.as_bytes()
    var indent_end = line_start
    while indent_end < pos and (
        bytes[indent_end] == UInt8(ord(" ")) or bytes[indent_end] == UInt8(ord("\t"))
    ):
        indent_end += 1
    return String(source[byte = indent_end : pos]).startswith("def ")


def crosses_top_level_def(text: String) -> Bool:
    """True if `text` spans a line starting at column 0 with `def ` --
    i.e. it crosses into a new top-level function body. Mojo has no mutable
    global/static state (see `Table`'s doc comment in `entity.mojo`), so
    `sqrrl__world` only lives inside whichever function called `@@init()`
    or received it as a parameter; `transform_source` uses this to reset
    its per-function bookkeeping (`entity_to_type`, `world_available`) at
    each such boundary, rather than tracking it once for the whole file --
    which previously let a second function silently reference state that
    only existed in a sibling function's scope."""
    if text.startswith("def "):
        return True
    return "\ndef " in text


def resolve_construct_value(
    value: String,
    field_owner_type: String,
    field_name: String,
    relation_schema: Dict[String, Dict[String, String]],
    entity_to_type: Dict[String, String],
    world_available: Bool,
) raises -> String:
    """If `value` (already trimmed by `parse_construct_fields`) itself
    starts with `@@`, it's a nested marker needing the same rewriting
    `transform_source`'s own top-level markers get -- either a bare
    reference to an already-constructed entity (`@@bob`) or a nested
    construct (`@@Employee { ... }`) -- rather than being spliced into the
    generated `create(...)` call as literal, uncompilable text. A plain
    (non-`@@`) value is assumed to already be a valid Mojo expression of
    the right type (e.g. a variable a caller bound some other way) and is
    returned untouched."""
    if not value.startswith("@@"):
        return value
    if not world_available:
        raise Error(
            "InvalidSquirrelSyntax: constructing '@@"
            + field_owner_type
            + "."
            + field_name
            + "' needs 'sqrrl__world' -- call @@init() or add '@@' to"
            " this function's own parameters first"
        )
    var sc = Scanner(value)
    if not sc.try_consume("@@"):
        raise Error("InvalidSquirrelSyntax: expected '@@' in relation field value")
    var ident = sc.scan_ident()
    if ident.byte_length() == 0:
        raise Error(
            "InvalidSquirrelSyntax: expected an identifier after '@@' in a"
            " relation field's value"
        )
    sc.skip_trivia()
    if sc.peek() == UInt8(ord("{")):
        var nested_body = sc.scan_braced_span()
        var nested_fields = parse_construct_fields(nested_body)
        return build_create_call(
            ident, nested_fields, relation_schema, entity_to_type, world_available
        )
    if ident not in entity_to_type:
        raise Error(
            "InvalidSquirrelSyntax: '"
            + ident
            + "' was never constructed via @@Type{...} in this function"
            " -- can't tell which table its fields live in"
        )
    return sqrrl_prefixed(ident)


def build_create_call(
    type_name: String,
    fields: List[ConstructField],
    relation_schema: Dict[String, Dict[String, String]],
    entity_to_type: Dict[String, String],
    world_available: Bool,
) raises -> String:
    """Builds `sqrrl__world.TypeName.create(name = value, ...)`, validating
    each field's `@@` marking against `relation_schema[type_name]` -- must
    match the struct's own declaration, the same way a mismatched
    struct-field declaration itself is already rejected (`parse_fields`) --
    and recursively resolving a relation field's value
    (`resolve_construct_value`) so a nested `@@bob` / `@@Employee{...}`
    rewrites correctly instead of passing straight through as literal text.
    Used both for a top-level construct and, recursively, for one nested
    inside a relation field's value -- neither case binds a name of its
    own, so `entity_to_type` is only ever read here, never written."""
    var type_relations = (
        relation_schema[type_name].copy() if type_name in relation_schema else Dict[String, String]()
    )
    var args = String()
    var first = True
    for f in fields:
        var declared_as_relation = f.name in type_relations
        if f.is_relation and not declared_as_relation:
            raise Error(
                "InvalidSquirrelSyntax: '"
                + type_name
                + "."
                + f.name
                + "' isn't declared as a relation field -- use '."
                + f.name
                + "' here, not '.@@"
                + f.name
                + "'"
            )
        if not f.is_relation and declared_as_relation:
            raise Error(
                "InvalidSquirrelSyntax: '"
                + type_name
                + "."
                + f.name
                + "' is declared as a relation field (`@@"
                + f.name
                + ": @@...`) -- must be written '.@@"
                + f.name
                + "' here too"
            )
        var value = f.value
        if f.is_relation:
            value = resolve_construct_value(
                f.value, type_name, f.name, relation_schema, entity_to_type, world_available
            )
        if not first:
            args += ", "
        args += f.name + " = " + value
        first = False
    return String(t"sqrrl__world.{type_name}.create({args})")


def transform_source(
    source: String, relation_schema: Dict[String, Dict[String, String]]
) raises -> String:
    """Rewrites every `@@`-marked construct in `source` to plain Mojo,
    leaving everything else byte-for-byte untouched -- mirrors the Zig
    parser's `transformSquirrel`, minus the incref/auto-defer machinery it
    needed (Mojo's own ASAP destruction already handles that, see
    `Scanner.find_next_marker`'s doc comment).

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

    `@@struct` becomes a generated table pair (`emit_table`), same as
    before. But table *instances* now all live in one place: the generated,
    project-wide `sqrrl__Squirrel` (see `driver.emit_squirrel_module`) --
    there's no per-file, per-type table variable anymore. A script obtains
    it explicitly, once per function that needs it, one of two ways:
    `@@init()` becomes `var sqrrl__world = sqrrl__init()`, or a bare `@@`
    in that function's own parameter list becomes `mut sqrrl__world:
    sqrrl__Squirrel` (opting the function into whatever its caller already
    holds). A bare `@@` anywhere else (a call argument) becomes a plain
    `sqrrl__world` reference, forwarding it along -- matching how every
    other `@@`-marked name is `sqrrl__`-prefixed (`@@alice` ->
    `sqrrl__alice`), just applied to the one name codegen itself invents
    for this. `@@TypeName { ... }` becomes `sqrrl__world.TypeName.create(
    ...)`, and `var @@alice = @@TypeName { ... };` additionally records
    that `alice` was constructed as a `TypeName`, so a later `@@alice.field`
    read/write knows which table to route through:
    `sqrrl__world.TypeName.get_field(sqrrl__alice)` /
    `.set_field(sqrrl__alice, expr)`. A chain
    (`@@alice.@@employee.title`) nests one `get_<hop>(...)` call per
    intermediate relation inside the next, all as a single expression --
    `sqrrl__world.Employee.get_title(sqrrl__world.Person.get_employee(
    sqrrl__alice))` -- rather than splicing intermediate temp-variable
    declarations, so it stays usable inline (`print(@@alice.@@employee.title)`)
    the same way a plain single-hop access already is.

    Both `entity_to_type` and whether `sqrrl__world` is available
    (`world_available`) are function-scoped, reset at every top-level `def`
    (`crosses_top_level_def`) -- Mojo has no mutable global/static state
    (see `Table`'s doc comment in `entity.mojo`), so neither an entity
    variable nor `sqrrl__world` itself outlives the function it was bound
    in. Referencing an entity that was never constructed via `@@Type{...}`
    in this same function, or using `@@Type{...}`/`@@entity.field`/a bare
    `@@` before this function has `sqrrl__world` in scope, raises a clear
    error rather than emitting code that fails to compile downstream."""
    var sc = Scanner(source)
    var out = String()
    var pos = 0

    var entity_to_type = Dict[String, String]()
    var world_available = False
    var pending_decl: Optional[String] = None

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
        if crosses_top_level_def(between):
            entity_to_type = Dict[String, String]()
            world_available = False

        if kind == MarkerKind.STRUCT:
            var parsed = sc.parse_struct()
            out += emit_table(parsed)
            pending_decl = None

        elif kind == MarkerKind.INIT:
            sc.parse_init()
            out += "var sqrrl__world = sqrrl__init()"
            world_available = True
            pending_decl = None

        elif kind == MarkerKind.WORLD:
            sc.parse_world_marker()
            if is_in_def_signature(source, marker_start):
                out += "mut sqrrl__world: sqrrl__Squirrel"
                world_available = True
            else:
                if not world_available:
                    raise Error(
                        "InvalidSquirrelSyntax: 'sqrrl__world' isn't"
                        " available here -- call @@init() or add '@@' to"
                        " this function's own parameters first"
                    )
                out += "sqrrl__world"
            pending_decl = None

        elif kind == MarkerKind.ENTITY_PARAM:
            var ep = sc.parse_entity_param()
            if not is_in_def_signature(source, marker_start):
                raise Error(
                    "InvalidSquirrelSyntax: '@@"
                    + ep.name
                    + ": @@"
                    + ep.type_name
                    + "' is only valid as a function parameter -- did you"
                    " mean '@@"
                    + ep.name
                    + " = @@"
                    + ep.type_name
                    + "{...}' to construct one instead?"
                )
            out += String(
                t"{sqrrl_prefixed(ep.name)}: EntityHandle[{sqrrl_prefixed(ep.type_name)}TableState]"
            )
            entity_to_type[ep.name] = ep.type_name
            pending_decl = None

        elif kind == MarkerKind.CONSTRUCT:
            var c = sc.parse_construct()
            if not world_available:
                raise Error(
                    "InvalidSquirrelSyntax: constructing '@@"
                    + c.type_name
                    + "' needs 'sqrrl__world' -- call @@init() or add"
                    " '@@' to this function's own parameters first"
                )
            out += build_create_call(
                c.type_name, c.fields, relation_schema, entity_to_type, world_available
            )
            if pending_decl:
                entity_to_type[pending_decl.value()] = c.type_name
            pending_decl = None

        elif kind == MarkerKind.FIELD_ACCESS:
            var fa = sc.parse_field_access()
            if fa.entity not in entity_to_type:
                raise Error(
                    "InvalidSquirrelSyntax: '"
                    + fa.entity
                    + "' was never constructed via @@Type{...} in this"
                    " function -- can't tell which table its fields live in"
                )
            if not world_available:
                raise Error(
                    "InvalidSquirrelSyntax: accessing '@@"
                    + fa.entity
                    + "."
                    + fa.field
                    + "' needs 'sqrrl__world' -- call @@init() or add"
                    " '@@' to this function's own parameters first"
                )
            var current_type = entity_to_type[fa.entity]
            var expr = sqrrl_prefixed(fa.entity)
            for hop in fa.hops:
                if current_type not in relation_schema or hop not in relation_schema[current_type]:
                    raise Error(
                        "InvalidSquirrelSyntax: '"
                        + current_type
                        + "' has no relation field '"
                        + hop
                        + "'"
                    )
                expr = String(t"sqrrl__world.{current_type}.get_{hop}({expr})")
                current_type = relation_schema[current_type][hop]
            if fa.write_value:
                out += String(
                    t"sqrrl__world.{current_type}.set_{fa.field}({expr}, {fa.write_value.value()});"
                )
            else:
                out += String(t"sqrrl__world.{current_type}.get_{fa.field}({expr})")
            pending_decl = None

        else:  # MarkerKind.NAME_REF
            var nr = sc.parse_name_ref()
            out += sqrrl_prefixed(nr.name)
            var save = sc.pos
            sc.skip_trivia()
            var is_decl = sc.peek() == UInt8(ord("=")) and sc.peek_at(1) != UInt8(ord("="))
            if is_decl:
                sc.pos += 1  # consume '='
                sc.skip_trivia()
                if not sc.starts_with("@@"):
                    raise Error(
                        "InvalidSquirrelSyntax: '@@"
                        + nr.name
                        + "' must be initialized from a '@@'-marked value"
                        " (e.g. '@@Type{...}' or another '@@'-marked"
                        " entity) -- an unmarked right-hand side would"
                        " silently skip the construct rewrite"
                    )
            sc.pos = save
            pending_decl = String(nr.name) if is_decl else None

        pos = sc.pos

    out += String(source[byte = pos : source.byte_length()])
    return out
