from std.testing import assert_true, assert_equal, assert_raises, TestSuite

from squirrel_compiler.parser import Scanner, Field, FieldModifier
from squirrel_compiler.codegen import (
    emit_table,
    emit_plain_struct,
    transform_source,
    encode_container_type,
    emit_json_module,
    emit_table_json_methods,
    emit_plain_struct_from_json,
)


def empty_schema() -> Dict[String, Dict[String, String]]:
    return Dict[String, Dict[String, String]]()


def empty_function_returns() -> Dict[String, String]:
    return Dict[String, String]()


def empty_unique_fields() -> Dict[String, List[String]]:
    return Dict[String, List[String]]()


def empty_ordered_fields() -> Dict[String, List[String]]:
    return Dict[String, List[String]]()


def empty_multi_fields() -> Dict[String, List[String]]:
    return Dict[String, List[String]]()


def empty_plain_struct_fields() -> Dict[String, List[Field]]:
    return Dict[String, List[Field]]()


def empty_relation_targets() -> Dict[String, List[String]]:
    return Dict[String, List[String]]()


def test_emits_state_struct_and_fields() raises:
    var sc = Scanner("@@struct @@Person:\n    name: String\n    age: UInt32\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true("struct sqrrl__PersonTableState(TableStateLike, Movable, ImplicitlyDeletable):" in out)
    assert_true("var name: Rel[String]" in out)
    assert_true("var age: Rel[UInt32]" in out)


def test_emits_table_wrapper() raises:
    var sc = Scanner("@@struct @@Person:\n    name: String\n    age: UInt32\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true("struct sqrrl__PersonTable(Movable):" in out)
    assert_true("var table: Table[sqrrl__PersonTableState]" in out)
    assert_true("self.table = Table[sqrrl__PersonTableState](sqrrl__PersonTableState())" in out)


def test_emits_create_with_all_fields() raises:
    var sc = Scanner("@@struct @@Person:\n    name: String\n    age: UInt32\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true(
        "def create(mut self, name: String, age: UInt32) ->"
        " EntityHandle[sqrrl__PersonTableState]:" in out
    )
    assert_true("self.table.state[].state.name.put(e.id(), name)" in out)
    assert_true("self.table.state[].state.age.put(e.id(), age)" in out)


def test_emits_get_and_set_per_field() raises:
    var sc = Scanner("@@struct @@Person:\n    age: UInt32\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

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


def test_emits_value_eq_comparing_every_field() raises:
    """`value_eq` compares two handles field-by-field via each
    field's own `get_<field>`/`!=` -- deliberately not `EntityHandle.
    __eq__` (id-based, load-bearing for `Rel`'s own `_bwd` dict keying), and
    a relation field is compared by its own `EntityHandle.__eq__` (still
    id-based) rather than recursed into the target's own fields, matching
    how a foreign key column's equality works in an ordinary relational
    database. `equatable`-tagged -- `value_eq` is opt-in (see
    `ParsedStruct`'s own doc comment), not generated unless a struct asks
    for it."""
    var sc = Scanner("@@struct equatable @@Person:\n    name: String\n    @@dept: @@Department\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true(
        "def value_eq(self, a: EntityHandle[sqrrl__PersonTableState], b:"
        " EntityHandle[sqrrl__PersonTableState]) -> Bool:" in out
    )
    assert_true("if self.get_name(a) != self.get_name(b):" in out)
    assert_true("if self.get_dept(a) != self.get_dept(b):" in out)
    assert_true("return False" in out)
    assert_true("return True" in out)


def test_emits_value_eq_for_struct_with_no_fields() raises:
    var sc = Scanner("@@struct equatable @@Marker:\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true(
        "def value_eq(self, a: EntityHandle[sqrrl__MarkerTableState], b:"
        " EntityHandle[sqrrl__MarkerTableState]) -> Bool:\n        return True\n" in out
    )


def test_no_value_eq_without_equatable_tag() raises:
    """A struct that never asks for `equatable` gets no `value_eq` at
    all -- opt-in, not unconditional, unlike every other generated method
    in this file. This is what confines the "every field needs to support
    `!=`" risk to only the structs that actually want `value_eq`, instead
    of every struct project-wide."""
    var sc = Scanner("@@struct @@Person:\n    name: String\n    @@dept: @@Department\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true("def value_eq" not in out)


def test_emits_to_json_calling_sqrrl_to_json_per_field() raises:
    """`to_json` (on the `@@struct`'s own `sqrrl__<Name>Table`) is uniform
    across every field -- a leaf, a container, or a relation field's
    `get_<field>` all get wrapped the same way, since `EntityHandle`
    itself knows how to serialize as its own id (`sqrrl__JsonSerializable`)."""
    var sc = Scanner("@@struct @@Person:\n    name: String\n    age: UInt32\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true(
        "def sqrrl__to_json(self, e: EntityHandle[sqrrl__PersonTableState]) -> String:" in out
    )
    assert_true('out += "\\"name\\":" + sqrrl__to_json(self.get_name(e))' in out)
    assert_true('out += ","' in out)
    assert_true('out += "\\"age\\":" + sqrrl__to_json(self.get_age(e))' in out)


def test_emit_table_from_json_uses_create() raises:
    """`from_json` is generated as a method on the struct's own
    `sqrrl__<Name>Table` (`self`), matching `to_json`/`create`/`get_*`/
    `set_*` -- a separate `mut sqrrl__world` parameter alongside `mut
    self` would alias the same memory `self` is already borrowed from
    (confirmed rejected by Mojo's own exclusivity checker), but passing
    only the *specific* sibling tables a struct's own fields actually
    need sidesteps that. A struct with no relation fields at all (like
    this one) needs none, so the signature stays exactly `mut self, mut
    sc`."""
    var sc = Scanner("@@struct @@Person:\n    name: String\n    age: UInt32\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table_json_methods(
        sc.parse_struct(), "sqrrl__PersonTableState", empty_plain_struct_fields()
    )

    assert_true(
        "def sqrrl__from_json(mut self, mut sc: sqrrl__JsonScanner) raises ->"
        " EntityHandle[sqrrl__PersonTableState]:" in out
    )
    assert_true("var sqrrl__parsed_name: Optional[String] = None" in out)
    assert_true("var sqrrl__parsed_age: Optional[UInt32] = None" in out)
    assert_true('if sqrrl__key == "name":' in out)
    assert_true("sqrrl__parsed_name = sqrrl__from_json[String](sc)" in out)
    assert_true('elif sqrrl__key == "age":' in out)
    assert_true("sqrrl__parsed_age = sqrrl__from_json[UInt32](sc)" in out)
    assert_true(
        "return self.create(sqrrl__parsed_name.take(), sqrrl__parsed_age.take())"
        in out
    )


def test_emit_table_from_json_handles_bare_relation_field() raises:
    """A bare relation field (`@@dept: @@Department`) can't be parsed via
    the shared `sqrrl__from_json[T]` dispatcher at all -- reconstructing
    an `EntityHandle` needs the *target's own table*, injected here as an
    explicit `sqrrl__tbl_Department: sqrrl__DepartmentTable` parameter
    rather than the whole `sqrrl__World`."""
    var sc = Scanner("@@struct @@Employee:\n    @@dept: @@Department\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table_json_methods(
        sc.parse_struct(), "sqrrl__EmployeeTableState", empty_plain_struct_fields()
    )

    assert_true(
        "def sqrrl__from_json(mut self, mut sqrrl__tbl_Department: sqrrl__DepartmentTable,"
        " mut sc: sqrrl__JsonScanner) raises -> EntityHandle[sqrrl__EmployeeTableState]:"
        in out
    )
    assert_true(
        "var sqrrl__parsed_dept: Optional[EntityHandle[sqrrl__DepartmentTableState]] = None"
        in out
    )
    assert_true(
        "sqrrl__parsed_dept = sqrrl__tbl_Department.table.handle_for(UInt32(sc.parse_json_int()))"
        in out
    )


def test_emit_table_from_json_handles_plain_struct_field() raises:
    """A field typed as a known plain struct (`home: Address`) routes to
    that struct's own `sqrrl__<Name>_from_json` free-function companion
    (prefixed, unlike an entity's own bare `from_json` method -- see
    `_emit_from_json_field_parse`'s own doc comment for why the two
    naming schemes can never collide), not the shared
    `sqrrl__from_json[T]` dispatcher, since only a struct's own generated
    function can know its fields (`sqrrl__from_json[T]`'s generic
    fallback doesn't exist -- reflection can't write into an arbitrary
    field, confirmed). `Address` itself has no relation fields, so no
    arguments are injected into the nested call."""
    var sc = Scanner("@@struct @@Person:\n    forwardonly home: Address\n")
    assert_true(sc.find_next_struct_decl())
    var plain_fields = Dict[String, List[Field]]()
    plain_fields["Address"] = List[Field]()
    var out = emit_table_json_methods(sc.parse_struct(), "sqrrl__PersonTableState", plain_fields)

    assert_true("var sqrrl__parsed_home: Optional[Address] = None" in out)
    assert_true("sqrrl__parsed_home = sqrrl__Address_from_json(sc)" in out)


def test_emit_table_from_json_handles_transitive_plain_struct_relation() raises:
    """A plain-struct-typed field whose *own* fields include a relation
    (`Note { @@author: @@Employee, text: String }`, embedded as `note:
    Note`) still needs `Employee`'s table threaded all the way through --
    both as a `sqrrl__tbl_Employee` parameter on the *owning* struct's
    own `from_json` (`_collect_relation_targets`'s transitive walk), and
    passed straight through as an argument to the nested
    `sqrrl__Note_from_json` call."""
    var note_sc = Scanner("struct Note { @@author: @@Employee, text: String }")
    assert_true(note_sc.find_next_plain_struct_decl())
    var plain_fields = Dict[String, List[Field]]()
    plain_fields["Note"] = note_sc.parse_plain_struct().fields.copy()

    var sc = Scanner("@@struct @@Report:\n    forwardonly note: Note\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table_json_methods(sc.parse_struct(), "sqrrl__ReportTableState", plain_fields)

    assert_true(
        "def sqrrl__from_json(mut self, mut sqrrl__tbl_Employee: sqrrl__EmployeeTable,"
        " mut sc: sqrrl__JsonScanner) raises -> EntityHandle[sqrrl__ReportTableState]:"
        in out
    )
    assert_true(
        "sqrrl__parsed_note = sqrrl__Note_from_json(sqrrl__tbl_Employee, sc)" in out
    )


def test_emit_plain_struct_from_json_uses_own_constructor() raises:
    var sc = Scanner("struct Address { city: String }")
    assert_true(sc.find_next_plain_struct_decl())
    var out = emit_plain_struct_from_json(sc.parse_plain_struct(), empty_plain_struct_fields())

    assert_true(
        "def sqrrl__Address_from_json(mut sc: sqrrl__JsonScanner) raises ->"
        " Address:" in out
    )
    assert_true("var sqrrl__parsed_city: Optional[String] = None" in out)
    assert_true('if sqrrl__key == "city":' in out)
    assert_true("sqrrl__parsed_city = sqrrl__from_json[String](sc)" in out)
    assert_true("return Address(sqrrl__parsed_city.take())" in out)


def test_emit_plain_struct_from_json_injects_relation_target_param() raises:
    """`Note { @@author: @@Employee, text: String }`'s own free-function
    companion takes `sqrrl__tbl_Employee: sqrrl__EmployeeTable` directly
    (no `mut self` to lead with, unlike `emit_table_json_methods`'s
    `from_json` -- a plain struct has no table of its own)."""
    var sc = Scanner("struct Note { @@author: @@Employee, text: String }")
    assert_true(sc.find_next_plain_struct_decl())
    var out = emit_plain_struct_from_json(sc.parse_plain_struct(), empty_plain_struct_fields())

    assert_true(
        "def sqrrl__Note_from_json(mut sqrrl__tbl_Employee: sqrrl__EmployeeTable,"
        " mut sc: sqrrl__JsonScanner) raises -> Note:" in out
    )
    assert_true(
        "sqrrl__parsed_author ="
        " sqrrl__tbl_Employee.table.handle_for(UInt32(sc.parse_json_int()))" in out
    )
    assert_true("return Note(sqrrl__parsed_author.take(), sqrrl__parsed_text.take())" in out)


def test_emit_plain_struct_from_json_generic_shorthand() raises:
    """A generic shorthand plain struct (`struct Box[T] { value: T }`)
    gets its own `[T: Bound, ...]` list on its `from_json` companion, a
    concrete `Box[T]` return type (not the bare name), and a field typed
    bare `T` just falls through to the ordinary
    `sqrrl__from_json[T](sc)` leaf-dispatch fallback -- `T` is already in
    scope as one of the function's own type parameters, no different
    from any other concrete field type. An unconstrained parameter
    (no `: Bound`) defaults to `Copyable & ImplicitlyDeletable`,
    matching what `emit_plain_struct`'s own derived conformances require
    of every field's type -- not `ImplicitlyCopyable`, which would
    wrongly reject instantiating this at a merely-`Copyable` type like
    `List[String]`."""
    var sc = Scanner("struct Box[T] { value: T }")
    assert_true(sc.find_next_plain_struct_decl())
    var out = emit_plain_struct_from_json(sc.parse_plain_struct(), empty_plain_struct_fields())

    assert_true(
        "def sqrrl__Box_from_json[T: Copyable & ImplicitlyDeletable]"
        "(mut sc: sqrrl__JsonScanner) raises -> Box[T]:" in out
    )
    assert_true("var sqrrl__parsed_value: Optional[T] = None" in out)
    assert_true("sqrrl__parsed_value = sqrrl__from_json[T](sc)" in out)
    assert_true("return Box[T](sqrrl__parsed_value.take())" in out)


def test_emit_plain_struct_from_json_generic_explicit_bound() raises:
    """An explicit `: Bound` on a type parameter (`Pair[K: Hashable, V]`)
    is preserved verbatim on the companion's own type-parameter list,
    multiple parameters each keeping their own bound (or the default)
    independently."""
    var sc = Scanner("struct Pair[K: Hashable, V] { key: K, value: V }")
    assert_true(sc.find_next_plain_struct_decl())
    var out = emit_plain_struct_from_json(sc.parse_plain_struct(), empty_plain_struct_fields())

    assert_true(
        "def sqrrl__Pair_from_json[K: Hashable, V: Copyable &"
        " ImplicitlyDeletable](mut sc: sqrrl__JsonScanner) raises -> Pair[K, V]:" in out
    )
    assert_true("sqrrl__parsed_key = sqrrl__from_json[K](sc)" in out)
    assert_true("sqrrl__parsed_value = sqrrl__from_json[V](sc)" in out)
    assert_true("return Pair[K, V](sqrrl__parsed_key.take(), sqrrl__parsed_value.take())" in out)


def test_emit_plain_struct_from_json_generic_hand_written() raises:
    """A hand-written generic plain struct (`struct Box[T: Bound](Traits
    ...): var value: Self.T ...`) gets the identical treatment -- its own
    type-parameter list comes before the parenthesized trait list, real
    Mojo's own syntax order, and `parse_hand_written_plain_struct`
    threads it through to the same generated companion shape a shorthand
    one gets. The fixture's own field says `Self.T`, not bare `T` -- real
    Mojo requires that qualification inside the struct's own body
    (confirmed: `var value: T` there raises "unqualified access to
    struct parameter 'T'; use 'Self.T' instead") -- and
    `parse_hand_written_plain_struct` unqualifies it back to bare `T`
    before this ever sees it, since the generated companion is a free
    function, where `Self` doesn't exist at all."""
    var sc = Scanner(
        "struct Box2[T: Copyable & Movable](Copyable, Movable, ImplicitlyDeletable):\n"
        "    var value: Self.T\n"
        "\n"
        "    def __init__(out self, var value: Self.T):\n"
        "        self.value = value^\n"
    )
    assert_true(sc.find_next_hand_written_plain_struct_decl())
    var out = emit_plain_struct_from_json(sc.parse_hand_written_plain_struct(), empty_plain_struct_fields())

    assert_true(
        "def sqrrl__Box2_from_json[T: Copyable & Movable](mut sc: sqrrl__JsonScanner)"
        " raises -> Box2[T]:" in out
    )
    assert_true("sqrrl__parsed_value = sqrrl__from_json[T](sc)" in out)
    assert_true("return Box2[T](sqrrl__parsed_value.take())" in out)


def test_emit_from_json_field_parse_routes_generic_instantiation_by_name() raises:
    """A field typed as a *concrete instantiation* of a generic plain
    struct (`home: Box[String]`, not bare `Box`) routes to the
    companion's own generic call, forwarding the instantiation's type
    argument(s) verbatim (`sqrrl__Box_from_json[String](sc)`) rather than
    falling through to the shared `sqrrl__from_json[T]` dispatcher (which
    has no branch for an arbitrary struct instantiation and would raise
    `unsupported type` at runtime) -- `_plain_struct_base_name` is what
    lets the `plain_struct_fields` lookup match `Box[String]` against
    the bare `Box` key it was actually registered under."""
    var box_sc = Scanner("struct Box[T] { value: T }")
    assert_true(box_sc.find_next_plain_struct_decl())
    var plain_fields = Dict[String, List[Field]]()
    plain_fields["Box"] = box_sc.parse_plain_struct().fields.copy()

    var sc = Scanner("@@struct @@Person:\n    forwardonly home: Box[String]\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table_json_methods(sc.parse_struct(), "sqrrl__PersonTableState", plain_fields)

    assert_true("var sqrrl__parsed_home: Optional[Box[String]] = None" in out)
    assert_true("sqrrl__parsed_home = sqrrl__Box_from_json[String](sc)" in out)


def test_emit_json_module_leaf_dispatch() raises:
    """`sqrrl__to_json`/`sqrrl__from_json`'s leaf branches are fixed --
    independent of any project-specific `container_types`."""
    var out = emit_json_module(List[String](), List[String]())

    assert_true("def sqrrl__to_json[T: AnyType](value: T) -> String:" in out)
    assert_true("comptime if T == String:" in out)
    assert_true("return sqrrl__escape_json_string(rebind[String](value))" in out)
    assert_true("elif T == UInt32:" in out)
    assert_true("elif conforms_to(T, sqrrl__JsonSerializable):" in out)
    assert_true("return value.sqrrl__to_json()" in out)
    assert_true("comptime r = reflect[T]" in out)
    assert_true(
        "def sqrrl__from_json[T: Copyable & ImplicitlyDeletable](mut sc: sqrrl__JsonScanner)"
        " raises -> T:" in out
    )
    # The container helpers themselves are static code in
    # `squirrel_runtime/json.mojo` now, not generated here -- no project
    # schema uses any container in this fixture, so no dispatcher branch
    # calling into them should appear either.
    assert_true("list_to_json" not in out)
    assert_true("set_to_json" not in out)
    assert_true("optional_to_json" not in out)


def test_emit_json_module_enumerates_container_types() raises:
    var types = List[String]()
    types.append("List[String]")
    types.append("Set[UInt32]")
    var out = emit_json_module(types, List[String]())

    assert_true("elif T == List[String]:" in out)
    assert_true("return list_to_json(rebind[List[String]](value).copy())" in out)
    assert_true("elif T == Set[UInt32]:" in out)
    assert_true("return set_to_json(rebind[Set[UInt32]](value).copy())" in out)
    # No Optional anywhere in this schema -- no dispatcher branch calling
    # `optional_to_json` should appear.
    assert_true("optional_to_json" not in out)


def test_emit_json_module_generates_dict_helpers() raises:
    """`Dict[K, V]` is the one wrapper with *two* type parameters rather
    than one -- JSON objects require string keys, so a `Dict` for
    arbitrary `K` serializes as a JSON array of `[key, value]` pairs
    instead of an object, reusing `sqrrl__to_json`/`sqrrl__from_json`
    recursively for both `K` and `V` rather than requiring `K ==
    String`. The helper's own body lives in `squirrel_runtime/json.mojo`
    (static, fully generic); this only checks the dispatch table calls
    into it correctly."""
    var types = List[String]()
    types.append("Dict[String, UInt32]")
    var out = emit_json_module(types, List[String]())

    assert_true("elif T == Dict[String, UInt32]:" in out)
    assert_true("return dict_to_json(rebind[Dict[String, UInt32]](value).copy())" in out)
    assert_true(
        "return rebind[T](dict_from_json[String, UInt32](sc)).copy()" in out
    )


def test_emit_json_module_generates_plain_struct_dispatch_for_bare_name() raises:
    """A non-generic plain struct reached in a position that needs the
    shared dispatcher (a container's own element, or a generic plain
    struct's own bare type-parameter field, see
    `driver.build_json_container_types`'s own doc comment) gets a
    `sqrrl__from_json[T]` branch routing to its own
    `sqrrl__<Name>_from_json` companion, no type arguments -- this is
    what closes the "plain struct nested inside a container" gap:
    without it, `list_from_json[Address]`'s own internal
    `sqrrl__from_json[Address](sc)` call had no dispatch branch to reach
    at all."""
    var dispatch_types = List[String]()
    dispatch_types.append("Address")
    var out = emit_json_module(List[String](), dispatch_types)

    assert_true("elif T == Address:" in out)
    assert_true("return rebind[T](sqrrl__Address_from_json(sc)).copy()" in out)


def test_emit_json_module_generates_plain_struct_dispatch_for_generic_instantiation() raises:
    """A generic plain struct's own concrete instantiation (`Box[String]`)
    reached the same way forwards its own type argument(s) explicitly to
    `sqrrl__<Name>_from_json[<args>]`, the same call shape
    `_emit_from_json_field_parse` already uses for a *direct* generic
    instantiation field."""
    var dispatch_types = List[String]()
    dispatch_types.append("Box[String]")
    var out = emit_json_module(List[String](), dispatch_types)

    assert_true("elif T == Box[String]:" in out)
    assert_true("return rebind[T](sqrrl__Box_from_json[String](sc)).copy()" in out)


def test_emit_json_module_skips_from_json_for_relation_containers() raises:
    """A relation container (`List[@@Employee]` -> `List[EntityHandle[...]]`)
    gets a `to_json` branch (serializing is uniform) but no `from_json`
    one -- reconstructing a list of entities needs the target's own
    table, which the shared dispatcher can't reach; that's handled
    per-struct instead (see `emit_squirrel_from_json_method`)."""
    var types = List[String]()
    types.append("List[EntityHandle[sqrrl__EmployeeTableState]]")
    var out = emit_json_module(types, List[String]())

    assert_true("elif T == List[EntityHandle[sqrrl__EmployeeTableState]]:" in out)
    assert_true(
        "return list_to_json(rebind[List[EntityHandle[sqrrl__EmployeeTableState]]](value).copy())"
        in out
    )
    var from_json_start = out.find("def sqrrl__from_json[T:")
    assert_true(from_json_start >= 0)
    var from_json_body = String(out[byte = from_json_start : out.byte_length()])
    assert_true("List[EntityHandle[sqrrl__EmployeeTableState]]" not in from_json_body)


def test_emits_cleanup_relations_for_every_field() raises:
    # This is what closes the relation-leak-on-destroy bug: every field,
    # relation or not, gets fetch_remove_fwd'd when the owning entity dies.
    var sc = Scanner("@@struct @@Person:\n    name: String\n    @@employee: @@Employee\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true("def sqrrl__cleanup_relations(mut self, id: UInt32):" in out)
    assert_true("_ = self.name.fetch_remove_fwd(id)" in out)
    assert_true("_ = self.employee.fetch_remove_fwd(id)" in out)


def test_relation_field_targets_the_other_table_state() raises:
    var sc = Scanner("@@struct @@Person:\n    @@employee: @@Employee\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

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
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

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
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

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
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

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

    assert_true("struct Point(Copyable, Movable, ImplicitlyDeletable):" in out)
    assert_true("var x: Int" in out)
    assert_true("var y: Int" in out)
    assert_true("def __init__(out self, var x: Int, var y: Int):" in out)
    assert_true("self.x = x^" in out)
    assert_true("self.y = y^" in out)


def test_emit_plain_struct_generates_generic_struct_header() raises:
    """A generic shorthand plain struct (`struct Box[T] { value: T }`)
    gets its own `[T: Bound]` list spliced in right after the name, same
    position real Mojo puts it -- and every reference to `T` within the
    struct's own body (a field's type, a constructor parameter's type)
    is qualified as `Self.T`, not bare `T` -- confirmed Mojo itself
    requires this inside a generic struct's own body (raises
    "unqualified access to struct parameter 'T'; use 'Self.T' instead"
    otherwise), unlike a free function's own type parameter, which stays
    bare (see `emit_plain_struct_from_json`'s own generated companion)."""
    var sc = Scanner("struct Box[T] { value: T }")
    assert_true(sc.find_next_plain_struct_decl())
    var out = emit_plain_struct(sc.parse_plain_struct())

    assert_true(
        "struct Box[T: Copyable & ImplicitlyDeletable]"
        "(Copyable, Movable, ImplicitlyDeletable):" in out
    )
    assert_true("var value: Self.T" in out)
    assert_true("def __init__(out self, var value: Self.T):" in out)
    assert_true("self.value = value^" in out)


def test_emit_plain_struct_allows_list_typed_field() raises:
    """`emit_plain_struct` declares `Copyable, Movable,
    ImplicitlyDeletable` -- not `ImplicitlyCopyable` -- specifically so a
    `List`/`Set`/`Dict`-typed field is allowed at all: those conform to
    `Copyable` but never `ImplicitlyCopyable` (an explicit `.copy()` is
    always required, by design, to avoid an accidental expensive copy),
    so declaring `ImplicitlyCopyable` here used to make Mojo reject the
    struct outright ("cannot synthesize implicit copy constructor
    because field 'items' has non-implicitly-copyable type
    'List[String]'"), confirmed via a real, non-generic case -- nothing
    to do with generics at all."""
    var sc = Scanner("struct Tags { items: List[String] }")
    assert_true(sc.find_next_plain_struct_decl())
    var out = emit_plain_struct(sc.parse_plain_struct())

    assert_true("struct Tags(Copyable, Movable, ImplicitlyDeletable):" in out)
    assert_true("var items: List[String]" in out)
    assert_true("def __init__(out self, var items: List[String]):" in out)


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
    var out = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
    assert_true("struct Note(Copyable, Movable, ImplicitlyDeletable):" in out)
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
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

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
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true("var tags: MultiRel[String]" in out)
    assert_true(
        "def add_to_tags(mut self, e: EntityHandle[sqrrl__FooTableState], value: String) -> Bool:" in out
    )
    assert_true(
        "def for_tags(self, value: String) -> List[EntityHandle[sqrrl__FooTableState]]:" in out
    )


def test_emits_group_by_for_plain_field() raises:
    """`group_by_<field>` on a plain field walks `Rel.all_bwd()` (the
    whole reverse index, every value at once) rather than one bucket via
    `for_<field>`, rebuilding it into `Dict[FieldType,
    List[EntityHandle[...]]]`."""
    var sc = Scanner("@@struct @@Employee:\n    @@dept: @@Department\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true(
        "def group_by_dept(self) -> Dict[EntityHandle[sqrrl__DepartmentTableState],"
        " List[EntityHandle[sqrrl__EmployeeTableState]]]:" in out
    )
    assert_true("ref buckets = self.table.state[].state.dept.all_bwd()" in out)
    assert_true("for entry in buckets.items():" in out)
    assert_true("handles.append(self.table.handle_for(id))" in out)
    assert_true("out[entry.key] = handles^" in out)


def test_emits_group_by_for_unique_field() raises:
    """`group_by_<field>` on a `unique` field walks `UniqueRel.all_bwd()`
    -- every value mapped to its own single id, by construction of
    `unique` -- so it's `Dict[FieldType, EntityHandle[...]]`, not wrapped
    in a `List`/`Set` the way every other field kind's `group_by_<field>`
    is."""
    var sc = Scanner("@@struct @@Person:\n    unique email: String\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true(
        "def group_by_email(self) -> Dict[String, EntityHandle[sqrrl__PersonTableState]]:"
        in out
    )
    assert_true("ref ids = self.table.state[].state.email.all_bwd()" in out)
    assert_true("for entry in ids.items():" in out)
    assert_true("out[entry.key] = self.table.handle_for(entry.value)" in out)


def test_emits_group_by_for_multi_field() raises:
    """`group_by_<field>` on a `multi` field walks `MultiRel.all_bwd()`,
    keyed by the *element* type (`emit_multi_element_type`), same as
    `for_<field>`/`add_to_<field>`/`remove_from_<field>` already are for
    `multi` -- "for each Employee, every Department containing them," not
    the field's own whole `Set[...]` type."""
    var sc = Scanner("@@struct @@Department:\n    multi @@members: @@Employee\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true(
        "def group_by_members(self) -> Dict[EntityHandle[sqrrl__EmployeeTableState],"
        " List[EntityHandle[sqrrl__DepartmentTableState]]]:" in out
    )
    assert_true("ref buckets = self.table.state[].state.members.all_bwd()" in out)
    assert_true("for entry in buckets.items():" in out)
    assert_true("handles.append(self.table.handle_for(id))" in out)


def test_emits_group_by_for_ordered_field() raises:
    """`group_by_<field>` on an `ordered` field walks `OrderedRel.
    all_bwd()` -- already ascending-ordered, since `Dict`'s own iteration
    order matches insertion order -- rebuilding it into `Dict[FieldType,
    List[EntityHandle[...]]]` in the same order."""
    var sc = Scanner("@@struct @@Employee:\n    ordered years_employed: UInt32\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true(
        "def group_by_years_employed(self) -> Dict[UInt32,"
        " List[EntityHandle[sqrrl__EmployeeTableState]]]:" in out
    )
    assert_true(
        "var buckets = self.table.state[].state.years_employed.all_bwd()" in out
    )
    assert_true("for entry in buckets.items():" in out)


def test_forward_only_field_has_no_group_by() raises:
    """`ForwardOnlyRel` has no `_bwd`/`all_bwd` at all -- same reason it
    has no `for_<field>` either (see
    `test_forward_only_field_uses_forward_only_rel_and_has_no_for_field`)."""
    var sc = Scanner("@@struct @@Foo:\n    forwardonly scores: List[Int]\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true("group_by_scores" not in out)
    assert_true("count_scores" not in out)
    assert_true("count_by_scores" not in out)
    assert_true("distinct_scores" not in out)


def test_emits_count_field_for_plain_field() raises:
    """`count_<field>(value)` is `len(for_<field>(value))` without
    building a handle for every matching row just to throw it away right
    after."""
    var sc = Scanner("@@struct @@Employee:\n    @@dept: @@Department\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true(
        "def count_dept(self, value: EntityHandle[sqrrl__DepartmentTableState]) -> Int:"
        in out
    )
    assert_true(
        "return len(self.table.state[].state.dept.get_bwd(value))" in out
    )


def test_emits_count_field_for_unique_field() raises:
    """`count_<field>(value)` on a `unique` field is the one genuinely new
    capability in this family, not just a faster version of something
    already possible -- `for_<field>` *raises* if `value` isn't in use, so
    there's no existing way to ask "is this taken" without a try/except.
    `0`/`1`, via a plain `in` check against `all_bwd()`, no raising."""
    var sc = Scanner("@@struct @@Person:\n    unique email: String\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true("def count_email(self, value: String) -> Int:" in out)
    assert_true(
        "return 1 if value in self.table.state[].state.email.all_bwd() else 0"
        in out
    )


def test_emits_count_field_for_multi_field() raises:
    """`count_<field>(value)` on a `multi` field takes the bare element
    type, same as `for_<field>` does for `multi`."""
    var sc = Scanner("@@struct @@Department:\n    multi @@members: @@Employee\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true(
        "def count_members(self, value: EntityHandle[sqrrl__EmployeeTableState]) -> Int:"
        in out
    )
    assert_true(
        "return len(self.table.state[].state.members.get_bwd(value))" in out
    )


def test_emits_count_field_for_ordered_field() raises:
    """`count_<field>(value)` on an `ordered` field is the exact-match
    count (same `get_bwd`/`between(value, value)` as `for_<field>`'s own
    exact-match form)."""
    var sc = Scanner("@@struct @@Employee:\n    ordered years_employed: UInt32\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true("def count_years_employed(self, value: UInt32) -> Int:" in out)
    assert_true(
        "return len(self.table.state[].state.years_employed.get_bwd(value))"
        in out
    )


def test_emits_count_by_for_plain_field() raises:
    """`count_by_<field>` is `group_by_<field>` without ever building the
    `List[EntityHandle[...]]` for each bucket, just `len()`-ing it."""
    var sc = Scanner("@@struct @@Employee:\n    @@dept: @@Department\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true(
        "def count_by_dept(self) -> Dict[EntityHandle[sqrrl__DepartmentTableState], Int]:"
        in out
    )
    assert_true("ref buckets = self.table.state[].state.dept.all_bwd()" in out)
    assert_true("out[entry.key] = len(entry.value)" in out)


def test_emits_count_by_for_multi_field() raises:
    var sc = Scanner("@@struct @@Department:\n    multi @@members: @@Employee\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true(
        "def count_by_members(self) -> Dict[EntityHandle[sqrrl__EmployeeTableState], Int]:"
        in out
    )


def test_emits_count_by_for_ordered_field() raises:
    """Unlike `Rel`/`UniqueRel`/`MultiRel`'s `all_bwd` (a `ref`),
    `OrderedRel.all_bwd` is rebuilt fresh (`var`, not `ref`) -- there's no
    persistent grouped structure to alias, since `OrderedRel` only keeps
    `_sorted` (flat) and `_fwd`, and `count_by_<field>` calls `all_bwd()`
    again independently of `group_by_<field>`'s own call, not sharing it."""
    var sc = Scanner("@@struct @@Employee:\n    ordered years_employed: UInt32\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true(
        "def count_by_years_employed(self) -> Dict[UInt32, Int]:" in out
    )
    assert_true(
        "var buckets = self.table.state[].state.years_employed.all_bwd()" in out
    )


def test_no_count_by_for_unique_field() raises:
    """No `count_by_<field>` for `unique` -- every group is exactly 1 by
    construction, so it would carry zero information beyond what `unique`
    already guarantees. `count_<field>` (the 0/1 existence check) is still
    generated -- see `test_emits_count_field_for_unique_field`."""
    var sc = Scanner("@@struct @@Person:\n    unique email: String\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true("count_by_email" not in out)
    assert_true("count_email" in out)


def test_emits_distinct_for_plain_field() raises:
    """`distinct_<field>` is every distinct value currently in use, with no
    `EntityHandle` built at all -- unlike `group_by_<field>().keys()`,
    which would already have paid for a `handle_for` call per value."""
    var sc = Scanner("@@struct @@Employee:\n    @@dept: @@Department\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true(
        "def distinct_dept(self) -> Set[EntityHandle[sqrrl__DepartmentTableState]]:"
        in out
    )
    assert_true(
        "for key in self.table.state[].state.dept.all_bwd().keys():" in out
    )
    assert_true("out.add(key)" in out)


def test_emits_distinct_for_unique_field() raises:
    """`distinct_<field>` on a `unique` field is the cheap way to ask
    "which values are currently taken" -- `group_by_<field>` answers the
    same question but pays for a `handle_for` call (a real `WeakPointer`
    upgrade + `EntityHandle` construction) per value; `count_by_<field>`
    isn't generated at all for `unique` (see
    `test_no_count_by_for_unique_field`), so this is the only cheap path."""
    var sc = Scanner("@@struct @@Person:\n    unique email: String\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true("def distinct_email(self) -> Set[String]:" in out)
    assert_true(
        "for key in self.table.state[].state.email.all_bwd().keys():" in out
    )


def test_emits_distinct_for_multi_field() raises:
    """`distinct_<field>` on a `multi` field is keyed by the bare element
    type, same as `for_<field>`/`group_by_<field>`/`count_by_<field>` are
    for `multi`."""
    var sc = Scanner("@@struct @@Department:\n    multi @@members: @@Employee\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true(
        "def distinct_members(self) -> Set[EntityHandle[sqrrl__EmployeeTableState]]:"
        in out
    )


def test_emits_distinct_for_ordered_field_returns_list() raises:
    """`distinct_<field>` on an `ordered` field returns `List`, not `Set`,
    unlike every other field kind's own `distinct_<field>` -- the ascending
    order is the whole point of `ordered` (same reason the range-shaped
    `for_<field>_*` methods stay `List`-returning), made explicit in the
    return type itself rather than resting on `Set`'s own iteration
    behavior."""
    var sc = Scanner("@@struct @@Employee:\n    ordered years_employed: UInt32\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true("def distinct_years_employed(self) -> List[UInt32]:" in out)
    assert_true(
        "for key in self.table.state[].state.years_employed.all_bwd().keys():"
        in out
    )
    assert_true("out.append(key)" in out)


def test_all_generated_unconditionally_but_keepalive_is_not() raises:
    """`all()` is generated for every struct regardless of `is_keepalive`
    -- a thin delegate to `Table.all()` (which walks the id allocator
    directly, not any one field's own index). `keepalive`/`dont_keepalive`,
    by contrast, are generated *only* for a `keepalive`-tagged struct (see
    `test_keepalive_struct_gets_keepalive_field_and_dont_keepalive`) --
    reload's own temporary retention of a non-tagged struct's
    reconstructed entities lives in `TempKeepAlives`
    (`driver.emit_world_module`) instead, deliberately kept off the
    individual table's own `keepalive` set."""
    var sc = Scanner("@@struct @@Foo:\n    name: String\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true("def all(self) -> Set[EntityHandle[sqrrl__FooTableState]]:" in out)
    assert_true("return self.table.all()" in out)
    assert_true("def count(self) -> Int:" in out)
    assert_true("return self.table.count()" in out)
    assert_true("var keepalive: Set[EntityHandle[sqrrl__FooTableState]]" not in out)
    assert_true(
        "def dont_keepalive(mut self, e: EntityHandle[sqrrl__FooTableState]) -> Bool:" not in out
    )
    assert_true("self.keepalive" not in out)


def test_keepalive_struct_gets_keepalive_field_and_dont_keepalive() raises:
    """`keepalive` adds a `Set[EntityHandle[...]]` field to the *table
    wrapper* (`sqrrl__FooTable`), not the `TableState` -- putting it on
    `TableState` would create a self-cycle (each kept-alive handle's own
    `ArcPointer` points back at the very `TableStorage` holding the set that
    holds it), leaking the whole table forever the moment anything was kept
    alive. Only a `keepalive`-tagged struct's own table gets this field at
    all (see `test_all_generated_unconditionally_but_keepalive_is_not`) --
    what's specific to `keepalive` beyond that is `create` adding every new
    entity to it *automatically*. `dont_keepalive` is the opt-out,
    releasing one back to ordinary refcounted lifetime."""
    var sc = Scanner("@@struct keepalive @@Foo:\n    name: String\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

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
    assert_equal(transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets()), source)


def test_transform_source_emits_table_for_struct() raises:
    var out = transform_source("@@struct @@Person:\n    name: String\n", empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
    assert_true("struct sqrrl__PersonTableState(TableStateLike, Movable, ImplicitlyDeletable):" in out)
    assert_true("struct sqrrl__PersonTable(Movable):" in out)


def test_transform_source_rewrites_construct_through_world() raises:
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        '        var @@alice = @@Person { .name = "alice" };\n'
        '        var @@bob = @@Person { .name = "bob" };\n'
        "    @@}\n"
    )
    var out = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
    assert_true("var sqrrl__world = sqrrl__init()\n    try:" in out)
    assert_true("sqrrl__world.sqrrl__check_no_leaks(); sqrrl__world = sqrrl__init();" in out)
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
        "    @@{\n"
        "        @@init();\n"
        '        var @@alice = Person { .name = "alice" };\n'
    )
    with assert_raises():
        _ = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())


def test_transform_source_rewrites_field_read_and_write() raises:
    var source = String(
        "@@struct @@Person:\n    name: String\n    age: UInt32\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        '        var @@alice = @@Person { .name = "alice", .age = 30 };\n'
        "        @@alice.age = 31;\n"
        "        print(@@alice.name);\n"
        "    @@}\n"
    )
    var out = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
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
        "    @@{\n"
        "        @@init();\n"
        '        var @@alice = @@Person { .name = "alice", .@@employee = bob };\n'
        "        print(@@alice.@@employee.title);\n"
        "        @@alice.@@employee.title = \"manager\";\n"
        "    @@}\n"
    )
    var out = transform_source(source, _person_employee_boss_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
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
        "    @@{\n"
        "        @@init();\n"
        '        var @@alice = @@Person { .name = "alice", .@@employee = bob };\n'
        "        print(@@alice.@@employee.@@boss.name);\n"
        "    @@}\n"
    )
    var out = transform_source(source, _person_employee_boss_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
    assert_true(
        "print(sqrrl__world.Person.get_name(sqrrl__world.Employee.get_boss(sqrrl__world.Person.get_employee(sqrrl__alice))));"
        in out
    )


def test_transform_source_rewrites_terminal_relation_hop_as_tracked_read() raises:
    """`@@alice.@@employee` (nothing after the last hop) reads the relation
    field itself, same as `@@Person.get_employee(@@alice)` -- and, bound to
    an '@@'-marked variable, is tracked as an `Employee` the same way that
    call's own result would be, so `@@e.title` works with no explicit type
    annotation needed."""
    var source = String(
        "@@struct @@Employee:\n    title: String\n\n"
        "\n"
        "@@struct @@Person:\n    name: String\n    @@employee: @@Employee\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        '        var @@alice = @@Person { .name = "alice", .@@employee = bob };\n'
        "        var @@e = @@alice.@@employee;\n"
        "        print(@@e.title);\n"
        "    @@}\n"
    )
    var out = transform_source(source, _person_employee_boss_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
    assert_true("var sqrrl__e = sqrrl__world.Person.get_employee(sqrrl__alice);" in out)
    assert_true("print(sqrrl__world.Employee.get_title(sqrrl__e));" in out)


def test_transform_source_rejects_unmarked_terminal_hop_for_a_relation_field() raises:
    """`@@alice.employee` (no `@@` on the terminal segment) is rejected --
    there's no plain spelling for a relation field, only `.@@employee`;
    marking the last hop is required, not optional documentation."""
    var source = String(
        "@@struct @@Employee:\n    title: String\n\n"
        "\n"
        "@@struct @@Person:\n    name: String\n    @@employee: @@Employee\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        '        var @@alice = @@Person { .name = "alice", .@@employee = bob };\n'
        "        var @@e = @@alice.employee;\n"
    )
    with assert_raises():
        _ = transform_source(source, _person_employee_boss_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())


def test_transform_source_rejects_marked_terminal_hop_for_a_plain_field() raises:
    """`@@alice.@@name` -- marking a terminal segment that *isn't* a
    relation field -- is rejected the other way: `@@` marks a relation,
    never a plain field, so `name` (a `String`) can't be marked either."""
    var source = String(
        "@@struct @@Employee:\n    title: String\n\n"
        "\n"
        "@@struct @@Person:\n    name: String\n    @@employee: @@Employee\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        '        var @@alice = @@Person { .name = "alice", .@@employee = bob };\n'
        "        print(@@alice.@@name);\n"
    )
    with assert_raises():
        _ = transform_source(source, _person_employee_boss_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())


def test_transform_source_rejects_unmarked_variable_for_terminal_relation_hop() raises:
    """Binding `@@alice.@@employee` to a plain, unmarked variable is
    rejected too, same as a table-level relation `get_<field>` call."""
    var source = String(
        "@@struct @@Employee:\n    title: String\n\n"
        "\n"
        "@@struct @@Person:\n    name: String\n    @@employee: @@Employee\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        '        var @@alice = @@Person { .name = "alice", .@@employee = bob };\n'
        "        var e = @@alice.@@employee;\n"
    )
    with assert_raises():
        _ = transform_source(source, _person_employee_boss_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())


def test_transform_source_rewrites_field_write_terminated_by_newline_not_semicolon() raises:
    """A field write no longer needs a trailing `;` -- the statement right
    after it on its own line must come through untouched, not merged into
    the write value or dropped."""
    var source = String(
        "@@struct @@Person:\n    name: String\n    age: UInt32\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init()\n"
        '        var @@alice = @@Person { .name = "alice", .age = 30 }\n'
        "        @@alice.age = 31\n"
        "        print(@@alice.name)\n"
        "    @@}\n"
    )
    var out = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
    assert_true("sqrrl__world.Person.set_age(sqrrl__alice, 31);\n" in out)
    assert_true("print(sqrrl__world.Person.get_name(sqrrl__alice))" in out)


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
        "    @@{\n"
        "        @@init();\n"
        '        var @@eng = @@Department { .name = "Engineering", .@@projects = Set[@@Project]() };\n'
        '        var @@website = @@Project { .name = "Website" };\n'
        "        _ = @@eng.add_to_projects(@@website);\n"
        "        _ = @@eng.remove_from_projects(@@website);\n"
        "    @@}\n"
    )
    var schema = Dict[String, Dict[String, String]]()
    var department_fields = Dict[String, String]()
    department_fields["projects"] = encode_container_type("Set", "Project")
    schema["Department"] = department_fields^
    var out = transform_source(source, schema^, empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
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
        "    @@{\n"
        "        @@init();\n"
        '        var @@bob = @@Employee { .title = "engineer" };\n'
        '        var @@alice = @@Person { .name = "alice", .@@employee = @@bob };\n'
        "    @@}\n"
    )
    var out = transform_source(source, _person_employee_boss_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
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
        "    @@{\n"
        "        @@init();\n"
        '        var @@alice = @@Person { .name = "alice", .@@employee = @@Employee { .title = "engineer" } };\n'
        "    @@}\n"
    )
    var out = transform_source(source, _person_employee_boss_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
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
        "    @@{\n"
        "        @@init();\n"
        '        var @@dept = @@Department { .name = "Engineering" };\n'
        '        var @@alice = @@Person { .name = "alice", .home = Address(@@dept.name) };\n'
        "    @@}\n"
    )
    var out = transform_source(source, _person_employee_boss_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
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
        "    @@{\n"
        "        @@init();\n"
        '        var @@alice = @@Person { .name = "alice", .employee = bob };\n'
    )
    with assert_raises():
        _ = transform_source(source, _person_employee_boss_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())


def test_transform_source_rejects_at_marked_plain_field_in_construct() raises:
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        '        var @@alice = @@Person { .@@name = "alice" };\n'
    )
    with assert_raises():
        _ = transform_source(source, _person_employee_boss_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())


def test_transform_source_rejects_unknown_relation_hop() raises:
    var source = String(
        "@@struct @@Employee:\n    title: String\n\n"
        "\n"
        "@@struct @@Person:\n    name: String\n    @@employee: @@Employee\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        '        var @@alice = @@Person { .name = "alice", .@@employee = bob };\n'
        "        print(@@alice.@@manager.title);\n"
    )
    with assert_raises():
        _ = transform_source(source, _person_employee_boss_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())


def test_transform_source_threads_entity_across_functions() raises:
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def @@print_name(@@subject: @@Person) raises:\n"
        "    print(@@subject.name);\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        '        var @@alice = @@Person { .name = "alice" };\n'
        "        @@print_name(@@alice);\n"
        "    @@}\n"
    )
    var out = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
    assert_true(
        "def sqrrl__print_name(mut sqrrl__world: sqrrl__World,"
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
        "    @@{\n"
        "        @@init();\n"
        "        @@alice: @@Person;\n"
    )
    with assert_raises():
        _ = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())


def test_transform_source_rejects_field_access_on_unconstructed_entity() raises:
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        "        print(@@alice.name);\n"
    )
    with assert_raises():
        _ = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())


def test_transform_source_rejects_construct_without_world() raises:
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        '    var @@alice = @@Person { .name = "alice" };\n'
    )
    with assert_raises():
        _ = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())


def test_transform_source_rejects_init_without_declare() raises:
    """`@@init()` (and, symmetrically, `@@begin_init_from_json(...)`) needs
    `@@{` to have already brought `sqrrl__world` into scope in this
    same function -- without it there's no `var sqrrl__world` for the bare
    assignment `@@init()` desugars to, to assign into."""
    var source = String(
        "def main() raises:\n"
        "    @@init();\n"
    )
    with assert_raises(contains="needs '@@{'"):
        _ = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())


def test_transform_source_rejects_double_declare() raises:
    """`@@{` twice in the same function is rejected -- `sqrrl__world`
    only needs declaring once; a second `var sqrrl__world: sqrrl__World`
    would be a redeclaration."""
    var source = String(
        "def main() raises:\n"
        "    @@{\n"
        "    @@{\n"
    )
    with assert_raises(contains="already opened"):
        _ = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())


def test_transform_source_allows_conditional_init_after_declare() raises:
    """The whole point of `@@{`: it lets a script choose between
    `@@init()` and `@@begin_init_from_json(...)` conditionally, something
    neither form could do on its own (each used to declare `sqrrl__world`
    itself, so whichever branch ran second would try to redeclare a name
    already out of scope from its sibling branch). `@@{` emits a
    real, live, empty `var sqrrl__world = sqrrl__init()` up front, so
    there's no "uninitialized on some path" state to worry about at all --
    each branch's `@@init()`/`@@begin_init_from_json(...)` is just a bare
    assignment (preceded by a `sqrrl__check_no_leaks()` call verifying the
    about-to-be-replaced world -- still the declare-time empty one here --
    is safe to discard)."""
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def main(dump: String, restore: Bool) raises:\n"
        "    @@{\n"
        "        if restore:\n"
        "            @@begin_init_from_json(dump);\n"
        "        else:\n"
        "            @@init();\n"
        '        var @@alice = @@Person { .name = "alice" };\n'
        "    @@}\n"
    )
    var out = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
    assert_true("var sqrrl__world = sqrrl__init()\n    try:" in out)
    assert_true(
        "sqrrl__world.sqrrl__check_no_leaks(); sqrrl__world ="
        " sqrrl__init_from_json(dump);" in out
    )
    assert_true("sqrrl__world.sqrrl__check_no_leaks(); sqrrl__world = sqrrl__init();" in out)
    assert_true('var sqrrl__alice = sqrrl__world.Person.create(name = "alice");' in out)


def test_transform_source_rewrites_return_type_whose_body_starts_with_a_marker() raises:
    """A `@@`-marked function's own `-> @@Type:` return type used to be
    misrecognized as `MarkerKind.ENTITY_PARAM` whenever its very first body
    statement happened to start with another `@@`-marker: the ENTITY_PARAM
    check (`@@name: @@Type`, same-line) used `skip_trivia`, which crosses
    newlines, to peek past the return type's own trailing colon --
    incidentally finding the *next line's* `@@`-marker and concluding the
    colon belonged to a same-line `@@name: @@Type` shape instead of a
    return type. Confirmed via `-> @@Employee:` directly followed by
    `@@e.title = ...` on the next line, which used to garble into
    `-> sqrrl__Employee: EntityHandle[sqrrl__eTableState].title = ...`
    rather than the correct `-> EntityHandle[sqrrl__EmployeeTableState]:`.
    Fixed by checking `is_after_arrow` (an unambiguous *backward* check)
    before the forward-looking `@@` peek, since `-> @@Type:` is never
    itself a same-line entity-param declaration."""
    var source = String(
        "@@struct @@Employee:\n    title: String\n\n"
        "\n"
        "def @@promote(@@e: @@Employee, new_title: String) -> @@Employee:\n"
        "    @@e.title = new_title;\n"
        "    return @@e;\n"
    )
    var out = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
    assert_true(
        "-> EntityHandle[sqrrl__EmployeeTableState]:" in out
    )
    assert_true("sqrrl__world.Employee.set_title(sqrrl__e, new_title);" in out)
    assert_true("return sqrrl__e;" in out)


def test_transform_source_allows_repeated_begin_init_from_json_in_one_function() raises:
    """`@@begin_init_from_json(...)` may now appear more than once in the
    same straight-line function (not just once per branch of a
    conditional) -- each occurrence desugars to a call into
    `sqrrl__init_from_json` (`driver.emit_world_module`), a *generated
    function* that builds its own `sqrrl__JsonScanner` internally, rather
    than inlining `var sqrrl__scanner = sqrrl__JsonScanner(...)` at the
    call site -- inlining it would redeclare that same local a second
    time here, a genuine Mojo compile error, not just a style concern."""
    var source = String(
        "def main(first: String, second: String) raises:\n"
        "    @@{\n"
        "        @@begin_init_from_json(first);\n"
        "        @@begin_init_from_json(second);\n"
        "    @@}\n"
    )
    var out = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
    assert_true("sqrrl__check_no_leaks(); sqrrl__world = sqrrl__init_from_json(first);" in out)
    assert_true("sqrrl__check_no_leaks(); sqrrl__world = sqrrl__init_from_json(second);" in out)
    assert_true("sqrrl__scanner" not in out)


def test_transform_source_threads_world_through_function_params_and_calls() raises:
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        "        @@make_person();\n"
        "    @@}\n"
        "\n"
        'def @@make_person() raises:\n'
        '    var @@alice = @@Person { .name = "alice" };\n'
    )
    var out = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
    assert_true("sqrrl__make_person(sqrrl__world);" in out)
    assert_true("def sqrrl__make_person(mut sqrrl__world: sqrrl__World) raises:" in out)
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
        "    @@{\n"
        "        @@init();\n"
        "        @@make_person();\n"
        "    @@}\n"
    )
    var out = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
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
        "    @@{\n"
        "        @@init();\n"
        '        var @@dept = @@make_department("Engineering");\n'
        "    @@}\n"
    )
    var out = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
    assert_true(
        'var sqrrl__dept = sqrrl__make_department(sqrrl__world, "Engineering");'
        in out
    )


def test_transform_source_rejects_construct_in_function_missing_world_param() raises:
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        "        make_person();\n"
        "    \n"
        "def make_person() raises:\n"
        '    var @@alice = @@Person { .name = "alice" };\n'
    )
    with assert_raises():
        _ = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())


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
        "    @@{\n"
        "        @@init();\n"
        "        var @@dept: @@Department = @@make_department();\n"
        "        print(@@dept.name);\n"
        "    @@}\n"
    )
    var out = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
    assert_true(
        "def sqrrl__make_department(mut sqrrl__world: sqrrl__World) raises"
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
        "    @@{\n"
        "        @@init();\n"
        "        var @@dept = @@make_department();\n"
        "        print(@@dept.name);\n"
        "    @@}\n"
    )
    var out = transform_source(source, empty_schema(), _department_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
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
        "    @@{\n"
        "        @@init();\n"
        "        var x = @@make_department();\n"
    )
    with assert_raises():
        _ = transform_source(source, empty_schema(), _department_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())


def test_transform_source_allows_entity_returning_call_as_argument() raises:
    """An entity-returning call used as a sub-expression/argument, rather
    than the initializer of a fresh `var` declaration, isn't required to be
    bound to an `@@`-marked variable at all -- there's no variable there to
    mark in the first place."""
    var source = String(
        "@@struct @@Department:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        "        report(@@make_department());\n"
        "    @@}\n"
    )
    var out = transform_source(source, empty_schema(), _department_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
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
        "    @@{\n"
        "        @@init();\n"
        '        var @@matches = @@Person.for_name("alice");\n'
        "    @@}\n"
    )
    var out = transform_source(source, _person_only_schema(), empty_function_returns(), _person_unique_email_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
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
        "    @@{\n"
        "        @@init();\n"
        '        var @@found = @@Person.for_email("alice@example.com");\n'
        "        print(@@found.name);\n"
        "    @@}\n"
    )
    var out = transform_source(source, _person_only_schema(), empty_function_returns(), _person_unique_email_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
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
        "    @@{\n"
        "        @@init();\n"
        '        var found = @@Person.for_email("alice@example.com");\n'
    )
    with assert_raises():
        _ = transform_source(source, _person_only_schema(), empty_function_returns(), _person_unique_email_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())


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
        "    @@{\n"
        "        @@init();\n"
        '        var matches = @@Person.for_name("alice");\n'
    )
    with assert_raises():
        _ = transform_source(source, _person_only_schema(), empty_function_returns(), _person_unique_email_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())


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
        "    @@{\n"
        "        @@init();\n"
        '        var @@matches = @@Person.for_name("alice");\n'
        "        print(@@matches[0].name);\n"
        "    @@}\n"
    )
    var out = transform_source(source, _person_only_schema(), empty_function_returns(), _person_unique_email_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
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
        "    @@{\n"
        "        @@init();\n"
        "        var @@entries = @@Person.all();\n"
        "        print(len(@@entries));\n"
        "    @@}\n"
    )
    var out = transform_source(source, _person_only_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
    assert_true("var sqrrl__entries = sqrrl__world.Person.all();" in out)
    assert_true("print(len(sqrrl__entries));" in out)


def test_transform_source_rejects_unmarked_variable_for_all_call() raises:
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        "        var entries = @@Person.all();\n"
    )
    with assert_raises(contains="Set[@@Person]"):
        _ = transform_source(source, _person_only_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())


def test_transform_source_rewrites_for_loop_over_all_call() raises:
    """`for @@entry in @@Person.all():` binds `@@entry` to the *element*
    type (`Person`), not the whole `Set[Person]` -- so `@@entry.name`
    inside the loop body reads through `get_name`, the same as it would for
    any other single, non-container-tracked entity variable."""
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        "        for @@entry in @@Person.all():\n"
        "            print(@@entry.name);\n"
        "    @@}\n"
    )
    var out = transform_source(source, _person_only_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
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
        "    @@{\n"
        "        @@init();\n"
        "        for @@match in @@Person.for_name(\"alice\"):\n"
        "            print(@@match.email);\n"
        "    @@}\n"
    )
    var out = transform_source(source, _person_only_schema(), empty_function_returns(), _person_unique_email_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
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
    assert_equal(transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets()), source)


def test_transform_source_rejects_field_access_without_index_on_container() raises:
    """`@@matches.name` (no `[i]`) on a container-tracked variable -- rejected
    with a clear error instead of a confusing downstream Mojo failure."""
    var source = String(
        "@@struct @@Person:\n    unique email: String\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        '        var @@matches = @@Person.for_name("alice");\n'
        "        print(@@matches.name);\n"
    )
    with assert_raises():
        _ = transform_source(source, _person_only_schema(), empty_function_returns(), _person_unique_email_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())


def test_transform_source_rejects_index_on_non_container() raises:
    """`@@found[0].name` on a variable that isn't container-tracked --
    rejected, since indexing a single entity doesn't make sense."""
    var source = String(
        "@@struct @@Person:\n    unique email: String\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        '        var @@found = @@Person.for_email("alice@example.com");\n'
        "        print(@@found[0].name);\n"
    )
    with assert_raises():
        _ = transform_source(source, _person_only_schema(), empty_function_returns(), _person_unique_email_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())


def test_transform_source_supports_explicit_container_entity_param() raises:
    """`@@name: List[@@Type] = expr;` -- the explicit-annotation form,
    alongside the auto-inferred one -- emits a `List[EntityHandle[...]]`
    declaration and registers the same container encoding."""
    var source = String(
        "@@struct @@Person:\n    unique email: String\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        '        var @@matches: List[@@Person] = @@Person.for_name("alice");\n'
        "        print(@@matches[0].name);\n"
        "    @@}\n"
    )
    var out = transform_source(source, _person_only_schema(), empty_function_returns(), _person_unique_email_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
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
        "    @@{\n"
        "        @@init();\n"
        "        var @@got = @@Department.get_members(eng);\n"
        "        print(@@got[0].title);\n"
        "    @@}\n"
    )
    var out = transform_source(source, _department_members_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
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
        "    @@{\n"
        "        @@init();\n"
        "        var got = @@Department.get_members(eng);\n"
    )
    with assert_raises():
        _ = transform_source(source, _department_members_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())


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
        "    @@{\n"
        "        @@init();\n"
        '        var @@alice = @@Person { .name = "alice", .@@employee = bob };\n'
        "        var @@boss = @@Employee.get_boss(bob);\n"
        "        print(@@boss.name);\n"
        "    @@}\n"
    )
    var out = transform_source(source, _person_employee_boss_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
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
        "    @@{\n"
        "        @@init();\n"
        "        var boss = @@Employee.get_boss(bob);\n"
    )
    with assert_raises():
        _ = transform_source(source, _person_employee_boss_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())


def test_transform_source_rejects_type_level_call_on_unknown_type() raises:
    """`@@Foo.bar()` where `Foo` is neither a declared entity nor a known
    `@@struct` -- rejected with a clear error instead of silently emitting
    a reference to a type that was never declared."""
    var source = String(
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        "        @@Foo.bar();\n"
    )
    with assert_raises():
        _ = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())


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
    var out = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
    assert_true(
        "def sqrrl__make_team(mut sqrrl__world: sqrrl__World) ->"
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
    var out = transform_source(source, empty_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
    assert_true(
        "def sqrrl__test2(mut sqrrl__world: sqrrl__World) ->"
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
        "    @@{\n"
        "        @@init();\n"
        "        var @@found = @@make_team();\n"
        "        print(@@found[0].name);\n"
        "    @@}\n"
    )
    var out = transform_source(source, empty_schema(), _make_team_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
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
        "    @@{\n"
        "        @@init();\n"
        "        for @@member in @@make_team():\n"
        "            print(@@member.name);\n"
        "    @@}\n"
    )
    var out = transform_source(source, empty_schema(), _make_team_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
    assert_true("for sqrrl__member in  sqrrl__make_team(sqrrl__world):" in out)
    assert_true("print(sqrrl__world.Person.get_name(sqrrl__member));" in out)


def test_transform_source_rejects_unmarked_variable_for_container_returning_world_func_call() raises:
    """`var found = @@make_team();` (unmarked) is rejected for a
    container-returning `@@funcName()`, same as a bare entity-returning one."""
    var source = String(
        "@@struct @@Person:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        "        var found = @@make_team();\n"
    )
    with assert_raises():
        _ = transform_source(source, empty_schema(), _make_team_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())


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
        "    @@{\n"
        "        @@init();\n"
        "        var @@team: List[@@Person] = List[@@Person]();\n"
        "    @@}\n"
    )
    var out = transform_source(source, _person_only_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
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
        "    @@{\n"
        "        @@init();\n"
        "        var team: List[@@Person] = List[@@Person]();\n"
    )
    with assert_raises():
        _ = transform_source(source, _person_only_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())


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
        "    @@{\n"
        "        @@init();\n"
        '        var @@alice = @@Person { .name = "alice" };\n'
        "        var @@team: List[@@Person] = List[@@Person]();\n"
        "        @@team.append(@@alice);\n"
        "    @@}\n"
    )
    var out = transform_source(source, _person_only_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
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
        "    @@{\n"
        "        @@init();\n"
        '        var @@alice = @@Person { .name = "alice" };\n'
        "        var @@team = List[@@Person]();\n"
        "        @@team.append(@@alice);\n"
        "        print(@@team[0].name);\n"
        "    @@}\n"
    )
    var out = transform_source(source, _person_only_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
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
        "    @@{\n"
        "        @@init();\n"
        "        var @@team = some_plain_call();\n"
    )
    with assert_raises():
        _ = transform_source(source, _person_only_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())


def _employee_dept_schema() -> Dict[String, Dict[String, String]]:
    """Employee.dept -> a bare "Department" target -- an ordinary
    (unwrapped, non-`multi`) relation field, the shape `distinct_<field>`
    wraps in `Set[...]` itself (unlike `get_<field>`, which returns the
    bare entity directly for this shape)."""
    var schema = Dict[String, Dict[String, String]]()
    var employee_fields = Dict[String, String]()
    employee_fields["dept"] = "Department"
    schema["Employee"] = employee_fields^
    return schema^


def _department_members_multi_schema() -> Tuple[
    Dict[String, Dict[String, String]], Dict[String, List[String]]
]:
    """Department.members -> a `multi` relation field -- `relation_schema`
    encodes it as `"Set[Employee]"` (`build_relation_schema`'s own doc
    comment), the same shape `distinct_members` itself returns, so
    `rewrite_markers`'s `multi` branch can reuse it as-is. `multi_fields`
    is what tells that branch this *is* the `multi` case, rather than a
    wrapped-but-not-`multi` collection field encoded the exact same way in
    `relation_schema` alone (see `_is_multi_field_query`'s own doc
    comment)."""
    var schema = Dict[String, Dict[String, String]]()
    var department_fields = Dict[String, String]()
    department_fields["members"] = encode_container_type("Set", "Employee")
    schema["Department"] = department_fields^
    var multi_fields = Dict[String, List[String]]()
    var department_multi = List[String]()
    department_multi.append("members")
    multi_fields["Department"] = department_multi^
    return (schema^, multi_fields^)


def test_transform_source_infers_container_type_for_distinct_call() raises:
    """`var @@x = @@Type.distinct_<field>();` for an ordinary (unwrapped,
    non-`multi`) relation field infers `Set[TargetType]` -- `distinct_
    <field>` wraps the field's own bare target type in `Set[...]` itself,
    unlike `get_<field>`, which returns the bare entity directly for this
    same field shape."""
    var source = String(
        "@@struct @@Department:\n    name: String\n\n"
        "\n"
        "@@struct @@Employee:\n    @@dept: @@Department\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        "        var @@depts = @@Employee.distinct_dept();\n"
        "        print(len(@@depts));\n"
        "    @@}\n"
    )
    var out = transform_source(source, _employee_dept_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
    assert_true("var sqrrl__depts = sqrrl__world.Employee.distinct_dept();" in out)
    assert_true("print(len(sqrrl__depts));" in out)


def test_transform_source_rewrites_for_loop_over_distinct_call() raises:
    """`for @@d in @@Employee.distinct_dept():` binds `@@d` to `Department`
    (the field's own target type), not `Employee` (`fa.entity`) -- unlike
    `for_<field>`/`all()`, whose container element is always `fa.entity`
    itself."""
    var source = String(
        "@@struct @@Department:\n    name: String\n\n"
        "\n"
        "@@struct @@Employee:\n    @@dept: @@Department\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        "        for @@d in @@Employee.distinct_dept():\n"
        "            print(@@d.name);\n"
        "    @@}\n"
    )
    var out = transform_source(source, _employee_dept_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
    assert_true("for sqrrl__d in  sqrrl__world.Employee.distinct_dept():" in out)
    assert_true("print(sqrrl__world.Department.get_name(sqrrl__d));" in out)


def test_transform_source_rejects_unmarked_variable_for_distinct_call() raises:
    var source = String(
        "@@struct @@Department:\n    name: String\n\n"
        "\n"
        "@@struct @@Employee:\n    @@dept: @@Department\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        "        var depts = @@Employee.distinct_dept();\n"
    )
    with assert_raises(contains="Set[@@Department]"):
        _ = transform_source(source, _employee_dept_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())


def test_transform_source_infers_element_type_for_multi_distinct_call() raises:
    """`@@Type.distinct_<field>()` for a `multi` relation field is keyed by
    the *element* type (`Employee`), same as `for_<field>`/
    `add_to_<field>`/`remove_from_<field>` already are for `multi` --
    needs `multi_fields` to tell it apart from a wrapped-but-not-`multi`
    collection field encoded identically in `relation_schema` alone."""
    var schema_and_multi = _department_members_multi_schema()
    var source = String(
        "@@struct @@Employee:\n    name: String\n\n"
        "\n"
        "@@struct @@Department:\n    multi @@members: @@Employee\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        "        for @@e in @@Department.distinct_members():\n"
        "            print(@@e.name);\n"
        "    @@}\n"
    )
    var out = transform_source(
        source,
        schema_and_multi[0],
        empty_function_returns(),
        empty_unique_fields(),
        empty_ordered_fields(),
        empty_plain_struct_fields(),
        empty_relation_targets(),
        schema_and_multi[1],
    )
    assert_true("for sqrrl__e in  sqrrl__world.Department.distinct_members():" in out)
    assert_true("print(sqrrl__world.Employee.get_name(sqrrl__e));" in out)


def test_transform_source_leaves_plain_field_distinct_call_untracked() raises:
    """`distinct_<field>` for a *plain* (non-relation) field returns a
    container of ordinary values, not entities -- `@@`-marking its result
    is rejected the same as any other unrecognized shape, not silently
    accepted. Uses `_employee_dept_schema()` specifically so `Employee` is
    a known type with `dept` as its only registered relation field --
    `name` deliberately isn't one, exercising the "field exists but isn't
    a relation" gate, not just "type isn't known at all"."""
    var source = String(
        "@@struct @@Department:\n    name: String\n\n"
        "\n"
        "@@struct @@Employee:\n    name: String\n    @@dept: @@Department\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        "        var @@names = @@Employee.distinct_name();\n"
    )
    with assert_raises():
        _ = transform_source(source, _employee_dept_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())


def test_transform_source_rewrites_for_loop_over_group_by_call() raises:
    """`for @@d in @@Employee.group_by_dept():` binds `@@d` to `Department`
    (the field's own target type, the first/key type parameter of
    `group_by_dept`'s real `Dict[Department, ...]` return) -- same target-
    type resolution `distinct_<field>` uses (`_resolve_relation_field_target`,
    shared), wrapped in `Dict[...]` instead of `Set[...]`. Iterating a bare
    `Dict` yields keys, so binding `@@d` to just the key type is correct --
    the value side (`List[EntityHandle[...]]` per department) isn't
    `@@`-tracked at all."""
    var source = String(
        "@@struct @@Department:\n    name: String\n\n"
        "\n"
        "@@struct @@Employee:\n    @@dept: @@Department\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        "        for @@d in @@Employee.group_by_dept():\n"
        "            print(@@d.name);\n"
        "    @@}\n"
    )
    var out = transform_source(source, _employee_dept_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
    assert_true("for sqrrl__d in  sqrrl__world.Employee.group_by_dept():" in out)
    assert_true("print(sqrrl__world.Department.get_name(sqrrl__d));" in out)


def test_transform_source_rewrites_for_loop_over_count_by_call() raises:
    """Same target-type resolution as `group_by_<field>` above, for
    `count_by_<field>`'s own `Dict[Department, Int]` return -- the `Int`
    value side was never trackable to begin with (not an entity type)."""
    var source = String(
        "@@struct @@Department:\n    name: String\n\n"
        "\n"
        "@@struct @@Employee:\n    @@dept: @@Department\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        "        for @@d in @@Employee.count_by_dept():\n"
        "            print(@@d.name);\n"
        "    @@}\n"
    )
    var out = transform_source(source, _employee_dept_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())
    assert_true("for sqrrl__d in  sqrrl__world.Employee.count_by_dept():" in out)
    assert_true("print(sqrrl__world.Department.get_name(sqrrl__d));" in out)


def test_transform_source_infers_element_type_for_multi_group_by_call() raises:
    """`@@Type.group_by_<field>()` for a `multi` relation field is keyed by
    the *element* type, same as `distinct_<field>`/`for_<field>` are for
    `multi` -- needs `multi_fields` to tell it apart from a wrapped-but-
    not-`multi` collection field encoded identically in `relation_schema`
    alone."""
    var schema_and_multi = _department_members_multi_schema()
    var source = String(
        "@@struct @@Employee:\n    name: String\n\n"
        "\n"
        "@@struct @@Department:\n    multi @@members: @@Employee\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        "        for @@e in @@Department.group_by_members():\n"
        "            print(@@e.name);\n"
        "    @@}\n"
    )
    var out = transform_source(
        source,
        schema_and_multi[0],
        empty_function_returns(),
        empty_unique_fields(),
        empty_ordered_fields(),
        empty_plain_struct_fields(),
        empty_relation_targets(),
        schema_and_multi[1],
    )
    assert_true("for sqrrl__e in  sqrrl__world.Department.group_by_members():" in out)
    assert_true("print(sqrrl__world.Employee.get_name(sqrrl__e));" in out)


def test_transform_source_leaves_plain_field_group_by_call_untracked() raises:
    """`group_by_<field>`/`count_by_<field>` for a *plain* (non-relation)
    field return a `Dict` keyed by ordinary values, not entities --
    `@@`-marking a loop over one is rejected the same as `distinct_<field>`
    is for a plain field."""
    var source = String(
        "@@struct @@Department:\n    name: String\n\n"
        "\n"
        "@@struct @@Employee:\n    name: String\n    @@dept: @@Department\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        "        for @@n in @@Employee.group_by_name():\n"
        "            print(@@n);\n"
    )
    with assert_raises():
        _ = transform_source(source, _employee_dept_schema(), empty_function_returns(), empty_unique_fields(), empty_ordered_fields(), empty_plain_struct_fields(), empty_relation_targets())


def test_emits_sum_avg_min_max_for_math_field() raises:
    """A `math`-marked field earns all four aggregate kinds, paired with
    every other groupable field (`name`, plain here): `_by_` (every group
    at once, `Dict`), `_for_` (one group, raises), and a whole-table
    sibling with no grouping field at all. `avg_` always returns
    `Float64` regardless of the aggregated field's own declared type
    (`Int` here) -- `sum_`/`min_`/`max_` stay in that type."""
    var sc = Scanner("@@struct @@Employee:\n    name: String\n    math score: Int\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true("def sum_score(self) raises -> Int:" in out)
    assert_true("def avg_score(self) raises -> Float64:" in out)
    assert_true("def min_score(self) raises -> Int:" in out)
    assert_true("def max_score(self) raises -> Int:" in out)

    assert_true("def sum_score_by_name(self) -> Dict[String, Int]:" in out)
    assert_true("def sum_score_for_name(self, value: String) raises -> Int:" in out)
    assert_true("def avg_score_by_name(self) -> Dict[String, Float64]:" in out)
    assert_true("def avg_score_for_name(self, value: String) raises -> Float64:" in out)
    assert_true("def min_score_by_name(self) -> Dict[String, Int]:" in out)
    assert_true("def max_score_for_name(self, value: String) raises -> Int:" in out)

    # `name` isn't aggregatable (no `math`, not `ordered`) -- no siblings
    # generated with it as the aggregated field.
    assert_true("def sum_name" not in out)
    assert_true("def avg_name" not in out)
    assert_true("def min_name" not in out)
    assert_true("def max_name" not in out)


def test_ordered_only_field_gets_min_max_but_not_sum_avg() raises:
    """An `ordered` (not `math`) field already proves `Comparable` for
    its own range queries, earning `min_`/`max_` for free -- but not
    `sum_`/`avg_`, which need `+` too, something `ordered` alone never
    established."""
    var sc = Scanner("@@struct @@Employee:\n    name: String\n    ordered years: UInt32\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true("def min_years_by_name(self) -> Dict[String, UInt32]:" in out)
    assert_true("def max_years_by_name(self) -> Dict[String, UInt32]:" in out)
    assert_true("def min_years(self) raises -> UInt32:" in out)
    assert_true("def max_years(self) raises -> UInt32:" in out)
    assert_true("def sum_years" not in out)
    assert_true("def avg_years" not in out)


def test_aggregate_skips_pairing_field_with_itself() raises:
    """Aggregating a field grouped by itself is degenerate -- every entity
    in one of its own value-groups already holds that exact value -- so
    `x == y` is skipped for the `_by_`/`_for_` siblings; the whole-table
    sibling (no grouping field at all) is unaffected."""
    var sc = Scanner("@@struct @@Employee:\n    math salary: Float64\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true("def sum_salary(self)" in out)
    assert_true("def sum_salary_by_salary" not in out)
    assert_true("def sum_salary_for_salary" not in out)


def test_aggregate_by_over_unique_grouping_field_is_trivial() raises:
    """`_by_` grouped by a `unique` field is trivial -- `UniqueRel.all_bwd()`
    already maps each value to its own single id, so there's no bucket to
    materialize into a `List` first, unlike every other modifier."""
    var sc = Scanner("@@struct @@Employee:\n    unique email: String\n    math salary: Float64\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true("def sum_salary_by_email(self) -> Dict[String, Float64]:" in out)
    assert_true("ref sqrrl__ids = self.table.state[].state.email.all_bwd()" in out)
    assert_true("for entry in sqrrl__ids.items():" in out)


def test_aggregate_by_over_multi_grouping_field_keys_by_element_type() raises:
    """`_by_` grouped by a `multi` field is keyed by the *element* type,
    same as `group_by_<field>`/`count_by_<field>` already are for `multi`."""
    var sc = Scanner(
        "@@struct @@Department:\n    multi @@members: @@Employee\n    math budget: Float64\n"
    )
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true(
        "def sum_budget_by_members(self) -> Dict[EntityHandle[sqrrl__EmployeeTableState], Float64]:"
        in out
    )
    assert_true("ref sqrrl__buckets = self.table.state[].state.members.all_bwd()" in out)


def test_aggregate_for_variant_raises_on_empty_group() raises:
    """`_for_` pays for only the one group asked about via `get_bwd(value)`,
    unlike `_by_` which never needs to raise (`all_bwd()`'s own buckets
    are never empty by construction) -- an arbitrary caller-supplied
    `value` can genuinely match nothing, and there's no sensible
    non-raising default for avg/min/max of nothing."""
    var sc = Scanner("@@struct @@Employee:\n    name: String\n    math salary: Float64\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true("def sum_salary_for_name(self, value: String) raises -> Float64:" in out)
    assert_true("if len(sqrrl__ids) == 0:" in out)
    assert_true('raise Error("sum_salary_for_name: no entities found for this value")' in out)


def test_aggregate_whole_table_variant_raises_on_empty_table() raises:
    """The whole-table sibling walks `id_count()`/`is_live` directly (no
    `EntityHandle` built at all, not even a discarded one) -- the same
    primitives `Table.all()` itself uses -- and raises if the table has no
    live entities, same reasoning as `_for_`'s empty-bucket case."""
    var sc = Scanner("@@struct @@Employee:\n    math salary: Float64\n")
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true("def sum_salary(self) raises -> Float64:" in out)
    assert_true("for sqrrl__i in range(self.table.state[].id_count()):" in out)
    assert_true("if self.table.state[].is_live(sqrrl__id):" in out)
    assert_true('raise Error("sum_salary: table has no entities")' in out)


def test_forwardonly_field_excluded_as_aggregate_grouping_field() raises:
    """A `forwardonly` field has no reverse index at all, so it can't be
    an aggregate's grouping field any more than it can `group_by_<field>`/
    `count_by_<field>` itself."""
    var sc = Scanner(
        "@@struct @@Employee:\n    forwardonly tags: List[String]\n    math salary: Float64\n"
    )
    assert_true(sc.find_next_struct_decl())
    var out = emit_table(sc.parse_struct(), empty_plain_struct_fields())

    assert_true("def sum_salary_by_tags" not in out)
    assert_true("def sum_salary_for_tags" not in out)


def test_transform_source_rewrites_for_loop_over_sum_by_call() raises:
    """`sum_<y>_by_<x>()` returns `Dict[Target, ResultType]` when `x` is a
    relation field, tracked the same way `group_by_<field>`/
    `count_by_<field>` are -- `for @@d in @@Employee.sum_salary_by_dept():`
    binds `@@d` to a `Department`."""
    var source = String(
        "@@struct @@Department:\n    name: String\n\n"
        "\n"
        "@@struct @@Employee:\n    name: String\n    @@dept: @@Department\n"
        "    math salary: Float64\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        "        for @@d in @@Employee.sum_salary_by_dept():\n"
        "            print(@@d.name);\n"
        "    @@}\n"
    )
    var out = transform_source(
        source,
        _employee_dept_schema(),
        empty_function_returns(),
        empty_unique_fields(),
        empty_ordered_fields(),
        empty_plain_struct_fields(),
        empty_relation_targets(),
    )
    assert_true("for sqrrl__d in  sqrrl__world.Employee.sum_salary_by_dept():" in out)
    assert_true("print(sqrrl__world.Department.get_name(sqrrl__d));" in out)


def test_transform_source_leaves_plain_field_sum_by_call_untracked() raises:
    """`sum_<y>_by_<x>()` for a *plain* (non-relation) `x` returns a `Dict`
    keyed by ordinary values, not entities -- `@@`-marking a loop over one
    is rejected the same as `group_by_<field>`/`distinct_<field>` are for
    a plain field."""
    var source = String(
        "@@struct @@Employee:\n    name: String\n    @@dept: @@Department\n"
        "    math salary: Float64\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        "        for @@n in @@Employee.sum_salary_by_name():\n"
        "            print(@@n);\n"
        "    @@}\n"
    )
    with assert_raises():
        _ = transform_source(
            source,
            _employee_dept_schema(),
            empty_function_returns(),
            empty_unique_fields(),
            empty_ordered_fields(),
            empty_plain_struct_fields(),
            empty_relation_targets(),
        )


def test_transform_source_rewrites_indexed_field_access_with_post_field() raises:
    """`@@dept.@@members[0].name` -- reads a wrapped relation field,
    indexes into it, and reads a further field off the indexed element,
    all in one expression -- no intermediate `var @@x = @@dept.@@members;`
    binding needed first."""
    var source = String(
        "@@struct @@Employee:\n    name: String\n\n"
        "\n"
        "@@struct @@Department:\n    name: String\n    @@members: List[@@Employee]\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        '        var @@dept = @@Department { .name = "Eng" };\n'
        "        print(@@dept.@@members[0].name);\n"
        "    @@}\n"
    )
    var out = transform_source(
        source,
        _department_members_schema(),
        empty_function_returns(),
        empty_unique_fields(),
        empty_ordered_fields(),
        empty_plain_struct_fields(),
        empty_relation_targets(),
    )
    assert_true(
        "print(sqrrl__world.Employee.get_name(sqrrl__world.Department.get_members(sqrrl__dept)[0]));" in out
    )


def test_transform_source_rewrites_for_loop_over_relation_field_read() raises:
    """`for @@e in @@dept.@@members:` -- iterating a wrapped relation
    field's own read result (not a table-level `for_<field>`/`all()`
    call) binds `@@e` to the field's element type, the same way iterating
    a call's result already does."""
    var source = String(
        "@@struct @@Employee:\n    name: String\n\n"
        "\n"
        "@@struct @@Department:\n    name: String\n    @@members: List[@@Employee]\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        '        var @@dept = @@Department { .name = "Eng" };\n'
        "        for @@e in @@dept.@@members:\n"
        "            print(@@e.name);\n"
        "    @@}\n"
    )
    var out = transform_source(
        source,
        _department_members_schema(),
        empty_function_returns(),
        empty_unique_fields(),
        empty_ordered_fields(),
        empty_plain_struct_fields(),
        empty_relation_targets(),
    )
    assert_true("for sqrrl__e in  sqrrl__world.Department.get_members(sqrrl__dept):" in out)
    assert_true("print(sqrrl__world.Employee.get_name(sqrrl__e));" in out)


def _note_plain_struct_fields() -> Dict[String, List[Field]]:
    """`Note` -- a plain struct with its own `@@author: @@Employee` field,
    the shape `note.@@author` (`note` a plain, unmarked variable) needs to
    tell "direct Mojo field access" (`Note` has no generated table) apart
    from "route through `get_<field>`" (an entity does)."""
    var fields = List[Field]()
    fields.append(Field(name="author", type_str="@@Employee", modifier=FieldModifier.NONE, is_math=False))
    var out = Dict[String, List[Field]]()
    out["Note"] = fields^
    return out^


def _note_relation_schema() -> Dict[String, Dict[String, String]]:
    var schema = Dict[String, Dict[String, String]]()
    var note_fields = Dict[String, String]()
    note_fields["author"] = "Employee"
    schema["Note"] = note_fields^
    return schema^


def test_transform_source_resolves_relation_field_on_unmarked_plain_struct_var() raises:
    """`var note: Note = ...` (unmarked, `PLAIN_VAR_DECL`) followed by
    `note.@@author.name` -- `note` was never itself `@@`-marked, but its
    declared type (`Note`, a known plain struct) is enough to resolve
    `.@@author` against `Note`'s own relation field, emitted as direct
    Mojo field access (`note.author`), not a `sqrrl__world.Note.get_author
    (...)` call -- `Note` has no generated table at all."""
    var source = String(
        "@@struct @@Employee:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        "        var note: Note = Note();\n"
        "        print(note.@@author.name);\n"
        "    @@}\n"
    )
    var out = transform_source(
        source,
        _note_relation_schema(),
        empty_function_returns(),
        empty_unique_fields(),
        empty_ordered_fields(),
        _note_plain_struct_fields(),
        empty_relation_targets(),
    )
    assert_true("var note: Note = Note();" in out)
    assert_true("print(sqrrl__world.Employee.get_name(note.author));" in out)


def test_transform_source_rejects_write_through_implicit_prefix() raises:
    """`note.@@author = @@bob;` -- writing through an implicit,
    unmarked-variable prefix isn't supported (only a read is) -- rejected
    with a clear error rather than silently misinterpreted as declaring a
    fresh `author` variable."""
    var source = String(
        "@@struct @@Employee:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        "        var @@bob = @@Employee { .name = \"Bob\" };\n"
        "        var note: Note = Note();\n"
        "        note.@@author = @@bob;\n"
        "    @@}\n"
    )
    with assert_raises():
        _ = transform_source(
            source,
            _note_relation_schema(),
            empty_function_returns(),
            empty_unique_fields(),
            empty_ordered_fields(),
            _note_plain_struct_fields(),
            empty_relation_targets(),
        )


def test_transform_source_leaves_untracked_prefix_erroring_as_before() raises:
    """An unrelated, never-declared `untracked.@@author` still raises the
    original "never constructed" error -- no implicit-prefix reinterpretation
    fires for a name that was never actually tracked."""
    var source = String(
        "@@struct @@Employee:\n    name: String\n\n"
        "\n"
        "def main() raises:\n"
        "    @@{\n"
        "        @@init();\n"
        "        print(untracked.@@author.name);\n"
        "    @@}\n"
    )
    with assert_raises():
        _ = transform_source(
            source,
            _note_relation_schema(),
            empty_function_returns(),
            empty_unique_fields(),
            empty_ordered_fields(),
            _note_plain_struct_fields(),
            empty_relation_targets(),
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
