from squirrel_compiler.parser.type_expr import parse_type_expr


def is_wrapped_relation_type(type_str: String) -> Bool:
    """True if `type_str` (a `@@struct` field's raw type text, from
    `Scanner.scan_type`) looks like `Ident[@@Type]` -- e.g.
    `List[@@Employee]` -- the collection form of a relation field,
    alongside the existing bare `@@Type` form. Mirrors `EntityParam.wrapper`'s
    `Container[@@Type]` shape, just written directly as a struct field's
    type instead of after a `:` in a declaration. Only the *first* type
    argument is checked (matching every caller's own single-relation
    assumption elsewhere -- a container ever taking a relation in a
    later argument position, `Dict[String, @@Employee]` say, isn't a shape
    this grammar produces today)."""
    var t = parse_type_expr(type_str)
    return t.is_parameterized() and t.arg_count() >= 1 and t.arg(0).is_relation()


def relation_target_of(type_str: String) -> String:
    """The target type name of a relation field's `type_str`, whether bare
    (`@@Employee` -> `Employee`) or wrapped (`List[@@Employee]` ->
    `Employee`). Requires `type_str.startswith("@@")` or
    `is_wrapped_relation_type(type_str)`."""
    var t = parse_type_expr(type_str)
    if t.is_relation():
        return t.name
    return t.arg(0).name


def relation_wrapper_of(type_str: String) -> String:
    """The container identifier of a wrapped relation field's `type_str`
    -- `List[@@Employee]` -> `List`. Requires
    `is_wrapped_relation_type(type_str)`. Same one-line shape as
    `codegen.container_wrapper_of`/`codegen._plain_struct_base_name` --
    deliberately not shared with either: this is the parser layer,
    which `codegen` depends on, never the other way around."""
    return parse_type_expr(type_str).name

