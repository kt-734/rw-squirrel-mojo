from std.testing import assert_true, assert_equal, assert_raises, TestSuite

from squirrel_compiler.parser import Scanner
from squirrel_compiler.codegen import emit_table, transform_source


def empty_schema() -> Dict[String, Dict[String, String]]:
    return Dict[String, Dict[String, String]]()


def test_emits_state_struct_and_fields() raises:
    var sc = Scanner("@@struct Person { name: String, age: UInt32 }")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct())

    assert_true("struct sqrrl__PersonTableState(TableStateLike, Movable, ImplicitlyDeletable):" in out)
    assert_true("var name: Rel[String]" in out)
    assert_true("var age: Rel[UInt32]" in out)


def test_emits_table_wrapper() raises:
    var sc = Scanner("@@struct Person { name: String, age: UInt32 }")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct())

    assert_true("struct sqrrl__PersonTable(Movable):" in out)
    assert_true("var table: Table[sqrrl__PersonTableState]" in out)
    assert_true("self.table = Table[sqrrl__PersonTableState](sqrrl__PersonTableState())" in out)


def test_emits_create_with_all_fields() raises:
    var sc = Scanner("@@struct Person { name: String, age: UInt32 }")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct())

    assert_true(
        "def create(mut self, name: String, age: UInt32) ->"
        " EntityHandle[sqrrl__PersonTableState]:" in out
    )
    assert_true("self.table.state[].state.name.put(e.id(), name)" in out)
    assert_true("self.table.state[].state.age.put(e.id(), age)" in out)


def test_emits_get_and_set_per_field() raises:
    var sc = Scanner("@@struct Person { age: UInt32 }")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct())

    assert_true(
        "def get_age(self, e: EntityHandle[sqrrl__PersonTableState]) -> UInt32:" in out
    )
    assert_true("return self.table.state[].state.age.get_fwd(e.id()).value()" in out)
    assert_true(
        "def set_age(mut self, e: EntityHandle[sqrrl__PersonTableState], v: UInt32):"
        in out
    )
    assert_true("self.table.state[].state.age.update(e.id(), v)" in out)


def test_emits_cleanup_relations_for_every_field() raises:
    # This is what closes the relation-leak-on-destroy bug: every field,
    # relation or not, gets fetch_remove_fwd'd when the owning entity dies.
    var sc = Scanner("@@struct Person { name: String, @@employee: @@Employee }")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct())

    assert_true("def sqrrl__cleanup_relations(mut self, id: UInt32):" in out)
    assert_true("_ = self.name.fetch_remove_fwd(id)" in out)
    assert_true("_ = self.employee.fetch_remove_fwd(id)" in out)


def test_relation_field_targets_the_other_table_state() raises:
    var sc = Scanner("@@struct Person { @@employee: @@Employee }")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct())

    assert_true("var employee: Rel[EntityHandle[sqrrl__EmployeeTableState]]" in out)
    assert_true(
        "def create(mut self, employee: EntityHandle[sqrrl__EmployeeTableState])"
        " -> EntityHandle[sqrrl__PersonTableState]:" in out
    )
    assert_true(
        "def get_employee(self, e: EntityHandle[sqrrl__PersonTableState]) ->"
        " EntityHandle[sqrrl__EmployeeTableState]:" in out
    )


def test_transform_source_passes_plain_code_through_untouched() raises:
    var source = String("def add(a: Int, b: Int) -> Int:\n    return a + b\n")
    assert_equal(transform_source(source, empty_schema()), source)


def test_transform_source_emits_table_for_struct() raises:
    var out = transform_source("@@struct Person { name: String }", empty_schema())
    assert_true("struct sqrrl__PersonTableState(TableStateLike, Movable, ImplicitlyDeletable):" in out)
    assert_true("struct sqrrl__PersonTable(Movable):" in out)


def test_transform_source_rewrites_construct_through_world() raises:
    var source = String(
        "@@struct Person { name: String }\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@alice = @@Person { .name = "alice" };\n'
        '    var @@bob = @@Person { .name = "bob" };\n'
    )
    var out = transform_source(source, empty_schema())
    assert_true("var sqrrl__world = sqrrl__init();" in out)
    assert_true('var sqrrl__alice = sqrrl__world.Person.create(name = "alice");' in out)
    assert_true('var sqrrl__bob = sqrrl__world.Person.create(name = "bob");' in out)


def test_transform_source_rejects_at_marked_variable_with_unmarked_construct() raises:
    """`@@` on the variable name obligates `@@` on the constructed type too
    -- an unmarked RHS (`Person{...}`, no `@@`) never goes through the
    construct rewrite at all, leaving genuinely broken Mojo behind (an
    undeclared bare `Person` type, un-stripped `.field = ` syntax) that
    might not surface as an error until real Mojo compilation, or not at
    all if the entity is never field-accessed afterward."""
    var source = String(
        "@@struct Person { name: String }\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@alice = Person { .name = "alice" };\n'
    )
    with assert_raises():
        _ = transform_source(source, empty_schema())


def test_transform_source_rewrites_field_read_and_write() raises:
    var source = String(
        "@@struct Person { name: String, age: UInt32 }\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@alice = @@Person { .name = "alice", .age = 30 };\n'
        "    @@alice.age = 31;\n"
        "    print(@@alice.name);\n"
    )
    var out = transform_source(source, empty_schema())
    assert_true("sqrrl__world.Person.set_age(sqrrl__alice, 31);" in out)
    assert_true("print(sqrrl__world.Person.get_name(sqrrl__alice));" in out)


def _person_employee_boss_schema() -> Dict[String, Dict[String, String]]:
    """Person.employee -> Employee, Employee.boss -> Person -- enough to
    exercise both a single-hop chain and a longer one (Person -> Employee
    -> Person)."""
    var schema = Dict[String, Dict[String, String]]()
    var person_fields = Dict[String, String]()
    person_fields["employee"] = "Employee"
    schema["Person"] = person_fields^
    var employee_fields = Dict[String, String]()
    employee_fields["boss"] = "Person"
    schema["Employee"] = employee_fields^
    return schema^


def test_transform_source_rewrites_single_hop_chain() raises:
    var source = String(
        "@@struct Employee { title: String }\n"
        "\n"
        "@@struct Person { name: String, @@employee: @@Employee }\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@alice = @@Person { .name = "alice", .@@employee = bob };\n'
        "    print(@@alice.@@employee.title);\n"
        "    @@alice.@@employee.title = \"manager\";\n"
    )
    var out = transform_source(source, _person_employee_boss_schema())
    assert_true(
        "print(sqrrl__world.Employee.get_title(sqrrl__world.Person.get_employee(sqrrl__alice)));"
        in out
    )
    assert_true(
        'sqrrl__world.Employee.set_title(sqrrl__world.Person.get_employee(sqrrl__alice), "manager");'
        in out
    )


def test_transform_source_rewrites_multi_hop_chain() raises:
    var source = String(
        "@@struct Employee { title: String }\n"
        "\n"
        "@@struct Person { name: String, @@employee: @@Employee }\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@alice = @@Person { .name = "alice", .@@employee = bob };\n'
        "    print(@@alice.@@employee.@@boss.name);\n"
    )
    var out = transform_source(source, _person_employee_boss_schema())
    assert_true(
        "print(sqrrl__world.Person.get_name(sqrrl__world.Employee.get_boss(sqrrl__world.Person.get_employee(sqrrl__alice))));"
        in out
    )


def test_transform_source_rewrites_nested_entity_reference_in_construct() raises:
    var source = String(
        "@@struct Employee { title: String }\n"
        "\n"
        "@@struct Person { name: String, @@employee: @@Employee }\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@bob = @@Employee { .title = "engineer" };\n'
        '    var @@alice = @@Person { .name = "alice", .@@employee = @@bob };\n'
    )
    var out = transform_source(source, _person_employee_boss_schema())
    assert_true(
        'var sqrrl__alice = sqrrl__world.Person.create(name = "alice", employee = sqrrl__bob);'
        in out
    )


def test_transform_source_rewrites_nested_construct_in_construct() raises:
    var source = String(
        "@@struct Employee { title: String }\n"
        "\n"
        "@@struct Person { name: String, @@employee: @@Employee }\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@alice = @@Person { .name = "alice", .@@employee = @@Employee { .title = "engineer" } };\n'
    )
    var out = transform_source(source, _person_employee_boss_schema())
    assert_true(
        'var sqrrl__alice = sqrrl__world.Person.create(name = "alice", employee = sqrrl__world.Employee.create(title = "engineer"));'
        in out
    )


def test_transform_source_rejects_unmarked_relation_field_in_construct() raises:
    var source = String(
        "@@struct Employee { title: String }\n"
        "\n"
        "@@struct Person { name: String, @@employee: @@Employee }\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@alice = @@Person { .name = "alice", .employee = bob };\n'
    )
    with assert_raises():
        _ = transform_source(source, _person_employee_boss_schema())


def test_transform_source_rejects_at_marked_plain_field_in_construct() raises:
    var source = String(
        "@@struct Person { name: String }\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@alice = @@Person { .@@name = "alice" };\n'
    )
    with assert_raises():
        _ = transform_source(source, _person_employee_boss_schema())


def test_transform_source_rejects_unknown_relation_hop() raises:
    var source = String(
        "@@struct Employee { title: String }\n"
        "\n"
        "@@struct Person { name: String, @@employee: @@Employee }\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@alice = @@Person { .name = "alice", .@@employee = bob };\n'
        "    print(@@alice.@@manager.title);\n"
    )
    with assert_raises():
        _ = transform_source(source, _person_employee_boss_schema())


def test_transform_source_threads_entity_across_functions() raises:
    var source = String(
        "@@struct Person { name: String }\n"
        "\n"
        "def print_name(@@subject: @@Person, @@) raises:\n"
        "    print(@@subject.name);\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@alice = @@Person { .name = "alice" };\n'
        "    print_name(@@alice, @@);\n"
    )
    var out = transform_source(source, empty_schema())
    assert_true(
        "def print_name(sqrrl__subject: EntityHandle[sqrrl__PersonTableState], mut sqrrl__world: sqrrl__Squirrel) raises:"
        in out
    )
    assert_true("print(sqrrl__world.Person.get_name(sqrrl__subject));" in out)
    assert_true("print_name(sqrrl__alice, sqrrl__world);" in out)


def test_transform_source_rejects_entity_param_syntax_outside_signature() raises:
    var source = String(
        "@@struct Person { name: String }\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        "    @@alice: @@Person;\n"
    )
    with assert_raises():
        _ = transform_source(source, empty_schema())


def test_transform_source_rejects_field_access_on_unconstructed_entity() raises:
    var source = String(
        "@@struct Person { name: String }\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        "    print(@@alice.name);\n"
    )
    with assert_raises():
        _ = transform_source(source, empty_schema())


def test_transform_source_rejects_construct_without_world() raises:
    var source = String(
        "@@struct Person { name: String }\n"
        "\n"
        "def main() raises:\n"
        '    var @@alice = @@Person { .name = "alice" };\n'
    )
    with assert_raises():
        _ = transform_source(source, empty_schema())


def test_transform_source_threads_world_through_function_params_and_calls() raises:
    var source = String(
        "@@struct Person { name: String }\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        "    make_person(@@);\n"
        "\n"
        'def make_person(@@) raises:\n'
        '    var @@alice = @@Person { .name = "alice" };\n'
    )
    var out = transform_source(source, empty_schema())
    assert_true("make_person(sqrrl__world);" in out)
    assert_true("def make_person(mut sqrrl__world: sqrrl__Squirrel) raises:" in out)
    assert_true('var sqrrl__alice = sqrrl__world.Person.create(name = "alice");' in out)


def test_transform_source_rejects_construct_in_function_missing_world_param() raises:
    var source = String(
        "@@struct Person { name: String }\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        "    make_person();\n"
        "\n"
        "def make_person() raises:\n"
        '    var @@alice = @@Person { .name = "alice" };\n'
    )
    with assert_raises():
        _ = transform_source(source, empty_schema())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
