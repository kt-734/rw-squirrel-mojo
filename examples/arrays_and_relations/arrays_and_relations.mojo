from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort
from sqrrl__Squirrel import sqrrl__init, sqrrl__Squirrel


from squirrel_runtime.entity import EntityHandle


struct sqrrl__DepartmentTableState(TableStateLike, Movable, ImplicitlyDeletable):
    var name: Rel[String]

    def __init__(out self):
        self.name = Rel[String]()

    def sqrrl__cleanup_relations(mut self, id: UInt32):
        _ = self.name.fetch_remove_fwd(id)


struct sqrrl__DepartmentTable(Movable):
    var table: Table[sqrrl__DepartmentTableState]

    def __init__(out self):
        self.table = Table[sqrrl__DepartmentTableState](sqrrl__DepartmentTableState())

    def create(mut self, name: String) -> EntityHandle[sqrrl__DepartmentTableState]:
        var e = self.table.create()
        self.table.state[].state.name.put(e.id(), name)
        return e

    def all(self) -> Set[EntityHandle[sqrrl__DepartmentTableState]]:
        return self.table.all()

    def get_name(self, e: EntityHandle[sqrrl__DepartmentTableState]) -> String:
        var got = self.table.state[].state.name.get_fwd(e.id())
        return got.take()

    def set_name(mut self, e: EntityHandle[sqrrl__DepartmentTableState], v: String):
        self.table.state[].state.name.update(e.id(), v)

    def for_name(self, value: String) -> List[EntityHandle[sqrrl__DepartmentTableState]]:
        var ids = self.table.state[].state.name.get_bwd(value)
        var out = List[EntityHandle[sqrrl__DepartmentTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^
struct sqrrl__EmployeeTableState(TableStateLike, Movable, ImplicitlyDeletable):
    var title: Rel[String]
    var dept: Rel[EntityHandle[sqrrl__DepartmentTableState]]

    def __init__(out self):
        self.title = Rel[String]()
        self.dept = Rel[EntityHandle[sqrrl__DepartmentTableState]]()

    def sqrrl__cleanup_relations(mut self, id: UInt32):
        _ = self.title.fetch_remove_fwd(id)
        _ = self.dept.fetch_remove_fwd(id)


struct sqrrl__EmployeeTable(Movable):
    var table: Table[sqrrl__EmployeeTableState]

    def __init__(out self):
        self.table = Table[sqrrl__EmployeeTableState](sqrrl__EmployeeTableState())

    def create(mut self, title: String, dept: EntityHandle[sqrrl__DepartmentTableState]) -> EntityHandle[sqrrl__EmployeeTableState]:
        var e = self.table.create()
        self.table.state[].state.title.put(e.id(), title)
        self.table.state[].state.dept.put(e.id(), dept)
        return e

    def all(self) -> Set[EntityHandle[sqrrl__EmployeeTableState]]:
        return self.table.all()

    def get_title(self, e: EntityHandle[sqrrl__EmployeeTableState]) -> String:
        var got = self.table.state[].state.title.get_fwd(e.id())
        return got.take()

    def set_title(mut self, e: EntityHandle[sqrrl__EmployeeTableState], v: String):
        self.table.state[].state.title.update(e.id(), v)

    def for_title(self, value: String) -> List[EntityHandle[sqrrl__EmployeeTableState]]:
        var ids = self.table.state[].state.title.get_bwd(value)
        var out = List[EntityHandle[sqrrl__EmployeeTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^

    def get_dept(self, e: EntityHandle[sqrrl__EmployeeTableState]) -> EntityHandle[sqrrl__DepartmentTableState]:
        var got = self.table.state[].state.dept.get_fwd(e.id())
        return got.take()

    def set_dept(mut self, e: EntityHandle[sqrrl__EmployeeTableState], v: EntityHandle[sqrrl__DepartmentTableState]):
        self.table.state[].state.dept.update(e.id(), v)

    def for_dept(self, value: EntityHandle[sqrrl__DepartmentTableState]) -> List[EntityHandle[sqrrl__EmployeeTableState]]:
        var ids = self.table.state[].state.dept.get_bwd(value)
        var out = List[EntityHandle[sqrrl__EmployeeTableState]]()
        for id in ids:
            out.append(self.table.handle_for(id))
        return out^
def hire(mut sqrrl__world: sqrrl__Squirrel, title: String, dept: EntityHandle[sqrrl__DepartmentTableState]) -> EntityHandle[sqrrl__EmployeeTableState]:
    # Ordinary, hand-written Mojo -- not a @@-marked construct/call at all
    # -- returning a plain, untracked EntityHandle to show it can still be
    # retroactively marked afterward.
    return sqrrl__world.Employee.create(title=title, dept=dept)


def main() raises:
    var sqrrl__world = sqrrl__init();
    var sqrrl__eng = sqrrl__world.Department.create(name = "Engineering");
    var sqrrl__alice = sqrrl__world.Employee.create(title = "Engineer", dept = sqrrl__eng);
    var sqrrl__bob = sqrrl__world.Employee.create(title = "Senior Engineer", dept = sqrrl__eng);

    # A relation field's own for_<field> works exactly like a plain
    # field's -- @@dept isn't unique, so for_dept returns a List, tracked
    # (via "var @@team = ...", no explicit annotation needed) and
    # indexable with proper @@name[i].field access.
    var sqrrl__team = sqrrl__world.Employee.for_dept(sqrrl__eng);
    print("team size:", len(sqrrl__team));
    print("first team member:", sqrrl__world.Employee.get_title(sqrrl__team[0]));
    sqrrl__world.Employee.set_title(sqrrl__team[0], "Lead Engineer");
    print("after writing through the index:", sqrrl__world.Employee.get_title(sqrrl__team[0]));

    # get_<field> on a relation field returns a single tracked entity too --
    # of the relation's *target* type (Department), not Employee.
    var sqrrl__alices_dept = sqrrl__world.Employee.get_dept(sqrrl__alice);
    print("alice's department:", sqrrl__world.Department.get_name(sqrrl__alices_dept));

    # Indexing without a following field extracts a bare, untracked
    # EntityHandle -- usable as-is, or re-marked with an explicit
    # annotation exactly like a value from ordinary hand-written Mojo
    # (hire, below) can be.
    var raw_member = sqrrl__team[1];
    var sqrrl__second: EntityHandle[sqrrl__EmployeeTableState] = raw_member;
    print("second team member (retroactively marked):", sqrrl__world.Employee.get_title(sqrrl__second));

    var raw_hire = hire(sqrrl__world, "Intern", sqrrl__eng);
    var sqrrl__intern: EntityHandle[sqrrl__EmployeeTableState] = raw_hire;
    print("hired outside @@ syntax, marked after the fact:", sqrrl__world.Employee.get_title(sqrrl__intern));

    print("keep alive:", sqrrl__world.Employee.get_title(sqrrl__alice), sqrrl__world.Employee.get_title(sqrrl__bob), sqrrl__world.Department.get_name(sqrrl__eng));
