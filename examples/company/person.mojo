from squirrel_runtime.entity import Table, EntityHandle, TableStateLike
from squirrel_runtime.rel import Rel
from sub.employee import sqrrl__EmployeeTableState


struct sqrrl__PersonTableState(TableStateLike, Movable, ImplicitlyDeletable):
    var name: Rel[String]
    var employee: Rel[EntityHandle[sqrrl__EmployeeTableState]]

    def __init__(out self):
        self.name = Rel[String]()
        self.employee = Rel[EntityHandle[sqrrl__EmployeeTableState]]()

    def sqrrl__cleanup_relations(mut self, id: UInt32):
        _ = self.name.fetch_remove_fwd(id)
        _ = self.employee.fetch_remove_fwd(id)


struct sqrrl__PersonTable(Movable):
    var table: Table[sqrrl__PersonTableState]

    def __init__(out self):
        self.table = Table[sqrrl__PersonTableState](sqrrl__PersonTableState())

    def create(mut self, name: String, employee: EntityHandle[sqrrl__EmployeeTableState]) -> EntityHandle[sqrrl__PersonTableState]:
        var e = self.table.create()
        self.table.state[].state.name.put(e.id(), name)
        self.table.state[].state.employee.put(e.id(), employee)
        return e

    def get_name(self, e: EntityHandle[sqrrl__PersonTableState]) -> String:
        return self.table.state[].state.name.get_fwd(e.id()).value()

    def set_name(mut self, e: EntityHandle[sqrrl__PersonTableState], v: String):
        self.table.state[].state.name.update(e.id(), v)

    def get_employee(self, e: EntityHandle[sqrrl__PersonTableState]) -> EntityHandle[sqrrl__EmployeeTableState]:
        return self.table.state[].state.employee.get_fwd(e.id()).value()

    def set_employee(mut self, e: EntityHandle[sqrrl__PersonTableState], v: EntityHandle[sqrrl__EmployeeTableState]):
        self.table.state[].state.employee.update(e.id(), v)

