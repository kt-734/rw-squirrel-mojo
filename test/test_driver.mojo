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
    employee_rel.write("@@struct @@Employee:\n    title: String\n\n")
    employee_rel.close()

    var person_rel = open(join(root, "person.rel"), "w")
    person_rel.write("@@struct @@Person:\n    name: String\n    @@employee: @@Employee\n\n")
    person_rel.close()

    convert_directory(".", root)

    assert_true(isfile(join(root, "person.mojo")))
    assert_true(isfile(join(root, "sub", "employee.mojo")))
    assert_true(isfile(join(root, "sub", "__init__.mojo")))
    assert_true(isfile(join(root, "sqrrl__Squirrel.mojo")))
    assert_true(isfile(join(root, "squirrel_runtime", "id_allocator.mojo")))
    assert_true(isfile(join(root, "squirrel_runtime", "rel", "__init__.mojo")))
    assert_true(isfile(join(root, "squirrel_runtime", "rel", "rel.mojo")))
    assert_true(isfile(join(root, "squirrel_runtime", "rel", "unique_rel.mojo")))
    assert_true(isfile(join(root, "squirrel_runtime", "rel", "forward_only_rel.mojo")))
    assert_true(isfile(join(root, "squirrel_runtime", "rel", "rel_like.mojo")))
    assert_true(isfile(join(root, "squirrel_runtime", "rel", "fwd_store.mojo")))
    assert_true(isfile(join(root, "squirrel_runtime", "entity", "__init__.mojo")))
    assert_true(isfile(join(root, "squirrel_runtime", "entity", "table_state_like.mojo")))
    assert_true(isfile(join(root, "squirrel_runtime", "entity", "table_storage.mojo")))
    assert_true(isfile(join(root, "squirrel_runtime", "entity", "entity_inner.mojo")))
    assert_true(isfile(join(root, "squirrel_runtime", "entity", "entity_handle.mojo")))
    assert_true(isfile(join(root, "squirrel_runtime", "entity", "table.mojo")))

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


def test_convert_directory_emits_ordinary_rel_for_collection_relation_field() raises:
    """A `@@struct`'s own collection-typed relation field (`@@members:
    List[@@Employee]`) compiles to an ordinary `Rel`-backed field, complete
    with a real `for_members` reverse lookup -- `List[EntityHandle[...]]`
    is `KeyElement`, so there's no reason to force `ForwardOnlyRel` storage
    just for being a container. `ForwardOnlyRel` still gets imported
    alongside `Rel`/`UniqueRel` unconditionally, matching the existing
    "always import everything" pattern, even though nothing in this
    fixture actually uses it."""
    var root = "test/tmp_driver_collection_relation_field_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var employee_rel = open(join(root, "employee.rel"), "w")
    employee_rel.write("@@struct @@Employee:\n    title: String\n\n")
    employee_rel.close()

    var department_rel = open(join(root, "department.rel"), "w")
    department_rel.write(
        "@@struct @@Department:\n    name: String\n    @@members: List[@@Employee]\n\n"
    )
    department_rel.close()

    convert_directory(".", root)

    assert_true(isfile(join(root, "department.mojo")))

    var f = open(join(root, "department.mojo"), "r")
    var generated = f.read()
    f.close()
    assert_true("from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel" in generated)
    assert_true(
        "var members: Rel[List[EntityHandle[sqrrl__EmployeeTableState]]]" in generated
    )
    assert_true(
        "def get_members(self, e: EntityHandle[sqrrl__DepartmentTableState]) ->"
        " List[EntityHandle[sqrrl__EmployeeTableState]]:" in generated
    )
    assert_true(
        "def for_members(self, value: List[EntityHandle[sqrrl__EmployeeTableState]])"
        " -> List[EntityHandle[sqrrl__DepartmentTableState]]:" in generated
    )

    _rmtree(root)


def test_convert_directory_handles_a_script_alongside_its_struct() raises:
    var root = "test/tmp_driver_script_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var greeter_rel = open(join(root, "greeter.rel"), "w")
    greeter_rel.write(
        "@@struct @@Person:\n"
        "    name: String\n"
        "    age: UInt32\n"
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
    a_rel.write("@@struct @@A:\n    @@b: @@B\n\n")
    a_rel.close()
    var b_rel = open(join(root, "b.rel"), "w")
    b_rel.write("@@struct @@B:\n    @@a: @@A\n\n")
    b_rel.close()

    with assert_raises(contains="CyclicRelation"):
        convert_directory(".", root)

    _rmtree(root)


def test_convert_directory_rejects_cycle_through_wrapped_relation_field() raises:
    """A wrapped-but-not-`multi` collection relation field
    (`@@members: List[@@A]`) is a graph edge too, just like a bare one --
    `A.b: @@B` and `B.members: List[@@A]` together are `A -> B -> A`, the
    same cycle as if `B.members` were written `@@a: @@A` instead."""
    var root = "test/tmp_driver_wrapped_cycle_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var a_rel = open(join(root, "a.rel"), "w")
    a_rel.write("@@struct @@A:\n    @@b: @@B\n\n")
    a_rel.close()
    var b_rel = open(join(root, "b.rel"), "w")
    b_rel.write("@@struct @@B:\n    @@members: List[@@A]\n\n")
    b_rel.close()

    with assert_raises(contains="CyclicRelation"):
        convert_directory(".", root)

    _rmtree(root)


def test_convert_directory_rejects_cycle_through_container_of_plain_struct() raises:
    """A *plain* (non-`@@`) field whose type is a container naming
    another known struct (`members: List[A]`, not `List[@@A]`) is also a
    graph edge -- an embed-by-value collection can still smuggle a cycle
    back through whatever `A`'s own fields point at, same as a bare
    embed-by-value field (`embedded: A`) already does."""
    var root = "test/tmp_driver_container_embed_cycle_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var a_rel = open(join(root, "a.rel"), "w")
    a_rel.write("struct A { @@b: @@B }\n")
    a_rel.close()
    var b_rel = open(join(root, "b.rel"), "w")
    b_rel.write("@@struct @@B:\n    members: List[A]\n\n")
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
    node_rel.write("@@struct @@Node:\n    @@friend: @@Node\n\n")
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
    a_rel.write("@@struct @@A:\n    @@b: @@B\n\n")
    a_rel.close()
    var b_rel = open(join(root, "b.rel"), "w")
    b_rel.write("@@struct @@B:\n    @@c: @@C\n\n")
    b_rel.close()
    var c_rel = open(join(root, "c.rel"), "w")
    c_rel.write("@@struct @@C:\n    @@a: @@A\n\n")
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
    a_rel.write("@@struct @@A:\n    @@b: @@B\n    @@c: @@C\n\n")
    a_rel.close()
    var b_rel = open(join(root, "b.rel"), "w")
    b_rel.write("@@struct @@B:\n    @@d: @@D\n\n")
    b_rel.close()
    var c_rel = open(join(root, "c.rel"), "w")
    c_rel.write("@@struct @@C:\n    @@d: @@D\n\n")
    c_rel.close()
    var d_rel = open(join(root, "d.rel"), "w")
    d_rel.write("@@struct @@D:\n    name: String\n\n")
    d_rel.close()

    convert_directory(".", root)
    assert_true(isfile(join(root, "a.mojo")))

    _rmtree(root)


def test_convert_directory_rejects_bidirectional_multi_relation() raises:
    """`multi` gets no special exemption from cycle detection: declaring
    it on *both* sides of a relationship, each pointing back at the other
    (`Student.courses`/`Course.students`), is a graph cycle like any
    other and is rejected -- and there's no real reason to write it this
    way in the first place: `MultiRel`'s own `get_fwd`/`get_bwd` already
    answer both directions from a *single* field declared on just one
    struct (see `test_convert_directory_allows_one_sided_multi_relation`
    below), so the two-sided form only adds a genuine `ArcPointer` cycle
    risk for nothing gained over the one-sided one."""
    var root = "test/tmp_driver_multi_cycle_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var student_rel = open(join(root, "student.rel"), "w")
    student_rel.write("@@struct @@Student:\n    name: String\n    multi @@courses: @@Course\n\n")
    student_rel.close()
    var course_rel = open(join(root, "course.rel"), "w")
    course_rel.write("@@struct @@Course:\n    title: String\n    multi @@students: @@Student\n\n")
    course_rel.close()

    with assert_raises(contains="CyclicRelation"):
        convert_directory(".", root)

    _rmtree(root)


def test_convert_directory_allows_one_sided_multi_relation() raises:
    """A `multi` field declared on just *one* struct, with nothing on the
    other side at all, is never a cycle (there's no edge back) -- and
    still provides a full many-to-many relation: `MultiRel`'s own
    `get_fwd`/`get_bwd` answer both "which employees does this department
    contain" and "which departments contain this employee" from the
    single field."""
    var root = "test/tmp_driver_one_sided_multi_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var student_rel = open(join(root, "student.rel"), "w")
    student_rel.write("@@struct @@Student:\n    name: String\n\n")
    student_rel.close()
    var course_rel = open(join(root, "course.rel"), "w")
    course_rel.write("@@struct @@Course:\n    title: String\n    multi @@students: @@Student\n\n")
    course_rel.close()

    convert_directory(".", root)
    assert_true(isfile(join(root, "course.mojo")))

    var f = open(join(root, "course.mojo"), "r")
    var generated = f.read()
    f.close()
    assert_true("from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel" in generated)
    assert_true("from std.collections import Set" in generated)
    assert_true(
        "var students: MultiRel[EntityHandle[sqrrl__StudentTableState]]" in generated
    )
    assert_true(
        "def add_to_students(mut self, e: EntityHandle[sqrrl__CourseTableState],"
        " value: EntityHandle[sqrrl__StudentTableState]) -> Bool:" in generated
    )
    assert_true(
        "def for_students(self, value: EntityHandle[sqrrl__StudentTableState]) ->"
        " List[EntityHandle[sqrrl__CourseTableState]]:" in generated
    )

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
        "@@struct @@Employee:\n"
        "    title: String\n"
        "\n"
        "@@struct @@Example:\n"
        "    title: String\n"
        "\n"
        "struct Other {\n"
        "    @@person: @@Person\n"
        "}\n"
        "\n"
        "@@struct @@Person:\n"
        "    name: String\n"
        "    other: Other\n"
        "    @@employee: @@Example\n"
    )
    schema_rel.close()

    with assert_raises(contains="CyclicRelation"):
        convert_directory(".", root)

    _rmtree(root)


def test_convert_directory_tolerates_a_real_mojo_plain_struct() raises:
    """A hand-written, real Mojo `struct Name(Traits...):` (colon + indented
    `var` block, not the brace-delimited shorthand `@@struct` bodies use)
    used to abort the entire `convert_directory` run the moment
    `discover_plain_structs` hit it, since it unconditionally expected a
    `{` right after the struct name. It should just be invisible to the
    plain-struct/cycle-detection pass instead, same as any other ordinary
    Mojo code a `.rel` file might contain."""
    var root = "test/tmp_driver_real_plain_struct_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var address_rel = open(join(root, "address.rel"), "w")
    address_rel.write(
        "struct Address(Copyable, Movable, ImplicitlyDeletable):\n"
        "    var city: String\n"
        "\n"
        "    fn __init__(out self, var city: String):\n"
        "        self.city = city^\n"
    )
    address_rel.close()

    convert_directory(".", root)
    assert_true(isfile(join(root, "address.mojo")))

    _rmtree(root)


def test_convert_directory_generates_real_struct_from_shorthand_plain_struct() raises:
    """The brace-delimited shorthand plain-struct form (`struct Name {
    field: Type, ... }`) used to only ever be an internal shape
    `check_no_relation_cycles` could analyze -- writing one in a real
    `.rel` file passed it through completely unchanged, which isn't valid
    Mojo at all (no brace-bodied struct literal). `emit_plain_struct`
    (via `MarkerKind.PLAIN_STRUCT`) is what makes it a real, compilable
    struct -- including a `@@`-marked field inside it, which previously
    misfired as `MarkerKind.ENTITY_PARAM`."""
    var root = "test/tmp_driver_shorthand_plain_struct_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var employee_rel = open(join(root, "employee.rel"), "w")
    employee_rel.write("@@struct @@Employee:\n    title: String\n\n")
    employee_rel.close()
    var note_rel = open(join(root, "note.rel"), "w")
    note_rel.write("struct Note { @@author: @@Employee, text: String }\n")
    note_rel.close()

    convert_directory(".", root)
    assert_true(isfile(join(root, "note.mojo")))

    var f = open(join(root, "note.mojo"), "r")
    var generated = f.read()
    f.close()
    assert_true("struct Note(ImplicitlyCopyable, Movable, ImplicitlyDeletable):" in generated)
    assert_true("var author: EntityHandle[sqrrl__EmployeeTableState]" in generated)
    assert_true("var text: String" in generated)

    _rmtree(root)


def test_convert_directory_imports_cross_file_plain_struct_field() raises:
    """A `@@struct`'s *plain* (non-`@@`) field whose type is a struct
    declared in a different file needs that struct imported too -- only
    relation (`@@`-marked) fields used to get cross-file import wiring."""
    var root = "test/tmp_driver_plain_field_import_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var address_rel = open(join(root, "address.rel"), "w")
    address_rel.write(
        "struct Address(Copyable, Movable, ImplicitlyDeletable):\n"
        "    var city: String\n"
        "\n"
        "    def __init__(out self, var city: String):\n"
        "        self.city = city^\n"
    )
    address_rel.close()

    var person_rel = open(join(root, "person.rel"), "w")
    person_rel.write("@@struct @@Person:\n    name: String\n    home: Address\n\n")
    person_rel.close()

    convert_directory(".", root)

    var f = open(join(root, "person.mojo"), "r")
    var generated = f.read()
    f.close()
    assert_true("from address import Address" in generated)

    _rmtree(root)


def test_convert_directory_imports_cross_file_entity_param() raises:
    """A script function's `ENTITY_PARAM` (`@@name: @@Type`) needs its
    type's `sqrrl__<Type>TableState` imported when `Type` is declared in a
    different file -- even when the file containing the function declares
    no `@@struct` of its own (so the old struct-field-based cross-file
    import scan, which only looked at structs declared in *this* file,
    never even considered it)."""
    var root = "test/tmp_driver_entity_param_import_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var employee_rel = open(join(root, "employee.rel"), "w")
    employee_rel.write("@@struct @@Employee:\n    title: String\n\n")
    employee_rel.close()

    var reports_rel = open(join(root, "reports.rel"), "w")
    reports_rel.write(
        "def @@print_title(@@emp: @@Employee) raises:\n"
        "    print(@@emp.title);\n"
    )
    reports_rel.close()

    convert_directory(".", root)

    var f = open(join(root, "reports.mojo"), "r")
    var generated = f.read()
    f.close()
    assert_true("from employee import sqrrl__EmployeeTableState" in generated)

    _rmtree(root)


def test_convert_directory_imports_cross_file_return_type() raises:
    """A function's `@@Type`-marked return type needs its type's
    `sqrrl__<Type>TableState` imported when `Type` is declared in a
    different file, same as an `ENTITY_PARAM` does."""
    var root = "test/tmp_driver_return_type_import_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var department_rel = open(join(root, "department.rel"), "w")
    department_rel.write("@@struct @@Department:\n    name: String\n\n")
    department_rel.close()

    var factories_rel = open(join(root, "factories.rel"), "w")
    factories_rel.write(
        "def @@make_department() raises -> @@Department:\n"
        '    var @@d = @@Department { .name = "engineering" };\n'
        "    return @@d;\n"
    )
    factories_rel.close()

    convert_directory(".", root)

    var f = open(join(root, "factories.mojo"), "r")
    var generated = f.read()
    f.close()
    assert_true("from department import sqrrl__DepartmentTableState" in generated)
    assert_true(
        "def sqrrl__make_department(mut sqrrl__world: sqrrl__Squirrel) raises"
        " -> EntityHandle[sqrrl__DepartmentTableState]:" in generated
    )

    _rmtree(root)


def test_convert_directory_infers_and_enforces_entity_return_binding_cross_file() raises:
    """`build_function_returns` is project-wide, so a call site in a
    *different* file than the one declaring the entity-returning function
    still gets automatic `entity_to_type` inference (no explicit
    `: @@Type` needed) and still gets the unmarked-variable rejection."""
    var root = "test/tmp_driver_function_returns_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var factories_rel = open(join(root, "factories.rel"), "w")
    factories_rel.write(
        "@@struct @@Department:\n    name: String\n\n"
        "\n"
        "def @@make_department() raises -> @@Department:\n"
        '    var @@d = @@Department { .name = "engineering" };\n'
        "    return @@d;\n"
    )
    factories_rel.close()

    var main_rel = open(join(root, "main.rel"), "w")
    main_rel.write(
        "from factories import sqrrl__make_department\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        "    var @@dept = @@make_department();\n"
        "    print(@@dept.name);\n"
    )
    main_rel.close()

    convert_directory(".", root)

    var f = open(join(root, "main.mojo"), "r")
    var generated = f.read()
    f.close()
    assert_true("var sqrrl__dept = sqrrl__make_department(sqrrl__world);" in generated)
    assert_true("print(sqrrl__world.Department.get_name(sqrrl__dept));" in generated)

    _rmtree(root)


def test_convert_directory_recognizes_multi_param_container_return_type() raises:
    """`build_function_returns` recognizes `-> Dict[@@Type, V]:` (a second
    type parameter after the entity type, not just `Container[@@Type]`),
    registering it the same way a single-param container return is --
    enough for `for @@name in @@func():` to bind `@@name` to `Type` (the
    first parameter), not fail with 'never constructed or bound'."""
    var root = "test/tmp_driver_multi_param_container_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var main_rel = open(join(root, "main.rel"), "w")
    main_rel.write(
        "@@struct @@AuditLog:\n    message: String\n\n"
        "\n"
        "def @@make_log() -> Dict[@@AuditLog, String]:\n"
        "    return Dict[@@AuditLog, String]();\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        "    for @@entry in @@make_log():\n"
        "        print(@@entry.message);\n"
    )
    main_rel.close()

    convert_directory(".", root)

    var f = open(join(root, "main.mojo"), "r")
    var generated = f.read()
    f.close()
    assert_true("for sqrrl__entry in  sqrrl__make_log(sqrrl__world):" in generated)
    assert_true("print(sqrrl__world.AuditLog.get_message(sqrrl__entry));" in generated)

    _rmtree(root)

    # Same project, but the receiving variable is unmarked -- rejected.
    makedirs(root, exist_ok=True)
    var factories_rel2 = open(join(root, "factories.rel"), "w")
    factories_rel2.write(
        "@@struct @@Department:\n    name: String\n\n"
        "\n"
        "def @@make_department() raises -> @@Department:\n"
        '    var @@d = @@Department { .name = "engineering" };\n'
        "    return @@d;\n"
    )
    factories_rel2.close()

    var main_rel2 = open(join(root, "main.rel"), "w")
    main_rel2.write(
        "from factories import sqrrl__make_department\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        "    var dept = @@make_department();\n"
    )
    main_rel2.close()

    with assert_raises():
        convert_directory(".", root)

    _rmtree(root)


def test_convert_directory_rejects_multiple_init_calls() raises:
    """Calling `@@init()` more than once anywhere in the project used to
    compile and run fine, silently creating a second, disconnected
    `sqrrl__Squirrel` instead of sharing the one the rest of the program
    uses -- a footgun with no error at all. `@@init()` is meant to be
    called exactly once; every other function should receive the result
    via `@@` in its own parameters instead."""
    var root = "test/tmp_driver_double_init_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var schema_rel = open(join(root, "schema.rel"), "w")
    schema_rel.write("@@struct @@Department:\n    name: String\n\n")
    schema_rel.close()

    var factories_rel = open(join(root, "factories.rel"), "w")
    factories_rel.write(
        "def make_department_oops() raises:\n"
        "    @@init();\n"
        '    var @@d = @@Department { .name = "engineering" };\n'
    )
    factories_rel.close()

    var main_rel = open(join(root, "main.rel"), "w")
    main_rel.write(
        "def main() raises:\n"
        "    @@init();\n"
        "    make_department_oops();\n"
    )
    main_rel.close()

    with assert_raises(contains="@@init() called 2 times"):
        convert_directory(".", root)

    _rmtree(root)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
