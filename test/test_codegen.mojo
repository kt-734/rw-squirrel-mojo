from std.testing import assert_true, assert_equal, assert_raises, TestSuite

from squirrel_compiler.parser import Scanner
from squirrel_compiler.codegen import emit_table, emit_plain_struct, transform_source, encode_container_type


def empty_schema() -> Dict[String, Dict[String, String]]:
    return Dict[String, Dict[String, String]]()


def empty_function_returns() -> Dict[String, String]:
    return Dict[String, String]()


def empty_unique_fields() -> Dict[String, List[String]]:
    return Dict[String, List[String]]()


def empty_ordered_fields() -> Dict[String, List[String]]:
    return Dict[String, List[String]]()


def test_emits_state_struct_and_fields() raises:
    var sc = Scanner("@@struct @@Person:\n    name: String\n    age: UInt32\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct())

    assert_true("struct sqrrl__PersonTableState(TableStateLike, Movable, ImplicitlyDeletable):" in out)
    assert_true("var name: Rel[String]" in out)
    assert_true("var age: Rel[UInt32]" in out)


def test_emits_table_wrapper() raises:
    var sc = Scanner("@@struct @@Person:\n    name: String\n    age: UInt32\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct())

    assert_true("struct sqrrl__PersonTable(Movable):" in out)
    assert_true("var table: Table[sqrrl__PersonTableState]" in out)
    assert_true("self.table = Table[sqrrl__PersonTableState](sqrrl__PersonTableState())" in out)


def test_emits_create_with_all_fields() raises:
    var sc = Scanner("@@struct @@Person:\n    name: String\n    age: UInt32\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct())

    assert_true(
        "def create(mut self, name: String, age: UInt32) ->"
        " EntityHandle[sqrrl__PersonTableState]:" in out
    )
    assert_true("self.table.state[].state.name.put(e.id(), name)" in out)
    assert_true("self.table.state[].state.age.put(e.id(), age)" in out)


def test_emits_get_and_set_per_field() raises:
    var sc = Scanner("@@struct @@Person:\n    age: UInt32\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct())

    assert_true(
        "def get_age(self, e: EntityHandle[sqrrl__PersonTableState]) -> UInt32:" in out
    )
    assert_true("var got = self.table.state[].state.age.get_fwd(e.id())" in out)
    assert_true("return got.take()" in out)
    assert_true(
        "def set_age(mut self, e: EntityHandle[sqrrl__PersonTableState], v: UInt32):"
        in out
    )
    assert_true("self.table.state[].state.age.update(e.id(), v)" in out)


def test_emits_cleanup_relations_for_every_field() raises:
    # This is what closes the relation-leak-on-destroy bug: every field,
    # relation or not, gets fetch_remove_fwd'd when the owning entity dies.
    var sc = Scanner("@@struct @@Person:\n    name: String\n    @@employee: @@Employee\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct())

    assert_true("def sqrrl__cleanup_relations(mut self, id: UInt32):" in out)
    assert_true("_ = self.name.fetch_remove_fwd(id)" in out)
    assert_true("_ = self.employee.fetch_remove_fwd(id)" in out)


def test_relation_field_targets_the_other_table_state() raises:
    var sc = Scanner("@@struct @@Person:\n    @@employee: @@Employee\n")
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


def test_collection_relation_field_uses_ordinary_rel_by_default() raises:
    """A collection-typed relation field (`List[@@Employee]`) isn't
    special-cased into `ForwardOnlyRel` just for being a container --
    `List[EntityHandle[...]]` is `KeyElement` (confirmed:
    `conforms_to(List[EntityHandle[...]], Hashable)` is `True`), so it gets
    ordinary `Rel` like any other field, complete with a real `for_members`
    reverse lookup, unless explicitly marked `forwardonly`."""
    var sc = Scanner("@@struct @@Department:\n    name: String\n    @@members: List[@@Employee]\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct())

    assert_true(
        "var members: Rel[List[EntityHandle[sqrrl__EmployeeTableState]]]" in out
    )
    assert_true(
        "def create(mut self, name: String, members:"
        " List[EntityHandle[sqrrl__EmployeeTableState]]) ->"
        " EntityHandle[sqrrl__DepartmentTableState]:" in out
    )
    assert_true(
        "def get_members(self, e: EntityHandle[sqrrl__DepartmentTableState]) ->"
        " List[EntityHandle[sqrrl__EmployeeTableState]]:" in out
    )
    assert_true(
        "def set_members(mut self, e: EntityHandle[sqrrl__DepartmentTableState],"
        " v: List[EntityHandle[sqrrl__EmployeeTableState]]):" in out
    )
    assert_true(
        "def for_members(self, value: List[EntityHandle[sqrrl__EmployeeTableState]])"
        " -> List[EntityHandle[sqrrl__DepartmentTableState]]:" in out
    )
    assert_true("_ = self.members.fetch_remove_fwd(id)" in out)


def test_forward_only_field_uses_forward_only_rel_and_has_no_for_field() raises:
    var sc = Scanner("@@struct @@Foo:\n    forwardonly scores: List[Int]\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct())

    assert_true("var scores: ForwardOnlyRel[List[Int]]" in out)
    assert_true(
        "def get_scores(self, e: EntityHandle[sqrrl__FooTableState]) -> List[Int]:" in out
    )
    # No _bwd index on ForwardOnlyRel -- there's no get_bwd to build a for_<field>
    # reverse lookup from, unlike every plain/relation field above.
    assert_true("for_scores" not in out)
    assert_true("_ = self.scores.fetch_remove_fwd(id)" in out)


def test_ordered_field_uses_ordered_rel_and_range_query_methods() raises:
    """`ordered years_employed: UInt32` -- storage is `OrderedRel`, and
    instead of a single `get_bwd`-backed `for_<field>`, every range shape
    gets its own method: exact match (`between(value, value)`), the four
    strict/inclusive one-sided bounds, and `between` itself."""
    var sc = Scanner("@@struct @@Employee:\n    ordered years_employed: UInt32\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct())

    assert_true("var years_employed: OrderedRel[UInt32]" in out)
    assert_true(
        "def for_years_employed(self, value: UInt32) ->"
        " Set[EntityHandle[sqrrl__EmployeeTableState]]:" in out
    )
    assert_true(
        "self.table.state[].state.years_employed.get_bwd(value)" in out
    )
    for method_name in ["greater_than", "less_than", "at_least", "at_most"]:
        assert_true(
            String("def for_years_employed_") + method_name
            + "(self, value: UInt32) -> List[EntityHandle[sqrrl__EmployeeTableState]]:" in out
        )
        assert_true(
            "self.table.state[].state.years_employed." + method_name + "(value)" in out
        )
    assert_true(
        "def for_years_employed_between(self, low: UInt32, high: UInt32) ->"
        " List[EntityHandle[sqrrl__EmployeeTableState]]:" in out
    )
    assert_true(
        "self.table.state[].state.years_employed.between(low, high)" in out
    )


def test_emit_plain_struct_generates_valid_mojo_shape() raises:
    """The shorthand plain-struct grammar (`struct Name { field: Type,
    ... }`) isn't valid Mojo on its own -- `emit_plain_struct` is what
    turns its parsed fields into a real struct definition: traits,
    `var` fields, and a positional `__init__` assigning each one."""
    var sc = Scanner("struct Point { x: Int, y: Int }")
    assert_true(sc.find_next_plain_struct_decl())
    var out = emit_plain_struct(sc.parse_plain_struct())

    assert_true("struct Point(ImplicitlyCopyable, Movable, ImplicitlyDeletable):" in out)
    assert_true("var x: Int" in out)
    assert_true("var y: Int" in out)
    assert_true("def __init__(out self, var x: Int, var y: Int):" in out)
    assert_true("self.x = x^" in out)
    assert_true("self.y = y^" in out)


def test_emit_plain_struct_rewrites_relation_field() raises:
    """A shorthand plain struct's own `@@`-marked field is rewritten the
    same way a `@@struct`'s field type is -- `@@boss: @@Employee` becomes
    a real `EntityHandle[...]`-typed field, not left as unparseable `@@`
    syntax the way it would've been before `MarkerKind.PLAIN_STRUCT`
    existed (confirmed previously indistinguishable from
    `MarkerKind.ENTITY_PARAM`)."""
    var sc = Scanner("struct Note { @@boss: @@Employee, text: String }")
    assert_true(sc.find_next_plain_struct_decl())
    var out = emit_plain_struct(sc.parse_plain_struct())

    assert_true("var boss: EntityHandle[sqrrl__EmployeeTableState]" in out)
    assert_true("var text: String" in out)
    assert_true(
        "def __init__(out self, var boss: EntityHandle[sqrrl__EmployeeTableState], var text: String):" in out
    )


def test_transform_source_rewrites_shorthand_plain_struct_in_place() raises:
    """The full pipeline: a shorthand plain struct sitting alongside
    ordinary code gets replaced with its generated struct definition,
    and a `@@`-marked field inside it no longer misfires as
    `MarkerKind.ENTITY_PARAM` (confirmed empirically before this existed:
    `@@boss: @@Employee` used to raise "only valid as a function
    parameter or a variable declaration")."""
    var source = String(
        "struct Note {\n"
        "    @@boss: @@Employee,\n"
        "}\n"
        "\n"
        "def main() raises:\n"
        "    pass\n"
    )
    var out = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())
    assert_true("struct Note(ImplicitlyCopyable, Movable, ImplicitlyDeletable):" in out)
    assert_true("var boss: EntityHandle[sqrrl__EmployeeTableState]" in out)
    assert_true("def main() raises:" in out)


def test_multi_relation_field_uses_multi_rel_and_element_typed_accessors() raises:
    """`multi @@members: @@Employee` -- `type_str` is the bare element
    type, but the actual field is `Set[EntityHandle[...]]`, backed by
    `MultiRel[EntityHandle[...]]` (its own type parameter is the element
    type, not the field's whole `Set[...]` type). `add_to_<field>`/
    `remove_from_<field>`/`for_<field>` all take the bare element type too --
    `MultiRel`'s own `add`/`remove`/`get_bwd` shape -- unlike `get_<field>`/
    `set_<field>`, which still deal in the whole `Set[...]` field value.
    Neither `create` nor `set_members` needs `raises` here -- unlike
    `unique`, `MultiRel.put`/`update` don't raise (a `Set`-backed field
    can't hold a duplicate to reject in the first place)."""
    var sc = Scanner("@@struct @@Department:\n    name: String\n    multi @@members: @@Employee\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct())

    assert_true(
        "var members: MultiRel[EntityHandle[sqrrl__EmployeeTableState]]" in out
    )
    assert_true(
        "def create(mut self, name: String, members:"
        " Set[EntityHandle[sqrrl__EmployeeTableState]]) ->"
        " EntityHandle[sqrrl__DepartmentTableState]:" in out
    )
    assert_true(
        "def get_members(self, e: EntityHandle[sqrrl__DepartmentTableState]) ->"
        " Set[EntityHandle[sqrrl__EmployeeTableState]]:" in out
    )
    assert_true(
        "def set_members(mut self, e: EntityHandle[sqrrl__DepartmentTableState],"
        " v: Set[EntityHandle[sqrrl__EmployeeTableState]]):" in out
    )
    assert_true(
        "def add_to_members(mut self, e: EntityHandle[sqrrl__DepartmentTableState],"
        " value: EntityHandle[sqrrl__EmployeeTableState]) -> Bool:" in out
    )
    assert_true("return self.table.state[].state.members.add(e.id(), value)" in out)
    assert_true(
        "def remove_from_members(mut self, e: EntityHandle[sqrrl__DepartmentTableState],"
        " value: EntityHandle[sqrrl__EmployeeTableState]) -> Bool:" in out
    )
    assert_true("return self.table.state[].state.members.remove(e.id(), value)" in out)
    assert_true(
        "def for_members(self, value: EntityHandle[sqrrl__EmployeeTableState]) ->"
        " List[EntityHandle[sqrrl__DepartmentTableState]]:" in out
    )
    assert_true("_ = self.members.fetch_remove_fwd(id)" in out)


def test_multi_plain_field_uses_element_type_not_list() raises:
    """`multi` isn't restricted to relation fields -- `multi tags: String`
    gets `MultiRel[String]`, and `add_to_tags`/`remove_from_tags`/`for_tags`
    all take a bare `String`, not `List[String]`."""
    var sc = Scanner("@@struct @@Foo:\n    multi tags: String\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct())

    assert_true("var tags: MultiRel[String]" in out)
    assert_true(
        "def add_to_tags(mut self, e: EntityHandle[sqrrl__FooTableState], value: String) -> Bool:" in out
    )
    assert_true(
        "def for_tags(self, value: String) -> List[EntityHandle[sqrrl__FooTableState]]:" in out
    )


def test_all_generated_unconditionally() raises:
    """Every struct gets `all()`, whether or not it's `keepalive`-tagged --
    a thin delegate to `Table.all()` (which walks the id allocator directly,
    not any one field's own index), so a struct with no `keepalive` tag
    still gets a working enumeration of whatever's currently alive."""
    var sc = Scanner("@@struct @@Foo:\n    name: String\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct())

    assert_true("def all(self) -> Set[EntityHandle[sqrrl__FooTableState]]:" in out)
    assert_true("return self.table.all()" in out)
    assert_true("keepalive" not in out)


def test_keepalive_struct_gets_keepalive_field_and_dont_keepalive() raises:
    """`keepalive` adds a `Set[EntityHandle[...]]` field to the *table
    wrapper* (`sqrrl__FooTable`), not the `TableState` -- putting it on
    `TableState` would create a self-cycle (each kept-alive handle's own
    `ArcPointer` points back at the very `TableStorage` holding the set that
    holds it), leaking the whole table forever the moment anything was kept
    alive. `create` adds every new entity to it by default; `dont_keepalive`
    is the opt-out, releasing one back to ordinary refcounted lifetime."""
    var sc = Scanner("@@struct keepalive @@Foo:\n    name: String\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct())

    var state_pos = out.find("struct sqrrl__FooTableState")
    var wrapper_pos = out.find("struct sqrrl__FooTable(Movable):")
    var field_pos = out.find("var keepalive: Set[EntityHandle[sqrrl__FooTableState]]")
    assert_true(state_pos >= 0 and wrapper_pos > state_pos and field_pos > wrapper_pos)

    assert_true("self.keepalive = Set[EntityHandle[sqrrl__FooTableState]]()" in out)
    assert_true("self.keepalive.add(e.copy())" in out)
    assert_true(
        "def dont_keepalive(mut self, e: EntityHandle[sqrrl__FooTableState]) -> Bool:" in out
    )
    assert_true("self.keepalive.remove(e)" in out)
    assert_true("def all(self) -> Set[EntityHandle[sqrrl__FooTableState]]:" in out)


def test_transform_source_passes_plain_code_through_untouched() raises:
    var source = String("def add(a: Int, b: Int) -> Int:\n    return a + b\n")
    assert_equal(transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields()), source)


def test_transform_source_emits_table_for_struct() raises:
    var out = transform_source("@@struct @@Person:\n    name: String\n", empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())
    assert_true("struct sqrrl__PersonTableState(TableStateLike, Movable, ImplicitlyDeletable):" in out)
    assert_true("struct sqrrl__PersonTable(Movable):" in out)


def test_transform_source_rewrites_construct_through_world() raises:
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@alice = @@Person { .name = "alice" };\n'
        '    var @@bob = @@Person { .name = "bob" };\n'
    )
    var out = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())
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
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@alice = Person { .name = "alice" };\n'
    )
    with assert_raises():
        _ = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())


def test_transform_source_rewrites_field_read_and_write() raises:
    var source = String(
        "@@struct @@Person:\n    name: String\n    age: UInt32\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@alice = @@Person { .name = "alice", .age = 30 };\n'
        "    @@alice.age = 31;\n"
        "    print(@@alice.name);\n"
    )
    var out = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())
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
        "@@struct @@Employee:\n    title: String\n\n"
        "\n"
        "@@struct @@Person:\n    name: String\n    @@employee: @@Employee\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@alice = @@Person { .name = "alice", .@@employee = bob };\n'
        "    print(@@alice.@@employee.title);\n"
        "    @@alice.@@employee.title = \"manager\";\n"
    )
    var out = transform_source(source, _person_employee_boss_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())
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
        "@@struct @@Employee:\n    title: String\n\n"
        "\n"
        "@@struct @@Person:\n    name: String\n    @@employee: @@Employee\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@alice = @@Person { .name = "alice", .@@employee = bob };\n'
        "    print(@@alice.@@employee.@@boss.name);\n"
    )
    var out = transform_source(source, _person_employee_boss_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())
    assert_true(
        "print(sqrrl__world.Person.get_name(sqrrl__world.Employee.get_boss(sqrrl__world.Person.get_employee(sqrrl__alice))));"
        in out
    )


def test_transform_source_rewrites_instance_call_without_get_prefix() raises:
    """`@@eng.add_to_projects(@@website)` -- a call directly on a
    `multi`-marked field, not a plain field read/write -- must not get the
    `get_<field>` treatment (`@@alice.@@employee.title`'s own shape): the
    generated `add_to_<field>(mut self, e, value)` takes the entity as its
    own first argument, so `expr` (the entity) is spliced in as that first
    argument and the call's own `(args)` gets a comma inserted before
    whatever the caller wrote, rather than the whole thing being wrapped as
    `get_add_to_projects(entity)(args)` (which isn't even the right shape
    -- `get_<field>` doesn't exist for `add_to_<field>` in the first
    place)."""
    var source = String(
        "@@struct @@Project:\n    name: String\n\n"
        "\n"
        "@@struct @@Department:\n    name: String\n    multi @@projects: @@Project\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@eng = @@Department { .name = "Engineering", .@@projects = Set[@@Project]() };\n'
        '    var @@website = @@Project { .name = "Website" };\n'
        "    _ = @@eng.add_to_projects(@@website);\n"
        "    _ = @@eng.remove_from_projects(@@website);\n"
    )
    var schema = Dict[String, Dict[String, String]]()
    var department_fields = Dict[String, String]()
    department_fields["projects"] = encode_container_type("Set", "Project")
    schema["Department"] = department_fields^
    var out = transform_source(source, schema^, empty_function_returns(), empty_unique_fields(), empty_ordered_fields())
    assert_true(
        "_ = sqrrl__world.Department.add_to_projects(sqrrl__eng, sqrrl__website);" in out
    )
    assert_true(
        "_ = sqrrl__world.Department.remove_from_projects(sqrrl__eng, sqrrl__website);" in out
    )
    assert_true("get_add_to_projects" not in out)
    assert_true("get_remove_from_projects" not in out)


def test_transform_source_rewrites_nested_entity_reference_in_construct() raises:
    var source = String(
        "@@struct @@Employee:\n    title: String\n\n"
        "\n"
        "@@struct @@Person:\n    name: String\n    @@employee: @@Employee\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@bob = @@Employee { .title = "engineer" };\n'
        '    var @@alice = @@Person { .name = "alice", .@@employee = @@bob };\n'
    )
    var out = transform_source(source, _person_employee_boss_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())
    assert_true(
        'var sqrrl__alice = sqrrl__world.Person.create(name = "alice", employee = sqrrl__bob);'
        in out
    )


def test_transform_source_rewrites_nested_construct_in_construct() raises:
    var source = String(
        "@@struct @@Employee:\n    title: String\n\n"
        "\n"
        "@@struct @@Person:\n    name: String\n    @@employee: @@Employee\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@alice = @@Person { .name = "alice", .@@employee = @@Employee { .title = "engineer" } };\n'
    )
    var out = transform_source(source, _person_employee_boss_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())
    assert_true(
        'var sqrrl__alice = sqrrl__world.Person.create(name = "alice", employee = sqrrl__world.Employee.create(title = "engineer"));'
        in out
    )


def test_transform_source_rewrites_marker_embedded_in_plain_field_value() raises:
    # A plain (non-relation) field's value isn't just "starts with @@" --
    # a marker can be embedded anywhere inside it, e.g. wrapped in a call.
    var source = String(
        "@@struct @@Department:\n    name: String\n\n"
        "\n"
        "@@struct @@Person:\n    name: String\n    home: Address\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@dept = @@Department { .name = "Engineering" };\n'
        '    var @@alice = @@Person { .name = "alice", .home = Address(@@dept.name) };\n'
    )
    var out = transform_source(source, _person_employee_boss_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())
    assert_true(
        'var sqrrl__alice = sqrrl__world.Person.create(name = "alice",'
        " home = Address(sqrrl__world.Department.get_name(sqrrl__dept)));"
        in out
    )


def test_transform_source_rejects_unmarked_relation_field_in_construct() raises:
    var source = String(
        "@@struct @@Employee:\n    title: String\n\n"
        "\n"
        "@@struct @@Person:\n    name: String\n    @@employee: @@Employee\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@alice = @@Person { .name = "alice", .employee = bob };\n'
    )
    with assert_raises():
        _ = transform_source(source, _person_employee_boss_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())


def test_transform_source_rejects_at_marked_plain_field_in_construct() raises:
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@alice = @@Person { .@@name = "alice" };\n'
    )
    with assert_raises():
        _ = transform_source(source, _person_employee_boss_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())


def test_transform_source_rejects_unknown_relation_hop() raises:
    var source = String(
        "@@struct @@Employee:\n    title: String\n\n"
        "\n"
        "@@struct @@Person:\n    name: String\n    @@employee: @@Employee\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@alice = @@Person { .name = "alice", .@@employee = bob };\n'
        "    print(@@alice.@@manager.title);\n"
    )
    with assert_raises():
        _ = transform_source(source, _person_employee_boss_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())


def test_transform_source_threads_entity_across_functions() raises:
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def @@print_name(@@subject: @@Person) raises:\n"
        "    print(@@subject.name);\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@alice = @@Person { .name = "alice" };\n'
        "    @@print_name(@@alice);\n"
    )
    var out = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())
    assert_true(
        "def sqrrl__print_name(mut sqrrl__world: sqrrl__Squirrel,"
        " sqrrl__subject: EntityHandle[sqrrl__PersonTableState]) raises:"
        in out
    )
    assert_true("print(sqrrl__world.Person.get_name(sqrrl__subject));" in out)
    assert_true("sqrrl__print_name(sqrrl__world, sqrrl__alice);" in out)


def test_transform_source_rejects_entity_param_syntax_outside_signature() raises:
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        "    @@alice: @@Person;\n"
    )
    with assert_raises():
        _ = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())


def test_transform_source_rejects_field_access_on_unconstructed_entity() raises:
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        "    print(@@alice.name);\n"
    )
    with assert_raises():
        _ = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())


def test_transform_source_rejects_construct_without_world() raises:
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        '    var @@alice = @@Person { .name = "alice" };\n'
    )
    with assert_raises():
        _ = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())


def test_transform_source_threads_world_through_function_params_and_calls() raises:
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        "    @@make_person();\n"
        "\n"
        'def @@make_person() raises:\n'
        '    var @@alice = @@Person { .name = "alice" };\n'
    )
    var out = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())
    assert_true("sqrrl__make_person(sqrrl__world);" in out)
    assert_true("def sqrrl__make_person(mut sqrrl__world: sqrrl__Squirrel) raises:" in out)
    assert_true('var sqrrl__alice = sqrrl__world.Person.create(name = "alice");' in out)


def test_transform_source_rewrites_world_func_name_in_import_statement() raises:
    """`from logic.factories import @@make_person` -- importing a
    `WORLD_FUNC` by its `@@`-marked name, matching how it's actually
    called at every use site, rather than the raw `sqrrl__`-prefixed name
    directly. The `@@make_person` here is neither a declaration (no `=`)
    nor an already-tracked entity, which `NAME_REF`'s ordinary check would
    otherwise reject -- `is_in_import_statement` recognizes the `from ...
    import ...` line and skips that check, same as for the plain,
    unprefixed names imported alongside it."""
    var source = String(
        "from logic.factories import @@make_person, other_helper\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        "    @@make_person();\n"
    )
    var out = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())
    assert_true("from logic.factories import sqrrl__make_person, other_helper" in out)


def test_transform_source_keeps_string_argument_after_world_func_call() raises:
    """`@@funcName(` used to peek past the opening paren with
    `skip_trivia()` (skips whitespace *and* string literals/comments) to
    decide whether more arguments follow -- so a string-literal first
    argument sitting right after `(` was silently swallowed and dropped
    from the output entirely, the same `skip_trivia`-eats-a-string-literal
    bug already fixed twice elsewhere this session, just in a third,
    unrelated spot. Fixed by using `skip_whitespace()` there instead."""
    var source = String(
        "@@struct @@Department:\n    name: String\n\n"
        "\n"
        "def @@make_department(name: String) raises -> @@Department:\n"
        '    var @@d = @@Department { .name = name };\n'
        "    return @@d;\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@dept = @@make_department("Engineering");\n'
    )
    var out = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())
    assert_true(
        'var sqrrl__dept = sqrrl__make_department(sqrrl__world, "Engineering");'
        in out
    )


def test_transform_source_rejects_construct_in_function_missing_world_param() raises:
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        "    make_person();\n"
        "\n"
        "def make_person() raises:\n"
        '    var @@alice = @@Person { .name = "alice" };\n'
    )
    with assert_raises():
        _ = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())


def test_transform_source_rewrites_entity_returning_function() raises:
    """A function's return type can be marked `@@Type`, and the call
    site's result can be bound to a properly typed, `entity_to_type`-
    tracked `@@` variable via the explicit `@@name: @@Type` form -- needed
    because the right-hand side (a plain function call) isn't itself a
    `@@`-marked expression for the type to be inferred from."""
    var source = String(
        "@@struct @@Department:\n    name: String\n\n"
        "\n"
        "def @@make_department() raises -> @@Department:\n"
        '    var @@d = @@Department { .name = "engineering" };\n'
        "    return @@d;\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        "    var @@dept: @@Department = @@make_department();\n"
        "    print(@@dept.name);\n"
    )
    var out = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())
    assert_true(
        "def sqrrl__make_department(mut sqrrl__world: sqrrl__Squirrel) raises"
        " -> EntityHandle[sqrrl__DepartmentTableState]:" in out
    )
    assert_true(
        "var sqrrl__dept: EntityHandle[sqrrl__DepartmentTableState] ="
        " sqrrl__make_department(sqrrl__world);" in out
    )
    assert_true("print(sqrrl__world.Department.get_name(sqrrl__dept));" in out)


def _department_function_returns() -> Dict[String, String]:
    var out = Dict[String, String]()
    out["make_department"] = "Department"
    return out^


def test_transform_source_infers_type_for_at_marked_variable_from_registry() raises:
    """With `make_department` known (via `function_returns`) to return
    `@@Department`, `var @@dept = @@make_department();` -- no explicit
    `: @@Type` -- infers `entity_to_type` automatically, since the call
    site itself (`MarkerKind.WORLD_FUNC`) is always a marker regardless of
    its argument list, unlike a plain unmarked function name would be."""
    var source = String(
        "@@struct @@Department:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        "    var @@dept = @@make_department();\n"
        "    print(@@dept.name);\n"
    )
    var out = transform_source(source, empty_schema(), _department_function_returns(), empty_unique_fields(), empty_ordered_fields())
    assert_true(
        "var sqrrl__dept = sqrrl__make_department(sqrrl__world);" in out
    )
    assert_true("print(sqrrl__world.Department.get_name(sqrrl__dept));" in out)


def test_transform_source_rejects_unmarked_variable_for_entity_returning_call() raises:
    """`var x = @@make_department();` (unmarked `x`) is rejected when
    `make_department` is known to return `@@Department` -- the call
    itself always being a marker (`@@make_department(...)`, regardless of
    arguments) is what makes this reliably catchable, unlike a plain
    function name would be."""
    var source = String(
        "@@struct @@Department:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        "    var x = @@make_department();\n"
    )
    with assert_raises():
        _ = transform_source(source, empty_schema(), _department_function_returns(), empty_unique_fields(), empty_ordered_fields())


def test_transform_source_allows_entity_returning_call_as_argument() raises:
    """An entity-returning call used as a sub-expression/argument, rather
    than the initializer of a fresh `var` declaration, isn't required to be
    bound to an `@@`-marked variable at all -- there's no variable there to
    mark in the first place."""
    var source = String(
        "@@struct @@Department:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        "    report(@@make_department());\n"
    )
    var out = transform_source(source, empty_schema(), _department_function_returns(), empty_unique_fields(), empty_ordered_fields())
    assert_true("report(sqrrl__make_department(sqrrl__world));" in out)


def _person_unique_email_fields() -> Dict[String, List[String]]:
    var email_list = List[String]()
    email_list.append("email")
    var out = Dict[String, List[String]]()
    out["Person"] = email_list^
    return out^


def _person_only_schema() -> Dict[String, Dict[String, String]]:
    """Registers `Person` as a known `@@struct` with no relation fields --
    `@@Type.method(...)`'s "is this a known type" check (`relation_schema`)
    needs `Person` present, even though it has nothing to put in the inner
    dict, unlike `_person_employee_boss_schema` which also needs real
    relation-field entries."""
    var schema = Dict[String, Dict[String, String]]()
    schema["Person"] = Dict[String, String]()
    return schema^


def test_transform_source_rewrites_type_level_call() raises:
    """`@@Type.method(args)` -- a table-level call, not an instance field
    access -- rewrites to `sqrrl__world.Type.method(args)`, letting a
    generated `for_<field>`/`create` be reached through `@@`-marked syntax
    instead of the raw `sqrrl__world` name."""
    var source = String(
        "@@struct @@Person:\n    unique email: String\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@matches = @@Person.for_name("alice");\n'
    )
    var out = transform_source(source, _person_only_schema(), empty_function_returns(), _person_unique_email_fields(), empty_ordered_fields())
    assert_true('var sqrrl__matches = sqrrl__world.Person.for_name("alice");' in out)


def test_transform_source_infers_type_for_unique_lookup_call() raises:
    """A `unique` field's own `for_<field>` returns a single entity, same as
    `create` -- binding it to an `@@`-marked variable (no explicit `: @@Type`
    needed) registers `entity_to_type` from `unique_fields`, so `@@found.name`
    works afterward."""
    var source = String(
        "@@struct @@Person:\n    unique email: String\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@found = @@Person.for_email("alice@example.com");\n'
        "    print(@@found.name);\n"
    )
    var out = transform_source(source, _person_only_schema(), empty_function_returns(), _person_unique_email_fields(), empty_ordered_fields())
    assert_true(
        'var sqrrl__found = sqrrl__world.Person.for_email("alice@example.com");' in out
    )
    assert_true("print(sqrrl__world.Person.get_name(sqrrl__found));" in out)


def test_transform_source_rejects_unmarked_variable_for_unique_lookup_call() raises:
    """`var found = @@Person.for_email(...);` (unmarked `found`) is rejected
    for a `unique` field's `for_<field>`, same reasoning as an entity-
    returning `@@funcName()` call."""
    var source = String(
        "@@struct @@Person:\n    unique email: String\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var found = @@Person.for_email("alice@example.com");\n'
    )
    with assert_raises():
        _ = transform_source(source, _person_only_schema(), empty_function_returns(), _person_unique_email_fields(), empty_ordered_fields())


def test_transform_source_rejects_unmarked_variable_for_non_unique_lookup_call() raises:
    """A non-`unique` field's `for_<field>` returns `List[EntityHandle[...]]`
    -- now that a container of entities can be properly tracked (via
    `entity_to_type`'s `List[Type]` encoding) and followed up with
    `@@name[i].field`, binding it to a plain (non-`@@`) variable is
    rejected too, same as `create`/a `unique` field's `for_<field>`."""
    var source = String(
        "@@struct @@Person:\n    unique email: String\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var matches = @@Person.for_name("alice");\n'
    )
    with assert_raises():
        _ = transform_source(source, _person_only_schema(), empty_function_returns(), _person_unique_email_fields(), empty_ordered_fields())


def test_transform_source_infers_container_type_for_non_unique_lookup_call() raises:
    """`var @@matches = @@Person.for_name(...);` (no explicit
    `: List[@@Type]` needed) infers `entity_to_type["matches"] =
    "List[Person]"` from `unique_fields` (`name` isn't unique, so
    `for_name` must return a list), letting `@@matches[0].name` work
    afterward."""
    var source = String(
        "@@struct @@Person:\n    unique email: String\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@matches = @@Person.for_name("alice");\n'
        "    print(@@matches[0].name);\n"
    )
    var out = transform_source(source, _person_only_schema(), empty_function_returns(), _person_unique_email_fields(), empty_ordered_fields())
    assert_true(
        'var sqrrl__matches = sqrrl__world.Person.for_name("alice");' in out
    )
    assert_true("print(sqrrl__world.Person.get_name(sqrrl__matches[0]));" in out)


def test_transform_source_infers_container_type_for_all_call() raises:
    """`var @@entries = @@Person.all();` infers `entity_to_type["entries"]
    = "Set[Person]"` -- `all()` is generated for every struct (see
    `emit_table`), returning `Set[EntityHandle[...]]`, not `List[...]` like
    `for_<field>` -- so binding its result no longer falls through to
    'never constructed or bound' the way it did before `all` was
    recognized alongside `create`/`for_`/`get_`."""
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        "    var @@entries = @@Person.all();\n"
        "    print(len(@@entries));\n"
    )
    var out = transform_source(source, _person_only_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())
    assert_true("var sqrrl__entries = sqrrl__world.Person.all();" in out)
    assert_true("print(len(sqrrl__entries));" in out)


def test_transform_source_rejects_unmarked_variable_for_all_call() raises:
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        "    var entries = @@Person.all();\n"
    )
    with assert_raises(contains="Set[@@Person]"):
        _ = transform_source(source, _person_only_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())


def test_transform_source_rewrites_for_loop_over_all_call() raises:
    """`for @@entry in @@Person.all():` binds `@@entry` to the *element*
    type (`Person`), not the whole `Set[Person]` -- so `@@entry.name`
    inside the loop body reads through `get_name`, the same as it would for
    any other single, non-container-tracked entity variable."""
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        "    for @@entry in @@Person.all():\n"
        "        print(@@entry.name);\n"
    )
    var out = transform_source(source, _person_only_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())
    assert_true("for sqrrl__entry in  sqrrl__world.Person.all():" in out)
    assert_true("print(sqrrl__world.Person.get_name(sqrrl__entry));" in out)


def test_transform_source_rewrites_for_loop_over_for_field_call() raises:
    """The same binding works for a `for_<field>`'s own `List[...]` result,
    not just `all()` -- both are `is_list_returning` cases, just encoded
    with different container wrappers (`List` vs `Set`)."""
    var source = String(
        "@@struct @@Person:\n    unique email: String\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        "    for @@match in @@Person.for_name(\"alice\"):\n"
        "        print(@@match.email);\n"
    )
    var out = transform_source(source, _person_only_schema(), empty_function_returns(), _person_unique_email_fields(), empty_ordered_fields())
    assert_true('for sqrrl__match in  sqrrl__world.Person.for_name("alice"):' in out)
    assert_true("print(sqrrl__world.Person.get_email(sqrrl__match));" in out)


def test_transform_source_leaves_unmarked_for_loop_untouched() raises:
    """A `for name in names:` with no `@@` on the target passes through
    unchanged -- this scanner never even reaches it as a marker (see
    `test_find_next_marker_ignores_unmarked_for_loop_target` in
    test_parser.mojo), so there's nothing here to rewrite."""
    var source = String(
        "def main():\n"
        "    var names = List[String]();\n"
        "    for name in names:\n"
        "        print(name);\n"
    )
    assert_equal(transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields()), source)


def test_transform_source_rejects_field_access_without_index_on_container() raises:
    """`@@matches.name` (no `[i]`) on a container-tracked variable -- rejected
    with a clear error instead of a confusing downstream Mojo failure."""
    var source = String(
        "@@struct @@Person:\n    unique email: String\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@matches = @@Person.for_name("alice");\n'
        "    print(@@matches.name);\n"
    )
    with assert_raises():
        _ = transform_source(source, _person_only_schema(), empty_function_returns(), _person_unique_email_fields(), empty_ordered_fields())


def test_transform_source_rejects_index_on_non_container() raises:
    """`@@found[0].name` on a variable that isn't container-tracked --
    rejected, since indexing a single entity doesn't make sense."""
    var source = String(
        "@@struct @@Person:\n    unique email: String\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@found = @@Person.for_email("alice@example.com");\n'
        "    print(@@found[0].name);\n"
    )
    with assert_raises():
        _ = transform_source(source, _person_only_schema(), empty_function_returns(), _person_unique_email_fields(), empty_ordered_fields())


def test_transform_source_supports_explicit_container_entity_param() raises:
    """`@@name: List[@@Type] = expr;` -- the explicit-annotation form,
    alongside the auto-inferred one -- emits a `List[EntityHandle[...]]`
    declaration and registers the same container encoding."""
    var source = String(
        "@@struct @@Person:\n    unique email: String\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@matches: List[@@Person] = @@Person.for_name("alice");\n'
        "    print(@@matches[0].name);\n"
    )
    var out = transform_source(source, _person_only_schema(), empty_function_returns(), _person_unique_email_fields(), empty_ordered_fields())
    assert_true(
        "sqrrl__matches: List[EntityHandle[sqrrl__PersonTableState]]" in out
    )
    assert_true("print(sqrrl__world.Person.get_name(sqrrl__matches[0]));" in out)


def _department_members_schema() -> Dict[String, Dict[String, String]]:
    """Department.members -> a `List[Employee]`-encoded target, the same
    shape `build_relation_schema` produces for a `List[@@Employee]`-typed
    field (see `encode_container_type`) -- exercises `get_<field>`'s
    container-vs-single-entity branch on the read side."""
    var schema = Dict[String, Dict[String, String]]()
    var department_fields = Dict[String, String]()
    department_fields["members"] = encode_container_type("List", "Employee")
    schema["Department"] = department_fields^
    return schema^


def test_transform_source_infers_container_type_for_collection_relation_get_call() raises:
    """`@@Type.get_<field>(entity)` for a *collection-typed* relation field
    returns `List[EntityHandle[...]]`, not a single entity -- binding it to
    a bare `var @@x = ...` (no explicit type) must infer the container type
    from `relation_schema`, same as a non-unique `for_<field>` already
    does, and the result must be indexable afterward."""
    var source = String(
        "@@struct @@Employee:\n    title: String\n\n"
        "\n"
        "@@struct @@Department:\n    name: String\n    @@members: List[@@Employee]\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        "    var @@got = @@Department.get_members(eng);\n"
        "    print(@@got[0].title);\n"
    )
    var out = transform_source(source, _department_members_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())
    assert_true("var sqrrl__got = sqrrl__world.Department.get_members(eng);" in out)
    assert_true("print(sqrrl__world.Employee.get_title(sqrrl__got[0]));" in out)


def test_transform_source_rejects_unmarked_variable_for_collection_relation_get_call() raises:
    """Binding `@@Department.get_members(...)` to a plain, unmarked variable
    is rejected too, same as any other container- or entity-returning call."""
    var source = String(
        "@@struct @@Employee:\n    title: String\n\n"
        "\n"
        "@@struct @@Department:\n    name: String\n    @@members: List[@@Employee]\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        "    var got = @@Department.get_members(eng);\n"
    )
    with assert_raises():
        _ = transform_source(source, _department_members_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())


def test_transform_source_infers_type_for_relation_get_call() raises:
    """`@@Type.get_<field>(entity)` for a *relation* field also returns a
    single `EntityHandle`, but of that field's own target type -- not
    `Type` itself -- so binding it to an `@@`-marked variable must
    register the *target* type (`relation_schema[Type][field]`), not
    `Type`. `Employee.boss -> Person` here, so `@@Employee.get_boss(...)`
    binds as `@@Person`, not `@@Employee`."""
    var source = String(
        "@@struct @@Employee:\n    title: String\n\n"
        "\n"
        "@@struct @@Person:\n    name: String\n    @@employee: @@Employee\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@alice = @@Person { .name = "alice", .@@employee = bob };\n'
        "    var @@boss = @@Employee.get_boss(bob);\n"
        "    print(@@boss.name);\n"
    )
    var out = transform_source(source, _person_employee_boss_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())
    assert_true("var sqrrl__boss = sqrrl__world.Employee.get_boss(bob);" in out)
    assert_true("print(sqrrl__world.Person.get_name(sqrrl__boss));" in out)


def test_transform_source_rejects_unmarked_variable_for_relation_get_call() raises:
    """Binding `@@Employee.get_boss(...)` (a relation `get_<field>`) to a
    plain, unmarked variable is rejected too, same as `create`/`for_<field>`."""
    var source = String(
        "@@struct @@Employee:\n    title: String\n\n"
        "\n"
        "@@struct @@Person:\n    name: String\n    @@employee: @@Employee\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        "    var boss = @@Employee.get_boss(bob);\n"
    )
    with assert_raises():
        _ = transform_source(source, _person_employee_boss_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())


def test_transform_source_rejects_type_level_call_on_unknown_type() raises:
    """`@@Foo.bar()` where `Foo` is neither a declared entity nor a known
    `@@struct` -- rejected with a clear error instead of silently emitting
    a reference to a type that was never declared."""
    var source = String(
        "def main() raises:\n"
        "    @@init();\n"
        "    @@Foo.bar();\n"
    )
    with assert_raises():
        _ = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())


def _make_team_function_returns() -> Dict[String, String]:
    var out = Dict[String, String]()
    out["make_team"] = encode_container_type("List", "Person")
    return out^


def test_transform_source_rewrites_container_return_type_signature() raises:
    """`def @@funcName(...) -> List[@@Type]:` -- the container form of a
    return-type marking -- rewrites to `-> List[EntityHandle[...]]:` with
    no duplication: the surrounding `List[`/`]` are never consumed by the
    `@@Type` marker itself (it sits *inside* them), so they stay in the
    output as ordinary pass-through text and only the type itself gets
    replaced."""
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def @@make_team() -> List[@@Person]:\n"
        "    var team = [];\n"
        "    return team;\n"
    )
    var out = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())
    assert_true(
        "def sqrrl__make_team(mut sqrrl__world: sqrrl__Squirrel) ->"
        " List[EntityHandle[sqrrl__PersonTableState]]:" in out
    )


def test_transform_source_rewrites_return_type_with_second_type_parameter() raises:
    """`-> Dict[@@Type1, @@Type2]:` -- a container with more than one type
    parameter, both `@@`-marked -- rewrites *both*, not just the first.
    `is_after_container_bracket` has to find the *enclosing* `[` by
    tracking bracket depth backward, since the second parameter isn't
    immediately preceded by `[` the way the first one is (it's preceded by
    `, `), and the first parameter's own presence means a naive
    single-level backward check would stop too early."""
    var source = String(
        "@@struct @@AuditLog:\n    message: String\n\n"
        "@@struct @@Employee:\n    title: String\n\n"
        "\n"
        "def @@test2() -> Dict[@@AuditLog, @@Employee]:\n"
        "    return Dict[@@AuditLog, @@Employee]();\n"
    )
    var out = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())
    assert_true(
        "def sqrrl__test2(mut sqrrl__world: sqrrl__Squirrel) ->"
        " Dict[EntityHandle[sqrrl__AuditLogTableState],"
        " EntityHandle[sqrrl__EmployeeTableState]]:" in out
    )
    assert_true(
        "return Dict[EntityHandle[sqrrl__AuditLogTableState],"
        " EntityHandle[sqrrl__EmployeeTableState]]();" in out
    )


def test_transform_source_infers_container_type_for_world_func_call() raises:
    """A `def @@funcName(...) -> List[@@Type]:` function's return, tracked
    via `build_function_returns`'s container encoding, infers
    `entity_to_type` the same way a bare `@@Type`-returning one already
    does -- binding to an `@@`-marked variable (no explicit annotation
    needed) enables `@@found[i].field` afterward."""
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        "    var @@found = @@make_team();\n"
        "    print(@@found[0].name);\n"
    )
    var out = transform_source(source, empty_schema(), _make_team_function_returns(), empty_unique_fields(), empty_ordered_fields())
    assert_true("var sqrrl__found = sqrrl__make_team(sqrrl__world);" in out)
    assert_true("print(sqrrl__world.Person.get_name(sqrrl__found[0]));" in out)


def test_transform_source_rewrites_for_loop_over_container_returning_world_func_call() raises:
    """`for @@name in @@make_team():` binds `@@name` to the *element* type
    (`Person`), the same as it would for a table-level call's `is_list_
    returning` case -- `WORLD_FUNC`'s own call-site branch needs its own
    `pending_for_loop_decl` consumption, distinct from the table-call one,
    since a `@@`-marked function's container return type is tracked via
    `function_returns`, not `relation_schema`/`unique_fields`."""
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        "    for @@member in @@make_team():\n"
        "        print(@@member.name);\n"
    )
    var out = transform_source(source, empty_schema(), _make_team_function_returns(), empty_unique_fields(), empty_ordered_fields())
    assert_true("for sqrrl__member in  sqrrl__make_team(sqrrl__world):" in out)
    assert_true("print(sqrrl__world.Person.get_name(sqrrl__member));" in out)


def test_transform_source_rejects_unmarked_variable_for_container_returning_world_func_call() raises:
    """`var found = @@make_team();` (unmarked) is rejected for a
    container-returning `@@funcName()`, same as a bare entity-returning one."""
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        "    var found = @@make_team();\n"
    )
    with assert_raises():
        _ = transform_source(source, empty_schema(), _make_team_function_returns(), empty_unique_fields(), empty_ordered_fields())


def test_transform_source_rewrites_bare_generic_instantiation_of_entity_type() raises:
    """`@@Type` used as a bare generic type argument, `List[@@Type]()`,
    with no return-type/entity-param context around it at all -- the same
    `Ident[@@Type]` shape works wherever it occurs, not just in a
    signature, since the only thing checked is what's immediately before
    the `[`."""
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        "    var @@team: List[@@Person] = List[@@Person]();\n"
    )
    var out = transform_source(source, _person_only_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())
    assert_true(
        "sqrrl__team: List[EntityHandle[sqrrl__PersonTableState]] ="
        " List[EntityHandle[sqrrl__PersonTableState]]();" in out
    )


def test_transform_source_rejects_unmarked_name_for_container_declaration() raises:
    """`name: List[@@Type]` -- a variable (or plain `struct` field)
    declaration whose type is a container of `@@`-marked entities, but
    whose own name isn't `@@`-marked -- used to compile silently: the
    inner `@@Type` got rewritten to `EntityHandle[...]` regardless, with
    nothing checking that the declared name itself was marked, unlike a
    `@@struct`'s own relation field (`parse_fields` already rejects
    exactly this shape there). Confirmed via a hand-written plain `struct`
    field before this check existed: `var members: List[@@Employee]`
    compiled without error, generating an inconsistent
    `members: List[EntityHandle[...]]` field nobody could ever construct
    correctly through the `@@`-marked pipeline."""
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        "    var team: List[@@Person] = List[@@Person]();\n"
    )
    with assert_raises():
        _ = transform_source(source, _person_only_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())


def test_transform_source_allows_container_method_call_without_indexing() raises:
    """`@@team.append(@@alice)` -- a method call directly on a
    container-tracked variable itself, not a field access on one of its
    elements -- passes through with just `@@` stripped (`sqrrl__team.append
    (sqrrl__alice)`), rather than requiring `[i]` first or routing through
    a generated get_/set_<field>. Distinguished from an element field
    access purely by `is_call` with no `index_expr`."""
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@alice = @@Person { .name = "alice" };\n'
        "    var @@team: List[@@Person] = List[@@Person]();\n"
        "    @@team.append(@@alice);\n"
    )
    var out = transform_source(source, _person_only_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())
    assert_true("sqrrl__team.append(sqrrl__alice);" in out)


def test_transform_source_infers_container_type_for_bare_constructor_declaration() raises:
    """`var @@team = List[@@Person]();` (no explicit `: List[@@Person]`
    annotation) -- the RHS doesn't literally start with `@@` (it starts
    with `List[`), so the ordinary `@@name = ...` decl check has to
    specifically recognize a bare `Container[@@Type](...)` constructor as
    a legitimate alternative, registering the container type itself
    (there's no other marker here for `pending_decl` to attach to, unlike
    a `@@Type{...}` construct or an entity-returning call) so
    `@@team.append(...)`/`@@team[i].field` both work afterward."""
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        '    var @@alice = @@Person { .name = "alice" };\n'
        "    var @@team = List[@@Person]();\n"
        "    @@team.append(@@alice);\n"
        "    print(@@team[0].name);\n"
    )
    var out = transform_source(source, _person_only_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())
    assert_true("var sqrrl__team = List[EntityHandle[sqrrl__PersonTableState]]();" in out)
    assert_true("sqrrl__team.append(sqrrl__alice);" in out)
    assert_true("print(sqrrl__world.Person.get_name(sqrrl__team[0]));" in out)


def test_transform_source_rejects_unrecognized_rhs_for_marked_declaration() raises:
    """`var @@team = some_plain_call();` -- an `@@`-marked declaration
    target whose RHS is neither itself `@@`-marked nor a recognized
    `Container[@@Type](...)` constructor shape -- is still rejected, same
    as before the container-constructor recognition was added."""
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@init();\n"
        "    var @@team = some_plain_call();\n"
    )
    with assert_raises():
        _ = transform_source(source, _person_only_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
