from squirrel_compiler.parser import is_ident_char, source_location, Field, ConstructField, Construct, FieldAccess
from squirrel_compiler.codegen.helpers import (
    is_container_type,
    container_wrapper_of,
    container_element_of,
)
from squirrel_compiler.codegen.rewrite import rewrite_markers


def line_start_of(source: String, pos: Int) -> Int:
    """Byte offset where the line containing `pos` begins."""
    var bytes = source.as_bytes()
    var line_start = pos
    while line_start > 0 and bytes[line_start - 1] != UInt8(ord("\n")):
        line_start -= 1
    return line_start


def indent_of(source: String, pos: Int) -> String:
    """The leading whitespace of the line containing `pos` -- `@@{`'s
    own indentation, used to open a `try:` at that same level and its
    `@@}` counterpart to close it with a `finally:` at that same
    level again, with the body one level deeper than both."""
    var line_start = line_start_of(source, pos)
    var bytes = source.as_bytes()
    var indent_end = line_start
    while indent_end < pos and (
        bytes[indent_end] == UInt8(ord(" ")) or bytes[indent_end] == UInt8(ord("\t"))
    ):
        indent_end += 1
    return String(source[byte = line_start : indent_end])


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


def is_in_import_statement(source: String, pos: Int) -> Bool:
    """True if byte offset `pos` sits on a line that starts (after
    indentation) with `from ` or `import ` -- i.e. `pos` names something
    being imported (`from logic.factories import @@make_department`)
    rather than a value being referenced anywhere else. A `WORLD_FUNC`
    name used this way is neither a declaration (there's no `=`) nor
    something `entity_to_type` would ever know about (it's a function
    being imported, not an entity being bound), so `NAME_REF`'s ordinary
    "was this ever constructed or bound" check doesn't apply here -- the
    name just needs its `sqrrl__` prefix, exactly like the plain,
    un-prefixed names already imported alongside it on the same line.
    Assumed to fit on one line, matching every example so far (same
    assumption `is_in_def_signature` already makes for a `def` line)."""
    var line_start = line_start_of(source, pos)
    var bytes = source.as_bytes()
    var indent_end = line_start
    while indent_end < pos and (
        bytes[indent_end] == UInt8(ord(" ")) or bytes[indent_end] == UInt8(ord("\t"))
    ):
        indent_end += 1
    var prefix = String(source[byte = indent_end : pos])
    return prefix.startswith("from ") or prefix.startswith("import ")


def crosses_top_level_def(text: String) -> Bool:
    """True if `text` spans a line starting at column 0 with `def ` --
    i.e. it crosses into a new top-level function body. Mojo has no mutable
    global/static state (see `Table`'s doc comment in `entity.mojo`), so
    `sqrrl__world` only lives inside whichever function called `@@{`
    or received it as a parameter; `transform_source` uses this to reset
    its per-function bookkeeping (`entity_to_type`, `world_declared`) at
    each such boundary, rather than tracking it once for the whole file --
    which previously let a second function silently reference state that
    only existed in a sibling function's scope."""
    if text.startswith("def "):
        return True
    return "\ndef " in text


def is_unmarked_var_target(source: String, pos: Int) -> Bool:
    """True if, scanning backward from byte offset `pos`, the immediately
    preceding text matches `var IDENT = ` where `IDENT` is *not*
    `@@`-marked -- i.e. `pos` is the start of the right-hand side of a
    plain, unmarked variable declaration. Used to reject binding an
    entity-returning function call's result to a variable that isn't
    itself `@@`-marked (`var x = @@make_employer();`) -- the same call used
    as a sub-expression/argument instead (`report(@@make_employer());`),
    where there's no variable at all to mark, correctly doesn't match
    this."""
    var bytes = source.as_bytes()
    var i = pos
    while i > 0 and (bytes[i - 1] == UInt8(ord(" ")) or bytes[i - 1] == UInt8(ord("\t"))):
        i -= 1
    if i == 0 or bytes[i - 1] != UInt8(ord("=")):
        return False
    if i >= 2 and bytes[i - 2] == UInt8(ord("=")):
        return False  # "==" isn't an assignment
    i -= 1
    while i > 0 and (bytes[i - 1] == UInt8(ord(" ")) or bytes[i - 1] == UInt8(ord("\t"))):
        i -= 1
    var ident_end = i
    while i > 0 and is_ident_char(bytes[i - 1]):
        i -= 1
    if i == ident_end:
        return False
    if i >= 2 and bytes[i - 1] == UInt8(ord("@")) and bytes[i - 2] == UInt8(ord("@")):
        return False  # marked -- the existing pending_decl path covers this
    while i > 0 and (bytes[i - 1] == UInt8(ord(" ")) or bytes[i - 1] == UInt8(ord("\t"))):
        i -= 1
    return i >= 3 and String(source[byte = i - 3 : i]) == "var"


def enforce_entity_binding(
    source: String,
    marker_start: Int,
    pending_decl: Optional[String],
    mut entity_to_type: Dict[String, String],
    registered_type: String,
    call_text: String,
) raises:
    """Shared by every call that returns a single entity or a container of
    them (`create`, a `unique` field's `for_<field>`, a non-unique
    `for_<field>`, a relation field's `get_<field>`, or a `def @@funcName(
    ...) -> @@Type:`/`-> Container[@@Type]:` call): binding it to a `var
    @@x = ...` declaration tracks `registered_type` (bare, or
    `encode_container_type`-encoded) in `entity_to_type`; binding it to a
    plain, unmarked variable instead is rejected with a clear,
    container-aware error. `call_text` is the call as written, without its
    leading `@@` (`func_name + "()"`, `fa.entity + "." + fa.field +
    "(...)"`), embedded in the error message either way."""
    if pending_decl:
        entity_to_type[pending_decl.value()] = registered_type
    elif is_unmarked_var_target(source, marker_start):
        raise Error(
            source_location(source, marker_start)
            + ": InvalidSquirrelSyntax: '@@"
            + call_text
            + "' returns "
            + (
                "'"
                + container_wrapper_of(registered_type)
                + "[@@"
                + container_element_of(registered_type)
                + "]'" if is_container_type(registered_type) else "'@@" + registered_type + "'"
            )
            + " -- bind it to an '@@'-marked variable"
            " ('var @@x = @@"
            + call_text
            + ";'), not a plain one"
        )


def build_create_call(
    source: String,
    marker_start: Int,
    type_name: String,
    fields: List[ConstructField],
    relation_schema: Dict[String, Dict[String, String]],
    function_returns: Dict[String, String],
    unique_fields: Dict[String, List[String]],
    ordered_fields: Dict[String, List[String]],
    plain_struct_fields: Dict[String, List[Field]],
    relation_targets: Dict[String, List[String]],
    mut entity_to_type: Dict[String, String],
    mut world_declared: Bool,
) raises -> String:
    """Builds `sqrrl__world.TypeName.create(name = value, ...)`, validating
    each field's `@@` marking against `relation_schema[type_name]` -- must
    match the struct's own declaration, the same way a mismatched
    struct-field declaration itself is already rejected (`parse_fields`) --
    and recursively rewriting *every* field's value through
    `rewrite_markers` (not only a relation field's), so any `@@`-marked
    expression embedded anywhere inside it -- a bare reference (`@@bob`), a
    nested construct (`@@Employee { ... }`), a chained field read, a call
    to an `@@`-marked function, however deeply nested inside an otherwise
    ordinary expression (`Address(@@dept.name)`) -- rewrites correctly
    instead of passing straight through as literal, uncompilable text. A
    field with no embedded markers at all comes back byte-for-byte
    unchanged, same as before. `entity_to_type`/`world_declared` are
    threaded through (not copied) so a nested fragment sees exactly what
    the enclosing function has already established (an entity it
    constructed earlier, or that `sqrrl__world` has already been declared)
    -- neither a top-level nor a nested construct binds a name of its own
    here, so both are only ever read through this call, but still need to
    be `mut` to flow into the recursive `rewrite_markers` calls below.
    `source`/`marker_start` are only for error location -- the `@@TypeName{`
    construct's own start, since individual fields don't carry a position of
    their own (`ConstructField` is built purely from parsed text)."""
    var type_relations = (
        relation_schema[type_name].copy() if type_name in relation_schema else Dict[String, String]()
    )
    var args = String()
    var first = True
    for f in fields:
        var declared_as_relation = f.name in type_relations
        if f.is_relation and not declared_as_relation:
            raise Error(
                source_location(source, marker_start)
                + ": InvalidSquirrelSyntax: '"
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
                source_location(source, marker_start)
                + ": InvalidSquirrelSyntax: '"
                + type_name
                + "."
                + f.name
                + "' is declared as a relation field (`@@"
                + f.name
                + ": @@...`) -- must be written '.@@"
                + f.name
                + "' here too"
            )
        var value = rewrite_markers(
            f.value,
            relation_schema,
            function_returns,
            unique_fields,
            ordered_fields,
            plain_struct_fields,
            relation_targets,
            entity_to_type,
            world_declared,
        )
        if not first:
            args += ", "
        args += f.name + " = " + value
        first = False
    return String(t"sqrrl__world.{type_name}.create({args})")


