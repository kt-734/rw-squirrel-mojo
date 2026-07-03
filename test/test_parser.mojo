from std.testing import assert_equal, assert_true, assert_false, assert_raises, TestSuite

from squirrel_compiler.parser import Scanner, ParsedStruct, Field, parse_fields, MarkerKind


def test_find_next_struct_decl_ignores_comment() raises:
    var sc = Scanner("// not @@struct Real\n@@struct Actual { x: u32 }")
    assert_true(sc.find_next_struct_decl())
    assert_true(sc.starts_with("@@struct Actual"))


def test_find_next_struct_decl_ignores_string() raises:
    var sc = Scanner('const s = "@@struct Fake { x: u32 }";\n@@struct Real { y: u32 }')
    assert_true(sc.find_next_struct_decl())
    assert_true(sc.starts_with("@@struct Real"))


def test_find_next_struct_decl_returns_false_when_absent() raises:
    var sc = Scanner("no structs here at all")
    assert_false(sc.find_next_struct_decl())


def test_parse_struct_basic() raises:
    var sc = Scanner("@@struct Foo { x: u32, label: String }")
    assert_true(sc.find_next_struct_decl())
    var parsed = sc.parse_struct()
    assert_equal(parsed.name, String("Foo"))
    assert_equal(len(parsed.fields), 2)
    assert_equal(parsed.fields[0].name, String("x"))
    assert_equal(parsed.fields[0].type_str, String("u32"))
    assert_equal(parsed.fields[1].name, String("label"))
    assert_equal(parsed.fields[1].type_str, String("String"))


def test_parse_struct_tolerates_brace_in_comment() raises:
    var sc = Scanner("@@struct Foo {\n    // odd brace: }\n    x: u32,\n}")
    assert_true(sc.find_next_struct_decl())
    var parsed = sc.parse_struct()
    assert_equal(parsed.name, String("Foo"))
    assert_equal(len(parsed.fields), 1)
    assert_equal(parsed.fields[0].name, String("x"))


def test_parse_struct_tolerates_nested_brackets_in_type() raises:
    var sc = Scanner("@@struct Foo { x: u32, tags: List[u32] }")
    assert_true(sc.find_next_struct_decl())
    var parsed = sc.parse_struct()
    assert_equal(len(parsed.fields), 2)
    assert_equal(parsed.fields[1].type_str, String("List[u32]"))


def test_parse_struct_rejects_duplicate_field_names() raises:
    var sc = Scanner("@@struct Foo { x: u32, x: f32 }")
    assert_true(sc.find_next_struct_decl())
    with assert_raises():
        _ = sc.parse_struct()


def test_parse_struct_rejects_malformed_input() raises:
    var sc = Scanner("@@struct Foo not_braces")
    assert_true(sc.find_next_struct_decl())
    with assert_raises():
        _ = sc.parse_struct()


def test_parse_struct_relation_field() raises:
    var sc = Scanner("@@struct Person { @@employee: @@Employee }")
    assert_true(sc.find_next_struct_decl())
    var parsed = sc.parse_struct()
    assert_equal(len(parsed.fields), 1)
    assert_equal(parsed.fields[0].name, String("employee"))
    assert_equal(parsed.fields[0].type_str, String("@@Employee"))


def test_parse_struct_rejects_unmarked_name_with_relation_type() raises:
    var sc = Scanner("@@struct Person { employee: @@Employee }")
    assert_true(sc.find_next_struct_decl())
    with assert_raises():
        _ = sc.parse_struct()


def test_parse_struct_rejects_marked_name_with_non_relation_type() raises:
    var sc = Scanner("@@struct Person { @@age: u32 }")
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


def test_find_next_marker_ignores_markers_in_comments_and_strings() raises:
    var sc = Scanner('// @@alice.name\nconst s = "@@bob.age = 1;";\n@@carol.title')
    assert_true(sc.find_next_marker() == MarkerKind.FIELD_ACCESS)
    var fa = sc.parse_field_access()
    assert_equal(fa.entity, String("carol"))
    assert_equal(fa.field, String("title"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
