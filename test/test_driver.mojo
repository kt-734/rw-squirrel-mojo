from std.testing import assert_equal, assert_raises, assert_true, TestSuite
from std.os import listdir, makedirs, remove, rmdir
from std.os.path import exists, isfile, join

from squirrel_compiler.driver import (
    convert_directory,
    module_path_for,
    mojo_output_path,
)


def test_mojo_output_path() raises:
    assert_equal(mojo_output_path("foo/bar.rel"), String("foo/bar.mojo"))
    assert_equal(mojo_output_path("person.rel"), String("person.mojo"))


def test_module_path_for() raises:
    assert_equal(
        module_path_for("examples/company/sub/employee.rel", "examples/company"),
        String("sub.employee"),
    )
    assert_equal(
        module_path_for("examples/company/person.rel", "examples/company"),
        String("person"),
    )


def _rmtree(dir: String) raises:
    """Minimal recursive delete -- no rmtree in `std.os`, and the fixture
    tree is shallow enough that hand-rolling this is simpler than pulling in
    more machinery."""
    for entry in listdir(dir):
        var full = join(dir, entry)
        if isfile(full):
            remove(full)
        else:
            _rmtree(full)
    rmdir(dir)


def test_convert_directory_end_to_end() raises:
    var root = "test/tmp_driver_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(join(root, "sub"), exist_ok=True)

    var employee_rel = open(join(root, "sub", "employee.rel"), "w")
    employee_rel.write("@@struct Employee { title: String }\n")
    employee_rel.close()

    var person_rel = open(join(root, "person.rel"), "w")
    person_rel.write("@@struct Person { name: String, @@employee: @@Employee }\n")
    person_rel.close()

    convert_directory(".", root)

    assert_true(isfile(join(root, "person.mojo")))
    assert_true(isfile(join(root, "sub", "employee.mojo")))
    assert_true(isfile(join(root, "sub", "__init__.mojo")))
    assert_true(isfile(join(root, "sqrrl__Squirrel.mojo")))
    assert_true(isfile(join(root, "squirrel_runtime", "entity.mojo")))
    assert_true(isfile(join(root, "squirrel_runtime", "rel.mojo")))
    assert_true(isfile(join(root, "squirrel_runtime", "id_allocator.mojo")))

    var f = open(join(root, "person.mojo"), "r")
    var generated = f.read()
    f.close()
    assert_true("from sub.employee import sqrrl__EmployeeTableState" in generated)
    assert_true("struct sqrrl__PersonTableState(TableStateLike, Movable, ImplicitlyDeletable):" in generated)
    # No script in this file touches sqrrl__world -- shouldn't import it.
    assert_true("from sqrrl__Squirrel import" not in generated)

    var sf = open(join(root, "sqrrl__Squirrel.mojo"), "r")
    var squirrel_generated = sf.read()
    sf.close()
    assert_true("from person import sqrrl__PersonTable" in squirrel_generated)
    assert_true("from sub.employee import sqrrl__EmployeeTable" in squirrel_generated)
    assert_true("struct sqrrl__Squirrel(Movable):" in squirrel_generated)
    assert_true("def sqrrl__init() -> sqrrl__Squirrel:" in squirrel_generated)

    _rmtree(root)


def test_convert_directory_handles_a_script_alongside_its_struct() raises:
    var root = "test/tmp_driver_script_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var greeter_rel = open(join(root, "greeter.rel"), "w")
    greeter_rel.write(
        "@@struct Person {\n"
        "    name: String,\n"
        "    age: UInt32,\n"
        "}\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@alice = @@Person { .name = "alice", .age = 30 };\n'
        "    @@alice.age = 31;\n"
        "    print(@@alice.name, @@alice.age);\n"
    )
    greeter_rel.close()

    convert_directory(".", root)

    var f = open(join(root, "greeter.mojo"), "r")
    var generated = f.read()
    f.close()
    assert_true("from sqrrl__Squirrel import sqrrl__init, sqrrl__Squirrel" in generated)
    assert_true("var sqrrl__world = sqrrl__init();" in generated)
    assert_true('var sqrrl__alice = sqrrl__world.Person.create(name = "alice", age = 30);' in generated)
    assert_true("sqrrl__world.Person.set_age(sqrrl__alice, 31);" in generated)

    _rmtree(root)


def test_convert_directory_rejects_direct_two_struct_cycle() raises:
    var root = "test/tmp_driver_cycle_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var a_rel = open(join(root, "a.rel"), "w")
    a_rel.write("@@struct A { @@b: @@B }\n")
    a_rel.close()
    var b_rel = open(join(root, "b.rel"), "w")
    b_rel.write("@@struct B { @@a: @@A }\n")
    b_rel.close()

    with assert_raises(contains="CyclicRelation"):
        convert_directory(".", root)

    _rmtree(root)


def test_convert_directory_rejects_self_relation_cycle() raises:
    var root = "test/tmp_driver_self_cycle_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var node_rel = open(join(root, "node.rel"), "w")
    node_rel.write("@@struct Node { @@friend: @@Node }\n")
    node_rel.close()

    with assert_raises(contains="CyclicRelation"):
        convert_directory(".", root)

    _rmtree(root)


def test_convert_directory_rejects_transitive_three_struct_cycle() raises:
    var root = "test/tmp_driver_transitive_cycle_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var a_rel = open(join(root, "a.rel"), "w")
    a_rel.write("@@struct A { @@b: @@B }\n")
    a_rel.close()
    var b_rel = open(join(root, "b.rel"), "w")
    b_rel.write("@@struct B { @@c: @@C }\n")
    b_rel.close()
    var c_rel = open(join(root, "c.rel"), "w")
    c_rel.write("@@struct C { @@a: @@A }\n")
    c_rel.close()

    with assert_raises(contains="CyclicRelation"):
        convert_directory(".", root)

    _rmtree(root)


def test_convert_directory_allows_acyclic_diamond_relations() raises:
    var root = "test/tmp_driver_diamond_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var a_rel = open(join(root, "a.rel"), "w")
    a_rel.write("@@struct A { @@b: @@B, @@c: @@C }\n")
    a_rel.close()
    var b_rel = open(join(root, "b.rel"), "w")
    b_rel.write("@@struct B { @@d: @@D }\n")
    b_rel.close()
    var c_rel = open(join(root, "c.rel"), "w")
    c_rel.write("@@struct C { @@d: @@D }\n")
    c_rel.close()
    var d_rel = open(join(root, "d.rel"), "w")
    d_rel.write("@@struct D { name: String }\n")
    d_rel.close()

    convert_directory(".", root)
    assert_true(isfile(join(root, "a.mojo")))

    _rmtree(root)


def test_convert_directory_rejects_cycle_smuggled_through_plain_struct() raises:
    """A plain (non-`@@`) `struct` isn't itself a relation field, but if a
    `@@struct`'s plain field embeds one by value, and that plain struct's
    own body has a `@@`-marked field pointing back, the result is the same
    unconstructible cycle as a direct `@@`-to-`@@` one -- just never
    written as `@@Type` on both ends."""
    var root = "test/tmp_driver_plain_struct_cycle_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var schema_rel = open(join(root, "schema.rel"), "w")
    schema_rel.write(
        "@@struct Employee { title: String }\n"
        "\n"
        "@@struct Example { title: String }\n"
        "\n"
        "struct Other {\n"
        "    @@person: @@Person\n"
        "}\n"
        "\n"
        "@@struct Person {\n"
        "    name: String,\n"
        "    other: Other,\n"
        "    @@employee: @@Example\n"
        "}\n"
    )
    schema_rel.close()

    with assert_raises(contains="CyclicRelation"):
        convert_directory(".", root)

    _rmtree(root)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
