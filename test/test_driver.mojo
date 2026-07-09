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

    convert_directory(root)

    assert_true(isfile(join(root, "person.mojo")))
    assert_true(isfile(join(root, "sub", "employee.mojo")))
    assert_true(isfile(join(root, "sub", "__init__.mojo")))
    assert_true(isfile(join(root, "sqrrl__world.mojo")))
    assert_true(isfile(join(root, "sqrrl__json.mojo")))
    assert_true(isfile(join(root, "squirrel_runtime", "json.mojo")))
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
    assert_true("from sqrrl__world import" not in generated)
    # `from_json` lives on the struct's own table (`emit_table_json_methods`),
    # not on `sqrrl__World` -- Person's own relation field (`@@employee:
    # @@Employee`) needs Employee's table threaded in as an explicit
    # sibling parameter, which crosses a file boundary here (Employee is
    # declared in sub/employee.rel), so its own Table type needs importing
    # too, not just its TableState.
    assert_true("from sub.employee import sqrrl__EmployeeTable" in generated)
    assert_true(
        "def sqrrl__from_json(mut self, mut sqrrl__tbl_Employee: sqrrl__EmployeeTable,"
        " mut sc: sqrrl__JsonScanner) raises -> EntityHandle[sqrrl__PersonTableState]:"
        in generated
    )
    assert_true(
        "sqrrl__parsed_employee ="
        " sqrrl__tbl_Employee.table.handle_for(UInt32(sc.parse_json_int()))"
        in generated
    )

    var ef = open(join(root, "sub", "employee.mojo"), "r")
    var employee_generated = ef.read()
    ef.close()
    # Employee has no relation fields of its own, so its own from_json
    # needs no sibling-table parameters beyond `mut self, mut sc`.
    assert_true(
        "def sqrrl__from_json(mut self, mut sc: sqrrl__JsonScanner) raises ->"
        " EntityHandle[sqrrl__EmployeeTableState]:" in employee_generated
    )

    var sf = open(join(root, "sqrrl__world.mojo"), "r")
    var world_generated = sf.read()
    sf.close()
    assert_true("from person import sqrrl__PersonTable" in world_generated)
    assert_true("from sub.employee import sqrrl__EmployeeTable" in world_generated)
    assert_true("struct sqrrl__World(Movable):" in world_generated)
    assert_true("def sqrrl__init() -> sqrrl__World:" in world_generated)

    var jf = open(join(root, "sqrrl__json.mojo"), "r")
    var json_generated = jf.read()
    jf.close()
    assert_true("def sqrrl__to_json[T: AnyType](value: T) -> String:" in json_generated)
    assert_true(
        "def sqrrl__from_json[T: Copyable & ImplicitlyDeletable](mut sc:"
        " sqrrl__JsonScanner) raises -> T:" in json_generated
    )

    _rmtree(root)


def test_convert_directory_generates_json_container_dispatch() raises:
    """A `List[String]` field project-wide gets its own `elif T ==
    List[String]:` branch in the generated `sqrrl__json.mojo`, delegating
    to `list_to_json`/`list_from_json` (static helpers imported from
    `squirrel_runtime.json`, not generated here) -- there's no way to ask
    Mojo's own type system "is `T` a container of anything" generically,
    so `build_json_container_types` has to enumerate every concrete
    combination the schema actually uses, project-wide."""
    var root = "test/tmp_driver_json_container_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var person_rel = open(join(root, "person.rel"), "w")
    person_rel.write("@@struct @@Person:\n    tags: List[String]\n\n")
    person_rel.close()

    convert_directory(root)

    var jf = open(join(root, "sqrrl__json.mojo"), "r")
    var json_generated = jf.read()
    jf.close()
    assert_true("elif T == List[String]:" in json_generated)
    assert_true("return list_to_json(rebind[List[String]](value).copy())" in json_generated)
    assert_true("return rebind[T](list_from_json[String](sc)).copy()" in json_generated)
    assert_true(
        "from squirrel_runtime.json import sqrrl__JsonScanner, sqrrl__escape_json_string,"
        " sqrrl__JsonSerializable, list_to_json, list_from_json, set_to_json, set_from_json,"
        " optional_to_json, optional_from_json, dict_to_json, dict_from_json" in json_generated
    )

    var rf = open(join(root, "squirrel_runtime", "json.mojo"), "r")
    var runtime_json = rf.read()
    rf.close()
    assert_true("def list_to_json[X: Copyable](lst: List[X]) -> String:" in runtime_json)

    _rmtree(root)


def test_convert_directory_registers_nested_container_types() raises:
    """A *doubly*-nested container field (`Optional[List[String]]`) used
    to only ever get the outer `Optional[List[String]]` registered --
    `optional_from_json`'s own generated body calls
    `sqrrl__from_json[List[String]]` internally, which had no dispatch
    branch of its own, crashing the whole compilation ("struct_field_types
    requires a struct type") the moment such a field was actually
    serialized. Nothing to do with generics or plain structs at all --
    confirmed with a bare `@@struct` field. `_collect_json_container_types`
    now registers every nesting level, not just the outermost one."""
    var root = "test/tmp_driver_nested_container_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var foo_rel = open(join(root, "foo.rel"), "w")
    foo_rel.write("@@struct @@Foo:\n    bar: Optional[List[String]]\n\n")
    foo_rel.close()

    convert_directory(root)

    var jf = open(join(root, "sqrrl__json.mojo"), "r")
    var json_generated = jf.read()
    jf.close()
    assert_true("elif T == Optional[List[String]]:" in json_generated)
    assert_true("elif T == List[String]:" in json_generated)

    _rmtree(root)


def test_convert_directory_registers_generic_instantiations_container_types() raises:
    """A generic plain struct's own field (`listfield: Optional[List[T]]`
    inside `struct Example[T]:`) is abstract until instantiated -- used
    elsewhere as a concrete instantiation (`items: Example[String]`),
    both `Optional[List[String]]` and `List[String]` (the substituted,
    concrete shape of `Example`'s own field) need registering project-
    wide, even though `Example[String]` itself is handled by its own
    dedicated `sqrrl__Example_from_json[T]` companion, not this shared
    dispatcher -- nothing else would ever discover them otherwise."""
    var root = "test/tmp_driver_generic_container_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var example_rel = open(join(root, "example.rel"), "w")
    example_rel.write("struct Example[T] { listfield: Optional[List[Self.T]] }\n")
    example_rel.close()

    var holder_rel = open(join(root, "holder.rel"), "w")
    holder_rel.write("@@struct @@Holder:\n    name: String\n    forwardonly items: Example[String]\n\n")
    holder_rel.close()

    convert_directory(root)

    var jf = open(join(root, "sqrrl__json.mojo"), "r")
    var json_generated = jf.read()
    jf.close()
    # Example[String] itself never gets a dispatcher branch -- its own
    # companion handles it directly.
    assert_true("Example[String]" not in json_generated)
    assert_true("elif T == Optional[List[String]]:" in json_generated)
    assert_true("elif T == List[String]:" in json_generated)

    _rmtree(root)


def test_convert_directory_registers_dict_element_types() raises:
    """`Dict[K, V]`'s own two element types (unlike every other
    container's one) both need registering independently, not just the
    first -- `Dict[String, List[Int]]` needs `List[Int]` registered too,
    the same way `Optional[List[String]]` needs `List[String]`
    registered alongside itself."""
    var root = "test/tmp_driver_dict_container_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var foo_rel = open(join(root, "foo.rel"), "w")
    foo_rel.write("@@struct @@Foo:\n    nested: Dict[String, List[Int]]\n\n")
    foo_rel.close()

    convert_directory(root)

    var jf = open(join(root, "sqrrl__json.mojo"), "r")
    var json_generated = jf.read()
    jf.close()
    assert_true("elif T == Dict[String, List[Int]]:" in json_generated)
    assert_true("elif T == List[Int]:" in json_generated)
    assert_true("return dict_to_json(rebind[Dict[String, List[Int]]](value).copy())" in json_generated)

    _rmtree(root)


def test_convert_directory_generates_dispatch_for_plain_struct_nested_in_container() raises:
    """A non-generic plain struct nested inside a `List`/`Set`/`Optional`/
    `Dict` field -- unlike one used as some struct's own *direct* field
    type -- genuinely needs a `sqrrl__from_json[T]` dispatch branch of
    its own: `list_from_json[Address]`'s own body calls
    `sqrrl__from_json[Address](sc)` internally, which had no branch to
    reach before `build_json_container_types` started registering plain
    structs reached this way too."""
    var root = "test/tmp_driver_plain_struct_in_container_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var address_rel = open(join(root, "address.rel"), "w")
    address_rel.write("struct Address { city: String }\n")
    address_rel.close()
    var foo_rel = open(join(root, "foo.rel"), "w")
    foo_rel.write("@@struct @@Foo:\n    addresses: List[Address]\n\n")
    foo_rel.close()

    convert_directory(root)

    var jf = open(join(root, "sqrrl__json.mojo"), "r")
    var json_generated = jf.read()
    jf.close()
    assert_true("elif T == List[Address]:" in json_generated)
    assert_true("elif T == Address:" in json_generated)
    assert_true("return rebind[T](sqrrl__Address_from_json(sc)).copy()" in json_generated)

    _rmtree(root)


def test_convert_directory_generates_dispatch_for_generic_instantiation_nested_in_container() raises:
    """A generic plain struct's own concrete instantiation (`Box[String]`)
    nested inside a container gets the same treatment, forwarding its own
    type argument(s) to `sqrrl__<Name>_from_json[<args>]`."""
    var root = "test/tmp_driver_generic_instantiation_in_container_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var box_rel = open(join(root, "box.rel"), "w")
    box_rel.write("struct Box[T] { value: T }\n")
    box_rel.close()
    var foo_rel = open(join(root, "foo.rel"), "w")
    foo_rel.write("@@struct @@Foo:\n    boxes: List[Box[String]]\n\n")
    foo_rel.close()

    convert_directory(root)

    var jf = open(join(root, "sqrrl__json.mojo"), "r")
    var json_generated = jf.read()
    jf.close()
    assert_true("elif T == List[Box[String]]:" in json_generated)
    assert_true("elif T == Box[String]:" in json_generated)
    assert_true("return rebind[T](sqrrl__Box_from_json[String](sc)).copy()" in json_generated)

    _rmtree(root)


def test_convert_directory_rejects_relation_embedding_plain_struct_nested_in_container() raises:
    """A plain struct embedding a relation field can't be reconstructed
    through the shared `sqrrl__from_json[T]` dispatcher -- its fixed
    `(mut sc: sqrrl__JsonScanner) raises -> T` signature has no way to
    supply the sibling table(s) its own `sqrrl__<Name>_from_json`
    companion needs as extra parameters, the way a struct's own directly-
    declared field's `_emit_from_json_field_parse` can. Used as a
    *direct* field, this works fine (see
    `test_convert_directory_generates_from_json_for_hand_written_plain_struct_with_relation_field`)
    -- only nesting it inside a container is rejected, with a clear error
    instead of silently generating code that would fail downstream."""
    var root = "test/tmp_driver_relation_embedding_in_container_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var target_rel = open(join(root, "target.rel"), "w")
    target_rel.write("@@struct @@Target:\n    name: String\n\n")
    target_rel.close()
    var assignment_rel = open(join(root, "assignment.rel"), "w")
    assignment_rel.write("struct Assignment { @@t: @@Target, role: String }\n")
    assignment_rel.close()
    var holder_rel = open(join(root, "holder.rel"), "w")
    holder_rel.write("@@struct @@Holder:\n    items: List[Assignment]\n\n")
    holder_rel.close()

    with assert_raises(contains="Assignment"):
        convert_directory(root)

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

    convert_directory(root)

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
        "    @@{\n"
        "        @@init();\n"
        '        var @@alice = @@Person { .name = "alice", .age = 30 };\n'
        "        @@alice.age = 31;\n"
        "        print(@@alice.name, @@alice.age);\n"
        "    @@}\n"
    )
    greeter_rel.close()

    convert_directory(root)

    var f = open(join(root, "greeter.mojo"), "r")
    var generated = f.read()
    f.close()
    assert_true("from sqrrl__world import sqrrl__init, sqrrl__World" in generated)
    assert_true("var sqrrl__world = sqrrl__init()\n    try:" in generated)
    assert_true("sqrrl__world.sqrrl__check_no_leaks(); sqrrl__world = sqrrl__init();" in generated)
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
        convert_directory(root)

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
        convert_directory(root)

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
        convert_directory(root)

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
        convert_directory(root)

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
        convert_directory(root)

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

    convert_directory(root)
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
        convert_directory(root)

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

    convert_directory(root)
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
        convert_directory(root)

    _rmtree(root)


def test_convert_directory_rejects_cycle_smuggled_through_hand_written_plain_struct() raises:
    """The same cycle as `test_convert_directory_rejects_cycle_smuggled_through_plain_struct`,
    but smuggled through a *hand-written* (real Mojo, non-shorthand) plain
    struct instead of a brace-shorthand one -- `discover_hand_written_plain_structs`
    is what makes this catchable at all: a hand-written struct's own
    relation field, spelled out by hand as
    `EntityHandle[sqrrl__EmployeeTableState]`, is recovered back to the
    pseudo `@@Employee` shape `check_no_relation_cycles`'s own graph
    already understands, the same as `build_plain_struct_fields` already
    does for JSON codegen purposes. Before this, a cycle written this way
    compiled without error and would only fail later, confusingly, at
    `create()`."""
    var root = "test/tmp_driver_hand_written_plain_struct_cycle_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var employee_rel = open(join(root, "employee.rel"), "w")
    employee_rel.write(
        "@@struct @@Employee:\n"
        "    title: String\n"
        "    embedded: Note\n"
        "\n"
    )
    employee_rel.close()

    var note_rel = open(join(root, "note.rel"), "w")
    note_rel.write(
        "struct Note(Copyable, Movable, ImplicitlyDeletable):\n"
        "    var author: EntityHandle[sqrrl__EmployeeTableState]\n"
        "\n"
        "    def __init__(out self, var author: EntityHandle[sqrrl__EmployeeTableState]):\n"
        "        self.author = author^\n"
    )
    note_rel.close()

    with assert_raises(contains="CyclicRelation"):
        convert_directory(root)

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

    convert_directory(root)
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

    convert_directory(root)
    assert_true(isfile(join(root, "note.mojo")))

    var f = open(join(root, "note.mojo"), "r")
    var generated = f.read()
    f.close()
    assert_true("struct Note(Copyable, Movable, ImplicitlyDeletable):" in generated)
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

    convert_directory(root)

    var f = open(join(root, "person.mojo"), "r")
    var generated = f.read()
    f.close()
    assert_true("from address import Address" in generated)

    _rmtree(root)


def test_convert_directory_generates_from_json_for_hand_written_plain_struct() raises:
    """A *hand-written* (non-shorthand) plain struct used to be entirely
    invisible to `from_json` codegen -- `discover_plain_structs` only ever
    recognized the brace-shorthand form, so a field typed as `Address`
    here fell through to the shared `sqrrl__from_json[T]` dispatcher's
    generic fallback, which raises at runtime (`unsupported type --
    structs use their own generated from_json`) since reflection can't
    write into an arbitrary field. `build_plain_struct_fields` now also
    scans for the hand-written form directly (`Scanner.
    find_next_hand_written_plain_struct_decl`/`parse_hand_written_plain_struct`),
    so `Address` gets its own `sqrrl__Address_from_json` free-function
    companion in `sqrrl__json.mojo` (alongside the rest of JSON
    serialization's generated code, not `sqrrl__world.mojo` -- see
    `build_json_module_source`), same as a shorthand plain struct's."""
    var root = "test/tmp_driver_hand_written_from_json_fixture"
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

    convert_directory(root)

    var jf = open(join(root, "sqrrl__json.mojo"), "r")
    var json_generated = jf.read()
    jf.close()
    assert_true(
        "def sqrrl__Address_from_json(mut sc: sqrrl__JsonScanner) raises -> Address:"
        in json_generated
    )
    assert_true("var sqrrl__parsed_city: Optional[String] = None" in json_generated)
    assert_true("sqrrl__parsed_city = sqrrl__from_json[String](sc)" in json_generated)
    assert_true("return Address(sqrrl__parsed_city.take())" in json_generated)

    var f = open(join(root, "person.mojo"), "r")
    var generated = f.read()
    f.close()
    # Person's own `home` field now routes through the generated
    # companion instead of the shared dispatcher's dead-end fallback --
    # and person.mojo actually imports it (the bug this closes: nothing
    # ever imported a plain struct's own from_json companion by name into
    # the file that calls it, so this call used to fail to compile at all
    # -- "use of unknown declaration 'sqrrl__Address_from_json'").
    assert_true("from sqrrl__json import sqrrl__Address_from_json" in generated)
    assert_true("sqrrl__parsed_home = sqrrl__Address_from_json(sc)" in generated)

    _rmtree(root)


def test_convert_directory_generates_from_json_for_generic_plain_struct() raises:
    """A generic shorthand plain struct (`struct Box[T] { value: T }`)
    gets a generic `sqrrl__Box_from_json[T: Bound](...)` companion in
    `sqrrl__json.mojo`, and an `@@struct` field naming a *concrete
    instantiation* of it (`price: Box[UInt32]`) routes to it with the
    instantiation's own type argument forwarded
    (`sqrrl__Box_from_json[UInt32](sc)`), not the shared
    `sqrrl__from_json[T]` dispatcher (which has no way to reconstruct an
    arbitrary struct at all)."""
    var root = "test/tmp_driver_generic_plain_struct_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var box_rel = open(join(root, "box.rel"), "w")
    box_rel.write("struct Box[T] { value: T }\n")
    box_rel.close()

    var product_rel = open(join(root, "product.rel"), "w")
    product_rel.write("@@struct @@Product:\n    name: String\n    price: Box[UInt32]\n\n")
    product_rel.close()

    convert_directory(root)

    var jf = open(join(root, "sqrrl__json.mojo"), "r")
    var json_generated = jf.read()
    jf.close()
    assert_true(
        "def sqrrl__Box_from_json[T: Copyable & ImplicitlyDeletable]"
        "(mut sc: sqrrl__JsonScanner) raises -> Box[T]:" in json_generated
    )
    assert_true("sqrrl__parsed_value = sqrrl__from_json[T](sc)" in json_generated)
    assert_true("return Box[T](sqrrl__parsed_value.take())" in json_generated)

    var f = open(join(root, "product.mojo"), "r")
    var generated = f.read()
    f.close()
    assert_true("from sqrrl__json import sqrrl__Box_from_json" in generated)
    assert_true("var sqrrl__parsed_price: Optional[Box[UInt32]] = None" in generated)
    assert_true("sqrrl__parsed_price = sqrrl__Box_from_json[UInt32](sc)" in generated)

    _rmtree(root)


def test_convert_directory_generates_from_json_for_hand_written_plain_struct_with_relation_field() raises:
    """A hand-written plain struct can embed a relation field too, spelled
    out by hand as `EntityHandle[sqrrl__<Name>TableState]` (there's no
    `@@`-marked shorthand available to a real Mojo struct body) --
    `codegen.recover_relation_type_str` reverses that back to the pseudo
    `@@Employee` shape `_relation_field_shape`/`_collect_relation_targets`
    already understand, so `Note`'s own generated `from_json` companion
    gets a `sqrrl__tbl_Employee: sqrrl__EmployeeTable` parameter, and the
    *owning* struct's own `from_json` threads it through transitively, the
    same as it would for a shorthand plain struct's relation field."""
    var root = "test/tmp_driver_hand_written_relation_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var employee_rel = open(join(root, "employee.rel"), "w")
    employee_rel.write("@@struct @@Employee:\n    title: String\n\n")
    employee_rel.close()

    var note_rel = open(join(root, "note.rel"), "w")
    note_rel.write(
        "struct Note(Copyable, Movable, ImplicitlyDeletable):\n"
        "    var author: EntityHandle[sqrrl__EmployeeTableState]\n"
        "    var text: String\n"
        "\n"
        "    def __init__(out self, var author: EntityHandle[sqrrl__EmployeeTableState], var text: String):\n"
        "        self.author = author^\n"
        "        self.text = text^\n"
    )
    note_rel.close()

    var report_rel = open(join(root, "report.rel"), "w")
    report_rel.write("@@struct @@Report:\n    forwardonly note: Note\n\n")
    report_rel.close()

    convert_directory(root)

    var jf = open(join(root, "sqrrl__json.mojo"), "r")
    var json_generated = jf.read()
    jf.close()
    assert_true(
        "def sqrrl__Note_from_json(mut sqrrl__tbl_Employee: sqrrl__EmployeeTable,"
        " mut sc: sqrrl__JsonScanner) raises -> Note:" in json_generated
    )
    assert_true(
        "sqrrl__parsed_author ="
        " sqrrl__tbl_Employee.table.handle_for(UInt32(sc.parse_json_int()))"
        in json_generated
    )

    var f = open(join(root, "report.mojo"), "r")
    var generated = f.read()
    f.close()
    assert_true("from sqrrl__json import sqrrl__Note_from_json" in generated)
    assert_true(
        "def sqrrl__from_json(mut self, mut sqrrl__tbl_Employee: sqrrl__EmployeeTable,"
        " mut sc: sqrrl__JsonScanner) raises -> EntityHandle[sqrrl__ReportTableState]:"
        in generated
    )
    assert_true(
        "sqrrl__parsed_note = sqrrl__Note_from_json(sqrrl__tbl_Employee, sc)" in generated
    )

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

    convert_directory(root)

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

    convert_directory(root)

    var f = open(join(root, "factories.mojo"), "r")
    var generated = f.read()
    f.close()
    assert_true("from department import sqrrl__DepartmentTableState" in generated)
    assert_true(
        "def sqrrl__make_department(mut sqrrl__world: sqrrl__World) raises"
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
        "    @@{\n"
        "        @@init();\n"
        "        var @@dept = @@make_department();\n"
        "        print(@@dept.name);\n"
        "    @@}\n"
    )
    main_rel.close()

    convert_directory(root)

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
        "    @@{\n"
        "        @@init();\n"
        "        for @@entry in @@make_log():\n"
        "            print(@@entry.message);\n"
        "    @@}\n"
    )
    main_rel.close()

    convert_directory(root)

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
        "    @@{\n"
        "        @@init();\n"
        "        var dept = @@make_department();\n"
    )
    main_rel2.close()

    with assert_raises():
        convert_directory(root)

    _rmtree(root)


def test_convert_directory_rejects_multiple_declare_calls() raises:
    """Opening `@@{` more than once anywhere in the project used to
    (with `@@init()` itself as the thing being counted) compile and run
    fine, silently creating a second, disconnected `sqrrl__World` instead
    of sharing the one the rest of the program uses -- a footgun with no
    error at all. `@@{` is meant to appear exactly once; every
    other function should receive the result via `@@` in its own
    parameters instead."""
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
        "    @@{\n"
        "        @@init();\n"
        '        var @@d = @@Department { .name = "engineering" };\n'
    )
    factories_rel.close()

    var main_rel = open(join(root, "main.rel"), "w")
    main_rel.write(
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        "        make_department_oops();\n"
    )
    main_rel.close()

    with assert_raises(contains="@@{ used 2 times"):
        convert_directory(root)

    _rmtree(root)


def test_convert_directory_rejects_start_init_from_json_without_declare_in_that_function() raises:
    """`world_declared` is function-scoped, reset at every top-level `def`
    (same as `world_available` always was) -- a *different* function using
    `@@start_init_from_json(...)` needs its *own* `@@{` in that
    same function, even if `main()` already declared and initialized its
    own `sqrrl__world`; there's no way for the two to end up sharing one
    binding this way regardless (see
    `test_convert_directory_rejects_multiple_declare_calls` for why two
    independent `@@{`s are rejected too)."""
    var root = "test/tmp_driver_mixed_init_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var schema_rel = open(join(root, "schema.rel"), "w")
    schema_rel.write("@@struct @@Department:\n    name: String\n\n")
    schema_rel.close()

    var main_rel = open(join(root, "main.rel"), "w")
    main_rel.write(
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        "        var dump = String(\"{}\");\n"
        "        reload(dump);\n"
        "    @@}\n"
        "\n"
        "def reload(dump: String) raises:\n"
        "    @@start_init_from_json(dump);\n"
    )
    main_rel.close()

    with assert_raises(contains="needs '@@{'"):
        convert_directory(root)

    _rmtree(root)


def test_convert_directory_allows_conditional_reload_or_init_after_declare() raises:
    """The end-to-end point of `@@{`: a real project can now choose
    between `@@init()` and `@@start_init_from_json(...)` conditionally, in
    one function, with both branches sharing the same declared
    `sqrrl__world` -- something neither form could do alone before
    `@@{` existed (see `misc_builders.check_single_declare_call`'s
    own doc comment)."""
    var root = "test/tmp_driver_conditional_declare_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var schema_rel = open(join(root, "schema.rel"), "w")
    schema_rel.write("@@struct @@Department:\n    name: String\n\n")
    schema_rel.close()

    var main_rel = open(join(root, "main.rel"), "w")
    main_rel.write(
        "def main(dump: String, restore: Bool) raises:\n"
        "    @@{\n"
        "        if restore:\n"
        "            @@start_init_from_json(dump);\n"
        "        else:\n"
        "            @@init();\n"
        '        var @@d = @@Department { .name = "engineering" };\n'
        "        print(@@d.name);\n"
        "    @@}\n"
    )
    main_rel.close()

    convert_directory(root)

    var f = open(join(root, "main.mojo"), "r")
    var generated = f.read()
    f.close()
    assert_true("var sqrrl__world = sqrrl__init()\n    try:" in generated)
    assert_true(
        "sqrrl__world.sqrrl__check_no_leaks(); sqrrl__world ="
        " sqrrl__init_from_json(dump);" in generated
    )
    assert_true("sqrrl__world.sqrrl__check_no_leaks(); sqrrl__world = sqrrl__init();" in generated)

    _rmtree(root)


def test_convert_directory_generates_start_init_from_json() raises:
    """`@@start_init_from_json(json)` desugars to `sqrrl__world =
    sqrrl__init_from_json(json)` -- `@@init()`'s reload counterpart,
    obtaining the same shared `sqrrl__world` binding from a JSON dump
    instead of an empty `sqrrl__World()`. Calls into a generated
    `sqrrl__init_from_json` function (which builds its own
    `sqrrl__JsonScanner` internally) rather than inlining one at the call
    site, so `@@start_init_from_json(...)` can be called more than once in
    the same function without redeclaring a scanner local (see
    `driver.emit_world_module`)."""
    var root = "test/tmp_driver_init_from_json_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var schema_rel = open(join(root, "schema.rel"), "w")
    schema_rel.write("@@struct @@Department:\n    name: String\n\n")
    schema_rel.close()

    var main_rel = open(join(root, "main.rel"), "w")
    main_rel.write(
        "def main(dump: String) raises:\n"
        "    @@{\n"
        "        @@start_init_from_json(dump);\n"
        '        var @@d = @@Department { .name = "engineering" };\n'
        "        print(@@d.name);\n"
        "    @@}\n"
    )
    main_rel.close()

    convert_directory(root)

    var f = open(join(root, "main.mojo"), "r")
    var generated = f.read()
    f.close()
    assert_true("var sqrrl__world = sqrrl__init()\n    try:" in generated)
    assert_true(
        "sqrrl__world.sqrrl__check_no_leaks(); sqrrl__world ="
        " sqrrl__init_from_json(dump);" in generated
    )
    assert_true(
        "from sqrrl__world import sqrrl__init, sqrrl__World,"
        " sqrrl__world_from_json, sqrrl__init_from_json" in generated
    )

    _rmtree(root)


def test_convert_directory_generates_check_no_leaks_and_del() raises:
    """`sqrrl__World` gets `sqrrl__check_no_leaks` (clears every
    `keepalive`-tagged table's own retention, then `abort`s with a
    `LeakedEntities` message if any table -- `keepalive`-tagged or not --
    still has live entities) and a `__del__` that just calls it directly.
    Not `raises` at either point, deliberately -- a leak is the same kind
    of bug regardless of when it's discovered, so it's fatal both times
    rather than catchable at one call site and not the other (see
    `driver.emit_world_module`'s own doc comment)."""
    var root = "test/tmp_driver_check_no_leaks_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var schema_rel = open(join(root, "schema.rel"), "w")
    schema_rel.write(
        "@@struct @@Department:\n    name: String\n\n"
        "@@struct keepalive @@AuditLog:\n    message: String\n\n"
    )
    schema_rel.close()

    var main_rel = open(join(root, "main.rel"), "w")
    main_rel.write(
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        "    @@}\n"
    )
    main_rel.close()

    convert_directory(root)

    var sf = open(join(root, "sqrrl__world.mojo"), "r")
    var world_generated = sf.read()
    sf.close()
    assert_true("from std.os import abort" in world_generated)
    assert_true("def sqrrl__check_no_leaks(mut self):" in world_generated)
    # Only the `keepalive`-tagged struct's own retention gets cleared...
    assert_true("self.AuditLog.sqrrl__clear_keepalive()" in world_generated)
    # ...but every struct's table gets checked for leftover live entities.
    assert_true("var sqrrl__leaked_Department = len(self.Department.all())" in world_generated)
    assert_true("if sqrrl__leaked_Department > 0:" in world_generated)
    assert_true("var sqrrl__leaked_AuditLog = len(self.AuditLog.all())" in world_generated)
    assert_true('abort("LeakedEntities:' in world_generated)
    assert_true("def __del__(deinit self):" in world_generated)
    assert_true("self.sqrrl__check_no_leaks()" in world_generated)
    assert_true("try:" not in world_generated)

    _rmtree(root)


def test_convert_directory_generates_finalize_init_from_json() raises:
    """`@@finalize_init_from_json()` desugars to
    `sqrrl__world.sqrrl__finalize_temp_keep_alives()` -- dropping every
    entity a prior `@@start_init_from_json(...)` retained only temporarily
    (see `TempKeepAlives`, `driver.emit_world_module`). Not inlined as
    `sqrrl__world.sqrrl__temp_keep_alives = None` directly at the call site
    -- confirmed empirically that corrupts earlier statements in the same
    function (see `emit_world_module`'s own doc comment for the concrete
    repro). Valid after `@@init()` too, not just the reload form (a no-op
    there, since an ordinary `sqrrl__init()`-built world already starts
    with `sqrrl__temp_keep_alives = None`)."""
    var root = "test/tmp_driver_finalize_init_from_json_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var schema_rel = open(join(root, "schema.rel"), "w")
    schema_rel.write("@@struct @@Department:\n    name: String\n\n")
    schema_rel.close()

    var main_rel = open(join(root, "main.rel"), "w")
    main_rel.write(
        "def main(dump: String) raises:\n"
        "    @@{\n"
        "        @@start_init_from_json(dump);\n"
        "        @@finalize_init_from_json();\n"
        "        print(len(@@Department.all()));\n"
        "    @@}\n"
    )
    main_rel.close()

    convert_directory(root)

    var f = open(join(root, "main.mojo"), "r")
    var generated = f.read()
    f.close()
    assert_true("sqrrl__world.sqrrl__finalize_temp_keep_alives()" in generated)

    _rmtree(root)


def test_convert_directory_rejects_finalize_init_from_json_before_declare() raises:
    """`@@finalize_init_from_json()` needs `sqrrl__world` already declared,
    same as `@@Type { ... }` construction or an ordinary `@@name(...)`
    world function call does -- rejected with the same
    'InvalidSquirrelSyntax' family of error rather than falling through to
    a confusing Mojo-level "sqrrl__world is not defined"."""
    var root = "test/tmp_driver_finalize_before_world_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var schema_rel = open(join(root, "schema.rel"), "w")
    schema_rel.write("@@struct @@Department:\n    name: String\n\n")
    schema_rel.close()

    var main_rel = open(join(root, "main.rel"), "w")
    main_rel.write(
        "def main() raises:\n"
        "    @@finalize_init_from_json();\n"
    )
    main_rel.close()

    with assert_raises(contains="InvalidSquirrelSyntax"):
        convert_directory(root)

    _rmtree(root)


def test_convert_directory_generates_init_from_json() raises:
    """`@@init_from_json(json)` desugars to `@@start_init_from_json(json)`
    immediately followed by `@@finalize_init_from_json()`, in one
    statement -- for the common case where a script doesn't need to grab
    anything from the reload beyond what real relation fields/`keepalive`
    tags already keep alive on their own, so there's nothing to remember
    to call separately (finalizing isn't optional cleanup -- skip it and
    the next leak check aborts, see `sqrrl__check_no_leaks`)."""
    var root = "test/tmp_driver_init_from_json_combined_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var schema_rel = open(join(root, "schema.rel"), "w")
    schema_rel.write("@@struct @@Department:\n    name: String\n\n")
    schema_rel.close()

    var main_rel = open(join(root, "main.rel"), "w")
    main_rel.write(
        "def main(dump: String) raises:\n"
        "    @@{\n"
        "        @@init_from_json(dump);\n"
        "        print(len(@@Department.all()));\n"
        "    @@}\n"
    )
    main_rel.close()

    convert_directory(root)

    var f = open(join(root, "main.mojo"), "r")
    var generated = f.read()
    f.close()
    assert_true(
        "sqrrl__world.sqrrl__check_no_leaks(); sqrrl__world ="
        " sqrrl__init_from_json(dump);"
        " sqrrl__world.sqrrl__finalize_temp_keep_alives()" in generated
    )

    _rmtree(root)


def test_convert_directory_rejects_init_from_json_without_declare_in_that_function() raises:
    """Same `world_declared` gate as `@@start_init_from_json(...)`'s own --
    a different function using `@@init_from_json(...)` needs its own
    `@@{` in that same function."""
    var root = "test/tmp_driver_init_from_json_no_declare_fixture"
    if exists(root):
        _rmtree(root)
    makedirs(root, exist_ok=True)

    var schema_rel = open(join(root, "schema.rel"), "w")
    schema_rel.write("@@struct @@Department:\n    name: String\n\n")
    schema_rel.close()

    var main_rel = open(join(root, "main.rel"), "w")
    main_rel.write(
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        "        var dump = String(\"{}\");\n"
        "        reload(dump);\n"
        "    @@}\n"
        "\n"
        "def reload(dump: String) raises:\n"
        "    @@init_from_json(dump);\n"
    )
    main_rel.close()

    with assert_raises(contains="needs '@@{'"):
        convert_directory(root)

    _rmtree(root)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
