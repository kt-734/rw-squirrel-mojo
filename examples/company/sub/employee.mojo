from squirrel_runtime.entity import Table, EntityHandle, TableStateLike
from squirrel_runtime.rel import Rel


struct sqrrl__EmployeeTableState(TableStateLike, Movable, ImplicitlyDeletable):
    var title: Rel[String]

    def __init__(out self):
        self.title = Rel[String]()

    def sqrrl__cleanup_relations(mut self, id: UInt32):
        _ = self.title.fetch_remove_fwd(id)


struct sqrrl__EmployeeTable(Movable):
    var table: Table[sqrrl__EmployeeTableState]

    def __init__(out self):
        self.table = Table[sqrrl__EmployeeTableState](sqrrl__EmployeeTableState())

    def create(mut self, title: String) -> EntityHandle[sqrrl__EmployeeTableState]:
        var e = self.table.create()
        self.table.state[].state.title.put(e.id(), title)
        return e

    def get_title(self, e: EntityHandle[sqrrl__EmployeeTableState]) -> String:
        return self.table.state[].state.title.get_fwd(e.id()).value()

    def set_title(mut self, e: EntityHandle[sqrrl__EmployeeTableState], v: String):
        self.table.state[].state.title.update(e.id(), v)

