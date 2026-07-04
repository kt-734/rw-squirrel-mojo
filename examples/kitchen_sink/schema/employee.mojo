from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort
from schema.department import sqrrl__DepartmentTableState


struct sqrrl__EmployeeTableState(TableStateLike, Movable, ImplicitlyDeletable):
    var email: UniqueRel[String]
    var title: Rel[String]
    var dept: Rel[EntityHandle[sqrrl__DepartmentTableState]]

    def __init__(out self):
        self.email = UniqueRel[String]()
        self.title = Rel[String]()
        self.dept = Rel[EntityHandle[sqrrl__DepartmentTableState]]()

    def sqrrl__cleanup_relations(mut self, id: UInt32):
        _ = self.email.fetch_remove_fwd(id)
        _ = self.title.fetch_remove_fwd(id)
        _ = self.dept.fetch_remove_fwd(id)


struct sqrrl__EmployeeTable(Movable):
    var table: Table[sqrrl__EmployeeTableState]

    def __init__(out self):
        self.table = Table[sqrrl__EmployeeTableState](sqrrl__EmployeeTableState())

    def create(mut self, email: String, title: String, dept: EntityHandle[sqrrl__DepartmentTableState]) raises -> EntityHandle[sqrrl__EmployeeTableState]:
        var e = self.table.create()
        self.table.state[].state.email.put(e.id(), email)
        self.table.state[].state.title.put(e.id(), title)
        self.table.state[].state.dept.put(e.id(), dept)
        return e

    def all(self) -> Set[EntityHandle[sqrrl__EmployeeTableState]]:
        return self.table.all()

    def get_email(self, e: EntityHandle[sqrrl__EmployeeTableState]) -> String:
        var got = self.table.state[].state.email.get_fwd(e.id())
        return got.take()

    def set_email(mut self, e: EntityHandle[sqrrl__EmployeeTableState], v: String) raises:
        self.table.state[].state.email.update(e.id(), v)

    def for_email(self, value: String) raises -> EntityHandle[sqrrl__EmployeeTableState]:
        var id = self.table.state[].state.email.get_bwd(value)
        return self.table.handle_for(id)

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
