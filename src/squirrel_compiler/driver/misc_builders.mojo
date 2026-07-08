from squirrel_compiler.parser import Scanner, Field, ParsedStruct
from squirrel_compiler.codegen import encode_container_type, recover_relation_type_str
from squirrel_compiler.driver.discovery import DiscoveredStruct
from squirrel_compiler.driver.file_paths import module_path_for


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


def discover_hand_written_plain_structs(rel_files: List[String], target_root: String) raises -> List[DiscoveredStruct]:
    """`discover_plain_structs`'s counterpart for the *hand-written* form
    (`struct Name(Traits...):`/`struct Name:`, a real Mojo struct, not the
    brace-shorthand grammar) -- closes the one gap `find_next_plain_struct_decl`'s
    own doc comment used to call "accepted": a relation field smuggled
    through a hand-written plain struct's own body used to be invisible to
    `check_no_relation_cycles` entirely, since only the shorthand form was
    ever folded into the project-wide relation graph. `Field.type_str` for
    each field is run through `recover_relation_type_str` (the same
    normalization `build_plain_struct_fields` already applies before
    handing a hand-written struct's fields to `_emit_from_json_field_parse`)
    so a relation field spelled out by hand as
    `EntityHandle[sqrrl__EmployeeTableState]` reads back as the pseudo
    `@@Employee` shorthand `_relation_targets`/`is_wrapped_relation_type`
    already expect -- letting `check_no_relation_cycles` treat a
    hand-written struct exactly like a shorthand one, with no separate
    code path of its own."""
    var out = List[DiscoveredStruct]()
    for path in rel_files:
        var module_path = module_path_for(path, target_root)
        var f = open(path, "r")
        var source = f.read()
        f.close()

        var sc = Scanner(source)
        try:
            while sc.find_next_hand_written_plain_struct_decl():
                var parsed = sc.parse_hand_written_plain_struct()
                var fields = List[Field]()
                for field in parsed.fields:
                    fields.append(
                        Field(
                            name=field.name,
                            type_str=recover_relation_type_str(field.type_str),
                            modifier=field.modifier,
                        )
                    )
                out.append(
                    DiscoveredStruct(
                        module_path, ParsedStruct(name=parsed.name, fields=fields^, type_params=parsed.type_params.copy())
                    )
                )
        except e:
            raise Error(path + ": " + String(e))

    return out^


def check_single_declare_call(rel_files: List[String]) raises:
    """Rejects more than one `@@declare()` call across the whole project.
    `@@declare()` is the single point that brings `sqrrl__world` into
    scope (`var sqrrl__world: sqrrl__World`, deliberately uninitialized)
    for a whole script -- any number of `@@init()`/`@@start_init_from_json(
    ...)` calls may follow it, in any control-flow shape, each assigning
    into the same `sqrrl__world` (see `rewrite_markers`'s own handling of
    all three), so unlike the old "exactly one construction call" rule
    this replaced, it's `@@declare()` itself, not the construction calls,
    that has to be unique project-wide -- two of *those* would mean two
    disconnected `sqrrl__world` bindings with no shared scope between them,
    silently defeating the whole `@@` threading design (confirmed: nothing
    else stops that from compiling and running, just with two independent
    sets of tables instead of one shared one). A project with no
    `@@declare()` at all is fine (a schema-only library file, say) -- an
    `@@init()`/`@@start_init_from_json(...)` call with no `@@declare()`
    before it in the same function is instead caught by
    `rewrite_markers` itself, once codegen actually reaches that call
    site, since only `@@declare()` establishes the `sqrrl__world` name
    for those to assign into."""
    var declare_sites = List[String]()
    for path in rel_files:
        var f = open(path, "r")
        var source = f.read()
        f.close()

        var sc = Scanner(source)
        while sc.find_next_declare_call():
            sc.parse_declare()
            declare_sites.append(path)

    if len(declare_sites) > 1:
        var files = String()
        for i in range(len(declare_sites)):
            if i > 0:
                files += ", "
            files += declare_sites[i]
        raise Error(
            "InvalidSquirrelSyntax: @@declare() called "
            + String(len(declare_sites))
            + " times across the project ("
            + files
            + ") -- it should be called exactly once (typically in the"
            " entry point); thread the result to every other function via"
            " '@@' in its parameters instead of calling @@declare() again"
        )


