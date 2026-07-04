from squirrel_runtime.entity import Table, EntityHandle, EntityInner, TableStateLike
from squirrel_runtime.rel import Rel, UniqueRel, ForwardOnlyRel, MultiRel, OrderedRel
from std.collections import Set
from std.os import abort


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
