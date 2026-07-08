from std.testing import assert_equal, assert_true, assert_false, assert_raises, TestSuite

from squirrel_compiler.parser import (
    Scanner,
    ParsedStruct,
    Field,
    FieldModifier,
    parse_fields,
    MarkerKind,
    is_wrapped_relation_type,
    relation_target_of,
    relation_wrapper_of,
    TypeExpr,
    parse_type_expr,
)


def test_find_next_struct_decl_ignores_comment() raises:
    var sc = Scanner("// not @@struct Real\n@@struct @@Actual:\n    x: u32\n")
    assert_true(sc.find_next_struct_decl())
    assert_true(sc.starts_with("@@struct @@Actual"))


def test_find_next_struct_decl_ignores_string() raises:
    var sc = Scanner('const s = "@@struct @@Fake:\n    x: u32\n";\n@@struct @@Real:\n    y: u32\n')
    assert_true(sc.find_next_struct_decl())
    assert_true(sc.starts_with("@@struct @@Real"))


def test_find_next_struct_decl_returns_false_when_absent() raises:
    var sc = Scanner("no structs here at all")
    assert_false(sc.find_next_struct_decl())


def test_parse_struct_basic() raises:
    var sc = Scanner("@@struct @@Foo:\n    x: u32\n    label: String\n")
    assert_true(sc.find_next_struct_decl())
    var parsed = sc.parse_struct()
    assert_equal(parsed.name, String("Foo"))
    assert_equal(len(parsed.fields), 2)
    assert_equal(parsed.fields[0].name, String("x"))
    assert_equal(parsed.fields[0].type_str, String("u32"))
    assert_equal(parsed.fields[1].name, String("label"))
    assert_equal(parsed.fields[1].type_str, String("String"))


def test_parse_struct_recognizes_keepalive() raises:
    var sc = Scanner("@@struct keepalive @@Foo:\n    x: u32\n")
    assert_true(sc.find_next_struct_decl())
    var parsed = sc.parse_struct()
    assert_equal(parsed.name, String("Foo"))
    assert_true(parsed.is_keepalive)


def test_parse_struct_without_keepalive_defaults_false() raises:
    var sc = Scanner("@@struct @@Foo:\n    x: u32\n")
    assert_true(sc.find_next_struct_decl())
    var parsed = sc.parse_struct()
    assert_false(parsed.is_keepalive)


def test_parse_struct_tolerates_comment_in_body() raises:
    """A `//`/`#` comment line inside the indented body, at the same
    indentation as the fields around it, is skipped rather than mistaken
    for a field or confusing the block's own indentation-based extent
    (no braces to miscount here, unlike the old brace-delimited grammar --
    the risk is a comment's own text being misread as a dedent or a field
    name instead)."""
    var sc = Scanner("@@struct @@Foo:\n    // odd text: not a field\n    x: u32\n")
    assert_true(sc.find_next_struct_decl())
    var parsed = sc.parse_struct()
    assert_equal(parsed.name, String("Foo"))
    assert_equal(len(parsed.fields), 1)
    assert_equal(parsed.fields[0].name, String("x"))


def test_parse_struct_tolerates_nested_brackets_in_type() raises:
    var sc = Scanner("@@struct @@Foo:\n    x: u32\n    tags: List[u32]\n")
    assert_true(sc.find_next_struct_decl())
    var parsed = sc.parse_struct()
    assert_equal(len(parsed.fields), 2)
    assert_equal(parsed.fields[1].type_str, String("List[u32]"))


def test_parse_struct_rejects_duplicate_field_names() raises:
    var sc = Scanner("@@struct @@Foo:\n    x: u32\n    x: f32\n")
    assert_true(sc.find_next_struct_decl())
    with assert_raises():
        _ = sc.parse_struct()


def test_parse_struct_rejects_malformed_input() raises:
    var sc = Scanner("@@struct Foo not_braces")
    assert_true(sc.find_next_struct_decl())
    with assert_raises():
        _ = sc.parse_struct()


def test_parse_struct_relation_field() raises:
    var sc = Scanner("@@struct @@Person:\n    @@employee: @@Employee\n")
    assert_true(sc.find_next_struct_decl())
    var parsed = sc.parse_struct()
    assert_equal(len(parsed.fields), 1)
    assert_equal(parsed.fields[0].name, String("employee"))
    assert_equal(parsed.fields[0].type_str, String("@@Employee"))


def test_parse_struct_rejects_unmarked_name_with_relation_type() raises:
    var sc = Scanner("@@struct @@Person:\n    employee: @@Employee\n")
    assert_true(sc.find_next_struct_decl())
    with assert_raises():
        _ = sc.parse_struct()


def test_parse_struct_rejects_marked_name_with_non_relation_type() raises:
    var sc = Scanner("@@struct @@Person:\n    @@age: u32\n")
    assert_true(sc.find_next_struct_decl())
    with assert_raises():
        _ = sc.parse_struct()


def test_parse_struct_wrapped_relation_field() raises:
    var sc = Scanner("@@struct @@Department:\n    @@members: List[@@Employee]\n")
    assert_true(sc.find_next_struct_decl())
    var parsed = sc.parse_struct()
    assert_equal(len(parsed.fields), 1)
    assert_equal(parsed.fields[0].name, String("members"))
    assert_equal(parsed.fields[0].type_str, String("List[@@Employee]"))
    assert_true(is_wrapped_relation_type(parsed.fields[0].type_str))
    assert_equal(relation_target_of(parsed.fields[0].type_str), String("Employee"))
    assert_equal(relation_wrapper_of(parsed.fields[0].type_str), String("List"))


def test_parse_struct_rejects_unmarked_name_with_wrapped_relation_type() raises:
    var sc = Scanner("@@struct @@Department:\n    members: List[@@Employee]\n")
    assert_true(sc.find_next_struct_decl())
    with assert_raises():
        _ = sc.parse_struct()


def test_parse_struct_allows_unique_on_wrapped_relation_field() raises:
    """A collection-typed relation field CAN be `unique` -- `List[@@Employee]`
    is `KeyElement` exactly when `@@Employee` (an `EntityHandle`) is, which
    it always is, so there's nothing collection-specific to reject (unlike
    `forwardonly`, an explicit opt-out of `KeyElement` storage entirely,
    which genuinely conflicts with `unique`)."""
    var sc = Scanner("@@struct @@Department:\n    unique @@members: List[@@Employee]\n")
    assert_true(sc.find_next_struct_decl())
    var parsed = sc.parse_struct()
    assert_equal(len(parsed.fields), 1)
    assert_true(parsed.fields[0].modifier == FieldModifier.UNIQUE)


def test_parse_struct_forward_only_field() raises:
    var sc = Scanner("@@struct @@Foo:\n    forwardonly scores: List[Int]\n")
    assert_true(sc.find_next_struct_decl())
    var parsed = sc.parse_struct()
    assert_equal(len(parsed.fields), 1)
    assert_equal(parsed.fields[0].name, String("scores"))
    assert_equal(parsed.fields[0].type_str, String("List[Int]"))
    assert_true(parsed.fields[0].modifier == FieldModifier.FORWARD_ONLY)
    assert_false(parsed.fields[0].modifier == FieldModifier.UNIQUE)


def test_parse_struct_forward_only_field_name_not_mistaken() raises:
    """A field merely starting with `forwardonly` (`forwardonlyId`) isn't
    mistaken for the keyword -- word-boundary checked the same way `unique`
    already is. A field literally, exactly named `forwardonly` is as
    inherently ambiguous with the keyword as one literally named `unique`
    already is -- a pre-existing limitation, not new here."""
    var sc = Scanner("@@struct @@Foo:\n    forwardonlyId: String\n")
    assert_true(sc.find_next_struct_decl())
    var parsed = sc.parse_struct()
    assert_equal(len(parsed.fields), 1)
    assert_equal(parsed.fields[0].name, String("forwardonlyId"))
    assert_false(parsed.fields[0].modifier == FieldModifier.FORWARD_ONLY)


def test_parse_struct_rejects_unique_and_forward_only_together() raises:
    var sc = Scanner("@@struct @@Foo:\n    unique forwardonly scores: List[Int]\n")
    assert_true(sc.find_next_struct_decl())
    with assert_raises():
        _ = sc.parse_struct()


def test_parse_struct_multi_relation_field() raises:
    """`multi @@members: @@Employee` -- the element type is written bare,
    not wrapped in `List[...]` -- the `multi` keyword itself already means
    "many of these"."""
    var sc = Scanner("@@struct @@Department:\n    multi @@members: @@Employee\n")
    assert_true(sc.find_next_struct_decl())
    var parsed = sc.parse_struct()
    assert_equal(len(parsed.fields), 1)
    assert_equal(parsed.fields[0].name, String("members"))
    assert_equal(parsed.fields[0].type_str, String("@@Employee"))
    assert_true(parsed.fields[0].modifier == FieldModifier.MULTI)
    assert_false(parsed.fields[0].modifier == FieldModifier.UNIQUE)
    assert_false(parsed.fields[0].modifier == FieldModifier.FORWARD_ONLY)


def test_parse_struct_multi_plain_field() raises:
    """`multi` isn't restricted to relation fields -- `multi tags: String`
    means "each row can hold several of these strings", indexed
    individually, no different in kind from a relation element."""
    var sc = Scanner("@@struct @@Department:\n    multi tags: String\n")
    assert_true(sc.find_next_struct_decl())
    var parsed = sc.parse_struct()
    assert_equal(len(parsed.fields), 1)
    assert_equal(parsed.fields[0].name, String("tags"))
    assert_equal(parsed.fields[0].type_str, String("String"))
    assert_true(parsed.fields[0].modifier == FieldModifier.MULTI)


def test_parse_struct_multi_field_name_not_mistaken() raises:
    var sc = Scanner("@@struct @@Foo:\n    multiplier: Int\n")
    assert_true(sc.find_next_struct_decl())
    var parsed = sc.parse_struct()
    assert_equal(len(parsed.fields), 1)
    assert_equal(parsed.fields[0].name, String("multiplier"))
    assert_false(parsed.fields[0].modifier == FieldModifier.MULTI)


def test_parse_struct_rejects_unique_and_multi_together() raises:
    var sc = Scanner("@@struct @@Department:\n    unique multi @@members: @@Employee\n")
    assert_true(sc.find_next_struct_decl())
    with assert_raises():
        _ = sc.parse_struct()


def test_parse_struct_rejects_forward_only_and_multi_together() raises:
    var sc = Scanner("@@struct @@Department:\n    forwardonly multi @@members: @@Employee\n")
    assert_true(sc.find_next_struct_decl())
    with assert_raises():
        _ = sc.parse_struct()


def test_parse_struct_allows_multi_of_container_element() raises:
    """`multi` doesn't require its element type to be bare -- `multi
    @@tags: List[@@Category]` is a field where each row can hold several
    `List[@@Category]` values; nothing about the element type looking
    container-shaped on its own means it must be a redundant wrapping."""
    var sc = Scanner("@@struct @@Department:\n    multi @@tags: List[@@Category]\n")
    assert_true(sc.find_next_struct_decl())
    var parsed = sc.parse_struct()
    assert_equal(len(parsed.fields), 1)
    assert_true(parsed.fields[0].modifier == FieldModifier.MULTI)
    assert_equal(parsed.fields[0].type_str, String("List[@@Category]"))


def test_parse_struct_ordered_field() raises:
    var sc = Scanner("@@struct @@Employee:\n    ordered years_employed: UInt32\n")
    assert_true(sc.find_next_struct_decl())
    var parsed = sc.parse_struct()
    assert_equal(len(parsed.fields), 1)
    assert_equal(parsed.fields[0].name, String("years_employed"))
    assert_equal(parsed.fields[0].type_str, String("UInt32"))
    assert_true(parsed.fields[0].modifier == FieldModifier.ORDERED)


def test_parse_struct_ordered_field_name_not_mistaken() raises:
    var sc = Scanner("@@struct @@Foo:\n    orderedBy: String\n")
    assert_true(sc.find_next_struct_decl())
    var parsed = sc.parse_struct()
    assert_equal(len(parsed.fields), 1)
    assert_equal(parsed.fields[0].name, String("orderedBy"))
    assert_false(parsed.fields[0].modifier == FieldModifier.ORDERED)


def test_parse_struct_rejects_ordered_and_unique_together() raises:
    var sc = Scanner("@@struct @@Foo:\n    unique ordered scores: UInt32\n")
    assert_true(sc.find_next_struct_decl())
    with assert_raises():
        _ = sc.parse_struct()


def test_find_next_marker_finds_construct() raises:
    var sc = Scanner('@@Person { .name = "alice", .age = 30 }')
    assert_true(sc.find_next_marker() == MarkerKind.CONSTRUCT)
    var c = sc.parse_construct()
    assert_equal(c.type_name, String("Person"))
    assert_equal(len(c.fields), 2)
    assert_equal(c.fields[0].name, String("name"))
    assert_false(c.fields[0].is_relation)
    assert_equal(c.fields[0].value, String('"alice"'))
    assert_equal(c.fields[1].name, String("age"))
    assert_false(c.fields[1].is_relation)
    assert_equal(c.fields[1].value, String("30"))


def test_construct_keeps_nested_dots_in_value() raises:
    # A dot INSIDE a value expression (like a float literal or a nested
    # call) must survive untouched -- only the leading `.` before each
    # field name is structural.
    var sc = Scanner("@@Foo { .x = 1.5, .label = bar.baz() }")
    assert_true(sc.find_next_marker() == MarkerKind.CONSTRUCT)
    var c = sc.parse_construct()
    assert_equal(len(c.fields), 2)
    assert_equal(c.fields[0].name, String("x"))
    assert_equal(c.fields[0].value, String("1.5"))
    assert_equal(c.fields[1].name, String("label"))
    assert_equal(c.fields[1].value, String("bar.baz()"))


def test_construct_marks_relation_field() raises:
    var sc = Scanner('@@Person { .name = "alice", .@@employee = @@bob }')
    assert_true(sc.find_next_marker() == MarkerKind.CONSTRUCT)
    var c = sc.parse_construct()
    assert_equal(len(c.fields), 2)
    assert_false(c.fields[0].is_relation)
    assert_true(c.fields[1].is_relation)
    assert_equal(c.fields[1].name, String("employee"))
    assert_equal(c.fields[1].value, String("@@bob"))


def test_find_next_marker_finds_field_read() raises:
    var sc = Scanner("print(@@alice.name);")
    assert_true(sc.find_next_marker() == MarkerKind.FIELD_ACCESS)
    var fa = sc.parse_field_access()
    assert_equal(fa.entity, String("alice"))
    assert_equal(fa.field, String("name"))
    assert_false(Bool(fa.write_value))


def test_find_next_marker_finds_field_write() raises:
    var sc = Scanner("@@alice.age = 31;")
    assert_true(sc.find_next_marker() == MarkerKind.FIELD_ACCESS)
    var fa = sc.parse_field_access()
    assert_equal(fa.entity, String("alice"))
    assert_equal(fa.field, String("age"))
    assert_equal(fa.write_value.value(), String("31"))


def test_field_access_does_not_mistake_equality_for_a_write() raises:
    var sc = Scanner("@@alice.age == 5")
    assert_true(sc.find_next_marker() == MarkerKind.FIELD_ACCESS)
    var fa = sc.parse_field_access()
    assert_false(Bool(fa.write_value))


def test_find_next_marker_finds_bare_name_ref() raises:
    var sc = Scanner("var @@alice = something;")
    assert_true(sc.find_next_marker() == MarkerKind.NAME_REF)
    var parsed_ref = sc.parse_name_ref()
    assert_equal(parsed_ref.name, String("alice"))


def test_find_next_marker_returns_none_when_absent() raises:
    var sc = Scanner("plain code with no markers")
    assert_true(sc.find_next_marker() == MarkerKind.NONE)


def test_find_next_marker_finds_for_entity_loop() raises:
    var sc = Scanner("for @@entry in @@AuditLog.all():")
    assert_true(sc.find_next_marker() == MarkerKind.FOR_ENTITY_LOOP)
    var name = sc.parse_for_entity_loop()
    assert_equal(name, String("entry"))
    # Left right at (or just before, mod whitespace) the iterated
    # expression's own marker -- `find_next_marker` skips trivia at its own
    # top, so the real codegen path doesn't care either way.
    sc.skip_trivia()
    assert_true(sc.starts_with("@@AuditLog"))


def test_find_next_marker_finds_for_entity_loop_with_var() raises:
    """`for var @@name in ...:` -- Mojo's own exclusivity checker sometimes
    *requires* `var` on a loop target (an owned copy, not the default
    aliased `ref` binding) when the loop body indexes back into the
    container being iterated, so this needs recognizing same as the bare
    `for @@name in ...:` form."""
    var sc = Scanner("for var @@entry in @@AuditLog.all():")
    assert_true(sc.find_next_marker() == MarkerKind.FOR_ENTITY_LOOP)
    var name = sc.parse_for_entity_loop()
    assert_equal(name, String("entry"))


def test_find_next_marker_finds_for_entity_loop_with_ref() raises:
    var sc = Scanner("for ref @@entry in @@AuditLog.all():")
    assert_true(sc.find_next_marker() == MarkerKind.FOR_ENTITY_LOOP)
    var name = sc.parse_for_entity_loop()
    assert_equal(name, String("entry"))


def test_find_next_marker_ignores_unmarked_for_loop_target() raises:
    """An ordinary `for x in y:` (no `@@` on the target) never reaches this
    scanner's `@@`-detection at all -- confirming the new marker doesn't
    misfire on the common, unmarked case already used elsewhere (e.g.
    `for name in names:` in `hire_team`)."""
    var sc = Scanner("for name in names: pass")
    assert_true(sc.find_next_marker() == MarkerKind.NONE)


def test_find_next_marker_ignores_markers_in_comments_and_strings() raises:
    var sc = Scanner('// @@alice.name\nconst s = "@@bob.age = 1;";\n@@carol.title')
    assert_true(sc.find_next_marker() == MarkerKind.FIELD_ACCESS)
    var fa = sc.parse_field_access()
    assert_equal(fa.entity, String("carol"))
    assert_equal(fa.field, String("title"))


def test_find_next_marker_ignores_markers_in_hash_comments() raises:
    """`#` is real Mojo's own comment syntax (`//` above is carried over
    from this compiler's original Zig-targeting version) -- a `@@`-looking
    mention inside one must be ignored the same way."""
    var sc = Scanner("# @@alice.name\n@@carol.title")
    assert_true(sc.find_next_marker() == MarkerKind.FIELD_ACCESS)
    var fa = sc.parse_field_access()
    assert_equal(fa.entity, String("carol"))
    assert_equal(fa.field, String("title"))


def test_parse_type_expr_leaf() raises:
    var t = parse_type_expr("String")
    assert_true(t.kind == TypeExpr.LEAF)
    assert_equal(t.name, String("String"))
    assert_true(t.arg_count() == 0)
    assert_equal(t.render(), String("String"))


def test_parse_type_expr_relation() raises:
    var t = parse_type_expr("@@Employee")
    assert_true(t.is_relation())
    assert_equal(t.name, String("Employee"))
    assert_equal(t.render(), String("@@Employee"))


def test_parse_type_expr_container_of_leaf() raises:
    var t = parse_type_expr("List[String]")
    assert_true(t.is_parameterized())
    assert_equal(t.name, String("List"))
    assert_true(t.arg_count() == 1)
    assert_true(t.arg(0).kind == TypeExpr.LEAF)
    assert_equal(t.arg(0).name, String("String"))
    assert_equal(t.render(), String("List[String]"))


def test_parse_type_expr_container_of_relation() raises:
    """`List[@@Employee]` -- the collection form of a relation field --
    parses to a `PARAMETERIZED` `List` wrapping a `RELATION` element, not
    a `RELATION` itself: only the bare `@@Employee` form is `is_relation()`."""
    var t = parse_type_expr("List[@@Employee]")
    assert_true(t.is_parameterized())
    assert_equal(t.name, String("List"))
    assert_false(t.is_relation())
    assert_true(t.arg(0).is_relation())
    assert_equal(t.arg(0).name, String("Employee"))
    assert_equal(t.render(), String("List[@@Employee]"))


def test_parse_type_expr_deeply_nested_container() raises:
    """`Optional[List[String]]` -- doubly-nested containers -- recurses
    correctly at every level."""
    var t = parse_type_expr("Optional[List[String]]")
    assert_equal(t.name, String("Optional"))
    var inner = t.arg(0)
    assert_true(inner.is_parameterized())
    assert_equal(inner.name, String("List"))
    assert_equal(inner.arg(0).name, String("String"))
    assert_equal(t.render(), String("Optional[List[String]]"))


def test_parse_type_expr_dict_two_args() raises:
    """`Dict[K, V]`'s own two type arguments, unlike every other
    container's one, both parse as independent `args` entries."""
    var t = parse_type_expr("Dict[String, UInt32]")
    assert_equal(t.name, String("Dict"))
    assert_true(t.arg_count() == 2)
    assert_equal(t.arg(0).name, String("String"))
    assert_equal(t.arg(1).name, String("UInt32"))
    assert_equal(t.render(), String("Dict[String, UInt32]"))


def test_parse_type_expr_dict_with_nested_container_value() raises:
    """`Dict[String, List[Int]]` -- a comma-separated argument that's
    itself bracketed mustn't split on its own inner comma."""
    var t = parse_type_expr("Dict[String, List[Int]]")
    assert_true(t.arg_count() == 2)
    assert_equal(t.arg(0).name, String("String"))
    assert_true(t.arg(1).is_parameterized())
    assert_equal(t.arg(1).name, String("List"))
    assert_equal(t.arg(1).arg(0).name, String("Int"))


def test_parse_type_expr_generic_plain_struct_instantiation() raises:
    """A generic plain struct's own instantiation (`Box[UInt32]`,
    `Pair[Int, Int]`) parses the same `PARAMETERIZED` shape a real
    container does -- distinguishing the two is a caller's own concern
    (checking `name` against the known container names), not something
    `TypeExpr` itself needs to decide."""
    var box = parse_type_expr("Box[UInt32]")
    assert_equal(box.name, String("Box"))
    assert_equal(box.arg(0).name, String("UInt32"))

    var pair = parse_type_expr("Pair[Int, Int]")
    assert_equal(pair.name, String("Pair"))
    assert_true(pair.arg_count() == 2)


def test_parse_type_expr_generic_instantiation_of_container() raises:
    """A generic plain struct field embedding a container of its own type
    parameter (`Box[List[String]]`, mirroring `Profile`'s own `rating:
    Box[UInt32]` alongside a container field) still recurses correctly --
    the `PARAMETERIZED` shape doesn't care whether its own argument is a
    leaf, a relation, or another `PARAMETERIZED` node."""
    var t = parse_type_expr("Box[List[String]]")
    assert_equal(t.name, String("Box"))
    var inner = t.arg(0)
    assert_true(inner.is_parameterized())
    assert_equal(inner.name, String("List"))
    assert_equal(inner.arg(0).name, String("String"))
    assert_equal(t.render(), String("Box[List[String]]"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
