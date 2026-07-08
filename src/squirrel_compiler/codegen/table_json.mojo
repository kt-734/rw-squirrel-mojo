from squirrel_compiler.parser import ParsedStruct, Field, FieldModifier, TypeParam, is_wrapped_relation_type, relation_target_of, relation_wrapper_of, parse_type_expr
from squirrel_compiler.codegen.helpers import sqrrl_prefixed, emit_field_type
from squirrel_compiler.codegen.generics import _emit_type_param_list, _emit_type_arg_list


def _plain_struct_base_name(type_str: String) -> String:
    """`Box[String]` -> `Box`; `Address` -> `Address` unchanged -- strips a
    generic plain struct's own type-argument suffix so a field naming an
    *instantiation* (`home: Box[String]`) still resolves against
    `plain_struct_fields`'s bare-name keys, the same way a non-generic
    plain struct's bare name already does. Safe to call on any type
    string -- a real container like `List[String]` also has a `[`, but
    `"List"` was never registered as a plain struct name, so the dict
    lookup this feeds into is the actual disambiguator; this alone can't
    misidentify one."""
    return parse_type_expr(type_str).name


def _collect_relation_targets(
    fields: List[Field],
    plain_struct_fields: Dict[String, List[Field]],
    mut seen: Dict[String, Bool],
    mut out: List[String],
) raises:
    """Every distinct `@@struct` name `fields` needs a live table
    reference to reconstruct, direct *or* transitive through an embedded
    plain struct's own relation field (`Note { @@author: @@Employee,
    ... }` embedded via a plain `note: Note` field still needs
    `Employee`'s table to reconstruct `Note`'s own `@@author`) -- this is
    exactly the parameter list `from_json` needs beyond `mut self`/`mut
    sc`, deduplicated and in first-encountered order. Safe against
    infinite recursion through plain structs embedding each other: the
    same relation graph `check_no_relation_cycles` already walks (which
    includes plain-struct-embedding edges) is guaranteed acyclic before
    codegen ever runs."""
    for f in fields:
        if f.modifier == FieldModifier.MULTI:
            if f.type_str.startswith("@@"):
                var target = String(f.type_str[byte=2 : f.type_str.byte_length()])
                if target not in seen:
                    seen[target] = True
                    out.append(target)
            continue
        if f.type_str.startswith("@@"):
            var target = String(f.type_str[byte=2 : f.type_str.byte_length()])
            if target not in seen:
                seen[target] = True
                out.append(target)
            continue
        if is_wrapped_relation_type(f.type_str):
            var target = relation_target_of(f.type_str)
            if target not in seen:
                seen[target] = True
                out.append(target)
            continue
        var base_name = _plain_struct_base_name(f.type_str)
        if base_name in plain_struct_fields:
            _collect_relation_targets(plain_struct_fields[base_name], plain_struct_fields, seen, out)


def relation_targets_for(
    fields: List[Field], plain_struct_fields: Dict[String, List[Field]]
) raises -> List[String]:
    """Convenience wrapper around `_collect_relation_targets`, allocating
    its own fresh `seen`/`out` -- used both internally (`sqrrl__from_json`
    codegen for one struct's own field list) and by
    `driver.build_relation_targets` to build the project-wide "struct
    name -> its own relation targets" map `sqrrl__world_from_json` needs
    to inject the right sibling-table arguments into each struct's own
    `sqrrl__all_from_json` call (see `driver.emit_world_module`)."""
    var seen = Dict[String, Bool]()
    var out = List[String]()
    _collect_relation_targets(fields, plain_struct_fields, seen, out)
    return out^


def _relation_target_params(targets: List[String]) -> String:
    """`, mut sqrrl__tbl_Department: sqrrl__DepartmentTable, ...` --
    `from_json`'s own parameter list beyond `mut self`/`mut sc`, one per
    entry in `_collect_relation_targets`'s output. `sqrrl__tbl_`-prefixed
    so a parameter can never collide with a field literally named the
    same as a target struct."""
    var out = String()
    for t in targets:
        out += String(t", mut sqrrl__tbl_{t}: {sqrrl_prefixed(t)}Table")
    return out^


def _relation_target_args(targets: List[String]) -> String:
    """The call-site counterpart to `_relation_target_params` -- passes
    each already-in-scope `sqrrl__tbl_<Target>` parameter straight
    through, whether from an enclosing struct's own `sqrrl__from_json`
    into a nested plain struct's `sqrrl__<Name>_from_json`, or from
    `sqrrl__all_from_json` into `sqrrl__from_json_with_id` (always a
    subset of the enclosing struct's own parameters, by construction --
    see `_collect_relation_targets`)."""
    var out = String()
    for t in targets:
        if out.byte_length() > 0:
            out += ", "
        out += String(t"sqrrl__tbl_{t}")
    return out^


def _relation_field_shape(f: Field) -> String:
    """Which of `from_json`'s three field-parsing shapes `f` needs --
    `"bare"` (a single id, `@@Employee`), `"multi"`/`"wrapped"` (an array
    of ids, `multi @@members: @@Employee` or `List[@@Employee]`), or
    `"optional"` (either an id or `null`, `Optional[@@Employee]`) for a
    relation field, versus `"plain"` for anything else (a leaf, a plain
    container, a nested plain struct, or a `multi`/wrapped field whose
    *element* isn't itself a relation) -- reconstructing a relation needs
    the target's own table (`self.<Target>.table.handle_for`), which the
    shared `sqrrl__from_json[T]` dispatcher has no way to reach, so these
    three shapes are the ones `emit_squirrel_from_json_method` inlines by
    hand instead of delegating to it."""
    if f.modifier == FieldModifier.MULTI:
        return "multi" if f.type_str.startswith("@@") else "plain"
    if f.type_str.startswith("@@"):
        return "bare"
    if is_wrapped_relation_type(f.type_str):
        if relation_wrapper_of(f.type_str) == "Optional":
            return "optional"
        return "wrapped"
    return "plain"


def _emit_from_json_field_parse(
    f: Field, tmp_prefix: String, plain_struct_fields: Dict[String, List[Field]]
) raises -> String:
    """The statement(s) `emit_table_json_methods`'s `from_json` runs once
    it's matched a JSON object key to field `f` -- assigns into
    `{tmp_prefix}{f.name}`, an `Optional[<field type>]` local declared
    before the parsing loop starts (see its own doc comment for why
    `Optional`, not the field type itself, is what gets declared). Relation
    lookups go through the already-in-scope `sqrrl__tbl_<Target>`
    parameter (see `_collect_relation_targets`/`_relation_target_params`)
    -- `from_json` takes one such parameter per distinct target its own
    fields need, rather than the whole `sqrrl__World`, specifically so
    it can stay a method on the struct's own table instead of moving to
    `sqrrl__World` (confirmed: `mut self: sqrrl__<Name>Table` plus
    disjoint sibling-table parameters doesn't alias, unlike `mut self`
    plus the whole `sqrrl__World` `self` is already part of).

    A `"plain"`-shaped field whose *own* type names a known plain struct
    (`home: Address`) can't go through the shared `sqrrl__from_json[T]`
    dispatcher either, for the same reason no struct ever can (see
    `emit_json_module`'s own doc comment) -- it's routed to
    `sqrrl__<Type>_from_json(...)` instead, a free function (a plain
    struct has no table of its own to be a method on), passed whichever
    subset of the enclosing `sqrrl__tbl_<Target>` parameters *that*
    struct's own fields need (always already in scope here, by
    construction -- see `_collect_relation_targets`). `sqrrl__`-*prefixed*
    for the same reason an entity's own `sqrrl__from_json` is a *method*
    on its own table, not a free function -- a plain struct's own
    `sqrrl__<Type>_from_json` free function has no table to live on, so
    its name isn't otherwise protected from colliding with an `@@struct`'s
    the way `sqrrl__<Name>TableState` already is."""
    var shape = _relation_field_shape(f)
    var var_name = tmp_prefix + f.name
    if shape == "bare":
        var target = String(f.type_str[byte=2 : f.type_str.byte_length()])
        return String(
            t"                    {var_name} ="
            t" sqrrl__tbl_{target}.table.handle_for(UInt32(sc.parse_json_int()))\n"
        )
    if shape == "multi" or shape == "wrapped":
        var target = String(f.type_str[byte=2 : f.type_str.byte_length()]) if shape == "multi" else relation_target_of(f.type_str)
        var wrapper = "Set" if shape == "multi" else relation_wrapper_of(f.type_str)
        var elem = String(t"EntityHandle[{sqrrl_prefixed(String(target))}TableState]")
        var out = String()
        out += String(t"                    var {var_name}_tmp = {wrapper}[{elem}]()\n")
        out += '                    sc.expect_byte(UInt8(ord("[")))\n'
        out += '                    if not sc.try_consume_byte(UInt8(ord("]"))):\n'
        out += "                        while True:\n"
        var add_call = "add" if wrapper == "Set" else "append"
        out += String(
            t"                            {var_name}_tmp.{add_call}(sqrrl__tbl_{target}.table.handle_for(UInt32(sc.parse_json_int())))\n"
        )
        out += '                            if sc.try_consume_byte(UInt8(ord(","))):\n'
        out += "                                continue\n"
        out += '                            sc.expect_byte(UInt8(ord("]")))\n'
        out += "                            break\n"
        out += String(t"                    {var_name} = {var_name}_tmp^\n")
        return out^
    if shape == "optional":
        var target = relation_target_of(f.type_str)
        var elem = String(t"EntityHandle[{sqrrl_prefixed(String(target))}TableState]")
        var out = String()
        out += '                    if sc.try_consume_literal("null"):\n'
        out += String(t"                        {var_name} = Optional[{elem}](None)\n")
        out += "                    else:\n"
        out += String(
            t"                        {var_name} ="
            t" Optional[{elem}](sqrrl__tbl_{target}.table.handle_for(UInt32(sc.parse_json_int())))\n"
        )
        return out^
    var field_type = emit_field_type(f)
    var base_name = _plain_struct_base_name(field_type)
    if base_name in plain_struct_fields:
        var nested_seen = Dict[String, Bool]()
        var nested_targets = List[String]()
        _collect_relation_targets(plain_struct_fields[base_name], plain_struct_fields, nested_seen, nested_targets)
        var nested_args = _relation_target_args(nested_targets)
        if nested_args.byte_length() > 0:
            nested_args += ", "
        if field_type != base_name:
            # A generic plain struct instantiation (`home: Box[String]`)
            # -- forward its own type argument(s), verbatim, as explicit
            # compile-time parameters to the companion, which declares
            # the matching `[T, ...]` list itself (see
            # `emit_plain_struct_from_json`). Only the *direct* field
            # type is handled this way here -- a generic instantiation
            # (or a non-generic plain struct) nested inside a container
            # (`List[Box[String]]`) is a different call shape (through
            # the shared `sqrrl__from_json[T]` dispatcher, not this
            # struct's own directly-declared-field parsing), handled
            # separately by `driver.build_json_container_types`'s
            # `plain_struct_dispatch_types` and `emit_json_module`'s own
            # generated branches for it.
            var type_args = String(
                field_type[byte = base_name.byte_length() + 1 : field_type.byte_length() - 1]
            )
            return String(
                t"                    {var_name} ="
                t" sqrrl__{base_name}_from_json[{type_args}]({nested_args}sc)\n"
            )
        return String(t"                    {var_name} = sqrrl__{base_name}_from_json({nested_args}sc)\n")
    return String(t"                    {var_name} = sqrrl__from_json[{field_type}](sc)\n")


def _emit_from_json_parse_loop(
    parsed: ParsedStruct, plain_struct_fields: Dict[String, List[Field]]
) raises -> String:
    """The field-declaration/parsing-loop body shared by `from_json` and
    `sqrrl__from_json_with_id` (`emit_table_json_methods`) -- byte-for-byte
    identical between the two; only the method signature around it and the
    final construction call (`self.create(...)` vs
    `self.sqrrl__create_with_id(id, ...)`) differ."""
    var out = String()
    for f in parsed.fields:
        out += String(t"        var sqrrl__parsed_{f.name}: Optional[{emit_field_type(f)}] = None\n")
    out += '        sc.expect_byte(UInt8(ord("{")))\n'
    out += '        if not sc.try_consume_byte(UInt8(ord("}"))):\n'
    out += "            while True:\n"
    out += "                var sqrrl__key = sc.parse_json_string()\n"
    out += '                sc.expect_byte(UInt8(ord(":")))\n'
    var first_field = True
    for f in parsed.fields:
        var keyword = "if" if first_field else "elif"
        out += String(t'                {keyword} sqrrl__key == "{f.name}":\n')
        first_field = False
        out += _emit_from_json_field_parse(f, "sqrrl__parsed_", plain_struct_fields)
    out += '                if sc.try_consume_byte(UInt8(ord(","))):\n'
    out += "                    continue\n"
    out += '                sc.expect_byte(UInt8(ord("}")))\n'
    out += "                break\n"
    return out^


def emit_table_json_methods(
    parsed: ParsedStruct, state_name: String, plain_struct_fields: Dict[String, List[Field]]
) raises -> String:
    """Generates `sqrrl__to_json`/`sqrrl__from_json` for one `@@struct`'s
    own `sqrrl__<Name>Table` -- unlike a plain struct (fully handled by
    the shared free-function `sqrrl__to_json`'s own reflection-based
    fallback with zero code generated for it, see `emit_json_module`), an
    entity's fields live in per-field `Rel`-backed table storage, not a
    flat, reflectable value struct -- serializing *one row* means going
    through `get_<field>`, the same accessor every other generated method
    already uses, not reflecting the `sqrrl__<Name>TableState` struct
    itself (that would expose the table's *storage machinery* -- every
    field wrapped in a `Rel`/`UniqueRel`/... -- not the row's own logical
    values). `sqrrl__`-prefixed, unlike `create`/`get_*`/`set_*` -- not
    DSL-reachable at all (there's no `@@Type.to_json(...)`/`@@Type.
    from_json(...)` sugar; a relation field's own bare-id serialization
    only really means anything alongside the rest of the world it points
    into, which is what whole-world serialization is for, see README's
    "JSON serialization" section) -- only ever called by
    `sqrrl__all_to_json` below and, for advanced/hand-written Mojo,
    directly on `sqrrl__world.<Name>`.

    Uniform across every field regardless of shape: a bare relation
    field's `get_<field>` already returns a live `EntityHandle[...]`, and
    `EntityHandle` conforms to `sqrrl__JsonSerializable` (serializing as
    its own bare id), so `sqrrl__to_json(self.get_<field>(e))` is correct
    whether the field is a leaf, a container, or a relation, wrapped or
    not (that's the shared free function of the same name, from
    `emit_json_module` -- distinct from this table's own method despite
    sharing a name, disambiguated the same way any two same-named methods
    on different types are).

    `sqrrl__from_json` is a method on `sqrrl__<Name>Table` itself (`self`,
    matching `create`/`get_*`/`set_*`) rather than on `sqrrl__World` --
    reconstructing a relation field needs the *target's own table*
    (`sqrrl__tbl_<Target>.table.handle_for`, to turn a parsed id back into
    a live handle), and passing the *whole* `sqrrl__World` as a second
    parameter alongside `self` doesn't actually work: `self`
    (`sqrrl__world.<Name>`) would already be *part of* `sqrrl__world`, so
    passing `sqrrl__world` again as an argument aliases memory `self`
    already holds a `mut` reference into -- confirmed, Mojo's own
    exclusivity checker rejects exactly this call shape ("argument ...
    allows writing a memory location previously writable through another
    aliased argument"). Passing only the *specific, disjoint* sibling
    tables a struct's own fields actually need (via
    `_collect_relation_targets`/`_relation_target_params`) sidesteps the
    conflict entirely: `self` and each `sqrrl__tbl_<Target>` are always
    different fields of `sqrrl__World`, never the whole aggregate.

    `_relation_field_shape`/`_emit_from_json_field_parse` inline
    bare/wrapped/`multi`/`Optional` relation parsing by hand per field
    (the shared `sqrrl__from_json[T]` dispatcher has no way to reach
    another table at all, regardless of this aliasing issue), falling
    back to `sqrrl__from_json[FieldType](sc)` for everything else. Every
    parsed field is collected into an `Optional[<field type>]` local (not
    the field type directly) purely so a field can be declared *before*
    the order-independent key-matching loop populates it, then unwrapped
    via `.take()` (aborts if a required key was missing from the JSON
    object -- same "trust the input" convention `Rel`/`OrderedRel`
    already use elsewhere) when building the final `self.create(...)`
    call, since JSON object keys have no guaranteed order to rely on
    instead."""
    var out = String()
    out += String(t"    def sqrrl__to_json(self, e: EntityHandle[{state_name}]) -> String:\n")
    out += '        var out = String("{")\n'
    var first = True
    for f in parsed.fields:
        if not first:
            out += '        out += ","\n'
        first = False
        out += String(
            t'        out += "\\"{f.name}\\":" + sqrrl__to_json(self.get_{f.name}(e))\n'
        )
    out += '        out += "}"\n'
    out += "        return out^\n"

    var targets = List[String]()
    var seen = Dict[String, Bool]()
    _collect_relation_targets(parsed.fields, plain_struct_fields, seen, targets)

    out += "\n"
    out += String(t"    def sqrrl__from_json(mut self{_relation_target_params(targets)}, mut sc: sqrrl__JsonScanner) raises ->")
    out += String(t" EntityHandle[{state_name}]:\n")
    out += _emit_from_json_parse_loop(parsed, plain_struct_fields)
    out += String(t"        return self.create(")
    var first_arg = True
    for f in parsed.fields:
        if not first_arg:
            out += ", "
        first_arg = False
        out += String(t"sqrrl__parsed_{f.name}.take()")
    out += ")\n"

    # `sqrrl__from_json_with_id` -- `sqrrl__from_json`'s twin, used only by
    # `sqrrl__world_from_json` (`emit_world_module`) to reconstruct a whole
    # `sqrrl__World` from a JSON dump: an entity has to land back on its
    # exact original id (embedded alongside its own JSON blob at the world
    # level, unlike a lone struct's own `sqrrl__to_json`/`sqrrl__from_json`,
    # which never need an entity's own id -- only what it *references* is
    # ever a bare id) for any other entity's relation field pointing at it
    # to resolve correctly, hence `self.sqrrl__create_with_id(sqrrl__id,
    # ...)` in place of `self.create(...)`.
    out += "\n"
    out += String(
        t"    def sqrrl__from_json_with_id(mut self{_relation_target_params(targets)}, sqrrl__id:"
        t" UInt32, mut sc: sqrrl__JsonScanner) raises ->"
    )
    out += String(t" EntityHandle[{state_name}]:\n")
    out += _emit_from_json_parse_loop(parsed, plain_struct_fields)
    out += String(t"        return self.sqrrl__create_with_id(sqrrl__id")
    for f in parsed.fields:
        out += String(t", sqrrl__parsed_{f.name}.take()")
    out += ")\n"

    # `sqrrl__all_to_json`/`sqrrl__all_from_json` -- the whole-table
    # counterpart to a single entity's own `sqrrl__to_json`/
    # `sqrrl__from_json`, used only by `sqrrl__World.to_json`/
    # `sqrrl__world_from_json` (`emit_world_module`) so the per-table
    # "array of [id, entity json] pairs" shape (and its parsing) is
    # written once here rather than re-spelled inline once per struct at
    # the world level.
    #
    # `sqrrl__all_to_json` needs no sibling-table params (a single
    # entity's own `sqrrl__to_json` never does either); returns just the
    # bracketed array, not `"Name":[...]` -- the key itself is the one
    # thing only the world level knows to attach. `sqrrl__all_from_json`
    # is the exact reverse: parses that same array, reconstructing each
    # entity via `sqrrl__from_json_with_id` (landing it back on its
    # original id). A `keepalive`-tagged struct's own
    # `sqrrl__create_with_id` already retains it automatically, same as
    # `create` does -- a non-tagged struct's has nothing else holding it
    # yet (no relation field pointing at it, no `keepalive` tag), so it
    # takes one further parameter, `mut sqrrl__temp:
    # List[EntityHandle[...]]`, and appends there instead -- the caller
    # (`sqrrl__world_from_json`) passes in the matching field of
    # `sqrrl__World`'s own `TempKeepAlives` (see `emit_world_module`'s doc
    # comment), *not* this table's own `keepalive` set, which stays
    # reserved for genuinely `keepalive`-tagged structs.
    out += "\n"
    out += "    def sqrrl__all_to_json(self) -> String:\n"
    out += '        var out = String("[")\n'
    out += "        var sqrrl__first = True\n"
    out += "        for sqrrl__e in self.all():\n"
    out += "            if not sqrrl__first:\n"
    out += '                out += ","\n'
    out += "            sqrrl__first = False\n"
    out += (
        '            out += "[" + String(sqrrl__e.id()) + "," + self.sqrrl__to_json(sqrrl__e) + "]"\n'
    )
    out += '        out += "]"\n'
    out += "        return out^\n"

    out += "\n"
    var temp_param = String() if parsed.is_keepalive else String(
        t", mut sqrrl__temp: List[EntityHandle[{state_name}]]"
    )
    out += String(
        t"    def sqrrl__all_from_json(mut self{_relation_target_params(targets)}{temp_param}, mut sc:"
        t" sqrrl__JsonScanner) raises:\n"
    )
    out += '        sc.expect_byte(UInt8(ord("[")))\n'
    out += '        if not sc.try_consume_byte(UInt8(ord("]"))):\n'
    out += "            while True:\n"
    out += '                sc.expect_byte(UInt8(ord("[")))\n'
    out += "                var sqrrl__id = UInt32(sc.parse_json_int())\n"
    out += '                sc.expect_byte(UInt8(ord(",")))\n'
    var target_args = _relation_target_args(targets)
    if target_args.byte_length() > 0:
        target_args += ", "
    if parsed.is_keepalive:
        out += String(
            t"                _ = self.sqrrl__from_json_with_id({target_args}sqrrl__id, sc)\n"
        )
    else:
        out += String(
            t"                var sqrrl__e ="
            t" self.sqrrl__from_json_with_id({target_args}sqrrl__id, sc)\n"
        )
        out += "                sqrrl__temp.append(sqrrl__e^)\n"
    out += '                sc.expect_byte(UInt8(ord("]")))\n'
    out += '                if sc.try_consume_byte(UInt8(ord(","))):\n'
    out += "                    continue\n"
    out += '                sc.expect_byte(UInt8(ord("]")))\n'
    out += "                break\n"
    return out^


def emit_plain_struct_from_json(
    parsed: ParsedStruct, plain_struct_fields: Dict[String, List[Field]]
) raises -> String:
    """Generates `sqrrl__{Name}_from_json`, a plain struct's own
    reconstruction companion (shorthand or hand-written -- `parsed.fields`
    already carries either shape uniformly by the time this runs, see
    `driver.build_plain_struct_fields`) -- `sqrrl__to_json` already
    handles *serializing* any plain struct automatically via reflection
    (see `emit_json_module`'s own doc comment), so this is only needed for
    the opposite direction, same reasoning `emit_table_json_methods`
    documents for `@@struct`s: writing into a reflected field requires
    `Ti` to prove `Movable`/`ImplicitlyDeletable` as an explicit type
    argument, which never works, so the field list has to be known and
    spelled out literally by the generator instead. Generated into
    `sqrrl__json.mojo` (`driver.build_json_module_source`), alongside the
    rest of JSON serialization's generated code, not `sqrrl__world.mojo`
    -- nothing about it needs anything `sqrrl__World` itself provides.

    A free function (a plain struct has no table of its own to be a
    method on), taking one `sqrrl__tbl_<Target>` parameter per distinct
    relation target its *own* fields need, for the same reason an
    entity's own `sqrrl__from_json` does: a plain struct can embed a
    relation field of its own (`Note { @@author: @@Employee, ... }`, see
    the README's "Plain structs" section), which needs
    `sqrrl__tbl_<Target>.table.handle_for` to reconstruct. `sqrrl__`-
    prefixed so this free function can never collide with an `@@struct`'s
    own `sqrrl__from_json` *method* even if a project somehow declares
    both with the identical name -- see `_emit_from_json_field_parse`'s
    own doc comment.

    A *generic* plain struct (`parsed.type_params` non-empty) gets its own
    `[T: Bound, ...]` list spliced in between the function name and its
    value-parameter list (`_emit_type_param_list`), and its return type
    becomes the concrete instantiation `{Name}[T, ...]`
    (`_emit_type_arg_list`) rather than the bare name -- a field typed
    `T` then just falls through `_emit_from_json_field_parse`'s ordinary
    `sqrrl__from_json[T](sc)` fallback, `T` already being in scope as one
    of this function's own type parameters, no different from any other
    concrete field type. The final constructor call is instantiated
    explicitly (`{Name}[T, ...](...)`, not the bare name) rather than
    relying on Mojo to infer it from the field arguments' own types --
    cheap to spell out, and removes any doubt about whether inference
    would actually land on the right instantiation."""
    var targets = List[String]()
    var seen = Dict[String, Bool]()
    _collect_relation_targets(parsed.fields, plain_struct_fields, seen, targets)
    var params = _relation_target_params(targets)
    # `_relation_target_params` is built for `def from_json(mut self, ...)`
    # (leading `, `) -- here there's no `mut self` to lead with, so the
    # first parameter (if any) needs its leading ", " trimmed to " ".
    if params.byte_length() > 0:
        params = String(params[byte=2 : params.byte_length()])

    var out = String()
    out += String(
        t"def sqrrl__{parsed.name}_from_json{_emit_type_param_list(parsed.type_params)}({params}"
    )
    if params.byte_length() > 0:
        out += ", "
    out += String(t"mut sc: sqrrl__JsonScanner) raises ->")
    out += String(t" {parsed.name}{_emit_type_arg_list(parsed.type_params)}:\n")
    for f in parsed.fields:
        out += String(t"    var sqrrl__parsed_{f.name}: Optional[{emit_field_type(f)}] = None\n")
    out += '    sc.expect_byte(UInt8(ord("{")))\n'
    out += '    if not sc.try_consume_byte(UInt8(ord("}"))):\n'
    out += "        while True:\n"
    out += "            var sqrrl__key = sc.parse_json_string()\n"
    out += '            sc.expect_byte(UInt8(ord(":")))\n'
    var first_field = True
    for f in parsed.fields:
        var keyword = "if" if first_field else "elif"
        out += String(t'            {keyword} sqrrl__key == "{f.name}":\n')
        first_field = False
        out += _emit_from_json_field_parse(f, "sqrrl__parsed_", plain_struct_fields)
    out += '            if sc.try_consume_byte(UInt8(ord(","))):\n'
    out += "                continue\n"
    out += '            sc.expect_byte(UInt8(ord("}")))\n'
    out += "            break\n"
    out += String(t"    return {parsed.name}{_emit_type_arg_list(parsed.type_params)}(")
    var first_arg = True
    for f in parsed.fields:
        if not first_arg:
            out += ", "
        first_arg = False
        out += String(t"sqrrl__parsed_{f.name}.take()")
    out += ")\n"
    return out^


